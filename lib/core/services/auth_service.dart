import 'dart:developer' as dev;

import 'package:firebase_auth/firebase_auth.dart';

/// Signs the device in anonymously so Firestore security rules can tie a
/// session to its admin and each camera document to its device.
///
/// The anonymous account persists across app restarts, so the UID stays the
/// same after a crash and crash recovery can still control its session.
/// Requires the Anonymous provider in Firebase Console → Authentication.
class AuthService {
  final FirebaseAuth _auth;

  AuthService({required FirebaseAuth auth}) : _auth = auth;

  Future<String>? _pending;

  /// UID of the signed-in device, or null before [ensureSignedIn] succeeds.
  String? get uid => _auth.currentUser?.uid;

  /// Returns the device's UID, signing in first if needed. Concurrent callers
  /// share one sign-in. Throws if sign-in fails (offline, provider disabled);
  /// a later call tries again.
  Future<String> ensureSignedIn() {
    final current = uid;
    if (current != null) return Future.value(current);
    return _pending ??= _signIn().whenComplete(() => _pending = null);
  }

  Future<String> _signIn() async {
    final credential = await _auth.signInAnonymously();
    final signedIn = credential.user?.uid;
    if (signedIn == null) {
      throw StateError('Anonymous sign-in returned no user');
    }
    dev.log('signed in anonymously as $signedIn', name: 'AuthService');
    return signedIn;
  }
}
