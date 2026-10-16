import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:get/get.dart';

import '../../../../core/services/clock_sync_service.dart';
import '../../../../features/session/domain/entities/peer_connection_state.dart';
import '../../../../features/session/domain/entities/recording_profile.dart';
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
                  onStartRecording: () => _showQualityPicker(context),
                  onStopRecording: controller.issueStopRecording,
                  onTransfer: () => TransferSheet.show(context),
                ),
                const SizedBox(height: 10),
                // --- Camera thumbnails + End Session ---
                Row(
                  children: [
                    Expanded(
                      child: SizedBox(
                        height: 110,
                        child: ListView.separated(
                          scrollDirection: Axis.horizontal,
                          physics: const AlwaysScrollableScrollPhysics(),
                          itemCount: slots.length + (slots.length < 8 ? 1 : 0),
                          separatorBuilder: (_, _) =>
                              const SizedBox(width: 8),
                          itemBuilder: (_, i) {
                            if (i == slots.length) {
                              return _AddCameraButton(
                                onTap: controller.connectNewSlot,
                              );
                            }
                            return _CameraThumbnail(
                              slot: slots[i],
                              renderer: controller.renderers[slots[i].peerId],
                              isActive: slots[i].peerId == activeId,
                              isCoAdmin: controller.coAdminPeerIds
                                  .contains(slots[i].peerId),
                              onTap: () =>
                                  controller.switchActiveCamera(slots[i].peerId),
                            );
                          },
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

  void _showQualityPicker(BuildContext context) {
    final ctrl = Get.find<AdminController>();
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF1A1A1A),
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) => _QualityPickerSheet(controller: ctrl),
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
        FilledButton.icon(
          onPressed: isRecording ? onStopRecording : onStartRecording,
          icon: Icon(
            isRecording ? Icons.stop : Icons.fiber_manual_record,
            size: 16,
          ),
          label: Text(
            isRecording ? 'STOP REC' : 'START REC',
            style: const TextStyle(letterSpacing: 1.2),
          ),
          style: FilledButton.styleFrom(
            backgroundColor:
                isRecording ? Colors.grey.shade800 : Colors.orange.shade800,
            minimumSize: const Size(130, 36),
          ),
        ),
        if (isRecording) ...[
          const SizedBox(width: 10),
          Obx(() {
            final secs =
                Get.find<AdminController>().recordingSeconds.value;
            final h = secs ~/ 3600;
            final m = (secs % 3600) ~/ 60;
            final s = secs % 60;
            return Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
              decoration: BoxDecoration(
                color: Colors.orange.withValues(alpha: 0.15),
                border: Border.all(color: Colors.orange.shade700),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 7,
                    height: 7,
                    decoration: const BoxDecoration(
                      color: Colors.orange,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    '${h.toString().padLeft(2, '0')}:'
                    '${m.toString().padLeft(2, '0')}:'
                    '${s.toString().padLeft(2, '0')}',
                    style: const TextStyle(
                      color: Colors.orange,
                      fontSize: 15,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
            );
          }),
        ],
        if (!isRecording && hasRecordings) ...[
          const SizedBox(width: 10),
          OutlinedButton.icon(
            onPressed: onTransfer,
            icon: const Icon(Icons.folder_open, size: 16),
            label: const Text('Recordings'),
            style: OutlinedButton.styleFrom(
              foregroundColor: Colors.white70,
              side: const BorderSide(color: Colors.white24),
              minimumSize: const Size(110, 36),
            ),
          ),
        ],
      ],
    );
  }
}

class _AddCameraButton extends StatelessWidget {
  final VoidCallback onTap;
  const _AddCameraButton({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 80,
        height: 110,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Colors.white24),
          color: Colors.white.withValues(alpha: 0.05),
        ),
        child: const Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.add, color: Colors.white38, size: 28),
            SizedBox(height: 4),
            Text(
              'Camera',
              style: TextStyle(color: Colors.white38, fontSize: 10),
            ),
          ],
        ),
      ),
    );
  }
}

class _CameraThumbnail extends StatelessWidget {
  final CameraSlot slot;
  final RTCVideoRenderer? renderer;
  final bool isActive;
  final bool isCoAdmin;
  final VoidCallback onTap;

  const _CameraThumbnail({
    required this.slot,
    required this.renderer,
    required this.isActive,
    required this.isCoAdmin,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final ctrl = Get.find<AdminController>();
    return GestureDetector(
      onTap: onTap,
      onLongPress: slot.connectionStatus == PeerStatus.connected
          ? () => _showRoleMenu(context, ctrl)
          : null,
      child: Container(
        width: 120,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: isActive ? Colors.red : Colors.white24,
            width: isActive ? 2.5 : 1,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          mainAxisSize: MainAxisSize.max,
          children: [
            // Video preview area
            SizedBox(
              height: 80,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  Obx(() {
                    final isPaused =
                        ctrl.pausedCameras[slot.peerId] ?? false;
                    if (isPaused) {
                      return Container(
                        color: Colors.black87,
                        child: const Center(
                          child: Icon(
                            Icons.pause_circle_outline,
                            color: Colors.white38,
                            size: 32,
                          ),
                        ),
                      );
                    }
                    if (renderer != null) {
                      return RTCVideoView(
                        renderer!,
                        objectFit:
                            RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
                      );
                    }
                    return Center(
                      child: Icon(
                        slot.connectionStatus == PeerStatus.connected
                            ? Icons.videocam_off
                            : Icons.hourglass_empty,
                        color: Colors.white38,
                        size: 20,
                      ),
                    );
                  }),
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
                  // Mic badge — shown when this camera is the master audio source
                  Obx(() {
                    final masterAudioId = ctrl.masterAudioCameraId.value ?? '';
                    if (masterAudioId.isEmpty || masterAudioId != slot.peerId) {
                      return const SizedBox.shrink();
                    }
                    return const Positioned(
                      bottom: 4,
                      right: 4,
                      child: Icon(Icons.mic, color: Colors.greenAccent, size: 14),
                    );
                  }),
                  if (isCoAdmin)
                    Positioned(
                      top: 4,
                      left: 4,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 4,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.amber.shade700,
                          borderRadius: BorderRadius.circular(3),
                        ),
                        child: const Text(
                          'CO-ADMIN',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 7,
                            fontWeight: FontWeight.bold,
                            letterSpacing: 0.5,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            // Controls bar — pause + mute
            Expanded(
              child: Container(
                color: const Color(0xFF1A1A1A),
                child: Row(
                  children: [
                    // Pause / Resume
                    Expanded(
                      child: Obx(() {
                        final isPaused =
                            ctrl.pausedCameras[slot.peerId] ?? false;
                        return GestureDetector(
                          onTap: () => ctrl.togglePauseCamera(slot.peerId),
                          child: Center(
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  isPaused
                                      ? Icons.play_arrow
                                      : Icons.pause,
                                  size: 13,
                                  color: isPaused
                                      ? Colors.orange
                                      : Colors.white60,
                                ),
                                const SizedBox(width: 2),
                                Text(
                                  isPaused ? 'RESUME' : 'PAUSE',
                                  style: TextStyle(
                                    color: isPaused
                                        ? Colors.orange
                                        : Colors.white60,
                                    fontSize: 8,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        );
                      }),
                    ),
                    Container(width: 1, height: 16, color: Colors.white12),
                    // Audio monitor — local only, no command sent to camera
                    Expanded(
                      child: Obx(() {
                        final isOn =
                            ctrl.liveAudioEnabled[slot.peerId] ?? false;
                        return GestureDetector(
                          onTap: () => ctrl.toggleLiveAudio(slot.peerId),
                          child: Center(
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  isOn ? Icons.mic : Icons.mic_off,
                                  size: 13,
                                  color: isOn
                                      ? Colors.greenAccent
                                      : Colors.white38,
                                ),
                                const SizedBox(width: 2),
                                Text(
                                  isOn ? 'Audio ON' : 'Audio OFF',
                                  style: TextStyle(
                                    color: isOn
                                        ? Colors.greenAccent
                                        : Colors.white38,
                                    fontSize: 8,
                                    fontWeight: FontWeight.bold,
                                  ),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ],
                            ),
                          ),
                        );
                      }),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showRoleMenu(BuildContext context, AdminController ctrl) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF1A1A1A),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                slot.deviceName ?? slot.label,
                style: const TextStyle(
                  color: Colors.white70,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            if (!isCoAdmin)
              ListTile(
                leading: const Icon(Icons.admin_panel_settings,
                    color: Colors.amber),
                title: const Text('Promote to Co-Admin',
                    style: TextStyle(color: Colors.white)),
                onTap: () {
                  Navigator.pop(ctx);
                  ctrl.promoteToCoAdmin(slot.peerId);
                },
              )
            else
              ListTile(
                leading:
                    const Icon(Icons.person_remove, color: Colors.redAccent),
                title: const Text('Revoke Co-Admin',
                    style: TextStyle(color: Colors.white)),
                onTap: () {
                  Navigator.pop(ctx);
                  ctrl.revokeCoAdmin(slot.peerId);
                },
              ),
            const SizedBox(height: 8),
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
          size: 20,
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Quality picker bottom sheet — shown before recording starts
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// Audio source selector — shown inside _QualityPickerSheet
// ---------------------------------------------------------------------------

class _AudioSourceSection extends StatelessWidget {
  final AdminController controller;
  const _AudioSourceSection({required this.controller});

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      final slots = controller.slots;
      final selectedId = controller.masterAudioCameraId.value;
      final isLocked = controller.isRecording.value;

      // Auto-select first camera the first time the sheet opens.
      if (selectedId == null && slots.isNotEmpty) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (controller.masterAudioCameraId.value == null) {
            controller.masterAudioCameraId.value = slots.first.peerId;
          }
        });
      }

      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.mic, color: Colors.white70, size: 16),
              const SizedBox(width: 8),
              const Text(
                'Audio Source',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                ),
              ),
              if (isLocked) ...[
                const SizedBox(width: 8),
                const Text(
                  '(locked during recording)',
                  style: TextStyle(color: Colors.white38, fontSize: 11),
                ),
              ],
            ],
          ),
          const SizedBox(height: 4),
          const Text(
            'One camera records audio for the final mix. Others record video only.',
            style: TextStyle(color: Colors.white38, fontSize: 12),
          ),
          const SizedBox(height: 12),
          // "No Audio" option
          _AudioSourceTile(
            icon: Icons.mic_off,
            label: 'No Audio',
            subtitle: 'All cameras record video only',
            isSelected: selectedId == '',
            isLocked: isLocked,
            onTap: () => controller.masterAudioCameraId.value = '',
          ),
          // Per-camera options
          ...slots.map((slot) {
            final label = slot.deviceName ?? slot.label;
            return _AudioSourceTile(
              icon: Icons.mic,
              label: label,
              subtitle: 'Records audio for the merged output',
              isSelected: selectedId == slot.peerId,
              isLocked: isLocked,
              onTap: () => controller.masterAudioCameraId.value = slot.peerId,
            );
          }),
        ],
      );
    });
  }
}

class _AudioSourceTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final String subtitle;
  final bool isSelected;
  final bool isLocked;
  final VoidCallback onTap;

  const _AudioSourceTile({
    required this.icon,
    required this.label,
    required this.subtitle,
    required this.isSelected,
    required this.isLocked,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final effectiveColor = isLocked ? Colors.white24 : Colors.white;
    final accentColor = isLocked ? Colors.white24 : Colors.greenAccent;
    return GestureDetector(
      onTap: isLocked ? null : onTap,
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: isSelected
              ? Colors.green.withValues(alpha: 0.12)
              : Colors.white.withValues(alpha: 0.05),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: isSelected ? accentColor : Colors.white12,
          ),
        ),
        child: Row(
          children: [
            Icon(icon,
                color: isSelected ? accentColor : Colors.white38, size: 20),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label,
                      style: TextStyle(
                          color: effectiveColor,
                          fontSize: 14,
                          fontWeight: FontWeight.w500)),
                  Text(subtitle,
                      style:
                          const TextStyle(color: Colors.white38, fontSize: 11)),
                ],
              ),
            ),
            if (isSelected)
              Icon(Icons.check_circle, color: accentColor, size: 18),
          ],
        ),
      ),
    );
  }
}

class _QualityPickerSheet extends StatelessWidget {
  final AdminController controller;
  const _QualityPickerSheet({required this.controller});

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.7,
      minChildSize: 0.4,
      maxChildSize: 0.92,
      builder: (_, scrollCtrl) => Obx(() {
        final profiles = controller.compatibleProfiles;
        final selected = controller.selectedProfile.value;
        final slots = controller.slots;
        final knownCount = slots
            .where((s) => controller.cameraCapabilities.containsKey(s.peerId))
            .length;
        final allReported = knownCount == slots.length && slots.isNotEmpty;

        return ListView(
          controller: scrollCtrl,
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
          children: [
            // Handle bar
            Center(
              child: Container(
                width: 40,
                height: 4,
                margin: const EdgeInsets.only(bottom: 20),
                decoration: BoxDecoration(
                  color: Colors.white24,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),

            // Title row
            Row(
              children: [
                const Text(
                  'Recording Quality',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const Spacer(),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    '${slots.length} camera${slots.length == 1 ? '' : 's'}',
                    style: const TextStyle(color: Colors.white70, fontSize: 12),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),

            // Capabilities loading indicator
            if (!allReported && slots.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(
                  'Profiles from $knownCount of ${slots.length} cameras',
                  style: const TextStyle(color: Colors.orange, fontSize: 12),
                ),
              ),

            const SizedBox(height: 16),

            // Profile list
            if (profiles.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 24),
                child: Center(
                  child: Column(
                    children: [
                      SizedBox(
                        width: 24,
                        height: 24,
                        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white38),
                      ),
                      SizedBox(height: 12),
                      Text(
                        'Discovering camera capabilities…',
                        style: TextStyle(color: Colors.white38, fontSize: 13),
                      ),
                    ],
                  ),
                ),
              )
            else
              ...profiles.asMap().entries.map((entry) {
                final idx = entry.key;
                final profile = entry.value;
                final isSelected = selected == profile;
                final isRecommended = idx == 0;
                return _ProfileTile(
                  profile: profile,
                  isSelected: isSelected,
                  isRecommended: isRecommended,
                  onTap: () => controller.selectedProfile.value = profile,
                );
              }),

            const SizedBox(height: 20),
            const Divider(color: Colors.white12),
            const SizedBox(height: 12),

            // Audio source selector
            _AudioSourceSection(controller: controller),

            const SizedBox(height: 20),
            const Divider(color: Colors.white12),
            const SizedBox(height: 12),

            // Session analyzer
            _SessionAnalyzer(controller: controller),

            const SizedBox(height: 24),

            // START RECORDING button
            FilledButton.icon(
              onPressed: () {
                Navigator.pop(context);
                controller.issueStartRecording();
              },
              icon: const Icon(Icons.fiber_manual_record, size: 16),
              label: const Text(
                'START RECORDING',
                style: TextStyle(letterSpacing: 1.2, fontWeight: FontWeight.bold),
              ),
              style: FilledButton.styleFrom(
                backgroundColor: Colors.red.shade700,
                minimumSize: const Size.fromHeight(50),
              ),
            ),
          ],
        );
      }),
    );
  }
}

class _ProfileTile extends StatelessWidget {
  final RecordingProfile profile;
  final bool isSelected;
  final bool isRecommended;
  final VoidCallback onTap;

  const _ProfileTile({
    required this.profile,
    required this.isSelected,
    required this.isRecommended,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: isSelected
              ? Colors.red.shade900.withValues(alpha: 0.5)
              : Colors.white.withValues(alpha: 0.05),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: isSelected ? Colors.red.shade400 : Colors.white12,
            width: isSelected ? 1.5 : 1,
          ),
        ),
        child: Row(
          children: [
            Icon(
              isSelected ? Icons.radio_button_checked : Icons.radio_button_unchecked,
              color: isSelected ? Colors.red.shade300 : Colors.white38,
              size: 20,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                profile.label,
                style: TextStyle(
                  color: isSelected ? Colors.white : Colors.white70,
                  fontSize: 15,
                  fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
                ),
              ),
            ),
            if (isRecommended)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: Colors.green.shade800,
                  borderRadius: BorderRadius.circular(4),
                ),
                child: const Text(
                  'RECOMMENDED',
                  style: TextStyle(
                    color: Colors.greenAccent,
                    fontSize: 9,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 0.8,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _SessionAnalyzer extends StatelessWidget {
  final AdminController controller;
  const _SessionAnalyzer({required this.controller});

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      final selected = controller.selectedProfile.value;
      final profiles = controller.compatibleProfiles;
      final highest = profiles.isNotEmpty ? profiles.first : null;
      final cameraCount = controller.slots.length;
      final allCompat = selected != null && profiles.contains(selected);

      final bitrateMbps = selected != null
          ? (selected.recommendedBitRate / 1_000_000).toStringAsFixed(0)
          : '—';
      final gbPerHour = selected != null
          ? selected.storageGbPerHour.toStringAsFixed(1)
          : '—';
      final totalGb = selected != null && cameraCount > 0
          ? (selected.storageGbPerHour * cameraCount).toStringAsFixed(1)
          : '—';

      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'SESSION ANALYZER',
            style: TextStyle(
              color: Colors.white38,
              fontSize: 11,
              letterSpacing: 1.5,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 12),
          _AnalyzerRow(
            label: 'Connected Cameras',
            value: '$cameraCount',
            valueColor: Colors.white,
          ),
          _AnalyzerRow(
            label: 'Highest Common Profile',
            value: highest?.label ?? '—',
            valueColor: Colors.greenAccent.shade400,
          ),
          _AnalyzerRow(
            label: 'Selected Profile',
            value: selected?.label ?? '—',
            valueColor: Colors.white,
          ),
          _AnalyzerRow(
            label: 'All Cameras Compatible',
            value: allCompat ? 'YES ✓' : 'NO ✗',
            valueColor: allCompat ? Colors.greenAccent : Colors.redAccent,
          ),
          _AnalyzerRow(
            label: 'Estimated Bitrate',
            value: '$bitrateMbps Mbps per camera',
            valueColor: Colors.white70,
          ),
          _AnalyzerRow(
            label: 'Est. Storage / Hour',
            value: '$gbPerHour GB × $cameraCount = $totalGb GB total',
            valueColor: Colors.white70,
          ),
        ],
      );
    });
  }
}

class _AnalyzerRow extends StatelessWidget {
  final String label;
  final String value;
  final Color valueColor;

  const _AnalyzerRow({
    required this.label,
    required this.value,
    required this.valueColor,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        children: [
          Expanded(
            flex: 5,
            child: Text(
              label,
              style: const TextStyle(color: Colors.white54, fontSize: 13),
            ),
          ),
          Expanded(
            flex: 5,
            child: Text(
              value,
              textAlign: TextAlign.right,
              style: TextStyle(
                color: valueColor,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
