import 'package:cloud_firestore/cloud_firestore.dart';

import '../../../../core/constants/firestore_constants.dart';
import '../../domain/entities/recording_info.dart';
import '../../domain/repositories/recording_repository.dart';
import '../datasources/recording_remote_datasource.dart';

class RecordingRepositoryImpl implements RecordingRepository {
  final RecordingRemoteDataSource _dataSource;
  const RecordingRepositoryImpl({required RecordingRemoteDataSource dataSource})
      : _dataSource = dataSource;

  @override
  Future<void> publishRecording(String sessionId, RecordingInfo info) =>
      _dataSource.addRecording(sessionId, {
        FirestoreConstants.peerId: info.peerId,
        FirestoreConstants.recordingFilename: info.filename,
        FirestoreConstants.localIp: info.localIp,
        FirestoreConstants.recordingPort: info.port,
        FirestoreConstants.sizeBytes: info.sizeBytes,
        FirestoreConstants.recordedAt: FieldValue.serverTimestamp(),
        FirestoreConstants.recordingFailure: ?info.failure,
      });

  @override
  Stream<List<RecordingInfo>> watchRecordings(String sessionId) =>
      _dataSource.watchRecordings(sessionId).map(
            (list) => list
                .map(
                  (data) => RecordingInfo(
                    peerId: data[FirestoreConstants.peerId] as String,
                    filename: data[FirestoreConstants.recordingFilename] as String,
                    localIp: data[FirestoreConstants.localIp] as String,
                    port: (data[FirestoreConstants.recordingPort] as num).toInt(),
                    sizeBytes: (data[FirestoreConstants.sizeBytes] as num).toInt(),
                    recordedAt: data[FirestoreConstants.recordedAt] is Timestamp
                        ? (data[FirestoreConstants.recordedAt] as Timestamp)
                            .toDate()
                        : DateTime.now(),
                    failure: data[FirestoreConstants.recordingFailure] as String?,
                  ),
                )
                .toList(),
          );
}
