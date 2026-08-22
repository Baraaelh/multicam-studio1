import 'package:cloud_firestore/cloud_firestore.dart';

enum SyncQuality { unsynced, good, degraded }

/// Measures and maintains the clock offset between this device and the
/// Firebase server clock. Uses repeated Firestore round-trips and takes
/// the median to produce a stable estimate.
class ClockSyncService {
  final FirebaseFirestore _firestore;

  ClockSyncService({required FirebaseFirestore firestore})
      : _firestore = firestore;

  // offset = localMid - serverMs  (positive ⟹ device clock is ahead)
  int _offsetMs = 0;
  int _varianceMs = 9999;
  bool _synced = false;

  bool get isSynced => _synced;
  int get offsetMs => _offsetMs;
  int get varianceMs => _varianceMs;

  SyncQuality get quality {
    if (!_synced) return SyncQuality.unsynced;
    return _varianceMs <= 30 ? SyncQuality.good : SyncQuality.degraded;
  }

  /// Converts a server-side [DateTime] to the equivalent local [DateTime].
  DateTime serverToLocal(DateTime serverTime) =>
      serverTime.add(Duration(milliseconds: _offsetMs));

  /// Measures clock offset. Writes [rounds] server-timestamp documents,
  /// reads each back, computes RTT-corrected offsets, and stores the median.
  ///
  /// Uses 3 rounds by default (down from 5) to reduce Firestore round-trips
  /// and improve startup latency. The median of 3 samples is still robust
  /// against outliers.
  Future<void> measure({int rounds = 1}) async {
    final offsets = <int>[];
    final col = _firestore.collection('_clock_probes');
    for (var i = 0; i < rounds; i++) {
      try {
        final t1 = DateTime.now().millisecondsSinceEpoch;
        final ref = col.doc();
        await ref.set({'t': FieldValue.serverTimestamp()});
        final snap = await ref.get();
        final t2 = DateTime.now().millisecondsSinceEpoch;
        ref.delete().ignore(); // fire-and-forget cleanup
        final serverMs =
            (snap.data()!['t'] as Timestamp).millisecondsSinceEpoch;
        final localMid = t1 + (t2 - t1) ~/ 2;
        offsets.add(localMid - serverMs);
      } catch (_) {
        // Skip failed probes — a single failure shouldn't abort the whole sync.
        continue;
      }
    }
    if (offsets.isEmpty) {
      // No successful probes — keep previous state.
      return;
    }
    offsets.sort();
    _offsetMs = offsets[offsets.length ~/ 2];
    _varianceMs = offsets.last - offsets.first;
    _synced = true;
  }
}
