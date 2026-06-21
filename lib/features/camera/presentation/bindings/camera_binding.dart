import 'package:get/get.dart';

import '../../../../core/di/injection.dart';
import '../../../../core/platform/camera_service_platform.dart';
import '../../../../core/services/webrtc_service.dart';
import '../../../session/domain/repositories/signaling_repository.dart';
import '../../../session/domain/usecases/lookup_session_code.dart';
import '../../../session/presentation/bindings/signaling_binding.dart';
import '../../../session/presentation/controllers/clock_controller.dart';
import '../../../session/presentation/controllers/signaling_controller.dart';
import '../../data/datasources/camera_local_datasource.dart';
import '../../data/services/recording_service.dart';
import '../../data/services/transfer_server_service.dart';
import '../../domain/usecases/register_device.dart';
import '../../domain/usecases/start_capture.dart';
import '../../domain/usecases/stop_capture.dart';
import '../../domain/usecases/switch_lens.dart';
import '../../../session/domain/usecases/publish_recording_info.dart';
import '../controllers/camera_controller.dart';

class CameraBinding extends Bindings {
  @override
  void dependencies() {
    if (!Get.isRegistered<SignalingController>()) {
      SignalingBinding().dependencies();
    }

    Get.lazyPut<CameraController>(
      () => CameraController(
        startCapture: getIt<StartCapture>(),
        stopCapture: getIt<StopCapture>(),
        switchLens: getIt<SwitchLens>(),
        lookupSessionCode: LookupSessionCode(getIt<SignalingRepository>()),
        registerDevice: RegisterDevice(
          signalingRepository: getIt<SignalingRepository>(),
          cameraDataSource: getIt<CameraLocalDataSource>(),
        ),
        webRtcService: getIt<WebRtcService>(),
        signalingController: Get.find<SignalingController>(),
        servicePlatform: getIt<CameraServicePlatform>(),
        clockController: Get.find<ClockController>(),
        recordingService: RecordingService(),
        transferServer: TransferServer(),
        publishRecordingInfo: getIt<PublishRecordingInfo>(),
      ),
      fenix: true,
    );
  }
}
