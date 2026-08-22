import '../entities/sync_command.dart';

abstract interface class ClockRepository {
  Future<String> addCommand(
    String sessionId,
    CommandType type,
    int bufferMs, {
    String? targetPeerId,
    Map<String, dynamic>? payload,
  });

  Stream<SyncCommand> watchCommands(String sessionId, {DateTime? issuedAfter});
}
