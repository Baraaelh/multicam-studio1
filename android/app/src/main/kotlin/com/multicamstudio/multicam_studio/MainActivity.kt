package com.multicamstudio.multicam_studio

import android.content.Intent
import android.util.Log
import com.cloudwebrtc.webrtc.FlutterWebRTCPlugin
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import org.webrtc.VideoTrack

class MainActivity : FlutterActivity() {

    private val channelName = "com.multicamstudio.multicam_studio/camera_service"
    private val tag = "MainActivity"

    private var currentRecorder: I420VideoRecorder? = null
    private var currentRecorderTrack: VideoTrack? = null

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
                    "startRecording" -> {
                        val trackId = call.argument<String>("trackId")
                        val outputPath = call.argument<String>("outputPath")
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
                            recorder.start()
                            videoTrack.addSink(recorder)
                            currentRecorder = recorder
                            currentRecorderTrack = videoTrack
                            Log.d(tag, "startRecording OK → $outputPath")
                            result.success(null)
                        } catch (e: Exception) {
                            Log.e(tag, "startRecording failed: ${e.message}", e)
                            result.error("RECORD_FAILED", e.message, null)
                        }
                    }
                    "stopRecording" -> {
                        val recorder = currentRecorder
                        val track = currentRecorderTrack
                        currentRecorder = null
                        currentRecorderTrack = null
                        if (recorder == null) {
                            result.success(null)
                            return@setMethodCallHandler
                        }
                        track?.removeSink(recorder)
                        recorder.stop {
                            runOnUiThread { result.success(null) }
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }
}
