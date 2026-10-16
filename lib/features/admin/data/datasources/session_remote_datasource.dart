import 'dart:async';
import 'dart:developer' as dev;

import 'package:cloud_firestore/cloud_firestore.dart';

import '../../../../core/constants/firestore_constants.dart';
import '../../../../core/constants/session_lifetime.dart';
import '../../../../core/error/exceptions.dart';
import '../../../../core/services/auth_service.dart';
import '../../../session/domain/entities/switch_event.dart';

abstract interface class SessionRemoteDataSource {
  /// Creates a session under a code from [nextCode] that no live session
  /// holds, retrying with a new code on collision.
  Future<({String sessionId, String code})> createSession({
    required String adminId,
    required String Function() nextCode,
  });
  Future<void> updateStatus(String sessionId, String status);

  /// Marks the session ended and frees its code for reuse.
  Future<void> endSession(String sessionId);
  Future<void> initTimeline(String sessionId);
  Future<void> appendSwitchEvent(String sessionId, SwitchEvent event);
  Future<List<SwitchEvent>> fetchTimeline(String sessionId);
}

class FirebaseSessionDataSource implements SessionRemoteDataSource {
  final FirebaseFirestore _firestore;
  final AuthService _auth;
  const FirebaseSessionDataSource({
    required FirebaseFirestore firestore,
    required AuthService auth,
  })  : _firestore = firestore,
        _auth = auth;

  static const _maxCodeAttempts = 5;

  @override
  Future<({String sessionId, String code})> createSession({
    required String adminId,
    required String Function() nextCode,
  }) async {
    try {
      final adminUid = await _auth.ensureSignedIn();
      for (var attempt = 0; attempt < _maxCodeAttempts; attempt++) {
        final code = nextCode();
        final codeRef =
            _firestore.collection(FirestoreConstants.sessionCodes).doc(code);
        final sessionRef =
            _firestore.collection(FirestoreConstants.sessions).doc();
        // Claim the code and create the session atomically: two admins
        // drawing the same code can't both get it, and a live session's
        // code is never overwritten (which would send its cameras into the
        // new session).
        final claimed = await _firestore.runTransaction<bool>((tx) async {
          final existing = await tx.get(codeRef);
          if (existing.exists && !isSessionCodeExpired(existing.data())) {
            return false;
          }
          tx.set(sessionRef, {
            FirestoreConstants.adminId: adminId,
            FirestoreConstants.adminUid: adminUid,
            FirestoreConstants.status: 'waiting',
            FirestoreConstants.code: code,
            FirestoreConstants.createdAt: FieldValue.serverTimestamp(),
            FirestoreConstants.expiresAt: sessionDataExpiresAt(),
          });
          // Reverse-lookup so cameras resolve code → sessionId in O(1).
          tx.set(codeRef, {
            'sessionId': sessionRef.id,
            FirestoreConstants.createdAt: FieldValue.serverTimestamp(),
            FirestoreConstants.expiresAt: Timestamp.fromDate(
              DateTime.now().add(sessionCodeLifetime),
            ),
          });
          return true;
        });
        if (claimed) return (sessionId: sessionRef.id, code: code);
      }
      throw const FirestoreException(
        'Could not get a free session code. Please try again.',
      );
    } on FirebaseException catch (e) {
      throw FirestoreException(e.message ?? 'Firestore error');
    }
  }

  @override
  Future<void> endSession(String sessionId) async {
    await _auth.ensureSignedIn();
    try {
      final sessionRef =
          _firestore.collection(FirestoreConstants.sessions).doc(sessionId);
      await _firestore.runTransaction<void>((tx) async {
        final session = await tx.get(sessionRef);
        final code = session.data()?[FirestoreConstants.code] as String?;
        if (code != null) {
          final codeRef =
              _firestore.collection(FirestoreConstants.sessionCodes).doc(code);
          final codeDoc = await tx.get(codeRef);
          // Only free the code if it still points here; it may already have
          // expired and been claimed by another session.
          if (codeDoc.data()?['sessionId'] == sessionId) tx.delete(codeRef);
        }
        tx.update(sessionRef, {FirestoreConstants.status: 'ended'});
      });
    } on FirebaseException catch (e) {
      throw FirestoreException(e.message ?? 'Firestore error');
    }
    // Not awaited: the session is already ended and its code freed, so the
    // admin doesn't wait on hundreds of deletes. If the app closes midway,
    // the leftovers expire through TTL (expiresAt).
    unawaited(_deleteSessionData(sessionId));
  }

  /// Deletes everything stored for a session: peers with their ICE candidate
  /// subcollections, commands, recordings, timeline, then the session doc.
  /// Firestore doesn't delete subcollections with their parent, so each is
  /// cleared explicitly, children first.
  Future<void> _deleteSessionData(String sessionId) async {
    final sessionRef =
        _firestore.collection(FirestoreConstants.sessions).doc(sessionId);
    try {
      final peers =
          await sessionRef.collection(FirestoreConstants.peers).get();
      for (final peer in peers.docs) {
        await _deleteCollection(
          peer.reference.collection(FirestoreConstants.adminCandidates),
        );
        await _deleteCollection(
          peer.reference.collection(FirestoreConstants.cameraCandidates),
        );
      }
      for (final name in const [
        FirestoreConstants.peers,
        FirestoreConstants.commands,
        FirestoreConstants.recordings,
        FirestoreConstants.timeline,
      ]) {
        await _deleteCollection(sessionRef.collection(name));
      }
      await sessionRef.delete();
      dev.log('deleted data of session $sessionId', name: 'SessionDataSource');
    } catch (e) {
      dev.log('cleanup of session $sessionId failed: $e', name: 'SessionDataSource');
    }
  }

  Future<void> _deleteCollection(
    CollectionReference<Map<String, dynamic>> col,
  ) async {
    // Batches are limited to 500 writes.
    const batchSize = 400;
    while (true) {
      final snap = await col.limit(batchSize).get();
      if (snap.docs.isEmpty) return;
      final batch = _firestore.batch();
      for (final doc in snap.docs) {
        batch.delete(doc.reference);
      }
      await batch.commit();
    }
  }

  @override
  Future<void> updateStatus(String sessionId, String status) async {
    await _auth.ensureSignedIn();
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
    await _auth.ensureSignedIn();
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
    await _auth.ensureSignedIn();
    try {
      await _firestore
          .collection(FirestoreConstants.sessions)
          .doc(sessionId)
          .collection(FirestoreConstants.timeline)
          .add({
        FirestoreConstants.timelineTimestamp: event.timestamp.toIso8601String(),
        FirestoreConstants.timelinePeerId: event.peerId,
        FirestoreConstants.expiresAt: sessionDataExpiresAt(),
      });
    } on FirebaseException catch (e) {
      throw FirestoreException(e.message ?? 'Firestore error');
    }
  }

  @override
  Future<List<SwitchEvent>> fetchTimeline(String sessionId) async {
    await _auth.ensureSignedIn();
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
