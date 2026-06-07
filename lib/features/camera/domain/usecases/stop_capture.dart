import 'package:flutter_webrtc/flutter_webrtc.dart' as webrtc;

import '../../../../core/error/failures.dart';
import '../../../../core/error/result.dart';
import '../../../../core/usecases/use_case.dart';
import '../repositories/camera_repository.dart';

class StopCaptureParams {
  final webrtc.MediaStream stream;
  const StopCaptureParams({required this.stream});
}

class StopCapture implements UseCase<void, StopCaptureParams> {
  final CameraRepository _repository;
  const StopCapture(this._repository);

  @override
  Future<Result<void>> call(StopCaptureParams params) async {
    try {
      await _repository.stopCapture(params.stream);
      return const Success(null);
    } catch (e) {
      return Failure(CameraFailure(e.toString()));
    }
  }
}
