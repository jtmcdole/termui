import 'dart:async';
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
_createEnv() {
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
    shaderProfileStore: store,
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

        // Watchdog quarantine on editor pane escalates to global E-Stop and renders
        // high-contrast recovery pill OUTSIDE TerminalShaderHost.
        final draftId = 'editor:${editorPane.paneId}';
        editorPane.gpuFrameWatchdog.setActiveCustomShaders(<String>[
          draftId,
        ], source: 'host');
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
  });
}
