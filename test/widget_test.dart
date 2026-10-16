import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:multicam_studio/app.dart';
import 'package:multicam_studio/core/di/injection.dart';

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
}
