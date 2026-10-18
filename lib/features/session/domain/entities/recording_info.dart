import 'package:equatable/equatable.dart';

class RecordingInfo extends Equatable {
  final String peerId;
  final String filename;
  final String localIp;
  final int port;
  final int sizeBytes;
  final DateTime recordedAt;

  /// Why this camera's recording failed, or null if it recorded normally.
  /// A failed recording has no file (sizeBytes 0) and is never downloaded.
  final String? failure;

  /// How much later than the take's start instant this file begins, when the
  /// camera had to switch recorders mid-take (e.g. surface → I420 fallback).
  final int startDelayMs;

  const RecordingInfo({
    required this.peerId,
    required this.filename,
    required this.localIp,
    required this.port,
    required this.sizeBytes,
    required this.recordedAt,
    this.failure,
    this.startDelayMs = 0,
  });

  /// No usable file: it failed, or came out empty.
  bool get isEmpty => failure != null || sizeBytes <= 0;

  String get downloadUrl => 'http://$localIp:$port/$filename';

  String get formattedSize {
    if (sizeBytes < 1024 * 1024) {
      return '${(sizeBytes / 1024).toStringAsFixed(1)} KB';
    }
    return '${(sizeBytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  @override
  List<Object?> get props =>
      [peerId, filename, localIp, port, sizeBytes, recordedAt, failure, startDelayMs];
}
