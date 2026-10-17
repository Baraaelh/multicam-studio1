package com.multicamstudio.multicam_studio

import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.graphics.SurfaceTexture
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraManager
import android.media.MediaCodecInfo
import android.media.MediaCodecList
import android.media.MediaScannerConnection
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import android.util.Log
import com.cloudwebrtc.webrtc.FlutterWebRTCPlugin
import com.cloudwebrtc.webrtc.utils.EglUtils
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import org.webrtc.VideoSink
import org.webrtc.VideoTrack
import java.io.File
import java.io.IOException

class MainActivity : FlutterActivity() {

    private val channelName = "com.multicamstudio.multicam_studio/camera_service"
    private val tag = "MainActivity"

    // VideoSink reference kept for removeSink(); stop function held separately so
    // both SurfaceVideoRecorder and I420VideoRecorder can be used without a shared
    // base class.
    private var currentRecorder: VideoSink? = null
    private var currentRecorderStopFn: (((() -> Unit) -> Unit))? = null
    private var currentRecorderTrack: VideoTrack? = null
    private var currentOutputPath: String? = null

    private var adminAudioRecorder: AdminAudioRecorder? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "start" -> {
                        startForegroundService(
                            Intent(this, CameraForegroundService::class.java).apply {
                                action = CameraForegroundService.ACTION_START
                            }
                        )
                        result.success(null)
                    }
                    "stop" -> {
                        startService(
                            Intent(this, CameraForegroundService::class.java).apply {
                                action = CameraForegroundService.ACTION_STOP
                            }
                        )
                        result.success(null)
                    }
                    "renderVideos" -> {
                        @Suppress("UNCHECKED_CAST")
                        val inputs = call.argument<List<String>>("inputs") ?: emptyList()
                        val outputPath = call.argument<String>("output")
                        @Suppress("UNCHECKED_CAST")
                        val segments = call.argument<List<Map<String, Any>>>("segments")
                        val adminAudioPath = call.argument<String>("adminAudioPath")
                        if (outputPath == null) {
                            result.error("INVALID_ARGS", "Missing output path", null)
                        } else {
                            VideoRenderService.resetCancel()
                            Thread {
                                try {
                                    if (!segments.isNullOrEmpty()) {
                                        VideoRenderService.mergeWithTimeline(segments, outputPath, adminAudioPath)
                                    } else {
                                        VideoRenderService.mergeSequential(inputs, outputPath)
                                    }
                                    runOnUiThread { result.success(null) }
                                } catch (e: Exception) {
                                    // Check the flag rather than the exception type: muxer.stop()
                                    // in the merge's finally block can throw and replace the
                                    // RenderCancelledException.
                                    if (VideoRenderService.isCancelRequested) {
                                        Log.d(tag, "renderVideos cancelled — deleting partial output")
                                        java.io.File(outputPath).delete()
                                        runOnUiThread {
                                            result.error("RENDER_CANCELLED", "Render cancelled", null)
                                        }
                                    } else {
                                        runOnUiThread {
                                            result.error("RENDER_FAILED", e.message, null)
                                        }
                                    }
                                }
                            }.start()
                        }
                    }
                    "cancelRender" -> {
                        VideoRenderService.requestCancel()
                        result.success(null)
                    }
                    "getAppCheckDebugToken" -> {
                        result.success(readAppCheckDebugToken())
                    }
                    "getRecordingCapabilities" -> {
                        try {
                            result.success(buildRecordingCapabilities())
                        } catch (e: Exception) {
                            Log.e(tag, "getRecordingCapabilities failed: ${e.message}", e)
                            result.error("CAPABILITIES_ERROR", e.message, null)
                        }
                    }
                    "startRecording" -> {
                        val trackId = call.argument<String>("trackId")
                        val outputPath = call.argument<String>("outputPath")
                        val recordAudio = call.argument<Boolean>("recordAudio") ?: true
                        val width = call.argument<Int>("width") ?: 1280
                        val height = call.argument<Int>("height") ?: 720
                        val frameRate = call.argument<Int>("frameRate") ?: 30
                        val bitRate = call.argument<Int>("bitRate") ?: 3_000_000
                        if (trackId == null || outputPath == null) {
                            result.error("INVALID_ARGS", "Missing trackId or outputPath", null)
                            return@setMethodCallHandler
                        }
                        val plugin = FlutterWebRTCPlugin.sharedSingleton
                        if (plugin == null) {
                            result.error("NO_PLUGIN", "FlutterWebRTCPlugin not initialized", null)
                            return@setMethodCallHandler
                        }
                        val localTrack = plugin.getLocalTrack(trackId)
                        if (localTrack == null) {
                            Log.e(tag, "startRecording: track not found id=$trackId")
                            result.error("NO_TRACK", "Track not found: $trackId", null)
                            return@setMethodCallHandler
                        }
                        val videoTrack = localTrack.track as? VideoTrack
                        if (videoTrack == null) {
                            result.error("NOT_VIDEO", "Track is not a VideoTrack: $trackId", null)
                            return@setMethodCallHandler
                        }
                        // MediaCodec.createEncoderByType() + configure() + start() can take
                        // 100–300 ms on mid-range hardware. Running them on the platform thread
                        // freezes Flutter's UI (and the camera preview) for that whole window.
                        // Validation is done above (platform-thread-safe); only the slow encoder
                        // init is moved to a background thread.
                        Thread {
                            try {
                                Log.i(tag, "DIAG startRecording thread=${Thread.currentThread().name} ts=${System.currentTimeMillis()}")

                                // Try GPU surface mode first (zero-copy, no glReadPixels
                                // per-frame bottleneck). Falls back to I420 CPU path if
                                // EGL context creation fails on this device.
                                val sink: VideoSink
                                val stopFn: ((() -> Unit) -> Unit)

                                var surfaceRec: SurfaceVideoRecorder? = null
                                try {
                                    val sharedCtx = EglUtils.getRootEglBaseContext()
                                    val rec = SurfaceVideoRecorder(
                                        outputPath, width, height, frameRate, bitRate, sharedCtx)
                                    val tSurf = System.nanoTime()
                                    rec.start(recordAudio)
                                    Log.i(tag, "DIAG SurfaceVideoRecorder.start(): ${(System.nanoTime() - tSurf) / 1_000_000L}ms")
                                    surfaceRec = rec
                                } catch (e: Exception) {
                                    Log.w(tag, "Surface mode unavailable (${e.message}), falling back to I420")
                                }

                                if (surfaceRec != null) {
                                    sink = surfaceRec
                                    stopFn = surfaceRec::stop
                                } else {
                                    val rec = I420VideoRecorder(outputPath, width, height, frameRate, bitRate)
                                    val tI420 = System.nanoTime()
                                    rec.start(recordAudio)
                                    Log.i(tag, "DIAG I420VideoRecorder.start(): ${(System.nanoTime() - tI420) / 1_000_000L}ms")
                                    sink = rec
                                    stopFn = rec::stop
                                }

                                val tSink = System.nanoTime()
                                videoTrack.addSink(sink)
                                Log.i(tag, "DIAG addSink() done: ${(System.nanoTime() - tSink) / 1_000_000L}ms")
                                // State variables are only written/read on the platform thread.
                                runOnUiThread {
                                    currentRecorder = sink
                                    currentRecorderStopFn = stopFn
                                    currentRecorderTrack = videoTrack
                                    currentOutputPath = outputPath
                                    Log.d(tag, "startRecording OK ${width}×${height}@${frameRate}fps ${bitRate}bps recordAudio=$recordAudio → $outputPath")
                                    result.success(null)
                                }
                            } catch (e: Exception) {
                                Log.e(tag, "startRecording failed: ${e.message}", e)
                                runOnUiThread { result.error("RECORD_FAILED", e.message, null) }
                            }
                        }.start()
                    }
                    "startAdminAudioRecording" -> {
                        val outputPath = call.argument<String>("outputPath")
                        if (outputPath == null) {
                            result.error("INVALID_ARGS", "Missing outputPath", null)
                            return@setMethodCallHandler
                        }
                        try {
                            adminAudioRecorder?.stop {}
                            val rec = AdminAudioRecorder(outputPath)
                            rec.start()
                            adminAudioRecorder = rec
                            Log.d(tag, "startAdminAudioRecording OK → $outputPath")
                            result.success(rec.captureStartEpochMs)
                        } catch (e: Exception) {
                            Log.e(tag, "startAdminAudioRecording failed: ${e.message}", e)
                            result.error("RECORD_FAILED", e.message, null)
                        }
                    }
                    "stopAdminAudioRecording" -> {
                        val rec = adminAudioRecorder
                        adminAudioRecorder = null
                        if (rec == null) { result.success(null); return@setMethodCallHandler }
                        rec.stop { runOnUiThread { result.success(null) } }
                    }
                    "stopRecording" -> {
                        val sink = currentRecorder
                        val stopFn = currentRecorderStopFn
                        val track = currentRecorderTrack
                        val savedPath = currentOutputPath
                        currentRecorder = null
                        currentRecorderStopFn = null
                        currentRecorderTrack = null
                        currentOutputPath = null
                        if (sink == null || stopFn == null) {
                            result.success(null)
                            return@setMethodCallHandler
                        }
                        track?.removeSink(sink)
                        stopFn {
                            // Notify Flutter as soon as the encoder/muxer is finalised.
                            // The internal file is complete at this point and the LAN
                            // transfer server can already serve it.
                            // saveToPublicStorage copies the file to the device gallery;
                            // it runs after result.success so it never delays the Dart
                            // caller (which is the primary source of perceived stop latency).
                            // The result carries the recorder's diagnostics so Dart can
                            // explain an empty file instead of publishing it silently.
                            val diagnostics = (sink as? RecorderDiagnostics)?.diagnostics
                            Log.d(tag, "stopRecording diagnostics: $diagnostics")
                            runOnUiThread { result.success(diagnostics) }
                            if (savedPath != null) {
                                try {
                                    saveToPublicStorage(savedPath, File(savedPath).name)
                                } catch (e: Exception) {
                                    Log.e(tag, "saveToPublicStorage failed: ${e.message}", e)
                                }
                            }
                        }
                    }
                    "reattachSink" -> {
                        val trackId = call.argument<String>("trackId")
                        if (trackId == null) { result.success(null); return@setMethodCallHandler }
                        val plugin = FlutterWebRTCPlugin.sharedSingleton
                        if (plugin == null) { result.success(null); return@setMethodCallHandler }
                        val localTrack = plugin.getLocalTrack(trackId)
                        val newVideoTrack = localTrack?.track as? VideoTrack
                        val sink = currentRecorder
                        val oldTrack = currentRecorderTrack
                        if (sink != null && newVideoTrack != null) {
                            oldTrack?.removeSink(sink)
                            newVideoTrack.addSink(sink)
                            currentRecorderTrack = newVideoTrack
                            Log.d(tag, "reattachSink: recorder moved to ${newVideoTrack.id()}")
                        }
                        result.success(null)
                    }
                    "saveToPublicStorage" -> {
                        val sourcePath = call.argument<String>("sourcePath")
                        val filename = call.argument<String>("filename")
                        if (sourcePath == null || filename == null) {
                            result.error("INVALID_ARGS", "Missing sourcePath or filename", null)
                        } else {
                            Thread {
                                try {
                                    saveToPublicStorage(sourcePath, filename)
                                    runOnUiThread { result.success(null) }
                                } catch (e: Exception) {
                                    Log.e(tag, "saveToPublicStorage failed: ${e.message}", e)
                                    runOnUiThread { result.error("SAVE_FAILED", e.message, null) }
                                }
                            }.start()
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    /**
     * Queries the back-facing camera via Camera2 to discover which (resolution, fps)
     * combinations are actually supported for H264 video capture.
     *
     * Uses SurfaceTexture output sizes (which WebRTC uses for camera capture) and
     * AE fixed fps ranges to determine genuine recording profiles.
     */
    private fun buildRecordingCapabilities(): List<Map<String, Any>> {
        val profiles = mutableListOf<Map<String, Any>>()
        try {
            val cameraManager = getSystemService(CAMERA_SERVICE) as CameraManager

            // Standard resolutions to probe, ordered highest-to-lowest quality.
            // 720p is the practical floor; anything below is not useful for broadcast.
            val targetSizes = listOf(3840 to 2160, 1920 to 1080, 1280 to 720)
            // Only probe 30fps: the WebRTC getUserMedia pipeline is capped at 30fps,
            // so higher values would not reflect achievable recording frame rates.
            val targetFps = listOf(30)

            // Query MediaCodec AVC encoder capabilities BEFORE probing camera sizes.
            // Camera2 SurfaceTexture sizes describe what the sensor can *capture*; they
            // say nothing about what the AVC *encoder* can encode. On mid-range MediaTek
            // SoCs (e.g. Helio G90T on Redmi Note 8 Pro) the sensor outputs 4K but the
            // OMX.MTK.VIDEO.ENCODER.AVC encoder tops out at 1080p. Without this check
            // the admin can select 4K → encoder gets ERROR(0x8000100b) → IllegalState
            // in drainVideoEncoder → FATAL EXCEPTION: SurfVid.
            var encoderName: String? = null
            val avcEncoderCaps: MediaCodecInfo.VideoCapabilities? = try {
                val allCodecs = MediaCodecList(MediaCodecList.ALL_CODECS).codecInfos
                val hwEnc = if (Build.VERSION.SDK_INT >= 29) {
                    allCodecs.firstOrNull { info ->
                        info.isEncoder && info.isHardwareAccelerated &&
                        info.supportedTypes.any { it.equals("video/avc", ignoreCase = true) }
                    }
                } else {
                    allCodecs.firstOrNull { info ->
                        info.isEncoder &&
                        !info.name.lowercase().startsWith("omx.google.") &&
                        info.supportedTypes.any { it.equals("video/avc", ignoreCase = true) }
                    }
                }
                // Fall back to any AVC encoder if no hardware encoder is found.
                val enc = hwEnc ?: allCodecs.firstOrNull { info ->
                    info.isEncoder &&
                    info.supportedTypes.any { it.equals("video/avc", ignoreCase = true) }
                }
                encoderName = enc?.name
                enc?.getCapabilitiesForType("video/avc")?.videoCapabilities
            } catch (e: Exception) {
                Log.w(tag, "buildRecordingCapabilities: AVC caps query failed: ${e.message}")
                null
            }

            val seen = mutableSetOf<Triple<Int, Int, Int>>()

            for (id in cameraManager.cameraIdList) {
                val chars = cameraManager.getCameraCharacteristics(id)
                val facing = chars.get(CameraCharacteristics.LENS_FACING)
                if (facing != CameraCharacteristics.LENS_FACING_BACK) continue

                val streamMap = chars.get(CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP)
                    ?: break

                // SurfaceTexture sizes match what WebRTC's camera source can open
                val supportedSizes = streamMap
                    .getOutputSizes(SurfaceTexture::class.java)
                    ?.map { it.width to it.height }
                    ?.toSet() ?: emptySet()

                // Fixed fps ranges: lower == upper means the camera guarantees that exact rate
                val aeRanges = chars.get(CameraCharacteristics.CONTROL_AE_AVAILABLE_TARGET_FPS_RANGES)
                    ?: break
                val supportedFixedFps = aeRanges
                    .filter { it.lower == it.upper }
                    .map { it.upper }
                    .toSet()

                for ((w, h) in targetSizes) {
                    if ((w to h) !in supportedSizes) continue
                    // Skip any resolution the AVC encoder cannot actually encode.
                    if (avcEncoderCaps != null && !avcEncoderCaps.isSizeSupported(w, h)) {
                        Log.d(tag, "buildRecordingCapabilities: skip ${w}×${h} — AVC encoder reports unsupported")
                        continue
                    }
                    // MediaTek hardware AVC encoders (e.g., POCO M5s / Redmi Note 8 Pro)
                    // incorrectly report isSizeSupported(1920, 1080) == true, but throw
                    // IllegalStateException inside dequeueOutputBuffer when fed 1080p frames.
                    // This includes OMX.MTK.* and c2.mtk.* encoders, but to be absolutely safe
                    // against Xiaomi encoder renaming, we check the Build properties.
                    val isMtk = encoderName?.contains("mtk", ignoreCase = true) == true ||
                                Build.HARDWARE.lowercase().startsWith("mt") ||
                                (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S && Build.SOC_MANUFACTURER.lowercase().contains("mediatek"))
                    if (w > 1280 && isMtk) {
                        Log.d(tag, "buildRecordingCapabilities: skip ${w}×${h} — MTK encoder known to crash at >720p")
                        continue
                    }
                    for (fps in targetFps) {
                        if (fps !in supportedFixedFps) continue
                        val key = Triple(w, h, fps)
                        if (seen.add(key)) {
                            profiles.add(mapOf("width" to w, "height" to h, "frameRate" to fps, "codec" to "H264"))
                        }
                    }
                }
                break // Only use the first back-facing camera
            }
        } catch (e: Exception) {
            Log.e(tag, "buildRecordingCapabilities: ${e.message}", e)
        }

        // Always guarantee at least 720p30 as a safe minimum
        if (profiles.none { it["height"] == 720 && it["frameRate"] == 30 }) {
            profiles.add(mapOf("width" to 1280, "height" to 720, "frameRate" to 30, "codec" to "H264"))
        }

        Log.d(tag, "buildRecordingCapabilities: ${profiles.size} profile(s) discovered")
        return profiles
    }

    /**
     * Copies [sourcePath] into the public Movies/MultiCamStudio folder so the
     * file is visible in the device file manager and gallery apps.
     *
     * On API 29+: inserts via MediaStore (no permission required).
     * On API <29: copies to Environment.DIRECTORY_MOVIES and triggers a media scan
     *             (requires WRITE_EXTERNAL_STORAGE, declared with maxSdkVersion="28").
     *
     * The original internal file is kept intact so the LAN transfer server can
     * continue serving it.
     */
    @Suppress("DEPRECATION")
    /**
     * Returns this install's App Check debug token, or null if the debug
     * provider hasn't generated one yet.
     *
     * firebase-appcheck-debug keeps it in SharedPreferences named
     * "com.google.firebase.appcheck.debug.store.<persistenceKey>" under
     * "com.google.firebase.appcheck.debug.DEBUG_SECRET" (its StorageHelper).
     * The files are matched by prefix so no Firebase classes are needed. If a
     * future SDK moves the token, this returns null and the app falls back to
     * pointing at logcat.
     */
    private fun readAppCheckDebugToken(): String? {
        val prefix = "com.google.firebase.appcheck.debug.store."
        val prefsDir = File(applicationInfo.dataDir, "shared_prefs")
        val names = prefsDir.listFiles()
            ?.map { it.name }
            ?.filter { it.startsWith(prefix) && it.endsWith(".xml") }
            ?: return null
        for (name in names) {
            val prefs = getSharedPreferences(name.removeSuffix(".xml"), Context.MODE_PRIVATE)
            prefs.getString("com.google.firebase.appcheck.debug.DEBUG_SECRET", null)
                ?.let { return it }
        }
        return null
    }

    private fun saveToPublicStorage(sourcePath: String, filename: String) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val values = ContentValues().apply {
                put(MediaStore.Video.Media.DISPLAY_NAME, filename)
                put(MediaStore.Video.Media.MIME_TYPE, "video/mp4")
                put(MediaStore.Video.Media.RELATIVE_PATH,
                    Environment.DIRECTORY_MOVIES + "/MultiCamStudio")
                put(MediaStore.Video.Media.IS_PENDING, 1)
            }
            val uri = contentResolver.insert(
                MediaStore.Video.Media.EXTERNAL_CONTENT_URI, values
            ) ?: throw IOException("MediaStore insert returned null for $filename")

            contentResolver.openOutputStream(uri)
                ?.use { out -> File(sourcePath).inputStream().use { it.copyTo(out) } }
                ?: throw IOException("openOutputStream returned null for $uri")

            values.clear()
            values.put(MediaStore.Video.Media.IS_PENDING, 0)
            contentResolver.update(uri, values, null, null)
            Log.d(tag, "saveToPublicStorage: MediaStore OK → Movies/MultiCamStudio/$filename")
        } else {
            val dir = File(
                Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_MOVIES),
                "MultiCamStudio"
            )
            dir.mkdirs()
            val dest = File(dir, filename)
            File(sourcePath).copyTo(dest, overwrite = true)
            MediaScannerConnection.scanFile(
                applicationContext,
                arrayOf(dest.absolutePath),
                arrayOf("video/mp4"),
                null,
            )
            Log.d(tag, "saveToPublicStorage: legacy OK → ${dest.absolutePath}")
        }
    }
}
