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
import '../services/render_service.dart';
import '../../../session/domain/entities/peer_connection_state.dart';
import '../../../session/domain/entities/recording_info.dart';
import '../../../session/domain/entities/recording_profile.dart';
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

/// AdminController manages the admin (director) side of a live production.
///
/// Flow:
/// 1. Cameras record locally (native I420VideoRecorder)
/// 2. When recording stops, cameras publish RecordingInfo to Firestore
/// 3. Admin auto-downloads each recording file from the camera's LAN server
/// 4. When all downloads complete, auto-merges into one video using FFmpeg
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

  // Admin-side live audio monitoring
  final liveAudioEnabled = <String, bool>{}.obs;

  // Co-admin role tracking
  final coAdminPeerIds = RxSet<String>();

  // Master Audio Camera: the peerId of the camera that records audio, '' for no
  // audio from any camera, null when not yet selected (UI sets before recording).
  final masterAudioCameraId = Rx<String?>(null);

  // Camera capability discovery and profile selection
  final cameraCapabilities = <String, List<RecordingProfile>>{}.obs;
  final compatibleProfiles = RxList<RecordingProfile>();
  final selectedProfile = Rx<RecordingProfile?>(null);

  // Recording timer
  final recordingSeconds = 0.obs;
  Timer? _recordingTimer;

  // Timeline tracking for timeline-based render
  final switchHistory = RxList<SwitchEvent>();
  DateTime? _recordingStartedAt;
  DateTime? _recordingStoppedAt;
  // Per-camera actual recording start (differs for late-joining cameras)
  final _cameraRecordingStartAt = <String, DateTime>{};

  // Remote streams
  final _remoteStreams = <String, webrtc.MediaStream>{};

  // Resolved path of master audio camera's downloaded MP4 (set during render).
  // Kept as a field to share between _autoMerge and a future manual-trigger path.
  String? _resolvedMasterAudioPath;

  // Auto-download + auto-merge state
  bool _autoDownloadEnabled = false;
  bool _autoMergeStarted = false;

  // --- Internals ---
  late String _adminId;
  final _deviceNameSubs = <String, StreamSubscription<String?>>{};
  StreamSubscription<RemoteStreamEvent>? _remoteStreamSub;
  StreamSubscription<List<RecordingInfo>>? _recordingSub;
  StreamSubscription<List<({String peerId, String? deviceName, List<RecordingProfile> capabilities})>>? _peerListSub;
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
    _switchWorker = ever(_clockController.pendingCommand, _onCoAdminCommand);
    unawaited(_tryRecoverFromDisk());
  }

  String get adminId => _adminId;

  /// Verifies that the current session belongs to this admin before sending
  /// any commands. Prevents a stale or hijacked session from being controlled.
  bool _isValidSession() {
    final s = session.value;
    return s != null && s.adminId == _adminId;
  }

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
    _watchPeerList(s.sessionId);

    session.value = s.copyWith(status: SessionStatus.live);
    isStarting.value = false;
  }

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
    if (s == null || !_isValidSession()) return;

    // One instant drives the timeline AND both delivery paths, so the render
    // offsets match when the cameras actually start recording.
    final startAt = _commandExecuteAt();
    _recordingStartedAt = startAt;
    _recordingStoppedAt = null;
    switchHistory.clear();
    _cameraRecordingStartAt.clear();
    _autoMergeStarted = false;

    unawaited(_sessionRepository.initTimeline(s.sessionId).catchError(
          (Object e) => dev.log('initTimeline failed: $e', name: 'AdminController'),
        ));

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

    final masterCamId = masterAudioCameraId.value;
    final profile = selectedProfile.value;
    final payload = <String, dynamic>{
      if (masterCamId != null) 'masterAudioCameraId': masterCamId,
      if (profile != null) ...profile.toMap(),
    };
    await _issueTimedCommand(
      s.sessionId,
      CommandType.startRecording,
      startAt,
      payload: payload.isEmpty ? null : payload,
    );
    isRecording.value = true;
    recordingSeconds.value = 0;
    _recordingTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      recordingSeconds.value++;
    });
  }

  Future<void> issueStopRecording() async {
    final s = session.value;
    if (s == null || !_isValidSession()) return;

    final stopAt = _commandExecuteAt();
    _recordingStoppedAt = stopAt;

    await _issueTimedCommand(s.sessionId, CommandType.stopRecording, stopAt);
    isRecording.value = false;
    _recordingTimer?.cancel();
    _recordingTimer = null;
    recordingSeconds.value = 0;

    // Arm auto-download: files arrive via Firestore → trigger downloads
    _autoDownloadEnabled = true;
    autoDownloading.value = true;
    downloadFailed.clear();
    downloadedPaths.clear();
  }

  Future<void> downloadRecording(RecordingInfo info) async {
    if (downloadProgress.containsKey(info.filename)) return;
    downloadProgress[info.filename] = 0.0;

    dev.log('downloadRecording: GET ${info.downloadUrl}', name: 'AdminController');

    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 10);
    try {
      final dir = await getApplicationDocumentsDirectory();
      final savePath = '${dir.path}/${info.filename}';
      final request = await client.getUrl(Uri.parse(info.downloadUrl));
      final response = await request.close();

      dev.log('downloadRecording: HTTP ${response.statusCode}  Content-Length=${response.contentLength}',
          name: 'AdminController');

      if (response.statusCode != HttpStatus.ok) {
        throw HttpException('Camera returned HTTP ${response.statusCode}',
            uri: Uri.parse(info.downloadUrl));
      }
      final total = response.contentLength;
      var received = 0;
      var lastNotified = 0.0;
      final sink = File(savePath).openWrite();
      try {
        await for (final chunk in response) {
          sink.add(chunk);
          received += chunk.length;
          if (total > 0) {
            final progress = received / total;
            if (progress - lastNotified >= 0.01) {
              lastNotified = progress;
              downloadProgress[info.filename] = progress;
            }
          }
        }
      } finally {
        await sink.close();
      }

      dev.log('downloadRecording: saved $received bytes → $savePath', name: 'AdminController');
      final savedSize = await File(savePath).length();
      if (savedSize == 0) {
        dev.log('downloadRecording: WARNING — file is 0 bytes: $savePath', name: 'AdminController');
      } else {
        dev.log('downloadRecording: file OK — sizeBytes=$savedSize path=$savePath', name: 'AdminController');
      }
      downloadedPaths[info.filename] = savePath;
      downloadProgress.remove(info.filename);
      _saveToPublicStorage(savePath, info.filename);
      _maybeFinishAutoDownload();
    } catch (e) {
      dev.log('downloadRecording: FAILED — $e', name: 'AdminController');
      downloadProgress.remove(info.filename);
      if (_autoDownloadEnabled) downloadFailed[info.filename] = info;
      _maybeFinishAutoDownload();
    } finally {
      client.close();
    }
  }

  void switchActiveCamera(String peerId) {
    if (!_isValidSession()) return;
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
  // Per-camera controls
  // ---------------------------------------------------------------------------

  Future<void> toggleMuteCamera(String peerId) async {
    final s = session.value;
    if (s == null || !_isValidSession()) return;
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
    if (s == null || !_isValidSession()) return;
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
    if (s == null || !_isValidSession()) return;
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
    if (s == null || !_isValidSession()) return;
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
    if (s == null || !_isValidSession()) return;
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
  // Timeline builder — called before navigating to render
  // ---------------------------------------------------------------------------

  List<Map<String, dynamic>> buildRenderSegments() {
    final startedAt = _recordingStartedAt;
    final stoppedAt = _recordingStoppedAt;

    dev.log('buildRenderSegments: startedAt=$startedAt stoppedAt=$stoppedAt '
        'switchHistory=${switchHistory.length} recordings=${recordings.length} '
        'downloaded=${downloadedPaths.length}', name: 'AdminController');

    if (startedAt == null || stoppedAt == null || switchHistory.isEmpty) {
      dev.log('buildRenderSegments: returning []', name: 'AdminController');
      return [];
    }

    final peerToPath = <String, String>{};
    for (final info in recordings) {
      final path = downloadedPaths[info.filename];
      if (path != null) {
        peerToPath[info.peerId] = path;
      }
    }

    final events = List<SwitchEvent>.from(switchHistory);
    final totalMs = stoppedAt.difference(startedAt).inMilliseconds.clamp(0, 999999);
    final segments = <Map<String, dynamic>>[];

    for (var i = 0; i < events.length; i++) {
      final peerId = events[i].peerId;
      final segStartMs = events[i].timestamp.difference(startedAt).inMilliseconds.clamp(0, totalMs);
      final segEndMs = i + 1 < events.length
          ? events[i + 1].timestamp.difference(startedAt).inMilliseconds.clamp(0, totalMs)
          : totalMs;

      final path = peerToPath[peerId];
      if (path == null) continue;

      final cameraStartedAt = _cameraRecordingStartAt[peerId] ?? startedAt;
      final joinOffsetMs = cameraStartedAt.difference(startedAt).inMilliseconds.clamp(0, totalMs);
      final effectiveStartMs = segStartMs.clamp(joinOffsetMs, totalMs);
      final effectiveEndMs = segEndMs.clamp(joinOffsetMs, totalMs);
      final fileDurationMs = effectiveEndMs - effectiveStartMs;

      if (fileDurationMs <= 0) continue;

      final fileStartMs = effectiveStartMs - joinOffsetMs;
      segments.add({
        'inputPath': path,
        'startMs': fileStartMs,
        'durationMs': fileDurationMs,
        'adminAudioStartMs': effectiveStartMs,
      });
    }

    dev.log('buildRenderSegments: produced ${segments.length} segment(s)', name: 'AdminController');
    return segments;
  }

  // ---------------------------------------------------------------------------
  // Auto-download + Auto-merge
  // ---------------------------------------------------------------------------

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
      (r) => downloadedPaths.containsKey(r.filename) || downloadFailed.containsKey(r.filename),
    );
    if (allSettled) {
      _autoDownloadEnabled = false;
      autoDownloading.value = false;
      // Only auto-merge if ALL downloads succeeded — if any failed, the user
      // must retry them manually before merging.
      final hasFailures = downloadFailed.isNotEmpty;
      if (!hasFailures && !_autoMergeStarted) {
        _autoMergeStarted = true;
        unawaited(_autoMerge());
      } else if (hasFailures) {
        Get.snackbar(
          'Download Incomplete',
          'Some recordings failed to download. Retry them before rendering.',
          snackPosition: SnackPosition.BOTTOM,
          duration: const Duration(seconds: 4),
        );
      }
    }
  }

  /// Auto-merges downloaded recordings into a single video based on switch timeline.
  Future<void> _autoMerge() async {
    if (downloadedPaths.isEmpty) {
      dev.log('_autoMerge: no downloaded files to merge', name: 'AdminController');
      return;
    }
    if (switchHistory.isEmpty) {
      dev.log('_autoMerge: no switch history, cannot build timeline', name: 'AdminController');
      return;
    }

    dev.log('_autoMerge: merging ${downloadedPaths.length} file(s) with ${switchHistory.length} switch(es)',
        name: 'AdminController');

    // Build RenderSource list from downloaded paths
    final sources = <RenderSource>[];
    for (final entry in downloadedPaths.entries) {
      final filename = entry.key;
      final path = entry.value;
      final info = recordings.firstWhereOrNull((r) => r.filename == filename);
      final slot = info != null
          ? slots.firstWhereOrNull((s) => s.peerId == info.peerId)
          : null;
      final label = slot?.deviceName ?? slot?.label ?? filename;
      sources.add(RenderSource(filename: filename, label: label, path: path));
    }

    // Build timeline segments
    final segments = buildRenderSegments();
    if (segments.isEmpty) {
      dev.log('_autoMerge: segments empty, skipping render', name: 'AdminController');
      return;
    }

    // Resolve the master audio camera's downloaded file, if one was selected.
    // VideoRenderService reads audio from this file (ignoring per-camera audio
    // tracks) so the master camera's continuous audio is preserved across cuts.
    _resolvedMasterAudioPath = null;
    final masterCamId = masterAudioCameraId.value;
    if (masterCamId != null && masterCamId.isNotEmpty) {
      final masterInfo = recordings.firstWhereOrNull((r) => r.peerId == masterCamId);
      if (masterInfo != null) {
        _resolvedMasterAudioPath = downloadedPaths[masterInfo.filename];
        if (_resolvedMasterAudioPath == null) {
          dev.log('_autoMerge: master camera ($masterCamId) file not downloaded — merging without audio override',
              name: 'AdminController');
        }
      } else {
        dev.log('_autoMerge: master camera ($masterCamId) has no recording info',
            name: 'AdminController');
      }
    }

    // Trigger render via RenderService and navigate to the render page so the
    // user can see progress. The RenderService is a GetxService that lives for
    // the app lifetime, so the render continues even if the user navigates away.
    final renderService = Get.find<RenderService>();
    renderService.prepare(sources, segments: segments, adminAudioPath: _resolvedMasterAudioPath);
    Get.toNamed<void>('/admin/render');
    await renderService.startRender();
    dev.log('_autoMerge: render completed', name: 'AdminController');
  }

  // ---------------------------------------------------------------------------
  // Session teardown
  // ---------------------------------------------------------------------------

  Future<void> endSession() async {
    final s = session.value;
    if (s == null) return;

    if (isRecording.value) await issueStopRecording();

    await Future.wait(
      slots.map((slot) => _signalingController.disconnect(s.sessionId, slot.peerId)),
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
    _autoMergeStarted = false;
    mutedCameras.clear();
    zoomLevels.clear();
    pausedCameras.clear();
    liveAudioEnabled.clear();
    _remoteStreams.clear();
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
    masterAudioCameraId.value = null;
    _resolvedMasterAudioPath = null;
    cameraCapabilities.clear();
    compatibleProfiles.clear();
    selectedProfile.value = null;
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

  String _generateSessionCode() => (100000 + _random.nextInt(900000)).toString();

  // ---------------------------------------------------------------------------
  // Internal handlers
  // ---------------------------------------------------------------------------

  Future<void> _onRemoteStream(RemoteStreamEvent event) async {
    final peerId = event.peerId;
    final stream = event.stream;
    final isNewPeer = !renderers.containsKey(peerId);

    final shouldEnable = isNewPeer ? false : (liveAudioEnabled[peerId] ?? false);

    liveAudioEnabled[peerId] = shouldEnable;
    _remoteStreams[peerId] = stream;
    for (final track in stream.getAudioTracks()) {
      track.enabled = shouldEnable;
    }

    if (!isNewPeer) {
      renderers[peerId]!.srcObject = stream;
      return;
    }
    final renderer = webrtc.RTCVideoRenderer();
    await renderer.initialize();
    renderer.srcObject = stream;
    renderers[peerId] = renderer;
    if (activePeerId.value == null) activePeerId.value = peerId;
  }

  void toggleLiveAudio(String peerId) {
    final nowEnabled = liveAudioEnabled[peerId] ?? false;
    liveAudioEnabled[peerId] = !nowEnabled;
    final stream = _remoteStreams[peerId];
    if (stream != null) {
      for (final track in stream.getAudioTracks()) {
        track.enabled = !nowEnabled;
      }
    }
  }

  void _syncPeerStatuses(Map<String, PeerConnectionState> peers) {
    final s = session.value;
    for (var i = 0; i < slots.length; i++) {
      final peerState = peers[slots[i].peerId];
      if (peerState != null && peerState.status != slots[i].connectionStatus) {
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

  Future<void> _autoStartRecordingForPeer(String peerId, String sessionId) async {
    if (!_isValidSession()) return;
    final startAt = _commandExecuteAt();
    _cameraRecordingStartAt[peerId] = startAt;
    final masterCamId = masterAudioCameraId.value;
    final profile = selectedProfile.value;
    final payload = <String, dynamic>{
      if (masterCamId != null) 'masterAudioCameraId': masterCamId,
      if (profile != null) ...profile.toMap(),
    };
    await _issueTimedCommand(
      sessionId,
      CommandType.startRecording,
      startAt,
      targetPeerId: peerId,
      payload: payload.isEmpty ? null : payload,
    );
  }

  /// Lead time for recording start/stop commands. Long enough for the
  /// Firestore fallback to reach every camera before the instant arrives;
  /// the LAN fast-path arrives sooner and simply waits for the same instant.
  static const _commandLeadMs = 1000;

  /// Local admin time at which a recording command will execute everywhere.
  DateTime _commandExecuteAt() =>
      DateTime.now().add(const Duration(milliseconds: _commandLeadMs));

  /// Publishes a recording command over Firestore and the LAN data channel,
  /// both pinned to the same execution instant [executeAtLocal].
  Future<void> _issueTimedCommand(
    String sessionId,
    CommandType type,
    DateTime executeAtLocal, {
    String? targetPeerId,
    Map<String, dynamic>? payload,
  }) async {
    final executeAtMs = _clockController.localToServerMs(executeAtLocal);
    final commandId = await _clockController.issueCommand(
      sessionId,
      type,
      bufferMs: _commandLeadMs,
      targetPeerId: targetPeerId,
      payload: payload,
      executeAtMs: executeAtMs,
    );
    if (commandId != null) {
      _sendLanCommand(
        commandId,
        type,
        executeAtMs,
        targetPeerId: targetPeerId,
        payload: payload,
      );
    }
  }

  /// Sends a recording command directly to cameras over the LAN WebRTC data
  /// channel. The [commandId] is the Firestore doc ID so cameras can deduplicate
  /// against the Firestore fallback using a single shared ID. [executeAtMs] is
  /// the same server-equivalent instant stored in the Firestore command, so
  /// whichever path arrives first, the camera fires at the same moment.
  void _sendLanCommand(
    String commandId,
    CommandType type,
    int executeAtMs, {
    String? targetPeerId,
    Map<String, dynamic>? payload,
  }) {
    final msg = jsonEncode({
      'commandId': commandId,
      'type': type.name,
      'executeAtMs': executeAtMs,
      'targetPeerId': ?targetPeerId,
      'payload': ?payload,
    });

    final targets = targetPeerId != null
        ? [targetPeerId]
        : slots.map((s) => s.peerId).toList();

    for (final peerId in targets) {
      unawaited(_webRtcService.sendToDataChannel(peerId, msg));
    }
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
    ).where((name) => name != null && name.isNotEmpty).distinct().listen((deviceName) {
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
          unawaited(_signalingController.connectToCamera(s.sessionId, peer.peerId, label));
          _watchDeviceNameFor(s.sessionId, peer.peerId);
          if (isRecording.value) {
            unawaited(_autoStartRecordingForPeer(peer.peerId, s.sessionId));
          }
        }
        if (peer.capabilities.isNotEmpty) {
          cameraCapabilities[peer.peerId] = peer.capabilities;
        }
      }
      _computeCompatibleProfiles();
    });
  }

  void _computeCompatibleProfiles() {
    final activePeerIds = slots.map((s) => s.peerId).toList();
    final knownCaps = activePeerIds
        .where((id) => cameraCapabilities.containsKey(id))
        .map((id) => cameraCapabilities[id]!.toSet())
        .toList();

    if (knownCaps.isEmpty) {
      if (compatibleProfiles.isEmpty) {
        compatibleProfiles.assignAll([_defaultProfile]);
        selectedProfile.value ??= _defaultProfile;
      }
      return;
    }

    final first = knownCaps.first;
    final intersection = knownCaps.skip(1).fold<Set<RecordingProfile>>(
          first,
          (acc, caps) => acc.intersection(caps),
        );

    final sorted = intersection.toList()
      ..sort((a, b) => b.quality.compareTo(a.quality));

    compatibleProfiles.assignAll(sorted);

    if (selectedProfile.value == null || !sorted.contains(selectedProfile.value)) {
      selectedProfile.value = sorted.isNotEmpty ? sorted.first : _defaultProfile;
    }
  }

  static const _defaultProfile =
      RecordingProfile(width: 1280, height: 720, frameRate: 30, codec: 'H264');

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
      await file.writeAsString(jsonEncode({'sessionId': sessionId, 'adminId': adminId}));
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

      session.value = Session(
        sessionId: sessionId,
        adminId: adminId,
        status: SessionStatus.live,
      );
      _adminId = adminId;
      switchHistory.assignAll(events);
      _recordingStartedAt = events.first.timestamp;
      // Restore the stop time so buildRenderSegments can produce a valid
      // timeline after crash recovery. Without this, segments are always empty.
      _recordingStoppedAt = DateTime.now();

      dev.log('Recovered session $sessionId with ${events.length} timeline events', name: 'AdminController');
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