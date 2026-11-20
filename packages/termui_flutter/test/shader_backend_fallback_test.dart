import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:termui_flutter/src/rendering/builtin_shaders.dart';
import 'package:termui_flutter/src/rendering/shader_backend.dart';
import 'package:termui_flutter/src/rendering/shader_backend_disabled.dart';
import 'package:termui_flutter/src/rendering/shader_backend_factory.dart';
import 'package:termui_flutter/src/rendering/shader_spec.dart';

final class _FakeGpuBackend implements TerminalShaderBackend {
  bool disposed = false;

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
  }) => throw UnimplementedError();

  @override
  Future<void> reload(CompiledShaderHandle handle, String shadertoyGlsl) =>
      throw UnimplementedError();

  @override
  ui.Image? renderBackgroundSync({
    required List<ShaderPassInvocation> passes,
    required ui.Size physicalSize,
    ui.Image? wallpaperImage,
  }) => null;

  @override
  Future<ui.Image?> renderPassesAsync({
    required List<ShaderPassInvocation> passes,
    required ui.Size physicalSize,
    ui.Image? inputImage,
    ui.Image? wallpaperImage,
  }) => Future<ui.Image?>.value();

  @override
  void dispose() {
    disposed = true;
  }
}

Future<ui.Image> _createSoftwareImage({int width = 4, int height = 4}) async {
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);
  canvas.drawRect(
    ui.Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
    ui.Paint()..color = const ui.Color(0xFF336699),
  );
  final picture = recorder.endRecording();
  try {
    return await picture.toImage(width, height);
  } finally {
    picture.dispose();
  }
}

void main() {
  group('createTerminalShaderBackend fallback and override selection', () {
    test('selects DisabledShaderBackend under flutter test software rendering '
        'with zero exceptions', () {
      final backend = createTerminalShaderBackend();
      expect(backend, isA<DisabledShaderBackend>());
      expect(backend.kind, ShaderBackendKind.disabled);
      expect(backend.supportsCustomGlsl, isFalse);
      expect(backend.supportsSyncBackground, isFalse);
      backend.dispose();
    });

    test('honors disabled and webGl2 overrides on native VM without invoking '
        'desktopGpuFactory', () {
      var desktopCalled = false;
      var webCalled = false;

      final disabled = createTerminalShaderBackend(
        override: ShaderBackendKind.disabled,
        desktopGpuFactory: () {
          desktopCalled = true;
          return _FakeGpuBackend();
        },
        webGl2Factory: () {
          webCalled = true;
          return _FakeGpuBackend();
        },
      );
      expect(disabled, isA<DisabledShaderBackend>());
      expect(disabled.kind, ShaderBackendKind.disabled);
      expect(desktopCalled, isFalse);
      expect(webCalled, isFalse);

      final webOnVm = createTerminalShaderBackend(
        override: ShaderBackendKind.webGl2,
        desktopGpuFactory: () {
          desktopCalled = true;
          return _FakeGpuBackend();
        },
      );
      expect(webOnVm, isA<DisabledShaderBackend>());
      expect(webOnVm.kind, ShaderBackendKind.disabled);
      expect(desktopCalled, isFalse);
    });

    test('returns desktop GPU backend when desktopGpuFactory succeeds for null '
        'and flutterGpu overrides', () {
      final defaultSelected = createTerminalShaderBackend(
        desktopGpuFactory: _FakeGpuBackend.new,
      );
      expect(defaultSelected, isA<_FakeGpuBackend>());
      expect(defaultSelected.kind, ShaderBackendKind.flutterGpu);
      defaultSelected.dispose();

      final forcedGpu = createTerminalShaderBackend(
        override: ShaderBackendKind.flutterGpu,
        desktopGpuFactory: _FakeGpuBackend.new,
      );
      expect(forcedGpu, isA<_FakeGpuBackend>());
      expect(forcedGpu.kind, ShaderBackendKind.flutterGpu);
      forcedGpu.dispose();
    });

    test('falls back cleanly to DisabledShaderBackend when desktopGpuFactory '
        'returns null or throws', () {
      final nullFallback = createTerminalShaderBackend(
        desktopGpuFactory: () => null,
      );
      expect(nullFallback, isA<DisabledShaderBackend>());

      final nullForcedFallback = createTerminalShaderBackend(
        override: ShaderBackendKind.flutterGpu,
        desktopGpuFactory: () => null,
      );
      expect(nullForcedFallback, isA<DisabledShaderBackend>());

      final unsupportedFallback = createTerminalShaderBackend(
        desktopGpuFactory: () => throw UnsupportedError('Skia desktop'),
      );
      expect(unsupportedFallback, isA<DisabledShaderBackend>());

      final stateErrorFallback = createTerminalShaderBackend(
        override: ShaderBackendKind.flutterGpu,
        desktopGpuFactory: () => throw StateError('No Impeller context'),
      );
      expect(stateErrorFallback, isA<DisabledShaderBackend>());
    });
  });

  group('DisabledShaderBackend lifecycle and disposal safety', () {
    test(
      'compiles lightweight handles, treats reload as no-op, and returns null '
      'from sync and async render paths without touching ImageFilter.shader',
      () async {
        const backend = DisabledShaderBackend();
        expect(backend.kind, ShaderBackendKind.disabled);
        expect(backend.supportsCustomGlsl, isFalse);
        expect(backend.supportsSyncBackground, isFalse);

        final bgHandle = await backend.compile(
          'bg_wave',
          BuiltinShaders.wallpaperWaveGlsl,
        );
        expect(bgHandle.id, 'bg_wave');
        expect(bgHandle.usesPrevFrame, isFalse);

        final fgHandle = await backend.compile(
          'fg_phosphor',
          BuiltinShaders.phosphorGlowGlsl,
          usesPrevFrame: true,
        );
        expect(fgHandle.id, 'fg_phosphor');
        expect(fgHandle.usesPrevFrame, isTrue);

        // Reload is a safe no-op even if given broken GLSL.
        await expectLater(
          backend.reload(bgHandle, 'not valid glsl {{{'),
          completes,
        );

        final uniforms = TerminalShaderUniforms(width: 640, height: 480);
        final inputImage = await _createSoftwareImage();
        final wallpaperImage = await _createSoftwareImage();
        try {
          final syncResult = backend.renderBackgroundSync(
            passes: <ShaderPassInvocation>[
              (handle: bgHandle, uniforms: uniforms, prevFrameKey: null),
            ],
            physicalSize: const ui.Size(640, 480),
            wallpaperImage: wallpaperImage,
          );
          expect(syncResult, isNull);

          final asyncResult = await backend.renderPassesAsync(
            passes: <ShaderPassInvocation>[
              (
                handle: fgHandle,
                uniforms: uniforms,
                prevFrameKey: 'pane_0:fg_phosphor',
              ),
            ],
            physicalSize: const ui.Size(640, 480),
            inputImage: inputImage,
            wallpaperImage: wallpaperImage,
          );
          expect(asyncResult, isNull);
        } finally {
          inputImage.dispose();
          wallpaperImage.dispose();
        }

        bgHandle.dispose();
        fgHandle.dispose();
        backend.dispose();
      },
    );

    test(
      'dispose is idempotent on both backend and compiled handles',
      () async {
        const backend = DisabledShaderBackend();
        final handle = await backend.compile(
          'scanline',
          BuiltinShaders.scanlineOverlayGlsl,
        );

        handle.dispose();
        handle.dispose();
        backend.dispose();
        backend.dispose();

        // Operations after repeated disposal remain safe no-ops.
        final postDisposeHandle = await backend.compile(
          'after_dispose',
          BuiltinShaders.crtLottesGlsl,
          usesPrevFrame: true,
        );
        expect(postDisposeHandle.id, 'after_dispose');
        expect(postDisposeHandle.usesPrevFrame, isTrue);
        await backend.reload(postDisposeHandle, BuiltinShaders.cursorGlowGlsl);
        expect(
          backend.renderBackgroundSync(
            passes: <ShaderPassInvocation>[
              (
                handle: postDisposeHandle,
                uniforms: TerminalShaderUniforms(width: 320, height: 240),
                prevFrameKey: null,
              ),
            ],
            physicalSize: const ui.Size(320, 240),
          ),
          isNull,
        );
        expect(
          await backend.renderPassesAsync(
            passes: <ShaderPassInvocation>[
              (
                handle: postDisposeHandle,
                uniforms: TerminalShaderUniforms(width: 320, height: 240),
                prevFrameKey: null,
              ),
            ],
            physicalSize: const ui.Size(320, 240),
          ),
          isNull,
        );
        postDisposeHandle.dispose();
      },
    );
  });
}
