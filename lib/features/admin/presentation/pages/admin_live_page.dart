import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:get/get.dart';

import '../../../../core/services/clock_sync_service.dart';
import '../../../../features/session/domain/entities/peer_connection_state.dart';
import '../../../../features/session/presentation/controllers/clock_controller.dart';
import '../../domain/entities/camera_slot.dart';
import '../../domain/entities/session.dart';
import '../controllers/admin_controller.dart';
import '../services/render_service.dart';
import '../widgets/transfer_sheet.dart';

class AdminLivePage extends GetView<AdminController> {
  const AdminLivePage({super.key});

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false, // Prevent accidental back-swipe during live session.
      child: Scaffold(
        backgroundColor: Colors.black,
        body: Obx(() {
          final activeId = controller.activePeerId.value;
          final sessionStatus = controller.session.value?.status;

          return Stack(
            children: [
              // --- Program feed (full screen) ---
              Positioned.fill(child: _ProgramView(activeId: activeId)),

              // --- Top bar ---
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: _TopBar(status: sessionStatus),
              ),

              // --- Zoom controls for the active camera ---
              if (activeId != null)
                Positioned(
                  right: 12,
                  bottom: 210,
                  child: _ZoomControls(
                    controller: controller,
                    peerId: activeId,
                  ),
                ),

              // --- Preview strip + command bar (bottom) ---
              Positioned(
                bottom: 0,
                left: 0,
                right: 0,
                child: _PreviewStrip(controller: controller, activeId: activeId),
              ),
            ],
          );
        }),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Program view — active camera full screen
// ---------------------------------------------------------------------------

class _ProgramView extends GetView<AdminController> {
  final String? activeId;
  const _ProgramView({required this.activeId});

  @override
  Widget build(BuildContext context) {
    if (activeId == null) {
      return const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 16),
            Text('Waiting for cameras…', style: TextStyle(color: Colors.white54)),
          ],
        ),
      );
    }
    final renderer = controller.renderers[activeId!];
    if (renderer == null) {
      return const Center(
        child: Text('No signal', style: TextStyle(color: Colors.white38)),
      );
    }
    return RTCVideoView(
      renderer,
      objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
    );
  }
}

// ---------------------------------------------------------------------------
// Top status bar
// ---------------------------------------------------------------------------

class _TopBar extends StatelessWidget {
  final SessionStatus? status;
  const _TopBar({required this.status});

  @override
  Widget build(BuildContext context) {
    final isLive = status == SessionStatus.live;
    return Container(
      padding: EdgeInsets.fromLTRB(
        16,
        MediaQuery.of(context).padding.top + 8,
        16,
        8,
      ),
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Colors.black87, Colors.transparent],
        ),
      ),
      child: Row(
        children: [
          if (isLive)
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: Colors.red,
                borderRadius: BorderRadius.circular(4),
              ),
              child: const Text(
                'LIVE',
                style: TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 1.4,
                  fontSize: 13,
                ),
              ),
            ),
          const SizedBox(width: 8),
          // Clock sync quality badge
          _SyncBadge(),
          const Spacer(),
          const Text(
            'Multicam Studio',
            style: TextStyle(color: Colors.white70, fontSize: 13),
          ),
        ],
      ),
    );
  }
}

class _SyncBadge extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final clock = Get.find<ClockController>();
    return Obx(() {
      final quality = clock.syncQuality.value;
      if (quality == SyncQuality.unsynced) return const SizedBox.shrink();
      final variance = clock.varianceMs.value;
      final color = quality == SyncQuality.good
          ? Colors.greenAccent.shade400
          : Colors.orange;
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: Colors.black54,
          borderRadius: BorderRadius.circular(4),
          border: Border.all(color: color.withValues(alpha: 0.6)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 6,
              height: 6,
              decoration: BoxDecoration(
                color: color,
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 5),
            Text(
              '±${variance}ms',
              style: TextStyle(
                color: color,
                fontSize: 11,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
      );
    });
  }
}

// ---------------------------------------------------------------------------
// Preview strip — thumbnails + command bar + End Session
// ---------------------------------------------------------------------------

class _PreviewStrip extends StatelessWidget {
  final AdminController controller;
  final String? activeId;
  const _PreviewStrip({required this.controller, required this.activeId});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.bottomCenter,
          end: Alignment.topCenter,
          colors: [Colors.black, Colors.transparent],
        ),
      ),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
          child: Obx(() {
            final slots = controller.slots;
            final isRecording = controller.isRecording.value;
            final hasRecordings = controller.recordings.isNotEmpty;
            return Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // --- Recording command bar ---
                _RecordingBar(
                  isRecording: isRecording,
                  hasRecordings: hasRecordings,
                  onStartRecording: controller.issueStartRecording,
                  onStopRecording: controller.issueStopRecording,
                  onTransfer: () => TransferSheet.show(context),
                ),
                const SizedBox(height: 10),
                // --- Camera thumbnails + End Session ---
                Row(
                  children: [
                    Expanded(
                      child: SizedBox(
                        height: 90,
                        child: ListView.separated(
                          scrollDirection: Axis.horizontal,
                          itemCount: slots.length,
                          separatorBuilder: (_, _) =>
                              const SizedBox(width: 8),
                          itemBuilder: (_, i) => _CameraThumbnail(
                            slot: slots[i],
                            renderer: controller.renderers[slots[i].peerId],
                            isActive: slots[i].peerId == activeId,
                            onTap: () =>
                                controller.switchActiveCamera(slots[i].peerId),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    GestureDetector(
                      onTap: () async {
                        if (Get.find<RenderService>().isRendering.value) {
                          Get.snackbar(
                            'Render in Progress',
                            'Wait for the render to complete before ending the session.',
                            snackPosition: SnackPosition.BOTTOM,
                            duration: const Duration(seconds: 3),
                          );
                          return;
                        }
                        final confirmed = await _confirmEnd(context);
                        if (confirmed == true) {
                          await controller.endSession();
                          Get.back<void>();
                        }
                      },
                      child: Container(
                        width: 64,
                        height: 64,
                        decoration: BoxDecoration(
                          color: Colors.red.shade800,
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: const Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(Icons.stop, color: Colors.white, size: 28),
                            Text(
                              'END',
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 10,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            );
          }),
        ),
      ),
    );
  }

  Future<bool?> _confirmEnd(BuildContext context) => showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('End Session'),
          content: const Text(
            'This will disconnect all cameras and end the live session.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              style: FilledButton.styleFrom(
                backgroundColor: Colors.red.shade700,
              ),
              child: const Text('End Session'),
            ),
          ],
        ),
      );
}

class _RecordingBar extends StatelessWidget {
  final bool isRecording;
  final bool hasRecordings;
  final VoidCallback onStartRecording;
  final VoidCallback onStopRecording;
  final VoidCallback onTransfer;

  const _RecordingBar({
    required this.isRecording,
    required this.hasRecordings,
    required this.onStartRecording,
    required this.onStopRecording,
    required this.onTransfer,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        if (!isRecording) ...[
          FilledButton.icon(
            onPressed: onStartRecording,
            icon: const Icon(Icons.fiber_manual_record, size: 16),
            label: const Text('REC', style: TextStyle(letterSpacing: 1.2)),
            style: FilledButton.styleFrom(
              backgroundColor: Colors.red.shade700,
              minimumSize: const Size(110, 36),
            ),
          ),
          if (hasRecordings) ...[
            const SizedBox(width: 10),
            OutlinedButton.icon(
              onPressed: onTransfer,
              icon: const Icon(Icons.download, size: 16),
              label: const Text('Transfer'),
              style: OutlinedButton.styleFrom(
                foregroundColor: Colors.white70,
                side: const BorderSide(color: Colors.white24),
                minimumSize: const Size(110, 36),
              ),
            ),
          ],
        ] else ...[
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: Colors.red.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.red.shade700),
            ),
            child: const Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.circle, color: Colors.red, size: 10),
                SizedBox(width: 6),
                Text(
                  'RECORDING',
                  style: TextStyle(
                    color: Colors.red,
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 1.2,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          OutlinedButton.icon(
            onPressed: onStopRecording,
            icon: const Icon(Icons.stop, size: 16),
            label: const Text('STOP'),
            style: OutlinedButton.styleFrom(
              foregroundColor: Colors.white70,
              side: const BorderSide(color: Colors.white24),
              minimumSize: const Size(90, 36),
            ),
          ),
        ],
      ],
    );
  }
}

class _CameraThumbnail extends StatelessWidget {
  final CameraSlot slot;
  final RTCVideoRenderer? renderer;
  final bool isActive;
  final VoidCallback onTap;

  const _CameraThumbnail({
    required this.slot,
    required this.renderer,
    required this.isActive,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final ctrl = Get.find<AdminController>();
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 120,
        height: 90,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: isActive ? Colors.red : Colors.white24,
            width: isActive ? 2.5 : 1,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: Stack(
          children: [
            if (renderer != null)
              Positioned.fill(
                child: RTCVideoView(
                  renderer!,
                  objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
                ),
              )
            else
              Center(
                child: Icon(
                  slot.connectionStatus == PeerStatus.connected
                      ? Icons.videocam_off
                      : Icons.hourglass_empty,
                  color: Colors.white38,
                  size: 20,
                ),
              ),
            Positioned(
              bottom: 4,
              left: 4,
              right: 4,
              child: Row(
                children: [
                  Container(
                    width: 6,
                    height: 6,
                    decoration: BoxDecoration(
                      color: _dotColor(slot.connectionStatus),
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 4),
                  Flexible(
                    child: Text(
                      slot.deviceName ?? slot.label,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 10,
                        fontWeight: FontWeight.w600,
                        shadows: [Shadow(blurRadius: 4)],
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
            if (isActive)
              const Positioned(
                top: 4,
                right: 4,
                child: Text(
                  'PGM',
                  style: TextStyle(
                    color: Colors.red,
                    fontSize: 9,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 0.5,
                  ),
                ),
              ),
            // Mute toggle — top-left corner of thumbnail
            Positioned(
              top: 2,
              left: 2,
              child: Obx(() {
                final isMuted = ctrl.mutedCameras[slot.peerId] ?? false;
                return GestureDetector(
                  onTap: () => ctrl.toggleMuteCamera(slot.peerId),
                  child: Container(
                    padding: const EdgeInsets.all(3),
                    decoration: BoxDecoration(
                      color: Colors.black54,
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Icon(
                      isMuted ? Icons.mic_off : Icons.mic,
                      color: isMuted ? Colors.redAccent : Colors.white70,
                      size: 12,
                    ),
                  ),
                );
              }),
            ),
          ],
        ),
      ),
    );
  }

  Color _dotColor(PeerStatus s) => switch (s) {
        PeerStatus.connected => Colors.green,
        PeerStatus.connecting => Colors.orange,
        PeerStatus.failed => Colors.red,
        _ => Colors.grey,
      };
}

// ---------------------------------------------------------------------------
// Zoom controls — overlaid on the program view for the active camera
// ---------------------------------------------------------------------------

class _ZoomControls extends StatelessWidget {
  final AdminController controller;
  final String peerId;

  const _ZoomControls({required this.controller, required this.peerId});

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      final zoom = controller.zoomLevels[peerId] ?? 1.0;
      return Container(
        decoration: BoxDecoration(
          color: Colors.black54,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _ZoomButton(
              icon: Icons.add,
              onTap: () => controller.adjustZoom(peerId, 0.5),
              enabled: zoom < 8.0,
            ),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Text(
                '${zoom.toStringAsFixed(1)}×',
                style: const TextStyle(
                  color: Colors.white70,
                  fontSize: 10,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            _ZoomButton(
              icon: Icons.remove,
              onTap: () => controller.adjustZoom(peerId, -0.5),
              enabled: zoom > 1.0,
            ),
          ],
        ),
      );
    });
  }
}

class _ZoomButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  final bool enabled;

  const _ZoomButton({
    required this.icon,
    required this.onTap,
    required this.enabled,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: enabled ? onTap : null,
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Icon(
          icon,
          color: enabled ? Colors.white : Colors.white24,
          size: 18,
        ),
      ),
    );
  }
}
