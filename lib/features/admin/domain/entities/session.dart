import 'package:equatable/equatable.dart';

enum SessionStatus { waiting, live, ended }

class Session extends Equatable {
  final String sessionId;
  final String adminId;
  final SessionStatus status;

  const Session({
    required this.sessionId,
    required this.adminId,
    required this.status,
  });

  Session copyWith({
    String? sessionId,
    String? adminId,
    SessionStatus? status,
  }) =>
      Session(
        sessionId: sessionId ?? this.sessionId,
        adminId: adminId ?? this.adminId,
        status: status ?? this.status,
      );

  @override
  List<Object?> get props => [sessionId, adminId, status];
}
