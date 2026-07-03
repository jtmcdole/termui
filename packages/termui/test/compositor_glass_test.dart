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
  });
}
