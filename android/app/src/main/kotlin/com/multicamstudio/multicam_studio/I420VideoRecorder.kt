package com.multicamstudio.multicam_studio

import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.media.MediaMuxer
import android.media.MediaRecorder
import android.os.Handler
import android.os.HandlerThread
import android.util.Log
import org.webrtc.VideoFrame
import org.webrtc.VideoSink
import java.io.IOException
import java.nio.ByteBuffer
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Records a WebRTC VideoTrack plus device microphone to a single MP4 file.
 *
 * Video: I420 → NV12 → H.264 via MediaCodec, attached as a VideoSink.
 *        Bypasses EGL entirely so it works on MIUI/MediaTek devices.
 * Audio: PCM from AudioRecord (device mic) → AAC via MediaCodec, muxed alongside video.
 */
class I420VideoRecorder(private val outputPath: String) : VideoSink {

    companion object {
        private const val TAG = "I420VideoRecorder"

        // Video
        private const val VIDEO_MIME = "video/avc"
        private const val VIDEO_BIT_RATE = 2_000_000
        private const val VIDEO_FRAME_RATE = 30
        private const val VIDEO_I_FRAME_INTERVAL = 1

        // Audio
        private const val AUDIO_MIME = "audio/mp4a-latm"
        private const val AUDIO_SAMPLE_RATE = 44_100
        private const val AUDIO_CHANNELS = 1
        private const val AUDIO_BIT_RATE = 128_000
        private const val AUDIO_CHANNEL_CONFIG = AudioFormat.CHANNEL_IN_MONO
        private const val AUDIO_FORMAT = AudioFormat.ENCODING_PCM_16BIT
    }

    // ── shared ────────────────────────────────────────────────────────────────
    private val isRunning = AtomicBoolean(false)
    private var muxer: MediaMuxer? = null
    private var muxerStarted = false
    private val muxerLock = Any()
    // Both tracks must be added before muxer.start(). audioAvailable=false means
    // AudioRecord init failed; in that case muxer starts on video format alone.
    @Volatile private var videoFormatReady = false
    @Volatile private var audioFormatReady = false
    @Volatile private var audioAvailable = false

    // ── video ─────────────────────────────────────────────────────────────────
    private var videoEncoder: MediaCodec? = null
    private var videoTrackIdx = -1
    private var firstVideoPtsUs = Long.MIN_VALUE
    private var encoderWidth = 0
    private var encoderHeight = 0

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

    // ─────────────────────────────────────────────────────────────────────────

    @Throws(IOException::class)
    fun start() {
        muxer = MediaMuxer(outputPath, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
        isRunning.set(true)
        startAudioCapture()
        Log.d(TAG, "start() → $outputPath")
    }

    // ── VideoSink ─────────────────────────────────────────────────────────────

    override fun onFrame(frame: VideoFrame) {
        if (!isRunning.get()) { frame.release(); return }
        frame.retain()
        videoHandler.post { processVideoFrame(frame) }
    }

    // ── video encoding ────────────────────────────────────────────────────────

    private fun initVideoEncoder(w: Int, h: Int) {
        Log.d(TAG, "initVideoEncoder ${w}×${h}")
        encoderWidth = w; encoderHeight = h
        val fmt = MediaFormat.createVideoFormat(VIDEO_MIME, w, h).apply {
            setInteger(MediaFormat.KEY_COLOR_FORMAT,
                MediaCodecInfo.CodecCapabilities.COLOR_FormatYUV420SemiPlanar)
            setInteger(MediaFormat.KEY_BIT_RATE, VIDEO_BIT_RATE)
            setInteger(MediaFormat.KEY_FRAME_RATE, VIDEO_FRAME_RATE)
            setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, VIDEO_I_FRAME_INTERVAL)
        }
        videoEncoder = MediaCodec.createEncoderByType(VIDEO_MIME).also {
            it.configure(fmt, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
            it.start()
        }
        Log.d(TAG, "videoEncoder started (${videoEncoder!!.name})")
    }

    private fun processVideoFrame(frame: VideoFrame) {
        try {
            val i420 = frame.buffer.toI420() ?: run {
                Log.w(TAG, "toI420() null — skipping"); return
            }
            try {
                val fw = i420.width; val fh = i420.height
                when {
                    videoEncoder == null -> {
                        initVideoEncoder(fw, fh)
                        muxer?.setOrientationHint(frame.rotation)
                    }
                    fw != encoderWidth || fh != encoderHeight -> {
                        if (!muxerStarted) {
                            videoEncoder?.stop(); videoEncoder?.release(); videoEncoder = null
                            initVideoEncoder(fw, fh)
                            muxer?.setOrientationHint(frame.rotation)
                        } else {
                            Log.w(TAG, "resolution mismatch mid-stream, skipping"); return
                        }
                    }
                }
                val enc = videoEncoder ?: return
                val idx = enc.dequeueInputBuffer(10_000L)
                if (idx < 0) return
                val buf = enc.getInputBuffer(idx) ?: run { enc.queueInputBuffer(idx, 0, 0, 0, 0); return }
                buf.clear(); writeNV12(i420, buf)
                enc.queueInputBuffer(idx, 0, buf.position(), frame.timestampNs / 1_000L, 0)
            } finally { i420.release() }
            drainVideoEncoder(false)
        } finally { frame.release() }
    }

    private fun writeNV12(i420: VideoFrame.I420Buffer, dst: ByteBuffer) {
        val w = i420.width; val h = i420.height
        val cW = (w + 1) / 2; val cH = (h + 1) / 2
        val yRow = ByteArray(w); val uRow = ByteArray(cW); val vRow = ByteArray(cW); val uvRow = ByteArray(cW * 2)
        val yBuf = i420.dataY
        for (row in 0 until h) { yBuf.position(row * i420.strideY); yBuf.get(yRow, 0, w); dst.put(yRow, 0, w) }
        val uBuf = i420.dataU; val vBuf = i420.dataV
        for (row in 0 until cH) {
            uBuf.position(row * i420.strideU); uBuf.get(uRow, 0, cW)
            vBuf.position(row * i420.strideV); vBuf.get(vRow, 0, cW)
            var j = 0; for (col in 0 until cW) { uvRow[j++] = uRow[col]; uvRow[j++] = vRow[col] }
            dst.put(uvRow, 0, cW * 2)
        }
    }

    private fun drainVideoEncoder(endOfStream: Boolean) {
        val enc = videoEncoder ?: return
        val mux = muxer ?: return
        while (true) {
            when (val status = enc.dequeueOutputBuffer(videoBufInfo, if (endOfStream) 50_000L else 5_000L)) {
                MediaCodec.INFO_TRY_AGAIN_LATER -> break
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
                            buf.position(videoBufInfo.offset); buf.limit(videoBufInfo.offset + videoBufInfo.size)
                            if (firstVideoPtsUs == Long.MIN_VALUE) firstVideoPtsUs = videoBufInfo.presentationTimeUs
                            videoBufInfo.presentationTimeUs -= firstVideoPtsUs
                            synchronized(muxerLock) { mux.writeSampleData(videoTrackIdx, buf, videoBufInfo) }
                        }
                    }
                    enc.releaseOutputBuffer(status, false)
                    if (videoBufInfo.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) break
                }
            }
        }
    }

    // ── audio capture + encoding ──────────────────────────────────────────────

    private fun startAudioCapture() {
        val minBuf = AudioRecord.getMinBufferSize(AUDIO_SAMPLE_RATE, AUDIO_CHANNEL_CONFIG, AUDIO_FORMAT)
        val bufSize = maxOf(minBuf, AUDIO_SAMPLE_RATE / 10 * 2) // ≥ 100 ms

        if (minBuf == AudioRecord.ERROR_BAD_VALUE) {
            Log.e(TAG, "AudioRecord params unsupported — recording video-only"); return
        }

        val ar = AudioRecord(MediaRecorder.AudioSource.MIC,
            AUDIO_SAMPLE_RATE, AUDIO_CHANNEL_CONFIG, AUDIO_FORMAT, bufSize)
        if (ar.state != AudioRecord.STATE_INITIALIZED) {
            Log.e(TAG, "AudioRecord init failed — recording video-only"); ar.release(); return
        }
        audioAvailable = true

        val aenc = MediaCodec.createEncoderByType(AUDIO_MIME).also { enc ->
            val fmt = MediaFormat.createAudioFormat(AUDIO_MIME, AUDIO_SAMPLE_RATE, AUDIO_CHANNELS).apply {
                setInteger(MediaFormat.KEY_AAC_PROFILE, MediaCodecInfo.CodecProfileLevel.AACObjectLC)
                setInteger(MediaFormat.KEY_BIT_RATE, AUDIO_BIT_RATE)
                setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, bufSize)
            }
            enc.configure(fmt, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
            enc.start()
        }

        audioEncoder = aenc
        audioRecord = ar
        ar.startRecording()
        Log.d(TAG, "AudioRecord started, bufSize=$bufSize")

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

        // Signal EOS to the audio encoder.
        val eosIdx = aenc.dequeueInputBuffer(50_000L)
        if (eosIdx >= 0) aenc.queueInputBuffer(eosIdx, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
        drainAudioEncoder(true)
    }

    private fun drainAudioEncoder(endOfStream: Boolean) {
        val aenc = audioEncoder ?: return
        val mux = muxer ?: return
        while (true) {
            when (val status = aenc.dequeueOutputBuffer(audioBufInfo, if (endOfStream) 50_000L else 5_000L)) {
                MediaCodec.INFO_TRY_AGAIN_LATER -> break
                MediaCodec.INFO_OUTPUT_BUFFERS_CHANGED -> Unit
                MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                    synchronized(muxerLock) {
                        audioTrackIdx = mux.addTrack(aenc.outputFormat)
                        audioFormatReady = true
                        Log.d(TAG, "audio format ready, track=$audioTrackIdx")
                        maybeStartMuxer(mux)
                    }
                }
                else -> if (status >= 0) {
                    val isConfig = audioBufInfo.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG != 0
                    if (muxerStarted && audioBufInfo.size > 0 && !isConfig) {
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
            Log.d(TAG, "muxer started (video=$videoTrackIdx, audio=$audioTrackIdx)")
        }
    }

    // ── stop ──────────────────────────────────────────────────────────────────

    /**
     * Stops recording, drains both encoders, finalises the muxer, then calls [onDone].
     * Must be called after [VideoTrack.removeSink] so no more frames arrive.
     */
    fun stop(onDone: () -> Unit) {
        isRunning.set(false)
        // Stop AudioRecord immediately so ar.read() in the audio thread unblocks.
        audioRecord?.stop()

        videoHandler.post {
            // ── video EOS + drain ──────────────────────────────────────────
            try {
                val enc = videoEncoder
                if (enc != null) {
                    val eosIdx = enc.dequeueInputBuffer(50_000L)
                    if (eosIdx >= 0) enc.queueInputBuffer(eosIdx, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                    else Log.w(TAG, "video: could not get EOS input buffer")
                    drainVideoEncoder(true)
                    enc.stop(); enc.release(); videoEncoder = null
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
                        if (muxerStarted) mux.stop()
                        mux.release(); muxer = null; muxerStarted = false
                    }
                    val fileSize = java.io.File(outputPath).length()
                    Log.d(TAG, "stop() complete — v=${videoTrackIdx >= 0} a=${audioTrackIdx >= 0} audioTrack=$audioTrackIdx sizeBytes=$fileSize path=$outputPath")
                } catch (e: Exception) { Log.e(TAG, "muxer stop error: ${e.message}", e) }

                onDone()
            }
        }
    }
}
