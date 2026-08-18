import '../entities/ice_candidate_entity.dart';
import '../entities/recording_profile.dart';
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

  Future<void> registerDevice(
    String sessionId,
    String peerId,
    String deviceName,
    List<Map<String, dynamic>> capabilities,
  );

  Stream<String?> watchDeviceName(String sessionId, String peerId);

  /// Returns the sessionId for a given 6-digit code, or null if not found.
  Future<String?> lookupSessionCode(String code);

  /// Emits the full peer list (with capabilities) whenever it changes.
  Stream<List<({String peerId, String? deviceName, List<RecordingProfile> capabilities})>> watchPeers(String sessionId);
}
