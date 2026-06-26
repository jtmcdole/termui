import 'package:test/test.dart';
import 'package:termui/ui/buffer.dart';
import 'package:termui/ui/style.dart';
import 'package:termui/ui/color.dart';
import 'package:termui/ui/widgets/core/widget.dart';
import 'package:termui/ui/widgets/core/element.dart';
import 'package:termui/ui/widgets/core/build_context.dart';
import 'package:termui/ui/widgets/core/geometry.dart';
import 'package:termui/ui/widget_toolkit.dart';
import 'package:termui_recorder/termui_recorder.dart';

class ThemeDisplayWidget extends StatelessWidget {
  const ThemeDisplayWidget();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return TestWidget(
      theme.primaryStyle.foreground == Colors.white ? 'W' : 'B',
    );
  }
}

class TestWidget extends Widget {
  final String char;
  const TestWidget(this.char);

  @override
  Element createElement() => TestWidgetElement(this);
}

class TestWidgetElement extends Element {
  TestWidgetElement(TestWidget super.widget);

  @override
  Size performLayout(BoxConstraints constraints) {
    final w = constraints.maxWidth == BoxConstraints.infinity
        ? 0
        : constraints.maxWidth;
    final h = constraints.maxHeight == BoxConstraints.infinity
        ? 0
        : constraints.maxHeight;
    return constraints.constrain(Size(w, h));
  }

  @override
  void performPaint(Buffer buffer, Offset offset) {
    final w = widget as TestWidget;
    for (var y = 0; y < size.height; y++) {
      for (var x = 0; x < size.width; x++) {
        buffer.setAttributes(
          offset.dx + x,
          offset.dy + y,
          char: w.char,
          modifiers: 0,
        );
      }
    }
  }
}

class LabelWidget extends Widget {
  final String label;
  const LabelWidget(this.label);

  @override
  Element createElement() => LabelWidgetElement(this);
}

class LabelWidgetElement extends Element {
  LabelWidgetElement(LabelWidget super.widget);

  @override
  Size performLayout(BoxConstraints constraints) {
    final w = constraints.maxWidth == BoxConstraints.infinity
        ? 0
        : constraints.maxWidth;
    final h = constraints.maxHeight == BoxConstraints.infinity
        ? 0
        : constraints.maxHeight;
    return constraints.constrain(Size(w, h));
  }

  @override
  void performPaint(Buffer buffer, Offset offset) {
    final w = widget as LabelWidget;
    for (var y = 0; y < size.height; y++) {
      for (var x = 0; x < size.width; x++) {
        buffer.setAttributes(
          offset.dx + x,
          offset.dy + y,
          char: ' ',
          modifiers: 0,
        );
      }
    }
    final labelX = (size.width - w.label.length) ~/ 2;
    final labelY = size.height ~/ 2;
    if (labelX >= 0 && labelY >= 0) {
      for (var i = 0; i < w.label.length; i++) {
        buffer.setAttributes(
          offset.dx + labelX + i,
          offset.dy + labelY,
          char: w.label[i],
          modifiers: 0,
        );
      }
    }
  }
}

void main() {
  group('Theme and ThemeData Tests', () {
    test('Default Theme (dark) falls back if none provided', () {
      final buffer = Buffer.blank(1, 1);
      const widget = ThemeDisplayWidget();

      final element = widget.createElement();
      element.mount(null);
      element.layout(BoxConstraints.tight(const Size(1, 1)));
      element.paint(buffer, Offset.zero);

      // Default dark theme primaryStyle has white foreground
      expect(buffer.getCharacter(0, 0), 'W');
    });

    test('Propagates custom light theme down the context tree', () {
      final buffer = Buffer.blank(1, 1);
      final widget = Theme(
        data: ThemeData.light,
        child: const ThemeDisplayWidget(),
      );

      final element = widget.createElement();
      element.mount(null);
      element.layout(BoxConstraints.tight(const Size(1, 1)));
      element.paint(buffer, Offset.zero);

      // Light theme primaryStyle has black foreground
      expect(buffer.getCharacter(0, 0), 'B');
    });
  });

  group('DecoratedBox Tests', () {
    test('Renders background color and Border.single', () {
      final buffer = Buffer.blank(4, 4);
      final widget = DecoratedBox(
        decoration: const BoxDecoration(
          backgroundStyle: Style(background: Colors.red),
          border: Border.single,
        ),
        child: const TestWidget('X'),
      );

      final wrapper = ElementWidget(widget);
      wrapper.layout(BoxConstraints.tight(const Size(4, 4)));
      wrapper.paint(buffer, Offset.zero);

      expect(
        buffer,
        matchesAnsiGolden('test/goldens/decorated_box_single.ansi'),
      );
    });

    test('Renders Border.doubleLine', () {
      final buffer = Buffer.blank(3, 3);
      final widget = DecoratedBox(
        decoration: const BoxDecoration(border: Border.doubleLine),
        child: const TestWidget(' '),
      );

      final wrapper = ElementWidget(widget);
      wrapper.layout(BoxConstraints.tight(const Size(3, 3)));
      wrapper.paint(buffer, Offset.zero);

      expect(
        buffer,
        matchesAnsiGolden('test/goldens/decorated_box_double.ansi'),
      );
    });

    test('Renders Border.rounded', () {
      final buffer = Buffer.blank(3, 3);
      final widget = DecoratedBox(
        decoration: const BoxDecoration(border: Border.rounded),
        child: const TestWidget(' '),
      );

      final wrapper = ElementWidget(widget);
      wrapper.layout(BoxConstraints.tight(const Size(3, 3)));
      wrapper.paint(buffer, Offset.zero);

      expect(
        buffer,
        matchesAnsiGolden('test/goldens/decorated_box_rounded.ansi'),
      );
    });

    test('Renders Border.ascii', () {
      final buffer = Buffer.blank(3, 3);
      final widget = DecoratedBox(
        decoration: const BoxDecoration(border: Border.ascii),
        child: const TestWidget(' '),
      );

      final wrapper = ElementWidget(widget);
      wrapper.layout(BoxConstraints.tight(const Size(3, 3)));
      wrapper.paint(buffer, Offset.zero);

      expect(
        buffer,
        matchesAnsiGolden('test/goldens/decorated_box_ascii.ansi'),
      );
    });

    test('Renders Border.heavy', () {
      final buffer = Buffer.blank(3, 3);
      final widget = DecoratedBox(
        decoration: const BoxDecoration(border: Border.heavy),
        child: const TestWidget(' '),
      );

      final wrapper = ElementWidget(widget);
      wrapper.layout(BoxConstraints.tight(const Size(3, 3)));
      wrapper.paint(buffer, Offset.zero);

      expect(
        buffer,
        matchesAnsiGolden('test/goldens/decorated_box_heavy.ansi'),
      );
    });

    test('Renders Border.dashed', () {
      final buffer = Buffer.blank(3, 3);
      final widget = DecoratedBox(
        decoration: const BoxDecoration(border: Border.dashed),
        child: const TestWidget(' '),
      );

      final wrapper = ElementWidget(widget);
      wrapper.layout(BoxConstraints.tight(const Size(3, 3)));
      wrapper.paint(buffer, Offset.zero);

      expect(
        buffer,
        matchesAnsiGolden('test/goldens/decorated_box_dashed.ansi'),
      );
    });

    test('Renders Border.block', () {
      final buffer = Buffer.blank(3, 3);
      final widget = DecoratedBox(
        decoration: const BoxDecoration(border: Border.block),
        child: const TestWidget(' '),
      );

      final wrapper = ElementWidget(widget);
      wrapper.layout(BoxConstraints.tight(const Size(3, 3)));
      wrapper.paint(buffer, Offset.zero);

      expect(
        buffer,
        matchesAnsiGolden('test/goldens/decorated_box_block.ansi'),
      );
    });

    test('Renders Border.shadedLight', () {
      final buffer = Buffer.blank(3, 3);
      final widget = DecoratedBox(
        decoration: const BoxDecoration(border: Border.shadedLight),
        child: const TestWidget(' '),
      );

      final wrapper = ElementWidget(widget);
      wrapper.layout(BoxConstraints.tight(const Size(3, 3)));
      wrapper.paint(buffer, Offset.zero);

      expect(
        buffer,
        matchesAnsiGolden('test/goldens/decorated_box_shaded_light.ansi'),
      );
    });

    test('Renders Border.shadedMedium', () {
      final buffer = Buffer.blank(3, 3);
      final widget = DecoratedBox(
        decoration: const BoxDecoration(border: Border.shadedMedium),
        child: const TestWidget(' '),
      );

      final wrapper = ElementWidget(widget);
      wrapper.layout(BoxConstraints.tight(const Size(3, 3)));
      wrapper.paint(buffer, Offset.zero);

      expect(
        buffer,
        matchesAnsiGolden('test/goldens/decorated_box_shaded_medium.ansi'),
      );
    });

    test('Renders Border.shadedDark', () {
      final buffer = Buffer.blank(3, 3);
      final widget = DecoratedBox(
        decoration: const BoxDecoration(border: Border.shadedDark),
        child: const TestWidget(' '),
      );

      final wrapper = ElementWidget(widget);
      wrapper.layout(BoxConstraints.tight(const Size(3, 3)));
      wrapper.paint(buffer, Offset.zero);

      expect(
        buffer,
        matchesAnsiGolden('test/goldens/decorated_box_shaded_dark.ansi'),
      );
    });

    test('Renders Border.halfBlock', () {
      final buffer = Buffer.blank(3, 3);
      final widget = DecoratedBox(
        decoration: const BoxDecoration(border: Border.halfBlock),
        child: const TestWidget(' '),
      );

      final wrapper = ElementWidget(widget);
      wrapper.layout(BoxConstraints.tight(const Size(3, 3)));
      wrapper.paint(buffer, Offset.zero);

      expect(
        buffer,
        matchesAnsiGolden('test/goldens/decorated_box_half_block.ansi'),
      );
    });

    test('Renders Border.diagonalSlash', () {
      final buffer = Buffer.blank(3, 3);
      final widget = DecoratedBox(
        decoration: const BoxDecoration(border: Border.diagonalSlash),
        child: const TestWidget(' '),
      );

      final wrapper = ElementWidget(widget);
      wrapper.layout(BoxConstraints.tight(const Size(3, 3)));
      wrapper.paint(buffer, Offset.zero);

      expect(
        buffer,
        matchesAnsiGolden('test/goldens/decorated_box_diagonal_slash.ansi'),
      );
    });

    test('Renders Border.diagonalBackslash', () {
      final buffer = Buffer.blank(3, 3);
      final widget = DecoratedBox(
        decoration: const BoxDecoration(border: Border.diagonalBackslash),
        child: const TestWidget(' '),
      );

      final wrapper = ElementWidget(widget);
      wrapper.layout(BoxConstraints.tight(const Size(3, 3)));
      wrapper.paint(buffer, Offset.zero);

      expect(
        buffer,
        matchesAnsiGolden('test/goldens/decorated_box_diagonal_backslash.ansi'),
      );
    });

    test('Renders Border.quadDiagonals', () {
      final buffer = Buffer.blank(4, 4);
      final widget = DecoratedBox(
        decoration: const BoxDecoration(border: Border.quadDiagonals),
        child: const TestWidget(' '),
      );

      final wrapper = ElementWidget(widget);
      wrapper.layout(BoxConstraints.tight(const Size(4, 4)));
      wrapper.paint(buffer, Offset.zero);

      expect(
        buffer,
        matchesAnsiGolden('test/goldens/decorated_box_quad_diagonals.ansi'),
      );
    });

    test('Renders Border.quadPadding', () {
      final buffer = Buffer.blank(4, 4);
      final widget = DecoratedBox(
        decoration: const BoxDecoration(border: Border.quadPadding),
        child: const TestWidget(' '),
      );

      final wrapper = ElementWidget(widget);
      wrapper.layout(BoxConstraints.tight(const Size(4, 4)));
      wrapper.paint(buffer, Offset.zero);

      expect(
        buffer,
        matchesAnsiGolden('test/goldens/decorated_box_quad_padding.ansi'),
      );
    });

    test('Renders Border.braille', () {
      final buffer = Buffer.blank(4, 4);
      final widget = DecoratedBox(
        decoration: const BoxDecoration(border: Border.braille),
        child: const TestWidget(' '),
      );

      final wrapper = ElementWidget(widget);
      wrapper.layout(BoxConstraints.tight(const Size(4, 4)));
      wrapper.paint(buffer, Offset.zero);

      expect(
        buffer,
        matchesAnsiGolden('test/goldens/decorated_box_braille.ansi'),
      );
    });

    test('Renders emoji border and matches golden', () {
      final buffer = Buffer.blank(6, 6);
      final widget = DecoratedBox(
        decoration: const BoxDecoration(
          border: Border(
            topChar: '😀',
            bottomChar: '😁',
            leftChar: '😂',
            rightChar: '😃',
            topLeftChar: '🤩',
            topRightChar: '🥳',
            bottomLeftChar: '😇',
            bottomRightChar: '🤠',
          ),
        ),
        child: const TestWidget(' '),
      );

      final wrapper = ElementWidget(widget);
      wrapper.layout(BoxConstraints.tight(const Size(6, 6)));
      wrapper.paint(buffer, Offset.zero);

      expect(
        buffer,
        matchesAnsiGolden('test/goldens/decorated_box_emoji.ansi'),
      );
    });

    test('Renders Neon Gradient shaded border', () {
      final buffer = Buffer.blank(10, 4);
      final widget = DecoratedBox(
        decoration: const BoxDecoration(
          border: Border.shadedLight,
          borderStartColor: Color(0, 240, 200),
          borderEndColor: Color(180, 40, 250),
        ),
        child: const TestWidget(' '),
      );

      final wrapper = ElementWidget(widget);
      wrapper.layout(BoxConstraints.tight(const Size(10, 4)));
      wrapper.paint(buffer, Offset.zero);

      expect(
        buffer,
        matchesAnsiGolden('test/goldens/decorated_box_neon_gradient.ansi'),
      );
    });

    test('Renders diagonal Neon Gradient border', () {
      final buffer = Buffer.blank(10, 4);
      final widget = DecoratedBox(
        decoration: const BoxDecoration(
          border: Border.shadedLight,
          borderStartColor: Color(0, 240, 200),
          borderEndColor: Color(180, 40, 250),
          borderGradientAngle: 0.785, // ~45 degrees diagonal gradient
        ),
        child: const TestWidget(' '),
      );

      final wrapper = ElementWidget(widget);
      wrapper.layout(BoxConstraints.tight(const Size(10, 4)));
      wrapper.paint(buffer, Offset.zero);

      expect(
        buffer,
        matchesAnsiGolden('test/goldens/decorated_box_diagonal_gradient.ansi'),
      );
    });

    test('Renders rotating Neon Gradient borders (10 angles 0-360)', () {
      // 10 boxes, each is 10x4.
      // We lay them out in a 2x5 grid.
      // Space between columns is 2, space between rows is 2.
      // Total width = 5 * 10 + 4 * 2 = 58.
      // Total height = 2 * 4 + 1 * 2 = 10.
      final buffer = Buffer.blank(58, 10);

      // We generate 10 angles from 0 to 360 degrees (in radians: 0 to 2*pi).
      // Let's divide 2*pi into 10 steps.
      const numBoxes = 10;
      const piVal = 3.141592653589793;
      for (var i = 0; i < numBoxes; i++) {
        final angle = (i * 2 * piVal) / numBoxes;
        final deg = i * 360 ~/ numBoxes;
        final widget = DecoratedBox(
          decoration: BoxDecoration(
            border: Border.shadedLight,
            borderStartColor: const Color(0, 240, 200),
            borderEndColor: const Color(180, 40, 250),
            borderGradientAngle: angle,
          ),
          child: LabelWidget('$deg°'),
        );

        final col = i % 5;
        final row = i ~/ 5;

        final x = col * 12;
        final y = row * 6;

        final wrapper = ElementWidget(widget);
        wrapper.layout(BoxConstraints.tight(const Size(10, 4)));
        wrapper.paint(buffer, Offset(x, y));
      }

      expect(
        buffer,
        matchesAnsiGolden('test/goldens/decorated_box_rotation_gradient.ansi'),
      );
    });

    test('Wide corners adjust layout offsets and prevent child overlap', () {
      final widget = DecoratedBox(
        decoration: const BoxDecoration(
          border: Border(
            topChar: '─',
            bottomChar: '─',
            leftChar: '', // empty side
            rightChar: '', // empty side
            topLeftChar: '😀', // width 2
            topRightChar: '🥳', // width 2
            bottomLeftChar: '😇', // width 2
            bottomRightChar: '🤠', // width 2
          ),
        ),
        child: const TestWidget('X'),
      );

      final element = widget.createElement() as DecoratedBoxElement;
      element.mount(null);

      // Total outer size is 8x4.
      // Top and bottom borders exist (height offset = 1 for top, 1 for bottom).
      // Left and right side characters are empty (width 0), but corners are width 2.
      // So _cachedLeftOffset = max(0, 2, 2) = 2.
      // _cachedRightOffset = max(0, 2, 2) = 2.
      // Total border horizontal width = 4, vertical height = 2.
      element.layout(BoxConstraints.tight(const Size(8, 4)));

      // Check offsets computed
      expect(element.childElement?.relativeOffset.dx, 2);
      expect(element.childElement?.relativeOffset.dy, 1);

      // Check inner child size
      expect(element.childElement?.size.width, 4); // 8 - 4
      expect(element.childElement?.size.height, 2); // 4 - 2

      final buffer = Buffer.blank(8, 4);
      element.paint(buffer, Offset.zero);

      // Left corners (x=0,1) and right corners (x=6,7) are drawn.
      // The child widget 'X' is drawn starting at relativeOffset (x=2, y=1) to (x=5, y=2).
      // So at x=2, y=1 we should find 'X', not ' ' or part of corner emoji.
      expect(buffer.getCharacter(2, 1), 'X');
      expect(buffer.getCharacter(5, 1), 'X');
      // At x=2, y=0 it should be '─' border line.
      expect(buffer.getCharacter(2, 0), '─');
    });
  });

  group('Text Widget Tests', () {
    test('measureStringWidth handles CJK and Emoji', () {
      expect(measureStringWidth('Hello'), 5);
      expect(measureStringWidth('你好'), 4);
      expect(measureStringWidth('Hello你好😀'), 11); // 5 + 4 + 2
    });

    test('Basic Text rendering without wrap', () {
      final buffer = Buffer.blank(10, 1);
      final widget = const Text('Hello你好', wrap: false);

      final wrapper = ElementWidget(widget);
      wrapper.layout(BoxConstraints.tight(const Size(10, 1)));
      wrapper.paint(buffer, Offset.zero);
      // "Hello你好": Hello is 5, 你好 is 4. Total = 9.
      expect(buffer.getCharacter(0, 0), 'H');
      expect(buffer.getCharacter(5, 0), '你');
      expect(buffer.getCharacter(6, 0), '');
      expect(buffer.getCharacter(7, 0), '好');
      expect(buffer.getCharacter(8, 0), '');
      expect(buffer.getCharacter(9, 0), ' ');
    });

    test('Truncation on narrow area boundary for CJK', () {
      final buffer = Buffer.blank(6, 1);
      final widget = const Text(
        'Hello你',
        wrap: false,
      ); // Hello = 5, 你 = 2. Total = 7.

      final wrapper = ElementWidget(widget);
      wrapper.layout(BoxConstraints.tight(const Size(6, 1)));
      wrapper.paint(buffer, Offset.zero);
      // Should show "Hello" and a space since "你" requires 2 cells but only 1 remains.
      expect(buffer.getCharacter(0, 0), 'H');
      expect(buffer.getCharacter(4, 0), 'o');
      expect(buffer.getCharacter(5, 0), ' ');
    });

    test('Text wrapping with CJK and Emojis', () {
      final buffer = Buffer.blank(8, 3);
      // "Hello 你好 😀 World" -> Hello(5) [space](1) 你好(4) [space](1) 😀(2) [space](1) World(5)
      // Wrap width is 8.
      // Line 1: "Hello" (5). "你好" (4) doesn't fit on same line.
      // Line 2: "你好 😀" (4 + 1 + 2 = 7).
      // Line 3: "World" (5).
      final widget = const Text('Hello 你好 😀 World', wrap: true);

      final wrapper = ElementWidget(widget);
      wrapper.layout(BoxConstraints.tight(const Size(8, 3)));
      wrapper.paint(buffer, Offset.zero);

      // Line 1
      expect(buffer.getCharacter(0, 0), 'H');
      expect(buffer.getCharacter(4, 0), 'o');
      expect(buffer.getCharacter(5, 0), ' ');

      // Line 2
      expect(buffer.getCharacter(0, 1), '你');
      expect(buffer.getCharacter(1, 1), '');
      expect(buffer.getCharacter(2, 1), '好');
      expect(buffer.getCharacter(3, 1), '');
      expect(buffer.getCharacter(4, 1), ' ');
      expect(buffer.getCharacter(5, 1), '😀');
      expect(buffer.getCharacter(6, 1), '');
      expect(buffer.getCharacter(7, 1), ' ');

      // Line 3
      expect(buffer.getCharacter(0, 2), 'W');
      expect(buffer.getCharacter(4, 2), 'd');
    });

    test('Text alignments (Left, Center, Right)', () {
      final bufferLeft = Buffer.blank(10, 1);
      final bufferCenter = Buffer.blank(10, 1);
      final bufferRight = Buffer.blank(10, 1);

      final wLeft = const Text('你好', wrap: false, textAlign: TextAlign.left);
      final wrapperLeft = ElementWidget(wLeft);
      wrapperLeft.layout(BoxConstraints.tight(const Size(10, 1)));
      wrapperLeft.paint(bufferLeft, Offset.zero);

      final wCenter = const Text(
        '你好',
        wrap: false,
        textAlign: TextAlign.center,
      );
      final wrapperCenter = ElementWidget(wCenter);
      wrapperCenter.layout(BoxConstraints.tight(const Size(10, 1)));
      wrapperCenter.paint(bufferCenter, Offset.zero);

      final wRight = const Text('你好', wrap: false, textAlign: TextAlign.right);
      final wrapperRight = ElementWidget(wRight);
      wrapperRight.layout(BoxConstraints.tight(const Size(10, 1)));
      wrapperRight.paint(bufferRight, Offset.zero);

      // Left
      expect(bufferLeft.getCharacter(0, 0), '你');
      expect(bufferLeft.getCharacter(2, 0), '好');
      expect(bufferLeft.getCharacter(4, 0), ' ');

      // Center: width 10, content width 4. start = (10-4) ~/ 2 = 3.
      expect(bufferCenter.getCharacter(2, 0), ' ');
      expect(bufferCenter.getCharacter(3, 0), '你');
      expect(bufferCenter.getCharacter(5, 0), '好');
      expect(bufferCenter.getCharacter(7, 0), ' ');

      // Right: start = 10 - 4 = 6.
      expect(bufferRight.getCharacter(5, 0), ' ');
      expect(bufferRight.getCharacter(6, 0), '你');
      expect(bufferRight.getCharacter(8, 0), '好');
    });
  });
}
