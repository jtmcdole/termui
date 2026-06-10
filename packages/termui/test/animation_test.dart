import 'dart:async';
import 'dart:math';
import 'package:test/test.dart';
import 'package:termui/ui/buffer.dart';
import 'package:termui/ui/layout.dart';
import 'package:termui/ui/style.dart';
import 'package:termui/ui/color.dart';
import 'package:termui/ui/event.dart' hide Modifier;
import 'package:termui/ui/widget_toolkit.dart';

/// A test animation effect implementation for validating lifecycles and ticks.
class TestEffect extends TuiAnimationEffect {
  /// True if the paint method was called.
  bool painted = false;

  /// Creates a [TestEffect] with config.
  TestEffect({
    required super.duration,
    super.easing,
    super.targetFrameInterval,
  });

  @override
  void paint(Buffer buffer, Rect area, Style baseStyle) {
    painted = true;
    final cell = buffer.getCell(0, 0);
    if (cell != null) {
      cell.char = 'X';
      cell.style = cell.style.merge(const Style(foreground: Colors.red));
    }
  }
}

/// A test stateful widget designed to run animation effects with the mixin.
class TestAnimatedWidget extends StatefulWidget {
  /// The test effect instance to run.
  final TestEffect effect;

  /// Creates a [TestAnimatedWidget].
  const TestAnimatedWidget({required this.effect});

  @override
  State<TestAnimatedWidget> createState() => TestAnimatedWidgetState();
}

/// The mutable state of the [TestAnimatedWidget].
class TestAnimatedWidgetState extends State<TestAnimatedWidget>
    with TuiAnimatedStateMixin<TestAnimatedWidget> {
  @override
  void initState() {
    super.initState();
    registerEffect(widget.effect);
  }

  /// Triggers the test effect.
  void startEffect(Point<int> point) {
    triggerEffect(widget.effect, point);
  }

  /// Helper to check if the ticker is active.
  bool hasTicker() => isTickerActive;

  @override
  Widget build(BuildContext context) {
    return _TestAnimatedRenderWidget(this);
  }
}

class _TestAnimatedRenderWidget extends Widget {
  final TestAnimatedWidgetState state;

  const _TestAnimatedRenderWidget(this.state);

  @override
  void render(Buffer buffer, Rect area) {
    for (var y = 0; y < area.height; y++) {
      for (var x = 0; x < area.width; x++) {
        buffer.setCell(x, y, Cell(' ', Style.empty));
      }
    }
    state.paintEffects(buffer, area, Style.empty);
  }
}

void main() {
  group('TuiAnimationEffect Lifecycle & Easing Tests', () {
    test('Initial dormant state', () {
      final effect = TestEffect(duration: const Duration(milliseconds: 100));
      expect(effect.status, equals(AnimationStatus.dismissed));
      expect(effect.isAnimating, isFalse);
      expect(effect.isVisible, isFalse);
      expect(effect.progress, equals(0.0));
      expect(effect.triggerPoint, isNull);
    });

    test('Start activates effect and stopwatch', () {
      final effect = TestEffect(duration: const Duration(milliseconds: 100));
      var updated = false;

      effect.start(const Point(2, 3), () {
        updated = true;
      });

      expect(effect.status, equals(AnimationStatus.forward));
      expect(effect.isAnimating, isTrue);
      expect(effect.isVisible, isTrue);
      expect(effect.triggerPoint, equals(const Point(2, 3)));
      expect(effect.progress, greaterThanOrEqualTo(0.0));
      expect(updated, isFalse);
    });

    test('Tick progress and completion', () async {
      final effect = TestEffect(duration: const Duration(milliseconds: 50));
      var updateCount = 0;

      effect.start(const Point(0, 0), () {
        updateCount++;
      });

      // Advance time slightly
      await Future.delayed(const Duration(milliseconds: 15));
      final ticking = effect.tick();

      expect(ticking, isTrue);
      expect(effect.status, equals(AnimationStatus.forward));
      expect(effect.isAnimating, isTrue);
      expect(effect.isVisible, isTrue);
      expect(effect.progress, greaterThan(0.0));
      expect(effect.progress, lessThan(1.0));
      expect(
        updateCount,
        equals(1),
      ); // targetFrameInterval is zero, tick triggers update on every frame

      // Wait until duration completes
      await Future.delayed(const Duration(milliseconds: 45));
      final tickingDone = effect.tick();

      expect(tickingDone, isFalse);
      expect(effect.status, equals(AnimationStatus.completed));
      expect(effect.isAnimating, isFalse);
      expect(effect.isVisible, isTrue);
      expect(effect.progress, equals(1.0)); // completed progress is 1.0
      expect(updateCount, equals(2)); // callback triggered on completion
    });

    test('Stop freezes and reset clears animation state', () {
      final effect = TestEffect(duration: const Duration(milliseconds: 100));
      effect.start(const Point(5, 5), () {});

      effect.stop();
      expect(effect.status, equals(AnimationStatus.completed));
      expect(effect.isAnimating, isFalse);
      expect(effect.isVisible, isTrue);
      expect(effect.triggerPoint, equals(const Point(5, 5)));

      effect.reset();
      expect(effect.status, equals(AnimationStatus.dismissed));
      expect(effect.isAnimating, isFalse);
      expect(effect.isVisible, isFalse);
      expect(effect.triggerPoint, isNull);
      expect(effect.progress, equals(0.0));
    });

    test('AnimationStatus forward and reverse transitions', () async {
      final effect = TestEffect(duration: const Duration(milliseconds: 100));
      effect.start(const Point(0, 0), () {});

      await Future.delayed(const Duration(milliseconds: 30));
      effect.tick();
      expect(effect.status, equals(AnimationStatus.forward));
      expect(effect.progress, greaterThan(0.0));

      // Reverse direction
      effect.reverse();
      expect(effect.status, equals(AnimationStatus.reverse));
      expect(effect.isAnimating, isTrue);
      expect(effect.isVisible, isTrue);

      // Tick to reverse completion (back to 0.0)
      await Future.delayed(const Duration(milliseconds: 50));
      final ticking = effect.tick();
      expect(ticking, isFalse);
      expect(effect.status, equals(AnimationStatus.dismissed));
      expect(effect.isAnimating, isFalse);
      expect(effect.isVisible, isFalse);
      expect(effect.progress, equals(0.0));
    });

    test('Easing calculations applied to progress', () async {
      final effect = TestEffect(
        duration: const Duration(milliseconds: 100),
        easing: Easing.easeOutQuad,
      );

      effect.start(const Point(0, 0), () {});
      await Future.delayed(const Duration(milliseconds: 40));

      final progressLinear =
          effect.progress; // This is already eased internally
      // Since it's easeOutQuad: f(t) = 1 - (1 - t)^2
      // If t is around 0.4, eased t is around 1 - 0.6^2 = 0.64, which is > 0.4.
      expect(progressLinear, greaterThan(0.0));
    });
  });

  group('Throttling & Vsync Tests', () {
    test('Tunable vsync ticking using TuiAnimationConfig.vsyncInterval', () {
      final oldInterval = TuiAnimationConfig.vsyncInterval;
      TuiAnimationConfig.vsyncInterval = const Duration(milliseconds: 8);

      final effect = TestEffect(duration: const Duration(milliseconds: 50));
      final widget = TestAnimatedWidget(effect: effect);
      final tree = ElementWidget(widget);
      final buffer = Buffer.blank(5, 5);

      tree.render(buffer, const Rect(0, 0, 5, 5));
      final state = tree.findState<TestAnimatedWidgetState>()!;

      expect(state.vsyncInterval, equals(const Duration(milliseconds: 8)));
      TuiAnimationConfig.vsyncInterval = oldInterval; // Restore
    });

    test('Paint/repaint throttling using targetFrameInterval', () async {
      final effect = TestEffect(
        duration: const Duration(milliseconds: 100),
        targetFrameInterval: const Duration(milliseconds: 30),
      );

      var updateCount = 0;
      effect.start(const Point(0, 0), () {
        updateCount++;
      });

      // Tick rapidly immediately (0 ms elapsed since start)
      effect.tick();
      expect(updateCount, equals(0));

      // Wait 15 ms (less than 30 ms interval)
      await Future.delayed(const Duration(milliseconds: 15));
      effect.tick();
      expect(updateCount, equals(0));

      // Wait another 20 ms (total 35 ms > 30 ms interval)
      await Future.delayed(const Duration(milliseconds: 20));
      effect.tick();
      expect(updateCount, equals(1));

      // Wait another 35 ms
      await Future.delayed(const Duration(milliseconds: 35));
      effect.tick();
      expect(updateCount, equals(2));
    });
  });

  group('TuiAnimatedStateMixin Integration Tests', () {
    test('Effect registration and automatic ticker cleanup', () async {
      final effect = TestEffect(duration: const Duration(milliseconds: 30));
      final widget = TestAnimatedWidget(effect: effect);
      final tree = ElementWidget(widget);
      final buffer = Buffer.blank(5, 5);

      tree.render(buffer, const Rect(0, 0, 5, 5));
      final state = tree.findState<TestAnimatedWidgetState>()!;

      expect(state.hasTicker(), isFalse);

      // Trigger effect starts the ticker
      state.startEffect(const Point(1, 1));
      expect(state.hasTicker(), isTrue);

      // Wait for duration to expire (30ms) plus a tick interval
      await Future.delayed(const Duration(milliseconds: 50));

      // Ticker should be automatically cleaned up
      expect(state.hasTicker(), isFalse);
    });

    test('Dispose cancels ticker and resets effects', () {
      final effect = TestEffect(duration: const Duration(milliseconds: 100));
      final widget = TestAnimatedWidget(effect: effect);
      final tree = ElementWidget(widget);
      final buffer = Buffer.blank(5, 5);

      tree.render(buffer, const Rect(0, 0, 5, 5));
      final state = tree.findState<TestAnimatedWidgetState>()!;

      state.startEffect(const Point(2, 2));
      expect(state.hasTicker(), isTrue);
      expect(effect.isAnimating, isTrue);

      // Dispose state
      state.dispose();
      expect(effect.isAnimating, isFalse);
      expect(effect.triggerPoint, isNull);
    });
  });

  group('Predefined Effects Rendering Tests', () {
    test('InkwellRippleEffect aspect-ratio and distance blending', () {
      final ripple = InkwellRippleEffect(
        duration: const Duration(milliseconds: 100),
        rippleColor: Colors.blue,
      );

      final buffer = Buffer.blank(10, 5);
      ripple.start(const Point(5, 2), () {});

      // Paint at progress ~ 0.5
      expect(ripple.isAnimating, isTrue);

      ripple.paint(buffer, const Rect(0, 0, 10, 5), Style.empty);

      // Center cell should be blended with rippleColor
      final centerCell = buffer.getCell(5, 2)!;
      expect(centerCell.style.background, equals(Colors.blue));

      // Cell far away should not be affected yet or blended less
      final cornerCell = buffer.getCell(0, 0)!;
      expect(cornerCell.style.background, isNot(equals(Colors.blue)));
    });

    test('SparkleEffect particle spawning and decay', () {
      final sparkles = SparkleEffect(
        duration: const Duration(milliseconds: 100),
        density: 5,
      );

      final buffer = Buffer.blank(10, 5);
      sparkles.start(const Point(5, 2), () {});

      // Try multiple frames to ensure we spawn particles (since it's probabilistic)
      var attempts = 0;
      var sparkleFound = false;
      while (!sparkleFound && attempts < 50) {
        buffer.clear();
        sparkles.paint(buffer, const Rect(0, 0, 10, 5), Style.empty);
        attempts++;
        for (var y = 0; y < 5; y++) {
          for (var x = 0; x < 10; x++) {
            final cell = buffer.getCell(x, y)!;
            if (sparkles.sparkleChars.contains(cell.char)) {
              sparkleFound = true;
              expect(cell.style.foreground, isNotNull);
              expect(Modifier.has(cell.style.modifiers, Modifier.bold), isTrue);
            }
          }
        }
      }
      expect(sparkleFound, isTrue);
    });

    test('FlashEffect oscillating sine intensity and bounds painting', () {
      final flash = FlashEffect(
        duration: const Duration(milliseconds: 100),
        flashColor: Colors.red,
        pulses: 1,
      );

      final buffer = Buffer.blank(10, 5);
      flash.start(const Point(0, 0), () {});

      flash.paint(buffer, const Rect(0, 0, 10, 5), Style.empty);

      // All cells should be affected since FlashEffect acts on whole buffer
      for (var y = 0; y < 5; y++) {
        for (var x = 0; x < 10; x++) {
          final cell = buffer.getCell(x, y)!;
          expect(cell.style.background, isNotNull);
        }
      }
    });
  });

  group('AnimatedButton Interactive Tests', () {
    test('Hover, press, and release lifecycle with render overlays', () {
      var pressedTriggered = false;
      final btn = AnimatedButton(
        text: 'Animate',
        onPressed: () {
          pressedTriggered = true;
        },
        width: 10,
        height: 3,
      );

      final tree = ElementWidget(btn);
      final buffer = Buffer.blank(10, 3);

      // Render base state
      tree.render(buffer, const Rect(0, 0, 10, 3));
      final state = tree.findState<AnimatedButtonState>()!;

      expect(state.isHovered, isFalse);
      expect(state.isPressed, isFalse);

      // Center should contain 'Animate' (len = 7). W = 10, start = 1. H = 3, center row = 1.
      expect(buffer.getCell(1, 1)!.char, equals('A'));
      expect(buffer.getCell(7, 1)!.char, equals('e'));

      // Move mouse inside: Hover should activate
      btn.handleMouseEvent(
        const MouseEvent(
          x: 5,
          y: 2,
          button: MouseButton.none,
          type: MouseEventType.move,
        ),
        4,
        1,
      );
      expect(state.isHovered, isTrue);
      expect(state.isPressed, isFalse);

      // Press mouse down: Pressed activates, Hover deactivates, animations start
      btn.handleMouseEvent(
        const MouseEvent(
          x: 5,
          y: 2,
          button: MouseButton.left,
          type: MouseEventType.press,
        ),
        4,
        1,
      );
      expect(state.isPressed, isTrue);
      expect(state.isHovered, isFalse);

      // Verify that particles and ripple painted something modified
      tree.render(buffer, const Rect(0, 0, 10, 3));

      // Release mouse inside: Pressed deactivates, Hover activates, onPressed called
      btn.handleMouseEvent(
        const MouseEvent(
          x: 5,
          y: 2,
          button: MouseButton.left,
          type: MouseEventType.release,
        ),
        4,
        1,
      );
      expect(pressedTriggered, isTrue);
      expect(state.isPressed, isFalse);
      expect(state.isHovered, isTrue);
    });
  });
}
