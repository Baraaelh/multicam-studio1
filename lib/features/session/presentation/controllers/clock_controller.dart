import 'dart:async';

import 'package:get/get.dart';

import '../../../../core/services/clock_sync_service.dart';
import '../../domain/entities/sync_command.dart';
import '../../domain/usecases/publish_command.dart';
import '../../domain/usecases/sync_clock.dart';
import '../../domain/usecases/watch_commands.dart';

class ClockController extends GetxController {
  final SyncClock _syncClock;
  final PublishCommand _publishCommand;
  final WatchCommands _watchCommands;
  final ClockSyncService _clockSyncService;

  ClockController({
    required SyncClock syncClock,
    required PublishCommand publishCommand,
    required WatchCommands watchCommands,
    required ClockSyncService clockSyncService,
  })  : _syncClock = syncClock,
        _publishCommand = publishCommand,
        _watchCommands = watchCommands,
        _clockSyncService = clockSyncService;

  final offsetMs = 0.obs;
  final varianceMs = 9999.obs;
  final syncQuality = Rx<SyncQuality>(SyncQuality.unsynced);
  final isSyncing = false.obs;

  /// Fires when a scheduled command's local execution time is reached.
  /// Step 7 hooks into this to start/stop recording.
  final pendingCommand = Rx<SyncCommand?>(null);

  StreamSubscription<SyncCommand>? _commandSub;
  final _timers = <Timer>[];
  // Tracks command IDs already scheduled so Firestore replay doesn't fire them twice.
  final _scheduledIds = <String>{};

  /// Measures clock offset between this device and Firebase server clock.
  Future<void> sync() async {
    isSyncing.value = true;
    final result = await _syncClock(const SyncClockParams());
    result.fold(
      onSuccess: (_) {
        offsetMs.value = _clockSyncService.offsetMs;
        varianceMs.value = _clockSyncService.varianceMs;
        syncQuality.value = _clockSyncService.quality;
      },
      onFailure: (f) => Get.snackbar(
        'Sync error',
        f.message,
        snackPosition: SnackPosition.BOTTOM,
      ),
    );
    isSyncing.value = false;
  }

  /// Issues a timed command to all cameras in the session via Firestore.
  /// Returns the Firestore document ID so the LAN fast-path can share the
  /// same ID for deduplication on the camera side.
  Future<String?> issueCommand(
    String sessionId,
    CommandType type, {
    int bufferMs = 3000,
    String? targetPeerId,
    Map<String, dynamic>? payload,
    int? executeAtMs,
  }) async {
    final result = await _publishCommand(
      PublishCommandParams(
        sessionId: sessionId,
        type: type,
        bufferMs: bufferMs,
        targetPeerId: targetPeerId,
        payload: payload,
        executeAtMs: executeAtMs,
      ),
    );
    return result.valueOrNull;
  }

  /// Converts a local [DateTime] on this device to server-equivalent ms.
  int localToServerMs(DateTime local) =>
      local.millisecondsSinceEpoch - _clockSyncService.offsetMs;

  /// Schedules a command that arrived via the LAN data channel fast-path.
  /// Uses the same deduplication set as Firestore commands so whichever
  /// path delivers first wins and the duplicate is silently dropped.
  void scheduleFromLan(SyncCommand cmd) => _scheduleCommand(cmd);

  /// Camera: subscribes to commands for this session and schedules them.
  /// Uses the current server-equivalent time as a cutoff so historical commands
  /// already in Firestore (from earlier recordings in the same session) are
  /// never replayed.
  void startWatchingCommands(String sessionId) {
    _commandSub?.cancel();
    _scheduledIds.clear();

    // Allow a 10-second look-back so commands issued just before the camera
    // connected (within the 3-second buffer window) are still received.
    final cutoff = DateTime.now()
        .subtract(const Duration(seconds: 10))
        .subtract(Duration(milliseconds: _clockSyncService.offsetMs));

    _commandSub = _watchCommands(
      WatchCommandsParams(sessionId: sessionId, issuedAfter: cutoff),
    ).listen(_scheduleCommand);
  }

  void stopWatchingCommands() {
    _commandSub?.cancel();
    _commandSub = null;
    _scheduledIds.clear();
  }

  void _scheduleCommand(SyncCommand cmd) {
    // Dedup: ignore commands already scheduled (Firestore can replay on reconnect).
    if (_scheduledIds.contains(cmd.id)) return;
    _scheduledIds.add(cmd.id);

    final executeAtServer = cmd.executeAtServer;
    final executeAtLocal = _clockSyncService.isSynced
        ? _clockSyncService.serverToLocal(executeAtServer)
        : executeAtServer;
    final delay = executeAtLocal.difference(DateTime.now());

    // Skip commands whose execution window has already passed by more than 10 s.
    // The Firestore filter handles most cases; this is a secondary safety net.
    if (delay.inMilliseconds < -10000) return;

    late final Timer timer;
    timer = Timer(
      delay.isNegative ? Duration.zero : delay,
      () {
        pendingCommand.value = cmd;
        _timers.remove(timer);
      },
    );
    _timers.add(timer);
  }

  @override
  void onClose() {
    _commandSub?.cancel();
    for (final t in _timers) {
      t.cancel();
    }
    super.onClose();
  }
}
