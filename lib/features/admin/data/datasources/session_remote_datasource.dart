import 'package:cloud_firestore/cloud_firestore.dart';

import '../../../../core/constants/firestore_constants.dart';
import '../../../../core/error/exceptions.dart';
import '../../../session/domain/entities/switch_event.dart';

abstract interface class SessionRemoteDataSource {
  Future<String> createSession({required String adminId, required String code});
  Future<void> updateStatus(String sessionId, String status);
  Future<void> initTimeline(String sessionId);
  Future<void> appendSwitchEvent(String sessionId, SwitchEvent event);
  Future<List<SwitchEvent>> fetchTimeline(String sessionId);
}

class FirebaseSessionDataSource implements SessionRemoteDataSource {
  final FirebaseFirestore _firestore;
  const FirebaseSessionDataSource({required FirebaseFirestore firestore})
      : _firestore = firestore;

  @override
  Future<String> createSession({
    required String adminId,
    required String code,
  }) async {
    try {
      final doc = _firestore.collection(FirestoreConstants.sessions).doc();
      await doc.set({
        FirestoreConstants.adminId: adminId,
        FirestoreConstants.status: 'waiting',
        FirestoreConstants.code: code,
        FirestoreConstants.createdAt: FieldValue.serverTimestamp(),
      });
      // Reverse-lookup so cameras resolve code → sessionId in O(1).
      await _firestore
          .collection(FirestoreConstants.sessionCodes)
          .doc(code)
          .set({
        'sessionId': doc.id,
        FirestoreConstants.createdAt: FieldValue.serverTimestamp(),
      });
      return doc.id;
    } on FirebaseException catch (e) {
      throw FirestoreException(e.message ?? 'Firestore error');
    }
  }

  @override
  Future<void> updateStatus(String sessionId, String status) async {
    try {
      await _firestore
          .collection(FirestoreConstants.sessions)
          .doc(sessionId)
          .update({FirestoreConstants.status: status});
    } on FirebaseException catch (e) {
      throw FirestoreException(e.message ?? 'Firestore error');
    }
  }

  @override
  Future<void> initTimeline(String sessionId) async {
    try {
      final col = _firestore
          .collection(FirestoreConstants.sessions)
          .doc(sessionId)
          .collection(FirestoreConstants.timeline);
      // Delete any stale events from a previous recording in this session.
      final existing = await col.get();
      final batch = _firestore.batch();
      for (final doc in existing.docs) {
        batch.delete(doc.reference);
      }
      await batch.commit();
    } on FirebaseException catch (e) {
      throw FirestoreException(e.message ?? 'Firestore error');
    }
  }

  @override
  Future<void> appendSwitchEvent(String sessionId, SwitchEvent event) async {
    try {
      await _firestore
          .collection(FirestoreConstants.sessions)
          .doc(sessionId)
          .collection(FirestoreConstants.timeline)
          .add({
        FirestoreConstants.timelineTimestamp: event.timestamp.toIso8601String(),
        FirestoreConstants.timelinePeerId: event.peerId,
      });
    } on FirebaseException catch (e) {
      throw FirestoreException(e.message ?? 'Firestore error');
    }
  }

  @override
  Future<List<SwitchEvent>> fetchTimeline(String sessionId) async {
    try {
      final snapshot = await _firestore
          .collection(FirestoreConstants.sessions)
          .doc(sessionId)
          .collection(FirestoreConstants.timeline)
          .orderBy(FirestoreConstants.timelineTimestamp)
          .get();
      return snapshot.docs
          .map((doc) => SwitchEvent.fromJson(doc.data()))
          .toList();
    } on FirebaseException catch (e) {
      throw FirestoreException(e.message ?? 'Firestore error');
    }
  }
}
