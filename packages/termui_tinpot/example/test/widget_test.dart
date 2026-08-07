import 'package:flutter_test/flutter_test.dart';
import 'package:termui_flutter/termui_flutter.dart';
import 'package:termui_tinpot_example/main.dart';

void main() {
  testWidgets('Tinpot example renders Terminal widget', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const MainApp());
    expect(find.byType(Terminal), findsOneWidget);
  });
}
