import '../../../../core/usecases/use_case.dart';
import '../entities/recording_info.dart';
import '../repositories/recording_repository.dart';

class WatchRecordingsParams {
  final String sessionId;
  const WatchRecordingsParams({required this.sessionId});
}

class WatchRecordings
    implements StreamUseCase<List<RecordingInfo>, WatchRecordingsParams> {
  final RecordingRepository _repository;
  const WatchRecordings(this._repository);

  @override
  Stream<List<RecordingInfo>> call(WatchRecordingsParams params) =>
      _repository.watchRecordings(params.sessionId);
}
