import 'dart:developer' as dev;

import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'app.dart';
import 'core/di/injection.dart';
import 'core/services/app_check_service.dart';
import 'core/services/auth_service.dart';
import 'core/services/ffmpeg_service.dart';
import 'features/admin/presentation/services/render_service.dart';
import 'firebase_options.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );
  // Before any other Firebase call, so every request carries a token.
  await activateAppCheck();

  configureDependencies();
  // Every Firestore request needs a signed-in device. Failing here (e.g.
  // offline) is not fatal: creating or joining a session signs in again.
  try {
    await getIt<AuthService>().ensureSignedIn();
  } catch (e) {
    dev.log('startup sign-in failed: $e', name: 'main');
  }
  // RenderService is a GetxService — it lives for the full app lifetime so the
  // native MediaMuxer background thread is never interrupted by route changes.
  await Get.putAsync<RenderService>(
    () async => RenderService(ffmpegService: getIt<FfmpegService>()),
    permanent: true,
  );

  runApp(const App());
}
