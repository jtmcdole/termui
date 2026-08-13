import 'package:test/test.dart';
import 'package:termui/termui.dart';
import 'package:termui_recorder/termui_recorder.dart';
import 'package:termui_test/termui_test.dart';
import 'dart:math';

final class ProgressiveGlitchEffect extends TerminalEffect {
  const ProgressiveGlitchEffect();

  @override
  void applyEffect(Buffer target, Rect bounds) {
    var shift = 1;
    // Glitch 5 lines at increasing rotations
    for (var y = 0; y < 5 && y < bounds.height; y++) {
      target.rotateRow(bounds, y, shift);
      shift++;
    }
  }
}

class MockRenderer implements SceneRenderer {
  @override
  final Buffer currentBuffer;

  MockRenderer(this.currentBuffer);

  @override
  bool get showsCursor => false;
  @override
  bool get wantsAlternateScreen => false;
  @override
  bool get wantsMouseTracking => false;
  @override
  Point<int>? get requestedCursorPosition => null;
  @override
  bool handleKeyEvent(KeyEvent event) => false;
  @override
  bool handleMouseEvent(MouseEvent event) => false;
  @override
  void resize(int width, int height) {}
  @override
  void dispose() {}
}

void main() {
  group('EffectWidget Golden Tests', () {
    test('Global vs Local Compositing with Dimmer and Glitch', () {
      final backend = MockTerminalBackend(size: const Point(20, 10));
      final terminal = Terminal(backend);
      final sceneManager = SceneManager(terminal);

      final content = Column([
        EffectWidget(
          globalComposite: true,
          effect: const DimmerEffect(scalar: 0.5),
          child: SizedBox(
            width: 20,
            height: 5,
            child: DecoratedBox(
              decoration: const BoxDecoration(
                backgroundColor: Color(
                  255,
                  255,
                  255,
                ), // Bright white background
              ),
              child: Text(
                '01234567890123456789',
                style: const Style(foreground: Color(0, 0, 0)),
              ),
            ),
          ),
        ),
        EffectWidget(
          globalComposite: false, // Apply locally to test the local toggle
          effect: const ProgressiveGlitchEffect(),
          child: SizedBox(
            width: 20,
            height: 5,
            child: DecoratedBox(
              decoration: const BoxDecoration(
                backgroundColor: Color(255, 255, 255),
              ),
              child: Text(
                'ABCDEFGHIJKLMNOPQRST',
                style: const Style(foreground: Color(0, 0, 0)),
              ),
            ),
          ),
        ),
      ]);

      final contentElement = ElementWidget(content)
        ..layout(BoxConstraints.tight(const Size(20, 10)));

      final layerBuffer = Buffer(20, 10);
      contentElement.paint(layerBuffer, Offset.zero);

      final appRunner = MockRenderer(layerBuffer);

      final appLayer = SceneLayer(
        renderer: appRunner,
        sizing: LayerSizing.fullscreen,
        zIndex: 0,
      );

      sceneManager.layers.add(appLayer);
      sceneManager.render(); // Composites into terminal.buffer

      expect(
        backend.buffer,
        matchesAnsiGolden('test/goldens/effect_pipeline_global_local.ansi'),
      );
    });

    test('Multiple Z-Indexed Effect Layers Compositing', () {
      final backend = MockTerminalBackend(size: const Point(20, 10));
      final terminal = Terminal(backend);
      final sceneManager = SceneManager(terminal);

      // Layer 0: Base content (Blue background)
      final layer0Buffer = Buffer(20, 10);
      final layer0Content = DecoratedBox(
        decoration: const BoxDecoration(backgroundColor: Color(0, 0, 255)),
        child: SizedBox(
          width: 20,
          height: 10,
          child: Text(
            'BASE',
            style: const Style(foreground: Color(255, 255, 255)),
          ),
        ),
      );
      ElementWidget(layer0Content)
        ..layout(BoxConstraints.tight(const Size(20, 10)))
        ..paint(layer0Buffer, Offset.zero);

      // Layer 1: Dimmer Effect over Layer 0 (Dims everything beneath)
      final layer1Buffer = Buffer(20, 10);
      final layer1Content = EffectWidget(
        globalComposite: true,
        effect: const DimmerEffect(
          scalar: 0.5,
        ), // Should turn 0,0,255 into 0,0,127
        child: SizedBox(
          width: 10,
          height: 5,
          child: DecoratedBox(
            decoration: const BoxDecoration(backgroundColor: Color(255, 0, 0)),
            child: Text(
              'RED',
              style: const Style(foreground: Color(255, 255, 255)),
            ),
          ),
        ),
      );
      ElementWidget(layer1Content)
        ..layout(BoxConstraints.tight(const Size(10, 5)))
        ..paint(layer1Buffer, Offset.zero); // Drawn at top-left

      // Layer 2: Glitch Effect over Layer 1 and 0
      final layer2Buffer = Buffer(20, 10);
      final layer2Content = EffectWidget(
        globalComposite: true,
        effect: const ProgressiveGlitchEffect(),
        child: Padding(
          padding: const EdgeInsets.only(left: 5, top: 2),
          child: SizedBox(
            width: 10,
            height: 5,
            child: DecoratedBox(
              decoration: const BoxDecoration(
                backgroundColor: Color(0, 255, 0),
              ),
              child: Text(
                'GREEN',
                style: const Style(foreground: Color(255, 255, 255)),
              ),
            ),
          ),
        ),
      );
      ElementWidget(layer2Content)
        ..layout(BoxConstraints.tight(const Size(20, 10)))
        ..paint(layer2Buffer, Offset.zero);

      // Layer 3: Opaque top layer with transparent background
      final layer3Buffer = Buffer(20, 10);
      final layer3Content = Padding(
        padding: const EdgeInsets.only(left: 2, top: 4),
        child: Text(
          'TOP',
          style: const Style(foreground: Color(255, 255, 0)),
        ), // Yellow text, transparent bg
      );
      ElementWidget(layer3Content)
        ..layout(BoxConstraints.tight(const Size(20, 10)))
        ..paint(layer3Buffer, Offset.zero);

      sceneManager.layers.add(
        SceneLayer(
          renderer: MockRenderer(layer0Buffer),
          sizing: LayerSizing.fullscreen,
          zIndex: 0,
        ),
      );
      sceneManager.layers.add(
        SceneLayer(
          renderer: MockRenderer(layer1Buffer),
          sizing: LayerSizing.fullscreen,
          zIndex: 1,
        ),
      );
      sceneManager.layers.add(
        SceneLayer(
          renderer: MockRenderer(layer2Buffer),
          sizing: LayerSizing.fullscreen,
          zIndex: 2,
        ),
      );
      sceneManager.layers.add(
        SceneLayer(
          renderer: MockRenderer(layer3Buffer),
          sizing: LayerSizing.fullscreen,
          zIndex: 3,
        ),
      );

      sceneManager.render();

      expect(
        backend.buffer,
        matchesAnsiGolden('test/goldens/multiple_effect_layers.ansi'),
      );
    });

    test('Helper functions fill background and foreground', () {
      final buffer = Buffer(10, 5);

      for (var y = 0; y < 5; y++) {
        buffer.writeString(
          0,
          y,
          'XXXXXXXXXX',
          Style(foreground: Color(255, 0, 0)),
        );
      }

      // Fill background
      buffer.fillBackgroundStyle(
        const Rect(0, 0, 10, 2),
        const Style(background: Color(0, 255, 0)),
        BlendOption.colorOnly,
      );

      // Fill foreground
      buffer.fillForegroundStyle(
        const Rect(0, 2, 10, 3),
        const Style(foreground: Color(0, 0, 255)),
        BlendOption.replace,
      );

      expect(
        buffer,
        matchesAnsiGolden('test/goldens/effect_helpers_fill.ansi'),
      );
    });
  });
}
