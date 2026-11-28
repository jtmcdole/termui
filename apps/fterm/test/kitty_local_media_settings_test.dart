import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
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
  Future<String?> Function()? clipboardReader,
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
    clipboardReader: clipboardReader,
  );
}

void main() {
  group('Kitty local media settings under System', () {
    test(
      'FtermPreferences defaults to enabled and round-trips JSON persistence',
      () {
        const defaults = FtermPreferences();
        expect(defaults.kittyTempFileMedium, isTrue);
        expect(defaults.kittyFileMedium, isTrue);
        expect(defaults.kittySharedMemoryMedium, isTrue);
        expect(defaults.localClipboardWrite, isTrue);
        expect(defaults.localClipboardRead, isFalse);

        // Missing keys in legacy JSON preserve defaults.
        final legacy = FtermPreferences.fromJsonString('{"audioMuted":false}');
        expect(legacy.kittyTempFileMedium, isTrue);
        expect(legacy.kittyFileMedium, isTrue);
        expect(legacy.kittySharedMemoryMedium, isTrue);
        expect(legacy.localClipboardWrite, isTrue);
        expect(legacy.localClipboardRead, isFalse);

        final disabled = defaults.copyWith(
          kittyTempFileMedium: false,
          kittyFileMedium: false,
          kittySharedMemoryMedium: false,
          localClipboardWrite: false,
          localClipboardRead: true,
        );
        expect(disabled, isNot(equals(defaults)));
        final decoded = FtermPreferences.fromJsonString(
          disabled.toJsonString(),
        );
        expect(decoded, equals(disabled));
        expect(decoded.kittyTempFileMedium, isFalse);
        expect(decoded.kittyFileMedium, isFalse);
        expect(decoded.kittySharedMemoryMedium, isFalse);
        expect(decoded.localClipboardWrite, isFalse);
        expect(decoded.localClipboardRead, isTrue);
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
              'system-kitty-file-medium',
              'system-kitty-shared-memory',
            ]),
          );
          expect(
            paletteIds(posix),
            containsAll(<String>[
              'settings.toggle.kitty_temp_file',
              'settings.toggle.kitty_file_medium',
              'settings.toggle.kitty_shared_memory',
              'settings.toggle.local_clipboard_write',
              'settings.toggle.local_clipboard_read',
            ]),
          );
        }

        // Windows shows t=t and t=f and hides POSIX t=s shared memory.
        expect(
          searchIds(windowsDesktop),
          containsAll(<String>[
            'system-kitty-temp-file',
            'system-kitty-file-medium',
          ]),
        );
        expect(
          searchIds(windowsDesktop),
          isNot(contains('system-kitty-shared-memory')),
        );
        expect(
          paletteIds(windowsDesktop),
          containsAll(<String>[
            'settings.toggle.kitty_temp_file',
            'settings.toggle.kitty_file_medium',
          ]),
        );
        expect(
          paletteIds(windowsDesktop),
          isNot(contains('system-kitty-shared-memory')),
        );
        expect(
          paletteIds(windowsDesktop),
          isNot(contains('settings.toggle.kitty_shared_memory')),
        );

        // Web hides all local media and local clipboard toggles.
        expect(searchIds(webLinux), isNot(contains('system-kitty-temp-file')));
        expect(
          searchIds(webLinux),
          isNot(contains('system-kitty-file-medium')),
        );
        expect(
          searchIds(webLinux),
          isNot(contains('system-kitty-shared-memory')),
        );
        expect(
          paletteIds(webLinux),
          isNot(contains('settings.toggle.local_clipboard_write')),
        );
        expect(
          paletteIds(webLinux),
          isNot(contains('settings.toggle.local_clipboard_read')),
        );
      },
    );

    testWidgets(
      'SettingsSystemSection renders Kitty Graphics Media panel and toggles active local shell live',
      (tester) async {
        final tempFile = File(
          '${Directory.systemTemp.path}/tty-graphics-protocol-fterm-settings-$pid.rgba',
        )..writeAsBytesSync(const [10, 20, 30, 255]);
        final regularFile = File(
          '${Directory.systemTemp.path}/fterm-regular-file-settings-$pid.rgba',
        )..writeAsBytesSync(const [40, 50, 60, 255]);
        addTearDown(() {
          if (tempFile.existsSync()) tempFile.deleteSync();
          if (regularFile.existsSync()) regularFile.deleteSync();
        });
        final tmpB64 = base64Encode(utf8.encode(tempFile.path));
        final regB64 = base64Encode(utf8.encode(regularFile.path));

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

        // Default is enabled -> a=q,t=t and a=q,t=f succeed.
        firstBackend.emitOutput(
          '\x1b_Ga=q,f=32,s=1,v=1,i=401,t=t;$tmpB64\x1b\\'
          '\x1b_Ga=q,f=32,s=1,v=1,i=403,t=f;$regB64\x1b\\',
        );
        await tester.pump();
        expect(
          firstBackend.replies,
          equals(<String>['\x1b_Gi=401;OK\x1b\\', '\x1b_Gi=403;OK\x1b\\']),
        );

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

        // Linux desktop: t=t, t=f, and t=s toggles are visible under System.
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
          find.byKey(const ValueKey('settings-kitty-file-medium')),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey('settings-kitty-shared-memory')),
          findsOneWidget,
        );

        // Toggle Temp File Medium and Regular File Medium OFF -> live pane immediately rejects both.
        await tester.tap(
          find.byKey(const ValueKey('settings-kitty-temp-file')),
        );
        await tester.tap(
          find.byKey(const ValueKey('settings-kitty-file-medium')),
        );
        await tester.pump();
        expect(ws.preferences.kittyTempFileMedium, isFalse);
        expect(ws.preferences.kittyFileMedium, isFalse);

        firstBackend.replies.clear();
        firstBackend.emitOutput(
          '\x1b_Ga=q,f=32,s=1,v=1,i=402,t=t;$tmpB64\x1b\\'
          '\x1b_Ga=q,f=32,s=1,v=1,i=404,t=f;$regB64\x1b\\',
        );
        await tester.pump();
        expect(
          firstBackend.replies,
          equals(<String>[
            '\x1b_Gi=402;EINVAL:unsupported transmission medium\x1b\\',
            '\x1b_Gi=404;EINVAL:unsupported transmission medium\x1b\\',
          ]),
        );

        // Toggle Shared Memory OFF too and verify newly opened shell inherits all three.
        await tester.tap(
          find.byKey(const ValueKey('settings-kitty-shared-memory')),
        );
        await tester.pump();
        expect(ws.preferences.kittySharedMemoryMedium, isFalse);

        await ws.openLocalShellTab();
        expect(backends, hasLength(2));
        final sessions = router.sessions.values.toList();
        expect(sessions.last.terminal.allowLocalKittyMedia, isFalse);
        expect(sessions.last.terminal.allowLocalKittyFiles, isFalse);
        expect(sessions.last.terminal.allowLocalKittyShm, isFalse);

        // Resetting settings restores defaults and re-enables active shells live.
        ws.resetSettingsToDefaults();
        await tester.pump();
        expect(ws.preferences.kittyTempFileMedium, isTrue);
        expect(ws.preferences.kittyFileMedium, isTrue);
        expect(ws.preferences.kittySharedMemoryMedium, isTrue);
        expect(sessions.last.terminal.allowLocalKittyMedia, isTrue);
        expect(sessions.last.terminal.allowLocalKittyFiles, isTrue);
        expect(sessions.last.terminal.allowLocalKittyShm, isTrue);

        // Windows desktop shows t=t and t=f and hides POSIX t=s.
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
          find.byKey(const ValueKey('settings-kitty-file-medium')),
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

    testWidgets(
      'SettingsInterfaceSection toggles local clipboard writes and reads live on active local shells',
      (tester) async {
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
        final ws =
            _createWorkspace(
                storage: storage,
                driver: driver,
                clipboardReader: () async => 'secret-clip',
              )
              ..setWorkspaceVisible(true)
              ..setWindowFocused(true);
        addTearDown(() async {
          await ws.dispose();
          await driver.dispose();
        });

        await ws.openLocalShellTab();
        final backend = backends.first;
        const plainMimeB64 = 'dGV4dC9wbGFpbg==';

        // Defaults: write allowed (DONE), read blocked (EPERM).
        backend.emitOutput(
          '\x1b]5522;type=write:mime=$plainMimeB64:id=w1;aGk=\x1b\\'
          '\x1b]5522;type=read:id=r1;$plainMimeB64\x1b\\',
        );
        await tester.pump();
        expect(
          backend.replies,
          equals(<String>[
            '\x1b]5522;type=write:status=DONE:id=w1\x1b\\',
            '\x1b]5522;type=read:status=EPERM:id=r1\x1b\\',
          ]),
        );

        final palette = FtermOverlayPalette.fromTerminalTheme(
          ws.activeTerminalTheme,
        );
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData(platform: .linux),
            home: Scaffold(
              body: SingleChildScrollView(
                child: ListenableBuilder(
                  listenable: ws,
                  builder: (_, _) => SettingsInterfaceSection(
                    workspace: ws,
                    palette: palette,
                    isWeb: false,
                    platformOverride: .linux,
                  ),
                ),
              ),
            ),
          ),
        );

        expect(
          find.byKey(const ValueKey('settings-local-clipboard-write')),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey('settings-local-clipboard-read')),
          findsOneWidget,
        );

        // Toggle Local Clipboard Writes OFF and Local Clipboard Reads ON.
        await tester.tap(
          find.byKey(const ValueKey('settings-local-clipboard-write')),
        );
        await tester.tap(
          find.byKey(const ValueKey('settings-local-clipboard-read')),
        );
        await tester.pump();
        expect(ws.preferences.localClipboardWrite, isFalse);
        expect(ws.preferences.localClipboardRead, isTrue);

        backend.replies.clear();
        backend.emitOutput(
          '\x1b]5522;type=write:mime=$plainMimeB64:id=w2;aGk=\x1b\\'
          '\x1b]5522;type=read:id=r2;$plainMimeB64\x1b\\',
        );
        await tester.pump();
        expect(
          backend.replies,
          equals(<String>[
            '\x1b]5522;type=write:status=EPERM:id=w2\x1b\\',
            '\x1b]5522;type=read:status=OK:id=r2\x1b\\',
            '\x1b]5522;type=read:status=DATA:mime=$plainMimeB64:id=r2;'
                '${base64Encode(utf8.encode('secret-clip'))}\x1b\\',
            '\x1b]5522;type=read:status=DONE:id=r2\x1b\\',
          ]),
        );

        // Primary selection reads do not leak system clipboard text.
        backend.replies.clear();
        backend.emitOutput(
          '\x1b]52;p;?\x1b\\'
          '\x1b]5522;type=read:loc=primary:id=rp;$plainMimeB64\x1b\\',
        );
        await tester.pump();
        expect(
          backend.replies,
          equals(<String>[
            '\x1b]5522;type=read:status=OK:id=rp\x1b\\',
            '\x1b]5522;type=read:status=DONE:id=rp\x1b\\',
          ]),
        );

        // Unfocused window blocks reads even when Local Clipboard Reads is ON.
        ws.setWindowFocused(false);
        backend.replies.clear();
        backend.emitOutput('\x1b]5522;type=read:id=r3;$plainMimeB64\x1b\\');
        await tester.pump();
        expect(
          backend.replies,
          equals(<String>['\x1b]5522;type=read:status=EPERM:id=r3\x1b\\']),
        );
      },
    );

    test('default clipboardReader reads host Clipboard via platform channel and tolerates channel errors', () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      var throwError = false;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
            if (call.method == 'Clipboard.getData') {
              if (throwError) throw PlatformException(code: 'unavailable');
              return <String, Object?>{'text': 'host-platform-clip'};
            }
            return null;
          });
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(SystemChannels.platform, null);
      });

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
      final ws = _createWorkspace(storage: _MemStorage(), driver: driver)
        ..setWorkspaceVisible(true)
        ..setWindowFocused(true);
      ws.updatePreferences(ws.preferences.copyWith(localClipboardRead: true));
      addTearDown(() async {
        await ws.dispose();
        await driver.dispose();
      });

      await ws.openLocalShellTab();
      final backend = backends.first;
      const plainMimeB64 = 'dGV4dC9wbGFpbg==';

      backend.emitOutput('\x1b]5522;type=read:id=p1;$plainMimeB64\x1b\\');
      await Future<void>.microtask(() {});
      await Future<void>.microtask(() {});
      expect(
        backend.replies,
        equals(<String>[
          '\x1b]5522;type=read:status=OK:id=p1\x1b\\',
          '\x1b]5522;type=read:status=DATA:mime=$plainMimeB64:id=p1;'
              '${base64Encode(utf8.encode('host-platform-clip'))}\x1b\\',
          '\x1b]5522;type=read:status=DONE:id=p1\x1b\\',
        ]),
      );

      // Platform error falls back to empty DONE without throwing.
      throwError = true;
      backend.replies.clear();
      backend.emitOutput('\x1b]5522;type=read:id=p2;$plainMimeB64\x1b\\');
      await Future<void>.microtask(() {});
      await Future<void>.microtask(() {});
      expect(
        backend.replies,
        equals(<String>[
          '\x1b]5522;type=read:status=OK:id=p2\x1b\\',
          '\x1b]5522;type=read:status=DONE:id=p2\x1b\\',
        ]),
      );
    });
  });
}
