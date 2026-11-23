import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:termui_flutter/src/rendering/builtin_shaders.dart';
import 'package:termui_flutter/src/rendering/gpu_frame_watchdog.dart';
import 'package:termui_flutter/src/rendering/impellerc_compiler_io.dart';
import 'package:termui_flutter/src/rendering/shader_backend.dart';
import 'package:termui_flutter/src/rendering/shader_backend_disabled.dart';
import 'package:termui_flutter/src/rendering/shader_backend_factory.dart';
import 'package:termui_flutter/src/rendering/shader_backend_gpu.dart';
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
    GpuFrameWatchdog? watchdog,
  }) => null;

  @override
  Future<ui.Image?> renderPassesAsync({
    required List<ShaderPassInvocation> passes,
    required ui.Size physicalSize,
    ui.Image? inputImage,
    ui.Image? wallpaperImage,
    GpuFrameWatchdog? watchdog,
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

  group('ImpellercCompiler path memoization and resetCache', () {
    test(
      'memoizes resolved hit until resetCache is called after file removal',
      () {
        final tempDir = Directory.systemTemp.createTempSync(
          'termui_impellerc_memo_hit_',
        );
        addTearDown(() => tempDir.deleteSync(recursive: true));
        final fakeBin = File(
          '${tempDir.path}${Platform.pathSeparator}impellerc_fake',
        )..writeAsStringSync('stub');

        final compiler = ImpellercCompiler(
          impellercPathOverride: fakeBin.path,
          environment: const <String, String>{},
          resolvedExecutablePath: '',
          fallbackSdkRoots: const <String>[],
        );

        expect(compiler.resolveImpellercPath(), fakeBin.path);
        expect(compiler.isAvailable, isTrue);

        // Removing the file on disk does not invalidate the memoized hit.
        fakeBin.deleteSync();
        expect(compiler.resolveImpellercPath(), fakeBin.path);
        expect(compiler.isAvailable, isTrue);

        // Resetting the cache forces a fresh probe and observes the removal.
        compiler.resetCache();
        expect(compiler.resolveImpellercPath(), isNull);
        expect(compiler.isAvailable, isFalse);
      },
    );

    test('memoizes miss until resetCache is called after file creation', () {
      final tempDir = Directory.systemTemp.createTempSync(
        'termui_impellerc_memo_miss_',
      );
      addTearDown(() => tempDir.deleteSync(recursive: true));
      final fakeBin = File(
        '${tempDir.path}${Platform.pathSeparator}impellerc_late',
      );

      final compiler = ImpellercCompiler(
        impellercPathOverride: fakeBin.path,
        environment: const <String, String>{},
        resolvedExecutablePath: '',
        fallbackSdkRoots: const <String>[],
      );

      expect(compiler.resolveImpellercPath(), isNull);
      expect(compiler.isAvailable, isFalse);

      // Creating the binary on disk does not invalidate the memoized miss.
      fakeBin.writeAsStringSync('stub');
      expect(compiler.resolveImpellercPath(), isNull);
      expect(compiler.isAvailable, isFalse);

      // Resetting the cache allows the new binary to be discovered.
      compiler.resetCache();
      expect(compiler.resolveImpellercPath(), fakeBin.path);
      expect(compiler.isAvailable, isTrue);
    });
  });

  group('GpuPaneSurfacePool', () {
    test('keeps 1 surface across 50 resize steps and invokes onResize', () {
      var createCalls = 0;
      final resizes = <(String, int, int)>[];
      final pool = GpuPaneSurfacePool<String>(
        maxEntries: 8,
        onResize: (surface, w, h) => resizes.add((surface, w, h)),
      );

      final initial = pool.obtain(
        'pane_0',
        800,
        600,
        (w, h) => 'surface_${++createCalls}',
      );
      expect(initial, 'surface_1');
      expect(pool.surfaceCount, 1);
      expect(resizes, isEmpty);

      // Re-obtaining unchanged dimensions does not trigger resize.
      expect(
        pool.obtain('pane_0', 800, 600, (w, h) => 'surface_${++createCalls}'),
        initial,
      );
      expect(resizes, isEmpty);

      // 50 consecutive drag-resize steps reuse the single surface in place.
      for (var step = 1; step <= 50; step++) {
        final s = pool.obtain(
          'pane_0',
          800 + step * 4,
          600 + step * 2,
          (w, h) => 'surface_${++createCalls}',
        );
        expect(s, initial);
      }
      expect(createCalls, 1);
      expect(pool.surfaceCount, 1);
      expect(resizes, hasLength(50));
      expect(resizes.last, ('surface_1', 1000, 700));
    });

    test('retains 4 split panes simultaneously and LRU-evicts past cap', () {
      final evicted = <String>[];
      final resizes = <(String, int, int)>[];
      var createCalls = 0;
      final pool = GpuPaneSurfacePool<String>(
        maxEntries: 4,
        onResize: (s, w, h) => resizes.add((s, w, h)),
        onEvict: evicted.add,
      );

      final s0 = pool.obtain('p0', 400, 300, (w, h) => 's${++createCalls}');
      final s1 = pool.obtain('p1', 400, 300, (w, h) => 's${++createCalls}');
      final s2 = pool.obtain('p2', 500, 400, (w, h) => 's${++createCalls}');
      final s3 = pool.obtain('p3', 600, 400, (w, h) => 's${++createCalls}');
      expect(pool.surfaceCount, 4);
      expect(pool.surfaces.toList(), <String>[s0, s1, s2, s3]);
      expect(evicted, isEmpty);

      // Resizing p2 touches only p2 and refreshes its LRU position.
      expect(pool.obtain('p2', 520, 420, (w, h) => 's${++createCalls}'), s2);
      expect(resizes, <(String, int, int)>[(s2, 520, 420)]);

      // Touch p0 so p1 becomes the least-recently-used pane.
      expect(pool.obtain('p0', 400, 300, (w, h) => 's${++createCalls}'), s0);

      // Adding a 5th pane evicts p1 (the LRU entry).
      final s4 = pool.obtain('p4', 800, 600, (w, h) => 's${++createCalls}');
      expect(pool.surfaceCount, 4);
      expect(evicted, <String>[s1]);
      expect(pool.surfaces, contains(s4));

      pool.remove('p4');
      expect(evicted, <String>[s1, s4]);
      expect(pool.surfaceCount, 3);

      pool.clear();
      expect(pool.surfaceCount, 0);
      expect(evicted, hasLength(5));
    });
  });

  group('GpuPaneTextureRingPool', () {
    test('cycles 3-slot ring round-robin and replaces on resize', () {
      final evicted = <String>[];
      var allocId = 0;
      String create(int w, int h) => 'tex_${++allocId}_${w}x$h';
      final pool = GpuPaneTextureRingPool<String>(
        maxEntries: 8,
        ringLength: 3,
        onEvict: evicted.add,
      );

      final t0 = pool.acquireNext('pane_a', 800, 600, create);
      final t1 = pool.acquireNext('pane_a', 800, 600, create);
      final t2 = pool.acquireNext('pane_a', 800, 600, create);
      expect(pool.paneCount, 1);
      expect(pool.totalTextureCount, 3);
      expect(allocId, 3);
      expect(<String>{t0, t1, t2}, hasLength(3));

      // Second cycle reuses the exact same 3 textures in round-robin order.
      expect(pool.acquireNext('pane_a', 800, 600, create), t0);
      expect(pool.acquireNext('pane_a', 800, 600, create), t1);
      expect(pool.acquireNext('pane_a', 800, 600, create), t2);
      expect(allocId, 3);
      expect(evicted, isEmpty);

      // Resizing evicts all 3 prior textures and allocates 3 fresh ones.
      final r0 = pool.acquireNext('pane_a', 1024, 768, create);
      expect(evicted, <String>[t0, t1, t2]);
      expect(pool.paneCount, 1);
      expect(pool.totalTextureCount, 3);
      expect(allocId, 6);
      expect(r0, 'tex_4_1024x768');
    });

    test(
      'isolates multiple panes, LRU-evicts past cap, and validates ringLength',
      () {
        expect(
          () => GpuPaneTextureRingPool<String>(ringLength: 0),
          throwsRangeError,
        );

        final evicted = <String>[];
        var allocId = 0;
        String create(int w, int h) => 'ring_${++allocId}';
        final pool = GpuPaneTextureRingPool<String>(
          maxEntries: 2,
          ringLength: 3,
          onEvict: evicted.add,
        );

        pool.acquireNext('p0', 300, 200, create);
        pool.acquireNext('p1', 400, 300, create);
        expect(pool.paneCount, 2);
        expect(pool.totalTextureCount, 6);

        // Touch p0 so p1 is evicted when p2 is inserted.
        pool.acquireNext('p0', 300, 200, create);
        pool.acquireNext('p2', 500, 400, create);
        expect(pool.paneCount, 2);
        expect(pool.totalTextureCount, 6);
        expect(evicted, <String>['ring_4', 'ring_5', 'ring_6']);

        pool.remove('p2');
        expect(pool.paneCount, 1);
        expect(pool.totalTextureCount, 3);

        pool.clear();
        expect(pool.paneCount, 0);
        expect(pool.totalTextureCount, 0);
        expect(evicted, hasLength(9));
      },
    );
  });

  group('GpuPaneTexturePool', () {
    test('retains 1 texture per pane across resizes and LRU-evicts', () {
      final evicted = <String>[];
      var allocId = 0;
      String create(int w, int h) => 'ptex_${++allocId}_${w}x$h';
      final pool = GpuPaneTexturePool<String>(
        maxEntries: 2,
        onEvict: evicted.add,
      );

      final a1 = pool.obtain('p0', 640, 480, create);
      expect(pool.obtain('p0', 640, 480, create), a1);
      expect(pool.textureCount, 1);
      expect(allocId, 1);

      // Resizing replaces p0's texture and evicts the old one.
      final a2 = pool.obtain('p0', 800, 600, create);
      expect(a2, isNot(a1));
      expect(pool.textureCount, 1);
      expect(evicted, <String>[a1]);

      final b1 = pool.obtain('p1', 320, 240, create);
      expect(pool.textureCount, 2);
      // Touch p0 so p1 is LRU and gets evicted when p2 is added.
      expect(pool.obtain('p0', 800, 600, create), a2);
      final c1 = pool.obtain('p2', 500, 500, create);
      expect(pool.textureCount, 2);
      expect(evicted, <String>[a1, b1]);
      expect(c1, 'ptex_4_500x500');

      pool.remove('p2');
      expect(pool.textureCount, 1);
      pool.clear();
      expect(pool.textureCount, 0);
      expect(evicted, <String>[a1, b1, c1, a2]);
    });
  });

  group('GpuInFlightFrameGate', () {
    test(
      'enforces per-pane backpressure, priming bypass, multi-pane isolation, '
      'token-safe stale-frame expiry, and reset',
      () {
        var nowUs = 0;
        final gate = GpuInFlightFrameGate(
          maxFramesInFlight: 2,
          staleTimeout: const Duration(seconds: 1),
          nowUs: () => nowUs,
        );

        // First two frames on paneA acquire monotonic tokens.
        final t1 = gate.tryAcquire('paneA', bypassForPriming: false);
        expect(t1, isNotNull);
        nowUs = 100_000;
        final t2 = gate.tryAcquire('paneA', bypassForPriming: false);
        expect(t2, isNotNull);
        expect(t2, greaterThan(t1!));
        expect(gate.totalInFlight, 2);
        expect(gate.inFlightFor('paneA'), 2);
        expect(gate.totalSkips, 0);

        // Third non-priming frame on paneA is backpressure-skipped.
        expect(gate.tryAcquire('paneA', bypassForPriming: false), isNull);
        expect(gate.totalSkips, 1);
        expect(gate.totalInFlight, 2);

        // Priming bypass always succeeds without incrementing totalSkips.
        final t3 = gate.tryAcquire('paneA', bypassForPriming: true);
        expect(t3, isNotNull);
        expect(gate.totalSkips, 1);
        expect(gate.inFlightFor('paneA'), 3);

        // Multi-pane isolation: saturating paneA does not block paneB.
        final tb1 = gate.tryAcquire('paneB', bypassForPriming: false);
        expect(tb1, isNotNull);
        expect(gate.inFlightFor('paneB'), 1);
        expect(gate.totalInFlight, 4);

        // Recording completion releases the exact token and updates latency.
        gate.recordCompletion('paneA', t1, 420);
        expect(gate.lastCompletionUs, 420);
        expect(gate.inFlightFor('paneA'), 2);

        // Duplicate completion for an already-completed token is a safe no-op.
        gate.recordCompletion('paneA', t1, 999);
        expect(gate.lastCompletionUs, 420);
        expect(gate.inFlightFor('paneA'), 2);

        // release() frees a slot without altering lastCompletionUs.
        expect(gate.release('paneA', t2!), isTrue);
        expect(gate.lastCompletionUs, 420);
        expect(gate.inFlightFor('paneA'), 1);

        // Now paneA has headroom (< 2) and can acquire again.
        nowUs = 200_000;
        final t4 = gate.tryAcquire('paneA', bypassForPriming: false);
        expect(t4, isNotNull);
        expect(gate.inFlightFor('paneA'), 2);

        // Stale-frame expiry: at t = 1_100_000 (1s after t = 100_000), t3
        // expires while t4 (at t = 200_000) stays active.
        nowUs = 1_100_000;
        expect(gate.inFlightFor('paneA'), 1);
        final t5 = gate.tryAcquire('paneA', bypassForPriming: false);
        expect(t5, isNotNull);
        expect(gate.inFlightFor('paneA'), 2);

        // A late GPU completion callback for expired token t3 must NOT evict
        // active tokens t4 or t5.
        gate.recordCompletion('paneA', t3!, 777);
        expect(gate.inFlightFor('paneA'), 2);
        expect(gate.lastCompletionUs, 420);

        // removePane() clears remaining slots for a disposed/evicted pane.
        gate.removePane('paneB');
        expect(gate.inFlightFor('paneB'), 0);

        // Advancing past all timestamps expires every stale frame.
        nowUs = 3_000_000;
        expect(gate.totalInFlight, 0);

        // reset() clears skips, completion latency, and active counts.
        gate.tryAcquire('paneA', bypassForPriming: false);
        gate.reset();
        expect(gate.totalInFlight, 0);
        expect(gate.totalSkips, 0);
        expect(gate.lastCompletionUs, 0);
      },
    );
  });

  group('GpuFrameBumpAllocator oversized block trimming', () {
    test('keeps oversized allocations isolated from same-frame normal allocations and trims on wrap', () {
      var createdNormal = 0;
      var createdOversized = 0;
      final allocator = GpuFrameBumpAllocator<String>(
        framesInFlight: 3,
        blockSizeBytes: 1024,
      );

      String createBlock(int cap) {
        if (cap > 1024) {
          return 'oversized_${++createdOversized}_$cap';
        }
        return 'normal_${++createdNormal}_$cap';
      }

      // Case (a): Oversized allocation first on an empty bucket must NOT be
      // reused by the subsequent normal allocation in the same frame.
      final oversizedFirst = allocator.allocate(
        byteLength: 4096,
        alignment: 64,
        createBlock: createBlock,
      );
      final normalAfterOversized = allocator.allocate(
        byteLength: 256,
        alignment: 64,
        createBlock: createBlock,
      );
      expect(oversizedFirst.buffer, 'oversized_1_4096');
      expect(normalAfterOversized.buffer, 'normal_1_1024');
      expect(normalAfterOversized.buffer, isNot(oversizedFirst.buffer));
      expect(allocator.totalBlockCount, 2);

      // Case (b): Overflowing normal_1 after an oversized allocation must
      // allocate normal_2 instead of stepping onto oversized_1.
      final oversizedSecond = allocator.allocate(
        byteLength: 8192,
        alignment: 64,
        createBlock: createBlock,
      );
      final normalOverflow = allocator.allocate(
        byteLength: 900,
        alignment: 64,
        createBlock: createBlock,
      );
      expect(oversizedSecond.buffer, 'oversized_2_8192');
      expect(normalOverflow.buffer, 'normal_2_1024');
      expect(allocator.totalBlockCount, 4);

      // Advancing to buckets 1 and 2 keeps bucket 0's oversized blocks alive
      // while bucket 0 is still potentially in flight on the GPU.
      allocator.advanceFrame(); // bucket 1
      expect(allocator.totalBlockCount, 4);
      allocator.advanceFrame(); // bucket 2
      expect(allocator.totalBlockCount, 4);

      // Wrapping back to bucket 0 trims both oversized blocks and keeps normal_1 & normal_2.
      allocator.advanceFrame(); // bucket 0 wrap
      expect(allocator.frameCursor, 0);
      expect(allocator.totalBlockCount, 2);

      // Next normal allocation reuses normal_1 without allocating a new block.
      final reused = allocator.allocate(
        byteLength: 256,
        alignment: 64,
        createBlock: createBlock,
      );
      expect(reused.buffer, 'normal_1_1024');
      expect(createdNormal, 2);
      expect(createdOversized, 2);
    });
  });
}
