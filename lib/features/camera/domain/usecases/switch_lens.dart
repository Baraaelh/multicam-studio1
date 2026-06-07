import 'package:flutter_webrtc/flutter_webrtc.dart' as webrtc;

import '../../../../core/error/failures.dart';
import '../../../../core/error/result.dart';
import '../../../../core/usecases/use_case.dart';
import '../entities/local_camera_state.dart';
import '../repositories/camera_repository.dart';

class SwitchLensParams {
  final webrtc.MediaStream currentStream;
  final LensDirection to;

  const SwitchLensParams({required this.currentStream, required this.to});
}

class SwitchLens implements UseCase<webrtc.MediaStream, SwitchLensParams> {
  final CameraRepository _repository;
  const SwitchLens(this._repository);

  @override
  Future<Result<webrtc.MediaStream>> call(SwitchLensParams params) async {
    try {
      final stream = await _repository.switchLens(
        params.currentStream,
        to: params.to,
      );
      return Success(stream);
    } catch (e) {
      return Failure(CameraFailure(e.toString()));
    }
  }
}
