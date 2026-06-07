import '../../../../core/usecases/use_case.dart';
import '../entities/sdp_info.dart';
import '../repositories/signaling_repository.dart';

class WatchAnswerParams {
  final String sessionId;
  final String peerId;

  const WatchAnswerParams({required this.sessionId, required this.peerId});
}

class WatchAnswer implements StreamUseCase<SdpInfo, WatchAnswerParams> {
  final SignalingRepository _repository;
  const WatchAnswer(this._repository);

  @override
  Stream<SdpInfo> call(WatchAnswerParams params) =>
      _repository.watchAnswer(params.sessionId, params.peerId);
}
