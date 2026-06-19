package com.multicamstudio.multicam_studio

import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMuxer
import android.util.Log
import java.nio.ByteBuffer

object VideoRenderService {

    private const val TAG = "VideoRenderService"
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

    /**
     * Produces a single MP4 from a list of timeline segments.
     *
     * Each segment is a map with three keys:
     *   inputPath  – absolute path to the source MP4
     *   startMs    – start offset within that file (milliseconds)
     *   durationMs – how long to extract (milliseconds)
     *
     * Cuts are snapped to the nearest preceding keyframe (H.264 I-frame
     * interval = 1 s), so each segment may begin up to one second before the
     * intended cut point. This is the inherent accuracy limit of muxer-level
     * editing without re-encoding.
     */
    fun mergeWithTimeline(segments: List<Map<String, Any>>, output: String) {
        require(segments.isNotEmpty()) { "No segments" }
        Log.d(TAG, "mergeWithTimeline: ${segments.size} segment(s) → $output")

        // Probe the first segment's file to obtain track formats.
        val firstPath = segments[0]["inputPath"] as String
        val probe = MediaExtractor()
        val videoFormat: MediaFormat
        val audioFormat: MediaFormat?
        try {
            probe.setDataSource(firstPath)
            videoFormat = findFormat(probe, "video/")
                ?: throw IllegalStateException("No video track in $firstPath")
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
        var videoOutputOffsetUs = 0L
        var audioOutputOffsetUs = 0L

        try {
            for ((segIdx, seg) in segments.withIndex()) {
                val inputPath = seg["inputPath"] as String
                val startMs = (seg["startMs"] as Number).toLong()
                val durationMs = (seg["durationMs"] as Number).toLong()
                val startUs = startMs * 1_000L
                val endUs = startUs + durationMs * 1_000L

                Log.d(TAG, "segment[$segIdx]: path=${inputPath.substringAfterLast('/')} " +
                        "startMs=$startMs endMs=${startMs + durationMs} durationMs=$durationMs")

                if (startUs >= endUs) {
                    Log.w(TAG, "segment[$segIdx]: degenerate (startUs >= endUs) — skipped")
                    continue
                }

                val ext = MediaExtractor()
                try {
                    ext.setDataSource(inputPath)

                    val inVideoTrack = findTrackIndex(ext, "video/")
                    val inAudioTrack = findTrackIndex(ext, "audio/")

                    if (inVideoTrack >= 0) ext.selectTrack(inVideoTrack)
                    if (inAudioTrack >= 0 && muxAudioTrack >= 0) ext.selectTrack(inAudioTrack)

                    // Seek to the keyframe at or immediately before startUs.
                    ext.seekTo(startUs, MediaExtractor.SEEK_TO_PREVIOUS_SYNC)
                    val actualStartUs = if (ext.sampleTime >= 0) ext.sampleTime else 0L

                    Log.d(TAG, "segment[$segIdx]: seekTo ${startUs / 1_000}ms → " +
                            "keyframe snap to ${actualStartUs / 1_000}ms " +
                            "(${(startUs - actualStartUs) / 1_000}ms pre-roll)")

                    var maxVideoUs = actualStartUs
                    var maxAudioUs = actualStartUs

                    // Track per-track exhaustion separately so we don't drop samples
                    // from one track just because the other track reached endUs first.
                    var videoExhausted = inVideoTrack < 0
                    var audioExhausted = inAudioTrack < 0 || muxAudioTrack < 0
                    var firstSampleWritten = false

                    while (true) {
                        buffer.clear()
                        val sampleSize = ext.readSampleData(buffer, 0)
                        if (sampleSize < 0) break // end of file

                        val trackIndex = ext.sampleTrackIndex
                        val rawTime = ext.sampleTime

                        val muxTrack: Int
                        val adjustedTime: Long
                        when {
                            trackIndex == inVideoTrack -> {
                                if (rawTime >= endUs) {
                                    videoExhausted = true
                                    ext.advance()
                                    if (audioExhausted) break else continue
                                }
                                muxTrack = muxVideoTrack
                                adjustedTime = (rawTime - actualStartUs) + videoOutputOffsetUs
                                if (rawTime > maxVideoUs) maxVideoUs = rawTime
                            }
                            trackIndex == inAudioTrack && muxAudioTrack >= 0 -> {
                                if (rawTime >= endUs) {
                                    audioExhausted = true
                                    ext.advance()
                                    if (videoExhausted) break else continue
                                }
                                muxTrack = muxAudioTrack
                                adjustedTime = (rawTime - actualStartUs) + audioOutputOffsetUs
                                if (rawTime > maxAudioUs) maxAudioUs = rawTime
                            }
                            else -> {
                                ext.advance()
                                continue
                            }
                        }

                        if (!firstSampleWritten) {
                            firstSampleWritten = true
                            Log.d(TAG, "segment[$segIdx]: first sample written — " +
                                    "track=${if (muxTrack == muxVideoTrack) "video" else "audio"} " +
                                    "rawTimeMs=${rawTime / 1_000} adjustedTimeMs=${adjustedTime / 1_000}")
                        }

                        info.offset = 0
                        info.size = sampleSize
                        info.presentationTimeUs = adjustedTime
                        info.flags = ext.sampleFlags
                        muxer.writeSampleData(muxTrack, buffer, info)
                        ext.advance()
                    }

                    // Advance output offsets by the actual extracted duration + one frame gap.
                    val videoDurationMs = (maxVideoUs - actualStartUs) / 1_000
                    val audioDurationMs = (maxAudioUs - actualStartUs) / 1_000
                    videoOutputOffsetUs += (maxVideoUs - actualStartUs) + 33_333L
                    audioOutputOffsetUs += (maxAudioUs - actualStartUs) + 22_676L
                    Log.d(TAG, "segment[$segIdx]: done — " +
                            "videoDurationMs=$videoDurationMs audioDurationMs=$audioDurationMs " +
                            "nextVideoOffsetMs=${videoOutputOffsetUs / 1_000} " +
                            "nextAudioOffsetMs=${audioOutputOffsetUs / 1_000}")
                } finally {
                    ext.release()
                }
            }
        } finally {
            muxer.stop()
            muxer.release()
            val sizeBytes = java.io.File(output).length()
            Log.d(TAG, "mergeWithTimeline: complete — sizeBytes=$sizeBytes path=$output")
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
