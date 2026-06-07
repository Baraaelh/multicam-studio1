import 'package:cloud_firestore/cloud_firestore.dart';

import '../../../../core/constants/firestore_constants.dart';
import '../../../../core/error/exceptions.dart';

abstract interface class SessionRemoteDataSource {
  Future<String> createSession({required String adminId});
  Future<void> updateStatus(String sessionId, String status);
}

class FirebaseSessionDataSource implements SessionRemoteDataSource {
  final FirebaseFirestore _firestore;
  const FirebaseSessionDataSource({required FirebaseFirestore firestore})
      : _firestore = firestore;

  @override
  Future<String> createSession({required String adminId}) async {
    try {
      final doc = _firestore.collection(FirestoreConstants.sessions).doc();
      await doc.set({
        FirestoreConstants.adminId: adminId,
        FirestoreConstants.status: 'waiting',
        // Firebase serverTimestamp — never device clock per architecture contract.
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
}
