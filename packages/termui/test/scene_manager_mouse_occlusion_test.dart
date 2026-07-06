import 'dart:math';
import 'package:test/test.dart';
import 'package:termui/termui.dart';
import 'package:termui/terminal/terminal.dart' as term;
import 'package:termui_test/termui_test.dart';

class TestButton extends Widget {
  final FocusNode? focusNode;
  final void Function() onPressed;
  final void Function()? onHover;

  const TestButton({
    super.key,
    this.focusNode,
    required this.onPressed,
    this.onHover,
  });

  @override
  Element createElement() => _TestButtonElement(this);
}

class _TestButtonElement extends Element implements MouseEventHandler {
  _TestButtonElement(TestButton super.widget);

  @override
  Size performLayout(BoxConstraints constraints) {
    return constraints.constrain(Size(10, 5));
  }

  @override
  void performPaint(Buffer buffer, Offset offset) {
    // Fill the button with red to make it opaque
    for (int y = 0; y < size.height; y++) {
      buffer.writeString(
        offset.dx,
        offset.dy + y,
        ' ' * size.width,
        const Style(background: Color(255, 0, 0)),
      );
    }
  }

  @override
  void handleMouseEvent(MouseEvent event, int localX, int localY) {
    if (event.type == MouseEventType.press) {
      (widget as TestButton).onPressed();
    } else if (event.type == MouseEventType.move) {
      (widget as TestButton).onHover?.call();
    }
  }
}

class VisualOccluder extends Widget {
  final bool transparent;

  const VisualOccluder({super.key, this.transparent = false});

  @override
  Element createElement() => _VisualOccluderElement(this);
}

class _VisualOccluderElement extends Element {
  _VisualOccluderElement(VisualOccluder super.widget);

  @override
  Size performLayout(BoxConstraints constraints) {
    return constraints.constrain(Size(10, 5));
  }

  @override
  void performPaint(Buffer buffer, Offset offset) {
    final w = widget as VisualOccluder;
    final style = w.transparent
        ? Style.transparent
        : const Style(background: Color(0, 255, 0));
    for (int y = 0; y < size.height; y++) {
      buffer.writeString(offset.dx, offset.dy + y, ' ' * size.width, style);
    }
  }
}

void main() {
  setUp(() {
    FocusManager.instance.setPrimaryFocus(null);
  });

  group('SceneManager Mouse Occlusion Tests', () {
    test(
      'Hover is occluded by opaque pixels regardless of mouseOpaque flag',
      () {
        final tester = TerminalTester(size: const Point(80, 24));
        tester.run(() async {
          final sceneManager = SceneManager(
            tester.terminal,
            renderingMode: RenderingMode.alternateScreen,
          );

          bool buttonHovered = false;

          final bottomRunner = PromptRunner(
            terminal: tester.terminal,
            widget: TestButton(
              onPressed: () {},
              onHover: () => buttonHovered = true,
            ),
            mode: ExecutionMode.managed,
          );
          final bottomLayer = SceneLayer(
            renderer: bottomRunner,
            sizing: LayerSizing.fixed,
            width: 10,
            height: 5,
            zIndex: 1,
          );

          final topRunner = PromptRunner(
            terminal: tester.terminal,
            widget: const VisualOccluder(transparent: false),
            mode: ExecutionMode.managed,
          );
          final topLayer = SceneLayer(
            renderer: topRunner,
            sizing: LayerSizing.fixed,
            width: 10,
            height: 5,
            zIndex: 2,
            mouseOpaque:
                false, // Does not trap clicks, but still visually occludes
          );

          sceneManager.layers.add(bottomLayer);
          sceneManager.layers.add(topLayer);

          bottomRunner.run().catchError((_) {});
          topRunner.run().catchError((_) {});
          await tester.pump();
          sceneManager.render();

          // Send a hover event
          sceneManager.handleMouseEvent(
            term.MouseEvent(
              x: 5,
              y: 2,
              button: term.MouseButton.none,
              type: term.MouseEventType.move,
            ),
          );

          // Since topLayer is visually opaque, the hover event is blocked.
          expect(buttonHovered, isFalse);
        });
      },
    );

    test(
      'Clicks are swallowed by visually opaque layers if mouseOpaque is false, but focus is not captured',
      () {
        final tester = TerminalTester(size: const Point(80, 24));
        tester.run(() async {
          final sceneManager = SceneManager(
            tester.terminal,
            renderingMode: RenderingMode.alternateScreen,
          );

          bool buttonClicked = false;

          final bottomRunner = PromptRunner(
            terminal: tester.terminal,
            widget: TestButton(onPressed: () => buttonClicked = true),
            mode: ExecutionMode.managed,
          );
          final bottomLayer = SceneLayer(
            renderer: bottomRunner,
            sizing: LayerSizing.fixed,
            width: 10,
            height: 5,
            zIndex: 1,
          );

          final topRunner = PromptRunner(
            terminal: tester.terminal,
            widget: const VisualOccluder(transparent: false),
            mode: ExecutionMode.managed,
          );
          final topLayer = SceneLayer(
            renderer: topRunner,
            sizing: LayerSizing.fixed,
            width: 10,
            height: 5,
            zIndex: 2,
            mouseOpaque: false, // Allows clicks to bleed through
          );

          sceneManager.layers.add(bottomLayer);
          sceneManager.layers.add(topLayer);

          bottomRunner.run().catchError((_) {});
          topRunner.run().catchError((_) {});
          await tester.pump();
          sceneManager.render();

          // Send a click event
          sceneManager.handleMouseEvent(
            term.MouseEvent(
              x: 5,
              y: 2,
              button: term.MouseButton.left,
              type: term.MouseEventType.press,
            ),
          );

          // Since mouseOpaque is false on topLayer, click is swallowed (doesn't bleed through) but focus is not stolen
          expect(buttonClicked, isFalse);
          expect(
            sceneManager.focusedLayer,
            isNull,
          ); // Focus isn't stolen by topLayer
        });
      },
    );

    test(
      'Clicks are trapped by visually opaque layers if mouseOpaque is true',
      () {
        final tester = TerminalTester(size: const Point(80, 24));
        tester.run(() async {
          final sceneManager = SceneManager(
            tester.terminal,
            renderingMode: RenderingMode.alternateScreen,
          );

          bool buttonClicked = false;

          final bottomRunner = PromptRunner(
            terminal: tester.terminal,
            widget: TestButton(onPressed: () => buttonClicked = true),
            mode: ExecutionMode.managed,
          );
          final bottomLayer = SceneLayer(
            renderer: bottomRunner,
            sizing: LayerSizing.fixed,
            width: 10,
            height: 5,
            zIndex: 1,
          );

          final topRunner = PromptRunner(
            terminal: tester.terminal,
            widget: const VisualOccluder(transparent: false),
            mode: ExecutionMode.managed,
          );
          final topLayer = SceneLayer(
            renderer: topRunner,
            sizing: LayerSizing.fixed,
            width: 10,
            height: 5,
            zIndex: 2,
            mouseOpaque: true, // Traps clicks!
          );

          sceneManager.layers.add(bottomLayer);
          sceneManager.layers.add(topLayer);

          bottomRunner.run().catchError((_) {});
          topRunner.run().catchError((_) {});
          await tester.pump();
          sceneManager.render();

          // Send a click event
          sceneManager.handleMouseEvent(
            term.MouseEvent(
              x: 5,
              y: 2,
              button: term.MouseButton.left,
              type: term.MouseEventType.press,
            ),
          );

          // Click is trapped by topLayer
          expect(buttonClicked, isFalse);
          expect(sceneManager.focusedLayer, equals(topLayer));
        });
      },
    );

    test(
      'Hover passes through transparent cells of a higher z-order layer',
      () {
        final tester = TerminalTester(size: const Point(80, 24));
        tester.run(() async {
          final sceneManager = SceneManager(
            tester.terminal,
            renderingMode: RenderingMode.alternateScreen,
          );

          bool buttonHovered = false;

          final bottomRunner = PromptRunner(
            terminal: tester.terminal,
            widget: TestButton(
              onPressed: () {},
              onHover: () => buttonHovered = true,
            ),
            mode: ExecutionMode.managed,
          );
          final bottomLayer = SceneLayer(
            renderer: bottomRunner,
            sizing: LayerSizing.fixed,
            width: 10,
            height: 5,
            zIndex: 1,
          );

          final topRunner = PromptRunner(
            terminal: tester.terminal,
            widget: const VisualOccluder(transparent: true),
            mode: ExecutionMode.managed,
          );
          final topLayer = SceneLayer(
            renderer: topRunner,
            sizing: LayerSizing.fixed,
            width: 10,
            height: 5,
            zIndex: 2,
            mouseOpaque:
                true, // Should not matter, transparent cell overrides this
          );

          sceneManager.layers.add(bottomLayer);
          sceneManager.layers.add(topLayer);

          bottomRunner.run().catchError((_) {});
          topRunner.run().catchError((_) {});
          await tester.pump();
          sceneManager.render();

          // Send a hover event
          sceneManager.handleMouseEvent(
            term.MouseEvent(
              x: 5,
              y: 2,
              button: term.MouseButton.none,
              type: term.MouseEventType.move,
            ),
          );

          // Since topLayer is transparent at (5, 2), hover event bleeds through
          expect(buttonHovered, isTrue);
        });
      },
    );

    test('Clicks pass through transparent cells of a higher z-order layer', () {
      final tester = TerminalTester(size: const Point(80, 24));
      tester.run(() async {
        final sceneManager = SceneManager(
          tester.terminal,
          renderingMode: RenderingMode.alternateScreen,
        );

        bool buttonClicked = false;

        final bottomRunner = PromptRunner(
          terminal: tester.terminal,
          widget: TestButton(onPressed: () => buttonClicked = true),
          mode: ExecutionMode.managed,
        );
        final bottomLayer = SceneLayer(
          renderer: bottomRunner,
          sizing: LayerSizing.fixed,
          width: 10,
          height: 5,
          zIndex: 1,
        );

        final topRunner = PromptRunner(
          terminal: tester.terminal,
          widget: const VisualOccluder(transparent: true),
          mode: ExecutionMode.managed,
        );
        final topLayer = SceneLayer(
          renderer: topRunner,
          sizing: LayerSizing.fixed,
          width: 10,
          height: 5,
          zIndex: 2,
          mouseOpaque:
              true, // Should not matter, transparent cell overrides this
        );

        sceneManager.layers.add(bottomLayer);
        sceneManager.layers.add(topLayer);

        bottomRunner.run().catchError((_) {});
        topRunner.run().catchError((_) {});
        await tester.pump();
        sceneManager.render();

        // Send a click event
        sceneManager.handleMouseEvent(
          term.MouseEvent(
            x: 5,
            y: 2,
            button: term.MouseButton.left,
            type: term.MouseEventType.press,
          ),
        );

        // Since topLayer is transparent at (5, 2), click event bleeds through
        expect(buttonClicked, isTrue);
        expect(sceneManager.focusedLayer, equals(bottomLayer));
      });
    });
  });
}
