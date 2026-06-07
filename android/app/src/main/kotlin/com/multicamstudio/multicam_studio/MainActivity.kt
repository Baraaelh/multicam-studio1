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
                    else -> result.notImplemented()
                }
            }
    }
}
