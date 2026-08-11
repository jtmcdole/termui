import 'package:test/test.dart';
import 'package:termui/termui.dart';

void main() {
  group('Compositor Glass / Transparent Background', () {
    test(
      'merges cell with foreground over a background without overwriting bg',
      () {
        final target = Buffer(5, 5);
        final layer = Buffer(5, 5);

        // Fill target with red background and empty characters
        target.fillAttributes(char: ' ', bg: Colors.red.argb);

        // Layer: cell at 2,2 has a 'X' with green foreground, and no background (0)
        layer.setAttributes(
          2,
          2,
          char: 'X',
          fg: Colors.green.argb,
          bg: 0,
          modifiers: 0,
        );

        final compositor = Compositor();
        compositor.composite(
          target: target,
          layers: [LayeredBuffer(buffer: layer, x: 0, y: 0, zIndex: 1)],
        );

        // At 2,2 we should have 'X', green foreground, red background
        expect(target.getCharacter(2, 2), 'X');
        expect(target.getForeground(2, 2), Colors.green.argb);
        expect(target.getBackground(2, 2), Colors.red.argb);

        // At 0,0 we should still have ' ', 0 foreground, red background
        expect(target.getCharacter(0, 0), ' ');
        expect(target.getBackground(0, 0), Colors.red.argb);
      },
    );

    test('alpha blending of colors with top character priority', () {
      final target = Buffer(5, 5);

      final layer0 = Buffer(5, 5); // Bottom
      final layer1 = Buffer(5, 5); // Top

      // Bottom layer: 'A' with yellow foreground (opaque) and blue background (opaque)
      layer0.setAttributes(
        2,
        2,
        char: 'A',
        fg: const Color.argb(0xFFFFFF00).argb, // Yellow
        bg: const Color.argb(0xFF0000FF).argb, // Blue
        modifiers: 0,
      );

      // Top layer: '-' with transparent foreground and semi-transparent red background
      layer1.setAttributes(
        2,
        2,
        char: '-',
        fg: 0, // Transparent (0x00000000)
        bg: const Color.argb(0x80FF0000).argb, // 50% Red (128 alpha)
        modifiers: 0,
      );

      final compositor = Compositor();
      compositor.composite(
        target: target,
        layers: [
          LayeredBuffer(buffer: layer0, x: 0, y: 0, zIndex: 0),
          LayeredBuffer(buffer: layer1, x: 0, y: 0, zIndex: 1),
        ],
      );

      // The top character '-' should win.
      expect(target.getCharacter(2, 2), '-');

      // Foreground: Transparent (top) over Yellow (bottom) = Yellow
      expect(target.getForeground(2, 2), const Color.argb(0xFFFFFF00).argb);

      // Background: 50% Red (top) over Blue (bottom)
      // Red: 0xFF * 0.5 = 127
      // Blue: 0xFF * 0.5 = 127
      // Expected ARGB: 0xFF7F007F (255, 127, 0, 127)
      expect(target.getBackground(2, 2), const Color.argb(0xFF80007F).argb);
    });
  });
}
