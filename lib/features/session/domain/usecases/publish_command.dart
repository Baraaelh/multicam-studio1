import '../../../../core/error/failures.dart';
import '../../../../core/error/result.dart';
import '../../../../core/usecases/use_case.dart';
import '../entities/sync_command.dart';
import '../repositories/clock_repository.dart';

class PublishCommandParams {
  final String sessionId;
  final CommandType type;
  final int bufferMs;

  const PublishCommandParams({
    required this.sessionId,
    required this.type,
    this.bufferMs = 3000,
  });
}

class PublishCommand implements UseCase<void, PublishCommandParams> {
  final ClockRepository _repository;
  const PublishCommand(this._repository);

  @override
  Future<Result<void>> call(PublishCommandParams params) async {
    try {
      await _repository.addCommand(
        params.sessionId,
        params.type,
        params.bufferMs,
      );
      return const Success(null);
    } catch (e) {
      return Failure(SignalingFailure('Failed to publish command: $e'));
    }
  }
}
