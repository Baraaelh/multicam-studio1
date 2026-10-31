import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../../../core/constants/join_qr.dart';
import '../controllers/admin_controller.dart';

/// Lets another camera join a session that is already live: the session
/// code as a QR to scan and as digits to type, plus share and copy.
class JoinCodeSheet extends StatelessWidget {
  const JoinCodeSheet({
    super.key,
    required this.code,
    this.onShare,
    this.onCopy,
  });

  final String code;
  final VoidCallback? onShare;
  final VoidCallback? onCopy;

  static Future<void> show(BuildContext context) {
    final controller = Get.find<AdminController>();
    return showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF151B28),
      isScrollControlled: true,
      builder: (_) => JoinCodeSheet(
        code: controller.sessionCode.value,
        onShare: controller.shareCode,
        onCopy: controller.copyCode,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final formatted =
        code.length == 6 ? '${code.substring(0, 3)} ${code.substring(3)}' : code;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 20, 24, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Add a camera',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: Colors.white),
            ),
            const SizedBox(height: 6),
            const Text(
              'On the new phone: Camera Mode › Scan QR, or type the code.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13, color: Colors.white54),
            ),
            const SizedBox(height: 20),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(16),
              ),
              child: QrImageView(
                data: joinQrData(code),
                size: 200,
                backgroundColor: Colors.white,
              ),
            ),
            const SizedBox(height: 16),
            Text(
              formatted,
              style: const TextStyle(
                fontSize: 36,
                fontWeight: FontWeight.bold,
                letterSpacing: 8,
                color: Colors.white,
              ),
            ),
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                FilledButton.icon(
                  onPressed: onShare,
                  icon: const Icon(Icons.share, size: 18),
                  label: const Text('Share'),
                ),
                const SizedBox(width: 12),
                OutlinedButton.icon(
                  onPressed: onCopy,
                  icon: const Icon(Icons.copy, size: 18),
                  label: const Text('Copy'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.white70,
                    side: const BorderSide(color: Colors.white24),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
