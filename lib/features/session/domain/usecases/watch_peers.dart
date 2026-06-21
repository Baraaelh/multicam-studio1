import '../repositories/signaling_repository.dart';

class WatchPeers {
  final SignalingRepository _repository;
  const WatchPeers(this._repository);

  Stream<List<({String peerId, String? deviceName})>> call(String sessionId) =>
      _repository.watchPeers(sessionId);
}
