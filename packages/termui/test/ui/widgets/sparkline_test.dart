import 'package:test/test.dart';
import 'package:termui/termui.dart';
import 'package:termui_recorder/termui_recorder.dart';

void main() {
  group('Sparkline', () {
    test('renders braille sparkline bottomToTop', () {
      final buffer = Buffer.blank(
        10,
        3,
      ); // 10 width (20 braille columns), 3 height (12 braille rows)
      final widget = ConstrainedBox(
        constraints: BoxConstraints.tightFor(width: 10, height: 3),
        child: Sparkline(
          List.generate(20, (i) => i.toDouble()), // data from 0 to 19
          max: 20,
          direction: ProgressDirection.bottomToTop,
          barType: ProgressBarType.braille,
        ),
      );
      final element = widget.createElement();
      element.mount(null);
      element.layout(BoxConstraints.tight(const Size(10, 3)));
      element.paint(buffer, Offset.zero);

      expect(
        buffer,
        matchesAnsiGolden(
          'test/goldens/sparkline_braille_bottomToTop.ansi',
          environment: {'GENERATE_GOLDENS': 'true'},
        ),
      );
    });

    test('renders sparkline with colorBuilder gradients', () {
      final buffer = Buffer.blank(10, 3);
      final widget = ConstrainedBox(
        constraints: BoxConstraints.tightFor(width: 10, height: 3),
        child: Sparkline(
          List.generate(20, (i) => i.toDouble()), // data from 0 to 19
          max: 20,
          direction: ProgressDirection.bottomToTop,
          barType: ProgressBarType.braille,
          colorBuilder: (index, values) => (
            fg: [
              (color: const Color(255, 0, 0), stop: 0.0), // red bottom
              (color: const Color(0, 0, 255), stop: 1.0), // blue top
            ],
            bg: null,
          ),
        ),
      );
      final element = widget.createElement();
      element.mount(null);
      element.layout(BoxConstraints.tight(const Size(10, 3)));
      element.paint(buffer, Offset.zero);

      expect(
        buffer,
        matchesAnsiGolden(
          'test/goldens/sparkline_braille_bottomToTop_gradient.ansi',
          environment: {'GENERATE_GOLDENS': 'true'},
        ),
      );
    });
  });
}
