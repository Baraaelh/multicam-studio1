import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../../../features/session/domain/entities/peer_connection_state.dart';
import '../../domain/entities/camera_slot.dart';
import '../controllers/admin_controller.dart';
import '../widgets/qr_slot_sheet.dart';
import 'admin_live_page.dart';

class AdminSetupPage extends GetView<AdminController> {
  const AdminSetupPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Admin Mode'),
        actions: [
          Obx(() {
            final s = controller.session.value;
            if (s == null) return const SizedBox.shrink();
            return Padding(
              padding: const EdgeInsets.only(right: 16),
              child: Center(
                child: Text(
                  'ID: ${s.sessionId.substring(0, 8)}…',
                  style: const TextStyle(fontSize: 12, color: Colors.white54),
                ),
              ),
            );
          }),
        ],
      ),
      body: Obx(() {
        final s = controller.session.value;
        return Column(
          children: [
            if (s == null) _CreateSessionBanner(controller: controller),
            if (s != null) _SlotList(controller: controller),
            const Spacer(),
            _BottomActions(controller: controller),
          ],
        );
      }),
    );
  }
}

class _CreateSessionBanner extends StatelessWidget {
  final AdminController controller;
  const _CreateSessionBanner({required this.controller});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        children: [
          const Icon(Icons.video_camera_back, size: 64, color: Colors.white24),
          const SizedBox(height: 16),
          const Text(
            'Create a session to generate camera QR codes',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white54),
          ),
          const SizedBox(height: 24),
          FilledButton.icon(
            onPressed: controller.createSession,
            icon: const Icon(Icons.add_circle_outline),
            label: const Text('Create Session'),
            style: FilledButton.styleFrom(minimumSize: const Size(220, 48)),
          ),
        ],
      ),
    );
  }
}

class _SlotList extends StatelessWidget {
  final AdminController controller;
  const _SlotList({required this.controller});

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Obx(() {
        final slots = controller.slots;
        if (slots.isEmpty) {
          return const Center(
            child: Text(
              'No camera slots yet.\nTap "Add Camera" to create one.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white38),
            ),
          );
        }
        return ListView.separated(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          itemCount: slots.length,
          separatorBuilder: (_, _) => const SizedBox(height: 8),
          itemBuilder: (context, i) =>
              _SlotTile(slot: slots[i], controller: controller),
        );
      }),
    );
  }
}

class _SlotTile extends StatelessWidget {
  final CameraSlot slot;
  final AdminController controller;
  const _SlotTile({required this.slot, required this.controller});

  @override
  Widget build(BuildContext context) {
    final statusColor = switch (slot.connectionStatus) {
      PeerStatus.connected => Colors.green,
      PeerStatus.connecting => Colors.orange,
      PeerStatus.failed => Colors.red,
      _ => Colors.white24,
    };

    return ListTile(
      tileColor: Colors.white.withValues(alpha: 0.05),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      leading: Container(
        width: 12,
        height: 12,
        decoration: BoxDecoration(color: statusColor, shape: BoxShape.circle),
      ),
      title: Text(slot.label),
      subtitle: slot.deviceName != null
          ? Text(
              slot.deviceName!,
              style: const TextStyle(fontSize: 11, color: Colors.white54),
            )
          : Text(
              slot.connectionStatus.name.toUpperCase(),
              style: TextStyle(fontSize: 11, color: statusColor, letterSpacing: 1),
            ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            icon: const Icon(Icons.qr_code),
            tooltip: 'Show QR',
            onPressed: () => QrSlotSheet.show(context, slot: slot),
          ),
          IconButton(
            icon: const Icon(Icons.close, color: Colors.red),
            tooltip: 'Remove slot',
            onPressed: () => controller.removeSlot(slot.peerId),
          ),
        ],
      ),
    );
  }
}

class _BottomActions extends StatelessWidget {
  final AdminController controller;
  const _BottomActions({required this.controller});

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      final s = controller.session.value;
      final slots = controller.slots;
      final isStarting = controller.isStarting.value;

      return SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (s != null)
                OutlinedButton.icon(
                  onPressed: slots.length < 4
                      ? controller.addCameraSlot
                      : null,
                  icon: const Icon(Icons.add),
                  label: Text(
                    slots.length < 4
                        ? 'Add Camera Slot (${slots.length}/4)'
                        : 'Maximum 4 cameras',
                  ),
                ),
              if (s != null) const SizedBox(height: 8),
              FilledButton.icon(
                onPressed: (s != null && slots.isNotEmpty && !isStarting)
                    ? () async {
                        await controller.startSession();
                        Get.to<void>(() => const AdminLivePage());
                      }
                    : null,
                icon: isStarting
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Icon(Icons.play_circle),
                label: Text(isStarting ? 'Starting…' : 'Go Live'),
                style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(50),
                  backgroundColor: Colors.red.shade700,
                ),
              ),
            ],
          ),
        ),
      );
    });
  }
}
