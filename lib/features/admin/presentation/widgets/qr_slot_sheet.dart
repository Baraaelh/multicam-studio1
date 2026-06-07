import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../../session/domain/entities/peer_connection_state.dart';
import '../../domain/entities/camera_slot.dart';
import '../controllers/admin_controller.dart';

class QrSlotSheet extends StatelessWidget {
  final CameraSlot slot;

  const QrSlotSheet({super.key, required this.slot});

  static void show(BuildContext context, {required CameraSlot slot}) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.grey.shade900,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => QrSlotSheet(slot: slot),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ctrl = Get.find<AdminController>();
    return SafeArea(
      child: Obx(() {
        // Re-read slot from controller to pick up live deviceName updates.
        final currentSlot = ctrl.slots.firstWhereOrNull(
              (s) => s.peerId == slot.peerId,
            ) ??
            slot;
        final qrJson = ctrl.qrData[slot.peerId] ?? '';
        final pin = ctrl.pinFor(slot.peerId);

        return Padding(
          padding: const EdgeInsets.fromLTRB(24, 24, 24, 32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Drag handle
              Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.white24,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(height: 20),
              Text(
                currentSlot.label,
                style: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                ),
              ),
              if (currentSlot.deviceName != null) ...[
                const SizedBox(height: 4),
                Text(
                  currentSlot.deviceName!,
                  style: const TextStyle(color: Colors.white54, fontSize: 13),
                ),
              ],
              const SizedBox(height: 8),
              Text(
                _statusLabel(currentSlot.connectionStatus),
                style: TextStyle(
                  color: _statusColor(currentSlot.connectionStatus),
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 1.2,
                ),
              ),
              const SizedBox(height: 24),
              // QR code
              if (qrJson.isNotEmpty)
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: QrImageView(
                    data: qrJson,
                    version: QrVersions.auto,
                    size: 240,
                    backgroundColor: Colors.white,
                  ),
                ),
              const SizedBox(height: 20),
              // PIN
              if (pin.isNotEmpty) ...[
                const Text(
                  'VERIFY PIN WITH ADMIN',
                  style: TextStyle(
                    color: Colors.white38,
                    fontSize: 10,
                    letterSpacing: 1.5,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  pin,
                  style: const TextStyle(
                    fontSize: 34,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 12,
                    color: Colors.white,
                  ),
                ),
                const SizedBox(height: 16),
              ],
              Text(
                'Scan with the camera device to join this session',
                style: const TextStyle(color: Colors.white54, fontSize: 13),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              OutlinedButton.icon(
                onPressed: () => ctrl.refreshQrFor(slot.peerId),
                icon: const Icon(Icons.refresh, size: 18),
                label: const Text('Refresh QR (new PIN)'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.white54,
                  side: const BorderSide(color: Colors.white24),
                ),
              ),
            ],
          ),
        );
      }),
    );
  }

  String _statusLabel(PeerStatus s) => switch (s) {
        PeerStatus.idle => 'WAITING FOR SCAN',
        PeerStatus.connecting => 'CONNECTING',
        PeerStatus.connected => 'CONNECTED',
        PeerStatus.disconnected => 'DISCONNECTED',
        PeerStatus.failed => 'FAILED',
      };

  Color _statusColor(PeerStatus s) => switch (s) {
        PeerStatus.connected => Colors.green,
        PeerStatus.connecting => Colors.orange,
        PeerStatus.failed => Colors.red,
        _ => Colors.white38,
      };
}
