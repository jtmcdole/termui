import 'package:termui/termui.dart';
import 'package:test/test.dart';

void main() {
  _defineColorAnsiTests();
  _definePaletteAndContrastTests();
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

void _expectAnsiSlotsMeetRatio(
  TerminalColorTheme theme,
  double minRatio, {
  required int skipSlot,
}) {
  for (var i = 0; i < 16; i++) {
    if (i == skipSlot) continue;
    final ratio = TerminalContrast.contrastRatio(
      theme.resolveAnsi256(i),
      theme.background,
    );
    expect(ratio, greaterThanOrEqualTo(minRatio));
  }
}

void _definePaletteAndContrastTests() {
  group('TerminalColorTheme & TerminalContrast', () {
    test('all 8 presets have 16 ANSI colors and lookup by id works', () {
      expect(TerminalColorTheme.presets.length, equals(8));
      for (final preset in TerminalColorTheme.presets) {
        expect(preset.ansi.length, equals(16));
        expect(TerminalColorTheme.byId(preset.id), equals(preset));
      }
      expect(TerminalColorTheme.byId('unknown_id'), isNull);
    });

    test(
      'default termuiDark ANSI 4 blue has >= 4.5:1 contrast on background',
      () {
        const dark = TerminalColorTheme.termuiDark;
        final ratio = TerminalContrast.contrastRatio(
          dark.resolveAnsi256(4),
          dark.background,
        );
        expect(ratio, greaterThanOrEqualTo(4.5));
      },
    );

    test(
      'highContrast presets meet WCAG AAA (>= 7.0) on all fg ANSI slots',
      () {
        _expectAnsiSlotsMeetRatio(
          TerminalColorTheme.highContrastDark,
          7.0,
          skipSlot: 0,
        );
        _expectAnsiSlotsMeetRatio(
          TerminalColorTheme.highContrastLight,
          7.0,
          skipSlot: 15,
        );
      },
    );

    test(
      'enforceMinimumContrast reaches AA (4.5) and AAA (7.0) while preserving hue',
      () {
        const darkBg = Color(0x14, 0x17, 0x1F);
        const darkBlue = Color(0x00, 0x00, 0x87); // 256-color index 18
        final aa = TerminalContrast.enforceMinimumContrast(
          darkBlue,
          darkBg,
          minRatio: 4.5,
        );
        expect(
          TerminalContrast.contrastRatio(aa, darkBg),
          greaterThanOrEqualTo(4.5),
        );
        expect(aa.b, greaterThan(aa.r));

        const lightBg = Color(0xFD, 0xF6, 0xE3);
        const brightYellow = Color(0xFF, 0xFF, 0x55);
        final aaa = TerminalContrast.enforceMinimumContrast(
          brightYellow,
          lightBg,
          minRatio: 7.0,
        );
        expect(
          TerminalContrast.contrastRatio(aaa, lightBg),
          greaterThanOrEqualTo(7.0),
        );
      },
    );

    test(
      'enforceMinimumContrast adjusts theme-bg collisions unless hasExplicitBackground is true',
      () {
        const gruvbox = TerminalColorTheme.gruvboxDark;
        expect(gruvbox.ansi[0], equals(gruvbox.background));

        // Implicit default background: colliding ANSI slot 0 IS adjusted.
        final adjusted = TerminalContrast.enforceMinimumContrast(
          gruvbox.ansi[0],
          gruvbox.background,
          minRatio: 4.5,
        );
        expect(
          TerminalContrast.contrastRatio(adjusted, gruvbox.background),
          greaterThanOrEqualTo(4.5),
        );

        // Explicit background: intentional fg == bg spoiler text is preserved.
        final preserved = TerminalContrast.enforceMinimumContrast(
          gruvbox.ansi[0],
          gruvbox.background,
          minRatio: 4.5,
          hasExplicitBackground: true,
        );
        expect(preserved, equals(gruvbox.ansi[0]));
      },
    );

    test('CustomPaletteOverrides round-trips JSON and applies to themes', () {
      expect(CustomPaletteOverrides.parseHexRgb('+112233'), isNull);
      expect(CustomPaletteOverrides.parseHexRgb('-112233'), isNull);
      expect(CustomPaletteOverrides.parseHexRgb('#+12345'), isNull);
      expect(CustomPaletteOverrides.parseHexRgb('#-12345'), isNull);

      final overrides = const CustomPaletteOverrides()
          .withAnsiSlot(4, const Color(0x66, 0xAA, 0xFF))
          .copyWith(background: const Color(0x10, 0x12, 0x18));
      final roundTripped = CustomPaletteOverrides.fromJson(overrides.toJson());
      expect(roundTripped, equals(overrides));

      final customized = TerminalColorTheme.termuiDark.withOverrides(overrides);
      expect(customized.background, equals(const Color(0x10, 0x12, 0x18)));
      expect(
        customized.resolveAnsi256(4),
        equals(const Color(0x66, 0xAA, 0xFF)),
      );
      expect(() => customized.ansi[0] = Colors.red, throwsUnsupportedError);
    });
  });
}
