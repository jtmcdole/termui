import 'package:flutter_test/flutter_test.dart';
import 'package:fterm/src/audio/fterm_audio_controller.dart';
import 'package:fterm/src/font_loader.dart';
import 'package:fterm/src/input/key_chord.dart';
import 'package:fterm/src/launch_config.dart';
import 'package:fterm/src/settings_storage.dart';
import 'package:fterm/src/ui/fterm_shell_scaffold.dart';
import 'package:fterm/src/workspace/fterm_workspace_controller.dart';
import 'package:fterm/src/workspace/local_host_driver.dart';
import 'package:material_ui/material_ui.dart';
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
bool _chipSelected(WidgetTester t, String key) =>
    t.widget<ChoiceChip>(_k(key)).selected;

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
    testWidgets('defaults to General, switches to Keyboard, keeps actions', (
      tester,
    ) async {
      final ws = _newWorkspace();
      await _pumpSettings(tester, ws);

      expect(_chipSelected(tester, 'settings-tab-general'), isTrue);
      expect(_k('settings-auto-hide-single'), findsOneWidget);
      expect(_k('settings-f12-toggle'), findsNothing);
      expect(_k('settings-open-about'), findsOneWidget);

      await _tap(tester, 'settings-tab-keyboard');
      expect(_chipSelected(tester, 'settings-tab-keyboard'), isTrue);
      expect(_k('settings-auto-hide-single'), findsNothing);
      for (final id in const [
        'settings-meta-mode-auto',
        'settings-f12-toggle',
        'settings-open-about',
        'settings-open-connect',
        'settings-reload-storage',
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
  });
}
