// ignore_for_file: type=lint
import 'package:firebase_core/firebase_core.dart' show FirebaseOptions;
import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb, TargetPlatform;

class DefaultFirebaseOptions {
  static FirebaseOptions get currentPlatform {
    if (kIsWeb) throw UnsupportedError('Web not supported');
    return switch (defaultTargetPlatform) {
      TargetPlatform.android => android,
      _ => throw UnsupportedError('Platform not supported'),
    };
  }

  static const FirebaseOptions android = FirebaseOptions(
    apiKey: 'AIzaSyC1L-KtJFhML_nY-zu2ExU5nl5HeMXzG8o',
    appId: '1:91103848718:android:85223c493f145713f08f5f',
    messagingSenderId: '91103848718',
    projectId: 'multicam-studio',
    storageBucket: 'multicam-studio.firebasestorage.app',
    databaseURL: 'https://multicam-studio-default-rtdb.firebaseio.com',
  );
}
