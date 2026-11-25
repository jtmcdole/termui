import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart' show RenderRepaintBoundary;
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:termui/perf/memory_sink.dart';
import 'package:termui/perf/tracer.dart';
import 'package:termui/ui/buffer.dart';
import 'package:termui/ui/color.dart' as tui;
import 'package:termui/ui/shader_region.dart';
import 'package:termui/ui/style.dart';
import 'package:termui/ui/terminal_palette.dart';
import 'package:termui/ui/widgets/core/geometry.dart' as tui_geo;
import 'package:termui_flutter/termui_flutter.dart';
// ignore: implementation_imports
import 'package:termui_flutter/src/rendering/painter.dart';
// ignore: implementation_imports
import 'package:termui_flutter/src/rendering/shader_backend_gpu.dart'
    show packAlignedUniformBatch;
// ignore: implementation_imports
import 'package:termui_flutter/src/terminal_surface.dart'
    show TerminalSurfaceState;

final class _FakeShaderHandle implements CompiledShaderHandle {
  @override
  final String id;

  @override
  bool usesPrevFrame;

  String source;
  int reloadCount = 0;
  bool disposed = false;

  _FakeShaderHandle({
    required this.id,
    required this.usesPrevFrame,
    required this.source,
  });

  @override
  void dispose() {
    disposed = true;
  }
}

class _FakeShaderBackend implements TerminalShaderBackend {
  @override
  final ShaderBackendKind kind;

  @override
  bool get supportsCustomGlsl => true;

  @override
  bool supportsSyncBackground;

  final List<_FakeShaderHandle> handles = <_FakeShaderHandle>[];
  final List<List<ShaderPassInvocation>> syncBackgroundCalls =
      <List<ShaderPassInvocation>>[];
  final List<List<ShaderPassInvocation>> asyncPassCalls =
      <List<ShaderPassInvocation>>[];
  final List<ui.Image?> asyncInputImages = <ui.Image?>[];
  final List<ui.Image?> asyncWallpapers = <ui.Image?>[];
  final List<Completer<ui.Image?>> pendingAsyncCompleters =
      <Completer<ui.Image?>>[];

  bool holdAsyncRender = false;
  bool returnNullFromSyncBackground = false;
  ShaderCompileException? nextCompileError;
  ShaderCompileException? nextReloadError;
  int compileCount = 0;
  int reloadCount = 0;
  bool disposed = false;

  ui.Image? nextSyncImage;
  Color asyncOutputColor = const Color(0xFF44AA88);
  Object? nextSyncRenderError;
  Object? nextAsyncRenderError;

  _FakeShaderBackend({
    this.kind = ShaderBackendKind.flutterGpu,
    this.supportsSyncBackground = true,
  });

  @override
  Future<CompiledShaderHandle> compile(
    String id,
    String shadertoyGlsl, {
    bool usesPrevFrame = false,
  }) async {
    compileCount++;
    final error = nextCompileError;
    if (error != null) {
      nextCompileError = null;
      throw error;
    }
    final handle = _FakeShaderHandle(
      id: id,
      usesPrevFrame: usesPrevFrame,
      source: shadertoyGlsl,
    );
    handles.add(handle);
    return handle;
  }

  @override
  Future<void> reload(CompiledShaderHandle handle, String shadertoyGlsl) async {
    reloadCount++;
    final error = nextReloadError;
    if (error != null) {
      nextReloadError = null;
      throw error;
    }
    final fake = handle as _FakeShaderHandle;
    fake.source = shadertoyGlsl;
    fake.reloadCount++;
  }

  @override
  ui.Image? renderBackgroundSync({
    required List<ShaderPassInvocation> passes,
    required ui.Size physicalSize,
    ui.Image? wallpaperImage,
    GpuFrameWatchdog? watchdog,
  }) {
    syncBackgroundCalls.add(List<ShaderPassInvocation>.of(passes));
    final err = nextSyncRenderError;
    if (err != null) {
      nextSyncRenderError = null;
      throw err;
    }
    if (returnNullFromSyncBackground) return null;
    final img = nextSyncImage;
    nextSyncImage = null;
    return img;
  }

  @override
  Future<ui.Image?> renderPassesAsync({
    required List<ShaderPassInvocation> passes,
    required ui.Size physicalSize,
    ui.Image? inputImage,
    ui.Image? wallpaperImage,
    GpuFrameWatchdog? watchdog,
  }) async {
    asyncPassCalls.add(List<ShaderPassInvocation>.of(passes));
    asyncInputImages.add(inputImage);
    asyncWallpapers.add(wallpaperImage);
    final err = nextAsyncRenderError;
    if (err != null) {
      nextAsyncRenderError = null;
      throw err;
    }
    if (holdAsyncRender) {
      final completer = Completer<ui.Image?>();
      pendingAsyncCompleters.add(completer);
      return completer.future;
    }
    return _createSolidImage(
      width: physicalSize.width.round().clamp(1, 32),
      height: physicalSize.height.round().clamp(1, 32),
      color: asyncOutputColor,
    );
  }

  @override
  void dispose() {
    disposed = true;
    for (final handle in handles) {
      handle.dispose();
    }
  }
}

final class _CountingTerminalService implements TerminalService {
  final List<String> savedNames = <String>[];
  final Map<String, List<int>> savedPayloads = <String, List<int>>{};

  @override
  Future<String?> getClipboard() async => null;

  @override
  Future<bool> openUrl(String url) async => true;

  @override
  Future<String?> saveScreenshot(String filename, List<int> bytes) async {
    savedNames.add(filename);
    savedPayloads[filename] = bytes;
    return filename;
  }

  @override
  Future<void> setClipboard(String text) async {}
}

final class _ManualNotifier extends ChangeNotifier {
  void trigger() => notifyListeners();
}

Future<ui.Image> _createSolidImage({
  int width = 8,
  int height = 8,
  Color color = const Color(0xFFFF0000),
}) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawRect(
    Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
    Paint()..color = color,
  );
  final picture = recorder.endRecording();
  try {
    return await picture.toImage(width, height);
  } finally {
    picture.dispose();
  }
}

Future<Uint8List> _createValidPngBytes({
  int width = 4,
  int height = 4,
  Color color = const Color(0xFF2288CC),
}) async {
  final img = await _createSolidImage(
    width: width,
    height: height,
    color: color,
  );
  try {
    final data = await img.toByteData(format: ui.ImageByteFormat.png);
    return data!.buffer.asUint8List();
  } finally {
    img.dispose();
  }
}

Future<({int r, int g, int b, int a})> _readPixel(
  ui.Image image,
  int x,
  int y,
) async {
  final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
  final bytes = data!.buffer.asUint8List();
  final offset = (y * image.width + x) * 4;
  return (
    r: bytes[offset],
    g: bytes[offset + 1],
    b: bytes[offset + 2],
    a: bytes[offset + 3],
  );
}

const String _validStaticGlsl = '''
void mainImage(out vec4 fragColor, in vec2 fragCoord) {
  vec2 uv = fragCoord / max(iResolution.xy, vec2(1.0));
  fragColor = texture(iChannel0, uv);
}
''';

const String _validAnimatedGlsl = '''
void mainImage(out vec4 fragColor, in vec2 fragCoord) {
  vec2 uv = fragCoord / max(iResolution.xy, vec2(1.0));
  fragColor = vec4(sin(iTime), uv.x, uv.y, 1.0);
}
''';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('TerminalShaderHost fast-path and animation modes', () {
    testWidgets(
      'empty config returns bare child directly with zero Ticker and zero extra RepaintBoundary',
      (tester) async {
        const markerKey = ValueKey<String>('bare-child');
        final backend = _FakeShaderBackend();
        final controller = TerminalShaderController(backend: backend);
        addTearDown(controller.dispose);

        await tester.pumpWidget(
          Directionality(
            textDirection: TextDirection.ltr,
            child: TerminalShaderHost(
              controller: controller,
              config: TerminalShaderConfig.empty,
              child: const SizedBox(key: markerKey, width: 100, height: 60),
            ),
          ),
        );

        final hostState = tester.state<TerminalShaderHostState>(
          find.byType(TerminalShaderHost),
        );
        expect(find.byKey(markerKey), findsOneWidget);
        expect(
          find.descendant(
            of: find.byType(TerminalShaderHost),
            matching: find.byType(Stack),
          ),
          findsNothing,
        );
        expect(
          find.descendant(
            of: find.byType(TerminalShaderHost),
            matching: find.byType(RepaintBoundary),
          ),
          findsNothing,
        );
        expect(hostState.debugIsTickerActive, isFalse);
        expect(SchedulerBinding.instance.transientCallbackCount, equals(0));
      },
    );

    testWidgets(
      'static shader (usesTime == false) and staticOnly mode keep transientCallbackCount == 0 while idle',
      (tester) async {
        final backend = _FakeShaderBackend();
        final controller = TerminalShaderController(backend: backend);
        addTearDown(controller.dispose);

        final staticConfig = TerminalShaderConfig(
          backgroundPasses: <ShaderPassSpec>[
            ShaderPassSpec(
              id: 'bg:static',
              stage: TerminalShaderStage.background,
              inlineGlsl: _validStaticGlsl,
            ),
          ],
          animationMode: ShaderAnimationMode.always,
        );
        await tester.runAsync(() => controller.syncConfig(staticConfig));
        expect(controller.anyPassUsesTime, isFalse);

        await tester.pumpWidget(
          Directionality(
            textDirection: TextDirection.ltr,
            child: SizedBox(
              width: 120,
              height: 80,
              child: TerminalShaderHost(
                controller: controller,
                config: staticConfig,
                child: const SizedBox.expand(),
              ),
            ),
          ),
        );
        expect(SchedulerBinding.instance.transientCallbackCount, equals(0));

        // Animated shader under staticOnly still keeps transientCallbackCount == 0.
        final staticOnlyConfig = TerminalShaderConfig(
          backgroundPasses: <ShaderPassSpec>[
            ShaderPassSpec(
              id: 'bg:wave',
              stage: TerminalShaderStage.background,
              preset: TerminalShaderPreset.wallpaperWave,
            ),
          ],
          animationMode: ShaderAnimationMode.staticOnly,
        );
        await tester.runAsync(() => controller.syncConfig(staticOnlyConfig));
        expect(controller.anyPassUsesTime, isTrue);

        await tester.pumpWidget(
          Directionality(
            textDirection: TextDirection.ltr,
            child: SizedBox(
              width: 120,
              height: 80,
              child: TerminalShaderHost(
                controller: controller,
                config: staticOnlyConfig,
                child: const SizedBox.expand(),
              ),
            ),
          ),
        );
        expect(SchedulerBinding.instance.transientCallbackCount, equals(0));

        // Disabled backend never runs a ticker even for animated passes.
        final disabledController = TerminalShaderController(
          backend: const DisabledShaderBackend(),
        );
        addTearDown(disabledController.dispose);
        final alwaysAnimated = staticOnlyConfig.copyWith(
          animationMode: ShaderAnimationMode.always,
        );
        await tester.runAsync(
          () => disabledController.syncConfig(alwaysAnimated),
        );
        await tester.pumpWidget(
          Directionality(
            textDirection: TextDirection.ltr,
            child: SizedBox(
              width: 120,
              height: 80,
              child: TerminalShaderHost(
                controller: disabledController,
                config: alwaysAnimated,
                child: const SizedBox.expand(),
              ),
            ),
          ),
        );
        expect(SchedulerBinding.instance.transientCallbackCount, equals(0));
      },
    );

    testWidgets(
      'focused, always, onActivity, and TickerMode control ticker lifecycle and iFocus/iTimeFocus uniforms with 0 child rebuilds on iTime',
      (tester) async {
        final backend = _FakeShaderBackend();
        final controller = TerminalShaderController(backend: backend);
        addTearDown(controller.dispose);
        final activity = _ManualNotifier();
        addTearDown(activity.dispose);

        final focusedConfig = TerminalShaderConfig(
          backgroundPasses: <ShaderPassSpec>[
            ShaderPassSpec(
              id: 'bg:anim',
              stage: TerminalShaderStage.background,
              inlineGlsl: _validAnimatedGlsl,
            ),
          ],
          animationMode: ShaderAnimationMode.focused,
        );
        await tester.runAsync(() => controller.syncConfig(focusedConfig));

        var childBuildCount = 0;
        Widget buildHost({
          required TerminalShaderConfig config,
          required bool isFocused,
          bool tickerEnabled = true,
        }) => Directionality(
          textDirection: TextDirection.ltr,
          child: TickerMode(
            enabled: tickerEnabled,
            child: SizedBox(
              width: 100,
              height: 80,
              child: TerminalShaderHost(
                controller: controller,
                config: config,
                isFocused: isFocused,
                activityListenable: activity,
                activityTimeout: const Duration(milliseconds: 120),
                child: Builder(
                  builder: (_) {
                    childBuildCount++;
                    return const SizedBox.expand();
                  },
                ),
              ),
            ),
          ),
        );

        await tester.pumpWidget(
          buildHost(config: focusedConfig, isFocused: true),
        );
        expect(
          SchedulerBinding.instance.transientCallbackCount,
          greaterThan(0),
        );
        final buildsAfterMount = childBuildCount;

        // Advance iTime ticks and verify 0 child widget rebuilds.
        await tester.pump(const Duration(milliseconds: 50));
        await tester.pump(const Duration(milliseconds: 50));
        expect(childBuildCount, equals(buildsAfterMount));
        expect(backend.syncBackgroundCalls, isNotEmpty);
        final focusedUniforms = backend.syncBackgroundCalls.last.first.uniforms;
        expect(focusedUniforms.isFocused, isTrue);
        expect(focusedUniforms.timeSeconds, greaterThan(0.0));

        // Unfocus stops ticker and records iFocus == false and iTimeFocus > 0.
        await tester.pumpWidget(
          buildHost(config: focusedConfig, isFocused: false),
        );
        expect(SchedulerBinding.instance.transientCallbackCount, equals(0));
        final unfocusedUniforms =
            backend.syncBackgroundCalls.last.first.uniforms;
        expect(unfocusedUniforms.isFocused, isFalse);
        expect(unfocusedUniforms.timeFocusChange, greaterThan(0.0));

        // Always mode ticks while unfocused, but stops when TickerMode is false.
        final alwaysConfig = focusedConfig.copyWith(
          animationMode: ShaderAnimationMode.always,
        );
        await tester.pumpWidget(
          buildHost(config: alwaysConfig, isFocused: false),
        );
        expect(
          SchedulerBinding.instance.transientCallbackCount,
          greaterThan(0),
        );
        await tester.pumpWidget(
          buildHost(
            config: alwaysConfig,
            isFocused: false,
            tickerEnabled: false,
          ),
        );
        expect(SchedulerBinding.instance.transientCallbackCount, equals(0));

        // onActivity mode stays idle when focus didn't change, starts on activity, then stops after timeout.
        final onActivityConfig = focusedConfig.copyWith(
          animationMode: ShaderAnimationMode.onActivity,
        );
        await tester.pumpWidget(
          buildHost(config: onActivityConfig, isFocused: false),
        );
        expect(SchedulerBinding.instance.transientCallbackCount, equals(0));

        activity.trigger();
        await tester.pump(const Duration(milliseconds: 20));
        expect(
          SchedulerBinding.instance.transientCallbackCount,
          greaterThan(0),
        );

        await tester.pump(const Duration(milliseconds: 200));
        expect(SchedulerBinding.instance.transientCallbackCount, equals(0));
      },
    );
  });

  group('Single-flight async foreground pipeline, chaining, and disposal', () {
    testWidgets(
      'coalesces overlapping requests latest-wins, paints previous image while in-flight, disposes superseded images post-frame, and chains multi-pass foreground shaders',
      (tester) async {
        final backend = _FakeShaderBackend()..holdAsyncRender = true;
        final controller = TerminalShaderController(backend: backend);
        addTearDown(controller.dispose);
        final activity = _ManualNotifier();
        addTearDown(activity.dispose);

        final fgConfig = TerminalShaderConfig(
          foregroundPasses: <ShaderPassSpec>[
            ShaderPassSpec(
              id: 'fg:crt',
              stage: TerminalShaderStage.foreground,
              preset: TerminalShaderPreset.crtLottes,
            ),
            ShaderPassSpec(
              id: 'fg:phosphor',
              stage: TerminalShaderStage.foreground,
              preset: TerminalShaderPreset.phosphorGlow,
              usesPrevFrame: true,
            ),
          ],
          animationMode: ShaderAnimationMode.staticOnly,
        );
        await tester.runAsync(() => controller.syncConfig(fgConfig));

        await tester.pumpWidget(
          Directionality(
            textDirection: TextDirection.ltr,
            child: SizedBox(
              width: 64,
              height: 48,
              child: TerminalShaderHost(
                controller: controller,
                config: fgConfig,
                paneKey: 'pane-1',
                activityListenable: activity,
                child: const ColoredBox(color: Color(0xFF102030)),
              ),
            ),
          ),
        );
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));
        await tester.pump();
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));

        expect(backend.asyncPassCalls, hasLength(1));
        expect(backend.asyncPassCalls.first, hasLength(2));
        expect(backend.asyncPassCalls.first[0].handle.id, equals('fg:crt'));
        expect(
          backend.asyncPassCalls.first[0].prevFrameKey,
          equals('pane-1:fg:crt'),
        );
        expect(
          backend.asyncPassCalls.first[1].handle.id,
          equals('fg:phosphor'),
        );
        expect(backend.asyncPassCalls.first[1].handle.usesPrevFrame, isTrue);
        expect(backend.asyncInputImages.first, isNotNull);

        // Trigger 3 overlapping activity updates while call #1 is still in flight.
        activity.trigger();
        activity.trigger();
        activity.trigger();
        await tester.pump();
        expect(
          backend.asyncPassCalls,
          hasLength(1),
          reason: 'Single-flight pipeline must coalesce overlapping requests.',
        );

        final img1 = await tester.runAsync(
          () => _createSolidImage(
            width: 64,
            height: 48,
            color: const Color(0xFF112233),
          ),
        );
        final img2 = await tester.runAsync(
          () => _createSolidImage(
            width: 64,
            height: 48,
            color: const Color(0xFF445566),
          ),
        );

        final hostState = tester.state<TerminalShaderHostState>(
          find.byType(TerminalShaderHost),
        );

        // Complete call #1 -> paints img1 and triggers exactly ONE coalesced rerun.
        backend.pendingAsyncCompleters[0].complete(img1);
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));
        await tester.pump();
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));

        expect(hostState.debugForegroundOutputImage, same(img1));
        expect(img1!.debugDisposed, isFalse);
        expect(backend.asyncPassCalls, hasLength(2));

        // While call #2 is still in flight, img1 remains painted and undisposed.
        await tester.pump();
        expect(hostState.debugForegroundOutputImage, same(img1));
        expect(img1.debugDisposed, isFalse);

        // Complete call #2 -> swaps to img2 and defers img1 disposal post-frame.
        backend.pendingAsyncCompleters[1].complete(img2);
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));
        expect(hostState.debugForegroundOutputImage, same(img2));
        expect(img1.debugDisposed, isFalse);
        expect(
          hostState.debugPendingImageDisposalCount,
          greaterThanOrEqualTo(1),
        );

        // Pump frame so post-frame callback disposes superseded img1.
        await tester.pump();
        expect(img1.debugDisposed, isTrue);
        expect(img2!.debugDisposed, isFalse);

        // Unmount disposes active img2 cleanly.
        await tester.pumpWidget(const SizedBox.shrink());
        expect(img2.debugDisposed, isTrue);
      },
    );

    testWidgets(
      'falls back to async background render when supportsSyncBackground is false or sync returns null',
      (tester) async {
        final backend = _FakeShaderBackend(
          kind: ShaderBackendKind.webGl2,
          supportsSyncBackground: true,
        )..returnNullFromSyncBackground = true;
        final controller = TerminalShaderController(backend: backend);
        addTearDown(controller.dispose);

        final bgConfig = TerminalShaderConfig(
          backgroundPasses: <ShaderPassSpec>[
            ShaderPassSpec(
              id: 'bg:wave',
              stage: TerminalShaderStage.background,
              preset: TerminalShaderPreset.wallpaperWave,
            ),
          ],
          animationMode: ShaderAnimationMode.staticOnly,
        );
        await tester.runAsync(() => controller.syncConfig(bgConfig));

        await tester.pumpWidget(
          Directionality(
            textDirection: TextDirection.ltr,
            child: SizedBox(
              width: 80,
              height: 40,
              child: TerminalShaderHost(
                controller: controller,
                config: bgConfig,
                child: const SizedBox.expand(),
              ),
            ),
          ),
        );
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));
        await tester.pump();

        expect(backend.syncBackgroundCalls, isNotEmpty);
        expect(backend.asyncPassCalls, isNotEmpty);
        expect(backend.asyncInputImages.first, isNull);
      },
    );
  });

  group('Ghostty cursor tracking and 256-color palette uniforms', () {
    testWidgets(
      'tracks Ghostty Y-up (left, bottomY, width, height) current/previous cursor and iTimeCursorChange',
      (tester) async {
        final backend = _FakeShaderBackend();
        final controller = TerminalShaderController(backend: backend);
        addTearDown(controller.dispose);

        final config = TerminalShaderConfig(
          backgroundPasses: <ShaderPassSpec>[
            ShaderPassSpec(
              id: 'bg:cursor_probe',
              stage: TerminalShaderStage.background,
              inlineGlsl: _validAnimatedGlsl,
            ),
          ],
          animationMode: ShaderAnimationMode.always,
        );
        await tester.runAsync(() => controller.syncConfig(config));

        final palette = Uint32List(TerminalShaderUniforms.paletteLength);
        for (var i = 0; i < palette.length; i++) {
          palette[i] = TerminalColorTheme.termuiDark.resolveAnsi256(i).argb;
        }

        // Viewport 200x100 logical @ DPR 1.0 -> cell 10x20.
        const initialRect = Rect.fromLTWH(0.0, 0.0, 10.0, 20.0);
        const movedRect = Rect.fromLTWH(30.0, 40.0, 10.0, 20.0);

        await tester.pumpWidget(
          MediaQuery(
            data: const MediaQueryData(devicePixelRatio: 1.0),
            child: Directionality(
              textDirection: TextDirection.ltr,
              child: Align(
                alignment: Alignment.topLeft,
                child: SizedBox(
                  width: 200,
                  height: 100,
                  child: TerminalShaderHost(
                    controller: controller,
                    config: config,
                    cursorRectLogical: initialRect,
                    cursorColorArgb: 0xFF62D196,
                    cursorStyle: TerminalShaderUniforms.cursorStyleBlock,
                    cursorVisible: true,
                    palette256Argb: palette,
                    cellSizeLogical: const Size(10.0, 20.0),
                    child: const SizedBox.expand(),
                  ),
                ),
              ),
            ),
          ),
        );

        final firstUniforms = backend.syncBackgroundCalls.last.first.uniforms;
        // Top-left (0, 0, 10, 20) in Y-down 100px viewport -> bottomY = 100 - 20 = 80.
        expect(
          firstUniforms.currentCursorXywh,
          equals(<double>[0.0, 80.0, 10.0, 20.0]),
        );
        expect(
          firstUniforms.previousCursorXywh,
          equals(<double>[0.0, 80.0, 10.0, 20.0]),
        );
        expect(
          firstUniforms.palette256Argb[4],
          equals(TerminalColorTheme.termuiDark.resolveAnsi256(4).argb),
        );

        // Advance time then move cursor + switch style to bar.
        await tester.pump(const Duration(milliseconds: 60));
        await tester.pumpWidget(
          MediaQuery(
            data: const MediaQueryData(devicePixelRatio: 1.0),
            child: Directionality(
              textDirection: TextDirection.ltr,
              child: Align(
                alignment: Alignment.topLeft,
                child: SizedBox(
                  width: 200,
                  height: 100,
                  child: TerminalShaderHost(
                    controller: controller,
                    config: config,
                    cursorRectLogical: movedRect,
                    cursorColorArgb: 0xFFFFAA00,
                    cursorStyle: TerminalShaderUniforms.cursorStyleBar,
                    cursorVisible: true,
                    palette256Argb: palette,
                    cellSizeLogical: const Size(10.0, 20.0),
                    child: const SizedBox.expand(),
                  ),
                ),
              ),
            ),
          ),
        );

        final secondUniforms = backend.syncBackgroundCalls.last.first.uniforms;
        // (30, 40, 10, 20) in Y-down 100px viewport -> bottomY = 100 - 60 = 40.
        expect(
          secondUniforms.currentCursorXywh,
          equals(<double>[30.0, 40.0, 10.0, 20.0]),
        );
        expect(
          secondUniforms.previousCursorXywh,
          equals(<double>[0.0, 80.0, 10.0, 20.0]),
        );
        expect(secondUniforms.currentCursorArgb, equals(0xFFFFAA00));
        expect(secondUniforms.previousCursorArgb, equals(0xFF62D196));
        expect(
          secondUniforms.currentCursorStyle,
          equals(TerminalShaderUniforms.cursorStyleBar),
        );
        expect(secondUniforms.timeCursorChange, greaterThan(0.0));
      },
    );

    testWidgets(
      'ignores hidden cursor jumps so iPreviousCursor stays on the last visible position',
      (WidgetTester tester) async {
        final backend = _FakeShaderBackend();
        final controller = TerminalShaderController(backend: backend);
        addTearDown(controller.dispose);

        final config = TerminalShaderConfig(
          backgroundPasses: <ShaderPassSpec>[
            ShaderPassSpec(
              id: 'bg:cursor_probe',
              stage: TerminalShaderStage.background,
              inlineGlsl: _validAnimatedGlsl,
            ),
          ],
          animationMode: ShaderAnimationMode.always,
        );
        await tester.runAsync(() => controller.syncConfig(config));

        final palette = Uint32List(TerminalShaderUniforms.paletteLength);
        for (var i = 0; i < palette.length; i++) {
          palette[i] = TerminalColorTheme.termuiDark.resolveAnsi256(i).argb;
        }

        Widget buildHost(Rect rect, {required bool visible}) => MediaQuery(
          data: const MediaQueryData(devicePixelRatio: 1.0),
          child: Directionality(
            textDirection: TextDirection.ltr,
            child: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: 200,
                height: 100,
                child: TerminalShaderHost(
                  controller: controller,
                  config: config,
                  cursorRectLogical: rect,
                  cursorColorArgb: 0xFF62D196,
                  cursorStyle: TerminalShaderUniforms.cursorStyleBlock,
                  cursorVisible: visible,
                  palette256Argb: palette,
                  cellSizeLogical: const Size(10.0, 20.0),
                  child: const SizedBox.expand(),
                ),
              ),
            ),
          ),
        );

        // 1. Initial hidden frame must not latch a bogus origin.
        await tester.pumpWidget(
          buildHost(const Rect.fromLTWH(180, 0, 10, 20), visible: false),
        );
        expect(
          backend.syncBackgroundCalls.last.first.uniforms.cursorVisible,
          isFalse,
        );

        // 2. First visible frame at (10, 20) initializes both current & previous.
        await tester.pumpWidget(
          buildHost(const Rect.fromLTWH(10, 20, 10, 20), visible: true),
        );
        final firstVisible = backend.syncBackgroundCalls.last.first.uniforms;
        expect(
          firstVisible.currentCursorXywh,
          equals(<double>[10.0, 60.0, 10.0, 20.0]),
        );
        expect(
          firstVisible.previousCursorXywh,
          equals(<double>[10.0, 60.0, 10.0, 20.0]),
        );
        final initialChangeTime = firstVisible.timeCursorChange;

        // 3. Hidden jump to far right (simulating Powerlevel10k RPROMPT redraw)
        // must NOT overwrite currentCursorXywh, previousCursorXywh, or timeCursorChange.
        await tester.pump(const Duration(milliseconds: 50));
        await tester.pumpWidget(
          buildHost(const Rect.fromLTWH(180, 20, 10, 20), visible: false),
        );
        final hiddenFrame = backend.syncBackgroundCalls.last.first.uniforms;
        expect(hiddenFrame.cursorVisible, isFalse);
        expect(
          hiddenFrame.currentCursorXywh,
          equals(<double>[10.0, 60.0, 10.0, 20.0]),
        );
        expect(
          hiddenFrame.previousCursorXywh,
          equals(<double>[10.0, 60.0, 10.0, 20.0]),
        );
        expect(hiddenFrame.timeCursorChange, equals(initialChangeTime));

        // 4. Cursor reappears on the next prompt row at (10, 40): previousCursor
        // is the last visible position (10, 20), NOT the hidden far-right jump.
        await tester.pump(const Duration(milliseconds: 50));
        await tester.pumpWidget(
          buildHost(const Rect.fromLTWH(10, 40, 10, 20), visible: true),
        );
        final nextVisible = backend.syncBackgroundCalls.last.first.uniforms;
        expect(nextVisible.cursorVisible, isTrue);
        expect(
          nextVisible.currentCursorXywh,
          equals(<double>[10.0, 40.0, 10.0, 20.0]),
        );
        expect(
          nextVisible.previousCursorXywh,
          equals(<double>[10.0, 60.0, 10.0, 20.0]),
        );
        expect(nextVisible.timeCursorChange, greaterThan(initialChangeTime));
      },
    );

    testWidgets(
      'coalesces multiple same-frame PTY cursor updates so unrendered intermediate positions do not pollute iPreviousCursor',
      (WidgetTester tester) async {
        final backend = _FakeShaderBackend();
        final controller = TerminalShaderController(backend: backend);
        addTearDown(controller.dispose);

        final config = TerminalShaderConfig(
          backgroundPasses: <ShaderPassSpec>[
            ShaderPassSpec(
              id: 'bg:cursor_probe',
              stage: TerminalShaderStage.background,
              inlineGlsl: _validAnimatedGlsl,
            ),
          ],
          animationMode: ShaderAnimationMode.always,
        );
        await tester.runAsync(() => controller.syncConfig(config));

        final palette = Uint32List(TerminalShaderUniforms.paletteLength);
        for (var i = 0; i < palette.length; i++) {
          palette[i] = TerminalColorTheme.termuiDark.resolveAnsi256(i).argb;
        }

        final activity = ChangeNotifier();
        addTearDown(activity.dispose);
        var currentRect = const Rect.fromLTWH(10, 20, 10, 20);

        await tester.pumpWidget(
          MediaQuery(
            data: const MediaQueryData(devicePixelRatio: 1.0),
            child: Directionality(
              textDirection: TextDirection.ltr,
              child: Align(
                alignment: Alignment.topLeft,
                child: SizedBox(
                  width: 200,
                  height: 100,
                  child: TerminalShaderHost(
                    controller: controller,
                    config: config,
                    cursorRectLogicalProvider: () => currentRect,
                    cursorColorArgb: 0xFF62D196,
                    cursorStyle: TerminalShaderUniforms.cursorStyleBlock,
                    cursorVisible: true,
                    activityListenable: activity,
                    palette256Argb: palette,
                    cellSizeLogical: const Size(10.0, 20.0),
                    child: const SizedBox.expand(),
                  ),
                ),
              ),
            ),
          ),
        );

        // Initial painted frame: cursor at (10, 20) -> Y-up bottomY = 60.
        final initial = backend.syncBackgroundCalls.last.first.uniforms;
        expect(
          initial.currentCursorXywh,
          equals(<double>[10.0, 60.0, 10.0, 20.0]),
        );

        // Simulate two rapid PTY chunks before the next VSync frame paints:
        // Chunk 1: zsh/P10k writes RPROMPT at far right (180, 20) while visible.
        currentRect = const Rect.fromLTWH(180, 20, 10, 20);
        activity.notifyListeners();
        // Chunk 2: zsh moves down to new prompt on next row (10, 40).
        currentRect = const Rect.fromLTWH(10, 40, 10, 20);
        activity.notifyListeners();

        // Next VSync paints: previousCursor must be (10, 20) [bottomY 60],
        // NOT the unrendered intermediate far-right (180, 20).
        await tester.pump(const Duration(milliseconds: 16));
        final painted = backend.syncBackgroundCalls.last.first.uniforms;
        expect(
          painted.currentCursorXywh,
          equals(<double>[10.0, 40.0, 10.0, 20.0]),
        );
        expect(
          painted.previousCursorXywh,
          equals(<double>[10.0, 60.0, 10.0, 20.0]),
        );
      },
    );
  });

  group(
    'Translucent backgroundOpacity, wallpaper visibility, and F12 boundary',
    () {
      test('TuiAtlasPainter blends translucent default bg == 0 cells while keeping explicit bg != 0 cells opaque and reversed text legible', () async {
        final atlas = await GlyphAtlasGenerator.generateEmpty(
          fontSize: 16.0,
          fontFamily: 'Roboto Mono',
        );
        addTearDown(atlas.dispose);

        final buffer = Buffer(3, 1)
          ..writeString(0, 0, ' ', Style.empty)
          ..writeString(
            1,
            0,
            ' ',
            const Style(background: tui.Color(0, 255, 0)),
          )
          ..writeString(2, 0, ' ', const Style(modifiers: Modifier.reverse));

        final imgW = (3 * atlas.cellWidth).ceil();
        final imgH = atlas.cellHeight.ceil();
        final recorder = ui.PictureRecorder();
        final canvas = Canvas(recorder);
        // Simulate a solid red wallpaper behind the terminal canvas.
        canvas.drawRect(
          Rect.fromLTWH(0, 0, imgW.toDouble(), imgH.toDouble()),
          Paint()..color = const Color(0xFFFF0000),
        );

        final painter = TuiAtlasPainter(
          buffer: buffer,
          atlas: atlas,
          fontFamily: 'Roboto Mono',
          fallbackPainters: const {},
          onMissingGlyphs: null,
          defaultForegroundArgb: 0xFFFFFFFF,
          defaultBackgroundArgb: 0x800000FF, // 50% translucent blue
        );
        painter.paint(canvas, Size(imgW.toDouble(), imgH.toDouble()));
        final picture = recorder.endRecording();
        final rendered = await picture.toImage(imgW, imgH);
        picture.dispose();
        addTearDown(rendered.dispose);

        final sampleY = (atlas.cellHeight * 0.5).floor();
        final defaultCellPx = await _readPixel(
          rendered,
          (atlas.cellWidth * 0.5).floor(),
          sampleY,
        );
        // 50% blue over solid red -> both red and blue channels visible (~127).
        expect(defaultCellPx.r, inInclusiveRange(100, 155));
        expect(defaultCellPx.b, inInclusiveRange(100, 155));

        final explicitCellPx = await _readPixel(
          rendered,
          (atlas.cellWidth * 1.5).floor(),
          sampleY,
        );
        // Explicit green cell stays 100% opaque green.
        expect(explicitCellPx.r, equals(0));
        expect(explicitCellPx.g, equals(255));
        expect(explicitCellPx.b, equals(0));
        expect(explicitCellPx.a, equals(255));

        // Reversed cell with alpha == 0 defaultBackgroundArgb keeps opaque fg.
        expect(
          TuiAtlasPainter.resolveCellForegroundArgb(
            0,
            0,
            modifiers: Modifier.reverse,
            isReverse: true,
            defaultBackgroundArgb: 0x0014171F,
          ),
          equals(0xFF14171F),
        );
      });

      testWidgets(
        'TerminalSurface reveals wallpaper at backgroundOpacity = 0.5 behind _buildCanvasContainer and F12 takeScreenshot wraps TerminalShaderHost',
        (tester) async {
          final wallpaper = await tester.runAsync(
            () => _createSolidImage(
              width: 32,
              height: 32,
              color: const Color(0xFFFF0000),
            ),
          );
          addTearDown(() => wallpaper?.dispose());

          final atlasController = GlyphAtlasController(
            fontSize: 14.0,
            fontFamily: 'Roboto Mono',
          );
          addTearDown(atlasController.dispose);
          await tester.runAsync(atlasController.ensureInitialized);

          final service = _CountingTerminalService();
          final buffer = Buffer(8, 2)
            ..writeString(0, 0, 'A', Style.empty)
            ..writeString(
              3,
              0,
              ' ',
              const Style(background: tui.Color(0, 255, 0)),
            );
          final surfaceKey = GlobalKey<TerminalSurfaceState>();

          final surfaceBackend = _FakeShaderBackend();
          final surfaceShaderController = TerminalShaderController(
            backend: surfaceBackend,
          );
          addTearDown(surfaceShaderController.dispose);
          final surfaceShaderConfig = TerminalShaderConfig(
            backgroundImage: wallpaper,
            backgroundOpacity: 0.5,
          );

          await tester.pumpWidget(
            Directionality(
              textDirection: TextDirection.ltr,
              child: SizedBox(
                width: 160,
                height: 64,
                child: TerminalSurface(
                  key: surfaceKey,
                  atlasController: atlasController,
                  buffer: buffer,
                  cursorPosition: (col: 2, row: 1),
                  backgroundColor: const Color(0xFF0000FF),
                  foregroundColor: const Color(0xFFFFFFFF),
                  backgroundOpacity: 0.5,
                  shaderController: surfaceShaderController,
                  shaderConfig: surfaceShaderConfig,
                  service: service,
                  alignment: Alignment.topLeft,
                ),
              ),
            ),
          );
          await tester.pump();

          // Verify _buildCanvasContainer's Container is not opaque.
          final container = tester.widget<Container>(
            find.descendant(
              of: find.byType(TerminalShaderHost),
              matching: find.byType(Container),
            ),
          );
          expect(container.color!.a, lessThan(1.0));

          // Verify the screenshot RepaintBoundary wraps TerminalShaderHost.
          final boundaryAncestors = find.ancestor(
            of: find.byType(TerminalShaderHost),
            matching: find.byType(RepaintBoundary),
          );
          expect(boundaryAncestors, findsWidgets);

          // Read back pixels from the screenshot RepaintBoundary directly.
          final boundaryRender = tester.renderObject<RenderRepaintBoundary>(
            boundaryAncestors.first,
          );
          final captured = await tester.runAsync(
            () => boundaryRender.toImage(pixelRatio: 1.0),
          );
          addTearDown(() => captured?.dispose());
          final atlas = atlasController.atlas!;
          final sampleY = (atlas.cellHeight * 0.5).floor();
          final blendedPx = await tester.runAsync(
            () =>
                _readPixel(captured!, (atlas.cellWidth * 1.5).floor(), sampleY),
          );
          expect(blendedPx!.r, inInclusiveRange(100, 155));
          expect(blendedPx.b, inInclusiveRange(100, 155));

          final opaquePx = await tester.runAsync(
            () =>
                _readPixel(captured!, (atlas.cellWidth * 3.5).floor(), sampleY),
          );
          expect(opaquePx!.g, equals(255));
          expect(opaquePx.r, equals(0));

          // Trigger F12 takeScreenshot pipeline and verify PNG output is saved.
          await tester.runAsync(
            () => surfaceKey.currentState!.takeScreenshot(),
          );
          expect(
            service.savedNames.any((n) => n.startsWith('screenshot_')),
            isTrue,
          );
        },
      );
    },
  );

  group('TerminalShaderController hot-reload, backend switch, and wallpaper disposal', () {
    testWidgets(
      'preserves previous compiled handle on ShaderCompileException and recovers on next valid reload',
      (tester) async {
        final backend = _FakeShaderBackend();
        final controller = TerminalShaderController(backend: backend);
        addTearDown(controller.dispose);

        var notifications = 0;
        controller.addListener(() => notifications++);

        var currentGlsl = _validStaticGlsl;
        final config = TerminalShaderConfig(
          foregroundPasses: <ShaderPassSpec>[
            ShaderPassSpec(
              id: 'fg:custom.glsl',
              stage: TerminalShaderStage.foreground,
              customSourcePath: 'custom.glsl',
            ),
          ],
        );

        await controller.syncConfig(
          config,
          sourceLoader: (_) async => currentGlsl,
        );
        final originalHandle = controller.handleForPass('fg:custom.glsl');
        expect(originalHandle, isNotNull);
        expect(controller.lastCompileError, isNull);
        expect(controller.analysisForPass('fg:custom.glsl')?.usesTime, isFalse);

        // Reload with broken GLSL (#include violation caught by shim):
        // preserves originalHandle and records lastCompileError.
        currentGlsl = '#include "bad.glsl"\n$_validStaticGlsl';
        final beforeNotify = notifications;
        await controller.reloadCustomShaders(
          sourceLoader: (_) async => currentGlsl,
        );
        expect(
          identical(controller.handleForPass('fg:custom.glsl'), originalHandle),
          isTrue,
        );
        expect(controller.lastCompileError, isNotNull);
        expect(controller.lastCompileError!.message, contains('#include'));
        expect(notifications, greaterThan(beforeNotify));

        // Reload with backend compile error: still preserves originalHandle.
        currentGlsl = _validAnimatedGlsl;
        backend.nextReloadError = const ShaderCompileException(
          shaderId: 'fg:custom.glsl',
          message: 'syntax error near token',
          lineNumber: 3,
        );
        await controller.reloadCustomShaders(
          sourceLoader: (_) async => currentGlsl,
        );
        expect(
          identical(controller.handleForPass('fg:custom.glsl'), originalHandle),
          isTrue,
        );
        expect(controller.lastCompileError?.lineNumber, equals(3));

        // Next valid reload succeeds, clears lastCompileError, updates analysis.
        await controller.reloadCustomShaders(
          sourceLoader: (_) async => currentGlsl,
        );
        expect(
          identical(controller.handleForPass('fg:custom.glsl'), originalHandle),
          isTrue,
        );
        expect(controller.lastCompileError, isNull);
        expect(controller.anyPassUsesTime, isTrue);

        // Missing sourceLoader produces structured ShaderCompileException.
        final noLoaderCtrl = TerminalShaderController(
          backend: _FakeShaderBackend(),
        );
        addTearDown(noLoaderCtrl.dispose);
        await noLoaderCtrl.syncConfig(config);
        expect(noLoaderCtrl.lastCompileError, isNotNull);
        noLoaderCtrl.clearLastCompileError();
        expect(noLoaderCtrl.lastCompileError, isNull);
      },
    );

    testWidgets(
      'switches backendOverride cleanly, disposes wallpaper images post-frame, and dispose() is idempotent',
      (tester) async {
        final createdBackends = <_FakeShaderBackend>[];
        final controller = TerminalShaderController(
          backendFactory: (override) {
            if (override == ShaderBackendKind.disabled) {
              return const DisabledShaderBackend();
            }
            final fake = _FakeShaderBackend();
            createdBackends.add(fake);
            return fake;
          },
        );

        expect(controller.backendKind, equals(ShaderBackendKind.flutterGpu));
        expect(controller.supportsCustomGlsl, isTrue);
        expect(controller.supportsSyncBackground, isTrue);

        final cfg = TerminalShaderConfig(
          foregroundPasses: <ShaderPassSpec>[
            ShaderPassSpec(
              id: 'fg:scanline',
              stage: TerminalShaderStage.foreground,
              preset: TerminalShaderPreset.scanlineOverlay,
            ),
          ],
        );
        await controller.syncConfig(cfg);
        expect(createdBackends.first.compileCount, equals(1));

        // Runtime switch to disabled disposes previous backend.
        await controller.setBackendOverride(ShaderBackendKind.disabled);
        expect(createdBackends.first.disposed, isTrue);
        expect(controller.backendKind, equals(ShaderBackendKind.disabled));
        expect(controller.backendOverride, equals(ShaderBackendKind.disabled));

        // Switch back to Auto creates a new backend and recompiles active pass.
        await controller.setBackendOverride(null);
        expect(controller.backendKind, equals(ShaderBackendKind.flutterGpu));
        expect(createdBackends, hasLength(2));
        expect(createdBackends.last.compileCount, equals(1));

        // Wallpaper post-frame disposal check.
        final wp1 = await tester.runAsync(
          () => _createSolidImage(color: const Color(0xFF111111)),
        );
        final wp2 = await tester.runAsync(
          () => _createSolidImage(color: const Color(0xFF222222)),
        );
        controller.setWallpaperImage(wp1);
        expect(controller.wallpaperImage, same(wp1));
        controller.setWallpaperImage(wp2);
        expect(controller.wallpaperImage, same(wp2));
        expect(wp1!.debugDisposed, isFalse);
        expect(controller.debugPendingImageDisposalCount, equals(1));

        await tester.pump();
        expect(wp1.debugDisposed, isTrue);
        expect(wp2!.debugDisposed, isFalse);

        // Encoded PNG bytes decode cleanly.
        final pngBytes = await tester.runAsync(_createValidPngBytes);
        await tester.runAsync(() => controller.setWallpaperBytes(pngBytes!));
        expect(controller.wallpaperImage, isNotNull);
        await tester.pump();
        expect(wp2.debugDisposed, isTrue);

        controller.clearWallpaperImage();
        expect(controller.wallpaperImage, isNull);
        await tester.pump();

        // Idempotent dispose.
        controller.dispose();
        controller.dispose();
        expect(controller.isDisposed, isTrue);
        expect(createdBackends.last.disposed, isTrue);
      },
    );

    testWidgets(
      'animated background shader refreshes foreground iChannel0 capture on idle ticks and catches runtime GPU link/draw errors cleanly',
      (tester) async {
        final backend = _FakeShaderBackend();
        final controller = TerminalShaderController(backend: backend);
        addTearDown(controller.dispose);

        final config = TerminalShaderConfig(
          animationMode: ShaderAnimationMode.focused,
          backgroundOpacity: 0.5,
          backgroundPasses: <ShaderPassSpec>[
            ShaderPassSpec(
              id: 'bg:wave',
              stage: TerminalShaderStage.background,
              preset: TerminalShaderPreset.wallpaperWave,
            ),
          ],
          foregroundPasses: <ShaderPassSpec>[
            ShaderPassSpec(
              id: 'fg:scanline',
              stage: TerminalShaderStage.foreground,
              preset: TerminalShaderPreset.scanlineOverlay,
            ),
          ],
        );
        await controller.syncConfig(config);

        await tester.pumpWidget(
          Directionality(
            textDirection: TextDirection.ltr,
            child: SizedBox(
              width: 120,
              height: 60,
              child: TerminalShaderHost(
                controller: controller,
                config: config,
                isFocused: true,
                child: const SizedBox.expand(),
              ),
            ),
          ),
        );
        await tester.pump();
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump();

        expect(backend.asyncInputImages, isNotEmpty);
        final firstCapture = backend.asyncInputImages.last;

        // Advance ticker with no user keypress/click -> must recapture iChannel0
        // so animated background shaders animate under foreground overlays.
        await tester.pump(const Duration(milliseconds: 50));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump();
        expect(backend.asyncInputImages.length, greaterThanOrEqualTo(2));
        expect(identical(backend.asyncInputImages.last, firstCapture), isFalse);

        // Runtime GPU pipeline error in sync background & async foreground
        // must be caught cleanly (no paint exception) and reported via
        // controller.lastCompileError.
        backend.nextSyncRenderError = const ShaderCompileException(
          shaderId: 'bg:wave',
          message: 'GPU pipeline failed to link',
        );
        await tester.pump(const Duration(milliseconds: 50));
        expect(tester.takeException(), isNull);
        expect(controller.lastCompileError?.shaderId, equals('bg:wave'));

        controller.clearLastCompileError();
        backend.nextAsyncRenderError = Exception('Failed to append draw');
        await tester.pump(const Duration(milliseconds: 50));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump();
        expect(tester.takeException(), isNull);
        expect(controller.lastCompileError, isNotNull);
        expect(
          controller.lastCompileError!.message,
          contains('Failed to append draw'),
        );
      },
    );

    testWidgets(
      'static foreground shader waits for child repaint before capture and occludes live baseLayer against translucent bleed-through',
      (tester) async {
        final backend = _FakeShaderBackend()
          // Translucent foreground output (50% green, like scanline with
          // backgroundOpacity < 1.0).
          ..asyncOutputColor = const Color(0x8000FF00);
        final controller = TerminalShaderController(backend: backend);
        addTearDown(controller.dispose);

        final config = TerminalShaderConfig(
          foregroundPasses: <ShaderPassSpec>[
            ShaderPassSpec(
              id: 'fg:scanline',
              stage: TerminalShaderStage.foreground,
              preset: TerminalShaderPreset.scanlineOverlay,
            ),
          ],
          animationMode: ShaderAnimationMode.focused,
          backgroundOpacity: 0.5,
        );
        await tester.runAsync(() => controller.syncConfig(config));

        final paintNotifier = _TestPaintNotifier();
        addTearDown(paintNotifier.dispose);
        var childColor = const Color(0xFF0000FF); // blue on frame 1
        final outerBoundaryKey = GlobalKey();

        await tester.pumpWidget(
          Directionality(
            textDirection: TextDirection.ltr,
            child: Center(
              child: RepaintBoundary(
                key: outerBoundaryKey,
                child: SizedBox(
                  width: 40,
                  height: 20,
                  child: TerminalShaderHost(
                    controller: controller,
                    config: config,
                    backgroundArgb: 0xFF000000,
                    activityListenable: paintNotifier,
                    child: CustomPaint(
                      painter: _ColorBlockPainter(
                        repaint: paintNotifier,
                        colorProvider: () => childColor,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pump();
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump();

        expect(backend.asyncInputImages, hasLength(1));
        final firstPx = await tester.runAsync(
          () => _readPixel(backend.asyncInputImages.last!, 5, 5),
        );
        expect(firstPx!.b, greaterThan(200));

        // Mutate child to bright RED and notify during SchedulerPhase.idle —
        // mirrors TerminalSurface._paintNotifier firing before child
        // RenderCustomPaint.markNeedsPaint runs.
        childColor = const Color(0xFFFF0000);
        paintNotifier.fire();

        // Must wait for the next frame so the captured inputImage contains the
        // NEW red child (not stale blue!).
        await tester.pump();
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump();

        expect(backend.asyncInputImages.length, greaterThanOrEqualTo(2));
        final secondPx = await tester.runAsync(
          () => _readPixel(backend.asyncInputImages.last!, 5, 5),
        );
        expect(secondPx!.r, greaterThan(200));
        expect(secondPx.b, lessThan(20));

        // Now capture the final composited TerminalShaderHost output: even
        // though the foreground shader image is 50% translucent green and the
        // live baseLayer underneath is bright RED, the opaque backdrop in
        // _ForegroundShaderPainter must prevent any red bleed-through!
        final hostBoundary =
            outerBoundaryKey.currentContext!.findRenderObject()!
                as RenderRepaintBoundary;
        final composited = await tester.runAsync(
          () => hostBoundary.toImage(pixelRatio: 1.0),
        );
        addTearDown(() => composited?.dispose());
        final outPx = await tester.runAsync(
          () => _readPixel(composited!, 5, 5),
        );
        expect(outPx!.r, equals(0));
        expect(outPx.g, inInclusiveRange(100, 155));
        expect(outPx.a, equals(255));
      },
    );
  });

  group('Direct GPU-to-GPU terminal rendering', () {
    testWidgets(
      'bypasses renderPassesAsync on clean frames, ticks foreground-only animations, and stays idle with zero shaders',
      (tester) async {
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetDevicePixelRatio);
        final atlasImg = await tester.runAsync(
          () => _createSolidImage(
            width: 32,
            height: 32,
            color: const Color(0xFFFFFFFF),
          ),
        );
        addTearDown(() => atlasImg?.dispose());
        final outputImg = await tester.runAsync(
          () => _createSolidImage(
            width: 120,
            height: 60,
            color: const Color(0xFF2288EE),
          ),
        );
        addTearDown(() => outputImg?.dispose());

        final backend = _FakeDirectShaderBackend(
          syncOutputFactory: () => outputImg!.clone(),
        );
        final controller = TerminalShaderController(backend: backend);
        addTearDown(controller.dispose);

        final cleanBatch = GpuAtlasQuadBatch(
          instanceData: Float32List(16),
          instanceCount: 1,
          italicStartInstanceIndex: 1,
          kittyInsertInstanceIndex: 1,
          generation: 1,
          defaultBackgroundArgb: 0xFF000000,
          kittyQuads: const <GpuKittyQuad>[],
          hasCanvasOnlyContent: false,
        );
        final activity = _TestPaintNotifier();
        addTearDown(activity.dispose);

        // 1. Zero-shader unified direct mode: renders once, 0 ticker ticks while idle.
        await tester.pumpWidget(
          Directionality(
            textDirection: TextDirection.ltr,
            child: Center(
              child: TerminalShaderHost(
                controller: controller,
                config: TerminalShaderConfig.empty,
                activityListenable: activity,
                atlasImage: atlasImg,
                atlasDevicePixelRatio: 1.0,
                directLogicalSize: const Size(120, 60),
                directTerminalBatchProvider: (_, _) => cleanBatch,
                child: const SizedBox(width: 120, height: 60),
              ),
            ),
          ),
        );
        await tester.pump();

        final hostState = tester.state<TerminalShaderHostState>(
          find.byType(TerminalShaderHost),
        );
        expect(hostState.debugIsDirectModeActive, isTrue);
        expect(hostState.debugIsTickerActive, isFalse);
        expect(backend.directSyncRenderCount, greaterThanOrEqualTo(1));
        expect(backend.asyncPassCalls, isEmpty);
        expect(
          tester.getSize(find.byType(TerminalShaderHost)),
          equals(const Size(120, 60)),
        );

        // Idle pump does not re-render; external activity triggers 1 direct sync render.
        final countAfterIdle = backend.directSyncRenderCount;
        await tester.pump(const Duration(milliseconds: 50));
        expect(backend.directSyncRenderCount, equals(countAfterIdle));
        activity.fire();
        await tester.pump();
        expect(backend.directSyncRenderCount, equals(countAfterIdle + 1));

        // 2. Animated foreground-only shader: ticks continuously in direct mode with 0 async captures.
        final animatedFgConfig = TerminalShaderConfig(
          foregroundPasses: <ShaderPassSpec>[
            ShaderPassSpec(
              id: 'fg:anim',
              stage: TerminalShaderStage.foreground,
              customSourcePath: 'anim.glsl',
            ),
          ],
          animationMode: ShaderAnimationMode.always,
        );
        await tester.runAsync(
          () => controller.syncConfig(
            animatedFgConfig,
            sourceLoader: (_) async => _validAnimatedGlsl,
          ),
        );
        await tester.pumpWidget(
          Directionality(
            textDirection: TextDirection.ltr,
            child: Center(
              child: TerminalShaderHost(
                controller: controller,
                config: animatedFgConfig,
                activityListenable: activity,
                atlasImage: atlasImg,
                atlasDevicePixelRatio: 1.0,
                directLogicalSize: const Size(120, 60),
                directTerminalBatchProvider: (_, _) => cleanBatch,
                child: const SizedBox(width: 120, height: 60),
              ),
            ),
          ),
        );
        await tester.pump();

        final beforeTicks = backend.directSyncRenderCount;
        await tester.pump(const Duration(milliseconds: 16));
        await tester.pump(const Duration(milliseconds: 16));
        expect(backend.directSyncRenderCount, greaterThan(beforeTicks));
        expect(backend.asyncPassCalls, isEmpty);
        expect(backend.lastDirectFgPassCount, equals(1));
      },
    );

    testWidgets(
      'primes uncached textures via fallback and recovers automatically on completion',
      (tester) async {
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetDevicePixelRatio);
        final atlasImg = await tester.runAsync(
          () => _createSolidImage(
            width: 32,
            height: 32,
            color: const Color(0xFFFFFFFF),
          ),
        );
        addTearDown(() => atlasImg?.dispose());
        final outputImg = await tester.runAsync(
          () => _createSolidImage(
            width: 100,
            height: 50,
            color: const Color(0xFF00AA55),
          ),
        );
        addTearDown(() => outputImg?.dispose());

        final primeCompleter = Completer<bool>();
        final backend = _FakeDirectShaderBackend(
          syncOutputFactory: () => outputImg!.clone(),
          primedInitially: false,
          prepareFuture: primeCompleter.future,
        );
        final controller = TerminalShaderController(backend: backend);
        addTearDown(controller.dispose);

        final cleanBatch = GpuAtlasQuadBatch(
          instanceData: Float32List(16),
          instanceCount: 1,
          italicStartInstanceIndex: 1,
          kittyInsertInstanceIndex: 1,
          generation: 1,
          defaultBackgroundArgb: 0xFF000000,
          kittyQuads: const <GpuKittyQuad>[],
          hasCanvasOnlyContent: false,
        );

        await tester.pumpWidget(
          Directionality(
            textDirection: TextDirection.ltr,
            child: TerminalShaderHost(
              controller: controller,
              config: TerminalShaderConfig.empty,
              atlasImage: atlasImg,
              atlasDevicePixelRatio: 1.0,
              directLogicalSize: const Size(100, 50),
              directTerminalBatchProvider: (_, _) => cleanBatch,
              child: const SizedBox(
                key: ValueKey<String>('fallback-child'),
                width: 100,
                height: 50,
              ),
            ),
          ),
        );
        // Post-frame fallback mounts while priming is in-flight.
        await tester.pump();
        final hostState = tester.state<TerminalShaderHostState>(
          find.byType(TerminalShaderHost),
        );
        expect(backend.prepareCallCount, equals(1));
        expect(hostState.debugIsDirectModeActive, isFalse);
        expect(
          find.byKey(const ValueKey<String>('fallback-child')),
          findsOneWidget,
        );

        // Completing priming transitions automatically back to direct mode.
        backend.primed = true;
        primeCompleter.complete(true);
        await tester.pump();
        await tester.pump();
        expect(hostState.debugIsDirectModeActive, isTrue);
        expect(backend.directSyncRenderCount, greaterThanOrEqualTo(1));
      },
    );

    testWidgets(
      'falls back cleanly on hasCanvasOnlyContent and DPR mismatch without oscillating, then recovers',
      (tester) async {
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetDevicePixelRatio);
        final atlasImg = await tester.runAsync(
          () => _createSolidImage(
            width: 32,
            height: 32,
            color: const Color(0xFFFFFFFF),
          ),
        );
        addTearDown(() => atlasImg?.dispose());
        final outputImg = await tester.runAsync(
          () => _createSolidImage(
            width: 100,
            height: 50,
            color: const Color(0xFFAA44CC),
          ),
        );
        addTearDown(() => outputImg?.dispose());

        final backend = _FakeDirectShaderBackend(
          syncOutputFactory: () => outputImg!.clone(),
        );
        final controller = TerminalShaderController(backend: backend);
        addTearDown(controller.dispose);
        final activity = _TestPaintNotifier();
        addTearDown(activity.dispose);

        var hasCanvasOnly = true;
        GpuAtlasQuadBatch batchProvider(Size _, double _) => GpuAtlasQuadBatch(
          instanceData: Float32List(16),
          instanceCount: 1,
          italicStartInstanceIndex: 1,
          kittyInsertInstanceIndex: 1,
          generation: 1,
          defaultBackgroundArgb: 0xFF000000,
          kittyQuads: const <GpuKittyQuad>[],
          hasCanvasOnlyContent: hasCanvasOnly,
        );

        Widget buildHost({required double atlasDpr}) => Directionality(
          textDirection: TextDirection.ltr,
          child: TerminalShaderHost(
            controller: controller,
            config: TerminalShaderConfig.empty,
            activityListenable: activity,
            atlasImage: atlasImg,
            atlasDevicePixelRatio: atlasDpr,
            directLogicalSize: const Size(100, 50),
            directTerminalBatchProvider: batchProvider,
            child: const SizedBox(
              key: ValueKey<String>('fallback-child'),
              width: 100,
              height: 50,
            ),
          ),
        );

        await tester.pumpWidget(buildHost(atlasDpr: 1.0));
        await tester.pump();
        final hostState = tester.state<TerminalShaderHostState>(
          find.byType(TerminalShaderHost),
        );
        expect(hostState.debugIsDirectModeActive, isFalse);

        // Activity while still canvas-only must NOT oscillate back to direct mode.
        activity.fire();
        await tester.pump();
        expect(hostState.debugIsDirectModeActive, isFalse);
        expect(backend.directSyncRenderCount, equals(0));

        // Clearing canvas-only content + activity recovers cleanly to direct mode.
        hasCanvasOnly = false;
        activity.fire();
        await tester.pump();
        await tester.pump();
        expect(hostState.debugIsDirectModeActive, isTrue);
        expect(backend.directSyncRenderCount, greaterThanOrEqualTo(1));

        // DPR mismatch falls back and recovers when atlas DPR catches up.
        await tester.pumpWidget(buildHost(atlasDpr: 2.0));
        await tester.pump();
        expect(hostState.debugIsDirectModeActive, isFalse);

        await tester.pumpWidget(buildHost(atlasDpr: 1.0));
        await tester.pump();
        expect(hostState.debugIsDirectModeActive, isTrue);
      },
    );

    testWidgets(
      'TerminalSurface direct GPU integration preserves hit-testing, F12 screenshot, and IME overlay',
      (tester) async {
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetDevicePixelRatio);
        final outputImg = await tester.runAsync(
          () => _createSolidImage(
            width: 160,
            height: 64,
            color: const Color(0xFF112233),
          ),
        );
        addTearDown(() => outputImg?.dispose());

        final atlasController = GlyphAtlasController(
          fontSize: 14.0,
          fontFamily: 'Roboto Mono',
        );
        addTearDown(atlasController.dispose);
        await tester.runAsync(atlasController.ensureInitialized);

        final backend = _FakeDirectShaderBackend(
          syncOutputFactory: () => outputImg!.clone(),
        );
        final shaderController = TerminalShaderController(backend: backend);
        addTearDown(shaderController.dispose);

        final service = _CountingTerminalService();
        final buffer = Buffer(10, 3)
          ..writeString(0, 0, 'hello world', Style.empty);
        final surfaceKey = GlobalKey<TerminalSurfaceState>();
        final selectionController = TerminalSelectionController();

        await tester.pumpWidget(
          Directionality(
            textDirection: TextDirection.ltr,
            child: SizedBox(
              width: 160,
              height: 64,
              child: TerminalSurface(
                key: surfaceKey,
                atlasController: atlasController,
                buffer: buffer,
                cursorPosition: (col: 2, row: 0),
                shaderController: shaderController,
                shaderConfig: TerminalShaderConfig.empty,
                selectionController: selectionController,
                service: service,
                alignment: Alignment.topLeft,
              ),
            ),
          ),
        );
        await tester.pump();

        final hostState = tester.state<TerminalShaderHostState>(
          find.byType(TerminalShaderHost),
        );
        expect(hostState.debugIsDirectModeActive, isTrue);
        expect(backend.directSyncRenderCount, greaterThanOrEqualTo(1));
        expect(backend.asyncPassCalls, isEmpty);
        expect(backend.lastDirectBatch?.instanceCount, greaterThan(0));

        // Pointer drag hit-testing reaches TerminalSurface Listener at exact cell coords.
        final atlas = atlasController.atlas!;
        final hostTopLeft = tester.getTopLeft(find.byType(TerminalShaderHost));
        final p1 =
            hostTopLeft + Offset(atlas.cellWidth * 0.5, atlas.cellHeight * 0.5);
        final p2 = p1 + Offset(atlas.cellWidth * 4.0, 0.0);
        final gesture = await tester.startGesture(
          p1,
          kind: ui.PointerDeviceKind.mouse,
        );
        await tester.pump();
        await gesture.moveTo(p2);
        await tester.pump();
        expect(selectionController.hasSelection, isTrue);
        await gesture.up();
        await tester.pump();

        // F12 screenshot RepaintBoundary still captures cleanly in direct mode.
        await tester.runAsync(() => surfaceKey.currentState!.takeScreenshot());
        expect(
          service.savedNames.any((n) => n.startsWith('screenshot_')),
          isTrue,
        );
      },
    );

    testWidgets(
      'direct GPU runtime error enters fallback without oscillating on reportRuntimeError',
      (tester) async {
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetDevicePixelRatio);
        final atlasImg = await tester.runAsync(
          () => _createSolidImage(
            width: 32,
            height: 32,
            color: const Color(0xFFFFFFFF),
          ),
        );
        addTearDown(() => atlasImg?.dispose());
        final outputImg = await tester.runAsync(
          () => _createSolidImage(
            width: 100,
            height: 50,
            color: const Color(0xFF00AA55),
          ),
        );
        addTearDown(() => outputImg?.dispose());

        final backend = _FakeDirectShaderBackend(
          syncOutputFactory: () => outputImg!.clone(),
          directRenderError: Exception('Unsupported GpuSurface pixel format.'),
        );
        final controller = TerminalShaderController(backend: backend);
        addTearDown(controller.dispose);
        final activity = _TestPaintNotifier();
        addTearDown(activity.dispose);

        final cleanBatch = GpuAtlasQuadBatch(
          instanceData: Float32List(16),
          instanceCount: 1,
          italicStartInstanceIndex: 1,
          kittyInsertInstanceIndex: 1,
          generation: 1,
          defaultBackgroundArgb: 0xFF000000,
          kittyQuads: const <GpuKittyQuad>[],
          hasCanvasOnlyContent: false,
        );

        await tester.pumpWidget(
          Directionality(
            textDirection: TextDirection.ltr,
            child: TerminalShaderHost(
              controller: controller,
              config: TerminalShaderConfig.empty,
              activityListenable: activity,
              atlasImage: atlasImg,
              atlasDevicePixelRatio: 1.0,
              directLogicalSize: const Size(100, 50),
              directTerminalBatchProvider: (_, _) => cleanBatch,
              child: const SizedBox(
                key: ValueKey<String>('fallback-child'),
                width: 100,
                height: 50,
              ),
            ),
          ),
        );
        await tester.pump();

        final hostState = tester.state<TerminalShaderHostState>(
          find.byType(TerminalShaderHost),
        );
        expect(controller.lastCompileError?.message, contains('Unsupported'));
        expect(hostState.debugIsDirectModeActive, isFalse);
        expect(
          find.byKey(const ValueKey<String>('fallback-child')),
          findsOneWidget,
        );

        // Subsequent activity must stay in fallback (no direct retry flicker).
        final failedCalls = backend.directSyncAttemptCount;
        activity.fire();
        await tester.pump();
        activity.fire();
        await tester.pump();
        expect(hostState.debugIsDirectModeActive, isFalse);
        expect(backend.directSyncAttemptCount, equals(failedCalls));
      },
    );

    testWidgets(
      'TerminalShaderUniforms.raw preserves palette identity across frames, explicit maxAmbientFps decimates 240 Hz ticks, and ambientTicksPaused pauses/resumes ticker',
      (tester) async {
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetDevicePixelRatio);
        final atlasImg = await tester.runAsync(
          () => _createSolidImage(width: 8, height: 8),
        );
        addTearDown(() => atlasImg?.dispose());
        final outputImg = await tester.runAsync(
          () => _createSolidImage(width: 120, height: 60),
        );
        addTearDown(() => outputImg?.dispose());

        final backend = _FakeDirectShaderBackend(
          syncOutputFactory: () => outputImg!.clone(),
        );
        final controller = TerminalShaderController(backend: backend);
        addTearDown(controller.dispose);

        final palette = Uint32List(256);
        for (var i = 0; i < 256; i++) {
          palette[i] = 0xFF000000 | (i << 16) | (i << 8) | i;
        }
        final config = TerminalShaderConfig(
          animationMode: ShaderAnimationMode.always,
          foregroundPasses: <ShaderPassSpec>[
            ShaderPassSpec(
              id: 'fg:anim',
              stage: TerminalShaderStage.foreground,
              customSourcePath: 'anim.glsl',
            ),
          ],
        );
        await tester.runAsync(
          () => controller.syncConfig(
            config,
            sourceLoader: (_) async => _validAnimatedGlsl,
          ),
        );
        final cleanBatch = GpuAtlasQuadBatch(
          instanceData: Float32List(16),
          instanceCount: 1,
          italicStartInstanceIndex: 1,
          kittyInsertInstanceIndex: 1,
          generation: 1,
          defaultBackgroundArgb: 0xFF000000,
          kittyQuads: const <GpuKittyQuad>[],
          hasCanvasOnlyContent: false,
        );

        await tester.pumpWidget(
          Directionality(
            textDirection: TextDirection.ltr,
            child: Center(
              child: TerminalShaderHost(
                controller: controller,
                config: config,
                paneKey: 'pane-1',
                palette256Argb: palette,
                maxAmbientFps: 120.0,
                atlasImage: atlasImg,
                atlasDevicePixelRatio: 1.0,
                directLogicalSize: const Size(120, 60),
                directTerminalBatchProvider: (_, _) => cleanBatch,
                child: const SizedBox(width: 120, height: 60),
              ),
            ),
          ),
        );
        await tester.pump();

        final hostState = tester.state<TerminalShaderHostState>(
          find.byType(TerminalShaderHost),
        );
        expect(hostState.debugIsDirectModeActive, isTrue);
        expect(hostState.debugIsTickerActive, isTrue);
        expect(backend.lastDirectBatch?.paneKey, equals('pane-1'));

        // H4: Uniform palette preserves exact reference for pre-pack cache hits.
        expect(
          identical(backend.lastDirectFgUniforms?.palette256Argb, palette),
          isTrue,
        );

        // H5: 240 Hz (4 ms) ticks are decimated when maxAmbientFps: 120.0 is set.
        // Prime first tick so _lastTickElapsed is initialized.
        await tester.pump(const Duration(milliseconds: 10));
        final callsBefore = backend.directSyncRenderCount;
        await tester.pump(const Duration(milliseconds: 4));
        await tester.pump(const Duration(milliseconds: 4));
        await tester.pump(const Duration(milliseconds: 4));
        await tester.pump(const Duration(milliseconds: 4));
        final callsAfter240Hz = backend.directSyncRenderCount - callsBefore;
        // 4 ticks at 4 ms (16 ms total) capped at 120 FPS -> 2 renders, not 4.
        expect(callsAfter240Hz, equals(2));
        expect(
          identical(backend.lastDirectFgUniforms?.palette256Argb, palette),
          isTrue,
        );

        // Default maxAmbientFps (null) locks to full 240 Hz without decimating.
        await tester.pumpWidget(
          Directionality(
            textDirection: TextDirection.ltr,
            child: Center(
              child: TerminalShaderHost(
                controller: controller,
                config: config,
                paneKey: 'pane-1',
                palette256Argb: palette,
                atlasImage: atlasImg,
                atlasDevicePixelRatio: 1.0,
                directLogicalSize: const Size(120, 60),
                directTerminalBatchProvider: (_, _) => cleanBatch,
                child: const SizedBox(width: 120, height: 60),
              ),
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 10));
        final uncappedBefore = backend.directSyncRenderCount;
        await tester.pump(const Duration(milliseconds: 4));
        await tester.pump(const Duration(milliseconds: 4));
        await tester.pump(const Duration(milliseconds: 4));
        await tester.pump(const Duration(milliseconds: 4));
        expect(backend.directSyncRenderCount - uncappedBefore, equals(4));

        // H5: Pausing ambient ticks (e.g. Win32 WM_ENTERSIZEMOVE) stops ticker.
        controller.setAmbientTicksPaused(true);
        await tester.pump();
        expect(hostState.debugIsTickerActive, isFalse);
        final callsWhilePaused = backend.directSyncRenderCount;
        await tester.pump(const Duration(milliseconds: 20));
        await tester.pump(const Duration(milliseconds: 20));
        expect(backend.directSyncRenderCount, equals(callsWhilePaused));

        // Resuming (WM_EXITSIZEMOVE) restarts ticker cleanly.
        controller.setAmbientTicksPaused(false);
        await tester.pump();
        expect(hostState.debugIsTickerActive, isTrue);
        await tester.pump(const Duration(milliseconds: 16));
        expect(backend.directSyncRenderCount, greaterThan(callsWhilePaused));
      },
    );

    testWidgets(
      'elides cursorGlow foreground pass and pauses ticker when cursorVisibleProvider returns false',
      (tester) async {
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetDevicePixelRatio);
        final atlasImg = await tester.runAsync(
          () => _createSolidImage(width: 8, height: 8),
        );
        addTearDown(() => atlasImg?.dispose());
        final outputImg = await tester.runAsync(
          () => _createSolidImage(width: 120, height: 60),
        );
        addTearDown(() => outputImg?.dispose());

        final backend = _FakeDirectShaderBackend(
          syncOutputFactory: () => outputImg!.clone(),
        );
        final controller = TerminalShaderController(backend: backend);
        addTearDown(controller.dispose);
        final activity = _TestPaintNotifier();
        addTearDown(activity.dispose);

        final config = TerminalShaderConfig(
          animationMode: ShaderAnimationMode.always,
          foregroundPasses: <ShaderPassSpec>[
            ShaderPassSpec(
              id: 'fg:cursor_glow',
              stage: TerminalShaderStage.foreground,
              preset: TerminalShaderPreset.cursorGlow,
            ),
          ],
        );
        await tester.runAsync(() => controller.syncConfig(config));
        final cleanBatch = GpuAtlasQuadBatch(
          instanceData: Float32List(16),
          instanceCount: 1,
          italicStartInstanceIndex: 1,
          kittyInsertInstanceIndex: 1,
          generation: 1,
          defaultBackgroundArgb: 0xFF000000,
          kittyQuads: const <GpuKittyQuad>[],
          hasCanvasOnlyContent: false,
        );

        var cursorVisible = false;
        await tester.pumpWidget(
          Directionality(
            textDirection: TextDirection.ltr,
            child: Center(
              child: TerminalShaderHost(
                controller: controller,
                config: config,
                cursorVisibleProvider: () => cursorVisible,
                activityListenable: activity,
                atlasImage: atlasImg,
                atlasDevicePixelRatio: 1.0,
                directLogicalSize: const Size(120, 60),
                directTerminalBatchProvider: (_, _) => cleanBatch,
                child: const SizedBox(width: 120, height: 60),
              ),
            ),
          ),
        );
        await tester.pump();

        final hostState = tester.state<TerminalShaderHostState>(
          find.byType(TerminalShaderHost),
        );
        expect(hostState.debugIsDirectModeActive, isTrue);
        expect(backend.lastDirectFgPassCount, equals(0));
        expect(hostState.debugIsTickerActive, isFalse);

        // Showing the cursor immediately re-enables cursorGlow and ticker.
        cursorVisible = true;
        activity.fire();
        await tester.pump();
        expect(backend.lastDirectFgPassCount, equals(1));
        expect(hostState.debugIsTickerActive, isTrue);

        // Hiding the cursor elides cursorGlow again and stops wasted ticks.
        cursorVisible = false;
        activity.fire();
        await tester.pump();
        expect(backend.lastDirectFgPassCount, equals(0));
        expect(hostState.debugIsTickerActive, isFalse);
      },
    );

    test('packAlignedUniformBatch reuses scratchBuffer, skips redundant 4 KiB palette copies via scratchPalettes, and fireGlsl uses ALU hash with hoisted FBM', () {
      final paletteA = Uint32List(256);
      final paletteB = Uint32List(256);
      for (var i = 0; i < 256; i++) {
        paletteA[i] = 0xFF112233;
        paletteB[i] = 0xFFCC8844;
      }
      final uniformsA = TerminalShaderUniforms.raw(
        width: 100.0,
        height: 50.0,
        palette256Argb: paletteA,
      );
      expect(identical(uniformsA.palette256Argb, paletteA), isTrue);

      final scratch = ByteData(ShadertoyGlslShim.uniformBufferByteLength * 2);
      final scratchPalettes = <Uint32List?>[];
      final packed1 = packAlignedUniformBatch(
        <TerminalShaderUniforms>[uniformsA],
        minimumUniformByteAlignment: 256,
        scratchBuffer: scratch,
        scratchPalettes: scratchPalettes,
      );
      expect(packed1.data.lengthInBytes, equals(packed1.alignedStride));
      expect(
        packed1.data.getFloat32(128, Endian.little),
        closeTo(0x11 / 255.0, 1e-4),
      );

      // Sentinel byte inside iPalette stays intact on identical palette reuse.
      scratch.setFloat32(128, 0.99, Endian.little);
      final packed2 = packAlignedUniformBatch(
        <TerminalShaderUniforms>[uniformsA],
        minimumUniformByteAlignment: 256,
        scratchBuffer: scratch,
        scratchPalettes: scratchPalettes,
      );
      expect(packed2.data.getFloat32(128, Endian.little), closeTo(0.99, 1e-4));

      // Switching to a new palette reference immediately rewrites iPalette.
      final uniformsB = TerminalShaderUniforms.raw(
        width: 100.0,
        height: 50.0,
        palette256Argb: paletteB,
      );
      final packed3 = packAlignedUniformBatch(
        <TerminalShaderUniforms>[uniformsB],
        minimumUniformByteAlignment: 256,
        scratchBuffer: scratch,
        scratchPalettes: scratchPalettes,
      );
      expect(
        packed3.data.getFloat32(128, Endian.little),
        closeTo(0xCC / 255.0, 1e-4),
      );

      // H3: fireGlsl uses ALU fract hash (no sin() calls) and analyzes cleanly.
      expect(ShaderRegionPresets.fireGlsl.contains('sin('), isFalse);
      final analysis = ShadertoyGlslShim.analyze(
        ShaderRegionPresets.fireGlsl,
        shaderId: 'fire',
      );
      expect(analysis.usesTime, isTrue);
    });
  });

  group('ShaderPerfTrace instrumentation', () {
    testWidgets(
      'captures TerminalSurface.stageDirectBatch, TerminalShaderHost.renderDirect, and staticHit/staticMiss counters when enabled',
      (tester) async {
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(() async {
          if (ShaderPerfTrace.isEnabled) {
            ShaderPerfTrace.stop();
          }
          if (Tracer.isEnabled) {
            await Tracer.stop();
          }
        });

        final outputImg = await tester.runAsync(
          () => _createSolidImage(
            width: 160,
            height: 64,
            color: const Color(0xFF112233),
          ),
        );
        addTearDown(() => outputImg?.dispose());

        final atlasController = GlyphAtlasController(
          fontSize: 14.0,
          fontFamily: 'Roboto Mono',
        );
        addTearDown(atlasController.dispose);
        await tester.runAsync(atlasController.ensureInitialized);

        final backend = _FakeDirectShaderBackend(
          syncOutputFactory: () => outputImg!.clone(),
        );
        final shaderController = TerminalShaderController(backend: backend);
        addTearDown(shaderController.dispose);

        final animatedConfig = TerminalShaderConfig(
          foregroundPasses: <ShaderPassSpec>[
            ShaderPassSpec(
              id: 'fg:anim',
              stage: TerminalShaderStage.foreground,
              customSourcePath: 'anim.glsl',
            ),
          ],
          animationMode: ShaderAnimationMode.always,
        );
        await tester.runAsync(
          () => shaderController.syncConfig(
            animatedConfig,
            sourceLoader: (_) async => _validAnimatedGlsl,
          ),
        );

        final buffer = Buffer(10, 3)
          ..writeString(0, 0, 'perf trace', Style.empty);

        late MemoryTracerSink memSink;
        Tracer.activeCategories = <TraceCategory>{...TraceCategory.values};
        await tester.runAsync(
          () => Tracer.startWithSink((baseEpochUs) {
            memSink = MemoryTracerSink(baseEpochUs: baseEpochUs);
            return memSink;
          }),
        );
        ShaderPerfTrace.start(mirrorToTimeline: false);

        await tester.pumpWidget(
          Directionality(
            textDirection: TextDirection.ltr,
            child: SizedBox(
              width: 160,
              height: 64,
              child: TerminalSurface(
                atlasController: atlasController,
                buffer: buffer,
                shaderController: shaderController,
                shaderConfig: animatedConfig,
                alignment: Alignment.topLeft,
              ),
            ),
          ),
        );
        // Initial frame misses static batch cache; subsequent animated tick hits it.
        await tester.pump(const Duration(milliseconds: 16));
        await tester.pump(const Duration(milliseconds: 16));

        final summary = ShaderPerfTrace.stop();
        await tester.runAsync(Tracer.stop);

        expect(
          summary.phases['TerminalShaderHost.renderDirect']?.count,
          greaterThanOrEqualTo(2),
        );
        expect(
          summary.phases['TerminalSurface.stageDirectBatch']?.count,
          greaterThanOrEqualTo(2),
        );
        expect(
          summary.totals['TerminalSurface.staticMiss'],
          greaterThanOrEqualTo(1),
        );
        expect(
          summary.totals['TerminalSurface.staticHit'],
          greaterThanOrEqualTo(1),
        );
        expect(memSink.eventCount, greaterThan(0));
      },
    );

    testWidgets(
      'captures TerminalShaderHost.renderBackground and TerminalShaderHost.foregroundPipeline when enabled',
      (tester) async {
        addTearDown(() {
          if (ShaderPerfTrace.isEnabled) {
            ShaderPerfTrace.stop();
          }
        });

        final bgImage = await tester.runAsync(
          () => _createSolidImage(
            width: 64,
            height: 48,
            color: const Color(0xFF223344),
          ),
        );
        final backend = _FakeShaderBackend()..nextSyncImage = bgImage;
        final controller = TerminalShaderController(backend: backend);
        addTearDown(controller.dispose);

        final config = TerminalShaderConfig(
          backgroundPasses: <ShaderPassSpec>[
            ShaderPassSpec(
              id: 'bg:static',
              stage: TerminalShaderStage.background,
              inlineGlsl: _validStaticGlsl,
            ),
          ],
          foregroundPasses: <ShaderPassSpec>[
            ShaderPassSpec(
              id: 'fg:static',
              stage: TerminalShaderStage.foreground,
              inlineGlsl: _validStaticGlsl,
            ),
          ],
          animationMode: ShaderAnimationMode.staticOnly,
        );
        await tester.runAsync(() => controller.syncConfig(config));

        ShaderPerfTrace.start(mirrorToTimeline: false);

        await tester.pumpWidget(
          Directionality(
            textDirection: TextDirection.ltr,
            child: SizedBox(
              width: 64,
              height: 48,
              child: TerminalShaderHost(
                controller: controller,
                config: config,
                child: const ColoredBox(color: Color(0xFF102030)),
              ),
            ),
          ),
        );
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));
        await tester.pump();
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));

        final summary = ShaderPerfTrace.stop();

        expect(
          summary.phases['TerminalShaderHost.renderBackground']?.count,
          greaterThanOrEqualTo(1),
        );
        expect(
          summary.phases['TerminalShaderHost.foregroundPipeline']?.count,
          greaterThanOrEqualTo(1),
        );
      },
    );

    testWidgets(
      'records zero spans, counters, or Tracer events when ShaderPerfTrace is disabled',
      (tester) async {
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(() async {
          if (ShaderPerfTrace.isEnabled) {
            ShaderPerfTrace.stop();
          }
          if (Tracer.isEnabled) {
            await Tracer.stop();
          }
        });

        final outputImg = await tester.runAsync(
          () => _createSolidImage(
            width: 160,
            height: 64,
            color: const Color(0xFF112233),
          ),
        );
        addTearDown(() => outputImg?.dispose());

        final atlasController = GlyphAtlasController(
          fontSize: 14.0,
          fontFamily: 'Roboto Mono',
        );
        addTearDown(atlasController.dispose);
        await tester.runAsync(atlasController.ensureInitialized);

        final backend = _FakeDirectShaderBackend(
          syncOutputFactory: () => outputImg!.clone(),
        );
        final shaderController = TerminalShaderController(backend: backend);
        addTearDown(shaderController.dispose);

        final animatedConfig = TerminalShaderConfig(
          foregroundPasses: <ShaderPassSpec>[
            ShaderPassSpec(
              id: 'fg:anim',
              stage: TerminalShaderStage.foreground,
              customSourcePath: 'anim.glsl',
            ),
          ],
          animationMode: ShaderAnimationMode.always,
        );
        await tester.runAsync(
          () => shaderController.syncConfig(
            animatedConfig,
            sourceLoader: (_) async => _validAnimatedGlsl,
          ),
        );

        final buffer = Buffer(10, 3)
          ..writeString(0, 0, 'disabled trace', Style.empty);

        late MemoryTracerSink memSink;
        Tracer.activeCategories = <TraceCategory>{...TraceCategory.values};
        await tester.runAsync(
          () => Tracer.startWithSink((baseEpochUs) {
            memSink = MemoryTracerSink(baseEpochUs: baseEpochUs);
            return memSink;
          }),
        );
        expect(ShaderPerfTrace.isEnabled, isFalse);

        await tester.pumpWidget(
          Directionality(
            textDirection: TextDirection.ltr,
            child: SizedBox(
              width: 160,
              height: 64,
              child: TerminalSurface(
                atlasController: atlasController,
                buffer: buffer,
                shaderController: shaderController,
                shaderConfig: animatedConfig,
                alignment: Alignment.topLeft,
              ),
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 16));
        await tester.pump(const Duration(milliseconds: 16));

        expect(backend.directSyncRenderCount, greaterThanOrEqualTo(2));
        await tester.runAsync(Tracer.stop);
        final summary = ShaderPerfTrace.stop();

        expect(memSink.eventCount, equals(0));
        expect(summary.phases, isEmpty);
        expect(summary.lastCounters, isEmpty);
        expect(summary.totals, isEmpty);
      },
    );

    testWidgets(
      'backpressure skip holds direct bridge image without re-priming or entering fallback',
      (tester) async {
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetDevicePixelRatio);
        final atlasImg = await tester.runAsync(
          () => _createSolidImage(
            width: 32,
            height: 32,
            color: const Color(0xFFFFFFFF),
          ),
        );
        final outputImg = await tester.runAsync(
          () => _createSolidImage(
            width: 100,
            height: 50,
            color: const Color(0xFF112233),
          ),
        );
        addTearDown(() {
          atlasImg?.dispose();
          outputImg?.dispose();
        });

        final backend = _FakeDirectShaderBackend(
          syncOutputFactory: () => outputImg!.clone(),
        );
        final controller = TerminalShaderController(backend: backend);
        addTearDown(controller.dispose);
        final activity = _TestPaintNotifier();
        addTearDown(activity.dispose);

        await tester.pumpWidget(
          Directionality(
            textDirection: TextDirection.ltr,
            child: TerminalShaderHost(
              controller: controller,
              config: TerminalShaderConfig.empty,
              activityListenable: activity,
              atlasImage: atlasImg,
              atlasDevicePixelRatio: 1.0,
              directLogicalSize: const Size(100, 50),
              directTerminalBatchProvider: (_, _) => GpuAtlasQuadBatch(
                instanceData: Float32List(16),
                instanceCount: 1,
                italicStartInstanceIndex: 1,
                kittyInsertInstanceIndex: 1,
                generation: 1,
                defaultBackgroundArgb: 0xFF000000,
                kittyQuads: const <GpuKittyQuad>[],
                hasCanvasOnlyContent: false,
              ),
              child: const SizedBox(width: 100, height: 50),
            ),
          ),
        );
        await tester.pump();
        final hostState = tester.state<TerminalShaderHostState>(
          find.byType(TerminalShaderHost),
        );
        expect(hostState.debugIsDirectModeActive, isTrue);
        expect(backend.directSyncRenderCount, greaterThanOrEqualTo(1));
        expect(backend.prepareCallCount, equals(0));

        // Simulate backpressure skip on the next frame: host must stay in
        // direct mode without calling prepareDirectResources or async fallback.
        backend.simulateBackpressureSkip = true;
        activity.fire();
        await tester.pump();
        await tester.pump();

        expect(hostState.debugIsDirectModeActive, isTrue);
        expect(backend.prepareCallCount, equals(0));
        expect(backend.asyncPassCalls, isEmpty);
      },
    );
  });

  group('Live iMouse propagation and zero-overhead guard', () {
    const mouseFgGlsl = '''
void mainImage(out vec4 fragColor, in vec2 fragCoord) {
  vec4 base = texture(iChannel0, fragCoord / iResolution.xy);
  float d = length(fragCoord - iMouse.xy);
  fragColor = vec4(base.rgb + vec3(step(d, 10.0) * 0.1), base.a);
}
''';

    testWidgets(
      'TerminalSurface propagates live Y-up iMouse to full-pane and region-local shaders without widget rebuilds',
      (tester) async {
        tester.view.devicePixelRatio = 2.0;
        addTearDown(tester.view.resetDevicePixelRatio);

        final outputImg = await tester.runAsync(
          () => _createSolidImage(
            width: 320,
            height: 160,
            color: const Color(0xFF101820),
          ),
        );
        addTearDown(() => outputImg?.dispose());

        final atlasController = GlyphAtlasController(
          fontSize: 13.0,
          fontFamily: 'Roboto Mono',
          devicePixelRatio: 2.0,
        );
        addTearDown(atlasController.dispose);
        await tester.runAsync(atlasController.ensureInitialized);
        final atlas = atlasController.atlas!;

        final backend = _FakeDirectShaderBackend(
          syncOutputFactory: () => outputImg!.clone(),
        );
        final shaderController = TerminalShaderController(backend: backend);
        addTearDown(shaderController.dispose);

        final config = TerminalShaderConfig(
          foregroundPasses: <ShaderPassSpec>[
            ShaderPassSpec(
              id: 'fg:mouse',
              stage: TerminalShaderStage.foreground,
              inlineGlsl: mouseFgGlsl,
            ),
          ],
          animationMode: ShaderAnimationMode.staticOnly,
        );
        await tester.runAsync(() => shaderController.syncConfig(config));

        final buffer = Buffer(20, 6)
          ..writeString(4, 2, 'ONE RING', Style.empty)
          ..addShaderRegion(
            ShaderRegion(
              id: 'ring',
              shaderId: 'one_ring',
              sourceRects: const <tui_geo.Rect>[tui_geo.Rect(4, 2, 8, 1)],
              padding: const CellPadding(top: 1, right: 1, bottom: 1, left: 1),
            ),
          );

        final paneWidth = 20 * atlas.cellWidth;
        final paneHeight = 6 * atlas.cellHeight;
        await tester.pumpWidget(
          Directionality(
            textDirection: TextDirection.ltr,
            child: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: paneWidth,
                height: paneHeight,
                child: TerminalSurface(
                  atlasController: atlasController,
                  buffer: buffer,
                  shaderController: shaderController,
                  shaderConfig: config,
                  alignment: Alignment.topLeft,
                ),
              ),
            ),
          ),
        );
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));
        await tester.pump();

        expect(backend.lastDirectFgUniforms, isNotNull);
        expect(
          backend.lastDirectFgUniforms!.mouseXyzw,
          equals(<double>[0.0, 0.0, 0.0, 0.0]),
        );

        final surfaceState = tester.state<TerminalSurfaceState>(
          find.byType(TerminalSurface),
        );
        await tester.runAsync(
          () => surfaceState.cliShaderRegistry.ensureRegionShaderCompiled(
            buffer.shaderRegions.single,
          ),
        );
        await tester.pump();

        final topLeft = tester.getTopLeft(find.byType(TerminalSurface));
        final regionLeftLogical = 3 * atlas.cellWidth;
        final regionTopLogical = 1 * atlas.cellHeight;
        final downLogical = Offset(
          regionLeftLogical + 12.0,
          regionTopLogical + 8.0,
        );
        final moveLogical = Offset(
          regionLeftLogical + 24.0,
          regionTopLogical + 14.0,
        );

        final gesture = await tester.startGesture(topLeft + downLogical);
        await tester.pump();

        final physH = paneHeight * 2.0;
        final fgDown = backend.lastDirectFgUniforms!.mouseXyzw;
        expect(fgDown[0], closeTo(downLogical.dx * 2.0, 0.5));
        expect(fgDown[1], closeTo(physH - downLogical.dy * 2.0, 0.5));
        expect(fgDown[2], greaterThan(0.0));
        expect(fgDown[3], greaterThan(0.0));

        // Drag inside region: region-local iMouse must be shifted into region FBO coords.
        await gesture.moveTo(topLeft + moveLogical);
        await tester.pump();

        final regionPasses = backend.lastDirectBatch!.regionPasses;
        expect(regionPasses, hasLength(1));
        final regionPass = regionPasses.single;
        final regRect = regionPass.outputRectPhysical;
        final regMouse = regionPass.uniforms.mouseXyzw;
        final expectedRegX = moveLogical.dx * 2.0 - regRect.left;
        final expectedRegY =
            regRect.height - (moveLogical.dy * 2.0 - regRect.top);
        expect(regMouse[0], closeTo(expectedRegX, 0.5));
        expect(regMouse[1], closeTo(expectedRegY, 0.5));
        expect(regMouse[2], greaterThan(0.0));
        expect(regMouse[3], greaterThan(0.0));

        // Release pointer: click sign flips negative for both pane and region.
        await gesture.up();
        await tester.pump();
        expect(backend.lastDirectFgUniforms!.mouseXyzw[2], lessThan(0.0));
        expect(
          backend.lastDirectBatch!.regionPasses.single.uniforms.mouseXyzw[2],
          lessThan(0.0),
        );
      },
    );

    testWidgets(
      'pointer hover/move causes zero extra shader renders when no active shader uses iMouse',
      (tester) async {
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetDevicePixelRatio);

        final outputImg = await tester.runAsync(
          () => _createSolidImage(
            width: 160,
            height: 80,
            color: const Color(0xFF101820),
          ),
        );
        addTearDown(() => outputImg?.dispose());

        final atlasController = GlyphAtlasController(
          fontSize: 13.0,
          fontFamily: 'Roboto Mono',
        );
        addTearDown(atlasController.dispose);
        await tester.runAsync(atlasController.ensureInitialized);
        final atlas = atlasController.atlas!;

        final backend = _FakeDirectShaderBackend(
          syncOutputFactory: () => outputImg!.clone(),
        );
        final shaderController = TerminalShaderController(backend: backend);
        addTearDown(shaderController.dispose);

        final config = TerminalShaderConfig(
          foregroundPasses: <ShaderPassSpec>[
            ShaderPassSpec(
              id: 'fg:retro',
              stage: TerminalShaderStage.foreground,
              preset: TerminalShaderPreset.retroPhosphor,
            ),
          ],
          animationMode: ShaderAnimationMode.staticOnly,
        );
        await tester.runAsync(() => shaderController.syncConfig(config));

        final buffer = Buffer(16, 4)
          ..writeString(0, 0, 'no mouse overhead', Style.empty);

        await tester.pumpWidget(
          Directionality(
            textDirection: TextDirection.ltr,
            child: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: 16 * atlas.cellWidth,
                height: 4 * atlas.cellHeight,
                child: TerminalSurface(
                  atlasController: atlasController,
                  buffer: buffer,
                  shaderController: shaderController,
                  shaderConfig: config,
                  alignment: Alignment.topLeft,
                ),
              ),
            ),
          ),
        );
        await tester.pump();

        final initialRenderCount = backend.directSyncRenderCount;
        expect(initialRenderCount, greaterThanOrEqualTo(1));

        final topLeft = tester.getTopLeft(find.byType(TerminalSurface));
        final hover = await tester.createGesture(
          kind: ui.PointerDeviceKind.mouse,
        );
        await hover.addPointer(location: topLeft + const Offset(10, 10));
        await tester.pump();
        await hover.moveTo(topLeft + const Offset(40, 20));
        await tester.pump();
        await hover.moveTo(topLeft + const Offset(80, 30));
        await tester.pump();
        await hover.removePointer();

        expect(backend.directSyncRenderCount, equals(initialRenderCount));
      },
    );
  });

  group('M2 & M4 regression proofs: background elision, activity dirtying, and stale async outputs', () {
    testWidgets(
      'M2a: eliding background cursorGlow pass clears stale background output image',
      (tester) async {
        final backend = _FakeShaderBackend(supportsSyncBackground: true);
        final controller = TerminalShaderController(backend: backend);
        addTearDown(controller.dispose);
        final activity = _ManualNotifier();
        addTearDown(activity.dispose);

        final bgConfig = TerminalShaderConfig(
          backgroundPasses: <ShaderPassSpec>[
            ShaderPassSpec(
              id: 'bg:cursor_glow',
              stage: TerminalShaderStage.background,
              preset: TerminalShaderPreset.cursorGlow,
            ),
          ],
          animationMode: ShaderAnimationMode.staticOnly,
        );
        await tester.runAsync(() => controller.syncConfig(bgConfig));

        final bgImg = await tester.runAsync(
          () => _createSolidImage(
            width: 64,
            height: 48,
            color: const Color(0xFFFF0000),
          ),
        );
        backend.nextSyncImage = bgImg;

        var cursorVisible = true;
        final boundaryKey = GlobalKey();
        await tester.pumpWidget(
          Directionality(
            textDirection: TextDirection.ltr,
            child: RepaintBoundary(
              key: boundaryKey,
              child: ColoredBox(
                color: const Color(0xFF0000FF),
                child: SizedBox(
                  width: 64,
                  height: 48,
                  child: TerminalShaderHost(
                    controller: controller,
                    config: bgConfig,
                    cursorVisibleProvider: () => cursorVisible,
                    activityListenable: activity,
                    child: const SizedBox.expand(),
                  ),
                ),
              ),
            ),
          ),
        );

        expect(backend.syncBackgroundCalls, hasLength(1));
        expect(bgImg!.debugDisposed, isFalse);

        // Verify red background shader image was painted while cursor visible.
        final beforeBoundary =
            boundaryKey.currentContext!.findRenderObject()!
                as RenderRepaintBoundary;
        final beforeSnap = await tester.runAsync(
          () => beforeBoundary.toImage(pixelRatio: 1.0),
        );
        final beforePx = await tester.runAsync(
          () => _readPixel(beforeSnap!, 8, 8),
        );
        beforeSnap!.dispose();
        expect(beforePx!.r, greaterThan(200));
        expect(beforePx.b, lessThan(50));

        // Flip cursor invisible -> cursorGlow pass is elided -> stale red
        // background output image must be cleared and disposed post-frame.
        cursorVisible = false;
        activity.trigger();
        await tester.pump();
        await tester.pump();

        final afterSnap = await tester.runAsync(
          () => beforeBoundary.toImage(pixelRatio: 1.0),
        );
        final afterPx = await tester.runAsync(
          () => _readPixel(afterSnap!, 8, 8),
        );
        afterSnap!.dispose();
        expect(
          afterPx!.b,
          greaterThan(200),
          reason:
              'Elided background pass must not keep painting stale red image.',
        );
        expect(
          bgImg.debugDisposed,
          isTrue,
          reason:
              'Cleared background output image must be disposed post-frame.',
        );
      },
    );

    testWidgets(
      'M2b: activityListenable marks async background pass dirty and triggers refresh',
      (tester) async {
        final backend = _FakeShaderBackend(supportsSyncBackground: false);
        final controller = TerminalShaderController(backend: backend);
        addTearDown(controller.dispose);
        final activity = _ManualNotifier();
        addTearDown(activity.dispose);

        final bgConfig = TerminalShaderConfig(
          backgroundPasses: <ShaderPassSpec>[
            ShaderPassSpec(
              id: 'bg:cursor_glow',
              stage: TerminalShaderStage.background,
              preset: TerminalShaderPreset.cursorGlow,
            ),
          ],
          animationMode: ShaderAnimationMode.staticOnly,
        );
        await tester.runAsync(() => controller.syncConfig(bgConfig));

        await tester.pumpWidget(
          Directionality(
            textDirection: TextDirection.ltr,
            child: SizedBox(
              width: 64,
              height: 48,
              child: TerminalShaderHost(
                controller: controller,
                config: bgConfig,
                activityListenable: activity,
                child: const SizedBox.expand(),
              ),
            ),
          ),
        );
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));
        await tester.pump();
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));

        final callsAfterInitial = backend.asyncPassCalls.length;
        expect(callsAfterInitial, equals(1));

        // Firing activityListenable must mark _backgroundDirty = true so the
        // async background backend schedules a fresh render pass.
        activity.trigger();
        await tester.pump();
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));
        await tester.pump();

        expect(
          backend.asyncPassCalls.length,
          greaterThan(callsAfterInitial),
          reason:
              'activityListenable must trigger async background refresh when '
              'supportsSyncBackground is false.',
        );
      },
    );

    testWidgets(
      'M4a: in-flight async background output is disposed if passes are disabled before completion',
      (tester) async {
        final backend = _FakeShaderBackend(supportsSyncBackground: false)
          ..holdAsyncRender = true;
        final controller = TerminalShaderController(backend: backend);
        addTearDown(controller.dispose);

        final bgConfig = TerminalShaderConfig(
          backgroundPasses: <ShaderPassSpec>[
            ShaderPassSpec(
              id: 'bg:wave',
              stage: TerminalShaderStage.background,
              preset: TerminalShaderPreset.wallpaperWave,
            ),
          ],
          animationMode: ShaderAnimationMode.staticOnly,
        );
        await tester.runAsync(() => controller.syncConfig(bgConfig));

        Widget buildHost(TerminalShaderConfig config) => Directionality(
          textDirection: TextDirection.ltr,
          child: SizedBox(
            width: 64,
            height: 48,
            child: TerminalShaderHost(
              controller: controller,
              config: config,
              child: const SizedBox.expand(),
            ),
          ),
        );

        await tester.pumpWidget(buildHost(bgConfig));
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));
        await tester.pump();

        expect(backend.pendingAsyncCompleters, hasLength(1));

        // Disable background passes while renderPassesAsync is in flight.
        await tester.runAsync(
          () => controller.syncConfig(TerminalShaderConfig.empty),
        );
        await tester.pumpWidget(buildHost(TerminalShaderConfig.empty));

        final staleBgImg = await tester.runAsync(
          () => _createSolidImage(width: 64, height: 48),
        );
        backend.pendingAsyncCompleters.single.complete(staleBgImg);
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));

        expect(
          staleBgImg!.debugDisposed,
          isTrue,
          reason:
              'In-flight async background output must be disposed immediately '
              'when background passes were disabled before completion.',
        );
      },
    );

    testWidgets(
      'M4b: in-flight async foreground output is disposed if passes are disabled or direct mode activates',
      (tester) async {
        final backend = _FakeShaderBackend()..holdAsyncRender = true;
        final controller = TerminalShaderController(backend: backend);
        addTearDown(controller.dispose);

        final fgConfig = TerminalShaderConfig(
          foregroundPasses: <ShaderPassSpec>[
            ShaderPassSpec(
              id: 'fg:scan',
              stage: TerminalShaderStage.foreground,
              preset: TerminalShaderPreset.scanlineOverlay,
            ),
          ],
          animationMode: ShaderAnimationMode.staticOnly,
        );
        await tester.runAsync(() => controller.syncConfig(fgConfig));

        Widget buildHost(TerminalShaderConfig config) => Directionality(
          textDirection: TextDirection.ltr,
          child: SizedBox(
            width: 64,
            height: 48,
            child: TerminalShaderHost(
              controller: controller,
              config: config,
              child: const ColoredBox(color: Color(0xFF102030)),
            ),
          ),
        );

        await tester.pumpWidget(buildHost(fgConfig));
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));
        await tester.pump();
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));

        expect(backend.pendingAsyncCompleters, hasLength(1));

        // Disable foreground passes while renderPassesAsync is in flight.
        await tester.runAsync(
          () => controller.syncConfig(TerminalShaderConfig.empty),
        );
        await tester.pumpWidget(buildHost(TerminalShaderConfig.empty));

        final hostState = tester.state<TerminalShaderHostState>(
          find.byType(TerminalShaderHost),
        );
        final staleFgImg = await tester.runAsync(
          () => _createSolidImage(width: 64, height: 48),
        );
        backend.pendingAsyncCompleters.single.complete(staleFgImg);
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));

        expect(hostState.debugForegroundOutputImage, isNull);
        expect(
          staleFgImg!.debugDisposed,
          isTrue,
          reason:
              'In-flight async foreground output must be disposed immediately '
              'when foreground passes were disabled before completion.',
        );
      },
    );

    testWidgets(
      'M4c: in-flight async foreground output is disposed if direct mode activates before completion',
      (tester) async {
        final directOutput = await tester.runAsync(
          () => _createSolidImage(
            width: 64,
            height: 48,
            color: const Color(0xFF224466),
          ),
        );
        addTearDown(() => directOutput?.dispose());
        final atlasImg = await tester.runAsync(
          () => _createSolidImage(width: 16, height: 16),
        );
        addTearDown(() => atlasImg?.dispose());

        final backend = _FakeDirectShaderBackend(
          syncOutputFactory: () => directOutput!.clone(),
          primedInitially: true,
        )..holdAsyncRender = true;
        final controller = TerminalShaderController(backend: backend);
        addTearDown(controller.dispose);

        final fgConfig = TerminalShaderConfig(
          foregroundPasses: <ShaderPassSpec>[
            ShaderPassSpec(
              id: 'fg:scan',
              stage: TerminalShaderStage.foreground,
              preset: TerminalShaderPreset.scanlineOverlay,
            ),
          ],
          animationMode: ShaderAnimationMode.staticOnly,
        );
        await tester.runAsync(() => controller.syncConfig(fgConfig));

        Widget buildHost({required bool enableDirect}) => Directionality(
          textDirection: TextDirection.ltr,
          child: SizedBox(
            width: 64,
            height: 48,
            child: TerminalShaderHost(
              controller: controller,
              config: fgConfig,
              atlasImage: enableDirect ? atlasImg : null,
              directLogicalSize: enableDirect ? const Size(64, 48) : null,
              directTerminalBatchProvider: enableDirect
                  ? (_, _) => GpuAtlasQuadBatch(
                      instanceData: Float32List(16),
                      instanceCount: 1,
                      italicStartInstanceIndex: 1,
                      kittyInsertInstanceIndex: 1,
                      generation: 1,
                      defaultBackgroundArgb: 0xFF000000,
                      kittyQuads: const <GpuKittyQuad>[],
                      hasCanvasOnlyContent: false,
                    )
                  : null,
              child: const ColoredBox(color: Color(0xFF102030)),
            ),
          ),
        );

        // Start in fallback mode so async foreground pass launches.
        await tester.pumpWidget(buildHost(enableDirect: false));
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));
        await tester.pump();
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));

        expect(backend.pendingAsyncCompleters, hasLength(1));

        // Activate direct mode while async foreground pass is in flight.
        await tester.pumpWidget(buildHost(enableDirect: true));
        final hostState = tester.state<TerminalShaderHostState>(
          find.byType(TerminalShaderHost),
        );
        expect(hostState.debugIsDirectModeActive, isTrue);

        final staleFgImg = await tester.runAsync(
          () => _createSolidImage(width: 64, height: 48),
        );
        backend.pendingAsyncCompleters.single.complete(staleFgImg);
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));

        expect(hostState.debugForegroundOutputImage, isNull);
        expect(
          staleFgImg!.debugDisposed,
          isTrue,
          reason:
              'In-flight async foreground output must be disposed immediately '
              'when direct mode becomes active before completion.',
        );
      },
    );
  });

  group('TerminalShaderHost watchdog registration and quarantine filtering', () {
    testWidgets(
      'registers non-preset passes under host source without wiping cli shaders',
      (tester) async {
        final backend = _FakeShaderBackend();
        final controller = TerminalShaderController(backend: backend);
        addTearDown(controller.dispose);
        final watchdog = GpuFrameWatchdog();
        addTearDown(watchdog.dispose);
        final replacementWatchdog = GpuFrameWatchdog();
        addTearDown(replacementWatchdog.dispose);

        watchdog.setActiveCustomShaders(const <String>[
          'cli:spark',
        ], source: 'cli');

        final config = TerminalShaderConfig(
          backgroundPasses: <ShaderPassSpec>[
            ShaderPassSpec(
              id: 'user:bg_custom',
              stage: TerminalShaderStage.background,
              inlineGlsl: _validStaticGlsl,
            ),
            ShaderPassSpec(
              id: 'bg:wave',
              stage: TerminalShaderStage.background,
              preset: TerminalShaderPreset.wallpaperWave,
            ),
          ],
          foregroundPasses: <ShaderPassSpec>[
            ShaderPassSpec(
              id: 'editor:fg_draft',
              stage: TerminalShaderStage.foreground,
              inlineGlsl: _validStaticGlsl,
            ),
            ShaderPassSpec(
              id: 'fg:scan',
              stage: TerminalShaderStage.foreground,
              preset: TerminalShaderPreset.scanlineOverlay,
            ),
          ],
          animationMode: ShaderAnimationMode.staticOnly,
        );
        await tester.runAsync(() => controller.syncConfig(config));

        Widget buildHost(TerminalShaderConfig cfg, GpuFrameWatchdog wd) =>
            Directionality(
              textDirection: TextDirection.ltr,
              child: SizedBox(
                width: 64,
                height: 48,
                child: TerminalShaderHost(
                  controller: controller,
                  config: cfg,
                  watchdog: wd,
                  child: const SizedBox.expand(),
                ),
              ),
            );

        await tester.pumpWidget(buildHost(config, watchdog));
        expect(
          watchdog.activeCustomShaderIds,
          equals(<String>{'cli:spark', 'user:bg_custom', 'editor:fg_draft'}),
        );

        // Disabling config clears host passes without touching cli shaders.
        await tester.pumpWidget(
          buildHost(config.copyWith(enabled: false), watchdog),
        );
        expect(watchdog.activeCustomShaderIds, equals(<String>{'cli:spark'}));

        // Re-enabling restores host registrations.
        await tester.pumpWidget(buildHost(config, watchdog));
        expect(
          watchdog.activeCustomShaderIds,
          equals(<String>{'cli:spark', 'user:bg_custom', 'editor:fg_draft'}),
        );

        // Swapping watchdog clears host entries on old watchdog only.
        await tester.pumpWidget(buildHost(config, replacementWatchdog));
        expect(watchdog.activeCustomShaderIds, equals(<String>{'cli:spark'}));
        expect(
          replacementWatchdog.activeCustomShaderIds,
          equals(<String>{'user:bg_custom', 'editor:fg_draft'}),
        );

        // Disposing host clears host entries cleanly.
        await tester.pumpWidget(const SizedBox.shrink());
        expect(replacementWatchdog.activeCustomShaderIds, isEmpty);
        expect(watchdog.activeCustomShaderIds, equals(<String>{'cli:spark'}));
      },
    );

    testWidgets(
      'skips quarantined custom passes while keeping built-in presets active',
      (tester) async {
        final backend = _FakeShaderBackend();
        final controller = TerminalShaderController(backend: backend);
        addTearDown(controller.dispose);
        final activity = _ManualNotifier();
        addTearDown(activity.dispose);
        final watchdog = GpuFrameWatchdog(
          slowFrameThreshold: const Duration(milliseconds: 16),
          consecutiveSlowFrameLimit: 2,
        );
        addTearDown(watchdog.dispose);

        final config = TerminalShaderConfig(
          backgroundPasses: <ShaderPassSpec>[
            ShaderPassSpec(
              id: 'user:bg_slow',
              stage: TerminalShaderStage.background,
              inlineGlsl: _validStaticGlsl,
            ),
            ShaderPassSpec(
              id: 'bg:wave',
              stage: TerminalShaderStage.background,
              preset: TerminalShaderPreset.wallpaperWave,
            ),
          ],
          foregroundPasses: <ShaderPassSpec>[
            ShaderPassSpec(
              id: 'editor:fg_draft',
              stage: TerminalShaderStage.foreground,
              inlineGlsl: _validStaticGlsl,
            ),
          ],
          animationMode: ShaderAnimationMode.staticOnly,
        );
        await tester.runAsync(() => controller.syncConfig(config));

        Widget buildHost() => Directionality(
          textDirection: TextDirection.ltr,
          child: SizedBox(
            width: 64,
            height: 48,
            child: TerminalShaderHost(
              controller: controller,
              config: config,
              watchdog: watchdog,
              activityListenable: activity,
              child: const ColoredBox(color: Color(0xFF102030)),
            ),
          ),
        );

        await tester.pumpWidget(buildHost());
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));
        await tester.pump();
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));

        int countAsyncCallsFor(String passId) => backend.asyncPassCalls
            .where((passes) => passes.any((p) => p.handle.id == passId))
            .length;

        expect(
          backend.syncBackgroundCalls.last.map((p) => p.handle.id),
          equals(<String>['user:bg_slow', 'bg:wave']),
        );
        expect(countAsyncCallsFor('editor:fg_draft'), greaterThanOrEqualTo(1));

        // Quarantine custom passes via slow frames and direct quarantine.
        watchdog.recordShaderFrameDuration(
          'user:bg_slow',
          const Duration(milliseconds: 50),
        );
        watchdog.recordShaderFrameDuration(
          'user:bg_slow',
          const Duration(milliseconds: 50),
        );
        watchdog.quarantineShader('editor:fg_draft', 'slow foreground');
        // Built-in preset stays unaffected even if its ID appears in watchdog.
        watchdog.quarantineShader('bg:wave', 'should not block preset');

        expect(watchdog.isQuarantined('user:bg_slow'), isTrue);
        expect(watchdog.isQuarantined('editor:fg_draft'), isTrue);

        final fgCallsBefore = countAsyncCallsFor('editor:fg_draft');
        activity.trigger();
        await tester.pumpWidget(buildHost());
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));
        await tester.pump();

        expect(
          backend.syncBackgroundCalls.last.map((p) => p.handle.id),
          equals(<String>['bg:wave']),
        );
        expect(countAsyncCallsFor('editor:fg_draft'), equals(fgCallsBefore));
        final hostState = tester.state<TerminalShaderHostState>(
          find.byType(TerminalShaderHost),
        );
        expect(hostState.debugForegroundOutputImage, isNull);

        // Clearing quarantine resumes custom pass rendering.
        watchdog.clearQuarantine();
        activity.trigger();
        await tester.pumpWidget(buildHost());
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));
        await tester.pump();

        expect(
          backend.syncBackgroundCalls.last.map((p) => p.handle.id),
          equals(<String>['user:bg_slow', 'bg:wave']),
        );
        expect(
          countAsyncCallsFor('editor:fg_draft'),
          greaterThan(fgCallsBefore),
        );
      },
    );

    testWidgets(
      'falls back to canvas child instead of looping black frames when direct render keeps returning null after priming succeeds',
      (tester) async {
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetDevicePixelRatio);

        final atlasImg = await tester.runAsync(
          () => _createSolidImage(
            width: 32,
            height: 32,
            color: const Color(0xFFFFFFFF),
          ),
        );
        addTearDown(() => atlasImg?.dispose());
        final outputImg = await tester.runAsync(
          () => _createSolidImage(
            width: 120,
            height: 60,
            color: const Color(0xFF2288EE),
          ),
        );
        addTearDown(() => outputImg?.dispose());

        final prepareCompleter = Completer<bool>();
        final backend = _FakeDirectShaderBackend(
          syncOutputFactory: () => outputImg!.clone(),
          primedInitially: true,
          prepareFuture: prepareCompleter.future,
        )..forceNullDirectRender = true;
        final controller = TerminalShaderController(backend: backend);
        addTearDown(controller.dispose);
        final activity = _TestPaintNotifier();
        addTearDown(activity.dispose);

        final batch = GpuAtlasQuadBatch(
          instanceData: Float32List(16),
          instanceCount: 1,
          italicStartInstanceIndex: 1,
          kittyInsertInstanceIndex: 1,
          generation: 1,
          defaultBackgroundArgb: 0xFF000000,
          kittyQuads: const <GpuKittyQuad>[],
          hasCanvasOnlyContent: false,
        );

        await tester.pumpWidget(
          Directionality(
            textDirection: TextDirection.ltr,
            child: Center(
              child: TerminalShaderHost(
                controller: controller,
                config: TerminalShaderConfig.empty,
                activityListenable: activity,
                atlasImage: atlasImg,
                atlasDevicePixelRatio: 1.0,
                directLogicalSize: const Size(120, 60),
                directTerminalBatchProvider: (_, _) => batch,
                child: const SizedBox(
                  key: Key('canvas-fallback-child'),
                  width: 120,
                  height: 60,
                ),
              ),
            ),
          ),
        );

        // Repaint while prepareDirectResources is still in flight stays in priming.
        activity.fire();
        await tester.pump();
        expect(backend.prepareCallCount, equals(1));

        prepareCompleter.complete(true);
        for (var i = 0; i < 4; i++) {
          await tester.runAsync(() => Future<void>.delayed(Duration.zero));
          await tester.pump();
        }

        final hostState = tester.state<TerminalShaderHostState>(
          find.byType(TerminalShaderHost),
        );
        // Must exit direct mode to Canvas fallback so real tabs show terminal
        // text instead of bouncing black frames in an infinite priming loop.
        expect(hostState.debugIsDirectModeActive, isFalse);
        expect(find.byKey(const Key('canvas-fallback-child')), findsOneWidget);
        expect(backend.prepareCallCount, lessThanOrEqualTo(2));
      },
    );
  });
}

final class _FakeDirectShaderBackend extends _FakeShaderBackend
    implements DirectTerminalShaderBackend, DiagnosableShaderBackend {
  final ui.Image Function() syncOutputFactory;
  final Future<bool>? prepareFuture;
  Object? directRenderError;
  bool primed;
  bool simulateBackpressureSkip = false;
  bool forceNullDirectRender = false;
  bool _lastSyncSkipped = false;
  int directSyncAttemptCount = 0;
  int directSyncRenderCount = 0;
  int prepareCallCount = 0;
  int lastDirectFgPassCount = 0;
  TerminalShaderUniforms? lastDirectFgUniforms;
  GpuAtlasQuadBatch? lastDirectBatch;

  _FakeDirectShaderBackend({
    required this.syncOutputFactory,
    bool primedInitially = true,
    this.prepareFuture,
    this.directRenderError,
  }) : primed = primedInitially;

  @override
  bool get supportsDirectTerminalRender => true;

  @override
  ShaderBackendDiagnostics readDiagnostics() => ShaderBackendDiagnostics(
    lastSyncFrameSkipped: _lastSyncSkipped,
    backpressureSkips: _lastSyncSkipped ? 1 : 0,
  );

  @override
  Future<bool> prepareDirectResources({
    required ui.Image atlasImage,
    ui.Image? wallpaperImage,
    Iterable<ui.Image> kittyImages = const <ui.Image>[],
  }) async {
    prepareCallCount++;
    if (prepareFuture != null) {
      return prepareFuture!;
    }
    primed = true;
    return true;
  }

  @override
  ui.Image? renderTerminalFrameSync({
    required List<ShaderPassInvocation> backgroundPasses,
    required List<ShaderPassInvocation> foregroundPasses,
    required ui.Size physicalSize,
    required ui.Image atlasImage,
    required GpuAtlasQuadBatch batch,
    ui.Image? wallpaperImage,
    GpuFrameWatchdog? watchdog,
  }) {
    _lastSyncSkipped = false;
    directSyncAttemptCount++;
    final error = directRenderError;
    if (error != null) {
      throw error;
    }
    if (!primed || forceNullDirectRender) return null;
    if (simulateBackpressureSkip) {
      _lastSyncSkipped = true;
      return null;
    }
    directSyncRenderCount++;
    lastDirectFgPassCount = foregroundPasses.length;
    lastDirectFgUniforms = foregroundPasses.isNotEmpty
        ? foregroundPasses.first.uniforms
        : null;
    lastDirectBatch = batch;
    return syncOutputFactory();
  }
}

final class _TestPaintNotifier extends ChangeNotifier {
  void fire() => notifyListeners();
}

final class _ColorBlockPainter extends CustomPainter {
  final Color Function() colorProvider;

  _ColorBlockPainter({required Listenable repaint, required this.colorProvider})
    : super(repaint: repaint);

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = colorProvider());
  }

  @override
  bool shouldRepaint(covariant _ColorBlockPainter oldDelegate) => false;
}
