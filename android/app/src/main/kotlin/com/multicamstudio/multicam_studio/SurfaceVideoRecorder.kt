package com.multicamstudio.multicam_studio

import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaCodecList
import android.media.MediaFormat
import android.media.MediaMuxer
import android.media.MediaRecorder
import android.opengl.EGL14
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.util.Log
import android.view.Surface
import org.webrtc.EglBase
import org.webrtc.GlRectDrawer
import org.webrtc.VideoFrame
import org.webrtc.VideoFrameDrawer
import org.webrtc.VideoSink
import java.io.IOException
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong

/**
 * Records a WebRTC VideoTrack plus device microphone to an MP4 file using
 * MediaCodec Surface input mode. Frames are rendered directly from the WebRTC
 * TextureBuffer (GPU) onto the encoder's input Surface via EGL, eliminating
 * the glReadPixels() GPU→CPU readback that I420VideoRecorder performs every
 * frame. Preview performance is unaffected because the GPU pipeline never stalls.
 *
 * EGL context: CONFIG_PLAIN (not CONFIG_RECORDABLE). CONFIG_RECORDABLE causes
 * eglSwapBuffers() to fail silently on MIUI / MediaTek devices. The preview
 * renderer uses CONFIG_PLAIN and works on all devices; we follow the same pattern.
 *
 * Rotation: VideoRenderService validates that all input files share the same
 * encoded dimensions (KEY_WIDTH × KEY_HEIGHT) and reads rotation from
 * MediaMetadataRetriever. To preserve identical encoded dimensions across all
 * recorders, we draw the raw unrotated sensor buffer (wrapping the incoming
 * frame with rotation=0) and set setOrientationHint() on the muxer — the same
 * convention I420VideoRecorder uses.
 *
 * Fallback: if EGL context creation fails during start(), an IOException is
 * thrown. The caller (MainActivity) catches this and falls back to
 * I420VideoRecorder. If swapBuffers() returns false during frame processing,
 * the frame is dropped and a warning is logged; after MAX_SWAP_FAILS consecutive
 * failures, further frames are silently ignored for the remainder of the session.
 */
class SurfaceVideoRecorder(
    private val outputPath: String,
    private val targetWidth: Int = 1280,
    private val targetHeight: Int = 720,
    private val targetFps: Int = 30,
    private val targetBitRate: Int = 3_000_000,
    private val sharedEglContext: EglBase.Context?,
) : VideoSink, RecorderDiagnostics {

    companion object {
        private const val TAG = "SurfaceVideoRecorder"

        private const val VIDEO_MIME = "video/avc"
        private const val VIDEO_I_FRAME_INTERVAL = 2

        private const val AUDIO_MIME = "audio/mp4a-latm"
        private const val AUDIO_SAMPLE_RATE = 44_100
        private const val AUDIO_CHANNELS = 1
        private const val AUDIO_BIT_RATE = 128_000
        private const val AUDIO_CHANNEL_CONFIG = AudioFormat.CHANNEL_IN_MONO
        private const val AUDIO_FORMAT = AudioFormat.ENCODING_PCM_16BIT

        // After this many consecutive swapBuffers() failures, stop feeding the encoder.
        private const val MAX_SWAP_FAILS = 3
    }

    // ── shared ────────────────────────────────────────────────────────────────
    private val isRunning = AtomicBoolean(false)
    private val frameCount = AtomicLong(0)

    private var muxer: MediaMuxer? = null
    private var muxerStarted = false
    private val muxerLock = Any()

    @Volatile private var videoFormatReady = false
    @Volatile private var audioFormatReady = false
    @Volatile private var audioAvailable = false
    // Diagnostics (see RecorderDiagnostics).
    @Volatile private var muxerEverStarted = false
    @Volatile private var videoSamplesWritten = 0L
    @Volatile private var audioIssue: String? = null
    @Volatile private var rotationSet = false

    // ── EGL / surface ─────────────────────────────────────────────────────────
    // All EGL fields are only accessed on videoHandler.
    private var eglBase: EglBase? = null
    private var encoderSurface: Surface? = null
    private var frameDrawer: VideoFrameDrawer? = null
    private var glDrawer: GlRectDrawer? = null

    // Surface mode failure flag — set when swapBuffers() consistently returns false.
    @Volatile private var surfaceFailed = false
    private var swapFailCount = 0
    // Encoder failure flag — set when dequeueOutputBuffer() throws IllegalStateException,
    // which happens when the hardware encoder enters an error state (e.g. OMX error on
    // MediaTek after an unsupported resolution slips through capability filtering).
    // Once set, no further frames are submitted to the encoder and stop() skips EOS.
    @Volatile private var encoderFailed = false

    // ── video ─────────────────────────────────────────────────────────────────
    private var videoEncoder: MediaCodec? = null
    private var videoTrackIdx = -1
    private var firstVideoPtsUs = Long.MIN_VALUE
    // Monotonicity guard: last presentation timestamp submitted to the encoder (ns).
    private var lastPtsNs = Long.MIN_VALUE

    private val videoThread = HandlerThread("SurfVid").also { it.start() }
    private val videoHandler = Handler(videoThread.looper)
    private val videoBufInfo = MediaCodec.BufferInfo()

    // ── audio ─────────────────────────────────────────────────────────────────
    private var audioEncoder: MediaCodec? = null
    private var audioRecord: AudioRecord? = null
    private var audioTrackIdx = -1
    private var firstAudioPtsUs = Long.MIN_VALUE

    private val audioThread = HandlerThread("SurfAud").also { it.start() }
    private val audioHandler = Handler(audioThread.looper)
    private val audioBufInfo = MediaCodec.BufferInfo()

    // ─────────────────────────────────────────────────────────────────────────

    /**
     * Initialises MediaCodec in surface input mode, creates the EGL context on
     * the video handler thread, and starts audio capture.
     *
     * @throws IOException if MediaCodec or EGL initialisation fails.
     */
    @Throws(IOException::class)
    fun start(recordAudio: Boolean = true) {
        Log.i(TAG, "start() ${targetWidth}×${targetHeight}@${targetFps}fps " +
                "${targetBitRate}bps recordAudio=$recordAudio → $outputPath")

        frameCount.set(0)
        rotationSet = false
        muxer = MediaMuxer(outputPath, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
        isRunning.set(true)

        try {
            initVideoEncoder()
        } catch (e: Exception) {
            // Clean up muxer before rethrowing so the caller doesn't inherit a
            // half-initialised muxer when it catches the exception and falls back.
            try { muxer?.release() } catch (_: Exception) {}
            muxer = null
            isRunning.set(false)
            throw e
        }

        if (recordAudio) startAudioCapture()

        Log.d(TAG, "start() complete")
    }

    // ── video encoder init ────────────────────────────────────────────────────

    private fun initVideoEncoder() {
        Log.i(TAG, "initVideoEncoder ${targetWidth}×${targetHeight}@${targetFps}fps")

        val fmt = MediaFormat.createVideoFormat(VIDEO_MIME, targetWidth, targetHeight).apply {
            // Surface input: the encoder receives GPU buffers via the input Surface;
            // no CPU-side NV12 copy is needed.
            setInteger(MediaFormat.KEY_COLOR_FORMAT,
                MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface)
            setInteger(MediaFormat.KEY_BIT_RATE, targetBitRate)
            setInteger(MediaFormat.KEY_FRAME_RATE, targetFps)
            setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, VIDEO_I_FRAME_INTERVAL)
            // Do NOT set KEY_PREPEND_HEADER_TO_SYNC_FRAMES — same rationale as
            // I420VideoRecorder: inline SPS/PPS corrupt VideoRenderService merges.
        }

        val enc = MediaCodec.createEncoderByType(VIDEO_MIME)

        // Some hardware encoders fail in Surface input mode due to dataspace/EGL
        // incompatibilities that are not detectable until encode time:
        //   • OMX.MTK.* / c2.mtk.* (MediaTek): fails at configure() with ERROR(0x8000100b) or encode time.
        //   • c2.qti.*  (Qualcomm):  fails at encode time with UNKNOWN_ERROR(0xffffffff)
        //     after a GraphicBufferSource dataspace change on the first real frame.
        // Both failures leave the encoder in an unrecoverable state. Bail immediately so
        // MainActivity's existing catch(Exception) routes to I420VideoRecorder, which uses
        // the same hardware encoder via CPU input (COLOR_FormatYUV420SemiPlanar) — no EGL,
        // no dataspace issues.
        if (enc.name.contains("mtk", ignoreCase = true) ||
            enc.name.startsWith("c2.qti.", ignoreCase = true)) {
            enc.release()
            throw IOException("${enc.name} does not support Surface input mode — falling back to I420")
        }

        enc.configure(fmt, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)

        // createInputSurface() must be called AFTER configure() and BEFORE start().
        val surface = enc.createInputSurface()
        encoderSurface = surface

        enc.start()
        videoEncoder = enc

        val isHw = isHwEncoder(enc.name)
        Log.i(TAG, "encoder: ${enc.name} isHW=$isHw surface=$surface")

        // EGL must be set up on the videoHandler thread so that all subsequent
        // drawFrame() + swapBuffers() calls run on the thread that owns the context.
        val latch = CountDownLatch(1)
        var initError: Exception? = null

        videoHandler.post {
            try {
                // CONFIG_PLAIN: same config the preview renderer uses.
                // CONFIG_RECORDABLE adds EGL_RECORDABLE_ANDROID=1, which causes
                // eglSwapBuffers() to fail silently on MIUI / MediaTek devices.
                val egl = EglBase.create(sharedEglContext, EglBase.CONFIG_PLAIN)
                egl.createSurface(surface)
                egl.makeCurrent()

                eglBase = egl
                frameDrawer = VideoFrameDrawer()
                glDrawer = GlRectDrawer()

                Log.i(TAG, "EGL context ready on ${Thread.currentThread().name}")
            } catch (e: Exception) {
                initError = e
                Log.e(TAG, "EGL init failed: ${e.message}", e)
            } finally {
                latch.countDown()
            }
        }

        val eglInitDone = latch.await(8L, TimeUnit.SECONDS)
        if (!eglInitDone && initError == null) {
            initError = IOException("EGL context init timed out after 8 s on ${Build.MODEL}")
            Log.e(TAG, "EGL init timed out — falling back to I420")
        }

        if (initError != null) {
            // Clean up encoder before propagating — caller will fall back to I420.
            try { enc.stop() } catch (_: Exception) {}
            enc.release()
            videoEncoder = null
            try { surface.release() } catch (_: Exception) {}
            encoderSurface = null
            throw IOException("Surface EGL init failed: ${initError!!.message}", initError)
        }
    }

    private fun isHwEncoder(name: String): Boolean {
        if (Build.VERSION.SDK_INT >= 29) {
            return MediaCodecList(MediaCodecList.ALL_CODECS).codecInfos
                .firstOrNull { it.name == name }?.isHardwareAccelerated ?: false
        }
        return !name.lowercase().startsWith("omx.google.")
    }

    // ── VideoSink ─────────────────────────────────────────────────────────────

    override fun onFrame(frame: VideoFrame) {
        // VideoSink.onFrame() receives a borrowed frame reference owned by the delivery chain
        // (VideoProcessor). Do NOT call frame.release() here — that over-releases the refcount
        // and crashes EglRenderer's EglThread when it tries to release its own retained copy.
        if (!isRunning.get() || surfaceFailed || encoderFailed) { return }

        val fc = frameCount.incrementAndGet()
        if (fc <= 3L) {
            Log.i(TAG, "frame #$fc ${frame.buffer.width}×${frame.buffer.height} " +
                    "rot=${frame.rotation}° rotW=${frame.rotatedWidth} rotH=${frame.rotatedHeight} " +
                    "thread=${Thread.currentThread().name}")
        }

        // OES textures are bound to the WebRTC camera thread's EGL context. Drawing them
        // from SurfVid's separate EGL context triggers OMX.MTK error 0x8000100b and
        // corrupts WebRTC's TextureBuffer refcount → SIGABRT on EncoderQueue.
        // Convert to I420 here on the delivery thread (which owns the OES context) so
        // VideoFrameDrawer receives a plain CPU buffer with no EGL dependency.
        //
        // We retain the buffer explicitly before calling toI420(). toI420() posts its
        // conversion lambda to the camera EGL handler via invokeAtFrontUninterruptibly(),
        // blocking this thread. Between the post and the lambda executing, WebRTC's
        // EncoderQueue can concurrently release the same TextureBufferImpl, dropping
        // refcount to 0. toI420()'s internal retain() would then fail with
        // "retain() called on an object with refcount < 1" → SIGABRT on EncoderQueue.
        // Our explicit retain() here prevents refcount from reaching 0 during that window.
        if (frame.buffer is VideoFrame.TextureBuffer) {
            frame.buffer.retain()           // hold the buffer through toI420()'s async post
            val i420 = frame.buffer.toI420()
            frame.buffer.release()          // balance explicit retain
            // Do NOT call frame.release() here. VideoSink.onFrame() is called with a
            // borrowed frame reference — the delivery chain (VideoProcessor) releases it
            // after all sinks return. Releasing it here under-counts the refcount and
            // causes VideoProcessor.onFrameCaptured:51 to throw "release() < 1".
            if (i420 == null) {
                Log.w(TAG, "TextureBuffer.toI420() null — frame #$fc dropped")
                return
            }
            val i420Frame = VideoFrame(i420, frame.rotation, frame.timestampNs)
            videoHandler.post { processVideoFrame(i420Frame) }
            return
        }

        frame.retain()
        videoHandler.post { processVideoFrame(frame) }
    }

    // ── frame rendering ───────────────────────────────────────────────────────

    private fun processVideoFrame(frame: VideoFrame) {
        try {
            if (surfaceFailed || encoderFailed) return

            val egl  = eglBase    ?: return
            val fd   = frameDrawer ?: return
            val gd   = glDrawer   ?: return

            // Set muxer orientation hint on the first frame so the container
            // carries the rotation, identical to I420VideoRecorder's behaviour.
            // VideoRenderService reads this via MediaMetadataRetriever and
            // propagates it to the merged output.
            if (!rotationSet) {
                muxer?.setOrientationHint(frame.rotation)
                rotationSet = true
            }

            // VideoFrameDrawer normally applies frame.rotation as a transform so
            // the output is in display (rotated) orientation.  We must instead
            // output the raw unrotated sensor pixels at targetWidth×targetHeight
            // so that VideoRenderService's KEY_WIDTH×KEY_HEIGHT validation passes
            // and all devices produce the same encoded dimensions.
            //
            // We wrap the frame with rotation=0 so VideoFrameDrawer treats the
            // buffer as already in the correct orientation and draws it without
            // rotation transforms.
            //
            // Buffer refcount contract:
            //   • VideoFrame constructor does NOT call buffer.retain().
            //   • We call buffer.retain() manually so that rawFrame.release()
            //     (which calls buffer.release()) is balanced by our retain, and
            //     the outer frame.release() in finally is balanced by the
            //     frame.retain() we called in onFrame().
            frame.buffer.retain()
            val rawFrame = VideoFrame(frame.buffer, 0, frame.timestampNs)
            try {
                // Monotonicity guard: surface encoders on some devices reject
                // non-monotonic PTSs; on-frame timestamps can occasionally repeat
                // or arrive slightly out of order under scheduler pressure.
                val rawPtsNs = frame.timestampNs
                val safePtsNs = if (lastPtsNs != Long.MIN_VALUE && rawPtsNs <= lastPtsNs) {
                    lastPtsNs + 33_333L  // advance by one frame at 30 fps in ns
                } else rawPtsNs
                lastPtsNs = safePtsNs

                // GPU texture → encoder input surface (no CPU readback, no glReadPixels).
                fd.drawFrame(rawFrame, gd, null, 0, 0, targetWidth, targetHeight)

                // swapBuffers(long) sets the EGL_ANDROID_presentation_time extension and
                // submits the rendered buffer to the encoder in one call.  This is the
                // EglBase API available in io.github.webrtc-sdk:android:144.7559.01
                // (setPresentationTime is not a method in this version).
                egl.swapBuffers(safePtsNs)

                // swapBuffers() is void — inspect the EGL error code to detect failures.
                val eglErr = EGL14.eglGetError()
                if (eglErr != EGL14.EGL_SUCCESS) {
                    swapFailCount++
                    Log.w(TAG, "swapBuffers EGL error 0x${eglErr.toString(16)} " +
                            "(${swapFailCount}/${MAX_SWAP_FAILS})")
                    if (swapFailCount >= MAX_SWAP_FAILS) {
                        surfaceFailed = true
                        Log.e(TAG, "Surface mode disabled after $MAX_SWAP_FAILS " +
                                "consecutive EGL swap errors — remaining frames will be dropped")
                    }
                    return
                }
                swapFailCount = 0

            } finally {
                rawFrame.release()  // balances our buffer.retain() above
            }

            drainVideoEncoder(false)

        } finally {
            frame.release()  // balances frame.retain() in onFrame()
        }
    }

    private fun drainVideoEncoder(endOfStream: Boolean) {
        if (encoderFailed) return
        val enc = videoEncoder ?: return
        val mux = muxer ?: return
        var eosRetries = 0

        while (true) {
            val status: Int
            try {
                status = enc.dequeueOutputBuffer(videoBufInfo, if (endOfStream) 50_000L else 5_000L)
            } catch (e: IllegalStateException) {
                // MediaCodec entered an error state (e.g. OMX.MTK.VIDEO.ENCODER.AVC
                // ERROR(0x8000100b) for an unsupported resolution). Mark the encoder
                // as failed so no further frames or stop() EOS signal attempt it.
                Log.e(TAG, "drainVideoEncoder: codec in error state — aborting: ${e.message}")
                encoderFailed = true
                isRunning.set(false)
                return
            }

            when (status) {
                MediaCodec.INFO_TRY_AGAIN_LATER ->
                    if (!endOfStream || ++eosRetries > 40) break
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
                            if (firstVideoPtsUs == Long.MIN_VALUE)
                                firstVideoPtsUs = videoBufInfo.presentationTimeUs
                            videoBufInfo.presentationTimeUs -= firstVideoPtsUs
                            synchronized(muxerLock) {
                                mux.writeSampleData(videoTrackIdx, buf, videoBufInfo)
                            }
                            videoSamplesWritten++
                        }
                    }
                    enc.releaseOutputBuffer(status, false)
                    if (videoBufInfo.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) break
                }
            }
        }
    }

    // ── audio capture + encoding (identical to I420VideoRecorder) ─────────────

    private fun startAudioCapture() {
        val minBuf = AudioRecord.getMinBufferSize(
            AUDIO_SAMPLE_RATE, AUDIO_CHANNEL_CONFIG, AUDIO_FORMAT)
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

        val aenc = try {
            MediaCodec.createEncoderByType(AUDIO_MIME).also { enc ->
                val fmt = MediaFormat.createAudioFormat(
                    AUDIO_MIME, AUDIO_SAMPLE_RATE, AUDIO_CHANNELS).apply {
                    setInteger(MediaFormat.KEY_AAC_PROFILE,
                        MediaCodecInfo.CodecProfileLevel.AACObjectLC)
                    setInteger(MediaFormat.KEY_BIT_RATE, AUDIO_BIT_RATE)
                    setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, bufSize)
                }
                enc.configure(fmt, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
                enc.start()
                Log.i(TAG, "audio encoder (${enc.name}) started")
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
        audioHandler.post { audioCaptureLoop(ar, aenc, bufSize) }
    }

    private fun audioCaptureLoop(ar: AudioRecord, aenc: MediaCodec, bufSize: Int) {
        val pcm = ByteArray(bufSize)
        val bytesPerSample = 2
        var samplesIn = 0L

        while (isRunning.get()) {
            val n = ar.read(pcm, 0, bufSize)
            if (n <= 0) break
            val inIdx = aenc.dequeueInputBuffer(10_000L)
            if (inIdx < 0) continue
            val inBuf = aenc.getInputBuffer(inIdx) ?: continue
            inBuf.clear(); inBuf.put(pcm, 0, n)
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

        val eosIdx = aenc.dequeueInputBuffer(50_000L)
        if (eosIdx >= 0) aenc.queueInputBuffer(eosIdx, 0, 0, 0,
            MediaCodec.BUFFER_FLAG_END_OF_STREAM)
        drainAudioEncoder(true)
    }

    private fun drainAudioEncoder(endOfStream: Boolean) {
        val aenc = audioEncoder ?: return
        val mux = muxer ?: return
        var eosRetries = 0
        while (true) {
            when (val status = aenc.dequeueOutputBuffer(
                audioBufInfo, if (endOfStream) 50_000L else 5_000L)) {
                MediaCodec.INFO_TRY_AGAIN_LATER ->
                    if (!endOfStream || ++eosRetries > 40) break
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
                    val isConfig =
                        audioBufInfo.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG != 0
                    if (muxerStarted && audioTrackIdx >= 0 && audioBufInfo.size > 0 && !isConfig) {
                        aenc.getOutputBuffer(status)?.let { buf ->
                            buf.position(audioBufInfo.offset)
                            buf.limit(audioBufInfo.offset + audioBufInfo.size)
                            if (firstAudioPtsUs == Long.MIN_VALUE)
                                firstAudioPtsUs = audioBufInfo.presentationTimeUs
                            audioBufInfo.presentationTimeUs -= firstAudioPtsUs
                            synchronized(muxerLock) {
                                mux.writeSampleData(audioTrackIdx, buf, audioBufInfo)
                            }
                        }
                    }
                    aenc.releaseOutputBuffer(status, false)
                    if (audioBufInfo.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) break
                }
            }
        }
    }

    private fun maybeStartMuxer(mux: MediaMuxer) {
        // Must be called under muxerLock.
        val ready = videoFormatReady && (audioFormatReady || !audioAvailable)
        if (!muxerStarted && ready) {
            mux.start()
            muxerStarted = true
            muxerEverStarted = true
            Log.d(TAG, "muxer started (video=$videoTrackIdx audio=$audioTrackIdx)")
        }
    }

    // ── stop ──────────────────────────────────────────────────────────────────

    override val diagnostics: Map<String, Any?>
        get() = mapOf(
            "recorder" to "SurfaceVideoRecorder",
            "framesReceived" to frameCount.get(),
            "videoSamplesWritten" to videoSamplesWritten,
            "videoFormatReady" to videoFormatReady,
            "encoderFailed" to encoderFailed,
            "surfaceFailed" to surfaceFailed,
            "audioAvailable" to audioAvailable,
            "audioFormatReady" to audioFormatReady,
            "audioIssue" to audioIssue,
            "muxerStarted" to muxerEverStarted,
            "sizeBytes" to java.io.File(outputPath).length(),
        )

    /**
     * Stops recording, drains encoders, finalises the muxer, releases EGL
     * resources, then calls [onDone]. Call after [VideoTrack.removeSink] so
     * no further frames arrive while draining.
     */
    fun stop(onDone: () -> Unit) {
        isRunning.set(false)
        audioRecord?.stop()  // unblocks ar.read() in the audio loop

        videoHandler.post {
            // Signal EOS to the surface encoder.  In surface input mode the
            // correct EOS mechanism is signalEndOfInputStream(), NOT queueing
            // an empty input buffer with BUFFER_FLAG_END_OF_STREAM.
            // If the encoder entered an error state (encoderFailed), skip EOS/drain
            // and go straight to stop()/release() to avoid another IllegalStateException.
            try {
                val enc = videoEncoder
                videoEncoder = null  // null early to prevent double-release on any path
                if (enc != null) {
                    if (!encoderFailed) {
                        eglBase?.makeCurrent()
                        try { enc.signalEndOfInputStream() } catch (e: Exception) {
                            Log.w(TAG, "signalEndOfInputStream: ${e.message}")
                        }
                        drainVideoEncoder(true)
                    }
                    try { enc.stop() } catch (_: Exception) {}
                    enc.release()
                }
            } catch (e: Exception) { Log.e(TAG, "video stop error: ${e.message}", e) }

            // Release EGL resources on the GL thread.
            try {
                frameDrawer?.release(); frameDrawer = null
                glDrawer?.release();    glDrawer = null
                eglBase?.release();     eglBase = null
            } catch (e: Exception) { Log.e(TAG, "EGL release error: ${e.message}", e) }

            try {
                encoderSurface?.release(); encoderSurface = null
            } catch (e: Exception) { Log.e(TAG, "surface release error: ${e.message}", e) }

            // Wait for audio thread to finish, then stop the muxer.
            audioHandler.post {
                try {
                    audioRecord?.release(); audioRecord = null
                    drainAudioEncoder(true)
                    val aenc = audioEncoder
                    if (aenc != null) { aenc.stop(); aenc.release(); audioEncoder = null }
                } catch (e: Exception) { Log.e(TAG, "audio stop error: ${e.message}", e) }

                try {
                    val mux = muxer
                    if (mux != null) {
                        if (muxerStarted) mux.stop()
                        else Log.w(TAG, "stop() — muxer never started; MP4 will have no tracks")
                        mux.release(); muxer = null; muxerStarted = false
                    }
                    val fileSize = java.io.File(outputPath).length()
                    Log.d(TAG, "stop() complete — ${targetWidth}×${targetHeight} " +
                            "frames=${frameCount.get()} " +
                            "v=${videoTrackIdx >= 0} a=${audioTrackIdx >= 0} " +
                            "sizeBytes=$fileSize surfaceFailed=$surfaceFailed " +
                            "path=${outputPath.substringAfterLast('/')}")
                } catch (e: Exception) { Log.e(TAG, "muxer stop error: ${e.message}", e) }

                onDone()
            }
        }
    }

    fun dispose() {
        if (isRunning.get()) stop {}
    }
}
