package com.multicamstudio.multicam_studio

import android.content.Intent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    private val channelName = "com.multicamstudio.multicam_studio/camera_service"

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
                        if (outputPath == null) {
                            result.error("INVALID_ARGS", "Missing output path", null)
                        } else {
                            Thread {
                                try {
                                    VideoRenderService.mergeSequential(inputs, outputPath)
                                    runOnUiThread { result.success(null) }
                                } catch (e: Exception) {
                                    runOnUiThread {
                                        result.error("RENDER_FAILED", e.message, null)
                                    }
                                }
                            }.start()
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }
}
