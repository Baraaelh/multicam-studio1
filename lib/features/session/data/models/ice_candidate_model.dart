import '../../domain/entities/ice_candidate_entity.dart';
import '../../../../core/constants/firestore_constants.dart';

class IceCandidateModel {
  final String candidate;
  final String sdpMid;
  final int sdpMLineIndex;

  const IceCandidateModel({
    required this.candidate,
    required this.sdpMid,
    required this.sdpMLineIndex,
  });

  factory IceCandidateModel.fromMap(Map<String, dynamic> map) =>
      IceCandidateModel(
        candidate: map[FirestoreConstants.candidate] as String,
        sdpMid: map[FirestoreConstants.sdpMid] as String,
        sdpMLineIndex: (map[FirestoreConstants.sdpMLineIndex] as num).toInt(),
      );

  Map<String, dynamic> toMap() => {
        FirestoreConstants.candidate: candidate,
        FirestoreConstants.sdpMid: sdpMid,
        FirestoreConstants.sdpMLineIndex: sdpMLineIndex,
      };

  IceCandidateEntity toEntity(String peerId) => IceCandidateEntity(
        peerId: peerId,
        candidate: candidate,
        sdpMid: sdpMid,
        sdpMLineIndex: sdpMLineIndex,
      );
}
