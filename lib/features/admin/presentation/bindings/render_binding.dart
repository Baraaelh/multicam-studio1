import 'package:get/get.dart';

import '../../../../core/di/injection.dart';
import '../../../../core/services/ffmpeg_service.dart';
import '../controllers/render_controller.dart';

class RenderBinding extends Bindings {
  @override
  void dependencies() {
    Get.lazyPut<RenderController>(
      () => RenderController(ffmpegService: getIt<FfmpegService>()),
      fenix: true,
    );
  }
}
