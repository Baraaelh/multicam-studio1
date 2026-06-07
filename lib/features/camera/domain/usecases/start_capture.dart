import 'package:flutter_webrtc/flutter_webrtc.dart' as webrtc;

import '../../../../core/error/exceptions.dart';
import '../../../../core/error/failures.dart';
import '../../../../core/error/result.dart';
import '../../../../core/usecases/use_case.dart';
import '../entities/local_camera_state.dart';
import '../repositories/camera_repository.dart';

class StartCaptureParams {
  final LensDirection lens;
  const StartCaptureParams({required this.lens});
}

class StartCapture implements UseCase<webrtc.MediaStream, StartCaptureParams> {
  final CameraRepository _repository;
  const StartCapture(this._repository);

  @override
  Future<Result<webrtc.MediaStream>> call(StartCaptureParams params) async {
    try {
      await _repository.requestPermissions();
      final stream = await _repository.startCapture(lens: params.lens);
      return Success(stream);
    } on PermissionDeniedException catch (e) {
      return Failure(CameraFailure(e.message));
    } catch (e) {
      return Failure(CameraFailure(e.toString()));
    }
  }
}
