import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as webrtc;
import 'package:permission_handler/permission_handler.dart';

import '../../../../core/error/exceptions.dart';
import '../../domain/entities/local_camera_state.dart';

abstract interface class CameraLocalDataSource {
  Future<void> requestPermissions();
  Future<webrtc.MediaStream> getUserMedia(LensDirection lens);
  Future<void> disposeStream(webrtc.MediaStream stream);
  Future<String> getDeviceName();
  Future<List<Map<String, dynamic>>> getRecordingCapabilities();
}

class CameraLocalDataSourceImpl implements CameraLocalDataSource {
  static const _channel =
      MethodChannel('com.multicamstudio.multicam_studio/camera_service');

  static Map<String, dynamic> _buildConstraints(LensDirection lens) => {
        'video': {
          'facingMode': lens == LensDirection.back ? 'environment' : 'user',
          'width': {'ideal': 1920, 'min': 1280},
          'height': {'ideal': 1080, 'min': 720},
          'frameRate': {'ideal': 30, 'max': 30},
        },
        'audio': {
          'echoCancellation': true,
          'noiseSuppression': true,
          'autoGainControl': true,
        },
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

    if (Platform.isAndroid) {
      // Android 13+ requires explicit notification permission for the
      // foreground service notification.
      await Permission.notification.request();

      // Android ≤ 9 needs WRITE_EXTERNAL_STORAGE to copy recordings to the
      // public Movies folder. API 29+ uses MediaStore and needs no permission.
      // Best-effort: denial only means the file won't appear in the file
      // manager; recording and LAN transfer still work.
      final sdk = (await DeviceInfoPlugin().androidInfo).version.sdkInt;
      if (sdk < 29) await Permission.storage.request();
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

  @override
  Future<List<Map<String, dynamic>>> getRecordingCapabilities() async {
    if (!Platform.isAndroid) {
      return [
        {'width': 1920, 'height': 1080, 'frameRate': 30, 'codec': 'H264'},
        {'width': 1280, 'height': 720, 'frameRate': 30, 'codec': 'H264'},
      ];
    }
    try {
      final raw = await _channel.invokeListMethod<Object?>('getRecordingCapabilities');
      if (raw == null) return _fallbackCapabilities();
      return raw
          .whereType<Map<Object?, Object?>>()
          .map((m) => m.cast<String, dynamic>())
          .toList();
    } catch (_) {
      return _fallbackCapabilities();
    }
  }

  static List<Map<String, dynamic>> _fallbackCapabilities() => [
        {'width': 1280, 'height': 720, 'frameRate': 30, 'codec': 'H264'},
      ];
}
