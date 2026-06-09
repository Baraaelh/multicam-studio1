import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../../session/domain/entities/recording_info.dart';
import '../controllers/admin_controller.dart';
import '../services/render_service.dart';

class TransferSheet extends StatelessWidget {
  const TransferSheet({super.key});

  static void show(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.grey.shade900,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => const TransferSheet(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ctrl = Get.find<AdminController>();
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 24, 24, 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.white24,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 20),
            const Text(
              'Transfer Recordings',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 4),
            const Text(
              'Download recordings from all cameras to this device.',
              style: TextStyle(color: Colors.white54, fontSize: 13),
            ),
            const SizedBox(height: 20),
            Obx(() {
              final recordings = ctrl.recordings;
              if (recordings.isEmpty) {
                return const Padding(
                  padding: EdgeInsets.symmetric(vertical: 32),
                  child: Center(
                    child: Text(
                      'No recordings available yet.\nStop recording to generate files.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.white38),
                    ),
                  ),
                );
              }
              final hasDownloads = ctrl.downloadedPaths.isNotEmpty;
              return Column(
                children: [
                  ...recordings.map(
                    (info) => _RecordingTile(info: info, controller: ctrl),
                  ),
                  if (hasDownloads) ...[
                    const SizedBox(height: 16),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton.icon(
                        onPressed: () {
                          _prepareAndNavigate(ctrl);
                        },
                        icon: const Icon(Icons.movie_edit, size: 18),
                        label: const Text('Render to Video'),
                        style: FilledButton.styleFrom(
                          backgroundColor: Colors.deepPurpleAccent,
                          minimumSize: const Size.fromHeight(48),
                        ),
                      ),
                    ),
                  ],
                ],
              );
            }),
          ],
        ),
      ),
    );
  }
}

void _prepareAndNavigate(AdminController ctrl) {
  final sources = ctrl.downloadedPaths.entries.map((entry) {
    final filename = entry.key;
    final path = entry.value;
    final info = ctrl.recordings.firstWhereOrNull(
      (r) => r.filename == filename,
    );
    final slot = info != null
        ? ctrl.slots.firstWhereOrNull((s) => s.peerId == info.peerId)
        : null;
    final label =
        slot?.deviceName ?? slot?.label ?? info?.peerId.substring(0, 8) ?? filename;
    return RenderSource(filename: filename, label: label, path: path);
  }).toList();

  // Build timeline segments from admin's switch history so the render engine
  // can produce a single video following the exact switching order.
  final segments = ctrl.buildRenderSegments();

  Get.find<RenderService>().prepare(sources, segments: segments);
  Get.back<void>();
  Get.toNamed<void>('/admin/render');
}

class _RecordingTile extends StatelessWidget {
  final RecordingInfo info;
  final AdminController controller;

  const _RecordingTile({required this.info, required this.controller});

  @override
  Widget build(BuildContext context) {
    final slot = controller.slots.firstWhereOrNull(
      (s) => s.peerId == info.peerId,
    );
    final label = slot?.deviceName ?? slot?.label ?? info.peerId.substring(0, 8);

    return Obx(() {
      final progress = controller.downloadProgress[info.filename];
      final savedPath = controller.downloadedPaths[info.filename];
      final isDownloading = progress != null;
      final isDone = savedPath != null;

      return Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.05),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          children: [
            const Icon(Icons.video_file, color: Colors.white54, size: 32),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label,
                      style: const TextStyle(fontWeight: FontWeight.w600)),
                  Text(
                    info.formattedSize,
                    style: const TextStyle(color: Colors.white54, fontSize: 12),
                  ),
                  if (isDownloading) ...[
                    const SizedBox(height: 6),
                    LinearProgressIndicator(
                      value: progress,
                      backgroundColor: Colors.white12,
                      valueColor:
                          const AlwaysStoppedAnimation<Color>(Colors.blue),
                    ),
                    Text(
                      '${(progress * 100).toStringAsFixed(0)}%',
                      style: const TextStyle(fontSize: 11, color: Colors.white38),
                    ),
                  ],
                  if (isDone)
                    const Text(
                      '✓ Saved',
                      style: TextStyle(color: Colors.green, fontSize: 12),
                    ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            if (!isDownloading && !isDone)
              FilledButton(
                onPressed: () => controller.downloadRecording(info),
                style: FilledButton.styleFrom(
                  backgroundColor: Colors.blueAccent,
                  minimumSize: const Size(80, 36),
                ),
                child: const Text('Download'),
              )
            else if (isDone)
              const Icon(Icons.check_circle, color: Colors.green),
          ],
        ),
      );
    });
  }
}
