import 'package:test/test.dart';
import 'package:termui/ui/buffer.dart';
import 'package:termui/ui/style.dart';
import 'package:termui/ui/color.dart';
import 'package:termui/ui/layout.dart';
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
  void render(Buffer buffer, Rect area) {
    for (var y = 0; y < area.height; y++) {
      for (var x = 0; x < area.width; x++) {
        buffer.setCell(area.x + x, area.y + y, Cell(char, Style.empty));
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
      element.render(buffer, const Rect(0, 0, 1, 1));

      // Default dark theme primaryStyle has white foreground
      expect(buffer.getCell(0, 0)!.char, 'W');
    });

    test('Propagates custom light theme down the context tree', () {
      final buffer = Buffer.blank(1, 1);
      final widget = Theme(
        data: ThemeData.light,
        child: const ThemeDisplayWidget(),
      );

      final element = widget.createElement();
      element.mount(null);
      element.render(buffer, const Rect(0, 0, 1, 1));

      // Light theme primaryStyle has black foreground
      expect(buffer.getCell(0, 0)!.char, 'B');
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

      widget.render(buffer, const Rect(0, 0, 4, 4));

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

      widget.render(buffer, const Rect(0, 0, 3, 3));

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

      widget.render(buffer, const Rect(0, 0, 3, 3));

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

      widget.render(buffer, const Rect(0, 0, 3, 3));

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

      widget.render(buffer, const Rect(0, 0, 10, 1));
      // "Hello你好": Hello is 5, 你好 is 4. Total = 9.
      expect(buffer.getCell(0, 0)!.char, 'H');
      expect(buffer.getCell(5, 0)!.char, '你');
      expect(buffer.getCell(6, 0)!.char, '');
      expect(buffer.getCell(7, 0)!.char, '好');
      expect(buffer.getCell(8, 0)!.char, '');
      expect(buffer.getCell(9, 0)!.char, ' ');
    });

    test('Truncation on narrow area boundary for CJK', () {
      final buffer = Buffer.blank(6, 1);
      final widget = const Text(
        'Hello你',
        wrap: false,
      ); // Hello = 5, 你 = 2. Total = 7.

      widget.render(buffer, const Rect(0, 0, 6, 1));
      // Should show "Hello" and a space since "你" requires 2 cells but only 1 remains.
      expect(buffer.getCell(0, 0)!.char, 'H');
      expect(buffer.getCell(4, 0)!.char, 'o');
      expect(buffer.getCell(5, 0)!.char, ' ');
    });

    test('Text wrapping with CJK and Emojis', () {
      final buffer = Buffer.blank(8, 3);
      // "Hello 你好 😀 World" -> Hello(5) [space](1) 你好(4) [space](1) 😀(2) [space](1) World(5)
      // Wrap width is 8.
      // Line 1: "Hello" (5). "你好" (4) doesn't fit on same line.
      // Line 2: "你好 😀" (4 + 1 + 2 = 7).
      // Line 3: "World" (5).
      final widget = const Text('Hello 你好 😀 World', wrap: true);

      widget.render(buffer, const Rect(0, 0, 8, 3));

      // Line 1
      expect(buffer.getCell(0, 0)!.char, 'H');
      expect(buffer.getCell(4, 0)!.char, 'o');
      expect(buffer.getCell(5, 0)!.char, ' ');

      // Line 2
      expect(buffer.getCell(0, 1)!.char, '你');
      expect(buffer.getCell(1, 1)!.char, '');
      expect(buffer.getCell(2, 1)!.char, '好');
      expect(buffer.getCell(3, 1)!.char, '');
      expect(buffer.getCell(4, 1)!.char, ' ');
      expect(buffer.getCell(5, 1)!.char, '😀');
      expect(buffer.getCell(6, 1)!.char, '');
      expect(buffer.getCell(7, 1)!.char, ' ');

      // Line 3
      expect(buffer.getCell(0, 2)!.char, 'W');
      expect(buffer.getCell(4, 2)!.char, 'd');
    });

    test('Text alignments (Left, Center, Right)', () {
      final bufferLeft = Buffer.blank(10, 1);
      final bufferCenter = Buffer.blank(10, 1);
      final bufferRight = Buffer.blank(10, 1);

      const Text(
        '你好',
        wrap: false,
        textAlign: TextAlign.left,
      ).render(bufferLeft, const Rect(0, 0, 10, 1));
      const Text(
        '你好',
        wrap: false,
        textAlign: TextAlign.center,
      ).render(bufferCenter, const Rect(0, 0, 10, 1));
      const Text(
        '你好',
        wrap: false,
        textAlign: TextAlign.right,
      ).render(bufferRight, const Rect(0, 0, 10, 1));

      // Left
      expect(bufferLeft.getCell(0, 0)!.char, '你');
      expect(bufferLeft.getCell(2, 0)!.char, '好');
      expect(bufferLeft.getCell(4, 0)!.char, ' ');

      // Center: width 10, content width 4. start = (10-4) ~/ 2 = 3.
      expect(bufferCenter.getCell(2, 0)!.char, ' ');
      expect(bufferCenter.getCell(3, 0)!.char, '你');
      expect(bufferCenter.getCell(5, 0)!.char, '好');
      expect(bufferCenter.getCell(7, 0)!.char, ' ');

      // Right: start = 10 - 4 = 6.
      expect(bufferRight.getCell(5, 0)!.char, ' ');
      expect(bufferRight.getCell(6, 0)!.char, '你');
      expect(bufferRight.getCell(8, 0)!.char, '好');
    });
  });
}
