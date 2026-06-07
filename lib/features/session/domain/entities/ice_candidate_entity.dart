import 'package:equatable/equatable.dart';

class IceCandidateEntity extends Equatable {
  final String peerId;
  final String candidate;
  final String sdpMid;
  final int sdpMLineIndex;

  const IceCandidateEntity({
    required this.peerId,
    required this.candidate,
    required this.sdpMid,
    required this.sdpMLineIndex,
  });

  @override
  List<Object?> get props => [peerId, candidate, sdpMid, sdpMLineIndex];
}
