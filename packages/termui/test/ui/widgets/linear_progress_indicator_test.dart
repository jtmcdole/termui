import 'package:test/test.dart';
import 'package:termui/termui.dart';

import 'package:termui_recorder/termui_recorder.dart';

void main() {
  group('LinearProgressIndicator', () {
    test('renders golden correctly with precision crossAxisFill', () {
      final buffer = Buffer.blank(10, 3);
      final widget = ConstrainedBox(
        constraints: BoxConstraints.tightFor(width: 10, height: 3),
        child: const LinearProgressIndicator(
          0.375, // 3/8
          smooth: true,
          barType: ProgressBarType.braille,
          crossAxisFill: CrossAxisFill.precise,
          direction: ProgressDirection.leftToRight,
        ),
      );
      final element = widget.createElement();
      element.mount(null);
      element.layout(BoxConstraints.tight(const Size(10, 3)));
      element.paint(buffer, Offset.zero);

      expect(
        buffer,
        matchesAnsiGolden(
          'test/goldens/linear_progress_indicator_precise.ansi',
          environment: {'GENERATE_GOLDENS': 'true'},
        ),
      );
    });

    test('renders directions correctly', () {
      final buffer = Buffer.blank(20, 5);
      final widget = Column([
        LinearProgressIndicator(0.5, direction: ProgressDirection.leftToRight),
        LinearProgressIndicator(0.5, direction: ProgressDirection.rightToLeft),
      ]);
      final element = widget.createElement();
      element.mount(null);
      element.layout(BoxConstraints.tight(const Size(20, 5)));
      element.paint(buffer, Offset.zero);

      expect(
        buffer,
        matchesAnsiGolden(
          'test/goldens/linear_progress_indicator_directions.ansi',
          environment: {'GENERATE_GOLDENS': 'true'},
        ),
      );
    });
  });
}
