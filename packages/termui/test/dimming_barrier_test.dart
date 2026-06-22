import 'package:test/test.dart';
import 'package:termui/termui.dart';

void main() {
  group('ColorMutator', () {
    test('dims white to grey', () {
      final mutator = ColorMutator(0.5);
      const white = Color(255, 255, 255);
      final grey = mutator.dim(white);

      expect(grey.r, equals(127));
      expect(grey.g, equals(127));
      expect(grey.b, equals(127));
    });
  });

  group('DimmingBarrier', () {
    test('dimming barrier modifies right half of the buffer', () {
      final buffer = Buffer(10, 1);
      final whiteStyle = Style(
        foreground: Color(255, 255, 255),
        background: Color(255, 255, 255),
      );

      // Write a string
      buffer.writeString(0, 0, '0123456789', whiteStyle);

      // Verify written
      for (var i = 0; i < 10; i++) {
        expect(buffer.getCell(i, 0)!.char, equals(i.toString()));
        expect(
          buffer.getCell(i, 0)!.style.foreground,
          equals(Color(255, 255, 255)),
        );
      }

      // Create dimmer effect directly for the right half
      final effect = DimmerEffect(scalar: 0.5);
      effect.applyEffect(buffer, const Rect(5, 0, 5, 1));

      // Check left half untouched
      for (var i = 0; i < 5; i++) {
        final cell = buffer.getCell(i, 0)!;
        expect(cell.char, equals(i.toString()));
        expect(cell.style.foreground, equals(Color(255, 255, 255)));
        expect(cell.style.background, equals(Color(255, 255, 255)));
      }

      // Check right half dimmed
      for (var i = 5; i < 10; i++) {
        final cell = buffer.getCell(i, 0)!;
        expect(cell.char, equals(i.toString()));
        expect(cell.style.foreground!.r, equals(127));
        expect(cell.style.foreground!.g, equals(127));
        expect(cell.style.foreground!.b, equals(127));
        expect(cell.style.background!.r, equals(127));
        expect(cell.style.background!.g, equals(127));
        expect(cell.style.background!.b, equals(127));
      }
    });

    test('Screenshot/ASCII test generates valid escape sequences', () {
      final renderer = Renderer(10, 1, mode: RenderingMode.inline);
      final buffer = Buffer(10, 1);
      final whiteStyle = Style(
        foreground: Color(255, 255, 255),
        background: Color(255, 255, 255),
      );
      buffer.writeString(0, 0, '0123456789', whiteStyle);

      final effect = DimmerEffect(scalar: 0.5);
      effect.applyEffect(buffer, const Rect(5, 0, 5, 1));

      final out = StringBuffer();
      renderer.render(buffer, out);

      final ansi = out.toString();
      print('Golden Snapshot ASCII:\n${ansi.replaceAll('\x1b', '\\x1b')}');
      expect(ansi, isNotEmpty);
      expect(ansi.contains('38;2;127;127;127'), isTrue);
      expect(ansi.contains('48;2;127;127;127'), isTrue);
    });
  });
}
