import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fterm/src/audio/fterm_audio_controller.dart';
import 'package:fterm/src/commands/action_descriptors.dart';
import 'package:fterm/src/commands/fterm_capability_context.dart';
import 'package:fterm/src/commands/fterm_descriptor_models.dart';
import 'package:fterm/src/commands/shortcut_catalog.dart';
import 'package:fterm/src/launch_config.dart';
import 'package:fterm/src/perf/fterm_trace_recorder.dart';
import 'package:fterm/src/perf/trace_exporter.dart';
import 'package:fterm/src/settings_storage.dart';
import 'package:fterm/src/shader_profile_store.dart';
import 'package:fterm/src/update/update_service.dart';
import 'package:fterm/src/workspace/fterm_workspace_controller.dart';
import 'package:fterm/src/workspace/local_host_driver.dart';
import 'package:material_ui/material_ui.dart' show Icons;
import 'package:termui/termui.dart' as tui;
import 'package:termui_cast_client_core/termui_cast_client_core.dart';
import 'package:termui_cast_protocol/termui_cast_protocol.dart';
import 'package:termui_flutter/termui_flutter.dart'
    show DisabledShaderBackend, TerminalShaderController;
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

  void emitShareSnapshot(LocalShareSnapshot snapshot) {
    _shareSnapshot = snapshot;
    if (!_shareUpdates.isClosed) {
      _shareUpdates.add(snapshot);
    }
  }

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
    emitShareSnapshot(
      LocalShareSnapshot(
        state: LocalShareState.live,
        sessionId: sessionId,
        subscriberCount: 1,
      ),
    );
    return sessionId;
  }

  @override
  Future<void> stopShare() async {
    emitShareSnapshot(LocalShareSnapshot.unshared);
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

  _FakeLocalHostDriver();

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

  int listCalls = 0;

  @override
  Future<List<String>> listShaderFiles() async {
    listCalls += 1;
    return const <String>[];
  }

  @override
  Future<String> loadShaderSource(String pathOrKey) =>
      throw ShaderAssetException('Not found', pathOrKey: pathOrKey);

  @override
  Future<Uint8List> loadWallpaperBytes(String pathOrKey) =>
      throw ShaderAssetException('Not found', pathOrKey: pathOrKey);

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

final class _FakeUpdateService implements UpdateService {
  @override
  SelfUpdateCapability get capability => SelfUpdateCapability.supported;

  int checkCalls = 0;

  _FakeUpdateService();

  @override
  FtermSemVer get currentVersion => FtermSemVer.parse('0.7.0');

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

FtermTraceRecorder _createFakeTraceRecorder() => FtermTraceRecorder(
  sampleRssBytes: () => 64 * 1024 * 1024,
  registerTimingsCallback: (_) {},
  unregisterTimingsCallback: (_) {},
  exporter:
      ({
        required basePath,
        required traceJson,
        required summaryJson,
        required eventCount,
      }) async => TraceExportResult(
        tracePath: '$basePath.trace.json',
        summaryPath: '$basePath.summary.json',
        eventCount: eventCount,
      ),
);

FtermWorkspaceController _createWorkspace({
  _MemStorage? storage,
  _FakeLocalHostDriver? localHostDriver,
  _FakeShaderProfileStore? shaderProfileStore,
  _FakeUpdateService? updateService,
  FtermTraceRecorder? traceRecorder,
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
    updateService: updateService ?? _FakeUpdateService(),
    traceRecorder: traceRecorder,
    openDirectoryHandler: openedDirs == null
        ? null
        : (dir) async => openedDirs.add(dir),
  );
}

FtermActionDescriptor _requireAction(String id) {
  final descriptor = actionDescriptorById(id);
  expect(descriptor, isNotNull, reason: 'Expected action descriptor "$id"');
  return descriptor!;
}

void main() {
  const macDesktop = FtermCapabilityContext(
    isWeb: false,
    platform: .macOS,
    isDesktopHost: true,
    supportsUpdates: true,
  );
  const linuxDesktop = FtermCapabilityContext(
    isWeb: false,
    platform: .linux,
    isDesktopHost: true,
    supportsUpdates: true,
  );
  const windowsDesktop = FtermCapabilityContext(
    isWeb: false,
    platform: .windows,
    isDesktopHost: true,
    supportsUpdates: false,
  );
  const desktopNoShell = FtermCapabilityContext(
    isWeb: false,
    platform: .linux,
    isDesktopHost: false,
    supportsUpdates: false,
  );
  const webMac = FtermCapabilityContext(
    isWeb: true,
    platform: .macOS,
    isDesktopHost: false,
    supportsUpdates: false,
  );
  const webLinux = FtermCapabilityContext(
    isWeb: true,
    platform: .linux,
    isDesktopHost: false,
    supportsUpdates: false,
  );
  const webWindows = FtermCapabilityContext(
    isWeb: true,
    platform: .windows,
    isDesktopHost: false,
    supportsUpdates: false,
  );

  group('Action descriptor catalog integrity', () {
    test('has unique IDs, immutable lists, and exact category ordering', () {
      final combined = <FtermActionDescriptor>[
        ...workspaceAndTabActionDescriptors,
        ...appearanceActionDescriptors,
        ...shaderActionDescriptors,
        ...systemAndOverlayActionDescriptors,
      ];
      expect(allActionDescriptors, equals(combined));

      final seenIds = <String>{};
      for (final descriptor in allActionDescriptors) {
        expect(
          seenIds.add(descriptor.id),
          isTrue,
          reason: 'Duplicate action descriptor id: ${descriptor.id}',
        );
        expect(descriptor.category, isNotEmpty);
        expect(descriptor.title, isNotEmpty);
        expect(descriptor.keywords, isNotEmpty);
        expect(actionDescriptorById(descriptor.id), same(descriptor));
      }
      expect(actionDescriptorById('does.not.exist'), isNull);

      expect(
        () => allActionDescriptors.add(allActionDescriptors.first),
        throwsUnsupportedError,
      );
      expect(
        () => workspaceAndTabActionDescriptors.clear(),
        throwsUnsupportedError,
      );
      expect(() => appearanceActionDescriptors.clear(), throwsUnsupportedError);
      expect(() => shaderActionDescriptors.clear(), throwsUnsupportedError);
      expect(
        () => systemAndOverlayActionDescriptors.clear(),
        throwsUnsupportedError,
      );
    });

    test('preserves canonical Palette action ID order in each group', () {
      expect(
        <String>[for (final d in workspaceAndTabActionDescriptors) d.id],
        equals(const <String>[
          'workspace.new_local_shell',
          'workspace.sessions_picker',
          'pane.split_right',
          'pane.split_down',
          'pane.focus_left',
          'pane.focus_down',
          'pane.focus_up',
          'pane.focus_right',
          'pane.toggle_zoom',
          'pane.close',
          'tab.next',
          'tab.previous',
          'tab.rename',
          'pane.toggle_relay_share',
          'interface.cycle_dock_position',
        ]),
      );
      expect(
        <String>[for (final d in appearanceActionDescriptors) d.id],
        equals(const <String>[
          'appearance.font_increase',
          'appearance.font_decrease',
          'appearance.font_reset',
          'appearance.wallpaper_set',
        ]),
      );
      expect(
        <String>[for (final d in shaderActionDescriptors) d.id],
        equals(const <String>[
          'shader.emergency_stop',
          'shader.reload',
          'shader.open_folder',
          'shader.new_editor_tab',
        ]),
      );
      expect(
        <String>[for (final d in systemAndOverlayActionDescriptors) d.id],
        equals(const <String>[
          'settings.reload_storage',
          'system.check_updates',
          'diagnostics.toggle_trace_recording',
          'overlay.connect',
          'overlay.stats',
          'overlay.help',
          'overlay.whats_new',
          'overlay.about',
        ]),
      );
    });
  });

  group('Action execution side effects and dynamic builders', () {
    test('executes Workspace, Pane, Tab, and Dock actions', () async {
      final driver = _FakeLocalHostDriver();
      final ws = _createWorkspace(localHostDriver: driver);
      addTearDown(ws.dispose);

      // New local shell + horizontal & vertical splits + directional focus.
      await _requireAction('workspace.new_local_shell').execute(ws);
      expect(ws.tabs, hasLength(1));

      await _requireAction('pane.split_right').execute(ws);
      expect(ws.activeSplitTree!.paneCount, equals(2));
      final rightPaneId = ws.focusedPaneId!;

      await _requireAction('pane.focus_left').execute(ws);
      expect(ws.focusedPaneId, isNot(equals(rightPaneId)));
      await _requireAction('pane.focus_right').execute(ws);
      expect(ws.focusedPaneId, equals(rightPaneId));

      await _requireAction('pane.split_down').execute(ws);
      expect(ws.activeSplitTree!.paneCount, equals(3));
      final bottomPaneId = ws.focusedPaneId!;

      await _requireAction('pane.focus_up').execute(ws);
      expect(ws.focusedPaneId, isNot(equals(bottomPaneId)));
      await _requireAction('pane.focus_down').execute(ws);
      expect(ws.focusedPaneId, equals(bottomPaneId));

      // Toggle zoom + activeBadgeBuilder.
      final toggleZoom = _requireAction('pane.toggle_zoom');
      expect(toggleZoom.activeBadgeBuilder!(ws), isNull);
      await toggleZoom.execute(ws);
      expect(ws.activeSplitTree!.isZoomed, isTrue);
      expect(toggleZoom.activeBadgeBuilder!(ws), equals('Zoomed'));
      await toggleZoom.execute(ws);
      expect(ws.activeSplitTree!.isZoomed, isFalse);
      expect(toggleZoom.activeBadgeBuilder!(ws), isNull);

      // Tab navigation + close pane.
      await _requireAction('workspace.new_local_shell').execute(ws);
      expect(ws.tabs, hasLength(2));
      expect(ws.activeTabIndex, equals(1));

      await _requireAction('tab.previous').execute(ws);
      expect(ws.activeTabIndex, equals(0));
      await _requireAction('tab.next').execute(ws);
      expect(ws.activeTabIndex, equals(1));

      await _requireAction('pane.close').execute(ws);
      expect(ws.tabs, hasLength(1));

      // Sessions picker and rename overlays.
      await _requireAction('workspace.sessions_picker').execute(ws);
      expect(ws.activeOverlay, equals(FtermOverlay.sessionPicker));
      await _requireAction('tab.rename').execute(ws);
      expect(ws.activeOverlay, equals(FtermOverlay.rename));

      // Cycle dock position + dynamic subtitle.
      final cycleDock = _requireAction('interface.cycle_dock_position');
      expect(ws.dockPosition, equals(DockPosition.top));
      expect(cycleDock.subtitleBuilder!(ws), equals('Current: Top'));
      await cycleDock.execute(ws);
      expect(ws.dockPosition, equals(DockPosition.left));
      expect(cycleDock.subtitleBuilder!(ws), equals('Current: Left'));
      await cycleDock.execute(ws);
      expect(ws.dockPosition, equals(DockPosition.hidden));
      expect(cycleDock.subtitleBuilder!(ws), equals('Current: Hidden'));
      await cycleDock.execute(ws);
      expect(ws.dockPosition, equals(DockPosition.top));
      expect(cycleDock.subtitleBuilder!(ws), equals('Current: Top'));
    });

    test('computes dynamic relay share badges across share states', () async {
      final driver = _FakeLocalHostDriver();
      final ws = _createWorkspace(localHostDriver: driver);
      addTearDown(ws.dispose);

      final shareAction = _requireAction('pane.toggle_relay_share');
      expect(shareAction.activeBadgeBuilder!(ws), isNull);

      await _requireAction('workspace.new_local_shell').execute(ws);
      final host = driver.hosts.single;
      expect(shareAction.activeBadgeBuilder!(ws), isNull);

      host.emitShareSnapshot(
        const LocalShareSnapshot(state: LocalShareState.connecting),
      );
      await Future<void>.delayed(Duration.zero);
      expect(shareAction.activeBadgeBuilder!(ws), equals('Connecting'));

      host.emitShareSnapshot(
        LocalShareSnapshot(
          state: LocalShareState.live,
          sessionId: SessionId('shared-1'),
          subscriberCount: 2,
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(shareAction.activeBadgeBuilder!(ws), equals('Live'));

      host.emitShareSnapshot(
        const LocalShareSnapshot(
          state: LocalShareState.error,
          errorMessage: 'offline',
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(shareAction.activeBadgeBuilder!(ws), isNull);

      // Executing togglePaneShare starts sharing when configured, or opens
      // connect overlay when unconfigured; verify execution does not throw.
      await shareAction.execute(ws);
    });

    test('executes Appearance font zoom and wallpaper actions with dynamic subtitles', () async {
      final ws = _createWorkspace();
      addTearDown(ws.dispose);

      final increase = _requireAction('appearance.font_increase');
      final decrease = _requireAction('appearance.font_decrease');
      final reset = _requireAction('appearance.font_reset');
      final wallpaper = _requireAction('appearance.wallpaper_set');

      final baseFont = ws.effectiveFontSize;
      final baseFormatted = baseFont == baseFont.roundToDouble()
          ? '${baseFont.toInt()} pt'
          : '${baseFont.toStringAsFixed(1)} pt';
      expect(increase.subtitleBuilder!(ws), equals('Current: $baseFormatted'));
      expect(decrease.subtitleBuilder!(ws), equals('Current: $baseFormatted'));
      expect(reset.subtitleBuilder!(ws), equals('Current: $baseFormatted'));

      await increase.execute(ws);
      expect(ws.effectiveFontSize, equals(baseFont + 1.0));
      await decrease.execute(ws);
      expect(ws.effectiveFontSize, equals(baseFont));

      // Fractional font sizes format with one decimal place.
      ws.setFontSize(14.5);
      expect(increase.subtitleBuilder!(ws), equals('Current: 14.5 pt'));
      expect(decrease.subtitleBuilder!(ws), equals('Current: 14.5 pt'));
      expect(reset.subtitleBuilder!(ws), equals('Current: 14.5 pt'));

      await reset.execute(ws);
      expect(ws.preferences.fontSize, isNull);

      expect(wallpaper.subtitleBuilder!(ws), equals('None'));
      await ws.setBackgroundImagePath('/wallpapers/nebula.png');
      expect(wallpaper.subtitleBuilder!(ws), equals('/wallpapers/nebula.png'));
      await wallpaper.execute(ws);
      expect(ws.activeOverlay, equals(FtermOverlay.settings));
      expect(
        ws.consumeRequestedSettingsSection(),
        equals(FtermSettingsSection.themes),
      );
    });

    test('executes Shader actions including emergency stop dynamic title/icon/badge', () async {
      final store = _FakeShaderProfileStore();
      final openedDirs = <String>[];
      final ws = _createWorkspace(
        shaderProfileStore: store,
        openedDirs: openedDirs,
      );
      addTearDown(ws.dispose);

      final emergencyStop = _requireAction('shader.emergency_stop');
      expect(
        emergencyStop.dynamicTitleBuilder!(ws),
        equals('Emergency Stop Shaders'),
      );
      expect(
        emergencyStop.dynamicIconBuilder!(ws),
        equals(Icons.stop_circle_outlined),
      );
      expect(emergencyStop.activeBadgeBuilder!(ws), isNull);

      await emergencyStop.execute(ws);
      expect(ws.shadersEmergencyStopped, isTrue);
      expect(emergencyStop.dynamicTitleBuilder!(ws), equals('Resume Shaders'));
      expect(emergencyStop.dynamicIconBuilder!(ws), equals(Icons.play_arrow));
      expect(emergencyStop.activeBadgeBuilder!(ws), equals('Stopped'));

      await emergencyStop.execute(ws);
      expect(ws.shadersEmergencyStopped, isFalse);
      expect(
        emergencyStop.dynamicTitleBuilder!(ws),
        equals('Emergency Stop Shaders'),
      );
      expect(emergencyStop.activeBadgeBuilder!(ws), isNull);

      final listCallsBefore = store.listCalls;
      await _requireAction('shader.reload').execute(ws);
      expect(store.listCalls, greaterThan(listCallsBefore));

      await _requireAction('shader.open_folder').execute(ws);
      expect(openedDirs, equals(const <String>['/tmp/fterm/shaders']));

      await _requireAction('shader.new_editor_tab').execute(ws);
      expect(ws.focusedEditorPane, isNotNull);
    });

    test(
      'executes System, Diagnostics trace recording, and Overlay actions',
      () async {
        final updateService = _FakeUpdateService();
        final traceRecorder = _createFakeTraceRecorder();
        final ws = _createWorkspace(
          updateService: updateService,
          traceRecorder: traceRecorder,
        );
        addTearDown(() async {
          traceRecorder.dispose();
          await ws.dispose();
        });

        await _requireAction('settings.reload_storage').execute(ws);

        await _requireAction('system.check_updates').execute(ws);
        expect(updateService.checkCalls, equals(1));
        expect(ws.activeOverlay, equals(FtermOverlay.settings));
        expect(
          ws.consumeRequestedSettingsSection(),
          equals(FtermSettingsSection.updates),
        );

        final traceAction = _requireAction(
          'diagnostics.toggle_trace_recording',
        );
        expect(traceAction.category, equals('System'));
        expect(traceAction.title, equals('Toggle Trace Recording'));
        expect(traceAction.visibility, equals(FtermVisibility.desktopOnly));
        expect(traceAction.shortcut, same(FtermShortcuts.toggleTraceRecording));
        expect(ws.isRecordingTrace, isFalse);
        expect(traceAction.activeBadgeBuilder!(ws), isNull);

        await traceAction.execute(ws);
        expect(ws.isRecordingTrace, isTrue);
        expect(traceAction.activeBadgeBuilder!(ws), equals('Recording'));

        await traceAction.execute(ws);
        expect(ws.isRecordingTrace, isFalse);
        expect(traceAction.activeBadgeBuilder!(ws), isNull);

        await _requireAction('overlay.connect').execute(ws);
        expect(ws.activeOverlay, equals(FtermOverlay.connect));
        await _requireAction('overlay.stats').execute(ws);
        expect(ws.activeOverlay, equals(FtermOverlay.stats));
        await _requireAction('overlay.help').execute(ws);
        expect(ws.activeOverlay, equals(FtermOverlay.help));
        await _requireAction('overlay.whats_new').execute(ws);
        expect(ws.activeOverlay, equals(FtermOverlay.whatsNew));
        await _requireAction('overlay.about').execute(ws);
        expect(ws.activeOverlay, equals(FtermOverlay.about));
      },
    );
  });

  group('Visibility and feature-flag gating', () {
    test('gates desktop, local shell, and updates actions across contexts', () {
      List<String> visibleIds(FtermCapabilityContext ctx) => <String>[
        for (final descriptor in allActionDescriptors)
          if (descriptor.isVisibleFor(ctx)) descriptor.id,
      ];

      final macIds = visibleIds(macDesktop);
      final winIds = visibleIds(windowsDesktop);
      final noShellIds = visibleIds(desktopNoShell);
      final webIds = visibleIds(webLinux);

      // Full desktop with updates sees every action.
      expect(macIds, hasLength(allActionDescriptors.length));
      expect(macIds, contains('workspace.new_local_shell'));
      expect(macIds, contains('pane.toggle_relay_share'));
      expect(macIds, contains('shader.open_folder'));
      expect(macIds, contains('system.check_updates'));
      expect(macIds, contains('diagnostics.toggle_trace_recording'));

      // Desktop without updates hides only system.check_updates.
      expect(winIds, isNot(contains('system.check_updates')));
      expect(winIds, contains('diagnostics.toggle_trace_recording'));
      expect(winIds, contains('workspace.new_local_shell'));

      // Desktop without local PTY shell hides local-shell actions but keeps
      // desktop-only diagnostics.
      expect(noShellIds, isNot(contains('workspace.new_local_shell')));
      expect(noShellIds, isNot(contains('pane.toggle_relay_share')));
      expect(noShellIds, isNot(contains('shader.open_folder')));
      expect(noShellIds, isNot(contains('system.check_updates')));
      expect(noShellIds, contains('diagnostics.toggle_trace_recording'));

      // Web hides all desktop-only, local-shell, and updates actions, while
      // keeping cross-platform actions like shader.reload and overlays.
      expect(webIds, isNot(contains('workspace.new_local_shell')));
      expect(webIds, isNot(contains('pane.toggle_relay_share')));
      expect(webIds, isNot(contains('shader.open_folder')));
      expect(webIds, isNot(contains('system.check_updates')));
      expect(webIds, isNot(contains('diagnostics.toggle_trace_recording')));
      expect(webIds, contains('shader.reload'));
      expect(webIds, contains('shader.emergency_stop'));
      expect(webIds, contains('overlay.about'));
    });

    test(
      'evaluates featureFlag and isAvailable gating on action descriptors',
      () {
        final flaggedAction = FtermActionDescriptor(
          id: 'experimental.trace_export',
          category: 'System',
          title: 'Export Flamegraph',
          icon: Icons.analytics_outlined,
          visibility: .desktopOnly,
          featureFlag: 'experimental.flamegraph',
          isAvailable: (ctx) => ctx.isLinuxDesktop || ctx.isMacOsDesktop,
          execute: (_) {},
        );

        expect(flaggedAction.isVisibleFor(linuxDesktop), isFalse);
        expect(flaggedAction.isVisibleFor(webLinux), isFalse);

        const linuxFlagged = FtermCapabilityContext(
          isWeb: false,
          platform: .linux,
          isDesktopHost: true,
          supportsUpdates: true,
          enabledFeatures: <String>{'experimental.flamegraph'},
        );
        const windowsFlagged = FtermCapabilityContext(
          isWeb: false,
          platform: .windows,
          isDesktopHost: true,
          supportsUpdates: true,
          enabledFeatures: <String>{'experimental.flamegraph'},
        );
        const webFlagged = FtermCapabilityContext(
          isWeb: true,
          platform: .linux,
          isDesktopHost: false,
          supportsUpdates: false,
          enabledFeatures: <String>{'experimental.flamegraph'},
        );

        expect(flaggedAction.isVisibleFor(linuxFlagged), isTrue);
        expect(flaggedAction.isVisibleFor(windowsFlagged), isFalse);
        expect(flaggedAction.isVisibleFor(webFlagged), isFalse);
      },
    );
  });

  group('Shortcut hint formatting across Web, macOS, Linux, and Windows', () {
    test('formats every bound action shortcut consistently per platform', () {
      String? hint(String actionId, FtermCapabilityContext ctx) =>
          _requireAction(actionId).shortcut?.formatPaletteHint(ctx);

      expect(hint('workspace.new_local_shell', macDesktop), equals('Cmd+T'));
      expect(
        hint('workspace.new_local_shell', linuxDesktop),
        equals('Ctrl+Shift+T'),
      );
      expect(
        hint('workspace.new_local_shell', windowsDesktop),
        equals('Ctrl+Shift+T'),
      );
      expect(hint('workspace.new_local_shell', webMac), isNull);
      expect(hint('workspace.new_local_shell', webLinux), isNull);

      expect(hint('pane.split_right', macDesktop), equals('Cmd+D'));
      expect(hint('pane.split_right', linuxDesktop), equals('Ctrl+Shift+D'));
      expect(hint('pane.split_right', windowsDesktop), equals('Ctrl+Shift+D'));
      expect(hint('pane.split_right', webMac), equals(r'Ctrl+\ |'));
      expect(hint('pane.split_right', webWindows), equals(r'Ctrl+\ |'));

      expect(hint('pane.split_down', macDesktop), equals('Cmd+Shift+D'));
      expect(hint('pane.split_down', linuxDesktop), equals('Ctrl+Shift+E'));
      expect(hint('pane.split_down', windowsDesktop), equals('Ctrl+Shift+E'));
      expect(hint('pane.split_down', webLinux), equals(r'Ctrl+\ -'));

      expect(hint('pane.close', macDesktop), equals('Cmd+W'));
      expect(hint('pane.close', linuxDesktop), equals('Ctrl+Shift+W'));
      expect(hint('pane.close', windowsDesktop), equals('Ctrl+Shift+W'));
      expect(hint('pane.close', webMac), equals(r'Ctrl+\ x'));

      expect(hint('appearance.font_increase', macDesktop), equals('Cmd+='));
      expect(hint('appearance.font_increase', linuxDesktop), equals('Ctrl+='));
      expect(
        hint('appearance.font_increase', windowsDesktop),
        equals('Ctrl+='),
      );
      expect(hint('appearance.font_increase', webMac), equals('Cmd+='));
      expect(hint('appearance.font_increase', webLinux), equals('Ctrl+='));

      expect(hint('appearance.font_decrease', macDesktop), equals('Cmd+-'));
      expect(hint('appearance.font_decrease', linuxDesktop), equals('Ctrl+-'));
      expect(hint('appearance.font_decrease', webWindows), equals('Ctrl+-'));

      expect(hint('appearance.font_reset', macDesktop), equals('Cmd+0'));
      expect(hint('appearance.font_reset', windowsDesktop), equals('Ctrl+0'));
      expect(hint('appearance.font_reset', webMac), equals('Cmd+0'));

      expect(
        hint('shader.emergency_stop', macDesktop),
        equals('Ctrl+Shift+F6'),
      );
      expect(
        hint('shader.emergency_stop', linuxDesktop),
        equals('Ctrl+Shift+F6'),
      );
      expect(hint('shader.emergency_stop', webLinux), equals('Ctrl+Shift+F6'));

      expect(hint('shader.reload', macDesktop), equals('Ctrl+Shift+F5'));
      expect(hint('shader.reload', linuxDesktop), equals('Ctrl+Shift+F5'));
      expect(hint('shader.reload', windowsDesktop), equals('Ctrl+Shift+F5'));
      expect(hint('shader.reload', webMac), isNull);
      expect(hint('shader.reload', webLinux), isNull);

      expect(
        hint('diagnostics.toggle_trace_recording', macDesktop),
        equals('Ctrl+Shift+F10'),
      );
      expect(
        hint('diagnostics.toggle_trace_recording', linuxDesktop),
        equals('Ctrl+Shift+F10'),
      );
      expect(
        hint('diagnostics.toggle_trace_recording', windowsDesktop),
        equals('Ctrl+Shift+F10'),
      );
      expect(hint('diagnostics.toggle_trace_recording', webMac), isNull);
      expect(hint('diagnostics.toggle_trace_recording', webWindows), isNull);

      // Leader-chord-only actions stay consistent on desktop and Web.
      for (final (id, expected) in const <(String, String)>[
        ('workspace.sessions_picker', r'Ctrl+\ c'),
        ('pane.focus_left', r'Ctrl+\ h'),
        ('pane.focus_down', r'Ctrl+\ j'),
        ('pane.focus_up', r'Ctrl+\ k'),
        ('pane.focus_right', r'Ctrl+\ l'),
        ('pane.toggle_zoom', r'Ctrl+\ z'),
        ('tab.next', r'Ctrl+\ n'),
        ('tab.previous', r'Ctrl+\ p'),
        ('tab.rename', r'Ctrl+\ r'),
        ('pane.toggle_relay_share', r'Ctrl+\ b'),
        ('interface.cycle_dock_position', r'Ctrl+\ d'),
        ('shader.new_editor_tab', r'Ctrl+\ e'),
        ('overlay.stats', r'Ctrl+\ i'),
        ('overlay.help', r'Ctrl+\ ?'),
        ('overlay.about', r'Ctrl+\ a'),
      ]) {
        expect(hint(id, macDesktop), equals(expected), reason: id);
        expect(hint(id, linuxDesktop), equals(expected), reason: id);
        expect(hint(id, windowsDesktop), equals(expected), reason: id);
        expect(hint(id, webLinux), equals(expected), reason: id);
      }

      // Zero desktop-only shortcut labels leak into Web mode across the entire
      // action catalog.
      for (final descriptor in allActionDescriptors) {
        final binding = descriptor.shortcut;
        if (binding == null || !binding.desktopOnlyHint) continue;
        for (final webCtx in const <FtermCapabilityContext>[
          webMac,
          webLinux,
          webWindows,
        ]) {
          expect(
            binding.formatPaletteHint(webCtx),
            equals(binding.leaderChordLabel),
            reason:
                '${descriptor.id} leaked a desktop-only hint on ${webCtx.platform}',
          );
        }
      }
    });
  });
}
