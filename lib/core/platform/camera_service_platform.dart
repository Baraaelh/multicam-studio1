import 'package:flutter/services.dart';

class CameraServicePlatform {
  static const _channel = MethodChannel(
    'com.multicamstudio.multicam_studio/camera_service',
  );

  Future<void> start() => _channel.invokeMethod<void>('start');
  Future<void> stop() => _channel.invokeMethod<void>('stop');
}
