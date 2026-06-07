import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

// ignore_for_file: unawaited_futures

import 'package:flutter_webrtc/flutter_webrtc.dart' as webrtc;
import 'package:get/get.dart';
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import '../../../../core/services/webrtc_service.dart';
import '../../../session/domain/entities/peer_connection_state.dart';
import '../../../session/domain/entities/recording_info.dart';
import '../../../session/domain/entities/sync_command.dart';
import '../../../session/domain/usecases/watch_recordings.dart';
import '../../../session/presentation/controllers/clock_controller.dart';
import '../../../session/presentation/controllers/signaling_controller.dart';
import '../../domain/entities/camera_slot.dart';
import '../../domain/entities/session.dart';
import '../../domain/usecases/create_session.dart';
import '../../domain/usecases/end_session.dart';
import '../../domain/usecases/watch_device_name.dart';

class AdminController extends GetxController {
  final CreateSession _createSession;
  final EndSession _endSession;
  final WebRtcService _webRtcService;
  final SignalingController _signalingController;
  final WatchDeviceName _watchDeviceName;
  final ClockController _clockController;
  final WatchRecordings _watchRecordings;

  AdminController({
    required CreateSession createSession,
    required EndSession endSession,
    required WebRtcService webRtcService,
    required SignalingController signalingController,
    required WatchDeviceName watchDeviceName,
    required ClockController clockController,
    required WatchRecordings watchRecordings,
  })  : _createSession = createSession,
        _endSession = endSession,
        _webRtcService = webRtcService,
        _signalingController = signalingController,
        _watchDeviceName = watchDeviceName,
        _clockController = clockController,
        _watchRecordings = watchRecordings;

  static const _maxSlots = 4;
  final _uuid = const Uuid();
  final _random = Random();

  // --- Observable state ---
  final session = Rx<Session?>(null);
  final slots = RxList<CameraSlot>();
  final renderers = <String, webrtc.RTCVideoRenderer>{}.obs;
  final activePeerId = Rx<String?>(null);
  final isStarting = false.obs;
  final isRecording = false.obs;
  final qrData = <String, String>{}.obs; // peerId → JSON
  final recordings = RxList<RecordingInfo>();
  final downloadProgress = <String, double>{}.obs; // filename → 0.0..1.0
  final downloadedPaths = <String, String>{}.obs;  // filename → local path

  // --- Internals ---
  late final String _adminId;
  final _slotPins = <String, String>{};
  final _deviceNameSubs = <String, StreamSubscription<String?>>{};
  StreamSubscription<RemoteStreamEvent>? _remoteStreamSub;
  StreamSubscription<List<RecordingInfo>>? _recordingSub;
  Worker? _peerStatusWorker;

  @override
  void onInit() {
    super.onInit();
    _adminId = _uuid.v4();
    _remoteStreamSub =
        _webRtcService.remoteStreamStream.listen(_onRemoteStream);
    _peerStatusWorker = ever(
      _signalingController.peers,
      _syncPeerStatuses,
    );
  }

  String get adminId => _adminId;

  // ---------------------------------------------------------------------------
  // Setup phase
  // ---------------------------------------------------------------------------

  Future<void> createSession() async {
    final result =
        await _createSession(CreateSessionParams(adminId: _adminId));
    result.fold(
      onSuccess: (id) => session.value = Session(
        sessionId: id,
        adminId: _adminId,
        status: SessionStatus.waiting,
      ),
      onFailure: (f) => Get.snackbar(
        'Error',
        f.message,
        snackPosition: SnackPosition.BOTTOM,
      ),
    );
  }

  void addCameraSlot() {
    if (slots.length >= _maxSlots || session.value == null) return;
    final n = slots.length + 1;
    final peerId = _uuid.v4();
    slots.add(CameraSlot(peerId: peerId, label: 'Camera $n'));
    _refreshQrData(peerId);
  }

  void removeSlot(String peerId) {
    slots.removeWhere((s) => s.peerId == peerId);
    qrData.remove(peerId);
    _slotPins.remove(peerId);
    _deviceNameSubs.remove(peerId)?.cancel();
  }

  /// Returns the 6-digit verification PIN for the given slot.
  String pinFor(String peerId) => _slotPins[peerId] ?? '';

  /// Invalidates the current PIN and regenerates QR data with a fresh expiry.
  void refreshQrFor(String peerId) {
    _slotPins.remove(peerId);
    _refreshQrData(peerId);
  }

  // ---------------------------------------------------------------------------
  // Live phase
  // ---------------------------------------------------------------------------

  Future<void> startSession() async {
    final s = session.value;
    if (s == null || slots.isEmpty) return;
    isStarting.value = true;

    await Future.wait(
      slots.map(
        (slot) => _signalingController.connectToCamera(
          s.sessionId,
          slot.peerId,
          slot.label,
        ),
      ),
    );

    for (final slot in List.of(slots)) {
      _watchDeviceNameFor(s.sessionId, slot.peerId);
    }

    // Sync admin clock after going live so sync quality is shown in UI.
    unawaited(_clockController.sync());

    _watchRecordingsFor(s.sessionId);

    session.value = s.copyWith(status: SessionStatus.live);
    isStarting.value = false;
  }

  /// Issues a synchronized start-recording command to all cameras.
  /// Cameras will begin recording 3 seconds after issuedAt (server time).
  Future<void> issueStartRecording() async {
    final s = session.value;
    if (s == null) return;
    await _clockController.issueCommand(
      s.sessionId,
      CommandType.startRecording,
    );
    isRecording.value = true;
  }

  /// Issues a synchronized stop-recording command to all cameras.
  Future<void> issueStopRecording() async {
    final s = session.value;
    if (s == null) return;
    await _clockController.issueCommand(
      s.sessionId,
      CommandType.stopRecording,
      bufferMs: 1000,
    );
    isRecording.value = false;
  }

  /// Downloads a camera recording file from the camera device over LAN HTTP.
  Future<void> downloadRecording(RecordingInfo info) async {
    if (downloadProgress.containsKey(info.filename)) return;
    downloadProgress[info.filename] = 0.0;
    try {
      final dir = await getApplicationDocumentsDirectory();
      final savePath = '${dir.path}/${info.filename}';
      final client = HttpClient();
      final request = await client.getUrl(Uri.parse(info.downloadUrl));
      final response = await request.close();
      final total = response.contentLength;
      var received = 0;
      final sink = File(savePath).openWrite();
      await for (final chunk in response) {
        sink.add(chunk);
        received += chunk.length;
        if (total > 0) downloadProgress[info.filename] = received / total;
      }
      await sink.close();
      client.close();
      downloadedPaths[info.filename] = savePath;
      downloadProgress.remove(info.filename);
    } catch (e) {
      downloadProgress.remove(info.filename);
      Get.snackbar(
        'Download Failed',
        e.toString(),
        snackPosition: SnackPosition.BOTTOM,
      );
    }
  }

  /// P2P Active Stream Switching: swap which renderer is shown full-screen.
  /// Remote receivers on all peer connections remain active — no renegotiation.
  void switchActiveCamera(String peerId) {
    _signalingController.switchActiveCamera(peerId);
    activePeerId.value = peerId;
  }

  Future<void> endSession() async {
    final s = session.value;
    if (s == null) return;

    if (isRecording.value) await issueStopRecording();

    await Future.wait(
      slots.map(
        (slot) =>
            _signalingController.disconnect(s.sessionId, slot.peerId),
      ),
    );

    await _endSession(EndSessionParams(sessionId: s.sessionId));

    for (final r in renderers.values) {
      await r.dispose();
    }
    for (final sub in _deviceNameSubs.values) {
      sub.cancel();
    }
    _deviceNameSubs.clear();
    _recordingSub?.cancel();
    _recordingSub = null;

    renderers.clear();
    slots.clear();
    qrData.clear();
    _slotPins.clear();
    recordings.clear();
    downloadProgress.clear();
    downloadedPaths.clear();
    session.value = null;
    activePeerId.value = null;
    isRecording.value = false;
  }

  // ---------------------------------------------------------------------------
  // Internal handlers
  // ---------------------------------------------------------------------------

  Future<void> _onRemoteStream(RemoteStreamEvent event) async {
    if (renderers.containsKey(event.peerId)) {
      renderers[event.peerId]!.srcObject = event.stream;
      return;
    }
    final renderer = webrtc.RTCVideoRenderer();
    await renderer.initialize();
    renderer.srcObject = event.stream;
    renderers[event.peerId] = renderer;
    if (activePeerId.value == null) activePeerId.value = event.peerId;
  }

  void _syncPeerStatuses(Map<String, PeerConnectionState> peers) {
    for (var i = 0; i < slots.length; i++) {
      final peerState = peers[slots[i].peerId];
      if (peerState != null &&
          peerState.status != slots[i].connectionStatus) {
        slots[i] = slots[i].copyWith(connectionStatus: peerState.status);
      }
    }
  }

  void _watchDeviceNameFor(String sessionId, String peerId) {
    _deviceNameSubs[peerId]?.cancel();
    _deviceNameSubs[peerId] = _watchDeviceName(
      WatchDeviceNameParams(sessionId: sessionId, peerId: peerId),
    ).where((name) => name != null && name.isNotEmpty).listen((deviceName) {
      final idx = slots.indexWhere((s) => s.peerId == peerId);
      if (idx >= 0) slots[idx] = slots[idx].copyWith(deviceName: deviceName);
    });
  }

  void _watchRecordingsFor(String sessionId) {
    _recordingSub?.cancel();
    _recordingSub = _watchRecordings(
      WatchRecordingsParams(sessionId: sessionId),
    ).listen((list) => recordings.assignAll(list));
  }

  void _refreshQrData(String peerId) {
    final s = session.value;
    if (s == null) return;
    final slot = slots.firstWhereOrNull((slot) => slot.peerId == peerId);
    if (slot == null) return;

    final pin = _slotPins.putIfAbsent(peerId, _generatePin);
    final expiresAt = DateTime.now()
        .add(const Duration(minutes: 10))
        .millisecondsSinceEpoch;

    qrData[peerId] = jsonEncode({
      'sessionId': s.sessionId,
      'peerId': peerId,
      'adminId': _adminId,
      'label': slot.label,
      'expiresAt': expiresAt,
      'pin': pin,
    });
  }

  String _generatePin() =>
      (100000 + _random.nextInt(900000)).toString();

  @override
  Future<void> onClose() async {
    _remoteStreamSub?.cancel();
    _peerStatusWorker?.dispose();
    _recordingSub?.cancel();
    for (final sub in _deviceNameSubs.values) {
      sub.cancel();
    }
    for (final r in renderers.values) {
      await r.dispose();
    }
    super.onClose();
  }
}
