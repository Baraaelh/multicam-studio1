import 'package:equatable/equatable.dart';

enum PeerStatus { idle, connecting, connected, disconnected, failed }

class PeerConnectionState extends Equatable {
  final String peerId;
  final String deviceName;
  final PeerStatus status;
  final bool isActiveCamera;

  const PeerConnectionState({
    required this.peerId,
    required this.deviceName,
    required this.status,
    this.isActiveCamera = false,
  });

  PeerConnectionState copyWith({
    String? peerId,
    String? deviceName,
    PeerStatus? status,
    bool? isActiveCamera,
  }) =>
      PeerConnectionState(
        peerId: peerId ?? this.peerId,
        deviceName: deviceName ?? this.deviceName,
        status: status ?? this.status,
        isActiveCamera: isActiveCamera ?? this.isActiveCamera,
      );

  @override
  List<Object?> get props => [peerId, deviceName, status, isActiveCamera];
}
