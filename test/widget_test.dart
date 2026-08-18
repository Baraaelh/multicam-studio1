import 'package:flutter_test/flutter_test.dart';
import 'package:multicam_studio/app.dart';
import 'package:multicam_studio/core/di/injection.dart';

void main() {
  testWidgets('Mode select page renders both mode buttons', (tester) async {
    // Initialize DI so GetMaterialApp can resolve dependencies.
    configureDependencies();

    await tester.pumpWidget(const App());
    expect(find.text('Camera Mode'), findsOneWidget);
    expect(find.text('Admin Mode'), findsOneWidget);
  });
}