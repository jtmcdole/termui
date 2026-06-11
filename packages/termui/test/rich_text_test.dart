import 'package:test/test.dart';
import 'package:termui/ui/buffer.dart';
import 'package:termui/ui/layout.dart';
import 'package:termui/ui/style.dart';
import 'package:termui/ui/color.dart';
import 'package:termui/ui/widget_toolkit.dart';
import 'package:termui_recorder/termui_recorder.dart';

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

      expect(
        buffer,
        matchesAnsiGolden(
          'test/goldens/rich_text_label_clipping.ansi',
          environment: {'GENERATE_GOLDENS': 'true'},
        ),
      );
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

      expect(
        buffer,
        matchesAnsiGolden(
          'test/goldens/rich_text_paragraph_wrap.ansi',
          environment: {'GENERATE_GOLDENS': 'true'},
        ),
      );
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

      expect(
        buffer,
        matchesAnsiGolden(
          'test/goldens/timer_widget_rendering.ansi',
          environment: {'GENERATE_GOLDENS': 'true'},
        ),
      );
    });
  });
}
