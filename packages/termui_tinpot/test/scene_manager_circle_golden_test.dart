import 'dart:math' as math;
import 'package:characters/characters.dart';
import 'package:image/image.dart' as img;
import 'package:termui/termui.dart';
import 'package:termui_recorder/termui_recorder.dart';
import 'package:termui_test/termui_test.dart';
import 'package:termui_tinpot/src/termui_tinpot.dart';
import 'package:test/test.dart';

/// Background widget rendering a distinct checkerboard pattern and centered text.
class CheckerboardBackground extends Widget {
  final int width;
  final int height;

  const CheckerboardBackground({
    super.key,
    required this.width,
    required this.height,
  });

  @override
  Element createElement() => CheckerboardBackgroundElement(this);
}

class CheckerboardBackgroundElement extends Element {
  CheckerboardBackgroundElement(CheckerboardBackground super.widget);

  @override
  Size performLayout(BoxConstraints constraints) {
    final w = widget as CheckerboardBackground;
    return constraints.constrain(Size(w.width, w.height));
  }

  @override
  void performPaint(Buffer buffer, Offset offset) {
    final w = widget as CheckerboardBackground;
    final ox = offset.dx.toInt();
    final oy = offset.dy.toInt();

    const style1 = Style(
      foreground: Color(255, 215, 0), // Gold
      background: Color(40, 40, 40), // Dark Grey
    );
    const style2 = Style(
      foreground: Color(255, 165, 0), // Orange
      background: Color(20, 20, 20), // Darker Grey
    );

    for (int y = 0; y < w.height; y++) {
      for (int x = 0; x < w.width; x++) {
        final useStyle1 = ((x + y) % 2 == 0);
        buffer.writeString(
          ox + x,
          oy + y,
          useStyle1 ? '░' : '▒',
          useStyle1 ? style1 : style2,
        );
      }
    }

    // Centered label visible through the transparent circle
    const label = 'BACKGROUND';
    final labelLen = label.characters.length;
    final labelX = ox + (w.width - labelLen) ~/ 2;
    final labelY = oy + w.height ~/ 2;

    buffer.writeString(
      labelX,
      labelY,
      label,
      const Style(
        foreground: Color(255, 255, 255),
        background: Color(0, 0, 0),
        modifiers: Modifier.bold,
      ),
    );
  }
}

/// Creates a solid fill image with a feathered transparent circle at the center.
img.Image createFeatheredCircleImage({
  required int width,
  required int height,
  required double innerRadius,
  required double outerRadius,
  required int fillR,
  required int fillG,
  required int fillB,
}) {
  final image = img.Image(width: width, height: height, numChannels: 4);
  final cx = width / 2.0;
  final cy = height / 2.0;

  for (int y = 0; y < height; y++) {
    for (int x = 0; x < width; x++) {
      // Scale Y by 2.0 to account for terminal character aspect ratio (~1:2)
      final dx = x - cx;
      final dy = (y - cy) * 2.0;
      final dist = math.sqrt(dx * dx + dy * dy);

      if (dist <= innerRadius) {
        // Fully transparent center
        image.setPixelRgba(x, y, 0, 0, 0, 0);
      } else if (dist >= outerRadius) {
        // Fully opaque fill
        image.setPixelRgba(x, y, fillR, fillG, fillB, 255);
      } else {
        // Feathered transition
        final t = (dist - innerRadius) / (outerRadius - innerRadius);
        final alpha = (t * 255).round().clamp(0, 255);
        image.setPixelRgba(x, y, fillR, fillG, fillB, alpha);
      }
    }
  }

  return image;
}

void main() {
  setUp(() {
    FocusManager.instance.setPrimaryFocus(null);
  });

  group('SceneManager Feathered Circle Blending Golden Test', () {
    test('background only', () async {
      const cols = 40;
      const rows = 15;
      final tester = TerminalTester(size: const math.Point(cols, rows));

      tester.run(() async {
        final sceneManager = SceneManager(
          tester.terminal,
          renderingMode: RenderingMode.alternateScreen,
        );

        // Layer 0: Background checkerboard pattern with text
        final bgRunner = PromptRunner<void>(
          terminal: tester.terminal,
          widget: const CheckerboardBackground(width: cols, height: rows),
          alternateScreen: false,
          mode: ExecutionMode.managed,
          onFramePainted: (_) => sceneManager.render(),
        );

        final bgLayer = SceneLayer(
          renderer: bgRunner,
          sizing: LayerSizing.fullscreen,
        );

        sceneManager.layers.add(bgLayer);

        try {
          await tester.runPrompt(bgRunner, () async {
            try {
              await tester.pump();
              sceneManager.render();
              final compositedBuffer = tester.backend.buffer!;

              expect(
                compositedBuffer,
                matchesAnsiGolden(
                  'test/goldens/scene_manager_tinpot_background.ansi',
                ),
              );
            } finally {
              bgRunner.abort();
            }
          });
        } on PromptAbortedException catch (_) {}
      });
    });

    test(
      'renders fill and reveals background through transparent circle in SceneManager',
      () async {
        const cols = 40;
        const rows = 15;
        final tester = TerminalTester(size: const math.Point(cols, rows));

        tester.run(() async {
          final sceneManager = SceneManager(
            tester.terminal,
            renderingMode: RenderingMode.alternateScreen,
          );

          // Layer 0: Background checkerboard pattern with text
          final bgRunner = PromptRunner<void>(
            terminal: tester.terminal,
            widget: const CheckerboardBackground(width: cols, height: rows),
            alternateScreen: false,
            mode: ExecutionMode.managed,
            onFramePainted: (_) => sceneManager.render(),
          );

          final bgLayer = SceneLayer(
            renderer: bgRunner,
            sizing: LayerSizing.fullscreen,
          );

          // Layer 1: Image converted by TermuiTinpot with fill + feathered transparent circle
          final circleImage = createFeatheredCircleImage(
            width: cols * 8,
            height: rows * 8,
            innerRadius: 36.0,
            outerRadius: 68.0,
            fillR: 30,
            fillG: 144,
            fillB: 255, // Dodger Blue
          );

          final tinpot = TermuiTinpot(workFactor: 5);
          final tinpotBuffer = tinpot.convertBuffer(circleImage, cols, rows);

          final tinpotRunner = PromptRunner<void>(
            terminal: tester.terminal,
            widget: BufferWidget(buffer: tinpotBuffer),
            alternateScreen: false,
            mode: ExecutionMode.managed,
            onFramePainted: (_) => sceneManager.render(),
          );

          final tinpotLayer = SceneLayer(
            renderer: tinpotRunner,
            sizing: LayerSizing.fullscreen,
          );

          sceneManager.layers.add(bgLayer);
          sceneManager.layers.add(tinpotLayer);

          try {
            await tester.runPrompt(bgRunner, () async {
              try {
                await tester.runPrompt(tinpotRunner, () async {
                  try {
                    await tester.pump();
                    sceneManager.render();

                    final compositedBuffer = tester.backend.buffer!;

                    // 1. Structural assertions on SceneManager composite output:
                    // Corner cell (0, 0) is far outside the circle (opaque blue fill in tinpot).
                    // It MUST NOT show the background layer's dark grey (0xFF282828).
                    // Instead it must be rendered from the tinpot layer.
                    expect(
                      compositedBuffer.getBackground(0, 0),
                      isNot(equals(0xFF282828)),
                      reason:
                          'Compositor must not skip non-transparent tinpot fill cells',
                    );

                    // Center cell (20, 7) is inside the transparent circle.
                    // It MUST show the background layer ("BACKGROUND" label in black background).
                    expect(
                      compositedBuffer.getBackground(20, 7),
                      equals(0xFF000000),
                      reason:
                          'Center of transparent circle must reveal the background layer',
                    );

                    // 2. Visual golden verification:
                    expect(
                      compositedBuffer,
                      matchesAnsiGolden(
                        'test/goldens/scene_manager_tinpot_feathered_circle.ansi',
                      ),
                    );
                  } finally {
                    tinpotRunner.abort();
                  }
                });
              } on PromptAbortedException catch (_) {
              } finally {
                bgRunner.abort();
              }
            });
          } on PromptAbortedException catch (_) {}
        });
      },
    );
  });
}
