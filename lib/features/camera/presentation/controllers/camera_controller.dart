import 'dart:async' show unawaited;
import 'dart:developer' as dev;

import 'package:flutter_webrtc/flutter_webrtc.dart' as webrtc;
import 'package:get/get.dart';
import 'package:uuid/uuid.dart';

import '../../../../core/error/result.dart';
import '../../../../core/platform/camera_service_platform.dart';
import '../../../../core/services/webrtc_service.dart';
import '../../../session/domain/entities/recording_info.dart';
import '../../../session/domain/entities/recording_profile.dart';
import '../../../session/domain/entities/sync_command.dart';
import '../../../session/domain/usecases/lookup_session_code.dart';
import '../../../session/domain/usecases/publish_recording_info.dart';
import '../../../session/presentation/controllers/clock_controller.dart';
import '../../../session/presentation/controllers/signaling_controller.dart';
import '../../data/services/recording_service.dart';
import '../../data/services/transfer_server_service.dart';
import '../../domain/entities/local_camera_state.dart';
import '../../domain/entities/qr_payload.dart';
import '../../domain/usecases/register_device.dart';
import '../../domain/usecases/start_capture.dart';
import '../../domain/usecases/stop_capture.dart';
import '../../domain/usecases/switch_lens.dart';

/// CameraController manages the local camera device.
/// Records locally using the native MethodChannel (I420VideoRecorder).
class CameraController extends GetxController {
  final StartCapture _startCapture;
  final StopCapture _stopCapture;
  final SwitchLens _switchLens;
  final LookupSessionCode _lookupSessionCode;
  final RegisterDevice _registerDevice;
  final WebRtcService _webRtcService;
  final SignalingController _signalingController;
  final CameraServicePlatform _servicePlatform;
  final ClockController _clockController;
  final RecordingService _recordingService;
  final TransferServer _transferServer;
  final PublishRecordingInfo _publishRecordingInfo;

  CameraController({
    required StartCapture startCapture,
    required StopCapture stopCapture,
    required SwitchLens switchLens,
    required LookupSessionCode lookupSessionCode,
    required RegisterDevice registerDevice,
    required WebRtcService webRtcService,
    required SignalingController signalingController,
    required CameraServicePlatform servicePlatform,
    required ClockController clockController,
    required RecordingService recordingService,
    required TransferServer transferServer,
    required PublishRecordingInfo publishRecordingInfo,
  })  : _startCapture = startCapture,
        _stopCapture = stopCapture,
        _switchLens = switchLens,
        _lookupSessionCode = lookupSessionCode,
        _registerDevice = registerDevice,
        _webRtcService = webRtcService,
        _signalingController = signalingController,
        _servicePlatform = servicePlatform,
        _clockController = clockController,
        _recordingService = recordingService,
        _transferServer = transferServer,
        _publishRecordingInfo = publishRecordingInfo;

  final localRenderer = webrtc.RTCVideoRenderer();
  final cameraState = Rx<LocalCameraState>(
    const LocalCameraState(status: CameraStatus.idle),
  );
  final slotLabel = ''.obs;
  final sessionPin = Rx<String?>(null);
  final isRecording = false.obs;
  final isPaused = false.obs;
  final isCoAdmin = false.obs;
  final coAdminSlots = RxList<Map<String, String>>();
  final isStudioMode = false.obs;

  webrtc.MediaStream? _localStream;
  QrPayload? _payload;
  Worker? _commandWorker;
  String? _expectedPin;

  @override
  Future<void> onInit() async {
    super.onInit();
    await localRenderer.initialize();
  }

  /// Looks up [code] in Firebase and returns a [QrPayload] with an
  /// auto-generated peerId. On success, call [startFromQr] with the payload.
  Future<Result<QrPayload>> resolveSessionCode(String code) async {
    final result = await _lookupSessionCode(code);
    if (result.isFailure) return Failure(result.failureOrNull!);
    final sessionId = result.valueOrNull!;
    // Store the expected PIN for verification in startFromQr.
    _expectedPin = code;
    return Success(QrPayload(
      sessionId: sessionId,
      peerId: const Uuid().v4(),
      adminId: '',
      label: 'Camera',
      // The 6-digit code itself serves as the PIN for code-based join.
      // This lets the camera display it for verification while the admin
      // confirms the code matches the session.
      pin: code,
    ));
  }

  Future<void> startFromQr(QrPayload payload) async {
    // Verify PIN if provided — prevents joining with a mismatched code.
    if (payload.pin.isNotEmpty && _expectedPin != null && payload.pin != _expectedPin) {
      cameraState.value = LocalCameraState(
        status: CameraStatus.error,
        errorMessage: 'Invalid PIN. Please re-enter the session code.',
      );
      return;
    }
    _payload = payload;
    slotLabel.value = payload.label;
    sessionPin.value = payload.pin.isNotEmpty ? payload.pin : null;

    cameraState.value = const LocalCameraState(
      status: CameraStatus.requestingPermission,
    );

    // 1. Request permissions + open camera (getUserMedia).
    final captureResult = await _startCapture(
      StartCaptureParams(lens: LensDirection.back),
    );

    if (captureResult.isFailure) {
      cameraState.value = LocalCameraState(
        status: CameraStatus.error,
        errorMessage: captureResult.failureOrNull?.message,
      );
      return;
    }

    // 2. Permissions granted — start foreground service + LAN transfer server.
    cameraState.value = const LocalCameraState(status: CameraStatus.starting);
    await Future.wait([
      _servicePlatform.start(),
      _transferServer.start(),
    ]);

    // 3. Wire up local renderer for preview.
    _localStream = captureResult.valueOrNull!;
    localRenderer.srcObject = _localStream;
    cameraState.value = const LocalCameraState(
      status: CameraStatus.active,
      lens: LensDirection.back,
    );

    // 4. Pre-add tracks BEFORE joinSession so the SDP answer includes the
    //    camera's audio/video m-lines.
    await _webRtcService.prepareForIncomingCall(payload.peerId, _localStream!);

    // 5. Sync clock with Firebase server time before watching commands.
    unawaited(_clockController.sync());

    // 6. Start signaling — watch for Admin's offer.
    await _signalingController.joinSession(
      payload.sessionId,
      payload.peerId,
      payload.label,
    );

    // 7. Register device model with Firestore so Admin sees actual hardware name.
    unawaited(
      _registerDevice(
        RegisterDeviceParams(
          sessionId: payload.sessionId,
          peerId: payload.peerId,
        ),
      ),
    );

    // 8. Start watching for Admin commands (record start/stop).
    _clockController.startWatchingCommands(payload.sessionId);
    _commandWorker = ever(_clockController.pendingCommand, _onCommand);
  }

  void _onCommand(SyncCommand? cmd) {
    if (cmd == null) return;
    if (cmd.targetPeerId != null && cmd.targetPeerId != _payload?.peerId) return;
    switch (cmd.type) {
      case CommandType.startRecording:
        isRecording.value = true;
        if (cmd.payload?['studioMode'] == true) isStudioMode.value = true;
        final profile = _profileFromPayload(cmd.payload);
        unawaited(_startRecording(profile: profile));
      case CommandType.stopRecording:
        isRecording.value = false;
        unawaited(_stopAndPublish());
      case CommandType.muteCamera:
        unawaited(_setAudioMuted(true));
      case CommandType.unmuteCamera:
        unawaited(_setAudioMuted(false));
      case CommandType.setZoom:
        final level = (cmd.payload?['zoom'] as num?)?.toDouble() ?? 1.0;
        unawaited(_applyZoom(level));
      case CommandType.pauseCamera:
        isPaused.value = true;
        _setVideoPaused(true);
      case CommandType.resumeCamera:
        isPaused.value = false;
        _setVideoPaused(false);
      case CommandType.promoteToCoAdmin:
        isCoAdmin.value = true;
        final rawSlots = cmd.payload?['slots'] as List<dynamic>? ?? [];
        coAdminSlots.assignAll(
          rawSlots
              .whereType<Map<String, dynamic>>()
              .map((s) => {
                    'peerId': s['peerId']?.toString() ?? '',
                    'label': s['label']?.toString() ?? '',
                  })
              .where((s) => s['peerId']!.isNotEmpty)
              .toList(),
        );
      case CommandType.revokeCoAdmin:
        isCoAdmin.value = false;
        coAdminSlots.clear();
      case CommandType.switchActiveCamera:
        // Co-admin switching is handled by the Admin side. On the camera side
        // there's nothing to do — the camera keeps streaming regardless of
        // which camera is currently on air.
        break;
    }
  }

  Future<void> _setAudioMuted(bool muted) async {
    final stream = _localStream;
    if (stream != null) {
      for (final track in stream.getAudioTracks()) {
        track.enabled = !muted;
      }
    }
    final peerId = _payload?.peerId;
    if (peerId != null) {
      await _webRtcService.setAudioSenderEnabled(peerId, !muted);
    }
  }

  void _setVideoPaused(bool paused) {
    final stream = _localStream;
    if (stream == null) return;
    for (final track in stream.getVideoTracks()) {
      track.enabled = !paused;
    }
  }

  Future<void> switchCameraForAdmin(String targetPeerId) async {
    final payload = _payload;
    if (payload == null || !isCoAdmin.value) return;
    await _clockController.issueCommand(
      payload.sessionId,
      CommandType.switchActiveCamera,
      bufferMs: 0,
      payload: {'peerId': targetPeerId},
    );
  }

  Future<void> _applyZoom(double zoomLevel) async {
    final stream = _localStream;
    if (stream == null) return;
    try {
      for (final track in stream.getVideoTracks()) {
        await webrtc.Helper.setZoom(track, zoomLevel);
      }
    } catch (e) {
      dev.log('_applyZoom failed: $e', name: 'CameraController');
    }
  }

  static RecordingProfile? _profileFromPayload(Map<String, dynamic>? p) {
    if (p == null) return null;
    final w = (p['width'] as num?)?.toInt();
    final h = (p['height'] as num?)?.toInt();
    final fps = (p['frameRate'] as num?)?.toInt();
    if (w == null || h == null || fps == null) return null;
    return RecordingProfile(
      width: w,
      height: h,
      frameRate: fps,
      codec: p['codec'] as String? ?? 'H264',
    );
  }

  Future<void> _startRecording({RecordingProfile? profile}) async {
    final stream = _localStream;
    final payload = _payload;
    if (stream == null || payload == null) return;

    // Use the profile selected by the Admin when available. The Admin sends
    // the selected profile in the startRecording command payload. If no
    // profile was provided, fall back to a lower resolution to avoid
    // double-encoding bottleneck — the Admin records the full-quality remote
    // WebRTC stream for the final merge, and the camera's local file is only
    // used as a fallback source in the merge pipeline.
    final localProfile = profile ??
        const RecordingProfile(
          width: 640,
          height: 480,
          frameRate: 15,
          codec: 'H264',
        );

    await _recordingService.startRecording(
      stream: stream,
      peerId: payload.peerId,
      recordAudio: !isStudioMode.value,
      profile: localProfile,
    );
  }

  Future<void> _stopAndPublish() async {
    final file = await _recordingService.stopRecording();
    final payload = _payload;
    if (file == null || payload == null) {
      dev.log('_stopAndPublish: aborted — file=$file payload=$payload', name: 'CameraController');
      return;
    }

    dev.log('_stopAndPublish: file=${file.path} size=${await file.length()}', name: 'CameraController');

    final ip = await TransferServer.getLanIp();
    if (ip == null) {
      dev.log('_stopAndPublish: no LAN IP — aborting publish', name: 'CameraController');
      return;
    }

    final filename = file.uri.pathSegments.last;
    final sizeBytes = await file.length();

    _transferServer.register(filename, file.path);

    final downloadUrl = 'http://$ip:${TransferServer.port}/$filename';
    dev.log('_stopAndPublish: publishing URL=$downloadUrl  size=$sizeBytes', name: 'CameraController');

    final result = await _publishRecordingInfo(
      PublishRecordingInfoParams(
        sessionId: payload.sessionId,
        info: RecordingInfo(
          peerId: payload.peerId,
          filename: filename,
          localIp: ip,
          port: TransferServer.port,
          sizeBytes: sizeBytes,
          recordedAt: DateTime.now(),
        ),
      ),
    );
    result.fold(
      onSuccess: (_) => dev.log('_stopAndPublish: Firestore publish OK', name: 'CameraController'),
      onFailure: (f) {
        dev.log('_stopAndPublish: Firestore publish FAILED — ${f.message}', name: 'CameraController');
        Get.snackbar('Transfer Error', 'Could not publish recording info: ${f.message}',
            snackPosition: SnackPosition.BOTTOM);
      },
    );
  }

  Future<void> switchLens() async {
    final stream = _localStream;
    final payload = _payload;
    if (stream == null || payload == null) return;

    final currentLens = cameraState.value.lens;
    final newLens = currentLens == LensDirection.back
        ? LensDirection.front
        : LensDirection.back;

    cameraState.value = cameraState.value.copyWith(
      status: CameraStatus.switchingLens,
    );

    final result = await _switchLens(
      SwitchLensParams(currentStream: stream, to: newLens),
    );

    if (result.isFailure) {
      cameraState.value = cameraState.value.copyWith(
        status: CameraStatus.active,
      );
      return;
    }

    _localStream = result.valueOrNull!;
    localRenderer.srcObject = _localStream;

    final videoTrack = _localStream!.getVideoTracks().firstOrNull;
    if (videoTrack != null) {
      await _webRtcService.replaceVideoTrack(payload.peerId, videoTrack);
    }

    cameraState.value = LocalCameraState(
      status: CameraStatus.active,
      lens: newLens,
    );
  }

  Future<void> disconnect() async {
    final payload = _payload;
    if (payload == null) return;
    _payload = null;
    _expectedPin = null;
    sessionPin.value = null;
    slotLabel.value = '';
    isRecording.value = false;

    _commandWorker?.dispose();
    _commandWorker = null;
    _clockController.stopWatchingCommands();

    isPaused.value = false;
    isCoAdmin.value = false;
    coAdminSlots.clear();
    isStudioMode.value = false;

    await _recordingService.dispose();
    await _signalingController.disconnect(payload.sessionId, payload.peerId);

    final stream = _localStream;
    if (stream != null) {
      await _stopCapture(StopCaptureParams(stream: stream));
      _localStream = null;
      localRenderer.srcObject = null;
    }

    await Future.wait([
      _servicePlatform.stop(),
      _transferServer.stop(),
    ]);
    cameraState.value = const LocalCameraState(status: CameraStatus.idle);
  }

  @override
  Future<void> onClose() async {
    _commandWorker?.dispose();
    await disconnect();
    await localRenderer.dispose();
    super.onClose();
  }
}