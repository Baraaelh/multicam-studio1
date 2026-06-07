import 'package:cloud_firestore/cloud_firestore.dart';

import '../../../../core/constants/firestore_constants.dart';
import '../../../../core/error/exceptions.dart';

abstract interface class SignalingRemoteDataSource {
  Future<void> setOfferField(
    String sessionId,
    String peerId,
    Map<String, dynamic> data,
  );

  Future<void> setAnswerField(
    String sessionId,
    String peerId,
    Map<String, dynamic> data,
  );

  Stream<Map<String, dynamic>?> watchPeerDocument(
    String sessionId,
    String peerId,
  );

  Future<void> addCandidate(
    String sessionId,
    String peerId,
    Map<String, dynamic> data, {
    required bool isAdmin,
  });

  Stream<Map<String, dynamic>> watchCandidates(
    String sessionId,
    String peerId, {
    required bool fromAdmin,
  });

  Future<void> clearPeerSignaling(String sessionId, String peerId);

  Future<void> registerDevice(String sessionId, String peerId, String deviceName);

  Stream<String?> watchDeviceName(String sessionId, String peerId);
}

class FirebaseSignalingDataSource implements SignalingRemoteDataSource {
  final FirebaseFirestore _firestore;
  const FirebaseSignalingDataSource({required FirebaseFirestore firestore})
      : _firestore = firestore;

  DocumentReference<Map<String, dynamic>> _peerDoc(
          String sessionId, String peerId) =>
      _firestore
          .collection(FirestoreConstants.sessions)
          .doc(sessionId)
          .collection(FirestoreConstants.peers)
          .doc(peerId);

  CollectionReference<Map<String, dynamic>> _candidatesCollection(
    String sessionId,
    String peerId, {
    required bool isAdmin,
  }) =>
      _peerDoc(sessionId, peerId).collection(
        isAdmin
            ? FirestoreConstants.adminCandidates
            : FirestoreConstants.cameraCandidates,
      );

  @override
  Future<void> setOfferField(
    String sessionId,
    String peerId,
    Map<String, dynamic> data,
  ) async {
    try {
      await _peerDoc(sessionId, peerId).set(
        {FirestoreConstants.offer: data},
        SetOptions(merge: true),
      );
    } on FirebaseException catch (e) {
      throw FirestoreException(e.message ?? 'Firestore error');
    }
  }

  @override
  Future<void> setAnswerField(
    String sessionId,
    String peerId,
    Map<String, dynamic> data,
  ) async {
    try {
      await _peerDoc(sessionId, peerId).set(
        {FirestoreConstants.answer: data},
        SetOptions(merge: true),
      );
    } on FirebaseException catch (e) {
      throw FirestoreException(e.message ?? 'Firestore error');
    }
  }

  @override
  Stream<Map<String, dynamic>?> watchPeerDocument(
    String sessionId,
    String peerId,
  ) =>
      _peerDoc(sessionId, peerId)
          .snapshots()
          .map((snap) => snap.data());

  @override
  Future<void> addCandidate(
    String sessionId,
    String peerId,
    Map<String, dynamic> data, {
    required bool isAdmin,
  }) async {
    try {
      await _candidatesCollection(sessionId, peerId, isAdmin: isAdmin).add(data);
    } on FirebaseException catch (e) {
      throw FirestoreException(e.message ?? 'Firestore error');
    }
  }

  @override
  Stream<Map<String, dynamic>> watchCandidates(
    String sessionId,
    String peerId, {
    required bool fromAdmin,
  }) =>
      _candidatesCollection(sessionId, peerId, isAdmin: fromAdmin)
          .snapshots()
          .expand(
            (snapshot) => snapshot.docChanges
                .where((c) => c.type == DocumentChangeType.added)
                .map((c) => c.doc.data()!),
          );

  @override
  Future<void> clearPeerSignaling(String sessionId, String peerId) async {
    try {
      final doc = _peerDoc(sessionId, peerId);

      // Clear SDP fields
      await doc.update({
        FirestoreConstants.offer: FieldValue.delete(),
        FirestoreConstants.answer: FieldValue.delete(),
      });

      // Delete candidate subcollections in batches
      await _deleteCandidates(sessionId, peerId, isAdmin: true);
      await _deleteCandidates(sessionId, peerId, isAdmin: false);
    } on FirebaseException catch (e) {
      throw FirestoreException(e.message ?? 'Firestore error');
    }
  }

  @override
  Future<void> registerDevice(
    String sessionId,
    String peerId,
    String deviceName,
  ) async {
    try {
      await _peerDoc(sessionId, peerId).set(
        {
          'deviceName': deviceName,
          'joinedAt': FieldValue.serverTimestamp(),
        },
        SetOptions(merge: true),
      );
    } on FirebaseException catch (e) {
      throw FirestoreException(e.message ?? 'Firestore error');
    }
  }

  @override
  Stream<String?> watchDeviceName(String sessionId, String peerId) =>
      _peerDoc(sessionId, peerId)
          .snapshots()
          .map((snap) => snap.data()?['deviceName'] as String?);

  Future<void> _deleteCandidates(
    String sessionId,
    String peerId, {
    required bool isAdmin,
  }) async {
    const batchSize = 100;
    while (true) {
      final snap = await _candidatesCollection(sessionId, peerId, isAdmin: isAdmin)
          .limit(batchSize)
          .get();
      if (snap.docs.isEmpty) break;
      final batch = _firestore.batch();
      for (final doc in snap.docs) {
        batch.delete(doc.reference);
      }
      await batch.commit();
    }
  }
}
