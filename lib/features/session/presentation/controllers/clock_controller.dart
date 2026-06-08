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

  /// Issues a timed command to all cameras in the session.
  /// [bufferMs] gives cameras time to receive and schedule the command
  /// before the execution timestamp arrives.
  Future<void> issueCommand(
    String sessionId,
    CommandType type, {
    int bufferMs = 3000,
  }) =>
      _publishCommand(
        PublishCommandParams(
          sessionId: sessionId,
          type: type,
          bufferMs: bufferMs,
        ),
      );

  /// Camera: subscribes to commands for this session and schedules them.
  void startWatchingCommands(String sessionId) {
    _commandSub?.cancel();
    _commandSub = _watchCommands(WatchCommandsParams(sessionId: sessionId))
        .listen(_scheduleCommand);
  }

  void stopWatchingCommands() {
    _commandSub?.cancel();
    _commandSub = null;
  }

  void _scheduleCommand(SyncCommand cmd) {
    final executeAtServer = cmd.executeAtServer;
    final executeAtLocal = _clockSyncService.isSynced
        ? _clockSyncService.serverToLocal(executeAtServer)
        : executeAtServer;
    final delay = executeAtLocal.difference(DateTime.now());

    // Skip commands whose execution window has already passed (>1s late).
    if (delay.inMilliseconds < -1000) return;

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
