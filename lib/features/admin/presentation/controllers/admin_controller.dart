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
import 'package:permission_handler/permission_handler.dart';
import 'package:share_plus/share_plus.dart';
import 'package:uuid/uuid.dart';

import '../../../../core/services/clock_sync_service.dart';
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

  // Audio source for the take: a camera's peerId (Master Audio Camera), '' for
  // no audio, [adminMicSourceId] for Studio Audio Mode, [followVideoSourceId]
  // for audio that follows the cuts, or null when not yet selected (UI sets
  // before recording).
  final masterAudioCameraId = Rx<String?>(null);

  /// Studio Audio Mode: the admin device's mic records the sole audio track
  /// and every camera records video only.
  static const adminMicSourceId = '__admin_mic__';

  bool get usesAdminMic => masterAudioCameraId.value == adminMicSourceId;

  /// Audio follows video: every camera records its own audio and each cut in
  /// the render uses the audio of the camera on screen.
  static const followVideoSourceId = '__follow_video__';

  /// What cameras receive as `masterAudioCameraId`: in Studio Audio Mode no
  /// camera is the audio source, which cameras understand as ''; when audio
  /// follows video none is named (null), so every camera records audio.
  String? get _cameraAudioSourceId => switch (masterAudioCameraId.value) {
        adminMicSourceId => '',
        followVideoSourceId => null,
        final id => id,
      };

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
  // True once this take has been rendered, so crash recovery skips it.
  bool _recordingRendered = false;
  // Serializes Firestore timeline writes (clear, then appends) in order.
  Future<void> _timelineWrites = Future.value();

  // Remote streams
  final _remoteStreams = <String, webrtc.MediaStream>{};

  // Studio Audio Mode recording of the current take: the admin mic file, the
  // wall-clock time of its first sample (t=0 of the file), and the pending
  // native stop that finalizes it.
  String? _adminAudioPath;
  DateTime? _adminAudioStartedAt;
  Future<void>? _adminAudioStop;
  bool _adminAudioFinalized = false;

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
  Worker? _renderDoneWorker;

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
    // Covers both the auto-merge and a manual render from the transfer sheet.
    _renderDoneWorker = ever(Get.find<RenderService>().outputPath, (path) {
      if (path == null || _recordingStartedAt == null) return;
      _recordingRendered = true;
      unawaited(_saveRecordingStateToDisk());
    });
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
    final result = await _createSession(
      CreateSessionParams(adminId: _adminId, nextCode: _generateSessionCode),
    );
    result.fold(
      onSuccess: (created) {
        session.value = Session(
          sessionId: created.sessionId,
          adminId: _adminId,
          status: SessionStatus.waiting,
        );
        sessionCode.value = created.code;
        unawaited(_saveSessionToDisk(created.sessionId, _adminId));
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

    // startSession kicks off clock sync without awaiting it. Execution times
    // are sent in server time, so an unsynced admin would be off by its whole
    // clock offset.
    if (_clockController.syncQuality.value == SyncQuality.unsynced) {
      await _clockController.sync();
    }

    // Studio Audio Mode: start the admin mic before anything else, so a mic
    // failure aborts the take instead of producing a silent video. The mic
    // starts slightly before the cameras; the render aligns it using the
    // recorded start time.
    _adminAudioPath = null;
    _adminAudioStartedAt = null;
    _adminAudioStop = null;
    _adminAudioFinalized = false;
    if (usesAdminMic && !await _startAdminAudio()) return;

    // One instant drives the timeline AND both delivery paths, so the render
    // offsets match when the cameras actually start recording.
    final startAt = _commandExecuteAt();
    _recordingStartedAt = startAt;
    _recordingStoppedAt = null;
    _recordingRendered = false;
    switchHistory.clear();
    _cameraRecordingStartAt.clear();
    _autoMergeStarted = false;

    // Queued so the clear finishes before any event of this take is written;
    // otherwise initTimeline's delete pass can remove the new initial event.
    final sid = s.sessionId;
    _enqueueTimelineWrite('initTimeline', () => _sessionRepository.initTimeline(sid));

    for (final slot in slots) {
      _cameraRecordingStartAt[slot.peerId] = _recordingStartedAt!;
    }

    final initial = activePeerId.value;
    if (initial != null) {
      final event = SwitchEvent(timestamp: _recordingStartedAt!, peerId: initial);
      switchHistory.add(event);
      _enqueueTimelineWrite(
        'appendSwitchEvent',
        () => _sessionRepository.appendSwitchEvent(sid, event),
      );
    }
    unawaited(_saveRecordingStateToDisk());

    final masterCamId = _cameraAudioSourceId;
    final profile = selectedProfile.value;
    final payload = <String, dynamic>{
      'masterAudioCameraId': ?masterCamId,
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
    unawaited(_saveRecordingStateToDisk());

    await _issueTimedCommand(s.sessionId, CommandType.stopRecording, stopAt);
    if (_adminAudioPath != null && _adminAudioStop == null) {
      // Keep the mic running until the cameras actually stop, plus a margin.
      final delay = stopAt.difference(DateTime.now()) +
          const Duration(milliseconds: 300);
      _adminAudioStop = Future<void>.delayed(
        delay.isNegative ? Duration.zero : delay,
        _stopAdminAudio,
      );
    }
    isRecording.value = false;
    _recordingTimer?.cancel();
    _recordingTimer = null;
    recordingSeconds.value = 0;
    _armAutoDownload();
  }

  // ---------------------------------------------------------------------------
  // Studio Audio Mode — admin mic recording
  // ---------------------------------------------------------------------------

  Future<bool> _startAdminAudio() async {
    if (!await Permission.microphone.request().isGranted) {
      Get.snackbar(
        'Microphone needed',
        'Allow microphone access to record with Admin Mic.',
        snackPosition: SnackPosition.BOTTOM,
      );
      return false;
    }
    try {
      final dir = await getApplicationDocumentsDirectory();
      final path =
          '${dir.path}/admin_audio_${DateTime.now().millisecondsSinceEpoch}.m4a';
      final startedMs = await _channel.invokeMethod<int>(
        'startAdminAudioRecording',
        {'outputPath': path},
      );
      _adminAudioPath = path;
      _adminAudioStartedAt = startedMs != null
          ? DateTime.fromMillisecondsSinceEpoch(startedMs)
          : DateTime.now();
      dev.log('admin mic started → $path', name: 'AdminController');
      return true;
    } catch (e) {
      dev.log('_startAdminAudio failed: $e', name: 'AdminController');
      Get.snackbar(
        'Admin Mic failed',
        'Could not start the microphone. Recording was not started.',
        snackPosition: SnackPosition.BOTTOM,
      );
      return false;
    }
  }

  Future<void> _stopAdminAudio() async {
    try {
      await _channel.invokeMethod<void>('stopAdminAudioRecording');
      _adminAudioFinalized = true;
      unawaited(_saveRecordingStateToDisk());
    } catch (e) {
      dev.log('_stopAdminAudio failed: $e', name: 'AdminController');
    }
  }

  /// The audio track that replaces per-camera audio in the render, if any:
  /// the admin mic file (Studio Audio Mode) or the master audio camera's
  /// downloaded file. [startedAt] is the wall-clock time of the file's t=0.
  ({String path, DateTime startedAt})? resolveRenderAudio() {
    final startedAt = _recordingStartedAt;
    if (startedAt == null) return null;

    final adminPath = _adminAudioPath;
    if (adminPath != null) {
      final f = File(adminPath);
      if (_adminAudioFinalized && f.existsSync() && f.lengthSync() > 0) {
        return (path: adminPath, startedAt: _adminAudioStartedAt ?? startedAt);
      }
      dev.log('resolveRenderAudio: admin mic file unusable — rendering without it',
          name: 'AdminController');
      return null;
    }

    final masterCamId = masterAudioCameraId.value;
    // No single source: '' (no audio), admin mic (handled above, but unusable
    // here), or audio follows video — the render then keeps each segment's
    // own camera audio.
    if (masterCamId == null ||
        masterCamId.isEmpty ||
        masterCamId == adminMicSourceId ||
        masterCamId == followVideoSourceId) {
      return null;
    }
    final masterInfo = recordings.firstWhereOrNull((r) => r.peerId == masterCamId);
    final path = masterInfo != null ? downloadedPaths[masterInfo.filename] : null;
    if (path == null) {
      dev.log('resolveRenderAudio: master camera ($masterCamId) file not available',
          name: 'AdminController');
      return null;
    }
    return (
      path: path,
      startedAt: _cameraRecordingStartAt[masterCamId] ?? startedAt,
    );
  }

  /// Files arrive via Firestore → trigger downloads, then auto-merge.
  void _armAutoDownload() {
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
        _enqueueTimelineWrite(
          'appendSwitchEvent',
          () => _sessionRepository.appendSwitchEvent(sid, event),
        );
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
    // Where the audio file's t=0 sits on the take timeline. The admin mic
    // starts before the take (negative), a late-joining master camera after.
    final audio = resolveRenderAudio();
    final audioOffsetMs =
        audio == null ? 0 : audio.startedAt.difference(startedAt).inMilliseconds;

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
        'adminAudioStartMs': max(0, effectiveStartMs - audioOffsetMs),
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

    // The admin mic file must be finalized before it can be read.
    await _adminAudioStop;

    // Build timeline segments
    final segments = buildRenderSegments();
    if (segments.isEmpty) {
      dev.log('_autoMerge: segments empty, skipping render', name: 'AdminController');
      return;
    }

    // VideoRenderService reads audio from this file (ignoring per-camera audio
    // tracks) so one continuous audio track is preserved across cuts.
    final audio = resolveRenderAudio();

    // Trigger render via RenderService and navigate to the render page so the
    // user can see progress. The RenderService is a GetxService that lives for
    // the app lifetime, so the render continues even if the user navigates away.
    final renderService = Get.find<RenderService>();
    renderService.prepare(sources, segments: segments, adminAudioPath: audio?.path);
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
    _adminAudioPath = null;
    _adminAudioStartedAt = null;
    _adminAudioStop = null;
    _adminAudioFinalized = false;
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
    unawaited(_saveRecordingStateToDisk());
    final masterCamId = _cameraAudioSourceId;
    final profile = selectedProfile.value;
    final payload = <String, dynamic>{
      'masterAudioCameraId': ?masterCamId,
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
    ).listen((all) {
      final list = all.where(_isCurrentTake).toList();
      recordings.assignAll(list);
      if (_autoDownloadEnabled) _checkAutoDownload(list);
    });
  }

  /// The recordings collection keeps every take of the session. Only files
  /// published after this take started belong to it; without this filter an
  /// earlier take's file could be downloaded and rendered in its place.
  bool _isCurrentTake(RecordingInfo info) {
    final startedAt = _recordingStartedAt;
    if (startedAt == null) return true;
    // recordedAt is a server timestamp written when the camera stopped.
    return info.recordedAt.millisecondsSinceEpoch >=
        _clockController.localToServerMs(startedAt);
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

  /// Persists the current take's timing next to the session ids, so a crash
  /// can be recovered with the real start/stop instants. Switch events
  /// themselves live in Firestore (`timeline`).
  Future<void> _saveRecordingStateToDisk() async {
    final s = session.value;
    final startedAt = _recordingStartedAt;
    if (s == null || startedAt == null) return;
    try {
      final file = await _sessionFile();
      await file.writeAsString(jsonEncode({
        'sessionId': s.sessionId,
        'adminId': s.adminId,
        'recording': {
          'startedAtMs': startedAt.millisecondsSinceEpoch,
          'stoppedAtMs': _recordingStoppedAt?.millisecondsSinceEpoch,
          'cameraStartAtMs': _cameraRecordingStartAt
              .map((peerId, t) => MapEntry(peerId, t.millisecondsSinceEpoch)),
          'masterAudioCameraId': masterAudioCameraId.value,
          'adminAudioPath': _adminAudioPath,
          'adminAudioStartedAtMs': _adminAudioStartedAt?.millisecondsSinceEpoch,
          'adminAudioFinalized': _adminAudioFinalized,
          'rendered': _recordingRendered,
        },
      }));
    } catch (e) {
      dev.log('_saveRecordingStateToDisk failed: $e', name: 'AdminController');
    }
  }

  void _enqueueTimelineWrite(String label, Future<void> Function() write) {
    _timelineWrites = _timelineWrites.then((_) => write()).catchError(
          (Object e) => dev.log('$label failed: $e', name: 'AdminController'),
        );
  }

  /// Restores a take that was interrupted by an admin crash and finishes it:
  /// downloads the camera files and renders them along the saved timeline.
  Future<void> _tryRecoverFromDisk() async {
    try {
      final file = await _sessionFile();
      if (!await file.exists()) return;
      final raw = await file.readAsString();
      final map = jsonDecode(raw) as Map<String, dynamic>;
      final sessionId = map['sessionId'] as String?;
      final adminId = map['adminId'] as String?;
      final rec = map['recording'] as Map<String, dynamic>?;
      if (sessionId == null || adminId == null || rec == null) return;
      if (rec['rendered'] == true) return;
      final startedAtMs = (rec['startedAtMs'] as num?)?.toInt();
      if (startedAtMs == null) return;

      final events = await _sessionRepository.fetchTimeline(sessionId);

      session.value = Session(
        sessionId: sessionId,
        adminId: adminId,
        status: SessionStatus.live,
      );
      _adminId = adminId;
      switchHistory.assignAll(events);
      _recordingStartedAt = DateTime.fromMillisecondsSinceEpoch(startedAtMs);
      _cameraRecordingStartAt
        ..clear()
        ..addAll(
          ((rec['cameraStartAtMs'] as Map<String, dynamic>?) ?? {}).map(
            (peerId, ms) => MapEntry(
              peerId,
              DateTime.fromMillisecondsSinceEpoch((ms as num).toInt()),
            ),
          ),
        );
      masterAudioCameraId.value = rec['masterAudioCameraId'] as String?;
      // An admin mic file is only usable if its muxer was stopped before the
      // crash; a file cut off mid-write is unreadable and would fail the
      // render, so that take renders without audio instead.
      _adminAudioPath = rec['adminAudioPath'] as String?;
      final adminAudioStartedAtMs = (rec['adminAudioStartedAtMs'] as num?)?.toInt();
      _adminAudioStartedAt = adminAudioStartedAtMs != null
          ? DateTime.fromMillisecondsSinceEpoch(adminAudioStartedAtMs)
          : null;
      _adminAudioFinalized = rec['adminAudioFinalized'] == true;
      if (!_adminAudioFinalized) {
        // Also keeps the stop below from scheduling a native stop, which
        // would mark the cut-off file as finalized.
        _adminAudioPath = null;
        _adminAudioStartedAt = null;
      }
      _adminAudioStop = null;
      _autoMergeStarted = false;

      // Needed for the stop command and for telling this take's recordings
      // from earlier ones.
      await _clockController.sync();

      final stoppedAtMs = (rec['stoppedAtMs'] as num?)?.toInt();
      if (stoppedAtMs != null) {
        _recordingStoppedAt = DateTime.fromMillisecondsSinceEpoch(stoppedAtMs);
        _armAutoDownload();
      } else {
        // Crashed mid-take: the cameras are still recording, but this admin
        // lost its live connections and has no running take to stop from the
        // UI. Stop them now so the footage is saved, downloaded and rendered.
        await issueStopRecording();
      }
      _watchRecordingsFor(sessionId);

      dev.log(
        'Recovered session $sessionId: ${events.length} timeline event(s), '
        '${stoppedAtMs != null ? 'take already stopped' : 'stopped the running take'}',
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
    _renderDoneWorker?.dispose();
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