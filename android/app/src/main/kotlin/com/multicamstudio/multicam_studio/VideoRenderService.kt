package com.multicamstudio.multicam_studio

import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMuxer
import java.nio.ByteBuffer

object VideoRenderService {

    private const val MAX_SAMPLE_SIZE = 2 * 1024 * 1024 // 2 MB per sample

    /**
     * Appends [inputs] one after another into a single MP4 at [output].
     * Tracks are discovered from the first file; all files must share the same codec.
     */
    fun mergeSequential(inputs: List<String>, output: String) {
        require(inputs.isNotEmpty()) { "No input files" }

        // Probe first file to determine track formats.
        val probe = MediaExtractor()
        val videoFormat: MediaFormat
        val audioFormat: MediaFormat?
        try {
            probe.setDataSource(inputs[0])
            videoFormat = findFormat(probe, "video/")
                ?: throw IllegalStateException("No video track in ${inputs[0]}")
            audioFormat = findFormat(probe, "audio/")
        } finally {
            probe.release()
        }

        val muxer = MediaMuxer(output, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
        val muxVideoTrack = muxer.addTrack(videoFormat)
        val muxAudioTrack = if (audioFormat != null) muxer.addTrack(audioFormat) else -1
        muxer.start()

        val buffer = ByteBuffer.allocate(MAX_SAMPLE_SIZE)
        val info = MediaCodec.BufferInfo()
        var videoOffsetUs = 0L
        var audioOffsetUs = 0L

        // Outer try/finally guarantees muxer.stop() + release() even if a clip fails.
        try {
            for (inputPath in inputs) {
                val ext = MediaExtractor()
                try {
                    ext.setDataSource(inputPath)

                    val inVideoTrack = findTrackIndex(ext, "video/")
                    val inAudioTrack = findTrackIndex(ext, "audio/")

                    if (inVideoTrack >= 0) ext.selectTrack(inVideoTrack)
                    if (inAudioTrack >= 0 && muxAudioTrack >= 0) ext.selectTrack(inAudioTrack)

                    var maxVideoUs = 0L
                    var maxAudioUs = 0L

                    while (true) {
                        buffer.clear()
                        val sampleSize = ext.readSampleData(buffer, 0)
                        if (sampleSize < 0) break

                        val trackIndex = ext.sampleTrackIndex
                        val rawTime = ext.sampleTime

                        val muxTrack: Int
                        val adjustedTime: Long
                        when {
                            trackIndex == inVideoTrack -> {
                                muxTrack = muxVideoTrack
                                adjustedTime = rawTime + videoOffsetUs
                                if (rawTime > maxVideoUs) maxVideoUs = rawTime
                            }
                            trackIndex == inAudioTrack && muxAudioTrack >= 0 -> {
                                muxTrack = muxAudioTrack
                                adjustedTime = rawTime + audioOffsetUs
                                if (rawTime > maxAudioUs) maxAudioUs = rawTime
                            }
                            else -> {
                                ext.advance()
                                continue
                            }
                        }

                        info.offset = 0
                        info.size = sampleSize
                        info.presentationTimeUs = adjustedTime
                        info.flags = ext.sampleFlags
                        muxer.writeSampleData(muxTrack, buffer, info)
                        ext.advance()
                    }

                    // Pad by one frame so clips don't overlap on the timeline.
                    videoOffsetUs += maxVideoUs + 33_333L   // +1 frame @ 30 fps
                    audioOffsetUs += maxAudioUs + 22_676L   // +1 frame @ 44.1 kHz
                } finally {
                    ext.release()
                }
            }
        } finally {
            // Always write the moov atom — without stop() the MP4 is unplayable.
            muxer.stop()
            muxer.release()
        }
    }

    private fun findFormat(ext: MediaExtractor, mimePrefix: String): MediaFormat? {
        for (i in 0 until ext.trackCount) {
            val fmt = ext.getTrackFormat(i)
            if (fmt.getString(MediaFormat.KEY_MIME)?.startsWith(mimePrefix) == true) return fmt
        }
        return null
    }

    private fun findTrackIndex(ext: MediaExtractor, mimePrefix: String): Int {
        for (i in 0 until ext.trackCount) {
            val fmt = ext.getTrackFormat(i)
            if (fmt.getString(MediaFormat.KEY_MIME)?.startsWith(mimePrefix) == true) return i
        }
        return -1
    }
}
