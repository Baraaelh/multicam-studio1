import 'package:flutter/material.dart';
import 'package:get/get.dart';

import 'features/admin/presentation/bindings/admin_binding.dart';
import 'features/admin/presentation/pages/admin_live_page.dart';
import 'features/admin/presentation/pages/admin_setup_page.dart';
import 'features/admin/presentation/pages/render_page.dart';
import 'features/camera/presentation/bindings/camera_binding.dart';
import 'features/camera/presentation/pages/camera_page.dart';
import 'features/camera/presentation/pages/qr_scan_page.dart';
import 'features/session/presentation/bindings/signaling_binding.dart';

class App extends StatelessWidget {
  const App({super.key});

  @override
  Widget build(BuildContext context) {
    return GetMaterialApp(
      title: 'Multicam Studio',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(useMaterial3: true),
      initialBinding: SignalingBinding(),
      initialRoute: '/',
      getPages: [
        GetPage(name: '/', page: () => const _ModeSelectPage()),
        GetPage(
          name: '/camera/scan',
          page: () => const QrScanPage(),
          binding: CameraBinding(),
        ),
        GetPage(name: '/camera', page: () => const CameraPage()),
        GetPage(
          name: '/admin',
          page: () => const AdminSetupPage(),
          binding: AdminBinding(),
        ),
        GetPage(name: '/admin/live', page: () => const AdminLivePage()),
        GetPage(
          name: '/admin/render',
          page: () => const RenderPage(),
        ),
      ],
    );
  }
}

class _ModeSelectPage extends StatelessWidget {
  const _ModeSelectPage();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Text(
                'Multicam Studio',
                style: TextStyle(fontSize: 26, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              Text(
                'Live production system',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: Colors.white54,
                    ),
              ),
              const SizedBox(height: 56),
              FilledButton.icon(
                onPressed: () => Get.toNamed<void>('/camera/scan'),
                icon: const Icon(Icons.videocam),
                label: const Text('Camera Mode'),
                style: FilledButton.styleFrom(
                  minimumSize: const Size(220, 52),
                ),
              ),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: () => Get.toNamed<void>('/admin'),
                icon: const Icon(Icons.dashboard),
                label: const Text('Admin Mode'),
                style: FilledButton.styleFrom(
                  minimumSize: const Size(220, 52),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
