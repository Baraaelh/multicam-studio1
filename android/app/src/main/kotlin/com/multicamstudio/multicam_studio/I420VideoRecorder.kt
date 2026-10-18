package com.multicamstudio.multicam_studio

import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaCodecList
import android.media.MediaFormat
import android.media.MediaMuxer
import android.media.MediaRecorder
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.util.Log
import org.webrtc.VideoFrame
import org.webrtc.VideoSink
import java.io.IOException
import java.nio.ByteBuffer
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong

/**
 * Records a WebRTC VideoTrack plus device microphone to a single MP4 file.
 *
 * Video: I420 → NV12 → H.264 via MediaCodec, attached as a VideoSink.
 *        Bypasses EGL entirely so it works on MIUI/MediaTek devices.
 * Audio: PCM from AudioRecord (device mic) → AAC via MediaCodec, muxed alongside video.
 */
class I420VideoRecorder(
    private val outputPath: String,
    private val targetWidth: Int = 1280,
    private val targetHeight: Int = 720,
    private val targetFps: Int = 30,
    private val targetBitRate: Int = 3_000_000,
    /**
     * Use Android's software H.264 encoder even on non-MediaTek devices. Set
     * after this device's hardware encoder already failed in surface mode.
     */
    private val forceSoftwareEncoder: Boolean = false,
) : VideoSink, RecorderDiagnostics {

    private val videoMime = "video/avc"
    private val expectedFrameGapMs = 1_000.0 / targetFps

    companion object {
        private const val TAG = "I420VideoRecorder"

        // Video
        private const val VIDEO_I_FRAME_INTERVAL = 2

        // Audio
        private const val AUDIO_MIME = "audio/mp4a-latm"
        private const val AUDIO_SAMPLE_RATE = 44_100
        private const val AUDIO_CHANNELS = 1
        private const val AUDIO_BIT_RATE = 128_000
        private const val AUDIO_CHANNEL_CONFIG = AudioFormat.CHANNEL_IN_MONO
        private const val AUDIO_FORMAT = AudioFormat.ENCODING_PCM_16BIT

        // Profiling — report every 5 s
        private const val PROF_INTERVAL_MS = 5_000L
    }

    // ── shared ────────────────────────────────────────────────────────────────
    private val isRunning = AtomicBoolean(false)
    private val frameCount = AtomicLong(0)
    private var muxer: MediaMuxer? = null
    private var muxerStarted = false
    private val muxerLock = Any()
    // Both tracks must be added before muxer.start(). audioAvailable=false means
    // AudioRecord init failed; in that case muxer starts on video format alone.
    @Volatile private var videoFormatReady = false
    @Volatile private var audioFormatReady = false
    @Volatile private var audioAvailable = false
    // Diagnostics (see RecorderDiagnostics).
    @Volatile private var muxerEverStarted = false
    @Volatile private var videoSamplesWritten = 0L
    @Volatile private var audioIssue: String? = null
    @Volatile private var rotationSet = false
    // Set when dequeueOutputBuffer() throws IllegalStateException (codec error state).
    // Prevents FATAL EXCEPTION on the I420Vid HandlerThread.
    @Volatile private var encoderFailed = false

    // ── video ─────────────────────────────────────────────────────────────────
    private var videoEncoder: MediaCodec? = null
    private var videoTrackIdx = -1
    private var firstVideoPtsUs = Long.MIN_VALUE
    private var encoderWidth = 0
    private var encoderHeight = 0
    private var encoderStride = 0      // actual row stride the encoder expects (>= width)
    private var encoderSliceHeight = 0 // actual slice height the encoder expects (>= height)

    private val videoThread = HandlerThread("I420Vid").also { it.start() }
    private val videoHandler = Handler(videoThread.looper)
    private val videoBufInfo = MediaCodec.BufferInfo()

    // ── audio ─────────────────────────────────────────────────────────────────
    private var audioEncoder: MediaCodec? = null
    private var audioRecord: AudioRecord? = null
    private var audioTrackIdx = -1
    private var firstAudioPtsUs = Long.MIN_VALUE

    private val audioThread = HandlerThread("I420Aud").also { it.start() }
    private val audioHandler = Handler(audioThread.looper)
    private val audioBufInfo = MediaCodec.BufferInfo()

    // ── profiling ─────────────────────────────────────────────────────────────
    // profLock guards all prof* fields.
    // profFramesReceived / profLastArrivalNs are written from the WebRTC thread
    // (onFrame); everything else is written from videoHandler.  We use one lock
    // for simplicity so the report snapshot is always consistent.
    private val profLock = Any()

    // Window timestamps
    private var profWindowStartNs  = 0L
    private var profLastArrivalNs  = 0L   // for inter-frame gap

    // Frame counts
    private var profFramesReceived   = 0L   // onFrame() calls
    private var profFramesProcessed  = 0L   // successfully submitted to encoder
    private var profFramesEncoded    = 0L   // written to muxer
    private var profFramesDroppedEnq = 0L   // dequeueInputBuffer() returned < 0
    private var profFramesSkipped    = 0L   // toI420() null or encoder not ready

    // Arrival timing (written from WebRTC thread)
    private var profArrivalSumNs     = 0L   // sum of inter-frame gaps

    // Stage timing accumulators — accumulated only for FULLY PROCESSED frames
    // so that per-frame averages and percentages are mutually comparable.
    private var profStage2I420Ns      = 0L  // frame.buffer.toI420()
    private var profStage3NV12Ns      = 0L  // writeNV12 / writeNV12Scaled
    private var profStage4BufOpsNs    = 0L  // getInputBuffer + buf.clear + queueInputBuffer
    private var profStage5QueueWaitNs = 0L  // dequeueInputBuffer wait
    private var profStage6EncodeNs    = 0L  // dequeueOutputBuffer wait (hardware encode latency)
    private var profStage7MuxNs       = 0L  // writeSampleData

    // Total wall-clock time inside processVideoFrame for processed frames
    private var profTotalProcessNs   = 0L

    // Encoder queue wait for dropped frames (separate so it doesn't skew processed avgs)
    private var profDropQueueWaitNs  = 0L

    // Periodic reporter posted on videoHandler
    private val profReporter = object : Runnable {
        override fun run() {
            if (!isRunning.get()) return
            printProfilingReport()
            videoHandler.postDelayed(this, PROF_INTERVAL_MS)
        }
    }

    // ─────────────────────────────────────────────────────────────────────────

    @Throws(IOException::class)
    fun start(recordAudio: Boolean = true) {
        val t0 = System.nanoTime()
        Log.i(TAG, "DIAG start() called thread=${Thread.currentThread().name} ts=${System.currentTimeMillis()}")

        frameCount.set(0)
        rotationSet = false
        muxer = MediaMuxer(outputPath, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
        isRunning.set(true)

        synchronized(profLock) { resetProfWindow(System.nanoTime()) }

        val tEnc = System.nanoTime()
        initVideoEncoder(targetWidth, targetHeight)
        Log.i(TAG, "DIAG initVideoEncoder total: ${(System.nanoTime() - tEnc) / 1_000_000L}ms")

        val tAud = System.nanoTime()
        if (recordAudio) startAudioCapture()
        Log.i(TAG, "DIAG audio init total: ${(System.nanoTime() - tAud) / 1_000_000L}ms")

        Log.i(TAG, "DIAG start() total: ${(System.nanoTime() - t0) / 1_000_000L}ms — main thread blocked this long")

        videoHandler.postDelayed(profReporter, PROF_INTERVAL_MS)
        // Early 2-second report to surface startup bottlenecks without waiting 5 s.
        videoHandler.postDelayed({ Log.i(TAG, "DIAG 2s report:"); printProfilingReport() }, 2_000L)
        Log.d(TAG, "start(recordAudio=$recordAudio) → $outputPath")
    }

    // ── VideoSink ─────────────────────────────────────────────────────────────

    override fun onFrame(frame: VideoFrame) {
        // VideoSink.onFrame() receives a borrowed frame reference owned by the delivery chain
        // (VideoProcessor). Do NOT call frame.release() here — that over-releases the refcount
        // and crashes EglRenderer's EglThread when it tries to release its own retained copy.
        if (!isRunning.get()) { return }

        val now = System.nanoTime()
        synchronized(profLock) {
            if (profLastArrivalNs > 0L) profArrivalSumNs += now - profLastArrivalNs
            profLastArrivalNs = now
            profFramesReceived++
        }

        val fc = frameCount.incrementAndGet()
        if (fc <= 5L) {
            Log.i(TAG, "DIAG frame #$fc ${frame.rotatedWidth}×${frame.rotatedHeight} thread=${Thread.currentThread().name}")
        }

        // WebRTC camera tracks on Android 13+ deliver TextureBuffer (GPU OES texture).
        // Calling TextureBuffer.toI420() on a thread without a current EGL context causes
        // a native crash on some MediaTek / Android 16 devices. The WebRTC delivery thread
        // always has a valid EGL context, so we convert here and post the I420Buffer.
        if (frame.buffer is VideoFrame.TextureBuffer) {
            // Retain explicitly before toI420(): toI420() posts its conversion lambda to
            // the camera EGL handler via invokeAtFrontUninterruptibly(), blocking this
            // thread. A concurrent release from WebRTC's EncoderQueue during that window
            // can drop the refcount to 0, causing toI420()'s internal retain() to throw
            // "retain() called on an object with refcount < 1" → SIGABRT on EncoderQueue.
            frame.buffer.retain()
            val i420 = frame.buffer.toI420()
            frame.buffer.release()          // balance explicit retain
            // Do NOT call frame.release() here. VideoSink.onFrame() receives a borrowed
            // frame reference — the delivery chain (VideoProcessor) releases it after all
            // sinks return. Releasing here causes VideoProcessor.onFrameCaptured:51 to
            // throw "release() called on an object with refcount < 1" → SIGKILL.
            if (i420 == null) {
                Log.w(TAG, "TextureBuffer.toI420() null — skipping frame #$fc")
                synchronized(profLock) { profFramesSkipped++ }
                return
            }
            val i420Frame = VideoFrame(i420, frame.rotation, frame.timestampNs)
            videoHandler.post { processVideoFrame(i420Frame) }
            return
        }

        frame.retain()
        videoHandler.post { processVideoFrame(frame) }
    }

    // ── video encoding ────────────────────────────────────────────────────────

    private fun initVideoEncoder(w: Int, h: Int) {
        Log.i(TAG, "DIAG initVideoEncoder ${w}×${h}@${targetFps}fps ${targetBitRate}bps thread=${Thread.currentThread().name}")
        encoderWidth = w; encoderHeight = h
        val fmt = MediaFormat.createVideoFormat(videoMime, w, h).apply {
            setInteger(MediaFormat.KEY_COLOR_FORMAT,
                MediaCodecInfo.CodecCapabilities.COLOR_FormatYUV420SemiPlanar)
            setInteger(MediaFormat.KEY_BIT_RATE, targetBitRate)
            setInteger(MediaFormat.KEY_FRAME_RATE, targetFps)
            setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, VIDEO_I_FRAME_INTERVAL)
            // Do NOT set KEY_PREPEND_HEADER_TO_SYNC_FRAMES: inline SPS/PPS in the
            // bitstream conflict with the container-level csd-0/csd-1 that
            // VideoRenderService writes from the first file, causing corruption at
            // every cut boundary when cameras have different encoder hardware.
            // KEY_I_FRAME_INTERVAL=0 already makes every frame a keyframe, so
            // the container codec config is sufficient for random-access decoding.
        }
        val isMtk = Build.HARDWARE.lowercase().startsWith("mt") ||
                    (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S && Build.SOC_MANUFACTURER.lowercase().contains("mediatek"))

        val tCreate = System.nanoTime()
        videoEncoder = if (isMtk || forceSoftwareEncoder) {
            try {
                Log.i(TAG, "DIAG forcing software encoder (mtk=$isMtk forced=$forceSoftwareEncoder)")
                try {
                    MediaCodec.createByCodecName("c2.android.avc.encoder")
                } catch (e: Exception) {
                    MediaCodec.createByCodecName("OMX.google.h264.encoder")
                }
            } catch (e: Exception) {
                Log.w(TAG, "DIAG fallback to default encoder: ${e.message}")
                MediaCodec.createEncoderByType(videoMime)
            }
        } else {
            MediaCodec.createEncoderByType(videoMime)
        }.also {
            Log.i(TAG, "DIAG encoder created: ${(System.nanoTime() - tCreate) / 1_000_000L}ms → ${it.name} isHW=${isHwEncoder(it.name)}")
            val tConf = System.nanoTime()
            it.configure(fmt, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
            Log.i(TAG, "DIAG encoder configure(): ${(System.nanoTime() - tConf) / 1_000_000L}ms")
            val tCodecStart = System.nanoTime()
            it.start()
            Log.i(TAG, "DIAG encoder start(): ${(System.nanoTime() - tCodecStart) / 1_000_000L}ms")
            // Query the actual buffer layout the encoder expects in its input buffers.
            // Hardware encoders often pad width/height to 16- or 32-pixel boundaries;
            // writing packed (non-padded) rows places the UV plane at the wrong offset
            // and causes severe chroma corruption ("bad TV signal" effect).
            val inFmt = it.inputFormat
            val rawStride = try { inFmt.getInteger(MediaFormat.KEY_STRIDE) } catch (_: Exception) { 0 }
            val rawSlice  = try { inFmt.getInteger(MediaFormat.KEY_SLICE_HEIGHT) } catch (_: Exception) { 0 }
            encoderStride      = if (rawStride > w) rawStride else w
            encoderSliceHeight = if (rawSlice  > h) rawSlice  else h
            Log.d(TAG, "encoder input: stride=$encoderStride sliceHeight=$encoderSliceHeight (frame ${w}×${h})")
        }
        Log.d(TAG, "videoEncoder started (${videoEncoder!!.name})")
    }

    private fun isHwEncoder(name: String): Boolean {
        if (Build.VERSION.SDK_INT >= 29) {
            return MediaCodecList(MediaCodecList.ALL_CODECS).codecInfos
                .firstOrNull { it.name == name }?.isHardwareAccelerated ?: false
        }
        // Pre-API 29: "OMX.google.*" names are Google's software reference encoders.
        return !name.lowercase().startsWith("omx.google.")
    }

    private fun processVideoFrame(frame: VideoFrame) {
        val frameStart = System.nanoTime()

        // Local timing slots — populated incrementally as we pass each stage.
        // All stay 0 if the stage is never reached (dropped / skipped frames).
        var localI420Ns     = 0L
        var localNv12Ns     = 0L
        var localBufOpsNs   = 0L
        var localQueueWaitNs= 0L
        var wasProcessed    = false
        var wasDropped      = false

        try {
            if (encoderFailed) return

            // ── [2] I420 conversion ───────────────────────────────────────────
            val t2 = System.nanoTime()
            val i420 = frame.buffer.toI420()
            localI420Ns = System.nanoTime() - t2

            if (i420 == null) {
                Log.w(TAG, "toI420() null — skipping")
                synchronized(profLock) { profFramesSkipped++ }
                return
            }

            try {
                val fw = i420.width; val fh = i420.height
                if (!rotationSet) {
                    // Rotation must be set before muxer.start() (called inside maybeStartMuxer
                    // on INFO_OUTPUT_FORMAT_CHANGED). First frame is the earliest we know it.
                    muxer?.setOrientationHint(frame.rotation)
                    rotationSet = true
                    if (fw != targetWidth || fh != targetHeight) {
                        Log.d(TAG, "source frame ${fw}×${fh} — scaling to ${targetWidth}×${targetHeight}")
                    }
                }

                val enc = videoEncoder ?: run {
                    synchronized(profLock) { profFramesSkipped++ }
                    return
                }

                // ── [5] Encoder input queue wait ──────────────────────────────
                val t5 = System.nanoTime()
                val idx = enc.dequeueInputBuffer(10_000L)
                localQueueWaitNs = System.nanoTime() - t5

                if (idx < 0) {
                    wasDropped = true
                    return
                }

                // ── [4a] Get + clear input buffer ─────────────────────────────
                val t4a = System.nanoTime()
                val buf = enc.getInputBuffer(idx) ?: run {
                    enc.queueInputBuffer(idx, 0, 0, 0, 0)
                    wasDropped = true
                    return
                }
                buf.clear()
                val getBufNs = System.nanoTime() - t4a

                // ── [3] NV12 conversion + memory copy ─────────────────────────
                // Encompasses: I420-planar → NV12-interleaved pixel conversion AND
                // the bulk ByteBuffer writes into the encoder input buffer.
                // These two operations are inseparable in the current implementation
                // without adding nanoTime() inside tight pixel loops (which would
                // dominate the measurement itself).
                val t3 = System.nanoTime()
                if (fw == targetWidth && fh == targetHeight) {
                    writeNV12(i420, buf, encoderStride, encoderSliceHeight)
                } else {
                    writeNV12Scaled(i420, buf, encoderStride, encoderSliceHeight)
                }
                localNv12Ns = System.nanoTime() - t3

                // ── [4b] Submit frame to encoder ──────────────────────────────
                val t4b = System.nanoTime()
                enc.queueInputBuffer(idx, 0, buf.position(), frame.timestampNs / 1_000L, 0)
                localBufOpsNs = getBufNs + (System.nanoTime() - t4b)

                wasProcessed = true
            } finally { i420.release() }

            // ── [6+7] Drain encoder ────────────────────────────────────────────
            // encode-wait and mux-write times are accumulated inside drainVideoEncoder.
            drainVideoEncoder(false)

        } finally {
            frame.release()
            val totalNs = System.nanoTime() - frameStart

            synchronized(profLock) {
                when {
                    wasProcessed -> {
                        profFramesProcessed++
                        profStage2I420Ns      += localI420Ns
                        profStage3NV12Ns      += localNv12Ns
                        profStage4BufOpsNs    += localBufOpsNs
                        profStage5QueueWaitNs += localQueueWaitNs
                        profTotalProcessNs    += totalNs
                    }
                    wasDropped -> {
                        profFramesDroppedEnq++
                        // Track drop queue-wait separately so it doesn't inflate
                        // the per-processed-frame encoder-queue average.
                        profDropQueueWaitNs += localQueueWaitNs
                    }
                    // else: skipped frame already counted in its own branch above
                }
            }
        }
    }

    private fun writeNV12(i420: VideoFrame.I420Buffer, dst: ByteBuffer, stride: Int, sliceHeight: Int) {
        val w = i420.width; val h = i420.height
        val cW = (w + 1) / 2; val cH = (h + 1) / 2
        val pad = ByteArray(stride) // zero-filled, reused for alignment padding rows

        // Y plane: stride bytes per row × sliceHeight rows.
        val yRow = ByteArray(stride)
        val yBuf = i420.dataY
        for (row in 0 until h) {
            yBuf.position(row * i420.strideY)
            yBuf.get(yRow, 0, w)
            dst.put(yRow, 0, stride)
        }
        for (row in h until sliceHeight) dst.put(pad, 0, stride)

        // UV plane (NV12 — interleaved U,V): stride bytes per row × (sliceHeight/2) rows.
        // Bulk ByteBuffer.get(array) uses System.arraycopy internally and is ~5× faster
        // than calling uBuf.get() / vBuf.get() once per pixel pair, which matters at
        // 720p (460 k calls/frame) and especially at 1080p+ (1 M+ calls/frame).
        val uArr = ByteArray(cW)
        val vArr = ByteArray(cW)
        val uvRow = ByteArray(stride)
        val uBuf = i420.dataU; val vBuf = i420.dataV
        for (row in 0 until cH) {
            uBuf.position(row * i420.strideU)
            vBuf.position(row * i420.strideV)
            uBuf.get(uArr, 0, cW)
            vBuf.get(vArr, 0, cW)
            var j = 0
            for (col in 0 until cW) { uvRow[j++] = uArr[col]; uvRow[j++] = vArr[col] }
            dst.put(uvRow, 0, stride)
        }
        for (row in cH until sliceHeight / 2) dst.put(pad, 0, stride)
    }

    // Nearest-neighbour scale from source I420 dimensions to targetWidth × targetHeight,
    // then interleave into NV12 with encoder stride/slice padding.
    // Source rows are bulk-read into temp arrays once per row so that the inner
    // pixel loop does fast array indexing rather than per-pixel ByteBuffer.get().
    private fun writeNV12Scaled(i420: VideoFrame.I420Buffer, dst: ByteBuffer, stride: Int, sliceHeight: Int) {
        val srcW = i420.width; val srcH = i420.height
        val srcCW = (srcW + 1) / 2; val srcCH = (srcH + 1) / 2
        val dstCW = (targetWidth + 1) / 2; val dstCH = (targetHeight + 1) / 2
        val xRatioY = srcW.toFloat() / targetWidth
        val yRatioY = srcH.toFloat() / targetHeight
        val xRatioC = srcCW.toFloat() / dstCW
        val yRatioC = srcCH.toFloat() / dstCH
        val pad = ByteArray(stride)

        val ySrcRow = ByteArray(srcW)
        val yRow = ByteArray(stride)
        var prevSyY = -1
        for (dy in 0 until targetHeight) {
            val sy = (dy * yRatioY).toInt().coerceIn(0, srcH - 1)
            if (sy != prevSyY) {
                i420.dataY.position(sy * i420.strideY)
                i420.dataY.get(ySrcRow, 0, srcW)
                prevSyY = sy
            }
            for (dx in 0 until targetWidth) {
                val sx = (dx * xRatioY).toInt().coerceIn(0, srcW - 1)
                yRow[dx] = ySrcRow[sx]
            }
            dst.put(yRow, 0, stride)
        }
        for (row in targetHeight until sliceHeight) dst.put(pad, 0, stride)

        val uSrcRow = ByteArray(srcCW)
        val vSrcRow = ByteArray(srcCW)
        val uvRow = ByteArray(stride)
        var prevSyC = -1
        for (dy in 0 until dstCH) {
            val sy = (dy * yRatioC).toInt().coerceIn(0, srcCH - 1)
            if (sy != prevSyC) {
                i420.dataU.position(sy * i420.strideU)
                i420.dataU.get(uSrcRow, 0, srcCW)
                i420.dataV.position(sy * i420.strideV)
                i420.dataV.get(vSrcRow, 0, srcCW)
                prevSyC = sy
            }
            var j = 0
            for (dx in 0 until dstCW) {
                val sx = (dx * xRatioC).toInt().coerceIn(0, srcCW - 1)
                uvRow[j++] = uSrcRow[sx]
                uvRow[j++] = vSrcRow[sx]
            }
            dst.put(uvRow, 0, stride)
        }
        for (row in dstCH until sliceHeight / 2) dst.put(pad, 0, stride)
    }

    private fun drainVideoEncoder(endOfStream: Boolean) {
        if (encoderFailed) return
        val enc = videoEncoder ?: return
        val mux = muxer ?: return
        var eosRetries = 0

        // Per-drain accumulators — flushed to profLock under sync at the end.
        // Keeping them local avoids lock contention inside the drain loop.
        var localEncodeWaitNs = 0L
        var localMuxWriteNs   = 0L
        var localEncoded      = 0

        while (true) {
            // ── [6] Encoder output wait ────────────────────────────────────────
            val tDq = System.nanoTime()
            val status: Int
            try {
                status = enc.dequeueOutputBuffer(videoBufInfo, if (endOfStream) 50_000L else 5_000L)
            } catch (e: IllegalStateException) {
                Log.e(TAG, "drainVideoEncoder: codec in error state — aborting: ${e.message}")
                encoderFailed = true
                isRunning.set(false)
                return
            }
            localEncodeWaitNs += System.nanoTime() - tDq

            when (status) {
                MediaCodec.INFO_TRY_AGAIN_LATER -> if (!endOfStream || ++eosRetries > 40) break
                MediaCodec.INFO_OUTPUT_BUFFERS_CHANGED -> Unit
                MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                    synchronized(muxerLock) {
                        videoTrackIdx = mux.addTrack(enc.outputFormat)
                        videoFormatReady = true
                        Log.d(TAG, "video format ready, track=$videoTrackIdx")
                        maybeStartMuxer(mux)
                    }
                }
                else -> if (status >= 0) {
                    if (muxerStarted && videoBufInfo.size > 0) {
                        enc.getOutputBuffer(status)?.let { buf ->
                            buf.position(videoBufInfo.offset)
                            buf.limit(videoBufInfo.offset + videoBufInfo.size)
                            if (firstVideoPtsUs == Long.MIN_VALUE) firstVideoPtsUs = videoBufInfo.presentationTimeUs
                            videoBufInfo.presentationTimeUs -= firstVideoPtsUs

                            // ── [7] Muxer write ───────────────────────────────
                            val tMux = System.nanoTime()
                            synchronized(muxerLock) { mux.writeSampleData(videoTrackIdx, buf, videoBufInfo) }
                            videoSamplesWritten++
                            localMuxWriteNs += System.nanoTime() - tMux
                            localEncoded++
                        }
                    }
                    enc.releaseOutputBuffer(status, false)
                    if (videoBufInfo.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) break
                }
            }
        }

        synchronized(profLock) {
            profStage6EncodeNs += localEncodeWaitNs
            profStage7MuxNs    += localMuxWriteNs
            profFramesEncoded  += localEncoded
        }
    }

    // ── profiling report ──────────────────────────────────────────────────────

    private fun printProfilingReport() {
        val now = System.nanoTime()

        // Snapshot and reset all accumulators atomically.
        val windowNs: Long
        val received: Long
        val processed: Long
        val encoded: Long
        val droppedEnq: Long
        val skipped: Long
        val arrivalSumNs: Long
        val i420Ns: Long
        val nv12Ns: Long
        val bufOpsNs: Long
        val queueWaitNs: Long
        val encodeNs: Long
        val muxNs: Long
        val totalProcessNs: Long
        val dropQueueWaitNs: Long

        synchronized(profLock) {
            windowNs        = now - profWindowStartNs
            received        = profFramesReceived
            processed       = profFramesProcessed
            encoded         = profFramesEncoded
            droppedEnq      = profFramesDroppedEnq
            skipped         = profFramesSkipped
            arrivalSumNs    = profArrivalSumNs
            i420Ns          = profStage2I420Ns
            nv12Ns          = profStage3NV12Ns
            bufOpsNs        = profStage4BufOpsNs
            queueWaitNs     = profStage5QueueWaitNs
            encodeNs        = profStage6EncodeNs
            muxNs           = profStage7MuxNs
            totalProcessNs  = profTotalProcessNs
            dropQueueWaitNs = profDropQueueWaitNs

            resetProfWindow(now)
        }

        val windowSec = windowNs / 1_000_000_000.0
        val fpsIn     = if (windowSec > 0) received  / windowSec else 0.0
        val fpsOut    = if (windowSec > 0) encoded   / windowSec else 0.0

        // Average inter-frame gap from onFrame() arrivals.
        val gaps = received - 1   // N frames → N-1 gaps
        val avgArrivalMs = if (gaps > 0) arrivalSumNs.toDouble() / gaps / 1_000_000.0 else 0.0

        // Per-frame averages for processed frames only.
        fun avgMs(ns: Long): Double = if (processed > 0) ns.toDouble() / processed / 1_000_000.0 else 0.0
        fun avgMsEnc(ns: Long): Double = if (encoded  > 0) ns.toDouble() / encoded  / 1_000_000.0 else 0.0

        val avgI420Ms     = avgMs(i420Ns)
        val avgNv12Ms     = avgMs(nv12Ns)
        val avgBufOpsMs   = avgMs(bufOpsNs)
        val avgQueueWaitMs= avgMs(queueWaitNs)
        val avgEncodeMs   = avgMs(encodeNs)
        val avgMuxMs      = avgMsEnc(muxNs)
        val avgTotalMs    = avgMs(totalProcessNs)

        // Stage percentages (relative to total processVideoFrame wall-clock for processed frames).
        fun pct(ns: Long): String {
            if (totalProcessNs <= 0L) return "  N/A"
            return "%5.1f%%".format(ns * 100.0 / totalProcessNs)
        }
        fun fmtMs(ms: Double): String = "%8.3f ms".format(ms)

        // Identify dominant stage.
        val stageNs = listOf(
            "I420 conversion"    to i420Ns,
            "NV12 conv+memcopy"  to nv12Ns,
            "Buffer ops"         to bufOpsNs,
            "Encoder queue wait" to queueWaitNs,
            "Encoder output wait" to encodeNs,
            "Muxer write"        to muxNs
        )
        val bottleneck = stageNs.maxByOrNull { it.second }?.first ?: "unknown"

        // CPU budget: how much of the 33.3 ms/frame budget are we using?
        val budgetPct = if (avgTotalMs > 0) avgTotalMs / expectedFrameGapMs * 100.0 else 0.0

        // Drop queue wait for context.
        val avgDropQueueMs = if (droppedEnq > 0) dropQueueWaitNs.toDouble() / droppedEnq / 1_000_000.0 else 0.0

        // Unmeasured overhead within processVideoFrame (finalies, branches, etc.)
        val measuredNs = i420Ns + nv12Ns + bufOpsNs + queueWaitNs + encodeNs + muxNs
        val overheadNs = (totalProcessNs - measuredNs).coerceAtLeast(0L)

        Log.i(TAG, "")
        Log.i(TAG, "╔══════════════════════════════════════════════════════════════════╗")
        Log.i(TAG, "║  I420VideoRecorder — PERF REPORT  (${"%4.1f".format(windowSec)}s window)            ║")
        Log.i(TAG, "╠══════════════════════════════════════════════════════════════════╣")
        Log.i(TAG, "║  FPS received : ${"%.2f".format(fpsIn).padStart(6)}   FPS encoded : ${"%.2f".format(fpsOut).padStart(6)}                 ║")
        Log.i(TAG, "║  Frames   recv=${received.toString().padStart(5)}  processed=${processed.toString().padStart(5)}  encoded=${encoded.toString().padStart(5)}      ║")
        Log.i(TAG, "║  Dropped (enc queue full)=${droppedEnq.toString().padStart(5)}   Skipped (I420/enc null)=${skipped.toString().padStart(4)} ║")
        Log.i(TAG, "║  Avg inter-frame gap : ${"%.3f".format(avgArrivalMs).padStart(8)} ms  (expected ${"%5.3f".format(expectedFrameGapMs)} ms)     ║")
        Log.i(TAG, "╠══════════════════════════════════════════════════════════════════╣")
        Log.i(TAG, "║  Stage                         avg/proc-frame    % of total     ║")
        Log.i(TAG, "║  ─────────────────────────────────────────────────────────────  ║")
        Log.i(TAG, "║  [2] I420 conversion        ${fmtMs(avgI420Ms)}      ${pct(i420Ns)}        ║")
        Log.i(TAG, "║  [3] NV12 conv + mem copy   ${fmtMs(avgNv12Ms)}      ${pct(nv12Ns)}        ║")
        Log.i(TAG, "║  [4] Buffer ops             ${fmtMs(avgBufOpsMs)}      ${pct(bufOpsNs)}        ║")
        Log.i(TAG, "║       (getInputBuf + clear + queueInputBuf)                     ║")
        Log.i(TAG, "║  [5] Encoder queue wait     ${fmtMs(avgQueueWaitMs)}      ${pct(queueWaitNs)}        ║")
        Log.i(TAG, "║       (dequeueInputBuffer timeout=10ms)                         ║")
        Log.i(TAG, "║  [6] Encoder output wait    ${fmtMs(avgEncodeMs)}      ${pct(encodeNs)}        ║")
        Log.i(TAG, "║       (dequeueOutputBuffer — hardware encode latency)           ║")
        Log.i(TAG, "║  [7] Muxer write            ${fmtMs(avgMuxMs)}   (per encoded frame)   ║")
        Log.i(TAG, "║       (writeSampleData)                                         ║")
        Log.i(TAG, "║  [O] Unmeasured overhead    ${fmtMs(avgMs(overheadNs))}      ${pct(overheadNs)}        ║")
        Log.i(TAG, "║  ─────────────────────────────────────────────────────────────  ║")
        Log.i(TAG, "║  TOTAL processVideoFrame    ${fmtMs(avgTotalMs)}                        ║")
        Log.i(TAG, "╠══════════════════════════════════════════════════════════════════╣")
        Log.i(TAG, "║  CPU BUDGET : ${"%.1f".format(avgTotalMs).padStart(6)} ms / ${"%.3f".format(expectedFrameGapMs)} ms = ${"%.1f".format(budgetPct).padStart(5)}% utilized      ║")
        if (droppedEnq > 0) {
            Log.i(TAG, "║  DROPPED FRAMES : avg enc-queue wait = ${"%.3f".format(avgDropQueueMs).padStart(8)} ms/drop       ║")
        }
        Log.i(TAG, "║                                                                  ║")
        Log.i(TAG, "║  *** DOMINANT BOTTLENECK : $bottleneck ***")
        Log.i(TAG, "╚══════════════════════════════════════════════════════════════════╝")
        Log.i(TAG, "")

        // Extra CPU-stress indicators on separate lines for easier grep.
        if (budgetPct > 90.0) {
            Log.w(TAG, "PERF_WARN: CPU budget >90% (${"%5.1f".format(budgetPct)}%) — frame drops imminent")
        }
        if (droppedEnq > received / 10) {
            Log.w(TAG, "PERF_WARN: >10% frames dropped by encoder queue ($droppedEnq / $received)")
        }
        if (avgQueueWaitMs > 5.0) {
            Log.w(TAG, "PERF_WARN: Encoder queue wait avg ${"%5.2f".format(avgQueueWaitMs)}ms — encoder likely overloaded")
        }
        if (avgNv12Ms > 15.0) {
            Log.w(TAG, "PERF_WARN: NV12 conv+copy avg ${"%5.2f".format(avgNv12Ms)}ms — CPU pixel loop is the bottleneck")
        }
        if (fpsIn > 0 && fpsOut < fpsIn * 0.85) {
            Log.w(TAG, "PERF_WARN: FPS gap recv=${"%4.1f".format(fpsIn)} enc=${"%4.1f".format(fpsOut)} — pipeline cannot keep up")
        }
    }

    private fun resetProfWindow(nowNs: Long) {
        // Must be called under profLock.
        profWindowStartNs    = nowNs
        profLastArrivalNs    = 0L
        profFramesReceived   = 0L
        profFramesProcessed  = 0L
        profFramesEncoded    = 0L
        profFramesDroppedEnq = 0L
        profFramesSkipped    = 0L
        profArrivalSumNs     = 0L
        profStage2I420Ns     = 0L
        profStage3NV12Ns     = 0L
        profStage4BufOpsNs   = 0L
        profStage5QueueWaitNs= 0L
        profStage6EncodeNs   = 0L
        profStage7MuxNs      = 0L
        profTotalProcessNs   = 0L
        profDropQueueWaitNs  = 0L
    }

    // ── audio capture + encoding ──────────────────────────────────────────────

    private fun startAudioCapture() {
        val tAud0 = System.nanoTime()
        val minBuf = AudioRecord.getMinBufferSize(AUDIO_SAMPLE_RATE, AUDIO_CHANNEL_CONFIG, AUDIO_FORMAT)
        val bufSize = maxOf(minBuf, AUDIO_SAMPLE_RATE / 10 * 2) // ≥ 100 ms

        if (minBuf == AudioRecord.ERROR_BAD_VALUE) {
            Log.e(TAG, "AudioRecord params unsupported — recording video-only")
            audioIssue = "mic params unsupported"; return
        }

        val ar = AudioRecord(MediaRecorder.AudioSource.MIC,
            AUDIO_SAMPLE_RATE, AUDIO_CHANNEL_CONFIG, AUDIO_FORMAT, bufSize)
        if (ar.state != AudioRecord.STATE_INITIALIZED) {
            Log.e(TAG, "AudioRecord init failed — recording video-only"); ar.release()
            audioIssue = "mic init failed"; return
        }
        Log.i(TAG, "DIAG AudioRecord created: ${(System.nanoTime() - tAud0) / 1_000_000L}ms")

        // Audio encoder init can throw on some MIUI/MediaTek devices (resource
        // contention, codec permission issues). audioAvailable must only be set
        // AFTER full encoder init succeeds — if it were set before and init throws,
        // maybeStartMuxer would wait forever for audioFormatReady, muxer would
        // never start, and the output file would be audio-only or empty.
        val tAudEnc = System.nanoTime()
        val aenc = try {
            MediaCodec.createEncoderByType(AUDIO_MIME).also { enc ->
                val fmt = MediaFormat.createAudioFormat(AUDIO_MIME, AUDIO_SAMPLE_RATE, AUDIO_CHANNELS).apply {
                    setInteger(MediaFormat.KEY_AAC_PROFILE, MediaCodecInfo.CodecProfileLevel.AACObjectLC)
                    setInteger(MediaFormat.KEY_BIT_RATE, AUDIO_BIT_RATE)
                    setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, bufSize)
                }
                enc.configure(fmt, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
                enc.start()
                Log.i(TAG, "DIAG audio encoder (${enc.name}) init: ${(System.nanoTime() - tAudEnc) / 1_000_000L}ms")
            }
        } catch (e: Exception) {
            Log.e(TAG, "Audio encoder init failed — recording video-only: ${e.message}")
            ar.release()
            audioIssue = "audio encoder init failed: ${e.message}"
            return
        }

        // The camera's live WebRTC stream already holds the microphone. On some
        // devices (notably Android 9 and older) a second capture can't start:
        // startRecording() returns without recording and read() fails at once.
        // Waiting for an audio format that never comes would keep the muxer
        // from ever starting and leave a 0-byte file, so record video-only.
        ar.startRecording()
        if (ar.recordingState != AudioRecord.RECORDSTATE_RECORDING) {
            Log.e(TAG, "AudioRecord.startRecording() did not start (mic in use?) — recording video-only")
            audioIssue = "mic busy (could not start)"
            ar.release()
            try { aenc.stop() } catch (_: Exception) {}
            aenc.release()
            return
        }
        audioAvailable = true
        audioEncoder = aenc
        audioRecord = ar
        Log.i(TAG, "DIAG AudioRecord started, bufSize=$bufSize total=${(System.nanoTime() - tAud0) / 1_000_000L}ms")

        // Run the capture loop on the dedicated audio handler thread.
        audioHandler.post { audioCaptureLoop(ar, aenc, bufSize) }
    }

    private fun audioCaptureLoop(ar: AudioRecord, aenc: MediaCodec, bufSize: Int) {
        val pcm = ByteArray(bufSize)
        val bytesPerSample = 2 // PCM 16-bit
        var samplesIn = 0L

        while (isRunning.get()) {
            val n = ar.read(pcm, 0, bufSize)
            if (n <= 0) {
                // AudioRecord was stopped (n == ERROR_INVALID_OPERATION) — exit cleanly.
                break
            }
            val inIdx = aenc.dequeueInputBuffer(10_000L)
            if (inIdx < 0) continue
            val inBuf = aenc.getInputBuffer(inIdx) ?: continue
            inBuf.clear(); inBuf.put(pcm, 0, n)
            // PTS from sample count — monotonic, no wall-clock jitter.
            val ptsUs = samplesIn * 1_000_000L / AUDIO_SAMPLE_RATE
            samplesIn += (n / bytesPerSample).toLong()
            aenc.queueInputBuffer(inIdx, 0, n, ptsUs, 0)
            drainAudioEncoder(false)
        }

        // Capture ended while still recording, before any audio was encoded:
        // stop waiting for an audio track so the video still gets written.
        if (isRunning.get() && !audioFormatReady) {
            Log.e(TAG, "mic stopped delivering before any audio was encoded — continuing video-only")
            audioIssue = "mic stopped delivering audio"
            synchronized(muxerLock) {
                audioAvailable = false
                muxer?.let { maybeStartMuxer(it) }
            }
            // Drop the audio encoder: if it emitted its format now, adding the
            // track to the already started muxer would throw.
            audioEncoder = null
            try { aenc.stop() } catch (_: Exception) {}
            aenc.release()
            return
        }

        // Signal EOS to the audio encoder.
        val eosIdx = aenc.dequeueInputBuffer(50_000L)
        if (eosIdx >= 0) aenc.queueInputBuffer(eosIdx, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
        drainAudioEncoder(true)
    }

    private fun drainAudioEncoder(endOfStream: Boolean) {
        val aenc = audioEncoder ?: return
        val mux = muxer ?: return
        var eosRetries = 0
        while (true) {
            when (val status = aenc.dequeueOutputBuffer(audioBufInfo, if (endOfStream) 50_000L else 5_000L)) {
                MediaCodec.INFO_TRY_AGAIN_LATER -> if (!endOfStream || ++eosRetries > 40) break
                MediaCodec.INFO_OUTPUT_BUFFERS_CHANGED -> Unit
                MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                    synchronized(muxerLock) {
                        if (muxerStarted) {
                            // Muxer already running video-only; tracks can't be added now.
                            Log.w(TAG, "audio format arrived after muxer start — audio dropped")
                            return@synchronized
                        }
                        audioTrackIdx = mux.addTrack(aenc.outputFormat)
                        audioFormatReady = true
                        Log.d(TAG, "audio format ready, track=$audioTrackIdx")
                        maybeStartMuxer(mux)
                    }
                }
                else -> if (status >= 0) {
                    val isConfig = audioBufInfo.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG != 0
                    if (muxerStarted && audioTrackIdx >= 0 && audioBufInfo.size > 0 && !isConfig) {
                        aenc.getOutputBuffer(status)?.let { buf ->
                            buf.position(audioBufInfo.offset); buf.limit(audioBufInfo.offset + audioBufInfo.size)
                            if (firstAudioPtsUs == Long.MIN_VALUE) {
                                firstAudioPtsUs = audioBufInfo.presentationTimeUs
                                Log.d(TAG, "first audio frame muxed — ptsUs=${audioBufInfo.presentationTimeUs} size=${audioBufInfo.size} track=$audioTrackIdx")
                            }
                            audioBufInfo.presentationTimeUs -= firstAudioPtsUs
                            synchronized(muxerLock) { mux.writeSampleData(audioTrackIdx, buf, audioBufInfo) }
                        }
                    }
                    aenc.releaseOutputBuffer(status, false)
                    if (audioBufInfo.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) break
                }
            }
        }
    }

    // Called under muxerLock. Starts the muxer once all expected tracks are registered.
    // If audio initialisation failed (audioAvailable=false) we start on video alone.
    private fun maybeStartMuxer(mux: MediaMuxer) {
        val ready = videoFormatReady && (audioFormatReady || !audioAvailable)
        if (!muxerStarted && ready) {
            mux.start()
            muxerStarted = true
            muxerEverStarted = true
            Log.d(TAG, "muxer started (video=$videoTrackIdx, audio=$audioTrackIdx)")
        }
    }

    // ── stop ──────────────────────────────────────────────────────────────────

    override val diagnostics: Map<String, Any?>
        get() = mapOf(
            "recorder" to "I420VideoRecorder",
            "softwareEncoderForced" to forceSoftwareEncoder,
            "framesReceived" to frameCount.get(),
            "videoSamplesWritten" to videoSamplesWritten,
            "videoFormatReady" to videoFormatReady,
            "encoderFailed" to encoderFailed,
            "audioAvailable" to audioAvailable,
            "audioFormatReady" to audioFormatReady,
            "audioIssue" to audioIssue,
            "muxerStarted" to muxerEverStarted,
            "sizeBytes" to java.io.File(outputPath).length(),
        )

    /**
     * Stops recording, drains both encoders, finalises the muxer, then calls [onDone].
     * Must be called after [VideoTrack.removeSink] so no more frames arrive.
     */
    fun stop(onDone: () -> Unit) {
        isRunning.set(false)
        // Cancel the periodic reporter before draining so it doesn't fire during teardown.
        videoHandler.removeCallbacks(profReporter)
        // Stop AudioRecord immediately so ar.read() in the audio thread unblocks.
        audioRecord?.stop()

        videoHandler.post {
            // ── video EOS + drain ──────────────────────────────────────────
            try {
                val enc = videoEncoder
                videoEncoder = null  // null early to prevent double-release on any path
                if (enc != null) {
                    if (!encoderFailed) {
                        val eosIdx = enc.dequeueInputBuffer(50_000L)
                        if (eosIdx >= 0) enc.queueInputBuffer(eosIdx, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                        else Log.w(TAG, "video: could not get EOS input buffer")
                        drainVideoEncoder(true)
                    }
                    try { enc.stop() } catch (_: Exception) {}
                    enc.release()
                }
            } catch (e: Exception) { Log.e(TAG, "video stop error: ${e.message}", e) }

            // ── wait for audio thread to finish, then finalise ─────────────
            audioHandler.post {
                try {
                    audioRecord?.release(); audioRecord = null
                    // The capture loop already posted EOS; do a final drain pass.
                    drainAudioEncoder(true)
                    val aenc = audioEncoder
                    if (aenc != null) { aenc.stop(); aenc.release(); audioEncoder = null }
                } catch (e: Exception) { Log.e(TAG, "audio stop error: ${e.message}", e) }

                // ── stop muxer ─────────────────────────────────────────────
                try {
                    val mux = muxer
                    if (mux != null) {
                        if (muxerStarted) {
                            mux.stop()
                        } else {
                            Log.w(TAG, "stop() — muxer never started; MP4 will have no tracks")
                        }
                        mux.release(); muxer = null; muxerStarted = false
                    }
                    val fileSize = java.io.File(outputPath).length()
                    Log.d(TAG, "stop() complete — ${targetWidth}×${targetHeight} " +
                            "frames=${frameCount.get()} v=${videoTrackIdx >= 0} a=${audioTrackIdx >= 0} " +
                            "sizeBytes=$fileSize path=${outputPath.substringAfterLast('/')}")
                } catch (e: Exception) { Log.e(TAG, "muxer stop error: ${e.message}", e) }

                onDone()
            }
        }
    }
}
