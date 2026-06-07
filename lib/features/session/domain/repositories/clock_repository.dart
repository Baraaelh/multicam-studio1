import '../entities/sync_command.dart';

abstract interface class ClockRepository {
  Future<void> addCommand(
    String sessionId,
    CommandType type,
    int bufferMs,
  );

  Stream<SyncCommand> watchCommands(String sessionId);
}
