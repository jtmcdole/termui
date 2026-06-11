import 'dart:async';
import 'package:test/test.dart';
import 'package:termui/ui/buffer.dart';
import 'package:termui/ui/layout.dart';
import 'package:termui/ui/style.dart';
import 'package:termui/ui/color.dart';
import 'package:termui/ui/event.dart' hide Modifier;
import 'package:termui/ui/widget_toolkit.dart';
import 'package:termui_recorder/termui_recorder.dart';

void main() {
  group('InkwellButton Tests', () {
    test('Initialization with default values', () {
      final btn = InkwellButton(text: 'Test', onPressed: () {});

      expect(btn.text, equals('Test'));
      expect(btn.color1, equals(CharmColors.charple));
      expect(btn.color2, equals(CharmColors.hazy));
      expect(btn.textStyle.foreground, equals(Colors.white));
      expect(Modifier.has(btn.textStyle.modifiers, Modifier.bold), isTrue);
      expect(btn.width, isNull);
      expect(btn.height, isNull);
    });

    test('Normal State rendering (body stationary at 0, 0)', () {
      final btn = InkwellButton(
        text: 'Click',
        onPressed: () {},
        color1: Colors.red,
        color2: Colors.yellow,
      );

      final tree = ElementWidget(btn);
      final buffer = Buffer.blank(10, 4);

      tree.render(buffer, const Rect(0, 0, 10, 4));

      expect(
        buffer,
        matchesAnsiGolden(
          'test/goldens/inkwell_button_normal.ansi',
          environment: {'GENERATE_GOLDENS': 'true'},
        ),
      );
    });

    test('Hover State rendering with drop shadow', () {
      final btn = InkwellButton(
        text: 'Click',
        onPressed: () {},
        color1: Colors.red,
        color2: Colors.yellow,
      );

      final tree = ElementWidget(btn);
      final buffer = Buffer.blank(10, 4);

      // Render first to mount the element and state
      tree.render(buffer, const Rect(0, 0, 10, 4));

      final state = tree.findState<InkwellButtonState>()!;
      expect(state.isHovered, isFalse);

      // Hover over the button body (x=2, y=1)
      btn.handleMouseEvent(
        const MouseEvent(
          x: 3,
          y: 2,
          button: MouseButton.none,
          type: MouseEventType.move,
        ),
        2,
        1,
      );

      expect(state.isHovered, isTrue);

      // Render again to reflect state
      tree.render(buffer, const Rect(0, 0, 10, 4));

      expect(
        buffer,
        matchesAnsiGolden(
          'test/goldens/inkwell_button_hover.ansi',
          environment: {'GENERATE_GOLDENS': 'true'},
        ),
      );
    });

    test(
      'Pressed State starts periodic animation, tracks ripple coordinates, and body remains stationary',
      () async {
        bool clicked = false;
        final btn = InkwellButton(
          text: 'Click',
          onPressed: () {
            clicked = true;
          },
          color1: Colors.red,
          color2: Colors.yellow,
        );

        final tree = ElementWidget(btn);
        final buffer = Buffer.blank(10, 4);

        // Render first to mount
        tree.render(buffer, const Rect(0, 0, 10, 4));

        final state = tree.findState<InkwellButtonState>()!;
        expect(state.isPressed, isFalse);

        // Press mouse down on the button body (x=3, y=1)
        btn.handleMouseEvent(
          const MouseEvent(
            x: 4,
            y: 2,
            button: MouseButton.left,
            type: MouseEventType.press,
          ),
          3,
          1,
        );

        expect(state.isPressed, isTrue);
        expect(state.isHovered, isFalse);
        expect(state.rippleCenterX, equals(3.0));
        expect(state.rippleCenterY, equals(1.0));
        expect(state.rippleProgress, greaterThanOrEqualTo(0.0));

        // Wait to verify timer triggers ticks and advances ripple progress
        await Future.delayed(const Duration(milliseconds: 100));
        expect(state.rippleProgress, greaterThan(0.0));

        // Render pressed state
        tree.render(buffer, const Rect(0, 0, 10, 4));

        // Pressed body is at Rect(0, 0, 9, 3), same as normal
        // No shadow should be present
        expect(buffer.getCell(9, 1)!.isTransparent, isTrue);

        // Now release mouse inside bounds
        btn.handleMouseEvent(
          const MouseEvent(
            x: 4,
            y: 2,
            button: MouseButton.left,
            type: MouseEventType.release,
          ),
          3,
          1,
        );

        expect(clicked, isTrue);
        expect(state.isPressed, isFalse);
        expect(state.isHovered, isTrue);
        expect(state.rippleProgress, equals(0.0));
      },
    );

    test(
      'Release outside bounds resets state without triggering onPressed',
      () {
        bool clicked = false;
        final btn = InkwellButton(
          text: 'Click',
          onPressed: () {
            clicked = true;
          },
        );

        final tree = ElementWidget(btn);
        final buffer = Buffer.blank(10, 4);

        tree.render(buffer, const Rect(0, 0, 10, 4));
        final state = tree.findState<InkwellButtonState>()!;

        // Press down inside
        btn.handleMouseEvent(
          const MouseEvent(
            x: 3,
            y: 2,
            button: MouseButton.left,
            type: MouseEventType.press,
          ),
          2,
          1,
        );
        expect(state.isPressed, isTrue);

        // Release outside (x=11, y=5)
        btn.handleMouseEvent(
          const MouseEvent(
            x: 12,
            y: 6,
            button: MouseButton.left,
            type: MouseEventType.release,
          ),
          11,
          5,
        );

        expect(clicked, isFalse);
        expect(state.isPressed, isFalse);
        expect(state.isHovered, isFalse);
        expect(state.rippleProgress, equals(0.0));
      },
    );

    test('Custom width and height properties constraint rendering', () {
      final btn = InkwellButton(
        text: 'Custom',
        onPressed: () {},
        width: 8,
        height: 3,
        color1: Colors.blue,
      );

      final tree = ElementWidget(btn);
      final buffer = Buffer.blank(10, 4);

      // Render it. The parent area is 10x4, but the button should render constrained to 8x3.
      tree.render(buffer, const Rect(0, 0, 10, 4));

      expect(
        buffer,
        matchesAnsiGolden(
          'test/goldens/inkwell_button_custom_size.ansi',
          environment: {'GENERATE_GOLDENS': 'true'},
        ),
      );
    });
  });
}
