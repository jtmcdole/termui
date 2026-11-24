import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fterm/src/audio/fterm_audio_controller.dart';
import 'package:fterm/src/font_loader.dart';
import 'package:fterm/src/input/key_chord.dart';
import 'package:fterm/src/launch_config.dart';
import 'package:fterm/src/settings_storage.dart';
import 'package:fterm/src/ui/fterm_keyboard_settings_tab.dart';
import 'package:fterm/src/ui/fterm_overlays.dart';
import 'package:fterm/src/ui/fterm_shell_scaffold.dart';
import 'package:fterm/src/workspace/fterm_workspace_controller.dart';
import 'package:fterm/src/workspace/local_host_driver.dart';
import 'package:material_ui/material_ui.dart';
import 'package:termui/terminal/event.dart' as ev;
import 'package:termui_cast_client_core/termui_cast_client_core.dart';
import 'package:termui_flutter/termui_flutter.dart';

final class _MemorySettingsStorage implements SettingsStorage {
  final Map<String, String> _items = <String, String>{};

  @override
  String? getItem(String key) => _items[key];

  @override
  void setItem(String key, String value) {
    _items[key] = value;
  }
}

final class _UnsupportedLocalHostDriver implements LocalHostDriver {
  @override
  bool get isSupported => false;

  @override
  Future<LocalPaneHost> openShell(LocalShellConfig config) =>
      throw UnimplementedError();

  @override
  Future<void> dispose() async {}
}

({FtermWorkspaceController workspace, _MemorySettingsStorage storage})
_buildWorkspace() {
  final storage = _MemorySettingsStorage();
  saveStoredPreferences(storage, const FtermPreferences(audioMuted: true));
  final transport = WsClientTransport(
    serverUri: CastLaunchConfig.defaultServerUri,
    token: '',
  );
  final repository = CastClientRepository(transport: transport);
  final shaderController = TerminalShaderController(
    backendFactory: (_) => const DisabledShaderBackend(),
  );
  final workspace = FtermWorkspaceController(
    launchConfig: CastLaunchConfig(promptForConnection: true),
    repository: repository,
    localHostDriver: _UnsupportedLocalHostDriver(),
    audioController: FtermAudioController(
      initialMuted: true,
      requireUserGesture: false,
    ),
    storage: storage,
    resizeDebounce: Duration.zero,
    shaderController: shaderController,
  );
  return (workspace: workspace, storage: storage);
}

Future<void> _pumpSettingsShell(
  WidgetTester tester,
  FtermWorkspaceController workspace, {
  TargetPlatform platform = TargetPlatform.linux,
  bool isWeb = false,
}) async {
  await tester.binding.setSurfaceSize(const Size(960, 760));
  addTearDown(() => tester.binding.setSurfaceSize(null));

  workspace.setOverlay(FtermOverlay.settings);
  await tester.pumpWidget(
    MaterialApp(
      home: FtermShellScaffold(
        workspace: workspace,
        onOpenUrl: (_) {},
        platformOverride: platform,
        isWebOverride: isWeb,
      ),
    ),
  );
  await tester.pump();
}

Future<void> _openKeyboardTab(WidgetTester tester) async {
  final tabChip = find.byKey(const ValueKey('settings-tab-keyboard'));
  expect(tabChip, findsOneWidget);
  await tester.tap(tabChip);
  await tester.pump();
}

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    await loadCastFonts();
  });

  group('Settings General | Keyboard tabs and FtermKeyboardSettingsTab', () {
    testWidgets(
      'defaults to General tab, switches to Keyboard tab, and keeps shared bottom actions',
      (tester) async {
        final env = _buildWorkspace();
        await _pumpSettingsShell(tester, env.workspace);

        // General tab is selected by default; General controls are visible,
        // Keyboard controls (including relocated F12 toggle) are hidden.
        final generalChip = tester.widget<ChoiceChip>(
          find.byKey(const ValueKey('settings-tab-general')),
        );
        final keyboardChip = tester.widget<ChoiceChip>(
          find.byKey(const ValueKey('settings-tab-keyboard')),
        );
        expect(generalChip.selected, isTrue);
        expect(keyboardChip.selected, isFalse);
        expect(
          find.byKey(const ValueKey('settings-auto-hide-single')),
          findsOneWidget,
        );
        expect(find.byKey(const ValueKey('settings-f12-toggle')), findsNothing);
        expect(
          find.byKey(const ValueKey('settings-meta-mode-auto')),
          findsNothing,
        );
        expect(
          find.byKey(const ValueKey('settings-open-about')),
          findsOneWidget,
        );

        // Switch to Keyboard tab.
        await _openKeyboardTab(tester);
        expect(
          tester
              .widget<ChoiceChip>(
                find.byKey(const ValueKey('settings-tab-keyboard')),
              )
              .selected,
          isTrue,
        );
        expect(
          find.byKey(const ValueKey('settings-auto-hide-single')),
          findsNothing,
        );
        expect(
          find.byKey(const ValueKey('settings-meta-mode-auto')),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey('settings-f12-toggle')),
          findsOneWidget,
        );
        // Shared bottom actions remain present.
        expect(
          find.byKey(const ValueKey('settings-open-about')),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey('settings-open-connect')),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey('settings-reload-storage')),
          findsOneWidget,
        );

        await tester.runAsync(env.workspace.dispose);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );

    testWidgets(
      'tapping Meta policy chips updates metaKeyMode and dynamic summary text',
      (tester) async {
        final env = _buildWorkspace();
        await _pumpSettingsShell(
          tester,
          env.workspace,
          platform: TargetPlatform.linux,
          isWeb: false,
        );
        await _openKeyboardTab(tester);

        expect(env.workspace.preferences.metaKeyMode, FtermMetaKeyMode.auto);
        final autoSummary = tester
            .widget<Text>(
              find.byKey(const ValueKey('settings-meta-mode-summary')),
            )
            .data!;
        expect(autoSummary.toLowerCase(), contains('kitty'));

        await tester.tap(
          find.byKey(const ValueKey('settings-meta-mode-passThrough')),
        );
        await tester.pump();
        expect(
          env.workspace.preferences.metaKeyMode,
          FtermMetaKeyMode.passThrough,
        );
        final passSummary = tester
            .widget<Text>(
              find.byKey(const ValueKey('settings-meta-mode-summary')),
            )
            .data!;
        expect(passSummary, isNot(equals(autoSummary)));
        expect(passSummary.toLowerCase(), contains('pass'));

        await tester.tap(
          find.byKey(const ValueKey('settings-meta-mode-kitty')),
        );
        await tester.pump();
        expect(env.workspace.preferences.metaKeyMode, FtermMetaKeyMode.kitty);
        final kittySummary = tester
            .widget<Text>(
              find.byKey(const ValueKey('settings-meta-mode-summary')),
            )
            .data!;
        expect(kittySummary, isNot(equals(passSummary)));
        expect(kittySummary.toLowerCase(), contains('kitty'));

        await tester.tap(find.byKey(const ValueKey('settings-meta-mode-auto')));
        await tester.pump();
        expect(env.workspace.preferences.metaKeyMode, FtermMetaKeyMode.auto);

        await tester.runAsync(env.workspace.dispose);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );

    testWidgets(
      'adds single alias and comma-separated chords, displays platform labels, removes a chip, and clears all',
      (tester) async {
        final env = _buildWorkspace();
        await _pumpSettingsShell(
          tester,
          env.workspace,
          platform: TargetPlatform.macOS,
          isWeb: false,
        );
        await _openKeyboardTab(tester);

        expect(
          find.byKey(const ValueKey('settings-passthrough-clear-all')),
          findsNothing,
        );

        final inputFinder = find.byKey(
          const ValueKey('settings-passthrough-input'),
        );
        final addFinder = find.byKey(
          const ValueKey('settings-passthrough-add'),
        );

        // Single alias via Enter submission.
        await tester.enterText(inputFinder, 'Cmd+K');
        await tester.testTextInput.receiveAction(TextInputAction.done);
        await tester.pump();

        expect(
          env.workspace.preferences.passthroughShortcuts,
          equals([KeyChord.tryParse('Meta+K')!]),
        );
        final metaKChip = find.byKey(
          const ValueKey('settings-passthrough-chip-Meta+K'),
        );
        expect(metaKChip, findsOneWidget);
        expect(
          find.descendant(of: metaKChip, matching: find.text('Cmd+K')),
          findsOneWidget,
        );

        // Comma-separated batch via Add button.
        await tester.enterText(inputFinder, 'Ctrl+Shift+I, Alt+F4');
        await tester.tap(addFinder);
        await tester.pump();

        expect(
          env.workspace.preferences.passthroughShortcuts,
          equals([
            KeyChord.tryParse('Meta+K')!,
            KeyChord.tryParse('Ctrl+Shift+I')!,
            KeyChord.tryParse('Alt+F4')!,
          ]),
        );
        final altF4Chip = find.byKey(
          const ValueKey('settings-passthrough-chip-Alt+F4'),
        );
        expect(
          find.descendant(of: altF4Chip, matching: find.text('Option+F4')),
          findsOneWidget,
        );

        // Remove single chip.
        final ctrlShiftIChip = find.byKey(
          const ValueKey('settings-passthrough-chip-Ctrl+Shift+I'),
        );
        tester.widget<InputChip>(ctrlShiftIChip).onDeleted!();
        await tester.pump();
        expect(
          env.workspace.preferences.passthroughShortcuts,
          equals([KeyChord.tryParse('Meta+K')!, KeyChord.tryParse('Alt+F4')!]),
        );
        expect(ctrlShiftIChip, findsNothing);

        // Clear all.
        final clearAllFinder = find.byKey(
          const ValueKey('settings-passthrough-clear-all'),
        );
        expect(clearAllFinder, findsOneWidget);
        await tester.tap(clearAllFinder);
        await tester.pump();

        expect(env.workspace.preferences.passthroughShortcuts, isEmpty);
        expect(clearAllFinder, findsNothing);

        await tester.runAsync(env.workspace.dispose);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );

    testWidgets(
      'surfaces inline error on empty, unsafe, invalid, or duplicate chord input without mutating preferences',
      (tester) async {
        final env = _buildWorkspace();
        await _pumpSettingsShell(tester, env.workspace);
        await _openKeyboardTab(tester);

        final inputFinder = find.byKey(
          const ValueKey('settings-passthrough-input'),
        );
        final addFinder = find.byKey(
          const ValueKey('settings-passthrough-add'),
        );
        final errorFinder = find.byKey(
          const ValueKey('settings-passthrough-error'),
        );

        for (final bad in const ['', 'a', 'Shift+A', 'Ctrl+Bogus']) {
          await tester.enterText(inputFinder, bad);
          await tester.tap(addFinder);
          await tester.pump();
          expect(errorFinder, findsOneWidget, reason: 'input="$bad"');
          expect(
            env.workspace.preferences.passthroughShortcuts,
            isEmpty,
            reason: 'input="$bad" must not mutate preferences',
          );
        }

        // Valid input succeeds and clears inline error.
        await tester.enterText(inputFinder, 'Ctrl+Shift+I');
        await tester.tap(addFinder);
        await tester.pump();
        expect(errorFinder, findsNothing);
        expect(
          env.workspace.preferences.passthroughShortcuts,
          equals([KeyChord.tryParse('Ctrl+Shift+I')!]),
        );

        // Duplicate input surfaces inline error and keeps list unchanged.
        await tester.enterText(inputFinder, 'ctrl+shift+i');
        await tester.tap(addFinder);
        await tester.pump();
        expect(errorFinder, findsOneWidget);
        expect(
          env.workspace.preferences.passthroughShortcuts,
          equals([KeyChord.tryParse('Ctrl+Shift+I')!]),
        );

        await tester.runAsync(env.workspace.dispose);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );

    testWidgets(
      'adding a colliding chord shows collision hint while still storing the chord',
      (tester) async {
        final env = _buildWorkspace();
        await _pumpSettingsShell(tester, env.workspace);
        await _openKeyboardTab(tester);

        final hintFinder = find.byKey(
          const ValueKey('settings-passthrough-collision-hint'),
        );
        expect(hintFinder, findsNothing);

        await tester.enterText(
          find.byKey(const ValueKey('settings-passthrough-input')),
          r'Ctrl+\',
        );
        await tester.tap(
          find.byKey(const ValueKey('settings-passthrough-add')),
        );
        await tester.pump();

        expect(
          env.workspace.preferences.passthroughShortcuts,
          contains(KeyChord.tryParse(r'Ctrl+\')!),
        );
        expect(hintFinder, findsOneWidget);

        // Removing the colliding chord hides the hint again.
        final chip = find.byKey(
          const ValueKey('settings-passthrough-chip-Ctrl+Backslash'),
        );
        tester.widget<InputChip>(chip).onDeleted!();
        await tester.pump();
        expect(hintFinder, findsNothing);

        await tester.runAsync(env.workspace.dispose);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );

    testWidgets(
      'Record chord captures valid chord, ignores standalone modifier, rejects bare key, and cancels on Escape without closing Settings',
      (tester) async {
        final env = _buildWorkspace();
        await _pumpSettingsShell(tester, env.workspace);
        await _openKeyboardTab(tester);

        final recordBtn = find.byKey(
          const ValueKey('settings-passthrough-record'),
        );
        final promptFinder = find.text('Press a chord (Esc to cancel)...');
        final errorFinder = find.byKey(
          const ValueKey('settings-passthrough-error'),
        );

        // Arm recording.
        await tester.tap(recordBtn);
        await tester.pump();
        expect(promptFinder, findsOneWidget);

        // Standalone modifier key stays armed and does not add anything.
        await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
        await tester.pump();
        expect(promptFinder, findsOneWidget);
        expect(env.workspace.preferences.passthroughShortcuts, isEmpty);

        // Bare 'a' shows inline error and does not add anything.
        await tester.sendKeyDownEvent(LogicalKeyboardKey.keyA);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.keyA);
        await tester.pump();
        expect(errorFinder, findsOneWidget);
        expect(env.workspace.preferences.passthroughShortcuts, isEmpty);

        // Valid Ctrl+Shift+I captures chord, disarms, and clears error.
        await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
        await tester.sendKeyDownEvent(LogicalKeyboardKey.keyI);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.keyI);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
        await tester.pump();

        expect(promptFinder, findsNothing);
        expect(errorFinder, findsNothing);
        expect(
          env.workspace.preferences.passthroughShortcuts,
          equals([
            KeyChord(
              key: LogicalKeyboardKey.keyI,
              modifiers: const {ev.Modifier.control, ev.Modifier.shift},
            ),
          ]),
        );

        // Arm again and press Escape -> cancels recording WITHOUT closing Settings!
        await tester.tap(recordBtn);
        await tester.pump();
        expect(promptFinder, findsOneWidget);

        await tester.sendKeyDownEvent(LogicalKeyboardKey.escape);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.escape);
        await tester.pump();

        expect(promptFinder, findsNothing);
        expect(env.workspace.activeOverlay, equals(FtermOverlay.settings));
        expect(
          find.byKey(const ValueKey('fterm-overlay-settings')),
          findsOneWidget,
        );

        await tester.runAsync(env.workspace.dispose);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );

    testWidgets(
      'renders platform-contextual quick-add presets and hides presets once added',
      (tester) async {
        final env = _buildWorkspace();
        final palette = FtermOverlayPalette.fromTerminalTheme(
          env.workspace.activeTerminalTheme,
        );

        Future<void> pumpStandalone({
          required TargetPlatform platform,
          required bool isWeb,
        }) async {
          await tester.pumpWidget(
            MaterialApp(
              home: Scaffold(
                body: SingleChildScrollView(
                  child: FtermKeyboardSettingsTab(
                    workspace: env.workspace,
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

        // macOS Web presets: Meta+Equal, Alt+Meta+I.
        await pumpStandalone(platform: TargetPlatform.macOS, isWeb: true);
        expect(
          find.byKey(const ValueKey('settings-passthrough-preset-Meta+Equal')),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey('settings-passthrough-preset-Alt+Meta+I')),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey('settings-passthrough-preset-Alt+F4')),
          findsNothing,
        );

        // Tapping Meta+Equal adds it and hides that preset chip.
        await tester.tap(
          find.byKey(const ValueKey('settings-passthrough-preset-Meta+Equal')),
        );
        await tester.pump();
        expect(
          env.workspace.preferences.passthroughShortcuts,
          contains(KeyChord.tryParse('Meta+Equal')!),
        );
        expect(
          find.byKey(const ValueKey('settings-passthrough-preset-Meta+Equal')),
          findsNothing,
        );

        // Reset shortcuts and check Linux Web presets: Ctrl+Shift+I, Alt+ArrowLeft.
        env.workspace.updatePreferences(
          env.workspace.preferences.copyWith(passthroughShortcuts: const []),
        );
        await pumpStandalone(platform: TargetPlatform.linux, isWeb: true);
        expect(
          find.byKey(
            const ValueKey('settings-passthrough-preset-Ctrl+Shift+I'),
          ),
          findsOneWidget,
        );
        expect(
          find.byKey(
            const ValueKey('settings-passthrough-preset-Alt+ArrowLeft'),
          ),
          findsOneWidget,
        );

        // Windows Desktop presets: Alt+F4, Alt+Space.
        await pumpStandalone(platform: TargetPlatform.windows, isWeb: false);
        expect(
          find.byKey(const ValueKey('settings-passthrough-preset-Alt+F4')),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey('settings-passthrough-preset-Alt+Space')),
          findsOneWidget,
        );

        // Linux Desktop presets: Alt+F4, Ctrl+Shift+I.
        await pumpStandalone(platform: TargetPlatform.linux, isWeb: false);
        expect(
          find.byKey(const ValueKey('settings-passthrough-preset-Alt+F4')),
          findsOneWidget,
        );
        expect(
          find.byKey(
            const ValueKey('settings-passthrough-preset-Ctrl+Shift+I'),
          ),
          findsOneWidget,
        );

        await tester.runAsync(env.workspace.dispose);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );

    testWidgets(
      'toggles macosOptionAsAlt and f12ShortcutsEnabled in workspace settings',
      (tester) async {
        final env = _buildWorkspace();
        await _pumpSettingsShell(tester, env.workspace);
        await _openKeyboardTab(tester);

        final optToggle = find.byKey(
          const ValueKey('settings-macos-option-as-alt'),
        );
        final f12Toggle = find.byKey(const ValueKey('settings-f12-toggle'));

        expect(env.workspace.preferences.macosOptionAsAlt, isFalse);
        await tester.ensureVisible(optToggle);
        await tester.tap(optToggle);
        await tester.pump();
        expect(env.workspace.preferences.macosOptionAsAlt, isTrue);

        final initialF12 = env.workspace.workspaceSettings.f12ShortcutsEnabled;
        await tester.ensureVisible(f12Toggle);
        await tester.tap(f12Toggle);
        await tester.pump();
        expect(
          env.workspace.workspaceSettings.f12ShortcutsEnabled,
          equals(!initialF12),
        );

        await tester.runAsync(env.workspace.dispose);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  });
}
