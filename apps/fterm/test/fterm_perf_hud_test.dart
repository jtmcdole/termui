import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fterm/src/audio/fterm_audio_controller.dart';
import 'package:fterm/src/font_loader.dart';
import 'package:fterm/src/launch_config.dart';
import 'package:fterm/src/perf/fterm_trace_recorder.dart';
import 'package:fterm/src/perf/trace_exporter.dart';
import 'package:fterm/src/settings_storage.dart';
import 'package:fterm/src/shader_profile_store.dart';
import 'package:fterm/src/ui/fterm_perf_hud.dart';
import 'package:fterm/src/ui/fterm_shell_scaffold.dart';
import 'package:fterm/src/ui/fterm_shortcut_dispatcher.dart';
import 'package:fterm/src/workspace/fterm_workspace_controller.dart';
import 'package:fterm/src/workspace/local_host_driver.dart';
import 'package:material_ui/material_ui.dart';
import 'package:termui/terminal/event.dart' as ev;
import 'package:termui/termui.dart' as tui;
import 'package:termui_cast_client_core/termui_cast_client_core.dart';
import 'package:termui_cast_protocol/termui_cast_protocol.dart';
import 'package:termui_flutter/termui_flutter.dart';
import 'package:termui_pty/termui_pty.dart';

final class _MemorySettingsStorage implements SettingsStorage {
  final Map<String, String> _items = <String, String>{};

  @override
  String? getItem(String key) => _items[key];

  @override
  void setItem(String key, String value) => _items[key] = value;
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

  final StreamController<LocalShareSnapshot> _shareUpdates =
      StreamController<LocalShareSnapshot>.broadcast();

  @override
  Stream<LocalShareSnapshot> get shareUpdates => _shareUpdates.stream;

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
    await _shareUpdates.close();
    await port.dispose();
    await _session.dispose();
  }
}

final class _FakeDesktopLocalHostDriver implements LocalHostDriver {
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

final class _FakeShaderStore implements ShaderProfileStore {
  final Map<String, Uint8List> wallpapers = <String, Uint8List>{};
  final Map<String, String> shaders = <String, String>{};
  final StreamController<ShaderDirectoryChange> _changes =
      StreamController<ShaderDirectoryChange>.broadcast();

  @override
  String? get shadersDirectoryPath => '/tmp/fterm/shaders';

  @override
  Future<Uint8List> loadWallpaperBytes(String pathOrKey) async {
    final data = wallpapers[pathOrKey];
    if (data == null) {
      throw ShaderAssetException('Missing wallpaper', pathOrKey: pathOrKey);
    }
    return data;
  }

  @override
  Future<String> loadShaderSource(String pathOrKey) async {
    final src = shaders[pathOrKey];
    if (src == null) {
      throw ShaderAssetException('Missing shader', pathOrKey: pathOrKey);
    }
    return src;
  }

  @override
  Future<List<String>> listShaderFiles() async => shaders.keys.toList();

  @override
  Future<void> saveShaderSource(String name, String glslSource) async {
    shaders[name] = glslSource;
  }

  @override
  Future<void> saveWallpaperBytes(String key, Uint8List bytes) async {
    wallpapers[key] = bytes;
  }

  @override
  Stream<ShaderDirectoryChange> watchShaderDirectory() => _changes.stream;

  @override
  void dispose() {
    unawaited(_changes.close());
  }
}

Future<Uint8List> _createValidPng() async {
  final recorder = ui.PictureRecorder();
  ui.Canvas(recorder).drawRect(const ui.Rect.fromLTWH(0, 0, 2, 2), ui.Paint());
  final pic = recorder.endRecording();
  final img = await pic.toImage(2, 2);
  pic.dispose();
  final data = await img.toByteData(format: ui.ImageByteFormat.png);
  img.dispose();
  return data!.buffer.asUint8List();
}

final class _FakeDiagnosableBackend
    implements TerminalShaderBackend, DiagnosableShaderBackend {
  static const DisabledShaderBackend _delegate = DisabledShaderBackend();

  ShaderBackendDiagnostics diagnostics;

  _FakeDiagnosableBackend(this.diagnostics);

  @override
  ShaderBackendKind get kind => _delegate.kind;

  @override
  bool get supportsCustomGlsl => _delegate.supportsCustomGlsl;

  @override
  bool get supportsSyncBackground => _delegate.supportsSyncBackground;

  @override
  Future<CompiledShaderHandle> compile(
    String id,
    String glslSource, {
    bool usesPrevFrame = false,
  }) => _delegate.compile(id, glslSource, usesPrevFrame: usesPrevFrame);

  @override
  Future<void> reload(CompiledShaderHandle handle, String glslSource) =>
      _delegate.reload(handle, glslSource);

  @override
  ui.Image? renderBackgroundSync({
    required List<ShaderPassInvocation> passes,
    required ui.Size physicalSize,
    ui.Image? wallpaperImage,
    GpuFrameWatchdog? watchdog,
  }) => _delegate.renderBackgroundSync(
    passes: passes,
    physicalSize: physicalSize,
    wallpaperImage: wallpaperImage,
    watchdog: watchdog,
  );

  @override
  Future<ui.Image?> renderPassesAsync({
    required List<ShaderPassInvocation> passes,
    required ui.Size physicalSize,
    ui.Image? inputImage,
    ui.Image? wallpaperImage,
    GpuFrameWatchdog? watchdog,
  }) => _delegate.renderPassesAsync(
    passes: passes,
    physicalSize: physicalSize,
    inputImage: inputImage,
    wallpaperImage: wallpaperImage,
    watchdog: watchdog,
  );

  @override
  void dispose() => _delegate.dispose();

  @override
  ShaderBackendDiagnostics readDiagnostics() => diagnostics;
}

({
  FtermWorkspaceController workspace,
  _MemorySettingsStorage storage,
  _FakeShaderStore store,
})
_buildWorkspace({
  TerminalShaderBackend? backend,
  FtermTraceRecorder? traceRecorder,
  CastLaunchConfig? launchConfig,
  Future<void> Function()? onRequestExit,
  Future<bool> Function(List<String> args)? onRelaunchApp,
  Future<void> Function(String directoryPath)? openDirectoryHandler,
}) {
  final storage = _MemorySettingsStorage();
  // Keep headless widget/unit tests muted so key events never trigger SoLoud FFI init.
  saveStoredPreferences(storage, const FtermPreferences(audioMuted: true));
  final store = _FakeShaderStore();
  final transport = WsClientTransport(
    serverUri: CastLaunchConfig.defaultServerUri,
    token: '',
  );
  final repository = CastClientRepository(transport: transport);
  final shaderController = TerminalShaderController(
    backendFactory: (_) => backend ?? const DisabledShaderBackend(),
  );
  final workspace = FtermWorkspaceController(
    launchConfig: launchConfig ?? CastLaunchConfig(promptForConnection: true),
    repository: repository,
    localHostDriver: _FakeDesktopLocalHostDriver(),
    audioController: FtermAudioController(requireUserGesture: false),
    storage: storage,
    resizeDebounce: Duration.zero,
    shaderController: shaderController,
    shaderProfileStore: store,
    traceRecorder: traceRecorder,
    onRequestExit: onRequestExit,
    onRelaunchApp: onRelaunchApp,
    openDirectoryHandler: openDirectoryHandler,
  );
  return (workspace: workspace, storage: storage, store: store);
}

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    await loadCastFonts();
  });

  group('PerfHudTracker frame timing math', () {
    test(
      'computes FPS, avg/p95 build & raster durations, and evicts oldest',
      () {
        final tracker = PerfHudTracker(maxSamples: 5);
        expect(tracker.computeMetrics().sampleCount, 0);
        expect(tracker.computeMetrics().fps, 0.0);

        // Single sample falls back to 1000 / avgTotalMs.
        tracker.recordRawSample(
          vsyncTimestampUs: 1000000,
          buildUs: 2000,
          rasterUs: 4000,
          totalUs: 10000,
        );
        final single = tracker.computeMetrics();
        expect(single.sampleCount, 1);
        expect(single.fps, closeTo(100.0, 0.1));
        expect(single.avgBuildMs, closeTo(2.0, 0.01));
        expect(single.avgRasterMs, closeTo(4.0, 0.01));

        // Fill beyond maxSamples (60Hz -> 16667 us spacing) with one spike.
        tracker.clear();
        for (var i = 0; i < 7; i++) {
          tracker.recordRawSample(
            vsyncTimestampUs: i * 16667,
            buildUs: i == 6 ? 8000 : 1500,
            rasterUs: i == 6 ? 12000 : 3000,
            totalUs: i == 6 ? 20000 : 5000,
          );
        }
        expect(tracker.sampleCount, 5);
        final metrics = tracker.computeMetrics();
        expect(metrics.fps, closeTo(60.0, 0.5));
        expect(metrics.p95BuildMs, closeTo(8.0, 0.01));
        expect(metrics.p95RasterMs, closeTo(12.0, 0.01));
        expect(metrics.p95TotalMs, closeTo(20.0, 0.01));

        // Also verify ui.FrameTiming ingestion directly.
        tracker.recordTimings(<ui.FrameTiming>[
          ui.FrameTiming(
            vsyncStart: 200000,
            buildStart: 200000,
            buildFinish: 202500,
            rasterStart: 202500,
            rasterFinish: 206500,
            rasterFinishWallTime: 206500,
          ),
        ]);
        expect(tracker.sampleCount, 5);
      },
    );
  });

  group('Background opacity auto-reveal and Perf HUD persistence', () {
    test('auto-lowers backgroundOpacity from 1.0 to 0.5 when enabling background shader or wallpaper', () async {
      final env = _buildWorkspace();
      addTearDown(env.workspace.dispose);

      expect(env.workspace.backgroundOpacity, 1.0);
      await env.workspace.setBackgroundShaderChain(const <String>[
        'wallpaper_wave',
      ]);
      expect(
        env.workspace.backgroundOpacity,
        FtermWorkspaceController.autoRevealBackgroundOpacity,
      );

      // User custom opacity (< 1.0) must NOT be overwritten.
      env.workspace.setBackgroundOpacity(0.75);
      final png = await _createValidPng();
      env.store.wallpapers['/tmp/bg.png'] = png;
      await env.workspace.setBackgroundImagePath('/tmp/bg.png');
      expect(env.workspace.backgroundOpacity, closeTo(0.75, 0.001));

      // If user sets back to 1.0 and uploads a new wallpaper, auto-reveal triggers.
      env.workspace.setBackgroundOpacity(1.0);
      await env.workspace.uploadWallpaperBytes('uploaded.png', png);
      expect(env.workspace.backgroundOpacity, closeTo(0.5, 0.001));
    });

    test(
      'FtermPreferences persists showPerfHud and Ctrl+Shift+F9 toggles it',
      () {
        const defaults = FtermPreferences.defaults;
        expect(defaults.showPerfHud, isFalse);

        final enabled = defaults.copyWith(showPerfHud: true);
        final roundTrip = FtermPreferences.fromJsonString(
          enabled.toJsonString(),
        );
        expect(roundTrip.showPerfHud, isTrue);
        expect(roundTrip, equals(enabled));
        expect(roundTrip.hashCode, equals(enabled.hashCode));

        final env = _buildWorkspace();
        addTearDown(env.workspace.dispose);
        final dispatcher = FtermShortcutDispatcher(
          workspace: env.workspace,
          platformOverride: TargetPlatform.windows,
          isWebOverride: false,
        );

        final event = KeyDownEvent(
          physicalKey: PhysicalKeyboardKey.f9,
          logicalKey: LogicalKeyboardKey.f9,
          timeStamp: Duration.zero,
        );
        const mods = <ev.Modifier>{ev.Modifier.control, ev.Modifier.shift};
        expect(env.workspace.showPerfHud, isFalse);
        expect(
          dispatcher.handleHostShortcut(event, mods),
          equals(HostShortcutResult.handled),
        );
        expect(env.workspace.showPerfHud, isTrue);
        expect(
          dispatcher.handleHostShortcut(event, mods),
          equals(HostShortcutResult.handled),
        );
        expect(env.workspace.showPerfHud, isFalse);
      },
    );
  });

  group('FtermPerfHud widget rendering and Settings switch', () {
    testWidgets(
      'toggles Performance HUD from Settings switch and renders FPS/UI/GPU metrics',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(960, 720));
        addTearDown(() => tester.binding.setSurfaceSize(null));

        final env = _buildWorkspace();
        await env.workspace.openLocalShellTab();

        await tester.pumpWidget(
          MaterialApp(
            home: FtermShellScaffold(
              workspace: env.workspace,
              onOpenUrl: (_) {},
              platformOverride: TargetPlatform.windows,
              isWebOverride: false,
            ),
          ),
        );
        await tester.pump();
        expect(find.byKey(const ValueKey('fterm-perf-hud')), findsNothing);

        // Open Settings -> System and toggle Performance HUD switch on.
        env.workspace.openSettingsOverlay(initialSection: .system);
        await tester.pump();

        final switchFinder = find.byKey(
          const ValueKey('settings-perf-hud-switch'),
        );
        await tester.ensureVisible(switchFinder);
        await tester.tap(switchFinder);
        await tester.pump();

        expect(env.workspace.showPerfHud, isTrue);
        expect(find.byKey(const ValueKey('fterm-perf-hud')), findsOneWidget);
        expect(
          find.byKey(const ValueKey('fterm-perf-hud-fps')),
          findsOneWidget,
        );
        expect(find.byKey(const ValueKey('fterm-perf-hud-ui')), findsOneWidget);
        expect(
          find.byKey(const ValueKey('fterm-perf-hud-gpu')),
          findsOneWidget,
        );

        // Verify pre-populated tracker renders green/amber/red metrics cleanly.
        for (final (spacingUs, totalUs) in const <(int, int)>[
          (16667, 8000),
          (25000, 26000),
          (50000, 48000),
        ]) {
          final tracker = PerfHudTracker();
          for (var i = 0; i < 5; i++) {
            tracker.recordRawSample(
              vsyncTimestampUs: i * spacingUs,
              buildUs: totalUs ~/ 3,
              rasterUs: (totalUs * 2) ~/ 3,
              totalUs: totalUs,
            );
          }
          await tester.pumpWidget(
            MaterialApp(
              home: Scaffold(
                body: FtermPerfHud(
                  workspace: env.workspace,
                  tracker: tracker,
                  refreshInterval: Duration.zero,
                ),
              ),
            ),
          );
          await tester.pump();
          final fpsWidget = tester.widget<Text>(
            find.byKey(const ValueKey('fterm-perf-hud-fps')),
          );
          expect(fpsWidget.data, contains('FPS'));
          expect(fpsWidget.data, isNot(contains('--.-')));
        }

        // Trigger real FrameTiming callback delivery and verify clean disposal.
        tester.binding.platformDispatcher.onReportTimings?.call(
          <ui.FrameTiming>[
            ui.FrameTiming(
              vsyncStart: 100000,
              buildStart: 100000,
              buildFinish: 101500,
              rasterStart: 101500,
              rasterFinish: 104500,
              rasterFinishWallTime: 104500,
            ),
          ],
        );
        await tester.pump();
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(env.workspace.dispose);
      },
    );

    testWidgets(
      'displays GPU diagnostics, toggles REC/STOP reactively, and handles Ctrl+Shift+F10',
      (tester) async {
        final fakeBackend = _FakeDiagnosableBackend(
          const ShaderBackendDiagnostics(
            inFlightFrames: 1,
            maxFramesInFlight: 2,
            backpressureSkips: 4,
            backingTextureCount: 3,
            surfaceCount: 1,
          ),
        );
        final recorder = FtermTraceRecorder(
          sampleRssBytes: () => 150 * 1024 * 1024,
          readDiagnostics: fakeBackend.readDiagnostics,
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
        final env = _buildWorkspace(
          backend: fakeBackend,
          traceRecorder: recorder,
        );
        addTearDown(() async {
          recorder.dispose();
          await env.workspace.dispose();
        });

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: FtermPerfHud(
                workspace: env.workspace,
                sampleRssBytes: () => 150 * 1024 * 1024,
              ),
            ),
          ),
        );
        await tester.pump();

        final diagText = tester.widget<Text>(
          find.byKey(const ValueKey('fterm-perf-hud-diagnostics')),
        );
        expect(diagText.data, contains('in-flight 1/2'));
        expect(diagText.data, contains('tex 3'));
        expect(diagText.data, contains('skip 4'));
        expect(diagText.data, contains('RSS 150 MB'));

        expect(find.text('REC'), findsOneWidget);
        await tester.tap(
          find.byKey(const ValueKey('fterm-perf-hud-trace-toggle')),
        );
        await tester.pump();
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));
        await tester.pump();

        expect(env.workspace.isRecordingTrace, isTrue);
        expect(find.text('STOP'), findsOneWidget);

        // Ctrl+Shift+F10 stops recording and surfaces export confirmation.
        final dispatcher = FtermShortcutDispatcher(
          workspace: env.workspace,
          platformOverride: TargetPlatform.windows,
          isWebOverride: false,
        );
        final f10 = KeyDownEvent(
          physicalKey: PhysicalKeyboardKey.f10,
          logicalKey: LogicalKeyboardKey.f10,
          timeStamp: Duration.zero,
        );
        const mods = <ev.Modifier>{ev.Modifier.control, ev.Modifier.shift};
        expect(
          dispatcher.handleHostShortcut(f10, mods),
          equals(HostShortcutResult.handled),
        );
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump();

        expect(env.workspace.isRecordingTrace, isFalse);
        expect(env.workspace.lastTraceExport, isNotNull);
        final statusText = tester.widget<Text>(
          find.byKey(const ValueKey('fterm-perf-hud-trace-status')),
        );
        expect(statusText.data, contains('Saved '));

        // Verify pointer clicks over the HUD metrics panel pass through to
        // underlying widgets while the REC/STOP button remains interactive.
        var underlyingTaps = 0;
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Stack(
                children: [
                  Positioned.fill(
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () => underlyingTaps++,
                      child: const SizedBox.expand(),
                    ),
                  ),
                  Align(
                    alignment: Alignment.topRight,
                    child: FtermPerfHud(
                      workspace: env.workspace,
                      sampleRssBytes: () => 150 * 1024 * 1024,
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
        await tester.pump();
        final fpsCenter = tester.getCenter(
          find.byKey(const ValueKey('fterm-perf-hud-fps')),
        );
        await tester.tapAt(fpsCenter);
        await tester.pump();
        expect(underlyingTaps, equals(1));
        expect(env.workspace.isRecordingTrace, isFalse);

        // Tapping REC still toggles tracing without passing through.
        await tester.tap(
          find.byKey(const ValueKey('fterm-perf-hud-trace-toggle')),
        );
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));
        await tester.pump();
        expect(env.workspace.isRecordingTrace, isTrue);
        expect(underlyingTaps, equals(1));
        await tester.runAsync(env.workspace.stopTraceRecording);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );

    testWidgets(
      'displays active GPU adapter name, VRAM, restart hint, and FPS cap status reactively',
      (tester) async {
        final env = _buildWorkspace();
        addTearDown(env.workspace.dispose);
        await env.workspace.openLocalShellTab();

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: FtermPerfHud(
                workspace: env.workspace,
                sampleRssBytes: () => null,
              ),
            ),
          ),
        );
        await tester.pump();

        Text readGpuInfo() => tester.widget<Text>(
          find.byKey(const ValueKey('fterm-perf-hud-gpu-info')),
        );

        expect(readGpuInfo().data, equals('uncapped'));

        env.workspace.setActiveGpuAdapterInfo(
          name: 'NVIDIA GeForce RTX 5080 Laptop GPU',
          dedicatedVramMb: 16003,
        );
        await tester.pump();
        expect(
          readGpuInfo().data,
          equals('NVIDIA GeForce RTX 5080 Laptop GPU (16 GB) • uncapped'),
        );

        env.workspace.setMaxShaderFps(120);
        await tester.pump();
        expect(
          readGpuInfo().data,
          equals('NVIDIA GeForce RTX 5080 Laptop GPU (16 GB) • cap 120 FPS'),
        );

        env.workspace.setGpuDriverPreference(GpuDriverPreference.powerSaving);
        await tester.pump();
        expect(readGpuInfo().data, contains('restart pending'));

        // Verify fterm/window getGraphicsAdapterInfo populates activeGpuAdapterName.
        const channel = MethodChannel('fterm/window');
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          (call) async {
            if (call.method == 'getGraphicsAdapterInfo') {
              return <String, Object?>{
                'description': 'Intel(R) Graphics',
                'dedicatedVideoMemoryMB': 128,
              };
            }
            return null;
          },
        );
        addTearDown(
          () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            channel,
            null,
          ),
        );

        final env2 = _buildWorkspace();
        addTearDown(env2.workspace.dispose);
        await tester.pumpWidget(
          MaterialApp(
            home: FtermShellScaffold(
              workspace: env2.workspace,
              onOpenUrl: (_) {},
              platformOverride: TargetPlatform.windows,
              isWebOverride: false,
            ),
          ),
        );
        await tester.pump();
        expect(
          env2.workspace.activeGpuAdapterName,
          equals('Intel(R) Graphics'),
        );
        expect(env2.workspace.activeGpuVramMb, equals(128));
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );

    testWidgets(
      'Settings Graphics Driver and Max Shader FPS controls persist choices and show restart/cap hints',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(960, 800));
        addTearDown(() => tester.binding.setSurfaceSize(null));

        final env = _buildWorkspace();
        await tester.runAsync(env.workspace.openLocalShellTab);
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData(platform: TargetPlatform.windows),
            home: FtermShellScaffold(
              workspace: env.workspace,
              onOpenUrl: (_) {},
              platformOverride: TargetPlatform.windows,
              isWebOverride: false,
            ),
          ),
        );
        env.workspace.openSettingsOverlay(initialSection: .system);
        await tester.pump();

        expect(
          find.byKey(const ValueKey('settings-gpu-driver-restart-hint')),
          findsNothing,
        );

        final powerSavingChip = find.byKey(
          const ValueKey('settings-gpu-driver-powerSaving'),
        );
        await tester.ensureVisible(powerSavingChip);
        await tester.tap(powerSavingChip);
        await tester.pump();

        expect(
          env.workspace.gpuDriverPreference,
          equals(GpuDriverPreference.powerSaving),
        );
        expect(env.workspace.gpuDriverRestartRequired, isTrue);
        expect(
          find.byKey(const ValueKey('settings-gpu-driver-restart-hint')),
          findsOneWidget,
        );

        // One-click 60 FPS cap recommendation sets maxShaderFps immediately.
        final suggest60 = find.byKey(
          const ValueKey('settings-gpu-suggest-60fps'),
        );
        await tester.ensureVisible(suggest60);
        await tester.tap(suggest60);
        await tester.pump();
        expect(env.workspace.maxShaderFps, equals(60));

        // Explicit 120 FPS control on Shaders tab updates maxShaderFps and propagates to mounted TerminalSurface.
        await tester.tap(find.byKey(const ValueKey('settings-tab-shaders')));
        await tester.pump();
        final fps120Chip = find.byKey(
          const ValueKey('settings-max-shader-fps-120'),
        );
        await tester.ensureVisible(fps120Chip);
        await tester.tap(fps120Chip);
        await tester.pump();
        expect(env.workspace.maxShaderFps, equals(120));
        final surface = tester.widget<TerminalSurface>(
          find.byType(TerminalSurface).first,
        );
        expect(surface.maxAmbientFps, equals(120.0));

        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(env.workspace.dispose);
      },
    );

    test('startup --trace-out/--trace-seconds/--trace-exit triggers timed export and exit seam', () async {
      final exited = Completer<void>();
      final recorder = FtermTraceRecorder(
        sampleRssBytes: () => 100 * 1024 * 1024,
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
      final env = _buildWorkspace(
        traceRecorder: recorder,
        launchConfig: CastLaunchConfig(
          traceOutPath: '/tmp/startup_trace',
          traceDuration: const Duration(milliseconds: 25),
          traceExitOnComplete: true,
        ),
        onRequestExit: () async {
          if (!exited.isCompleted) exited.complete();
        },
      );
      addTearDown(() async {
        recorder.dispose();
        await env.workspace.dispose();
      });

      await env.workspace.start();
      await exited.future.timeout(const Duration(seconds: 2));
      expect(env.workspace.lastTraceExport, isNotNull);
      expect(
        env.workspace.lastTraceExport!.summaryPath,
        equals('/tmp/startup_trace.summary.json'),
      );
    });

    testWidgets(
      'FtermPerfHud displays full saved trace path and tapping it opens its folder',
      (tester) async {
        final openedDirs = <String>[];
        final recorder = FtermTraceRecorder(
          sampleRssBytes: () => null,
          registerTimingsCallback: (_) {},
          unregisterTimingsCallback: (_) {},
          exporter:
              ({
                required basePath,
                required traceJson,
                required summaryJson,
                required eventCount,
              }) async => TraceExportResult(
                tracePath: '/tmp/fterm_traces/run1.trace.json',
                summaryPath: '/tmp/fterm_traces/run1.summary.json',
                eventCount: eventCount,
              ),
        );
        final env = _buildWorkspace(
          traceRecorder: recorder,
          openDirectoryHandler: (dir) async => openedDirs.add(dir),
        );
        addTearDown(() async {
          recorder.dispose();
          await env.workspace.dispose();
        });

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: FtermPerfHud(
                workspace: env.workspace,
                sampleRssBytes: () => null,
              ),
            ),
          ),
        );
        await tester.runAsync(() async {
          await env.workspace.startTraceRecording(
            outputBasePath: '/tmp/fterm_traces/run1',
          );
          await env.workspace.stopTraceRecording();
        });
        await tester.pump();

        final statusText = tester.widget<Text>(
          find.byKey(const ValueKey('fterm-perf-hud-trace-status')),
        );
        expect(
          statusText.data,
          equals('Saved /tmp/fterm_traces/run1.summary.json'),
        );

        await tester.tap(
          find.byKey(const ValueKey('fterm-perf-hud-trace-open')),
        );
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));
        await tester.pump();

        expect(openedDirs, equals(<String>['/tmp/fterm_traces']));
        expect(
          env.workspace.statusBanner,
          equals('Trace path copied: /tmp/fterm_traces/run1.summary.json'),
        );
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );

    testWidgets(
      'Settings GPU Restart Now confirms with active shells, flushes settings, and relaunches',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(960, 800));
        addTearDown(() => tester.binding.setSurfaceSize(null));

        List<String>? relaunchedArgs;
        var exitCalls = 0;
        final exited = Completer<void>();
        final env = _buildWorkspace(
          launchConfig: CastLaunchConfig(
            promptForConnection: true,
            relaunchArgs: const <String>['--server', 'wss://relay.example'],
          ),
          onRelaunchApp: (args) async {
            relaunchedArgs = args;
            return true;
          },
          onRequestExit: () async {
            exitCalls += 1;
            if (!exited.isCompleted) exited.complete();
          },
        );
        await env.workspace.openLocalShellTab();

        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData(platform: TargetPlatform.windows),
            home: FtermShellScaffold(
              workspace: env.workspace,
              onOpenUrl: (_) {},
              platformOverride: TargetPlatform.windows,
              isWebOverride: false,
            ),
          ),
        );
        env.workspace.openSettingsOverlay(initialSection: .system);
        await tester.pump();

        final highPerfChip = find.byKey(
          const ValueKey('settings-gpu-driver-highPerformance'),
        );
        await tester.ensureVisible(highPerfChip);
        await tester.tap(highPerfChip);
        await tester.pump();

        final restartBtn = find.byKey(
          const ValueKey('settings-gpu-driver-restart-now'),
        );
        expect(restartBtn, findsOneWidget);
        await tester.ensureVisible(restartBtn);
        await tester.tap(restartBtn);
        await tester.pump();

        // Active local shell triggers inline confirmation instead of immediate exit.
        expect(relaunchedArgs, isNull);
        expect(exitCalls, equals(0));
        expect(
          find.byKey(
            const ValueKey('settings-gpu-driver-restart-confirm-text'),
          ),
          findsOneWidget,
        );

        // Cancel dismisses confirmation cleanly.
        await tester.tap(
          find.byKey(const ValueKey('settings-gpu-driver-cancel-restart')),
        );
        await tester.pump();
        expect(restartBtn, findsOneWidget);

        // Confirm flushes settings, launches replacement app, and exits.
        await tester.tap(restartBtn);
        await tester.pump();
        final confirmBtn = find.byKey(
          const ValueKey('settings-gpu-driver-confirm-restart'),
        );
        await tester.ensureVisible(confirmBtn);
        await tester.pump();
        await tester.tap(confirmBtn);
        // Drain alternating Zone.root (StreamSubscription.cancel/close
        // Future._nullFuture) and FakeAsync microtasks during pane teardown
        // without advancing fake time past prepareForUpdateSwap's 2s timeout.
        for (var i = 0; i < 8 && !exited.isCompleted; i++) {
          await tester.runAsync(() => Future<void>.delayed(Duration.zero));
          await tester.pump();
        }

        expect(
          relaunchedArgs,
          equals(const <String>['--server', 'wss://relay.example']),
        );
        expect(exited.isCompleted, isTrue);
        expect(exitCalls, equals(1));
        expect(env.workspace.tabs, isEmpty);
        expect(env.workspace.panes, isEmpty);
        expect(
          loadStoredPreferences(env.storage).gpuDriverPreference,
          equals(GpuDriverPreference.highPerformance),
        );

        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(env.workspace.dispose);
      },
    );

    testWidgets(
      'Settings GPU Restart Now restarts immediately with no active shells and preserves tabs if relaunch fails',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(960, 800));
        addTearDown(() => tester.binding.setSurfaceSize(null));

        // 1. Zero active local shells -> restarts without confirmation.
        var relaunchCalls = 0;
        var exitCalls = 0;
        final idleEnv = _buildWorkspace(
          onRelaunchApp: (_) async {
            relaunchCalls += 1;
            return true;
          },
          onRequestExit: () async => exitCalls += 1,
        );
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData(platform: TargetPlatform.windows),
            home: FtermShellScaffold(
              workspace: idleEnv.workspace,
              onOpenUrl: (_) {},
              platformOverride: TargetPlatform.windows,
              isWebOverride: false,
            ),
          ),
        );
        idleEnv.workspace.openSettingsOverlay(initialSection: .system);
        await tester.pump();

        final chip = find.byKey(
          const ValueKey('settings-gpu-driver-powerSaving'),
        );
        await tester.ensureVisible(chip);
        await tester.tap(chip);
        await tester.pump();

        final restartBtn = find.byKey(
          const ValueKey('settings-gpu-driver-restart-now'),
        );
        await tester.ensureVisible(restartBtn);
        await tester.tap(restartBtn);
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));
        await tester.pump();

        expect(relaunchCalls, equals(1));
        expect(exitCalls, equals(1));
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(idleEnv.workspace.dispose);

        // 2. Failed relaunch preserves open tabs and skips exit.
        var failedExitCalls = 0;
        final failEnv = _buildWorkspace(
          onRelaunchApp: (_) async => false,
          onRequestExit: () async => failedExitCalls += 1,
        );
        addTearDown(failEnv.workspace.dispose);
        await tester.runAsync(failEnv.workspace.openLocalShellTab);
        expect(failEnv.workspace.tabs, hasLength(1));

        final restarted = await tester.runAsync(
          failEnv.workspace.restartApplication,
        );
        expect(restarted, isFalse);
        expect(failedExitCalls, equals(0));
        expect(failEnv.workspace.tabs, hasLength(1));
        expect(
          failEnv.workspace.statusBanner,
          contains('Unable to relaunch fterm automatically'),
        );
      },
    );
  });
}
