import 'dart:convert';
import 'dart:math';
import 'package:file/file.dart';
import 'package:termui/perf/fs_locator.dart';
import 'package:termui_test/termui_test.dart';
import 'package:termui/termui.dart';
import 'package:test/test.dart';
// ignore: implementation_imports, depend_on_referenced_packages
import 'package:test_api/src/backend/invoker.dart';

void main() {
  group('TerminalTester Integration Tests', () {
    test('pumpWidget, finders, and matchers work', () {
      final tester = TerminalTester();
      tester.run(() async {
        final key1 = const ValueKey('text1');
        final key2 = const ValueKey('text2');

        await tester.pumpWidget(
          Column([
            Text('Hello World', key: key1),
            Text('TermUI Test Framework', key: key2),
          ]),
          size: const Size(80, 10),
        );

        // Find by type
        expect(find.byType<Text>(), findsNWidgets(2));

        // Find by text
        expect(find.text('Hello World'), findsOneWidget);
        expect(find.textPattern('Framework'), findsOneWidget);
        expect(find.text('Nonexistent'), findsNothing);

        // Find by key
        expect(find.byKey(key1), findsOneWidget);
        expect(find.byKey(key2), findsOneWidget);
      });
    });

    test('sendKey and raw input injection work', () {
      final tester = TerminalTester();

      tester.run(() async {
        var keyReceived = '';
        final runner = PromptRunner<String>(
          terminal: tester.terminal,
          widget: const Text('Input Screen'),
          onKeyEvent: (event) {
            keyReceived = event.key;
            return true; // handled
          },
        );

        final runnerFuture = tester.runPrompt(runner, () async {
          await tester.pump();

          tester.sendKey(LogicalKey.arrowDown);
          await tester.pump();
          runner.dispose();
        });

        await runnerFuture;
        expect(keyReceived, equals('down'));
      });
    });

    test('tap coordinate resolution works', () {
      final tester = TerminalTester();

      tester.run(() async {
        var clickX = 0;
        var clickY = 0;
        final widgetKey = const ValueKey('clickable');

        final runner = PromptRunner<String>(
          terminal: tester.terminal,
          widget: Column([
            const SizedBox(
              width: 80,
              height: 2,
            ), // offset vertically by 2 lines
            Row([
              const SizedBox(
                width: 5,
                height: 1,
              ), // offset horizontally by 5 cells
              SizedBox(
                width: 10,
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 2,
                    vertical: 1,
                  ),
                  child: SizedBox(
                    width: 6,
                    child: Text('Tap Me', key: widgetKey),
                  ),
                ),
              ),
            ]),
          ]),
        );

        tester.terminal.events.listen((event) {
          if (event is MouseEvent) {
            clickX = event.x;
            clickY = event.y;
            runner.dispose();
          }
        });

        final runnerFuture = tester.runPrompt(runner, () async {
          await tester.pump();

          tester.tap(find.byKey(widgetKey));
          await tester.pump();
          runner.dispose();
        });

        await runnerFuture;

        // Expectation:
        // Column child 1: SizedBox (height: 2) -> y = 2
        // Column child 2: Row -> starts at y = 2
        // Row child 1: SizedBox (width: 5) -> x = 5
        // Row child 2: Padding (left: 2, top: 1) -> starts at (5+2, 2+1) = (7, 3)
        // Padding child: Text ("Tap Me" width: 6, height: 1) -> center is (7 + 3, 3 + 0) = (10, 3)
        // 1-indexed terminal coordinates: x = 11, y = 4
        expect(clickX, equals(11));
        expect(clickY, equals(4));
      });
    });

    test('mouseDown, mouseMove, and mouseUp drag/move simulation works', () {
      final tester = TerminalTester();

      tester.run(() async {
        final events = <MouseEvent>[];
        final runner = PromptRunner<String>(
          terminal: tester.terminal,
          widget: const Text('Mouse Test Screen'),
        );

        tester.terminal.events.listen((event) {
          if (event is MouseEvent) {
            events.add(event);
          }
        });

        final runnerFuture = tester.runPrompt(runner, () async {
          await tester.pump();

          tester.mouseDown(10, 5);
          tester.mouseMove(11, 5, drag: true);
          tester.mouseMove(12, 5, drag: false);
          tester.mouseUp(12, 5);

          await tester.pump();
          runner.dispose();
        });

        await runnerFuture;

        expect(events.length, equals(4));

        expect(events[0].x, equals(10));
        expect(events[0].y, equals(5));
        expect(events[0].button, equals(MouseButton.left));
        expect(events[0].type, equals(MouseEventType.press));

        expect(events[1].x, equals(11));
        expect(events[1].y, equals(5));
        expect(events[1].button, equals(MouseButton.left));
        expect(events[1].type, equals(MouseEventType.drag));

        expect(events[2].x, equals(12));
        expect(events[2].y, equals(5));
        expect(events[2].button, equals(MouseButton.none));
        expect(events[2].type, equals(MouseEventType.move));

        expect(events[3].x, equals(12));
        expect(events[3].y, equals(5));
        expect(events[3].button, equals(MouseButton.left));
        expect(events[3].type, equals(MouseEventType.release));
      });
    });

    test('RichText finder handles disjointed spans safely', () {
      final tester = TerminalTester();
      tester.run(() async {
        final widget = RichText(
          text: const TextSpan(
            children: [
              TextSpan(text: 'Name'),
              TextSpan(text: 'Age'),
            ],
          ),
        );

        await tester.pumpWidget(widget);

        // Substring within individual span should match
        expect(find.textPattern('Name'), findsOneWidget);
        expect(find.textPattern('Age'), findsOneWidget);
        expect(find.textPattern('Nam'), findsOneWidget);

        // Exact match of full flattened text should match
        expect(find.text('NameAge'), findsOneWidget);

        // Substring crossing boundaries of separate columns/spans should NOT match
        expect(find.text('meA'), findsNothing);
      });
    });

    test('simulateResize updates dimensions and triggers repaint', () {
      final tester = TerminalTester();
      tester.run(() async {
        await tester.pumpWidget(
          const SizedBox(width: 80, height: 24, child: Text('Sized Box')),
          size: const Size(80, 24),
        );

        expect(tester.terminal.backend.size, equals(const Point(80, 24)));

        await tester.simulateResize(const Size(100, 30));

        expect(tester.terminal.backend.size, equals(const Point(100, 30)));
      });
    });

    test('mouse clicks support different mouse buttons', () {
      final tester = TerminalTester();
      tester.run(() async {
        final events = <MouseEvent>[];
        final runner = PromptRunner<String>(
          terminal: tester.terminal,
          widget: const Text('Mouse Buttons Screen'),
        );

        tester.terminal.events.listen((event) {
          if (event is MouseEvent) {
            events.add(event);
          }
        });

        final runnerFuture = tester.runPrompt(runner, () async {
          await tester.pump();

          tester.mouseDown(10, 5, button: MouseButton.right);
          tester.mouseUp(10, 5, button: MouseButton.right);

          tester.mouseDown(20, 10, button: MouseButton.middle);
          tester.mouseUp(20, 10, button: MouseButton.middle);

          await tester.pump();
          runner.dispose();
        });

        await runnerFuture;

        expect(events.length, equals(4));

        expect(events[0].button, equals(MouseButton.right));
        expect(events[0].type, equals(MouseEventType.press));

        expect(events[1].button, equals(MouseButton.right));
        expect(events[1].type, equals(MouseEventType.release));

        expect(events[2].button, equals(MouseButton.middle));
        expect(events[2].type, equals(MouseEventType.press));

        expect(events[3].button, equals(MouseButton.middle));
        expect(events[3].type, equals(MouseEventType.release));
      });
    });

    test(
      'recordTraces configuration and actionLog queue work correctly',
      () async {
        final defaultTester = TerminalTester();
        expect(defaultTester.recordTraces, isFalse);

        defaultTester.run(() async {
          final key = const ValueKey('widget');
          await defaultTester.pumpWidget(
            Text('Action Logging', key: key),
            size: const Size(80, 24),
          );

          defaultTester.sendString('Hello');
          defaultTester.sendKey(LogicalKey.arrowDown);
          defaultTester.tap(find.byKey(key));
          await defaultTester.simulateResize(const Size(100, 30));

          expect(defaultTester.actionLog, [
            'Type: Hello',
            'Key: arrowDown',
            'Tap: key ValueKey(widget)',
            'Resize: Size(100, 30)',
          ]);
        });

        final fs = getDefaultFileSystem();
        final testName = Invoker.current?.liveTest.test.name ?? 'trace';
        Directory parentDir = fs.currentDirectory;
        try {
          final dummyFile = fs.file('.write_test');
          dummyFile.writeAsStringSync('');
          dummyFile.deleteSync();
        } catch (_) {
          parentDir = fs.systemTempDirectory;
        }
        final traceFile = parentDir.childFile(
          '${sanitizeTestName(testName)}.cast',
        );
        if (traceFile.existsSync()) {
          traceFile.deleteSync();
        }

        final customTester = TerminalTester(recordTraces: true);
        expect(customTester.recordTraces, isTrue);

        customTester.run(() async {
          final key = const ValueKey('widget');
          await customTester.pumpWidget(
            Text('Action Logging', key: key),
            size: const Size(80, 24),
          );

          customTester.sendString('Hello');
          customTester.sendKey(LogicalKey.arrowDown);
          customTester.tap(find.byKey(key));
          await customTester.simulateResize(const Size(100, 30));

          expect(customTester.actionLog, [
            'Type: Hello',
            'Key: arrowDown',
            'Tap: key ValueKey(widget)',
            'Resize: Size(100, 30)',
          ]);
        });

        expect(traceFile.existsSync(), isTrue);
        final lines = traceFile.readAsLinesSync();
        expect(lines, isNotEmpty);

        bool foundActionsRow = false;
        for (final line in lines) {
          if (line.trim().isEmpty) continue;
          try {
            final row = jsonDecode(line) as List<dynamic>;
            if (row.length == 3 && row[1] == 'd') {
              expect(
                row[2],
                equals(
                  'Actions: Type: Hello, Key: arrowDown, Tap: key ValueKey(widget), Resize: Size(100, 30)',
                ),
              );
              foundActionsRow = true;
            }
          } catch (_) {}
        }
        expect(foundActionsRow, isTrue);

        if (traceFile.existsSync()) {
          traceFile.deleteSync();
        }
      },
    );
  });
}
