import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fterm/src/audio/fterm_audio_controller.dart';
import 'package:fterm/src/font_loader.dart';
import 'package:fterm/src/launch_config.dart';
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

({
  FtermWorkspaceController workspace,
  _MemorySettingsStorage storage,
  _FakeShaderStore store,
})
_buildWorkspace() {
  final storage = _MemorySettingsStorage();
  final store = _FakeShaderStore();
  final transport = WsClientTransport(
    serverUri: CastLaunchConfig.defaultServerUri,
    token: '',
  );
  final repository = CastClientRepository(transport: transport);
  final shaderController = TerminalShaderController(
    backendFactory: (_) => const DisabledShaderBackend(),
  );
  final workspace = FtermWorkspaceController(
    launchConfig: CastLaunchConfig(promptForConnection: true),
    repository: repository,
    localHostDriver: _FakeDesktopLocalHostDriver(),
    audioController: FtermAudioController(),
    storage: storage,
    resizeDebounce: Duration.zero,
    shaderController: shaderController,
    shaderProfileStore: store,
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
        expect(dispatcher.handleHostShortcut(event, mods), isTrue);
        expect(env.workspace.showPerfHud, isTrue);
        expect(dispatcher.handleHostShortcut(event, mods), isTrue);
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
        await tester.runAsync(env.workspace.openLocalShellTab);

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

        // Open Settings and toggle Performance HUD switch on.
        env.workspace.setOverlay(FtermOverlay.settings);
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
  });
}
