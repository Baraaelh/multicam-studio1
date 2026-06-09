import 'dart:developer' as dev;
import 'dart:io';

import 'package:flutter_webrtc/flutter_webrtc.dart' as webrtc;
import 'package:path_provider/path_provider.dart';

/// Records the local camera stream to an MP4 file using flutter_webrtc's
/// MediaRecorder.
///
/// Uses the [videoRenderer] (GL texture) path rather than the videoTrack
/// (VideoSink) path. The renderer captures directly from the surface that is
/// already rendering the preview, so frames are never dropped. The VideoSink
/// path creates a secondary consumer that can fall behind the camera produce
/// rate and silently drop frames, leaving a 0-byte file.
///
/// Audio is omitted: the WebRTC audio engine holds the microphone on Android.
/// Passing audioChannel would require a second AudioRecord which fails
/// silently and prevents the MediaMuxer from ever starting (it waits for both
/// video and audio encoder format signals before calling muxer.start()).
class RecordingService {
  static const _tag = 'RecordingService';

  webrtc.MediaRecorder? _recorder;
  String? _currentFilePath;
  bool _isRecording = false;

  bool get isRecording => _isRecording;
  String? get lastFilePath => _currentFilePath;

  Future<void> startRecording({
    required webrtc.RTCVideoRenderer renderer,
    required String peerId,
  }) async {
    if (_isRecording) return;

    dev.log(
      'startRecording — textureId=${renderer.textureId}  '
      'videoWidth=${renderer.videoWidth}  videoHeight=${renderer.videoHeight}',
      name: _tag,
    );

    if (renderer.textureId == null || renderer.textureId == -1) {
      dev.log('startRecording ABORTED — renderer not initialised', name: _tag);
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
      videoRenderer: renderer,
      // audioChannel intentionally omitted — see class-level doc.
    );

    _currentFilePath = filePath;
    _isRecording = true;
    dev.log('startRecording — started → $filePath', name: _tag);
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
