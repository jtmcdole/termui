import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fterm/src/audio/fterm_audio_controller.dart';
import 'package:fterm/src/font_loader.dart';
import 'package:fterm/src/launch_config.dart';
import 'package:fterm/src/settings_storage.dart';
import 'package:fterm/src/shader_editor/shader_editor_controller.dart';
import 'package:fterm/src/shader_editor/shader_editor_view.dart';
import 'package:fterm/src/shader_profile_store.dart';
import 'package:fterm/src/shader_profile_store_io.dart'
    show IoShaderProfileStore;
import 'package:fterm/src/ui/fterm_shell_scaffold.dart';
import 'package:fterm/src/workspace/fterm_workspace_controller.dart';
import 'package:fterm/src/workspace/local_host_driver.dart';
import 'package:fterm/src/workspace/split_tree_model.dart';
import 'package:material_ui/material_ui.dart';
import 'package:termui/termui.dart' as tui;
import 'package:termui_cast_client_core/termui_cast_client_core.dart';
import 'package:termui_cast_protocol/termui_cast_protocol.dart';
import 'package:termui_flutter/termui_flutter.dart';
import 'package:termui_pty/termui_pty.dart';

const String _validBgGlsl = '''
// @fterm-stage: bg
void mainImage(out vec4 fragColor, in vec2 fragCoord) {
  vec2 uv = fragCoord / max(iResolution.xy, vec2(1.0));
  fragColor = vec4(uv, 0.4, 1.0);
}
''';

const String _validFgGlsl = '''
// @fterm-stage: fg
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
  void setItem(String key, String value) {
    data[key] = value;
  }
}

final class _FakeShaderProfileStore implements ShaderProfileStore {
  @override
  String? get shadersDirectoryPath => '/tmp/fterm/shaders';

  final Map<String, String> shaders = <String, String>{};
  final StreamController<ShaderDirectoryChange> _changes =
      StreamController<ShaderDirectoryChange>.broadcast();

  @override
  Future<List<String>> listShaderFiles() async {
    final keys = shaders.keys.toList()..sort();
    return keys;
  }

  @override
  Future<String> loadShaderSource(String pathOrKey) async {
    final src = shaders[pathOrKey];
    if (src == null) {
      throw ShaderAssetException('Shader not found.', pathOrKey: pathOrKey);
    }
    return src;
  }

  @override
  Future<void> saveShaderSource(String name, String glslSource) async {
    validateShaderSource(glslSource, pathOrKey: name);
    shaders[name] = glslSource;
  }

  @override
  Future<Uint8List> loadWallpaperBytes(String pathOrKey) async => Uint8List(0);

  @override
  Future<void> saveWallpaperBytes(String key, Uint8List bytes) async {}

  @override
  Stream<ShaderDirectoryChange> watchShaderDirectory() => _changes.stream;

  @override
  void dispose() {
    unawaited(_changes.close());
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

final class _ValidatingMockGpuBackend implements TerminalShaderBackend {
  int compileCalls = 0;
  int reloadCalls = 0;
  Completer<void>? compileGate;

  @override
  ShaderBackendKind get kind => ShaderBackendKind.flutterGpu;

  @override
  bool get supportsCustomGlsl => true;

  @override
  bool get supportsSyncBackground => true;

  void _validateGlsl(String id, String source) {
    final lines = source.split('\n');
    for (var i = 0; i < lines.length; i++) {
      final col = lines[i].indexOf('badSymbol');
      if (col >= 0) {
        throw ShaderCompileException(
          shaderId: id,
          message: "undeclared identifier 'badSymbol'",
          lineNumber: i + 1,
          diagnostics: <ShaderDiagnostic>[
            ShaderDiagnostic(
              severity: ShaderDiagnosticSeverity.error,
              origin: ShaderDiagnosticOrigin.compiler,
              message: "undeclared identifier 'badSymbol'",
              line: i + 1,
              column: col + 1,
              length: 'badSymbol'.length,
            ),
          ],
        );
      }
    }
  }

  @override
  Future<CompiledShaderHandle> compile(
    String id,
    String shadertoyGlsl, {
    bool usesPrevFrame = false,
  }) async {
    compileCalls++;
    final gate = compileGate;
    if (gate != null && !gate.isCompleted) {
      await gate.future;
    }
    _validateGlsl(id, shadertoyGlsl);
    return _MockHandle(id: id, usesPrevFrame: usesPrevFrame);
  }

  @override
  Future<void> reload(CompiledShaderHandle handle, String shadertoyGlsl) async {
    reloadCalls++;
    _validateGlsl(handle.id, shadertoyGlsl);
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
      initialCols: 60,
      initialRows: 20,
    );
    final port = session.openPort(initialCols: 60, initialRows: 20);
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

({
  FtermWorkspaceController workspace,
  _FakeShaderProfileStore store,
  _ValidatingMockGpuBackend backend,
})
_createEnv({ShaderProfileStore? storeOverride}) {
  final storage = _MemorySettingsStorage();
  final store = _FakeShaderProfileStore();
  final backend = _ValidatingMockGpuBackend();
  final shaderController = TerminalShaderController(backend: backend);
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
    shaderProfileStore: storeOverride ?? store,
  );
  return (workspace: workspace, store: store, backend: backend);
}

Future<void> _sendLeaderChord(
  WidgetTester tester,
  LogicalKeyboardKey key,
) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
  await tester.sendKeyDownEvent(LogicalKeyboardKey.backslash);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.backslash);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
  await tester.pump();
  await tester.sendKeyDownEvent(key);
  await tester.sendKeyUpEvent(key);
  await tester.pump();
}

String _rowText(tui.Buffer buf, int y) =>
    [for (var x = 0; x < buf.width; x++) buf.getCharacter(x, y)]
        .join()
        .trimRight();

Future<void> _pumpApp(
  WidgetTester tester,
  FtermWorkspaceController workspace,
) async {
  await tester.pumpWidget(
    MaterialApp(
      home: FtermShellScaffold(
        workspace: workspace,
        onOpenUrl: (_) {},
        platformOverride: TargetPlatform.linux,
        isWebOverride: false,
      ),
    ),
  );
  await tester.pump();
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 50)),
  );
  await tester.pump();
  await tester.pump();
}

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    await loadCastFonts();
  });

  group('fterm Shader Editor Tab E2E Integration', () {
    testWidgets(
      'opens shader editor via Ctrl+\\ e without skull badge, receives immediate focus, renders syntax errors with curly squiggles, dirty highlight, and right-click Save + Solo/Blend/Off preview override',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(1024, 720));
        addTearDown(() => tester.binding.setSurfaceSize(null));

        final env = _createEnv();
        final ws = env.workspace;
        env.store.shaders['workspace_fg.glsl'] = _validFgGlsl;
        await tester.runAsync(ws.openLocalShellTab);
        await tester.runAsync(
          () => ws.setBackgroundShaderChain(const <String>['wallpaper_wave']),
        );
        await tester.runAsync(
          () =>
              ws.setForegroundShaderChain(const <String>['workspace_fg.glsl']),
        );

        await _pumpApp(tester, ws);

        // Open Shader Editor tab via Ctrl+\ e leader chord.
        await _sendLeaderChord(tester, LogicalKeyboardKey.keyE);
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));
        await tester.pump();
        await tester.pump();

        expect(ws.tabs, hasLength(2));
        final editorTab = ws.activeTab!;
        final editorPane = ws.focusedEditorPane!;
        expect(ws.focusedPaneId, equals(editorPane.paneId));
        expect(
          editorTab.isExited(ws.panes, editorPanes: ws.editorPanes),
          isFalse,
        );
        expect(find.text('💀'), findsNothing);
        expect(
          ws.buildDiagnosticSummary(isWeb: false).focusedPaneKind,
          equals('shader editor'),
        );

        // Editor TerminalSurface has mouseTracking: true and receives keyboard focus.
        final editorSurfaceFinder = find.descendant(
          of: find.byKey(ValueKey('pane-leaf-${editorPane.paneId}')),
          matching: find.byType(TerminalSurface),
        );
        expect(editorSurfaceFinder, findsOneWidget);
        final editorSurface = tester.widget<TerminalSurface>(
          editorSurfaceFinder,
        );
        expect(editorSurface.mouseTracking, isTrue);
        expect(editorSurface.focusNode?.hasFocus, isTrue);

        // Type GLSL with an intentional syntax error ('badSymbol').
        const brokenSource =
            '// @fterm-stage: bg\n'
            'void mainImage(out vec4 fragColor, in vec2 fragCoord) {\n'
            '  float x = badSymbol;\n'
            '  fragColor = vec4(x, 0.0, 0.0, 1.0);\n'
            '}';
        editorPane.controller.textController.text = brokenSource;
        await tester.runAsync(editorPane.controller.triggerCompileNow);
        await tester.pump();

        // Tab chip shows dirty '*' title and dirty highlight indicator dot.
        expect(ws.tabHasDirtyShaderEditor(editorTab), isTrue);
        expect(
          find.byKey(ValueKey('fterm-tab-dirty-dot-${editorTab.tabId}')),
          findsOneWidget,
        );
        expect(
          find.descendant(
            of: find.byKey(ValueKey('fterm-tab-${editorTab.tabId}')),
            matching: find.text('${editorPane.shaderName}*'),
          ),
          findsOneWidget,
        );

        // Verify red SGR 58 curly squiggle on 'badSymbol' and diagnostics footer.
        final buf = editorPane.readDisplayBuffer();
        final gutterW = ShaderEditorView.gutterWidthForLines(5);
        final errX =
            gutterW + 12; // '  float x = badSymbol;' -> col 12 (0-based)
        expect(buf.getCharacter(errX, 4), equals('b'));
        expect(buf.getUnderlineColor(errX, 4), isNot(equals(0)));
        expect(
          tui.Modifier.getUnderlineStyle(buf.getModifiers(errX, 4)),
          equals(tui.UnderlineStyle.curly),
        );
        final lastRow = _rowText(buf, buf.height - 1);
        expect(lastRow, contains('badSymbol'));

        // Fix the shader source.
        editorPane.controller.textController.text = _validBgGlsl;
        await tester.runAsync(editorPane.controller.triggerCompileNow);
        await tester.pump();
        expect(editorPane.controller.errorCount, equals(0));

        // Right-click the shader editor tab -> choose "Preview: Solo".
        final editorTabFinder = find.byKey(
          ValueKey('fterm-tab-${editorTab.tabId}'),
        );
        await tester.tap(editorTabFinder, buttons: kSecondaryMouseButton);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));

        expect(
          find.byKey(const ValueKey('tab-menu-save-shader')),
          findsOneWidget,
        );
        await tester.tap(find.byKey(const ValueKey('tab-menu-preview-solo')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        await tester.runAsync(editorPane.controller.triggerCompileNow);
        await tester.pump();

        // Solo overrides workspace shaders so only editor:<paneId> renders.
        final soloSurface = tester.widget<TerminalSurface>(editorSurfaceFinder);
        final soloConfig = soloSurface.shaderConfig!;
        expect(soloConfig.enabled, isTrue);
        expect(
          soloConfig.backgroundPasses.map((p) => p.id).toList(),
          equals(<String>['editor:${editorPane.paneId}']),
        );
        expect(soloConfig.foregroundPasses, isEmpty);
        expect(soloSurface.backgroundOpacity, closeTo(0.75, 1e-6));
        expect(
          ws.shaderController.handleForPass('editor:${editorPane.paneId}'),
          isNotNull,
        );

        // reloadShaders() preserves the active editor preview handle.
        await tester.runAsync(ws.reloadShaders);
        await tester.pump();
        expect(
          ws.shaderController.handleForPass('editor:${editorPane.paneId}'),
          isNotNull,
        );

        // Right-click -> choose "Preview: Blend with Workspace".
        await tester.tap(editorTabFinder, buttons: kSecondaryMouseButton);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        await tester.tap(find.byKey(const ValueKey('tab-menu-preview-blend')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));

        final blendSurface = tester.widget<TerminalSurface>(
          editorSurfaceFinder,
        );
        final blendConfig = blendSurface.shaderConfig!;
        expect(
          blendConfig.backgroundPasses.map((p) => p.id).toList(),
          equals(<String>[
            'background:wallpaper_wave',
            'editor:${editorPane.paneId}',
          ]),
        );
        expect(
          blendConfig.foregroundPasses.map((p) => p.id).toList(),
          equals(<String>['foreground:workspace_fg.glsl']),
        );

        // Right-click -> choose "Save Shader (Alt+S)" -> persists & clears dirty highlight.
        await tester.tap(editorTabFinder, buttons: kSecondaryMouseButton);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        await tester.tap(find.byKey(const ValueKey('tab-menu-save-shader')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));
        await tester.pump();

        expect(ws.tabHasDirtyShaderEditor(editorTab), isFalse);
        expect(env.store.shaders[editorPane.shaderName], equals(_validBgGlsl));
        expect(
          find.byKey(ValueKey('fterm-tab-dirty-dot-${editorTab.tabId}')),
          findsNothing,
        );

        // Right-click -> choose "Preview: Off" -> disables preview passes & prunes handle.
        await tester.tap(editorTabFinder, buttons: kSecondaryMouseButton);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        await tester.tap(find.byKey(const ValueKey('tab-menu-preview-off')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));
        await tester.pump();

        final offSurface = tester.widget<TerminalSurface>(editorSurfaceFinder);
        expect(offSurface.shaderConfig!.enabled, isFalse);
        expect(
          ws.shaderController.handleForPass('editor:${editorPane.paneId}'),
          isNull,
        );

        // Left rail dock also renders dirty indicator and right-click context menu.
        editorPane.controller.textController.text = '$_validBgGlsl\n// dirty';
        ws.setDockPosition(DockPosition.left);
        await tester.pump();
        expect(
          find.byKey(ValueKey('fterm-tab-dirty-dot-${editorTab.tabId}')),
          findsOneWidget,
        );
        await tester.tap(editorTabFinder, buttons: kSecondaryMouseButton);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        expect(
          find.byKey(const ValueKey('tab-menu-save-shader')),
          findsOneWidget,
        );
        await tester.tap(find.byKey(const ValueKey('tab-menu-rename')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        expect(ws.activeOverlay, equals(FtermOverlay.rename));
        ws.dismissOverlay();
        await tester.pump();

        // Regular tab right-click offers only Rename & Close (no shader menu items).
        final shellTab = ws.tabs.first;
        await tester.tap(
          find.byKey(ValueKey('fterm-tab-${shellTab.tabId}')),
          buttons: kSecondaryMouseButton,
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        expect(
          find.byKey(const ValueKey('tab-menu-save-shader')),
          findsNothing,
        );
        expect(find.byKey(const ValueKey('tab-menu-rename')), findsOneWidget);
        expect(find.byKey(const ValueKey('tab-menu-close')), findsOneWidget);
        await tester.tapAt(const Offset(500, 500));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));

        await tester.runAsync(ws.dispose);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );

    testWidgets(
      'supports mouse click routing, split + Ctrl+\\ z zoom, preview background color/opacity cycling, dirty close guard, and E-Stop recovery pill outside TerminalShaderHost',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(1024, 720));
        addTearDown(() => tester.binding.setSurfaceSize(null));

        final env = _createEnv();
        final ws = env.workspace;
        env.store.shaders['fx.glsl'] = _validBgGlsl;
        await tester.runAsync(ws.openLocalShellTab);
        await tester.runAsync(ws.refreshCustomShaders);
        await _pumpApp(tester, ws);

        // Open existing custom shader from workspace controller; second open reuses tab.
        final tabId1 = await tester.runAsync(
          () => ws.openShaderEditorTab(pathOrKey: 'fx.glsl'),
        );
        final tabId2 = await tester.runAsync(
          () => ws.openShaderEditorTab(pathOrKey: 'fx.glsl'),
        );
        expect(tabId1, isNotNull);
        expect(tabId2, equals(tabId1));
        await tester.pump();

        // Missing path surfaces error banner cleanly.
        final missing = await tester.runAsync(
          () => ws.openShaderEditorTab(pathOrKey: 'does_not_exist.glsl'),
        );
        expect(missing, isNull);
        expect(ws.lastShaderAssetError, isNotNull);

        final editorPane = ws.focusedEditorPane!;
        final surfaceFinder = find.descendant(
          of: find.byKey(ValueKey('pane-leaf-${editorPane.paneId}')),
          matching: find.byType(TerminalSurface),
        );

        // Cycle preview background color swatch & opacity -> TerminalSurface reflects changes.
        editorPane.controller.setPreviewMode(
          ShaderEditorPreviewMode.background,
        );
        editorPane.controller.adjustPreviewOpacity(-0.15);
        editorPane.controller.cycleBackgroundPreset(); // dark
        await tester.pump();
        final styledSurface = tester.widget<TerminalSurface>(surfaceFinder);
        expect(styledSurface.backgroundOpacity, closeTo(0.60, 1e-6));
        expect(
          styledSurface.backgroundColor,
          equals(Color(ShaderEditorBackgroundPreset.dark.colorOverride!.argb)),
        );

        // Click inside editor code body via mouseTracking: true -> moves cursor line.
        final surfaceRect = tester.getRect(surfaceFinder);
        await tester.tapAt(surfaceRect.topLeft + const Offset(80, 72));
        await tester.pump();
        expect(
          editorPane.controller.textController.value.selection.cursorLine,
          greaterThanOrEqualTo(1),
        );

        // Split a live shell beside the editor, then focus editor and zoom with Ctrl+\ z.
        await tester.runAsync(() => ws.splitFocusedPane(SplitAxis.horizontal));
        await tester.pump();
        expect(ws.activeSplitTree!.paneCount, equals(2));
        ws.focusPane(editorPane.paneId);
        await tester.pump();

        await _sendLeaderChord(tester, LogicalKeyboardKey.keyZ);
        await tester.pump();
        expect(ws.activeSplitTree!.isZoomed, isTrue);
        expect(
          find.byKey(ValueKey('pane-leaf-${editorPane.paneId}')),
          findsOneWidget,
        );
        expect(
          find.byKey(ValueKey('pane-pill-${editorPane.paneId}')),
          findsOneWidget,
        );

        // Unzoom back to split view.
        await _sendLeaderChord(tester, LogicalKeyboardKey.keyZ);
        await tester.pump();
        expect(ws.activeSplitTree!.isZoomed, isFalse);

        // Watchdog warmup ignores initial slow frames; sustained slow frames
        // after warmup escalate to global E-Stop and render the high-contrast
        // recovery pill OUTSIDE TerminalShaderHost.
        final draftId = 'editor:${editorPane.paneId}';
        editorPane.gpuFrameWatchdog.setActiveCustomShaders(<String>[
          draftId,
        ], source: 'host');
        final warmup = editorPane.gpuFrameWatchdog.warmupFramesRemainingFor(
          draftId,
        );
        expect(warmup, greaterThan(0));
        for (var i = 0; i < warmup; i++) {
          editorPane.gpuFrameWatchdog.recordShaderFrameDuration(
            draftId,
            const Duration(milliseconds: 55),
          );
        }
        expect(ws.shadersEmergencyStopped, isFalse);
        for (var i = 0; i < 3; i++) {
          editorPane.gpuFrameWatchdog.recordShaderFrameDuration(
            draftId,
            const Duration(milliseconds: 55),
          );
        }
        await tester.pump();

        expect(ws.shadersEmergencyStopped, isTrue);
        final pillFinder = find.byKey(
          const ValueKey('fterm-shader-estop-pill'),
        );
        expect(pillFinder, findsOneWidget);
        expect(
          find.ancestor(
            of: pillFinder,
            matching: find.byType(TerminalShaderHost),
          ),
          findsNothing,
        );

        // Clicking Resume clears editor watchdog quarantine and hides recovery pill.
        await tester.tap(
          find.byKey(const ValueKey('fterm-shader-estop-resume')),
        );
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));
        await tester.pump();

        expect(ws.shadersEmergencyStopped, isFalse);
        expect(editorPane.gpuFrameWatchdog.isQuarantined(draftId), isFalse);
        expect(pillFinder, findsNothing);

        // Trigger E-Stop via Ctrl+Shift+F6 hotkey and verify pill appears again.
        await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
        await tester.sendKeyDownEvent(LogicalKeyboardKey.f6);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.f6);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
        await tester.pump();
        expect(ws.shadersEmergencyStopped, isTrue);
        expect(pillFinder, findsOneWidget);

        await tester.tap(
          find.byKey(const ValueKey('fterm-shader-estop-resume')),
        );
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));
        await tester.pump();
        expect(ws.shadersEmergencyStopped, isFalse);

        // Dirty-buffer close guard blocks closing until confirmed.
        editorPane.controller.textController.text = '$_validBgGlsl\n// unsaved';
        await tester.pump();
        await tester.runAsync(() => ws.closeTab(ws.activeTabIndex));
        await tester.pump();
        expect(editorPane.controller.confirmingClose, isTrue);
        expect(ws.shaderEditorPaneById(editorPane.paneId), isNotNull);

        // Confirm discard via 'n' closes editor pane cleanly.
        editorPane.handleCommittedText('n');
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));
        await tester.pump();
        expect(ws.shaderEditorPaneById(editorPane.paneId), isNull);

        // Theme change & prepareForUpdateSwap dispose open editors cleanly.
        await tester.runAsync(
          () => ws.openShaderEditorTab(
            clonePreset: TerminalShaderPreset.cursorGlow,
          ),
        );
        ws.setPlatformBrightness(tui.TerminalBrightness.light);
        expect(ws.editorPanes, hasLength(1));
        await tester.runAsync(ws.prepareForUpdateSwap);
        expect(ws.editorPanes, isEmpty);

        await tester.runAsync(ws.dispose);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );

    test('surfaces runtime GPU pipeline link errors in the shader editor instead of staying OK', () async {
      final env = _createEnv();
      final ws = env.workspace;
      env.store.shaders['northern_nested_circles.glsl'] = _validBgGlsl;
      addTearDown(() async {
        await ws.dispose();
        env.store.dispose();
      });

      String rowText(int y) {
        final buf = ws.editorPanes.values.single.readDisplayBuffer();
        return [for (var x = 0; x < buf.width; x++) buf.getCharacter(x, y)]
            .join()
            .trimRight();
      }

      await ws.openShaderEditorTab(pathOrKey: 'northern_nested_circles.glsl');
      final editorPane = ws.editorPanes.values.single
        ..updateViewportSize(100, 20, 8, 16);
      editorPane.controller.setPreviewMode(ShaderEditorPreviewMode.background);
      await editorPane.controller.triggerCompileNow();

      expect(editorPane.controller.errorCount, equals(0));
      expect(rowText(1), contains('OK'));

      // Simulate lazy Impeller GLES pipeline link failure on first draw frame.
      ws.shaderController.reportRuntimeError(
        ShaderCompileException(
          shaderId: editorPane.previewPassId,
          message:
              'GPU pipeline failed to link or draw shader '
              '"${editorPane.previewPassId}": Exception: Failed to append draw',
        ),
      );

      expect(editorPane.controller.errorCount, equals(1));
      expect(
        editorPane.controller.diagnostics.single.message,
        contains('GPU pipeline failed to link or draw'),
      );
      final hintRibbon = rowText(1);
      expect(hintRibbon, contains('1 error'));
      expect(hintRibbon, isNot(contains('OK')));

      // Clearing runtime compile errors returns the editor to OK.
      ws.shaderController.clearLastCompileError();
      expect(editorPane.controller.errorCount, equals(0));
      expect(rowText(1), contains('OK'));
    });

    testWidgets(
      'renders an escape pill outside TerminalShaderHost when FG preview has no iChannel0',
      (tester) async {
        final env = _createEnv();
        final ws = env.workspace;
        env.store.shaders['northern_nested_circles.glsl'] = _validBgGlsl;
        addTearDown(() async {
          await tester.runAsync(ws.dispose);
          env.store.dispose();
        });

        await tester.pumpWidget(
          MaterialApp(
            home: FtermShellScaffold(
              workspace: ws,
              onOpenUrl: (_) {},
              platformOverride: TargetPlatform.linux,
              isWebOverride: false,
            ),
          ),
        );
        await tester.runAsync(
          () =>
              ws.openShaderEditorTab(pathOrKey: 'northern_nested_circles.glsl'),
        );
        await tester.pump();

        final editorPane = ws.editorPanes.values.single;
        final pillKey = ValueKey('editor-fg-opaque-pill-${editorPane.paneId}');
        expect(find.byKey(pillKey), findsNothing);

        // Switching a background-only shader (no iChannel0) to FG surfaces an
        // escape pill outside TerminalShaderHost so the user is never blinded.
        editorPane.controller.setPreviewMode(
          ShaderEditorPreviewMode.foreground,
        );
        await tester.pump();

        expect(find.byKey(pillKey), findsOneWidget);
        expect(
          find.ancestor(
            of: find.byKey(pillKey),
            matching: find.byType(TerminalShaderHost),
          ),
          findsNothing,
        );

        // Tapping Switch to BG recovers immediately and dismisses the pill.
        await tester.tap(
          find.byKey(ValueKey('editor-fg-switch-bg-${editorPane.paneId}')),
        );
        await tester.pump();
        expect(
          editorPane.controller.previewMode,
          equals(ShaderEditorPreviewMode.background),
        );
        expect(find.byKey(pillKey), findsNothing);

        // Switching back to FG and tapping Off disables preview and hides pill.
        editorPane.controller.setPreviewMode(
          ShaderEditorPreviewMode.foreground,
        );
        await tester.pump();
        expect(find.byKey(pillKey), findsOneWidget);
        await tester.tap(
          find.byKey(ValueKey('editor-fg-off-${editorPane.paneId}')),
        );
        await tester.pump();
        expect(
          editorPane.controller.previewMode,
          equals(ShaderEditorPreviewMode.off),
        );
        expect(find.byKey(pillKey), findsNothing);

        await tester.pumpWidget(const SizedBox.shrink());
      },
    );

    testWidgets(
      'supports Save Shader As... from tab context menu and updates tab title on save',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(1024, 720));
        addTearDown(() => tester.binding.setSurfaceSize(null));

        final env = _createEnv();
        final ws = env.workspace;
        await tester.runAsync(() => ws.openShaderEditorTab());
        await _pumpApp(tester, ws);

        final editorPane = ws.editorPanes.values.single;
        final tabId = ws.activeTab!.tabId;
        final tabFinder = find.byKey(ValueKey('fterm-tab-$tabId'));
        expect(tabFinder, findsOneWidget);

        // Right-click tab -> Save Shader As... -> opens inline Save As prompt.
        await tester.tap(tabFinder, buttons: kSecondaryMouseButton);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        await tester.tap(find.byKey(const ValueKey('tab-menu-save-shader-as')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));

        expect(editorPane.controller.promptingSaveAs, isTrue);

        // Name the new shader and confirm -> persists and renames tab title.
        editorPane.controller.clearSaveAsDraft();
        editorPane.controller.appendSaveAsText('my_new_effect');
        final saved = await editorPane.controller.confirmSaveAs();
        await tester.pump();

        expect(saved, isTrue);
        expect(editorPane.shaderName, equals('my_new_effect.glsl'));
        expect(env.store.shaders['my_new_effect.glsl'], isNotNull);
        expect(find.text('my_new_effect.glsl'), findsOneWidget);

        // M1: Re-opening via Desktop full path inside shadersDirectory focuses
        // the existing tab instead of opening a duplicate.
        final reopenedId = await ws.openShaderEditorTab(
          pathOrKey: '/tmp/fterm/shaders/my_new_effect.glsl',
        );
        expect(reopenedId, equals(tabId));
        expect(ws.editorPanes.length, equals(1));

        // H1: Editor TerminalSurface forwards metaKeyPolicy from preferences.
        ws.updatePreferences(
          ws.preferences.copyWith(metaKeyMode: FtermMetaKeyMode.passThrough),
        );
        await tester.pump();
        final editorSurface = tester.widget<TerminalSurface>(
          find.byType(TerminalSurface),
        );
        expect(
          editorSurface.metaKeyPolicy,
          equals(TerminalMetaKeyPolicy.passThroughUnhandled),
        );

        // M4: Opaque FG escape pill stays visible after a shim error while the
        // previously compiled opaque FG handle remains active.
        editorPane.controller.textController.text =
            'void mainImage(out vec4 fragColor, in vec2 fragCoord) {\n'
            '  fragColor = vec4(1.0, 0.0, 0.0, 1.0);\n'
            '}';
        editorPane.controller.setPreviewMode(
          ShaderEditorPreviewMode.foreground,
        );
        await editorPane.controller.triggerCompileNow();
        await tester.pump();
        final pillKey = ValueKey('editor-fg-opaque-pill-${editorPane.paneId}');
        expect(find.byKey(pillKey), findsOneWidget);

        editorPane.controller.textController.text =
            '#version 460\nvoid broken() {}';
        await editorPane.controller.triggerCompileNow();
        await tester.pump();
        expect(editorPane.controller.lastAnalysis, isNull);
        expect(find.byKey(pillKey), findsOneWidget);

        // M5: Emptying buffer and closing editor still prunes preview handle.
        final previewPassId = editorPane.previewPassId;
        expect(ws.shaderController.handleForPass(previewPassId), isNotNull);
        editorPane.controller.textController.text = '';
        editorPane.controller.markSaved();
        await ws.closePane(editorPane.paneId);
        await tester.pump();
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));
        expect(ws.shaderController.handleForPass(previewPassId), isNull);

        // M2 + L1: Concurrent openShaderEditorTab dedupes, and saving an
        // external absolute path outside shadersDirectory fails with banner.
        env.store.shaders['/opt/external/ext.glsl'] =
            'void mainImage(out vec4 fragColor, in vec2 fragCoord) {\n'
            '  fragColor = vec4(0.0);\n'
            '}';
        final opens = await Future.wait<String?>(<Future<String?>>[
          ws.openShaderEditorTab(pathOrKey: '/opt/external/ext.glsl'),
          ws.openShaderEditorTab(pathOrKey: '/opt/external/ext.glsl'),
        ]);
        expect(opens[0], equals(opens[1]));
        expect(ws.editorPanes.length, equals(1));
        final extSaved = await ws.editorPanes.values.single.controller.save();
        expect(extSaved, isFalse);
        expect(ws.statusBanner, contains('Save As'));

        await tester.runAsync(ws.dispose);
        env.store.dispose();
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  });

  group('PR #475 review regression coverage (workspace & shell)', () {
    test('H1: nested subdirectory and symlinked ancestor shaders require Save As without clobbering top-level files', () async {
      final dir = await Directory.systemTemp.createTemp('fterm_h1_');
      final outside = await Directory.systemTemp.createTemp('fterm_h1_out_');
      final ioStore = IoShaderProfileStore(dir);
      final env = _createEnv(storeOverride: ioStore);
      final ws = env.workspace;
      addTearDown(() async {
        await ws.dispose();
        ioStore.dispose();
        env.store.dispose();
        if (dir.existsSync()) dir.deleteSync(recursive: true);
        if (outside.existsSync()) outside.deleteSync(recursive: true);
      });

      final rootFile = File('${dir.path}/glow.glsl')
        ..writeAsStringSync('// ROOT\n$_validBgGlsl');
      final subFile = File('${dir.path}/sub/glow.glsl')
        ..createSync(recursive: true)
        ..writeAsStringSync('// SUB\n$_validBgGlsl');
      final outsideSub = File('${outside.path}/sub/secret.glsl')
        ..createSync(recursive: true)
        ..writeAsStringSync('// OUTSIDE\n$_validBgGlsl');
      final extLink = Link('${dir.path}/ext')..createSync(outside.path);

      // Nested subdirectory must be rejected as external and must NOT clobber root glow.glsl.
      await ws.openShaderEditorTab(pathOrKey: subFile.path);
      ws.focusedEditorPane!.controller.textController.text =
          '// EDITED_SUB\n$_validBgGlsl';
      expect(await ws.focusedEditorPane!.controller.save(), isFalse);
      expect(rootFile.readAsStringSync(), startsWith('// ROOT'));
      expect(ws.statusBanner, contains('Save As'));

      // Symlinked ancestor path must be rejected as external and must NOT write into root dir.
      final viaSymlink = '${extLink.path}/sub/secret.glsl';
      expect(File(viaSymlink).existsSync(), isTrue);
      await ws.openShaderEditorTab(pathOrKey: viaSymlink);
      ws.focusedEditorPane!.controller.textController.text =
          '// EDITED_EXT\n$_validBgGlsl';
      expect(await ws.focusedEditorPane!.controller.save(), isFalse);
      expect(File('${dir.path}/secret.glsl').existsSync(), isFalse);
      expect(outsideSub.readAsStringSync(), startsWith('// OUTSIDE'));

      // Direct child inside shadersDir still saves cleanly.
      await ws.openShaderEditorTab(pathOrKey: rootFile.path);
      ws.focusedEditorPane!.controller.textController.text =
          '// UPDATED_ROOT\n$_validBgGlsl';
      expect(await ws.focusedEditorPane!.controller.save(), isTrue);
      expect(rootFile.readAsStringSync(), startsWith('// UPDATED_ROOT'));
    });

    testWidgets(
      'H2: tab context menu resolves live tabId after tabs shift or close while menu is open',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(1024, 720));
        addTearDown(() => tester.binding.setSurfaceSize(null));

        final env = _createEnv();
        final ws = env.workspace;
        await tester.runAsync(ws.openLocalShellTab);
        final tab1Id = (await tester.runAsync(ws.openShaderEditorTab))!;
        final tab2Id = (await tester.runAsync(ws.openLocalShellTab))!;
        await _pumpApp(tester, ws);

        // Open context menu on tab 1, then close tab 0 so tab 1 shifts from index 1 -> 0.
        await tester.tap(
          find.byKey(ValueKey('fterm-tab-$tab1Id')),
          buttons: kSecondaryMouseButton,
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));

        await tester.runAsync(() => ws.closeTab(0, force: true));
        await tester.pump();

        // Clicking Close Tab must close tab 1 (leaving tab 2 intact), not tab 2.
        await tester.tap(find.byKey(const ValueKey('tab-menu-close')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));
        await tester.pump();
        expect(ws.tabs.map((t) => t.tabId).toList(), equals(<String>[tab2Id]));

        // Closing the menu's own tab while menu is open aborts safely without closing tab 2.
        final tab3Id = (await tester.runAsync(ws.openShaderEditorTab))!;
        await tester.pump();
        await tester.tap(
          find.byKey(ValueKey('fterm-tab-$tab3Id')),
          buttons: kSecondaryMouseButton,
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        await tester.runAsync(() => ws.closeTab(1, force: true));
        await tester.pump();
        await tester.tap(find.byKey(const ValueKey('tab-menu-close')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));
        await tester.pump();
        expect(ws.tabs.map((t) => t.tabId).toList(), equals(<String>[tab2Id]));

        await tester.runAsync(ws.dispose);
        env.store.dispose();
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );

    test('H4 + H5 + M6: workspace disposes editor resources, prunes handles on empty buffer and in-flight close, and releases handles in prepareForUpdateSwap', () async {
      final env = _createEnv();
      final ws = env.workspace;
      addTearDown(() async {
        await ws.dispose();
        env.store.dispose();
      });

      // H5a: Emptying buffer during in-flight compile and closing tab does not leak GPU handle.
      await ws.openShaderEditorTab();
      final editor1 = ws.focusedEditorPane!;
      final watchdog1 = editor1.gpuFrameWatchdog;
      env.backend.compileGate = Completer<void>();
      editor1.controller.setPreviewMode(ShaderEditorPreviewMode.background);
      final compile1 = editor1.controller.triggerCompileNow();
      await Future<void>.delayed(Duration.zero);
      editor1.controller.textController.text = '';
      await ws.closeTab(0, force: true);
      expect(watchdog1.isDisposed, isTrue);
      env.backend.compileGate!.complete();
      await compile1;
      expect(ws.shaderController.handleForPass(editor1.previewPassId), isNull);

      // H5b: Emptying an already-compiled open editor prunes its stale GPU handle.
      env.backend.compileGate = null;
      await ws.openShaderEditorTab();
      final editor2 = ws.focusedEditorPane!;
      editor2.controller.setPreviewMode(ShaderEditorPreviewMode.background);
      await editor2.controller.triggerCompileNow();
      expect(
        ws.shaderController.handleForPass(editor2.previewPassId),
        isNotNull,
      );
      editor2.controller.textController.text = '';
      await Future<void>.delayed(Duration.zero);
      expect(ws.shaderController.handleForPass(editor2.previewPassId), isNull);

      // M6: prepareForUpdateSwap releases compiled editor GPU handles and disposes watchdogs.
      editor2.controller.textController.text = _validBgGlsl;
      await editor2.controller.triggerCompileNow();
      expect(
        ws.shaderController.handleForPass(editor2.previewPassId),
        isNotNull,
      );
      final watchdog2 = editor2.gpuFrameWatchdog;
      await ws.prepareForUpdateSwap();
      expect(watchdog2.isDisposed, isTrue);
      expect(ws.shaderController.handleForPass(editor2.previewPassId), isNull);
    });

    test('M1: dedupes absolute and relative managed paths, never hijacks untitled drafts, and assigns unique names to concurrent preset clones', () async {
      final env = _createEnv();
      final ws = env.workspace;
      addTearDown(() async {
        await ws.dispose();
        env.store.dispose();
      });

      env.store.shaders['/tmp/fterm/shaders/glow.glsl'] = _validBgGlsl;
      env.store.shaders['glow.glsl'] = _validBgGlsl;
      final t1 = await ws.openShaderEditorTab(
        pathOrKey: '/tmp/fterm/shaders/glow.glsl',
      );
      final t2 = await ws.openShaderEditorTab(pathOrKey: 'glow.glsl');
      expect(t2, equals(t1));

      // External file sharing basename with an untitled draft opens a separate tab.
      final untitledTab = await ws.openShaderEditorTab();
      final untitledName = ws.focusedEditorPane!.shaderName;
      final externalPath = '/opt/external/$untitledName';
      env.store.shaders[externalPath] = _validBgGlsl;
      final extTab = await ws.openShaderEditorTab(pathOrKey: externalPath);
      expect(extTab, isNotNull);
      expect(extTab, isNot(equals(untitledTab)));

      // Concurrent preset clones receive distinct shader names.
      final clones = await Future.wait<String?>(<Future<String?>>[
        ws.openShaderEditorTab(
          clonePreset: TerminalShaderPreset.scanlineOverlay,
        ),
        ws.openShaderEditorTab(
          clonePreset: TerminalShaderPreset.scanlineOverlay,
        ),
      ]);
      expect(clones[0], isNotNull);
      expect(clones[1], isNotNull);
      expect(clones[0], isNot(equals(clones[1])));
      final cloneNames = ws.editorPanes.values
          .where((e) => e.shaderName.startsWith('scanline_overlay_custom'))
          .map((e) => e.shaderName)
          .toSet();
      expect(cloneNames, hasLength(2));
    });
  });
}
