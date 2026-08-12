import 'package:test/test.dart';
import 'package:termui/termui.dart';

void main() {
  group('Buffer Grapheme Splitting', () {
    test(
      'Overwriting a wide grapheme trailing sentinel clears previous cell attributes',
      () {
        final buffer = Buffer(10, 10);
        final redBg = 0xFFFF0000;
        final blueBg = 0xFF0000FF;

        // Write a wide grapheme (e.g. 🍎 which is wide) at x=2, y=2
        buffer.setAttributes(2, 2, char: '🍎', bg: redBg);

        expect(buffer.getCharacter(2, 2), '🍎');
        expect(buffer.getBackground(2, 2), redBg);
        expect(buffer.getCharacter(3, 2), ''); // sentinel
        expect(buffer.getBackground(3, 2), redBg); // copied to sentinel

        // Overwrite the sentinel cell at x=3, y=2 with a normal character 'A' and blue bg
        buffer.setAttributes(3, 2, char: 'A', bg: blueBg);

        // The left side (x=2) should have been cleared to ' ' and attributes reset
        expect(buffer.getCharacter(2, 2), ' ');
        expect(buffer.getBackground(2, 2), 0); // cleared background

        expect(buffer.getCharacter(3, 2), 'A');
        expect(buffer.getBackground(3, 2), blueBg);
      },
    );

    test(
      'Overwriting the start of a wide grapheme clears the trailing sentinel',
      () {
        final buffer = Buffer(10, 10);
        final redBg = 0xFFFF0000;
        final blueBg = 0xFF0000FF;

        buffer.setAttributes(2, 2, char: '🍎', bg: redBg);

        // Overwrite x=2 with 'A' and blue bg
        buffer.setAttributes(2, 2, char: 'A', bg: blueBg);

        // x=2 is 'A', x=3 should be cleared ' ' and attributes reset
        expect(buffer.getCharacter(2, 2), 'A');
        expect(buffer.getBackground(2, 2), blueBg);

        expect(buffer.getCharacter(3, 2), ' ');
        expect(buffer.getBackground(3, 2), 0); // cleared background
      },
    );
  });
}
