import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:termui/ui/buffer.dart';
import 'package:termui/ui/cell_transform.dart';
import 'package:termui/ui/shader_region.dart';
import 'package:termui/ui/style.dart';
import 'package:termui/ui/terminal_palette.dart';
import 'package:termui/ui/widgets/core/geometry.dart' as tui_geo;
import 'package:termui_flutter/termui_flutter.dart';
// ignore: implementation_imports
import 'package:termui_flutter/src/rendering/gpu_atlas_batch.dart';
// ignore: implementation_imports
import 'package:termui_flutter/src/rendering/gpu_atlas_shaders.dart';
// ignore: implementation_imports
import 'package:termui_flutter/src/rendering/painter.dart';
// ignore: implementation_imports
import 'package:termui_flutter/src/rendering/shader_resource_pools.dart'
    show
        GpuFrameBumpAllocator,
        GpuKeyedPool,
        GpuPingPongRegistry,
        GpuSizePool,
        WebGlRegionTargetPool;
// ignore: implementation_imports
import 'package:termui_flutter/src/terminal_surface.dart'
    show TerminalSurfaceState;

final class _FakeHandle implements CompiledShaderHandle {
  @override
  final String id;

  @override
  bool usesPrevFrame;

  bool disposed = false;

  _FakeHandle({required this.id, required this.usesPrevFrame});

  @override
  void dispose() {
    disposed = true;
  }
}

final class _FakeDirectBackend
    implements DirectTerminalShaderBackend, WatchdogBindableShaderBackend {
  final ui.Image Function() imageFactory;
  final Duration? compileDelay;
  final List<GpuAtlasQuadBatch> directBatches = <GpuAtlasQuadBatch>[];
  final List<List<ShaderPassInvocation>> directForegroundCalls =
      <List<ShaderPassInvocation>>[];
  final List<List<ShaderPassInvocation>> asyncPassCalls =
      <List<ShaderPassInvocation>>[];
  final List<ui.Size> asyncSizes = <ui.Size>[];
  final List<ui.Image?> asyncInputs = <ui.Image?>[];
  int compileCount = 0;

  final List<GpuFrameWatchdog?> directWatchdogs = <GpuFrameWatchdog?>[];
  final List<GpuFrameWatchdog?> asyncWatchdogs = <GpuFrameWatchdog?>[];

  @override
  GpuFrameWatchdog? watchdog;

  _FakeDirectBackend({required this.imageFactory, this.compileDelay});

  @override
  ShaderBackendKind get kind => ShaderBackendKind.flutterGpu;

  @override
  bool get supportsCustomGlsl => true;

  @override
  bool get supportsSyncBackground => true;

  @override
  bool get supportsDirectTerminalRender => true;

  @override
  Future<CompiledShaderHandle> compile(
    String id,
    String shadertoyGlsl, {
    bool usesPrevFrame = false,
  }) async {
    compileCount++;
    if (compileDelay != null) {
      await Future<void>.delayed(compileDelay!);
    }
    return _FakeHandle(id: id, usesPrevFrame: usesPrevFrame);
  }

  @override
  Future<void> reload(
    CompiledShaderHandle handle,
    String shadertoyGlsl,
  ) async {}

  @override
  Future<bool> prepareDirectResources({
    required ui.Image atlasImage,
    ui.Image? wallpaperImage,
    Iterable<ui.Image> kittyImages = const <ui.Image>[],
  }) async => true;

  @override
  ui.Image? renderBackgroundSync({
    required List<ShaderPassInvocation> passes,
    required ui.Size physicalSize,
    ui.Image? wallpaperImage,
    GpuFrameWatchdog? watchdog,
  }) => imageFactory();

  @override
  Future<ui.Image?> renderPassesAsync({
    required List<ShaderPassInvocation> passes,
    required ui.Size physicalSize,
    ui.Image? inputImage,
    ui.Image? wallpaperImage,
    GpuFrameWatchdog? watchdog,
  }) async {
    asyncPassCalls.add(List<ShaderPassInvocation>.of(passes));
    asyncSizes.add(physicalSize);
    asyncInputs.add(inputImage);
    asyncWatchdogs.add(watchdog);
    return imageFactory();
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
    directBatches.add(batch);
    directForegroundCalls.add(List<ShaderPassInvocation>.of(foregroundPasses));
    directWatchdogs.add(watchdog);
    return imageFactory();
  }

  @override
  void dispose() {}
}

final class _ManualListenable extends ChangeNotifier {
  void fire() => notifyListeners();
}

Future<ui.Image> _makeSolidImage({
  int width = 32,
  int height = 32,
  Color color = const Color(0xFF224466),
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

const String _customRegionGlsl = '''
void mainImage(out vec4 fragColor, in vec2 fragCoord) {
  vec2 uv = fragCoord / max(iResolution.xy, vec2(1.0));
  vec4 mask = texture(iChannel0, uv);
  vec4 prev = texture(iPrevFrame, uv);
  float pulse = 0.5 + 0.5 * sin(iTime * 4.0);
  fragColor = max(vec4(mask.rgb * pulse, mask.a), prev * 0.7);
}
''';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Direct GPU a_extra.w rotation & transformed-slice staging', () {
    test('WebGL2 and Impeller vertex shaders rotate around quad center via a_extra.w', () {
      for (final src in <String>[
        GpuAtlasShaders.webgl2VertexSource,
        GpuAtlasShaders.impellerVertexSource,
      ]) {
        expect(src, contains('if (a_extra.w != 0.0)'));
        expect(src, contains('cos(a_extra.w)'));
        expect(src, contains('sin(a_extra.w)'));
        expect(src, contains('a_dst_rect.xy + a_dst_rect.zw * 0.5'));
      }
    });

    test('stages non-uniform scale, a_extra.w rotation, and zLayer ordering into transformed slice', () async {
      final atlas = await GlyphAtlasGenerator.generate(
        fontSize: 14.0,
        fontFamily: 'Roboto Mono',
        devicePixelRatio: 2.0,
      );
      addTearDown(atlas.dispose);

      final buffer = Buffer(10, 4)..writeString(0, 0, 'ABC', Style.empty);
      buffer.setCellTransform(
        0,
        0,
        const CellTransform(
          dx: 1.5,
          dy: 0.5,
          scaleX: 2.0,
          scaleY: 0.5,
          rotationRad: math.pi / 4,
          alpha: 0.75,
          zLayer: 5,
        ),
      );
      buffer.setCellTransform(
        1,
        0,
        const CellTransform(
          dx: -0.25,
          dy: 0.0,
          scaleX: 1.0,
          scaleY: 1.0,
          rotationRad: -0.5,
          zLayer: -2,
        ),
      );

      final animator = CellTransformAnimator()
        ..evaluate(
          table: buffer.cellTransforms,
          cols: buffer.width,
          rows: buffer.height,
          nowSec: 0.0,
        );
      final stager = CellTransformGpuStager();
      final slice = stager.stageTransformedCells(
        buffer: buffer,
        atlas: atlas,
        entries: animator.sortedEntries,
        devicePixelRatio: 2.0,
        defaultForegroundArgb: 0xFFFFFFFF,
        defaultBackgroundArgb: 0xFF000000,
        faintOpacity: 0.5,
        palette: TerminalColorTheme.termuiDark,
      );

      expect(slice.hasCanvasOnlyFallback, isFalse);
      expect(slice.count, equals(2));
      // Negative zLayer (-2) is sorted first and counted in underGlyphCount.
      expect(slice.underGlyphCount, equals(1));

      // Instance 0: cell (1,0), zLayer -2, rotation -0.5.
      expect(slice.data[15], closeTo(-0.5, 1e-5));
      // Instance 1: cell (0,0), zLayer 5, rotation pi/4, non-uniform scale (2.0, 0.5).
      const secondBase = GpuAtlasQuadBatch.floatsPerInstance;
      expect(slice.data[secondBase + 15], closeTo(math.pi / 4, 1e-5));
      // Width scaled 2x vs instance 0 width (scale 1x); height scaled 0.5x vs instance 0 height.
      expect(slice.data[secondBase + 2], closeTo(slice.data[2] * 2.0, 1e-2));
      expect(slice.data[secondBase + 3], closeTo(slice.data[3] * 0.5, 1e-2));
      // Premultiplied alpha 0.75.
      expect(slice.data[secondBase + 11], closeTo(0.75, 0.02));
    });
  });

  group('120 Hz CellTween evaluator & auto-idle ticker', () {
    test('evaluates easing, fromCurrent continuity, hold vs clearOnFinish, and stable animationId across rebuilds', () {
      final animator = CellTransformAnimator();
      final table = CellTransformTable();

      // Start easeOut tween from (0,0) -> (10, 20) over 1.0s with animationId=7.
      table.set(
        0,
        const CellTransform(
          dx: 0.0,
          dy: 0.0,
          tween: CellTween(
            animationId: 7,
            endDx: 10.0,
            endDy: 20.0,
            endRotationRad: 2.0,
            durationSec: 1.0,
            easing: CellTweenEasing.easeOut,
            clearOnFinish: false,
          ),
        ),
      );
      animator.evaluate(table: table, cols: 10, rows: 4, nowSec: 10.0);
      expect(animator.hasActiveTweens, isTrue);
      expect(animator.activePoses[0]!.dx, closeTo(0.0, 1e-5));

      // Unrelated rebuild at t=10.5 with SAME animationId=7 must NOT restart motion.
      animator.evaluate(table: table, cols: 10, rows: 4, nowSec: 10.5);
      expect(animator.hasActiveTweens, isTrue);
      // easeOut(0.5) = 1 - 0.25 = 0.75 -> dx=7.5, dy=15.0.
      expect(animator.activePoses[0]!.dx, closeTo(7.5, 1e-4));
      expect(animator.activePoses[0]!.dy, closeTo(15.0, 1e-4));

      // New keyframe with animationId=8 and fromCurrent=true captures live pose (7.5, 15.0).
      table.set(
        0,
        const CellTransform(
          dx: 0.0,
          dy: 0.0,
          tween: CellTween(
            animationId: 8,
            endDx: 17.5,
            endDy: 15.0,
            durationSec: 1.0,
            easing: CellTweenEasing.linear,
            fromCurrent: true,
            clearOnFinish: false,
          ),
        ),
      );
      animator.evaluate(table: table, cols: 10, rows: 4, nowSec: 10.5);
      expect(animator.activePoses[0]!.dx, closeTo(7.5, 1e-4));

      // Halfway through second tween (t=11.0): dx = 7.5 + (17.5 - 7.5)*0.5 = 12.5.
      animator.evaluate(table: table, cols: 10, rows: 4, nowSec: 11.0);
      expect(animator.activePoses[0]!.dx, closeTo(12.5, 1e-4));

      // Completion with clearOnFinish=false holds end pose and stops active tweens.
      animator.evaluate(table: table, cols: 10, rows: 4, nowSec: 11.6);
      expect(animator.hasActiveTweens, isFalse);
      expect(animator.activePoses[0]!.dx, closeTo(17.5, 1e-4));

      // Completion with clearOnFinish=true clears transform completely.
      table.set(
        1,
        const CellTransform(
          dx: 2.0,
          tween: CellTween(
            animationId: 9,
            endDx: 6.0,
            durationSec: 0.5,
            clearOnFinish: true,
          ),
        ),
      );
      animator.evaluate(table: table, cols: 10, rows: 4, nowSec: 12.0);
      expect(animator.hasActiveTweens, isTrue);
      expect(animator.activePoses[1], isNotNull);

      animator.evaluate(table: table, cols: 10, rows: 4, nowSec: 12.6);
      expect(animator.hasActiveTweens, isFalse);
      expect(animator.activePoses[1], isNull);
    });

    testWidgets(
      'TerminalSurface tween ticker drives direct GPU without widget rebuilds and auto-stops when idle',
      (tester) async {
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetDevicePixelRatio);
        final outImg = await tester.runAsync(_makeSolidImage);
        addTearDown(() => outImg?.dispose());

        final atlasController = GlyphAtlasController(
          fontSize: 14.0,
          fontFamily: 'Roboto Mono',
        );
        addTearDown(atlasController.dispose);
        await tester.runAsync(atlasController.ensureInitialized);

        final backend = _FakeDirectBackend(imageFactory: () => outImg!.clone());
        final shaderController = TerminalShaderController(backend: backend);
        addTearDown(shaderController.dispose);

        final buffer = Buffer(20, 6)..writeString(0, 0, 'FALLING', Style.empty);
        buffer.setCellTransform(
          0,
          0,
          const CellTransform(
            dx: 0.0,
            dy: 0.0,
            tween: CellTween(
              animationId: 42,
              endDx: 4.0,
              endDy: 3.0,
              endRotationRad: 1.5,
              durationSec: 0.2,
              clearOnFinish: false,
            ),
          ),
        );

        final surfaceKey = GlobalKey<TerminalSurfaceState>();
        await tester.pumpWidget(
          Directionality(
            textDirection: TextDirection.ltr,
            child: SizedBox(
              width: 240,
              height: 120,
              child: TerminalSurface(
                key: surfaceKey,
                atlasController: atlasController,
                buffer: buffer,
                shaderController: shaderController,
                shaderConfig: TerminalShaderConfig.empty,
                alignment: Alignment.topLeft,
              ),
            ),
          ),
        );
        await tester.pump();

        final state = surfaceKey.currentState!;
        expect(state.debugIsTweenTickerActive, isTrue);
        expect(backend.directBatches, isNotEmpty);
        final initialStaticGen = backend.directBatches.last.generation;
        final initialXformGen =
            backend.directBatches.last.transformedGeneration;

        // Advance mid-tween (50ms): transformedGeneration advances while static generation stays unchanged!
        await tester.pump(const Duration(milliseconds: 50));
        expect(state.debugIsTweenTickerActive, isTrue);
        expect(backend.directBatches.last.generation, equals(initialStaticGen));
        expect(
          backend.directBatches.last.transformedGeneration,
          greaterThan(initialXformGen),
        );

        // Advance past durationSec (0.2s): ticker stops automatically!
        await tester.pump(const Duration(milliseconds: 250));
        await tester.pump(const Duration(milliseconds: 16));
        expect(state.debugIsTweenTickerActive, isFalse);
      },
    );
  });

  group('200x60 static row-cache hits & GPU generation stability', () {
    test('animating 20 letters over a 200x60 grid keeps all 60 static rows 100% cache-hit and static GPU generation unchanged', () async {
      final atlas = await GlyphAtlasGenerator.generate(
        fontSize: 12.0,
        fontFamily: 'Roboto Mono',
        devicePixelRatio: 1.0,
      );
      addTearDown(atlas.dispose);

      const cols = 200;
      const rows = 60;
      final buffer = Buffer(cols, rows);
      for (var y = 0; y < rows; y++) {
        buffer.writeString(
          0,
          y,
          'Row${y.toString().padLeft(2, '0')}:TheQuickBrownFoxJumpsOverTheLazyDog0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ',
          Style.empty,
        );
      }

      // Attach active 120 Hz tweens to 20 letters spread across 10 rows.
      for (var i = 0; i < 20; i++) {
        final col = 8 + (i * 3);
        final row = i % 10;
        buffer.setCellTransform(
          col,
          row,
          CellTransform(
            dx: 0.0,
            dy: 0.0,
            tween: CellTween(
              animationId: 100 + i,
              endDx: 5.0,
              endDy: 12.0,
              endRotationRad: 3.14,
              durationSec: 1.0,
            ),
          ),
        );
      }

      final stagingCache = TuiAtlasStagingCache();
      final batchBuilder = GpuAtlasBatchBuilder();
      final animator = CellTransformAnimator();
      final maskBuilder = CellOverrideMaskBuilder();
      final xformStager = CellTransformGpuStager();
      final logicalSize = Size(cols * atlas.cellWidth, rows * atlas.cellHeight);

      GpuAtlasQuadBatch stageAt(double nowSec) {
        animator.evaluate(
          table: buffer.cellTransforms,
          cols: cols,
          rows: rows,
          nowSec: nowSec,
        );
        final mask = maskBuilder.build(
          cols: cols,
          rows: rows,
          activeTransforms: animator.activePoses,
          replaceRegions: const <ShaderRegion>[],
        );
        final painter = TuiAtlasPainter(
          buffer: buffer,
          atlas: atlas,
          stagingCache: stagingCache,
          cellOverrideMask: mask,
          fontFamily: 'Roboto Mono',
          fallbackPainters: const {},
          onMissingGlyphs: null,
        );
        final staticBatch = painter.stageForGpu(logicalSize, 1.0, batchBuilder);
        final xformSlice = xformStager.stageTransformedCells(
          buffer: buffer,
          atlas: atlas,
          entries: animator.sortedEntries,
          devicePixelRatio: 1.0,
          defaultForegroundArgb: 0xFFFFFFFF,
          defaultBackgroundArgb: 0xFF000000,
          faintOpacity: 0.5,
          palette: TerminalColorTheme.termuiDark,
        );
        return staticBatch.withDynamicSlices(
          transformedInstanceData: xformSlice.data,
          transformedInstanceCount: xformSlice.count,
          transformedUnderGlyphCount: xformSlice.underGlyphCount,
          transformedGeneration: xformSlice.generation,
        );
      }

      // Frame 0 warms the row cache with the 20 overridden cells.
      final frame0 = stageAt(0.0);
      expect(frame0.transformedInstanceCount, equals(20));

      // Frames 1..10 simulate 120 Hz animation ticks (~8.33ms apart).
      var prevXformGen = frame0.transformedGeneration;
      for (var step = 1; step <= 10; step++) {
        final next = stageAt(step / 120.0);
        expect(
          stagingCache.lastRowHits,
          equals(rows),
          reason: 'All 60 static rows must hit cache on tick $step',
        );
        expect(stagingCache.lastRowMisses, equals(0));
        expect(
          next.generation,
          equals(frame0.generation),
          reason:
              'Static GPU grid generation must remain unchanged on tick $step',
        );
        expect(
          next.transformedGeneration,
          greaterThan(prevXformGen),
          reason: 'Transformed slice generation must advance on tick $step',
        );
        prevXformGen = next.transformedGeneration;
      }
    });
  });

  group('Uniform Canvas drawRawAtlas fallback (DisabledShaderBackend)', () {
    testWidgets(
      'renders transformed cells via uniform Canvas drawRawAtlas clipped to pane viewport',
      (tester) async {
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetDevicePixelRatio);

        final atlasController = GlyphAtlasController(
          fontSize: 14.0,
          fontFamily: 'Roboto Mono',
        );
        addTearDown(atlasController.dispose);
        await tester.runAsync(atlasController.ensureInitialized);

        final shaderController = TerminalShaderController(
          backend: const DisabledShaderBackend(),
        );
        addTearDown(shaderController.dispose);

        final buffer = Buffer(12, 4)..writeString(0, 0, 'HELLO', Style.empty);
        buffer.setCellTransform(
          0,
          0,
          const CellTransform(
            dx: 2.0,
            dy: 1.0,
            scaleX: 1.8,
            scaleY: 1.2,
            rotationRad: 0.6,
            alpha: 0.9,
          ),
        );
        // Far out-of-pane displacement must clip cleanly without throwing.
        buffer.setCellTransform(
          1,
          0,
          const CellTransform(dx: 500.0, dy: 500.0, rotationRad: 1.2),
        );

        await tester.pumpWidget(
          Directionality(
            textDirection: TextDirection.ltr,
            child: SizedBox(
              width: 160,
              height: 80,
              child: TerminalSurface(
                atlasController: atlasController,
                buffer: buffer,
                shaderController: shaderController,
                shaderConfig: TerminalShaderConfig.empty,
                alignment: Alignment.topLeft,
              ),
            ),
          ),
        );
        await tester.pump();
        expect(tester.takeException(), isNull);

        // Directly verify Canvas fallback paints non-empty pixels inside viewport.
        final atlas = atlasController.atlas!;
        final animator = CellTransformAnimator()
          ..evaluate(
            table: buffer.cellTransforms,
            cols: buffer.width,
            rows: buffer.height,
            nowSec: 0.0,
          );
        final recorder = ui.PictureRecorder();
        final canvas = Canvas(recorder);
        CellTransformPainter().paintCanvas(
          canvas: canvas,
          viewportSize: const Size(120, 64),
          buffer: buffer,
          atlas: atlas,
          entries: animator.sortedEntries,
          defaultForegroundArgb: 0xFFFFFFFF,
          defaultBackgroundArgb: 0xFF000000,
          faintOpacity: 0.5,
          palette: TerminalColorTheme.termuiDark,
          fontFamily: 'Roboto Mono',
          fontFamilyFallback: null,
          fallbackPainters: const {},
        );
        final picture = recorder.endRecording();
        final img = await tester.runAsync(() => picture.toImage(120, 64));
        picture.dispose();
        addTearDown(() => img?.dispose());
        final bytes = await tester.runAsync(
          () => img!.toByteData(format: ui.ImageByteFormat.rawRgba),
        );
        final nonZeroAlpha = bytes!.buffer.asUint8List().any((b) => b != 0);
        expect(nonZeroAlpha, isTrue);
      },
    );
  });

  group('ShaderRegion presets, tight-bbox uGlyphMask, 512x512 cap & Canvas fallback', () {
    test('all eight built-in region presets validate and shim for Impeller and WebGL2', () {
      expect(
        ShaderRegionPresets.presetIds,
        equals(const <String>[
          'fire',
          'ice_frost',
          'neon_pulse',
          'glitch_tear',
          'one_ring',
          'vortex',
          'forge_spark',
          'water_ripple',
        ]),
      );
      for (final id in ShaderRegionPresets.presetIds) {
        expect(ShaderRegionPresets.isPreset(id), isTrue);
        final source = ShaderRegionPresets.sourceFor(id);
        expect(source, isNotNull);
        final shimmed = ShadertoyGlslShim.shim(source!, shaderId: id);
        expect(shimmed.impellerFragmentGlsl, contains('#version 460 core'));
        expect(shimmed.webgl2FragmentGlsl, contains('#version 300 es'));
        expect(shimmed.analysis.samplesChannel0, isTrue);
        expect(shimmed.analysis.usesTime, isTrue);
      }

      final oneRing = ShadertoyGlslShim.analyze(
        ShaderRegionPresets.oneRingGlsl,
      );
      expect(oneRing.usesPrevFrame, isTrue);
      expect(oneRing.usesMouse, isTrue);
      expect(
        ShaderRegionPresets.oneRingGlsl,
        allOf(
          contains('cellCenterPx'),
          contains('fragColor = vec4(metalCol, 1.0);'),
          contains('glow >= 0.40'),
          contains('max(latchedCol.r, 0.84)'),
          contains('haloFlicker'),
          contains('iPrevFrame'),
        ),
      );

      final vortex = ShadertoyGlslShim.analyze(ShaderRegionPresets.vortexGlsl);
      expect(vortex.usesPrevFrame, isFalse);
      expect(vortex.usesMouse, isTrue);
      expect(
        ShaderRegionPresets.vortexGlsl,
        allOf(contains('mouseInRegion'), contains('visIntensity')),
      );

      final forgeSpark = ShadertoyGlslShim.analyze(
        ShaderRegionPresets.forgeSparkGlsl,
      );
      expect(forgeSpark.usesPrevFrame, isFalse);
      expect(forgeSpark.usesMouse, isFalse);
      expect(forgeSpark.usesCursorUniforms, isFalse);
      expect(
        ShaderRegionPresets.forgeSparkGlsl,
        allOf(
          contains('max(1.06, 0.90 * pxScale)'),
          contains('max(0.525, 0.45 * pxScale)'),
          isNot(contains('shockwave')),
          isNot(contains('expanding')),
        ),
      );

      final waterRipple = ShadertoyGlslShim.analyze(
        ShaderRegionPresets.waterRippleGlsl,
      );
      expect(waterRipple.usesPrevFrame, isFalse);
      expect(waterRipple.usesMouse, isTrue);

      expect(ShaderRegionPresets.isPreset('user_custom'), isFalse);
      expect(ShaderRegionPresets.sourceFor('user_custom'), isNull);
    });

    test('CliShaderRegistry auto-enables usesPrevFrame for one_ring and tracks anyShaderUsesMouse', () async {
      final backend = _FakeDirectBackend(
        imageFactory: () => throw UnimplementedError(),
      );
      final registry = CliShaderRegistry(backend: backend);
      addTearDown(registry.dispose);

      expect(registry.anyShaderUsesMouse, isFalse);

      // Even with persist: false, one_ring's static iPrevFrame analysis enables ping-pong.
      final region = ShaderRegion(
        id: 'ring_r',
        shaderId: 'one_ring',
        sourceRects: const <tui_geo.Rect>[tui_geo.Rect(0, 0, 10, 2)],
        persist: false,
      );
      final handle = await registry.ensureRegionShaderCompiled(region);
      expect(handle, isNotNull);
      expect(handle!.usesPrevFrame, isTrue);
      expect(registry.anyShaderUsesMouse, isTrue);
    });

    test('ComputedShaderRegionLayout transforms pane iMouse and iCurrentCursor into region-local Y-up coords', () {
      // Pane 400x300 logical @ dpr 2.0 => 800x600 physical.
      // Region at logical (50, 25, 100, 50) => physical (100, 50, 200, 100).
      final layout = ComputedShaderRegionLayout(
        region: ShaderRegion(
          id: 'r_mouse',
          shaderId: 'one_ring',
          sourceRects: const <tui_geo.Rect>[tui_geo.Rect(0, 0, 4, 1)],
        ),
        sourceUnionLogical: const Rect.fromLTWH(50, 25, 100, 50),
        outputRectLogical: const Rect.fromLTWH(50, 25, 100, 50),
        outputRectPhysical: const Rect.fromLTWH(100, 50, 200, 100),
        physicalWidth: 200,
        physicalHeight: 100,
        sourceCellIndices: const <int>[0],
      );
      final out = Float32List(4);

      // Idle zero mouse stays exact (0, 0, 0, 0).
      layout.writeRegionMouseXyzw(
        paneMouseXyzw: Float32List(4),
        panePhysicalHeight: 600.0,
        out: out,
      );
      expect(out, equals(<double>[0.0, 0.0, 0.0, 0.0]));

      // Active drag inside region: pane top-down (150, 75) => pane Y-up (150, 525),
      // click origin top-down (120, 80) => pane Y-up (+120, +520).
      layout.writeRegionMouseXyzw(
        paneMouseXyzw: Float32List.fromList(<double>[150, 525, 120, 520]),
        panePhysicalHeight: 600.0,
        out: out,
      );
      expect(out[0], closeTo(50.0, 1e-4));
      expect(out[1], closeTo(75.0, 1e-4));
      expect(out[2], closeTo(20.0, 1e-4));
      expect(out[3], closeTo(70.0, 1e-4));

      // Released button preserves negative click sign.
      layout.writeRegionMouseXyzw(
        paneMouseXyzw: Float32List.fromList(<double>[150, 525, -120, -520]),
        panePhysicalHeight: 600.0,
        out: out,
      );
      expect(out[2], closeTo(-20.0, 1e-4));
      expect(out[3], closeTo(-70.0, 1e-4));

      // Click outside left edge of region while held keeps z > 0.
      layout.writeRegionMouseXyzw(
        paneMouseXyzw: Float32List.fromList(<double>[150, 525, 40, 520]),
        panePhysicalHeight: 600.0,
        out: out,
      );
      expect(out[2], greaterThan(0.0));
      expect(out[3], closeTo(70.0, 1e-4));

      // Pane Y-up cursor at top-down (120, 60, 8, 16) => bottom=76 => paneBottomY=524.
      layout.writeRegionCursorXywh(
        paneCursorXywh: Float32List.fromList(<double>[120, 524, 8, 16]),
        panePhysicalHeight: 600.0,
        out: out,
      );
      expect(out[0], closeTo(20.0, 1e-4));
      expect(out[1], closeTo(74.0, 1e-4));
      expect(out[2], closeTo(8.0, 1e-4));
      expect(out[3], closeTo(16.0, 1e-4));
    });

    test('tight-bbox isolates sourceRects from padded neighbors and enforces 512x512 logical px cap', () {
      // 4-char word "fire" at col 10..13, row 4 with top padding 2, left/right 1.
      final region = ShaderRegion(
        id: 'r_fire',
        shaderId: 'fire',
        sourceRects: const <tui_geo.Rect>[tui_geo.Rect(10, 4, 4, 1)],
        padding: const CellPadding(top: 2, right: 1, bottom: 0, left: 1),
      );
      final layout = ComputedShaderRegionLayout.compute(
        region: region,
        gridCols: 80,
        gridRows: 24,
        cellWidth: 8.0,
        cellHeight: 16.0,
        paneLogicalSize: const Size(640, 384),
        devicePixelRatio: 1.0,
      )!;

      // Only the 4 source cells belong to uGlyphMask (neighbor cells inside padding are excluded!).
      expect(layout.sourceCellIndices, hasLength(4));
      expect(
        layout.sourceCellIndices,
        equals(<int>[4 * 80 + 10, 4 * 80 + 11, 4 * 80 + 12, 4 * 80 + 13]),
      );
      // Width: (4 + 1 + 1) * 8 = 48px; Height: (1 + 2) * 16 = 48px (<= 128x128).
      expect(layout.outputRectLogical.width, closeTo(48.0, 1e-4));
      expect(layout.outputRectLogical.height, closeTo(48.0, 1e-4));
      expect(layout.physicalWidth, equals(48));
      expect(layout.physicalHeight, equals(48));

      // Moving transformed glyph expands bbox within 512x512 cap, while a huge
      // jump beyond 512 logical px exits cleanly without exceeding the cap!
      final mildMove = ComputedShaderRegionLayout.compute(
        region: region,
        gridCols: 120,
        gridRows: 60,
        cellWidth: 10.0,
        cellHeight: 20.0,
        paneLogicalSize: const Size(1200, 1200),
        devicePixelRatio: 2.0,
        activeTransforms: const <int, EvaluatedCellTransform>{
          4 * 120 + 10: EvaluatedCellTransform(dx: 5.0, dy: 3.0),
        },
      )!;
      expect(mildMove.sourceUnionLogical.width, greaterThan(40.0));
      expect(
        mildMove.outputRectLogical.width,
        lessThanOrEqualTo(ComputedShaderRegionLayout.maxRegionLogicalExtent),
      );

      final hugeRegion = ShaderRegion(
        id: 'r_huge',
        shaderId: 'fire',
        sourceRects: const <tui_geo.Rect>[tui_geo.Rect(0, 0, 100, 50)],
        padding: const CellPadding.all(8),
      );
      final capped = ComputedShaderRegionLayout.compute(
        region: hugeRegion,
        gridCols: 120,
        gridRows: 60,
        cellWidth: 10.0,
        cellHeight: 20.0,
        paneLogicalSize: const Size(1200, 1200),
        devicePixelRatio: 2.0,
        activeTransforms: const <int, EvaluatedCellTransform>{
          0: EvaluatedCellTransform(dx: 100.0, dy: 80.0),
        },
      )!;
      expect(capped.outputRectLogical.width, lessThanOrEqualTo(512.0));
      expect(capped.outputRectLogical.height, lessThanOrEqualTo(512.0));
      expect(capped.physicalWidth, lessThanOrEqualTo(1024));
      expect(capped.physicalHeight, lessThanOrEqualTo(1024));
    });

    testWidgets(
      'two persist=1 overGlyphs regions execute before full-pane FG shaders in direct mode and fall back alongside ligatures',
      (tester) async {
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetDevicePixelRatio);
        final outImg = await tester.runAsync(_makeSolidImage);
        addTearDown(() => outImg?.dispose());

        final atlasController = GlyphAtlasController(
          fontSize: 14.0,
          fontFamily: 'Roboto Mono',
        );
        addTearDown(atlasController.dispose);
        await tester.runAsync(atlasController.ensureInitialized);

        final backend = _FakeDirectBackend(imageFactory: () => outImg!.clone());
        final shaderController = TerminalShaderController(backend: backend);
        addTearDown(shaderController.dispose);

        final fgConfig = TerminalShaderConfig(
          foregroundPasses: <ShaderPassSpec>[
            ShaderPassSpec(
              id: 'crt_fg',
              stage: TerminalShaderStage.foreground,
              preset: TerminalShaderPreset.scanlineOverlay,
            ),
          ],
        );
        await tester.runAsync(() => shaderController.syncConfig(fgConfig));

        final buffer = Buffer(30, 6)
          ..writeString(0, 1, 'word1 fire and word2 ice', Style.empty);
        buffer.addShaderRegion(
          ShaderRegion(
            id: 'r1',
            shaderId: 'fire',
            sourceRects: const <tui_geo.Rect>[tui_geo.Rect(6, 1, 4, 1)],
            padding: const CellPadding(top: 1, right: 1, bottom: 0, left: 1),
            stage: ShaderRegionStage.overGlyphs,
            zIndex: 1,
            persist: true,
            params: Float32List.fromList(<double>[1.5, 0.8, 0, 0, 0, 0, 0, 0]),
          ),
        );
        buffer.addShaderRegion(
          ShaderRegion.fromRef(
            id: 'r2',
            shader: const ShaderRef.glsl(
              id: 'custom_burn',
              source: _customRegionGlsl,
              persist: true,
            ),
            sourceRects: const <tui_geo.Rect>[tui_geo.Rect(21, 1, 3, 1)],
            padding: const CellPadding.all(1),
            stage: ShaderRegionStage.overGlyphs,
            zIndex: 2,
          ),
        );

        final notifier = _ManualListenable();
        addTearDown(notifier.dispose);
        var enableLigatures = false;

        Widget buildSurface() => Directionality(
          textDirection: TextDirection.ltr,
          child: SizedBox(
            width: 300,
            height: 120,
            child: TerminalSurface(
              atlasController: atlasController,
              buffer: buffer,
              bufferListenable: notifier,
              enableLigatures: enableLigatures,
              shaderController: shaderController,
              shaderConfig: fgConfig,
              alignment: Alignment.topLeft,
            ),
          ),
        );

        await tester.pumpWidget(buildSurface());
        await tester.pump();
        await tester.pump();

        expect(backend.directBatches, isNotEmpty);
        final lastDirect = backend.directBatches.last;
        expect(lastDirect.regionPasses, hasLength(2));
        expect(lastDirect.regionMaskSlices, hasLength(2));
        expect(
          lastDirect.regionPasses.map((p) => p.prevFrameKey).toList(),
          equals(<String>['region:r1', 'region:r2']),
        );
        expect(
          lastDirect.regionPasses[0].uniforms.params[0],
          closeTo(1.5, 1e-4),
        );
        expect(
          lastDirect.regionPasses[0].stage,
          equals(ShaderRegionStage.overGlyphs),
        );
        expect(lastDirect.regionPasses[1].handle.usesPrevFrame, isTrue);
        // Full-pane FG pass runs in the same direct frame AFTER regions.
        expect(backend.directForegroundCalls.last, hasLength(1));
        expect(
          backend.directForegroundCalls.last.single.handle.id,
          equals('crt_fg'),
        );

        // Now write a non-prebaked ligature ('<!--') with enableLigatures=true
        // to trigger Canvas fallback and confirm regions still render via PictureRecorder + renderPassesAsync!
        enableLigatures = true;
        buffer.writeString(0, 3, '<!--', Style.empty);
        await tester.pumpWidget(buildSurface());
        notifier.fire();
        await tester.pump();
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump();

        final hostState = tester.state<TerminalShaderHostState>(
          find.byType(TerminalShaderHost),
        );
        expect(hostState.debugIsDirectModeActive, isFalse);
        expect(
          backend.asyncPassCalls.any(
            (passes) => passes.any((p) => p.prevFrameKey == 'region:r1'),
          ),
          isTrue,
          reason: 'Canvas fallback must execute region passes via renderPassesAsync',
        );
      },
    );
  });

  group('GpuFrameWatchdog & CliShaderRegistry per-shader quarantine', () {
    test('sustained > 33ms quarantines only offending custom CLI shader and preserves presets', () {
      final quarantined = <(String, String)>[];
      final watchdog = GpuFrameWatchdog(
        isBuiltinPreset: ShaderRegionPresets.isPreset,
        onShaderQuarantined: (id, reason) => quarantined.add((id, reason)),
      );
      addTearDown(watchdog.dispose);

      watchdog.setActiveCustomShaders(const <String>[
        'evil_cli',
        'good_cli',
        'fire',
      ]);
      // Built-in preset 'fire' is never tracked as a custom CLI shader.
      expect(
        watchdog.activeCustomShaderIds,
        equals(<String>{'evil_cli', 'good_cli'}),
      );

      // Non-consecutive slow frames reset streak and do not trip.
      watchdog.recordShaderFrameDuration(
        'evil_cli',
        const Duration(milliseconds: 40),
      );
      watchdog.recordShaderFrameDuration(
        'evil_cli',
        const Duration(milliseconds: 42),
      );
      watchdog.recordShaderFrameDuration(
        'evil_cli',
        const Duration(milliseconds: 10),
      );
      expect(watchdog.isQuarantined('evil_cli'), isFalse);

      // 3 consecutive slow frames trip quarantine ONLY for evil_cli.
      watchdog.recordShaderFrameDuration(
        'evil_cli',
        const Duration(milliseconds: 35),
      );
      watchdog.recordShaderFrameDuration(
        'evil_cli',
        const Duration(milliseconds: 38),
      );
      watchdog.recordShaderFrameDuration(
        'evil_cli',
        const Duration(milliseconds: 45),
      );
      expect(watchdog.isQuarantined('evil_cli'), isTrue);
      expect(watchdog.isQuarantined('good_cli'), isFalse);
      expect(watchdog.isQuarantined('fire'), isFalse);
      expect(quarantined, hasLength(1));
      expect(quarantined.single.$1, equals('evil_cli'));
    });

    testWidgets(
      'single command-buffer completion timeout and webglcontextlost trip quarantine',
      (tester) async {
        final quarantined = <String>[];
        final watchdog = GpuFrameWatchdog(
          completionTimeout: const Duration(seconds: 2),
          isBuiltinPreset: ShaderRegionPresets.isPreset,
          onShaderQuarantined: (id, _) => quarantined.add(id),
        );
        addTearDown(watchdog.dispose);
        watchdog.setActiveCustomShaders(const <String>['hang_shader', 'fire']);

        final token = watchdog.beginCommandSubmission(const <String>[
          'hang_shader',
        ]);
        expect(token, isNonZero);
        expect(watchdog.pendingSubmissionCount, equals(1));

        await tester.pump(const Duration(seconds: 2));
        expect(watchdog.isQuarantined('hang_shader'), isTrue);
        expect(watchdog.isQuarantined('fire'), isFalse);
        expect(quarantined, equals(<String>['hang_shader']));

        // Disjoint WebGL timer queries are ignored; non-disjoint slow queries trip.
        watchdog.setActiveCustomShaders(const <String>['slow_web']);
        for (var i = 0; i < 5; i++) {
          watchdog.recordWebGlTimerQueryResult(
            50 * 1000 * 1000,
            customShaderIds: const <String>['slow_web'],
            disjoint: true,
          );
        }
        expect(watchdog.isQuarantined('slow_web'), isFalse);

        // webglcontextlost immediately quarantines active custom CLI shaders.
        watchdog.reportWebGlContextLost();
        expect(watchdog.isQuarantined('slow_web'), isTrue);
        expect(watchdog.isQuarantined('fire'), isFalse);
      },
    );

    test('CliShaderRegistry enforces 32 KiB limit, 4s compile timeout, and preserves presets on quarantine', () async {
      final outImg = await _makeSolidImage();
      addTearDown(outImg.dispose);
      final backend = _FakeDirectBackend(
        imageFactory: () => outImg.clone(),
        compileDelay: const Duration(milliseconds: 60),
      );
      final watchdog = GpuFrameWatchdog(
        isBuiltinPreset: ShaderRegionPresets.isPreset,
      );
      addTearDown(watchdog.dispose);
      final registry = CliShaderRegistry(backend: backend, watchdog: watchdog);
      addTearDown(registry.dispose);

      // Oversized > 32 KiB CLI shader rejected.
      final oversized = '$_customRegionGlsl\n// ${'x' * 33000}';
      await expectLater(
        registry.registerCliShader(id: 'too_big', source: oversized),
        throwsA(isA<ShaderCompileException>()),
      );

      // Short compile timeout throws ShaderCompileException.
      await expectLater(
        registry.registerCliShader(
          id: 'slow_compile',
          source: _customRegionGlsl,
          timeout: const Duration(milliseconds: 5),
        ),
        throwsA(isA<ShaderCompileException>()),
      );

      // Normal CLI shader + built-in preset both compile.
      final customHandle = await registry.registerCliShader(
        id: 'cli_fx',
        source: _customRegionGlsl,
      );
      final presetHandle = await registry.ensureRegionShaderCompiled(
        ShaderRegion(
          id: 'r_fire',
          shaderId: 'fire',
          sourceRects: const <tui_geo.Rect>[tui_geo.Rect(0, 0, 4, 1)],
        ),
      );
      expect(customHandle, isNotNull);
      expect(presetHandle, isNotNull);

      // Quarantining cli_fx hides only cli_fx while preserving 'fire'.
      registry.quarantineShader('cli_fx', 'slow frame');
      registry.quarantineShader('fire', 'ignored for builtin');
      expect(registry.handleForShader('cli_fx'), isNull);
      expect(registry.handleForShader('fire'), isNotNull);
    });
  });

  group('Batch 2 regressions (H6, M1, M2, L1)', () {
    test('CellOverrideMaskBuilder sparse clear and order-independent lastMaskHash (M1)', () {
      final builder = CellOverrideMaskBuilder();
      final maskA = builder.build(
        cols: 10,
        rows: 5,
        activeTransforms: const <int, EvaluatedCellTransform>{
          3: EvaluatedCellTransform(dx: 1.0),
          17: EvaluatedCellTransform(dx: 2.0),
        },
        replaceRegions: const <ShaderRegion>[],
      );
      expect(maskA, isNotNull);
      expect(maskA![3], equals(1));
      expect(maskA[17], equals(1));
      final hash1 = builder.lastMaskHash;
      expect(hash1, isNonZero);

      // Reversed insertion order produces identical hash.
      builder.build(
        cols: 10,
        rows: 5,
        activeTransforms: const <int, EvaluatedCellTransform>{
          17: EvaluatedCellTransform(dx: 2.0),
          3: EvaluatedCellTransform(dx: 1.0),
        },
        replaceRegions: const <ShaderRegion>[],
      );
      expect(builder.lastMaskHash, equals(hash1));

      // Moving marked cell sparsely clears previous indices.
      final maskB = builder.build(
        cols: 10,
        rows: 5,
        activeTransforms: const <int, EvaluatedCellTransform>{
          4: EvaluatedCellTransform(dx: 1.0),
        },
        replaceRegions: const <ShaderRegion>[],
      );
      expect(maskB![3], equals(0));
      expect(maskB[17], equals(0));
      expect(maskB[4], equals(1));
      expect(builder.lastMaskHash, isNot(equals(hash1)));

      // Clearing all overrides resets mask & hash to 0.
      expect(
        builder.build(
          cols: 10,
          rows: 5,
          activeTransforms: const <int, EvaluatedCellTransform>{},
          replaceRegions: const <ShaderRegion>[],
        ),
        isNull,
      );
      expect(builder.lastMaskHash, equals(0));
    });

    testWidgets(
      'TerminalSurface tweenClock drives deterministic poses and reaches final rawT == 1.0 pose for clearOnFinish: false (H6, M2, L1)',
      (tester) async {
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetDevicePixelRatio);
        final outImg = await tester.runAsync(_makeSolidImage);
        addTearDown(() => outImg?.dispose());

        final atlasController = GlyphAtlasController(
          fontSize: 14.0,
          fontFamily: 'Roboto Mono',
        );
        addTearDown(atlasController.dispose);
        await tester.runAsync(atlasController.ensureInitialized);

        final backend = _FakeDirectBackend(imageFactory: () => outImg!.clone());
        final shaderController = TerminalShaderController(backend: backend);
        addTearDown(shaderController.dispose);

        var simNow = Duration.zero;
        final buffer = Buffer(20, 6)..writeString(0, 0, 'HOLD', Style.empty);
        buffer.setCellTransform(
          0,
          0,
          const CellTransform(
            dx: 0.0,
            dy: 0.0,
            tween: CellTween(
              animationId: 77,
              endDx: 5.0,
              endDy: 0.0,
              endRotationRad: 1.0,
              durationSec: 0.1,
              easing: CellTweenEasing.linear,
              clearOnFinish: false,
            ),
          ),
        );

        final surfaceKey = GlobalKey<TerminalSurfaceState>();
        await tester.pumpWidget(
          Directionality(
            textDirection: TextDirection.ltr,
            child: SizedBox(
              width: 240,
              height: 120,
              child: TerminalSurface(
                key: surfaceKey,
                atlasController: atlasController,
                buffer: buffer,
                shaderController: shaderController,
                shaderConfig: TerminalShaderConfig.empty,
                tweenClock: () => simNow,
                alignment: Alignment.topLeft,
              ),
            ),
          ),
        );
        await tester.pump();
        expect(surfaceKey.currentState!.debugIsTweenTickerActive, isTrue);

        // Halfway through (50 ms): rotation is ~0.5 rad.
        simNow = const Duration(milliseconds: 50);
        await tester.pump(const Duration(milliseconds: 16));
        final midBatch = backend.directBatches.last;
        expect(midBatch.transformedInstanceCount, equals(1));
        expect(midBatch.transformedInstanceData[15], closeTo(0.5, 1e-3));

        // Complete tween (120 ms >= 100 ms): hasActiveTweens becomes false,
        // and direct GPU batch MUST reach final 1.0 rad pose (not freeze at 0.5).
        simNow = const Duration(milliseconds: 120);
        await tester.pump(const Duration(milliseconds: 16));
        final finalBatch = backend.directBatches.last;
        expect(surfaceKey.currentState!.debugIsTweenTickerActive, isFalse);
        expect(finalBatch.transformedInstanceData[15], closeTo(1.0, 1e-3));
        expect(
          finalBatch.transformedGeneration,
          greaterThan(midBatch.transformedGeneration),
        );

        // L1: Buffer monotonic regionRevision & transformRevision advance on in-place replacements.
        final revBefore = buffer.regionRevision;
        buffer.addShaderRegion(
          ShaderRegion(
            id: 'r1',
            shaderId: 'fire',
            sourceRects: const <tui_geo.Rect>[tui_geo.Rect(0, 0, 4, 1)],
          ),
        );
        final revAfterAdd = buffer.regionRevision;
        expect(revAfterAdd, greaterThan(revBefore));
        buffer.addShaderRegion(
          ShaderRegion(
            id: 'r1',
            shaderId: 'ice_frost',
            sourceRects: const <tui_geo.Rect>[tui_geo.Rect(0, 0, 4, 1)],
          ),
        );
        expect(buffer.regionRevision, greaterThan(revAfterAdd));
      },
    );
  });

  group('Batch 3 regressions (C1, H1, M4, L2, L4)', () {
    test('M4: wrapped multi-rect ShaderRegion partitions disconnected row-runs so BOTH fragments hit and survive 512px cap', () async {
      final atlas = await GlyphAtlasGenerator.generate(
        fontSize: 14.0,
        fontFamily: 'Roboto Mono',
      );
      addTearDown(atlas.dispose);

      // 100-col wide pane (1000 logical px at 10 px/cell) with a wrapped phrase:
      // fragment 0 at right edge of row 2 (cols 85..100), fragment 1 at left edge of row 3 (cols 0..15).
      final wrappedRegion = ShaderRegion(
        id: 'r_wrapped',
        shaderId: 'fire',
        sourceRects: const <tui_geo.Rect>[
          tui_geo.Rect(85, 2, 15, 1),
          tui_geo.Rect(0, 3, 15, 1),
        ],
        padding: const CellPadding(top: 2, bottom: 0, left: 1, right: 1),
      );
      final layouts = ComputedShaderRegionLayout.computeAll(
        region: wrappedRegion,
        gridCols: 100,
        gridRows: 10,
        cellWidth: 10.0,
        cellHeight: 20.0,
        paneLogicalSize: const ui.Size(1000.0, 200.0),
        devicePixelRatio: 1.0,
      );

      // Must partition into 2 independent sub-layouts instead of 1 centered 512px crop!
      expect(layouts, hasLength(2));
      expect(layouts[0].layoutId, equals('r_wrapped#0'));
      expect(layouts[1].layoutId, equals('r_wrapped#1'));

      // Fragment 0 MUST hit cell (90, 2) -> logical point (905, 50).
      expect(
        layouts[0].outputRectLogical.contains(const ui.Offset(905, 50)),
        isTrue,
      );
      expect(layouts[0].outputRectLogical.width, lessThanOrEqualTo(512.0));
      expect(layouts[0].sourceCellIndices, contains(2 * 100 + 85));
      expect(layouts[0].sourceCellIndices, isNot(contains(3 * 100 + 0)));

      // Fragment 1 MUST hit cell (5, 3) -> logical point (55, 70).
      expect(
        layouts[1].outputRectLogical.contains(const ui.Offset(55, 70)),
        isTrue,
      );
      expect(layouts[1].outputRectLogical.width, lessThanOrEqualTo(512.0));
      expect(layouts[1].sourceCellIndices, contains(3 * 100 + 0));
      expect(layouts[1].sourceCellIndices, isNot(contains(2 * 100 + 85)));

      // Stager emits 2 mask slices covering both wrapped fragments.
      final buf = Buffer(100, 10)
        ..writeString(85, 2, 'this word is on', Style.empty)
        ..writeString(0, 3, 'fire across wrap', Style.empty);
      final stager = ShaderRegionGpuStager();
      final staged = stager.stageRegionMasks(
        buffer: buf,
        atlas: atlas,
        regions: <ShaderRegion>[wrappedRegion],
        paneLogicalSize: ui.Size(100 * atlas.cellWidth, 10 * atlas.cellHeight),
        devicePixelRatio: 1.0,
        defaultForegroundArgb: 0xFFFFFFFF,
        defaultBackgroundArgb: 0xFF000000,
        faintOpacity: 0.5,
        palette: TerminalColorTheme.termuiDark,
      );
      expect(staged.layouts, hasLength(2));
      expect(staged.slices.map((s) => s.regionId).toList(), <String>[
        'r_wrapped#0',
        'r_wrapped#1',
      ]);
      expect(staged.slices[0].instanceCount, greaterThan(0));
      expect(staged.slices[1].instanceCount, greaterThan(0));

      // Adjacent overlapping rects within 512px stay merged as 1 layout with bare region.id.
      final compactRegion = ShaderRegion(
        id: 'r_compact',
        shaderId: 'fire',
        sourceRects: const <tui_geo.Rect>[
          tui_geo.Rect(2, 2, 6, 1),
          tui_geo.Rect(2, 3, 6, 1),
        ],
        padding: const CellPadding(top: 1, bottom: 1, left: 1, right: 1),
      );
      final compactLayouts = ComputedShaderRegionLayout.computeAll(
        region: compactRegion,
        gridCols: 40,
        gridRows: 10,
        cellWidth: 10.0,
        cellHeight: 20.0,
        paneLogicalSize: const ui.Size(400.0, 200.0),
        devicePixelRatio: 1.0,
      );
      expect(compactLayouts, hasLength(1));
      expect(compactLayouts.single.layoutId, equals('r_compact'));
    });

    test('C1, H1, L2, L4: per-slot GpuKeyedPool, 4-frame GpuFrameBumpAllocator, GpuPingPongRegistry owner/prefix eviction, and 12-entry GpuSizePool', () {
      // C1: Equal-sized regions in distinct slots obtain distinct textures.
      final regionPool = GpuKeyedPool<(int, int, int), String>(maxEntries: 4);
      var nextTexId = 0;
      final slot0 = regionPool.obtain((0, 128, 64), () => 'tex_${nextTexId++}');
      final slot1 = regionPool.obtain((1, 128, 64), () => 'tex_${nextTexId++}');
      expect(slot0, isNot(equals(slot1)));
      expect(
        regionPool.obtain((0, 128, 64), () => 'tex_${nextTexId++}'),
        equals(slot0),
      );

      // H1: GpuFrameBumpAllocator serves 10 aligned non-overlapping slices in
      // one frame, spills cleanly to a new block at exact capacity boundary,
      // and cycles 4 frames before reusing bucket 0.
      final allocator = GpuFrameBumpAllocator<String>(
        framesInFlight: 4,
        blockSizeBytes: 1024,
      );
      var nextBlockId = 0;
      final seenRanges = <(String, int, int)>[];
      for (var i = 0; i < 6; i++) {
        final slice = allocator.allocate(
          byteLength: 300,
          alignment: 256,
          createBlock: (_) => 'blk_${nextBlockId++}',
        );
        expect(slice.offsetInBytes % 256, equals(0));
        expect(slice.lengthInBytes, equals(300));
        // Ensure zero overlap with any prior slice in the same frame.
        for (final prev in seenRanges) {
          if (prev.$1 == slice.buffer) {
            final noOverlap =
                slice.offsetInBytes >= prev.$3 ||
                slice.offsetInBytes + slice.lengthInBytes <= prev.$2;
            expect(noOverlap, isTrue);
          }
        }
        seenRanges.add((
          slice.buffer,
          slice.offsetInBytes,
          slice.offsetInBytes + slice.lengthInBytes,
        ));
      }
      // 300 aligned to 256 -> offsets 0, 512 in blk_0 (total 812); next 300 needs 1024+300>1024 -> spills cleanly to blk_1!
      expect(
        seenRanges.map((r) => r.$1).toSet().length,
        greaterThanOrEqualTo(2),
      );

      final frame0Buf = seenRanges.first.$1;
      for (var f = 0; f < 3; f++) {
        allocator.advanceFrame();
        final s = allocator.allocate(
          byteLength: 256,
          alignment: 256,
          createBlock: (_) => 'blk_${nextBlockId++}',
        );
        expect(s.buffer, isNot(equals(frame0Buf)));
      }
      // 4th advance cycles back to frame 0's bucket.
      allocator.advanceFrame();
      final reused = allocator.allocate(
        byteLength: 256,
        alignment: 256,
        createBlock: (_) => 'blk_${nextBlockId++}',
      );
      expect(reused.buffer, equals(frame0Buf));
      expect(reused.offsetInBytes, equals(0));

      // L2: GpuPingPongRegistry evicts by ownerTag and by paneKey prefix.
      final pingPong = GpuPingPongRegistry<String>(maxEntries: 16);
      pingPong.acquire(
        'paneA:region:r1',
        64,
        32,
        (_, _) => 't',
        ownerTag: 'sh1',
      );
      pingPong.acquire('paneB:sh1', 64, 32, (_, _) => 't', ownerTag: 'sh1');
      pingPong.acquire(
        'paneA:region:r2',
        64,
        32,
        (_, _) => 't',
        ownerTag: 'sh2',
      );
      pingPong.acquire(
        'paneB:region:r3',
        64,
        32,
        (_, _) => 't',
        ownerTag: 'sh2',
      );
      expect(pingPong.length, equals(4));
      expect(pingPong.removeByOwnerTag('sh1'), equals(2));
      expect(pingPong.length, equals(2));
      expect(pingPong.removeByPrefix('paneA:'), equals(1));
      expect(pingPong.length, equals(1));

      // L4: GpuSizePool with maxEntries 12 retains 8 distinct pane sizes without eviction.
      final sizePool = GpuSizePool<String>(maxEntries: 12);
      var creates = 0;
      for (var i = 0; i < 8; i++) {
        sizePool.obtain(100 + i * 10, 80, (_, _) => 's_${creates++}');
      }
      for (var i = 0; i < 8; i++) {
        sizePool.obtain(100 + i * 10, 80, (_, _) => 's_${creates++}');
      }
      expect(creates, equals(8));
      expect(sizePool.length, equals(8));
    });
  });

  group('Batch 4 regressions (M5, M6, M7)', () {
    test('M5: row-interval union deduplicates overlapping sourceRects and enforces pane pixel budget', () {
      final overlappingRects = <tui_geo.Rect>[
        for (var i = 0; i < 32; i++) const tui_geo.Rect(0, 0, 12, 4),
        const tui_geo.Rect(10, 1, 6, 2),
        // Overlaps (10,1,6,2) -> same cluster with gap [12..14) on row 0.
        const tui_geo.Rect(14, 0, 2, 2),
        // Disconnected -> 2nd cluster.
        const tui_geo.Rect(24, 0, 2, 1),
      ];
      final region = ShaderRegion(
        id: 'overlap',
        shaderId: 'fire',
        sourceRects: overlappingRects,
        padding: CellPadding.zero,
      );
      final layouts = ComputedShaderRegionLayout.computeAll(
        region: region,
        gridCols: 40,
        gridRows: 10,
        cellWidth: 8.0,
        cellHeight: 16.0,
        paneLogicalSize: const Size(320, 160),
        devicePixelRatio: 1.0,
      );
      expect(layouts, hasLength(2));
      // Cluster 0:
      //   Row 0: [0..12) + [14..16) = 14 cells
      //   Row 1: [0..16) = 16 cells
      //   Row 2: [0..16) = 16 cells
      //   Row 3: [0..12) = 12 cells
      //   Total = 58 unique cells in strict row-major order.
      final cluster0 = layouts.first;
      expect(cluster0.sourceCellIndices, hasLength(58));
      expect(cluster0.sourceCellIndices.toSet(), hasLength(58));
      expect(cluster0.sourceCellIndices.first, equals(0));
      expect(cluster0.sourceCellIndices.contains(12), isFalse);
      expect(cluster0.sourceCellIndices.contains(14), isTrue);
      expect(cluster0.sourceCellIndices.contains(40 + 15), isTrue);
      // Cluster 1: Row 0 [24..26) = 2 cells.
      expect(layouts[1].sourceCellIndices, equals(<int>[24, 25]));

      // Per-pane physical pixel budget truncates excess max-size regions.
      final bigLayouts = <ComputedShaderRegionLayout>[
        for (var i = 0; i < 6; i++)
          ComputedShaderRegionLayout(
            region: ShaderRegion(
              id: 'big_$i',
              shaderId: 'fire',
              zIndex: i,
              sourceRects: const <tui_geo.Rect>[tui_geo.Rect(0, 0, 10, 10)],
            ),
            sourceUnionLogical: const Rect.fromLTWH(0, 0, 512, 512),
            outputRectLogical: const Rect.fromLTWH(0, 0, 512, 512),
            outputRectPhysical: const Rect.fromLTWH(0, 0, 1024, 1024),
            physicalWidth: 1024,
            physicalHeight: 1024,
            sourceCellIndices: const <int>[0],
          ),
      ];
      final budgeted = ComputedShaderRegionLayout.applyPanePixelBudget(
        bigLayouts,
      );
      // 2048 * 2048 = 4 * (1024 * 1024) -> keeps first 4 in zIndex order.
      expect(budgeted, hasLength(4));
      expect(
        budgeted.map((l) => l.layoutId),
        equals(<String>['big_0', 'big_1', 'big_2', 'big_3']),
      );
    });

    test('M5: GpuFrameWatchdog throttles slow built-in presets to 30 FPS without quarantining and recovers', () {
      final quarantined = <String>[];
      final watchdog = GpuFrameWatchdog(
        isBuiltinPreset: ShaderRegionPresets.isPreset,
        onShaderQuarantined: (id, _) => quarantined.add(id),
      );
      addTearDown(watchdog.dispose);

      watchdog.setActiveBuiltinPresets(true);
      expect(watchdog.throttledPresetMaxFps, isNull);

      for (var i = 0; i < 3; i++) {
        watchdog.recordPresetFrameDuration(const Duration(milliseconds: 40));
      }
      expect(
        watchdog.throttledPresetMaxFps,
        equals(GpuFrameWatchdog.defaultThrottledPresetFps),
      );
      expect(quarantined, isEmpty);
      expect(watchdog.isQuarantined('fire'), isFalse);

      // 9 fast frames are not enough to lift throttling; 10th recovers.
      for (var i = 0; i < 9; i++) {
        watchdog.recordPresetFrameDuration(const Duration(milliseconds: 10));
      }
      expect(
        watchdog.throttledPresetMaxFps,
        equals(GpuFrameWatchdog.defaultThrottledPresetFps),
      );
      watchdog.recordPresetFrameDuration(const Duration(milliseconds: 10));
      expect(watchdog.throttledPresetMaxFps, isNull);

      // Clearing active built-in presets immediately lifts throttling.
      for (var i = 0; i < 3; i++) {
        watchdog.recordPresetFrameDuration(const Duration(milliseconds: 45));
      }
      expect(watchdog.throttledPresetMaxFps, isNotNull);
      watchdog.setActiveBuiltinPresets(false);
      expect(watchdog.throttledPresetMaxFps, isNull);
    });

    testWidgets(
      'M6: watchdog resists UI-stall false quarantine, sweeps timeouts, attaches external FrameTiming, and isolates panes',
      (tester) async {
        // 1. UI-stall false-quarantine protection when FrameTiming raster is fast.
        final watchdog = GpuFrameWatchdog(
          isBuiltinPreset: ShaderRegionPresets.isPreset,
        );
        addTearDown(watchdog.dispose);
        watchdog.attachFrameTimingsCallback();
        watchdog.setActiveCustomShaders(const <String>['fx_ui_stall']);

        final fastTiming = FrameTiming(
          vsyncStart: 0,
          buildStart: 0,
          buildFinish: 3000,
          rasterStart: 3000,
          rasterFinish: 7000, // 4 ms raster duration (healthy GPU)
          rasterFinishWallTime: 7000,
        );
        watchdog.handleFrameTimings(<FrameTiming>[fastTiming]);

        // 4 submissions with inflated 80 ms UI-thread Stopwatch must NOT trip.
        for (var i = 0; i < 4; i++) {
          final token = watchdog.beginCommandSubmission(const <String>[
            'fx_ui_stall',
          ]);
          watchdog.completeCommandSubmission(
            token,
            success: true,
            gpuDuration: const Duration(milliseconds: 80),
          );
        }
        expect(watchdog.isQuarantined('fx_ui_stall'), isFalse);
        expect(watchdog.pendingSubmissionCount, equals(0));

        // Real slow raster timings DO trip quarantine after 3 consecutive frames.
        final slowTiming = FrameTiming(
          vsyncStart: 0,
          buildStart: 0,
          buildFinish: 2000,
          rasterStart: 2000,
          rasterFinish: 45000, // 43 ms raster duration
          rasterFinishWallTime: 45000,
        );
        watchdog.handleFrameTimings(<FrameTiming>[
          slowTiming,
          slowTiming,
          slowTiming,
        ]);
        expect(watchdog.isQuarantined('fx_ui_stall'), isTrue);

        // 2. External watchdog receives FrameTiming attachment in TerminalSurface
        //    and two sibling panes pass isolated per-call watchdogs without
        //    mutating shared backend.watchdog.
        final outImg = await _makeSolidImage();
        addTearDown(outImg.dispose);
        final backend = _FakeDirectBackend(imageFactory: () => outImg.clone());
        final controller = TerminalShaderController(backend: backend);
        addTearDown(controller.dispose);
        final wdA = GpuFrameWatchdog(
          isBuiltinPreset: ShaderRegionPresets.isPreset,
        );
        final wdB = GpuFrameWatchdog(
          isBuiltinPreset: ShaderRegionPresets.isPreset,
        );
        addTearDown(wdA.dispose);
        addTearDown(wdB.dispose);

        final bufA = Buffer.blank(10, 4)
          ..writeString(0, 0, 'PaneA', Style.empty);
        final bufB = Buffer.blank(10, 4)
          ..writeString(0, 0, 'PaneB', Style.empty);
        bufA.addShaderRegion(
          ShaderRegion(
            id: 'rA',
            shaderId: 'fire',
            sourceRects: const <tui_geo.Rect>[tui_geo.Rect(0, 0, 5, 1)],
          ),
        );
        bufB.addShaderRegion(
          ShaderRegion(
            id: 'rB',
            shaderId: 'fire',
            sourceRects: const <tui_geo.Rect>[tui_geo.Rect(0, 0, 5, 1)],
          ),
        );

        await tester.pumpWidget(
          Directionality(
            textDirection: TextDirection.ltr,
            child: Row(
              children: <Widget>[
                SizedBox(
                  width: 120,
                  height: 80,
                  child: TerminalSurface(
                    key: const ValueKey<String>('paneA'),
                    buffer: bufA,
                    shaderController: controller,
                    shaderConfig: const TerminalShaderConfig(enabled: true),
                    gpuFrameWatchdog: wdA,
                    autofocus: false,
                  ),
                ),
                SizedBox(
                  width: 120,
                  height: 80,
                  child: TerminalSurface(
                    key: const ValueKey<String>('paneB'),
                    buffer: bufB,
                    shaderController: controller,
                    shaderConfig: const TerminalShaderConfig(enabled: true),
                    gpuFrameWatchdog: wdB,
                    autofocus: false,
                  ),
                ),
              ],
            ),
          ),
        );
        await tester.pump();
        await tester.pump();

        expect(wdA.isFrameTimingsAttached, isTrue);
        expect(wdB.isFrameTimingsAttached, isTrue);
        expect(wdA.hasActiveBuiltinPresets, isTrue);
        expect(wdB.hasActiveBuiltinPresets, isTrue);
        // Shared backend.watchdog is NOT mutated; per-call watchdogs are isolated.
        expect(backend.watchdog, isNull);
        expect(
          backend.directWatchdogs,
          containsAll(<GpuFrameWatchdog>[wdA, wdB]),
        );

        // Unmounting detaches FrameTiming without disposing external watchdogs.
        await tester.pumpWidget(const SizedBox.shrink());
        expect(wdA.isFrameTimingsAttached, isFalse);
        expect(wdB.isFrameTimingsAttached, isFalse);
        expect(wdA.isDisposed, isFalse);
        expect(wdB.isDisposed, isFalse);
      },
    );

    test('M7: WebGL2 ping-pong LRU eviction and WebGlRegionTargetPool triple caching/deletion', () {
      // 1. GpuPingPongRegistry invokes onEvict for both textures on LRU,
      //    resize, removeByOwnerTag, and clear(invokeOnEvict: true), while
      //    skipping onEvict on context-loss clear(invokeOnEvict: false).
      final evicted = <String>[];
      var nextId = 0;
      final pp = GpuPingPongRegistry<String>(
        maxEntries: 2,
        onEvict: evicted.add,
      );
      pp.tryAcquire(
        'p1:r1',
        64,
        32,
        (w, h) => 'tex_${nextId++}_${w}x$h',
        ownerTag: 'shA',
      );
      pp.tryAcquire(
        'p1:r2',
        64,
        32,
        (w, h) => 'tex_${nextId++}_${w}x$h',
        ownerTag: 'shB',
      );
      // 3rd entry evicts p1:r1 (2 textures deleted).
      pp.tryAcquire(
        'p1:r3',
        64,
        32,
        (w, h) => 'tex_${nextId++}_${w}x$h',
        ownerTag: 'shA',
      );
      expect(pp.length, equals(2));
      expect(evicted, equals(<String>['tex_0_64x32', 'tex_1_64x32']));

      // Resize p1:r2 deletes its previous pair.
      pp.tryAcquire(
        'p1:r2',
        128,
        64,
        (w, h) => 'tex_${nextId++}_${w}x$h',
        ownerTag: 'shB',
      );
      expect(evicted, hasLength(4));

      // removeByOwnerTag deletes only matching ownerTag's pair.
      expect(pp.removeByOwnerTag('shA'), equals(1));
      expect(evicted, hasLength(6));
      expect(pp.length, equals(1));

      // Context-loss clear skips GL deletes.
      pp.clear(invokeOnEvict: false);
      expect(evicted, hasLength(6));
      expect(pp.length, equals(0));

      // 2. WebGlRegionTargetPool pools multi-size region FBO triples without
      //    reallocations and caches uGlyphMask freshness per (paneKey, regionId).
      final deletedFbos = <String>[];
      var fboAllocCount = 0;
      final regionPool = WebGlRegionTargetPool<String>(
        maxEntries: 4,
        onDelete: deletedFbos.add,
      );
      final maskBuf = Float32List(16);
      final atlasA = Object();
      final atlasB = Object();

      String createFbo(int w, int h) => 'fbo_${fboAllocCount++}_${w}x$h';

      final r1Frame1 = regionPool.acquire(
        paneKey: 'pane1',
        regionId: 'fire',
        width: 120,
        height: 48,
        maskData: maskBuf,
        maskGeneration: 1,
        startInstance: 0,
        instanceCount: 5,
        atlasToken: atlasA,
        createTarget: createFbo,
      );
      final r2Frame1 = regionPool.acquire(
        paneKey: 'pane1',
        regionId: 'ice',
        width: 240,
        height: 64,
        maskData: maskBuf,
        maskGeneration: 1,
        startInstance: 5,
        instanceCount: 8,
        atlasToken: atlasA,
        createTarget: createFbo,
      );
      expect(r1Frame1!.maskCacheHit, isFalse);
      expect(r2Frame1!.maskCacheHit, isFalse);
      expect(fboAllocCount, equals(6)); // 2 regions * 3 FBOs

      // Second frame with identical mask & different sizes: zero reallocations
      // and both report maskCacheHit: true!
      final r1Frame2 = regionPool.acquire(
        paneKey: 'pane1',
        regionId: 'fire',
        width: 120,
        height: 48,
        maskData: maskBuf,
        maskGeneration: 1,
        startInstance: 0,
        instanceCount: 5,
        atlasToken: atlasA,
        createTarget: createFbo,
      );
      final r2Frame2 = regionPool.acquire(
        paneKey: 'pane1',
        regionId: 'ice',
        width: 240,
        height: 64,
        maskData: maskBuf,
        maskGeneration: 1,
        startInstance: 5,
        instanceCount: 8,
        atlasToken: atlasA,
        createTarget: createFbo,
      );
      expect(r1Frame2!.maskCacheHit, isTrue);
      expect(r2Frame2!.maskCacheHit, isTrue);
      expect(fboAllocCount, equals(6));
      expect(deletedFbos, isEmpty);

      // Atlas swap or generation bump invalidates mask without reallocating FBOs.
      final r1AtlasSwap = regionPool.acquire(
        paneKey: 'pane1',
        regionId: 'fire',
        width: 120,
        height: 48,
        maskData: maskBuf,
        maskGeneration: 1,
        startInstance: 0,
        instanceCount: 5,
        atlasToken: atlasB,
        createTarget: createFbo,
      );
      expect(r1AtlasSwap!.maskCacheHit, isFalse);
      expect(fboAllocCount, equals(6));

      // Pane-scoped removal deletes only pane1's 6 FBOs.
      regionPool.acquire(
        paneKey: 'pane2',
        regionId: 'fire',
        width: 120,
        height: 48,
        maskData: maskBuf,
        maskGeneration: 1,
        startInstance: 0,
        instanceCount: 5,
        atlasToken: atlasA,
        createTarget: createFbo,
      );
      expect(regionPool.removePane('pane1'), equals(2));
      expect(deletedFbos, hasLength(6));
      expect(regionPool.length, equals(1));

      // Context-loss clear(invokeOnDelete: false) drops without GL delete.
      regionPool.clear(invokeOnDelete: false);
      expect(deletedFbos, hasLength(6));
      expect(regionPool.length, equals(0));
    });
  });
}
