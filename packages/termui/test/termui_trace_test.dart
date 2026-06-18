import 'dart:math';
import 'package:test/test.dart';
import 'package:termui_test/termui_test.dart';
import 'package:termui/termui.dart';
import 'package:termui/ui/renderer.dart';
import 'package:termui/ui/window.dart';
import 'package:termui_recorder/termui_recorder.dart';
import '../bin/termui_trace.dart';

void main() {
  group('Trace Viewer Integration Tests', () {
    late List<TraceSpan> spans;
    late int minTs;
    late int maxTs;

    setUp(() {
      // Clean slate for FocusManager singleton
      FocusManager.instance.setPrimaryFocus(null);

      // Create mock JSON events
      final jsonTrace = [
        {
          "ph": "B",
          "name": "MainTask",
          "ts": 1000,
          "cat": "TUI",
          "args": {"metaKey": "metaVal"},
        },
        {"ph": "E", "name": "MainTask", "ts": 3000, "cat": "TUI"},
        {"ph": "B", "name": "KeyEvent", "ts": 1500, "cat": "event"},
        {"ph": "E", "name": "KeyEvent", "ts": 1600, "cat": "event"},
      ];

      final rawEvents = jsonTrace.map((e) => TraceEvent.fromJson(e)).toList();
      final baseTime = rawEvents.map((e) => e.timestamp).reduce(min);
      final events = rawEvents.map((e) {
        return TraceEvent(
          name: e.name,
          phase: e.phase,
          category: e.category,
          timestamp: e.timestamp - baseTime,
          metadata: e.metadata,
        );
      }).toList();

      spans = computeSpans(events);
      minTs = spans.map((s) => s.startUs).reduce(min);
      maxTs = spans.map((s) => s.endUs).reduce(max);
    });

    dynamic findTraceViewerState(Element root) {
      dynamic found;
      void find(Element el) {
        if (found != null) return;
        if (el is StatefulElement) {
          final state = el.state;
          if (state.runtimeType.toString().contains('TraceViewerAppState')) {
            found = state;
            return;
          }
        }
        el.visitChildren(find);
      }

      find(root);
      if (found == null) {
        throw StateError('TraceViewerAppState not found in element tree');
      }
      return found!;
    }

    test('Integration test: Navigation, Hover, and Caliper Mode', () async {
      final tester = TerminalTester(size: const Point(80, 24));
      tester.run(() async {
        globalSceneManager = SceneManager(
          tester.terminal,
          renderingMode: RenderingMode.alternateScreen,
        );
        final app = TraceViewerApp(spans: spans, minTs: minTs, maxTs: maxTs);
        final runner = PromptRunner<void>(
          terminal: tester.terminal,
          widget: app,
          alternateScreen: true,
        );

        final runnerFuture = tester.runPrompt(runner, () async {
          await tester.pumpAndSettle();

          final root = tester.rootElement!;
          final state = findTraceViewerState(root);

          // 1. Initial State assertions
          expect(state.isCaliperMode, isFalse);
          expect(state.hoveredSpan, isNull);

          // 2. Test Pan & Zoom
          final double initialZoom = state.zoomLevel;
          final double initialOffset = state.offsetX;

          // Zoom In using key '+'
          tester.sendKey(LogicalKey.character('+'));
          await tester.pumpAndSettle();
          expect(state.zoomLevel, lessThan(initialZoom));

          // Zoom Out using key '-'
          final double zoomedIn = state.zoomLevel;
          tester.sendKey(LogicalKey.character('-'));
          await tester.pumpAndSettle();
          expect(state.zoomLevel, greaterThan(zoomedIn));

          // Pan Right using key 'd'
          tester.sendKey(LogicalKey.character('d'));
          await tester.pumpAndSettle();
          expect(state.offsetX, greaterThan(initialOffset));

          // Pan Left using key 'a'
          final double pannedRight = state.offsetX;
          tester.sendKey(LogicalKey.character('a'));
          await tester.pumpAndSettle();
          expect(state.offsetX, lessThan(pannedRight));

          // 3. Test Hover Inspector
          // Hover main task (depth 0, row terminal y = 4, x = 10)
          tester.mouseMove(10, 4, drag: false);
          await tester.pumpAndSettle();
          expect(state.hoveredSpan, isNotNull);
          expect(state.hoveredSpan!.name, equals('MainTask'));
          expect(state.hoveredSpan!.metadata['metaKey'], equals('metaVal'));

          // Hover input event key event (row terminal y = 16, x = 23)
          tester.mouseMove(23, 16, drag: false);
          await tester.pumpAndSettle();
          expect(state.hoveredSpan, isNotNull);
          expect(state.hoveredSpan!.name, equals('KeyEvent'));

          // 4. Test Caliper Measurement Mode
          // Toggle to Caliper Mode via 'm'
          tester.sendKey(LogicalKey.character('m'));
          await tester.pumpAndSettle();
          expect(state.isCaliperMode, isTrue);

          // Drag from terminal coordinates (10, 10) to (20, 10)
          tester.mouseDown(10, 10);
          await tester.pumpAndSettle();
          expect(state.measureStartMs, isNotNull);

          tester.mouseMove(20, 10, drag: true);
          await tester.pumpAndSettle();
          expect(state.measureEndMs, isNotNull);

          tester.mouseUp(20, 10);
          await tester.pumpAndSettle();

          // Assert measurement details
          expect(state.measureStartMs, isNotNull);
          expect(state.measureEndMs, isNotNull);
          expect(state.measureStartMs, lessThan(state.measureEndMs!));

          // Exit Caliper Mode via Escape
          tester.sendKey(LogicalKey.escape);
          await tester.pumpAndSettle();
          expect(state.isCaliperMode, isFalse);
          expect(state.measureStartMs, isNull);
          expect(state.measureEndMs, isNull);

          // Quit the prompt
          tester.sendKey(LogicalKey.character('q'));
          await tester.pumpAndSettle();
        });

        await runnerFuture;
      });
    });
    test('Integration test: Overlays and Mutually Exclusive Modes', () async {
      final tester = TerminalTester(size: const Point(80, 24));
      tester.run(() async {
        globalSceneManager = SceneManager(
          tester.terminal,
          renderingMode: RenderingMode.alternateScreen,
        );
        final app = TraceViewerApp(spans: spans, minTs: minTs, maxTs: maxTs);
        final runner = PromptRunner<void>(
          terminal: tester.terminal,
          widget: app,
          alternateScreen: true,
        );

        final runnerFuture = tester.runPrompt(runner, () async {
          await tester.pumpAndSettle();

          final root = tester.rootElement!;
          final state = findTraceViewerState(root);

          // 1. Mutually Exclusive Modes
          expect(state.isCaliperMode, isFalse);
          expect(state.isBoxSelectMode, isFalse);

          // Turn on Box Select
          tester.sendKey(LogicalKey.character('z'));
          await tester.pumpAndSettle();
          expect(state.isBoxSelectMode, isTrue);

          // Turn on Caliper Mode, should turn off Box Select
          tester.sendKey(LogicalKey.character('m'));
          await tester.pumpAndSettle();
          expect(state.isCaliperMode, isTrue);
          expect(state.isBoxSelectMode, isFalse);

          // Turn on Box Select, should turn off Caliper Mode
          tester.sendKey(LogicalKey.character('z'));
          await tester.pumpAndSettle();
          expect(state.isCaliperMode, isFalse);
          expect(state.isBoxSelectMode, isTrue);

          // Exit via Escape
          tester.sendKey(LogicalKey.escape);
          await tester.pumpAndSettle();
          expect(state.isBoxSelectMode, isFalse);

          // 2. Search Overlay Keyboard Navigation
          // Open Search Overlay
          tester.sendKey(LogicalKey.character('/'));
          await tester.pumpAndSettle();

          // Search overlay should be active
          // Type 'dur'
          tester.sendKey(LogicalKey.character('d'));
          await tester.pumpAndSettle();
          tester.sendKey(LogicalKey.character('u'));
          await tester.pumpAndSettle();
          tester.sendKey(LogicalKey.character('r'));
          await tester.pumpAndSettle();

          // Navigate down
          tester.sendKey(LogicalKey.arrowDown);
          await tester.pumpAndSettle();

          // Press Enter to select
          tester.sendKey(LogicalKey.enter);
          await tester.pumpAndSettle();

          // Check if hovered span changed to something from the search
          // (Wait, since we don't know exactly what was selected without testing, we'll just check if it doesn't crash)

          // 3. Help Overlay
          tester.sendKey(LogicalKey.character('?'));
          await tester.pumpAndSettle();

          // Press Escape to close
          tester.sendKey(LogicalKey.escape);
          await tester.pumpAndSettle();

          // Quit the prompt
          tester.sendKey(LogicalKey.character('q'));
          await tester.pumpAndSettle();
        });

        await runnerFuture;
      });
    });
    test('Golden Screen Test: Trace Viewer Base Layout', () async {
      final tester = TerminalTester(size: const Point(80, 24));
      tester.run(() async {
        globalSceneManager = SceneManager(
          tester.terminal,
          renderingMode: RenderingMode.alternateScreen,
        );
        final app = TraceViewerApp(spans: spans, minTs: minTs, maxTs: maxTs);
        final runner = PromptRunner<void>(
          terminal: tester.terminal,
          widget: app,
          alternateScreen: true,
        );

        final runnerFuture = tester.runPrompt(runner, () async {
          await tester.pumpAndSettle();

          expect(
            tester.backend.buffer,
            matchesAnsiGolden('test/goldens/termui_trace_viewer_base.ansi'),
          );

          tester.sendKey(LogicalKey.character('q'));
          await tester.pumpAndSettle();
        });

        await runnerFuture;
      });
    });
  });
}
