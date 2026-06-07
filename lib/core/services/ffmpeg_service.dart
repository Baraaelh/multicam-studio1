import 'package:flutter/services.dart';

class FfmpegService {
  static const _channel = MethodChannel(
    'com.multicamstudio.multicam_studio/camera_service',
  );

  Future<void> renderGrid({
    required List<String> inputPaths,
    required String outputPath,
    void Function(double progress)? onProgress,
    void Function(String error)? onError,
    void Function(String outputPath)? onComplete,
  }) async {
    onProgress?.call(0.0);
    try {
      await _channel.invokeMethod<void>('renderVideos', {
        'inputs': inputPaths,
        'output': outputPath,
      });
      onProgress?.call(1.0);
      onComplete?.call(outputPath);
    } on PlatformException catch (e) {
      onError?.call(e.message ?? 'Render failed');
    } catch (e) {
      onError?.call(e.toString());
    }
  }

  Future<void> cancel() async {
    // Native MediaMuxer runs synchronously — cannot be cancelled mid-flight.
  }
}
