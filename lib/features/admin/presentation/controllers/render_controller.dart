import 'package:get/get.dart';
import 'package:path_provider/path_provider.dart';

import '../../../../core/services/ffmpeg_service.dart';
import 'admin_controller.dart';

class RenderController extends GetxController {
  final FfmpegService _ffmpegService;

  RenderController({required FfmpegService ffmpegService})
      : _ffmpegService = ffmpegService;

  final isRendering = false.obs;
  final renderProgress = 0.0.obs;
  final outputPath = Rx<String?>(null);
  final errorMessage = Rx<String?>(null);

  late final AdminController _adminController;

  @override
  void onInit() {
    super.onInit();
    _adminController = Get.find<AdminController>();
  }

  /// `({filename, label, path})` tuples for all completed downloads.
  List<({String filename, String label, String path})> get sources {
    return _adminController.downloadedPaths.entries.map((entry) {
      return (
        filename: entry.key,
        label: _labelFor(entry.key),
        path: entry.value,
      );
    }).toList();
  }

  String _labelFor(String filename) {
    final info = _adminController.recordings.firstWhereOrNull(
      (r) => r.filename == filename,
    );
    if (info == null) return filename;
    final slot = _adminController.slots.firstWhereOrNull(
      (s) => s.peerId == info.peerId,
    );
    return slot?.deviceName ?? slot?.label ?? info.peerId.substring(0, 8);
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

  @override
  Future<void> onClose() async {
    if (isRendering.value) await cancelRender();
    super.onClose();
  }
}
