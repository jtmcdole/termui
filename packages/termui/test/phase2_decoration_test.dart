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
        matchesAnsiGolden(
          'test/goldens/decorated_box_single.ansi',
          environment: {'GENERATE_GOLDENS': 'true'},
        ),
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
        matchesAnsiGolden(
          'test/goldens/decorated_box_double.ansi',
          environment: {'GENERATE_GOLDENS': 'true'},
        ),
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
        matchesAnsiGolden(
          'test/goldens/decorated_box_rounded.ansi',
          environment: {'GENERATE_GOLDENS': 'true'},
        ),
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
        matchesAnsiGolden(
          'test/goldens/decorated_box_ascii.ansi',
          environment: {'GENERATE_GOLDENS': 'true'},
        ),
      );
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
