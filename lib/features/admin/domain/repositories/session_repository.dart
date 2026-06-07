import '../entities/session.dart';

abstract interface class SessionRepository {
  Future<String> createSession({required String adminId});
  Future<void> updateStatus(String sessionId, SessionStatus status);
}
