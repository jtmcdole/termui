import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fterm/src/audio/fterm_audio_controller.dart';
import 'package:fterm/src/automation/automation_models.dart';
import 'package:fterm/src/launch_config.dart';
import 'package:fterm/src/settings_storage.dart';
import 'package:fterm/src/shader_profile_store.dart';
import 'package:fterm/src/ui/palette/fuzzy_matcher.dart';
import 'package:fterm/src/ui/palette/palette_command_registry.dart';
import 'package:fterm/src/ui/palette/palette_models.dart';
import 'package:fterm/src/update/update_service.dart';
import 'package:fterm/src/workspace/fterm_workspace_controller.dart';
import 'package:fterm/src/workspace/local_host_driver.dart';
import 'package:termui/termui.dart' as tui;
import 'package:termui_cast_client_core/termui_cast_client_core.dart';
import 'package:termui_cast_protocol/termui_cast_protocol.dart';
import 'package:termui_flutter/termui_flutter.dart'
    show
        DisabledShaderBackend,
        ShaderAnimationMode,
        ShaderBackendKind,
        TerminalShaderController,
        TerminalShaderPreset;
import 'package:termui_pty/termui_pty.dart';

final class _MemStorage implements SettingsStorage {
  final Map<String, String> data = <String, String>{};

  @override
  String? getItem(String key) => data[key];

  @override
  void setItem(String key, String value) => data[key] = value;
}

final class _FakeTerminalPort implements TerminalPort {
  @override
  final String id;

  @override
  final String? workingDirectory;

  final tui.Buffer _buffer = tui.Buffer.blank(80, 24);
  final Set<void Function()> _listeners = <void Function()>{};
  final Set<void Function()> _bellListeners = <void Function()>{};
  final Set<void Function(String)> _titleListeners = <void Function(String)>{};
  final Set<void Function(TerminalAudioEvent)> _audioListeners =
      <void Function(TerminalAudioEvent)>{};
  final Set<void Function(String, String)> _clipboardListeners =
      <void Function(String, String)>{};
  final Set<void Function(TerminalShaderApcEvent)> _shaderListeners =
      <void Function(TerminalShaderApcEvent)>{};
  final Completer<int> _exitCode = Completer<int>();
  @override
  final String windowTitle;

  _FakeTerminalPort({
    required this.id,
    this.workingDirectory,
    this.windowTitle = 'zsh',
  });

  @override
  tui.Buffer get buffer => _buffer;

  @override
  int get cols => _buffer.width;

  @override
  int get rows => _buffer.height;

  @override
  int get renderRevision => 0;

  @override
  int get fullSyncRevision => 0;

  @override
  List<DirtyCellSpan> get dirtySpans => const <DirtyCellSpan>[];

  @override
  (int cols, int rows) get activePtySize => (_buffer.width, _buffer.height);

  @override
  CursorStateData get cursor => CursorStateData.origin;

  @override
  TerminalPortModes get modes => TerminalPortModes.defaults;

  @override
  ScrollbackWindowData get scrollbackWindow =>
      (clearSeq: 0, oldestLine: 0, totalLines: 0);

  @override
  List<ScrollbackLine> readScrollbackSlice(int startLine, int count) =>
      const <ScrollbackLine>[];

  @override
  void setViewportSize(
    int cols,
    int rows, {
    int cellPixelWidth = 0,
    int cellPixelHeight = 0,
  }) {}

  @override
  void sendInput(Uint8List data) {}

  @override
  void setShaderCapabilities(TerminalShaderCapabilities capabilities) {}

  @override
  void addListener(void Function() listener) => _listeners.add(listener);

  @override
  void removeListener(void Function() listener) => _listeners.remove(listener);

  @override
  void addBellListener(void Function() listener) =>
      _bellListeners.add(listener);

  @override
  void removeBellListener(void Function() listener) =>
      _bellListeners.remove(listener);

  @override
  void addTitleListener(void Function(String title) listener) =>
      _titleListeners.add(listener);

  @override
  void removeTitleListener(void Function(String title) listener) =>
      _titleListeners.remove(listener);

  @override
  void addAudioListener(void Function(TerminalAudioEvent event) listener) =>
      _audioListeners.add(listener);

  @override
  void removeAudioListener(void Function(TerminalAudioEvent event) listener) =>
      _audioListeners.remove(listener);

  @override
  void addClipboardListener(
    void Function(String selection, String text) listener,
  ) => _clipboardListeners.add(listener);

  @override
  void removeClipboardListener(
    void Function(String selection, String text) listener,
  ) => _clipboardListeners.remove(listener);

  @override
  void addShaderListener(
    void Function(TerminalShaderApcEvent event) listener,
  ) => _shaderListeners.add(listener);

  @override
  void removeShaderListener(
    void Function(TerminalShaderApcEvent event) listener,
  ) => _shaderListeners.remove(listener);

  @override
  Future<int> get exitCode => _exitCode.future;

  @override
  Future<void> dispose() async {
    _listeners.clear();
    _bellListeners.clear();
    _titleListeners.clear();
    _audioListeners.clear();
    _clipboardListeners.clear();
    _shaderListeners.clear();
    if (!_exitCode.isCompleted) _exitCode.complete(0);
  }
}

final class _FakeLocalPaneHost implements LocalPaneHost {
  @override
  final String id;

  @override
  final _FakeTerminalPort port;

  final StreamController<LocalShareSnapshot> _shareUpdates =
      StreamController<LocalShareSnapshot>.broadcast();
  LocalShareSnapshot _shareSnapshot = LocalShareSnapshot.unshared;

  _FakeLocalPaneHost({
    required this.id,
    String? workingDirectory,
    String title = 'zsh',
  }) : port = _FakeTerminalPort(
         id: 'port-$id',
         workingDirectory: workingDirectory,
         windowTitle: title,
       );

  @override
  Future<int> get exitCode => port.exitCode;

  @override
  LocalShareSnapshot get shareSnapshot => _shareSnapshot;

  @override
  Stream<LocalShareSnapshot> get shareUpdates => _shareUpdates.stream;

  @override
  Future<SessionId> startShare({
    required Uri serverUri,
    required String casterToken,
    required String title,
    String? uploadDirPath,
    IapTokenProvider? iapTokenProvider,
    CasterTransportOpener? channelOpener,
  }) async {
    final sessionId = SessionId('shared-$id');
    _shareSnapshot = LocalShareSnapshot(
      state: LocalShareState.live,
      sessionId: sessionId,
      subscriberCount: 1,
    );
    if (!_shareUpdates.isClosed) {
      _shareUpdates.add(_shareSnapshot);
    }
    return sessionId;
  }

  @override
  Future<void> stopShare() async {
    _shareSnapshot = LocalShareSnapshot.unshared;
    if (!_shareUpdates.isClosed) {
      _shareUpdates.add(_shareSnapshot);
    }
  }

  @override
  void setColorScheme(tui.TerminalBrightness brightness) {}

  @override
  bool isLiveRowWrapped(int row) => false;

  @override
  Future<void> dispose() async {
    await port.dispose();
    await _shareUpdates.close();
  }
}

final class _FakeLocalHostDriver implements LocalHostDriver {
  @override
  bool get isSupported => true;

  int _counter = 0;
  final List<_FakeLocalPaneHost> hosts = <_FakeLocalPaneHost>[];

  @override
  Future<LocalPaneHost> openShell(LocalShellConfig config) async {
    final idx = ++_counter;
    final host = _FakeLocalPaneHost(
      id: 'local-$idx',
      workingDirectory: config.workingDirectory ?? '/work/shell-$idx',
      title: 'shell-$idx',
    );
    hosts.add(host);
    return host;
  }

  @override
  Future<void> dispose() async {}
}

final class _FakeShaderProfileStore implements ShaderProfileStore {
  @override
  String? get shadersDirectoryPath => '/tmp/fterm/shaders';

  final Map<String, String> shaders;

  _FakeShaderProfileStore({Map<String, String>? initialShaders})
    : shaders = <String, String>{...?initialShaders};

  @override
  Future<List<String>> listShaderFiles() async => [...shaders.keys]..sort();

  @override
  Future<String> loadShaderSource(String pathOrKey) async {
    final source = shaders[pathOrKey];
    if (source == null) {
      throw ShaderAssetException('Not found', pathOrKey: pathOrKey);
    }
    return source;
  }

  @override
  Future<Uint8List> loadWallpaperBytes(String pathOrKey) =>
      throw ShaderAssetException('Not found', pathOrKey: pathOrKey);

  @override
  Future<void> saveShaderSource(String name, String glslSource) async {
    shaders[name] = glslSource;
  }

  @override
  Future<void> saveWallpaperBytes(String key, Uint8List bytes) async {}

  @override
  Stream<ShaderDirectoryChange> watchShaderDirectory() =>
      const Stream<ShaderDirectoryChange>.empty();

  @override
  void dispose() {}
}

final class _FakeAutomationBackend implements AutomationHttpServerBackend {
  @override
  bool isSupported = true;

  bool _running = false;
  int? _boundPort;

  @override
  bool get isRunning => _running;

  @override
  int? get boundPort => _boundPort;

  @override
  Future<void> start({
    required int port,
    required String password,
    required bool allowPty,
    required AutomationRequestHandler onRequest,
  }) async {
    _running = true;
    _boundPort = port;
  }

  @override
  Future<void> stop() async {
    _running = false;
    _boundPort = null;
  }

  @override
  void updatePassword(String password) {}

  @override
  void updateAllowPty(bool allowPty) {}
}

final class _FakeUpdateService implements UpdateService {
  @override
  SelfUpdateCapability get capability => SelfUpdateCapability.supported;

  int checkCalls = 0;

  @override
  FtermSemVer get currentVersion => FtermSemVer.parse('0.2.5');

  @override
  Future<UpdateCheckOutcome> checkForUpdates({
    required bool includePrereleases,
    String? lastEtag,
    List<String> cachedTags = const <String>[],
  }) async {
    checkCalls += 1;
    return UpdateCheckOutcome(
      availableUpdate: null,
      tagEtag: 'etag-1',
      cachedTags: const <String>[],
      cacheTagState: true,
    );
  }

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
    List<String> relaunchArgs = const <String>[],
    Future<void> Function()? beforeExitTeardown,
  }) async {}

  @override
  Future<void> revealStagedInFinder(StagedUpdate staged) async {}

  @override
  Future<void> runStartupCleanup() async {}

  @override
  void dispose() {}
}

FtermWorkspaceController _createWorkspace({
  _MemStorage? storage,
  _FakeLocalHostDriver? localHostDriver,
  _FakeShaderProfileStore? shaderProfileStore,
  _FakeAutomationBackend? automationBackend,
  _FakeUpdateService? updateService,
  List<String>? openedDirs,
}) {
  final transport = WsClientTransport(
    serverUri: CastLaunchConfig.defaultServerUri,
    token: '',
  );
  return FtermWorkspaceController(
    launchConfig: CastLaunchConfig(promptForConnection: false),
    repository: CastClientRepository(transport: transport),
    localHostDriver: localHostDriver ?? _FakeLocalHostDriver(),
    audioController: FtermAudioController(
      initialMuted: false,
      requireUserGesture: false,
    ),
    storage: storage ?? _MemStorage(),
    resizeDebounce: Duration.zero,
    shaderProfileStore: shaderProfileStore ?? _FakeShaderProfileStore(),
    shaderController: TerminalShaderController(
      backendFactory: (_) => const DisabledShaderBackend(),
    ),
    automationServerBackend: automationBackend ?? _FakeAutomationBackend(),
    updateService: updateService ?? _FakeUpdateService(),
    openDirectoryHandler: openedDirs == null
        ? null
        : (dir) async => openedDirs.add(dir),
  );
}

PaletteItem _byId(List<PaletteItem> items, String id) => items.firstWhere(
  (item) => item.id == id,
  orElse: () => fail('Expected PaletteItem with id "$id"'),
);

void main() {
  group('fuzzyMatch & matchPaletteEntry', () {
    test('handles empty, non-matching, and oversized queries', () {
      expect(
        fuzzyMatch('', 'Toggle Zoom'),
        equals((score: 0, matchedIndices: const <int>[])),
      );
      expect(
        fuzzyMatch('   ', 'Toggle Zoom'),
        equals((score: 0, matchedIndices: const <int>[])),
      );
      expect(fuzzyMatch('abc', ''), isNull);
      expect(fuzzyMatch('abcdef', 'abc'), isNull);
      expect(fuzzyMatch('xyz', 'Toggle Zoom'), isNull);
    });

    test('ranks prefix > word boundary > camelCase > scattered', () {
      final prefix = fuzzyMatch('dark', 'dark_mode_x')!;
      final wordBoundary = fuzzyMatch('dark', 'set_dark_xx')!;
      final camel = fuzzyMatch('dark', 'setsDarkXxx')!;
      final scattered = fuzzyMatch('dark', 'sxdxaxrxkxx')!;

      expect(prefix.score, greaterThan(wordBoundary.score));
      expect(wordBoundary.score, greaterThan(camel.score));
      expect(camel.score, greaterThan(scattered.score));
      expect(prefix.matchedIndices, equals(<int>[0, 1, 2, 3]));
      expect(wordBoundary.matchedIndices, equals(<int>[4, 5, 6, 7]));
      expect(camel.matchedIndices, equals(<int>[4, 5, 6, 7]));
    });

    test('rewards consecutive streaks and shorter candidates', () {
      final consecutive = fuzzyMatch('crt', 'crt_lottes')!;
      final gapped = fuzzyMatch('crt', 'color_reset_tab')!;
      expect(consecutive.score, greaterThan(gapped.score));
      expect(consecutive.matchedIndices, equals(<int>[0, 1, 2]));

      final short = fuzzyMatch('zoom', 'Zoom')!;
      final long = fuzzyMatch('zoom', 'Zoom Terminal Viewport Size')!;
      expect(short.score, greaterThan(long.score));
    });

    test('supports grapheme clusters and greedy fallback for large inputs', () {
      final emoji = fuzzyMatch('hi', '🔥hi')!;
      expect(emoji.matchedIndices, equals(<int>[1, 2]));

      final longCandidate = '${'a' * 200}needle${'b' * 200}';
      final longQuery = '${'a' * 12}needle';
      final fallback = fuzzyMatch(longQuery, longCandidate)!;
      expect(fallback.matchedIndices, hasLength(longQuery.length));
      for (var i = 1; i < fallback.matchedIndices.length; i++) {
        expect(
          fallback.matchedIndices[i],
          greaterThan(fallback.matchedIndices[i - 1]),
        );
      }
    });

    test(
      'matchPaletteEntry matches title, category+title shifted, and keywords',
      () {
        final titleHit = matchPaletteEntry(
          'solarized',
          category: 'Theme',
          title: 'solarized_dark',
          keywords: 'palette dark',
        )!;
        expect(
          titleHit.matchedIndices,
          equals(<int>[0, 1, 2, 3, 4, 5, 6, 7, 8]),
        );

        final catTitleHit = matchPaletteEntry(
          'themsol',
          category: 'Theme',
          title: 'solarized_dark',
        )!;
        // 'sol' matches indices 0, 1, 2 inside title after shifting past 'Theme: '.
        expect(catTitleHit.matchedIndices, equals(<int>[0, 1, 2]));

        final keywordOnly = matchPaletteEntry(
          'yank',
          category: 'Settings',
          title: 'Toggle Copy on Selection',
          keywords: 'clipboard yank highlight',
        )!;
        expect(keywordOnly.matchedIndices, isEmpty);
        expect(titleHit.score, greaterThan(keywordOnly.score));

        final combined = matchPaletteEntry(
          'copyyank',
          category: 'Settings',
          title: 'Copy',
          keywords: 'yank',
        )!;
        expect(combined.matchedIndices, equals(<int>[0, 1, 2, 3]));
      },
    );
  });

  group('parsePaletteInput & PaletteMode', () {
    test('parses empty, >, :, and % prefixes accurately', () {
      expect(
        parsePaletteInput(''),
        equals((mode: PaletteMode.quickSwitch, query: '')),
      );
      expect(
        parsePaletteInput('   '),
        equals((mode: PaletteMode.quickSwitch, query: '')),
      );
      expect(
        parsePaletteInput('tab 2'),
        equals((mode: PaletteMode.quickSwitch, query: 'tab 2')),
      );
      expect(
        parsePaletteInput('>'),
        equals((mode: PaletteMode.commands, query: '')),
      );
      expect(
        parsePaletteInput('> drac'),
        equals((mode: PaletteMode.commands, query: 'drac')),
      );
      expect(
        parsePaletteInput('  >theme  '),
        equals((mode: PaletteMode.commands, query: 'theme')),
      );
      expect(
        parsePaletteInput(':'),
        equals((mode: PaletteMode.scrollbackJump, query: '')),
      );
      expect(
        parsePaletteInput(': 50%'),
        equals((mode: PaletteMode.scrollbackJump, query: '50%')),
      );
      expect(
        parsePaletteInput('%'),
        equals((mode: PaletteMode.textSearch, query: '')),
      );
      expect(
        parsePaletteInput('% mainImage'),
        equals((mode: PaletteMode.textSearch, query: 'mainImage')),
      );
      expect(
        parsePaletteInput('% ['),
        equals((mode: PaletteMode.textSearch, query: '[')),
      );
      // Preserves intentional trailing whitespace in text search.
      expect(
        parsePaletteInput('%foo '),
        equals((mode: PaletteMode.textSearch, query: 'foo ')),
      );
    });

    test('exposes canonical prefixes and mode badge labels', () {
      expect(PaletteMode.quickSwitch.prefix, isEmpty);
      expect(PaletteMode.quickSwitch.label, equals('Quick Switch'));
      expect(PaletteMode.commands.prefix, equals('>'));
      expect(PaletteMode.commands.label, equals('Commands'));
      expect(PaletteMode.scrollbackJump.prefix, equals(':'));
      expect(PaletteMode.scrollbackJump.label, equals('Go to Line'));
      expect(PaletteMode.textSearch.prefix, equals('%'));
      expect(PaletteMode.textSearch.label, equals('Search'));
    });
  });

  group('Flat command registry (>) execution & badges', () {
    test('executes Theme presets including opposite-brightness appearanceMode sync', () async {
      final ws = _createWorkspace();
      addTearDown(ws.dispose);
      final ctx = PaletteContext(workspace: ws, isWeb: false, platform: .linux);

      final initialCommands = buildPaletteCommands(ctx);
      for (final preset in tui.TerminalColorTheme.presets) {
        final item = _byId(initialCommands, 'theme.preset.${preset.id}');
        expect(item.category, equals('Theme'));
        expect(item.title, equals(preset.id));
      }
      expect(
        _byId(
          initialCommands,
          'theme.preset.${ws.activeTerminalTheme.id}',
        ).activeBadge,
        equals('Active'),
      );

      // Switch from dark theme to light preset: appearanceMode must sync to light.
      await _byId(initialCommands, 'theme.preset.solarized_light').onExecute!();
      expect(
        ws.workspaceSettings.themeSettings.appearanceMode,
        equals(ThemeAppearanceMode.light),
      );
      expect(
        ws.workspaceSettings.themeSettings.lightThemeId,
        equals('solarized_light'),
      );
      expect(ws.activeTerminalTheme.id, equals('solarized_light'));

      final afterLight = buildPaletteCommands(ctx);
      expect(
        _byId(afterLight, 'theme.preset.solarized_light').activeBadge,
        equals('Active'),
      );
      expect(_byId(afterLight, 'theme.preset.termui_dark').activeBadge, isNull);

      // Switch back to an opposite-brightness dark preset.
      await _byId(afterLight, 'theme.preset.catppuccin_mocha').onExecute!();
      expect(
        ws.workspaceSettings.themeSettings.appearanceMode,
        equals(ThemeAppearanceMode.dark),
      );
      expect(
        ws.workspaceSettings.themeSettings.darkThemeId,
        equals('catppuccin_mocha'),
      );
      expect(ws.activeTerminalTheme.id, equals('catppuccin_mocha'));

      // Appearance mode & font size commands.
      await _byId(afterLight, 'appearance.mode.system').onExecute!();
      expect(
        ws.workspaceSettings.themeSettings.appearanceMode,
        equals(ThemeAppearanceMode.system),
      );
      final baseFont = ws.effectiveFontSize;
      await _byId(afterLight, 'appearance.font_increase').onExecute!();
      expect(ws.effectiveFontSize, equals(baseFont + 1.0));
      await _byId(afterLight, 'appearance.font_decrease').onExecute!();
      expect(ws.effectiveFontSize, equals(baseFont));
      await _byId(afterLight, 'appearance.font_increase').onExecute!();
      await _byId(afterLight, 'appearance.font_reset').onExecute!();
      expect(ws.preferences.fontSize, isNull);
    });

    test(
      'toggles built-in shaders, custom .glsl shaders, and shader controls',
      () async {
        final openedDirs = <String>[];
        final store = _FakeShaderProfileStore(
          initialShaders: <String, String>{
            'aurora_bg.glsl': '''
// @fterm-stage: bg
void mainImage(out vec4 fragColor, in vec2 fragCoord) {
  fragColor = vec4(0.1, 0.2, 0.3, 1.0);
}
''',
            'glow_fg.glsl': '''
// @fterm-stage: fg
void mainImage(out vec4 fragColor, in vec2 fragCoord) {
  fragColor = texture(iChannel0, fragCoord / iResolution.xy);
}
''',
          },
        );
        final ws = _createWorkspace(
          shaderProfileStore: store,
          openedDirs: openedDirs,
        );
        addTearDown(ws.dispose);
        await ws.refreshCustomShaders();

        final ctx = PaletteContext(
          workspace: ws,
          isWeb: false,
          platform: .linux,
        );
        var cmds = buildPaletteCommands(ctx);

        // Built-in presets exist (excluding .none).
        for (final preset in TerminalShaderPreset.values) {
          if (preset == TerminalShaderPreset.none) continue;
          expect(
            cmds.any((item) => item.id == 'shader.preset.${preset.wireName}'),
            isTrue,
          );
        }

        // Toggle background preset.
        await _byId(cmds, 'shader.preset.wallpaper_wave').onExecute!();
        expect(ws.backgroundShaderChain, contains('wallpaper_wave'));
        cmds = buildPaletteCommands(ctx);
        expect(
          _byId(cmds, 'shader.preset.wallpaper_wave').activeBadge,
          equals('Active'),
        );
        await _byId(cmds, 'shader.preset.wallpaper_wave').onExecute!();
        expect(ws.backgroundShaderChain, isNot(contains('wallpaper_wave')));

        // Toggle foreground preset.
        await _byId(cmds, 'shader.preset.crt_lottes').onExecute!();
        expect(ws.foregroundShaderChain, contains('crt_lottes'));

        // Toggle discovered custom shaders into their hinted stages.
        await _byId(cmds, 'shader.custom.aurora_bg.glsl').onExecute!();
        expect(ws.backgroundShaderChain, contains('aurora_bg.glsl'));
        await _byId(cmds, 'shader.custom.glow_fg.glsl').onExecute!();
        expect(ws.foregroundShaderChain, contains('glow_fg.glsl'));
        cmds = buildPaletteCommands(ctx);
        expect(
          _byId(cmds, 'shader.custom.aurora_bg.glsl').activeBadge,
          equals('Active'),
        );
        expect(
          _byId(cmds, 'shader.custom.glow_fg.glsl').activeBadge,
          equals('Active'),
        );

        // Backend, Animation Mode, Max FPS, Emergency Stop, Reload, Folder, Editor.
        await _byId(cmds, 'shader.backend.disabled').onExecute!();
        expect(ws.shaderBackendOverride, equals(ShaderBackendKind.disabled));
        await _byId(cmds, 'shader.backend.auto').onExecute!();
        expect(ws.shaderBackendOverride, isNull);

        await _byId(cmds, 'shader.animation.always').onExecute!();
        expect(ws.shaderAnimationMode, equals(ShaderAnimationMode.always));

        await _byId(cmds, 'shader.max_fps.60').onExecute!();
        expect(ws.maxShaderFps, equals(60));
        await _byId(cmds, 'shader.max_fps.uncapped').onExecute!();
        expect(ws.maxShaderFps, isNull);

        await _byId(cmds, 'shader.emergency_stop').onExecute!();
        expect(ws.shadersEmergencyStopped, isTrue);
        cmds = buildPaletteCommands(ctx);
        expect(
          _byId(cmds, 'shader.emergency_stop').title,
          equals('Resume Shaders'),
        );
        expect(
          _byId(cmds, 'shader.emergency_stop').activeBadge,
          equals('Stopped'),
        );
        await _byId(cmds, 'shader.emergency_stop').onExecute!();
        expect(ws.shadersEmergencyStopped, isFalse);

        await _byId(cmds, 'shader.reload').onExecute!();
        await _byId(cmds, 'shader.open_folder').onExecute!();
        expect(openedDirs, equals(<String>['/tmp/fterm/shaders']));

        await _byId(cmds, 'shader.new_editor_tab').onExecute!();
        expect(ws.focusedEditorPane, isNotNull);
      },
    );

    test('executes boolean toggles, enum setters, Settings deep-links, and overlays', () async {
      final storage = _MemStorage();
      final updateService = _FakeUpdateService();
      final ws = _createWorkspace(
        storage: storage,
        updateService: updateService,
      );
      addTearDown(ws.dispose);
      final ctx = PaletteContext(
        workspace: ws,
        isWeb: false,
        platform: .windows,
      );

      var cmds = buildPaletteCommands(ctx);

      // Boolean toggles flip state and badges.
      expect(
        _byId(cmds, 'settings.toggle.auto_hide_single_tab').activeBadge,
        equals('Off'),
      );
      await _byId(cmds, 'settings.toggle.auto_hide_single_tab').onExecute!();
      expect(ws.preferences.autoHideSingleTab, isTrue);
      expect(
        _byId(
          buildPaletteCommands(ctx),
          'settings.toggle.auto_hide_single_tab',
        ).activeBadge,
        equals('On'),
      );

      final initialCopy = ws.copyOnSelect;
      await _byId(cmds, 'settings.toggle.copy_on_select').onExecute!();
      expect(ws.copyOnSelect, equals(!initialCopy));

      final initialOsc = ws.workspaceSettings.osc52Policy;
      await _byId(cmds, 'settings.toggle.osc52').onExecute!();
      expect(ws.workspaceSettings.osc52Policy, isNot(equals(initialOsc)));

      await _byId(cmds, 'settings.toggle.mute_audio').onExecute!();
      expect(ws.preferences.audioMuted, isTrue);

      await _byId(cmds, 'settings.toggle.perf_hud').onExecute!();
      expect(ws.showPerfHud, isTrue);

      await _byId(cmds, 'settings.toggle.macos_option_as_alt').onExecute!();
      expect(ws.preferences.macosOptionAsAlt, isTrue);

      final initialF12 = ws.f12ShortcutsEnabled;
      await _byId(cmds, 'settings.toggle.f12_shortcuts').onExecute!();
      expect(ws.f12ShortcutsEnabled, equals(!initialF12));

      final initialLogin = ws.preferences.loginShell;
      await _byId(cmds, 'settings.toggle.login_shell').onExecute!();
      expect(ws.preferences.loginShell, equals(!initialLogin));

      await _byId(cmds, 'settings.toggle.automation_driver').onExecute!();
      expect(ws.automationDriver.isRunning, isTrue);
      await _byId(
        buildPaletteCommands(ctx),
        'settings.toggle.automation_driver',
      ).onExecute!();
      expect(ws.automationDriver.isRunning, isFalse);

      // Enum setters: Dock Position, Meta Key Policy, Shell Presets, Windows GPU Driver.
      await _byId(cmds, 'interface.dock.left').onExecute!();
      expect(ws.dockPosition, equals(DockPosition.left));
      await _byId(cmds, 'interface.cycle_dock_position').onExecute!();
      expect(ws.dockPosition, equals(DockPosition.hidden));

      await _byId(cmds, 'keyboard.meta_policy.kitty').onExecute!();
      expect(ws.preferences.metaKeyMode, equals(FtermMetaKeyMode.kitty));

      await _byId(cmds, 'shell.preset.pwsh').onExecute!();
      expect(ws.preferences.shellExecutable, equals('pwsh'));
      await _byId(cmds, 'shell.preset.default').onExecute!();
      expect(ws.preferences.shellExecutable, isNull);

      await _byId(cmds, 'system.gpu_driver.highPerformance').onExecute!();
      expect(
        ws.gpuDriverPreference,
        equals(GpuDriverPreference.highPerformance),
      );

      // Settings section deep-links.
      for (final section in FtermSettingsSection.values) {
        await _byId(cmds, 'settings.open.${section.name}').onExecute!();
        expect(ws.activeOverlay, equals(FtermOverlay.settings));
        expect(ws.consumeRequestedSettingsSection(), equals(section));
      }

      // Reload from storage.
      await _byId(cmds, 'settings.reload_storage').onExecute!();

      // Check for Updates & modal overlays.
      await _byId(cmds, 'system.check_updates').onExecute!();
      expect(updateService.checkCalls, equals(1));
      expect(ws.activeOverlay, equals(FtermOverlay.settings));

      await _byId(cmds, 'overlay.connect').onExecute!();
      expect(ws.activeOverlay, equals(FtermOverlay.connect));
      await _byId(cmds, 'overlay.stats').onExecute!();
      expect(ws.activeOverlay, equals(FtermOverlay.stats));
      await _byId(cmds, 'overlay.help').onExecute!();
      expect(ws.activeOverlay, equals(FtermOverlay.help));
      await _byId(cmds, 'overlay.whats_new').onExecute!();
      expect(ws.activeOverlay, equals(FtermOverlay.whatsNew));
      await _byId(cmds, 'overlay.about').onExecute!();
      expect(ws.activeOverlay, equals(FtermOverlay.about));
    });

    test('executes Workspace, Tab, and Pane commands', () async {
      final ws = _createWorkspace();
      addTearDown(ws.dispose);
      final ctx = PaletteContext(workspace: ws, isWeb: false, platform: .linux);

      await _byId(
        buildPaletteCommands(ctx),
        'workspace.new_local_shell',
      ).onExecute!();
      expect(ws.tabs, hasLength(1));

      await _byId(buildPaletteCommands(ctx), 'pane.split_right').onExecute!();
      expect(ws.activeSplitTree!.paneCount, equals(2));

      final rightPaneId = ws.focusedPaneId!;
      await _byId(buildPaletteCommands(ctx), 'pane.focus_left').onExecute!();
      expect(ws.focusedPaneId, isNot(equals(rightPaneId)));
      await _byId(buildPaletteCommands(ctx), 'pane.focus_right').onExecute!();
      expect(ws.focusedPaneId, equals(rightPaneId));

      await _byId(buildPaletteCommands(ctx), 'pane.toggle_zoom').onExecute!();
      expect(ws.activeSplitTree!.isZoomed, isTrue);
      expect(
        _byId(buildPaletteCommands(ctx), 'pane.toggle_zoom').activeBadge,
        equals('Zoomed'),
      );
      await _byId(buildPaletteCommands(ctx), 'pane.toggle_zoom').onExecute!();
      expect(ws.activeSplitTree!.isZoomed, isFalse);

      await _byId(
        buildPaletteCommands(ctx),
        'workspace.new_local_shell',
      ).onExecute!();
      expect(ws.tabs, hasLength(2));
      expect(ws.activeTabIndex, equals(1));

      await _byId(buildPaletteCommands(ctx), 'tab.previous').onExecute!();
      expect(ws.activeTabIndex, equals(0));
      await _byId(buildPaletteCommands(ctx), 'tab.next').onExecute!();
      expect(ws.activeTabIndex, equals(1));

      await _byId(buildPaletteCommands(ctx), 'pane.close').onExecute!();
      expect(ws.tabs, hasLength(1));
    });
  });

  group('Platform visibility gating', () {
    test(
      'gates desktop-only, Windows-only, and update commands accurately',
      () {
        final ws = _createWorkspace();
        addTearDown(ws.dispose);

        final webIds = {
          for (final item in buildPaletteCommands(
            PaletteContext(
              workspace: ws,
              isWeb: true,
              platform: .linux,
              isDesktopHost: false,
              supportsUpdates: false,
            ),
          ))
            item.id,
        };
        expect(webIds, isNot(contains('workspace.new_local_shell')));
        expect(webIds, isNot(contains('pane.toggle_relay_share')));
        expect(webIds, isNot(contains('shader.open_folder')));
        expect(webIds, isNot(contains('settings.toggle.login_shell')));
        expect(webIds, isNot(contains('settings.toggle.automation_driver')));
        expect(webIds, isNot(contains('shell.preset.zsh')));
        expect(webIds, isNot(contains('shell.preset.pwsh')));
        expect(webIds, isNot(contains('system.gpu_driver.auto')));
        expect(webIds, isNot(contains('system.check_updates')));
        expect(webIds, isNot(contains('settings.open.shell')));
        expect(webIds, isNot(contains('settings.open.automation')));
        expect(webIds, isNot(contains('settings.open.updates')));
        // Cross-platform sections remain visible on Web.
        expect(webIds, contains('settings.open.interface'));
        expect(webIds, contains('settings.open.themes'));
        expect(webIds, contains('settings.open.shaders'));
        expect(webIds, contains('settings.open.keyboard'));
        expect(webIds, contains('settings.open.system'));

        final linuxDesktopIds = {
          for (final item in buildPaletteCommands(
            PaletteContext(
              workspace: ws,
              isWeb: false,
              platform: .linux,
              isDesktopHost: true,
              supportsUpdates: true,
            ),
          ))
            item.id,
        };
        expect(linuxDesktopIds, contains('workspace.new_local_shell'));
        expect(linuxDesktopIds, contains('shader.open_folder'));
        expect(linuxDesktopIds, contains('settings.toggle.login_shell'));
        expect(linuxDesktopIds, contains('settings.toggle.automation_driver'));
        expect(linuxDesktopIds, contains('shell.preset.zsh'));
        expect(linuxDesktopIds, contains('shell.preset.bash'));
        expect(linuxDesktopIds, isNot(contains('shell.preset.pwsh')));
        expect(linuxDesktopIds, isNot(contains('system.gpu_driver.auto')));
        expect(linuxDesktopIds, contains('system.check_updates'));

        final windowsDesktopIds = {
          for (final item in buildPaletteCommands(
            PaletteContext(
              workspace: ws,
              isWeb: false,
              platform: .windows,
              isDesktopHost: true,
              supportsUpdates: false,
            ),
          ))
            item.id,
        };
        expect(windowsDesktopIds, contains('shell.preset.pwsh'));
        expect(windowsDesktopIds, contains('shell.preset.powershell'));
        expect(windowsDesktopIds, contains('shell.preset.cmd'));
        expect(windowsDesktopIds, isNot(contains('shell.preset.zsh')));
        expect(windowsDesktopIds, contains('system.gpu_driver.auto'));
        expect(
          windowsDesktopIds,
          contains('system.gpu_driver.highPerformance'),
        );
        expect(windowsDesktopIds, contains('system.gpu_driver.powerSaving'));
        expect(windowsDesktopIds, isNot(contains('system.check_updates')));
        expect(windowsDesktopIds, isNot(contains('settings.open.updates')));
      },
    );
  });

  group('MRU pinning & fuzzy command query ranking', () {
    test(
      'pins Recently Used group at top on empty > query and deduplicates',
      () {
        final ws = _createWorkspace();
        addTearDown(ws.dispose);
        final ctx = PaletteContext(
          workspace: ws,
          isWeb: false,
          platform: .linux,
        );

        ws.recordRecentCommand('overlay.about');
        ws.recordRecentCommand('theme.preset.catppuccin_mocha');
        ws.recordRecentCommand('nonexistent.stale.command');

        final results = queryPaletteCommands(ctx, '');
        expect(results[0].id, equals('theme.preset.catppuccin_mocha'));
        expect(results[0].groupLabel, equals(paletteRecentlyUsedGroup));
        expect(results[1].id, equals('overlay.about'));
        expect(results[1].groupLabel, equals(paletteRecentlyUsedGroup));
        expect(results[2].groupLabel, equals(paletteAllCommandsGroup));

        final seen = <String>{};
        for (final item in results) {
          expect(seen.add(item.id), isTrue, reason: 'Duplicate id ${item.id}');
        }
      },
    );

    test('filters and ranks > commands with matchedTitleIndices and clears groupLabel', () {
      final ws = _createWorkspace();
      addTearDown(ws.dispose);
      final ctx = PaletteContext(workspace: ws, isWeb: false, platform: .linux);

      final results = queryPaletteCommands(ctx, 'catppuccin');
      expect(results, isNotEmpty);
      expect(results.first.id, equals('theme.preset.catppuccin_mocha'));
      expect(results.first.groupLabel, isNull);
      expect(
        results.first.matchedTitleIndices,
        equals(<int>[0, 1, 2, 3, 4, 5, 6, 7, 8, 9]),
      );
    });
  });

  group('Quick Switcher ordering & execution', () {
    test('orders Open Tabs, Split Panes (multi-pane only), Remote Sessions, and MRU commands', () async {
      final ws = _createWorkspace();
      addTearDown(ws.dispose);
      final ctx = PaletteContext(workspace: ws, isWeb: false, platform: .linux);

      // Open 2 local tabs; split Tab 1 into 2 panes, keep Tab 2 single-pane.
      await ws.openLocalShellTab();
      ws.renameTab(tabIndex: 0, title: 'dev-build');
      await ws.splitFocusedPane(.horizontal);
      final splitPane1 = ws.tabs[0].splitTree.paneIds[0];
      final splitPane2 = ws.tabs[0].splitTree.paneIds[1];

      await ws.openLocalShellTab();
      ws.renameTab(tabIndex: 1, title: 'logs');

      // Inject available remote relay sessions via repository bus.
      clientMessageReceivedEvent.post(
        ws.repository.bus,
        SessionDirectoryFrame(
          sessions: const <SessionSummary>[
            SessionSummary(
              id: SessionId('rem-prod'),
              title: 'prod-box',
              cols: 120,
              rows: 40,
              subscriberCount: 2,
              isUserPinned: false,
              allowSpawn: true,
            ),
          ],
        ),
      );

      // Record 6 MRU commands to verify default cap of 5 in Quick Switcher.
      ws.recordRecentCommand('overlay.about');
      ws.recordRecentCommand('overlay.help');
      ws.recordRecentCommand('overlay.stats');
      ws.recordRecentCommand('settings.toggle.perf_hud');
      ws.recordRecentCommand('settings.toggle.mute_audio');
      ws.recordRecentCommand('theme.preset.gruvbox_dark');

      final items = queryQuickSwitchItems(ctx, '');
      final groupsInOrder = <String>[];
      for (final item in items) {
        final group = item.groupLabel!;
        if (groupsInOrder.isEmpty || groupsInOrder.last != group) {
          groupsInOrder.add(group);
        }
      }
      expect(
        groupsInOrder,
        equals(<String>[
          quickSwitchTabsGroup,
          quickSwitchPanesGroup,
          quickSwitchRemoteGroup,
          quickSwitchRecentGroup,
        ]),
      );

      final tabItems = [
        for (final item in items)
          if (item.groupLabel == quickSwitchTabsGroup) item,
      ];
      expect(tabItems, hasLength(2));
      expect(tabItems[0].title, equals('Tab 1: dev-build'));
      expect(tabItems[0].activeBadge, isNull);
      expect(tabItems[1].title, equals('Tab 2: logs'));
      expect(tabItems[1].activeBadge, equals('Active'));

      // Only multi-pane Tab 1 produces Split Panes items.
      final paneItems = [
        for (final item in items)
          if (item.groupLabel == quickSwitchPanesGroup) item,
      ];
      expect(paneItems, hasLength(2));
      expect(paneItems[0].id, equals('switch.pane.$splitPane1'));
      expect(paneItems[1].id, equals('switch.pane.$splitPane2'));

      // Remote session item appears and opens remote tab on execute.
      final remoteItems = [
        for (final item in items)
          if (item.groupLabel == quickSwitchRemoteGroup) item,
      ];
      expect(remoteItems, hasLength(1));
      expect(remoteItems.first.title, equals('prod-box'));
      expect(remoteItems.first.activeBadge, isNull);

      // MRU commands capped at 5 in newest-first order.
      final recentItems = [
        for (final item in items)
          if (item.groupLabel == quickSwitchRecentGroup) item,
      ];
      expect(recentItems, hasLength(defaultQuickSwitchRecentLimit));
      expect(recentItems.first.id, equals('theme.preset.gruvbox_dark'));

      // Executing Quick Switcher items switches tab, focuses pane, opens remote.
      await tabItems[0].onExecute!();
      expect(ws.activeTabIndex, equals(0));

      await paneItems[0].onExecute!();
      expect(ws.focusedPaneId, equals(splitPane1));

      await remoteItems.first.onExecute!();
      expect(ws.tabs, hasLength(3));
      expect(
        _byId(
          queryQuickSwitchItems(ctx, ''),
          'switch.remote.rem-prod',
        ).activeBadge,
        equals('Open'),
      );

      // Filtered Quick Switcher query ranks matching items with indices.
      final filtered = queryQuickSwitchItems(ctx, 'prod');
      expect(filtered, isNotEmpty);
      expect(filtered.first.id, equals('switch.remote.rem-prod'));
      expect(filtered.first.matchedTitleIndices, equals(<int>[0, 1, 2, 3]));
      expect(filtered.first.groupLabel, isNull);
    });
  });
}
