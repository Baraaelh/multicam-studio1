import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:share_plus/share_plus.dart';

import '../../../../core/services/app_check_service.dart';

/// Shows this device's App Check debug token so it can be added to the
/// allow list in Firebase Console without adb.
class DeviceTokenPage extends StatefulWidget {
  /// Reads the token; replaceable in tests.
  final Future<String?> Function() readToken;

  /// Whether this build uses the debug provider; replaceable in tests.
  final bool usesDebugProvider;

  DeviceTokenPage({
    super.key,
    Future<String?> Function()? readToken,
    bool? usesDebugProvider,
  })  : readToken = readToken ?? readAppCheckDebugToken,
        usesDebugProvider = usesDebugProvider ?? appCheckUsesDebugProvider;

  @override
  State<DeviceTokenPage> createState() => _DeviceTokenPageState();
}

class _DeviceTokenPageState extends State<DeviceTokenPage> {
  String? _token;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    String? token;
    // The debug provider writes the token shortly after startup.
    for (var attempt = 0; attempt < 5 && token == null; attempt++) {
      if (attempt > 0) await Future<void>.delayed(const Duration(seconds: 1));
      token = await widget.readToken();
      if (!mounted) return;
    }
    setState(() {
      _token = token;
      _loading = false;
    });
  }

  Future<void> _copy() async {
    final token = _token;
    if (token == null) return;
    await Clipboard.setData(ClipboardData(text: token));
    Get.snackbar(
      'Copied',
      'Paste it under App Check → Manage debug tokens',
      snackPosition: SnackPosition.BOTTOM,
      duration: const Duration(seconds: 2),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Device token')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            if (!widget.usesDebugProvider)
              const _Note(
                icon: Icons.verified_user,
                text: 'This build uses Play Integrity. No device token is needed.',
              )
            else if (_loading)
              const Center(child: CircularProgressIndicator())
            else if (_token == null)
              _Note(
                icon: Icons.info_outline,
                text: 'The token isn\'t available yet. Try again in a moment. '
                    'If it still doesn\'t appear, read it with:\n'
                    'adb logcat | grep DebugAppCheckProvider',
                action: TextButton(onPressed: _load, child: const Text('Try again')),
              )
            else ...[
              const Text(
                'App Check debug token for this device',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.06),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: SelectableText(
                  _token!,
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 15),
                ),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: _copy,
                      icon: const Icon(Icons.copy),
                      label: const Text('Copy'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () => Share.share(_token!),
                      icon: const Icon(Icons.share),
                      label: const Text('Share'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 28),
              const Text(
                'Add it in Firebase Console → App Check → Apps → '
                'your Android app → ⋮ → Manage debug tokens.\n\n'
                'Only devices whose token is added can connect once App Check '
                'is enforced. Keep it private: anyone with it can pass as this '
                'device.\n\n'
                'Reinstalling the app or clearing its data creates a new '
                'token, which has to be added again.',
                style: TextStyle(color: Colors.white60, height: 1.4),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _Note extends StatelessWidget {
  final IconData icon;
  final String text;
  final Widget? action;

  const _Note({required this.icon, required this.text, this.action});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Icon(icon, size: 40, color: Colors.white54),
        const SizedBox(height: 12),
        Text(text, textAlign: TextAlign.center, style: const TextStyle(height: 1.4)),
        ?action,
      ],
    );
  }
}
