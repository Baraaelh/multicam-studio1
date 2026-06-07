import 'package:equatable/equatable.dart';

enum SdpType {
  offer,
  answer;

  static SdpType fromString(String s) =>
      SdpType.values.firstWhere((e) => e.name == s);
}

class SdpInfo extends Equatable {
  final String sessionId;
  final String peerId;
  final String sdp;
  final SdpType type;

  const SdpInfo({
    required this.sessionId,
    required this.peerId,
    required this.sdp,
    required this.type,
  });

  @override
  List<Object?> get props => [sessionId, peerId, sdp, type];
}
