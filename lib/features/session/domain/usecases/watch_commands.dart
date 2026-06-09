import '../../../../core/usecases/use_case.dart';
import '../entities/sync_command.dart';
import '../repositories/clock_repository.dart';

class WatchCommandsParams {
  final String sessionId;
  /// Only return commands issued at or after this instant.
  /// Used to prevent Firestore's initial-snapshot replay of historical commands.
  final DateTime? issuedAfter;

  const WatchCommandsParams({required this.sessionId, this.issuedAfter});
}

class WatchCommands implements StreamUseCase<SyncCommand, WatchCommandsParams> {
  final ClockRepository _repository;
  const WatchCommands(this._repository);

  @override
  Stream<SyncCommand> call(WatchCommandsParams params) =>
      _repository.watchCommands(params.sessionId, issuedAfter: params.issuedAfter);
}
