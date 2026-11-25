import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fterm/src/audio/fterm_audio_controller.dart';
import 'package:fterm/src/font_loader.dart';
import 'package:fterm/src/fterm_app.dart';
import 'package:fterm/src/settings_storage.dart';
import 'package:fterm/src/ui/fterm_shortcut_dispatcher.dart';
import 'package:fterm/src/workspace/fterm_workspace_controller.dart';
import 'package:fterm/src/workspace/local_host_driver.dart';
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
  bool releaseMetaFirst = false,
}) async {
  for (final mod in mods) {
    await tester.sendKeyDownEvent(mod);
  }
  final down = await tester.sendKeyDownEvent(key);
  if (releaseMetaFirst) {
    await tester.sendKeyUpEvent(.metaLeft);
  }
  final up = await tester.sendKeyUpEvent(key);
  for (final mod in mods.reversed) {
    if (releaseMetaFirst && mod == .metaLeft) continue;
    await tester.sendKeyUpEvent(mod);
  }
  await settleCastApp(tester, cycles: 3);
  return (down, up);
}

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    await loadCastFonts();
  });

  test('resolveMetaKeyPolicy covers all 6 (OS × Web/Desktop) defaults', () {
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

    const platforms = [
      TargetPlatform.macOS,
      TargetPlatform.linux,
      TargetPlatform.windows,
    ];
    var checked = 0;
    for (final platform in platforms) {
      for (final isWeb in const [true, false]) {
        final expected = (isWeb || platform == .macOS)
            ? TerminalMetaKeyPolicy.passThroughUnhandled
            : TerminalMetaKeyPolicy.claimWhenKittyActive;
        final dispatcher = FtermShortcutDispatcher(
          workspace: workspace,
          platformOverride: platform,
          isWebOverride: isWeb,
        );
        expect(
          dispatcher.resolveMetaKeyPolicy(),
          equals(expected),
          reason: 'platform=$platform isWeb=$isWeb',
        );
        checked++;
      }
    }
    expect(checked, equals(6));
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
              releaseMetaFirst: true,
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
  });
}
