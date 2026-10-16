import 'package:cloud_firestore/cloud_firestore.dart';

import 'firestore_constants.dart';

/// How long a session code stays reserved. After that it can be reused and
/// cameras can no longer join with it — this also frees codes of sessions
/// that were never ended (e.g. the admin app was killed).
const sessionCodeLifetime = Duration(hours: 24);

/// Whether a `session_codes` document no longer reserves its code. Documents
/// written before `expiresAt` existed fall back to `createdAt`.
bool isSessionCodeExpired(Map<String, dynamic>? data) {
  if (data == null) return true;
  final expiresAt = data[FirestoreConstants.expiresAt];
  if (expiresAt is Timestamp) return expiresAt.toDate().isBefore(DateTime.now());
  final createdAt = data[FirestoreConstants.createdAt];
  if (createdAt is Timestamp) {
    return createdAt.toDate().add(sessionCodeLifetime).isBefore(DateTime.now());
  }
  return true;
}

/// How long a session's Firestore data is kept. Ending a session deletes it
/// right away; this bound covers sessions that are never ended (app killed,
/// crash). Longer than any realistic session, since a TTL policy may delete
/// a document as soon as it expires.
const sessionDataLifetime = Duration(days: 7);

/// `expiresAt` value for every document written under a session. A Firestore
/// TTL policy on each collection group (see tool/enable_firestore_ttl.sh)
/// deletes expired documents. TTL deletes only the document itself, not its
/// subcollections, so every document needs its own field.
Timestamp sessionDataExpiresAt() =>
    Timestamp.fromDate(DateTime.now().add(sessionDataLifetime));
