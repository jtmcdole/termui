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

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    await loadCastFonts();
  });

  group('FtermShortcutDispatcher.resolveMetaKeyPolicy', () {
    test('resolves policy across all 6 (platform × runtime) combinations', () {
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

      const cases = [
        (
          TargetPlatform.macOS,
          true,
          TerminalMetaKeyPolicy.passThroughUnhandled,
        ),
        (
          TargetPlatform.macOS,
          false,
          TerminalMetaKeyPolicy.passThroughUnhandled,
        ),
        (
          TargetPlatform.linux,
          true,
          TerminalMetaKeyPolicy.passThroughUnhandled,
        ),
        (
          TargetPlatform.linux,
          false,
          TerminalMetaKeyPolicy.claimWhenKittyActive,
        ),
        (
          TargetPlatform.windows,
          true,
          TerminalMetaKeyPolicy.passThroughUnhandled,
        ),
        (
          TargetPlatform.windows,
          false,
          TerminalMetaKeyPolicy.claimWhenKittyActive,
        ),
      ];

      for (final (platform, isWeb, expected) in cases) {
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
      }
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
  });
}
