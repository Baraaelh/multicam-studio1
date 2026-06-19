import '../../../session/domain/entities/switch_event.dart';
import '../entities/session.dart';

abstract interface class SessionRepository {
  Future<String> createSession({required String adminId, required String code});
  Future<void> updateStatus(String sessionId, SessionStatus status);
  Future<void> initTimeline(String sessionId);
  Future<void> appendSwitchEvent(String sessionId, SwitchEvent event);
  Future<List<SwitchEvent>> fetchTimeline(String sessionId);
}
