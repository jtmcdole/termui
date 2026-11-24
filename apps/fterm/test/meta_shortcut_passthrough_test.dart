import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fterm/src/audio/fterm_audio_controller.dart';
import 'package:fterm/src/font_loader.dart';
import 'package:fterm/src/fterm_app.dart';
import 'package:fterm/src/input/key_chord.dart';
import 'package:fterm/src/settings_storage.dart';
import 'package:fterm/src/ui/fterm_shortcut_dispatcher.dart';
import 'package:fterm/src/workspace/fterm_workspace_controller.dart';
import 'package:fterm/src/workspace/local_host_driver.dart';
import 'package:termui/terminal/event.dart' as ev;
import 'package:termui_cast_client_core/termui_cast_client_core.dart';
import 'package:termui_flutter/termui_flutter.dart';

import 'support/app_three_way_harness.dart';

final class _MemorySettingsStorage implements SettingsStorage {
  final Map<String, String> _items = {};

  @override
  String? getItem(String key) => _items[key];

  @override
  void setItem(String key, String value) => _items[key] = value;
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

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    await loadCastFonts();
  });

  group('FtermShortcutDispatcher.resolveMetaKeyPolicy', () {
    test('resolves policy across all 18 (platform × runtime × FtermMetaKeyMode) combinations', () {
      final transport = WsClientTransport(
        serverUri: CastLaunchConfig.defaultServerUri,
        token: '',
      );
      final repository = CastClientRepository(transport: transport);
      final workspace = FtermWorkspaceController(
        launchConfig: CastLaunchConfig(promptForConnection: true),
        repository: repository,
        localHostDriver: _UnsupportedLocalHostDriver(),
        audioController: FtermAudioController(initialMuted: true),
        storage: _MemorySettingsStorage(),
        resizeDebounce: Duration.zero,
      );
      addTearDown(() async {
        await workspace.dispose();
        await repository.dispose();
      });

      const platforms = [
        TargetPlatform.macOS,
        TargetPlatform.linux,
        TargetPlatform.windows,
      ];
      const runtimes = [true, false];

      var checked = 0;
      for (final mode in FtermMetaKeyMode.values) {
        workspace.updatePreferences(
          workspace.preferences.copyWith(metaKeyMode: mode),
        );
        for (final platform in platforms) {
          for (final isWeb in runtimes) {
            final expected = switch (mode) {
              FtermMetaKeyMode.passThrough =>
                TerminalMetaKeyPolicy.passThroughUnhandled,
              FtermMetaKeyMode.kitty =>
                TerminalMetaKeyPolicy.claimWhenKittyActive,
              FtermMetaKeyMode.auto =>
                (isWeb || platform == TargetPlatform.macOS)
                    ? TerminalMetaKeyPolicy.passThroughUnhandled
                    : TerminalMetaKeyPolicy.claimWhenKittyActive,
            };
            final dispatcher = FtermShortcutDispatcher(
              workspace: workspace,
              platformOverride: platform,
              isWebOverride: isWeb,
            );
            expect(
              dispatcher.resolveMetaKeyPolicy(),
              equals(expected),
              reason: 'mode=$mode platform=$platform isWeb=$isWeb',
            );
            checked++;
          }
        }
      }
      expect(checked, equals(18));
    });
  });

  group('FtermShortcutDispatcher passthroughShortcuts', () {
    test('returns .passThrough for configured chords (including built-in overrides and numpad variants) while active overlays and armed leaders still complete', () {
      final transport = WsClientTransport(
        serverUri: CastLaunchConfig.defaultServerUri,
        token: '',
      );
      final repository = CastClientRepository(transport: transport);
      final workspace = FtermWorkspaceController(
        launchConfig: CastLaunchConfig(promptForConnection: true),
        repository: repository,
        localHostDriver: _UnsupportedLocalHostDriver(),
        audioController: FtermAudioController(initialMuted: true),
        storage: _MemorySettingsStorage(),
        resizeDebounce: Duration.zero,
      );
      addTearDown(() async {
        await workspace.dispose();
        await repository.dispose();
      });

      workspace.updatePreferences(
        workspace.preferences.copyWith(
          passthroughShortcuts: [
            KeyChord.tryParse(r'Ctrl+\')!,
            KeyChord.tryParse('Cmd+=')!,
            KeyChord.tryParse('Cmd+V')!,
            KeyChord.tryParse('Alt+F4')!,
            KeyChord.tryParse('Ctrl+Shift+I')!,
            KeyChord.tryParse('Ctrl+1')!,
          ],
        ),
      );

      final dispatcher = FtermShortcutDispatcher(
        workspace: workspace,
        platformOverride: TargetPlatform.macOS,
        isWebOverride: false,
      );

      KeyDownEvent down(
        LogicalKeyboardKey logical,
        PhysicalKeyboardKey physical, {
        String? character,
      }) => KeyDownEvent(
        physicalKey: physical,
        logicalKey: logical,
        character: character,
        timeStamp: Duration.zero,
      );

      // Built-in overrides reclaimed by passthroughShortcuts.
      expect(
        dispatcher.handleHostShortcut(
          down(
            LogicalKeyboardKey.backslash,
            PhysicalKeyboardKey.backslash,
            character: '\x1c',
          ),
          const {ev.Modifier.control},
        ),
        equals(HostShortcutResult.passThrough),
      );
      expect(workspace.isLeaderArmed, isFalse);

      final initialFontSize = workspace.effectiveFontSize;
      expect(
        dispatcher.handleHostShortcut(
          down(LogicalKeyboardKey.equal, PhysicalKeyboardKey.equal),
          const {ev.Modifier.meta},
        ),
        equals(HostShortcutResult.passThrough),
      );
      expect(workspace.effectiveFontSize, equals(initialFontSize));

      expect(
        dispatcher.handleHostShortcut(
          down(LogicalKeyboardKey.keyV, PhysicalKeyboardKey.keyV),
          const {ev.Modifier.meta},
        ),
        equals(HostShortcutResult.passThrough),
      );
      expect(
        dispatcher.handleHostShortcut(
          down(LogicalKeyboardKey.f4, PhysicalKeyboardKey.f4),
          const {ev.Modifier.alt},
        ),
        equals(HostShortcutResult.passThrough),
      );
      expect(
        dispatcher.handleHostShortcut(
          down(LogicalKeyboardKey.keyI, PhysicalKeyboardKey.keyI),
          const {ev.Modifier.control, ev.Modifier.shift},
        ),
        equals(HostShortcutResult.passThrough),
      );

      // Numpad variant normalizes cleanly to match Ctrl+1.
      expect(
        dispatcher.isPassthroughShortcut(LogicalKeyboardKey.numpad1, const {
          ev.Modifier.control,
        }),
        isTrue,
      );
      expect(
        dispatcher.handleHostShortcut(
          down(LogicalKeyboardKey.numpad1, PhysicalKeyboardKey.numpad1),
          const {ev.Modifier.control},
        ),
        equals(HostShortcutResult.passThrough),
      );

      // Unconfigured shortcut remains unhandled.
      expect(
        dispatcher.handleHostShortcut(
          down(LogicalKeyboardKey.keyL, PhysicalKeyboardKey.keyL),
          const {ev.Modifier.control},
        ),
        equals(HostShortcutResult.unhandled),
      );

      // Active overlay takes priority over passthroughShortcuts.
      workspace.setOverlay(FtermOverlay.settings);
      expect(
        dispatcher.handleHostShortcut(
          down(LogicalKeyboardKey.escape, PhysicalKeyboardKey.escape),
          const {},
        ),
        equals(HostShortcutResult.handled),
      );
      expect(workspace.activeOverlay, equals(FtermOverlay.none));

      // Already-armed leader chord completes cleanly even if follow-up chord is configured.
      workspace.setLeaderArmed(true);
      expect(
        dispatcher.handleHostShortcut(
          down(LogicalKeyboardKey.keyI, PhysicalKeyboardKey.keyI),
          const {ev.Modifier.control, ev.Modifier.shift},
        ),
        equals(HostShortcutResult.handled),
      );
      expect(workspace.isLeaderArmed, isFalse);
      expect(workspace.activeOverlay, equals(FtermOverlay.stats));
    });
  });

  group('End-to-end Meta shortcut passthrough (#426)', () {
    testWidgets(
      'macOS Web ignores Ctrl+Option+Cmd+ArrowLeft and writes 0 PTY bytes in both legacy and Kitty (\\x1b[>3u) modes',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(640, 384));
        addTearDown(() => tester.binding.setSurfaceSize(null));

        final harness = AppThreeWayWsHarness();
        final pty = await tester.runAsync(
          () => harness.startCaster(id: 'mac-web-pty', title: 'mac-web'),
        );
        addTearDown(harness.dispose);

        final bubbledEvents = <KeyEvent>[];
        try {
          await tester.pumpWidget(
            Focus(
              canRequestFocus: false,
              onKeyEvent: (_, event) {
                bubbledEvents.add(event);
                return KeyEventResult.ignored;
              },
              child: FtermApp(
                config: CastLaunchConfig(token: harness.token),
                channelFactory: harness.openClientChannel,
                resizeDebounce: Duration.zero,
                platformOverride: TargetPlatform.macOS,
                isWebOverride: true,
              ),
            ),
          );
          await settleCastApp(tester);

          // 1. Legacy mode (kittyKeyboardFlags == 0).
          pty!.writtenInputs.clear();
          bubbledEvents.clear();
          await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
          await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
          await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
          final legacyDown = await tester.sendKeyDownEvent(
            LogicalKeyboardKey.arrowLeft,
          );
          await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
          final legacyUp = await tester.sendKeyUpEvent(
            LogicalKeyboardKey.arrowLeft,
          );
          await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
          await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
          await settleCastApp(tester, cycles: 3);

          expect(legacyDown, isFalse);
          expect(legacyUp, isFalse);
          expect(pty.writtenInputs, isEmpty);
          expect(
            bubbledEvents.where(
              (e) => e.logicalKey == LogicalKeyboardKey.arrowLeft,
            ),
            hasLength(2),
          );

          // 2. Kitty mode (\x1b[>3u: disambiguate + report event types).
          pty.emitRawAnsi('\x1b[>3u');
          await settleCastApp(tester, cycles: 3);
          pty.writtenInputs.clear();
          bubbledEvents.clear();

          await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
          await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
          await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
          final kittyDown = await tester.sendKeyDownEvent(
            LogicalKeyboardKey.arrowLeft,
          );
          // Release Meta before ArrowLeft to verify zero orphan Kitty release bytes.
          await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
          final kittyUp = await tester.sendKeyUpEvent(
            LogicalKeyboardKey.arrowLeft,
          );
          await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
          await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
          await settleCastApp(tester, cycles: 3);

          expect(kittyDown, isFalse);
          expect(kittyUp, isFalse);
          expect(pty.writtenInputs, isEmpty);
          expect(
            bubbledEvents.where(
              (e) => e.logicalKey == LogicalKeyboardKey.arrowLeft,
            ),
            hasLength(2),
          );
        } finally {
          await tester.pumpWidget(const SizedBox.shrink());
          await settleCastApp(tester, cycles: 2);
        }
      },
    );

    testWidgets(
      'Linux Desktop ignores Meta+ArrowLeft in legacy mode and forwards CSI u bytes when Kitty (\\x1b[>3u) is active',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(640, 384));
        addTearDown(() => tester.binding.setSurfaceSize(null));

        final harness = AppThreeWayWsHarness();
        final pty = await tester.runAsync(
          () => harness.startCaster(id: 'linux-desk-pty', title: 'linux-desk'),
        );
        addTearDown(harness.dispose);

        try {
          await tester.pumpWidget(
            FtermApp(
              config: CastLaunchConfig(token: harness.token),
              channelFactory: harness.openClientChannel,
              resizeDebounce: Duration.zero,
              platformOverride: TargetPlatform.linux,
              isWebOverride: false,
            ),
          );
          await settleCastApp(tester);

          // Legacy mode: Meta+ArrowLeft ignored, 0 PTY bytes.
          pty!.writtenInputs.clear();
          await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
          final legacyDown = await tester.sendKeyDownEvent(
            LogicalKeyboardKey.arrowLeft,
          );
          await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowLeft);
          await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
          await settleCastApp(tester, cycles: 3);

          expect(legacyDown, isFalse);
          expect(pty.writtenInputs, isEmpty);

          // Kitty mode (\x1b[>3u): Meta+ArrowLeft claimed and encoded to PTY.
          pty.emitRawAnsi('\x1b[>3u');
          await settleCastApp(tester, cycles: 3);
          pty.writtenInputs.clear();

          await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
          final kittyDown = await tester.sendKeyDownEvent(
            LogicalKeyboardKey.arrowLeft,
          );
          await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowLeft);
          await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
          await settleCastApp(tester, cycles: 3);

          expect(kittyDown, isTrue);
          expect(pty.writtenInputs, isNotEmpty);
          final decoded = [
            for (final chunk in pty.writtenInputs) utf8.decode(chunk),
          ].join();
          expect(decoded, contains('\x1b['));
        } finally {
          await tester.pumpWidget(const SizedBox.shrink());
          await settleCastApp(tester, cycles: 2);
        }
      },
    );

    testWidgets(
      'Linux/Windows Web ignores configured Ctrl+Shift+I in both legacy and Kitty (\\x1b[>3u) modes while Ctrl+L still writes \\x0c',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(640, 384));
        addTearDown(() => tester.binding.setSurfaceSize(null));

        for (final platform in const [
          TargetPlatform.linux,
          TargetPlatform.windows,
        ]) {
          final harness = AppThreeWayWsHarness();
          final pty = await tester.runAsync(
            () => harness.startCaster(
              id: '${platform.name}-web-pty',
              title: '${platform.name}-web',
            ),
          );
          final storage = _MemorySettingsStorage();
          saveStoredPreferences(
            storage,
            FtermPreferences.defaults.copyWith(
              passthroughShortcuts: [KeyChord.tryParse('Ctrl+Shift+I')!],
            ),
          );
          final bubbledEvents = <KeyEvent>[];

          try {
            await tester.pumpWidget(
              Focus(
                canRequestFocus: false,
                onKeyEvent: (_, event) {
                  bubbledEvents.add(event);
                  return KeyEventResult.ignored;
                },
                child: FtermApp(
                  config: CastLaunchConfig(token: harness.token),
                  channelFactory: harness.openClientChannel,
                  settingsStorage: storage,
                  resizeDebounce: Duration.zero,
                  platformOverride: platform,
                  isWebOverride: true,
                ),
              ),
            );
            await settleCastApp(tester);

            // 1. Legacy mode: Ctrl+Shift+I ignored (0 PTY bytes), Ctrl+L sends \x0c.
            pty!.writtenInputs.clear();
            bubbledEvents.clear();
            await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
            await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
            final legacyDown = await tester.sendKeyDownEvent(
              LogicalKeyboardKey.keyI,
            );
            await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
            final legacyUp = await tester.sendKeyUpEvent(
              LogicalKeyboardKey.keyI,
            );
            await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
            await settleCastApp(tester, cycles: 3);

            expect(legacyDown, isFalse, reason: '${platform.name} legacy down');
            expect(legacyUp, isFalse, reason: '${platform.name} legacy up');
            expect(pty.writtenInputs, isEmpty);
            expect(
              bubbledEvents.where(
                (e) => e.logicalKey == LogicalKeyboardKey.keyI,
              ),
              hasLength(2),
            );

            await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
            final ctrlLDown = await tester.sendKeyDownEvent(
              LogicalKeyboardKey.keyL,
            );
            await tester.sendKeyUpEvent(LogicalKeyboardKey.keyL);
            await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
            await settleCastApp(tester, cycles: 3);

            expect(ctrlLDown, isTrue);
            final ctrlLOutput = [
              for (final chunk in pty.writtenInputs) utf8.decode(chunk),
            ].join();
            expect(ctrlLOutput, contains('\x0c'));

            // 2. Kitty mode (\x1b[>3u): Ctrl+Shift+I still ignored (0 PTY bytes).
            pty.emitRawAnsi('\x1b[>3u');
            await settleCastApp(tester, cycles: 3);
            pty.writtenInputs.clear();
            bubbledEvents.clear();

            await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
            await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
            final kittyDown = await tester.sendKeyDownEvent(
              LogicalKeyboardKey.keyI,
            );
            // Release modifiers before KeyI to verify zero orphan Kitty release bytes.
            await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
            await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
            final kittyUp = await tester.sendKeyUpEvent(
              LogicalKeyboardKey.keyI,
            );
            await settleCastApp(tester, cycles: 3);

            expect(kittyDown, isFalse, reason: '${platform.name} kitty down');
            expect(kittyUp, isFalse, reason: '${platform.name} kitty up');
            expect(pty.writtenInputs, isEmpty);
            expect(
              bubbledEvents.where(
                (e) => e.logicalKey == LogicalKeyboardKey.keyI,
              ),
              hasLength(2),
            );
          } finally {
            await tester.pumpWidget(const SizedBox.shrink());
            await settleCastApp(tester, cycles: 2);
            await tester.runAsync(harness.dispose);
          }
        }
      },
    );

    testWidgets(
      'macOS Web live-switching metaKeyMode from auto to kitty emits \\x1b[1;9D in Kitty mode while staying ignored in legacy mode',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(640, 384));
        addTearDown(() => tester.binding.setSurfaceSize(null));

        final harness = AppThreeWayWsHarness();
        final pty = await tester.runAsync(
          () => harness.startCaster(id: 'mac-live-pty', title: 'mac-live'),
        );
        addTearDown(harness.dispose);

        FtermWorkspaceController? workspace;
        try {
          await tester.pumpWidget(
            FtermApp(
              config: CastLaunchConfig(token: harness.token),
              channelFactory: harness.openClientChannel,
              settingsStorage: _MemorySettingsStorage(),
              resizeDebounce: Duration.zero,
              platformOverride: TargetPlatform.macOS,
              isWebOverride: true,
              onWorkspaceCreated: (ws) => workspace = ws,
            ),
          );
          await settleCastApp(tester);
          expect(workspace, isNotNull);

          // Enable Kitty keyboard mode (\x1b[>3u).
          pty!.emitRawAnsi('\x1b[>3u');
          await settleCastApp(tester, cycles: 3);
          pty.writtenInputs.clear();

          // Under default `.auto` on macOS Web: Meta+ArrowLeft is passed through (0 PTY bytes).
          await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
          final autoDown = await tester.sendKeyDownEvent(
            LogicalKeyboardKey.arrowLeft,
          );
          await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowLeft);
          await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
          await settleCastApp(tester, cycles: 3);

          expect(autoDown, isFalse);
          expect(pty.writtenInputs, isEmpty);

          // Live-switch metaKeyMode from `.auto` -> `.kitty`.
          workspace!.updatePreferences(
            workspace!.preferences.copyWith(
              metaKeyMode: FtermMetaKeyMode.kitty,
            ),
          );
          await settleCastApp(tester, cycles: 3);
          pty.writtenInputs.clear();

          await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
          final kittyDown = await tester.sendKeyDownEvent(
            LogicalKeyboardKey.arrowLeft,
          );
          await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowLeft);
          await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
          await settleCastApp(tester, cycles: 3);

          expect(kittyDown, isTrue);
          final kittyOutput = [
            for (final chunk in pty.writtenInputs) utf8.decode(chunk),
          ].join();
          expect(kittyOutput, contains('\x1b[1;9D'));

          // Pop Kitty mode back to legacy (\x1b[<u): Meta+ArrowLeft must STILL return ignored (0 PTY bytes).
          pty.emitRawAnsi('\x1b[<u');
          await settleCastApp(tester, cycles: 3);
          pty.writtenInputs.clear();

          await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
          final legacyDown = await tester.sendKeyDownEvent(
            LogicalKeyboardKey.arrowLeft,
          );
          await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowLeft);
          await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
          await settleCastApp(tester, cycles: 3);

          expect(legacyDown, isFalse);
          expect(pty.writtenInputs, isEmpty);
        } finally {
          await tester.pumpWidget(const SizedBox.shrink());
          await settleCastApp(tester, cycles: 2);
        }
      },
    );

    testWidgets(
      'early F12 handler and TerminalSurface respect Shift+F12 in passthroughShortcuts (ignored, 0 PTY bytes, no atlas recreate)',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(640, 384));
        addTearDown(() => tester.binding.setSurfaceSize(null));

        final harness = AppThreeWayWsHarness();
        final pty = await tester.runAsync(
          () => harness.startCaster(id: 'f12-pass-pty', title: 'f12-pass'),
        );
        addTearDown(harness.dispose);

        final storage = _MemorySettingsStorage();
        saveStoredPreferences(
          storage,
          FtermPreferences.defaults.copyWith(
            passthroughShortcuts: [KeyChord.tryParse('Shift+F12')!],
          ),
        );
        final bubbledEvents = <KeyEvent>[];
        FtermWorkspaceController? workspace;

        try {
          await tester.pumpWidget(
            Focus(
              canRequestFocus: false,
              onKeyEvent: (_, event) {
                bubbledEvents.add(event);
                return KeyEventResult.ignored;
              },
              child: FtermApp(
                config: CastLaunchConfig(token: harness.token),
                channelFactory: harness.openClientChannel,
                settingsStorage: storage,
                resizeDebounce: Duration.zero,
                platformOverride: TargetPlatform.linux,
                isWebOverride: false,
                onWorkspaceCreated: (ws) => workspace = ws,
              ),
            ),
          );
          await settleCastApp(tester);
          expect(workspace, isNotNull);

          // Enable Kitty release reporting to verify zero orphan F12 release bytes too.
          pty!.emitRawAnsi('\x1b[>3u');
          await settleCastApp(tester, cycles: 3);

          for (final f12HostEnabled in const [false, true]) {
            workspace!.setF12ShortcutsEnabled(f12HostEnabled);
            await settleCastApp(tester, cycles: 2);
            pty.writtenInputs.clear();
            bubbledEvents.clear();

            await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
            final downHandled = await tester.sendKeyDownEvent(
              LogicalKeyboardKey.f12,
            );
            // Release Shift before F12 to ensure _handleEarlyF12Event doesn't emit orphan release.
            await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
            final upHandled = await tester.sendKeyUpEvent(
              LogicalKeyboardKey.f12,
            );
            await settleCastApp(tester, cycles: 3);

            expect(
              downHandled,
              isFalse,
              reason: 'f12HostEnabled=$f12HostEnabled down',
            );
            expect(
              upHandled,
              isFalse,
              reason: 'f12HostEnabled=$f12HostEnabled up',
            );
            expect(pty.writtenInputs, isEmpty);
            expect(
              bubbledEvents.where(
                (e) => e.logicalKey == LogicalKeyboardKey.f12,
              ),
              hasLength(2),
            );
          }

          // Unconfigured bare F12 still writes to PTY when f12ShortcutsEnabled is false.
          workspace!.setF12ShortcutsEnabled(false);
          await settleCastApp(tester, cycles: 2);
          pty.writtenInputs.clear();

          final bareF12Down = await tester.sendKeyDownEvent(
            LogicalKeyboardKey.f12,
          );
          await tester.sendKeyUpEvent(LogicalKeyboardKey.f12);
          await settleCastApp(tester, cycles: 3);

          expect(bareF12Down, isTrue);
          expect(pty.writtenInputs, isNotEmpty);
        } finally {
          await tester.pumpWidget(const SizedBox.shrink());
          await settleCastApp(tester, cycles: 2);
        }
      },
    );
  });
}
