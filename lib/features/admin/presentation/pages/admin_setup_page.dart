import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../controllers/admin_controller.dart';
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
            if (s == null)
              _CreateSessionBanner(controller: controller)
            else
              _SessionCodeCard(controller: controller),
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
            'Create a session to generate a session code\nthat cameras can use to join.',
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

class _SessionCodeCard extends StatelessWidget {
  final AdminController controller;
  const _SessionCodeCard({required this.controller});

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      final code = controller.sessionCode.value;
      if (code.isEmpty) return const SizedBox.shrink();

      // Format as "482 917" for readability
      final formatted = '${code.substring(0, 3)} ${code.substring(3)}';

      return Padding(
        padding: const EdgeInsets.fromLTRB(24, 32, 24, 8),
        child: Column(
          children: [
            const Text(
              'SESSION CODE',
              style: TextStyle(
                color: Colors.white38,
                fontSize: 12,
                letterSpacing: 2,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 20),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.05),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: Colors.white12),
              ),
              child: Text(
                formatted,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 52,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 10,
                ),
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              'Share this code with camera operators',
              style: TextStyle(color: Colors.white38, fontSize: 12),
            ),
            const SizedBox(height: 20),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                FilledButton.icon(
                  onPressed: controller.shareCode,
                  icon: const Icon(Icons.share, size: 18),
                  label: const Text('Share Code'),
                  style: FilledButton.styleFrom(
                    minimumSize: const Size(140, 44),
                  ),
                ),
                const SizedBox(width: 12),
                OutlinedButton.icon(
                  onPressed: controller.copyCode,
                  icon: const Icon(Icons.copy, size: 18),
                  label: const Text('Copy Code'),
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size(140, 44),
                    foregroundColor: Colors.white70,
                    side: const BorderSide(color: Colors.white24),
                  ),
                ),
              ],
            ),
          ],
        ),
      );
    });
  }
}

class _BottomActions extends StatelessWidget {
  final AdminController controller;
  const _BottomActions({required this.controller});

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      final s = controller.session.value;
      final isStarting = controller.isStarting.value;

      return SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              FilledButton.icon(
                onPressed: (s != null && !isStarting)
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
