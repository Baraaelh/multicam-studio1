import 'dart:developer' as dev;

import 'package:firebase_app_check/firebase_app_check.dart';
import 'package:flutter/foundation.dart';

/// Use the App Check debug provider instead of Play Integrity.
///
/// Play Integrity only attests apps installed from Google Play. Builds that
/// are installed directly (shared APK, `flutter run`) must use the debug
/// provider, and each device's debug token has to be allowed in Firebase
/// Console → App Check → Apps → Manage debug tokens. Debug builds always use
/// it; release builds opt in with `--dart-define=APP_CHECK_DEBUG=true`.
const bool _useDebugProvider =
    kDebugMode || bool.fromEnvironment('APP_CHECK_DEBUG');

/// Turns on Firebase App Check, so Firestore and Auth can reject requests
/// that don't come from this app (e.g. scripts using the API key from the
/// repository). Must run right after Firebase.initializeApp and before any
/// other Firebase call.
///
/// Requests are only rejected once enforcement is enabled in the console;
/// until then App Check just reports which requests were verified.
Future<void> activateAppCheck() async {
  try {
    await FirebaseAppCheck.instance.activate(
      androidProvider: _useDebugProvider
          ? AndroidProvider.debug
          : AndroidProvider.playIntegrity,
    );
    dev.log(
      'App Check active (${_useDebugProvider ? 'debug' : 'Play Integrity'} provider)',
      name: 'AppCheck',
    );
  } catch (e) {
    // Not fatal: without enforcement requests still go through.
    dev.log('App Check activation failed: $e', name: 'AppCheck');
  }
}
