import '../entities/recording_info.dart';

abstract interface class RecordingRepository {
  Future<void> publishRecording(String sessionId, RecordingInfo info);
  Stream<List<RecordingInfo>> watchRecordings(String sessionId);
}
