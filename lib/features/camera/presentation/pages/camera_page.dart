import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:get/get.dart';

import '../../../../core/services/clock_sync_service.dart';
import '../../../session/domain/entities/peer_connection_state.dart';
import '../../../session/presentation/controllers/clock_controller.dart';
import '../../../session/presentation/controllers/signaling_controller.dart';
import '../../domain/entities/local_camera_state.dart';
import '../controllers/camera_controller.dart';

class CameraPage extends GetView<CameraController> {
  const CameraPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Obx(() {
        final state = controller.cameraState.value;
        final sigCtrl = Get.find<SignalingController>();
        final peerStatus = sigCtrl.peers.values.firstOrNull?.status;
        final label = controller.slotLabel.value;
        final pin = controller.sessionPin.value;
        final isRecording = controller.isRecording.value;

        return Stack(
          children: [
            // Full-screen local preview
            if (state.status == CameraStatus.active ||
                state.status == CameraStatus.switchingLens)
              Positioned.fill(
                child: RTCVideoView(
                  controller.localRenderer,
                  objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
                  mirror: state.lens == LensDirection.front,
                ),
              ),

            if (state.status != CameraStatus.active &&
                state.status != CameraStatus.switchingLens)
              const Positioned.fill(
                child: Center(child: CircularProgressIndicator()),
              ),

            _StatusBanner(
              cameraStatus: state.status,
              peerStatus: peerStatus,
              isRecording: isRecording,
            ),

            if (label.isNotEmpty) _SlotLabelBadge(label: label),

            if (pin != null && peerStatus != PeerStatus.connected)
              _PinBadge(pin: pin),

            // Clock sync quality (below PIN badge, fades in after sync)
            _SyncBadge(),

            if (isRecording) _RecordingBadge(),

            _BottomControls(
              lens: state.lens,
              enabled: state.status == CameraStatus.active,
              onSwitchLens: controller.switchLens,
              onDisconnect: () async {
                await controller.disconnect();
                Get.back<void>();
              },
            ),

            // Co-admin overlay — shown when this device has been promoted.
            // Positioned is a direct Stack child so layout is correct.
            Positioned(
              left: 0,
              right: 0,
              bottom: MediaQuery.of(context).padding.bottom + 110,
              child: Obx(() {
                if (!controller.isCoAdmin.value) return const SizedBox.shrink();
                return _CoAdminOverlay(
                  slots: controller.coAdminSlots,
                  onSwitch: controller.switchCameraForAdmin,
                );
              }),
            ),
          ],
        );
      }),
    );
  }
}

class _StatusBanner extends StatelessWidget {
  final CameraStatus cameraStatus;
  final PeerStatus? peerStatus;
  final bool isRecording;

  const _StatusBanner({
    required this.cameraStatus,
    required this.peerStatus,
    required this.isRecording,
  });

  @override
  Widget build(BuildContext context) {
    final (label, color) = switch (cameraStatus) {
      CameraStatus.active when isRecording => ('REC', Colors.red),
      CameraStatus.active when peerStatus == PeerStatus.connected =>
        ('LIVE', Colors.red),
      CameraStatus.active => ('WAITING', Colors.orange),
      CameraStatus.starting ||
      CameraStatus.requestingPermission =>
        ('STARTING', Colors.orange),
      CameraStatus.switchingLens => ('SWITCHING', Colors.blue),
      CameraStatus.error => ('ERROR', Colors.red.shade900),
      CameraStatus.idle => ('IDLE', Colors.grey),
    };

    return Positioned(
      top: MediaQuery.of(context).padding.top + 16,
      left: 16,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.88),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(
          label,
          style: const TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.bold,
            fontSize: 13,
            letterSpacing: 1.4,
          ),
        ),
      ),
    );
  }
}

class _SlotLabelBadge extends StatelessWidget {
  final String label;
  const _SlotLabelBadge({required this.label});

  @override
  Widget build(BuildContext context) {
    return Positioned(
      top: MediaQuery.of(context).padding.top + 16,
      right: 16,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: Colors.black54,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(
          label,
          style: const TextStyle(
            color: Colors.white70,
            fontSize: 13,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}

class _PinBadge extends StatelessWidget {
  final String pin;
  const _PinBadge({required this.pin});

  @override
  Widget build(BuildContext context) {
    return Positioned(
      top: MediaQuery.of(context).padding.top + 56,
      left: 16,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: Colors.black54,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'VERIFY PIN',
              style: TextStyle(
                color: Colors.white38,
                fontSize: 9,
                letterSpacing: 1.5,
              ),
            ),
            Text(
              pin,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 22,
                fontWeight: FontWeight.bold,
                letterSpacing: 6,
              ),
            ),
          ],
        ),
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
      return Positioned(
        bottom: MediaQuery.of(context).padding.bottom + 110,
        left: 0,
        right: 0,
        child: Center(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: Colors.black54,
              borderRadius: BorderRadius.circular(4),
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
                  'SYNC ±${variance}ms',
                  style: TextStyle(
                    color: color,
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 0.8,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    });
  }
}

class _RecordingBadge extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Positioned(
      top: MediaQuery.of(context).padding.top + 16,
      left: 0,
      right: 0,
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
          decoration: BoxDecoration(
            color: Colors.red.withValues(alpha: 0.9),
            borderRadius: BorderRadius.circular(6),
          ),
          child: const Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.circle, color: Colors.white, size: 8),
              SizedBox(width: 6),
              Text(
                'RECORDING',
                style: TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                  fontSize: 12,
                  letterSpacing: 1.4,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _BottomControls extends StatelessWidget {
  final LensDirection lens;
  final bool enabled;
  final VoidCallback onSwitchLens;
  final VoidCallback onDisconnect;

  const _BottomControls({
    required this.lens,
    required this.enabled,
    required this.onSwitchLens,
    required this.onDisconnect,
  });

  @override
  Widget build(BuildContext context) {
    return Positioned(
      bottom: 0,
      left: 0,
      right: 0,
      child: Container(
        padding: EdgeInsets.fromLTRB(
          24,
          20,
          24,
          MediaQuery.of(context).padding.bottom + 24,
        ),
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.bottomCenter,
            end: Alignment.topCenter,
            colors: [Colors.black87, Colors.transparent],
          ),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            IconButton(
              onPressed: onDisconnect,
              icon: const Icon(Icons.stop_circle_outlined, size: 40),
              color: Colors.red,
              tooltip: 'Disconnect',
            ),
            IconButton(
              onPressed: enabled ? onSwitchLens : null,
              icon: const Icon(Icons.flip_camera_android, size: 40),
              color: enabled ? Colors.white : Colors.white38,
              tooltip: lens == LensDirection.back
                  ? 'Switch to front camera'
                  : 'Switch to back camera',
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Co-Admin overlay — shown when this camera device has been promoted.
// Lets the co-admin switch which camera is on air without access to recording
// or session controls.
// ---------------------------------------------------------------------------

class _CoAdminOverlay extends StatelessWidget {
  final RxList<Map<String, String>> slots;
  final void Function(String peerId) onSwitch;

  const _CoAdminOverlay({required this.slots, required this.onSwitch});

  @override
  Widget build(BuildContext context) {
    return Container(
        margin: const EdgeInsets.symmetric(horizontal: 12),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.82),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: Colors.amber.shade700, width: 1.2),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.admin_panel_settings,
                    color: Colors.amber.shade400, size: 14),
                const SizedBox(width: 6),
                Text(
                  'CO-ADMIN — Switch Camera',
                  style: TextStyle(
                    color: Colors.amber.shade400,
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 0.8,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Obx(() => Wrap(
                  spacing: 8,
                  runSpacing: 6,
                  children: slots.map((s) {
                    final peerId = s['peerId'] ?? '';
                    final label = s['label'] ?? peerId;
                    return GestureDetector(
                      onTap: () => onSwitch(peerId),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 6,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.08),
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(color: Colors.white24),
                        ),
                        child: Text(
                          label,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    );
                  }).toList(),
                )),
          ],
        ),
    );
  }
}
