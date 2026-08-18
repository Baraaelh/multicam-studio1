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
    String? adminAudioPath,
    void Function(double progress)? onProgress,
    void Function(String error)? onError,
    void Function(String outputPath)? onComplete,
  }) async {
    onProgress?.call(0.0);
    try {
      await _channel.invokeMethod<void>('renderVideos', {
        'inputs': inputPaths,
        'output': outputPath,
        'segments': (segments != null && segments.isNotEmpty) ? segments : null,
        'adminAudioPath': adminAudioPath,
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
    // We still notify the native side so it can clean up any partial output
    // file and release resources. The native implementation should handle
    // this gracefully if a render is in progress.
    try {
      await _channel.invokeMethod<void>('cancelRender');
    } catch (_) {
      // Best-effort: if the native side doesn't support cancellation, ignore.
    }
  }
}
