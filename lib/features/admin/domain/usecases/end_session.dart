import '../../../../core/error/exceptions.dart';
import '../../../../core/error/failures.dart';
import '../../../../core/error/result.dart';
import '../../../../core/usecases/use_case.dart';
import '../repositories/session_repository.dart';

class EndSessionParams {
  final String sessionId;
  const EndSessionParams({required this.sessionId});
}

class EndSession implements UseCase<void, EndSessionParams> {
  final SessionRepository _repository;
  const EndSession(this._repository);

  @override
  Future<Result<void>> call(EndSessionParams params) async {
    try {
      await _repository.endSession(params.sessionId);
      return const Success(null);
    } on FirestoreException catch (e) {
      return Failure(FirestoreFailure(e.message));
    } catch (e) {
      return Failure(FirestoreFailure(e.toString()));
    }
  }
}
