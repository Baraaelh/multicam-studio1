import 'dart:async';
import 'dart:developer' as dev;
import 'dart:io';

import 'package:get/get.dart';
import 'package:path_provider/path_provider.dart';

// ignore_for_file: unawaited_futures

import '../../../../core/services/ffmpeg_service.dart';

class RenderSource {
  final String filename;
  final String label;
  final String path;

  const RenderSource({
    required this.filename,
    required this.label,
    required this.path,
  });
}

/// A GetxService — lives for the app lifetime, never disposed by route changes.
/// This decouples the native MediaMuxer background thread from the
/// /admin/render page lifecycle so rendering survives navigation.
class RenderService extends GetxService {
  final FfmpegService _ffmpegService;

  RenderService({required FfmpegService ffmpegService})
      : _ffmpegService = ffmpegService;

  final isRendering = false.obs;
  final isCancelling = false.obs;
  final renderProgress = 0.0.obs;
  final outputPath = Rx<String?>(null);
  final errorMessage = Rx<String?>(null);
  final sources = RxList<RenderSource>();

  // Timeline segments produced from the admin's switch history.
  // Non-empty → timeline render; empty → sequential concatenation fallback.
  final segments = RxList<Map<String, dynamic>>();

  // Studio Audio Mode: path to admin's audio-only recording, or null.
  String? _adminAudioPath;

  /// Called by TransferSheet before navigating to the render page.
  void prepare(
    List<RenderSource> renderSources, {
    List<Map<String, dynamic>>? segments,
    String? adminAudioPath,
  }) {
    if (isRendering.value) return;
    sources.assignAll(renderSources);
    this.segments.assignAll(segments ?? []);
    _adminAudioPath = adminAudioPath;
    outputPath.value = null;
    errorMessage.value = null;
    renderProgress.value = 0;
  }

  static const _tag = 'RenderService';

  Future<void> startRender() async {
    final paths = sources.map((s) => s.path).toList();
    if (paths.isEmpty) return;

    // ── pre-render validation ─────────────────────────────────────────────────
    dev.log(
      'startRender: ${sources.length} source(s), ${segments.length} segment(s)'
      '${_adminAudioPath != null ? ', studioAudio=${_adminAudioPath!.split('/').last}' : ''}',
      name: _tag,
    );

    for (final source in sources) {
      final file = File(source.path);
      final exists = file.existsSync();
      final size = exists ? file.lengthSync() : -1;
      dev.log(
        'source: ${source.filename} label="${source.label}" exists=$exists sizeBytes=$size',
        name: _tag,
      );
      if (!exists) {
        errorMessage.value = 'Input file not found: ${source.filename}';
        dev.log('startRender ABORTED — file not found: ${source.path}', name: _tag);
        return;
      }
      if (size == 0) {
        errorMessage.value = 'Input file is empty (0 bytes): ${source.filename}';
        dev.log('startRender ABORTED — empty file: ${source.path}', name: _tag);
        return;
      }
    }

    if (segments.isNotEmpty) {
      dev.log('segments (${segments.length}):', name: _tag);
      for (var i = 0; i < segments.length; i++) {
        final seg = segments[i];
        final name = (seg['inputPath'] as String? ?? '').split('/').last;
        dev.log(
          '  [$i] file=$name startMs=${seg['startMs']} '
          'durationMs=${seg['durationMs']}'
          '${seg.containsKey('adminAudioStartMs') ? ' adminAudioStartMs=${seg['adminAudioStartMs']}' : ''}',
          name: _tag,
        );
      }
    } else {
      dev.log('no timeline segments — will use sequential merge', name: _tag);
    }

    // ── kick off native render ────────────────────────────────────────────────
    isRendering.value = true;
    renderProgress.value = 0;
    outputPath.value = null;
    errorMessage.value = null;

    final dir = await getApplicationDocumentsDirectory();
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final output = '${dir.path}/render_$timestamp.mp4';
    dev.log('output path: $output', name: _tag);

    final capturedAdminAudioPath = _adminAudioPath;
    final capturedSources = List<RenderSource>.from(sources);
    // Only a finished render may delete its sources — never a cancelled one.
    var completed = false;

    await _ffmpegService.renderGrid(
      inputPaths: paths,
      outputPath: output,
      segments: segments.isEmpty ? null : List<Map<String, dynamic>>.from(segments),
      adminAudioPath: _adminAudioPath,
      onProgress: (p) => renderProgress.value = p,
      onComplete: (path) {
        final size = File(path).existsSync() ? File(path).lengthSync() : -1;
        dev.log(
          'startRender COMPLETE — sizeBytes=$size path=$path',
          name: _tag,
        );
        completed = true;
        outputPath.value = path;
        isRendering.value = false;
        isCancelling.value = false;
        renderProgress.value = 1.0;
        unawaited(_ffmpegService.saveToPublicStorage(path, path.split('/').last));
      },
      onError: (err) {
        dev.log('startRender FAILED — $err', name: _tag);
        errorMessage.value = err;
        isRendering.value = false;
        isCancelling.value = false;
      },
      onCancelled: () {
        // Back to the ready state with sources intact, so the user can
        // render again.
        dev.log('startRender CANCELLED', name: _tag);
        isRendering.value = false;
        isCancelling.value = false;
        renderProgress.value = 0;
      },
    );

    if (completed) {
      _deleteSourceFiles(capturedSources, capturedAdminAudioPath);
    }
  }

  void _deleteSourceFiles(List<RenderSource> renderSources, String? adminAudioPath) {
    for (final source in renderSources) {
      try {
        final f = File(source.path);
        if (f.existsSync()) {
          f.deleteSync();
          dev.log('deleted source: ${source.filename}', name: _tag);
        }
      } catch (e) {
        dev.log('failed to delete ${source.filename}: $e', name: _tag);
      }
    }
    if (adminAudioPath != null) {
      try {
        final f = File(adminAudioPath);
        if (f.existsSync()) {
          f.deleteSync();
          dev.log('deleted admin audio: ${adminAudioPath.split('/').last}', name: _tag);
        }
      } catch (e) {
        dev.log('failed to delete admin audio: $e', name: _tag);
      }
    }
  }

  /// Requests cancellation. [isRendering] stays true until the native render
  /// actually stops; startRender's callbacks then reset the state.
  Future<void> cancelRender() async {
    if (!isRendering.value || isCancelling.value) return;
    isCancelling.value = true;
    await _ffmpegService.cancel();
  }
}
