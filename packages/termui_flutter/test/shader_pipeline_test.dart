import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart' show RenderRepaintBoundary;
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:termui/ui/buffer.dart';
import 'package:termui/ui/color.dart' as tui;
import 'package:termui/ui/style.dart';
import 'package:termui/ui/terminal_palette.dart';
import 'package:termui_flutter/termui_flutter.dart';
// ignore: implementation_imports
import 'package:termui_flutter/src/rendering/painter.dart';
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
  });
}

final class _FakeDirectShaderBackend extends _FakeShaderBackend
    implements DirectTerminalShaderBackend {
  final ui.Image Function() syncOutputFactory;
  final Future<bool>? prepareFuture;
  Object? directRenderError;
  bool primed;
  int directSyncAttemptCount = 0;
  int directSyncRenderCount = 0;
  int prepareCallCount = 0;
  int lastDirectFgPassCount = 0;
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
  }) {
    directSyncAttemptCount++;
    final error = directRenderError;
    if (error != null) {
      throw error;
    }
    if (!primed) return null;
    directSyncRenderCount++;
    lastDirectFgPassCount = foregroundPasses.length;
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
