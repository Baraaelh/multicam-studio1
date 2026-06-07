import '../../domain/entities/session.dart';
import '../../domain/repositories/session_repository.dart';
import '../datasources/session_remote_datasource.dart';

class SessionRepositoryImpl implements SessionRepository {
  final SessionRemoteDataSource _dataSource;
  const SessionRepositoryImpl({required SessionRemoteDataSource dataSource})
      : _dataSource = dataSource;

  @override
  Future<String> createSession({required String adminId}) =>
      _dataSource.createSession(adminId: adminId);

  @override
  Future<void> updateStatus(String sessionId, SessionStatus status) =>
      _dataSource.updateStatus(sessionId, status.name);
}
