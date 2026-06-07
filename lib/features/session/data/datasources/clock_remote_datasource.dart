import 'package:cloud_firestore/cloud_firestore.dart';

import '../../../../core/constants/firestore_constants.dart';

abstract interface class ClockRemoteDataSource {
  Future<void> addCommand(String sessionId, Map<String, dynamic> data);
  Stream<Map<String, dynamic>> watchCommands(String sessionId);
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
  Stream<Map<String, dynamic>> watchCommands(String sessionId) =>
      _commandsCol(sessionId).snapshots().expand(
            (snap) => snap.docChanges
                .where((c) => c.type == DocumentChangeType.added)
                // Guard: skip locally-cached writes where serverTimestamp is unresolved.
                .where((c) => c.doc.data()?[FirestoreConstants.issuedAt] != null)
                .map((c) => {'id': c.doc.id, ...c.doc.data()!}),
          );
}
