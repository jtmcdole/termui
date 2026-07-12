import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:example_flutter/main.dart';
import 'package:termui_flutter/termui_flutter.dart';
import 'package:termui_shared_examples/widget_book/events.dart';

void main() {
  testWidgets('App renders Asciicast Player by default', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const MainApp());
    expect(find.byType(Terminal), findsOneWidget);
  });

  testWidgets(
    'App routes to Widget Book and sub-page from initial query parameters',
    (WidgetTester tester) async {
      // Inject mock query parameters for widgetbook demo and fruitGame page
      await tester.pumpWidget(
        const MainApp(
          initialQuery: {'demo': 'widgetbook', 'page': 'fruitGame'},
        ),
      );

      // The app should immediately run the WidgetBook
      await tester.pump(const Duration(milliseconds: 100));

      final homeState = tester.state<TermUIWebHomeState>(
        find.byType(TermUIWebHome),
      );
      expect(homeState.currentDemo, equals(TuiDemo.widgetBook));
      expect(homeState.initialPage, equals('fruitGame'));
    },
  );

  testWidgets('App updates sub-page via core_bus pageSelectedEvent', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      const MainApp(initialQuery: {'demo': 'widgetbook'}),
    );

    await tester.pump(const Duration(milliseconds: 100));

    // Post selection event to bus
    pageSelectedEvent.post(widgetBookEventBus, 'fruitGame');
    await tester.pump(const Duration(milliseconds: 100));

    final homeState = tester.state<TermUIWebHomeState>(
      find.byType(TermUIWebHome),
    );
    expect(homeState.initialPage, equals('fruitGame'));
  });

  testWidgets(
    'Selecting asciicast player does not immediately pop up switch dialog',
    (WidgetTester tester) async {
      await tester.pumpWidget(
        const MainApp(initialQuery: {'demo': 'widgetbook'}),
      );

      // Let widget book load and start TUI loop
      await tester.pump(const Duration(milliseconds: 100));

      // 1. Open the switch dialog
      await tester.tap(find.byIcon(Icons.swap_horiz));
      await tester.pumpAndSettle();

      // 2. Select Asciicast Player
      await tester.tap(find.text('Asciicast Player'));
      await tester.pumpAndSettle();

      // 3. Let TUI run loop iterations complete
      await tester.pump(const Duration(milliseconds: 200));

      // 4. Verify no dialog pops back up
      expect(find.byType(AlertDialog), findsNothing);
    },
  );
}
