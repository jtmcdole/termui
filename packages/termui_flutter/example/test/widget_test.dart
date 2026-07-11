import 'package:flutter_test/flutter_test.dart';
import 'package:example_flutter/main.dart';
import 'package:termui_flutter/termui_flutter.dart';
import 'package:termui_shared_examples/widget_book/events.dart';

void main() {
  testWidgets('App renders terminal view', (WidgetTester tester) async {
    await tester.pumpWidget(const MainApp());
    expect(find.byType(Terminal), findsOneWidget);
    for (int i = 0; i < 50; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
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

      // The app should immediately run the WidgetBook instead of GlassCompositing
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
}
