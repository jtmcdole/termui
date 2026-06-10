import 'dart:async';
import 'package:test/test.dart';
import 'package:termui/ui/buffer.dart';
import 'package:termui/ui/layout.dart';
import 'package:termui/ui/style.dart';
import 'package:termui/ui/color.dart';
import 'package:termui/ui/event.dart' hide Modifier;
import 'package:termui/ui/widget_toolkit.dart';

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

      // Normal state body at Rect(0, 0, 9, 3)
      // So rightmost column 9 and bottom row 3 are empty/transparent
      expect(buffer.getCell(9, 0)!.isTransparent, isTrue);
      expect(buffer.getCell(9, 1)!.isTransparent, isTrue);
      expect(buffer.getCell(9, 2)!.isTransparent, isTrue);
      expect(buffer.getCell(9, 3)!.isTransparent, isTrue);
      expect(buffer.getCell(0, 3)!.isTransparent, isTrue);
      expect(buffer.getCell(5, 3)!.isTransparent, isTrue);

      // Body background should be red (color1)
      final bodyCell = buffer.getCell(0, 0)!;
      expect(bodyCell.style.background, equals(Colors.red));

      // Text 'Click' centered inside body Rect(0, 0, 9, 3)
      // bodyWidth = 9, bodyHeight = 3
      // textLen = 5. Center row = 1, start column = 2 (relative to body)
      // So buffer coordinates: row = 1, start column = 2
      expect(buffer.getCell(2, 1)!.char, equals('C'));
      expect(buffer.getCell(3, 1)!.char, equals('l'));
      expect(buffer.getCell(4, 1)!.char, equals('i'));
      expect(buffer.getCell(5, 1)!.char, equals('c'));
      expect(buffer.getCell(6, 1)!.char, equals('k'));

      // Verify text style has white foreground and bold modifier merged with red background
      final firstCharCell = buffer.getCell(2, 1)!;
      expect(firstCharCell.style.foreground, equals(Colors.white));
      expect(firstCharCell.style.background, equals(Colors.red));
      expect(
        Modifier.has(firstCharCell.style.modifiers, Modifier.bold),
        isTrue,
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

      // Body at Rect(0, 0, 9, 3)
      expect(buffer.getCell(0, 0)!.style.background, equals(Colors.red));

      // Text centered inside body Rect(0, 0, 9, 3) -> row = 1, start column = 2
      expect(buffer.getCell(2, 1)!.char, equals('C'));
      expect(buffer.getCell(3, 1)!.char, equals('l'));
      expect(buffer.getCell(4, 1)!.char, equals('i'));
      expect(buffer.getCell(5, 1)!.char, equals('c'));
      expect(buffer.getCell(6, 1)!.char, equals('k'));

      // Drop shadow in bottom row (H - 1 = 3) and rightmost column (W - 1 = 9)
      final shadowColor = const Color(64, 64, 64);
      // Rightmost column shadow (from row 1 to H - 2) draws Right Half-Block '▐'
      expect(buffer.getCell(9, 1)!.char, equals('▐'));
      expect(buffer.getCell(9, 1)!.style.foreground, equals(shadowColor));
      expect(buffer.getCell(9, 2)!.char, equals('▐'));
      expect(buffer.getCell(9, 2)!.style.foreground, equals(shadowColor));

      // Bottom row shadow (from column 1 to W - 1) draws Lower Half-Block '▄'
      expect(buffer.getCell(1, 3)!.char, equals('▄'));
      expect(buffer.getCell(1, 3)!.style.foreground, equals(shadowColor));
      expect(buffer.getCell(8, 3)!.char, equals('▄'));
      expect(buffer.getCell(8, 3)!.style.foreground, equals(shadowColor));

      // Bottom-right corner shadow
      expect(buffer.getCell(9, 3)!.char, equals('▄'));
      expect(buffer.getCell(9, 3)!.style.foreground, equals(shadowColor));

      // Other cells (like top-right 9,0 and bottom-left 0,3) are transparent/empty
      expect(buffer.getCell(9, 0)!.isTransparent, isTrue);
      expect(buffer.getCell(0, 3)!.isTransparent, isTrue);
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

      // Body at Rect(0, 0, 7, 2). Columns: 0 to 6. Rows: 0 to 1.
      // Column 7 should be empty/transparent since width is 8 (columns 0..7, so shadow is at 7, body at 0..6).
      // Row 2 should be empty/transparent since height is 3 (rows 0..2, so shadow is at 2, body at 0..1).
      expect(buffer.getCell(7, 0)!.isTransparent, isTrue);
      expect(buffer.getCell(0, 2)!.isTransparent, isTrue);

      // Cells outside 8x3 should remain untouched (not transparent in a blank buffer)
      expect(buffer.getCell(8, 0)!.isTransparent, isFalse);
      expect(buffer.getCell(0, 3)!.isTransparent, isFalse);
    });
  });
}
