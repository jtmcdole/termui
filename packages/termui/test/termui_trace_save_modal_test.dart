import 'dart:math';

import 'package:file/memory.dart';
import 'package:termui/termui.dart';
import 'package:termui/termui_trace.dart';
import 'package:termui_test/termui_test.dart';
import 'package:test/test.dart';

void main() {
  group('Trace Viewer Save Modal UI Tests', () {
    final spans = [
      TraceSpan(
        name: 'test span 1',
        startUs: 1000,
        endUs: 2000,
        category: 'test',
        depth: 0,
        args: {},
      ),
      TraceSpan(
        name: 'test span 2',
        startUs: 1500,
        endUs: 2500,
        category: 'test',
        depth: 1,
        args: {},
      ),
    ];
    final minTs = 1000;
    final maxTs = 2500;

    test(
      'Integration test: Save modal saves, dismisses and shows 3s message',
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

            // Press Ctrl+S to spawn modal (we have no selection, so it selects all)
            tester.sendKey(LogicalKey.character('s'), control: true);
            await tester.pump();

            expect(globalSceneManager.layers.length, equals(2));

            // Press Enter to submit
            tester.sendKey(LogicalKey.enter);
            await tester.pump();

            // Modal should be dismissed
            expect(globalSceneManager.layers.length, equals(1));

            // File should exist
            final exportedFile = fs.file('trace_cropped.json');
            expect(exportedFile.existsSync(), isTrue);

            // exportMessage should be set
            expect(state.exportMessage, isNotNull);
            expect(state.exportMessage, contains('Exported'));

            // Wait 3 seconds using pump so fakeAsync elapses it safely
            await tester.pump(const Duration(seconds: 3));

            // Message should be gone
            expect(state.exportMessage, isNull);

            runner.dispose();
          });

          globalSceneManager.dispose();
        });
      },
    );

    test('Integration test: Save modal [x] dismisses without saving', () {
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

          // Make sure no message initially
          expect(state.exportMessage, isNull);

          // Press Ctrl+S to spawn modal
          tester.sendKey(LogicalKey.character('s'), control: true);
          await tester.pump();

          // Click [x] button
          tester.mouseDown(62, 9);
          tester.mouseUp(62, 9);
          await tester.pump();

          // Modal should be dismissed
          expect(globalSceneManager.layers.length, equals(1));

          // File should not exist
          final exportedFile = fs.file('trace_cropped.json');
          expect(exportedFile.existsSync(), isFalse);

          // exportMessage should still be null
          expect(state.exportMessage, isNull);

          runner.dispose();
        });

        globalSceneManager.dispose();
      });
    });
  });
}

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
  return found;
}
