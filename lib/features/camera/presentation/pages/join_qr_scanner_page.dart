import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../../../core/constants/join_qr.dart';

/// Scans the admin's join QR and pops with the session code.
class JoinQrScannerPage extends StatefulWidget {
  const JoinQrScannerPage({super.key});

  @override
  State<JoinQrScannerPage> createState() => _JoinQrScannerPageState();
}

class _JoinQrScannerPageState extends State<JoinQrScannerPage> {
  final _scanner = MobileScannerController(formats: const [BarcodeFormat.qrCode]);
  bool _done = false;
  bool _showHint = false;

  @override
  void dispose() {
    _scanner.dispose();
    super.dispose();
  }

  void _onDetect(BarcodeCapture capture) {
    if (_done) return;
    for (final barcode in capture.barcodes) {
      final code = sessionCodeFromQr(barcode.rawValue ?? '');
      if (code != null) {
        _done = true;
        Get.back<String>(result: code);
        return;
      }
    }
    if (!_showHint) setState(() => _showHint = true);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        foregroundColor: Colors.white,
        title: const Text('Scan QR'),
        elevation: 0,
      ),
      body: Stack(
        children: [
          MobileScanner(controller: _scanner, onDetect: _onDetect),
          Center(
            child: Container(
              width: 240,
              height: 240,
              decoration: BoxDecoration(
                border: Border.all(color: Colors.white70, width: 3),
                borderRadius: BorderRadius.circular(16),
              ),
            ),
          ),
          Positioned(
            left: 24,
            right: 24,
            bottom: 48,
            child: Text(
              _showHint
                  ? 'That QR is not a Multicam Studio session code.'
                  : 'Point at the QR on the director\'s phone.',
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white, fontSize: 15),
            ),
          ),
        ],
      ),
    );
  }
}
