import 'package:flutter/material.dart';
import 'package:get/get.dart';

import 'features/admin/presentation/bindings/admin_binding.dart';
import 'features/admin/presentation/pages/admin_live_page.dart';
import 'features/admin/presentation/pages/admin_setup_page.dart';
import 'features/admin/presentation/pages/render_page.dart';
import 'features/border/presentation/pages/border_page.dart';
import 'features/camera/presentation/bindings/camera_binding.dart';
import 'features/camera/presentation/pages/camera_page.dart';
import 'features/camera/presentation/pages/qr_scan_page.dart' show CodeJoinPage;
import 'features/policy/presentation/pages/policy_page.dart';
import 'features/splash/presentation/pages/splash_page.dart';

class App extends StatelessWidget {
  const App({super.key});

  @override
  Widget build(BuildContext context) {
    return GetMaterialApp(
      title: 'Multicam Studio',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(useMaterial3: true),
      initialRoute: '/splash',
      getPages: [
        GetPage(name: '/splash', page: () => const SplashPage()),
        GetPage(name: '/', page: () => const ModeSelectPage()),
        GetPage(
          name: '/camera/scan',
          page: () => const CodeJoinPage(),
          binding: CameraBinding(),
        ),
        GetPage(
          name: '/camera',
          page: () => const CameraPage(),
          binding: CameraBinding(),
        ),
        GetPage(
          name: '/admin',
          page: () => const AdminSetupPage(),
          binding: AdminBinding(),
        ),
        GetPage(
          name: '/admin/live',
          page: () => const AdminLivePage(),
          binding: AdminBinding(),
        ),
        GetPage(
          name: '/admin/render',
          page: () => const RenderPage(),
        ),
        GetPage(name: '/border', page: () => const BorderPage()),
        GetPage(name: '/policy', page: () => const PolicyPage()),
      ],
    );
  }
}

class ModeSelectPage extends StatelessWidget {
  const ModeSelectPage({super.key});

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
              const SizedBox(height: 24),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  TextButton(
                    onPressed: () => Get.toNamed<void>('/border'),
                    child: const Text('Terms'),
                  ),
                  const SizedBox(width: 16),
                  TextButton(
                    onPressed: () => Get.toNamed<void>('/policy'),
                    child: const Text('Privacy'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
