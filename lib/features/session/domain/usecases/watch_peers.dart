import '../entities/peer_info.dart';
import '../repositories/signaling_repository.dart';

class WatchPeers {
  final SignalingRepository _repository;
  const WatchPeers(this._repository);

  Stream<List<PeerInfo>> call(String sessionId) =>
      _repository.watchPeers(sessionId);
}
