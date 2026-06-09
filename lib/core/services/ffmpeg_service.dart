import 'package:flutter/services.dart';

class FfmpegService {
  static const _channel = MethodChannel(
    'com.multicamstudio.multicam_studio/camera_service',
  );

  /// Renders [inputPaths] into a single MP4 at [outputPath].
  ///
  /// When [segments] is provided the render follows the admin's switching
  /// timeline (each segment specifies which file and which time window to
  /// extract). When [segments] is null or empty the clips are concatenated
  /// sequentially.
  Future<void> renderGrid({
    required List<String> inputPaths,
    required String outputPath,
    List<Map<String, dynamic>>? segments,
    void Function(double progress)? onProgress,
    void Function(String error)? onError,
    void Function(String outputPath)? onComplete,
  }) async {
    onProgress?.call(0.0);
    try {
      await _channel.invokeMethod<void>('renderVideos', {
        'inputs': inputPaths,
        'output': outputPath,
        if (segments != null && segments.isNotEmpty) 'segments': segments,
      });
      onProgress?.call(1.0);
      onComplete?.call(outputPath);
    } on PlatformException catch (e) {
      onError?.call(e.message ?? 'Render failed');
    } catch (e) {
      onError?.call(e.toString());
    }
  }

  Future<void> saveToPublicStorage(String sourcePath, String filename) async {
    try {
      await _channel.invokeMethod<void>('saveToPublicStorage', {
        'sourcePath': sourcePath,
        'filename': filename,
      });
    } catch (_) {
      // Best-effort: internal file still works for LAN transfer even if export fails.
    }
  }

  Future<void> cancel() async {
    // Native MediaMuxer runs synchronously — cannot be cancelled mid-flight.
  }
}
