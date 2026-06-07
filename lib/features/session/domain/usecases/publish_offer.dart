import '../../../../core/error/exceptions.dart';
import '../../../../core/error/failures.dart';
import '../../../../core/error/result.dart';
import '../../../../core/usecases/use_case.dart';
import '../repositories/signaling_repository.dart';

class PublishOfferParams {
  final String sessionId;
  final String peerId;
  final String sdp;
  final String type;

  const PublishOfferParams({
    required this.sessionId,
    required this.peerId,
    required this.sdp,
    required this.type,
  });
}

class PublishOffer implements UseCase<void, PublishOfferParams> {
  final SignalingRepository _repository;
  const PublishOffer(this._repository);

  @override
  Future<Result<void>> call(PublishOfferParams params) async {
    try {
      await _repository.publishOffer(
        params.sessionId,
        params.peerId,
        params.sdp,
        params.type,
      );
      return const Success(null);
    } on FirestoreException catch (e) {
      return Failure(FirestoreFailure(e.message));
    } catch (e) {
      return Failure(FirestoreFailure(e.toString()));
    }
  }
}
