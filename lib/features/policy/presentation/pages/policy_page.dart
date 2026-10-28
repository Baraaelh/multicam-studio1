import 'package:flutter/material.dart';
import 'package:get/get.dart';

class PolicyPage extends StatelessWidget {
  const PolicyPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Privacy Policy & Terms'),
        backgroundColor: Colors.cyanAccent,
        foregroundColor: Colors.black,
      ),
      body: Container(
        color: const Color(0xFF0A0E17),
        padding: const EdgeInsets.all(24),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Center(
                child: Icon(
                  Icons.shield,
                  size: 80,
                  color: Colors.cyanAccent,
                ),
              ),
              const SizedBox(height: 24),
              const Text(
                'Multicam Studio — Privacy Policy & Terms of Use',
                style: TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.bold,
                  color: Colors.white,
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                'Last updated: 2025',
                style: TextStyle(fontSize: 12, color: Colors.white38),
              ),
              const SizedBox(height: 24),
              _Section(
                title: 'Data & Recordings',
                body:
                    'All recordings are stored locally on your device and transferred '
                    'only over your local network between connected devices. '
                    'Recordings are never uploaded to external servers without your '
                    'explicit action.',
              ),
              _Section(
                title: 'Camera & Microphone',
                body:
                    'Multicam Studio requires access to your camera and microphone '
                    'solely to capture video and audio for recording sessions. '
                    'This data is processed on-device and is not shared with third parties.',
              ),
              _Section(
                title: 'Network Access',
                body:
                    'Local network access is used to discover and connect camera '
                    'devices on the same Wi-Fi network. No data is routed through '
                    'the internet during a recording session.',
              ),
              _Section(
                title: 'Personal Information',
                body:
                    'Multicam Studio does not collect, store, or share personally '
                    'identifiable information (PII). Session codes are ephemeral and '
                    'are not linked to any user account or identity.',
              ),
              _Section(
                title: 'Data Deletion',
                body:
                    'You can delete any recording at any time from within the app or '
                    'directly from your device storage. No copies are retained by the app '
                    'after deletion.',
              ),
              _Section(
                title: 'Terms of Use',
                body:
                    'Multicam Studio is provided for personal and professional video '
                    'production use. You are responsible for ensuring you have the '
                    'necessary rights and consents before recording individuals. '
                    'Redistribution or reverse-engineering of the application is not permitted.',
              ),
              _Section(
                title: 'Contact',
                body:
                    'For questions about this policy or your data, please contact us at:\n'
                    'anasahmes03@icloud.com',
              ),
              const SizedBox(height: 32),
              Center(
                child: FilledButton(
                  onPressed: () => Get.back<void>(),
                  child: const Text('Back'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.body});

  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.bold,
              color: Colors.cyanAccent,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            body,
            style: const TextStyle(
              fontSize: 14,
              color: Colors.white54,
              height: 1.6,
            ),
          ),
        ],
      ),
    );
  }
}
