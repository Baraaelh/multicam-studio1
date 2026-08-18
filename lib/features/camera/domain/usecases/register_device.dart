import '../../../../core/error/failures.dart';
import '../../../../core/error/result.dart';
import '../../../../core/usecases/use_case.dart';
import '../../../session/domain/repositories/signaling_repository.dart';
import '../../data/datasources/camera_local_datasource.dart';

class RegisterDeviceParams {
  final String sessionId;
  final String peerId;
  const RegisterDeviceParams({required this.sessionId, required this.peerId});
}

class RegisterDevice implements UseCase<void, RegisterDeviceParams> {
  final SignalingRepository _signalingRepository;
  final CameraLocalDataSource _cameraDataSource;

  const RegisterDevice({
    required SignalingRepository signalingRepository,
    required CameraLocalDataSource cameraDataSource,
  })  : _signalingRepository = signalingRepository,
        _cameraDataSource = cameraDataSource;

  @override
  Future<Result<void>> call(RegisterDeviceParams params) async {
    try {
      final deviceName = await _cameraDataSource.getDeviceName();
      final capabilities = await _cameraDataSource.getRecordingCapabilities();
      await _signalingRepository.registerDevice(
        params.sessionId,
        params.peerId,
        deviceName,
        capabilities,
      );
      return const Success(null);
    } catch (e) {
      return Failure(CameraFailure(e.toString()));
    }
  }
}
