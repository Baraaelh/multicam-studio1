import '../../../../core/error/exceptions.dart';
import '../../../../core/error/failures.dart';
import '../../../../core/error/result.dart';
import '../../../../core/usecases/use_case.dart';
import '../repositories/signaling_repository.dart';

class ClearSignalingParams {
  final String sessionId;
  final String peerId;

  const ClearSignalingParams({
    required this.sessionId,
    required this.peerId,
  });
}

class ClearSignaling implements UseCase<void, ClearSignalingParams> {
  final SignalingRepository _repository;
  const ClearSignaling(this._repository);

  @override
  Future<Result<void>> call(ClearSignalingParams params) async {
    try {
      await _repository.clearSignaling(params.sessionId, params.peerId);
      return const Success(null);
    } on FirestoreException catch (e) {
      return Failure(FirestoreFailure(e.message));
    } catch (e) {
      return Failure(FirestoreFailure(e.toString()));
    }
  }
}
