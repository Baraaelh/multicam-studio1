import 'package:ffmpeg_kit_flutter_min_gpl/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_min_gpl/ffprobe_kit.dart';
import 'package:ffmpeg_kit_flutter_min_gpl/return_code.dart';
import 'package:ffmpeg_kit_flutter_min_gpl/statistics.dart';

/// Wraps FFmpegKit to render a multi-camera grid composite.
///
/// Grid layout:
///   1 input  → passthrough copy
///   2 inputs → hstack (side by side, 1920×540)
///   3 inputs → xstack 2×2 with bottom-right empty (1920×1080)
///   4 inputs → xstack 2×2 full grid (1920×1080)
class FfmpegService {
  int? _activeSessionId;

  Future<void> renderGrid({
    required List<String> inputPaths,
    required String outputPath,
    void Function(double progress)? onProgress,
    void Function(String error)? onError,
    void Function(String outputPath)? onComplete,
  }) async {
    // Measure the longest input duration to drive the progress indicator.
    double totalDurationMs = 0;
    for (final path in inputPaths) {
      final probeSession = await FFprobeKit.getMediaInformation(path);
      final info = probeSession.getMediaInformation();
      if (info != null) {
        final durationStr = info.getDuration();
        final ms = (double.tryParse(durationStr ?? '') ?? 0) * 1000;
        if (ms > totalDurationMs) totalDurationMs = ms;
      }
    }

    final command = _buildCommand(inputPaths, outputPath);

    final session = await FFmpegKit.executeAsync(
      command,
      (completedSession) async {
        _activeSessionId = null;
        final rc = await completedSession.getReturnCode();
        if (ReturnCode.isSuccess(rc)) {
          onComplete?.call(outputPath);
        } else {
          final output = await completedSession.getOutput();
          onError?.call(output ?? 'FFmpeg render failed (unknown error)');
        }
      },
      null,
      (Statistics stats) {
        if (totalDurationMs > 0) {
          final progress = stats.getTime() / totalDurationMs;
          onProgress?.call(progress.clamp(0.0, 1.0));
        }
      },
    );
    _activeSessionId = session.getSessionId();
  }

  Future<void> cancel() async {
    final id = _activeSessionId;
    if (id != null) {
      await FFmpegKit.cancel(id);
      _activeSessionId = null;
    }
  }

  static String _buildCommand(List<String> inputs, String output) {
    if (inputs.length == 1) {
      return '-i "${inputs[0]}" -c copy -y "$output"';
    }

    final inputArgs = inputs.map((p) => '-i "$p"').join(' ');

    // Scale each tile to 960×540; pad with black to preserve aspect ratio.
    const tileW = 960;
    const tileH = 540;
    final scaleFilters = List.generate(
      inputs.length,
      (i) => '[$i:v]scale=$tileW:$tileH:force_original_aspect_ratio=decrease,'
          'pad=$tileW:$tileH:(ow-iw)/2:(oh-ih)/2:black[v$i]',
    ).join(';');

    final String stackFilter;
    switch (inputs.length) {
      case 2:
        stackFilter = '[v0][v1]hstack=inputs=2[vout]';
      case 3:
        stackFilter = '[v0][v1][v2]xstack=inputs=3:layout=0_0|w0_0|0_h0[vout]';
      default:
        stackFilter =
            '[v0][v1][v2][v3]xstack=inputs=4:layout=0_0|w0_0|0_h0|w0_h0[vout]';
    }

    // Map the first input's audio as the program audio track.
    return '$inputArgs '
        '-filter_complex "$scaleFilters;$stackFilter" '
        '-map "[vout]" -map 0:a? '
        '-c:v libx264 -preset fast -crf 22 -c:a aac -y "$output"';
  }
}
