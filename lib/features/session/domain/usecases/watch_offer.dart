import '../../../../core/usecases/use_case.dart';
import '../entities/sdp_info.dart';
import '../repositories/signaling_repository.dart';

class WatchOfferParams {
  final String sessionId;
  final String peerId;

  const WatchOfferParams({required this.sessionId, required this.peerId});
}

class WatchOffer implements StreamUseCase<SdpInfo, WatchOfferParams> {
  final SignalingRepository _repository;
  const WatchOffer(this._repository);

  @override
  Stream<SdpInfo> call(WatchOfferParams params) =>
      _repository.watchOffer(params.sessionId, params.peerId);
}
