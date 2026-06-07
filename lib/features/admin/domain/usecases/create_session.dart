import '../../../../core/error/exceptions.dart';
import '../../../../core/error/failures.dart';
import '../../../../core/error/result.dart';
import '../../../../core/usecases/use_case.dart';
import '../repositories/session_repository.dart';

class CreateSessionParams {
  final String adminId;
  const CreateSessionParams({required this.adminId});
}

class CreateSession implements UseCase<String, CreateSessionParams> {
  final SessionRepository _repository;
  const CreateSession(this._repository);

  @override
  Future<Result<String>> call(CreateSessionParams params) async {
    try {
      final id = await _repository.createSession(adminId: params.adminId);
      return Success(id);
    } on FirestoreException catch (e) {
      return Failure(FirestoreFailure(e.message));
    } catch (e) {
      return Failure(FirestoreFailure(e.toString()));
    }
  }
}
