import '../../../../core/error/exceptions.dart';
import '../../../../core/error/failures.dart';
import '../../../../core/error/result.dart';
import '../../../../core/usecases/use_case.dart';
import '../entities/ice_candidate_entity.dart';
import '../repositories/signaling_repository.dart';

class PublishIceCandidateParams {
  final String sessionId;
  final String peerId;
  final IceCandidateEntity candidate;
  final bool isAdmin;

  const PublishIceCandidateParams({
    required this.sessionId,
    required this.peerId,
    required this.candidate,
    required this.isAdmin,
  });
}

class PublishIceCandidate
    implements UseCase<void, PublishIceCandidateParams> {
  final SignalingRepository _repository;
  const PublishIceCandidate(this._repository);

  @override
  Future<Result<void>> call(PublishIceCandidateParams params) async {
    try {
      await _repository.publishIceCandidate(
        params.sessionId,
        params.peerId,
        params.candidate,
        isAdmin: params.isAdmin,
      );
      return const Success(null);
    } on FirestoreException catch (e) {
      return Failure(FirestoreFailure(e.message));
    } catch (e) {
      return Failure(FirestoreFailure(e.toString()));
    }
  }
}
