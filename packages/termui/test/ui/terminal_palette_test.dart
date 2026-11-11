import 'package:termui/termui.dart';
import 'package:test/test.dart';

void main() {
  _defineColorAnsiTests();
}

void _defineColorAnsiTests() {
  group('Color.ansi', () {
    test('encodes 0..255 into 0x00010000..0x000100FF without transparency', () {
      for (var i = 0; i < 256; i++) {
        final c = Color.ansi(i);
        expect(c.isAnsiIndexed, isTrue);
        expect(c.ansiIndex, equals(i));
        expect(c.isTransparent, isFalse);
        expect(c.argb & 0xFFFFFF00, equals(0x00010000));
      }
      expect(Color.argb(0).isAnsiIndexed, isFalse);
      expect(Color.argb(0).isTransparent, isTrue);
      expect(const Color(0, 0, 170).isAnsiIndexed, isFalse);
      expect(const Color(0, 0, 170).isTransparent, isFalse);
    });

    test('withAlpha(0) never collides with Color.ansi sentinel range', () {
      for (var i = 0; i < 256; i++) {
        final fromRgb = Color(1, 0, i).argb.withAlpha(0);
        expect(fromRgb, equals(0));
        expect(fromRgb.isAnsiIndexed, isFalse);
        expect(fromRgb.isTransparent, isTrue);

        final fromAnsi = Color.ansi(i).argb.withAlpha(0);
        expect(fromAnsi, equals(0));
        expect(fromAnsi.isAnsiIndexed, isFalse);
        expect(fromAnsi.isTransparent, isTrue);
      }
      final translucent = const Color(1, 0, 4).argb.withAlpha(128);
      expect(translucent, equals(0x80010004));
      expect(translucent.isAnsiIndexed, isFalse);
      expect(translucent.a, equals(128));
    });

    test('emits palette SGR codes for foregroundCode and backgroundCode', () {
      expect(const Color.ansi(4).foregroundCode, equals('\x1b[34m'));
      expect(const Color.ansi(12).foregroundCode, equals('\x1b[94m'));
      expect(const Color.ansi(196).foregroundCode, equals('\x1b[38;5;196m'));
      expect(const Color.ansi(1).backgroundCode, equals('\x1b[41m'));
      expect(const Color.ansi(9).backgroundCode, equals('\x1b[101m'));
      expect(const Color.ansi(235).backgroundCode, equals('\x1b[48;5;235m'));
    });
  });
}
