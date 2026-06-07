import '../../../../core/usecases/use_case.dart';
import '../entities/ice_candidate_entity.dart';
import '../repositories/signaling_repository.dart';

class WatchIceCandidatesParams {
  final String sessionId;
  final String peerId;
  final bool fromAdmin;

  const WatchIceCandidatesParams({
    required this.sessionId,
    required this.peerId,
    required this.fromAdmin,
  });
}

class WatchIceCandidates
    implements StreamUseCase<IceCandidateEntity, WatchIceCandidatesParams> {
  final SignalingRepository _repository;
  const WatchIceCandidates(this._repository);

  @override
  Stream<IceCandidateEntity> call(WatchIceCandidatesParams params) =>
      _repository.watchIceCandidates(
        params.sessionId,
        params.peerId,
        fromAdmin: params.fromAdmin,
      );
}
