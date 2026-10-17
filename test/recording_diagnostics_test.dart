import 'package:flutter_test/flutter_test.dart';
import 'package:multicam_studio/features/camera/data/services/recording_service.dart';

void main() {
  String explain(Map<String, dynamic>? d) => RecordingService.explainEmptyRecording(d);

  test('no diagnostics', () {
    expect(explain(null), 'the recorder reported nothing');
  });

  test('no frames reached the recorder', () {
    expect(
      explain({'recorder': 'SurfaceVideoRecorder', 'framesReceived': 0}),
      'no camera frames reached the recorder [SurfaceVideoRecorder]',
    );
  });

  test('surface recording failed', () {
    expect(
      explain({'recorder': 'SurfaceVideoRecorder', 'framesReceived': 90, 'surfaceFailed': true}),
      contains('GPU (surface) recording failed'),
    );
  });

  test('muxer never started because audio never became ready', () {
    expect(
      explain({
        'recorder': 'I420VideoRecorder',
        'framesReceived': 300,
        'videoFormatReady': true,
        'muxerStarted': false,
        'audioIssue': null,
      }),
      'the file was never started (audio: not ready) [I420VideoRecorder]',
    );
  });

  test('encoder never produced output', () {
    expect(
      explain({'recorder': 'I420VideoRecorder', 'framesReceived': 10, 'videoFormatReady': false}),
      contains('the video encoder produced no output'),
    );
  });
}
