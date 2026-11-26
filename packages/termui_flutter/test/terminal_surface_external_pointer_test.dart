import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:termui/terminal/terminal.dart' as term;
import 'package:termui/ui/buffer.dart';
import 'package:termui/ui/style.dart';
import 'package:termui_flutter/termui_flutter.dart';

const String _mouseBgGlsl = '''
void mainImage(out vec4 fragColor, in vec2 fragCoord) {
  float d = length(fragCoord - iMouse.xy);
  float press = step(0.0, iMouse.z);
  fragColor = vec4(step(d, 12.0), press, 0.0, 1.0);
}
''';

final class _FakeShaderHandle implements CompiledShaderHandle {
  @override
  final String id;

  @override
  final bool usesPrevFrame;

  bool disposed = false;

  _FakeShaderHandle({required this.id, required this.usesPrevFrame});

  @override
  void dispose() {
    disposed = true;
  }
}

final class _FakeMouseShaderBackend implements TerminalShaderBackend {
  final ui.Image Function() _imageFactory;
  final List<_FakeShaderHandle> _handles = <_FakeShaderHandle>[];
  final List<List<double>> recordedMouseXyzw = <List<double>>[];

  _FakeMouseShaderBackend(this._imageFactory);

  @override
  ShaderBackendKind get kind => ShaderBackendKind.flutterGpu;

  @override
  bool get supportsCustomGlsl => true;

  @override
  bool get supportsSyncBackground => true;

  List<double> get lastMouseXyzw => recordedMouseXyzw.last;

  @override
  Future<CompiledShaderHandle> compile(
    String id,
    String shadertoyGlsl, {
    bool usesPrevFrame = false,
  }) async {
    final handle = _FakeShaderHandle(id: id, usesPrevFrame: usesPrevFrame);
    _handles.add(handle);
    return handle;
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
  }) {
    if (passes.isNotEmpty) {
      recordedMouseXyzw.add(List<double>.of(passes.first.uniforms.mouseXyzw));
    }
    return _imageFactory();
  }

  @override
  Future<ui.Image?> renderPassesAsync({
    required List<ShaderPassInvocation> passes,
    required ui.Size physicalSize,
    ui.Image? inputImage,
    ui.Image? wallpaperImage,
    GpuFrameWatchdog? watchdog,
  }) async => _imageFactory();

  @override
  void dispose() {
    for (final handle in _handles) {
      handle.dispose();
    }
  }
}

Future<ui.Image> _createSolidImage() async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawRect(
    const Rect.fromLTWH(0, 0, 8, 8),
    Paint()..color = const Color(0xFF102030),
  );
  final picture = recorder.endRecording();
  try {
    return await picture.toImage(8, 8);
  } finally {
    picture.dispose();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('TerminalSurfaceState external iMouse pointer hook', () {
    testWidgets(
      'hover, press, drag, release, clamping, and clear update iMouse without emitting PTY events',
      (tester) async {
        const dpr = 2.0;
        tester.view.devicePixelRatio = dpr;
        addTearDown(tester.view.resetDevicePixelRatio);

        final backingImage = await tester.runAsync(_createSolidImage);
        addTearDown(() => backingImage?.dispose());

        final atlasController = GlyphAtlasController(
          fontSize: 13.0,
          fontFamily: 'Roboto Mono',
          devicePixelRatio: dpr,
        );
        addTearDown(atlasController.dispose);
        await tester.runAsync(atlasController.ensureInitialized);
        final atlas = atlasController.atlas!;

        final backend = _FakeMouseShaderBackend(() => backingImage!.clone());
        final shaderController = TerminalShaderController(backend: backend);
        addTearDown(shaderController.dispose);

        final shaderConfig = TerminalShaderConfig(
          backgroundPasses: <ShaderPassSpec>[
            ShaderPassSpec(
              id: 'bg:mouse',
              stage: TerminalShaderStage.background,
              inlineGlsl: _mouseBgGlsl,
            ),
          ],
          animationMode: ShaderAnimationMode.staticOnly,
        );
        await tester.runAsync(() => shaderController.syncConfig(shaderConfig));

        final surfaceKey = GlobalKey<TerminalSurfaceState>();
        final inputEvents = <term.InputEvent>[];
        final buffer = Buffer(20, 10)..writeString(0, 0, 'HELLO', Style.empty);

        final paneWidth = 20 * atlas.cellWidth;
        final paneHeight = 10 * atlas.cellHeight;
        final physW = paneWidth * dpr;
        final physH = paneHeight * dpr;

        await tester.pumpWidget(
          Directionality(
            textDirection: TextDirection.ltr,
            child: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: paneWidth,
                height: paneHeight,
                child: TerminalSurface(
                  key: surfaceKey,
                  atlasController: atlasController,
                  buffer: buffer,
                  shaderController: shaderController,
                  shaderConfig: shaderConfig,
                  mouseTracking: true,
                  onInputEvent: inputEvents.add,
                  alignment: Alignment.topLeft,
                ),
              ),
            ),
          ),
        );
        await tester.pump();

        final state = surfaceKey.currentState!;
        expect(
          state.lastLogicalLayoutSize,
          equals(Size(paneWidth, paneHeight)),
        );
        expect(backend.recordedMouseXyzw, isNotEmpty);
        expect(backend.lastMouseXyzw, equals(<double>[0.0, 0.0, 0.0, 0.0]));

        // 1. Hover: z == 0, w == 0, Y flipped to Shadertoy bottom-left origin.
        state.injectShaderPointerNormalized(x: 0.25, y: 0.75);
        await tester.pump();
        expect(backend.lastMouseXyzw[0], closeTo(0.25 * physW, 0.5));
        expect(backend.lastMouseXyzw[1], closeTo(0.25 * physH, 0.5));
        expect(backend.lastMouseXyzw[2], equals(0.0));
        expect(backend.lastMouseXyzw[3], equals(0.0));

        // 2. Press (false -> true): sets positive click origin (z > 0, w > 0).
        state.injectShaderPointerNormalized(x: 0.2, y: 0.4, pressed: true);
        await tester.pump();
        final pressClickX = 0.2 * physW;
        final pressClickY = 0.6 * physH;
        expect(backend.lastMouseXyzw[0], closeTo(pressClickX, 0.5));
        expect(backend.lastMouseXyzw[1], closeTo(pressClickY, 0.5));
        expect(backend.lastMouseXyzw[2], closeTo(pressClickX, 0.5));
        expect(backend.lastMouseXyzw[3], closeTo(pressClickY, 0.5));
        expect(backend.lastMouseXyzw[2], greaterThan(0.0));
        expect(backend.lastMouseXyzw[3], greaterThan(0.0));

        // 3. Drag (true -> true): updates xy while preserving initial click origin.
        state.injectShaderPointerNormalized(x: 0.8, y: 0.6, pressed: true);
        await tester.pump();
        expect(backend.lastMouseXyzw[0], closeTo(0.8 * physW, 0.5));
        expect(backend.lastMouseXyzw[1], closeTo(0.4 * physH, 0.5));
        expect(backend.lastMouseXyzw[2], closeTo(pressClickX, 0.5));
        expect(backend.lastMouseXyzw[3], closeTo(pressClickY, 0.5));

        // 4. Release (true -> false): negates preserved click origin (z < 0, w < 0).
        state.injectShaderPointerNormalized(x: 0.9, y: 0.1, pressed: false);
        await tester.pump();
        expect(backend.lastMouseXyzw[0], closeTo(0.9 * physW, 0.5));
        expect(backend.lastMouseXyzw[1], closeTo(0.9 * physH, 0.5));
        expect(backend.lastMouseXyzw[2], closeTo(-pressClickX, 0.5));
        expect(backend.lastMouseXyzw[3], closeTo(-pressClickY, 0.5));
        expect(backend.lastMouseXyzw[2], lessThan(0.0));
        expect(backend.lastMouseXyzw[3], lessThan(0.0));

        // 5. New press after release replaces click origin; out-of-range inputs clamp.
        state.injectShaderPointerNormalized(x: 1.75, y: -0.5, pressed: true);
        await tester.pump();
        expect(backend.lastMouseXyzw[0], closeTo(physW, 0.5));
        expect(backend.lastMouseXyzw[1], closeTo(physH, 0.5));
        expect(backend.lastMouseXyzw[2], closeTo(physW, 0.5));
        expect(backend.lastMouseXyzw[3], closeTo(physH, 0.5));

        // Out-of-range drag clamps to [0.0, 1.0] (x=0, y=1 -> bottom-left (0, 0) in Y-up).
        state.injectShaderPointerNormalized(x: -2.0, y: 3.0, pressed: true);
        await tester.pump();
        expect(backend.lastMouseXyzw[0], closeTo(0.0, 0.5));
        expect(backend.lastMouseXyzw[1], closeTo(0.0, 0.5));
        expect(backend.lastMouseXyzw[2], closeTo(physW, 0.5));
        expect(backend.lastMouseXyzw[3], closeTo(physH, 0.5));

        // Press at exact (0.0, 0.0) uses non-zero floor so z > 0 on press and z < 0 on release.
        state.injectShaderPointerNormalized(x: 0.0, y: 0.0, pressed: false);
        await tester.pump();
        state.injectShaderPointerNormalized(x: 0.0, y: 0.0, pressed: true);
        await tester.pump();
        expect(backend.lastMouseXyzw[2], greaterThan(0.0));
        expect(backend.lastMouseXyzw[3], greaterThan(0.0));

        // NaN input is ignored without corrupting uniforms.
        final beforeNan = List<double>.of(backend.lastMouseXyzw);
        state.injectShaderPointerNormalized(
          x: double.nan,
          y: 0.5,
          pressed: false,
        );
        await tester.pump();
        expect(backend.lastMouseXyzw, equals(beforeNan));

        // 6. clearInjectedShaderPointer resets iMouse to zero and clears click history.
        state.clearInjectedShaderPointer();
        await tester.pump();
        expect(backend.lastMouseXyzw, equals(<double>[0.0, 0.0, 0.0, 0.0]));

        // Hover after clear keeps z == 0 and w == 0 (no stale negative click).
        state.injectShaderPointerNormalized(x: 0.5, y: 0.5, pressed: false);
        await tester.pump();
        expect(backend.lastMouseXyzw[0], closeTo(0.5 * physW, 0.5));
        expect(backend.lastMouseXyzw[1], closeTo(0.5 * physH, 0.5));
        expect(backend.lastMouseXyzw[2], equals(0.0));
        expect(backend.lastMouseXyzw[3], equals(0.0));

        // External iMouse injection must never emit PTY mouse events.
        expect(inputEvents, isEmpty);
      },
    );

    testWidgets(
      'lastLogicalLayoutSize is null before atlas init and unmounted calls are safe no-ops',
      (tester) async {
        final atlasController = GlyphAtlasController(
          fontSize: 13.0,
          fontFamily: 'Roboto Mono',
          devicePixelRatio: 1.0,
        );
        addTearDown(atlasController.dispose);

        final surfaceKey = GlobalKey<TerminalSurfaceState>();
        await tester.pumpWidget(
          Directionality(
            textDirection: TextDirection.ltr,
            child: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: 200,
                height: 100,
                child: TerminalSurface(
                  key: surfaceKey,
                  atlasController: atlasController,
                  buffer: Buffer(20, 10),
                ),
              ),
            ),
          ),
        );

        final state = surfaceKey.currentState!;
        expect(state.lastLogicalLayoutSize, isNull);

        // Falls back to mounted RenderBox size safely before LayoutBuilder runs.
        expect(
          () => state.injectShaderPointerNormalized(
            x: 0.5,
            y: 0.5,
            pressed: true,
          ),
          returnsNormally,
        );
        expect(state.clearInjectedShaderPointer, returnsNormally);

        // Unmount surface and verify both methods are safe no-ops after dispose.
        await tester.pumpWidget(const SizedBox.shrink());
        expect(state.mounted, isFalse);
        expect(
          () => state.injectShaderPointerNormalized(
            x: 0.5,
            y: 0.5,
            pressed: true,
          ),
          returnsNormally,
        );
        expect(state.clearInjectedShaderPointer, returnsNormally);
      },
    );
  });
}
