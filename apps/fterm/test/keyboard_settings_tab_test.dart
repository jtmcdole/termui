import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:fterm/src/audio/fterm_audio_controller.dart';
import 'package:fterm/src/font_loader.dart';
import 'package:fterm/src/input/key_chord.dart';
import 'package:fterm/src/launch_config.dart';
import 'package:fterm/src/settings_storage.dart';
import 'package:fterm/src/ui/fterm_overlays.dart';
import 'package:fterm/src/ui/fterm_shell_scaffold.dart';
import 'package:fterm/src/ui/settings/fterm_keyboard_settings_tab.dart';
import 'package:fterm/src/workspace/fterm_workspace_controller.dart';
import 'package:fterm/src/workspace/local_host_driver.dart';
import 'package:material_ui/material_ui.dart';
import 'package:termui/terminal/event.dart' as ev;
import 'package:termui_cast_client_core/termui_cast_client_core.dart';
import 'package:termui_flutter/termui_flutter.dart';

final class _MemStorage implements SettingsStorage {
  final _items = <String, String>{};
  @override
  String? getItem(String key) => _items[key];
  @override
  void setItem(String key, String value) => _items[key] = value;
}

final class _NoLocalHost implements LocalHostDriver {
  @override
  bool get isSupported => false;
  @override
  Future<LocalPaneHost> openShell(LocalShellConfig c) =>
      throw UnimplementedError();
  @override
  Future<void> dispose() async {}
}

FtermWorkspaceController _newWorkspace() {
  final storage = _MemStorage();
  saveStoredPreferences(storage, const FtermPreferences(audioMuted: true));
  final transport = WsClientTransport(
    serverUri: CastLaunchConfig.defaultServerUri,
    token: '',
  );
  return FtermWorkspaceController(
    launchConfig: CastLaunchConfig(promptForConnection: true),
    repository: CastClientRepository(transport: transport),
    localHostDriver: _NoLocalHost(),
    audioController: FtermAudioController(
      initialMuted: true,
      requireUserGesture: false,
    ),
    storage: storage,
    resizeDebounce: .zero,
    shaderController: TerminalShaderController(
      backendFactory: (_) => const DisabledShaderBackend(),
    ),
  );
}

Finder _k(String key) => find.byKey(ValueKey(key));
bool _navSelected(WidgetTester t, String key) {
  final semantics = t.widget<Semantics>(
    find.ancestor(of: _k(key), matching: find.byType(Semantics)).first,
  );
  return semantics.properties.selected == true;
}

Future<void> _tap(WidgetTester t, String key) async {
  await t.ensureVisible(_k(key));
  await t.tap(_k(key));
  await t.pump();
}

Future<void> _pumpSettings(
  WidgetTester tester,
  FtermWorkspaceController ws, {
  TargetPlatform platform = .linux,
  bool isWeb = false,
  bool openKeyboard = false,
}) async {
  await tester.binding.setSurfaceSize(const Size(960, 760));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  ws.setOverlay(.settings);
  await tester.pumpWidget(
    MaterialApp(
      home: FtermShellScaffold(
        workspace: ws,
        onOpenUrl: (_) {},
        platformOverride: platform,
        isWebOverride: isWeb,
      ),
    ),
  );
  await tester.pump();
  if (openKeyboard) await _tap(tester, 'settings-tab-keyboard');
}

Future<void> _disposeWs(WidgetTester t, FtermWorkspaceController ws) async {
  await t.runAsync(ws.dispose);
  await t.pumpWidget(const SizedBox.shrink());
}

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    await loadCastFonts();
  });

  group('Settings tabs and FtermKeyboardSettingsTab', () {
    testWidgets('defaults to Interface, switches to Keyboard, keeps actions', (
      tester,
    ) async {
      final ws = _newWorkspace();
      await _pumpSettings(tester, ws);

      expect(_navSelected(tester, 'settings-tab-interface'), isTrue);
      expect(_k('settings-auto-hide-single'), findsOneWidget);
      expect(_k('settings-f12-toggle'), findsNothing);
      expect(_k('settings-open-about'), findsOneWidget);

      await _tap(tester, 'settings-tab-keyboard');
      expect(_navSelected(tester, 'settings-tab-keyboard'), isTrue);
      expect(_k('settings-auto-hide-single'), findsNothing);
      for (final id in const [
        'settings-meta-mode-auto',
        'settings-f12-toggle',
        'settings-open-about',
        'settings-open-connect',
        'settings-prefs-menu',
      ]) {
        expect(_k(id), findsOneWidget);
      }
      await _disposeWs(tester, ws);
    });

    testWidgets('Meta policy chips update preference and runtime summary', (
      tester,
    ) async {
      final ws = _newWorkspace();
      String summary() =>
          tester.widget<Text>(_k('settings-meta-mode-summary')).data!;

      await _pumpSettings(tester, ws, openKeyboard: true);
      expect(ws.preferences.metaKeyMode, FtermMetaKeyMode.auto);
      expect(summary(), contains('Auto (Desktop)'));

      await _tap(tester, 'settings-meta-mode-passThrough');
      expect(ws.preferences.metaKeyMode, FtermMetaKeyMode.passThrough);
      expect(summary(), contains('OS'));

      await _tap(tester, 'settings-meta-mode-kitty');
      expect(ws.preferences.metaKeyMode, FtermMetaKeyMode.kitty);
      expect(summary(), contains('Kitty'));

      await _tap(tester, 'settings-meta-mode-auto');
      await _pumpSettings(tester, ws, platform: .macOS);
      expect(summary(), contains('Auto (macOS)'));

      await _pumpSettings(tester, ws, isWeb: true);
      expect(summary(), contains('Auto (Web)'));
      await _tap(tester, 'settings-meta-mode-passThrough');
      expect(summary(), contains('browser'));
      await _disposeWs(tester, ws);
    });

    testWidgets('toggles macosOptionAsAlt and f12ShortcutsEnabled', (
      tester,
    ) async {
      final ws = _newWorkspace();
      await _pumpSettings(tester, ws, openKeyboard: true);

      expect(ws.preferences.macosOptionAsAlt, isFalse);
      await _tap(tester, 'settings-macos-option-as-alt');
      expect(ws.preferences.macosOptionAsAlt, isTrue);

      final initialF12 = ws.workspaceSettings.f12ShortcutsEnabled;
      await _tap(tester, 'settings-f12-toggle');
      expect(ws.workspaceSettings.f12ShortcutsEnabled, !initialF12);
      await _disposeWs(tester, ws);
    });

    testWidgets(
      'adds aliases & batch chords, shows labels, removes chip, clears all',
      (tester) async {
        final ws = _newWorkspace();
        await _pumpSettings(tester, ws, platform: .macOS, openKeyboard: true);
        expect(_k('settings-passthrough-clear-all'), findsNothing);

        final input = _k('settings-passthrough-input');
        await tester.enterText(input, 'Cmd+K');
        await tester.testTextInput.receiveAction(.done);
        await tester.pump();
        expect(
          ws.preferences.passthroughShortcuts,
          equals([KeyChord.tryParse('Meta+K')!]),
        );
        final metaK = _k('settings-passthrough-chip-Meta+K');
        expect(
          find.descendant(of: metaK, matching: find.text('Cmd+K')),
          findsOneWidget,
        );

        await tester.enterText(input, 'Ctrl+Shift+I, Alt+F4');
        await _tap(tester, 'settings-passthrough-add');
        expect(
          ws.preferences.passthroughShortcuts,
          equals([
            KeyChord.tryParse('Meta+K')!,
            KeyChord.tryParse('Ctrl+Shift+I')!,
            KeyChord.tryParse('Alt+F4')!,
          ]),
        );
        final altF4 = _k('settings-passthrough-chip-Alt+F4');
        expect(
          find.descendant(of: altF4, matching: find.text('Option+F4')),
          findsOneWidget,
        );

        final ctrlShiftI = _k('settings-passthrough-chip-Ctrl+Shift+I');
        tester.widget<InputChip>(ctrlShiftI).onDeleted!();
        await tester.pump();
        expect(ctrlShiftI, findsNothing);
        expect(
          ws.preferences.passthroughShortcuts,
          equals([KeyChord.tryParse('Meta+K')!, KeyChord.tryParse('Alt+F4')!]),
        );

        await _tap(tester, 'settings-passthrough-clear-all');
        expect(ws.preferences.passthroughShortcuts, isEmpty);
        expect(_k('settings-passthrough-clear-all'), findsNothing);
        await _disposeWs(tester, ws);
      },
    );

    testWidgets(
      'rejects empty, unsafe, invalid, and duplicate input without mutating',
      (tester) async {
        final ws = _newWorkspace();
        await _pumpSettings(tester, ws, openKeyboard: true);
        final input = _k('settings-passthrough-input');
        final err = _k('settings-passthrough-error');

        for (final bad in const ['', 'a', 'Shift+A', 'Ctrl+Bogus']) {
          await tester.enterText(input, bad);
          await _tap(tester, 'settings-passthrough-add');
          expect(err, findsOneWidget, reason: 'input="$bad"');
          expect(ws.preferences.passthroughShortcuts, isEmpty);
        }

        await tester.enterText(input, 'Ctrl+Shift+I');
        await tester.pump();
        expect(err, findsNothing);
        await _tap(tester, 'settings-passthrough-add');
        expect(err, findsNothing);
        expect(
          ws.preferences.passthroughShortcuts,
          equals([KeyChord.tryParse('Ctrl+Shift+I')!]),
        );

        await tester.enterText(input, 'ctrl+shift+i');
        await _tap(tester, 'settings-passthrough-add');
        expect(err, findsOneWidget);
        expect(
          ws.preferences.passthroughShortcuts,
          equals([KeyChord.tryParse('Ctrl+Shift+I')!]),
        );

        await _tap(tester, 'settings-passthrough-clear-all');
        expect(err, findsNothing);
        await _disposeWs(tester, ws);
      },
    );

    testWidgets(
      'Record chord captures chord, ignores modifier, rejects bare key, cancels on Esc',
      (tester) async {
        final ws = _newWorkspace();
        await _pumpSettings(tester, ws, openKeyboard: true);
        final prompt = find.text('Press a chord (Esc to cancel)…');
        final err = _k('settings-passthrough-error');

        Future<void> press(List<LogicalKeyboardKey> keys) async {
          for (final k in keys) {
            await tester.sendKeyDownEvent(k);
          }
          for (final k in keys.reversed) {
            await tester.sendKeyUpEvent(k);
          }
          await tester.pump();
        }

        await _tap(tester, 'settings-passthrough-record');
        expect(prompt, findsOneWidget);

        await press(const [.shiftLeft]);
        expect(prompt, findsOneWidget);
        expect(ws.preferences.passthroughShortcuts, isEmpty);

        await press(const [.keyA]);
        expect(err, findsOneWidget);

        await press(const [.controlLeft, .shiftLeft, .keyI]);
        expect(prompt, findsNothing);
        expect(err, findsNothing);
        expect(
          ws.preferences.passthroughShortcuts,
          equals([
            KeyChord(
              key: .keyI,
              modifiers: const {ev.Modifier.control, ev.Modifier.shift},
            ),
          ]),
        );

        await _tap(tester, 'settings-passthrough-record');
        await press(const [.controlLeft, .shiftLeft, .keyI]);
        expect(prompt, findsNothing);
        expect(err, findsOneWidget);

        await _tap(tester, 'settings-passthrough-record');
        await press(const [.escape]);
        expect(prompt, findsNothing);
        expect(ws.activeOverlay, FtermOverlay.settings);
        expect(_k('fterm-overlay-settings'), findsOneWidget);

        await _tap(tester, 'settings-passthrough-record');
        await _tap(tester, 'settings-passthrough-record');
        expect(prompt, findsNothing);
        await _disposeWs(tester, ws);
      },
    );

    testWidgets('presets adapt to platform/web and disappear once added', (
      tester,
    ) async {
      final ws = _newWorkspace();
      final palette = FtermOverlayPalette.fromTerminalTheme(
        ws.activeTerminalTheme,
      );
      Future<void> pumpTab(TargetPlatform platform, bool isWeb) async {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SingleChildScrollView(
                child: FtermKeyboardSettingsTab(
                  workspace: ws,
                  palette: palette,
                  isWeb: isWeb,
                  platformOverride: platform,
                ),
              ),
            ),
          ),
        );
        await tester.pump();
      }

      await pumpTab(.macOS, true);
      expect(_k('settings-passthrough-preset-Meta+Equal'), findsOneWidget);
      expect(_k('settings-passthrough-preset-Alt+Meta+I'), findsOneWidget);
      await _tap(tester, 'settings-passthrough-preset-Meta+Equal');
      expect(_k('settings-passthrough-preset-Meta+Equal'), findsNothing);
      await _tap(tester, 'settings-passthrough-preset-Alt+Meta+I');
      expect(find.text('Quick-add presets'), findsNothing);

      ws.updatePreferences(
        ws.preferences.copyWith(passthroughShortcuts: const []),
      );
      await pumpTab(.linux, true);
      expect(_k('settings-passthrough-preset-Ctrl+Shift+I'), findsOneWidget);
      expect(_k('settings-passthrough-preset-Alt+ArrowLeft'), findsOneWidget);

      await pumpTab(.windows, false);
      expect(_k('settings-passthrough-preset-Alt+F4'), findsOneWidget);
      expect(_k('settings-passthrough-preset-Alt+Space'), findsOneWidget);

      await pumpTab(.linux, false);
      expect(_k('settings-passthrough-preset-Alt+F4'), findsOneWidget);
      expect(_k('settings-passthrough-preset-Ctrl+Shift+I'), findsOneWidget);
      await _disposeWs(tester, ws);
    });

    testWidgets('colliding chord shows collision hint while still storing it', (
      tester,
    ) async {
      final ws = _newWorkspace();
      await _pumpSettings(tester, ws, openKeyboard: true);
      final hint = _k('settings-passthrough-collision-hint');
      expect(hint, findsNothing);

      await tester.enterText(_k('settings-passthrough-input'), r'Ctrl+\');
      await _tap(tester, 'settings-passthrough-add');
      expect(
        ws.preferences.passthroughShortcuts,
        contains(KeyChord.tryParse(r'Ctrl+\')!),
      );
      expect(hint, findsOneWidget);

      final chip = _k('settings-passthrough-chip-Ctrl+Backslash');
      tester.widget<InputChip>(chip).onDeleted!();
      await tester.pump();
      expect(hint, findsNothing);
      await _disposeWs(tester, ws);
    });
  });
}
