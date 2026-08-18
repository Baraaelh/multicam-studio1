import 'package:flutter/material.dart';
import 'package:get/get.dart';

/// Border/Terms screen shown in the app.
/// Displays terms of service or similar content with a bordered layout.
class BorderPage extends StatelessWidget {
  const BorderPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('الشروط والأحكام'),
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
                'شروط خدمة Multicam Studio',
                style: TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.bold,
                  color: Colors.white,
                ),
              ),
              const SizedBox(height: 16),
              const Text(
                'باستخدام هذا التطبيق، فإنك توافق على الشروط التالية:\n\n'
                '1. يجب أن يكون المستخدم أكبر من 18 عاماً لاستخدام التطبيق.\n'
                '2. يحتفظ التطبيق بحق تعديل السياسات في أي وقت.\n'
                '3. جميع Recordings تخزن محليًا وإذاعيًا عبر الشبكة المحلية.\n'
                '4. يحترم المستخدم خصوصية الآخرين أثناء التسجيل.',
                style: TextStyle(
                  fontSize: 14,
                  color: Colors.white54,
                  height: 1.5,
                ),
              ),
              const SizedBox(height: 32),
              Center(
                child: FilledButton(
                  onPressed: () => Get.offNamed('/'),
                  child: const Text('عودة إلى البداية'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}