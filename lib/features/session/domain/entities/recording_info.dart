import 'package:equatable/equatable.dart';

class RecordingInfo extends Equatable {
  final String peerId;
  final String filename;
  final String localIp;
  final int port;
  final int sizeBytes;
  final DateTime recordedAt;

  const RecordingInfo({
    required this.peerId,
    required this.filename,
    required this.localIp,
    required this.port,
    required this.sizeBytes,
    required this.recordedAt,
  });

  String get downloadUrl => 'http://$localIp:$port/$filename';

  String get formattedSize {
    if (sizeBytes < 1024 * 1024) {
      return '${(sizeBytes / 1024).toStringAsFixed(1)} KB';
    }
    return '${(sizeBytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  @override
  List<Object?> get props => [peerId, filename, localIp, port, sizeBytes, recordedAt];
}
