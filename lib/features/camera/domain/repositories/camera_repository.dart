import 'package:flutter_webrtc/flutter_webrtc.dart' as webrtc;

import '../entities/local_camera_state.dart';

abstract interface class CameraRepository {
  Future<void> requestPermissions();

  Future<webrtc.MediaStream> startCapture({required LensDirection lens});

  Future<webrtc.MediaStream> switchLens(
    webrtc.MediaStream currentStream, {
    required LensDirection to,
  });

  Future<void> stopCapture(webrtc.MediaStream stream);
}
