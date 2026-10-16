import 'dart:developer' as dev;
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as webrtc;
import 'package:path_provider/path_provider.dart';

import '../../../session/domain/entities/recording_profile.dart';

/// Records the local camera stream to an MP4 file via a native I420VideoRecorder
/// that bypasses EGL entirely.
///
/// flutter_webrtc's MediaRecorder uses VideoFileRenderer which calls EGL
/// swapBuffers internally. On MIUI/MediaTek devices this fails silently,
/// producing a 0-byte file with no Dart-visible error. The native recorder
/// instead attaches directly as a VideoSink on the local VideoTrack and feeds
/// raw I420 frames to MediaCodec, which has no EGL dependency.
class RecordingService {
  static const _tag = 'RecordingService';
  static const _channel =
      MethodChannel('com.multicamstudio.multicam_studio/camera_service');

  String? _currentFilePath;
  bool _isRecording = false;
  // Cached once — the documents directory never changes during app lifetime.
  String? _docsDir;

  bool get isRecording => _isRecording;
  String? get lastFilePath => _currentFilePath;

  /// Resolves and caches the documents directory. Call once at session start
  /// so the path is ready when the timed recording command fires.
  Future<void> warmUp() async {
    _docsDir ??= (await getApplicationDocumentsDirectory()).path;
  }

  Future<void> startRecording({
    required webrtc.MediaStream stream,
    required String peerId,
    bool recordAudio = true,
    RecordingProfile? profile,
  }) async {
    if (_isRecording) return;

    final videoTracks = stream.getVideoTracks();
    final videoTrack = videoTracks.firstOrNull;

    dev.log(
      'startRecording — videoTracks=${videoTracks.length}  '
      'trackId=${videoTrack?.id}  enabled=${videoTrack?.enabled}  '
      'profile=${profile?.label ?? "default"}',
      name: _tag,
    );

    if (videoTrack == null) {
      dev.log('startRecording ABORTED — no video track in stream', name: _tag);
      return;
    }

    // Use cached path; fall back to resolving if warmUp was never called.
    final dir = _docsDir ?? (await getApplicationDocumentsDirectory()).path;
    _docsDir = dir;
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final shortId = peerId.length >= 8 ? peerId.substring(0, 8) : peerId;
    final filename = 'rec_${shortId}_$timestamp.mp4';
    final filePath = '$dir/$filename';

    try {
      final params = <String, dynamic>{
        'trackId': videoTrack.id,
        'outputPath': filePath,
        'recordAudio': recordAudio,
      };
      if (profile != null) {
        params['width'] = profile.width;
        params['height'] = profile.height;
        params['frameRate'] = profile.frameRate;
        params['bitRate'] = profile.recommendedBitRate;
      }
      await _channel.invokeMethod<void>('startRecording', params);
      _currentFilePath = filePath;
      _isRecording = true;
      dev.log('startRecording — started → $filePath', name: _tag);
    } catch (e) {
      dev.log('startRecording FAILED: $e', name: _tag);
    }
  }

  /// Moves the recorder's VideoSink from the current track to the new track's
  /// video track. Must be called after lens switch so the recorder keeps
  /// receiving frames from the new camera.
  Future<void> reattachSink(webrtc.MediaStream stream) async {
    if (!_isRecording) return;
    final videoTrack = stream.getVideoTracks().firstOrNull;
    if (videoTrack == null) return;
    try {
      await _channel.invokeMethod<void>('reattachSink', {
        'trackId': videoTrack.id,
      });
      dev.log('reattachSink — recorder moved to track ${videoTrack.id}', name: _tag);
    } catch (e) {
      dev.log('reattachSink failed: $e', name: _tag);
    }
  }

  /// Stops recording and returns the written [File], or null if nothing was recorded.
  Future<File?> stopRecording() async {
    if (!_isRecording) return null;

    _isRecording = false;
    final path = _currentFilePath;
    _currentFilePath = null;

    try {
      await _channel.invokeMethod<void>('stopRecording');
    } catch (e) {
      dev.log('stopRecording error: $e', name: _tag);
    }

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
