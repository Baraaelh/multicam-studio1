import 'package:cloud_firestore/cloud_firestore.dart';

enum SyncQuality { unsynced, good, degraded }

/// Measures and maintains the clock offset between this device and the
/// Firebase server clock using NTP-style probes over Firestore.
class ClockSyncService {
  final FirebaseFirestore _firestore;

  ClockSyncService({required FirebaseFirestore firestore})
      : _firestore = firestore;

  // offset = localMid - serverMs  (positive ⟹ device clock is ahead)
  int _offsetMs = 0;
  // Worst-case error of [_offsetMs]: half the round-trip of the probe used.
  int _varianceMs = 9999;
  bool _synced = false;

  bool get isSynced => _synced;
  int get offsetMs => _offsetMs;

  /// Error bound (±ms) of the current offset estimate.
  int get varianceMs => _varianceMs;

  SyncQuality get quality {
    if (!_synced) return SyncQuality.unsynced;
    return _varianceMs <= 30 ? SyncQuality.good : SyncQuality.degraded;
  }

  /// Converts a server-side [DateTime] to the equivalent local [DateTime].
  DateTime serverToLocal(DateTime serverTime) =>
      serverTime.add(Duration(milliseconds: _offsetMs));

  /// Measures clock offset with [rounds] probes and keeps the one with the
  /// shortest round-trip.
  ///
  /// Only the write is timed: the server stamps `t` while committing it, so
  /// the server time lies inside [t1, t2] and the midpoint is off by at most
  /// rtt/2. The read-back happens afterwards and is excluded, otherwise its
  /// latency (which differs per device) would skew the midpoint.
  ///
  /// The shortest round-trip has the tightest bound and is least affected by
  /// queueing delay, so it beats a median. The first probe also pays the
  /// connection warm-up, which this discards naturally.
  Future<void> measure({int rounds = 5}) async {
    final col = _firestore.collection('_clock_probes');
    int? bestRtt;
    int? bestOffset;
    for (var i = 0; i < rounds; i++) {
      final ref = col.doc();
      try {
        final t1 = DateTime.now().millisecondsSinceEpoch;
        await ref.set({'t': FieldValue.serverTimestamp()});
        final t2 = DateTime.now().millisecondsSinceEpoch;

        final snap = await ref.get(const GetOptions(source: Source.server));
        final serverMs =
            (snap.data()!['t'] as Timestamp).millisecondsSinceEpoch;

        final rtt = t2 - t1;
        if (bestRtt == null || rtt < bestRtt) {
          bestRtt = rtt;
          bestOffset = (t1 + rtt ~/ 2) - serverMs;
        }
      } catch (_) {
        // Skip failed probes — a single failure shouldn't abort the whole sync.
      } finally {
        ref.delete().ignore(); // fire-and-forget cleanup
      }
    }
    if (bestRtt == null || bestOffset == null) {
      // No successful probes — keep previous state.
      return;
    }
    _offsetMs = bestOffset;
    _varianceMs = (bestRtt + 1) ~/ 2;
    _synced = true;
  }
}
