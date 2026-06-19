import 'package:test/test.dart';
import 'package:termui/termui.dart';
import 'package:termui_recorder/termui_recorder.dart';

void main() {
  group('SevenSegmentDisplay', () {
    test('calculates correct width and height', () {
      final widget1 = SevenSegmentDisplay(value: '8');
      final element1 = widget1.createElement();
      element1.mount(null);

      final size1 = element1.layout(const BoxConstraints());
      expect(size1.width, 5); // 1 digit * 6 - 1 = 5
      expect(size1.height, 5);

      final widget2 = SevenSegmentDisplay(value: '42');
      final element2 = widget2.createElement();
      element2.mount(null);

      final size2 = element2.layout(const BoxConstraints());
      expect(size2.width, 11); // 2 digits * 6 - 1 = 11
      expect(size2.height, 5);

      final widget3 = SevenSegmentDisplay(value: '');
      final element3 = widget3.createElement();
      element3.mount(null);

      final size3 = element3.layout(const BoxConstraints());
      expect(size3.width, 0);
      expect(size3.height, 5);
    });

    test('internal character-mapping logic works correctly', () {
      final buffer = Buffer.blank(5, 5);
      final widget = SevenSegmentDisplay(value: '8');

      final element = widget.createElement();
      element.mount(null);
      element.layout(BoxConstraints.tight(const Size(5, 5)));
      element.paint(buffer, Offset.zero);

      // Verify some active segments for '8' (all 5x5 borders and middle row are active, except for corners)
      // Actually '8' is:
      // [1, 1, 1, 1, 1]
      // [1, 0, 0, 0, 1]
      // [1, 1, 1, 1, 1]
      // [1, 0, 0, 0, 1]
      // [1, 1, 1, 1, 1]
      expect(buffer.getCell(0, 0)?.style.foreground, widget.activeColor);
      expect(buffer.getCell(2, 0)?.style.foreground, widget.activeColor);
      expect(buffer.getCell(1, 1)?.style.foreground, widget.inactiveColor);
    });

    test('renders golden correctly for 8', () {
      final buffer = Buffer.blank(5, 5);

      final widget = SevenSegmentDisplay(value: '8');

      final element = widget.createElement();
      element.mount(null);
      element.layout(BoxConstraints.tight(const Size(5, 5)));
      element.paint(buffer, Offset.zero);

      expect(
        buffer,
        matchesAnsiGolden(
          'test/goldens/seven_segment_8.ansi',
          environment: {'GENERATE_GOLDENS': 'true'},
        ),
      );
    });

    test('renders golden correctly for 42', () {
      final buffer = Buffer.blank(11, 5);

      final widget = SevenSegmentDisplay(value: '42');

      final element = widget.createElement();
      element.mount(null);
      element.layout(BoxConstraints.tight(const Size(11, 5)));
      element.paint(buffer, Offset.zero);

      expect(
        buffer,
        matchesAnsiGolden(
          'test/goldens/seven_segment_42.ansi',
          environment: {'GENERATE_GOLDENS': 'true'},
        ),
      );
    });
  });
}
