import '../../../../core/error/failures.dart';
import '../../../../core/error/result.dart';
import '../../../../core/services/clock_sync_service.dart';
import '../../../../core/usecases/use_case.dart';

class SyncClockParams {
  const SyncClockParams();
}

class SyncClock implements UseCase<void, SyncClockParams> {
  final ClockSyncService _clockSyncService;
  const SyncClock(this._clockSyncService);

  @override
  Future<Result<void>> call(SyncClockParams params) async {
    try {
      await _clockSyncService.measure();
      return const Success(null);
    } catch (e) {
      return Failure(SignalingFailure('Clock sync failed: $e'));
    }
  }
}
