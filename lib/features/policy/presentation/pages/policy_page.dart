import 'package:flutter/material.dart';
import 'package:get/get.dart';

/// App policy screen shown in the app.
/// Displays the privacy policy and data usage information.
class PolicyPage extends StatelessWidget {
  const PolicyPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('سياسة الخصوصية'),
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
                'سياسة خصوصية Multicam Studio',
                style: TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.bold,
                  color: Colors.white,
                ),
              ),
              const SizedBox(height: 16),
              const Text(
                'نحرص على حماية خصوصيتك ونوضح هنا كيفية تعاملنا مع بياناتك:\n\n'
                '• لا يتم رفع Recordings إلى سيرفرات خارجية إلا بالاختيار الصريح.\n'
                '• تخزن التسجيلات محليًا على الجهاز وفي الشبكة المحلية فقط.\n'
                '• يمكن للمستخدم حذف أي Recording في أي وقت.\n'
                '• يتم استخدام بيانات الموقع فقط لتحديد IP الكاميرات على الشبكة المحلية.\n'
                '• لا نgather nor share personal identifiable information (PII).\n\n'
                'تاريخ التحديث: Last updated\n\n'
                'لأي استفسارات بخصوص السياسة، يرجى التواصل معنا.',
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