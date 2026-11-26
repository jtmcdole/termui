import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:fterm/src/audio/fterm_audio_controller.dart';
import 'package:fterm/src/font_loader.dart';
import 'package:fterm/src/launch_config.dart';
import 'package:fterm/src/settings_storage.dart';
import 'package:fterm/src/shader_profile_store.dart';
import 'package:fterm/src/ui/fterm_shell_scaffold.dart';
import 'package:fterm/src/ui/settings/settings_catalog.dart';
import 'package:fterm/src/update/update_service.dart';
import 'package:fterm/src/workspace/fterm_workspace_controller.dart';
import 'package:fterm/src/workspace/local_host_driver.dart';
import 'package:material_ui/material_ui.dart';
import 'package:termui_cast_client_core/termui_cast_client_core.dart';
import 'package:termui_flutter/termui_flutter.dart'
    show DisabledShaderBackend, TerminalShaderController;

final class _MemStorage implements SettingsStorage {
  final Map<String, String> _map = <String, String>{};
  @override
  String? getItem(String key) => _map[key];
  @override
  void setItem(String key, String value) => _map[key] = value;
}

final class _NoopHostDriver implements LocalHostDriver {
  @override
  bool get isSupported => true;
  @override
  Future<LocalPaneHost> openShell(LocalShellConfig config) =>
      throw UnimplementedError();
  @override
  Future<void> dispose() async {}
}

final class _FakeShaderProfileStore implements ShaderProfileStore {
  @override
  final String? shadersDirectoryPath = '/tmp/fterm/shaders';

  final Map<String, String> shaders = <String, String>{};
  final Map<String, Uint8List> wallpapers = <String, Uint8List>{};

  @override
  Future<List<String>> listShaderFiles() async => [...shaders.keys]..sort();

  @override
  Future<String> loadShaderSource(String pathOrKey) async {
    final src = shaders[pathOrKey];
    if (src == null) {
      throw ShaderAssetException(
        'Shader file not found.',
        pathOrKey: pathOrKey,
      );
    }
    return src;
  }

  @override
  Future<Uint8List> loadWallpaperBytes(String pathOrKey) async {
    final bytes = wallpapers[pathOrKey];
    if (bytes == null) {
      throw ShaderAssetException('Wallpaper not found.', pathOrKey: pathOrKey);
    }
    validateWallpaperBytes(bytes, pathOrKey: pathOrKey);
    return bytes;
  }

  @override
  Future<void> saveShaderSource(String name, String glslSource) async {
    shaders[name] = glslSource;
  }

  @override
  Future<void> saveWallpaperBytes(String key, Uint8List bytes) async {
    validateWallpaperBytes(bytes, pathOrKey: key);
    wallpapers[key] = bytes;
  }

  @override
  Stream<ShaderDirectoryChange> watchShaderDirectory() =>
      const Stream<ShaderDirectoryChange>.empty();

  @override
  void dispose() {}
}

final class _AvailableUpdateService implements UpdateService {
  @override
  final FtermSemVer currentVersion = FtermSemVer.parse('0.2.2');

  @override
  SelfUpdateCapability get capability => SelfUpdateCapability.supported;

  @override
  Future<UpdateCheckOutcome> checkForUpdates({
    required bool includePrereleases,
    String? lastEtag,
    List<String> cachedTags = const [],
  }) async => UpdateCheckOutcome(
    availableUpdate: AvailableUpdate(
      version: FtermSemVer.parse('9.9.9'),
      tagName: 'fterm-v9.9.9',
      notes: 'Test update',
      htmlUrl: Uri.parse('https://example.invalid/release'),
      asset: ReleaseAssetInfo(
        name: 'fterm.zip',
        browserDownloadUrl: Uri.parse('https://example.invalid/fterm.zip'),
        size: 1024,
        sha256Hex: '0' * 64,
      ),
    ),
    tagEtag: 'etag-1',
    cachedTags: const ['fterm-v9.9.9'],
    cacheTagState: true,
  );

  @override
  Future<StagedUpdate> stageUpdate(
    AvailableUpdate update, {
    void Function(DownloadProgress progress)? onProgress,
  }) => throw UnimplementedError();

  @override
  bool hasSiblingInstances() => false;

  @override
  bool prepareExclusiveSwapLock() => true;

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

Future<Uint8List> _createValidPng() async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawRect(
    const Rect.fromLTWH(0, 0, 4, 4),
    Paint()..color = const Color(0xFF3399CC),
  );
  final picture = recorder.endRecording();
  final img = await picture.toImage(4, 4);
  picture.dispose();
  try {
    final data = await img.toByteData(format: ui.ImageByteFormat.png);
    return data!.buffer.asUint8List();
  } finally {
    img.dispose();
  }
}

FtermWorkspaceController _buildWorkspace({
  _MemStorage? storage,
  UpdateService? updateService,
  ShaderProfileStore? shaderProfileStore,
}) {
  final transport = WsClientTransport(
    serverUri: CastLaunchConfig.defaultServerUri,
    token: '',
  );
  return FtermWorkspaceController(
    launchConfig: CastLaunchConfig(promptForConnection: false),
    repository: CastClientRepository(transport: transport),
    localHostDriver: _NoopHostDriver(),
    audioController: FtermAudioController(
      initialMuted: false,
      requireUserGesture: false,
    ),
    storage: storage ?? _MemStorage(),
    updateService: updateService,
    resizeDebounce: Duration.zero,
    shaderProfileStore: shaderProfileStore,
    shaderController: TerminalShaderController(
      backendFactory: (_) => const DisabledShaderBackend(),
    ),
  );
}

Finder _k(String key) => find.byKey(ValueKey(key));

Future<void> _pumpSettings(
  WidgetTester tester,
  FtermWorkspaceController ws, {
  TargetPlatform platform = .linux,
  bool isWeb = false,
  Size surfaceSize = const Size(1000, 760),
}) async {
  await tester.binding.setSurfaceSize(surfaceSize);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(platform: platform),
      home: FtermShellScaffold(
        workspace: ws,
        onOpenUrl: (_) {},
        platformOverride: platform,
        isWebOverride: isWeb,
      ),
    ),
  );
  await tester.pump();
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

  group('Blender-style Settings Overhaul', () {
    testWidgets(
      'renders 8 desktop sidebar tabs (5 on Web) and shows update badge dot',
      (tester) async {
        final ws = _buildWorkspace(updateService: _AvailableUpdateService());
        ws.setOverlay(FtermOverlay.settings);
        await _pumpSettings(tester, ws);

        for (final section in FtermSettingsSection.values) {
          expect(_k('settings-tab-${section.name}'), findsOneWidget);
        }

        // Update dot appears on Updates tab once an actionable update exists.
        expect(_k('settings-tab-updates-dot'), findsNothing);
        await tester.runAsync(ws.updateViewModel.checkForUpdates);
        await tester.pump();
        expect(_k('settings-tab-updates-dot'), findsOneWidget);

        await _disposeWs(tester, ws);

        // Web mode hides Shell, Automation, and Updates.
        final webWs = _buildWorkspace();
        webWs.setOverlay(FtermOverlay.settings);
        await _pumpSettings(tester, webWs, isWeb: true);
        for (final visible in const [
          FtermSettingsSection.interface,
          FtermSettingsSection.themes,
          FtermSettingsSection.shaders,
          FtermSettingsSection.keyboard,
          FtermSettingsSection.system,
        ]) {
          expect(_k('settings-tab-${visible.name}'), findsOneWidget);
        }
        for (final hidden in const [
          FtermSettingsSection.shell,
          FtermSettingsSection.automation,
          FtermSettingsSection.updates,
        ]) {
          expect(_k('settings-tab-${hidden.name}'), findsNothing);
        }
        await _disposeWs(tester, webWs);
      },
    );

    testWidgets(
      'remembers last visited section across reopen and honors deep-links',
      (tester) async {
        final ws = _buildWorkspace();
        ws.setOverlay(FtermOverlay.settings);
        await _pumpSettings(tester, ws);

        // Defaults to Interface.
        expect(_k('settings-panel-interface-tab-bar'), findsOneWidget);

        // Switch to Themes, dismiss, and reopen via setOverlay -> restores Themes.
        await tester.tap(_k('settings-tab-themes'));
        await tester.pump();
        expect(_k('settings-panel-themes-appearance'), findsOneWidget);

        ws.dismissOverlay();
        await tester.pump();
        ws.setOverlay(FtermOverlay.settings);
        await tester.pump();
        expect(_k('settings-panel-themes-appearance'), findsOneWidget);

        // Deep-linking to Shaders overrides remembered section.
        ws.openSettingsOverlay(initialSection: .shaders);
        await tester.pump();
        expect(_k('settings-shaders-section'), findsOneWidget);

        await _disposeWs(tester, ws);
      },
    );

    testWidgets(
      'collapses and expands panels and collapses CLI Shaders by default',
      (tester) async {
        final ws = _buildWorkspace();
        ws.openSettingsOverlay(initialSection: .shaders);
        await _pumpSettings(tester, ws);

        // CLI Shaders starts collapsed by default.
        expect(_k('settings-panel-header-shaders-cli'), findsOneWidget);
        expect(_k('settings-cli-shader-policy-section'), findsNothing);

        // Expanding reveals controls.
        await tester.ensureVisible(_k('settings-panel-header-shaders-cli'));
        await tester.tap(_k('settings-panel-header-shaders-cli'));
        await tester.pump();
        expect(_k('settings-cli-shader-policy-section'), findsOneWidget);

        // Collapsing hides controls again.
        await tester.tap(_k('settings-panel-header-shaders-cli'));
        await tester.pump();
        expect(_k('settings-cli-shader-policy-section'), findsNothing);

        await _disposeWs(tester, ws);
      },
    );

    testWidgets(
      'Themes dropdown, Appearance segmented toggle, Dock toggle, and System Sound controls mutate workspace',
      (tester) async {
        final ws = _buildWorkspace();
        ws.setOverlay(FtermOverlay.settings);
        await _pumpSettings(tester, ws);

        // Interface -> Dock position segmented toggle.
        await tester.tap(_k('settings-dock-left'));
        await tester.pump();
        expect(ws.workspaceSettings.dockPosition, equals(DockPosition.left));

        // Themes -> Appearance mode + Theme preset dropdown.
        await tester.tap(_k('settings-tab-themes'));
        await tester.pump();
        await tester.tap(_k('settings-appearance-light'));
        await tester.pump();
        expect(
          ws.workspaceSettings.themeSettings.appearanceMode,
          equals(ThemeAppearanceMode.light),
        );

        await tester.tap(_k('settings-theme-preset-dropdown'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('solarized_light').last);
        await tester.pumpAndSettle();
        expect(ws.activeTerminalTheme.id, equals('solarized_light'));

        // System -> Sound mute checkbox and volume slider.
        await tester.tap(_k('settings-tab-system'));
        await tester.pump();
        expect(_k('settings-panel-system-sound'), findsOneWidget);
        await tester.tap(_k('settings-audio-mute'));
        await tester.pump();
        expect(ws.preferences.audioMuted, isTrue);

        final volSlider = tester.widget<Slider>(
          _k('settings-audio-volume-slider'),
        );
        volSlider.onChanged!(0.35);
        await tester.pump();
        expect(ws.preferences.audioVolume, closeTo(0.35, 0.001));
        expect(
          tester.widget<Text>(_k('settings-audio-volume-value')).data,
          equals('35%'),
        );

        await _disposeWs(tester, ws);
      },
    );

    testWidgets(
      'selecting an opposite-brightness Theme Preset switches appearanceMode and does not snap back',
      (tester) async {
        final ws = _buildWorkspace();
        ws.setThemeSettings(
          ws.workspaceSettings.themeSettings.copyWith(appearanceMode: .dark),
        );
        ws.openSettingsOverlay(initialSection: .themes);
        await _pumpSettings(tester, ws);

        expect(
          ws.workspaceSettings.themeSettings.appearanceMode,
          equals(ThemeAppearanceMode.dark),
        );

        await tester.tap(_k('settings-theme-preset-dropdown'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('solarized_light').last);
        await tester.pumpAndSettle();

        expect(ws.activeTerminalTheme.id, equals('solarized_light'));
        expect(
          ws.workspaceSettings.themeSettings.appearanceMode,
          equals(ThemeAppearanceMode.light),
        );
        final dropdown = tester.widget<DropdownButton<String>>(
          _k('settings-theme-preset-dropdown'),
        );
        expect(dropdown.value, equals('solarized_light'));

        await _disposeWs(tester, ws);
      },
    );

    testWidgets(
      'Ctrl+F (Linux) and Cmd+F (macOS) focus the search field immediately on open before typing',
      (tester) async {
        final linuxWs = _buildWorkspace();
        linuxWs.setOverlay(FtermOverlay.settings);
        await _pumpSettings(tester, linuxWs, platform: .linux);

        await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        await tester.sendKeyDownEvent(LogicalKeyboardKey.keyF);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.keyF);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
        await tester.pump();
        expect(
          FocusManager.instance.primaryFocus?.debugLabel,
          equals('fterm-settings-search'),
        );
        await _disposeWs(tester, linuxWs);

        final macWs = _buildWorkspace();
        macWs.setOverlay(FtermOverlay.settings);
        await _pumpSettings(tester, macWs, platform: .macOS);

        await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
        await tester.sendKeyDownEvent(LogicalKeyboardKey.keyF);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.keyF);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
        await tester.pump();
        expect(
          FocusManager.instance.primaryFocus?.debugLabel,
          equals('fterm-settings-search'),
        );
        await _disposeWs(tester, macWs);
      },
    );

    testWidgets(
      'live cross-category search filters panels, auto-expands collapsed panels, shows sidebar badges, and handles Esc',
      (tester) async {
        final ws = _buildWorkspace();
        ws.setOverlay(FtermOverlay.settings);
        await _pumpSettings(tester, ws);

        // Ctrl+F focuses the search field immediately.
        await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        await tester.sendKeyDownEvent(LogicalKeyboardKey.keyF);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.keyF);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
        await tester.pump();
        expect(
          FocusManager.instance.primaryFocus?.debugLabel,
          equals('fterm-settings-search'),
        );

        // Searching "bell" surfaces System > Sound across categories.
        await tester.enterText(_k('settings-search-field'), 'bell');
        await tester.pump();
        expect(_k('settings-search-results'), findsOneWidget);
        expect(_k('settings-panel-system-sound'), findsOneWidget);
        expect(_k('settings-audio-mute'), findsOneWidget);
        expect(_k('settings-tab-count-system'), findsOneWidget);
        expect(_k('settings-panel-interface-tab-bar'), findsNothing);

        // Searching "sha256" auto-expands collapsed-by-default CLI Shaders panel.
        await tester.enterText(_k('settings-search-field'), 'sha256');
        await tester.pump();
        expect(_k('settings-panel-shaders-cli'), findsOneWidget);
        expect(_k('settings-reset-trusted-cli-hashes'), findsOneWidget);
        expect(_k('settings-tab-count-shaders'), findsOneWidget);

        // Clicking a sidebar tab during search clears query and navigates there.
        await tester.tap(_k('settings-tab-keyboard'));
        await tester.pump();
        expect(_k('settings-search-results'), findsNothing);
        expect(_k('settings-panel-keyboard-meta'), findsOneWidget);

        // Non-matching query displays empty state and Clear Search recovers.
        await tester.enterText(_k('settings-search-field'), 'zzznomatch999');
        await tester.pump();
        expect(_k('settings-search-empty'), findsOneWidget);
        await tester.tap(_k('settings-search-clear-empty'));
        await tester.pump();
        expect(_k('settings-search-empty'), findsNothing);
        expect(_k('settings-panel-keyboard-meta'), findsOneWidget);

        // First Escape clears an active search query WITHOUT closing Settings;
        // second Escape dismisses Settings.
        await tester.enterText(_k('settings-search-field'), 'crt');
        await tester.pump();
        expect(_k('settings-search-results'), findsOneWidget);

        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pump();
        expect(ws.activeOverlay, equals(FtermOverlay.settings));
        expect(_k('settings-search-results'), findsNothing);

        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pump();
        expect(ws.activeOverlay, equals(FtermOverlay.none));

        await _disposeWs(tester, ws);
      },
    );

    testWidgets(
      'Esc cancels the Reset All confirmation banner without closing Settings',
      (tester) async {
        final ws = _buildWorkspace();
        ws.setOverlay(FtermOverlay.settings);
        await _pumpSettings(tester, ws);

        await tester.tap(_k('settings-prefs-menu'));
        await tester.pumpAndSettle();
        await tester.tap(_k('settings-reset-defaults-menu-item'));
        await tester.pumpAndSettle();
        expect(_k('settings-reset-confirm-banner'), findsOneWidget);

        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pump();
        expect(_k('settings-reset-confirm-banner'), findsNothing);
        expect(ws.activeOverlay, equals(FtermOverlay.settings));

        await _disposeWs(tester, ws);
      },
    );

    testWidgets(
      'wallpaper editing survives background chromeNotifier ticks and surfaces invalid wallpaper errors inline on Themes',
      (tester) async {
        final store = _FakeShaderProfileStore();
        final ws = _buildWorkspace(shaderProfileStore: store);
        ws.openSettingsOverlay(initialSection: .themes);
        await _pumpSettings(tester, ws);

        await tester.tap(_k('settings-wallpaper-edit'));
        await tester.pump();

        final fieldFinder = _k('settings-wallpaper-path-field');
        await tester.enterText(fieldFinder, '/unsaved/draft.png');
        await tester.pump();

        // Trigger an unrelated chromeNotifier update while editing wallpaper.
        ws.setCopyOnSelect(!ws.copyOnSelect);
        await tester.pump();
        expect(
          tester.widget<TextField>(fieldFinder).controller!.text,
          equals('/unsaved/draft.png'),
        );

        // Applying a missing wallpaper path displays the error inline on Themes.
        await tester.tap(_k('settings-wallpaper-apply'));
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));
        await tester.pump();
        expect(ws.lastWallpaperError, isNotNull);
        expect(_k('settings-wallpaper-error'), findsOneWidget);

        // Clearing wallpaper clears the inline error banner.
        await tester.tap(_k('settings-wallpaper-clear'));
        await tester.pump();
        expect(ws.lastWallpaperError, isNull);
        expect(_k('settings-wallpaper-error'), findsNothing);

        await _disposeWs(tester, ws);
      },
    );

    testWidgets(
      'resetSettingsToDefaults clears active wallpaper, custom shaders, and flushes storage so immediate reload keeps defaults',
      (tester) async {
        final storage = _MemStorage();
        final store = _FakeShaderProfileStore();
        final png = await tester.runAsync(_createValidPng);
        store.wallpapers['/tmp/wall.png'] = png!;
        store.shaders['fx.glsl'] =
            'void mainImage(out vec4 c, in vec2 u) { c = vec4(1.0); }';

        final ws = _buildWorkspace(storage: storage, shaderProfileStore: store);
        await tester.runAsync(() => ws.setBackgroundImagePath('/tmp/wall.png'));
        await tester.runAsync(
          () => ws.setForegroundShaderChain(const <String>['fx.glsl']),
        );
        ws.setFontSize(18.0);
        // Fire a throttled write right before reset to verify flush() wins.
        ws.updatePreferences(ws.preferences.copyWith(audioMuted: true));

        expect(ws.shaderController.wallpaperImage, isNotNull);
        expect(ws.foregroundShaderChain, equals(const <String>['fx.glsl']));
        expect(ws.effectiveFontSize, equals(18.0));

        ws.resetSettingsToDefaults();
        expect(ws.backgroundImagePath, isNull);
        expect(ws.shaderController.wallpaperImage, isNull);
        expect(ws.foregroundShaderChain, isEmpty);
        expect(ws.preferences.fontSize, isNull);
        expect(ws.preferences.audioMuted, isFalse);
        expect(ws.lastWallpaperError, isNull);
        expect(ws.lastShaderAssetError, isNull);

        // Immediate reload within the throttle cooldown must keep factory defaults.
        expect(ws.reloadSettingsFromStorage(), isTrue);
        expect(ws.backgroundImagePath, isNull);
        expect(ws.foregroundShaderChain, isEmpty);
        expect(ws.preferences.fontSize, isNull);
        expect(ws.preferences.audioMuted, isFalse);

        await _disposeWs(tester, ws);
      },
    );

    testWidgets(
      'bottom-left settings menu reloads from storage and resets all settings with confirmation',
      (tester) async {
        final storage = _MemStorage();
        final ws = _buildWorkspace(storage: storage);
        ws.setDockPosition(DockPosition.left);
        ws.updatePreferences(
          ws.preferences.copyWith(
            audioMuted: true,
            autoHideSingleTab: true,
            lastSeenWhatsNewVersion: '0.9.0',
          ),
        );
        ws.flushPendingSettings();

        ws.setOverlay(FtermOverlay.settings);
        await _pumpSettings(tester, ws);

        // Mutate backing storage externally, then invoke Reload from Storage.
        saveStoredPreferences(
          storage,
          ws.preferences.copyWith(audioVolume: 0.25),
        );
        await tester.tap(_k('settings-prefs-menu'));
        await tester.pumpAndSettle();
        await tester.tap(_k('settings-reload-storage'));
        await tester.pumpAndSettle();
        expect(ws.preferences.audioVolume, closeTo(0.25, 0.001));
        expect(
          tester.widget<Text>(_k('settings-status-feedback')).data,
          equals('Reloaded from storage'),
        );

        // Trigger Reset All to Defaults -> confirm banner appears; Cancel keeps state.
        await tester.tap(_k('settings-prefs-menu'));
        await tester.pumpAndSettle();
        await tester.tap(_k('settings-reset-defaults-menu-item'));
        await tester.pumpAndSettle();
        expect(_k('settings-reset-confirm-banner'), findsOneWidget);

        await tester.tap(_k('settings-reset-cancel'));
        await tester.pump();
        expect(_k('settings-reset-confirm-banner'), findsNothing);
        expect(ws.preferences.audioMuted, isTrue);

        // Trigger Reset All again and confirm -> restores factory defaults while
        // preserving lastSeenWhatsNewVersion.
        await tester.tap(_k('settings-prefs-menu'));
        await tester.pumpAndSettle();
        await tester.tap(_k('settings-reset-defaults-menu-item'));
        await tester.pumpAndSettle();
        await tester.tap(_k('settings-reset-confirm'));
        await tester.pump();

        expect(_k('settings-reset-confirm-banner'), findsNothing);
        expect(ws.workspaceSettings.dockPosition, equals(DockPosition.top));
        expect(ws.preferences.audioMuted, isFalse);
        expect(ws.preferences.autoHideSingleTab, isFalse);
        expect(ws.preferences.lastSeenWhatsNewVersion, equals('0.9.0'));

        // Drain the status feedback timer cleanly.
        await tester.pump(const Duration(seconds: 3));
        await _disposeWs(tester, ws);
      },
    );

    testWidgets(
      'renders cleanly on narrow viewports (520x480) including Updates, reset banner, search results, and expanded CLI Shaders',
      (tester) async {
        final ws = _buildWorkspace(updateService: _AvailableUpdateService());
        ws.setOverlay(FtermOverlay.settings);
        await _pumpSettings(
          tester,
          ws,
          platform: .windows,
          surfaceSize: const Size(520, 480),
        );

        await tester.runAsync(ws.updateViewModel.checkForUpdates);
        await tester.pump();

        for (final section in FtermSettingsSection.values) {
          final tab = _k('settings-tab-${section.name}');
          await tester.ensureVisible(tab);
          await tester.tap(tab);
          await tester.pump();
          expect(
            tester.takeException(),
            isNull,
            reason: 'section ${section.name} should not overflow at 520x480',
          );
        }

        // Expand CLI Shaders on Shaders page at narrow width.
        final shadersTab = _k('settings-tab-shaders');
        await tester.ensureVisible(shadersTab);
        await tester.tap(shadersTab);
        await tester.pump();
        await tester.ensureVisible(_k('settings-panel-header-shaders-cli'));
        await tester.tap(_k('settings-panel-header-shaders-cli'));
        await tester.pump();
        expect(_k('settings-cli-shader-policy-section'), findsOneWidget);
        expect(
          tester.takeException(),
          isNull,
          reason: 'expanded CLI Shaders should not overflow at 520x480',
        );

        // Open Reset All confirmation banner at narrow width.
        await tester.tap(_k('settings-prefs-menu'));
        await tester.pumpAndSettle();
        await tester.tap(_k('settings-reset-defaults-menu-item'));
        await tester.pumpAndSettle();
        expect(_k('settings-reset-confirm-banner'), findsOneWidget);
        expect(
          tester.takeException(),
          isNull,
          reason: 'reset confirmation banner should not overflow at 520x480',
        );

        // Active cross-category search results at narrow width.
        await tester.enterText(_k('settings-search-field'), 'update');
        await tester.pump();
        expect(_k('settings-search-results'), findsOneWidget);
        expect(
          tester.takeException(),
          isNull,
          reason: 'search results should not overflow at 520x480',
        );
        await _disposeWs(tester, ws);
      },
    );

    testWidgets(
      'catalog drift guard: every visible SettingsSearchItem panelId renders its settings-panel widget when queried',
      (tester) async {
        final ws = _buildWorkspace(updateService: _AvailableUpdateService());
        ws.setOverlay(FtermOverlay.settings);
        await _pumpSettings(tester, ws, platform: .windows);

        final testedDesktopPanels = <String>{};
        for (final item in SettingsCatalog.allSearchItems) {
          if (!testedDesktopPanels.add(item.panelId)) continue;
          await tester.enterText(_k('settings-search-field'), item.title);
          await tester.pump();
          expect(
            _k('settings-panel-${item.panelId}'),
            findsOneWidget,
            reason:
                'Desktop query "${item.title}" should render '
                'settings-panel-${item.panelId}',
          );
        }
        await _disposeWs(tester, ws);

        // Verify Web-visible catalog entries also match rendered panels.
        final webWs = _buildWorkspace();
        webWs.setOverlay(FtermOverlay.settings);
        await _pumpSettings(tester, webWs, isWeb: true);

        final testedWebPanels = <String>{};
        for (final item in SettingsCatalog.allSearchItems) {
          if (item.desktopOnly || item.windowsOnly) continue;
          if (!testedWebPanels.add(item.panelId)) continue;
          await tester.enterText(_k('settings-search-field'), item.title);
          await tester.pump();
          expect(
            _k('settings-panel-${item.panelId}'),
            findsOneWidget,
            reason:
                'Web query "${item.title}" should render '
                'settings-panel-${item.panelId}',
          );
        }
        await _disposeWs(tester, webWs);
      },
    );

    test('SettingsCatalog.search filters platform-specific items accurately and matches output volume & Web GLSL upload', () {
      final winResult = SettingsCatalog.search(
        'gpu adapter',
        isWeb: false,
        isDesktopHost: true,
        supportsUpdates: true,
        isWindows: true,
      );
      expect(winResult.totalMatches, equals(1));
      expect(
        winResult.panelMatches.single.matchedItemIds,
        contains('system-gpu-driver'),
      );

      final macResult = SettingsCatalog.search(
        'gpu adapter',
        isWeb: false,
        isDesktopHost: true,
        supportsUpdates: true,
        isWindows: false,
      );
      expect(macResult.totalMatches, equals(0));

      final webShellResult = SettingsCatalog.search(
        'zsh',
        isWeb: true,
        isDesktopHost: false,
        supportsUpdates: false,
        isWindows: false,
      );
      expect(webShellResult.totalMatches, equals(0));

      final outputResult = SettingsCatalog.search(
        'output',
        isWeb: false,
        isDesktopHost: true,
        supportsUpdates: true,
        isWindows: false,
      );
      expect(
        outputResult.panelMatches.expand((m) => m.matchedItemIds),
        contains('system-audio-volume'),
      );

      final webUploadResult = SettingsCatalog.search(
        'web glsl',
        isWeb: true,
        isDesktopHost: false,
        supportsUpdates: false,
        isWindows: false,
      );
      expect(webUploadResult.totalMatches, equals(1));
      expect(
        webUploadResult.panelMatches.single.panelId,
        equals('shaders-pipeline'),
      );
      expect(
        webUploadResult.panelMatches.single.matchedItemIds,
        contains('shaders-actions'),
      );
    });
  });
}
