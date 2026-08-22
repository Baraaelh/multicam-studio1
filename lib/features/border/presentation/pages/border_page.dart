import 'package:flutter/material.dart';
import 'package:get/get.dart';

class BorderPage extends StatelessWidget {
  const BorderPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Terms & Conditions'),
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
                  Icons.gavel,
                  size: 80,
                  color: Colors.cyanAccent,
                ),
              ),
              const SizedBox(height: 24),
              const Text(
                'Multicam Studio — Terms of Service',
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
              const Text(
                'By using this application, you agree to the following terms:\n\n'
                '1. You must be at least 18 years old to use this application.\n\n'
                '2. All recordings are stored locally on your device and shared '
                'only over your local network between connected devices. '
                'No recordings are uploaded to external servers without your explicit action.\n\n'
                '3. You are responsible for respecting the privacy of individuals '
                'you record. Ensure you have obtained the necessary consents '
                'before recording any person.\n\n'
                '4. Multicam Studio reserves the right to update these terms at '
                'any time. Continued use of the application constitutes acceptance '
                'of any revised terms.\n\n'
                '5. The application is provided "as is" without warranties of any kind. '
                'We are not liable for any loss of data or damages arising from use '
                'of the application.',
                style: TextStyle(
                  fontSize: 14,
                  color: Colors.white54,
                  height: 1.6,
                ),
              ),
              const SizedBox(height: 32),
              Center(
                child: FilledButton(
                  onPressed: () => Get.offNamed('/'),
                  child: const Text('Back to Start'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
