import 'dart:async' show unawaited;
import 'dart:developer' as dev;

import 'package:flutter_webrtc/flutter_webrtc.dart' as webrtc;
import 'package:get/get.dart';

import '../../../../core/error/result.dart';
import '../../../../core/platform/camera_service_platform.dart';
import '../../../../core/services/webrtc_service.dart';
import '../../../session/domain/entities/recording_info.dart';
import '../../../session/domain/entities/sync_command.dart';
import '../../../session/domain/usecases/publish_recording_info.dart';
import '../../../session/presentation/controllers/clock_controller.dart';
import '../../../session/presentation/controllers/signaling_controller.dart';
import '../../data/services/recording_service.dart';
import '../../data/services/transfer_server_service.dart';
import '../../domain/entities/local_camera_state.dart';
import '../../domain/entities/qr_payload.dart';
import '../../domain/usecases/parse_qr_payload.dart';
import '../../domain/usecases/register_device.dart';
import '../../domain/usecases/start_capture.dart';
import '../../domain/usecases/stop_capture.dart';
import '../../domain/usecases/switch_lens.dart';

class CameraController extends GetxController {
  final StartCapture _startCapture;
  final StopCapture _stopCapture;
  final SwitchLens _switchLens;
  final ParseQrPayload _parseQrPayload;
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
    required ParseQrPayload parseQrPayload,
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
        _parseQrPayload = parseQrPayload,
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

  webrtc.MediaStream? _localStream;
  QrPayload? _payload;
  Worker? _commandWorker;

  @override
  Future<void> onInit() async {
    super.onInit();
    await localRenderer.initialize();
  }

  Future<Result<QrPayload>> parseQr(String rawValue) =>
      _parseQrPayload(rawValue);

  Future<void> startFromQr(QrPayload payload) async {
    _payload = payload;
    slotLabel.value = payload.label;
    sessionPin.value = payload.pin.isNotEmpty ? payload.pin : null;

    cameraState.value = const LocalCameraState(
      status: CameraStatus.requestingPermission,
    );

    // 1. Request permissions + open camera (getUserMedia).
    //    Permissions must be granted before starting the foreground service
    //    on API 34+ to avoid SecurityException.
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
    // Per-camera commands carry a targetPeerId — ignore if it's not us.
    if (cmd.targetPeerId != null && cmd.targetPeerId != _payload?.peerId) return;
    switch (cmd.type) {
      case CommandType.startRecording:
        isRecording.value = true;
        unawaited(_startRecording());
      case CommandType.stopRecording:
        isRecording.value = false;
        unawaited(_stopAndPublish());
      case CommandType.muteCamera:
        _setAudioMuted(true);
      case CommandType.unmuteCamera:
        _setAudioMuted(false);
      case CommandType.setZoom:
        final level = (cmd.payload?['zoom'] as num?)?.toDouble() ?? 1.0;
        unawaited(_applyZoom(level));
    }
  }

  void _setAudioMuted(bool muted) {
    final stream = _localStream;
    if (stream == null) return;
    for (final track in stream.getAudioTracks()) {
      track.enabled = !muted;
    }
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

  Future<void> _startRecording() async {
    final stream = _localStream;
    final payload = _payload;
    if (stream == null || payload == null) return;
    await _recordingService.startRecording(
      stream: stream,
      peerId: payload.peerId,
    );
  }

  Future<void> _stopAndPublish() async {
    final file = await _recordingService.stopRecording();
    final payload = _payload;
    if (file == null || payload == null) {
      dev.log(
        '_stopAndPublish: aborted — file=$file payload=$payload',
        name: 'CameraController',
      );
      return;
    }

    dev.log(
      '_stopAndPublish: file=${file.path} size=${await file.length()}',
      name: 'CameraController',
    );

    final ip = await TransferServer.getLanIp();
    if (ip == null) {
      dev.log('_stopAndPublish: no LAN IP — aborting publish', name: 'CameraController');
      return;
    }

    final filename = file.uri.pathSegments.last;
    final sizeBytes = await file.length();

    // Register BEFORE publishing so the server is ready when admin requests.
    _transferServer.register(filename, file.path);

    final downloadUrl = 'http://$ip:${TransferServer.port}/$filename';
    dev.log(
      '_stopAndPublish: publishing URL=$downloadUrl  size=$sizeBytes  serverRunning=${_transferServer.isRunning}',
      name: 'CameraController',
    );

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
        Get.snackbar(
          'Transfer Error',
          'Could not publish recording info: ${f.message}',
          snackPosition: SnackPosition.BOTTOM,
        );
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

    // replaceTrack does not renegotiate SDP — safe to call on a live connection.
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
    sessionPin.value = null;
    slotLabel.value = '';
    isRecording.value = false;

    _commandWorker?.dispose();
    _commandWorker = null;
    _clockController.stopWatchingCommands();

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
