import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:multicam_studio/app.dart';
import 'package:multicam_studio/core/di/injection.dart';
import 'package:multicam_studio/features/app_check/presentation/pages/device_token_page.dart';
import 'package:multicam_studio/features/onboarding/data/onboarding_store.dart';

class _FakeStore extends OnboardingStore {
  _FakeStore({this.accepted = false});

  bool accepted;

  @override
  Future<bool> isAccepted() async => accepted;

  @override
  Future<void> accept() async => accepted = true;
}

void main() {
  setUpAll(() {
    // Initialize DI so GetMaterialApp can resolve dependencies.
    configureDependencies();
  });

  tearDown(Get.reset);

  testWidgets('First launch opens the welcome guide with the developer credit',
      (tester) async {
    await tester.pumpWidget(App(onboardingStore: _FakeStore()));
    await tester.pumpAndSettle();

    expect(find.text('Multicam Studio'), findsOneWidget);
    expect(find.text('Baraa Alhaddad'), findsOneWidget);
    expect(find.text('Camera Mode'), findsNothing);
  });

  testWidgets('Terms must be accepted before reaching the mode select page',
      (tester) async {
    final store = _FakeStore();
    await tester.pumpWidget(App(onboardingStore: store));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Skip'));
    await tester.pumpAndSettle();
    expect(find.text('Usage & privacy'), findsOneWidget);

    final start = find.widgetWithText(FilledButton, 'Get started');
    expect(tester.widget<FilledButton>(start).onPressed, isNull);

    await tester.tap(find.byType(Checkbox));
    await tester.pump();
    await tester.tap(start);
    await tester.pumpAndSettle();

    expect(store.accepted, isTrue);
    expect(find.text('Camera Mode'), findsOneWidget);
    expect(find.text('Admin Mode'), findsOneWidget);
  });

  testWidgets('Next walks through the usage steps', (tester) async {
    await tester.pumpWidget(App(onboardingStore: _FakeStore()));
    await tester.pumpAndSettle();

    for (final title in ['How it works', 'Director phone', 'Camera phones', 'Usage & privacy']) {
      await tester.tap(find.text('Next'));
      await tester.pumpAndSettle();
      expect(find.text(title), findsOneWidget);
    }
  });

  testWidgets('Returning users skip straight to the mode select page',
      (tester) async {
    await tester.pumpWidget(App(onboardingStore: _FakeStore(accepted: true)));
    await tester.pumpAndSettle();

    expect(find.text('Camera Mode'), findsOneWidget);
  });

  testWidgets('How to use reopens the guide without asking again',
      (tester) async {
    await tester.pumpWidget(App(onboardingStore: _FakeStore(accepted: true)));
    await tester.pumpAndSettle();

    await tester.tap(find.text('How to use'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Skip'));
    await tester.pumpAndSettle();

    expect(find.byType(Checkbox), findsNothing);
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    expect(find.text('Camera Mode'), findsOneWidget);
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
