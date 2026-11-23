import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fterm/src/audio/fterm_audio_controller.dart';
import 'package:fterm/src/font_loader.dart';
import 'package:fterm/src/launch_config.dart';
import 'package:fterm/src/settings_storage.dart';
import 'package:fterm/src/shader_profile_store.dart';
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

  final Map<String, String> shaders = <String, String>{};
  final Map<String, Uint8List> wallpapers = <String, Uint8List>{};
  final StreamController<ShaderDirectoryChange> changes =
      StreamController<ShaderDirectoryChange>.broadcast();
  bool disposed = false;

  _FakeShaderProfileStore({this.shadersDirectoryPath = '/tmp/fterm/shaders'});

  @override
  Future<List<String>> listShaderFiles() async {
    final keys = shaders.keys.toList()..sort();
    return keys;
  }

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
    validateShaderSource(glslSource, pathOrKey: name);
    shaders[name] = glslSource;
  }

  @override
  Future<void> saveWallpaperBytes(String key, Uint8List bytes) async {
    validateWallpaperBytes(bytes, pathOrKey: key);
    wallpapers[key] = bytes;
  }

  @override
  Stream<ShaderDirectoryChange> watchShaderDirectory() => changes.stream;

  void emitWatchChange(List<String> paths) {
    if (!disposed && !changes.isClosed) {
      changes.add(ShaderDirectoryChange(paths: paths));
    }
  }

  @override
  void dispose() {
    disposed = true;
    unawaited(changes.close());
  }
}

final class _MockHandle implements CompiledShaderHandle {
  @override
  final String id;

  @override
  final bool usesPrevFrame;

  bool disposed = false;

  _MockHandle({required this.id, required this.usesPrevFrame});

  @override
  void dispose() {
    disposed = true;
  }
}

final class _MockGpuBackend implements TerminalShaderBackend {
  @override
  final ShaderBackendKind kind;

  int compileCalls = 0;
  int reloadCalls = 0;
  ShaderCompileException? nextCompileOrReloadError;
  bool disposed = false;

  _MockGpuBackend({this.kind = ShaderBackendKind.flutterGpu});

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
    compileCalls++;
    final error = nextCompileOrReloadError;
    if (error != null) {
      nextCompileOrReloadError = null;
      throw error;
    }
    return _MockHandle(id: id, usesPrevFrame: usesPrevFrame);
  }

  @override
  Future<void> reload(CompiledShaderHandle handle, String shadertoyGlsl) async {
    reloadCalls++;
    final error = nextCompileOrReloadError;
    if (error != null) {
      nextCompileOrReloadError = null;
      throw error;
    }
  }

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
  void dispose() {
    disposed = true;
  }
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

const String _validCustomGlsl = '''
void mainImage(out vec4 fragColor, in vec2 fragCoord) {
  vec2 uv = fragCoord / max(iResolution.xy, vec2(1.0));
  fragColor = texture(iChannel0, uv);
}
''';

const String _opaqueCustomGlsl = '''
void mainImage(out vec4 fragColor, in vec2 fragCoord) {
  vec2 uv = fragCoord / max(iResolution.xy, vec2(1.0));
  fragColor = vec4(uv, 0.5, 1.0);
}
''';

const String _dualStageCustomGlsl = '''
// @fterm-stage: both
void mainImage(out vec4 fragColor, in vec2 fragCoord) {
  vec2 uv = fragCoord / max(iResolution.xy, vec2(1.0));
  fragColor = texture(iChannel0, uv);
}
''';

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

({
  FtermWorkspaceController workspace,
  _MemorySettingsStorage storage,
  _FakeShaderProfileStore store,
  List<_MockGpuBackend> createdBackends,
  List<String> openedDirs,
})
_buildWorkspace({
  ShaderBackendKind defaultBackendKind = ShaderBackendKind.flutterGpu,
  String? shadersDir = '/tmp/fterm/shaders',
}) {
  final storage = _MemorySettingsStorage();
  final store = _FakeShaderProfileStore(shadersDirectoryPath: shadersDir);
  final createdBackends = <_MockGpuBackend>[];
  final openedDirs = <String>[];
  final shaderController = TerminalShaderController(
    backendFactory: (override) {
      if (override == ShaderBackendKind.disabled) {
        return const DisabledShaderBackend();
      }
      final fake = _MockGpuBackend(kind: defaultBackendKind);
      createdBackends.add(fake);
      return fake;
    },
  );
  final transport = WsClientTransport(
    serverUri: CastLaunchConfig.defaultServerUri,
    token: '',
  );
  final repository = CastClientRepository(transport: transport);
  final workspace = FtermWorkspaceController(
    launchConfig: CastLaunchConfig(promptForConnection: true),
    repository: repository,
    localHostDriver: _FakeDesktopLocalHostDriver(),
    audioController: FtermAudioController(),
    storage: storage,
    resizeDebounce: Duration.zero,
    shaderController: shaderController,
    shaderProfileStore: store,
    openDirectoryHandler: (dir) async => openedDirs.add(dir),
  );
  return (
    workspace: workspace,
    storage: storage,
    store: store,
    createdBackends: createdBackends,
    openedDirs: openedDirs,
  );
}

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    await loadCastFonts();
  });

  group('fterm Shaders & Background Settings UI and shortcuts', () {
    testWidgets(
      'selects preset & custom .glsl chains, adjusts uParams0 and backgroundOpacity, persists settings, and switches shaderBackendOverride badge',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(960, 720));
        addTearDown(() => tester.binding.setSurfaceSize(null));

        final env = _buildWorkspace();
        env.store.shaders['retro.glsl'] = _validCustomGlsl;
        final pngBytes = await tester.runAsync(_createValidPng);
        env.store.wallpapers['/tmp/wall.png'] = pngBytes!;

        await tester.runAsync(env.workspace.openLocalShellTab);
        await tester.runAsync(env.workspace.refreshCustomShaders);

        await tester.pumpWidget(
          MaterialApp(
            home: FtermShellScaffold(
              workspace: env.workspace,
              onOpenUrl: (_) {},
              platformOverride: TargetPlatform.linux,
              isWebOverride: false,
            ),
          ),
        );
        await tester.pump();
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));
        await tester.pump();

        // Open Settings overlay.
        env.workspace.setOverlay(FtermOverlay.settings);
        await tester.pump();

        // Active backend badge renders 'flutterGpu'.
        final badgeFinder = find.byKey(
          const ValueKey('settings-shader-backend-badge'),
        );
        await tester.ensureVisible(badgeFinder);
        expect(
          find.descendant(of: badgeFinder, matching: find.text('flutterGpu')),
          findsOneWidget,
        );

        // Adjust backgroundOpacity slider and verify persistence + TerminalSurface forwarding.
        final opacitySliderFinder = find.byKey(
          const ValueKey('settings-background-opacity-slider'),
        );
        await tester.ensureVisible(opacitySliderFinder);
        final slider = tester.widget<Slider>(opacitySliderFinder);
        slider.onChanged!(0.55);
        await tester.pump();
        expect(env.workspace.backgroundOpacity, closeTo(0.55, 0.001));

        env.workspace.flushPendingSettings();
        final persisted = loadStoredSettings(env.storage);
        expect(persisted.themeSettings.backgroundOpacity, closeTo(0.55, 0.001));
        final surface = tester.widget<TerminalSurface>(
          find.byType(TerminalSurface),
        );
        expect(surface.backgroundOpacity, closeTo(0.55, 0.001));

        // Apply wallpaper path then clear it.
        final wpEdit = find.byKey(const ValueKey('settings-wallpaper-edit'));
        await tester.ensureVisible(wpEdit);
        await tester.pump(const Duration(milliseconds: 200));
        await tester.tap(wpEdit);
        await tester.pump();
        final wpField = find.byKey(
          const ValueKey('settings-wallpaper-path-field'),
        );
        await tester.ensureVisible(wpField);
        await tester.pump(const Duration(milliseconds: 200));
        await tester.enterText(wpField, '/tmp/wall.png');
        await tester.pump(const Duration(milliseconds: 200));
        final wpApply = find.byKey(const ValueKey('settings-wallpaper-apply'));
        await tester.ensureVisible(wpApply);
        await tester.pump(const Duration(milliseconds: 200));
        await tester.tap(wpApply);
        await tester.runAsync(() async {
          for (var i = 0; i < 40; i++) {
            if (env.workspace.shaderController.wallpaperImage != null) break;
            await Future<void>.delayed(const Duration(milliseconds: 10));
          }
        });
        await tester.pump();
        expect(env.workspace.backgroundImagePath, equals('/tmp/wall.png'));
        expect(env.workspace.shaderController.wallpaperImage, isNotNull);

        final wpClear = find.byKey(const ValueKey('settings-wallpaper-clear'));
        await tester.ensureVisible(wpClear);
        await tester.pump(const Duration(milliseconds: 200));
        await tester.tap(wpClear);
        await tester.pump();
        expect(env.workspace.backgroundImagePath, isNull);
        expect(env.workspace.shaderController.wallpaperImage, isNull);

        // Select background preset wallpaper_wave & foreground preset crt_lottes.
        final bgChip = find.byKey(
          const ValueKey('settings-bg-shader-wallpaper_wave'),
        );
        await tester.ensureVisible(bgChip);
        await tester.pump(const Duration(milliseconds: 200));
        await tester.tap(bgChip);
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));
        await tester.pump();
        expect(env.workspace.backgroundShaderChain, contains('wallpaper_wave'));

        final fgChip = find.byKey(
          const ValueKey('settings-fg-shader-crt_lottes'),
        );
        await tester.ensureVisible(fgChip);
        await tester.pump(const Duration(milliseconds: 200));
        await tester.tap(fgChip);
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));
        await tester.pump();
        expect(env.workspace.foregroundShaderChain, contains('crt_lottes'));

        // Verify retro_phosphor chip is exposed in Foreground Shaders and toggles cleanly.
        final retroChip = find.byKey(
          const ValueKey('settings-fg-shader-retro_phosphor'),
        );
        expect(retroChip, findsOneWidget);
        await tester.ensureVisible(retroChip);
        await tester.pump(const Duration(milliseconds: 200));
        await tester.tap(retroChip);
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));
        await tester.pump();
        expect(env.workspace.foregroundShaderChain, contains('retro_phosphor'));
        // Untoggle retro_phosphor to preserve subsequent chain assertions.
        await tester.tap(retroChip);
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));
        await tester.pump();
        expect(
          env.workspace.foregroundShaderChain,
          isNot(contains('retro_phosphor')),
        );

        // Add custom .glsl files to both BG and FG via custom path input row.
        final customToggle = find.byKey(
          const ValueKey('settings-custom-shader-toggle'),
        );
        await tester.ensureVisible(customToggle);
        await tester.pump(const Duration(milliseconds: 200));
        await tester.tap(customToggle);
        await tester.pump();
        final customField = find.byKey(
          const ValueKey('settings-custom-shader-path-field'),
        );
        await tester.ensureVisible(customField);
        await tester.pump(const Duration(milliseconds: 200));
        await tester.enterText(customField, 'retro.glsl');
        await tester.pump(const Duration(milliseconds: 200));
        final addBgBtn = find.byKey(
          const ValueKey('settings-custom-shader-add-bg'),
        );
        await tester.ensureVisible(addBgBtn);
        await tester.pump(const Duration(milliseconds: 200));
        await tester.tap(addBgBtn);
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));
        await tester.pump();
        expect(env.workspace.backgroundShaderChain, contains('retro.glsl'));

        await tester.ensureVisible(customField);
        await tester.pump(const Duration(milliseconds: 200));
        await tester.enterText(customField, 'retro.glsl');
        await tester.pump(const Duration(milliseconds: 200));
        final addFgBtn = find.byKey(
          const ValueKey('settings-custom-shader-add-fg'),
        );
        await tester.ensureVisible(addFgBtn);
        await tester.pump(const Duration(milliseconds: 200));
        await tester.tap(addFgBtn);
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));
        await tester.pump();
        expect(
          env.workspace.foregroundShaderChain,
          equals(<String>['crt_lottes', 'retro.glsl']),
        );

        // Adjust uParams0.x slider for active pass.
        final paramSliderFinder = find.byKey(
          const ValueKey('settings-shader-param-0'),
        );
        await tester.ensureVisible(paramSliderFinder);
        await tester.pump(const Duration(milliseconds: 200));
        tester.widget<Slider>(paramSliderFinder).onChanged!(0.75);
        await tester.pump();
        expect(
          env.workspace.shaderParamsFor('foreground:crt_lottes')[0],
          closeTo(0.75, 0.001),
        );

        // Change ShaderAnimationMode to onActivity and verify persistence.
        final animChip = find.byKey(
          const ValueKey('settings-shader-anim-onActivity'),
        );
        await tester.ensureVisible(animChip);
        await tester.pump(const Duration(milliseconds: 200));
        await tester.tap(animChip);
        await tester.pump();
        expect(
          env.workspace.shaderAnimationMode,
          equals(ShaderAnimationMode.onActivity),
        );

        // Open Shaders Folder button invokes handler.
        final openFolderBtn = find.byKey(
          const ValueKey('settings-open-shaders-folder'),
        );
        await tester.ensureVisible(openFolderBtn);
        await tester.pump(const Duration(milliseconds: 200));
        await tester.tap(openFolderBtn);
        await tester.pump();
        expect(env.openedDirs, equals(<String>['/tmp/fterm/shaders']));

        // Switch shaderBackendOverride -> Disabled and verify badge + persistence.
        final disableChip = find.byKey(
          const ValueKey('settings-shader-backend-disabled'),
        );
        await tester.ensureVisible(disableChip);
        await tester.pump(const Duration(milliseconds: 200));
        await tester.tap(disableChip);
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));
        await tester.pump();
        expect(
          env.workspace.shaderBackendOverride,
          equals(ShaderBackendKind.disabled),
        );
        expect(
          find.descendant(of: badgeFinder, matching: find.text('disabled')),
          findsOneWidget,
        );

        env.workspace.flushPendingSettings();
        expect(
          loadStoredPreferences(env.storage).shaderBackendOverride,
          equals(ShaderBackendKind.disabled),
        );

        // Switch back to Auto -> restores flutterGpu badge.
        final autoChip = find.byKey(
          const ValueKey('settings-shader-backend-auto'),
        );
        await tester.ensureVisible(autoChip);
        await tester.pump(const Duration(milliseconds: 200));
        await tester.tap(autoChip);
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));
        await tester.pump();
        expect(env.workspace.shaderBackendOverride, isNull);
        expect(
          find.descendant(of: badgeFinder, matching: find.text('flutterGpu')),
          findsOneWidget,
        );

        await tester.runAsync(env.workspace.dispose);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );

    testWidgets(
      'Ctrl+Shift+F5 reloads shaders across all desktop platforms while Ctrl+Shift+, still opens Settings on Linux/Windows and Cmd+, on macOS',
      (tester) async {
        final env = _buildWorkspace();
        env.store.shaders['live.glsl'] = _validCustomGlsl;
        await env.workspace.setForegroundShaderChain(const <String>[
          'live.glsl',
        ]);
        final backend = env.createdBackends.single;
        expect(backend.compileCalls, equals(1));

        for (final platform in const <TargetPlatform>[
          TargetPlatform.linux,
          TargetPlatform.windows,
          TargetPlatform.macOS,
        ]) {
          final dispatcher = FtermShortcutDispatcher(
            workspace: env.workspace,
            platformOverride: platform,
            isWebOverride: false,
          );
          final reloadsBefore = backend.reloadCalls;
          final handled = dispatcher.handleHostShortcut(
            const KeyDownEvent(
              physicalKey: PhysicalKeyboardKey.f5,
              logicalKey: LogicalKeyboardKey.f5,
              timeStamp: Duration.zero,
            ),
            const <ev.Modifier>{ev.Modifier.control, ev.Modifier.shift},
          );
          expect(handled, isTrue, reason: 'Ctrl+Shift+F5 on $platform');
          await tester.runAsync(() => Future<void>.delayed(Duration.zero));
          expect(backend.reloadCalls, equals(reloadsBefore + 1));
        }

        // Ctrl+Shift+, STILL opens Settings on Linux & Windows.
        for (final platform in const <TargetPlatform>[
          TargetPlatform.linux,
          TargetPlatform.windows,
        ]) {
          env.workspace.dismissOverlay();
          final dispatcher = FtermShortcutDispatcher(
            workspace: env.workspace,
            platformOverride: platform,
            isWebOverride: false,
          );
          final opened = dispatcher.handleHostShortcut(
            const KeyDownEvent(
              physicalKey: PhysicalKeyboardKey.comma,
              logicalKey: LogicalKeyboardKey.comma,
              timeStamp: Duration.zero,
            ),
            const <ev.Modifier>{ev.Modifier.control, ev.Modifier.shift},
          );
          expect(opened, isTrue);
          expect(env.workspace.activeOverlay, equals(FtermOverlay.settings));
        }

        // Cmd+, STILL opens Settings on macOS.
        env.workspace.dismissOverlay();
        final macDispatcher = FtermShortcutDispatcher(
          workspace: env.workspace,
          platformOverride: TargetPlatform.macOS,
          isWebOverride: false,
        );
        expect(
          macDispatcher.handleHostShortcut(
            const KeyDownEvent(
              physicalKey: PhysicalKeyboardKey.comma,
              logicalKey: LogicalKeyboardKey.comma,
              timeStamp: Duration.zero,
            ),
            const <ev.Modifier>{ev.Modifier.meta},
          ),
          isTrue,
        );
        expect(env.workspace.activeOverlay, equals(FtermOverlay.settings));

        // Web ignores Ctrl+Shift+F5 desktop shortcut.
        final webDispatcher = FtermShortcutDispatcher(
          workspace: env.workspace,
          platformOverride: TargetPlatform.linux,
          isWebOverride: true,
        );
        expect(
          webDispatcher.handleHostShortcut(
            const KeyDownEvent(
              physicalKey: PhysicalKeyboardKey.f5,
              logicalKey: LogicalKeyboardKey.f5,
              timeStamp: Duration.zero,
            ),
            const <ev.Modifier>{ev.Modifier.control, ev.Modifier.shift},
          ),
          isFalse,
        );

        // File-watcher event from ShaderProfileStore triggers automatic reload.
        final beforeWatch = backend.reloadCalls;
        env.store.emitWatchChange(const <String>['live.glsl']);
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));
        expect(backend.reloadCalls, equals(beforeWatch + 1));

        await tester.runAsync(env.workspace.dispose);
      },
    );

    testWidgets(
      'renders inline compile error banner on shader compile failure, clears on recovery, and supports Web Upload .glsl flow',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(960, 720));
        addTearDown(() => tester.binding.setSurfaceSize(null));

        final env = _buildWorkspace(
          defaultBackendKind: ShaderBackendKind.webGl2,
          shadersDir: null,
        );
        env.store.shaders['broken.glsl'] = _validCustomGlsl;
        await env.workspace.setForegroundShaderChain(const <String>[
          'broken.glsl',
        ]);
        env.workspace.setOverlay(FtermOverlay.settings);

        await tester.pumpWidget(
          MaterialApp(
            home: FtermShellScaffold(
              workspace: env.workspace,
              onOpenUrl: (_) {},
              platformOverride: TargetPlatform.linux,
              isWebOverride: true,
            ),
          ),
        );
        await tester.pump();

        expect(
          find.byKey(const ValueKey('settings-shader-compile-error')),
          findsNothing,
        );

        // Break the custom shader and trigger reload -> banner appears.
        env.store.shaders['broken.glsl'] = 'not valid glsl without mainImage';
        final reloadBtn = find.byKey(const ValueKey('settings-reload-shaders'));
        await tester.ensureVisible(reloadBtn);
        await tester.tap(reloadBtn);
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));
        await tester.pump();

        final errorBanner = find.byKey(
          const ValueKey('settings-shader-compile-error'),
        );
        expect(errorBanner, findsOneWidget);
        expect(
          find.descendant(
            of: errorBanner,
            matching: find.textContaining('mainImage'),
          ),
          findsOneWidget,
        );
        expect(env.workspace.statusBanner, contains('Shader error'));

        // Fix the shader and reload -> error banner clears cleanly.
        env.store.shaders['broken.glsl'] = _validCustomGlsl;
        await tester.ensureVisible(reloadBtn);
        await tester.tap(reloadBtn);
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));
        await tester.pump();
        expect(errorBanner, findsNothing);
        expect(env.workspace.lastShaderCompileError, isNull);

        // Web mode shows Upload .glsl button and saves + activates custom snippet.
        final uploadBtn = find.byKey(const ValueKey('settings-upload-glsl'));
        await tester.ensureVisible(uploadBtn);
        await tester.tap(uploadBtn);
        await tester.pump();

        expect(
          find.byKey(const ValueKey('settings-web-glsl-form')),
          findsOneWidget,
        );
        await tester.enterText(
          find.byKey(const ValueKey('settings-web-glsl-name')),
          'web_fx.glsl',
        );
        await tester.enterText(
          find.byKey(const ValueKey('settings-web-glsl-source')),
          _validCustomGlsl,
        );
        await tester.ensureVisible(
          find.byKey(const ValueKey('settings-web-glsl-save')),
        );
        await tester.tap(find.byKey(const ValueKey('settings-web-glsl-save')));
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));
        await tester.pump();

        expect(env.store.shaders.containsKey('web_fx.glsl'), isTrue);
        expect(env.workspace.foregroundShaderChain, contains('web_fx.glsl'));

        // Also exercise uploadWallpaperBytes, error reporting, and reloadSettingsFromStorage.
        final png = await tester.runAsync(_createValidPng);
        await tester.runAsync(
          () => env.workspace.uploadWallpaperBytes('web_bg.png', png!),
        );
        expect(env.workspace.backgroundImagePath, equals('web_bg.png'));
        expect(env.workspace.shaderController.wallpaperImage, isNotNull);

        // Invalid wallpaper bytes record lastShaderAssetError and render banner.
        await env.workspace.uploadWallpaperBytes(
          'bad.png',
          Uint8List.fromList(const <int>[1, 2, 3, 4]),
        );
        await tester.pump();
        expect(env.workspace.lastShaderAssetError, isNotNull);
        expect(
          find.byKey(const ValueKey('settings-shader-compile-error')),
          findsOneWidget,
        );

        // Background custom shader upload + openShadersFolder when null + storage reload.
        await env.workspace.uploadCustomShader(
          'bg_custom.glsl',
          _validCustomGlsl,
          stage: TerminalShaderStage.background,
        );
        expect(env.workspace.backgroundShaderChain, contains('bg_custom.glsl'));
        expect(await env.workspace.openShadersFolder(), isFalse);
        env.workspace.setShaderParam('background:bg_custom.glsl', 1, 0.42);
        env.workspace.flushPendingSettings();
        expect(env.workspace.reloadSettingsFromStorage(), isTrue);
        expect(
          env.workspace.shaderParamsFor('background:bg_custom.glsl')[1],
          closeTo(0.42, 0.001),
        );

        await tester.runAsync(env.workspace.dispose);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );

    testWidgets(
      'warns on multiple/overwriting background shaders and lets users reorder or remove passes',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(960, 800));
        addTearDown(() => tester.binding.setSurfaceSize(null));

        final env = _buildWorkspace();
        env.store.shaders['smoke_and_ghosts.glsl'] = _validCustomGlsl;
        env.store.shaders['opaque_bg.glsl'] = _opaqueCustomGlsl;
        env.store.shaders['dual_stage.glsl'] = _dualStageCustomGlsl;
        await env.workspace.refreshCustomShaders();
        await env.workspace.setBackgroundShaderChain(const <String>[
          'smoke_and_ghosts.glsl',
          'wallpaper_wave',
        ]);
        env.workspace.setOverlay(FtermOverlay.settings);

        await tester.pumpWidget(
          MaterialApp(
            home: FtermShellScaffold(
              workspace: env.workspace,
              onOpenUrl: (_) {},
              platformOverride: TargetPlatform.macOS,
              isWebOverride: false,
            ),
          ),
        );
        await tester.pump();

        // 1. Role legend and base/chains chip icons appear immediately for
        // both built-in presets and pre-analyzed custom shaders.
        expect(
          find.byKey(const ValueKey('settings-shader-role-legend')),
          findsOneWidget,
        );
        expect(
          find.descendant(
            of: find.byKey(const ValueKey('settings-bg-shader-wallpaper_wave')),
            matching: find.byIcon(Icons.bolt),
          ),
          findsOneWidget,
        );
        expect(
          find.descendant(
            of: find.byKey(const ValueKey('settings-bg-shader-opaque_bg.glsl')),
            matching: find.byIcon(Icons.bolt),
          ),
          findsOneWidget,
        );
        expect(
          find.descendant(
            of: find.byKey(
              const ValueKey('settings-bg-shader-smoke_and_ghosts.glsl'),
            ),
            matching: find.byIcon(Icons.input),
          ),
          findsOneWidget,
        );
        expect(
          find.descendant(
            of: find.byKey(const ValueKey('settings-fg-shader-crt_lottes')),
            matching: find.byIcon(Icons.input),
          ),
          findsOneWidget,
        );

        // Stage hint badges (BG / FG / Any) appear on custom shader chips.
        expect(
          find.descendant(
            of: find.byKey(
              const ValueKey('settings-bg-shader-stage-hint-opaque_bg.glsl'),
            ),
            matching: find.text('BG'),
          ),
          findsOneWidget,
        );
        expect(
          find.descendant(
            of: find.byKey(
              const ValueKey(
                'settings-bg-shader-stage-hint-smoke_and_ghosts.glsl',
              ),
            ),
            matching: find.text('FG'),
          ),
          findsOneWidget,
        );
        expect(
          find.descendant(
            of: find.byKey(
              const ValueKey('settings-bg-shader-stage-hint-dual_stage.glsl'),
            ),
            matching: find.text('Any'),
          ),
          findsOneWidget,
        );

        // 2. wallpaper_wave runs second and does not sample iChannel0 ->
        // explicit overwrite warning + ordered pass list with role badges.
        final bgWarning = find.byKey(
          const ValueKey('settings-bg-shader-warning'),
        );
        expect(bgWarning, findsOneWidget);
        expect(
          find.descendant(
            of: bgWarning,
            matching: find.textContaining(
              'wallpaper_wave does not sample iChannel0 and overwrites '
              'smoke_and_ghosts.glsl',
            ),
          ),
          findsOneWidget,
        );
        final bgOrderList = find.byKey(
          const ValueKey('settings-bg-shader-order-list'),
        );
        expect(bgOrderList, findsOneWidget);
        expect(
          find.descendant(of: bgOrderList, matching: find.text('final')),
          findsOneWidget,
        );
        expect(
          find.descendant(
            of: find.byKey(const ValueKey('settings-bg-shader-role-0')),
            matching: find.text('chains'),
          ),
          findsOneWidget,
        );
        expect(
          find.descendant(
            of: find.byKey(const ValueKey('settings-bg-shader-role-1')),
            matching: find.text('base'),
          ),
          findsOneWidget,
        );

        // 2. Move smoke_and_ghosts.glsl down (higher priority / final pass) ->
        // chain becomes [wallpaper_wave, smoke_and_ghosts.glsl]. Since
        // smoke_and_ghosts.glsl samples iChannel0, warning becomes a general
        // multi-background ordering notice.
        final moveDown0 = find.byKey(
          const ValueKey('settings-bg-shader-move-down-0'),
        );
        await tester.ensureVisible(moveDown0);
        await tester.pump();
        await tester.tap(moveDown0);
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));
        await tester.pump();

        expect(
          env.workspace.backgroundShaderChain,
          equals(const <String>['wallpaper_wave', 'smoke_and_ghosts.glsl']),
        );
        expect(
          env.workspace.activeShaderConfig.backgroundPasses
              .map((p) => p.id)
              .toList(),
          equals(const <String>[
            'background:wallpaper_wave',
            'background:smoke_and_ghosts.glsl',
          ]),
        );
        expect(
          find.descendant(
            of: bgWarning,
            matching: find.textContaining('2 background shaders active'),
          ),
          findsOneWidget,
        );

        // Persisted preference reflects the new order.
        env.workspace.flushPendingSettings();
        expect(
          loadStoredPreferences(env.storage).backgroundShaderPaths,
          equals(const <String>['wallpaper_wave', 'smoke_and_ghosts.glsl']),
        );

        // 3. Remove wallpaper_wave via row remove button -> single active
        // background shader clears warning and hides the order list.
        final remove0 = find.byKey(
          const ValueKey('settings-bg-shader-remove-0'),
        );
        await tester.ensureVisible(remove0);
        await tester.pump();
        await tester.tap(remove0);
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));
        await tester.pump();

        expect(
          env.workspace.backgroundShaderChain,
          equals(const <String>['smoke_and_ghosts.glsl']),
        );
        expect(bgWarning, findsNothing);
        expect(bgOrderList, findsNothing);

        // 4. Foreground chain: two iChannel0-sampling presets show order list
        // with no warning, and move-up reorders priority cleanly.
        await env.workspace.setForegroundShaderChain(const <String>[
          'cursor_glow',
          'crt_lottes',
        ]);
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));
        await tester.pump();

        expect(
          find.byKey(const ValueKey('settings-fg-shader-warning')),
          findsNothing,
        );
        expect(
          find.byKey(const ValueKey('settings-fg-shader-order-list')),
          findsOneWidget,
        );

        final fgMoveUp1 = find.byKey(
          const ValueKey('settings-fg-shader-move-up-1'),
        );
        await tester.ensureVisible(fgMoveUp1);
        await tester.pump();
        await tester.tap(fgMoveUp1);
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));
        await tester.pump();

        expect(
          env.workspace.foregroundShaderChain,
          equals(const <String>['crt_lottes', 'cursor_glow']),
        );

        // Adding a non-iChannel0 shader at the end of foreground chain raises
        // an explicit overwrite warning naming the hidden passes.
        await env.workspace.setForegroundShaderChain(const <String>[
          'crt_lottes',
          'opaque_bg.glsl',
        ]);
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));
        await tester.pump();

        final fgWarning = find.byKey(
          const ValueKey('settings-fg-shader-warning'),
        );
        expect(fgWarning, findsOneWidget);
        expect(
          find.descendant(
            of: fgWarning,
            matching: find.textContaining(
              'opaque_bg.glsl does not sample iChannel0 and overwrites '
              'crt_lottes',
            ),
          ),
          findsOneWidget,
        );

        // Single-pass base shader in Foreground warns that it will cover
        // terminal text and recommends moving it to Background Shaders.
        await env.workspace.setForegroundShaderChain(const <String>[
          'opaque_bg.glsl',
        ]);
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));
        await tester.pump();
        expect(
          find.descendant(
            of: fgWarning,
            matching: find.textContaining(
              'opaque_bg.glsl does not sample iChannel0 and will cover '
              'terminal text',
            ),
          ),
          findsOneWidget,
        );

        // Out-of-bounds / no-op move calls leave chains unchanged.
        await env.workspace.moveBackgroundShader(-1, 0);
        await env.workspace.moveForegroundShader(0, 99);
        await env.workspace.moveForegroundShader(1, 1);
        expect(
          env.workspace.foregroundShaderChain,
          equals(const <String>['opaque_bg.glsl']),
        );

        await tester.runAsync(env.workspace.dispose);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );

    testWidgets(
      'Web Upload .glsl auto-detects BG vs FG stage from pasted GLSL and allows manual stage override',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(960, 800));
        addTearDown(() => tester.binding.setSurfaceSize(null));

        final env = _buildWorkspace(
          defaultBackendKind: ShaderBackendKind.webGl2,
          shadersDir: null,
        );
        env.workspace.setOverlay(FtermOverlay.settings);

        await tester.pumpWidget(
          MaterialApp(
            home: FtermShellScaffold(
              workspace: env.workspace,
              onOpenUrl: (_) {},
              platformOverride: TargetPlatform.linux,
              isWebOverride: true,
            ),
          ),
        );
        await tester.pump();

        final uploadBtn = find.byKey(const ValueKey('settings-upload-glsl'));
        await tester.ensureVisible(uploadBtn);
        await tester.tap(uploadBtn);
        await tester.pump();

        // Pasting an opaque generator auto-detects BG and activates in Background.
        await tester.enterText(
          find.byKey(const ValueKey('settings-web-glsl-name')),
          'aurora.glsl',
        );
        await tester.enterText(
          find.byKey(const ValueKey('settings-web-glsl-source')),
          _opaqueCustomGlsl,
        );
        await tester.pump();

        expect(
          tester
              .widget<Text>(
                find.byKey(const ValueKey('settings-web-glsl-detected-stage')),
              )
              .data,
          equals('Detected: BG'),
        );
        final saveBtn = find.byKey(const ValueKey('settings-web-glsl-save'));
        await tester.ensureVisible(saveBtn);
        await tester.tap(saveBtn);
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));
        await tester.pump();

        expect(env.workspace.backgroundShaderChain, contains('aurora.glsl'));
        expect(
          env.workspace.foregroundShaderChain,
          isNot(contains('aurora.glsl')),
        );

        // Re-open form, paste FG shader, and manually override to Background.
        await tester.ensureVisible(uploadBtn);
        await tester.tap(uploadBtn);
        await tester.pump();
        await tester.enterText(
          find.byKey(const ValueKey('settings-web-glsl-name')),
          'smoke.glsl',
        );
        await tester.enterText(
          find.byKey(const ValueKey('settings-web-glsl-source')),
          _validCustomGlsl,
        );
        await tester.pump();
        expect(
          tester
              .widget<Text>(
                find.byKey(const ValueKey('settings-web-glsl-detected-stage')),
              )
              .data,
          equals('Detected: FG'),
        );
        final bgStageChip = find.byKey(
          const ValueKey('settings-web-glsl-stage-bg'),
        );
        await tester.ensureVisible(bgStageChip);
        await tester.tap(bgStageChip);
        await tester.pump();
        await tester.ensureVisible(saveBtn);
        await tester.tap(saveBtn);
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));
        await tester.pump();

        expect(env.workspace.backgroundShaderChain, contains('smoke.glsl'));

        await tester.runAsync(env.workspace.dispose);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  });
}
