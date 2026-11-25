import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:fterm/src/audio/fterm_audio_controller.dart';
import 'package:fterm/src/launch_config.dart';
import 'package:fterm/src/settings_storage.dart';
import 'package:fterm/src/shader_profile_store.dart';
import 'package:fterm/src/workspace/fterm_workspace_controller.dart';
import 'package:fterm/src/workspace/local_host_driver.dart';
import 'package:termui/termui.dart' as tui;
import 'package:termui_cast_client_core/termui_cast_client_core.dart';
import 'package:termui_cast_protocol/termui_cast_protocol.dart';
import 'package:termui_flutter/termui_flutter.dart';
import 'package:termui_pty/termui_pty.dart';

const String _validCustomGlsl = '''
void mainImage(out vec4 fragColor, in vec2 fragCoord) {
  vec2 uv = fragCoord / max(iResolution.xy, vec2(1.0));
  fragColor = texture(iChannel0, uv);
}
''';

final class _MemorySettingsStorage implements SettingsStorage {
  final Map<String, String> data = <String, String>{};

  @override
  String? getItem(String key) => data[key];

  @override
  void setItem(String key, String value) => data[key] = value;
}

final class _FakeShaderProfileStore implements ShaderProfileStore {
  final Map<String, String> shaders = <String, String>{
    'custom_bg.glsl': _validCustomGlsl,
    'custom_fg.glsl': _validCustomGlsl,
  };

  @override
  String? get shadersDirectoryPath => null;

  @override
  Future<List<String>> listShaderFiles() async => shaders.keys.toList()..sort();

  @override
  Future<String> loadShaderSource(String pathOrKey) async {
    final src = shaders[pathOrKey];
    if (src == null) {
      throw ShaderAssetException('Not found', pathOrKey: pathOrKey);
    }
    return src;
  }

  @override
  Future<void> saveShaderSource(String name, String glslSource) async {
    shaders[name] = glslSource;
  }

  @override
  Future<Uint8List> loadWallpaperBytes(String pathOrKey) async => Uint8List(0);

  @override
  Future<void> saveWallpaperBytes(String key, Uint8List bytes) async {}

  @override
  Stream<ShaderDirectoryChange> watchShaderDirectory() =>
      const Stream<ShaderDirectoryChange>.empty();

  @override
  void dispose() {}
}

final class _FakeHandle implements CompiledShaderHandle {
  @override
  final String id;

  @override
  final bool usesPrevFrame;

  bool disposed = false;

  _FakeHandle(this.id, {required this.usesPrevFrame});

  @override
  void dispose() => disposed = true;
}

final class _FakeGpuBackend implements TerminalShaderBackend {
  final List<String> compiledIds = <String>[];

  @override
  ShaderBackendKind get kind => ShaderBackendKind.flutterGpu;

  @override
  bool get supportsCustomGlsl => true;

  @override
  bool get supportsSyncBackground => true;

  @override
  Future<CompiledShaderHandle> compile(
    String id,
    String shadertoyGlsl, {
    bool usesPrevFrame = false,
  }) async {
    compiledIds.add(id);
    return _FakeHandle(id, usesPrevFrame: usesPrevFrame);
  }

  @override
  Future<void> reload(
    CompiledShaderHandle handle,
    String shadertoyGlsl,
  ) async {}

  @override
  ui.Image? renderBackgroundSync({
    required List<ShaderPassInvocation> passes,
    required ui.Size physicalSize,
    ui.Image? wallpaperImage,
    GpuFrameWatchdog? watchdog,
  }) => null;

  @override
  Future<ui.Image?> renderPassesAsync({
    required List<ShaderPassInvocation> passes,
    required ui.Size physicalSize,
    ui.Image? inputImage,
    ui.Image? wallpaperImage,
    GpuFrameWatchdog? watchdog,
  }) async => null;

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

({FtermWorkspaceController workspace, _FakeGpuBackend backend})
_createWorkspace() {
  final storage = _MemorySettingsStorage();
  final store = _FakeShaderProfileStore();
  final backend = _FakeGpuBackend();
  final shaderController = TerminalShaderController(backend: backend);
  final transport = WsClientTransport(
    serverUri: CastLaunchConfig.defaultServerUri,
    token: '',
  );
  final repository = CastClientRepository(transport: transport);
  final workspace = FtermWorkspaceController(
    launchConfig: CastLaunchConfig(
      serverUri: CastLaunchConfig.defaultServerUri,
      token: '',
    ),
    repository: repository,
    localHostDriver: _FakeLocalHostDriver(),
    audioController: FtermAudioController(),
    storage: storage,
    shaderController: shaderController,
    shaderProfileStore: store,
  );
  return (workspace: workspace, backend: backend);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('FtermWorkspaceController shader Emergency Stop', () {
    test('disables activeShaderConfig while preserving chains and opacity, then restores pruned handles on resume', () async {
      final env = _createWorkspace();
      final ws = env.workspace;
      addTearDown(ws.dispose);

      await ws.openLocalShellTab();
      await ws.setBackgroundShaderChain(const <String>['custom_bg.glsl']);
      await ws.setForegroundShaderChain(const <String>['custom_fg.glsl']);
      ws.setBackgroundOpacity(0.65);

      expect(ws.shadersEmergencyStopped, isFalse);
      expect(ws.shaderEmergencyStopReason, isNull);
      expect(ws.activeShaderConfig.enabled, isTrue);
      expect(
        ws.shaderController.handleForPass('background:custom_bg.glsl'),
        isNotNull,
      );
      expect(
        ws.shaderController.handleForPass('foreground:custom_fg.glsl'),
        isNotNull,
      );

      ws.triggerShaderEmergencyStop();
      expect(ws.shadersEmergencyStopped, isTrue);
      expect(ws.shaderEmergencyStopReason, isNull);
      expect(ws.activeShaderConfig.enabled, isFalse);
      expect(ws.backgroundShaderChain, equals(const ['custom_bg.glsl']));
      expect(ws.foregroundShaderChain, equals(const ['custom_fg.glsl']));
      expect(ws.backgroundOpacity, closeTo(0.65, 1e-6));
      expect(ws.statusBanner, contains('Shaders stopped'));

      // Calling trigger again without a new reason is a no-op.
      var notifyCount = 0;
      ws.chromeNotifier.addListener(() => notifyCount++);
      ws.triggerShaderEmergencyStop();
      expect(notifyCount, equals(0));

      // Simulate shader sync while stopped pruning compiled handles, plus a
      // pane watchdog quarantine.
      await ws.reloadShaders();
      expect(ws.activeShaderConfig.enabled, isFalse);
      expect(
        ws.shaderController.handleForPass('background:custom_bg.glsl'),
        isNull,
      );
      expect(
        ws.shaderController.handleForPass('foreground:custom_fg.glsl'),
        isNull,
      );

      final pane = ws.focusedPane!;
      pane.gpuFrameWatchdog.quarantineShader(
        'foreground:custom_fg.glsl',
        'slow frame',
      );
      expect(
        pane.gpuFrameWatchdog.isQuarantined('foreground:custom_fg.glsl'),
        isTrue,
      );

      await ws.resumeShadersFromEmergencyStop();
      expect(ws.shadersEmergencyStopped, isFalse);
      expect(ws.shaderEmergencyStopReason, isNull);
      expect(ws.statusBanner, isNull);
      expect(ws.activeShaderConfig.enabled, isTrue);
      expect(
        pane.gpuFrameWatchdog.isQuarantined('foreground:custom_fg.glsl'),
        isFalse,
      );
      expect(
        ws.shaderController.handleForPass('background:custom_bg.glsl'),
        isNotNull,
      );
      expect(
        ws.shaderController.handleForPass('foreground:custom_fg.glsl'),
        isNotNull,
      );
      expect(ws.backgroundShaderChain, equals(const ['custom_bg.glsl']));
      expect(ws.foregroundShaderChain, equals(const ['custom_fg.glsl']));
      expect(ws.backgroundOpacity, closeTo(0.65, 1e-6));

      // Resuming when not stopped is a clean no-op.
      await ws.resumeShadersFromEmergencyStop();
      expect(ws.shadersEmergencyStopped, isFalse);
    });

    test('escalates user and draft watchdog quarantines to E-Stop with reason while keeping CLI-only quarantines scoped', () async {
      final env = _createWorkspace();
      final ws = env.workspace;
      addTearDown(ws.dispose);

      await ws.openLocalShellTab();
      final pane = ws.focusedPane!;
      final watchdog = pane.gpuFrameWatchdog;

      // CLI shader quarantine stays scoped and does NOT trigger global E-Stop.
      watchdog.setActiveCustomShaders(const ['cli_only_fx'], source: 'cli');
      for (var i = 0; i < 3; i++) {
        watchdog.recordShaderFrameDuration(
          'cli_only_fx',
          const Duration(milliseconds: 50),
        );
      }
      expect(ws.shadersEmergencyStopped, isFalse);
      expect(ws.statusBanner, contains('Quarantined CLI shader'));

      // User foreground shader quarantine escalates to global E-Stop.
      await ws.setForegroundShaderChain(const <String>['custom_fg.glsl']);
      watchdog.setActiveCustomShaders(const [
        'foreground:custom_fg.glsl',
      ], source: 'host');
      for (var i = 0; i < 3; i++) {
        watchdog.recordShaderFrameDuration(
          'foreground:custom_fg.glsl',
          const Duration(milliseconds: 55),
        );
      }
      expect(ws.shadersEmergencyStopped, isTrue);
      expect(ws.activeShaderConfig.enabled, isFalse);
      expect(
        ws.shaderEmergencyStopReason,
        contains('foreground:custom_fg.glsl'),
      );
      expect(ws.statusBanner, contains('Shaders stopped:'));
      expect(ws.statusBanner, contains('foreground:custom_fg.glsl'));

      // Resume lifts quarantine and clears reason.
      await ws.resumeShadersFromEmergencyStop();
      expect(ws.shadersEmergencyStopped, isFalse);
      expect(ws.shaderEmergencyStopReason, isNull);
      expect(watchdog.isQuarantined('foreground:custom_fg.glsl'), isFalse);

      // Editor draft shader quarantine also escalates to E-Stop.
      final draftId = 'editor:${pane.paneId}';
      watchdog.setActiveCustomShaders(<String>[draftId], source: 'host');
      for (var i = 0; i < 3; i++) {
        watchdog.recordShaderFrameDuration(
          draftId,
          const Duration(milliseconds: 60),
        );
      }
      expect(ws.shadersEmergencyStopped, isTrue);
      expect(ws.shaderEmergencyStopReason, contains(draftId));
    });

    test(
      'toggleShaderEmergencyStop flips between stopped and resumed',
      () async {
        final env = _createWorkspace();
        final ws = env.workspace;
        addTearDown(ws.dispose);

        await ws.openLocalShellTab();
        await ws.setForegroundShaderChain(const <String>['custom_fg.glsl']);

        ws.toggleShaderEmergencyStop();
        expect(ws.shadersEmergencyStopped, isTrue);
        expect(ws.activeShaderConfig.enabled, isFalse);

        ws.toggleShaderEmergencyStop();
        expect(ws.shadersEmergencyStopped, isFalse);
        expect(ws.activeShaderConfig.enabled, isTrue);
        await Future<void>.delayed(Duration.zero);
        expect(
          ws.shaderController.handleForPass('foreground:custom_fg.glsl'),
          isNotNull,
        );
      },
    );
  });
}
