import 'dart:typed_data';

import 'package:checks/checks.dart';
import 'package:termui/termui.dart';
import 'package:termui_cast_client_core/termui_cast_client_core.dart';
import 'package:test/test.dart';

import 'support/fake_three_way_ws_harness.dart';

void main() {
  _defineThemeSettingsTests();
  _defineColorResolverTests();
  _defineMultiViewerThemeTests();
}

void _defineThemeSettingsTests() {
  group('TerminalThemeSettings JSON serialization & defaults', () {
    test('round-trips default settings to/from JSON cleanly', () {
      const settings = TerminalThemeSettings();
      final json = settings.toJson();
      check(json['appearanceMode']).equals('system');
      check(json['darkThemeId']).equals('termui_dark');
      check(json['lightThemeId']).equals('termui_light');
      check(json['minimumContrast']).equals(1.0);
      check(json['boldIsBright']).equals(false);
      check(json['faintOpacity']).equals(0.55);
      check(json['smartCursorColor']).equals(true);
      check(json['backgroundOpacity']).equals(1.0);
      check(json['animationMode']).equals('focused');
      check(json.containsKey('backgroundShaderChain')).isFalse();
      check(json.containsKey('foregroundShaderChain')).isFalse();

      final parsed = TerminalThemeSettings.fromJson(json);
      check(parsed).equals(settings);
    });

    test(
      'round-trips shader chains, backgroundOpacity, and animationMode cleanly',
      () {
        final settings = const TerminalThemeSettings().copyWith(
          backgroundOpacity: 0.72,
          backgroundShaderChain: const <String>['wallpaper_wave'],
          foregroundShaderChain: const <String>[
            'crt_lottes',
            '~/.config/fterm/shaders/cursor_trail.glsl',
          ],
          animationMode: ShaderAnimationMode.onActivity,
        );
        final json = settings.toJson();
        check(json['backgroundOpacity']).equals(0.72);
        check(json['animationMode']).equals('on_activity');
        check(
          json['backgroundShaderChain'],
        ).isA<List<String>>().deepEquals(const <String>['wallpaper_wave']);
        check(json['foregroundShaderChain']).isA<List<String>>().deepEquals(
          const <String>[
            'crt_lottes',
            '~/.config/fterm/shaders/cursor_trail.glsl',
          ],
        );

        final parsed = TerminalThemeSettings.fromJson(json);
        check(parsed).equals(settings);
        check(parsed.hashCode).equals(settings.hashCode);

        // Legacy JSON missing the new fields preserves backward-compatible defaults.
        final legacyParsed = TerminalThemeSettings.fromJson(<String, Object?>{
          'appearanceMode': 'dark',
          'darkThemeId': 'gruvbox_dark',
        });
        check(legacyParsed.backgroundOpacity).equals(1.0);
        check(legacyParsed.backgroundShaderChain).isEmpty();
        check(legacyParsed.foregroundShaderChain).isEmpty();
        check(legacyParsed.animationMode).equals(ShaderAnimationMode.focused);
      },
    );

    test(
      'recovers safely from invalid, corrupt, or NaN/infinite values without throwing',
      () {
        final parsed = TerminalThemeSettings.fromJson({
          'appearanceMode': 'unknown_mode',
          'darkThemeId': '',
          'minimumContrast': 'invalid',
          'boldIsBright': 123,
          'faintOpacity': -5.0,
          'smartCursorColor': 'nope',
          'customOverrides': 'not a map',
          'backgroundOpacity': 3.5,
          'backgroundShaderChain': <Object?>['  ', 42, ' wallpaper_wave '],
          'foregroundShaderChain': 'not a list',
          'animationMode': 'invalid_mode',
        });
        check(parsed.appearanceMode).equals(ThemeAppearanceMode.system);
        check(parsed.darkThemeId).equals('termui_dark');
        check(parsed.minimumContrast).equals(1.0);
        check(parsed.boldIsBright).isFalse();
        check(parsed.faintOpacity).equals(0.25);
        check(parsed.smartCursorColor).isTrue();
        check(parsed.customOverrides.isEmpty).isTrue();
        check(parsed.backgroundOpacity).equals(1.0);
        check(
          parsed.backgroundShaderChain,
        ).deepEquals(const <String>['wallpaper_wave']);
        check(parsed.foregroundShaderChain).isEmpty();
        check(parsed.animationMode).equals(ShaderAnimationMode.focused);

        final fromNan = TerminalThemeSettings.fromJson({
          'minimumContrast': double.nan,
          'faintOpacity': double.infinity,
          'backgroundOpacity': double.nan,
          'animationMode': 'staticOnly',
        });
        check(fromNan.minimumContrast).equals(1.0);
        check(fromNan.faintOpacity).equals(0.55);
        check(fromNan.backgroundOpacity).equals(1.0);
        check(fromNan.animationMode).equals(ShaderAnimationMode.staticOnly);

        final copiedNan =
            const TerminalThemeSettings(
              minimumContrast: 4.5,
              faintOpacity: 0.7,
              backgroundOpacity: 0.65,
            ).copyWith(
              minimumContrast: double.nan,
              faintOpacity: double.negativeInfinity,
              backgroundOpacity: double.infinity,
            );
        check(copiedNan.minimumContrast).equals(4.5);
        check(copiedNan.faintOpacity).equals(0.7);
        check(copiedNan.backgroundOpacity).equals(0.65);
      },
    );

    test('parses customOverrides and resolves active theme correctly', () {
      final overrides = const CustomPaletteOverrides().withAnsiSlot(
        4,
        const Color(0x12, 0x34, 0x56),
      );
      final settings = TerminalThemeSettings(
        appearanceMode: .dark,
        customOverrides: overrides,
      );
      final resolved = settings.resolveActiveTheme(.dark);
      check(resolved.ansi[4]).equals(const Color(0x12, 0x34, 0x56));
    });
  });

  group('CastWorkspaceSettings themeSettings integration', () {
    test('preserves themeSettings across copyWith and serialization', () {
      final customSettings = const CastWorkspaceSettings().copyWith(
        themeSettings: const TerminalThemeSettings(
          appearanceMode: .light,
          minimumContrast: 4.5,
        ),
      );
      final jsonStr = customSettings.toJsonString();
      final parsed = CastWorkspaceSettings.fromJsonString(jsonStr);
      check(
        parsed.themeSettings.appearanceMode,
      ).equals(ThemeAppearanceMode.light);
      check(parsed.themeSettings.minimumContrast).equals(4.5);
    });

    test(
      'backward compatible with legacy v1 settings without themeSettings',
      () {
        const legacyJson = '{"dockPosition":"left","copyOnSelect":false}';
        final parsed = CastWorkspaceSettings.fromJsonString(legacyJson);
        check(parsed.dockPosition).equals(DockPosition.left);
        check(parsed.copyOnSelect).isFalse();
        check(
          parsed.themeSettings.appearanceMode,
        ).equals(ThemeAppearanceMode.system);
      },
    );
  });
}

void _defineColorResolverTests() {
  group('TerminalColorResolver color remapping and contrast', () {
    test('leaves fg == 0 and bg == 0 untouched', () {
      final resolver = TerminalColorResolver(
        theme: TerminalColorTheme.termuiDark,
        settings: const TerminalThemeSettings(),
      );
      final (fg, bg) = resolver.resolveCellColors(
        rawFg: 0,
        rawBg: 0,
        modifiers: Modifier.none,
        grapheme: 'A',
      );
      check(fg).equals(0);
      check(bg).equals(0);
    });

    test(
      'leaves 24-bit truecolor untouched even with high minimumContrast and reverse video',
      () {
        final resolver = TerminalColorResolver(
          theme: TerminalColorTheme.termuiDark,
          settings: const TerminalThemeSettings(minimumContrast: 7.0),
        );
        const truecolorBlue = 0xFF0000AA;
        final (fg, bg) = resolver.resolveCellColors(
          rawFg: truecolorBlue,
          rawBg: 0,
          modifiers: Modifier.none,
          grapheme: 'A',
        );
        check(fg).equals(truecolorBlue);
        check(bg).equals(0);

        final (revFg, revBg) = resolver.resolveCellColors(
          rawFg: truecolorBlue,
          rawBg: 0xFF112233,
          modifiers: Modifier.reverse,
          grapheme: 'A',
        );
        check(revFg).equals(truecolorBlue);
        check(revBg).equals(0xFF112233);
      },
    );

    test('remaps ANSI indexed color to theme palette slot', () {
      final resolver = TerminalColorResolver(
        theme: TerminalColorTheme.solarizedLight,
        settings: const TerminalThemeSettings(),
      );
      final rawAnsi4 = const Color.ansi(4).argb;
      final (fg, bg) = resolver.resolveCellColors(
        rawFg: rawAnsi4,
        rawBg: 0,
        modifiers: Modifier.none,
        grapheme: 'A',
      );
      check(fg).equals(TerminalColorTheme.solarizedLight.ansi[4].argb);
      check(bg).equals(0);
    });

    test(
      'remaps normal ANSI 0..7 to bright ANSI 8..15 when boldIsBright and bold modifier active',
      () {
        final resolver = TerminalColorResolver(
          theme: TerminalColorTheme.termuiDark,
          settings: const TerminalThemeSettings(boldIsBright: true),
        );
        final rawAnsi4 = const Color.ansi(4).argb;
        final (fg, bg) = resolver.resolveCellColors(
          rawFg: rawAnsi4,
          rawBg: 0,
          modifiers: Modifier.bold,
          grapheme: 'A',
        );
        check(fg).equals(TerminalColorTheme.termuiDark.ansi[12].argb);
        check(bg).equals(0);
      },
    );

    test(
      'enforces minimum contrast via precomputed LUT, explicit bg cache, and Modifier.reverse',
      () {
        final hcResolver = TerminalColorResolver(
          theme: TerminalColorTheme.highContrastDark,
          settings: const TerminalThemeSettings(minimumContrast: 7.0),
        );
        final rawAnsi0 = const Color.ansi(0).argb;
        final (fg, bg) = hcResolver.resolveCellColors(
          rawFg: rawAnsi0,
          rawBg: 0,
          modifiers: Modifier.none,
          grapheme: 'A',
        );
        final contrast = TerminalContrast.contrastRatio(
          Color.argb(fg),
          TerminalColorTheme.highContrastDark.background,
        );
        check(contrast).isGreaterOrEqual(7.0);
        check(bg).equals(0);

        final gruvboxResolver = TerminalColorResolver(
          theme: TerminalColorTheme.gruvboxDark,
          settings: const TerminalThemeSettings(minimumContrast: 4.5),
        );
        final (gruvFg, gruvBg) = gruvboxResolver.resolveCellColors(
          rawFg: rawAnsi0,
          rawBg: 0,
          modifiers: Modifier.none,
          grapheme: 'A',
        );
        check(gruvBg).equals(0);
        check(
          TerminalContrast.contrastRatio(
            Color.argb(gruvFg),
            TerminalColorTheme.gruvboxDark.background,
          ),
        ).isGreaterOrEqual(4.5);

        final (spoilerFg, spoilerBg) = gruvboxResolver.resolveCellColors(
          rawFg: rawAnsi0,
          rawBg: rawAnsi0,
          modifiers: Modifier.none,
          grapheme: 'A',
        );
        check(spoilerFg).equals(spoilerBg);

        final lightResolver = TerminalColorResolver(
          theme: TerminalColorTheme.termuiLight,
          settings: const TerminalThemeSettings(minimumContrast: 7.0),
        );
        final (revFg, revBg) = lightResolver.resolveCellColors(
          rawFg: 0,
          rawBg: const Color.ansi(7).argb,
          modifiers: Modifier.reverse,
          grapheme: 'A',
        );
        check(revFg).equals(0);
        check(
          TerminalContrast.contrastRatio(
            Color.argb(revBg),
            TerminalColorTheme.termuiLight.foreground,
          ),
        ).isGreaterOrEqual(7.0);

        final (revFgCached, revBgCached) = lightResolver.resolveCellColors(
          rawFg: 0,
          rawBg: const Color.ansi(7).argb,
          modifiers: Modifier.reverse,
          grapheme: 'B',
        );
        check(revFgCached).equals(revFg);
        check(revBgCached).equals(revBg);
      },
    );

    test('skips contrast enforcement on block and powerline characters', () {
      final resolver = TerminalColorResolver(
        theme: TerminalColorTheme.termuiDark,
        settings: const TerminalThemeSettings(minimumContrast: 10.0),
      );
      final rawAnsi0 = const Color.ansi(0).argb;
      final (fg, _) = resolver.resolveCellColors(
        rawFg: rawAnsi0,
        rawBg: 0,
        modifiers: Modifier.none,
        grapheme: '█',
      );
      check(fg).equals(TerminalColorTheme.termuiDark.ansi[0].argb);
    });

    test(
      'smartCursorColor inverts text on matching cell color for readability',
      () {
        final resolver = TerminalColorResolver(
          theme: TerminalColorTheme.termuiLight,
          settings: const TerminalThemeSettings(smartCursorColor: true),
        );
        final (cursorCol, textCol) = resolver.resolveCursorColors(
          cellFg: TerminalColorTheme.termuiLight.cursorColor.argb,
          cellBg: 0,
        );
        check(cursorCol).not((it) => it.equals(textCol));
        check(
          TerminalContrast.contrastRatio(
            Color.argb(textCol),
            Color.argb(cursorCol),
          ),
        ).isGreaterOrEqual(4.5);
      },
    );

    test(
      'resolveCellInto matches resolveCellColors across default, ANSI 256, RGB, boldIsBright, reverse, block skip, and explicit-bg contrast',
      () {
        final resolvers = <TerminalColorResolver>[
          TerminalColorResolver(
            theme: TerminalColorTheme.termuiDark,
            settings: const TerminalThemeSettings(),
          ),
          TerminalColorResolver(
            theme: TerminalColorTheme.solarizedDark,
            settings: const TerminalThemeSettings(
              minimumContrast: 4.5,
              boldIsBright: true,
            ),
          ),
          TerminalColorResolver(
            theme: TerminalColorTheme.termuiLight,
            settings: const TerminalThemeSettings(
              minimumContrast: 7.0,
              boldIsBright: true,
            ),
          ),
        ];
        final cases = <(int fg, int bg, int mods, String ch)>[
          (0, 0, Modifier.none, 'A'),
          (const Color.ansi(4).argb, 0, Modifier.none, 'A'),
          (const Color.ansi(4).argb, 0, Modifier.bold, 'B'),
          (
            const Color.ansi(208).argb,
            const Color.ansi(17).argb,
            Modifier.none,
            'C',
          ),
          (0xFF123456, 0, Modifier.bold | Modifier.italic, 'D'),
          (0xFF123456, 0xFF654321, Modifier.reverse, 'E'),
          (0, const Color.ansi(7).argb, Modifier.reverse, 'F'),
          (const Color.ansi(3).argb, 0, Modifier.reverse | Modifier.bold, 'G'),
          (
            const Color.ansi(0).argb,
            const Color.ansi(0).argb,
            Modifier.none,
            '█',
          ),
          (
            const Color.ansi(0).argb,
            const Color.ansi(0).argb,
            Modifier.reverse,
            '▀',
          ),
          (0xFF112233, const Color.ansi(8).argb, Modifier.none, 'H'),
        ];

        final out = Uint32List(9);
        for (final resolver in resolvers) {
          for (final (rawFg, rawBg, mods, ch) in cases) {
            out.fillRange(0, out.length, 0xDEADBEEF);
            final (expectedFg, expectedBg) = resolver.resolveCellColors(
              rawFg: rawFg,
              rawBg: rawBg,
              modifiers: mods,
              grapheme: ch,
            );
            resolver.resolveCellInto(
              rawFg: rawFg,
              rawBg: rawBg,
              modifiers: mods,
              grapheme: ch,
              outAttributes: out,
              attrOffset: 3,
            );
            check(out[0]).equals(0xDEADBEEF);
            check(out[1]).equals(0xDEADBEEF);
            check(out[2]).equals(0xDEADBEEF);
            check(out[3]).equals(expectedFg);
            check(out[4]).equals(expectedBg);
            check(out[5]).equals(mods);
            check(out[6]).equals(0xDEADBEEF);
            check(out[7]).equals(0xDEADBEEF);
            check(out[8]).equals(0xDEADBEEF);
          }
        }
      },
    );

    test(
      'resolveCellInto and resolveCellColors preserve Kitty placeholder imageId fg and resolve indexed bg despite reverse, bold, and high minimumContrast',
      () {
        const theme = TerminalColorTheme.solarizedLight;
        final resolver = TerminalColorResolver(
          theme: theme,
          settings: const TerminalThemeSettings(
            minimumContrast: 7.0,
            boldIsBright: true,
          ),
        );
        const kittyMods =
            Modifier.kittyPlaceholder | Modifier.bold | Modifier.reverse;
        const placeholderChar = '\u{10EEEE}';

        final cases = <(int rawFg, int rawBg, int expectedFg, int expectedBg)>[
          (
            const Color.ansi(42).argb,
            const Color.ansi(4).argb,
            0xFF00_0000 | 42,
            theme.resolveAnsi256(4).argb,
          ),
          (const Color.ansi(3).argb, 0, 0xFF00_0000 | 3, 0),
          (
            0xFF12_3456,
            const Color.ansi(7).argb,
            0xFF12_3456,
            theme.resolveAnsi256(7).argb,
          ),
          (0xFF12_3456, 0xFF65_4321, 0xFF12_3456, 0xFF65_4321),
          (0, const Color.ansi(1).argb, 0, theme.resolveAnsi256(1).argb),
        ];

        final out = Uint32List(6);
        for (final (rawFg, rawBg, expectedFg, expectedBg) in cases) {
          final (fg, bg) = resolver.resolveCellColors(
            rawFg: rawFg,
            rawBg: rawBg,
            modifiers: kittyMods,
            grapheme: placeholderChar,
          );
          check(fg).equals(expectedFg);
          check(bg).equals(expectedBg);

          out.fillRange(0, out.length, 0xDEAD_BEEF);
          resolver.resolveCellInto(
            rawFg: rawFg,
            rawBg: rawBg,
            modifiers: kittyMods,
            grapheme: placeholderChar,
            outAttributes: out,
            attrOffset: 3,
          );
          check(out[0]).equals(0xDEAD_BEEF);
          check(out[1]).equals(0xDEAD_BEEF);
          check(out[2]).equals(0xDEAD_BEEF);
          check(out[3]).equals(expectedFg);
          check(out[4]).equals(expectedBg);
          check(out[5]).equals(kittyMods);
        }
      },
    );
  });
}

Future<void> _pumpRelay() async {
  for (var i = 0; i < 8; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 15));
  }
}

int _findLiveRedRow(Buffer buf) {
  for (var y = 0; y < buf.height; y++) {
    if (buf.getCharacter(0, y) == 'l' && buf.getCharacter(5, y) == 'r') {
      return y;
    }
  }
  return -1;
}

void _defineMultiViewerThemeTests() {
  group('Multi-viewer TerminalColorResolver isolation', () {
    test(
      'two simultaneous RemoteTerminalPorts on one CasterService resolve solarized_light vs high_contrast_dark across live deltas and scrollback rows',
      () async {
        final harness = FakeThreeWayWsHarness();
        addTearDown(harness.dispose);

        final caster = await harness.startCaster(
          id: 'shared-pty',
          title: 'zsh',
          initialCols: 32,
          initialRows: 5,
        );
        final viewerLight = await harness.connectViewer();
        final viewerHcDark = await harness.connectViewer();

        final portLight = viewerLight.repository.openTerminalPort(
          caster.sessionId,
          initialCols: 32,
          initialRows: 5,
        );
        final portHcDark = viewerHcDark.repository.openTerminalPort(
          caster.sessionId,
          initialCols: 32,
          initialRows: 5,
        );
        addTearDown(() async {
          await portLight.dispose();
          await portHcDark.dispose();
        });

        const lightSettings = TerminalThemeSettings(
          appearanceMode: .light,
          lightThemeId: 'solarized_light',
        );
        const hcSettings = TerminalThemeSettings(
          appearanceMode: .dark,
          darkThemeId: 'high_contrast_dark',
          minimumContrast: 7.0,
        );
        final lightResolver = TerminalColorResolver(
          theme: lightSettings.resolveActiveTheme(.light),
          settings: lightSettings,
        );
        final hcResolver = TerminalColorResolver(
          theme: hcSettings.resolveActiveTheme(.dark),
          settings: hcSettings,
        );

        await _pumpRelay();

        final historyLines = [
          for (var i = 0; i < 12; i++)
            '\x1b[34mhist-${'$i'.padLeft(2, '0')}\x1b[0m',
        ].join('\r\n');
        caster.pty.emitRawAnsi(
          '\x1b[2J\x1b[H$historyLines\r\n'
          '\x1b[31mlive-red\x1b[0m \x1b[38;2;18;52;86mtrue\x1b[0m',
        );
        await _pumpRelay();

        final liveRow = _findLiveRedRow(portLight.buffer);
        check(liveRow).isGreaterOrEqual(0);

        final (lightFg, _) = lightResolver.resolveCellColors(
          rawFg: portLight.buffer.getForeground(0, liveRow),
          rawBg: portLight.buffer.getBackground(0, liveRow),
          modifiers: portLight.buffer.getModifiers(0, liveRow),
          grapheme: portLight.buffer.getCharacter(0, liveRow),
        );
        final (hcFg, _) = hcResolver.resolveCellColors(
          rawFg: portHcDark.buffer.getForeground(0, liveRow),
          rawBg: portHcDark.buffer.getBackground(0, liveRow),
          modifiers: portHcDark.buffer.getModifiers(0, liveRow),
          grapheme: portHcDark.buffer.getCharacter(0, liveRow),
        );
        check(lightFg).equals(TerminalColorTheme.solarizedLight.ansi[1].argb);
        check(hcFg).not((it) => it.equals(lightFg));
        check(
          TerminalContrast.contrastRatio(
            Color.argb(hcFg),
            TerminalColorTheme.highContrastDark.background,
          ),
        ).isGreaterOrEqual(7.0);

        final (lightTrueFg, _) = lightResolver.resolveCellColors(
          rawFg: portLight.buffer.getForeground(9, liveRow),
          rawBg: portLight.buffer.getBackground(9, liveRow),
          modifiers: portLight.buffer.getModifiers(9, liveRow),
          grapheme: portLight.buffer.getCharacter(9, liveRow),
        );
        final (hcTrueFg, _) = hcResolver.resolveCellColors(
          rawFg: portHcDark.buffer.getForeground(9, liveRow),
          rawBg: portHcDark.buffer.getBackground(9, liveRow),
          modifiers: portHcDark.buffer.getModifiers(9, liveRow),
          grapheme: portHcDark.buffer.getCharacter(9, liveRow),
        );
        check(lightTrueFg).equals(0xFF123456);
        check(hcTrueFg).equals(0xFF123456);

        // Fetch primary scrollback rows and resolve their ANSI 4 colors per viewer theme.
        final win = portLight.scrollbackWindow;
        check(win.totalLines).isGreaterThan(0);
        portLight.readScrollbackSlice(0, win.totalLines);
        portHcDark.readScrollbackSlice(0, win.totalLines);
        await _pumpRelay();

        final sbLightRow = portLight.scrollbackCache.rowAt(0);
        final sbHcRow = portHcDark.scrollbackCache.rowAt(0);
        check(sbLightRow).isNotNull();
        check(sbHcRow).isNotNull();
        check(sbLightRow!.characters[0]).equals('h');
        check(sbHcRow!.characters[0]).equals('h');
        final (sbLightFg, _) = lightResolver.resolveCellColors(
          rawFg: sbLightRow.attributes[0],
          rawBg: sbLightRow.attributes[1],
          modifiers: sbLightRow.attributes[2],
          grapheme: sbLightRow.characters[0],
        );
        final (sbHcFg, _) = hcResolver.resolveCellColors(
          rawFg: sbHcRow.attributes[0],
          rawBg: sbHcRow.attributes[1],
          modifiers: sbHcRow.attributes[2],
          grapheme: sbHcRow.characters[0],
        );
        check(sbLightFg).equals(TerminalColorTheme.solarizedLight.ansi[4].argb);
        check(sbHcFg).equals(TerminalColorTheme.highContrastDark.ansi[4].argb);
      },
    );
  });
}
