import 'package:cloud_firestore/cloud_firestore.dart';

import '../../../../core/constants/firestore_constants.dart';
import '../../../../core/constants/session_lifetime.dart';
import '../../../../core/error/exceptions.dart';
import '../../../session/domain/entities/recording_profile.dart';

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

  Future<void> registerDevice(
    String sessionId,
    String peerId,
    String deviceName,
    List<Map<String, dynamic>> capabilities,
  );

  Stream<String?> watchDeviceName(String sessionId, String peerId);

  /// Looks up a session by its 6-digit code. Returns null if not found.
  Future<String?> lookupSessionCode(String code);

  /// Emits the full peer list (with capabilities) whenever it changes.
  Stream<List<({String peerId, String? deviceName, List<RecordingProfile> capabilities})>> watchPeers(String sessionId);
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
        {
          FirestoreConstants.offer: data,
          FirestoreConstants.expiresAt: sessionDataExpiresAt(),
        },
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
        {
          FirestoreConstants.answer: data,
          FirestoreConstants.expiresAt: sessionDataExpiresAt(),
        },
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
      await _candidatesCollection(sessionId, peerId, isAdmin: isAdmin).add({
        ...data,
        FirestoreConstants.expiresAt: sessionDataExpiresAt(),
      });
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
          )
          // Deduplicate candidates by their candidate string to prevent
          // re-processing the same ICE candidate on Firestore snapshot replays.
          .distinct(
            (a, b) =>
                a[FirestoreConstants.candidate] ==
                b[FirestoreConstants.candidate],
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
    List<Map<String, dynamic>> capabilities,
  ) async {
    try {
      await _peerDoc(sessionId, peerId).set(
        {
          'deviceName': deviceName,
          'joinedAt': FieldValue.serverTimestamp(),
          FirestoreConstants.capabilities: capabilities,
          FirestoreConstants.expiresAt: sessionDataExpiresAt(),
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

  @override
  Future<String?> lookupSessionCode(String code) async {
    try {
      final doc = await _firestore
          .collection(FirestoreConstants.sessionCodes)
          .doc(code)
          .get();
      // An expired code may belong to an abandoned session, or be about to be
      // reused by a new one — never join through it.
      if (!doc.exists || isSessionCodeExpired(doc.data())) return null;
      final sessionId = doc.data()?['sessionId']?.toString();
      if (sessionId == null) return null;
      final session = await _firestore
          .collection(FirestoreConstants.sessions)
          .doc(sessionId)
          .get();
      if (session.data()?[FirestoreConstants.status] == 'ended') return null;
      return sessionId;
    } on FirebaseException catch (e) {
      throw FirestoreException(e.message ?? 'Firestore error');
    }
  }

  @override
  Stream<List<({String peerId, String? deviceName, List<RecordingProfile> capabilities})>> watchPeers(
    String sessionId,
  ) =>
      _firestore
          .collection(FirestoreConstants.sessions)
          .doc(sessionId)
          .collection(FirestoreConstants.peers)
          .snapshots()
          .map((snap) => snap.docs
              .map((doc) => (
                    peerId: doc.id,
                    deviceName: doc.data()['deviceName']?.toString(),
                    capabilities: _parseCapabilities(doc.data()[FirestoreConstants.capabilities]),
                  ))
              .toList());

  static List<RecordingProfile> _parseCapabilities(dynamic raw) {
    if (raw == null) return [];
    try {
      return (raw as List<dynamic>)
          .whereType<Map<Object?, Object?>>()
          .map((m) => RecordingProfile.fromMap(Map<String, dynamic>.from(m)))
          .toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> _deleteCandidates(
    String sessionId,
    String peerId, {
    required bool isAdmin,
  }) async {
    // Firestore batch limit is 500 writes per commit. Use the max batch size
    // to minimize the number of round-trips when cleaning up many candidates.
    const batchSize = 500;
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
