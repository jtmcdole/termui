import 'package:test/test.dart';
import 'package:termui/termui.dart';

void main() {
  group('Buffer Bounding Box Limited Copying (Issue #87)', () {
    test(
      'Off-screen DimmerEffect with bounding box limiting does not wrap rows',
      () {
        final buffer = Buffer(80, 24);
        // Pre-fill buffer with 'A' and non-zero colors
        for (var y = 0; y < 24; y++) {
          for (var x = 0; x < 80; x++) {
            buffer.setCell(x, y, 'A', 0xFFFFFFFF, 0x00000000, 0);
          }
        }

        // Apply effect at off-screen bounds (x=80..120, y=10..15)
        const offscreenBounds = Rect(80, 10, 40, 5);
        const effect = DimmerEffect(scalar: 0.5);
        effect.applyEffect(buffer, offscreenBounds);

        // Verify Row 11, Column 0 was NOT modified (remains 0xFFFFFFFF, not dimmed)
        expect(buffer.getForeground(0, 11), equals(0xFFFFFFFF));
        expect(buffer.getForeground(0, 10), equals(0xFFFFFFFF));
      },
    );

    test(
      'Off-screen DecoratedBox background fill limits copies to bounding box',
      () {
        final buffer = Buffer(80, 24);
        const box = DecoratedBox(
          decoration: BoxDecoration(backgroundColor: Color(255, 0, 0)),
          child: SizedBox(width: 40, height: 5),
        );

        final element = box.createElement();
        element.layout(const BoxConstraints());

        // Paint at off-screen offset (80, 10)
        element.paint(buffer, const Offset(80, 10));

        // Row 11, Column 0 must not be filled with red background
        expect(buffer.getBackground(0, 11), equals(0));
        expect(buffer.getBackground(0, 10), equals(0));
      },
    );

    test(
      'CanvasElement bounding box calculation clips off-screen rendering',
      () {
        final buffer = Buffer(80, 24);
        final canvas = Canvas(40, 10, renderMode: CanvasRenderMode.density);
        canvas.fillBox(0, 0, 40, 10); // Fill entire canvas

        final element = canvas.createElement();
        element.layout(const BoxConstraints(maxWidth: 40, maxHeight: 10));

        // Paint canvas off-screen at x=80, y=5
        element.paint(buffer, const Offset(80, 5));

        // Row 6, Column 0 should remain empty space
        expect(buffer.getCharacter(0, 6), equals(' '));
        expect(buffer.getCharacter(0, 5), equals(' '));
      },
    );

    test('Buffer writeString with off-screen offset clips gracefully', () {
      final buffer = Buffer(80, 24);

      // Write string starting at x=80 (off-screen)
      buffer.writeString(
        80,
        10,
        'Hello World',
        const Style(foreground: Colors.red),
      );

      // Column 0 on line 11 must be empty space and transparent
      expect(buffer.getCharacter(0, 11), equals(' '));
      expect(buffer.getForeground(0, 11), equals(0));
    });

    test('Grid bounding box calculation clips off-screen rendering', () {
      final buffer = Buffer(80, 24);
      final grid = Grid([
        [
          const GridCell('X', Style(foreground: Colors.green)),
          const GridCell('Y', Style(foreground: Colors.green)),
        ],
        [
          const GridCell('Z', Style(foreground: Colors.green)),
          const GridCell('W', Style(foreground: Colors.green)),
        ],
      ]);

      final element = grid.createElement();
      element.layout(const BoxConstraints(maxWidth: 10, maxHeight: 10));

      // Paint grid off-screen at x=80, y=5
      element.paint(buffer, const Offset(80, 5));

      // Row 6, Column 0 should remain empty space
      expect(buffer.getCharacter(0, 6), equals(' '));
      expect(buffer.getCharacter(0, 5), equals(' '));
    });
  });
}
