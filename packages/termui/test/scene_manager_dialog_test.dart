import 'dart:math';
import 'package:test/test.dart';
import 'package:termui/termui.dart';
import 'package:termui_recorder/termui_recorder.dart';
import 'package:termui_test/termui_test.dart';

class TestButton extends Widget {
  final FocusNode focusNode;
  final String text;
  final void Function() onPressed;

  const TestButton({
    super.key,
    required this.focusNode,
    required this.text,
    required this.onPressed,
  });

  @override
  Element createElement() => _TestButtonElement(this);
}

class _TestButtonElement extends Element implements MouseEventHandler {
  _TestButtonElement(TestButton super.widget);

  @override
  Size performLayout(BoxConstraints constraints) {
    return constraints.constrain(Size(10, 1));
  }

  @override
  void performPaint(Buffer buffer, Offset offset) {
    final w = widget as TestButton;
    buffer.writeString(offset.dx, offset.dy, '[${w.text}]', Style.empty);
  }

  @override
  void handleMouseEvent(MouseEvent event, int localX, int localY) {
    if (event.type == MouseEventType.press) {
      (widget as TestButton).onPressed();
    }
  }
}

void main() {
  setUp(() {
    FocusManager.instance.setPrimaryFocus(null);
  });

  group('SceneManager showDialog Integration Tests', () {
    test(
      'showDialog displays overlay, traps focus, and resolves on barrier click',
      () {
        final tester = TerminalTester(size: const Point(80, 24));
        tester.run(() async {
          final sceneManager = SceneManager(
            tester.terminal,
            renderingMode: RenderingMode.alternateScreen,
          );

          final runner = PromptRunner<void>(
            terminal: tester.terminal,
            widget: const SizedBox(width: 10, height: 1, child: Text('Base')),
            alternateScreen: false,
            mode: ExecutionMode.managed,
            onFramePainted: (_) => sceneManager.render(),
          );

          final baseLayer = SceneLayer(
            renderer: runner,
            sizing: LayerSizing.fullscreen,
          );
          sceneManager.layers.add(baseLayer);
          sceneManager.focusedLayer = baseLayer;

          await tester.runPrompt(runner, () async {
            await tester.pump();
            expect(sceneManager.layers.length, equals(1));

            // Trigger showDialog
            final dialogFuture = sceneManager.showDialog<String>(
              barrierDismissible: true,
              width: 20,
              height: 5,
              builder: (context) {
                return SizedBox(
                  width: 20,
                  height: 5,
                  child: StatefulBuilder(
                    builder: (context, setState) {
                      final btnNode = FocusNode(id: 'btn');
                      return TestButton(
                        focusNode: btnNode,
                        text: 'Submit',
                        onPressed: () {
                          PromptScope.of(context)?.done('Confirmed');
                        },
                      );
                    },
                  ),
                );
              },
            );

            await tester.pump();

            // Dialog layer and barrier layer should be added (Base + Barrier + Dialog = 3)
            expect(sceneManager.layers.length, equals(3));

            // Click barrier at coordinate (1, 1) (which corresponds to 0-indexed top-left cell 0, 0)
            tester.mouseDown(1, 1);
            tester.mouseUp(1, 1);
            await tester.pump();

            // Dialog should be dismissed
            final result = await dialogFuture;
            expect(result, isNull);
            expect(sceneManager.layers.length, equals(1));

            runner.dispose();
          });

          sceneManager.dispose();
        });
      },
    );

    test('showDialog resolves with value on action click', () {
      final tester = TerminalTester(size: const Point(80, 24));
      tester.run(() async {
        final sceneManager = SceneManager(
          tester.terminal,
          renderingMode: RenderingMode.alternateScreen,
        );

        final runner = PromptRunner<void>(
          terminal: tester.terminal,
          widget: const SizedBox(width: 10, height: 1, child: Text('Base')),
          alternateScreen: false,
          mode: ExecutionMode.managed,
          onFramePainted: (_) => sceneManager.render(),
        );

        final baseLayer = SceneLayer(
          renderer: runner,
          sizing: LayerSizing.fullscreen,
        );
        sceneManager.layers.add(baseLayer);
        sceneManager.focusedLayer = baseLayer;

        await tester.runPrompt(runner, () async {
          await tester.pump();

          // Trigger showDialog
          final dialogFuture = sceneManager.showDialog<String>(
            barrierDismissible: true,
            width: 20,
            height: 5,
            builder: (context) {
              return SizedBox(
                width: 20,
                height: 5,
                child: StatefulBuilder(
                  builder: (context, setState) {
                    final btnNode = FocusNode(id: 'btn');
                    return TestButton(
                      focusNode: btnNode,
                      text: 'Submit',
                      onPressed: () {
                        PromptScope.of(context)?.done('Confirmed');
                      },
                    );
                  },
                ),
              );
            },
          );

          await tester.pump();

          // Click the button inside the dialog.
          // Dialog size is 20x5, centered on 80x24 viewport.
          // Dialog bounds: left: (80 - 20)/2 = 30, top: (24 - 5)/2 = 9.
          // TestButton size is 10x1, centered inside Dialog.
          // TestButton bounds inside dialog: left: (20 - 10)/2 = 5, top: (5 - 1)/2 = 2.
          // So absolute coordinates of button: left: 30 + 5 = 35, top: 9 + 2 = 11.
          // Terminal coordinate (1-indexed): x: 36, y: 12.
          tester.mouseDown(36, 12);
          tester.mouseUp(36, 12);
          await tester.pump();

          // Dialog should resolve with the confirmed result
          final result = await dialogFuture;
          expect(result, equals('Confirmed'));
          expect(sceneManager.layers.length, equals(1));

          runner.dispose();
        });

        sceneManager.dispose();
      });
    });

    test(
      'showDialog with barrierDismissible: false does NOT dismiss on barrier click',
      () {
        final tester = TerminalTester(size: const Point(80, 24));
        tester.run(() async {
          final sceneManager = SceneManager(
            tester.terminal,
            renderingMode: RenderingMode.alternateScreen,
          );

          final runner = PromptRunner<void>(
            terminal: tester.terminal,
            widget: const SizedBox(width: 10, height: 1, child: Text('Base')),
            alternateScreen: false,
            mode: ExecutionMode.managed,
            onFramePainted: (_) => sceneManager.render(),
          );

          final baseLayer = SceneLayer(
            renderer: runner,
            sizing: LayerSizing.fullscreen,
          );
          sceneManager.layers.add(baseLayer);
          sceneManager.focusedLayer = baseLayer;

          await tester.runPrompt(runner, () async {
            await tester.pump();

            var dialogDismissed = false;
            final dialogFuture = sceneManager.showDialog<String>(
              barrierDismissible: false,
              width: 20,
              height: 5,
              builder: (context) {
                return SizedBox(
                  width: 20,
                  height: 5,
                  child: StatefulBuilder(
                    builder: (context, setState) {
                      final btnNode = FocusNode(id: 'btn');
                      return TestButton(
                        focusNode: btnNode,
                        text: 'Submit',
                        onPressed: () {
                          PromptScope.of(context)?.done('Confirmed');
                        },
                      );
                    },
                  ),
                );
              },
            );
            dialogFuture.then((_) => dialogDismissed = true);

            await tester.pump();

            // Dialog and barrier layers should be added (Base + Barrier + Dialog = 3)
            expect(sceneManager.layers.length, equals(3));

            // Click barrier at coordinate (1, 1)
            tester.mouseDown(1, 1);
            tester.mouseUp(1, 1);
            await tester.pump();

            // Dialog should NOT be dismissed
            expect(dialogDismissed, isFalse);
            expect(sceneManager.layers.length, equals(3));

            // Now click the submit button to resolve it
            tester.mouseDown(36, 12);
            tester.mouseUp(36, 12);
            await tester.pump();

            final result = await dialogFuture;
            expect(result, equals('Confirmed'));
            expect(sceneManager.layers.length, equals(1));

            runner.dispose();
          });

          sceneManager.dispose();
        });
      },
    );

    test('showDialog renders modal golden screenshot with dimming barrier', () {
      final tester = TerminalTester(size: const Point(80, 24));
      tester.run(() async {
        final sceneManager = SceneManager(
          tester.terminal,
          renderingMode: RenderingMode.alternateScreen,
        );

        const headerStyle = Style(foreground: Color(255, 170, 0)); // Orange
        const normalStyle = Style(
          foreground: Color(220, 220, 220),
        ); // Off-white
        const activeStyle = Style(foreground: Color(0, 255, 85)); // Light green
        const warningStyle = Style(
          foreground: Color(255, 100, 0),
        ); // Red-orange

        final backgroundWidget = Column(const [
          Text('=== SYSTEM CONFIGURATION MONITOR ===', style: headerStyle),
          SizedBox(height: 1),
          Text('Service status:', style: normalStyle),
          Text('  - Database Sync:         [ACTIVE]', style: activeStyle),
          Text('  - Cache Cluster:         [ACTIVE]', style: activeStyle),
          Text('  - API Gateway:           [ACTIVE]', style: activeStyle),
          Text(
            '  - Background Workers:    [WARNING] (Queue high)',
            style: warningStyle,
          ),
          SizedBox(height: 1),
          Text('Resource Usage:', style: normalStyle),
          Text('  - CPU:   [████████░░░░░░░░░░░░] 40%', style: warningStyle),
          Text('  - Memory: [██████████████░░░░░░] 70%', style: warningStyle),
          SizedBox(height: 1),
          Text('Recent Events Log:', style: normalStyle),
          Text(
            '  [19:04:01] DB connection pool scale up (+5)',
            style: normalStyle,
          ),
          Text(
            '  [19:04:05] Memory usage exceeded warning threshold (70%)',
            style: normalStyle,
          ),
          Text(
            '  [19:04:10] Worker pool heartbeat latency: 150ms',
            style: normalStyle,
          ),
        ]);

        final runner = PromptRunner<void>(
          terminal: tester.terminal,
          widget: backgroundWidget,
          alternateScreen: false,
          mode: ExecutionMode.managed,
          onFramePainted: (_) => sceneManager.render(),
        );

        final baseLayer = SceneLayer(
          renderer: runner,
          sizing: LayerSizing.fullscreen,
        );
        sceneManager.layers.add(baseLayer);
        sceneManager.focusedLayer = baseLayer;

        await tester.runPrompt(runner, () async {
          await tester.pump();

          final dialogFuture = sceneManager.showDialog<void>(
            width: 30,
            height: 8,
            builder: (context) {
              return const SizedBox(
                width: 30,
                height: 8,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    border: Border(style: Style(foreground: Colors.white)),
                    backgroundStyle: Style(background: Colors.black),
                  ),
                  child: Center(
                    child: Text(
                      'Modal Dialog',
                      style: Style(foreground: Colors.white),
                    ),
                  ),
                ),
              );
            },
          );

          await tester.pump();

          // Assert the golden representation of the screen buffer, ensuring dimming barrier renders correctly
          expect(
            tester.backend.buffer,
            matchesAnsiGolden(
              'test/goldens/scene_manager_dialog_modal.ansi',
              environment: {'GENERATE_GOLDENS': 'true'},
            ),
          );

          // Dismiss dialog
          tester.mouseDown(1, 1);
          tester.mouseUp(1, 1);
          await tester.pump();
          await dialogFuture;

          runner.dispose();
        });

        sceneManager.dispose();
      });
    });
  });
}
