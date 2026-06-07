import '../../domain/entities/sdp_info.dart';
import '../../../../core/constants/firestore_constants.dart';

class SdpModel {
  final String sdp;
  final String type;

  const SdpModel({required this.sdp, required this.type});

  factory SdpModel.fromMap(Map<String, dynamic> map) => SdpModel(
        sdp: map[FirestoreConstants.sdp] as String,
        type: map[FirestoreConstants.type] as String,
      );

  Map<String, dynamic> toMap() => {
        FirestoreConstants.sdp: sdp,
        FirestoreConstants.type: type,
      };

  SdpInfo toEntity(String sessionId, String peerId) => SdpInfo(
        sessionId: sessionId,
        peerId: peerId,
        sdp: sdp,
        type: SdpType.fromString(type),
      );
}
