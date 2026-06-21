import '../../domain/entities/ice_candidate_entity.dart';
import '../../domain/entities/sdp_info.dart';
import '../../domain/repositories/signaling_repository.dart';
import '../datasources/signaling_remote_datasource.dart';
import '../models/ice_candidate_model.dart';
import '../models/sdp_model.dart';

class SignalingRepositoryImpl implements SignalingRepository {
  final SignalingRemoteDataSource _dataSource;
  const SignalingRepositoryImpl({required SignalingRemoteDataSource dataSource})
      : _dataSource = dataSource;

  @override
  Future<void> publishOffer(
    String sessionId,
    String peerId,
    String sdp,
    String type,
  ) =>
      _dataSource.setOfferField(
        sessionId,
        peerId,
        SdpModel(sdp: sdp, type: type).toMap(),
      );

  @override
  Future<void> publishAnswer(
    String sessionId,
    String peerId,
    String sdp,
    String type,
  ) =>
      _dataSource.setAnswerField(
        sessionId,
        peerId,
        SdpModel(sdp: sdp, type: type).toMap(),
      );

  @override
  Stream<SdpInfo> watchOffer(String sessionId, String peerId) =>
      _dataSource
          .watchPeerDocument(sessionId, peerId)
          .map((data) => data?['offer'])
          .where((offer) => offer != null)
          .map((offer) =>
              SdpModel.fromMap(offer as Map<String, dynamic>)
                  .toEntity(sessionId, peerId))
          .distinct();

  @override
  Stream<SdpInfo> watchAnswer(String sessionId, String peerId) =>
      _dataSource
          .watchPeerDocument(sessionId, peerId)
          .map((data) => data?['answer'])
          .where((answer) => answer != null)
          .map((answer) =>
              SdpModel.fromMap(answer as Map<String, dynamic>)
                  .toEntity(sessionId, peerId))
          .distinct();

  @override
  Future<void> publishIceCandidate(
    String sessionId,
    String peerId,
    IceCandidateEntity candidate, {
    required bool isAdmin,
  }) =>
      _dataSource.addCandidate(
        sessionId,
        peerId,
        IceCandidateModel(
          candidate: candidate.candidate,
          sdpMid: candidate.sdpMid,
          sdpMLineIndex: candidate.sdpMLineIndex,
        ).toMap(),
        isAdmin: isAdmin,
      );

  @override
  Stream<IceCandidateEntity> watchIceCandidates(
    String sessionId,
    String peerId, {
    required bool fromAdmin,
  }) =>
      _dataSource
          .watchCandidates(sessionId, peerId, fromAdmin: fromAdmin)
          .map((data) =>
              IceCandidateModel.fromMap(data).toEntity(peerId));

  @override
  Future<void> clearSignaling(String sessionId, String peerId) =>
      _dataSource.clearPeerSignaling(sessionId, peerId);

  @override
  Future<void> registerDevice(
    String sessionId,
    String peerId,
    String deviceName,
  ) =>
      _dataSource.registerDevice(sessionId, peerId, deviceName);

  @override
  Stream<String?> watchDeviceName(String sessionId, String peerId) =>
      _dataSource.watchDeviceName(sessionId, peerId);

  @override
  Future<String?> lookupSessionCode(String code) =>
      _dataSource.lookupSessionCode(code);

  @override
  Stream<List<({String peerId, String? deviceName})>> watchPeers(
    String sessionId,
  ) =>
      _dataSource.watchPeers(sessionId);
}
