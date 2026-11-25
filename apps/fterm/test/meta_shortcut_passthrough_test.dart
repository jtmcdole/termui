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

Future<void> _runMountedApp(
  WidgetTester tester, {
  required String id,
  required TargetPlatform platform,
  required bool isWeb,
  required Future<void> Function(
    FtermWorkspaceController workspace,
    AppFakePtySession pty,
    List<KeyEvent> bubbled,
  )
  body,
}) async {
  await tester.binding.setSurfaceSize(const Size(640, 384));
  addTearDown(() => tester.binding.setSurfaceSize(null));

  final harness = AppThreeWayWsHarness();
  final pty = await tester.runAsync(
    () => harness.startCaster(id: '$id-pty', title: id),
  );
  addTearDown(harness.dispose);

  final bubbled = <KeyEvent>[];
  FtermWorkspaceController? workspace;
  try {
    await tester.pumpWidget(
      Focus(
        canRequestFocus: false,
        onKeyEvent: (_, event) {
          bubbled.add(event);
          return .ignored;
        },
        child: FtermApp(
          config: CastLaunchConfig(token: harness.token),
          channelFactory: harness.openClientChannel,
          settingsStorage: _MemorySettingsStorage(),
          resizeDebounce: Duration.zero,
          platformOverride: platform,
          isWebOverride: isWeb,
          onWorkspaceCreated: (ws) => workspace = ws,
        ),
      ),
    );
    await settleCastApp(tester);
    await body(workspace!, pty!, bubbled);
  } finally {
    await tester.pumpWidget(const SizedBox.shrink());
    await settleCastApp(tester, cycles: 2);
  }
}

Future<(bool down, bool up)> _sendChord(
  WidgetTester tester,
  List<LogicalKeyboardKey> mods,
  LogicalKeyboardKey key, {
  LogicalKeyboardKey? releaseModFirst,
  bool includeRepeat = false,
}) async {
  for (final mod in mods) {
    await tester.sendKeyDownEvent(mod);
  }
  final down = await tester.sendKeyDownEvent(key);
  if (includeRepeat) {
    await tester.sendKeyRepeatEvent(key);
  }
  if (releaseModFirst != null) {
    await tester.sendKeyUpEvent(releaseModFirst);
  }
  final up = await tester.sendKeyUpEvent(key);
  for (final mod in mods.reversed) {
    if (mod == releaseModFirst) continue;
    await tester.sendKeyUpEvent(mod);
  }
  await settleCastApp(tester, cycles: 3);
  return (down, up);
}

FtermWorkspaceController _createUnitWorkspace() {
  final repository = CastClientRepository(
    transport: WsClientTransport(
      serverUri: CastLaunchConfig.defaultServerUri,
      token: '',
    ),
  );
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
  return workspace;
}

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    await loadCastFonts();
  });

  test('resolveMetaKeyPolicy covers all 18 (OS × Web/Desktop × FtermMetaKeyMode) combinations', () {
    final workspace = _createUnitWorkspace();

    const platforms = [
      TargetPlatform.macOS,
      TargetPlatform.linux,
      TargetPlatform.windows,
    ];
    var checked = 0;
    for (final mode in FtermMetaKeyMode.values) {
      workspace.updatePreferences(
        workspace.preferences.copyWith(metaKeyMode: mode),
      );
      for (final platform in platforms) {
        for (final isWeb in const [true, false]) {
          final expected = switch (mode) {
            .passThrough => TerminalMetaKeyPolicy.passThroughUnhandled,
            .kitty => TerminalMetaKeyPolicy.claimWhenKittyActive,
            .auto =>
              (isWeb || platform == .macOS)
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

  group('End-to-end Meta shortcut passthrough (#426)', () {
    testWidgets(
      'macOS Web ignores Ctrl+Option+Cmd+ArrowLeft and writes 0 PTY bytes in legacy and Kitty (\\x1b[>3u) modes',
      (tester) => _runMountedApp(
        tester,
        id: 'mac-web',
        platform: .macOS,
        isWeb: true,
        body: (_, pty, bubbled) async {
          const mods = [
            LogicalKeyboardKey.controlLeft,
            LogicalKeyboardKey.altLeft,
            LogicalKeyboardKey.metaLeft,
          ];
          for (final kittyAnsi in const <String?>[null, '\x1b[>3u']) {
            if (kittyAnsi != null) {
              pty.emitRawAnsi(kittyAnsi);
              await settleCastApp(tester, cycles: 3);
            }
            pty.writtenInputs.clear();
            bubbled.clear();
            final res = await _sendChord(
              tester,
              mods,
              .arrowLeft,
              releaseModFirst: .metaLeft,
            );
            expect(res, equals((false, false)), reason: 'kitty=$kittyAnsi');
            expect(pty.writtenInputs, isEmpty, reason: 'kitty=$kittyAnsi');
            expect(
              bubbled.where((e) => e.logicalKey == .arrowLeft),
              hasLength(2),
            );
          }
        },
      ),
    );

    testWidgets(
      'Linux Desktop ignores Meta+ArrowLeft in legacy mode and forwards CSI u bytes in Kitty (\\x1b[>3u) mode',
      (tester) => _runMountedApp(
        tester,
        id: 'linux-desk',
        platform: .linux,
        isWeb: false,
        body: (_, pty, _) async {
          pty.writtenInputs.clear();
          final (legacyDown, _) = await _sendChord(tester, const [
            .metaLeft,
          ], .arrowLeft);
          expect(legacyDown, isFalse);
          expect(pty.writtenInputs, isEmpty);

          pty.emitRawAnsi('\x1b[>3u');
          await settleCastApp(tester, cycles: 3);
          pty.writtenInputs.clear();

          final (kittyDown, _) = await _sendChord(tester, const [
            .metaLeft,
          ], .arrowLeft);
          expect(kittyDown, isTrue);
          final decoded = [
            for (final chunk in pty.writtenInputs) utf8.decode(chunk),
          ].join();
          expect(decoded, contains('\x1b[1;9D'));
        },
      ),
    );

    testWidgets(
      'macOS Web live-switching metaKeyMode auto -> kitty emits \\x1b[1;9D in Kitty mode while staying ignored in legacy mode',
      (tester) => _runMountedApp(
        tester,
        id: 'mac-live',
        platform: .macOS,
        isWeb: true,
        body: (workspace, pty, _) async {
          pty.emitRawAnsi('\x1b[>3u');
          await settleCastApp(tester, cycles: 3);
          pty.writtenInputs.clear();

          // Default .auto on macOS Web passes through even in Kitty mode.
          expect(
            (await _sendChord(tester, const [.metaLeft], .arrowLeft)).$1,
            isFalse,
          );
          expect(pty.writtenInputs, isEmpty);

          // Live-switch .auto -> .kitty: Meta+ArrowLeft emits \x1b[1;9D.
          workspace.updatePreferences(
            workspace.preferences.copyWith(metaKeyMode: .kitty),
          );
          await settleCastApp(tester, cycles: 3);
          pty.writtenInputs.clear();

          expect(
            (await _sendChord(tester, const [.metaLeft], .arrowLeft)).$1,
            isTrue,
          );
          final kittyOutput = [
            for (final chunk in pty.writtenInputs) utf8.decode(chunk),
          ].join();
          expect(kittyOutput, contains('\x1b[1;9D'));

          // Pop back to legacy (\x1b[<u): .kitty still ignores legacy Meta chords.
          pty.emitRawAnsi('\x1b[<u');
          await settleCastApp(tester, cycles: 3);
          pty.writtenInputs.clear();

          expect(
            (await _sendChord(tester, const [.metaLeft], .arrowLeft)).$1,
            isFalse,
          );
          expect(pty.writtenInputs, isEmpty);
        },
      ),
    );
  });

  group('Configured passthroughShortcuts dispatch (#426)', () {
    test('dispatcher passes through configured chords (including numpad) while preserving overlay and armed leader', () {
      final workspace = _createUnitWorkspace();
      workspace.updatePreferences(
        workspace.preferences.copyWith(
          passthroughShortcuts: KeyChord.parseAll(const [
            r'Ctrl+\',
            'Cmd+=',
            'Cmd+V',
            'Alt+F4',
            'Ctrl+Shift+I',
            'Ctrl+1',
          ]).chords,
        ),
      );
      final dispatcher = FtermShortcutDispatcher(
        workspace: workspace,
        platformOverride: .macOS,
        isWebOverride: false,
      );

      KeyDownEvent down(LogicalKeyboardKey key) => KeyDownEvent(
        physicalKey: .keyA,
        logicalKey: key,
        timeStamp: Duration.zero,
      );

      const configured = <(LogicalKeyboardKey, Set<ev.Modifier>)>[
        (.backslash, {.control}),
        (.equal, {.meta}),
        (.keyV, {.meta}),
        (.f4, {.alt}),
        (.keyI, {.control, .shift}),
        (.numpad1, {.control}),
      ];
      for (final (key, mods) in configured) {
        expect(
          dispatcher.handleHostShortcut(down(key), mods),
          equals(HostShortcutResult.passThrough),
          reason: 'key=$key mods=$mods',
        );
      }
      expect(
        dispatcher.handleHostShortcut(down(.keyL), const {.control}),
        equals(HostShortcutResult.unhandled),
      );
      expect(workspace.isLeaderArmed, isFalse);

      // Active overlay Escape still dismisses even when passthrough chords exist.
      workspace.setOverlay(.settings);
      expect(
        dispatcher.handleHostShortcut(down(.escape), const {}),
        equals(HostShortcutResult.handled),
      );
      expect(workspace.activeOverlay, equals(FtermOverlay.none));

      // Armed leader chord still completes before passthrough matching.
      workspace.setLeaderArmed(true);
      expect(
        dispatcher.handleHostShortcut(down(.keyI), const {.control, .shift}),
        equals(HostShortcutResult.handled),
      );
      expect(workspace.isLeaderArmed, isFalse);
      expect(workspace.activeOverlay, equals(FtermOverlay.stats));
    });

    testWidgets(
      'Linux/Windows Web ignores configured Ctrl+Shift+I in legacy and Kitty (\\x1b[>3u) modes while Ctrl+L writes \\x0c',
      (tester) => _runMountedApp(
        tester,
        id: 'linux-web-pt',
        platform: .linux,
        isWeb: true,
        body: (workspace, pty, bubbled) async {
          workspace.updatePreferences(
            workspace.preferences.copyWith(
              passthroughShortcuts: [KeyChord.tryParse('Ctrl+Shift+I')!],
            ),
          );
          await settleCastApp(tester, cycles: 3);

          // Legacy mode: Ctrl+Shift+I ignored (0 bytes); Ctrl+L writes \x0c.
          pty.writtenInputs.clear();
          bubbled.clear();
          final legacyPt = await _sendChord(tester, const [
            .controlLeft,
            .shiftLeft,
          ], .keyI);
          expect(legacyPt, equals((false, false)));
          expect(pty.writtenInputs, isEmpty);
          expect(bubbled.where((e) => e.logicalKey == .keyI), hasLength(2));

          final (ctrlLDown, _) = await _sendChord(tester, const [
            .controlLeft,
          ], .keyL);
          expect(ctrlLDown, isTrue);
          final legacyCtrlL = [
            for (final chunk in pty.writtenInputs) utf8.decode(chunk),
          ].join();
          expect(legacyCtrlL, equals('\x0c'));

          // Kitty mode (\x1b[>3u): Ctrl+Shift+I still ignored (0 bytes).
          pty.emitRawAnsi('\x1b[>3u');
          await settleCastApp(tester, cycles: 3);
          pty.writtenInputs.clear();
          bubbled.clear();

          final kittyPt = await _sendChord(tester, const [
            .controlLeft,
            .shiftLeft,
          ], .keyI);
          expect(kittyPt, equals((false, false)));
          expect(pty.writtenInputs, isEmpty);
          expect(bubbled.where((e) => e.logicalKey == .keyI), hasLength(2));
        },
      ),
    );

    testWidgets(
      'early Shift+F12 passthrough ignores down/repeat/up with 0 orphan bytes in Kitty mode for both f12ShortcutsEnabled states',
      (tester) => _runMountedApp(
        tester,
        id: 'early-f12-pt',
        platform: .windows,
        isWeb: true,
        body: (workspace, pty, bubbled) async {
          workspace.updatePreferences(
            workspace.preferences.copyWith(
              passthroughShortcuts: [KeyChord.tryParse('Shift+F12')!],
            ),
          );
          pty.emitRawAnsi('\x1b[>3u');
          await settleCastApp(tester, cycles: 3);

          for (final f12Enabled in const [false, true]) {
            workspace.setF12ShortcutsEnabled(f12Enabled);
            await settleCastApp(tester, cycles: 2);
            pty.writtenInputs.clear();
            bubbled.clear();

            final res = await _sendChord(
              tester,
              const [.shiftLeft],
              .f12,
              releaseModFirst: .shiftLeft,
              includeRepeat: true,
            );
            expect(
              res,
              equals((false, false)),
              reason: 'f12ShortcutsEnabled=$f12Enabled',
            );
            expect(
              pty.writtenInputs,
              isEmpty,
              reason: 'f12ShortcutsEnabled=$f12Enabled',
            );
            expect(
              bubbled.where((e) => e.logicalKey == .f12),
              hasLength(3),
              reason: 'down+repeat+up should bubble for f12=$f12Enabled',
            );
          }
        },
      ),
    );
  });
}
