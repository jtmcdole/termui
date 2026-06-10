import 'package:flutter_test/flutter_test.dart';
import 'package:example_flutter/main.dart';
import 'package:termui_flutter/termui_flutter.dart';

void main() {
  testWidgets('App renders terminal view', (WidgetTester tester) async {
    await tester.pumpWidget(const MainApp());
    expect(find.byType(Terminal), findsOneWidget);
    for (int i = 0; i < 50; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
  });
}
