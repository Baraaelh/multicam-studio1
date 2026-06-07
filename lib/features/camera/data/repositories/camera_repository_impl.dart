import 'package:flutter_webrtc/flutter_webrtc.dart' as webrtc;

import '../../domain/entities/local_camera_state.dart';
import '../../domain/repositories/camera_repository.dart';
import '../datasources/camera_local_datasource.dart';

class CameraRepositoryImpl implements CameraRepository {
  final CameraLocalDataSource _dataSource;

  const CameraRepositoryImpl({required CameraLocalDataSource dataSource})
      : _dataSource = dataSource;

  @override
  Future<void> requestPermissions() => _dataSource.requestPermissions();

  @override
  Future<webrtc.MediaStream> startCapture({required LensDirection lens}) =>
      _dataSource.getUserMedia(lens);

  @override
  Future<webrtc.MediaStream> switchLens(
    webrtc.MediaStream currentStream, {
    required LensDirection to,
  }) async {
    await _dataSource.disposeStream(currentStream);
    return _dataSource.getUserMedia(to);
  }

  @override
  Future<void> stopCapture(webrtc.MediaStream stream) =>
      _dataSource.disposeStream(stream);
}
