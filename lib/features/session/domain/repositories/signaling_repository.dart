import '../entities/ice_candidate_entity.dart';
import '../entities/sdp_info.dart';

abstract interface class SignalingRepository {
  Future<void> publishOffer(
    String sessionId,
    String peerId,
    String sdp,
    String type,
  );

  Future<void> publishAnswer(
    String sessionId,
    String peerId,
    String sdp,
    String type,
  );

  Stream<SdpInfo> watchOffer(String sessionId, String peerId);

  Stream<SdpInfo> watchAnswer(String sessionId, String peerId);

  Future<void> publishIceCandidate(
    String sessionId,
    String peerId,
    IceCandidateEntity candidate, {
    required bool isAdmin,
  });

  Stream<IceCandidateEntity> watchIceCandidates(
    String sessionId,
    String peerId, {
    required bool fromAdmin,
  });

  Future<void> clearSignaling(String sessionId, String peerId);

  Future<void> registerDevice(String sessionId, String peerId, String deviceName);

  Stream<String?> watchDeviceName(String sessionId, String peerId);
}
