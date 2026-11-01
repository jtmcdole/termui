import 'dart:async';
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

typedef _TwoLayerSceneBody =
    Future<void> Function(
      TerminalTester tester,
      SceneManager sceneManager,
      SceneLayer layerA,
      SceneLayer layerB,
    );

void _runTwoLayerScene({
  required Widget Function(
    SceneManager sceneManager,
    SceneLayer Function() getLayerB,
  )
  buildLayerB,
  required _TwoLayerSceneBody body,
  bool layerBInitiallyFocused = false,
  bool layerBDraggable = false,
  bool layerBResizable = false,
  int layerBWidth = 14,
  int layerBHeight = 1,
  void Function()? onLayerAFocus,
  void Function(SceneManager sceneManager, SceneLayer layerB)? onLayerBFocus,
}) {
  final tester = TerminalTester(size: const Point(60, 20));
  tester.run(() async {
    final sceneManager = SceneManager(
      tester.terminal,
      renderingMode: .alternateScreen,
    );
    addTearDown(sceneManager.dispose);

    late final SceneLayer layerB;
    final runnerA = PromptRunner<void>(
      terminal: tester.terminal,
      widget: const SizedBox(width: 12, height: 1, child: Text('Layer A')),
      alternateScreen: false,
      mode: .managed,
      onFramePainted: (_) => sceneManager.render(),
    );
    final runnerB = PromptRunner<void>(
      terminal: tester.terminal,
      widget: buildLayerB(sceneManager, () => layerB),
      alternateScreen: false,
      mode: .managed,
      onFramePainted: (_) => sceneManager.render(),
    );

    final layerA = SceneLayer(
      renderer: runnerA,
      sizing: .fixed,
      x: 0,
      y: 0,
      width: 12,
      height: 1,
      onFocus: onLayerAFocus,
    );
    layerB = SceneLayer(
      renderer: runnerB,
      sizing: .fixed,
      x: 0,
      y: 2,
      width: layerBWidth,
      height: layerBHeight,
      draggable: layerBDraggable,
      resizable: layerBResizable,
      onFocus: onLayerBFocus == null
          ? null
          : () => onLayerBFocus(sceneManager, layerB),
    );
    sceneManager.layers.add(layerA);
    sceneManager.layers.add(layerB);
    sceneManager.focusedLayer = layerA;
    if (layerBInitiallyFocused) {
      sceneManager.focusedLayer = layerB;
    }

    unawaited(runnerA.run());
    await tester.runPrompt(runnerB, () async {
      try {
        await tester.pump();
        await body(tester, sceneManager, layerA, layerB);
      } finally {
        runnerA.dispose();
        runnerB.dispose();
      }
    });
  });
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
            matchesAnsiGolden('test/goldens/scene_manager_dialog_modal.ansi'),
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

    test(
      'showDialog centers responsively on terminal resize events and handles bounds safety',
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

            final dialogFuture = sceneManager.showDialog<void>(
              width: 20,
              height: 10,
              builder: (context) {
                return const SizedBox(
                  width: 20,
                  height: 10,
                  child: Text('Dialog'),
                );
              },
            );

            await tester.pump();

            // Get reference to the dialog layer
            // dialogLayer is the 3rd layer added (index 2)
            final dialogLayer = sceneManager.layers[2];
            expect(dialogLayer.sizing, equals(LayerSizing.fixed));

            // Initial centering verification
            expect(dialogLayer.x, equals((80 - 20) ~/ 2)); // 30
            expect(dialogLayer.y, equals((24 - 10) ~/ 2)); // 7

            // Resize terminal to 100x40
            await tester.simulateResize(const Size(100, 40));
            await tester.pump();

            // Centering verification after resize
            expect(dialogLayer.x, equals((100 - 20) ~/ 2)); // 40
            expect(dialogLayer.y, equals((40 - 10) ~/ 2)); // 15

            // Test coordinate boundary safety with a terminal smaller than the dialog
            await tester.simulateResize(const Size(10, 5));
            await tester.pump();

            // Centering offsets should be clamped to 0
            expect(dialogLayer.x, equals(0));
            expect(dialogLayer.y, equals(0));

            // Resize back to 100x40 so we can click the barrier to dismiss
            await tester.simulateResize(const Size(100, 40));
            await tester.pump();

            // Clean up by clicking barrier (which is outside the 20x10 dialog centered at 40,15)
            tester.mouseDown(1, 1);
            tester.mouseUp(1, 1);
            await tester.pump();
            await dialogFuture;

            runner.dispose();
          });

          sceneManager.dispose();
        });
      },
    );

    test(
      'showDialog opened inside unfocused layer press focuses modal, defers onFocus until dismissal, and restores keyboard delivery',
      () {
        final modalController = TextEditingController();
        final layerBFocusNode = FocusNode(id: 'layer_b_focus');
        addTearDown(layerBFocusNode.dispose);
        final layerBKeys = <String>[];
        var layerAFocusCalls = 0;
        var layerBFocusCalls = 0;

        _runTwoLayerScene(
          layerBDraggable: true,
          onLayerAFocus: () => layerAFocusCalls++,
          onLayerBFocus: (_, _) {
            layerBFocusCalls++;
            layerBFocusNode.requestFocus();
          },
          buildLayerB: (sceneManager, _) => KeyboardListener(
            focusNode: layerBFocusNode,
            onKeyEvent: (event) {
              if (event.type == .character) {
                layerBKeys.add(event.key);
                return true;
              }
              return false;
            },
            child: Button(
              text: 'Open Modal',
              onPressed: () {
                unawaited(
                  sceneManager.showDialog<String>(
                    width: 30,
                    height: 6,
                    builder: (_) =>
                        TextField(controller: modalController, focused: true),
                  ),
                );
              },
            ),
          ),
          body: (tester, sceneManager, layerA, layerB) async {
            expect(sceneManager.focusedLayer, same(layerA));

            tester.mouseDown(2, 3);
            tester.mouseMove(6, 5);
            tester.mouseUp(6, 5);
            await tester.pump();

            expect(sceneManager.layers, hasLength(4));
            final dialogLayer = sceneManager.layers.last;
            expect(sceneManager.focusedLayer, same(dialogLayer));
            expect(layerB.x, equals(0));
            expect(layerB.y, equals(2));
            expect(layerBFocusCalls, equals(0));

            tester.sendString('ok');
            await tester.pump();
            expect(modalController.value.text, equals('ok'));
            expect(layerBKeys, isEmpty);

            // Dismiss via barrier click; layerB regains focus and receives onFocus + keys.
            tester.mouseDown(1, 1);
            tester.mouseUp(1, 1);
            await tester.pump();
            expect(sceneManager.layers, [layerA, layerB]);
            expect(sceneManager.focusedLayer, same(layerB));
            expect(layerBFocusCalls, equals(1));

            tester.sendString('b');
            await tester.pump();
            expect(layerBKeys, ['b']);

            // Removing layerB restores layerA from _focusStack and triggers its onFocus.
            sceneManager.layers.remove(layerB);
            expect(sceneManager.focusedLayer, same(layerA));
            expect(layerAFocusCalls, equals(1));
          },
        );
      },
    );

    test(
      'showDialog opened from already-focused layer press retains modal focus and fires onFocus on restoration',
      () {
        final layerBFocusNode = FocusNode(id: 'focused_layer_b');
        addTearDown(layerBFocusNode.dispose);
        final layerBKeys = <String>[];
        var layerBFocusCalls = 0;
        Future<String?>? dialogFuture;

        _runTwoLayerScene(
          layerBInitiallyFocused: true,
          onLayerBFocus: (_, _) {
            layerBFocusCalls++;
            layerBFocusNode.requestFocus();
          },
          buildLayerB: (sceneManager, _) => KeyboardListener(
            focusNode: layerBFocusNode,
            onKeyEvent: (event) {
              if (event.type == .character) {
                layerBKeys.add(event.key);
                return true;
              }
              return false;
            },
            child: Button(
              text: 'Open Modal',
              onPressed: () {
                dialogFuture = sceneManager.showDialog<String>(
                  width: 30,
                  height: 6,
                  builder: (ctx) => Focus(
                    autofocus: true,
                    onKeyEvent: (event) {
                      if (event.type == .enter) {
                        PromptScope.of(ctx)?.done('submitted');
                        return true;
                      }
                      return false;
                    },
                    child: const Text('Press Enter'),
                  ),
                );
              },
            ),
          ),
          body: (tester, sceneManager, layerA, layerB) async {
            expect(sceneManager.focusedLayer, same(layerB));

            tester.mouseDown(2, 3);
            tester.mouseUp(2, 3);
            await tester.pump();

            final dialogLayer = sceneManager.layers.last;
            expect(sceneManager.focusedLayer, same(dialogLayer));
            expect(layerBFocusCalls, equals(0));

            tester.sendKey(.enter);
            await tester.pump();

            expect(await dialogFuture, equals('submitted'));
            expect(sceneManager.layers, [layerA, layerB]);
            expect(sceneManager.focusedLayer, same(layerB));
            expect(layerBFocusCalls, equals(1));

            tester.sendString('k');
            await tester.pump();
            expect(layerBKeys, ['k']);
          },
        );
      },
    );

    test(
      'draggable layer whose press handler explicitly focuses itself still drags and fires onFocus',
      () {
        var layerBFocusCalls = 0;

        _runTwoLayerScene(
          layerBDraggable: true,
          onLayerBFocus: (_, _) => layerBFocusCalls++,
          buildLayerB: (sceneManager, getLayerB) => Button(
            text: 'Self Focus',
            onPressed: () {
              sceneManager.focusedLayer = getLayerB();
            },
          ),
          body: (tester, sceneManager, _, layerB) async {
            tester.mouseDown(2, 3);
            tester.mouseMove(7, 6);
            tester.mouseUp(7, 6);
            await tester.pump();

            expect(sceneManager.focusedLayer, same(layerB));
            expect(layerBFocusCalls, equals(1));
            expect(layerB.x, equals(5));
            expect(layerB.y, equals(5));
          },
        );
      },
    );

    test(
      'pointer capture inside background Slider is cancelled when press opens showDialog',
      () {
        var sliderValue = 0.0;
        var modalOpened = false;

        _runTwoLayerScene(
          layerBWidth: 11,
          buildLayerB: (sceneManager, _) => StatefulBuilder(
            builder: (_, setState) => SizedBox(
              width: 11,
              height: 1,
              child: Slider(
                value: sliderValue,
                min: 0.0,
                max: 1.0,
                onChanged: (next) {
                  setState(() => sliderValue = next);
                  if (!modalOpened) {
                    modalOpened = true;
                    unawaited(
                      sceneManager.showDialog<void>(
                        width: 24,
                        height: 5,
                        builder: (_) => const Text('Confirm change'),
                      ),
                    );
                  }
                },
              ),
            ),
          ),
          body: (tester, sceneManager, _, _) async {
            // Press slider at localX = 2 (20% of 11-cell track -> 0.2), which opens modal.
            tester.mouseDown(3, 3);
            await tester.pump();
            expect(sliderValue, closeTo(0.2, 0.01));
            expect(sceneManager.layers, hasLength(4));

            // Drag to the far right while modal is open; cancelled capture must ignore drag.
            tester.mouseMove(11, 3);
            tester.mouseUp(11, 3);
            await tester.pump();

            expect(sliderValue, closeTo(0.2, 0.01));

            tester.mouseDown(1, 1);
            tester.mouseUp(1, 1);
            await tester.pump();
          },
        );
      },
    );

    test(
      'showDialog opened synchronously inside SceneLayer.onFocus cancels drag and resize capture',
      () {
        _runTwoLayerScene(
          layerBDraggable: true,
          layerBResizable: true,
          layerBWidth: 14,
          layerBHeight: 5,
          onLayerBFocus: (sceneManager, _) {
            unawaited(
              sceneManager.showDialog<void>(
                width: 24,
                height: 5,
                builder: (_) => const Text('Focus Modal'),
              ),
            );
          },
          buildLayerB: (_, _) =>
              const SizedBox(width: 14, height: 5, child: Text('Panel')),
          body: (tester, sceneManager, _, layerB) async {
            // Press bottom-right resize corner of layerB: 0-indexed (13, 6) -> 1-indexed (14, 7).
            tester.mouseDown(14, 7);
            tester.mouseMove(24, 12);
            tester.mouseUp(24, 12);
            await tester.pump();

            expect(sceneManager.layers, hasLength(4));
            expect(sceneManager.focusedLayer, same(sceneManager.layers.last));
            expect(layerB.width, equals(14));
            expect(layerB.height, equals(5));
            expect(layerB.x, equals(0));
            expect(layerB.y, equals(2));

            tester.mouseDown(1, 1);
            tester.mouseUp(1, 1);
            await tester.pump();
          },
        );
      },
    );

    test(
      'press handler overriding focusedLayer to another layer or null is preserved without dragging',
      () {
        var clearFocus = false;

        _runTwoLayerScene(
          layerBDraggable: true,
          buildLayerB: (sceneManager, _) => Button(
            text: 'Toolbar',
            onPressed: () {
              sceneManager.focusedLayer = clearFocus
                  ? null
                  : sceneManager.layers.first;
            },
          ),
          body: (tester, sceneManager, layerA, layerB) async {
            // Keep focus on layerA when clicking floating toolbar layerB.
            tester.mouseDown(2, 3);
            tester.mouseMove(8, 7);
            tester.mouseUp(8, 7);
            await tester.pump();

            expect(sceneManager.focusedLayer, same(layerA));
            expect(layerB.x, equals(0));
            expect(layerB.y, equals(2));

            // Clear focus explicitly on press.
            clearFocus = true;
            tester.mouseDown(2, 3);
            tester.mouseUp(2, 3);
            await tester.pump();

            expect(sceneManager.focusedLayer, isNull);
          },
        );
      },
    );

    test(
      'handleMouseEvent does not resurrect or drag a layer removed synchronously inside onPress',
      () {
        var layerBFocused = false;

        _runTwoLayerScene(
          layerBDraggable: true,
          onLayerBFocus: (_, _) => layerBFocused = true,
          buildLayerB: (sceneManager, getLayerB) => Button(
            text: 'Close Self',
            onPressed: () {
              sceneManager.layers.remove(getLayerB());
            },
          ),
          body: (tester, sceneManager, layerA, layerB) async {
            tester.mouseDown(2, 3);
            tester.mouseMove(8, 8);
            tester.mouseUp(8, 8);
            await tester.pump();

            expect(sceneManager.layers, [layerA]);
            expect(sceneManager.focusedLayer, same(layerA));
            expect(layerBFocused, isFalse);
            expect(layerB.x, equals(0));
            expect(layerB.y, equals(2));
          },
        );
      },
    );
  });
}
