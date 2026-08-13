import 'dart:convert';
import 'dart:math';
import 'package:termui_recorder/termui_recorder.dart';
import 'package:file/memory.dart';
import 'package:test/test.dart';
import 'package:termui_test/termui_test.dart';
import 'package:termui/termui.dart';
import 'package:termui/termui_trace.dart';

void main() {
  group('Trace Viewer Export Integration Tests', () {
    late List<TraceSpan> spans;
    late int minTs;
    late int maxTs;

    setUp(() {
      // Clean slate for FocusManager singleton
      FocusManager.instance.setPrimaryFocus(null);

      // Create mock JSON events
      final rawEvents = [
        TraceEvent(
          name: 'TaskA',
          phase: 'B',
          category: 'event',
          timestamp: 999000,
          tid: 1,
          args: {},
        ),
        TraceEvent(
          name: 'TaskA',
          phase: 'E',
          category: 'event',
          timestamp: 1000000,
          tid: 1,
          args: {},
        ),
        TraceEvent(
          name: 'TaskB',
          phase: 'B',
          category: 'event',
          timestamp: 1000500,
          tid: 1,
          args: {},
        ),
        TraceEvent(
          name: 'TaskB',
          phase: 'E',
          category: 'event',
          timestamp: 1001000,
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

    test('Integration test: Box select and Export via Modal', () {
      final fs = MemoryFileSystem();
      final tester = TerminalTester(size: const Point(80, 24));
      tester.run(() async {
        globalSceneManager = SceneManager(
          tester.terminal,
          renderingMode: RenderingMode.alternateScreen,
        );
        globalSceneManager.enableMouseTracking = true;

        // Pass MemoryFileSystem
        final app = TraceViewerApp(
          spans: spans,
          minTs: minTs,
          maxTs: maxTs,
          fileSystem: fs,
        );

        final runner = PromptRunner<void>(
          terminal: tester.terminal,
          widget: app,
          alternateScreen: false,
          mode: ExecutionMode.managed,
          onFramePainted: (_) => globalSceneManager.render(),
        );

        // Put app inside a layer
        final appLayer = SceneLayer(
          renderer: runner,
          sizing: LayerSizing.fullscreen,
        );
        globalSceneManager.layers.add(appLayer);
        globalSceneManager.focusedLayer = appLayer;

        runner.resize(80, 24);

        await tester.runPrompt(runner, () async {
          await tester.pump();

          final root = tester.rootElement!;
          final state = findTraceViewerState(root);

          print('Primary Focus: ${FocusManager.instance.primaryFocus}');

          // Turn on Box Select mode
          tester.sendKey(LogicalKey.character('z'));
          await tester.pump();
          print('isBoxSelectMode: ${state.isBoxSelectMode}');
          expect(state.isBoxSelectMode, isTrue);

          // Mock hovering over first span
          state.setState(() {
            state.hoveredSpan = spans[0];
          });
          await tester.pump();

          // Start selection with '['
          tester.sendKey(LogicalKey.character('['));
          await tester.pump();
          expect(state.selectionStartUs, equals(spans[0].startUs));

          // Mock hovering over second span
          state.setState(() {
            state.hoveredSpan = spans[1];
          });
          await tester.pump();

          // End selection with ']'
          tester.sendKey(LogicalKey.character(']'));
          await tester.pump();
          expect(state.selectionEndUs, equals(spans[1].endUs));

          // Press Ctrl+S to spawn modal
          tester.sendKey(LogicalKey.character('s'), control: true);
          await tester.pump();

          // The save layer should exist
          expect(globalSceneManager.layers.length, equals(2));
          final saveLayer = globalSceneManager.focusedLayer!;
          expect(saveLayer, isNot(appLayer));

          // Golden match for the save modal
          await expectLater(
            tester.backend.buffer,
            matchesAnsiGolden(
              'test/goldens/trace_viewer_save_modal.ansi',
              environment: {'GENERATE_GOLDENS': 'true'},
            ),
          );

          // Focus should be in TextField, send enter
          tester.sendKey(LogicalKey.enter);
          await tester.pump();

          // Modal should be closed
          expect(globalSceneManager.layers.length, equals(1));
          expect(globalSceneManager.focusedLayer, equals(appLayer));

          // File should exist in memory filesystem
          final exportedFile = fs.file('trace_cropped.json');
          expect(exportedFile.existsSync(), isTrue);

          // Verify content
          final content = exportedFile.readAsStringSync();
          final json = jsonDecode(content) as List;
          expect(json.length, equals(4)); // 2 spans * (1 B + 1 E) = 4 events

          runner.dispose();
        });

        // Terminate SceneManager
        globalSceneManager.dispose();
      }); // closes tester.run
    }); // closes test

    test('Integration test: Modal cancel via Esc', () {
      final fs = MemoryFileSystem();
      final tester = TerminalTester(size: const Point(80, 24));
      tester.run(() async {
        globalSceneManager = SceneManager(
          tester.terminal,
          renderingMode: RenderingMode.alternateScreen,
        );
        globalSceneManager.enableMouseTracking = true;

        final app = TraceViewerApp(
          spans: spans,
          minTs: minTs,
          maxTs: maxTs,
          fileSystem: fs,
        );

        final runner = PromptRunner<void>(
          terminal: tester.terminal,
          widget: app,
          alternateScreen: false,
          mode: ExecutionMode.managed,
          onFramePainted: (_) => globalSceneManager.render(),
        );

        final appLayer = SceneLayer(
          renderer: runner,
          sizing: LayerSizing.fullscreen,
        );
        globalSceneManager.layers.add(appLayer);
        globalSceneManager.focusedLayer = appLayer;

        await tester.runPrompt(runner, () async {
          await tester.pump();
          final state = findTraceViewerState(tester.rootElement!);

          state.setState(() {
            state.hoveredSpan = spans[0];
          });
          await tester.pump();

          tester.sendKey(LogicalKey.character('['));
          await tester.pump();

          state.setState(() {
            state.hoveredSpan = spans[1];
          });
          await tester.pump();

          tester.sendKey(LogicalKey.character(']'));
          await tester.pump();

          // Press Ctrl+S to spawn modal
          tester.sendKey(LogicalKey.character('s'), control: true);
          await tester.pump();

          expect(globalSceneManager.layers.length, equals(2));

          // Press Escape
          tester.sendKey(LogicalKey.escape);
          await tester.pump();

          // Modal should be closed
          expect(globalSceneManager.layers.length, equals(1));
          expect(globalSceneManager.focusedLayer, equals(appLayer));

          // File should NOT exist
          final exportedFile = fs.file('trace_cropped.json');
          expect(exportedFile.existsSync(), isFalse);

          runner.dispose();
        });

        globalSceneManager.dispose();
      });
    });

    test(
      'Integration test: Save modal spawns correctly after crop operation',
      () {
        final fs = MemoryFileSystem();
        final tester = TerminalTester(size: const Point(80, 24));
        tester.run(() async {
          globalSceneManager = SceneManager(
            tester.terminal,
            renderingMode: RenderingMode.alternateScreen,
          );
          globalSceneManager.enableMouseTracking = true;

          final app = TraceViewerApp(
            spans: spans,
            minTs: minTs,
            maxTs: maxTs,
            fileSystem: fs,
          );

          final runner = PromptRunner<void>(
            terminal: tester.terminal,
            widget: app,
            alternateScreen: false,
            mode: ExecutionMode.managed,
            onFramePainted: (_) => globalSceneManager.render(),
          );

          final appLayer = SceneLayer(
            renderer: runner,
            sizing: LayerSizing.fullscreen,
          );
          globalSceneManager.layers.add(appLayer);
          globalSceneManager.focusedLayer = appLayer;

          await tester.runPrompt(runner, () async {
            await tester.pump();
            final state = findTraceViewerState(tester.rootElement!);

            // Mock hovering over first span
            state.setState(() {
              state.hoveredSpan = spans[0];
            });
            await tester.pump();

            // Start selection with '['
            tester.sendKey(LogicalKey.character('['));
            await tester.pump();

            // Mock hovering over second span
            state.setState(() {
              state.hoveredSpan = spans[1];
            });
            await tester.pump();

            // End selection with ']'
            tester.sendKey(LogicalKey.character(']'));
            await tester.pump();

            // Press Ctrl+X to crop
            tester.sendKey(LogicalKey.character('x'), control: true);
            await tester.pump();

            // The selection should be cleared
            expect(state.selectionStartUs, isNull);
            expect(state.selectionEndUs, isNull);

            // Press Ctrl+S to spawn modal
            tester.sendKey(LogicalKey.character('s'), control: true);
            await tester.pump();

            // The save layer should exist
            expect(globalSceneManager.layers.length, equals(2));
            final saveLayer = globalSceneManager.focusedLayer!;
            expect(saveLayer, isNot(appLayer));

            // Golden match for the save modal after crop
            await expectLater(
              tester.backend.buffer,
              matchesAnsiGolden(
                'test/goldens/trace_viewer_save_modal_after_crop.ansi',
                environment: {'GENERATE_GOLDENS': 'true'},
              ),
            );

            // Focus should be in TextField, send enter
            tester.sendKey(LogicalKey.enter);
            await tester.pump();

            // Modal should be closed
            expect(globalSceneManager.layers.length, equals(1));
            expect(globalSceneManager.focusedLayer, equals(appLayer));

            // File should exist in memory filesystem
            final exportedFile = fs.file('trace_cropped.json');
            expect(exportedFile.existsSync(), isTrue);

            // Verify content
            final content = exportedFile.readAsStringSync();
            final json = jsonDecode(content) as List;
            expect(json.length, equals(4)); // 2 spans * (1 B + 1 E) = 4 events

            runner.dispose();
          });

          // Terminate SceneManager
          globalSceneManager.dispose();
        });
      },
    );
  });
}
