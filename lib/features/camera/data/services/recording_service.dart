import 'dart:developer' as dev;
import 'dart:io';

import 'package:flutter_webrtc/flutter_webrtc.dart' as webrtc;
import 'package:path_provider/path_provider.dart';

/// Wraps flutter_webrtc's MediaRecorder to write a local camera stream
/// to an MP4 (video-only) file in the app's documents directory.
///
/// Audio is intentionally omitted: flutter_webrtc's WebRTC audio engine holds
/// an exclusive AudioRecord on the microphone on Android < 10. Opening a
/// second AudioRecord via audioChannel: INPUT fails silently at the native
/// layer and causes the MediaMuxer to never call muxer.start() (it waits for
/// both the video and audio encoder format signals). Result: 0-byte file even
/// though the recorder reports no error. Video-only recording avoids the
/// conflict and gives a valid, playable MP4.
class RecordingService {
  static const _tag = 'RecordingService';

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

    final videoTracks = stream.getVideoTracks();
    final videoTrack = videoTracks.firstOrNull;

    dev.log(
      'startRecording — videoTracks=${videoTracks.length}  '
      'trackId=${videoTrack?.id}  trackEnabled=${videoTrack?.enabled}',
      name: _tag,
    );

    if (videoTrack == null) {
      dev.log('startRecording ABORTED — no video track in stream', name: _tag);
      return;
    }

    final dir = await getApplicationDocumentsDirectory();
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final shortId = peerId.length >= 8 ? peerId.substring(0, 8) : peerId;
    final filename = 'rec_${shortId}_$timestamp.mp4';
    final filePath = '${dir.path}/$filename';

    _recorder = webrtc.MediaRecorder();
    await _recorder!.start(
      filePath,
      videoTrack: videoTrack,
      // audioChannel intentionally omitted — see class-level doc.
    );

    _currentFilePath = filePath;
    _isRecording = true;
    dev.log('startRecording — MediaRecorder started → $filePath', name: _tag);
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
    final exists = await file.exists();
    final size = exists ? await file.length() : -1;
    dev.log(
      'stopRecording — exists=$exists  size=${size}B  path=$path',
      name: _tag,
    );

    return exists ? file : null;
  }

  Future<void> dispose() async {
    if (_isRecording) await stopRecording();
  }
}
