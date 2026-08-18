import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:get_it/get_it.dart';

import '../platform/camera_service_platform.dart';
import '../services/clock_sync_service.dart';
import '../services/ffmpeg_service.dart';
import '../services/webrtc_service.dart';
import '../../features/camera/data/services/recording_service.dart';
import '../../features/camera/data/services/transfer_server_service.dart';
import '../../features/admin/data/datasources/session_remote_datasource.dart';
import '../../features/admin/data/repositories/session_repository_impl.dart';
import '../../features/admin/domain/repositories/session_repository.dart';
import '../../features/admin/domain/usecases/create_session.dart';
import '../../features/admin/domain/usecases/end_session.dart';
import '../../features/admin/domain/usecases/watch_device_name.dart';
import '../../features/camera/data/datasources/camera_local_datasource.dart';
import '../../features/camera/data/repositories/camera_repository_impl.dart';
import '../../features/camera/domain/repositories/camera_repository.dart';
import '../../features/camera/domain/usecases/parse_qr_payload.dart';
import '../../features/camera/domain/usecases/register_device.dart';
import '../../features/camera/domain/usecases/start_capture.dart';
import '../../features/camera/domain/usecases/stop_capture.dart';
import '../../features/camera/domain/usecases/switch_lens.dart';
import '../../features/session/data/datasources/signaling_remote_datasource.dart';
import '../../features/session/data/repositories/signaling_repository_impl.dart';
import '../../features/session/domain/repositories/signaling_repository.dart';
import '../../features/session/data/datasources/clock_remote_datasource.dart';
import '../../features/session/data/repositories/clock_repository_impl.dart';
import '../../features/session/domain/repositories/clock_repository.dart';
import '../../features/session/domain/usecases/clear_signaling.dart';
import '../../features/session/domain/usecases/lookup_session_code.dart';
import '../../features/session/domain/usecases/publish_command.dart';
import '../../features/session/domain/usecases/sync_clock.dart';
import '../../features/session/domain/usecases/watch_commands.dart';
import '../../features/session/domain/usecases/watch_peers.dart';
import '../../features/session/data/datasources/recording_remote_datasource.dart';
import '../../features/session/data/repositories/recording_repository_impl.dart';
import '../../features/session/domain/repositories/recording_repository.dart';
import '../../features/session/domain/usecases/publish_recording_info.dart';
import '../../features/session/domain/usecases/watch_recordings.dart';
import '../../features/session/domain/usecases/publish_answer.dart';
import '../../features/session/domain/usecases/publish_ice_candidate.dart';
import '../../features/session/domain/usecases/publish_offer.dart';
import '../../features/session/domain/usecases/watch_answer.dart';
import '../../features/session/domain/usecases/watch_ice_candidates.dart';
import '../../features/session/domain/usecases/watch_offer.dart';

final GetIt getIt = GetIt.instance;

void configureDependencies() {
  // External
  getIt.registerLazySingleton<FirebaseFirestore>(
    () => FirebaseFirestore.instance,
  );

  // Core services & platform
  getIt.registerLazySingleton<WebRtcService>(() => WebRtcService());
  getIt.registerLazySingleton<FfmpegService>(() => FfmpegService());
  getIt.registerLazySingleton<CameraServicePlatform>(
    () => CameraServicePlatform(),
  );
  getIt.registerLazySingleton<ClockSyncService>(
    () => ClockSyncService(firestore: getIt<FirebaseFirestore>()),
  );
  getIt.registerLazySingleton<RecordingService>(() => RecordingService());
  getIt.registerLazySingleton<TransferServer>(() => TransferServer());

  // --- Clock / timeline ---
  getIt.registerLazySingleton<ClockRemoteDataSource>(
    () => FirebaseClockDataSource(firestore: getIt<FirebaseFirestore>()),
  );
  getIt.registerLazySingleton<ClockRepository>(
    () => ClockRepositoryImpl(dataSource: getIt<ClockRemoteDataSource>()),
  );
  getIt.registerFactory(() => SyncClock(getIt<ClockSyncService>()));
  getIt.registerFactory(() => PublishCommand(getIt<ClockRepository>()));
  getIt.registerFactory(() => WatchCommands(getIt<ClockRepository>()));

  // --- Session (signaling) ---
  getIt.registerLazySingleton<SignalingRemoteDataSource>(
    () => FirebaseSignalingDataSource(firestore: getIt<FirebaseFirestore>()),
  );
  getIt.registerLazySingleton<SignalingRepository>(
    () => SignalingRepositoryImpl(
      dataSource: getIt<SignalingRemoteDataSource>(),
    ),
  );
  getIt.registerFactory(() => PublishOffer(getIt<SignalingRepository>()));
  getIt.registerFactory(() => PublishAnswer(getIt<SignalingRepository>()));
  getIt.registerFactory(() => WatchOffer(getIt<SignalingRepository>()));
  getIt.registerFactory(() => WatchAnswer(getIt<SignalingRepository>()));
  getIt.registerFactory(
    () => PublishIceCandidate(getIt<SignalingRepository>()),
  );
  getIt.registerFactory(
    () => WatchIceCandidates(getIt<SignalingRepository>()),
  );
  getIt.registerFactory(() => ClearSignaling(getIt<SignalingRepository>()));
  getIt.registerFactory(() => LookupSessionCode(getIt<SignalingRepository>()));
  getIt.registerFactory(() => WatchPeers(getIt<SignalingRepository>()));

  // --- Camera ---
  getIt.registerLazySingleton<CameraLocalDataSource>(
    () => CameraLocalDataSourceImpl(),
  );
  getIt.registerLazySingleton<CameraRepository>(
    () => CameraRepositoryImpl(dataSource: getIt<CameraLocalDataSource>()),
  );
  getIt.registerFactory(() => StartCapture(getIt<CameraRepository>()));
  getIt.registerFactory(() => StopCapture(getIt<CameraRepository>()));
  getIt.registerFactory(() => SwitchLens(getIt<CameraRepository>()));
  getIt.registerFactory(() => ParseQrPayload());
  getIt.registerFactory(() => RegisterDevice(
    signalingRepository: getIt<SignalingRepository>(),
    cameraDataSource: getIt<CameraLocalDataSource>(),
  ));

  // --- Recordings ---
  getIt.registerLazySingleton<RecordingRemoteDataSource>(
    () => FirebaseRecordingDataSource(firestore: getIt<FirebaseFirestore>()),
  );
  getIt.registerLazySingleton<RecordingRepository>(
    () => RecordingRepositoryImpl(
      dataSource: getIt<RecordingRemoteDataSource>(),
    ),
  );
  getIt.registerFactory(
    () => PublishRecordingInfo(getIt<RecordingRepository>()),
  );
  getIt.registerFactory(() => WatchRecordings(getIt<RecordingRepository>()));

  // --- Admin / session management ---
  getIt.registerLazySingleton<SessionRemoteDataSource>(
    () => FirebaseSessionDataSource(firestore: getIt<FirebaseFirestore>()),
  );
  getIt.registerLazySingleton<SessionRepository>(
    () => SessionRepositoryImpl(dataSource: getIt<SessionRemoteDataSource>()),
  );
  getIt.registerFactory(() => CreateSession(getIt<SessionRepository>()));
  getIt.registerFactory(() => EndSession(getIt<SessionRepository>()));
  getIt.registerFactory(
    () => WatchDeviceName(getIt<SignalingRepository>()),
  );
}
