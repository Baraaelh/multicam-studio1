import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'app.dart';
import 'core/di/injection.dart';
import 'core/services/ffmpeg_service.dart';
import 'features/admin/presentation/services/render_service.dart';
import 'firebase_options.dart';

Future<void> main() async {     
  WidgetsFlutterBinding.ensureInitialized();

  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );

  configureDependencies();
  // RenderService is a GetxService — it lives for the full app lifetime so the
  // native MediaMuxer background thread is never interrupted by route changes.
  await Get.putAsync<RenderService>(
    () async => RenderService(ffmpegService: getIt<FfmpegService>()),
    permanent: true,
  );

  runApp(const App());
}
