import 'dart:developer' as dev;

import 'package:firebase_app_check/firebase_app_check.dart';
import 'package:flutter/foundation.dart';

/// Use Play Integrity instead of the App Check debug provider.
///
/// The app is distributed as a directly installed APK, and Play Integrity
/// only attests apps installed from Google Play, so every build uses the
/// debug provider by default: each device's debug token has to be allowed in
/// Firebase Console → App Check → Apps → Manage debug tokens. A release build
/// published on Google Play opts in with
/// `--dart-define=APP_CHECK_PLAY_INTEGRITY=true`.
const bool _usePlayIntegrity =
    !kDebugMode && bool.fromEnvironment('APP_CHECK_PLAY_INTEGRITY');
const bool _useDebugProvider = !_usePlayIntegrity;

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
