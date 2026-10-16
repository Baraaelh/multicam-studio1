import '../../../session/domain/entities/switch_event.dart';
import '../entities/session.dart';

abstract interface class SessionRepository {
  Future<({String sessionId, String code})> createSession({
    required String adminId,
    required String Function() nextCode,
  });
  Future<void> updateStatus(String sessionId, SessionStatus status);
  Future<void> endSession(String sessionId);
  Future<void> initTimeline(String sessionId);
  Future<void> appendSwitchEvent(String sessionId, SwitchEvent event);
  Future<List<SwitchEvent>> fetchTimeline(String sessionId);
}
