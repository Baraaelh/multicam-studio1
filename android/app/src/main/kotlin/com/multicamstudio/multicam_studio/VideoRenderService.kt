package com.multicamstudio.multicam_studio

import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMetadataRetriever
import android.media.MediaMuxer
import android.util.Log
import java.nio.ByteBuffer

/** Thrown from inside a merge loop when [VideoRenderService.requestCancel] was called. */
class RenderCancelledException : RuntimeException("Render cancelled")

object VideoRenderService {

    private const val TAG = "VideoRenderService"
    private const val MAX_SAMPLE_SIZE = 2 * 1024 * 1024 // 2 MB per sample

    // Set from the main thread, read on the render thread between samples.
    @Volatile
    private var cancelRequested = false

    val isCancelRequested: Boolean get() = cancelRequested

    /** Call before starting a render so a stale cancel doesn't abort it. */
    fun resetCancel() {
        cancelRequested = false
    }

    /** Asks the running merge to stop at the next sample. */
    fun requestCancel() {
        cancelRequested = true
    }

    private fun checkCancelled() {
        if (cancelRequested) throw RenderCancelledException()
    }

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

        // MediaFormat.KEY_ROTATION is not reliably populated by MediaExtractor on
        // MIUI/MediaTek devices. Use MediaMetadataRetriever which reads the
        // container-level rotation and is reliable on all Android versions.
        val rotation = readRotation(inputs[0])

        val muxer = MediaMuxer(output, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
        if (rotation != 0) muxer.setOrientationHint(rotation)
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
                        checkCancelled()
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
    /**
     * [adminAudioPath] — optional path to an audio-only MP4 recorded by the admin
     * device (Studio Audio Mode). When provided:
     *   • camera MP4 audio tracks are ignored (cameras recorded video-only)
     *   • audio is extracted from [adminAudioPath] and muxed as the sole audio track
     *   • each segment map must include "adminAudioStartMs" (Long) — the position
     *     within [adminAudioPath] that aligns with the start of that video segment
     */
    fun mergeWithTimeline(
        segments: List<Map<String, Any>>,
        output: String,
        adminAudioPath: String? = null,
    ) {
        require(segments.isNotEmpty()) { "No segments" }

        // Guard: if the admin audio file is missing or empty (e.g. AudioRecord init
        // failed silently), fall back to no studio audio rather than crashing.
        val validAdminAudioPath: String? = adminAudioPath?.let { p ->
            val f = java.io.File(p)
            when {
                !f.exists()     -> { Log.w(TAG, "admin audio missing — skipping studio audio: ${p.substringAfterLast('/')}"); null }
                f.length() == 0L -> { Log.w(TAG, "admin audio is 0 bytes — skipping studio audio: ${p.substringAfterLast('/')}"); null }
                else            -> p
            }
        }

        Log.d(TAG, "mergeWithTimeline: ${segments.size} segment(s) → $output" +
                if (validAdminAudioPath != null) " [studio audio: ${validAdminAudioPath.substringAfterLast('/')}]" else "")

        // Diagnostic: log full metadata for every input file before touching the muxer.
        segments.forEach { seg ->
            val p = seg["inputPath"] as String
            val f = java.io.File(p)
            Log.d(TAG, "input: ${p.substringAfterLast('/')} exists=${f.exists()} size=${f.length()}B")
            if (f.exists()) {
                val rotation = try { readRotation(p) } catch (e: Exception) { -1 }
                Log.d(TAG, "  rotation=${rotation}°")
                val ext = MediaExtractor()
                try {
                    ext.setDataSource(p)
                    Log.d(TAG, "  trackCount=${ext.trackCount}")
                    for (i in 0 until ext.trackCount) {
                        val fmt = ext.getTrackFormat(i)
                        val mime = fmt.getString(MediaFormat.KEY_MIME) ?: "?"
                        val w = try { fmt.getInteger(MediaFormat.KEY_WIDTH) } catch (_: Exception) { -1 }
                        val h = try { fmt.getInteger(MediaFormat.KEY_HEIGHT) } catch (_: Exception) { -1 }
                        val dur = try { fmt.getLong(MediaFormat.KEY_DURATION) / 1_000 } catch (_: Exception) { -1L }
                        Log.d(TAG, "  track[$i] $mime ${if (w > 0) "${w}×${h}" else ""} dur=${dur}ms")
                        if (mime.startsWith("video/") && dur <= 0L)
                            Log.w(TAG, "  WARNING: video track has zero/negative duration (dur=$dur)")
                    }
                } catch (e: Exception) {
                    Log.e(TAG, "  probe exception: ${e.message}")
                } finally {
                    ext.release()
                }
            }
        }

        // Validate every input file before touching the output muxer.
        // Checks: exists, non-empty, openable, has video track, video duration > 0.
        val badPaths = segments.mapNotNull { seg ->
            val p = seg["inputPath"] as String
            val f = java.io.File(p)
            if (!f.exists()) {
                throw IllegalStateException(
                    "Input file not found: ${p.substringAfterLast('/')} (full path: $p)"
                )
            }
            if (f.length() == 0L) {
                throw IllegalStateException(
                    "Input file is empty (0 bytes): ${p.substringAfterLast('/')}"
                )
            }
            val ext = MediaExtractor()
            try {
                ext.setDataSource(p)
                var hasVideo = false
                var videoDur = -1L
                for (i in 0 until ext.trackCount) {
                    val fmt = ext.getTrackFormat(i)
                    if (fmt.getString(MediaFormat.KEY_MIME)?.startsWith("video/") == true) {
                        hasVideo = true
                        videoDur = try { fmt.getLong(MediaFormat.KEY_DURATION) } catch (_: Exception) { -1L }
                        break
                    }
                }
                if (!hasVideo) {
                    Log.e(TAG, "VALIDATION FAIL — no video track: ${p.substringAfterLast('/')} trackCount=${ext.trackCount}")
                    p
                } else {
                    if (videoDur <= 0L)
                        Log.w(TAG, "VALIDATION WARN — video track duration=$videoDur in ${p.substringAfterLast('/')}")
                    null
                }
            } catch (e: Exception) {
                throw IllegalStateException(
                    "Cannot open ${p.substringAfterLast('/')}: ${e.message}"
                )
            } finally {
                ext.release()
            }
        }
        if (badPaths.isNotEmpty()) {
            val names = badPaths.joinToString(", ") { it.substringAfterLast('/') }
            throw IllegalStateException("No video track in: $names")
        }

        // Probe the first segment's file to obtain video format.
        // Audio format comes from the admin audio file (Studio Mode) or the first camera file.
        val firstPath = segments[0]["inputPath"] as String
        val probe = MediaExtractor()
        val videoFormat: MediaFormat
        val cameraAudioFormat: MediaFormat?
        try {
            probe.setDataSource(firstPath)
            videoFormat = findFormat(probe, "video/")
                ?: throw IllegalStateException("No video track in $firstPath")
            cameraAudioFormat = if (validAdminAudioPath == null) findFormat(probe, "audio/") else null
        } finally {
            probe.release()
        }

        val audioFormat: MediaFormat? = if (validAdminAudioPath != null) {
            val adminProbe = MediaExtractor()
            try {
                adminProbe.setDataSource(validAdminAudioPath)
                findFormat(adminProbe, "audio/")
                    ?: run { Log.w(TAG, "admin audio file has no audio track — output will be silent"); null }
            } finally {
                adminProbe.release()
            }
        } else {
            cameraAudioFormat
        }

        // Validate all segments share the same resolution as the first file.
        // Different resolutions produce incompatible H.264 SPS and silently corrupt
        // the merged video; surface this as a clear error instead.
        val refWidth  = try { videoFormat.getInteger(MediaFormat.KEY_WIDTH)  } catch (_: Exception) { -1 }
        val refHeight = try { videoFormat.getInteger(MediaFormat.KEY_HEIGHT) } catch (_: Exception) { -1 }
        if (refWidth > 0 && refHeight > 0) {
            val resMismatches = segments.drop(1).mapNotNull { seg ->
                val p = seg["inputPath"] as String
                val ext = MediaExtractor()
                try {
                    ext.setDataSource(p)
                    val fmt = findFormat(ext, "video/") ?: return@mapNotNull null
                    val w = try { fmt.getInteger(MediaFormat.KEY_WIDTH)  } catch (_: Exception) { -1 }
                    val h = try { fmt.getInteger(MediaFormat.KEY_HEIGHT) } catch (_: Exception) { -1 }
                    if (w != refWidth || h != refHeight) "${p.substringAfterLast('/')} (${w}×${h})" else null
                } finally { ext.release() }
            }
            if (resMismatches.isNotEmpty()) {
                throw IllegalStateException(
                    "Resolution mismatch — expected ${refWidth}×${refHeight}, " +
                    "but got different sizes in: ${resMismatches.joinToString(", ")}"
                )
            }
        }

        val rotation = readRotation(firstPath)

        val muxer = MediaMuxer(output, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
        if (rotation != 0) muxer.setOrientationHint(rotation)
        val muxVideoTrack = muxer.addTrack(videoFormat)
        val muxAudioTrack = if (audioFormat != null) muxer.addTrack(audioFormat) else -1
        muxer.start()

        val buffer = ByteBuffer.allocate(MAX_SAMPLE_SIZE)
        val info = MediaCodec.BufferInfo()
        var videoOutputOffsetUs = 0L
        var audioOutputOffsetUs = 0L

        // Studio Mode: open admin audio extractor once; reuse across all segments.
        val adminAudioExt: MediaExtractor? = if (validAdminAudioPath != null && muxAudioTrack >= 0) {
            val ext = MediaExtractor()
            ext.setDataSource(validAdminAudioPath)
            val idx = findTrackIndex(ext, "audio/")
            if (idx >= 0) { ext.selectTrack(idx); ext } else { ext.release(); null }
        } else null

        try {
            for ((segIdx, seg) in segments.withIndex()) {
                val inputPath = seg["inputPath"] as String
                val startMs = (seg["startMs"] as Number).toLong()
                val durationMs = (seg["durationMs"] as Number).toLong()
                val startUs = startMs * 1_000L
                val endUs = startUs + durationMs * 1_000L
                // Session-timeline position for admin audio (supplied by Dart buildRenderSegments).
                val adminAudioStartMs = (seg["adminAudioStartMs"] as? Number)?.toLong() ?: startMs
                val adminStartUs = adminAudioStartMs * 1_000L
                val adminEndUs = adminStartUs + durationMs * 1_000L

                Log.d(TAG, "segment[$segIdx]: path=${inputPath.substringAfterLast('/')} " +
                        "startMs=$startMs endMs=${startMs + durationMs} durationMs=$durationMs" +
                        if (adminAudioExt != null) " adminStartMs=$adminAudioStartMs" else "")

                if (startUs >= endUs) {
                    Log.w(TAG, "segment[$segIdx]: degenerate (startUs >= endUs) — skipped")
                    continue
                }

                val ext = MediaExtractor()
                try {
                    ext.setDataSource(inputPath)

                    val inVideoTrack = findTrackIndex(ext, "video/")
                    // In Studio Mode cameras record video-only; skip camera audio track.
                    val inAudioTrack = if (adminAudioExt == null) findTrackIndex(ext, "audio/") else -1

                    if (inVideoTrack >= 0) ext.selectTrack(inVideoTrack)
                    if (inAudioTrack >= 0 && muxAudioTrack >= 0) ext.selectTrack(inAudioTrack)

                    ext.seekTo(startUs, MediaExtractor.SEEK_TO_PREVIOUS_SYNC)
                    val actualStartUs = if (ext.sampleTime >= 0) ext.sampleTime else 0L

                    Log.d(TAG, "segment[$segIdx]: seekTo ${startUs / 1_000}ms → " +
                            "keyframe snap to ${actualStartUs / 1_000}ms " +
                            "(${(startUs - actualStartUs) / 1_000}ms pre-roll)")

                    var maxVideoUs = actualStartUs
                    var maxAudioUs = actualStartUs

                    var videoExhausted = inVideoTrack < 0
                    var audioExhausted = inAudioTrack < 0 || muxAudioTrack < 0
                    var firstSampleWritten = false

                    while (true) {
                        checkCancelled()
                        buffer.clear()
                        val sampleSize = ext.readSampleData(buffer, 0)
                        if (sampleSize < 0) break

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

                    videoOutputOffsetUs += (maxVideoUs - actualStartUs) + 33_333L

                    // Studio Mode: extract admin audio for this segment's time window.
                    if (adminAudioExt != null && muxAudioTrack >= 0) {
                        adminAudioExt.seekTo(adminStartUs, MediaExtractor.SEEK_TO_PREVIOUS_SYNC)
                        val adminActualStartUs = if (adminAudioExt.sampleTime >= 0) adminAudioExt.sampleTime else adminStartUs
                        var maxAdminUs = adminActualStartUs

                        while (true) {
                            checkCancelled()
                            buffer.clear()
                            val sampleSize = adminAudioExt.readSampleData(buffer, 0)
                            if (sampleSize < 0) break
                            val rawTime = adminAudioExt.sampleTime
                            if (rawTime >= adminEndUs) break

                            val adjustedTime = (rawTime - adminActualStartUs) + audioOutputOffsetUs
                            if (rawTime > maxAdminUs) maxAdminUs = rawTime

                            info.offset = 0
                            info.size = sampleSize
                            info.presentationTimeUs = adjustedTime
                            info.flags = adminAudioExt.sampleFlags
                            muxer.writeSampleData(muxAudioTrack, buffer, info)
                            adminAudioExt.advance()
                        }

                        audioOutputOffsetUs += (maxAdminUs - adminActualStartUs) + 22_676L
                        Log.d(TAG, "segment[$segIdx]: admin audio snapMs=${adminActualStartUs / 1_000} " +
                                "durMs=${(maxAdminUs - adminActualStartUs) / 1_000}")
                    } else {
                        audioOutputOffsetUs += (maxAudioUs - actualStartUs) + 22_676L
                    }

                    Log.d(TAG, "segment[$segIdx]: done — " +
                            "videoDurMs=${(maxVideoUs - actualStartUs) / 1_000} " +
                            "nextVideoOffsetMs=${videoOutputOffsetUs / 1_000} " +
                            "nextAudioOffsetMs=${audioOutputOffsetUs / 1_000}")
                } finally {
                    ext.release()
                }
            }
        } finally {
            adminAudioExt?.release()
            muxer.stop()
            muxer.release()
            val outFile = java.io.File(output)
            val sizeBytes = outFile.length()
            Log.d(TAG, "mergeWithTimeline: complete — sizeBytes=$sizeBytes path=$output")

            // Post-render output probe — confirm the merged file is playable.
            if (outFile.exists() && sizeBytes > 0) {
                val outExt = MediaExtractor()
                try {
                    outExt.setDataSource(output)
                    Log.d(TAG, "output probe: trackCount=${outExt.trackCount}")
                    for (i in 0 until outExt.trackCount) {
                        val fmt = outExt.getTrackFormat(i)
                        val mime = fmt.getString(MediaFormat.KEY_MIME) ?: "?"
                        val w = try { fmt.getInteger(MediaFormat.KEY_WIDTH) } catch (_: Exception) { -1 }
                        val h = try { fmt.getInteger(MediaFormat.KEY_HEIGHT) } catch (_: Exception) { -1 }
                        val dur = try { fmt.getLong(MediaFormat.KEY_DURATION) / 1_000 } catch (_: Exception) { -1L }
                        Log.d(TAG, "  output track[$i] $mime ${if (w > 0) "${w}×${h}" else ""} dur=${dur}ms")
                    }
                } catch (e: Exception) {
                    Log.e(TAG, "output probe failed: ${e.message}")
                } finally {
                    outExt.release()
                }
            } else {
                Log.e(TAG, "mergeWithTimeline: output file missing or empty after muxer.stop()")
            }
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

    // MediaFormat.KEY_ROTATION from MediaExtractor is not reliably populated on
    // MIUI/MediaTek ROMs. MediaMetadataRetriever reads the container-level rotation
    // from the mvhd matrix and works correctly on all Android versions.
    private fun readRotation(path: String): Int {
        val retriever = MediaMetadataRetriever()
        return try {
            retriever.setDataSource(path)
            retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_ROTATION)
                ?.toIntOrNull() ?: 0
        } catch (e: Exception) {
            Log.w(TAG, "readRotation failed for ${path.substringAfterLast('/')}: ${e.message}")
            0
        } finally {
            retriever.release()
        }
    }
}
