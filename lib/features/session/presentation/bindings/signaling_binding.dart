import 'package:get/get.dart';

import '../../../../core/di/injection.dart';
import '../../../../core/services/clock_sync_service.dart';
import '../../../../core/services/webrtc_service.dart';
import '../../domain/usecases/clear_signaling.dart';
import '../../domain/usecases/publish_answer.dart';
import '../../domain/usecases/publish_command.dart';
import '../../domain/usecases/publish_ice_candidate.dart';
import '../../domain/usecases/publish_offer.dart';
import '../../domain/usecases/sync_clock.dart';
import '../../domain/usecases/watch_answer.dart';
import '../../domain/usecases/watch_commands.dart';
import '../../domain/usecases/watch_ice_candidates.dart';
import '../../domain/usecases/watch_offer.dart';
import '../controllers/clock_controller.dart';
import '../controllers/signaling_controller.dart';

class SignalingBinding extends Bindings {
  @override
  void dependencies() {
    Get.lazyPut<SignalingController>(
      () => SignalingController(
        webRtcService: getIt<WebRtcService>(),
        publishOffer: getIt<PublishOffer>(),
        publishAnswer: getIt<PublishAnswer>(),
        watchOffer: getIt<WatchOffer>(),
        watchAnswer: getIt<WatchAnswer>(),
        publishIceCandidate: getIt<PublishIceCandidate>(),
        watchIceCandidates: getIt<WatchIceCandidates>(),
        clearSignaling: getIt<ClearSignaling>(),
      ),
    );

    Get.lazyPut<ClockController>(
      () => ClockController(
        syncClock: getIt<SyncClock>(),
        publishCommand: getIt<PublishCommand>(),
        watchCommands: getIt<WatchCommands>(),
        clockSyncService: getIt<ClockSyncService>(),
      ),
      fenix: true,
    );
  }
}
