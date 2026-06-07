import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as webrtc;
import 'package:permission_handler/permission_handler.dart';

import '../../../../core/error/exceptions.dart';
import '../../domain/entities/local_camera_state.dart';

abstract interface class CameraLocalDataSource {
  Future<void> requestPermissions();
  Future<webrtc.MediaStream> getUserMedia(LensDirection lens);
  Future<void> disposeStream(webrtc.MediaStream stream);
  Future<String> getDeviceName();
}

class CameraLocalDataSourceImpl implements CameraLocalDataSource {
  static Map<String, dynamic> _buildConstraints(LensDirection lens) => {
        'video': {
          'facingMode': lens == LensDirection.back ? 'environment' : 'user',
          'width': {'ideal': 1920, 'min': 1280},
          'height': {'ideal': 1080, 'min': 720},
          'frameRate': {'ideal': 30, 'max': 30},
        },
        'audio': true,
      };

  @override
  Future<void> requestPermissions() async {
    final statuses = await [
      Permission.camera,
      Permission.microphone,
    ].request();

    if (statuses.values.any((s) => !s.isGranted)) {
      throw const PermissionDeniedException(
        'Camera or microphone permission denied',
      );
    }

    // Android 13+ requires explicit notification permission for the
    // foreground service notification.
    if (Platform.isAndroid) {
      await Permission.notification.request();
    }
  }

  @override
  Future<webrtc.MediaStream> getUserMedia(LensDirection lens) =>
      webrtc.navigator.mediaDevices.getUserMedia(_buildConstraints(lens));

  @override
  Future<void> disposeStream(webrtc.MediaStream stream) async {
    for (final track in stream.getTracks()) {
      await track.stop();
    }
    await stream.dispose();
  }

  @override
  Future<String> getDeviceName() async {
    if (!Platform.isAndroid) return 'Unknown Device';
    final info = await DeviceInfoPlugin().androidInfo;
    final mfr = info.manufacturer;
    final model = info.model;
    // Avoid redundancy: some OEMs prefix model with manufacturer name.
    if (model.toLowerCase().startsWith(mfr.toLowerCase())) return model;
    return '$mfr $model';
  }
}
