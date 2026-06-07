import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../controllers/camera_controller.dart';
import 'camera_page.dart';

class QrScanPage extends StatefulWidget {
  const QrScanPage({super.key});

  @override
  State<QrScanPage> createState() => _QrScanPageState();
}

class _QrScanPageState extends State<QrScanPage> {
  final _scanner = MobileScannerController();
  bool _processing = false;

  @override
  void dispose() {
    _scanner.dispose();
    super.dispose();
  }

  Future<void> _onDetect(BarcodeCapture capture) async {
    if (_processing) return;
    final raw = capture.barcodes.firstOrNull?.rawValue;
    if (raw == null) return;

    _processing = true;
    await _scanner.stop();

    final controller = Get.find<CameraController>();
    final result = await controller.parseQr(raw);

    result.fold(
      onSuccess: (payload) {
        // Push CameraPage on top of QrScanPage. On disconnect, user returns here.
        Get.to<void>(() => const CameraPage());
        controller.startFromQr(payload);
      },
      onFailure: (_) {
        _processing = false;
        _scanner.start();
        Get.snackbar(
          'Invalid QR',
          'Point at a valid Multicam Studio session code',
          backgroundColor: Colors.red.shade900,
          colorText: Colors.white,
          snackPosition: SnackPosition.BOTTOM,
          margin: const EdgeInsets.all(16),
        );
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
      body: Stack(
        alignment: Alignment.center,
        children: [
          MobileScanner(controller: _scanner, onDetect: _onDetect),
          // Viewfinder frame
          Container(
            width: 260,
            height: 260,
            decoration: BoxDecoration(
              border: Border.all(color: Colors.white70, width: 2),
              borderRadius: BorderRadius.circular(16),
            ),
          ),
          Positioned(
            bottom: 56,
            child: const Text(
              'Point at the session QR code',
              style: TextStyle(color: Colors.white70, fontSize: 15),
            ),
          ),
        ],
      ),
    );
  }
}
