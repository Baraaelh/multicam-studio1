import 'package:get/get.dart';
import 'package:path_provider/path_provider.dart';

// ignore_for_file: unawaited_futures

import '../../../../core/services/ffmpeg_service.dart';

class RenderSource {
  final String filename;
  final String label;
  final String path;

  const RenderSource({
    required this.filename,
    required this.label,
    required this.path,
  });
}

/// A GetxService — lives for the app lifetime, never disposed by route changes.
/// This decouples the native MediaMuxer background thread from the
/// /admin/render page lifecycle so rendering survives navigation.
class RenderService extends GetxService {
  final FfmpegService _ffmpegService;

  RenderService({required FfmpegService ffmpegService})
      : _ffmpegService = ffmpegService;

  final isRendering = false.obs;
  final renderProgress = 0.0.obs;
  final outputPath = Rx<String?>(null);
  final errorMessage = Rx<String?>(null);
  final sources = RxList<RenderSource>();

  /// Called by TransferSheet before navigating to the render page.
  /// Resets prior result and loads the new source list.
  void prepare(List<RenderSource> renderSources) {
    if (isRendering.value) return;
    sources.assignAll(renderSources);
    outputPath.value = null;
    errorMessage.value = null;
    renderProgress.value = 0;
  }

  Future<void> startRender() async {
    final paths = sources.map((s) => s.path).toList();
    if (paths.isEmpty) return;

    isRendering.value = true;
    renderProgress.value = 0;
    outputPath.value = null;
    errorMessage.value = null;

    final dir = await getApplicationDocumentsDirectory();
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final output = '${dir.path}/render_$timestamp.mp4';

    await _ffmpegService.renderGrid(
      inputPaths: paths,
      outputPath: output,
      onProgress: (p) => renderProgress.value = p,
      onComplete: (path) {
        outputPath.value = path;
        isRendering.value = false;
        renderProgress.value = 1.0;
        _ffmpegService.saveToPublicStorage(path, path.split('/').last);
      },
      onError: (err) {
        errorMessage.value = err;
        isRendering.value = false;
      },
    );
  }

  Future<void> cancelRender() async {
    await _ffmpegService.cancel();
    isRendering.value = false;
    renderProgress.value = 0;
  }
}
