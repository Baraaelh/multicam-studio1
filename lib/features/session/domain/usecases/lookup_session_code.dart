import '../../../../core/error/exceptions.dart';
import '../../../../core/error/failures.dart';
import '../../../../core/error/result.dart';
import '../repositories/signaling_repository.dart';

class LookupSessionCode {
  final SignalingRepository _repository;
  const LookupSessionCode(this._repository);

  Future<Result<String>> call(String code) async {
    try {
      final sessionId = await _repository.lookupSessionCode(code);
      if (sessionId == null) {
        return const Failure(FirestoreFailure('Session not found. Check the code and try again.'));
      }
      return Success(sessionId);
    } on FirestoreException catch (e) {
      return Failure(FirestoreFailure(e.message));
    } catch (e) {
      return Failure(FirestoreFailure(e.toString()));
    }
  }
}
