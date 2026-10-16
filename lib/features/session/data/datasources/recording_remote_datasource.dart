import 'package:cloud_firestore/cloud_firestore.dart';

import '../../../../core/constants/firestore_constants.dart';
import '../../../../core/constants/session_lifetime.dart';

abstract interface class RecordingRemoteDataSource {
  Future<void> addRecording(String sessionId, Map<String, dynamic> data);
  Stream<List<Map<String, dynamic>>> watchRecordings(String sessionId);
}

class FirebaseRecordingDataSource implements RecordingRemoteDataSource {
  final FirebaseFirestore _firestore;
  const FirebaseRecordingDataSource({required FirebaseFirestore firestore})
      : _firestore = firestore;

  CollectionReference<Map<String, dynamic>> _col(String sessionId) =>
      _firestore
          .collection(FirestoreConstants.sessions)
          .doc(sessionId)
          .collection(FirestoreConstants.recordings);

  @override
  Future<void> addRecording(String sessionId, Map<String, dynamic> data) =>
      _col(sessionId).add({
        ...data,
        FirestoreConstants.expiresAt: sessionDataExpiresAt(),
      });

  @override
  Stream<List<Map<String, dynamic>>> watchRecordings(String sessionId) =>
      _col(sessionId)
          .snapshots()
          .map((snap) => snap.docs.map((d) => d.data()).toList());
}
