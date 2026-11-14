import 'dart:math';
import 'dart:typed_data';

import 'package:checks/checks.dart';
import 'package:clock/clock.dart';
import 'package:termui/termui.dart';
import 'package:termui_cast_client_core/src/session_slot.dart';
import 'package:termui_cast_client_core/termui_cast_client_core.dart';
import 'package:termui_cast_protocol/termui_cast_protocol.dart';
import 'package:test/test.dart';

import 'support/fake_three_way_ws_harness.dart';

void main() {
  _defineThemeSettingsTests();
  _defineColorResolverTests();
  _defineCompositorCursorAndSelectionTests();
  _defineMultiViewerAndReloadTests();
  _defineWorkspaceChromeThemeTests();
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

      final parsed = TerminalThemeSettings.fromJson(json);
      check(parsed).equals(settings);
    });

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
        });
        check(parsed.appearanceMode).equals(ThemeAppearanceMode.system);
        check(parsed.darkThemeId).equals('termui_dark');
        check(parsed.minimumContrast).equals(1.0);
        check(parsed.boldIsBright).isFalse();
        check(parsed.faintOpacity).equals(0.25);
        check(parsed.smartCursorColor).isTrue();
        check(parsed.customOverrides.isEmpty).isTrue();

        final fromNan = TerminalThemeSettings.fromJson({
          'minimumContrast': double.nan,
          'faintOpacity': double.infinity,
        });
        check(fromNan.minimumContrast).equals(1.0);
        check(fromNan.faintOpacity).equals(0.55);

        final copiedNan =
            const TerminalThemeSettings(
              minimumContrast: 4.5,
              faintOpacity: 0.7,
            ).copyWith(
              minimumContrast: double.nan,
              faintOpacity: double.negativeInfinity,
            );
        check(copiedNan.minimumContrast).equals(4.5);
        check(copiedNan.faintOpacity).equals(0.7);
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
  });
}

SessionSlot _makeTestSlot([String id = 'theme-slot']) => SessionSlot(
  id: SessionId(id),
  clock: const Clock(),
  requestTimeout: const Duration(seconds: 2),
  onVisualChange: () {},
  onClearSelection: () {},
  onRequestKeyframe: () {},
  onRequestScrollback: (_) {},
);

void _defineCompositorCursorAndSelectionTests() {
  group('WorkspaceBufferCompositor.compose themed cursor & selection', () {
    test(
      'paints themed normal selection, legible Light Mode box selection (>= 4.5:1), and wide CJK themed block cursor',
      () {
        final slot = _makeTestSlot();
        addTearDown(slot.dispose);

        final src = Buffer.blank(8, 2)
          ..writeString(0, 0, 'Hello', Style.empty)
          ..writeString(2, 1, '漢字', Style.empty);
        slot.buffer = src;
        slot.cursor = const CursorState(
          x: 3,
          y: 1,
          visible: true,
          shape: .steadyBlock,
        );

        const lightTheme = TerminalColorTheme.termuiLight;
        final normalSelected = WorkspaceBufferCompositor.compose(
          slot: slot,
          viewportCols: 8,
          viewportRows: 2,
          hoveredLink: null,
          activeSelection: const TerminalSelection(
            anchor: Point<int>(0, 0),
            focus: Point<int>(3, 0),
          ),
          theme: lightTheme,
          themeSettings: const TerminalThemeSettings(appearanceMode: .light),
          nowMs: 0,
          hiddenClipboardNotice: null,
        );
        check(
          normalSelected.getBackground(1, 0),
        ).equals(lightTheme.selectionBackground.argb);
        check(
          normalSelected.getForeground(1, 0),
        ).equals(lightTheme.selectionForeground!.argb);

        for (final col in const [2, 3]) {
          check(
            normalSelected.getBackground(col, 1),
          ).equals(lightTheme.cursorColor.argb);
          check(
            normalSelected.getForeground(col, 1),
          ).equals(lightTheme.cursorTextColor.argb);
          check(
            normalSelected.getModifiers(col, 1) & Modifier.reverse,
          ).equals(0);
        }

        final boxSelected = WorkspaceBufferCompositor.compose(
          slot: slot,
          viewportCols: 8,
          viewportRows: 2,
          hoveredLink: null,
          activeSelection: const TerminalSelection(
            anchor: Point<int>(0, 0),
            focus: Point<int>(2, 0),
            mode: .box,
          ),
          theme: lightTheme,
          themeSettings: const TerminalThemeSettings(appearanceMode: .light),
          nowMs: 0,
          hiddenClipboardNotice: null,
        );
        final boxFg = Color.argb(boxSelected.getForeground(1, 0));
        final boxBg = Color.argb(boxSelected.getBackground(1, 0));
        check(
          TerminalContrast.contrastRatio(boxFg, boxBg),
        ).isGreaterOrEqual(4.5);
      },
    );

    test(
      'keeps block cursor high-contrast (>= 4.5:1) on SGR 7 reverse-video status bars across gruvbox_dark, solarized_dark, and termui_light',
      () {
        final slot = _makeTestSlot('reverse-cursor-slot');
        addTearDown(slot.dispose);
        slot.buffer = _buildReverseStatusBarBuffer();

        for (final preset in const [
          TerminalColorTheme.gruvboxDark,
          TerminalColorTheme.solarizedDark,
          TerminalColorTheme.termuiLight,
        ]) {
          _assertReverseStatusBarCursorContrast(slot, preset);
        }
      },
    );

    test(
      'overriding only ANSI 4 on termui_dark preserves default Modifier.reverse cursor',
      () {
        final slot = _makeTestSlot('override-ansi4-slot');
        addTearDown(slot.dispose);
        slot.buffer = Buffer.blank(4, 1)..writeString(0, 0, 'dir', Style.empty);
        slot.cursor = const CursorState(
          x: 0,
          y: 0,
          visible: true,
          shape: .steadyBlock,
        );

        final settings = TerminalThemeSettings(
          appearanceMode: .dark,
          darkThemeId: 'termui_dark',
          customOverrides: const CustomPaletteOverrides().withAnsiSlot(
            4,
            const Color(0x33, 0x99, 0xFF),
          ),
        );
        final activeTheme = settings.resolveActiveTheme(.dark);
        final out = WorkspaceBufferCompositor.compose(
          slot: slot,
          viewportCols: 4,
          viewportRows: 1,
          hoveredLink: null,
          activeSelection: null,
          theme: activeTheme,
          themeSettings: settings,
          nowMs: 0,
          hiddenClipboardNotice: null,
        );
        check(
          out.getModifiers(0, 0) & Modifier.reverse,
        ).equals(Modifier.reverse);
        check(out.getBackground(0, 0)).equals(0);
      },
    );
  });
}

Buffer _buildReverseStatusBarBuffer() {
  final src = Buffer.blank(10, 2);
  for (var x = 0; x < 10; x++) {
    src.setAttributes(
      x,
      0,
      char: 'S',
      fg: 0,
      bg: 0,
      modifiers: Modifier.reverse,
    );
    src.setAttributes(
      x,
      1,
      char: 'B',
      fg: const Color.ansi(4).argb,
      bg: 0,
      modifiers: Modifier.reverse,
    );
  }
  return src;
}

void _assertReverseStatusBarCursorContrast(
  SessionSlot slot,
  TerminalColorTheme preset,
) {
  for (final (row, barBg) in [(0, preset.foreground), (1, preset.ansi[4])]) {
    slot.cursor = CursorState(x: 2, y: row, visible: true, shape: .steadyBlock);
    final composed = WorkspaceBufferCompositor.compose(
      slot: slot,
      viewportCols: 10,
      viewportRows: 2,
      hoveredLink: null,
      activeSelection: null,
      theme: preset,
      themeSettings: const TerminalThemeSettings(),
      nowMs: 0,
      hiddenClipboardNotice: null,
    );
    final curFg = Color.argb(composed.getForeground(2, row));
    final curBg = Color.argb(composed.getBackground(2, row));
    check(composed.getModifiers(2, row) & Modifier.reverse).equals(0);
    check(TerminalContrast.contrastRatio(curFg, curBg)).isGreaterOrEqual(4.5);
    check(TerminalContrast.contrastRatio(curBg, barBg)).isGreaterOrEqual(4.5);
  }
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

void _defineMultiViewerAndReloadTests() {
  group('Multi-viewer theme isolation & storage reload', () {
    test(
      'two simultaneous viewers on one CasterService render solarized_light vs high_contrast_dark across live deltas and ScrollbackChunkFrame rows',
      () async {
        final harness = FakeThreeWayWsHarness();
        addTearDown(harness.dispose);

        final caster = await harness.startCaster(
          id: 'shared-pty',
          title: 'zsh',
          initialCols: 32,
          initialRows: 5,
        );
        final viewerLight = await harness.connectViewer(
          initialViewportCols: 32,
          initialViewportRows: 5,
          resizeDebounce: Duration.zero,
        );
        final viewerHcDark = await harness.connectViewer(
          initialViewportCols: 32,
          initialViewportRows: 5,
          resizeDebounce: Duration.zero,
        );

        viewerLight.viewModel.updateThemeSettings(
          const TerminalThemeSettings(
            appearanceMode: .light,
            lightThemeId: 'solarized_light',
          ),
        );
        viewerHcDark.viewModel.updateThemeSettings(
          const TerminalThemeSettings(
            appearanceMode: .dark,
            darkThemeId: 'high_contrast_dark',
            minimumContrast: 7.0,
          ),
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

        final liveLight = viewerLight.viewModel.composeActiveBufferWithCursor();
        final liveHc = viewerHcDark.viewModel.composeActiveBufferWithCursor();
        final liveRow = _findLiveRedRow(liveLight);

        check(liveRow).isGreaterOrEqual(0);
        check(
          liveLight.getForeground(0, liveRow),
        ).equals(TerminalColorTheme.solarizedLight.ansi[1].argb);
        check(
          liveHc.getForeground(0, liveRow),
        ).not((it) => it.equals(liveLight.getForeground(0, liveRow)));
        check(
          TerminalContrast.contrastRatio(
            Color.argb(liveHc.getForeground(0, liveRow)),
            TerminalColorTheme.highContrastDark.background,
          ),
        ).isGreaterOrEqual(7.0);

        check(liveLight.getForeground(9, liveRow)).equals(0xFF123456);
        check(liveHc.getForeground(9, liveRow)).equals(0xFF123456);

        check(viewerLight.viewModel.scrollActiveBy(5)).isTrue();
        check(viewerHcDark.viewModel.scrollActiveBy(5)).isTrue();
        await _pumpRelay();

        final sbLight = viewerLight.viewModel.composeActiveBufferWithCursor();
        final sbHc = viewerHcDark.viewModel.composeActiveBufferWithCursor();
        check(sbLight.getCharacter(0, 0)).equals('h');
        check(sbHc.getCharacter(0, 0)).equals('h');
        check(
          sbLight.getForeground(0, 0),
        ).equals(TerminalColorTheme.solarizedLight.ansi[4].argb);
        check(
          sbHc.getForeground(0, 0),
        ).equals(TerminalColorTheme.highContrastDark.ansi[4].argb);
      },
    );

    test(
      'CastWorkspaceViewModel caches activeTerminalTheme/colorResolver and reloads settings via onReloadSettings',
      () async {
        final harness = FakeThreeWayWsHarness();
        addTearDown(harness.dispose);
        final unbacked = await harness.connectViewer(autoConnect: false);
        check(unbacked.viewModel.canReloadSettings).isFalse();
        check(unbacked.viewModel.reloadSettingsFromStorage()).isFalse();

        const stored = CastWorkspaceSettings(
          dockPosition: .left,
          copyOnSelect: false,
          debugOverlayEnabled: true,
          f12ShortcutsEnabled: true,
          themeSettings: TerminalThemeSettings(
            appearanceMode: .dark,
            darkThemeId: 'catppuccin_mocha',
          ),
        );
        final transport = WsClientTransport(
          token: harness.token,
          channelFactory: harness.openClientChannel,
        );
        final repo = CastClientRepository(transport: transport);
        final vm = CastWorkspaceViewModel(
          repository: repo,
          onReloadSettings: () => stored,
        );
        addTearDown(() async {
          await vm.dispose();
          await repo.dispose();
        });

        check(vm.canReloadSettings).isTrue();
        final firstResolver = vm.colorResolver;
        check(vm.colorResolver).identicalTo(firstResolver);

        check(vm.reloadSettingsFromStorage()).isTrue();
        check(vm.dockPosition).equals(DockPosition.left);
        check(vm.copyOnSelect).isFalse();
        check(vm.debugOverlayEnabled).isTrue();
        check(vm.f12ShortcutsEnabled).isTrue();
        check(vm.activeTerminalTheme.id).equals('catppuccin_mocha');
        check(vm.clipboardNotice).equals('Settings reloaded from storage');
        check(vm.colorResolver).not((it) => it.identicalTo(firstResolver));
      },
    );
  });
}

void _defineWorkspaceChromeThemeTests() {
  group('WorkspaceChromeTheme presets and scope', () {
    test('returns exact defaultDark constants for termuiDark preset', () {
      final chrome = WorkspaceChromeTheme.fromTerminalTheme(
        TerminalColorTheme.termuiDark,
      );
      check(chrome).identicalTo(WorkspaceChromeTheme.defaultDark);
    });

    test('derives coordinated styles and barrierColor for light preset', () {
      final chrome = WorkspaceChromeTheme.fromTerminalTheme(
        TerminalColorTheme.termuiLight,
      );
      check(chrome.barrierColor).isNotNull();
      check(
        chrome.activeTabStyle.background,
      ).equals(TerminalColorTheme.termuiLight.cursorColor);
    });
  });
}
