import '../../../../core/usecases/use_case.dart';
import '../../../session/domain/repositories/signaling_repository.dart';

class WatchDeviceNameParams {
  final String sessionId;
  final String peerId;
  const WatchDeviceNameParams({required this.sessionId, required this.peerId});
}

class WatchDeviceName implements StreamUseCase<String?, WatchDeviceNameParams> {
  final SignalingRepository _repository;
  const WatchDeviceName(this._repository);

  @override
  Stream<String?> call(WatchDeviceNameParams params) =>
      _repository.watchDeviceName(params.sessionId, params.peerId);
}
