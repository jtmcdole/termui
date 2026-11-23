import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fterm/src/audio/fterm_audio_controller.dart';
import 'package:fterm/src/font_loader.dart';
import 'package:fterm/src/launch_config.dart';
import 'package:fterm/src/settings_storage.dart';
import 'package:fterm/src/shader_profile_store.dart';
import 'package:fterm/src/ui/fterm_shell_scaffold.dart';
import 'package:fterm/src/update/update_service.dart';
import 'package:fterm/src/workspace/fterm_workspace_controller.dart';
import 'package:fterm/src/workspace/local_host_driver.dart';
import 'package:material_ui/material_ui.dart';
import 'package:termui/termui.dart' as tui;
import 'package:termui_cast_client_core/termui_cast_client_core.dart';
import 'package:termui_cast_protocol/termui_cast_protocol.dart';
import 'package:termui_pty/termui_pty.dart';

final class _MemorySettingsStorage implements SettingsStorage {
  final Map<String, String> data = <String, String>{};

  @override
  String? getItem(String key) => data[key];

  @override
  void setItem(String key, String value) {
    data[key] = value;
  }
}

final class _FakeShaderProfileStore implements ShaderProfileStore {
  @override
  final String? shadersDirectoryPath;

  _FakeShaderProfileStore({this.shadersDirectoryPath = '/tmp/fterm/shaders'});

  @override
  Future<List<String>> listShaderFiles() async => const <String>[];

  @override
  Future<String> loadShaderSource(String pathOrKey) =>
      Future<String>.error(StateError('unused'));

  @override
  Future<Uint8List> loadWallpaperBytes(String pathOrKey) =>
      Future<Uint8List>.error(StateError('unused'));

  @override
  Future<void> saveShaderSource(String name, String glslSource) async {}

  @override
  Future<void> saveWallpaperBytes(String key, Uint8List bytes) async {}

  @override
  Stream<ShaderDirectoryChange> watchShaderDirectory() =>
      const Stream<ShaderDirectoryChange>.empty();

  @override
  void dispose() {}
}

final class _FixedVersionUpdateService implements UpdateService {
  @override
  final FtermSemVer currentVersion;

  _FixedVersionUpdateService(this.currentVersion);

  @override
  SelfUpdateCapability get capability =>
      SelfUpdateCapability.readOnlyOrNonPortable;

  @override
  Future<UpdateCheckOutcome> checkForUpdates({
    required bool includePrereleases,
    String? lastEtag,
    List<String> cachedTags = const [],
  }) async => UpdateCheckOutcome(
    availableUpdate: null,
    tagEtag: lastEtag,
    cachedTags: cachedTags,
    cacheTagState: false,
  );

  @override
  Future<StagedUpdate> stageUpdate(
    AvailableUpdate update, {
    void Function(DownloadProgress progress)? onProgress,
  }) => Future<StagedUpdate>.error(UnsupportedError('unused'));

  @override
  bool hasSiblingInstances() => false;

  @override
  bool prepareExclusiveSwapLock() => false;

  @override
  void cancelExclusiveSwapLock() {}

  @override
  Future<void> applyStagedUpdateAndExit(
    StagedUpdate staged, {
    required bool relaunch,
    List<String> relaunchArgs = const [],
    Future<void> Function()? beforeExitTeardown,
  }) async {}

  @override
  Future<void> revealStagedInFinder(StagedUpdate staged) async {}

  @override
  Future<void> runStartupCleanup() async {}

  @override
  void dispose() {}
}

final class _StubPtyBackend implements RoutedPtyBackend {
  final StreamController<Uint8List> _out =
      StreamController<Uint8List>.broadcast();
  final Completer<int> _exit = Completer<int>();

  @override
  Stream<Uint8List> get output => _out.stream;

  @override
  Future<int> get exitCode => _exit.future;

  @override
  void write(Uint8List data) {}

  @override
  void resize(int cols, int rows, {int pixelWidth = 0, int pixelHeight = 0}) {}

  @override
  void kill() {
    if (!_exit.isCompleted) _exit.complete(0);
  }

  @override
  Future<void> dispose() async {
    kill();
    await _out.close();
  }
}

final class _FakeLocalPaneHost implements LocalPaneHost {
  @override
  final String id;

  final PtyRouterSession _session;

  @override
  final TerminalPort port;

  bool _disposed = false;

  _FakeLocalPaneHost(this.id, this._session, this.port);

  @override
  Future<int> get exitCode => _session.exitCode;

  @override
  LocalShareSnapshot get shareSnapshot => LocalShareSnapshot.unshared;

  @override
  Stream<LocalShareSnapshot> get shareUpdates =>
      const Stream<LocalShareSnapshot>.empty();

  @override
  bool isLiveRowWrapped(int row) => false;

  @override
  void setColorScheme(tui.TerminalBrightness brightness) {}

  @override
  Future<SessionId> startShare({
    required Uri serverUri,
    required String casterToken,
    required String title,
    String? uploadDirPath,
    IapTokenProvider? iapTokenProvider,
    CasterTransportOpener? channelOpener,
  }) => throw UnimplementedError();

  @override
  Future<void> stopShare() async {}

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await port.dispose();
    await _session.dispose();
  }
}

final class _FakeLocalHostDriver implements LocalHostDriver {
  final PtyRouter _router = PtyRouter();
  final List<_FakeLocalPaneHost> _hosts = <_FakeLocalPaneHost>[];
  int _counter = 0;

  @override
  bool get isSupported => true;

  @override
  Future<LocalPaneHost> openShell(LocalShellConfig config) async {
    final session = _router.createSession(
      backend: _StubPtyBackend(),
      initialCols: 40,
      initialRows: 12,
    );
    final port = session.openPort(initialCols: 40, initialRows: 12);
    final host = _FakeLocalPaneHost('local-${++_counter}', session, port);
    _hosts.add(host);
    return host;
  }

  @override
  Future<void> dispose() async {
    for (final host in _hosts) {
      await host.dispose();
    }
    await _router.dispose();
  }
}

final class _WhatsNewHarness {
  final _MemorySettingsStorage storage;
  final List<String> openedDirectories = <String>[];
  late final FtermWorkspaceController workspace;

  _WhatsNewHarness({
    _MemorySettingsStorage? storage,
    FtermSemVer? currentVersion,
    bool isWeb = false,
  }) : storage = storage ?? _MemorySettingsStorage() {
    final transport = WsClientTransport(
      serverUri: Uri.parse('ws://127.0.0.1:9/v1/client'),
    );
    workspace = FtermWorkspaceController(
      launchConfig: CastLaunchConfig(promptForConnection: false),
      repository: CastClientRepository(transport: transport),
      localHostDriver: isWeb ? createLocalHostDriver() : _FakeLocalHostDriver(),
      audioController: FtermAudioController(),
      storage: this.storage,
      resizeDebounce: Duration.zero,
      updateService: currentVersion != null
          ? _FixedVersionUpdateService(currentVersion)
          : createPlatformUpdateService(),
      shaderProfileStore: _FakeShaderProfileStore(
        shadersDirectoryPath: isWeb ? null : '/tmp/fterm/shaders',
      ),
      openDirectoryHandler: (dir) async {
        openedDirectories.add(dir);
      },
    );
  }

  Future<void> dispose() => workspace.dispose();
}

Widget _buildScaffoldApp(
  FtermWorkspaceController workspace, {
  bool isWeb = false,
  TargetPlatform platform = TargetPlatform.windows,
}) => MaterialApp(
  debugShowCheckedModeBanner: false,
  themeMode: ThemeMode.dark,
  darkTheme: ThemeData(
    brightness: Brightness.dark,
    fontFamily: castPrimaryFontFamily,
    fontFamilyFallback: castFallbackFontFamilies,
  ),
  home: FtermShellScaffold(
    workspace: workspace,
    onOpenUrl: (_) {},
    platformOverride: platform,
    isWebOverride: isWeb,
  ),
);

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    await loadCastFonts();
  });

  group('FtermPreferences.lastSeenWhatsNewVersion persistence', () {
    test('decodes missing key to null, round-trips JSON, and supports copyWith/clear', () {
      const legacyJson = '{"audioMuted":true,"audioVolume":0.5}';
      final legacy = FtermPreferences.fromJsonString(legacyJson);
      expect(legacy.lastSeenWhatsNewVersion, isNull);
      expect(legacy.toJsonString(), isNot(contains('lastSeenWhatsNewVersion')));

      final seen = legacy.copyWith(lastSeenWhatsNewVersion: ' 0.3.0 ');
      expect(seen.lastSeenWhatsNewVersion, equals('0.3.0'));
      expect(seen, isNot(equals(legacy)));

      final roundTripped = FtermPreferences.fromJsonString(seen.toJsonString());
      expect(roundTripped, equals(seen));
      expect(roundTripped.hashCode, equals(seen.hashCode));
      expect(roundTripped.lastSeenWhatsNewVersion, equals('0.3.0'));

      final blank = seen.copyWith(lastSeenWhatsNewVersion: '   ');
      expect(blank.lastSeenWhatsNewVersion, isNull);

      final cleared = seen.copyWith(clearLastSeenWhatsNewVersion: true);
      expect(cleared.lastSeenWhatsNewVersion, isNull);
      expect(cleared, equals(legacy));
    });
  });

  group('What\'s New tab-bar pill & interactive Try-It modal', () {
    testWidgets(
      'shows non-blocking NEW pill until viewed, persists version, and adapts cleanly to left rail and narrow 320px surfaces',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(960, 640));
        addTearDown(() => tester.binding.setSurfaceSize(null));

        final env = _WhatsNewHarness(currentVersion: FtermSemVer(0, 3, 0));
        addTearDown(() => tester.runAsync(env.dispose));
        await tester.runAsync(env.workspace.start);

        await tester.pumpWidget(_buildScaffoldApp(env.workspace));
        await tester.pump();

        // Never auto-pops on startup.
        expect(env.workspace.activeOverlay, equals(FtermOverlay.none));
        expect(env.workspace.shouldShowWhatsNewPill, isTrue);
        expect(
          find.byKey(const ValueKey('fterm-whats-new-pill')),
          findsOneWidget,
        );
        expect(find.text('NEW'), findsOneWidget);

        // Narrow 320px top bar renders compact sparkle pill with zero overflow.
        await tester.binding.setSurfaceSize(const Size(320, 480));
        await tester.pump();
        expect(
          find.byKey(const ValueKey('fterm-whats-new-pill')),
          findsOneWidget,
        );
        expect(find.text('NEW'), findsNothing);
        expect(tester.takeException(), isNull);

        // Left rail dock renders compact sparkle badge with zero overflow.
        await tester.binding.setSurfaceSize(const Size(960, 640));
        env.workspace.setDockPosition(DockPosition.left);
        await tester.pump();
        expect(
          find.byKey(const ValueKey('fterm-whats-new-pill')),
          findsOneWidget,
        );
        expect(find.text('NEW'), findsNothing);
        expect(tester.takeException(), isNull);

        // Return to top dock and click the pill -> opens modal & persists seen version.
        env.workspace.setDockPosition(DockPosition.top);
        await tester.pump();
        await tester.tap(find.byKey(const ValueKey('fterm-whats-new-pill')));
        await tester.pump();

        expect(env.workspace.activeOverlay, equals(FtermOverlay.whatsNew));
        expect(find.text("What's New in v0.3.0"), findsOneWidget);
        expect(
          find.text('Remote Shell Spawning, Nerd Font v3 & Layout Resume'),
          findsOneWidget,
        );
        expect(
          find.text('Self-Hosted Web Relay, Compression & Subpaths'),
          findsOneWidget,
        );
        expect(env.workspace.shouldShowWhatsNewPill, isFalse);
        expect(
          find.byKey(const ValueKey('fterm-whats-new-pill')),
          findsNothing,
        );

        // Flush storage and verify persisted version suppresses pill on restart.
        env.workspace.flushPendingSettings();
        final reloadedPrefs = loadStoredPreferences(env.storage);
        expect(reloadedPrefs.lastSeenWhatsNewVersion, equals('0.3.0'));

        final sameVersionEnv = _WhatsNewHarness(
          storage: env.storage,
          currentVersion: FtermSemVer(0, 3, 0),
        );
        addTearDown(() => tester.runAsync(sameVersionEnv.dispose));
        expect(sameVersionEnv.workspace.shouldShowWhatsNewPill, isFalse);

        // Upgrading to a newer version shows the pill again.
        final upgradedEnv = _WhatsNewHarness(
          storage: env.storage,
          currentVersion: FtermSemVer(0, 4, 0),
        );
        addTearDown(() => tester.runAsync(upgradedEnv.dispose));
        expect(upgradedEnv.workspace.shouldShowWhatsNewPill, isTrue);
      },
    );

    testWidgets(
      'live-previews Wave + Glow and Retro Phosphor CRT, toggles Perf HUD, and reverts cleanly in 1 click',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(960, 720));
        addTearDown(() => tester.binding.setSurfaceSize(null));

        final env = _WhatsNewHarness(currentVersion: FtermSemVer(0, 3, 0));
        addTearDown(() => tester.runAsync(env.dispose));
        await tester.runAsync(env.workspace.start);

        await tester.pumpWidget(_buildScaffoldApp(env.workspace));
        await tester.pump();

        expect(env.workspace.backgroundShaderChain, isEmpty);
        expect(env.workspace.foregroundShaderChain, isEmpty);
        expect(env.workspace.backgroundOpacity, equals(1.0));
        expect(env.workspace.showPerfHud, isFalse);

        await tester.tap(find.byKey(const ValueKey('fterm-whats-new-pill')));
        await tester.pump();

        expect(env.workspace.hasWhatsNewPreviewChanges, isFalse);
        expect(
          find.byKey(const ValueKey('whats-new-revert-preview')),
          findsNothing,
        );

        // Try Wave + Glow: sets bg + fg chains and auto-reveals background opacity.
        await tester.tap(find.byKey(const ValueKey('whats-new-try-wave-glow')));
        await tester.pump();
        expect(
          env.workspace.backgroundShaderChain,
          equals(const ['wallpaper_wave']),
        );
        expect(
          env.workspace.foregroundShaderChain,
          equals(const ['cursor_glow']),
        );
        expect(
          env.workspace.backgroundOpacity,
          equals(FtermWorkspaceController.autoRevealBackgroundOpacity),
        );
        expect(env.workspace.hasWhatsNewPreviewChanges, isTrue);
        expect(
          find.byKey(const ValueKey('whats-new-revert-preview')),
          findsOneWidget,
        );

        // Try Retro Phosphor CRT: switches chains live.
        await tester.tap(find.byKey(const ValueKey('whats-new-try-retro-crt')));
        await tester.pump();
        expect(env.workspace.backgroundShaderChain, isEmpty);
        expect(
          env.workspace.foregroundShaderChain,
          equals(const ['retro_phosphor']),
        );

        // Toggle Perf HUD on.
        await tester.tap(
          find.byKey(const ValueKey('whats-new-toggle-perf-hud')),
        );
        await tester.pump();
        expect(env.workspace.showPerfHud, isTrue);

        // Click Revert -> restores original chains, opacity, and Perf HUD.
        await tester.tap(
          find.byKey(const ValueKey('whats-new-revert-preview')),
        );
        await tester.pump();
        expect(env.workspace.backgroundShaderChain, isEmpty);
        expect(env.workspace.foregroundShaderChain, isEmpty);
        expect(env.workspace.backgroundOpacity, equals(1.0));
        expect(env.workspace.showPerfHud, isFalse);
        expect(env.workspace.hasWhatsNewPreviewChanges, isFalse);
        expect(
          find.byKey(const ValueKey('whats-new-revert-preview')),
          findsNothing,
        );

        // Keeping a preview when clicking Done preserves chosen shaders & clears snapshot.
        await tester.tap(find.byKey(const ValueKey('whats-new-try-wave-glow')));
        await tester.pump();
        await tester.tap(find.byKey(const ValueKey('whats-new-done')));
        await tester.pump();
        expect(env.workspace.activeOverlay, equals(FtermOverlay.none));
        expect(
          env.workspace.backgroundShaderChain,
          equals(const ['wallpaper_wave']),
        );
        expect(
          env.workspace.foregroundShaderChain,
          equals(const ['cursor_glow']),
        );
        expect(env.workspace.hasWhatsNewPreviewChanges, isFalse);
      },
    );

    testWidgets(
      'opens Shader Settings, Shaders Folder (desktop only), and reopens from About and Help overlays',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(960, 720));
        addTearDown(() => tester.binding.setSurfaceSize(null));

        final env = _WhatsNewHarness(currentVersion: FtermSemVer(0, 3, 0));
        addTearDown(() => tester.runAsync(env.dispose));
        await tester.runAsync(env.workspace.start);

        await tester.pumpWidget(_buildScaffoldApp(env.workspace));
        await tester.pump();

        // Open and dismiss What's New so the pill disappears.
        env.workspace.openWhatsNew();
        await tester.pump();
        expect(
          find.byKey(const ValueKey('whats-new-open-shaders-folder')),
          findsOneWidget,
        );

        // Shaders Folder invokes platform openDirectoryHandler on desktop.
        await tester.tap(
          find.byKey(const ValueKey('whats-new-open-shaders-folder')),
        );
        await tester.pump();
        expect(env.openedDirectories, equals(const ['/tmp/fterm/shaders']));

        // Shader Settings switches directly to FtermOverlay.settings.
        await tester.tap(find.byKey(const ValueKey('whats-new-open-settings')));
        await tester.pump();
        expect(env.workspace.activeOverlay, equals(FtermOverlay.settings));

        // Reopen What's New from About overlay after pill is gone.
        env.workspace.setOverlay(FtermOverlay.about);
        await tester.pump();
        expect(
          find.byKey(const ValueKey('fterm-whats-new-pill')),
          findsNothing,
        );
        expect(
          find.byKey(const ValueKey('about-whats-new-button')),
          findsOneWidget,
        );
        await tester.tap(find.byKey(const ValueKey('about-whats-new-button')));
        await tester.pump();
        expect(env.workspace.activeOverlay, equals(FtermOverlay.whatsNew));

        // Reopen What's New from Help overlay as well.
        env.workspace.setOverlay(FtermOverlay.help);
        await tester.pump();
        await tester.tap(find.byKey(const ValueKey('help-whats-new-button')));
        await tester.pump();
        expect(env.workspace.activeOverlay, equals(FtermOverlay.whatsNew));

        // Web mode hides desktop-only Shaders Folder button.
        final webEnv = _WhatsNewHarness(
          currentVersion: FtermSemVer(0, 3, 0),
          isWeb: true,
        );
        addTearDown(() => tester.runAsync(webEnv.dispose));
        webEnv.workspace.openWhatsNew();
        await tester.pumpWidget(
          _buildScaffoldApp(webEnv.workspace, isWeb: true),
        );
        await tester.pump();
        expect(
          find.byKey(const ValueKey('whats-new-open-shaders-folder')),
          findsNothing,
        );
        expect(find.byIcon(Icons.auto_awesome), findsWidgets);
      },
    );
  });
}
