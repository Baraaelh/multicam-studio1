import 'package:cloud_firestore/cloud_firestore.dart';

import '../../../../core/constants/firestore_constants.dart';

abstract interface class ClockRemoteDataSource {
  Future<void> addCommand(String sessionId, Map<String, dynamic> data);
  Stream<Map<String, dynamic>> watchCommands(String sessionId, {DateTime? issuedAfter});
}

class FirebaseClockDataSource implements ClockRemoteDataSource {
  final FirebaseFirestore _firestore;
  const FirebaseClockDataSource({required FirebaseFirestore firestore})
      : _firestore = firestore;

  CollectionReference<Map<String, dynamic>> _commandsCol(String sessionId) =>
      _firestore
          .collection(FirestoreConstants.sessions)
          .doc(sessionId)
          .collection(FirestoreConstants.commands);

  @override
  Future<void> addCommand(String sessionId, Map<String, dynamic> data) =>
      _commandsCol(sessionId).add(data);

  @override
  Stream<Map<String, dynamic>> watchCommands(
    String sessionId, {
    DateTime? issuedAfter,
  }) {
    // Filter at the Firestore level so the initial snapshot replay does not
    // include historical commands from earlier in the same session.
    Query<Map<String, dynamic>> query = _commandsCol(sessionId);
    if (issuedAfter != null) {
      query = query.where(
        FirestoreConstants.issuedAt,
        isGreaterThanOrEqualTo: Timestamp.fromDate(issuedAfter),
      );
    }
    return query.snapshots().expand(
          (snap) => snap.docChanges
              .where((c) => c.type == DocumentChangeType.added)
              // Guard: skip locally-cached writes where serverTimestamp is unresolved.
              .where((c) => c.doc.data()?[FirestoreConstants.issuedAt] != null)
              .map((c) => {'id': c.doc.id, ...c.doc.data()!}),
        );
  }
}
