package com.multicamstudio.multicam_studio

import android.content.ContentValues
import android.content.Intent
import android.media.MediaScannerConnection
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import android.util.Log
import com.cloudwebrtc.webrtc.FlutterWebRTCPlugin
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import org.webrtc.VideoTrack
import java.io.File
import java.io.IOException

class MainActivity : FlutterActivity() {

    private val channelName = "com.multicamstudio.multicam_studio/camera_service"
    private val tag = "MainActivity"

    private var currentRecorder: I420VideoRecorder? = null
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
                            Thread {
                                try {
                                    if (!segments.isNullOrEmpty()) {
                                        VideoRenderService.mergeWithTimeline(segments, outputPath, adminAudioPath)
                                    } else {
                                        VideoRenderService.mergeSequential(inputs, outputPath)
                                    }
                                    runOnUiThread { result.success(null) }
                                } catch (e: Exception) {
                                    runOnUiThread {
                                        result.error("RENDER_FAILED", e.message, null)
                                    }
                                }
                            }.start()
                        }
                    }
                    "startRecording" -> {
                        val trackId = call.argument<String>("trackId")
                        val outputPath = call.argument<String>("outputPath")
                        val recordAudio = call.argument<Boolean>("recordAudio") ?: true
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
                        try {
                            val recorder = I420VideoRecorder(outputPath)
                            recorder.start(recordAudio)
                            videoTrack.addSink(recorder)
                            currentRecorder = recorder
                            currentRecorderTrack = videoTrack
                            currentOutputPath = outputPath
                            Log.d(tag, "startRecording OK recordAudio=$recordAudio → $outputPath")
                            result.success(null)
                        } catch (e: Exception) {
                            Log.e(tag, "startRecording failed: ${e.message}", e)
                            result.error("RECORD_FAILED", e.message, null)
                        }
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
                            result.success(null)
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
                        val recorder = currentRecorder
                        val track = currentRecorderTrack
                        val savedPath = currentOutputPath
                        currentRecorder = null
                        currentRecorderTrack = null
                        currentOutputPath = null
                        if (recorder == null) {
                            result.success(null)
                            return@setMethodCallHandler
                        }
                        track?.removeSink(recorder)
                        recorder.stop {
                            // Export to public Movies so the file is visible in the device
                            // file manager. Runs on the encoder thread (background) — safe.
                            // Failure here is non-fatal: internal file still serves via HTTP.
                            if (savedPath != null) {
                                try {
                                    saveToPublicStorage(savedPath, File(savedPath).name)
                                } catch (e: Exception) {
                                    Log.e(tag, "saveToPublicStorage failed: ${e.message}", e)
                                }
                            }
                            runOnUiThread { result.success(null) }
                        }
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
