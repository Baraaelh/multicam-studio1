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
import java.io.IOException

/**
 * Records the admin device's microphone to an audio-only MP4 (AAC inside MediaMuxer).
 *
 * Used in Studio Audio Mode: camera devices record video-only; this recorder
 * captures the sole audio track that replaces per-camera audio in the final render.
 * Android routes Bluetooth mic input through AudioSource.MIC automatically, so
 * connecting a BT mic before recording is sufficient — no extra configuration needed.
 */
class AdminAudioRecorder(private val outputPath: String) {

    companion object {
        private const val TAG = "AdminAudioRecorder"
        private const val AUDIO_MIME = "audio/mp4a-latm"
        private const val AUDIO_SAMPLE_RATE = 44_100
        private const val AUDIO_CHANNELS = 1
        private const val AUDIO_BIT_RATE = 128_000
        private const val AUDIO_CHANNEL_CONFIG = AudioFormat.CHANNEL_IN_MONO
        private const val AUDIO_FORMAT = AudioFormat.ENCODING_PCM_16BIT
    }

    private var muxer: MediaMuxer? = null
    private var audioEncoder: MediaCodec? = null
    private var audioRecord: AudioRecord? = null
    private var audioTrackIdx = -1
    private var muxerStarted = false
    private var firstAudioPtsUs = Long.MIN_VALUE
    @Volatile private var isRunning = false

    private val audioThread = HandlerThread("AdminAud").also { it.start() }
    private val audioHandler = Handler(audioThread.looper)
    private val audioBufInfo = MediaCodec.BufferInfo()

    @Throws(IOException::class)
    fun start() {
        muxer = MediaMuxer(outputPath, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)

        val minBuf = AudioRecord.getMinBufferSize(AUDIO_SAMPLE_RATE, AUDIO_CHANNEL_CONFIG, AUDIO_FORMAT)
        if (minBuf <= 0) {
            Log.e(TAG, "AudioRecord params unsupported")
            muxer?.release(); muxer = null
            return
        }
        val bufSize = maxOf(minBuf, AUDIO_SAMPLE_RATE / 10 * 2) // ≥ 100 ms

        val ar = AudioRecord(
            MediaRecorder.AudioSource.MIC,
            AUDIO_SAMPLE_RATE, AUDIO_CHANNEL_CONFIG, AUDIO_FORMAT, bufSize,
        )
        if (ar.state != AudioRecord.STATE_INITIALIZED) {
            ar.release(); muxer?.release(); muxer = null
            throw IOException("AudioRecord init failed — microphone may be in use by WebRTC")
        }

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
        isRunning = true
        ar.startRecording()
        Log.d(TAG, "started → $outputPath")
        audioHandler.post { captureLoop(ar, aenc, bufSize) }
    }

    private fun captureLoop(ar: AudioRecord, aenc: MediaCodec, bufSize: Int) {
        val pcm = ByteArray(bufSize)
        var samplesIn = 0L

        while (isRunning) {
            val n = ar.read(pcm, 0, bufSize)
            if (n <= 0) break
            val inIdx = aenc.dequeueInputBuffer(10_000L)
            if (inIdx < 0) continue
            val inBuf = aenc.getInputBuffer(inIdx) ?: continue
            inBuf.clear(); inBuf.put(pcm, 0, n)
            val ptsUs = samplesIn * 1_000_000L / AUDIO_SAMPLE_RATE
            samplesIn += (n / 2).toLong()
            aenc.queueInputBuffer(inIdx, 0, n, ptsUs, 0)
            drain(false)
        }

        val eosIdx = aenc.dequeueInputBuffer(50_000L)
        if (eosIdx >= 0) aenc.queueInputBuffer(eosIdx, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
        drain(true)
    }

    private fun drain(endOfStream: Boolean) {
        val aenc = audioEncoder ?: return
        val mux = muxer ?: return
        var eosRetries = 0
        while (true) {
            when (val status = aenc.dequeueOutputBuffer(audioBufInfo, if (endOfStream) 50_000L else 5_000L)) {
                MediaCodec.INFO_TRY_AGAIN_LATER -> if (!endOfStream || ++eosRetries > 40) break
                MediaCodec.INFO_OUTPUT_BUFFERS_CHANGED -> Unit
                MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                    audioTrackIdx = mux.addTrack(aenc.outputFormat)
                    mux.start()
                    muxerStarted = true
                    Log.d(TAG, "muxer started, track=$audioTrackIdx")
                }
                else -> if (status >= 0) {
                    val isConfig = audioBufInfo.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG != 0
                    if (muxerStarted && audioBufInfo.size > 0 && !isConfig) {
                        aenc.getOutputBuffer(status)?.let { buf ->
                            buf.position(audioBufInfo.offset)
                            buf.limit(audioBufInfo.offset + audioBufInfo.size)
                            if (firstAudioPtsUs == Long.MIN_VALUE) firstAudioPtsUs = audioBufInfo.presentationTimeUs
                            audioBufInfo.presentationTimeUs -= firstAudioPtsUs
                            mux.writeSampleData(audioTrackIdx, buf, audioBufInfo)
                        }
                    }
                    aenc.releaseOutputBuffer(status, false)
                    if (audioBufInfo.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) break
                }
            }
        }
    }

    /**
     * Stops recording, drains the encoder, finalises the muxer, then calls [onDone].
     * [onDone] is called on the audio handler thread (background); if you need UI
     * work, dispatch to the main thread inside [onDone].
     */
    fun stop(onDone: () -> Unit) {
        isRunning = false
        audioRecord?.stop()

        audioHandler.post {
            try {
                audioRecord?.release(); audioRecord = null
                drain(true)
                val aenc = audioEncoder
                if (aenc != null) { aenc.stop(); aenc.release(); audioEncoder = null }
            } catch (e: Exception) {
                Log.e(TAG, "encoder stop error: ${e.message}", e)
            }

            try {
                val mux = muxer
                if (mux != null) {
                    if (muxerStarted) mux.stop()
                    else Log.w(TAG, "stop() — muxer never started; output will be empty")
                    mux.release(); muxer = null
                }
                val size = java.io.File(outputPath).length()
                Log.d(TAG, "stop() complete — size=${size}B path=$outputPath")
            } catch (e: Exception) {
                Log.e(TAG, "muxer stop error: ${e.message}", e)
            }

            onDone()
        }
    }
}
