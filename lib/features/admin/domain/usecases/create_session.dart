import '../../../../core/error/exceptions.dart';
import '../../../../core/error/failures.dart';
import '../../../../core/error/result.dart';
import '../../../../core/usecases/use_case.dart';
import '../repositories/session_repository.dart';

class CreateSessionParams {
  final String adminId;
  /// Draws a candidate code; called again if the code is already taken.
  final String Function() nextCode;
  const CreateSessionParams({required this.adminId, required this.nextCode});
}

class CreateSession
    implements UseCase<({String sessionId, String code}), CreateSessionParams> {
  final SessionRepository _repository;
  const CreateSession(this._repository);

  @override
  Future<Result<({String sessionId, String code})>> call(
    CreateSessionParams params,
  ) async {
    try {
      final created = await _repository.createSession(
        adminId: params.adminId,
        nextCode: params.nextCode,
      );
      return Success(created);
    } on FirestoreException catch (e) {
      return Failure(FirestoreFailure(e.message));
    } catch (e) {
      return Failure(FirestoreFailure(e.toString()));
    }
  }
}
