import 'package:termui/termui.dart';
import 'package:test/test.dart';

void main() {
  _defineColorAnsiTests();
  _defineCompositorAndDimmerTests();
  _defineAnsiRoundTripTests();
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

void _defineCompositorAndDimmerTests() {
  group('Compositor, blendColor, and DimmerEffect with Color.ansi', () {
    test('preserves Color.ansi across blendColor and Compositor', () {
      final blue = const Color.ansi(4).argb;
      final bg = const Color.ansi(0).argb;
      expect(blendColor(blue, 0), equals(blue));
      expect(blendColor(0, blue), equals(blue));
      expect(blendColor(blue, bg), equals(blue));

      final layer = Buffer.blank(4, 1)
        ..writeString(
          0,
          0,
          'dir ',
          const Style(foreground: Color.ansi(4), background: Color.ansi(0)),
        );
      final target = Buffer.blank(4, 1);
      Compositor().composite(
        target: target,
        layers: [LayeredBuffer(buffer: layer, x: 0, y: 0)],
      );
      expect(target.getForeground(0, 0), equals(blue));
      expect(target.getBackground(0, 0), equals(bg));
    });

    test('blends translucent overlay over Color.ansi via legacyVga', () {
      final translucentWhite = const Color.argb(0x80FFFFFF).argb;
      final ansiBlack = const Color.ansi(0).argb;
      final blended = blendColor(translucentWhite, ansiBlack);
      expect(blended.isAnsiIndexed, isFalse);
      expect(blended.a, equals(255));
      expect(blended.r, greaterThan(100));
    });

    test(
      'DimmerEffect resolves Color.ansi and supports light barrierColor',
      () {
        final buf = Buffer.blank(2, 1)
          ..writeString(
            0,
            0,
            'A',
            const Style(foreground: Color.ansi(4), background: Color.ansi(15)),
          );
        const DimmerEffect(
          scalar: 0.5,
        ).applyEffect(buf, const Rect(0, 0, 2, 1));
        expect(buf.getForeground(0, 0).isAnsiIndexed, isFalse);
        expect(buf.getForeground(0, 0).b, equals(85));
        expect(buf.getBackground(0, 0).r, equals(127));

        final lightBuf = Buffer.blank(1, 1);
        const DimmerEffect(
          scalar: 0.5,
          barrierColor: Color(0, 0, 0),
          defaultForeground: Color(0x65, 0x7B, 0x83),
          defaultBackground: Color(0xFD, 0xF6, 0xE3),
        ).applyEffect(lightBuf, const Rect(0, 0, 1, 1));
        expect(lightBuf.getBackground(0, 0).r, equals(127));
        expect(lightBuf.getForeground(0, 0).r, equals(51));
      },
    );
  });
}

void _defineAnsiRoundTripTests() {
  group('Buffer ANSI & Renderer round-trip with Color.ansi', () {
    test(
      'toAnsiString and fromAnsi preserve basic, bright, 256, and ul colors',
      () {
        final src = Buffer.blank(4, 1)
          ..writeString(
            0,
            0,
            'A',
            const Style(foreground: Color.ansi(4), background: Color.ansi(0)),
          )
          ..writeString(
            1,
            0,
            'B',
            const Style(
              foreground: Color.ansi(12),
              background: Color.ansi(9),
              underlineColor: Color.ansi(202),
              underlineStyle: .single,
            ),
          )
          ..writeString(
            2,
            0,
            'C',
            const Style(
              foreground: Color.ansi(220),
              background: Color.ansi(235),
            ),
          );

        final ansi = src.toAnsiString();
        expect(ansi, contains('\x1b[34;40m'));
        expect(ansi, contains('94'));
        expect(ansi, contains('101'));
        expect(ansi, contains('58:5:202m'));
        expect(ansi, contains('38;5;220;48;5;235m'));

        final parsed = BufferAnsiSerialization.fromAnsi(
          ansi,
          width: 4,
          height: 1,
        );
        expect(parsed.getForeground(0, 0), equals(const Color.ansi(4).argb));
        expect(parsed.getBackground(0, 0), equals(const Color.ansi(0).argb));
        expect(parsed.getForeground(1, 0), equals(const Color.ansi(12).argb));
        expect(parsed.getBackground(1, 0), equals(const Color.ansi(9).argb));
        expect(
          parsed.getUnderlineColor(1, 0),
          equals(const Color.ansi(202).argb),
        );
        expect(parsed.getForeground(2, 0), equals(const Color.ansi(220).argb));
        expect(parsed.getBackground(2, 0), equals(const Color.ansi(235).argb));
      },
    );

    test('Renderer emits compact ANSI palette SGR sequences', () {
      final renderer = Renderer(3, 1);
      final back = Buffer.blank(3, 1)
        ..writeString(
          0,
          0,
          'X',
          const Style(
            foreground: Color.ansi(4),
            background: Color.ansi(10),
            underlineColor: Color.ansi(196),
            underlineStyle: .single,
          ),
        );
      final out = StringBuffer();
      renderer.render(back, out);
      final emitted = out.toString();
      expect(emitted, contains('34;102'));
      expect(emitted, contains('\x1b[58:5:196m'));
    });

    test('fromAnsi ignores out-of-range 256-color indices without masking', () {
      final parsed = BufferAnsiSerialization.fromAnsi(
        '\x1b[38;5;300;48;5;-1;58:5:256;38:5:-5;1mA\x1b[0m',
        width: 2,
        height: 1,
      );
      expect(parsed.getForeground(0, 0), equals(0));
      expect(parsed.getBackground(0, 0), equals(0));
      expect(parsed.getUnderlineColor(0, 0), equals(0));
      expect(parsed.getModifiers(0, 0) & Modifier.bold, equals(Modifier.bold));
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
