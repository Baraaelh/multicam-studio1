import 'package:get/get.dart';

import '../../../../core/di/injection.dart';
import '../../../../core/services/webrtc_service.dart';
import '../../../session/domain/repositories/signaling_repository.dart';
import '../../../session/presentation/bindings/signaling_binding.dart';
import '../../../session/presentation/controllers/clock_controller.dart';
import '../../../session/presentation/controllers/signaling_controller.dart';
import '../../domain/usecases/create_session.dart';
import '../../domain/usecases/end_session.dart';
import '../../domain/usecases/watch_device_name.dart';
import '../../../session/domain/repositories/recording_repository.dart';
import '../../../session/domain/usecases/watch_recordings.dart';
import '../controllers/admin_controller.dart';

class AdminBinding extends Bindings {
  @override
  void dependencies() {
    if (!Get.isRegistered<SignalingController>()) {
      SignalingBinding().dependencies();
    }

    Get.lazyPut<AdminController>(
      () => AdminController(
        createSession: getIt<CreateSession>(),
        endSession: getIt<EndSession>(),
        webRtcService: getIt<WebRtcService>(),
        signalingController: Get.find<SignalingController>(),
        watchDeviceName: WatchDeviceName(getIt<SignalingRepository>()),
        clockController: Get.find<ClockController>(),
        watchRecordings: WatchRecordings(getIt<RecordingRepository>()),
      ),
      fenix: true,
    );
  }
}
