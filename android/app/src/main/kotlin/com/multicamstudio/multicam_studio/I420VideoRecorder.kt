package com.multicamstudio.multicam_studio

import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.media.MediaMuxer
import android.os.Handler
import android.os.HandlerThread
import android.util.Log
import org.webrtc.VideoFrame
import org.webrtc.VideoSink
import java.io.IOException
import java.nio.ByteBuffer
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Records a WebRTC VideoTrack to an MP4 file by converting each VideoFrame to I420 and
 * feeding it directly to a MediaCodec H.264 encoder in buffer mode.
 *
 * This bypasses EGL/OpenGL entirely, which avoids the silent EGL surface failures that
 * flutter_webrtc's VideoFileRenderer encounters on certain MIUI/MediaTek devices.
 */
class I420VideoRecorder(private val outputPath: String) : VideoSink {

    companion object {
        private const val TAG = "I420VideoRecorder"
        private const val MIME = "video/avc"
        private const val BIT_RATE = 2_000_000
        private const val FRAME_RATE = 30
        private const val I_FRAME_INTERVAL = 1
    }

    private val isRunning = AtomicBoolean(false)
    private var encoder: MediaCodec? = null
    private var muxer: MediaMuxer? = null
    private var videoTrackIdx = -1
    private var muxerStarted = false
    private var firstPtsUs = Long.MIN_VALUE
    private var encoderWidth = 0
    private var encoderHeight = 0
    private var orientationHint = 0

    private val encThread = HandlerThread("I420Enc").also { it.start() }
    private val encHandler = Handler(encThread.looper)
    private val bufInfo = MediaCodec.BufferInfo()

    // Per-frame reusable buffers (allocated lazily at first frame).
    private var yRow: ByteArray? = null
    private var uvRow: ByteArray? = null
    private var uRow: ByteArray? = null
    private var vRow: ByteArray? = null

    @Throws(IOException::class)
    fun start() {
        muxer = MediaMuxer(outputPath, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
        isRunning.set(true)
        Log.d(TAG, "start() → $outputPath")
    }

    override fun onFrame(frame: VideoFrame) {
        if (!isRunning.get()) { frame.release(); return }
        frame.retain()
        encHandler.post { processFrame(frame) }
    }

    private fun initEncoder(w: Int, h: Int, rotation: Int) {
        Log.d(TAG, "initEncoder ${w}×${h} rotation=$rotation")
        orientationHint = rotation
        encoderWidth = w
        encoderHeight = h

        val fmt = MediaFormat.createVideoFormat(MIME, w, h).apply {
            setInteger(MediaFormat.KEY_COLOR_FORMAT,
                MediaCodecInfo.CodecCapabilities.COLOR_FormatYUV420SemiPlanar)
            setInteger(MediaFormat.KEY_BIT_RATE, BIT_RATE)
            setInteger(MediaFormat.KEY_FRAME_RATE, FRAME_RATE)
            setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, I_FRAME_INTERVAL)
        }

        encoder = MediaCodec.createEncoderByType(MIME).also { enc ->
            enc.configure(fmt, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
            enc.start()
        }
        Log.d(TAG, "encoder started (${encoder!!.name})")

        // Allocate row buffers for NV12 conversion.
        yRow  = ByteArray(w)
        uRow  = ByteArray((w + 1) / 2)
        vRow  = ByteArray((w + 1) / 2)
        uvRow = ByteArray((w + 1) / 2 * 2)
    }

    private fun processFrame(frame: VideoFrame) {
        try {
            if (encoder == null) {
                // Initialise encoder on first frame using unrotated buffer dimensions.
                val buf = frame.buffer
                initEncoder(buf.width, buf.height, frame.rotation)
                muxer?.setOrientationHint(frame.rotation)
            }

            val enc = encoder ?: return

            val i420 = frame.buffer.toI420()
            if (i420 == null) {
                Log.w(TAG, "toI420() returned null — skipping frame")
                return
            }

            try {
                val idx = enc.dequeueInputBuffer(10_000L)
                if (idx < 0) { Log.w(TAG, "no input buffer (idx=$idx)"); return }

                val buf = enc.getInputBuffer(idx) ?: run {
                    enc.queueInputBuffer(idx, 0, 0, 0, 0); return
                }
                buf.clear()
                writeNV12(i420, buf)

                val ptsUs = frame.timestampNs / 1_000L
                enc.queueInputBuffer(idx, 0, buf.position(), ptsUs, 0)
            } finally {
                i420.release()
            }

            drainEncoder(false)
        } finally {
            frame.release()
        }
    }

    /** Converts an I420 buffer to NV12 (Y planar + UV interleaved) in [dst]. */
    private fun writeNV12(i420: VideoFrame.I420Buffer, dst: ByteBuffer) {
        val w = i420.width
        val h = i420.height
        val chromaH = (h + 1) / 2
        val chromaW = (w + 1) / 2

        // Y plane — copy row-by-row to strip stride padding.
        val yBuf = i420.dataY
        val yStride = i420.strideY
        val yRowArr = yRow!!
        for (row in 0 until h) {
            yBuf.position(row * yStride)
            yBuf.get(yRowArr, 0, w)
            dst.put(yRowArr, 0, w)
        }

        // UV interleaved (NV12 = U then V).
        val uBuf = i420.dataU
        val vBuf = i420.dataV
        val uStride = i420.strideU
        val vStride = i420.strideV
        val uRowArr = uRow!!
        val vRowArr = vRow!!
        val uvRowArr = uvRow!!
        val uvLen = chromaW * 2

        for (row in 0 until chromaH) {
            uBuf.position(row * uStride)
            uBuf.get(uRowArr, 0, chromaW)
            vBuf.position(row * vStride)
            vBuf.get(vRowArr, 0, chromaW)
            var uvIdx = 0
            for (col in 0 until chromaW) {
                uvRowArr[uvIdx++] = uRowArr[col]
                uvRowArr[uvIdx++] = vRowArr[col]
            }
            dst.put(uvRowArr, 0, uvLen)
        }
    }

    private fun drainEncoder(endOfStream: Boolean) {
        val enc = encoder ?: return
        val mux = muxer ?: return

        while (true) {
            val timeout = if (endOfStream) 50_000L else 5_000L
            when (val status = enc.dequeueOutputBuffer(bufInfo, timeout)) {
                MediaCodec.INFO_TRY_AGAIN_LATER -> break
                MediaCodec.INFO_OUTPUT_BUFFERS_CHANGED -> { /* no-op */ }
                MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                    val newFmt = enc.outputFormat
                    Log.d(TAG, "OUTPUT_FORMAT_CHANGED: $newFmt")
                    videoTrackIdx = mux.addTrack(newFmt)
                    mux.start()
                    muxerStarted = true
                    Log.d(TAG, "muxer started, trackIdx=$videoTrackIdx")
                }
                else -> if (status >= 0) {
                    if (muxerStarted && bufInfo.size > 0) {
                        val outBuf: ByteBuffer? = enc.getOutputBuffer(status)
                        if (outBuf != null) {
                            outBuf.position(bufInfo.offset)
                            outBuf.limit(bufInfo.offset + bufInfo.size)
                            if (firstPtsUs == Long.MIN_VALUE) firstPtsUs = bufInfo.presentationTimeUs
                            bufInfo.presentationTimeUs -= firstPtsUs
                            mux.writeSampleData(videoTrackIdx, outBuf, bufInfo)
                        }
                    }
                    enc.releaseOutputBuffer(status, false)
                    if (bufInfo.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) {
                        Log.d(TAG, "EOS received from encoder")
                        break
                    }
                }
            }
        }
    }

    /**
     * Signals EOS, drains remaining output, stops encoder and muxer, then calls [onDone].
     * Must be called after [VideoTrack.removeSink] to ensure no more frames arrive.
     */
    fun stop(onDone: () -> Unit) {
        isRunning.set(false)
        encHandler.post {
            try {
                val enc = encoder
                if (enc != null) {
                    // Signal end-of-stream via an empty input buffer.
                    val eosIdx = enc.dequeueInputBuffer(50_000L)
                    if (eosIdx >= 0) {
                        enc.queueInputBuffer(eosIdx, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                    } else {
                        Log.w(TAG, "could not dequeue input buffer for EOS")
                    }
                    drainEncoder(true)
                    enc.stop()
                    enc.release()
                    encoder = null
                }
                val mux = muxer
                if (mux != null) {
                    if (muxerStarted) mux.stop()
                    mux.release()
                    muxer = null
                    muxerStarted = false
                }
                Log.d(TAG, "stop() complete — muxed=${videoTrackIdx >= 0}")
            } catch (e: Exception) {
                Log.e(TAG, "error in stop(): ${e.message}", e)
            } finally {
                onDone()
            }
        }
    }
}
