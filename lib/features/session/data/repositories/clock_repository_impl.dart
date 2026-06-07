import 'package:cloud_firestore/cloud_firestore.dart';

import '../../../../core/constants/firestore_constants.dart';
import '../../domain/entities/sync_command.dart';
import '../../domain/repositories/clock_repository.dart';
import '../datasources/clock_remote_datasource.dart';

class ClockRepositoryImpl implements ClockRepository {
  final ClockRemoteDataSource _dataSource;
  const ClockRepositoryImpl({required ClockRemoteDataSource dataSource})
      : _dataSource = dataSource;

  @override
  Future<void> addCommand(
    String sessionId,
    CommandType type,
    int bufferMs,
  ) =>
      _dataSource.addCommand(sessionId, {
        FirestoreConstants.commandType: type.name,
        FirestoreConstants.issuedAt: FieldValue.serverTimestamp(),
        FirestoreConstants.bufferMs: bufferMs,
      });

  @override
  Stream<SyncCommand> watchCommands(String sessionId) =>
      _dataSource.watchCommands(sessionId).map(
            (data) => SyncCommand(
              id: data['id'] as String,
              type: CommandType.fromString(
                data[FirestoreConstants.commandType] as String,
              ),
              issuedAt:
                  (data[FirestoreConstants.issuedAt] as Timestamp).toDate(),
              bufferMs:
                  (data[FirestoreConstants.bufferMs] as num).toInt(),
            ),
          );
}
