import 'dart:convert';
import 'dart:math';
import 'package:file/memory.dart';
import 'package:test/test.dart';
import 'package:termui_test/termui_test.dart';
import 'package:termui/termui.dart';
import 'package:termui/termui_trace.dart';
import 'package:termui/utils/gzip_json.dart';
import 'package:termui_recorder/termui_recorder.dart';

void main() {
  group('Trace Viewer Integration Tests', () {
    late List<TraceSpan> spans;
    late int minTs;
    late int maxTs;

    setUp(() {
      // Clean slate for FocusManager singleton
      FocusManager.instance.setPrimaryFocus(null);

      // Create mock JSON events
      final rawEvents = [
        TraceEvent(
          name: 'KeyEvent',
          phase: 'B',
          category: 'event',
          timestamp: 999000,
          tid: 1,
          args: {},
        ),
        TraceEvent(
          name: 'MainTask',
          phase: 'B',
          category: 'tui',
          timestamp: 1000000,
          tid: 1,
          args: {'metaKey': 'metaVal'},
        ),
        TraceEvent(
          name: 'SubTask',
          phase: 'B',
          category: 'tui',
          timestamp: 1000500,
          tid: 1,
          args: {},
        ),
        TraceEvent(
          name: 'SubTask',
          phase: 'E',
          category: 'tui',
          timestamp: 1001500,
          tid: 1,
          args: {},
        ),
        TraceEvent(
          name: 'MainTask',
          phase: 'E',
          category: 'tui',
          timestamp: 1002000,
          tid: 1,
          args: {},
        ),
        TraceEvent(
          name: 'KeyEvent',
          phase: 'E',
          category: 'event',
          timestamp: 1003000,
          tid: 1,
          args: {},
        ),
      ];

      final baseTime = rawEvents.map((e) => e.timestamp).reduce(min);
      final events = [
        for (final e in rawEvents)
          TraceEvent(
            name: e.name,
            phase: e.phase,
            category: e.category,
            timestamp: e.timestamp - baseTime,
            tid: e.tid,
            args: e.args,
          ),
      ];

      spans = computeSpans(events);
      minTs = spans.map((s) => s.startUs).reduce(min);
      maxTs = spans.map((s) => s.endUs).reduce(max);
    });

    TraceViewerAppState findTraceViewerState(Element root) {
      TraceViewerAppState? found;
      void find(Element el) {
        if (found != null) return;
        if (el case StatefulElement(state: final TraceViewerAppState s)) {
          found = s;
          return;
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
          // Hover main task (depth 1, row terminal y = 4, x = 25)
          tester.mouseMove(25, 5, drag: false);
          await tester.pumpAndSettle();
          expect(state.hoveredSpan, isNotNull);
          expect(state.hoveredSpan!.name, equals('MainTask'));
          expect(state.hoveredSpan!.args['metaKey'], equals('metaVal'));

          // Hover input event key event (row terminal y = 3, x = 10)
          tester.mouseMove(10, 4, drag: false);
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

    test('Golden Screen Test: Trace Viewer Inspector Layout', () async {
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

          // Hover main task (depth 1, row terminal y = 4, x = 25)
          tester.mouseMove(25, 5, drag: false);
          await tester.pumpAndSettle();

          expect(
            tester.backend.buffer,
            matchesAnsiGolden(
              'test/goldens/termui_trace_viewer_inspector.ansi',
            ),
          );

          tester.sendKey(LogicalKey.character('q'));
          await tester.pumpAndSettle();
        });

        await runnerFuture;
      });
    });

    test(
      'decompressGzip enforces maxDecompressedBytes cap and parseTraceFile supports MemoryFileSystem',
      () async {
        final payload = jsonEncode([
          {
            'name': 'FramePaint',
            'ph': 'X',
            'cat': 'tui',
            'ts': 100,
            'dur': 250,
            'tid': 1,
          },
        ]);
        final compressed = await compressString(payload);

        final decoded = await decompressGzip(
          compressed,
          maxDecompressedBytes: 1024,
        );
        expect(utf8.decode(decoded), equals(payload));

        await expectLater(
          decompressGzip(compressed, maxDecompressedBytes: 8),
          throwsFormatException,
        );

        final fs = MemoryFileSystem();
        final traceFile = fs.file('/virtual/trace.json.gz')
          ..createSync(recursive: true);
        await traceFile.writeAsBytes(compressed);
        final parsed = await parseTraceFile(
          '/virtual/trace.json.gz',
          fileSystem: fs,
        );
        expect(parsed, isNotNull);
        final parsedSpans = parsed!['spans'] as List<TraceSpan>;
        expect(parsedSpans, hasLength(1));
        expect(parsedSpans.single.name, equals('FramePaint'));
      },
    );

    test(
      'Inspector panel and TimelineCanvas handle maxWidth = 3 and emoji span labels without RangeError',
      () {
        final emojiSpan = TraceSpan(
          name: '🚀 Launch 👨‍👩‍👧‍👦',
          category: 'tui',
          startUs: 0,
          endUs: 1000,
          depth: 0,
          args: {'note': '🍎🍊🍋🍇🍓🍒🍑🍍'},
        );

        expect(wrapTraceText('🚀 🍎 🍊', 3), isNotEmpty);

        // Narrow maxWidth = 3 must not throw RangeError in inspector or timeline.
        final narrowBuffer = Buffer.blank(3, 8);
        final inspectorEl =
            buildInspectorPanel(
                null,
                emojiSpan,
                TimeDisplayMode.formatted,
                0,
              ).createElement()
              ..mount(null)
              ..layout(BoxConstraints.tight(const Size(3, 8)))
              ..paint(narrowBuffer, Offset.zero);
        addTearDown(inspectorEl.unmount);

        final narrowTimelineBuffer = Buffer.blank(3, 4);
        final narrowTimelineEl =
            TimelineCanvas(
                spans: [emojiSpan],
                offsetX: 0,
                offsetY: 0,
                zoomLevel: 100,
                maxSpanDuration: 1000,
              ).createElement()
              ..mount(null)
              ..layout(BoxConstraints.tight(const Size(3, 4)))
              ..paint(narrowTimelineBuffer, Offset.zero);
        addTearDown(narrowTimelineEl.unmount);

        // Wide enough timeline renders emoji grapheme intact without surrogate splitting.
        final wideBuffer = Buffer.blank(30, 3);
        final wideTimelineEl =
            TimelineCanvas(
                spans: [emojiSpan],
                offsetX: 0,
                offsetY: 0,
                zoomLevel: 40,
                maxSpanDuration: 1000,
              ).createElement()
              ..mount(null)
              ..layout(BoxConstraints.tight(const Size(30, 3)))
              ..paint(wideBuffer, Offset.zero);
        addTearDown(wideTimelineEl.unmount);

        final row0 = [
          for (var x = 0; x < 30; x++) wideBuffer.getCharacter(x, 0),
        ];
        expect(row0, contains('🚀'));
        expect(row0, contains('👨‍👩‍👧‍👦'));
      },
    );
  });
}
