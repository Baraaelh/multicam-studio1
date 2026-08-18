import 'package:equatable/equatable.dart';

class RecordingProfile extends Equatable {
  final int width;
  final int height;
  final int frameRate;
  final String codec;

  const RecordingProfile({
    required this.width,
    required this.height,
    required this.frameRate,
    required this.codec,
  });

  String get label {
    final String res;
    if (height >= 2160) {
      res = '4K';
    } else if (height >= 1440) {
      res = '1440p';
    } else {
      res = '${height}p';
    }
    return '$res • $frameRate FPS • $codec';
  }

  int get quality => width * height * frameRate;

  int get recommendedBitRate {
    final pixels = width * height;
    final hi = frameRate > 30;
    if (pixels >= 3840 * 2160) return hi ? 50_000_000 : 25_000_000;
    if (pixels >= 1920 * 1080) return hi ? 12_000_000 : 8_000_000;
    if (pixels >= 1280 * 720) return hi ? 5_000_000 : 3_000_000;
    return 1_500_000;
  }

  double get storageGbPerHour =>
      recommendedBitRate * 3600 / 8 / (1024 * 1024 * 1024);

  Map<String, dynamic> toMap() => {
        'width': width,
        'height': height,
        'frameRate': frameRate,
        'codec': codec,
      };

  factory RecordingProfile.fromMap(Map<String, dynamic> m) => RecordingProfile(
        width: (m['width'] as num).toInt(),
        height: (m['height'] as num).toInt(),
        frameRate: (m['frameRate'] as num).toInt(),
        codec: m['codec'] as String? ?? 'H264',
      );

  @override
  List<Object?> get props => [width, height, frameRate, codec];
}
