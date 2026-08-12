import 'dart:math';
import 'package:test/test.dart';
import 'package:termui/termui.dart';
import 'package:termui_recorder/termui_recorder.dart';
import 'package:termui_test/termui_test.dart';

class GradientBox extends Widget {
  final int width;
  final int height;
  final String char;
  final int startFg;
  final int endFg;
  final int startBg;
  final int endBg;

  const GradientBox({
    required this.width,
    required this.height,
    required this.char,
    required this.startFg,
    required this.endFg,
    required this.startBg,
    required this.endBg,
  });

  @override
  int getIntrinsicHeight(int width) => height;

  @override
  Element createElement() => GradientBoxElement(this);
}

class GradientBoxElement extends Element {
  GradientBoxElement(GradientBox super.widget);

  @override
  Size performLayout(BoxConstraints constraints) {
    final w = widget as GradientBox;
    print('Painting GradientBox ${w.char}...');
    return constraints.constrain(Size(w.width, w.height));
  }

  @override
  void performPaint(Buffer buffer, Offset offset) {
    final w = widget as GradientBox;

    for (int y = 0; y < w.height; y++) {
      for (int x = 0; x < w.width; x++) {
        double t = x / (w.width - 1);
        t = (t * 20).floor() / 20.0;

        int fgA = _lerp(w.startFg.a, w.endFg.a, t);
        int fgR = _lerp(w.startFg.r, w.endFg.r, t);
        int fgG = _lerp(w.startFg.g, w.endFg.g, t);
        int fgB = _lerp(w.startFg.b, w.endFg.b, t);
        int fg = (fgA << 24) | (fgR << 16) | (fgG << 8) | fgB;

        int bgA = _lerp(w.startBg.a, w.endBg.a, t);
        int bgR = _lerp(w.startBg.r, w.endBg.r, t);
        int bgG = _lerp(w.startBg.g, w.endBg.g, t);
        int bgB = _lerp(w.startBg.b, w.endBg.b, t);
        int bg = (bgA << 24) | (bgR << 16) | (bgG << 8) | bgB;

        buffer.setAttributes(
          offset.dx.toInt() + x,
          offset.dy.toInt() + y,
          char: w.char,
          fg: fg,
          bg: bg,
          modifiers: 0,
        );
      }
    }
  }

  int _lerp(int a, int b, double t) {
    return (a + (b - a) * t).round().clamp(0, 255);
  }
}

int makeColor(int a, int r, int g, int b) {
  return (a << 24) | (r << 16) | (g << 8) | b;
}

void main() {
  setUp(() {
    FocusManager.instance.setPrimaryFocus(null);
  });

  group('SceneManager Blending', () {
    test('Layers blend correctly using Compositor', () async {
      final tester = TerminalTester(size: const Point(50, 10));
      tester.run(() async {
        final sceneManager = SceneManager(
          tester.terminal,
          renderingMode: RenderingMode.alternateScreen,
        );

        final runner0 = PromptRunner<void>(
          terminal: tester.terminal,
          widget: GradientBox(
            width: 50,
            height: 10,
            char: ' ',
            startFg: makeColor(255, 0, 0, 0),
            endFg: makeColor(255, 0, 0, 0),
            startBg: makeColor(255, 0, 0, 0),
            endBg: makeColor(255, 0, 0, 0),
          ),
          alternateScreen: false,
          mode: ExecutionMode.managed,
          onFramePainted: (_) => sceneManager.render(),
        );

        final layer0 = SceneLayer(
          renderer: runner0,
          sizing: LayerSizing.fullscreen,
        );

        final runner1 = PromptRunner<void>(
          terminal: tester.terminal,
          widget: GradientBox(
            width: 50,
            height: 10,
            char: '+',
            startFg: makeColor(255, 255, 255, 0), // yellow
            endFg: makeColor(255, 255, 255, 0),
            startBg: makeColor(255, 0, 0, 255), // blue opaque
            endBg: makeColor(0, 0, 0, 255), // blue transparent
          ),
          alternateScreen: false,
          mode: ExecutionMode.managed,
          onFramePainted: (_) => sceneManager.render(),
        );

        final layer1 = SceneLayer(
          renderer: runner1,
          sizing: LayerSizing.fullscreen,
        );

        final runner2 = PromptRunner<void>(
          terminal: tester.terminal,
          widget: GradientBox(
            width: 40,
            height: 5,
            char: '-',
            startFg: makeColor(255, 255, 0, 0), // red opaque
            endFg: makeColor(0, 255, 0, 0), // red transparent
            startBg: makeColor(0, 0, 255, 0), // green transparent
            endBg: makeColor(255, 0, 255, 0), // green opaque
          ),
          alternateScreen: false,
          mode: ExecutionMode.managed,
          onFramePainted: (_) => sceneManager.render(),
        );

        final layer2 = SceneLayer(
          renderer: runner2,
          sizing: LayerSizing.intrinsic,
          x: 5,
          y: 2,
        );

        sceneManager.layers.add(layer0);
        sceneManager.layers.add(layer1);
        sceneManager.layers.add(layer2);

        try {
          await tester.runPrompt(runner0, () async {
            try {
              await tester.runPrompt(runner1, () async {
                try {
                  await tester.runPrompt(runner2, () async {
                    await tester.pump();
                    sceneManager.render();

                    expect(
                      tester.backend.buffer,
                      matchesAnsiGolden(
                        'test/goldens/scene_manager_blend_double.ansi',
                      ),
                    );

                    runner2.abort();
                  });
                } on PromptAbortedException catch (_) {
                } finally {
                  runner1.abort();
                }
              });
            } on PromptAbortedException catch (_) {
            } finally {
              runner0.abort();
            }
          });
        } on PromptAbortedException catch (_) {}
      });
    });
  });
}
