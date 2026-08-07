import 'package:test/test.dart';
import 'package:termui/termui.dart';
import 'package:termui_recorder/termui_recorder.dart';

void main() {
  group('BufferWidget Unit & Integration Tests', () {
    setUp(() {
      FocusManager.instance.setPrimaryFocus(null);
    });

    test('BufferWidget performLayout matches buffer dimensions', () {
      final srcBuffer = Buffer(30, 15);
      final widget = BufferWidget(buffer: srcBuffer);

      final element = widget.createElement();

      final constraints = const BoxConstraints(maxWidth: 80, maxHeight: 24);
      final layoutSize = element.layout(constraints);

      expect(layoutSize.width, equals(30));
      expect(layoutSize.height, equals(15));
    });

    test(
      'BufferWidget performPaint writes character and attribute data directly',
      () {
        final srcBuffer = Buffer(5, 3);
        srcBuffer.setCharacter(1, 1, 'X');
        srcBuffer.setForeground(1, 1, 0xFFFF0000); // Red
        srcBuffer.setBackground(1, 1, 0xFF00FF00); // Green
        srcBuffer.setModifiers(1, 1, Modifier.bold);

        final widget = BufferWidget(buffer: srcBuffer);
        final element = widget.createElement();
        element.layout(const BoxConstraints(maxWidth: 80, maxHeight: 24));

        final targetBuffer = Buffer(20, 10);
        element.paint(targetBuffer, const Offset(3, 2));

        // Check cell at target position (3 + 1, 2 + 1) = (4, 3)
        expect(targetBuffer.getCharacter(4, 3), equals('X'));
        expect(targetBuffer.getForeground(4, 3), equals(0xFFFF0000));
        expect(targetBuffer.getBackground(4, 3), equals(0xFF00FF00));
        expect(targetBuffer.getModifiers(4, 3), equals(Modifier.bold));
      },
    );

    test('BufferWidget respects target buffer clip bounds', () {
      final srcBuffer = Buffer(10, 10);
      for (int y = 0; y < 10; y++) {
        for (int x = 0; x < 10; x++) {
          srcBuffer.setCharacter(x, y, '#');
          srcBuffer.setForeground(x, y, 0xFFFFFFFF);
        }
      }

      final widget = BufferWidget(buffer: srcBuffer);
      final element = widget.createElement();
      element.layout(const BoxConstraints(maxWidth: 80, maxHeight: 24));

      final targetBuffer = Buffer(20, 20);
      targetBuffer.pushClip(const Rect(2, 2, 4, 4));
      element.paint(targetBuffer, Offset.zero);

      // (1, 1) is outside clip (2,2,4,4) -> should be untouched ' '
      expect(targetBuffer.getCharacter(1, 1), equals(' '));
      // (2, 2) is inside clip -> should be '#'
      expect(targetBuffer.getCharacter(2, 2), equals('#'));
      // (6, 6) is outside clip -> should be ' '
      expect(targetBuffer.getCharacter(6, 6), equals(' '));
    });

    test('BufferWidget inside Stack/Positioned golden test', () {
      final buffer = Buffer.blank(30, 10);

      final assetBuffer = Buffer(12, 4);
      assetBuffer.writeString(
        0,
        0,
        '┌──────────┐',
        const Style(foreground: Color(0, 255, 255)),
      );
      assetBuffer.writeString(
        0,
        1,
        '│ ASSET 01 │',
        const Style(foreground: Color(255, 255, 0)),
      );
      assetBuffer.writeString(
        0,
        2,
        '│ READY!   │',
        const Style(foreground: Color(0, 255, 0)),
      );
      assetBuffer.writeString(
        0,
        3,
        '└──────────┘',
        const Style(foreground: Color(0, 255, 255)),
      );

      final appWidget = Stack([
        Positioned(left: 5, top: 2, child: BufferWidget(buffer: assetBuffer)),
      ]);

      final element = appWidget.createElement()..mount(null);
      element.layout(BoxConstraints.tight(const Size(30, 10)));
      element.paint(buffer, Offset.zero);

      expect(
        buffer,
        matchesAnsiGolden('test/goldens/buffer_widget_positioned.ansi'),
      );
    });
  });
}
