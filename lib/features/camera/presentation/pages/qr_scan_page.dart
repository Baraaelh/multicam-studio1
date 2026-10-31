import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';

import '../controllers/camera_controller.dart';
import 'join_qr_scanner_page.dart';

class CodeJoinPage extends StatefulWidget {
  const CodeJoinPage({super.key});

  @override
  State<CodeJoinPage> createState() => _CodeJoinPageState();
}

class _CodeJoinPageState extends State<CodeJoinPage> {
  final _codeController = TextEditingController();
  bool _loading = false;
  String? _error;

  @override
  void dispose() {
    _codeController.dispose();
    super.dispose();
  }

  Future<void> _scanQr() async {
    final code = await Get.to<String>(() => const JoinQrScannerPage());
    if (code == null || !mounted) return;
    _codeController.text = code;
    await _join();
  }

  Future<void> _join() async {
    final code = _codeController.text.trim();
    if (code.length != 6) {
      setState(() => _error = 'Enter a 6-digit code');
      return;
    }

    setState(() {
      _loading = true;
      _error = null;
    });

    final controller = Get.find<CameraController>();
    final result = await controller.resolveSessionCode(code);

    if (!mounted) return;
    result.fold(
      onSuccess: (payload) {
        // Navigate first, then start camera (same pattern as previous QR flow).
        Get.toNamed<void>('/camera');
        controller.startFromQr(payload);
      },
      onFailure: (f) {
        setState(() {
          _loading = false;
          _error = f.message;
        });
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        foregroundColor: Colors.white,
        title: const Text('Join Session'),
        elevation: 0,
      ),
      body: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.videocam, size: 64, color: Colors.white24),
            const SizedBox(height: 24),
            const Text(
              'Enter the 6-digit session code\nshared by the admin.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white54, fontSize: 15),
            ),
            const SizedBox(height: 36),
            TextField(
              controller: _codeController,
              keyboardType: TextInputType.number,
              maxLength: 6,
              textAlign: TextAlign.center,
              autofocus: true,
              style: const TextStyle(
                fontSize: 36,
                letterSpacing: 14,
                fontWeight: FontWeight.bold,
                color: Colors.white,
              ),
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              decoration: InputDecoration(
                hintText: '------',
                hintStyle: const TextStyle(
                  color: Colors.white24,
                  fontSize: 36,
                  letterSpacing: 14,
                ),
                counterText: '',
                errorText: _error,
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: const BorderSide(color: Colors.white24),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: const BorderSide(color: Colors.white70),
                ),
                errorBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide(color: Colors.red.shade700),
                ),
                focusedErrorBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide(color: Colors.red.shade700),
                ),
              ),
              onSubmitted: (_) => _join(),
            ),
            const SizedBox(height: 28),
            FilledButton(
              onPressed: _loading ? null : _join,
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(52),
              ),
              child: _loading
                  ? const SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : const Text(
                      'Join Session',
                      style: TextStyle(fontSize: 16),
                    ),
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: _loading ? null : _scanQr,
              icon: const Icon(Icons.qr_code_scanner),
              label: const Text('Scan QR'),
              style: OutlinedButton.styleFrom(
                minimumSize: const Size.fromHeight(52),
                foregroundColor: Colors.white,
                side: const BorderSide(color: Colors.white24),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
