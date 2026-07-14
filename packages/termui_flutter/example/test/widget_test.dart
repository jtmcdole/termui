import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:example_flutter/main.dart';
import 'package:example_flutter/src/events.dart';
import 'package:termui_flutter/termui_flutter.dart';
import 'package:termui_shared_examples/widget_book/events.dart';

void main() {
  testWidgets('App renders Glass Compositing by default', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const MainApp());
    expect(find.byType(Terminal), findsOneWidget);

    // Unmount MainApp to trigger dispose() which injects Ctrl+C and cleans up timers
    await tester.pumpWidget(const SizedBox());

    // Yield to the real event loop to allow the unawaited _runTUI Future to finish its finally block
    await tester.runAsync(() async {
      await Future.delayed(const Duration(milliseconds: 100));
    });
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

  testWidgets('App routes to Trace Viewer and processes uploaded trace file', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const MainApp(initialQuery: {'demo': 'trace'}));
    await tester.pump(const Duration(milliseconds: 100));

    final homeState = tester.state<TermUIWebHomeState>(
      find.byType(TermUIWebHome),
    );
    expect(homeState.currentDemo, equals(TuiDemo.traceViewer));

    // Simulate a dropped trace file
    final mockJson = jsonEncode([
      {'name': 'test_span', 'ph': 'B', 'ts': 1000, 'tid': 1},
      {'name': 'test_span', 'ph': 'E', 'ts': 2000, 'tid': 1},
    ]);
    final mockBytes = Uint8List.fromList(utf8.encode(mockJson));

    traceUploadedEvent.post(
      playerEventBus,
      UploadedTraceData('test_trace.json', mockBytes),
    );

    await tester.pump(const Duration(milliseconds: 200));
    // Re-pump to let async parse operations and microtasks complete
    await tester.pump(const Duration(milliseconds: 100));

    // Simulate dropping a second trace file with the same name
    traceUploadedEvent.post(
      playerEventBus,
      UploadedTraceData('test_trace.json', mockBytes),
    );

    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump(const Duration(milliseconds: 100));
  });
}
