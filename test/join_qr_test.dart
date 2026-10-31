import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:multicam_studio/core/constants/join_qr.dart';
import 'package:multicam_studio/features/admin/presentation/widgets/join_code_sheet.dart';
import 'package:qr_flutter/qr_flutter.dart';

void main() {
  group('join QR contents', () {
    test('round-trips the session code', () {
      expect(sessionCodeFromQr(joinQrData('482917')), '482917');
    });

    test('accepts a bare 6-digit code', () {
      expect(sessionCodeFromQr(' 482917 '), '482917');
    });

    test('rejects anything else', () {
      for (final raw in ['', 'https://example.com', 'MULTICAM:4829', 'MULTICAM:4829170', 'OTHER:482917']) {
        expect(sessionCodeFromQr(raw), isNull, reason: raw);
      }
    });
  });

  testWidgets('join sheet shows the QR and the formatted code', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: JoinCodeSheet(code: '482917'))),
    );

    expect(find.text('482 917'), findsOneWidget);
    expect(find.byType(QrImageView), findsOneWidget);
    expect(find.text('Share'), findsOneWidget);
    expect(find.text('Copy'), findsOneWidget);
  });
}
