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
  Future<String> addCommand(
    String sessionId,
    CommandType type,
    int bufferMs, {
    String? targetPeerId,
    Map<String, dynamic>? payload,
    int? executeAtMs,
  }) =>
      _dataSource.addCommand(sessionId, {
        FirestoreConstants.commandType: type.name,
        FirestoreConstants.issuedAt: FieldValue.serverTimestamp(),
        FirestoreConstants.bufferMs: bufferMs,
        FirestoreConstants.executeAtMs: ?executeAtMs,
        'targetPeerId': targetPeerId,
        'payload': payload,
      });

  @override
  Stream<SyncCommand> watchCommands(String sessionId, {DateTime? issuedAfter}) =>
      _dataSource.watchCommands(sessionId, issuedAfter: issuedAfter).expand((data) {
        final type = CommandType.tryFromString(
          data[FirestoreConstants.commandType] as String? ?? '',
        );
        if (type == null) return <SyncCommand>[];
        // An explicit executeAtMs (server-equivalent) pins the execution
        // instant so the Firestore and LAN paths fire at exactly the same time.
        // Represented as issuedAt + bufferMs=0, matching the LAN path.
        final executeAtMs =
            (data[FirestoreConstants.executeAtMs] as num?)?.toInt();
        return [
          SyncCommand(
            id: data['id'] as String,
            type: type,
            issuedAt: executeAtMs != null
                ? DateTime.fromMillisecondsSinceEpoch(executeAtMs)
                : (data[FirestoreConstants.issuedAt] as Timestamp).toDate(),
            bufferMs: executeAtMs != null
                ? 0
                : (data[FirestoreConstants.bufferMs] as num).toInt(),
            targetPeerId: data['targetPeerId'] as String?,
            payload: (data['payload'] as Map?)?.cast<String, dynamic>(),
          ),
        ];
      });
}