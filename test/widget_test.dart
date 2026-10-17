import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:multicam_studio/app.dart';
import 'package:multicam_studio/core/di/injection.dart';
import 'package:multicam_studio/features/app_check/presentation/pages/device_token_page.dart';

void main() {
  setUpAll(() {
    // Initialize DI so GetMaterialApp can resolve dependencies.
    configureDependencies();
  });

  tearDown(Get.reset);

  testWidgets('App opens on the splash screen', (tester) async {
    await tester.pumpWidget(const App());

    expect(find.text('Multicam Studio'), findsOneWidget);
    expect(find.text('Start'), findsOneWidget);
    expect(find.text('Camera Mode'), findsNothing);
  });

  testWidgets('Start leads to the mode select page with both modes',
      (tester) async {
    await tester.pumpWidget(const App());

    await tester.tap(find.text('Start'));
    await tester.pumpAndSettle();

    expect(find.text('Camera Mode'), findsOneWidget);
    expect(find.text('Admin Mode'), findsOneWidget);
  });

  group('Device token page', () {
    Widget page({required Future<String?> Function() read, bool debug = true}) =>
        GetMaterialApp(home: DeviceTokenPage(readToken: read, usesDebugProvider: debug));

    testWidgets('shows the token with copy and share', (tester) async {
      await tester.pumpWidget(page(read: () async => 'abc-123-token'));
      await tester.pumpAndSettle();

      expect(find.text('abc-123-token'), findsOneWidget);
      expect(find.text('Copy'), findsOneWidget);
      expect(find.text('Share'), findsOneWidget);
    });

    testWidgets('retries until the token appears', (tester) async {
      var calls = 0;
      await tester.pumpWidget(page(read: () async => ++calls < 3 ? null : 'late-token'));
      await tester.pump();
      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();

      expect(find.text('late-token'), findsOneWidget);
      expect(calls, 3);
    });

    testWidgets('falls back to logcat when no token is found', (tester) async {
      await tester.pumpWidget(page(read: () async => null));
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();

      expect(find.textContaining('adb logcat'), findsOneWidget);
      expect(find.text('Try again'), findsOneWidget);
    });

    testWidgets('says no token is needed for Play Integrity builds', (tester) async {
      await tester.pumpWidget(page(read: () async => 'unused', debug: false));
      await tester.pumpAndSettle();

      expect(find.textContaining('Play Integrity'), findsOneWidget);
      expect(find.text('unused'), findsNothing);
    });
  });
}
