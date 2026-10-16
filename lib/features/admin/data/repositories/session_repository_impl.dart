import '../../../session/domain/entities/switch_event.dart';
import '../../domain/entities/session.dart';
import '../../domain/repositories/session_repository.dart';
import '../datasources/session_remote_datasource.dart';

class SessionRepositoryImpl implements SessionRepository {
  final SessionRemoteDataSource _dataSource;
  const SessionRepositoryImpl({required SessionRemoteDataSource dataSource})
      : _dataSource = dataSource;

  @override
  Future<({String sessionId, String code})> createSession({
    required String adminId,
    required String Function() nextCode,
  }) =>
      _dataSource.createSession(adminId: adminId, nextCode: nextCode);

  @override
  Future<void> endSession(String sessionId) => _dataSource.endSession(sessionId);

  @override
  Future<void> updateStatus(String sessionId, SessionStatus status) =>
      _dataSource.updateStatus(sessionId, status.name);

  @override
  Future<void> initTimeline(String sessionId) =>
      _dataSource.initTimeline(sessionId);

  @override
  Future<void> appendSwitchEvent(String sessionId, SwitchEvent event) =>
      _dataSource.appendSwitchEvent(sessionId, event);

  @override
  Future<List<SwitchEvent>> fetchTimeline(String sessionId) =>
      _dataSource.fetchTimeline(sessionId);
}
