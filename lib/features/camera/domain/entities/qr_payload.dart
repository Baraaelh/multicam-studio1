import 'package:equatable/equatable.dart';

class QrPayload extends Equatable {
  final String sessionId;
  final String peerId;
  final String adminId;
  final String label;
  final int expiresAt;
  final String pin;

  const QrPayload({
    required this.sessionId,
    required this.peerId,
    required this.adminId,
    this.label = 'Camera',
    this.expiresAt = 0,
    this.pin = '',
  });

  @override
  List<Object?> get props => [sessionId, peerId, adminId, label, expiresAt, pin];
}
