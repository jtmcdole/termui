import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:termui/ui/shader_region.dart';

import 'gpu_atlas_batch.dart';
import 'gpu_frame_watchdog.dart';
import 'shader_spec.dart';

/// Immutable point-in-time GPU diagnostics snapshot exposed by backends
/// implementing [DiagnosableShaderBackend].
final class ShaderBackendDiagnostics {
  /// Number of command buffers currently executing on the GPU.
  final int inFlightFrames;

  /// Configured per-pane cap on concurrent in-flight frames (`0` if uncapped).
  final int maxFramesInFlight;

  /// Cumulative frames skipped due to in-flight GPU backpressure.
  final int backpressureSkips;

  /// Number of backing textures currently allocated across output surfaces/rings.
  final int backingTextureCount;

  /// Number of active pane output surfaces or texture rings retained.
  final int surfaceCount;

  /// Cumulative static terminal scene layer cache hits.
  final int staticCacheHits;

  /// Cumulative static terminal scene layer cache misses.
  final int staticCacheMisses;

  /// Most recent measured GPU submission completion latency in microseconds.
  final int lastGpuCompletionUs;

  /// Whether the most recent synchronous render call returned `null` solely
  /// because of GPU in-flight backpressure (so callers hold the bridge image
  /// instead of re-priming or entering fallback mode).
  final bool lastSyncFrameSkipped;

  /// Optional GPU renderer/adapter description reported by the active backend
  /// (e.g. WebGL2 `UNMASKED_RENDERER_WEBGL`).
  final String? gpuRenderer;

  /// Creates an immutable GPU diagnostics snapshot.
  const ShaderBackendDiagnostics({
    this.inFlightFrames = 0,
    this.maxFramesInFlight = 0,
    this.backpressureSkips = 0,
    this.backingTextureCount = 0,
    this.surfaceCount = 0,
    this.staticCacheHits = 0,
    this.staticCacheMisses = 0,
    this.lastGpuCompletionUs = 0,
    this.lastSyncFrameSkipped = false,
    this.gpuRenderer,
  });
}

/// Optional diagnostic interface implemented by GPU shader backends to report
/// live queue depth, backing texture counts, and GPU completion latency to the
/// Perf HUD and trace recorders.
abstract interface class DiagnosableShaderBackend {
  /// Reads the current backend diagnostics snapshot without allocating GPU work.
  ShaderBackendDiagnostics readDiagnostics();
}

/// Optional capability implemented by GPU shader backends that feed execution
/// timings, command completion callbacks, or context-loss notifications into a
/// [GpuFrameWatchdog].
abstract interface class WatchdogBindableShaderBackend {
  /// Active per-pane GPU watchdog, or `null` when none is bound.
  GpuFrameWatchdog? watchdog;
}

/// Opaque handle representing a compiled shader pipeline owned by a
/// [TerminalShaderBackend].
abstract interface class CompiledShaderHandle {
  /// Stable pass identifier associated with this compiled shader.
  String get id;

  /// Whether this compiled shader reads `iPrevFrame` and requires ping-pong
  /// frame persistence.
  bool get usesPrevFrame;

  /// Releases native GPU or WebGL resources held by this handle.
  void dispose();
}

/// Single pass execution record combining a compiled shader handle, its
/// per-frame uniforms, and an optional ping-pong buffer key.
typedef ShaderPassInvocation = ({
  CompiledShaderHandle handle,
  TerminalShaderUniforms uniforms,
  String? prevFrameKey,
});

/// Single scoped [ShaderRegion] pass executed synchronously inside a
/// [DirectTerminalShaderBackend] frame or asynchronously in canvas fallback.
final class ShaderRegionPassInvocation {
  /// Stable region identifier matching a [GpuRegionMaskSlice.regionId].
  final String regionId;

  /// Logical shader identifier (built-in preset or custom CLI slot ID).
  final String shaderId;

  /// Compiled shader handle for this region.
  final CompiledShaderHandle handle;

  /// Per-frame uniforms sized to the tight physical region bounds (`iRegionRect`,
  /// `iCellSize`, `uParams0`, `uParams1`).
  final TerminalShaderUniforms uniforms;

  /// Compositing stage relative to text glyphs.
  final ShaderRegionStage stage;

  /// Ascending stacking order among active regions.
  final int zIndex;

  /// Ping-pong persistence key (e.g. `'region:<id>'` or `'<pane>:region:<id>'`).
  final String prevFrameKey;

  /// Physical destination rectangle on the terminal pane viewport.
  final ui.Rect outputRectPhysical;

  /// Creates an immutable scoped region pass invocation.
  const ShaderRegionPassInvocation({
    required this.regionId,
    required this.shaderId,
    required this.handle,
    required this.uniforms,
    required this.stage,
    required this.zIndex,
    required this.prevFrameKey,
    required this.outputRectPhysical,
  });

  /// Converts this region pass into a standard [ShaderPassInvocation] for
  /// executing against a tight `uGlyphMask` input texture.
  ShaderPassInvocation toPassInvocation() =>
      (handle: handle, uniforms: uniforms, prevFrameKey: prevFrameKey);
}

/// Structured error raised when validating, shimming, or compiling a custom
/// terminal fragment shader fails.
final class ShaderCompileException implements Exception {
  /// Identifier or path of the shader that failed compilation.
  final String shaderId;

  /// Human-readable summary of the compilation failure.
  final String message;

  /// Optional 1-based line number reported by the GLSL compiler.
  final int? lineNumber;

  /// Optional raw compiler log (e.g. `impellerc` stderr or `gl.getShaderInfoLog`).
  final String? compilerLog;

  /// Creates a shader compilation exception.
  const ShaderCompileException({
    required this.shaderId,
    required this.message,
    this.lineNumber,
    this.compilerLog,
  });

  @override
  String toString() {
    final location = lineNumber == null ? '' : ' (line $lineNumber)';
    return 'ShaderCompileException[$shaderId$location]: $message';
  }
}

/// Cross-platform contract implemented by Desktop (`flutter_gpu`), Web
/// (`OffscreenCanvas` WebGL2), and `disabled` shader backends.
abstract interface class TerminalShaderBackend {
  /// Identifies the active backend implementation.
  ShaderBackendKind get kind;

  /// Whether this backend can compile and run custom user GLSL shaders.
  bool get supportsCustomGlsl;

  /// Whether background passes without an `inputImage` can render
  /// synchronously during paint.
  bool get supportsSyncBackground;

  /// Compiles [shadertoyGlsl] into a reusable [CompiledShaderHandle].
  ///
  /// Throws [ShaderCompileException] if validation or GPU compilation fails.
  Future<CompiledShaderHandle> compile(
    String id,
    String shadertoyGlsl, {
    bool usesPrevFrame = false,
  });

  /// Recompiles [shadertoyGlsl] and swaps [handle] in place without tearing
  /// down downstream references.
  ///
  /// On compilation failure, implementations must leave the previously active
  /// shader program intact and throw [ShaderCompileException].
  Future<void> reload(CompiledShaderHandle handle, String shadertoyGlsl);

  /// Synchronous render path for background passes that do not sample
  /// `inputImage` (used on Desktop `flutter_gpu`).
  ui.Image? renderBackgroundSync({
    required List<ShaderPassInvocation> passes,
    required ui.Size physicalSize,
    ui.Image? wallpaperImage,
    GpuFrameWatchdog? watchdog,
  });

  /// Single-flight async render path for `iChannel0` foreground passes and
  /// scoped region passes.
  Future<ui.Image?> renderPassesAsync({
    required List<ShaderPassInvocation> passes,
    required ui.Size physicalSize,
    ui.Image? inputImage,
    ui.Image? wallpaperImage,
    GpuFrameWatchdog? watchdog,
  });

  /// Disposes all compiled handles, framebuffers, and GPU contexts owned by
  /// this backend.
  void dispose();
}

/// Optional additive contract implemented by [TerminalShaderBackend]s that can
/// render staged terminal atlas and Kitty quads directly inside the GPU shader
/// context, avoiding `RepaintBoundary.toImage()` and Web RGBA readbacks.
abstract interface class DirectTerminalShaderBackend
    implements TerminalShaderBackend {
  /// Whether direct instanced terminal rendering is currently available.
  ///
  /// Returns `false` if internal atlas shader compilation permanently failed or
  /// the GPU backend cannot support instanced rendering.
  bool get supportsDirectTerminalRender;

  /// Asynchronously prepares GPU resources required by [renderTerminalFrameSync].
  ///
  /// On Web, uploads uncached [atlasImage], [wallpaperImage], and [kittyImages]
  /// pixels with per-image in-flight deduplication. On Native Desktop, compiles
  /// the internal Impeller instanced atlas pipeline once. Returns `true` when
  /// resources are ready for synchronous rendering.
  Future<bool> prepareDirectResources({
    required ui.Image atlasImage,
    ui.Image? wallpaperImage,
    Iterable<ui.Image> kittyImages = const <ui.Image>[],
  });

  /// Synchronously renders [backgroundPasses] (or [wallpaperImage] cover fill),
  /// staged terminal atlas + Kitty quads from [batch], and [foregroundPasses]
  /// inside one GPU context.
  ///
  /// Returns `null` when any required texture or internal pipeline is not yet
  /// primed (or after context loss), signaling the host to trigger
  /// [prepareDirectResources] and bridge via fallback.
  ui.Image? renderTerminalFrameSync({
    required List<ShaderPassInvocation> backgroundPasses,
    required List<ShaderPassInvocation> foregroundPasses,
    required ui.Size physicalSize,
    required ui.Image atlasImage,
    required GpuAtlasQuadBatch batch,
    ui.Image? wallpaperImage,
    GpuFrameWatchdog? watchdog,
  });
}

/// Captured raw RGBA pixels and dimensions read from a cloned [ui.Image].
final class RgbaImagePixels {
  /// Raw RGBA pixel bytes.
  final ByteData bytes;

  /// Pixel width captured from the cloned image.
  final int width;

  /// Pixel height captured from the cloned image.
  final int height;

  /// Creates an immutable [RgbaImagePixels] snapshot.
  const RgbaImagePixels({
    required this.bytes,
    required this.width,
    required this.height,
  });
}

/// Clones [image] synchronously before awaiting `toByteData(rawRgba)` so
/// callers that dispose the original [ui.Image] mid-readback cannot trigger
/// disposed-image failures during readback or post-await dimension lookups.
///
/// Returns `null` if [image] is `null`, already disposed, or pixel readback
/// fails. Always disposes the internal clone in a `finally` block.
Future<RgbaImagePixels?> readImageRgbaSafely(ui.Image? image) async {
  if (image == null) return null;
  ui.Image? cloned;
  try {
    cloned = image.clone();
    final width = cloned.width;
    final height = cloned.height;
    final bytes = await cloned.toByteData(format: ui.ImageByteFormat.rawRgba);
    if (bytes == null || width <= 0 || height <= 0) return null;
    return RgbaImagePixels(bytes: bytes, width: width, height: height);
  } on Object {
    return null;
  } finally {
    cloned?.dispose();
  }
}
