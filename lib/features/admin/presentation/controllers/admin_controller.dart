import 'dart:async';
import 'dart:convert';
import 'dart:developer' as dev;
import 'dart:io';
import 'dart:math';

// ignore_for_file: unawaited_futures

import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as webrtc;
import 'package:get/get.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:uuid/uuid.dart';

import '../../../../core/services/webrtc_service.dart';
import '../../../session/domain/entities/peer_connection_state.dart';
import '../../../session/domain/entities/recording_info.dart';
import '../../../session/domain/entities/switch_event.dart';
import '../../../session/domain/entities/sync_command.dart';
import '../../../session/domain/usecases/watch_peers.dart';
import '../../../session/domain/usecases/watch_recordings.dart';
import '../../../session/presentation/controllers/clock_controller.dart';
import '../../../session/presentation/controllers/signaling_controller.dart';
import '../../domain/entities/camera_slot.dart';
import '../../domain/entities/session.dart';
import '../../domain/repositories/session_repository.dart';
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
  final WatchPeers _watchPeers;
  final SessionRepository _sessionRepository;

  AdminController({
    required CreateSession createSession,
    required EndSession endSession,
    required WebRtcService webRtcService,
    required SignalingController signalingController,
    required WatchDeviceName watchDeviceName,
    required ClockController clockController,
    required WatchRecordings watchRecordings,
    required WatchPeers watchPeers,
    required SessionRepository sessionRepository,
  })  : _createSession = createSession,
        _endSession = endSession,
        _webRtcService = webRtcService,
        _signalingController = signalingController,
        _watchDeviceName = watchDeviceName,
        _clockController = clockController,
        _watchRecordings = watchRecordings,
        _watchPeers = watchPeers,
        _sessionRepository = sessionRepository;

  static const _maxSlots = 8;
  final _uuid = const Uuid();
  final _random = Random();

  // --- Observable state ---
  final session = Rx<Session?>(null);
  final sessionCode = ''.obs;
  final slots = RxList<CameraSlot>();
  final renderers = <String, webrtc.RTCVideoRenderer>{}.obs;
  final activePeerId = Rx<String?>(null);
  final isStarting = false.obs;
  final isRecording = false.obs;
  final recordings = RxList<RecordingInfo>();
  final downloadProgress = <String, double>{}.obs;
  final downloadedPaths = <String, String>{}.obs;
  final downloadFailed = <String, RecordingInfo>{}.obs;
  final autoDownloading = false.obs;

  // Per-camera controls (peerId → state)
  final mutedCameras = <String, bool>{}.obs;
  final zoomLevels = <String, double>{}.obs;
  final pausedCameras = <String, bool>{}.obs;

  // Co-admin role tracking
  final coAdminPeerIds = RxSet<String>();

  // Recording timer
  final recordingSeconds = 0.obs;
  Timer? _recordingTimer;

  // Timeline tracking for timeline-based render
  final switchHistory = RxList<SwitchEvent>();
  DateTime? _recordingStartedAt;
  DateTime? _recordingStoppedAt;
  // Per-camera actual recording start (differs for late-joining cameras)
  final _cameraRecordingStartAt = <String, DateTime>{};

  // Auto-download state (set on Stop Recording, cleared when all files settle)
  bool _autoDownloadEnabled = false;

  // --- Internals ---
  late final String _adminId;
  final _deviceNameSubs = <String, StreamSubscription<String?>>{};
  StreamSubscription<RemoteStreamEvent>? _remoteStreamSub;
  StreamSubscription<List<RecordingInfo>>? _recordingSub;
  StreamSubscription<List<({String peerId, String? deviceName})>>? _peerListSub;
  Worker? _peerStatusWorker;
  Worker? _switchWorker;

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
    // Watch pendingCommand to process co-admin camera-switch requests.
    _switchWorker = ever(_clockController.pendingCommand, _onCoAdminCommand);
    // Attempt to restore a previous session if the app was killed mid-recording.
    unawaited(_tryRecoverFromDisk());
  }

  String get adminId => _adminId;

  // ---------------------------------------------------------------------------
  // Setup phase
  // ---------------------------------------------------------------------------

  Future<void> createSession() async {
    final code = _generateSessionCode();
    final result = await _createSession(
      CreateSessionParams(adminId: _adminId, code: code),
    );
    result.fold(
      onSuccess: (id) {
        session.value = Session(
          sessionId: id,
          adminId: _adminId,
          status: SessionStatus.waiting,
        );
        sessionCode.value = code;
        unawaited(_saveSessionToDisk(id, _adminId));
      },
      onFailure: (f) => Get.snackbar(
        'Error',
        f.message,
        snackPosition: SnackPosition.BOTTOM,
      ),
    );
  }

  Future<void> shareCode() async {
    final code = sessionCode.value;
    if (code.isEmpty) return;
    await Share.share('Join my Multicam Studio session. Code: $code');
  }

  Future<void> copyCode() async {
    final code = sessionCode.value;
    if (code.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: code));
    Get.snackbar(
      'Copied!',
      'Session code $code copied to clipboard',
      snackPosition: SnackPosition.BOTTOM,
      duration: const Duration(seconds: 2),
    );
  }

  // ---------------------------------------------------------------------------
  // Live phase
  // ---------------------------------------------------------------------------

  Future<void> startSession() async {
    final s = session.value;
    if (s == null) return;
    isStarting.value = true;

    unawaited(_clockController.sync());
    _watchRecordingsFor(s.sessionId);
    _clockController.startWatchingCommands(s.sessionId);
    // Detect cameras joining via code (fires immediately with existing peers).
    _watchPeerList(s.sessionId);

    session.value = s.copyWith(status: SessionStatus.live);
    isStarting.value = false;
  }

  /// Adds a new camera slot and immediately initiates the WebRTC connection.
  /// Can be called while the session is already live.
  Future<void> connectNewSlot() async {
    final s = session.value;
    if (s == null || slots.length >= _maxSlots) return;
    final n = slots.length + 1;
    final peerId = _uuid.v4();
    final slot = CameraSlot(peerId: peerId, label: 'Camera $n');
    slots.add(slot);
    await _signalingController.connectToCamera(s.sessionId, peerId, slot.label);
    _watchDeviceNameFor(s.sessionId, peerId);
  }

  Future<void> issueStartRecording() async {
    final s = session.value;
    if (s == null) return;

    const bufferMs = 3000;
    _recordingStartedAt =
        DateTime.now().add(const Duration(milliseconds: bufferMs));
    _recordingStoppedAt = null;
    switchHistory.clear();
    _cameraRecordingStartAt.clear();

    // Reset persisted timeline for this new recording.
    unawaited(_sessionRepository.initTimeline(s.sessionId).catchError(
          (Object e) => dev.log('initTimeline failed: $e', name: 'AdminController'),
        ));

    // All currently-connected cameras start at the same global origin.
    for (final slot in slots) {
      _cameraRecordingStartAt[slot.peerId] = _recordingStartedAt!;
    }

    final initial = activePeerId.value;
    if (initial != null) {
      final event = SwitchEvent(timestamp: _recordingStartedAt!, peerId: initial);
      switchHistory.add(event);
      unawaited(_sessionRepository.appendSwitchEvent(s.sessionId, event).catchError(
            (Object e) => dev.log('appendSwitchEvent failed: $e', name: 'AdminController'),
          ));
    }

    await _clockController.issueCommand(
      s.sessionId,
      CommandType.startRecording,
    );
    isRecording.value = true;
    recordingSeconds.value = 0;
    _recordingTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      recordingSeconds.value++;
    });
  }

  Future<void> issueStopRecording() async {
    final s = session.value;
    if (s == null) return;

    // Recording stops 1 second after command issue (bufferMs = 1000).
    _recordingStoppedAt =
        DateTime.now().add(const Duration(milliseconds: 1000));

    await _clockController.issueCommand(
      s.sessionId,
      CommandType.stopRecording,
      bufferMs: 1000,
    );
    isRecording.value = false;
    _recordingTimer?.cancel();
    _recordingTimer = null;
    recordingSeconds.value = 0;

    // Arm auto-download: files arrive asynchronously via Firestore; the
    // recordings watcher will trigger downloads as each entry lands.
    _autoDownloadEnabled = true;
    autoDownloading.value = true;
    downloadFailed.clear();
  }

  /// Downloads a camera recording file from the camera device over LAN HTTP.
  Future<void> downloadRecording(RecordingInfo info) async {
    if (downloadProgress.containsKey(info.filename)) return;
    downloadProgress[info.filename] = 0.0;

    dev.log(
      'downloadRecording: GET ${info.downloadUrl}',
      name: 'AdminController',
    );

    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 10);
    try {
      final dir = await getApplicationDocumentsDirectory();
      final savePath = '${dir.path}/${info.filename}';
      final request = await client.getUrl(Uri.parse(info.downloadUrl));
      final response = await request.close();

      dev.log(
        'downloadRecording: HTTP ${response.statusCode}  Content-Length=${response.contentLength}',
        name: 'AdminController',
      );

      if (response.statusCode != HttpStatus.ok) {
        throw HttpException(
          'Camera returned HTTP ${response.statusCode}',
          uri: Uri.parse(info.downloadUrl),
        );
      }
      final total = response.contentLength;
      var received = 0;
      final sink = File(savePath).openWrite();
      try {
        await for (final chunk in response) {
          sink.add(chunk);
          received += chunk.length;
          if (total > 0) downloadProgress[info.filename] = received / total;
        }
      } finally {
        await sink.close();
      }
      dev.log(
        'downloadRecording: saved $received bytes → $savePath',
        name: 'AdminController',
      );
      downloadedPaths[info.filename] = savePath;
      downloadProgress.remove(info.filename);
      _saveToPublicStorage(savePath, info.filename);
      _maybeFinishAutoDownload();
    } catch (e) {
      dev.log('downloadRecording: FAILED — $e', name: 'AdminController');
      downloadProgress.remove(info.filename);
      if (_autoDownloadEnabled) downloadFailed[info.filename] = info;
      _maybeFinishAutoDownload();
      Get.snackbar(
        'Download Failed',
        e.toString(),
        snackPosition: SnackPosition.BOTTOM,
      );
    } finally {
      client.close();
    }
  }

  /// Switches the admin program view to a different camera.
  /// Records a timeline event when recording is active so the render engine
  /// knows the exact cut point.
  void switchActiveCamera(String peerId) {
    if (isRecording.value && activePeerId.value != peerId) {
      final event = SwitchEvent(timestamp: DateTime.now(), peerId: peerId);
      switchHistory.add(event);
      final sid = session.value?.sessionId;
      if (sid != null) {
        unawaited(_sessionRepository.appendSwitchEvent(sid, event).catchError(
              (Object e) => dev.log('appendSwitchEvent failed: $e', name: 'AdminController'),
            ));
      }
    }
    _signalingController.switchActiveCamera(peerId);
    activePeerId.value = peerId;
  }

  // ---------------------------------------------------------------------------
  // Per-camera controls (mute / zoom / pause)
  // ---------------------------------------------------------------------------

  Future<void> toggleMuteCamera(String peerId) async {
    final s = session.value;
    if (s == null) return;
    final nowMuted = mutedCameras[peerId] ?? false;
    mutedCameras[peerId] = !nowMuted;
    await _clockController.issueCommand(
      s.sessionId,
      nowMuted ? CommandType.unmuteCamera : CommandType.muteCamera,
      bufferMs: 200,
      targetPeerId: peerId,
    );
  }

  Future<void> togglePauseCamera(String peerId) async {
    final s = session.value;
    if (s == null) return;
    final nowPaused = pausedCameras[peerId] ?? false;
    pausedCameras[peerId] = !nowPaused;
    await _clockController.issueCommand(
      s.sessionId,
      nowPaused ? CommandType.resumeCamera : CommandType.pauseCamera,
      bufferMs: 200,
      targetPeerId: peerId,
    );
  }

  Future<void> promoteToCoAdmin(String peerId) async {
    final s = session.value;
    if (s == null) return;
    coAdminPeerIds.add(peerId);
    final slotLabels = slots
        .map((slot) => {
              'peerId': slot.peerId,
              'label': slot.deviceName ?? slot.label,
            })
        .toList();
    await _clockController.issueCommand(
      s.sessionId,
      CommandType.promoteToCoAdmin,
      bufferMs: 0,
      targetPeerId: peerId,
      payload: {'slots': slotLabels},
    );
  }

  Future<void> revokeCoAdmin(String peerId) async {
    final s = session.value;
    if (s == null) return;
    coAdminPeerIds.remove(peerId);
    await _clockController.issueCommand(
      s.sessionId,
      CommandType.revokeCoAdmin,
      bufferMs: 0,
      targetPeerId: peerId,
    );
  }

  Future<void> adjustZoom(String peerId, double delta) async {
    final s = session.value;
    if (s == null) return;
    final current = zoomLevels[peerId] ?? 1.0;
    final newLevel = (current + delta).clamp(1.0, 8.0);
    zoomLevels[peerId] = newLevel;
    await _clockController.issueCommand(
      s.sessionId,
      CommandType.setZoom,
      bufferMs: 200,
      targetPeerId: peerId,
      payload: {'zoom': newLevel},
    );
  }

  // ---------------------------------------------------------------------------
  // Timeline builder — called from TransferSheet before navigating to render
  // ---------------------------------------------------------------------------

  List<Map<String, dynamic>> buildRenderSegments() {
    final startedAt = _recordingStartedAt;
    final stoppedAt = _recordingStoppedAt;
    if (startedAt == null || stoppedAt == null || switchHistory.isEmpty) {
      return [];
    }

    // Build peerId → local path map from downloaded recordings.
    final peerToPath = <String, String>{};
    for (final info in recordings) {
      final path = downloadedPaths[info.filename];
      if (path != null) peerToPath[info.peerId] = path;
    }

    final events = List<SwitchEvent>.from(switchHistory);
    final totalMs =
        stoppedAt.difference(startedAt).inMilliseconds.clamp(0, 999999);
    final segments = <Map<String, dynamic>>[];

    for (var i = 0; i < events.length; i++) {
      final peerId = events[i].peerId;
      final segStartMs = events[i]
          .timestamp
          .difference(startedAt)
          .inMilliseconds
          .clamp(0, totalMs);
      final segEndMs = i + 1 < events.length
          ? events[i + 1]
              .timestamp
              .difference(startedAt)
              .inMilliseconds
              .clamp(0, totalMs)
          : totalMs;

      final path = peerToPath[peerId];
      if (path == null) continue;

      // Late-joining cameras start recording after the global session origin.
      // Adjust the file seek offset and trim any portion before the camera joined.
      final cameraStartedAt = _cameraRecordingStartAt[peerId] ?? startedAt;
      final joinOffsetMs =
          cameraStartedAt.difference(startedAt).inMilliseconds.clamp(0, totalMs);

      final effectiveStartMs = segStartMs.clamp(joinOffsetMs, totalMs);
      final effectiveEndMs = segEndMs.clamp(joinOffsetMs, totalMs);
      final fileDurationMs = effectiveEndMs - effectiveStartMs;
      if (fileDurationMs <= 0) continue;

      final fileStartMs = effectiveStartMs - joinOffsetMs;

      segments.add({
        'inputPath': path,
        'startMs': fileStartMs,
        'durationMs': fileDurationMs,
      });
    }

    return segments;
  }

  // ---------------------------------------------------------------------------
  // Session teardown
  // ---------------------------------------------------------------------------

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
    _peerListSub?.cancel();
    _peerListSub = null;

    renderers.clear();
    slots.clear();
    recordings.clear();
    downloadProgress.clear();
    downloadedPaths.clear();
    downloadFailed.clear();
    autoDownloading.value = false;
    _autoDownloadEnabled = false;
    mutedCameras.clear();
    zoomLevels.clear();
    pausedCameras.clear();
    coAdminPeerIds.clear();
    switchHistory.clear();
    _cameraRecordingStartAt.clear();
    _recordingTimer?.cancel();
    _recordingTimer = null;
    recordingSeconds.value = 0;
    _recordingStartedAt = null;
    _recordingStoppedAt = null;
    session.value = null;
    sessionCode.value = '';
    activePeerId.value = null;
    isRecording.value = false;
    _clockController.stopWatchingCommands();
    unawaited(_clearSessionFromDisk());
  }

  // ---------------------------------------------------------------------------
  // Internal helpers
  // ---------------------------------------------------------------------------

  static const _channel = MethodChannel(
    'com.multicamstudio.multicam_studio/camera_service',
  );

  Future<void> _saveToPublicStorage(String sourcePath, String filename) async {
    try {
      await _channel.invokeMethod<void>('saveToPublicStorage', {
        'sourcePath': sourcePath,
        'filename': filename,
      });
    } catch (e) {
      dev.log('_saveToPublicStorage failed: $e', name: 'AdminController');
    }
  }

  String _generateSessionCode() =>
      (100000 + _random.nextInt(900000)).toString();

  // ---------------------------------------------------------------------------
  // Internal handlers
  // ---------------------------------------------------------------------------

  Future<void> _onRemoteStream(RemoteStreamEvent event) async {
    // Admin device only needs video preview — disable audio tracks to prevent
    // camera audio from playing through device speakers (causes feedback/noise).
    for (final track in event.stream.getAudioTracks()) {
      track.enabled = false;
    }

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
    final s = session.value;
    for (var i = 0; i < slots.length; i++) {
      final peerState = peers[slots[i].peerId];
      if (peerState != null && peerState.status != slots[i].connectionStatus) {
        // Camera connected mid-recording → issue targeted startRecording.
        if (isRecording.value &&
            peerState.status == PeerStatus.connected &&
            slots[i].connectionStatus != PeerStatus.connected &&
            s != null) {
          unawaited(_autoStartRecordingForPeer(slots[i].peerId, s.sessionId));
        }
        slots[i] = slots[i].copyWith(connectionStatus: peerState.status);
      }
    }
  }

  Future<void> _autoStartRecordingForPeer(
    String peerId,
    String sessionId,
  ) async {
    const bufferMs = 1000;
    _cameraRecordingStartAt[peerId] =
        DateTime.now().add(const Duration(milliseconds: bufferMs));
    await _clockController.issueCommand(
      sessionId,
      CommandType.startRecording,
      bufferMs: bufferMs,
      targetPeerId: peerId,
    );
  }

  void _onCoAdminCommand(SyncCommand? cmd) {
    if (cmd == null || cmd.type != CommandType.switchActiveCamera) return;
    final targetPeerId = cmd.payload?['peerId'] as String?;
    if (targetPeerId != null) switchActiveCamera(targetPeerId);
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
    ).listen((list) {
      recordings.assignAll(list);
      if (_autoDownloadEnabled) _checkAutoDownload(list);
    });
  }

  void _checkAutoDownload(List<RecordingInfo> list) {
    for (final info in list) {
      if (!downloadedPaths.containsKey(info.filename) &&
          !downloadProgress.containsKey(info.filename) &&
          !downloadFailed.containsKey(info.filename)) {
        unawaited(downloadRecording(info));
      }
    }
    _maybeFinishAutoDownload();
  }

  void _maybeFinishAutoDownload() {
    if (!_autoDownloadEnabled) return;
    if (recordings.isEmpty) return;
    final allSettled = recordings.every(
      (r) =>
          downloadedPaths.containsKey(r.filename) ||
          downloadFailed.containsKey(r.filename),
    );
    if (allSettled) {
      _autoDownloadEnabled = false;
      autoDownloading.value = false;
    }
  }

  /// Watches the peer collection for cameras joining via code.
  /// Fires immediately with existing peers when the subscription is created,
  /// so cameras that joined before Go Live are connected automatically.
  void _watchPeerList(String sessionId) {
    _peerListSub?.cancel();
    _peerListSub = _watchPeers(sessionId).listen((peers) {
      final s = session.value;
      if (s == null) return;
      for (final peer in peers) {
        if (!slots.any((slot) => slot.peerId == peer.peerId) &&
            slots.length < _maxSlots) {
          final label = peer.deviceName ?? 'Camera ${slots.length + 1}';
          final slot = CameraSlot(peerId: peer.peerId, label: label);
          slots.add(slot);
          unawaited(
            _signalingController.connectToCamera(s.sessionId, peer.peerId, label),
          );
          _watchDeviceNameFor(s.sessionId, peer.peerId);
          if (isRecording.value) {
            unawaited(_autoStartRecordingForPeer(peer.peerId, s.sessionId));
          }
        }
      }
    });
  }

  // ---------------------------------------------------------------------------
  // Timeline disk persistence — crash recovery helpers
  // ---------------------------------------------------------------------------

  static const _sessionFileName = '_active_session.json';

  Future<File> _sessionFile() async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/$_sessionFileName');
  }

  Future<void> _saveSessionToDisk(String sessionId, String adminId) async {
    try {
      final file = await _sessionFile();
      await file.writeAsString(
        jsonEncode({'sessionId': sessionId, 'adminId': adminId}),
      );
    } catch (e) {
      dev.log('_saveSessionToDisk failed: $e', name: 'AdminController');
    }
  }

  Future<void> _clearSessionFromDisk() async {
    try {
      final file = await _sessionFile();
      if (await file.exists()) await file.delete();
    } catch (e) {
      dev.log('_clearSessionFromDisk failed: $e', name: 'AdminController');
    }
  }

  Future<void> _tryRecoverFromDisk() async {
    try {
      final file = await _sessionFile();
      if (!await file.exists()) return;
      final raw = await file.readAsString();
      final map = jsonDecode(raw) as Map<String, dynamic>;
      final sessionId = map['sessionId'] as String?;
      final adminId = map['adminId'] as String?;
      if (sessionId == null || adminId == null) return;

      final events = await _sessionRepository.fetchTimeline(sessionId);
      if (events.isEmpty) return;

      // Restore in-memory state from Firestore.
      session.value = Session(
        sessionId: sessionId,
        adminId: adminId,
        status: SessionStatus.live,
      );
      _adminId = adminId;
      switchHistory.assignAll(events);
      _recordingStartedAt = events.first.timestamp;

      dev.log(
        'Recovered session $sessionId with ${events.length} timeline events',
        name: 'AdminController',
      );
    } catch (e) {
      dev.log('_tryRecoverFromDisk failed: $e', name: 'AdminController');
    }
  }

  @override
  Future<void> onClose() async {
    _remoteStreamSub?.cancel();
    _peerStatusWorker?.dispose();
    _switchWorker?.dispose();
    _recordingSub?.cancel();
    _peerListSub?.cancel();
    _recordingTimer?.cancel();
    for (final sub in _deviceNameSubs.values) {
      sub.cancel();
    }
    for (final r in renderers.values) {
      await r.dispose();
    }
    super.onClose();
  }
}
