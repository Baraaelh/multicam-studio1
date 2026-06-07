import '../../../../core/error/failures.dart';
import '../../../../core/error/result.dart';
import '../../../../core/usecases/use_case.dart';
import '../entities/recording_info.dart';
import '../repositories/recording_repository.dart';

class PublishRecordingInfoParams {
  final String sessionId;
  final RecordingInfo info;
  const PublishRecordingInfoParams({
    required this.sessionId,
    required this.info,
  });
}

class PublishRecordingInfo implements UseCase<void, PublishRecordingInfoParams> {
  final RecordingRepository _repository;
  const PublishRecordingInfo(this._repository);

  @override
  Future<Result<void>> call(PublishRecordingInfoParams params) async {
    try {
      await _repository.publishRecording(params.sessionId, params.info);
      return const Success(null);
    } catch (e) {
      return Failure(SignalingFailure('Failed to publish recording info: $e'));
    }
  }
}
