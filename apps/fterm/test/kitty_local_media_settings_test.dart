import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fterm/src/audio/fterm_audio_controller.dart';
import 'package:fterm/src/commands/fterm_capability_context.dart';
import 'package:fterm/src/launch_config.dart';
import 'package:fterm/src/settings_storage.dart';
import 'package:fterm/src/ui/fterm_overlays.dart';
import 'package:fterm/src/ui/palette/palette_command_registry.dart';
import 'package:fterm/src/ui/settings/settings_catalog.dart';
import 'package:fterm/src/ui/settings/settings_sections.dart';
import 'package:fterm/src/workspace/fterm_workspace_controller.dart';
import 'package:fterm/src/workspace/local_host_driver_io.dart';
import 'package:material_ui/material_ui.dart';
import 'package:termui_cast_client_core/termui_cast_client_core.dart';
import 'package:termui_flutter/termui_flutter.dart'
    show DisabledShaderBackend, TerminalShaderController;
import 'package:termui_pty/termui_pty.dart';

final class _MemStorage implements SettingsStorage {
  final Map<String, String> _map = <String, String>{};

  @override
  String? getItem(String key) => _map[key];

  @override
  void setItem(String key, String value) => _map[key] = value;
}

final class _FakeRoutedBackend implements RoutedPtyBackend {
  final StreamController<Uint8List> _output =
      StreamController<Uint8List>.broadcast();
  final Completer<int> _exit = Completer<int>();
  final List<String> replies = <String>[];

  void emitOutput(String text) {
    if (!_output.isClosed) {
      _output.add(Uint8List.fromList(utf8.encode(text)));
    }
  }

  @override
  Stream<Uint8List> get output => _output.stream;

  @override
  Future<int> get exitCode => _exit.future;

  @override
  void write(Uint8List bytes) => replies.add(utf8.decode(bytes));

  @override
  void resize(int cols, int rows, {int pixelWidth = 0, int pixelHeight = 0}) {}

  @override
  void kill() {
    if (!_exit.isCompleted) _exit.complete(0);
  }

  @override
  Future<void> dispose() async {
    kill();
    await _output.close();
  }
}

FtermWorkspaceController _createWorkspace({
  required _MemStorage storage,
  required IoLocalHostDriver driver,
}) {
  final transport = WsClientTransport(
    serverUri: CastLaunchConfig.defaultServerUri,
    token: '',
  );
  return FtermWorkspaceController(
    launchConfig: CastLaunchConfig(promptForConnection: false),
    repository: CastClientRepository(transport: transport),
    localHostDriver: driver,
    audioController: FtermAudioController(
      initialMuted: false,
      requireUserGesture: false,
    ),
    storage: storage,
    resizeDebounce: Duration.zero,
    shaderController: TerminalShaderController(
      backendFactory: (_) => const DisabledShaderBackend(),
    ),
  );
}

void main() {
  group('Kitty local media settings under System', () {
    test(
      'FtermPreferences defaults to enabled and round-trips JSON persistence',
      () {
        const defaults = FtermPreferences();
        expect(defaults.kittyTempFileMedium, isTrue);
        expect(defaults.kittySharedMemoryMedium, isTrue);

        // Missing keys in legacy JSON preserve defaults (`true`).
        final legacy = FtermPreferences.fromJsonString('{"audioMuted":false}');
        expect(legacy.kittyTempFileMedium, isTrue);
        expect(legacy.kittySharedMemoryMedium, isTrue);

        final disabled = defaults.copyWith(
          kittyTempFileMedium: false,
          kittySharedMemoryMedium: false,
        );
        expect(disabled, isNot(equals(defaults)));
        final decoded = FtermPreferences.fromJsonString(
          disabled.toJsonString(),
        );
        expect(decoded, equals(disabled));
        expect(decoded.kittyTempFileMedium, isFalse);
        expect(decoded.kittySharedMemoryMedium, isFalse);
      },
    );

    test(
      'SettingsCatalog search and Command Palette gate t=t and t=s by platform',
      () {
        final storage = _MemStorage();
        final driver = IoLocalHostDriver(
          backendFactory: ({
            required executable,
            required arguments,
            required initialCols,
            required initialRows,
            required pixelWidth,
            required pixelHeight,
            workingDirectory,
            environment,
          }) => _FakeRoutedBackend(),
          ensureConPtyReady: ({
            bool download = false,
            void Function(String)? onWarning,
          }) async => null,
        );
        final ws = _createWorkspace(storage: storage, driver: driver);
        addTearDown(() async {
          await ws.dispose();
          await driver.dispose();
        });

        Set<String> searchIds(FtermCapabilityContext ctx) => <String>{
          for (final panel in SettingsCatalog.search(
            'kitty',
            capabilities: ctx,
          ).panelMatches)
            ...panel.matchedItemIds,
        };

        Set<String> paletteIds(FtermCapabilityContext ctx) => <String>{
          for (final item in buildPaletteCommands(
            PaletteContext(
              workspace: ws,
              isWeb: ctx.isWeb,
              platform: ctx.platform,
              isDesktopHost: ctx.isDesktopHost,
              supportsUpdates: ctx.supportsUpdates,
            ),
          ))
            item.id,
        };

        const linuxDesktop = FtermCapabilityContext(
          isWeb: false,
          platform: .linux,
          isDesktopHost: true,
          supportsUpdates: true,
        );
        const macDesktop = FtermCapabilityContext(
          isWeb: false,
          platform: .macOS,
          isDesktopHost: true,
          supportsUpdates: true,
        );
        const windowsDesktop = FtermCapabilityContext(
          isWeb: false,
          platform: .windows,
          isDesktopHost: true,
          supportsUpdates: true,
        );
        const webLinux = FtermCapabilityContext(
          isWeb: true,
          platform: .linux,
          isDesktopHost: false,
          supportsUpdates: false,
        );

        for (final posix in [linuxDesktop, macDesktop]) {
          expect(
            searchIds(posix),
            containsAll(<String>[
              'system-kitty-temp-file',
              'system-kitty-shared-memory',
            ]),
          );
          expect(
            paletteIds(posix),
            containsAll(<String>[
              'settings.toggle.kitty_temp_file',
              'settings.toggle.kitty_shared_memory',
            ]),
          );
        }

        // Windows shows t=t temp files and hides POSIX t=s shared memory.
        expect(searchIds(windowsDesktop), contains('system-kitty-temp-file'));
        expect(
          searchIds(windowsDesktop),
          isNot(contains('system-kitty-shared-memory')),
        );
        expect(
          paletteIds(windowsDesktop),
          contains('settings.toggle.kitty_temp_file'),
        );
        expect(
          paletteIds(windowsDesktop),
          isNot(contains('settings.toggle.kitty_shared_memory')),
        );

        // Web hides both local media toggles.
        expect(searchIds(webLinux), isNot(contains('system-kitty-temp-file')));
        expect(
          searchIds(webLinux),
          isNot(contains('system-kitty-shared-memory')),
        );
      },
    );

    testWidgets(
      'SettingsSystemSection renders Kitty Graphics Media panel and toggles active local shell live',
      (tester) async {
        final tempFile = File(
          '${Directory.systemTemp.path}/tty-graphics-protocol-fterm-settings-$pid.rgba',
        )..writeAsBytesSync(const [10, 20, 30, 255]);
        addTearDown(() {
          if (tempFile.existsSync()) tempFile.deleteSync();
        });
        final tmpB64 = base64Encode(utf8.encode(tempFile.path));

        final backends = <_FakeRoutedBackend>[];
        final router = PtyRouter();
        final driver = IoLocalHostDriver(
          router: router,
          backendFactory:
              ({
                required executable,
                required arguments,
                required initialCols,
                required initialRows,
                required pixelWidth,
                required pixelHeight,
                workingDirectory,
                environment,
              }) {
                final b = _FakeRoutedBackend();
                backends.add(b);
                return b;
              },
          ensureConPtyReady: ({
            bool download = false,
            void Function(String)? onWarning,
          }) async => null,
        );
        final storage = _MemStorage();
        final ws = _createWorkspace(storage: storage, driver: driver);
        addTearDown(() async {
          await ws.dispose();
          await driver.dispose();
        });

        await ws.openLocalShellTab();
        expect(backends, hasLength(1));
        final firstBackend = backends.first;

        // Default is enabled -> a=q,t=t succeeds.
        firstBackend.emitOutput(
          '\x1b_Ga=q,f=32,s=1,v=1,i=401,t=t;$tmpB64\x1b\\',
        );
        await tester.pump();
        expect(firstBackend.replies, equals(<String>['\x1b_Gi=401;OK\x1b\\']));

        final palette = FtermOverlayPalette.fromTerminalTheme(
          ws.activeTerminalTheme,
        );
        Widget buildSystemSection({
          required bool isWeb,
          required TargetPlatform platform,
        }) => MaterialApp(
          theme: ThemeData(platform: platform),
          home: Scaffold(
            body: SingleChildScrollView(
              child: ListenableBuilder(
                listenable: ws,
                builder: (_, _) => SettingsSystemSection(
                  workspace: ws,
                  palette: palette,
                  isWeb: isWeb,
                  platformOverride: platform,
                ),
              ),
            ),
          ),
        );

        // Linux desktop: both t=t and t=s toggles are visible under System.
        await tester.pumpWidget(
          buildSystemSection(isWeb: false, platform: .linux),
        );
        expect(
          find.byKey(const ValueKey('settings-panel-system-kitty-media')),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey('settings-kitty-temp-file')),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey('settings-kitty-shared-memory')),
          findsOneWidget,
        );

        // Toggle Temp File Medium OFF -> live pane immediately rejects t=t.
        await tester.tap(
          find.byKey(const ValueKey('settings-kitty-temp-file')),
        );
        await tester.pump();
        expect(ws.preferences.kittyTempFileMedium, isFalse);

        firstBackend.replies.clear();
        firstBackend.emitOutput(
          '\x1b_Ga=q,f=32,s=1,v=1,i=402,t=t;$tmpB64\x1b\\',
        );
        await tester.pump();
        expect(
          firstBackend.replies,
          equals(<String>[
            '\x1b_Gi=402;EINVAL:unsupported transmission medium\x1b\\',
          ]),
        );

        // Toggle Shared Memory OFF too and verify newly opened shell inherits both.
        await tester.tap(
          find.byKey(const ValueKey('settings-kitty-shared-memory')),
        );
        await tester.pump();
        expect(ws.preferences.kittySharedMemoryMedium, isFalse);

        await ws.openLocalShellTab();
        expect(backends, hasLength(2));
        final sessions = router.sessions.values.toList();
        expect(sessions.last.terminal.allowLocalKittyMedia, isFalse);
        expect(sessions.last.terminal.allowLocalKittyShm, isFalse);

        // Resetting settings restores defaults and re-enables active shells live.
        ws.resetSettingsToDefaults();
        await tester.pump();
        expect(ws.preferences.kittyTempFileMedium, isTrue);
        expect(ws.preferences.kittySharedMemoryMedium, isTrue);
        expect(sessions.last.terminal.allowLocalKittyMedia, isTrue);
        expect(sessions.last.terminal.allowLocalKittyShm, isTrue);

        // Windows desktop shows t=t and hides POSIX t=s.
        await tester.pumpWidget(
          buildSystemSection(isWeb: false, platform: .windows),
        );
        expect(
          find.byKey(const ValueKey('settings-panel-system-kitty-media')),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey('settings-kitty-temp-file')),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey('settings-kitty-shared-memory')),
          findsNothing,
        );

        // Web hides the Kitty Graphics Media panel completely.
        await tester.pumpWidget(
          buildSystemSection(isWeb: true, platform: .linux),
        );
        expect(
          find.byKey(const ValueKey('settings-panel-system-kitty-media')),
          findsNothing,
        );
      },
    );
  });
}
