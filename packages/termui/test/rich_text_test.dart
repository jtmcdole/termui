import 'package:test/test.dart';
import 'package:termui/ui/buffer.dart';
import 'package:termui/ui/layout.dart';
import 'package:termui/ui/style.dart';
import 'package:termui/ui/color.dart';
import 'package:termui/ui/widget_toolkit.dart';

void main() {
  group('RichText Widget Tests', () {
    test('RichLabel renders styled runs sequentially and clips to bounds', () {
      final buffer = Buffer.blank(10, 1);
      final label = const RichText(
        wrap: false,
        text: TextSpan(
          children: [
            TextSpan(
              text: 'abc',
              style: Style(foreground: Colors.red),
            ),
            TextSpan(
              text: 'def',
              style: Style(foreground: Colors.blue),
            ),
            TextSpan(
              text: 'ghijkl',
              style: Style(foreground: Colors.green),
            ), // exceeds 10 chars
          ],
        ),
      );

      label.render(buffer, const Rect(0, 0, 10, 1));

      // Cells 0-2: 'abc' with red style
      expect(buffer.getCell(0, 0)!.char, equals('a'));
      expect(buffer.getCell(0, 0)!.style.foreground, equals(Colors.red));
      expect(buffer.getCell(2, 0)!.char, equals('c'));
      expect(buffer.getCell(2, 0)!.style.foreground, equals(Colors.red));

      // Cells 3-5: 'def' with blue style
      expect(buffer.getCell(3, 0)!.char, equals('d'));
      expect(buffer.getCell(3, 0)!.style.foreground, equals(Colors.blue));
      expect(buffer.getCell(5, 0)!.char, equals('f'));
      expect(buffer.getCell(5, 0)!.style.foreground, equals(Colors.blue));

      // Cells 6-9: 'ghij' with green style (clipped)
      expect(buffer.getCell(6, 0)!.char, equals('g'));
      expect(buffer.getCell(6, 0)!.style.foreground, equals(Colors.green));
      expect(buffer.getCell(9, 0)!.char, equals('j'));
      expect(buffer.getCell(9, 0)!.style.foreground, equals(Colors.green));

      // Cell 10 should not exist in 10-char wide buffer
      expect(buffer.getCell(10, 0), isNull);
    });

    test('RichParagraph wraps styled runs correctly', () {
      final buffer = Buffer.blank(10, 3);
      final paragraph = const RichText(
        text: TextSpan(
          children: [
            TextSpan(
              text: 'Hello ',
              style: Style(foreground: Colors.red),
            ),
            TextSpan(
              text: 'rich ',
              style: Style(foreground: Colors.blue),
            ),
            TextSpan(
              text: 'world wrapping',
              style: Style(foreground: Colors.green),
            ),
          ],
        ),
      );

      // MaxWidth = 10
      // 'Hello' (5) + ' ' -> fits
      // 'rich' (4) + ' ' -> fits (total 10)
      // 'world' (5) -> wraps to line 1
      // 'wrapping' (8) -> wraps to line 2
      paragraph.render(buffer, const Rect(0, 0, 10, 3));

      // Line 0: 'Hello rich'
      final line0 = List.generate(
        10,
        (x) => buffer.getCell(x, 0)!.char,
      ).join('');
      expect(line0, equals('Hello rich'));
      expect(buffer.getCell(0, 0)!.style.foreground, equals(Colors.red));
      expect(buffer.getCell(6, 0)!.style.foreground, equals(Colors.blue));

      // Line 1: 'world' (trailing whitespace trimmed)
      final line1 = List.generate(
        5,
        (x) => buffer.getCell(x, 1)!.char,
      ).join('');
      expect(line1, equals('world'));
      expect(buffer.getCell(0, 1)!.style.foreground, equals(Colors.green));

      // Line 2: 'wrapping'
      final line2 = List.generate(
        8,
        (x) => buffer.getCell(x, 2)!.char,
      ).join('');
      expect(line2, equals('wrapping'));
      expect(buffer.getCell(0, 2)!.style.foreground, equals(Colors.green));
    });
  });

  group('TimerWidget Tests', () {
    test('Timer ticks down and triggers callback', () {
      var finished = false;
      final timer = TimerWidget(
        duration: const Duration(seconds: 3),
        running: true,
        onFinished: () {
          finished = true;
        },
      );

      timer.tick(const Duration(seconds: 1));
      expect(timer.duration.inSeconds, equals(2));
      expect(finished, isFalse);

      timer.tick(const Duration(seconds: 2));
      expect(timer.duration.inSeconds, equals(0));
      expect(finished, isTrue);
      expect(timer.running, isFalse);
    });

    test('TimerWidget renders countdown digits and progress bar', () {
      final timer = TimerWidget(
        duration: const Duration(seconds: 5),
        running: true,
      );
      final buffer = Buffer.blank(10, 2);

      timer.render(buffer, const Rect(0, 0, 10, 2));

      // Digits centered on row 0: '00:05'
      final row0 = List.generate(
        10,
        (x) => buffer.getCell(x, 0)!.char,
      ).join('');
      expect(row0, contains('00:05'));

      // Progress bar on row 1: full initial progress should render filled bar
      final row1 = List.generate(
        10,
        (x) => buffer.getCell(x, 1)!.char,
      ).join('');
      expect(row1, equals('██████████'));
    });
  });
}
