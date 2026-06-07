import 'package:equatable/equatable.dart';

import '../../../session/domain/entities/peer_connection_state.dart';

class CameraSlot extends Equatable {
  final String peerId;
  final String label;
  final String? deviceName;
  final PeerStatus connectionStatus;

  const CameraSlot({
    required this.peerId,
    required this.label,
    this.deviceName,
    this.connectionStatus = PeerStatus.idle,
  });

  CameraSlot copyWith({
    String? peerId,
    String? label,
    String? deviceName,
    PeerStatus? connectionStatus,
  }) =>
      CameraSlot(
        peerId: peerId ?? this.peerId,
        label: label ?? this.label,
        deviceName: deviceName ?? this.deviceName,
        connectionStatus: connectionStatus ?? this.connectionStatus,
      );

  @override
  List<Object?> get props => [peerId, label, deviceName, connectionStatus];
}
