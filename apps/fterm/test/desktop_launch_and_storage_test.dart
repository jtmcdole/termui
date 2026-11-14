@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:clock/clock.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fterm/src/desktop_launch_env.dart';
import 'package:fterm/src/desktop_launch_env_io.dart';
import 'package:fterm/src/font_loader.dart';
import 'package:fterm/src/fterm_app.dart';
import 'package:fterm/src/settings_storage.dart';
import 'package:fterm/src/settings_storage_io.dart';
import 'package:fterm/src/workspace/fterm_workspace_controller.dart';
import 'package:material_ui/material_ui.dart' show Color, Scaffold;
import 'package:path/path.dart' as p;
import 'package:termui/termui.dart' show TerminalColorTheme;
import 'package:termui_cast_client_core/termui_cast_client_core.dart'
    show
        CastWorkspaceSettings,
        ClientConnectionState,
        DockPosition,
        TerminalThemeSettings,
        ThemeAppearanceMode;
import 'package:termui_cast_protocol/termui_cast_protocol.dart';
import 'package:termui_cast_protocol/termui_cast_protocol_io.dart';
import 'package:termui_flutter/termui_flutter.dart';

import 'support/app_three_way_harness.dart';

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    await loadCastFonts();
  });

  _defineDesktopLaunchConfigTests();
  _defineDesktopIapLaunchTests();
  _defineFileSettingsStorageUnitTests();
  _defineFileSettingsStorageWidgetTests();
  _defineThrottledSettingsSaverTests();
  _defineDesktopIapWidgetTests();
}

void _defineDesktopLaunchConfigTests() {
  group('Desktop CastLaunchConfig file:// and CLI/env resolution', () {
    test(
      'falls back cleanly to defaultServerUri across POSIX, Windows drive, and UNC file:// base URIs',
      () {
        for (final rawBase in const [
          'file:///Users/dev/termui_caster/apps/fterm/',
          'file:///C:/Users/dev/fterm/',
          'file://fileserver/share/fterm/',
        ]) {
          final unconfigured = resolveCastLaunchConfig(
            baseUri: Uri.parse(rawBase),
            environment: const {},
          );
          expect(
            unconfigured.serverUri,
            equals(CastLaunchConfig.defaultServerUri),
          );
          expect(unconfigured.token, isEmpty);
          expect(unconfigured.promptForConnection, isTrue);
        }

        // URL fragments on file:// base URIs must never auto-populate a token.
        final fileFragmentIgnored = resolveCastLaunchConfig(
          baseUri: Uri.parse('file:///tmp/index.html#token=untrusted-frag'),
          environment: const {},
        );
        expect(fileFragmentIgnored.token, isEmpty);
        expect(fileFragmentIgnored.promptForConnection, isTrue);

        // Providing a token alone on desktop connects to defaultServerUri without prompting.
        final tokenOnlyDesktop = resolveCastLaunchConfig(
          baseUri: Uri.parse('file:///Users/dev/fterm/'),
          environment: const {'TERMUI_CAST_TOKEN': 'dev-client'},
        );
        expect(
          tokenOnlyDesktop.serverUri,
          equals(CastLaunchConfig.defaultServerUri),
        );
        expect(tokenOnlyDesktop.token, equals('dev-client'));
        expect(tokenOnlyDesktop.promptForConnection, isFalse);
      },
    );

    test(
      'applies CLI > runtime environment > --dart-define precedence and ignores unknown platform flags',
      () {
        final desktopBase = Uri.parse('file:///Users/dev/fterm/');

        // 1. --dart-define fallback when CLI and runtime environment are empty.
        final fromDefines = resolveCastLaunchConfig(
          baseUri: desktopBase,
          environment: const {'TERMUI_CAST_SERVER_URL': '   '},
          defineServerUrl: 'ws://127.0.0.1:9001/v1/client',
          defineToken: 'define-tok',
        );
        expect(
          fromDefines.serverUri,
          equals(Uri.parse('ws://127.0.0.1:9001/v1/client')),
        );
        expect(fromDefines.token, equals('define-tok'));
        expect(fromDefines.promptForConnection, isFalse);

        // 2. Runtime environment overrides --dart-define.
        final fromEnv = resolveCastLaunchConfig(
          baseUri: desktopBase,
          environment: const {
            'TERMUI_CAST_SERVER_URL': 'wss://relay.example.com/v1/client',
            'TERMUI_CAST_TOKEN': 'env-tok',
          },
          defineServerUrl: 'ws://127.0.0.1:9001/v1/client',
          defineToken: 'define-tok',
        );
        expect(
          fromEnv.serverUri,
          equals(Uri.parse('wss://relay.example.com/v1/client')),
        );
        expect(fromEnv.token, equals('env-tok'));
        expect(fromEnv.promptForConnection, isFalse);

        // 3. CLI flags (--server/--url and --token, space and =) override runtime env and ignore OS flags & post-'--' args.
        final fromSpaceCli = resolveCastLaunchConfig(
          baseUri: desktopBase,
          args: const [
            '-NSDocumentRevisionsDebugMode',
            'YES',
            '--url',
            'ws://127.0.0.1:9440/v1/client',
            '--token',
            'cli-space-tok',
            '--',
            '--server',
            'ws://ignored.example/v1/client',
          ],
          environment: const {
            'TERMUI_CAST_SERVER_URL': 'wss://relay.example.com/v1/client',
            'TERMUI_CAST_TOKEN': 'env-tok',
          },
        );
        expect(
          fromSpaceCli.serverUri,
          equals(Uri.parse('ws://127.0.0.1:9440/v1/client')),
        );
        expect(fromSpaceCli.token, equals('cli-space-tok'));

        final fromEqualsCli = resolveCastLaunchConfig(
          baseUri: desktopBase,
          args: const [
            '--server=wss://cli.example.com/v1/client',
            '--token=base64+tok==',
          ],
          environment: const {
            'TERMUI_CAST_SERVER_URL': 'wss://relay.example.com/v1/client',
            'TERMUI_CAST_TOKEN': 'env-tok',
          },
        );
        expect(
          fromEqualsCli.serverUri,
          equals(Uri.parse('wss://cli.example.com/v1/client')),
        );
        expect(fromEqualsCli.token, equals('base64+tok=='));

        // Platform reader delegates cleanly to Platform.environment + CLI args.
        final ioOverrides = readPlatformLaunchOverrides(const [
          '--url=ws://127.0.0.1:8420/v1/client',
          '--token=io-tok',
        ]);
        expect(ioOverrides.serverUrl, equals('ws://127.0.0.1:8420/v1/client'));
        expect(ioOverrides.token, equals('io-tok'));

        for (final badArgs in const [
          ['--server'],
          ['--url'],
          ['--token'],
          ['--server=http://not-websocket.example/v1/client'],
          ['--server=ws://https://relay.run.app'],
          ['--server=wss://https://relay.run.app/v1/client'],
        ]) {
          expect(
            () => resolveCastLaunchConfig(
              baseUri: desktopBase,
              args: badArgs,
              environment: const {},
            ),
            throwsFormatException,
          );
        }

        // HTTPS, bare host, and /v1/caster relay URLs normalize to ws(s)://.../v1/client.
        final httpsRoot = resolveCastLaunchConfig(
          baseUri: desktopBase,
          args: const ['--server=https://relay.run.app'],
          environment: const {},
        );
        expect(
          httpsRoot.serverUri,
          equals(Uri.parse('wss://relay.run.app/v1/client')),
        );
        final httpsCasterPath = resolveCastLaunchConfig(
          baseUri: desktopBase,
          args: const ['--server=https://relay.run.app/v1/caster'],
          environment: const {},
        );
        expect(
          httpsCasterPath.serverUri,
          equals(Uri.parse('wss://relay.run.app/v1/client')),
        );
        final bareHost = resolveCastLaunchConfig(
          baseUri: desktopBase,
          args: const ['--server=relay.run.app'],
          environment: const {},
        );
        expect(
          bareHost.serverUri,
          equals(Uri.parse('wss://relay.run.app/v1/client')),
        );
        final bareLoopback = resolveCastLaunchConfig(
          baseUri: desktopBase,
          args: const ['--server=localhost:8420'],
          environment: const {},
        );
        expect(
          bareLoopback.serverUri,
          equals(Uri.parse('ws://localhost:8420/v1/client')),
        );
        final httpsCustom = resolveCastLaunchConfig(
          baseUri: desktopBase,
          environment: const {
            'TERMUI_CAST_SERVER_URL':
                'https://relay.run.app:8443/custom/client',
          },
        );
        expect(
          httpsCustom.serverUri,
          equals(Uri.parse('wss://relay.run.app:8443/custom/client')),
        );
      },
    );
  });
}

void _defineFileSettingsStorageUnitTests() {
  group('Desktop FileSettingsStorage and FLUTTER_TEST isolation', () {
    test(
      'resolves macOS/Linux and Windows settings paths and isolates storage under FLUTTER_TEST',
      () {
        expect(
          resolveDesktopSettingsFilePath(
            environment: const {'HOME': '/Users/alice'},
            isWindows: false,
          ),
          equals('/Users/alice/.config/fterm/settings.json'),
        );
        expect(
          resolveDesktopSettingsFilePath(
            environment: const {},
            isWindows: false,
          ),
          isNull,
        );
        expect(
          resolveDesktopSettingsFilePath(
            environment: const {'APPDATA': r'C:\Users\alice\AppData\Roaming'},
            isWindows: true,
          ),
          equals(r'C:\Users\alice\AppData\Roaming\fterm\settings.json'),
        );
        expect(
          resolveDesktopSettingsFilePath(
            environment: const {'USERPROFILE': r'C:\Users\alice'},
            isWindows: true,
          ),
          equals(r'C:\Users\alice\AppData\Roaming\fterm\settings.json'),
        );
        expect(
          resolveDesktopSettingsFilePath(
            environment: const {},
            isWindows: true,
          ),
          isNull,
        );

        final tempHome = Directory.systemTemp.createTempSync('fterm_home_');
        addTearDown(() => tempHome.deleteSync(recursive: true));

        // Under FLUTTER_TEST, createPlatformSettingsStorage & defaultSettingsStorage never touch HOME.
        final testIsolated = createPlatformSettingsStorage(
          environment: {'FLUTTER_TEST': 'true', 'HOME': tempHome.path},
          isWindows: false,
        );
        testIsolated.setItem(castSettingsStorageKey, '{"copyOnSelect":false}');
        expect(testIsolated.getItem(castSettingsStorageKey), isNull);
        defaultSettingsStorage.setItem(
          castSettingsStorageKey,
          '{"copyOnSelect":false}',
        );
        expect(defaultSettingsStorage.getItem(castSettingsStorageKey), isNull);
        expect(
          File(
            p.join(tempHome.path, '.config', 'fterm', 'settings.json'),
          ).existsSync(),
          isFalse,
        );

        // Outside FLUTTER_TEST, createPlatformSettingsStorage persists to <HOME>/.config/fterm/settings.json
        // with strict 0700 directory and 0600 file permissions on POSIX.
        final liveDesktop = createPlatformSettingsStorage(
          environment: {'HOME': tempHome.path},
          isWindows: false,
        );
        liveDesktop.setItem(castSettingsStorageKey, '{"copyOnSelect":false}');
        saveStoredRelayCredentials(
          liveDesktop,
          const RelayCredentials(
            serverUrl: 'wss://relay.example.com/v1/client',
            clientToken: 'viewer-secret',
            casterToken: 'caster-secret',
          ),
        );
        final settingsDir = Directory(
          p.join(tempHome.path, '.config', 'fterm'),
        );
        final settingsFile = File(p.join(settingsDir.path, 'settings.json'));
        expect(settingsFile.existsSync(), isTrue);
        expect(
          liveDesktop.getItem(castSettingsStorageKey),
          equals('{"copyOnSelect":false}'),
        );
        expect(
          loadStoredRelayCredentials(liveDesktop).casterToken,
          equals('caster-secret'),
        );
        if (!Platform.isWindows) {
          expect(settingsDir.statSync().mode & 0x1ff, equals(0x1c0));
          expect(settingsFile.statSync().mode & 0x1ff, equals(0x180));
        }

        // Legacy ~/.config/termui_cast/settings.json is read as fallback and migrated cleanly.
        final legacyHome = Directory.systemTemp.createTempSync('fterm_legacy_');
        addTearDown(() => legacyHome.deleteSync(recursive: true));
        final legacyFile = File(
          p.join(legacyHome.path, '.config', 'termui_cast', 'settings.json'),
        )..createSync(recursive: true);
        legacyFile.writeAsStringSync(
          jsonEncode({castSettingsStorageKey: '{"copyOnSelect":false}'}),
        );
        final migratedDesktop = createPlatformSettingsStorage(
          environment: {'HOME': legacyHome.path},
          isWindows: false,
        );
        expect(loadStoredSettings(migratedDesktop).copyOnSelect, isFalse);
        saveStoredRelayCredentials(
          migratedDesktop,
          const RelayCredentials(clientToken: 'migrated-token'),
        );
        expect(loadStoredSettings(migratedDesktop).copyOnSelect, isFalse);
        expect(
          loadStoredRelayCredentials(migratedDesktop).clientToken,
          equals('migrated-token'),
        );
      },
    );

    test(
      'round-trips CastWorkspaceSettings in a temp directory, supports nested JSON maps, and heals corrupt files',
      () {
        final tempDir = Directory.systemTemp.createTempSync(
          'termui_cast_settings_',
        );
        addTearDown(() => tempDir.deleteSync(recursive: true));

        final settingsFile = File(
          p.join(tempDir.path, 'nested', 'termui_cast', 'settings.json'),
        );
        final writer = FileSettingsStorage(settingsFile);
        expect(writer.getItem(castSettingsStorageKey), isNull);

        const saved = CastWorkspaceSettings(
          dockPosition: DockPosition.left,
          copyOnSelect: false,
          debugOverlayEnabled: true,
          f12ShortcutsEnabled: true,
          themeSettings: TerminalThemeSettings(
            appearanceMode: .light,
            darkThemeId: 'catppuccin_mocha',
            lightThemeId: 'solarized_light',
            minimumContrast: 4.5,
            boldIsBright: true,
            faintOpacity: 0.4,
            smartCursorColor: false,
          ),
        );
        saveStoredSettings(writer, saved);
        writer.setItem('other.key', 'preserved');

        final reader = FileSettingsStorage(settingsFile);
        final restored = loadStoredSettings(reader);
        expect(restored.dockPosition, equals(DockPosition.left));
        expect(restored.copyOnSelect, isFalse);
        expect(restored.debugOverlayEnabled, isTrue);
        expect(restored.f12ShortcutsEnabled, isTrue);
        expect(
          restored.themeSettings.appearanceMode,
          equals(ThemeAppearanceMode.light),
        );
        expect(restored.themeSettings.darkThemeId, equals('catppuccin_mocha'));
        expect(restored.themeSettings.lightThemeId, equals('solarized_light'));
        expect(restored.themeSettings.minimumContrast, equals(4.5));
        expect(restored.themeSettings.boldIsBright, isTrue);
        expect(restored.themeSettings.faintOpacity, equals(0.4));
        expect(restored.themeSettings.smartCursorColor, isFalse);
        expect(reader.getItem('other.key'), equals('preserved'));

        // Hand-edited unescaped JSON object under castSettingsStorageKey also loads cleanly.
        settingsFile.writeAsStringSync(
          jsonEncode({
            castSettingsStorageKey: {
              'dockPosition': 'hidden',
              'copyOnSelect': true,
            },
          }),
        );
        final fromNestedMap = loadStoredSettings(reader);
        expect(fromNestedMap.dockPosition, equals(DockPosition.hidden));

        // Corrupt JSON falls back safely on read and heals on next write.
        settingsFile.writeAsStringSync('{corrupt-json');
        expect(reader.getItem(castSettingsStorageKey), isNull);
        saveStoredSettings(writer, CastWorkspaceSettings.defaults);
        expect(
          loadStoredSettings(reader).dockPosition,
          equals(DockPosition.top),
        );
      },
    );
  });
}

void _defineFileSettingsStorageWidgetTests() {
  testWidgets(
    'loads file-backed SettingsStorage on startup, flushes edits to disk, and reloads external settings.json edits via Reload from Storage',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(640, 384));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final tempDir = Directory.systemTemp.createTempSync(
        'termui_cast_widget_',
      );
      addTearDown(() => tempDir.deleteSync(recursive: true));

      final settingsFile = File(
        p.join(tempDir.path, 'termui_cast', 'settings.json'),
      );
      final fileStorage = FileSettingsStorage(settingsFile);
      saveStoredSettings(
        fileStorage,
        const CastWorkspaceSettings(
          themeSettings: TerminalThemeSettings(
            appearanceMode: .dark,
            darkThemeId: 'catppuccin_mocha',
            faintOpacity: 0.65,
          ),
        ),
      );

      final harness = AppThreeWayWsHarness();
      await tester.runAsync(
        () => harness.startCaster(id: 'desk-s1', title: 'zsh'),
      );

      FtermWorkspaceController? workspace;
      await tester.pumpWidget(
        FtermApp(
          config: CastLaunchConfig(token: harness.token),
          channelFactory: harness.openClientChannel,
          resizeDebounce: Duration.zero,
          settingsStorage: fileStorage,
          onWorkspaceCreated: (ws) => workspace = ws,
        ),
      );
      await settleCastApp(tester);

      expect(workspace, isNotNull);
      expect(
        tester.widget<TerminalSurface>(find.byType(TerminalSurface)).palette.id,
        equals('catppuccin_mocha'),
      );

      // Mutating a setting in the workspace persists directly to settings.json on disk.
      workspace!.setCopyOnSelect(false);
      expect(
        loadStoredSettings(FileSettingsStorage(settingsFile)).copyOnSelect,
        isFalse,
      );

      // Simulate editing settings.json externally on disk, then invoking Reload from Storage.
      saveStoredSettings(
        FileSettingsStorage(settingsFile),
        const CastWorkspaceSettings(
          copyOnSelect: true,
          themeSettings: TerminalThemeSettings(
            appearanceMode: .light,
            lightThemeId: 'solarized_light',
            faintOpacity: 0.35,
          ),
        ),
      );

      expect(workspace!.reloadSettingsFromStorage(), isTrue);
      await tester.pump();

      expect(workspace!.copyOnSelect, isTrue);
      expect(workspace!.activeTerminalTheme.id, equals('solarized_light'));
      final terminal = tester.widget<TerminalSurface>(
        find.byType(TerminalSurface),
      );
      final scaffold = tester.widget<Scaffold>(find.byType(Scaffold).first);
      final expectedBg = Color(
        TerminalColorTheme.solarizedLight.background.argb,
      );
      expect(terminal.palette.id, equals('solarized_light'));
      expect(terminal.faintOpacity, equals(0.35));
      expect(terminal.backgroundColor, equals(expectedBg));
      expect(scaffold.backgroundColor, equals(expectedBg));

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(harness.dispose);
    },
  );
}

const String _iapLoopbackCertPem = '''
-----BEGIN CERTIFICATE-----
MIIBXjCCAQSgAwIBAgIULU3zm1zY44xP1dipeoCjSC/8K70wCgYIKoZIzj0EAwIw
FDESMBAGA1UEAwwJMTI3LjAuMC4xMCAXDTI2MTAzMTA0MDU0M1oYDzIxMjYxMDA3
MDQwNTQzWjAUMRIwEAYDVQQDDAkxMjcuMC4wLjEwWTATBgcqhkjOPQIBBggqhkjO
PQMBBwNCAAT6yG8zLGFj+MjDuYRd1ADtqLt5rTI8w4exRE3P94LpwktT6JM3sijt
RxSUJM5sfrP/nuLlt0ybG+f2ZAfvG8sOozIwMDAdBgNVHQ4EFgQUKyz+9Glq20Rm
nJ0YWXDYbbbE1d4wDwYDVR0TAQH/BAUwAwEB/zAKBggqhkjOPQQDAgNIADBFAiEA
uYj8rkQ0YjvzlQEAK+n0RKl/u3RajZVX6AegRkn32rQCIHjGmHCbsMIbqGi+tuMy
Kd7O/JigQBUF35okHmv7/y+N
-----END CERTIFICATE-----
''';

const String _iapLoopbackKeyPem = '''
-----BEGIN PRIVATE KEY-----
MIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQgcnEPuDznhktG/80D
VI1RW5oy4n+z93IGlv9cLtYJuBOhRANCAAT6yG8zLGFj+MjDuYRd1ADtqLt5rTI8
w4exRE3P94LpwktT6JM3sijtRxSUJM5sfrP/nuLlt0ybG+f2ZAfvG8sO
-----END PRIVATE KEY-----
''';

const String _iapRsaKeyPem = '''
-----BEGIN PRIVATE KEY-----
MIICdQIBADANBgkqhkiG9w0BAQEFAASCAl8wggJbAgEAAoGBAKEbjO9lhv9IyH7m
FdUnxE9DeZhlOpUv6m24yYDzGKODSXUKkP5j3ulvCjIlFkRZNtC/zxCEdCFzIy60
jCgWOzgNSi50xrprE4vbPssG5G7Nssv6UX+rY5p2DEmS+Ivy+Szn4xb4KkYlncgm
fXAsTV71MAHHcmh9OXs9T0Hsf4KzAgMBAAECgYAuUtmnTC4Q4UClHEtSyuhrUh94
bkL1+p0Rh3yJE10WRv2sJamjO9wwirkHyhoo9O4J/9zuBufNZmnLWCaksB++fWnH
AuuA9xf7TC/TMUxETYCGrFBAWB2VM+tJn2/7OSdYzLByUZPY4DW3t/74c4TaLk/H
J/tRc3cINOfmwCUgAQJBAMt3XQgEm8QmGnoC1UtUr2iVS8/NIKgF0j1ERPPHLN2E
7rUjHQC3J78CSetCFQzm1NBEELJwI7WqSbEym+raTrMCQQDKtGGi2P+yYW2gxUms
kh3sk2sEHNfA74Gquj+1LduCUX4aR5IKDycKTSJtInY0d5RfJgMgYwfFbvlOKWxZ
n/wBAkAX0lTREIEQOQnWiShh1ntm+jvTC4gsQ+o2hByykfo9wUeVa5QEtmzv3xu6
cJU4WnpGHAH8ckasCVDxbyR0HbUjAkAdGt1SBppgQID/LpSvhKNrTpd1Fbcc6sbR
fsCbASSdh5n1qAUeEKLoZb7lsKcMTYcuSkT0p4N8I70ELgpyq/gBAkB0cyb73k5w
AcUmR6oniiNfTkhtwRerwKrdqSbSjEbxlevwqqQnM1+Kl1vKC0Tyy8WM5yVuQkAJ
EwFSx/7Q3CSd
-----END PRIVATE KEY-----
''';

void _defineDesktopIapLaunchTests() {
  group('Desktop Cloud Run IAP CLI and environment resolution', () {
    late Directory tempDir;
    late File keyFile;
    final desktopBase = Uri.parse('file:///Users/dev/fterm/');

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('desktop_iap_cfg_');
      keyFile = File(p.join(tempDir.path, 'sa.json'))
        ..writeAsStringSync(
          jsonEncode(<String, Object>{
            'client_email': 'desktop-viewer@proj.iam.gserviceaccount.com',
            'private_key_id': 'kid-desktop',
            'private_key': _iapRsaKeyPem,
          }),
        );
    });

    tearDown(() {
      tempDir.deleteSync(recursive: true);
    });

    test(
      'resolves --iap-key-file and --iap-service-account with CLI > env precedence and ws:// env ignore',
      () async {
        // 1. Ambient TERMUI_CAST_IAP_* ignored on default ws:// loopback.
        final loopbackCfg = resolveCastLaunchConfig(
          baseUri: desktopBase,
          environment: <String, String>{
            'TERMUI_CAST_IAP_KEY_FILE': keyFile.path,
            'TERMUI_CAST_IAP_SERVICE_ACCOUNT':
                'ambient@proj.iam.gserviceaccount.com',
          },
        );
        expect(loopbackCfg.iapTokenProvider, isNull);

        // 2. Ambient TERMUI_CAST_IAP_KEY_FILE activates when defineServerUrl or --server uses wss://.
        final envKeyCfg = resolveCastLaunchConfig(
          baseUri: desktopBase,
          defineServerUrl: 'wss://relay.run.app/v1/client',
          environment: <String, String>{
            'TERMUI_CAST_IAP_KEY_FILE': keyFile.path,
          },
        );
        expect(envKeyCfg.iapTokenProvider, isNotNull);
        final jwt = await envKeyCfg.iapTokenProvider!();
        final payload =
            jsonDecode(
                  utf8.decode(
                    base64Url.decode(base64Url.normalize(jwt.split('.')[1])),
                  ),
                )
                as Map<String, Object?>;
        expect(
          payload['iss'],
          equals('desktop-viewer@proj.iam.gserviceaccount.com'),
        );
        expect(payload['aud'], equals('https://relay.run.app/v1/client'));

        // Sharing derives /v1/caster and must mint an IAP JWT targeting /v1/caster, not /v1/client.
        final casterProvider = envKeyCfg.iapTokenProviderFor(
          envKeyCfg.casterServerUri,
        );
        expect(casterProvider, isNotNull);
        final casterJwt = await casterProvider!();
        final casterPayload =
            jsonDecode(
                  utf8.decode(
                    base64Url.decode(
                      base64Url.normalize(casterJwt.split('.')[1]),
                    ),
                  ),
                )
                as Map<String, Object?>;
        expect(casterPayload['aud'], equals('https://relay.run.app/v1/caster'));

        // 3. Explicit --iap-service-account on CLI overrides TERMUI_CAST_IAP_KEY_FILE in env without conflict.
        final cliAccountCfg = resolveCastLaunchConfig(
          baseUri: desktopBase,
          args: const [
            '--server=wss://relay.run.app/v1/client',
            '--iap-service-account=cli-sa@proj.iam.gserviceaccount.com',
          ],
          environment: <String, String>{
            'TERMUI_CAST_IAP_KEY_FILE': keyFile.path,
          },
          iapProviderBuilder:
              ({required serverUri, serviceAccount, keyFilePath}) =>
                  buildPlatformIapTokenProvider(
                    serverUri: serverUri,
                    serviceAccount: serviceAccount,
                    keyFilePath: keyFilePath,
                    clock: Clock.fixed(DateTime.utc(2026, 11, 10)),
                    processRunner: (_, arguments) async {
                      await File(
                        arguments.last,
                      ).writeAsString('gcloud-signed-jwt\n');
                      return ProcessResult(1, 0, '', '');
                    },
                  ),
        );
        expect(
          await cliAccountCfg.iapTokenProvider!(),
          equals('gcloud-signed-jwt'),
        );
      },
    );

    test(
      'rejects conflicting flags, ws:// CLI flags, invalid emails, and bad key files',
      () {
        final badInvocations = <void Function()>[
          // Both CLI flags.
          () => resolveCastLaunchConfig(
            baseUri: desktopBase,
            args: [
              '--server=wss://relay.run.app/v1/client',
              '--iap-service-account=sa@proj.iam.gserviceaccount.com',
              '--iap-key-file=${keyFile.path}',
            ],
            environment: const {},
          ),
          // Both env vars on wss://.
          () => resolveCastLaunchConfig(
            baseUri: desktopBase,
            args: const ['--server=wss://relay.run.app/v1/client'],
            environment: <String, String>{
              'TERMUI_CAST_IAP_SERVICE_ACCOUNT':
                  'sa@proj.iam.gserviceaccount.com',
              'TERMUI_CAST_IAP_KEY_FILE': keyFile.path,
            },
          ),
          // Explicit CLI IAP flag on ws://.
          () => resolveCastLaunchConfig(
            baseUri: desktopBase,
            args: ['--iap-key-file', keyFile.path],
            environment: const {},
          ),
          // Blank explicit CLI flag value.
          () => resolveCastLaunchConfig(
            baseUri: desktopBase,
            args: const [
              '--server=wss://relay.run.app/v1/client',
              '--iap-service-account=',
            ],
            environment: const {},
          ),
          // Invalid email format.
          () => resolveCastLaunchConfig(
            baseUri: desktopBase,
            args: const [
              '--server=wss://relay.run.app/v1/client',
              '--iap-service-account=not-an-email',
            ],
            environment: const {},
          ),
          // Missing key file on disk.
          () => resolveCastLaunchConfig(
            baseUri: desktopBase,
            args: [
              '--server=wss://relay.run.app/v1/client',
              '--iap-key-file=${p.join(tempDir.path, "missing.json")}',
            ],
            environment: const {},
          ),
        ];

        for (final call in badInvocations) {
          expect(call, throwsFormatException);
        }
      },
    );

    test(
      'reportPlatformStartupError swallows IOException and skips exit under FLUTTER_TEST',
      () {
        final buffer = StringBuffer();
        int? exitedCode;
        reportPlatformStartupError(
          'bad --iap-key-file',
          err: buffer,
          environment: const {'FLUTTER_TEST': 'true'},
          onExit: (code) => exitedCode = code,
        );
        expect('$buffer', contains('fterm: bad --iap-key-file'));
        expect(exitedCode, isNull);

        reportPlatformStartupError(
          'detached console failure',
          err: _ThrowingStdoutSink(),
          environment: const {},
          onExit: (code) => exitedCode = code,
        );
        expect(exitedCode, equals(64));

        final connectErrBuf = StringBuffer();
        logPlatformConnectError(
          const SocketException('dial failed'),
          err: connectErrBuf,
        );
        expect(
          '$connectErrBuf',
          contains('fterm: connect failed: SocketException'),
        );
      },
    );
  });
}

void _defineDesktopIapWidgetTests() {
  testWidgets(
    'CastApp upgrades over loopback wss:// with RS256 IAP Authorization header and binary AuthFrame token',
    (tester) async {
      final tempDir = Directory.systemTemp.createTempSync('cast_app_iap_wss_');
      addTearDown(() => tempDir.deleteSync(recursive: true));

      final keyFile = File(p.join(tempDir.path, 'sa.json'))
        ..writeAsStringSync(
          jsonEncode(<String, Object>{
            'client_email': 'app-viewer@proj.iam.gserviceaccount.com',
            'private_key_id': 'kid-live',
            'private_key': _iapRsaKeyPem,
          }),
        );

      String? capturedUpgradeAuth;
      String? capturedViewerToken;
      final server = await tester.runAsync(() async {
        final ctx = SecurityContext()
          ..useCertificateChainBytes(_iapLoopbackCertPem.codeUnits)
          ..usePrivateKeyBytes(_iapLoopbackKeyPem.codeUnits);
        final bound = await HttpServer.bindSecure(
          InternetAddress.loopbackIPv4,
          0,
          ctx,
        );
        bound.listen((req) async {
          capturedUpgradeAuth = req.headers.value(
            HttpHeaders.authorizationHeader,
          );
          if (capturedUpgradeAuth == null ||
              !capturedUpgradeAuth!.startsWith('Bearer eyJ')) {
            req.response.statusCode = HttpStatus.unauthorized;
            await req.response.close();
            return;
          }
          final (:channel, closeWithCode: _) = await upgradeCastWebSocket(req);
          channel.stream.listen((raw) {
            final msg = BufferFrameCodec.decode(raw);
            if (msg is AuthFrame) {
              capturedViewerToken = msg.token;
              channel.sink.add(
                BufferFrameCodec.encode(const AuthAcceptedFrame(role: .client)),
              );
            }
          });
        });
        return bound;
      });
      addTearDown(() => tester.runAsync(() => server!.close(force: true)));

      final config = resolveCastLaunchConfig(
        baseUri: Uri.parse('file:///Users/dev/fterm/'),
        args: [
          '--server=wss://127.0.0.1:${server!.port}/v1/client',
          '--token=desktop-viewer-secret',
          '--iap-key-file=${keyFile.path}',
        ],
        environment: const {},
      );

      FtermWorkspaceController? workspace;
      await tester.pumpWidget(
        FtermApp(
          config: config,
          resizeDebounce: Duration.zero,
          onWorkspaceCreated: (ws) => workspace = ws,
        ),
      );
      await tester.pump();
      await tester.runAsync(
        () => HttpOverrides.runZoned(
          () async {
            await workspace!.repository.reconnect((
              serverUri: config.serverUri,
              token: config.token,
            ));
            final deadline = DateTime.now().add(const Duration(seconds: 4));
            while (workspace?.connectionState !=
                ClientConnectionState.authenticated) {
              if (DateTime.now().isAfter(deadline)) {
                throw TimeoutException(
                  'Timed out awaiting FtermApp wss:// auth',
                );
              }
              await Future<void>.delayed(const Duration(milliseconds: 20));
            }
            await workspace!.repository.dispose();
          },
          createHttpClient: (context) =>
              _LoopbackTrustHttpOverrides().createHttpClient(context),
        ),
      );
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 6));

      expect(capturedUpgradeAuth, startsWith('Bearer eyJ'));
      expect(capturedViewerToken, equals('desktop-viewer-secret'));
      expect(
        workspace!.connectionState,
        equals(ClientConnectionState.authenticated),
      );
    },
  );
}

final class _ThrowingStdoutSink implements StringSink {
  @override
  void write(Object? object) =>
      throw const StdoutException('No console attached');

  @override
  void writeAll(Iterable<Object?> objects, [String separator = '']) =>
      write(objects);

  @override
  void writeCharCode(int charCode) => write(charCode);

  @override
  void writeln([Object? object = '']) => write(object);
}

final class _LoopbackTrustHttpOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    return super.createHttpClient(context)
      ..badCertificateCallback = (_, host, _) => host == '127.0.0.1';
  }
}

void _defineThrottledSettingsSaverTests() {
  group('ThrottledSettingsSaver', () {
    testWidgets(
      'writes leading immediately, coalesces rapid updates into trailing write at 200ms, and resets to idle after quiet cooldown',
      (tester) async {
        final storage = _CountingSettingsStorage();
        final saver = ThrottledSettingsSaver(storage);

        const s1 = CastWorkspaceSettings(copyOnSelect: false);
        const s2 = CastWorkspaceSettings(
          copyOnSelect: false,
          debugOverlayEnabled: true,
        );
        const s3 = CastWorkspaceSettings(
          copyOnSelect: false,
          debugOverlayEnabled: true,
          f12ShortcutsEnabled: true,
        );
        const s4 = CastWorkspaceSettings(dockPosition: DockPosition.left);

        saver.save(s1);
        expect(storage.writeCount, equals(1));
        expect(loadStoredSettings(storage), equals(s1));

        saver
          ..save(s2)
          ..save(s3);
        expect(storage.writeCount, equals(1));

        await tester.pump(const Duration(milliseconds: 200));
        expect(storage.writeCount, equals(2));
        expect(loadStoredSettings(storage), equals(s3));

        // After one quiet cooldown window, the next save writes on the leading edge again.
        await tester.pump(const Duration(milliseconds: 200));
        saver.save(s4);
        expect(storage.writeCount, equals(3));
        expect(loadStoredSettings(storage), equals(s4));
        saver.dispose();
      },
    );

    testWidgets(
      'cancelPending prevents stale trailing write from overwriting reloaded storage and resets leading edge',
      (tester) async {
        final storage = _CountingSettingsStorage();
        final saver = ThrottledSettingsSaver(storage);

        const initial = CastWorkspaceSettings(copyOnSelect: false);
        const staleQueued = CastWorkspaceSettings(debugOverlayEnabled: true);
        const reloadedOnDisk = CastWorkspaceSettings(f12ShortcutsEnabled: true);
        const afterReload = CastWorkspaceSettings(
          dockPosition: DockPosition.hidden,
        );

        saver
          ..save(initial)
          ..save(staleQueued);
        expect(storage.writeCount, equals(1));

        saver.cancelPending();
        saveStoredSettings(storage, reloadedOnDisk);
        final writesAfterExternalReload = storage.writeCount;

        await tester.pump(const Duration(milliseconds: 250));
        expect(storage.writeCount, equals(writesAfterExternalReload));
        expect(loadStoredSettings(storage), equals(reloadedOnDisk));

        saver.save(afterReload);
        expect(storage.writeCount, equals(writesAfterExternalReload + 1));
        expect(loadStoredSettings(storage), equals(afterReload));
        saver.dispose();
      },
    );

    testWidgets(
      'flush keeps saver active, dispose flushes once and ignores post-dispose saves, and _onCooldownDone recovers from throw',
      (tester) async {
        final storage = _CountingSettingsStorage();
        final saver = ThrottledSettingsSaver(storage);

        const s1 = CastWorkspaceSettings(copyOnSelect: false);
        const s2 = CastWorkspaceSettings(debugOverlayEnabled: true);
        const s3 = CastWorkspaceSettings(f12ShortcutsEnabled: true);
        const s4 = CastWorkspaceSettings(dockPosition: DockPosition.left);

        saver
          ..save(s1)
          ..save(s2)
          ..flush();
        expect(storage.writeCount, equals(2));
        expect(loadStoredSettings(storage), equals(s2));

        // Saver remains usable and idle after flush(), then recovers if a cooldown write throws once.
        final errors = <Object>[];
        await runZonedGuarded(() async {
          saver.save(s3);
          expect(storage.writeCount, equals(3));
          storage.throwOnNextSetItem = true;
          saver.save(s4);
          await tester.pump(const Duration(milliseconds: 200));
        }, (error, _) => errors.add(error));
        expect(errors, hasLength(1));

        // After the failed cooldown write, _cooldownTimer was cleared so the next save recovers immediately.
        saver.save(s4);
        expect(storage.writeCount, equals(4));
        expect(loadStoredSettings(storage), equals(s4));

        // dispose() flushes pending s1 and ignores subsequent save() calls.
        saver
          ..save(s1)
          ..dispose();
        expect(storage.writeCount, equals(5));
        expect(loadStoredSettings(storage), equals(s1));

        saver.save(s2);
        expect(storage.writeCount, equals(5));
        expect(loadStoredSettings(storage), equals(s1));
      },
    );

    testWidgets(
      'flushes pending trailing settings synchronously on AppLifecycleState.paused in CastApp',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(640, 384));
        addTearDown(() {
          tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.resumed,
          );
          return tester.binding.setSurfaceSize(null);
        });

        final storage = _CountingSettingsStorage();
        final harness = AppThreeWayWsHarness();
        await tester.runAsync(
          () => harness.startCaster(id: 'lifecycle-flush', title: 'zsh'),
        );

        FtermWorkspaceController? workspace;
        await tester.pumpWidget(
          FtermApp(
            config: CastLaunchConfig(token: harness.token),
            channelFactory: harness.openClientChannel,
            resizeDebounce: Duration.zero,
            settingsStorage: storage,
            onWorkspaceCreated: (ws) => workspace = ws,
          ),
        );
        await settleCastApp(tester);

        storage.writeCount = 0;
        workspace!.setCopyOnSelect(false);
        workspace!.updateWorkspaceSettings(
          workspace!.workspaceSettings.copyWith(debugOverlayEnabled: true),
        );
        expect(storage.writeCount, equals(1));
        expect(loadStoredSettings(storage).debugOverlayEnabled, isFalse);

        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
        await tester.pump();
        expect(storage.writeCount, equals(2));
        expect(loadStoredSettings(storage).debugOverlayEnabled, isTrue);

        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(harness.dispose);
      },
    );
  });
}

final class _CountingSettingsStorage implements SettingsStorage {
  final Map<String, String> _entries = {};
  int writeCount = 0;
  bool throwOnNextSetItem = false;

  @override
  String? getItem(String key) => _entries[key];

  @override
  void setItem(String key, String value) {
    if (throwOnNextSetItem) {
      throwOnNextSetItem = false;
      throw StateError('Simulated storage write failure');
    }
    writeCount++;
    _entries[key] = value;
  }
}
