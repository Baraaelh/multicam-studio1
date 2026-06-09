import 'dart:io';

import 'package:flutter_webrtc/flutter_webrtc.dart' as webrtc;
import 'package:path_provider/path_provider.dart';
import 'package:webrtc_interface/webrtc_interface.dart';

/// Wraps flutter_webrtc's MediaRecorder to write a local camera stream
/// to an MP4 file in the app's documents directory.
class RecordingService {
  webrtc.MediaRecorder? _recorder;
  String? _currentFilePath;
  bool _isRecording = false;

  bool get isRecording => _isRecording;
  String? get lastFilePath => _currentFilePath;

  Future<void> startRecording({
    required webrtc.MediaStream stream,
    required String peerId,
  }) async {
    if (_isRecording) return;

    final dir = await getApplicationDocumentsDirectory();
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final shortId = peerId.length >= 8 ? peerId.substring(0, 8) : peerId;
    final filename = 'rec_${shortId}_$timestamp.mp4';
    final filePath = '${dir.path}/$filename';

    _recorder = webrtc.MediaRecorder();
    await _recorder!.start(
      filePath,
      videoTrack: stream.getVideoTracks().firstOrNull,
      audioChannel: RecorderAudioChannel.INPUT,
    );
    _currentFilePath = filePath;
    _isRecording = true;
  }

  /// Stops recording and returns the written [File], or null if nothing was recorded.
  Future<File?> stopRecording() async {
    if (!_isRecording || _recorder == null) return null;

    await _recorder!.stop();
    _recorder = null;
    _isRecording = false;

    final path = _currentFilePath;
    _currentFilePath = null;
    if (path == null) return null;

    final file = File(path);
    return await file.exists() ? file : null;
  }

  Future<void> dispose() async {
    if (_isRecording) await stopRecording();
  }
}
