import 'dart:developer' as dev;

import 'package:cloud_firestore/cloud_firestore.dart';

import '../../../../core/constants/firestore_constants.dart';

abstract interface class ClockRemoteDataSource {
  Future<String> addCommand(String sessionId, Map<String, dynamic> data);
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
  Future<String> addCommand(String sessionId, Map<String, dynamic> data) {
    // .doc() generates the ID client-side with no network call.
    // The actual Firestore write runs in the background so callers get the ID
    // instantly and can dispatch the LAN fast-path without waiting ~300 ms for
    // a server round-trip. The write still completes for Firestore fallback delivery.
    final ref = _commandsCol(sessionId).doc();
    ref.set(data).catchError(
      (Object e) => dev.log('addCommand write failed: $e', name: 'ClockDataSource'),
    );
    return Future.value(ref.id);
  }

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
