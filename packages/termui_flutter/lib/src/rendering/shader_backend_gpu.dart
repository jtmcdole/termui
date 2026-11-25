import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, visibleForTesting;
import 'package:flutter/scheduler.dart';
import 'package:flutter_gpu/gpu.dart' as gpu;
import 'package:termui/ui/shader_region.dart';

import 'gpu_atlas_batch.dart';
import 'gpu_atlas_shaders.dart';
import 'gpu_frame_watchdog.dart';
import 'impellerc_compiler_stub.dart'
    if (dart.library.io) 'impellerc_compiler_io.dart';
import 'perf_trace.dart';
import 'shader_backend.dart';
import 'shader_resource_pools.dart';
import 'shader_spec.dart';
import 'shadertoy_glsl_shim.dart';

export 'shader_resource_pools.dart'
    show
        GpuFrameBumpAllocator,
        GpuInFlightFrameGate,
        GpuKeyedPool,
        GpuPaneSurfacePool,
        GpuPaneTexturePool,
        GpuPaneTextureRingPool,
        GpuPingPongRegistry,
        GpuPingPongSlot,
        GpuSizePool,
        GpuTextureSizeKey,
        alignUniformByteSize;

/// Packs [uniformsList] into one contiguous [ByteData] where every pass begins
/// at a byte offset aligned to [minimumUniformByteAlignment].
///
/// When [scratchBuffer] is supplied and large enough to hold the packed batch,
/// packing reuses a sublist view over [scratchBuffer] with zero heap
/// allocations. When [scratchPalettes] is also supplied alongside a reused
/// [scratchBuffer], passes whose `palette256Argb` reference matches the
/// previously packed slot skip re-copying the 4 KiB `iPalette` array.
({ByteData data, int alignedStride}) packAlignedUniformBatch(
  List<TerminalShaderUniforms> uniformsList, {
  required int minimumUniformByteAlignment,
  ByteData? scratchBuffer,
  List<Uint32List?>? scratchPalettes,
}) {
  final stride = alignUniformByteSize(
    ShadertoyGlslShim.uniformBufferByteLength,
    minimumUniformByteAlignment,
  );
  final totalBytes = uniformsList.length * stride;
  final reusingScratch =
      scratchBuffer != null && scratchBuffer.lengthInBytes >= totalBytes;
  final data = reusingScratch
      ? ByteData.sublistView(scratchBuffer, 0, totalBytes)
      : ByteData(totalBytes);
  for (var i = 0; i < uniformsList.length; i++) {
    final uniforms = uniformsList[i];
    final canSkipPalette =
        reusingScratch &&
        scratchPalettes != null &&
        i < scratchPalettes.length &&
        identical(scratchPalettes[i], uniforms.palette256Argb);
    ShadertoyGlslShim.packUniformsStd140(
      uniforms,
      data,
      byteOffset: i * stride,
      skipPalette: canSkipPalette,
    );
    if (reusingScratch && scratchPalettes != null) {
      if (i < scratchPalettes.length) {
        scratchPalettes[i] = uniforms.palette256Argb;
      } else {
        scratchPalettes.add(uniforms.palette256Argb);
      }
    }
  }
  return (data: data, alignedStride: stride);
}

/// Resolves the stable ping-pong persistence key for [invocation].
String resolvePrevFrameKey(ShaderPassInvocation invocation) =>
    invocation.prevFrameKey ?? invocation.handle.id;

/// Executes a GPU pass chain using one command buffer per render pass (and a
/// separate command buffer for the trailing texture copy when the final pass
/// writes to a ping-pong texture rather than [finalSurfaceTexture]).
///
/// Flutter 3.50's `flutter_gpu` `CommandBuffer` keeps each `RenderPass` and
/// `BlitPass` encoder open until `CommandBuffer.submit()`, so creating a second
/// pass or blit on the same command buffer trips Metal's single-active-encoder
/// assertion (`A command encoder is already encoding to this command buffer`)
/// and violates Vulkan render-pass ordering. Returning the final unsubmitted
/// command buffer lets the caller invoke `surfaceFrame.present(...)` before
/// final submission.
TCmd
executeSingleEncoderGpuPassChain<TCmd extends Object, TTex extends Object>({
  required int passCount,
  required TTex finalSurfaceTexture,
  required TCmd Function() createCommandBuffer,
  required TTex Function(int passIndex, TCmd commandBuffer) encodeRenderPass,
  required void Function(TCmd commandBuffer) submitIntermediate,
  required void Function(TCmd commandBuffer, TTex source, TTex destination)
  encodeCopyToSurface,
}) {
  if (passCount <= 0) {
    throw RangeError.value(passCount, 'passCount', 'Must be positive.');
  }
  TTex? lastTarget;
  TCmd? finalCommandBuffer;

  for (var i = 0; i < passCount; i++) {
    final commandBuffer = createCommandBuffer();
    final target = encodeRenderPass(i, commandBuffer);
    lastTarget = target;
    if (i == passCount - 1 && identical(target, finalSurfaceTexture)) {
      finalCommandBuffer = commandBuffer;
    } else {
      submitIntermediate(commandBuffer);
    }
  }

  if (finalCommandBuffer != null) {
    return finalCommandBuffer;
  }

  final copyCommandBuffer = createCommandBuffer();
  encodeCopyToSurface(
    copyCommandBuffer,
    lastTarget as TTex,
    finalSurfaceTexture,
  );
  return copyCommandBuffer;
}

/// Per-shader reflection guard that skips SPIRV-Cross-stripped uniform blocks
/// and memoizes stripped texture sampler names so binding never throws.
final class GpuReflectionBindingCache {
  final Set<String> _strippedSamplers = <String>{};

  /// Unmodifiable view of sampler names confirmed stripped by reflection.
  Set<String> get strippedSamplers =>
      Set<String>.unmodifiable(_strippedSamplers);

  /// Returns whether a uniform struct with reflected [reflectedSizeInBytes]
  /// should be bound, clamping the length to [maxLengthInBytes].
  int? resolveUniformBindLength(
    int? reflectedSizeInBytes, {
    required int maxLengthInBytes,
  }) {
    if (reflectedSizeInBytes == null || reflectedSizeInBytes <= 0) {
      return null;
    }
    return reflectedSizeInBytes <= maxLengthInBytes
        ? reflectedSizeInBytes
        : maxLengthInBytes;
  }

  /// Invokes [bind] for [samplerName] unless it was already found stripped.
  ///
  /// Returns `true` if bound, or `false` if skipped or stripped by
  /// SPIRV-Cross. Non-reflection errors are rethrown.
  bool tryBindSampler(String samplerName, void Function() bind) {
    if (_strippedSamplers.contains(samplerName)) {
      return false;
    }
    try {
      bind();
      return true;
    } on Exception catch (error) {
      if (_isMissingTextureBindingError(error)) {
        _strippedSamplers.add(samplerName);
        return false;
      }
      rethrow;
    }
  }

  /// Clears cached reflection state after an in-place shader reload.
  void invalidate() {
    _strippedSamplers.clear();
  }

  static bool _isMissingTextureBindingError(Exception error) =>
      error.toString().contains('no texture named');
}

/// Compiled `flutter_gpu` shader handle owned by [FlutterGpuShaderBackend].
final class _GpuCompiledShaderHandle implements CompiledShaderHandle {
  @override
  final String id;

  final bool requestedUsesPrevFrame;
  final gpu.ShaderLibrary library;
  final gpu.Shader vertexShader;
  final gpu.Shader fragmentShader;
  final GpuReflectionBindingCache reflectionCache = GpuReflectionBindingCache();
  final void Function(_GpuCompiledShaderHandle handle) onDispose;

  gpu.RenderPipeline pipeline;
  gpu.UniformSlot? _uboSlot;
  final Map<String, gpu.UniformSlot> _samplerSlots =
      <String, gpu.UniformSlot>{};
  bool _usesPrevFrame;
  bool _disposed = false;
  bool _pipelineFailed = false;
  String? _pipelineError;

  _GpuCompiledShaderHandle({
    required this.id,
    required this.requestedUsesPrevFrame,
    required this.library,
    required this.vertexShader,
    required this.fragmentShader,
    required this.pipeline,
    required bool initialUsesPrevFrame,
    required this.onDispose,
  }) : _usesPrevFrame = initialUsesPrevFrame;

  @override
  bool get usesPrevFrame => _usesPrevFrame;

  bool get isDisposed => _disposed;

  bool get isPipelineFailed => _pipelineFailed;

  String? get pipelineError => _pipelineError;

  gpu.UniformSlot get uboSlot => _uboSlot ??= fragmentShader.getUniformSlot(
    ShadertoyGlslShim.uniformBlockName,
  );

  gpu.UniformSlot samplerSlot(String name) =>
      _samplerSlots[name] ??= fragmentShader.getUniformSlot(name);

  void markPipelineFailed(String message) {
    _pipelineFailed = true;
    _pipelineError = message;
  }

  void applyReload({
    required gpu.RenderPipeline nextPipeline,
    required bool analysisUsesPrevFrame,
  }) {
    pipeline = nextPipeline;
    _usesPrevFrame = requestedUsesPrevFrame || analysisUsesPrevFrame;
    _pipelineFailed = false;
    _pipelineError = null;
    _uboSlot = null;
    _samplerSlots.clear();
    reflectionCache.invalidate();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _uboSlot = null;
    _samplerSlots.clear();
    reflectionCache.invalidate();
    onDispose(this);
  }
}

/// Desktop Impeller shader backend built on `package:flutter_gpu` and
/// out-of-process `impellerc` `.shaderbundle` compilation.
final class FlutterGpuShaderBackend
    implements
        DirectTerminalShaderBackend,
        WatchdogBindableShaderBackend,
        DiagnosableShaderBackend {
  static final Float32List _fullscreenTriangleVertices = Float32List.fromList(
    <double>[-1.0, -1.0, 3.0, -1.0, -1.0, 3.0],
  );

  static final gpu.SamplerOptions _nearestClampSampler = gpu.SamplerOptions(
    minFilter: gpu.MinMagFilter.nearest,
    magFilter: gpu.MinMagFilter.nearest,
    mipFilter: gpu.MipFilter.nearest,
    widthAddressMode: gpu.SamplerAddressMode.clampToEdge,
    heightAddressMode: gpu.SamplerAddressMode.clampToEdge,
  );

  static final gpu.SamplerOptions _linearClampSampler = gpu.SamplerOptions(
    minFilter: gpu.MinMagFilter.linear,
    magFilter: gpu.MinMagFilter.linear,
    mipFilter: gpu.MipFilter.nearest,
    widthAddressMode: gpu.SamplerAddressMode.clampToEdge,
    heightAddressMode: gpu.SamplerAddressMode.clampToEdge,
  );

  static final gpu.ColorBlendEquation _premultipliedSrcOver =
      gpu.ColorBlendEquation();

  static const gpu.VertexLayout _directAtlasVertexLayout = gpu.VertexLayout(
    buffers: <gpu.VertexBuffer>[
      gpu.VertexBuffer(
        strideInBytes: 8,
        stepMode: gpu.VertexStepMode.vertex,
        attributes: <gpu.VertexAttribute>[
          gpu.VertexAttribute(
            name: GpuAtlasShaders.attrCorner,
            format: gpu.VertexFormat.float32x2,
            offsetInBytes: 0,
          ),
        ],
      ),
      gpu.VertexBuffer(
        strideInBytes: GpuAtlasQuadBatch.bytesPerInstance,
        stepMode: gpu.VertexStepMode.instance,
        attributes: <gpu.VertexAttribute>[
          gpu.VertexAttribute(
            name: GpuAtlasShaders.attrDstRect,
            format: gpu.VertexFormat.float32x4,
            offsetInBytes: 0,
          ),
          gpu.VertexAttribute(
            name: GpuAtlasShaders.attrUvRect,
            format: gpu.VertexFormat.float32x4,
            offsetInBytes: 16,
          ),
          gpu.VertexAttribute(
            name: GpuAtlasShaders.attrColor,
            format: gpu.VertexFormat.float32x4,
            offsetInBytes: 32,
          ),
          gpu.VertexAttribute(
            name: GpuAtlasShaders.attrExtra,
            format: gpu.VertexFormat.float32x4,
            offsetInBytes: 48,
          ),
        ],
      ),
    ],
  );

  static const int _instanceRingLength = 4;
  static const int _maxViewportUboEntries = 16;
  static const int _maxStaticSceneLayers = 8;
  static const int _maxPaneUploadCaches = 8;
  static const int _maxCachedRegionMasks = 32;
  static const int _maxUploadedAtlasTextures = 4;
  static const int _maxUploadedWallpaperTextures = 4;
  static const int _maxUploadedInputTextures = 8;
  static const int _maxUploadedKittyTextures = 64;
  static const int _maxPrimedPanes = 64;

  static final Stopwatch _gpuTimerClock = Stopwatch()..start();

  static void _resizeGpuSurface(
    gpu.GpuImageSurface surface,
    int width,
    int height,
  ) {
    surface.resize(width, height);
  }

  final ImpellercCompiler _compiler;
  final gpu.GpuContext _context;
  final bool _usePixelUploadForImages;
  final bool _useTextureRingSurface;

  final Set<_GpuCompiledShaderHandle> _handles = <_GpuCompiledShaderHandle>{};
  final GpuPaneSurfacePool<gpu.GpuImageSurface> _backgroundSurfacePool =
      GpuPaneSurfacePool<gpu.GpuImageSurface>(
        maxEntries: 16,
        onResize: _resizeGpuSurface,
      );
  final GpuPaneSurfacePool<gpu.GpuImageSurface> _foregroundSurfacePool =
      GpuPaneSurfacePool<gpu.GpuImageSurface>(
        maxEntries: 16,
        onResize: _resizeGpuSurface,
      );
  final GpuPaneSurfacePool<gpu.GpuImageSurface> _directSurfacePool =
      GpuPaneSurfacePool<gpu.GpuImageSurface>(
        maxEntries: 16,
        onResize: _resizeGpuSurface,
      );
  final GpuPaneTextureRingPool<gpu.Texture> _backgroundRingPool =
      GpuPaneTextureRingPool<gpu.Texture>(maxEntries: 16, ringLength: 3);
  final GpuPaneTextureRingPool<gpu.Texture> _foregroundRingPool =
      GpuPaneTextureRingPool<gpu.Texture>(maxEntries: 16, ringLength: 3);
  final GpuPaneTextureRingPool<gpu.Texture> _directRingPool =
      GpuPaneTextureRingPool<gpu.Texture>(maxEntries: 16, ringLength: 3);
  final GpuPaneTexturePool<gpu.Texture> _directScenePool =
      GpuPaneTexturePool<gpu.Texture>(maxEntries: 16);
  final GpuKeyedPool<(int, int, int), gpu.Texture> _regionOutPool =
      GpuKeyedPool<(int, int, int), gpu.Texture>(maxEntries: 16);
  final GpuKeyedPool<(int, int, int), gpu.Texture> _scratchPool =
      GpuKeyedPool<(int, int, int), gpu.Texture>(maxEntries: 16);
  final GpuPingPongRegistry<gpu.Texture> _pingPongRegistry =
      GpuPingPongRegistry<gpu.Texture>(maxEntries: 32);
  final GpuFrameBumpAllocator<gpu.DeviceBuffer> _uniformBumpAllocator =
      GpuFrameBumpAllocator<gpu.DeviceBuffer>();
  final GpuFrameBumpAllocator<gpu.DeviceBuffer> _auxQuadBumpAllocator =
      GpuFrameBumpAllocator<gpu.DeviceBuffer>();
  final GpuInFlightFrameGate _inFlightGate = GpuInFlightFrameGate(
    maxFramesInFlight: 2,
  );
  final LinkedHashSet<Object> _primedPanes = LinkedHashSet<Object>();
  Duration? _lastBumpFrameStamp;

  final Float32List _directViewportUniformScratch = Float32List(4);
  final LinkedHashMap<(int, int), gpu.DeviceBuffer> _viewportUboCache =
      LinkedHashMap<(int, int), gpu.DeviceBuffer>();
  ByteData? _uniformPackScratch;
  final List<Uint32List?> _uniformPackScratchPalettes = <Uint32List?>[];
  int _uniformPackScratchStride = 0;
  Float32List? _directAuxQuadScratch;
  final LinkedHashMap<String, _CachedStaticSceneLayers> _cachedStaticLayers =
      LinkedHashMap<String, _CachedStaticSceneLayers>();
  final LinkedHashMap<String, _PaneGpuUploadCache> _paneUploadCaches =
      LinkedHashMap<String, _PaneGpuUploadCache>();

  /// Optional per-pane GPU frame watchdog hooked into
  /// `CommandBuffer.submit(completionCallback: ...)`.
  @override
  GpuFrameWatchdog? watchdog;

  gpu.ShaderLibrary? _directAtlasLibrary;
  gpu.Shader? _directAtlasVertexShader;
  gpu.Shader? _directAtlasFragmentShader;
  gpu.UniformSlot? _directAtlasUniformSlot;
  gpu.UniformSlot? _directAtlasSamplerSlot;
  gpu.RenderPipeline? _directAtlasPipeline;
  gpu.DeviceBuffer? _directUnitQuadBuffer;
  final LinkedHashMap<ui.Image, gpu.Texture> _uploadedAtlasTextures =
      LinkedHashMap<ui.Image, gpu.Texture>.identity();
  final LinkedHashMap<ui.Image, gpu.Texture> _uploadedWallpaperTextures =
      LinkedHashMap<ui.Image, gpu.Texture>.identity();
  final LinkedHashMap<ui.Image, gpu.Texture> _uploadedInputTextures =
      LinkedHashMap<ui.Image, gpu.Texture>.identity();
  final LinkedHashMap<ui.Image, gpu.Texture> _uploadedKittyTextures =
      LinkedHashMap<ui.Image, gpu.Texture>.identity();
  int _uploadedKittyCapacity = _maxUploadedKittyTextures;
  final Map<ui.Image, Future<bool>> _pixelUploadsInFlight =
      Map<ui.Image, Future<bool>>.identity();
  final LinkedHashMap<(String, String), _CachedGpuRegionMask>
  _cachedRegionMasks = LinkedHashMap<(String, String), _CachedGpuRegionMask>();
  Future<bool>? _directPrepareFuture;
  bool _directPipelineFailed = false;

  int _staticCacheHits = 0;
  int _staticCacheMisses = 0;
  int _lastGpuCompletionUs = 0;
  bool _lastSyncFrameSkipped = false;

  gpu.DeviceBuffer? _fullscreenVertexBuffer;
  gpu.Texture? _fallbackTexture;
  bool _disposed = false;

  /// Resolves a render-target-safe [gpu.PixelFormat] for `GpuImageSurface` and
  /// intermediate offscreen textures.
  ///
  /// On Apple wide-gamut displays, Flutter 3.50's `defaultColorFormat` maps
  /// Impeller's `kB10G10R10A10XR` to [gpu.PixelFormat.unknown], which
  /// `GpuImageSurface` rejects with `Unsupported GpuSurface pixel format.`.
  /// Falling back to [gpu.PixelFormat.b8g8r8a8UNormInt] matches Metal's native
  /// 8-bit render-target format cleanly.
  static gpu.PixelFormat resolveSafeGpuColorFormat(gpu.PixelFormat format) =>
      format == gpu.PixelFormat.unknown
      ? gpu.PixelFormat.b8g8r8a8UNormInt
      : format;

  gpu.PixelFormat get _renderColorFormat =>
      resolveSafeGpuColorFormat(_context.defaultColorFormat);

  /// Creates a Desktop `flutter_gpu` shader backend.
  FlutterGpuShaderBackend({
    ImpellercCompiler? compiler,
    gpu.GpuContext? context,
    bool? usePixelUploadForImages,
    bool? useTextureRingSurface,
  }) : _compiler = compiler ?? ImpellercCompiler(),
       _context = context ?? gpu.gpuContext,
       _usePixelUploadForImages =
           usePixelUploadForImages ??
           (defaultTargetPlatform == TargetPlatform.windows),
       _useTextureRingSurface =
           useTextureRingSurface ??
           (defaultTargetPlatform == TargetPlatform.windows);

  /// Probes `gpu.gpuContext` and returns a [FlutterGpuShaderBackend], or
  /// `null` without throwing if Impeller/`flutter_gpu` is unavailable (such as
  /// under Skia Desktop or `flutter test` software rendering).
  static FlutterGpuShaderBackend? tryCreate({
    ImpellercCompiler? compiler,
    bool? usePixelUploadForImages,
    bool? useTextureRingSurface,
  }) {
    try {
      final context = gpu.gpuContext;
      if (context.minimumUniformByteAlignment <= 0) {
        return null;
      }
      return FlutterGpuShaderBackend(
        compiler: compiler,
        context: context,
        usePixelUploadForImages: usePixelUploadForImages,
        useTextureRingSurface: useTextureRingSurface,
      );
    } on Object {
      return null;
    }
  }

  @override
  ShaderBackendDiagnostics readDiagnostics() {
    final int backingTextureCount;
    final int surfaceCount;
    if (_useTextureRingSurface) {
      backingTextureCount =
          _directRingPool.totalTextureCount +
          _backgroundRingPool.totalTextureCount +
          _foregroundRingPool.totalTextureCount;
      surfaceCount =
          _directRingPool.paneCount +
          _backgroundRingPool.paneCount +
          _foregroundRingPool.paneCount;
    } else {
      backingTextureCount =
          _countSurfaceBackingTextures(_directSurfacePool) +
          _countSurfaceBackingTextures(_backgroundSurfacePool) +
          _countSurfaceBackingTextures(_foregroundSurfacePool);
      surfaceCount =
          _directSurfacePool.surfaceCount +
          _backgroundSurfacePool.surfaceCount +
          _foregroundSurfacePool.surfaceCount;
    }
    return ShaderBackendDiagnostics(
      inFlightFrames: _inFlightGate.totalInFlight,
      maxFramesInFlight: _inFlightGate.maxFramesInFlight,
      backpressureSkips: _inFlightGate.totalSkips,
      backingTextureCount: backingTextureCount,
      surfaceCount: surfaceCount,
      staticCacheHits: _staticCacheHits,
      staticCacheMisses: _staticCacheMisses,
      lastGpuCompletionUs: _lastGpuCompletionUs,
      lastSyncFrameSkipped: _lastSyncFrameSkipped,
    );
  }

  static int _countSurfaceBackingTextures(
    GpuPaneSurfacePool<gpu.GpuImageSurface> pool,
  ) {
    var total = 0;
    for (final surface in pool.surfaces) {
      total += surface.debugBackingTextureCount;
    }
    return total;
  }

  @override
  ShaderBackendKind get kind => ShaderBackendKind.flutterGpu;

  @override
  bool get supportsCustomGlsl => _compiler.isAvailable;

  @override
  bool get supportsSyncBackground => true;

  @override
  bool get supportsDirectTerminalRender =>
      !_disposed && !_directPipelineFailed && _compiler.isAvailable;

  @override
  Future<CompiledShaderHandle> compile(
    String id,
    String shadertoyGlsl, {
    bool usesPrevFrame = false,
  }) async {
    _ensureNotDisposed();
    final compiled = await _compiler.compile(shadertoyGlsl, shaderId: id);
    _ensureNotDisposed();
    final library = await _loadShaderLibrary(id, compiled.bytes);
    _ensureNotDisposed();
    final vertexShader = library[ShadertoyGlslShim.vertexShaderName];
    final fragmentShader = library[ShadertoyGlslShim.fragmentShaderName];
    if (vertexShader == null || fragmentShader == null) {
      throw ShaderCompileException(
        shaderId: id,
        message:
            'Compiled shader bundle is missing vertex or fragment entrypoint.',
      );
    }
    final pipeline = _createPipeline(id, vertexShader, fragmentShader);
    final handle = _GpuCompiledShaderHandle(
      id: id,
      requestedUsesPrevFrame: usesPrevFrame,
      library: library,
      vertexShader: vertexShader,
      fragmentShader: fragmentShader,
      pipeline: pipeline,
      initialUsesPrevFrame: usesPrevFrame || compiled.analysis.usesPrevFrame,
      onDispose: _handleDisposed,
    );
    _handles.add(handle);
    return handle;
  }

  @override
  Future<void> reload(CompiledShaderHandle handle, String shadertoyGlsl) async {
    _ensureNotDisposed();
    final gpuHandle = _requireOwnedHandle(handle);
    final compiled = await _compiler.compile(
      shadertoyGlsl,
      shaderId: gpuHandle.id,
    );
    _ensureNotDisposed();
    _requireOwnedHandle(gpuHandle);
    final error = gpuHandle.library.reinitializeFromBytes(compiled.bytes);
    if (error != null) {
      throw ShaderCompileException(
        shaderId: gpuHandle.id,
        message: 'Failed to reload Impeller shader library: $error',
      );
    }
    final nextPipeline = _createPipeline(
      gpuHandle.id,
      gpuHandle.vertexShader,
      gpuHandle.fragmentShader,
    );
    gpuHandle.applyReload(
      nextPipeline: nextPipeline,
      analysisUsesPrevFrame: compiled.analysis.usesPrevFrame,
    );
  }

  /// Maximum time [renderPassesAsync] waits for the GPU command buffer
  /// completion callback before releasing backpressure.
  static const Duration gpuCompletionTimeout = Duration(seconds: 4);

  @override
  ui.Image? renderBackgroundSync({
    required List<ShaderPassInvocation> passes,
    required ui.Size physicalSize,
    ui.Image? wallpaperImage,
    GpuFrameWatchdog? watchdog,
  }) {
    _lastSyncFrameSkipped = false;
    if (_disposed || passes.isEmpty) return null;
    final activePasses = _filterHealthyPasses(passes);
    if (activePasses.isEmpty) return null;
    final width = physicalSize.width.round();
    final height = physicalSize.height.round();
    if (width <= 0 || height <= 0) return null;

    final wallpaperTexture = _wrapCachedWallpaperImage(wallpaperImage);
    if (wallpaperImage != null &&
        _usePixelUploadForImages &&
        wallpaperTexture == null) {
      return null;
    }

    final paneKey = _paneKeyForPasses(activePasses, fallbackPrefix: 'bg');
    final gateToken = _tryAcquireSyncFrameSlot(paneKey);
    if (gateToken == null) {
      _lastSyncFrameSkipped = true;
      return null;
    }

    final image = _renderPasses(
      paneKey: paneKey,
      passes: activePasses,
      width: width,
      height: height,
      inputTexture: null,
      wallpaperTexture: wallpaperTexture,
      isForeground: false,
      gatePaneKey: paneKey,
      gateToken: gateToken,
      watchdog: watchdog ?? this.watchdog,
    );
    if (image != null) {
      _markPanePrimed(paneKey);
    }
    return image;
  }

  @override
  Future<ui.Image?> renderPassesAsync({
    required List<ShaderPassInvocation> passes,
    required ui.Size physicalSize,
    ui.Image? inputImage,
    ui.Image? wallpaperImage,
    GpuFrameWatchdog? watchdog,
  }) async {
    if (_disposed || passes.isEmpty) return null;
    final activePasses = _filterHealthyPasses(passes);
    if (activePasses.isEmpty) return null;
    final width = physicalSize.width.round();
    final height = physicalSize.height.round();
    if (width <= 0 || height <= 0) return null;

    if (_usePixelUploadForImages) {
      await _primeAsyncPassImages(
        inputImage: inputImage,
        wallpaperImage: wallpaperImage,
      );
      if (_disposed) return null;
    }

    final inputTexture = _resolveInputImageTexture(inputImage);
    if (inputImage != null && inputTexture == null) return null;
    final wallpaperTexture = _wrapCachedWallpaperImage(wallpaperImage);
    final isForeground = inputImage != null;
    final paneKey = _paneKeyForPasses(
      activePasses,
      fallbackPrefix: isForeground ? 'fg' : 'bg',
    );

    final completion = Completer<bool>();
    final image = _renderPasses(
      paneKey: paneKey,
      passes: activePasses,
      width: width,
      height: height,
      inputTexture: inputTexture,
      wallpaperTexture: wallpaperTexture,
      isForeground: isForeground,
      completion: completion,
      gatePaneKey: null,
      gateToken: null,
      watchdog: watchdog ?? this.watchdog,
    );
    if (image == null) return null;
    await completion.future.timeout(
      gpuCompletionTimeout,
      onTimeout: () => true,
    );
    if (_disposed) {
      image.dispose();
      return null;
    }
    return image;
  }

  @override
  Future<bool> prepareDirectResources({
    required ui.Image atlasImage,
    ui.Image? wallpaperImage,
    Iterable<ui.Image> kittyImages = const <ui.Image>[],
  }) async {
    if (_disposed || _directPipelineFailed || !_compiler.isAvailable) {
      return false;
    }
    final pipelineReady =
        (_directAtlasLibrary != null && _directAtlasPipeline != null) ||
        await (_directPrepareFuture ??= _compileDirectAtlasPipeline());
    if (!pipelineReady || _disposed) return false;
    if (!_usePixelUploadForImages) return true;
    return _primeDirectPixelUploads(
      atlasImage: atlasImage,
      wallpaperImage: wallpaperImage,
      kittyImages: kittyImages,
    );
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
    _lastSyncFrameSkipped = false;
    if (_disposed || _directPipelineFailed) return null;
    final pipeline = _directAtlasPipeline;
    if (pipeline == null) return null;
    final activeBackgroundPasses = _filterHealthyPasses(backgroundPasses);
    final activeForegroundPasses = _filterHealthyPasses(foregroundPasses);

    final width = physicalSize.width.round();
    final height = physicalSize.height.round();
    if (width <= 0 || height <= 0) return null;

    final atlasTexture = _wrapCachedAtlasImage(atlasImage);
    if (atlasTexture == null) return null;
    final wallpaperTexture = _wrapCachedWallpaperImage(wallpaperImage);
    if (wallpaperImage != null &&
        _usePixelUploadForImages &&
        wallpaperTexture == null) {
      return null;
    }
    final kittyTextures = _wrapKittyQuadTextures(batch.kittyQuads);
    if (kittyTextures == null) return null;

    final paneKey = batch.paneKey;
    final gateToken = _tryAcquireSyncFrameSlot(paneKey);
    if (gateToken == null) {
      _lastSyncFrameSkipped = true;
      return null;
    }

    final image = _executeDirectSurfaceRender(
      paneKey: paneKey,
      gateToken: gateToken,
      pipeline: pipeline,
      backgroundPasses: activeBackgroundPasses,
      foregroundPasses: activeForegroundPasses,
      width: width,
      height: height,
      atlasTexture: atlasTexture,
      wallpaperImage: wallpaperImage,
      wallpaperTexture: wallpaperTexture,
      batch: batch,
      kittyTextures: kittyTextures,
      watchdog: watchdog ?? this.watchdog,
    );
    if (image != null) {
      _markPanePrimed(paneKey);
    }
    return image;
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    final active = _handles.toList();
    _handles.clear();
    for (final handle in active) {
      handle.dispose();
    }
    _backgroundSurfacePool.clear();
    _foregroundSurfacePool.clear();
    _directSurfacePool.clear();
    _backgroundRingPool.clear();
    _foregroundRingPool.clear();
    _directRingPool.clear();
    _directScenePool.clear();
    _regionOutPool.clear();
    _scratchPool.clear();
    _pingPongRegistry.clear();
    _uniformBumpAllocator.clear();
    _auxQuadBumpAllocator.clear();
    _inFlightGate.reset();
    _primedPanes.clear();
    _lastBumpFrameStamp = null;
    _directAtlasPipeline = null;
    _directAtlasVertexShader = null;
    _directAtlasFragmentShader = null;
    _directAtlasUniformSlot = null;
    _directAtlasSamplerSlot = null;
    _directAtlasLibrary = null;
    _directUnitQuadBuffer = null;
    _paneUploadCaches.clear();
    _uploadedAtlasTextures.clear();
    _uploadedWallpaperTextures.clear();
    _uploadedInputTextures.clear();
    _uploadedKittyTextures.clear();
    _uploadedKittyCapacity = _maxUploadedKittyTextures;
    _pixelUploadsInFlight.clear();
    _cachedRegionMasks.clear();
    _viewportUboCache.clear();
    _cachedStaticLayers.clear();
    _uniformPackScratch = null;
    _uniformPackScratchPalettes.clear();
    _uniformPackScratchStride = 0;
    _directAuxQuadScratch = null;
    _fullscreenVertexBuffer = null;
    _fallbackTexture = null;
    _staticCacheHits = 0;
    _staticCacheMisses = 0;
    _lastGpuCompletionUs = 0;
    _lastSyncFrameSkipped = false;
  }

  Future<bool> _compileDirectAtlasPipeline() async {
    try {
      final bytes = await _compiler.compileRawBundle(
        vertexGlsl: GpuAtlasShaders.impellerVertexSource,
        fragmentGlsl: GpuAtlasShaders.impellerFragmentSource,
        vertexEntryName: GpuAtlasShaders.impellerVertexName,
        fragmentEntryName: GpuAtlasShaders.impellerFragmentName,
        shaderId: 'direct_gpu_atlas',
      );
      if (_disposed) return false;
      final library = await _loadShaderLibrary('direct_gpu_atlas', bytes);
      if (_disposed) return false;
      final vert = library[GpuAtlasShaders.impellerVertexName];
      final frag = library[GpuAtlasShaders.impellerFragmentName];
      if (vert == null || frag == null) {
        _directPipelineFailed = true;
        return false;
      }
      final pipeline = _context.createRenderPipeline(
        vert,
        frag,
        vertexLayout: _directAtlasVertexLayout,
      );
      _directAtlasLibrary = library;
      _directAtlasVertexShader = vert;
      _directAtlasFragmentShader = frag;
      _directAtlasUniformSlot = vert.getUniformSlot(
        GpuAtlasShaders.uniformBlockName,
      );
      _directAtlasSamplerSlot = frag.getUniformSlot(
        GpuAtlasShaders.atlasSamplerName,
      );
      _directAtlasPipeline = pipeline;
      return true;
    } on Object {
      _directPipelineFailed = true;
      return false;
    } finally {
      _directPrepareFuture = null;
    }
  }

  List<gpu.Texture>? _wrapKittyQuadTextures(List<GpuKittyQuad> quads) {
    if (quads.isEmpty) return const <gpu.Texture>[];
    if (_usePixelUploadForImages) {
      final wrapped = <gpu.Texture>[];
      for (final quad in quads) {
        final tex = _touchLruTexture(_uploadedKittyTextures, quad.image);
        if (tex == null) return null;
        wrapped.add(tex);
      }
      return wrapped;
    }
    final cache = Map<ui.Image, gpu.Texture>.identity();
    final wrapped = <gpu.Texture>[];
    for (final quad in quads) {
      var tex = cache[quad.image];
      if (tex == null) {
        tex = _tryWrapImage(quad.image);
        if (tex == null) return null;
        cache[quad.image] = tex;
      }
      wrapped.add(tex);
    }
    return wrapped;
  }

  void _markPanePrimed(Object paneKey) {
    _primedPanes.remove(paneKey);
    while (_primedPanes.length >= _maxPrimedPanes && _primedPanes.isNotEmpty) {
      final evicted = _primedPanes.first;
      _primedPanes.remove(evicted);
      _inFlightGate.removePane(evicted);
    }
    _primedPanes.add(paneKey);
  }

  int? _tryAcquireSyncFrameSlot(Object paneKey) {
    final bypassForPriming = !_primedPanes.contains(paneKey);
    final token = _inFlightGate.tryAcquire(
      paneKey,
      bypassForPriming: bypassForPriming,
    );
    if (token != null) return token;
    if (ShaderPerfTrace.isEnabled) {
      ShaderPerfTrace.incrementCounter('backpressureSkips');
    }
    return null;
  }

  Object _paneKeyForPasses(
    List<ShaderPassInvocation> passes, {
    required String fallbackPrefix,
  }) {
    if (passes.isNotEmpty) {
      final key = passes.first.prevFrameKey;
      if (key != null && key.isNotEmpty) {
        final sep = key.indexOf(':');
        if (sep > 0) return '$fallbackPrefix:${key.substring(0, sep)}';
      }
    }
    return fallbackPrefix;
  }

  void _advanceBumpAllocatorsIfNewFrame() {
    final stamp = SchedulerBinding.instance.currentSystemFrameTimeStamp;
    if (_lastBumpFrameStamp == stamp) return;
    _lastBumpFrameStamp = stamp;
    _uniformBumpAllocator.advanceFrame();
    _auxQuadBumpAllocator.advanceFrame();
  }

  ui.Image? _executeDirectSurfaceRender({
    required Object paneKey,
    required int gateToken,
    required gpu.RenderPipeline pipeline,
    required List<ShaderPassInvocation> backgroundPasses,
    required List<ShaderPassInvocation> foregroundPasses,
    required int width,
    required int height,
    required gpu.Texture atlasTexture,
    required ui.Image? wallpaperImage,
    required gpu.Texture? wallpaperTexture,
    required GpuAtlasQuadBatch batch,
    required List<gpu.Texture> kittyTextures,
    required GpuFrameWatchdog? watchdog,
  }) {
    final tracing = ShaderPerfTrace.isEnabled;
    final startUs = tracing
        ? ShaderPerfTrace.beginSpan('FlutterGpu.renderDirect')
        : 0;
    try {
      if (_useTextureRingSurface) {
        return _executeDirectRingFrame(
          paneKey: paneKey,
          gateToken: gateToken,
          pipeline: pipeline,
          backgroundPasses: backgroundPasses,
          foregroundPasses: foregroundPasses,
          width: width,
          height: height,
          atlasTexture: atlasTexture,
          wallpaperImage: wallpaperImage,
          wallpaperTexture: wallpaperTexture,
          batch: batch,
          kittyTextures: kittyTextures,
          watchdog: watchdog,
        );
      }
      return _executeDirectImageSurfaceFrame(
        paneKey: paneKey,
        gateToken: gateToken,
        pipeline: pipeline,
        backgroundPasses: backgroundPasses,
        foregroundPasses: foregroundPasses,
        width: width,
        height: height,
        atlasTexture: atlasTexture,
        wallpaperImage: wallpaperImage,
        wallpaperTexture: wallpaperTexture,
        batch: batch,
        kittyTextures: kittyTextures,
        watchdog: watchdog,
      );
    } finally {
      if (tracing) {
        ShaderPerfTrace.endSpan('FlutterGpu.renderDirect', startUs);
        _recordDiagnosticsTraceCounter();
      }
    }
  }

  void _recordDiagnosticsTraceCounter() {
    final diag = readDiagnostics();
    ShaderPerfTrace.recordCounter('gpu.diagnostics', <String, num>{
      'inFlightFrames': diag.inFlightFrames,
      'maxFramesInFlight': diag.maxFramesInFlight,
      'backpressureSkips': diag.backpressureSkips,
      'backingTextureCount': diag.backingTextureCount,
      'surfaceCount': diag.surfaceCount,
      'staticCacheHits': diag.staticCacheHits,
      'staticCacheMisses': diag.staticCacheMisses,
      'lastGpuCompletionUs': diag.lastGpuCompletionUs,
    });
  }

  ui.Image? _executeDirectRingFrame({
    required Object paneKey,
    required int gateToken,
    required gpu.RenderPipeline pipeline,
    required List<ShaderPassInvocation> backgroundPasses,
    required List<ShaderPassInvocation> foregroundPasses,
    required int width,
    required int height,
    required gpu.Texture atlasTexture,
    required ui.Image? wallpaperImage,
    required gpu.Texture? wallpaperTexture,
    required GpuAtlasQuadBatch batch,
    required List<gpu.Texture> kittyTextures,
    required GpuFrameWatchdog? watchdog,
  }) {
    var submissionStarted = false;
    final pendingSwaps = <GpuPingPongSlot<gpu.Texture>>[];
    try {
      _advanceBumpAllocatorsIfNewFrame();
      final ringTexture = _directRingPool.acquireNext(
        paneKey,
        width,
        height,
        _createRingTargetTexture,
      );
      final finalCommandBuffer = _encodeDirectFrameCommandBuffer(
        paneKey: paneKey,
        outputTexture: ringTexture,
        pipeline: pipeline,
        backgroundPasses: backgroundPasses,
        foregroundPasses: foregroundPasses,
        width: width,
        height: height,
        atlasTexture: atlasTexture,
        wallpaperImage: wallpaperImage,
        wallpaperTexture: wallpaperTexture,
        batch: batch,
        kittyTextures: kittyTextures,
        pendingSwaps: pendingSwaps,
        watchdog: watchdog,
      );
      submissionStarted = true;
      _submitFinalCommandBuffer(
        finalCommandBuffer,
        onSyncSubmitError: () => _directRingPool.remove(paneKey),
        gatePaneKey: paneKey,
        gateToken: gateToken,
        watchdog: watchdog,
        activeCustomShaderIds: _collectDirectCustomShaderIds(
          watchdog,
          backgroundPasses,
          foregroundPasses,
          batch.regionPasses,
        ),
      );
      for (final slot in pendingSwaps) {
        slot.commitWriteAndSwap();
      }
      return ringTexture.asImage();
    } finally {
      if (!submissionStarted) {
        _inFlightGate.release(paneKey, gateToken);
      }
    }
  }

  ui.Image? _executeDirectImageSurfaceFrame({
    required Object paneKey,
    required int gateToken,
    required gpu.RenderPipeline pipeline,
    required List<ShaderPassInvocation> backgroundPasses,
    required List<ShaderPassInvocation> foregroundPasses,
    required int width,
    required int height,
    required gpu.Texture atlasTexture,
    required ui.Image? wallpaperImage,
    required gpu.Texture? wallpaperTexture,
    required GpuAtlasQuadBatch batch,
    required List<gpu.Texture> kittyTextures,
    required GpuFrameWatchdog? watchdog,
  }) {
    var submissionStarted = false;
    gpu.GpuImageSurfaceFrame? surfaceFrame;
    var presented = false;
    final pendingSwaps = <GpuPingPongSlot<gpu.Texture>>[];
    try {
      _advanceBumpAllocatorsIfNewFrame();
      final surface = _directSurfacePool.obtain(
        paneKey,
        width,
        height,
        _createImageSurface,
      );
      final frame = surface.acquireNextFrame();
      surfaceFrame = frame;
      final finalCommandBuffer = _encodeDirectFrameCommandBuffer(
        paneKey: paneKey,
        outputTexture: frame.colorTexture,
        pipeline: pipeline,
        backgroundPasses: backgroundPasses,
        foregroundPasses: foregroundPasses,
        width: width,
        height: height,
        atlasTexture: atlasTexture,
        wallpaperImage: wallpaperImage,
        wallpaperTexture: wallpaperTexture,
        batch: batch,
        kittyTextures: kittyTextures,
        pendingSwaps: pendingSwaps,
        watchdog: watchdog,
      );
      frame.present(finalCommandBuffer);
      presented = true;
      submissionStarted = true;
      _submitFinalCommandBuffer(
        finalCommandBuffer,
        onSyncSubmitError: () => _directSurfacePool.remove(paneKey),
        gatePaneKey: paneKey,
        gateToken: gateToken,
        watchdog: watchdog,
        activeCustomShaderIds: _collectDirectCustomShaderIds(
          watchdog,
          backgroundPasses,
          foregroundPasses,
          batch.regionPasses,
        ),
      );
      for (final slot in pendingSwaps) {
        slot.commitWriteAndSwap();
      }
      return surface.currentImage;
    } finally {
      if (surfaceFrame != null && !presented) {
        surfaceFrame.discard();
      }
      if (!submissionStarted) {
        _inFlightGate.release(paneKey, gateToken);
      }
    }
  }

  gpu.CommandBuffer _encodeDirectFrameCommandBuffer({
    required Object paneKey,
    required gpu.Texture outputTexture,
    required gpu.RenderPipeline pipeline,
    required List<ShaderPassInvocation> backgroundPasses,
    required List<ShaderPassInvocation> foregroundPasses,
    required int width,
    required int height,
    required gpu.Texture atlasTexture,
    required ui.Image? wallpaperImage,
    required gpu.Texture? wallpaperTexture,
    required GpuAtlasQuadBatch batch,
    required List<gpu.Texture> kittyTextures,
    required List<GpuPingPongSlot<gpu.Texture>> pendingSwaps,
    required GpuFrameWatchdog? watchdog,
  }) {
    final hasForeground = foregroundPasses.isNotEmpty;
    final sceneTarget = hasForeground
        ? _directScenePool.obtain(
            paneKey,
            width,
            height,
            _createRenderTargetTexture,
          )
        : outputTexture;

    final fallback = _ensureFallbackTexture();
    final renderedRegions = _renderDirectRegionPasses(
      pipeline: pipeline,
      batch: batch,
      atlasTexture: atlasTexture,
      wallpaperTexture: wallpaperTexture,
      fallback: fallback,
      pendingSwaps: pendingSwaps,
      watchdog: watchdog,
    );
    if (backgroundPasses.isNotEmpty) {
      _submitDirectShaderChain(
        paneKey: paneKey,
        passes: backgroundPasses,
        width: width,
        height: height,
        inputTexture: null,
        wallpaperTexture: wallpaperTexture,
        fallback: fallback,
        targetTexture: sceneTarget,
        pendingSwaps: pendingSwaps,
        watchdog: watchdog,
      );
    }

    final atlasCmd = _buildDirectSceneCommandBuffer(
      pipeline: pipeline,
      sceneTarget: sceneTarget,
      hasBackgroundPasses: backgroundPasses.isNotEmpty,
      hasForegroundPasses: hasForeground,
      width: width,
      height: height,
      atlasTexture: atlasTexture,
      wallpaperImage: wallpaperImage,
      wallpaperTexture: wallpaperTexture,
      batch: batch,
      kittyTextures: kittyTextures,
      renderedRegions: renderedRegions,
    );

    if (!hasForeground) return atlasCmd;
    atlasCmd.submit();
    return _buildDirectShaderChain(
      paneKey: paneKey,
      passes: foregroundPasses,
      width: width,
      height: height,
      inputTexture: sceneTarget,
      wallpaperTexture: wallpaperTexture,
      fallback: fallback,
      targetTexture: outputTexture,
      pendingSwaps: pendingSwaps,
      watchdog: watchdog,
    );
  }

  void _submitDirectShaderChain({
    required Object paneKey,
    required List<ShaderPassInvocation> passes,
    required int width,
    required int height,
    required gpu.Texture? inputTexture,
    required gpu.Texture? wallpaperTexture,
    required gpu.Texture fallback,
    required gpu.Texture targetTexture,
    required List<GpuPingPongSlot<gpu.Texture>> pendingSwaps,
    required GpuFrameWatchdog? watchdog,
  }) {
    final tracing = ShaderPerfTrace.isEnabled;
    final startUs = tracing
        ? ShaderPerfTrace.beginSpan('FlutterGpu.shaderChain')
        : 0;
    try {
      final cmd = _buildDirectShaderChain(
        paneKey: paneKey,
        passes: passes,
        width: width,
        height: height,
        inputTexture: inputTexture,
        wallpaperTexture: wallpaperTexture,
        fallback: fallback,
        targetTexture: targetTexture,
        pendingSwaps: pendingSwaps,
        watchdog: watchdog,
      );
      _submitIntermediateCommandBuffer(
        cmd,
        watchdog: watchdog,
        activeCustomShaderIds: _collectDirectCustomShaderIds(
          watchdog,
          passes,
          const <ShaderPassInvocation>[],
          const <ShaderRegionPassInvocation>[],
        ),
      );
    } finally {
      if (tracing) {
        ShaderPerfTrace.endSpan('FlutterGpu.shaderChain', startUs);
      }
    }
  }

  ({ByteData data, int alignedStride}) _packUniformBatchReusingScratch(
    List<TerminalShaderUniforms> uniformsList,
  ) {
    final alignment = _context.minimumUniformByteAlignment;
    final stride = alignUniformByteSize(
      ShadertoyGlslShim.uniformBufferByteLength,
      alignment,
    );
    final totalBytes = uniformsList.length * stride;
    var scratch = _uniformPackScratch;
    if (scratch == null ||
        scratch.lengthInBytes < totalBytes ||
        _uniformPackScratchStride != stride) {
      scratch = ByteData(totalBytes);
      _uniformPackScratch = scratch;
      _uniformPackScratchStride = stride;
      _uniformPackScratchPalettes.clear();
    }
    return packAlignedUniformBatch(
      uniformsList,
      minimumUniformByteAlignment: alignment,
      scratchBuffer: scratch,
      scratchPalettes: _uniformPackScratchPalettes,
    );
  }

  gpu.CommandBuffer _buildDirectShaderChain({
    required Object paneKey,
    required List<ShaderPassInvocation> passes,
    required int width,
    required int height,
    required gpu.Texture? inputTexture,
    required gpu.Texture? wallpaperTexture,
    required gpu.Texture fallback,
    required gpu.Texture targetTexture,
    required List<GpuPingPongSlot<gpu.Texture>> pendingSwaps,
    required GpuFrameWatchdog? watchdog,
  }) {
    final aligned = _packUniformBatchReusingScratch(<TerminalShaderUniforms>[
      for (final pass in passes) pass.uniforms,
    ]);
    final uboView = _stageUniformSlice(aligned.data);
    final vertexView = _ensureVertexBufferView();
    return _encodePassChain(
      paneKey: paneKey,
      passes: passes,
      width: width,
      height: height,
      uboBuffer: uboView.buffer,
      uboBaseOffset: uboView.offsetInBytes,
      uboStride: aligned.alignedStride,
      vertexView: vertexView,
      fallback: fallback,
      inputTexture: inputTexture,
      wallpaperTexture: wallpaperTexture,
      finalSurfaceTexture: targetTexture,
      pendingSwaps: pendingSwaps,
      watchdog: watchdog,
    );
  }

  gpu.UniformSlot get _resolvedDirectAtlasUniformSlot =>
      _directAtlasUniformSlot ??= _directAtlasVertexShader!.getUniformSlot(
        GpuAtlasShaders.uniformBlockName,
      );

  gpu.UniformSlot get _resolvedDirectAtlasSamplerSlot =>
      _directAtlasSamplerSlot ??= _directAtlasFragmentShader!.getUniformSlot(
        GpuAtlasShaders.atlasSamplerName,
      );

  gpu.CommandBuffer _buildDirectSceneCommandBuffer({
    required gpu.RenderPipeline pipeline,
    required gpu.Texture sceneTarget,
    required bool hasBackgroundPasses,
    required bool hasForegroundPasses,
    required int width,
    required int height,
    required gpu.Texture atlasTexture,
    required ui.Image? wallpaperImage,
    required gpu.Texture? wallpaperTexture,
    required GpuAtlasQuadBatch batch,
    required List<gpu.Texture> kittyTextures,
    required List<_RenderedGpuRegion> renderedRegions,
  }) {
    final tracing = ShaderPerfTrace.isEnabled;
    final startUs = tracing
        ? ShaderPerfTrace.beginSpan('FlutterGpu.buildScene')
        : 0;
    try {
      final drawCoverWallpaper =
          !hasBackgroundPasses &&
          wallpaperImage != null &&
          wallpaperTexture != null;
      final coverImage = drawCoverWallpaper ? wallpaperImage : null;
      final coverTexture = drawCoverWallpaper ? wallpaperTexture : null;
      final splitLayers =
          renderedRegions.isNotEmpty || batch.transformedInstanceCount > 0;
      final cachedLayers =
          _shouldUseStaticSceneLayerCache(
            batch: batch,
            renderedRegions: renderedRegions,
            hasBackgroundPasses: hasBackgroundPasses,
            hasForegroundPasses: hasForegroundPasses,
          )
          ? _obtainOrRenderStaticSceneLayers(
              pipeline: pipeline,
              width: width,
              height: height,
              atlasTexture: atlasTexture,
              wallpaperImage: coverImage,
              wallpaperTexture: coverTexture,
              batch: batch,
              kittyTextures: kittyTextures,
              splitLayers: splitLayers,
            )
          : null;
      final atlasCmd = _context.createCommandBuffer();
      if (cachedLayers != null) {
        _recordDirectCachedSceneCompositePass(
          commandBuffer: atlasCmd,
          pipeline: pipeline,
          targetTexture: sceneTarget,
          hasBackgroundPasses: hasBackgroundPasses,
          width: width,
          height: height,
          atlasTexture: atlasTexture,
          batch: batch,
          cachedLayers: cachedLayers,
          renderedRegions: renderedRegions,
        );
        return atlasCmd;
      }
      _recordDirectAtlasPass(
        commandBuffer: atlasCmd,
        pipeline: pipeline,
        targetTexture: sceneTarget,
        loadAction: hasBackgroundPasses
            ? gpu.LoadAction.load
            : gpu.LoadAction.clear,
        width: width,
        height: height,
        atlasTexture: atlasTexture,
        wallpaperImage: coverImage,
        wallpaperTexture: coverTexture,
        batch: batch,
        kittyTextures: kittyTextures,
        renderedRegions: renderedRegions,
      );
      return atlasCmd;
    } finally {
      if (tracing) {
        ShaderPerfTrace.endSpan('FlutterGpu.buildScene', startUs);
      }
    }
  }

  bool _shouldUseStaticSceneLayerCache({
    required GpuAtlasQuadBatch batch,
    required List<_RenderedGpuRegion> renderedRegions,
    required bool hasBackgroundPasses,
    required bool hasForegroundPasses,
  }) =>
      batch.instanceCount > 0 &&
      (renderedRegions.isNotEmpty ||
          batch.transformedInstanceCount > 0 ||
          hasBackgroundPasses ||
          hasForegroundPasses);

  _CachedStaticSceneLayers _obtainOrRenderStaticSceneLayers({
    required gpu.RenderPipeline pipeline,
    required int width,
    required int height,
    required gpu.Texture atlasTexture,
    required ui.Image? wallpaperImage,
    required gpu.Texture? wallpaperTexture,
    required GpuAtlasQuadBatch batch,
    required List<gpu.Texture> kittyTextures,
    required bool splitLayers,
  }) {
    final tracing = ShaderPerfTrace.isEnabled;
    final startUs = tracing
        ? ShaderPerfTrace.beginSpan('FlutterGpu.staticLayers')
        : 0;
    try {
      final key = batch.paneKey;
      final existing = _cachedStaticLayers.remove(key);
      if (existing != null &&
          existing.matches(
            width: width,
            height: height,
            batch: batch,
            atlasTexture: atlasTexture,
            wallpaperImage: wallpaperImage,
            wallpaperTexture: wallpaperTexture,
            kittyTextures: kittyTextures,
            splitLayers: splitLayers,
          )) {
        _cachedStaticLayers[key] = existing;
        _staticCacheHits++;
        if (tracing) ShaderPerfTrace.incrementCounter('staticHit');
        return existing;
      }
      _staticCacheMisses++;
      if (tracing) ShaderPerfTrace.incrementCounter('staticMiss');
      return _renderAndCacheStaticSceneLayers(
        key: key,
        existing: existing,
        pipeline: pipeline,
        width: width,
        height: height,
        atlasTexture: atlasTexture,
        wallpaperImage: wallpaperImage,
        wallpaperTexture: wallpaperTexture,
        batch: batch,
        kittyTextures: kittyTextures,
        splitLayers: splitLayers,
      );
    } finally {
      if (tracing) {
        ShaderPerfTrace.endSpan('FlutterGpu.staticLayers', startUs);
      }
    }
  }

  _CachedStaticSceneLayers _renderAndCacheStaticSceneLayers({
    required String key,
    required _CachedStaticSceneLayers? existing,
    required gpu.RenderPipeline pipeline,
    required int width,
    required int height,
    required gpu.Texture atlasTexture,
    required ui.Image? wallpaperImage,
    required gpu.Texture? wallpaperTexture,
    required GpuAtlasQuadBatch batch,
    required List<gpu.Texture> kittyTextures,
    required bool splitLayers,
  }) {
    final reuseExistingSize =
        existing != null &&
        existing.width == width &&
        existing.height == height;
    final bgTexture = reuseExistingSize
        ? existing.bgTexture
        : _createRenderTargetTexture(width, height);
    final fgTexture = splitLayers
        ? (reuseExistingSize ? existing.fgTexture : null) ??
              _createRenderTargetTexture(width, height)
        : null;

    final instanceBuffer = _stageDirectInstancesIfNeeded(batch);
    final bgEnd = batch.bgEndInstanceIndex.clamp(
      0,
      batch.italicStartInstanceIndex,
    );
    if (splitLayers) {
      _renderStaticBgLayer(
        pipeline: pipeline,
        targetTexture: bgTexture,
        width: width,
        height: height,
        atlasTexture: atlasTexture,
        wallpaperImage: wallpaperImage,
        wallpaperTexture: wallpaperTexture,
        instanceBuffer: instanceBuffer,
        bgEnd: bgEnd,
      );
      _renderStaticFgLayer(
        pipeline: pipeline,
        targetTexture: fgTexture!,
        width: width,
        height: height,
        atlasTexture: atlasTexture,
        instanceBuffer: instanceBuffer,
        batch: batch,
        bgEnd: bgEnd,
        kittyTextures: kittyTextures,
      );
    } else {
      _renderStaticCombinedLayer(
        pipeline: pipeline,
        targetTexture: bgTexture,
        width: width,
        height: height,
        atlasTexture: atlasTexture,
        wallpaperImage: wallpaperImage,
        wallpaperTexture: wallpaperTexture,
        instanceBuffer: instanceBuffer,
        batch: batch,
        bgEnd: bgEnd,
        kittyTextures: kittyTextures,
      );
    }

    final entry = _CachedStaticSceneLayers(
      bgTexture: bgTexture,
      fgTexture: fgTexture,
      splitLayers: splitLayers,
      width: width,
      height: height,
      generation: batch.generation,
      instanceData: batch.instanceData,
      instanceCount: batch.instanceCount,
      bgEnd: bgEnd,
      italicStart: batch.italicStartInstanceIndex,
      kittySplit: batch.kittyInsertInstanceIndex,
      atlasTexture: atlasTexture,
      wallpaperImage: wallpaperImage,
      wallpaperTexture: wallpaperTexture,
      kittyQuads: batch.kittyQuads,
      kittyTextures: List<gpu.Texture>.of(kittyTextures, growable: false),
    );
    _cachedStaticLayers[key] = entry;
    while (_cachedStaticLayers.length > _maxStaticSceneLayers) {
      _cachedStaticLayers.remove(_cachedStaticLayers.keys.first);
    }
    return entry;
  }

  void _renderStaticCombinedLayer({
    required gpu.RenderPipeline pipeline,
    required gpu.Texture targetTexture,
    required int width,
    required int height,
    required gpu.Texture atlasTexture,
    required ui.Image? wallpaperImage,
    required gpu.Texture? wallpaperTexture,
    required gpu.DeviceBuffer? instanceBuffer,
    required GpuAtlasQuadBatch batch,
    required int bgEnd,
    required List<gpu.Texture> kittyTextures,
  }) {
    final unitQuadView = _ensureDirectUnitQuadView();
    final atlasUbo = _stageDirectViewportUniform(width, height);
    final hasWallpaper = wallpaperImage != null && wallpaperTexture != null;
    final auxView = hasWallpaper || batch.kittyQuads.isNotEmpty
        ? _stageDirectAuxQuads(
            width: width,
            height: height,
            wallpaperImage: hasWallpaper ? wallpaperImage : null,
            kittyQuads: batch.kittyQuads,
          )
        : null;
    final cmd = _context.createCommandBuffer();
    final renderPass = _beginDirectAtlasRenderPass(
      commandBuffer: cmd,
      pipeline: pipeline,
      targetTexture: targetTexture,
      loadAction: gpu.LoadAction.clear,
      width: width,
      height: height,
      unitQuadView: unitQuadView,
      atlasUbo: atlasUbo,
    );
    final samplerSlot = _resolvedDirectAtlasSamplerSlot;
    var kittyAuxBase = 0;
    if (auxView != null && hasWallpaper) {
      renderPass.setColorBlendEnable(false);
      _drawAuxSingleQuad(renderPass, auxView, 0, samplerSlot, wallpaperTexture);
      kittyAuxBase = 1;
    }
    renderPass.setColorBlendEnable(true);
    renderPass.setColorBlendEquation(_premultipliedSrcOver);
    final italicStart = batch.italicStartInstanceIndex;
    final kittySplit = batch.kittyInsertInstanceIndex;
    _drawDirectSliceIfNonEmpty(
      renderPass,
      instanceBuffer,
      samplerSlot,
      atlasTexture,
      _nearestClampSampler,
      0,
      italicStart,
    );
    _drawDirectSliceIfNonEmpty(
      renderPass,
      instanceBuffer,
      samplerSlot,
      atlasTexture,
      _linearClampSampler,
      italicStart,
      kittySplit - italicStart,
    );
    _drawKittyAuxQuads(
      renderPass,
      auxView,
      kittyAuxBase,
      samplerSlot,
      kittyTextures,
    );
    _drawDirectSliceIfNonEmpty(
      renderPass,
      instanceBuffer,
      samplerSlot,
      atlasTexture,
      _nearestClampSampler,
      kittySplit,
      batch.instanceCount - kittySplit,
    );
    cmd.submit();
  }

  void _renderStaticBgLayer({
    required gpu.RenderPipeline pipeline,
    required gpu.Texture targetTexture,
    required int width,
    required int height,
    required gpu.Texture atlasTexture,
    required ui.Image? wallpaperImage,
    required gpu.Texture? wallpaperTexture,
    required gpu.DeviceBuffer? instanceBuffer,
    required int bgEnd,
  }) {
    final unitQuadView = _ensureDirectUnitQuadView();
    final atlasUbo = _stageDirectViewportUniform(width, height);
    final auxView = wallpaperImage != null && wallpaperTexture != null
        ? _stageDirectAuxQuads(
            width: width,
            height: height,
            wallpaperImage: wallpaperImage,
            kittyQuads: const <GpuKittyQuad>[],
          )
        : null;
    final cmd = _context.createCommandBuffer();
    final renderPass = _beginDirectAtlasRenderPass(
      commandBuffer: cmd,
      pipeline: pipeline,
      targetTexture: targetTexture,
      loadAction: gpu.LoadAction.clear,
      width: width,
      height: height,
      unitQuadView: unitQuadView,
      atlasUbo: atlasUbo,
    );
    final samplerSlot = _resolvedDirectAtlasSamplerSlot;
    if (auxView != null && wallpaperTexture != null) {
      renderPass.setColorBlendEnable(false);
      _drawAuxSingleQuad(renderPass, auxView, 0, samplerSlot, wallpaperTexture);
    }
    renderPass.setColorBlendEnable(true);
    renderPass.setColorBlendEquation(_premultipliedSrcOver);
    _drawDirectSliceIfNonEmpty(
      renderPass,
      instanceBuffer,
      samplerSlot,
      atlasTexture,
      _nearestClampSampler,
      0,
      bgEnd,
    );
    cmd.submit();
  }

  void _renderStaticFgLayer({
    required gpu.RenderPipeline pipeline,
    required gpu.Texture targetTexture,
    required int width,
    required int height,
    required gpu.Texture atlasTexture,
    required gpu.DeviceBuffer? instanceBuffer,
    required GpuAtlasQuadBatch batch,
    required int bgEnd,
    required List<gpu.Texture> kittyTextures,
  }) {
    final unitQuadView = _ensureDirectUnitQuadView();
    final atlasUbo = _stageDirectViewportUniform(width, height);
    final auxView = batch.kittyQuads.isNotEmpty
        ? _stageDirectAuxQuads(
            width: width,
            height: height,
            wallpaperImage: null,
            kittyQuads: batch.kittyQuads,
          )
        : null;
    final cmd = _context.createCommandBuffer();
    final renderPass = _beginDirectAtlasRenderPass(
      commandBuffer: cmd,
      pipeline: pipeline,
      targetTexture: targetTexture,
      loadAction: gpu.LoadAction.clear,
      width: width,
      height: height,
      unitQuadView: unitQuadView,
      atlasUbo: atlasUbo,
    );
    final samplerSlot = _resolvedDirectAtlasSamplerSlot;
    renderPass.setColorBlendEnable(true);
    renderPass.setColorBlendEquation(_premultipliedSrcOver);
    final italicStart = batch.italicStartInstanceIndex;
    final kittySplit = batch.kittyInsertInstanceIndex;
    _drawDirectSliceIfNonEmpty(
      renderPass,
      instanceBuffer,
      samplerSlot,
      atlasTexture,
      _nearestClampSampler,
      bgEnd,
      italicStart - bgEnd,
    );
    _drawDirectSliceIfNonEmpty(
      renderPass,
      instanceBuffer,
      samplerSlot,
      atlasTexture,
      _linearClampSampler,
      italicStart,
      kittySplit - italicStart,
    );
    _drawKittyAuxQuads(renderPass, auxView, 0, samplerSlot, kittyTextures);
    _drawDirectSliceIfNonEmpty(
      renderPass,
      instanceBuffer,
      samplerSlot,
      atlasTexture,
      _nearestClampSampler,
      kittySplit,
      batch.instanceCount - kittySplit,
    );
    cmd.submit();
  }

  void _recordDirectCachedSceneCompositePass({
    required gpu.CommandBuffer commandBuffer,
    required gpu.RenderPipeline pipeline,
    required gpu.Texture targetTexture,
    required bool hasBackgroundPasses,
    required int width,
    required int height,
    required gpu.Texture atlasTexture,
    required GpuAtlasQuadBatch batch,
    required _CachedStaticSceneLayers cachedLayers,
    required List<_RenderedGpuRegion> renderedRegions,
  }) {
    final unitQuadView = _ensureDirectUnitQuadView();
    final atlasUbo = _stageDirectViewportUniform(width, height);
    final split = cachedLayers.splitLayers;
    final transformedBuffer = split
        ? _stageTransformedInstancesIfNeeded(batch)
        : null;
    final auxView = _stageDirectAuxQuads(
      width: width,
      height: height,
      wallpaperImage: null,
      kittyQuads: const <GpuKittyQuad>[],
      renderedRegions: renderedRegions,
      fullscreenLayerQuadCount: split ? 2 : 1,
    );
    final renderPass = _beginDirectAtlasRenderPass(
      commandBuffer: commandBuffer,
      pipeline: pipeline,
      targetTexture: targetTexture,
      loadAction: hasBackgroundPasses
          ? gpu.LoadAction.load
          : gpu.LoadAction.dontCare,
      width: width,
      height: height,
      unitQuadView: unitQuadView,
      atlasUbo: atlasUbo,
    );
    final samplerSlot = _resolvedDirectAtlasSamplerSlot;
    if (auxView != null) {
      renderPass.setColorBlendEnable(hasBackgroundPasses);
      if (hasBackgroundPasses) {
        renderPass.setColorBlendEquation(_premultipliedSrcOver);
      }
      _drawAuxSingleQuad(
        renderPass,
        auxView,
        0,
        samplerSlot,
        cachedLayers.bgTexture,
      );
    }
    if (!split) return;
    renderPass.setColorBlendEnable(true);
    renderPass.setColorBlendEquation(_premultipliedSrcOver);
    const regionAuxBase = 2;
    final underXform = batch.transformedUnderGlyphCount.clamp(
      0,
      batch.transformedInstanceCount,
    );
    _drawRenderedRegionsForStage(
      renderPass: renderPass,
      auxView: auxView,
      regionAuxBase: regionAuxBase,
      samplerSlot: samplerSlot,
      renderedRegions: renderedRegions,
      stageFilter: ShaderRegionStage.underGlyphs,
    );
    _drawDirectSliceIfNonEmpty(
      renderPass,
      transformedBuffer,
      samplerSlot,
      atlasTexture,
      _linearClampSampler,
      0,
      underXform,
    );
    if (auxView != null && cachedLayers.fgTexture != null) {
      _drawAuxSingleQuad(
        renderPass,
        auxView,
        1,
        samplerSlot,
        cachedLayers.fgTexture!,
      );
    }
    _drawDirectSliceIfNonEmpty(
      renderPass,
      transformedBuffer,
      samplerSlot,
      atlasTexture,
      _linearClampSampler,
      underXform,
      batch.transformedInstanceCount - underXform,
    );
    _drawRenderedRegionsForStage(
      renderPass: renderPass,
      auxView: auxView,
      regionAuxBase: regionAuxBase,
      samplerSlot: samplerSlot,
      renderedRegions: renderedRegions,
      stageFilter: ShaderRegionStage.replaceGlyphs,
    );
    _drawRenderedRegionsForStage(
      renderPass: renderPass,
      auxView: auxView,
      regionAuxBase: regionAuxBase,
      samplerSlot: samplerSlot,
      renderedRegions: renderedRegions,
      stageFilter: ShaderRegionStage.overGlyphs,
    );
  }

  gpu.RenderPass _beginDirectAtlasRenderPass({
    required gpu.CommandBuffer commandBuffer,
    required gpu.RenderPipeline pipeline,
    required gpu.Texture targetTexture,
    required gpu.LoadAction loadAction,
    required int width,
    required int height,
    required gpu.BufferView unitQuadView,
    required gpu.DeviceBuffer atlasUbo,
  }) {
    final attachment = gpu.ColorAttachment(
      texture: targetTexture,
      loadAction: loadAction,
      storeAction: gpu.StoreAction.store,
    );
    final renderPass = commandBuffer.createRenderPass(
      gpu.RenderTarget.singleColor(attachment),
    );
    renderPass.bindPipeline(pipeline);
    renderPass.setCullMode(gpu.CullMode.none);
    renderPass.setPrimitiveType(gpu.PrimitiveType.triangle);
    renderPass.setViewport(gpu.Viewport(width: width, height: height));
    renderPass.bindVertexBuffer(unitQuadView, slot: 0);
    renderPass.bindUniform(
      _resolvedDirectAtlasUniformSlot,
      gpu.BufferView(
        atlasUbo,
        offsetInBytes: 0,
        lengthInBytes: GpuAtlasShaders.impellerUniformByteLength,
      ),
    );
    return renderPass;
  }

  void _recordDirectAtlasPass({
    required gpu.CommandBuffer commandBuffer,
    required gpu.RenderPipeline pipeline,
    required gpu.Texture targetTexture,
    required gpu.LoadAction loadAction,
    required int width,
    required int height,
    required gpu.Texture atlasTexture,
    required ui.Image? wallpaperImage,
    required gpu.Texture? wallpaperTexture,
    required GpuAtlasQuadBatch batch,
    required List<gpu.Texture> kittyTextures,
    required List<_RenderedGpuRegion> renderedRegions,
  }) {
    final unitQuadView = _ensureDirectUnitQuadView();
    final atlasUbo = _stageDirectViewportUniform(width, height);
    final instanceBuffer = _stageDirectInstancesIfNeeded(batch);
    final transformedBuffer = _stageTransformedInstancesIfNeeded(batch);
    final auxView = _stageDirectAuxQuads(
      width: width,
      height: height,
      wallpaperImage: wallpaperImage,
      kittyQuads: batch.kittyQuads,
      renderedRegions: renderedRegions,
    );

    final renderPass = _beginDirectAtlasRenderPass(
      commandBuffer: commandBuffer,
      pipeline: pipeline,
      targetTexture: targetTexture,
      loadAction: loadAction,
      width: width,
      height: height,
      unitQuadView: unitQuadView,
      atlasUbo: atlasUbo,
    );

    final samplerSlot = _resolvedDirectAtlasSamplerSlot;

    var auxQuadIndex = 0;
    if (wallpaperImage != null && wallpaperTexture != null && auxView != null) {
      renderPass.setColorBlendEnable(false);
      _drawAuxSingleQuad(
        renderPass,
        auxView,
        auxQuadIndex,
        samplerSlot,
        wallpaperTexture,
      );
      auxQuadIndex++;
    }

    renderPass.setColorBlendEnable(true);
    renderPass.setColorBlendEquation(_premultipliedSrcOver);

    _drawDirectAtlasLayers(
      renderPass: renderPass,
      batch: batch,
      instanceBuffer: instanceBuffer,
      transformedBuffer: transformedBuffer,
      auxView: auxView,
      auxQuadIndex: auxQuadIndex,
      samplerSlot: samplerSlot,
      atlasTexture: atlasTexture,
      kittyTextures: kittyTextures,
      renderedRegions: renderedRegions,
    );
  }

  void _drawDirectAtlasLayers({
    required gpu.RenderPass renderPass,
    required GpuAtlasQuadBatch batch,
    required gpu.DeviceBuffer? instanceBuffer,
    required gpu.DeviceBuffer? transformedBuffer,
    required gpu.BufferView? auxView,
    required int auxQuadIndex,
    required gpu.UniformSlot samplerSlot,
    required gpu.Texture atlasTexture,
    required List<gpu.Texture> kittyTextures,
    required List<_RenderedGpuRegion> renderedRegions,
  }) {
    final bgEnd = batch.bgEndInstanceIndex.clamp(
      0,
      batch.italicStartInstanceIndex,
    );
    final italicStart = batch.italicStartInstanceIndex;
    final kittySplit = batch.kittyInsertInstanceIndex;
    final underXform = batch.transformedUnderGlyphCount.clamp(
      0,
      batch.transformedInstanceCount,
    );
    final regionAuxBase = auxQuadIndex + kittyTextures.length;

    _drawDirectSliceIfNonEmpty(
      renderPass,
      instanceBuffer,
      samplerSlot,
      atlasTexture,
      _nearestClampSampler,
      0,
      bgEnd,
    );
    _drawRenderedRegionsForStage(
      renderPass: renderPass,
      auxView: auxView,
      regionAuxBase: regionAuxBase,
      samplerSlot: samplerSlot,
      renderedRegions: renderedRegions,
      stageFilter: ShaderRegionStage.underGlyphs,
    );
    _drawDirectSliceIfNonEmpty(
      renderPass,
      transformedBuffer,
      samplerSlot,
      atlasTexture,
      _linearClampSampler,
      0,
      underXform,
    );
    _drawDirectSliceIfNonEmpty(
      renderPass,
      instanceBuffer,
      samplerSlot,
      atlasTexture,
      _nearestClampSampler,
      bgEnd,
      italicStart - bgEnd,
    );
    _drawDirectSliceIfNonEmpty(
      renderPass,
      instanceBuffer,
      samplerSlot,
      atlasTexture,
      _linearClampSampler,
      italicStart,
      kittySplit - italicStart,
    );
    _drawKittyAuxQuads(
      renderPass,
      auxView,
      auxQuadIndex,
      samplerSlot,
      kittyTextures,
    );
    _drawDirectSliceIfNonEmpty(
      renderPass,
      instanceBuffer,
      samplerSlot,
      atlasTexture,
      _nearestClampSampler,
      kittySplit,
      batch.instanceCount - kittySplit,
    );
    _drawDirectSliceIfNonEmpty(
      renderPass,
      transformedBuffer,
      samplerSlot,
      atlasTexture,
      _linearClampSampler,
      underXform,
      batch.transformedInstanceCount - underXform,
    );
    _drawRenderedRegionsForStage(
      renderPass: renderPass,
      auxView: auxView,
      regionAuxBase: regionAuxBase,
      samplerSlot: samplerSlot,
      renderedRegions: renderedRegions,
      stageFilter: ShaderRegionStage.replaceGlyphs,
    );
    _drawRenderedRegionsForStage(
      renderPass: renderPass,
      auxView: auxView,
      regionAuxBase: regionAuxBase,
      samplerSlot: samplerSlot,
      renderedRegions: renderedRegions,
      stageFilter: ShaderRegionStage.overGlyphs,
    );
  }

  void _drawDirectSliceIfNonEmpty(
    gpu.RenderPass renderPass,
    gpu.DeviceBuffer? buffer,
    gpu.UniformSlot samplerSlot,
    gpu.Texture atlasTexture,
    gpu.SamplerOptions sampler,
    int startInstance,
    int count,
  ) {
    if (buffer == null || count <= 0) return;
    _drawDirectAtlasSlice(
      renderPass: renderPass,
      instanceBuffer: buffer,
      samplerSlot: samplerSlot,
      atlasTexture: atlasTexture,
      sampler: sampler,
      startInstance: startInstance,
      count: count,
    );
  }

  void _drawKittyAuxQuads(
    gpu.RenderPass renderPass,
    gpu.BufferView? auxView,
    int auxQuadIndex,
    gpu.UniformSlot samplerSlot,
    List<gpu.Texture> kittyTextures,
  ) {
    if (auxView == null || kittyTextures.isEmpty) return;
    var i = 0;
    while (i < kittyTextures.length) {
      final tex = kittyTextures[i];
      var runEnd = i + 1;
      while (runEnd < kittyTextures.length &&
          identical(kittyTextures[runEnd], tex)) {
        runEnd++;
      }
      final count = runEnd - i;
      renderPass.bindVertexBuffer(
        gpu.BufferView(
          auxView.buffer,
          offsetInBytes:
              auxView.offsetInBytes +
              (auxQuadIndex + i) * GpuAtlasQuadBatch.bytesPerInstance,
          lengthInBytes: count * GpuAtlasQuadBatch.bytesPerInstance,
        ),
        slot: 1,
      );
      renderPass.bindTexture(samplerSlot, tex, sampler: _linearClampSampler);
      renderPass.draw(6, instanceCount: count);
      i = runEnd;
    }
  }

  void _drawAuxSingleQuad(
    gpu.RenderPass renderPass,
    gpu.BufferView auxView,
    int quadIndex,
    gpu.UniformSlot samplerSlot,
    gpu.Texture texture,
  ) {
    renderPass.bindVertexBuffer(
      gpu.BufferView(
        auxView.buffer,
        offsetInBytes:
            auxView.offsetInBytes +
            quadIndex * GpuAtlasQuadBatch.bytesPerInstance,
        lengthInBytes: GpuAtlasQuadBatch.bytesPerInstance,
      ),
      slot: 1,
    );
    renderPass.bindTexture(samplerSlot, texture, sampler: _linearClampSampler);
    renderPass.draw(6, instanceCount: 1);
  }

  void _drawRenderedRegionsForStage({
    required gpu.RenderPass renderPass,
    required gpu.BufferView? auxView,
    required int regionAuxBase,
    required gpu.UniformSlot samplerSlot,
    required List<_RenderedGpuRegion> renderedRegions,
    required ShaderRegionStage stageFilter,
  }) {
    if (auxView == null) return;
    for (var i = 0; i < renderedRegions.length; i++) {
      final entry = renderedRegions[i];
      if (entry.pass.stage != stageFilter) continue;
      _drawAuxSingleQuad(
        renderPass,
        auxView,
        regionAuxBase + i,
        samplerSlot,
        entry.texture,
      );
    }
  }

  List<_RenderedGpuRegion> _renderDirectRegionPasses({
    required gpu.RenderPipeline pipeline,
    required GpuAtlasQuadBatch batch,
    required gpu.Texture atlasTexture,
    required gpu.Texture? wallpaperTexture,
    required gpu.Texture fallback,
    required List<GpuPingPongSlot<gpu.Texture>> pendingSwaps,
    required GpuFrameWatchdog? watchdog,
  }) {
    if (batch.regionPasses.isEmpty) {
      if (_cachedRegionMasks.isNotEmpty) {
        _cachedRegionMasks.removeWhere((key, _) => key.$1 == batch.paneKey);
      }
      return const <_RenderedGpuRegion>[];
    }
    final maskBuffer = _stageRegionMaskInstancesIfNeeded(batch);
    final results = <_RenderedGpuRegion>[];
    var slotIndex = 0;
    for (final regionPass in batch.regionPasses) {
      if (_isFailedHandle(regionPass.handle)) {
        continue;
      }
      final slice = _findRegionMaskSlice(
        batch.regionMaskSlices,
        regionPass.regionId,
      );
      if (slice == null) continue;
      final outTex = _renderSingleGpuRegionPass(
        paneKey: batch.paneKey,
        slotIndex: slotIndex++,
        pipeline: pipeline,
        regionPass: regionPass,
        slice: slice,
        maskData: batch.regionMaskInstanceData,
        maskGeneration: batch.regionMaskGeneration,
        maskBuffer: maskBuffer,
        atlasTexture: atlasTexture,
        wallpaperTexture: wallpaperTexture,
        fallback: fallback,
        pendingSwaps: pendingSwaps,
        watchdog: watchdog,
      );
      if (outTex != null) {
        results.add(_RenderedGpuRegion(pass: regionPass, texture: outTex));
      }
    }
    return results;
  }

  gpu.Texture _obtainRenderedRegionMask({
    required String paneKey,
    required String regionId,
    required gpu.RenderPipeline pipeline,
    required GpuRegionMaskSlice slice,
    required Float32List maskData,
    required int maskGeneration,
    required int mw,
    required int mh,
    required gpu.DeviceBuffer? maskBuffer,
    required gpu.Texture atlasTexture,
  }) {
    final cacheKey = (paneKey, regionId);
    final cached = _cachedRegionMasks.remove(cacheKey);
    if (cached != null &&
        cached.matches(
          maskData: maskData,
          generation: maskGeneration,
          startInstance: slice.startInstance,
          instanceCount: slice.instanceCount,
          width: mw,
          height: mh,
          atlasTexture: atlasTexture,
        )) {
      _cachedRegionMasks[cacheKey] = cached;
      return cached.texture;
    }

    final maskTex =
        (cached != null && cached.width == mw && cached.height == mh)
        ? cached.texture
        : _createRenderTargetTexture(mw, mh);
    final maskCmd = _context.createCommandBuffer();
    final maskPass = maskCmd.createRenderPass(
      gpu.RenderTarget.singleColor(
        gpu.ColorAttachment(
          texture: maskTex,
          loadAction: gpu.LoadAction.clear,
          storeAction: gpu.StoreAction.store,
        ),
      ),
    );
    if (maskBuffer != null && slice.instanceCount > 0) {
      final maskUbo = _stageDirectViewportUniform(mw, mh);
      maskPass.bindPipeline(pipeline);
      maskPass.setCullMode(gpu.CullMode.none);
      maskPass.setPrimitiveType(gpu.PrimitiveType.triangle);
      maskPass.setViewport(gpu.Viewport(width: mw, height: mh));
      maskPass.setColorBlendEnable(true);
      maskPass.setColorBlendEquation(_premultipliedSrcOver);
      maskPass.bindVertexBuffer(_ensureDirectUnitQuadView(), slot: 0);
      maskPass.bindUniform(
        _resolvedDirectAtlasUniformSlot,
        gpu.BufferView(
          maskUbo,
          offsetInBytes: 0,
          lengthInBytes: GpuAtlasShaders.impellerUniformByteLength,
        ),
      );
      _drawDirectAtlasSlice(
        renderPass: maskPass,
        instanceBuffer: maskBuffer,
        samplerSlot: _resolvedDirectAtlasSamplerSlot,
        atlasTexture: atlasTexture,
        sampler: _linearClampSampler,
        startInstance: slice.startInstance,
        count: slice.instanceCount,
      );
    }
    maskCmd.submit();
    while (_cachedRegionMasks.length >= _maxCachedRegionMasks &&
        _cachedRegionMasks.isNotEmpty) {
      _cachedRegionMasks.remove(_cachedRegionMasks.keys.first);
    }
    _cachedRegionMasks[cacheKey] = _CachedGpuRegionMask(
      texture: maskTex,
      maskData: maskData,
      generation: maskGeneration,
      startInstance: slice.startInstance,
      instanceCount: slice.instanceCount,
      width: mw,
      height: mh,
      atlasTexture: atlasTexture,
    );
    return maskTex;
  }

  gpu.Texture? _renderSingleGpuRegionPass({
    required String paneKey,
    required int slotIndex,
    required gpu.RenderPipeline pipeline,
    required ShaderRegionPassInvocation regionPass,
    required GpuRegionMaskSlice slice,
    required Float32List maskData,
    required int maskGeneration,
    required gpu.DeviceBuffer? maskBuffer,
    required gpu.Texture atlasTexture,
    required gpu.Texture? wallpaperTexture,
    required gpu.Texture fallback,
    required List<GpuPingPongSlot<gpu.Texture>> pendingSwaps,
    required GpuFrameWatchdog? watchdog,
  }) {
    final mw = regionPass.outputRectPhysical.width.round();
    final mh = regionPass.outputRectPhysical.height.round();
    if (mw <= 0 || mh <= 0) return null;

    // 1. Obtain cached (or freshly rasterized) tight uGlyphMask texture.
    final maskTex = _obtainRenderedRegionMask(
      paneKey: paneKey,
      regionId: regionPass.regionId,
      pipeline: pipeline,
      slice: slice,
      maskData: maskData,
      maskGeneration: maskGeneration,
      mw: mw,
      mh: mh,
      maskBuffer: maskBuffer,
      atlasTexture: atlasTexture,
    );

    // 2. Execute region fragment shader directly into ping-pong writeTexture
    // (when usesPrevFrame) or a per-slot pooled region output texture so
    // equal-sized sibling regions never overwrite each other mid-frame.
    final invocation = regionPass.toPassInvocation();
    final handle = _requireOwnedHandle(invocation.handle);
    final pingPong = handle.usesPrevFrame
        ? _pingPongRegistry.acquire(
            resolvePrevFrameKey(invocation),
            mw,
            mh,
            _createRenderTargetTexture,
            ownerTag: handle.id,
          )
        : null;
    final outTex =
        pingPong?.writeTexture ??
        _regionOutPool.obtain((
          slotIndex,
          mw,
          mh,
        ), () => _createRenderTargetTexture(mw, mh));
    final aligned = _packUniformBatchReusingScratch(<TerminalShaderUniforms>[
      invocation.uniforms,
    ]);
    final uboView = _stageUniformSlice(aligned.data);
    final regionCmd = _context.createCommandBuffer();
    _recordSinglePass(
      commandBuffer: regionCmd,
      handle: handle,
      targetTexture: outTex,
      width: mw,
      height: mh,
      vertexView: _ensureVertexBufferView(),
      uboBuffer: uboView.buffer,
      uboOffset: uboView.offsetInBytes,
      uboMaxLength: aligned.alignedStride,
      channel0: maskTex,
      channel1: wallpaperTexture ?? fallback,
      prevFrame: pingPong?.readTexture ?? fallback,
    );
    if (pingPong != null) {
      pendingSwaps.add(pingPong);
    }
    _submitIntermediateCommandBuffer(
      regionCmd,
      watchdog: watchdog,
      activeCustomShaderIds:
          watchdog != null && watchdog.isActiveCustomShader(regionPass.shaderId)
          ? <String>[regionPass.shaderId]
          : const <String>[],
    );
    return outTex;
  }

  GpuRegionMaskSlice? _findRegionMaskSlice(
    List<GpuRegionMaskSlice> slices,
    String regionId,
  ) {
    for (final slice in slices) {
      if (slice.regionId == regionId) return slice;
    }
    return null;
  }

  _PaneGpuUploadCache _obtainPaneUploadCache(String paneKey) {
    final existing = _paneUploadCaches.remove(paneKey);
    if (existing != null) {
      _paneUploadCaches[paneKey] = existing;
      return existing;
    }
    while (_paneUploadCaches.length >= _maxPaneUploadCaches &&
        _paneUploadCaches.isNotEmpty) {
      _paneUploadCaches.remove(_paneUploadCaches.keys.first);
    }
    final created = _PaneGpuUploadCache(_instanceRingLength);
    _paneUploadCaches[paneKey] = created;
    return created;
  }

  gpu.DeviceBuffer? _stageTransformedInstancesIfNeeded(
    GpuAtlasQuadBatch batch,
  ) {
    final count = batch.transformedInstanceCount;
    if (count <= 0) return null;
    final cache = _obtainPaneUploadCache(batch.paneKey).transformed;
    return _stageCachedInstanceSlot(
      slot: cache,
      data: batch.transformedInstanceData,
      generation: batch.transformedGeneration,
      count: count,
      initialCapacityBytes: 4096,
    );
  }

  gpu.DeviceBuffer? _stageRegionMaskInstancesIfNeeded(GpuAtlasQuadBatch batch) {
    final count = batch.regionMaskInstanceCount;
    if (count <= 0) return null;
    final cache = _obtainPaneUploadCache(batch.paneKey).regionMask;
    return _stageCachedInstanceSlot(
      slot: cache,
      data: batch.regionMaskInstanceData,
      generation: batch.regionMaskGeneration,
      count: count,
      initialCapacityBytes: 4096,
    );
  }

  gpu.DeviceBuffer _stageCachedInstanceSlot({
    required _GpuInstanceSlotCache slot,
    required Float32List data,
    required int generation,
    required int count,
    required int initialCapacityBytes,
  }) {
    final cached = slot.lastBuffer;
    if (cached != null &&
        identical(data, slot.lastData) &&
        generation == slot.lastGeneration &&
        count == slot.lastCount) {
      return cached;
    }
    final buffer = _uploadInstanceRing(
      ring: slot.ring,
      ringIndex: slot.ringIndex,
      data: data,
      count: count,
      initialCapacityBytes: initialCapacityBytes,
    );
    slot.ringIndex = (slot.ringIndex + 1) % slot.ring.length;
    slot.lastBuffer = buffer;
    slot.lastData = data;
    slot.lastGeneration = generation;
    slot.lastCount = count;
    return buffer;
  }

  gpu.DeviceBuffer _uploadInstanceRing({
    required List<gpu.DeviceBuffer?> ring,
    required int ringIndex,
    required Float32List data,
    required int count,
    int initialCapacityBytes = 4096,
  }) {
    final byteLength = count * GpuAtlasQuadBatch.bytesPerInstance;
    var buffer = ring[ringIndex];
    if (buffer == null || buffer.sizeInBytes < byteLength) {
      var capBytes = buffer?.sizeInBytes ?? initialCapacityBytes;
      while (capBytes < byteLength) {
        capBytes <<= 1;
      }
      buffer = _context.createDeviceBuffer(
        gpu.StorageMode.hostVisible,
        capBytes,
      );
      ring[ringIndex] = buffer;
    }
    final activeBytes = ByteData.sublistView(
      data,
      0,
      count * GpuAtlasQuadBatch.floatsPerInstance,
    );
    buffer.overwrite(activeBytes);
    buffer.flush(offsetInBytes: 0, lengthInBytes: byteLength);
    return buffer;
  }

  List<String> _collectDirectCustomShaderIds(
    GpuFrameWatchdog? wd,
    List<ShaderPassInvocation> bg,
    List<ShaderPassInvocation> fg,
    List<ShaderRegionPassInvocation> regions,
  ) {
    if (wd == null || wd.activeCustomShaderIds.isEmpty) {
      return const <String>[];
    }
    final active = <String>[];
    for (final p in bg) {
      if (wd.isActiveCustomShader(p.handle.id)) active.add(p.handle.id);
    }
    for (final p in fg) {
      if (wd.isActiveCustomShader(p.handle.id)) active.add(p.handle.id);
    }
    for (final r in regions) {
      if (wd.isActiveCustomShader(r.shaderId)) active.add(r.shaderId);
    }
    return active;
  }

  void _drawDirectAtlasSlice({
    required gpu.RenderPass renderPass,
    required gpu.DeviceBuffer instanceBuffer,
    required gpu.UniformSlot samplerSlot,
    required gpu.Texture atlasTexture,
    required gpu.SamplerOptions sampler,
    required int startInstance,
    required int count,
  }) {
    renderPass.bindVertexBuffer(
      gpu.BufferView(
        instanceBuffer,
        offsetInBytes: startInstance * GpuAtlasQuadBatch.bytesPerInstance,
        lengthInBytes: count * GpuAtlasQuadBatch.bytesPerInstance,
      ),
      slot: 1,
    );
    renderPass.bindTexture(samplerSlot, atlasTexture, sampler: sampler);
    renderPass.draw(6, instanceCount: count);
  }

  gpu.BufferView _ensureDirectUnitQuadView() {
    final buffer = _directUnitQuadBuffer ??= _context
        .createDeviceBufferWithCopy(
          GpuAtlasShaders.unitQuadVertices.buffer.asByteData(),
        );
    return gpu.BufferView(
      buffer,
      offsetInBytes: 0,
      lengthInBytes: buffer.sizeInBytes,
    );
  }

  gpu.DeviceBuffer _stageDirectViewportUniform(int width, int height) {
    final key = (width, height);
    final cached = _viewportUboCache.remove(key);
    if (cached != null) {
      _viewportUboCache[key] = cached;
      return cached;
    }
    _directViewportUniformScratch[0] = width.toDouble();
    _directViewportUniformScratch[1] = height.toDouble();
    _directViewportUniformScratch[2] = 0.0;
    _directViewportUniformScratch[3] = 0.0;
    const byteLength = GpuAtlasShaders.impellerUniformByteLength;
    final buffer = _context.createDeviceBuffer(
      gpu.StorageMode.hostVisible,
      byteLength,
    );
    buffer.overwrite(
      _directViewportUniformScratch.buffer.asByteData(0, byteLength),
    );
    buffer.flush(offsetInBytes: 0, lengthInBytes: byteLength);
    _viewportUboCache[key] = buffer;
    while (_viewportUboCache.length > _maxViewportUboEntries) {
      _viewportUboCache.remove(_viewportUboCache.keys.first);
    }
    return buffer;
  }

  gpu.DeviceBuffer? _stageDirectInstancesIfNeeded(GpuAtlasQuadBatch batch) {
    final count = batch.instanceCount;
    if (count <= 0) return null;
    final cache = _obtainPaneUploadCache(batch.paneKey).staticGrid;
    return _stageCachedInstanceSlot(
      slot: cache,
      data: batch.instanceData,
      generation: batch.generation,
      count: count,
      initialCapacityBytes: 16384,
    );
  }

  gpu.BufferView? _stageDirectAuxQuads({
    required int width,
    required int height,
    required ui.Image? wallpaperImage,
    required List<GpuKittyQuad> kittyQuads,
    List<_RenderedGpuRegion> renderedRegions = const <_RenderedGpuRegion>[],
    int fullscreenLayerQuadCount = 0,
  }) {
    final quadCount =
        fullscreenLayerQuadCount +
        (wallpaperImage != null ? 1 : 0) +
        kittyQuads.length +
        renderedRegions.length;
    if (quadCount <= 0) return null;
    final requiredFloats = quadCount * GpuAtlasQuadBatch.floatsPerInstance;
    final byteLength = quadCount * GpuAtlasQuadBatch.bytesPerInstance;
    var scratch = _directAuxQuadScratch;
    if (scratch == null || scratch.length < requiredFloats) {
      scratch = Float32List(requiredFloats);
      _directAuxQuadScratch = scratch;
    }
    var offsetFloats = 0;
    for (var i = 0; i < fullscreenLayerQuadCount; i++) {
      GpuAtlasShaders.writeTexturedQuadInstance(
        Float32List.sublistView(
          scratch,
          offsetFloats,
          offsetFloats + GpuAtlasQuadBatch.floatsPerInstance,
        ),
        dstX: 0.0,
        dstY: 0.0,
        dstWidth: width.toDouble(),
        dstHeight: height.toDouble(),
        u0: 0.0,
        v0: 0.0,
        u1: 1.0,
        v1: 1.0,
      );
      offsetFloats += GpuAtlasQuadBatch.floatsPerInstance;
    }
    if (wallpaperImage != null) {
      final uv = GpuAtlasShaders.computeCoverUvRect(
        imageWidth: wallpaperImage.width.toDouble(),
        imageHeight: wallpaperImage.height.toDouble(),
        viewportWidth: width.toDouble(),
        viewportHeight: height.toDouble(),
      );
      GpuAtlasShaders.writeTexturedQuadInstance(
        Float32List.sublistView(
          scratch,
          offsetFloats,
          offsetFloats + GpuAtlasQuadBatch.floatsPerInstance,
        ),
        dstX: 0.0,
        dstY: 0.0,
        dstWidth: width.toDouble(),
        dstHeight: height.toDouble(),
        u0: uv.u0,
        v0: uv.v0,
        u1: uv.u1,
        v1: uv.v1,
      );
      offsetFloats += GpuAtlasQuadBatch.floatsPerInstance;
    }
    for (final quad in kittyQuads) {
      GpuAtlasShaders.writeTexturedQuadInstance(
        Float32List.sublistView(
          scratch,
          offsetFloats,
          offsetFloats + GpuAtlasQuadBatch.floatsPerInstance,
        ),
        dstX: quad.dstX,
        dstY: quad.dstY,
        dstWidth: quad.dstWidth,
        dstHeight: quad.dstHeight,
        u0: quad.u0,
        v0: quad.v0,
        u1: quad.u1,
        v1: quad.v1,
      );
      offsetFloats += GpuAtlasQuadBatch.floatsPerInstance;
    }
    for (final region in renderedRegions) {
      final dst = region.pass.outputRectPhysical;
      GpuAtlasShaders.writeTexturedQuadInstance(
        Float32List.sublistView(
          scratch,
          offsetFloats,
          offsetFloats + GpuAtlasQuadBatch.floatsPerInstance,
        ),
        dstX: dst.left,
        dstY: dst.top,
        dstWidth: dst.width,
        dstHeight: dst.height,
        u0: 0.0,
        v0: 0.0,
        u1: 1.0,
        v1: 1.0,
      );
      offsetFloats += GpuAtlasQuadBatch.floatsPerInstance;
    }
    final slice = _auxQuadBumpAllocator.allocate(
      byteLength: byteLength,
      alignment: 16,
      createBlock: (cap) =>
          _context.createDeviceBuffer(gpu.StorageMode.hostVisible, cap),
    );
    slice.buffer.overwrite(
      scratch.buffer.asByteData(0, byteLength),
      destinationOffsetInBytes: slice.offsetInBytes,
    );
    slice.buffer.flush(
      offsetInBytes: slice.offsetInBytes,
      lengthInBytes: byteLength,
    );
    return gpu.BufferView(
      slice.buffer,
      offsetInBytes: slice.offsetInBytes,
      lengthInBytes: byteLength,
    );
  }

  ui.Image? _renderPasses({
    required Object paneKey,
    required List<ShaderPassInvocation> passes,
    required int width,
    required int height,
    required gpu.Texture? inputTexture,
    required gpu.Texture? wallpaperTexture,
    required bool isForeground,
    Completer<bool>? completion,
    required Object? gatePaneKey,
    required int? gateToken,
    required GpuFrameWatchdog? watchdog,
  }) {
    if (_useTextureRingSurface) {
      final ringPool = isForeground ? _foregroundRingPool : _backgroundRingPool;
      return _executeRingRender(
        paneKey: paneKey,
        ringPool: ringPool,
        passes: passes,
        width: width,
        height: height,
        inputTexture: inputTexture,
        wallpaperTexture: wallpaperTexture,
        completion: completion,
        gatePaneKey: gatePaneKey,
        gateToken: gateToken,
        watchdog: watchdog,
      );
    }
    final surfacePool = isForeground
        ? _foregroundSurfacePool
        : _backgroundSurfacePool;
    return _executeSurfaceRender(
      paneKey: paneKey,
      surfacePool: surfacePool,
      passes: passes,
      width: width,
      height: height,
      inputTexture: inputTexture,
      wallpaperTexture: wallpaperTexture,
      completion: completion,
      gatePaneKey: gatePaneKey,
      gateToken: gateToken,
      watchdog: watchdog,
    );
  }

  /// Filters [passes] to exclude shader handles whose GPU pipeline failed to
  /// link or draw so healthy passes and direct atlas rendering continue
  /// uninterrupted.
  ///
  /// Returns [passes] unchanged without allocating when all handles are
  /// healthy.
  @visibleForTesting
  static List<ShaderPassInvocation> filterHealthyShaderPasses(
    List<ShaderPassInvocation> passes, {
    bool Function(CompiledShaderHandle handle) isFailed = _isFailedHandle,
  }) {
    if (passes.isEmpty || !passes.any((p) => isFailed(p.handle))) {
      return passes;
    }
    return <ShaderPassInvocation>[
      for (final pass in passes)
        if (!isFailed(pass.handle)) pass,
    ];
  }

  static bool _isFailedHandle(CompiledShaderHandle handle) =>
      handle is _GpuCompiledShaderHandle && handle.isPipelineFailed;

  static List<ShaderPassInvocation> _filterHealthyPasses(
    List<ShaderPassInvocation> passes,
  ) => filterHealthyShaderPasses(passes);

  ui.Image? _executeRingRender({
    required Object paneKey,
    required GpuPaneTextureRingPool<gpu.Texture> ringPool,
    required List<ShaderPassInvocation> passes,
    required int width,
    required int height,
    required gpu.Texture? inputTexture,
    required gpu.Texture? wallpaperTexture,
    Completer<bool>? completion,
    required Object? gatePaneKey,
    required int? gateToken,
    required GpuFrameWatchdog? watchdog,
  }) {
    var submissionStarted = false;
    final pendingSwaps = <GpuPingPongSlot<gpu.Texture>>[];
    try {
      _advanceBumpAllocatorsIfNewFrame();
      final ringTexture = ringPool.acquireNext(
        paneKey,
        width,
        height,
        _createRingTargetTexture,
      );
      final finalCommandBuffer = _encodeStandalonePassChain(
        paneKey: paneKey,
        passes: passes,
        width: width,
        height: height,
        inputTexture: inputTexture,
        wallpaperTexture: wallpaperTexture,
        finalSurfaceTexture: ringTexture,
        pendingSwaps: pendingSwaps,
        watchdog: watchdog,
      );
      submissionStarted = true;
      _submitFinalCommandBuffer(
        finalCommandBuffer,
        onSyncSubmitError: () => ringPool.remove(paneKey),
        completion: completion,
        gatePaneKey: gatePaneKey,
        gateToken: gateToken,
        watchdog: watchdog,
        activeCustomShaderIds: _collectDirectCustomShaderIds(
          watchdog,
          passes,
          const <ShaderPassInvocation>[],
          const <ShaderRegionPassInvocation>[],
        ),
      );
      for (final slot in pendingSwaps) {
        slot.commitWriteAndSwap();
      }
      return ringTexture.asImage();
    } finally {
      if (!submissionStarted && gatePaneKey != null && gateToken != null) {
        _inFlightGate.release(gatePaneKey, gateToken);
      }
    }
  }

  ui.Image? _executeSurfaceRender({
    required Object paneKey,
    required GpuPaneSurfacePool<gpu.GpuImageSurface> surfacePool,
    required List<ShaderPassInvocation> passes,
    required int width,
    required int height,
    required gpu.Texture? inputTexture,
    required gpu.Texture? wallpaperTexture,
    Completer<bool>? completion,
    required Object? gatePaneKey,
    required int? gateToken,
    required GpuFrameWatchdog? watchdog,
  }) {
    var submissionStarted = false;
    gpu.GpuImageSurfaceFrame? surfaceFrame;
    var presented = false;
    final pendingSwaps = <GpuPingPongSlot<gpu.Texture>>[];
    try {
      _advanceBumpAllocatorsIfNewFrame();
      final surface = surfacePool.obtain(
        paneKey,
        width,
        height,
        _createImageSurface,
      );
      final frame = surface.acquireNextFrame();
      surfaceFrame = frame;
      final finalCommandBuffer = _encodeStandalonePassChain(
        paneKey: paneKey,
        passes: passes,
        width: width,
        height: height,
        inputTexture: inputTexture,
        wallpaperTexture: wallpaperTexture,
        finalSurfaceTexture: frame.colorTexture,
        pendingSwaps: pendingSwaps,
        watchdog: watchdog,
      );
      frame.present(finalCommandBuffer);
      presented = true;
      submissionStarted = true;
      _submitFinalCommandBuffer(
        finalCommandBuffer,
        onSyncSubmitError: () => surfacePool.remove(paneKey),
        completion: completion,
        gatePaneKey: gatePaneKey,
        gateToken: gateToken,
        watchdog: watchdog,
        activeCustomShaderIds: _collectDirectCustomShaderIds(
          watchdog,
          passes,
          const <ShaderPassInvocation>[],
          const <ShaderRegionPassInvocation>[],
        ),
      );
      for (final slot in pendingSwaps) {
        slot.commitWriteAndSwap();
      }
      return surface.currentImage;
    } finally {
      if (surfaceFrame != null && !presented) {
        surfaceFrame.discard();
      }
      if (!submissionStarted && gatePaneKey != null && gateToken != null) {
        _inFlightGate.release(gatePaneKey, gateToken);
      }
    }
  }

  gpu.CommandBuffer _encodeStandalonePassChain({
    required Object paneKey,
    required List<ShaderPassInvocation> passes,
    required int width,
    required int height,
    required gpu.Texture? inputTexture,
    required gpu.Texture? wallpaperTexture,
    required gpu.Texture finalSurfaceTexture,
    required List<GpuPingPongSlot<gpu.Texture>> pendingSwaps,
    required GpuFrameWatchdog? watchdog,
  }) {
    final batch = _packUniformBatchReusingScratch(<TerminalShaderUniforms>[
      for (final pass in passes) pass.uniforms,
    ]);
    final uboView = _stageUniformSlice(batch.data);
    final vertexView = _ensureVertexBufferView();
    final fallback = _ensureFallbackTexture();
    return _encodePassChain(
      paneKey: paneKey,
      passes: passes,
      width: width,
      height: height,
      uboBuffer: uboView.buffer,
      uboBaseOffset: uboView.offsetInBytes,
      uboStride: batch.alignedStride,
      vertexView: vertexView,
      fallback: fallback,
      inputTexture: inputTexture,
      wallpaperTexture: wallpaperTexture,
      finalSurfaceTexture: finalSurfaceTexture,
      pendingSwaps: pendingSwaps,
      watchdog: watchdog,
    );
  }

  gpu.CommandBuffer _encodePassChain({
    required Object paneKey,
    required List<ShaderPassInvocation> passes,
    required int width,
    required int height,
    required gpu.DeviceBuffer uboBuffer,
    required int uboBaseOffset,
    required int uboStride,
    required gpu.BufferView vertexView,
    required gpu.Texture fallback,
    required gpu.Texture? inputTexture,
    required gpu.Texture? wallpaperTexture,
    required gpu.Texture finalSurfaceTexture,
    required List<GpuPingPongSlot<gpu.Texture>> pendingSwaps,
    required GpuFrameWatchdog? watchdog,
  }) {
    var currentInput = inputTexture ?? fallback;
    final channel1 = wallpaperTexture ?? fallback;
    final customIds = _collectDirectCustomShaderIds(
      watchdog,
      passes,
      const <ShaderPassInvocation>[],
      const <ShaderRegionPassInvocation>[],
    );

    return executeSingleEncoderGpuPassChain<gpu.CommandBuffer, gpu.Texture>(
      passCount: passes.length,
      finalSurfaceTexture: finalSurfaceTexture,
      createCommandBuffer: _context.createCommandBuffer,
      encodeRenderPass: (i, commandBuffer) {
        final invocation = passes[i];
        final handle = _requireOwnedHandle(invocation.handle);
        final pingPong = handle.usesPrevFrame
            ? _pingPongRegistry.acquire(
                resolvePrevFrameKey(invocation),
                width,
                height,
                _createRenderTargetTexture,
                ownerTag: handle.id,
              )
            : null;
        final target = _selectPassTarget(
          paneKey: paneKey,
          passIndex: i,
          isFinal: i == passes.length - 1,
          width: width,
          height: height,
          pingPong: pingPong,
          finalSurfaceTexture: finalSurfaceTexture,
        );
        _recordSinglePass(
          commandBuffer: commandBuffer,
          handle: handle,
          targetTexture: target,
          width: width,
          height: height,
          vertexView: vertexView,
          uboBuffer: uboBuffer,
          uboOffset: uboBaseOffset + i * uboStride,
          uboMaxLength: uboStride,
          channel0: currentInput,
          channel1: channel1,
          prevFrame: pingPong?.readTexture ?? fallback,
        );
        if (pingPong != null) {
          pendingSwaps.add(pingPong);
        }
        currentInput = target;
        return target;
      },
      submitIntermediate: (commandBuffer) => _submitIntermediateCommandBuffer(
        commandBuffer,
        watchdog: watchdog,
        activeCustomShaderIds: customIds,
      ),
      encodeCopyToSurface: (commandBuffer, source, destination) {
        commandBuffer.copyTextureToTexture(
          gpu.TextureRegion(source),
          gpu.TextureDestinationRegion(destination),
        );
      },
    );
  }

  gpu.Texture _selectPassTarget({
    required Object paneKey,
    required int passIndex,
    required bool isFinal,
    required int width,
    required int height,
    required GpuPingPongSlot<gpu.Texture>? pingPong,
    required gpu.Texture finalSurfaceTexture,
  }) {
    if (pingPong != null) {
      return pingPong.writeTexture;
    }
    if (isFinal) {
      return finalSurfaceTexture;
    }
    return _scratchPool.obtain((
      width,
      height,
      passIndex.isEven ? 0 : 1,
    ), () => _createRenderTargetTexture(width, height));
  }

  void _recordSinglePass({
    required gpu.CommandBuffer commandBuffer,
    required _GpuCompiledShaderHandle handle,
    required gpu.Texture targetTexture,
    required int width,
    required int height,
    required gpu.BufferView vertexView,
    required gpu.DeviceBuffer uboBuffer,
    required int uboOffset,
    required int uboMaxLength,
    required gpu.Texture channel0,
    required gpu.Texture channel1,
    required gpu.Texture prevFrame,
  }) {
    final attachment = gpu.ColorAttachment(
      texture: targetTexture,
      loadAction: gpu.LoadAction.clear,
      storeAction: gpu.StoreAction.store,
    );
    final renderPass = commandBuffer.createRenderPass(
      gpu.RenderTarget.singleColor(attachment),
    );
    renderPass.bindPipeline(handle.pipeline);
    renderPass.setColorBlendEnable(false);
    renderPass.setCullMode(gpu.CullMode.none);
    renderPass.setPrimitiveType(gpu.PrimitiveType.triangle);
    renderPass.setViewport(gpu.Viewport(width: width, height: height));
    renderPass.bindVertexBuffer(vertexView, slot: 0);

    _bindUniformBlockIfPresent(
      renderPass: renderPass,
      handle: handle,
      uboBuffer: uboBuffer,
      uboOffset: uboOffset,
      uboMaxLength: uboMaxLength,
    );
    _bindSamplerIfPresent(renderPass, handle, 'iChannel0', channel0);
    _bindSamplerIfPresent(renderPass, handle, 'iChannel1', channel1);
    _bindSamplerIfPresent(renderPass, handle, 'iPrevFrame', prevFrame);
    try {
      renderPass.draw(3);
    } on Object catch (error) {
      final message =
          'GPU pipeline failed to link or draw shader "${handle.id}": $error';
      handle.markPipelineFailed(message);
      throw ShaderCompileException(shaderId: handle.id, message: message);
    }
  }

  void _bindUniformBlockIfPresent({
    required gpu.RenderPass renderPass,
    required _GpuCompiledShaderHandle handle,
    required gpu.DeviceBuffer uboBuffer,
    required int uboOffset,
    required int uboMaxLength,
  }) {
    final slot = handle.uboSlot;
    final bindLength = handle.reflectionCache.resolveUniformBindLength(
      slot.sizeInBytes,
      maxLengthInBytes: uboMaxLength,
    );
    if (bindLength == null) return;
    renderPass.bindUniform(
      slot,
      gpu.BufferView(
        uboBuffer,
        offsetInBytes: uboOffset,
        lengthInBytes: bindLength,
      ),
    );
  }

  void _bindSamplerIfPresent(
    gpu.RenderPass renderPass,
    _GpuCompiledShaderHandle handle,
    String samplerName,
    gpu.Texture texture,
  ) {
    handle.reflectionCache.tryBindSampler(samplerName, () {
      renderPass.bindTexture(
        handle.samplerSlot(samplerName),
        texture,
        sampler: _linearClampSampler,
      );
    });
  }

  gpu.BufferView _stageUniformSlice(ByteData data) {
    final requiredBytes = data.lengthInBytes;
    final slice = _uniformBumpAllocator.allocate(
      byteLength: requiredBytes,
      alignment: _context.minimumUniformByteAlignment,
      createBlock: (cap) =>
          _context.createDeviceBuffer(gpu.StorageMode.hostVisible, cap),
    );
    slice.buffer.overwrite(data, destinationOffsetInBytes: slice.offsetInBytes);
    slice.buffer.flush(
      offsetInBytes: slice.offsetInBytes,
      lengthInBytes: requiredBytes,
    );
    return gpu.BufferView(
      slice.buffer,
      offsetInBytes: slice.offsetInBytes,
      lengthInBytes: requiredBytes,
    );
  }

  void _submitIntermediateCommandBuffer(
    gpu.CommandBuffer commandBuffer, {
    required GpuFrameWatchdog? watchdog,
    required List<String> activeCustomShaderIds,
  }) {
    final token = watchdog != null && activeCustomShaderIds.isNotEmpty
        ? watchdog.beginCommandSubmission(activeCustomShaderIds)
        : 0;
    if (token == 0) {
      commandBuffer.submit();
      return;
    }
    final submitStartUs = _gpuTimerClock.elapsedMicroseconds;
    try {
      commandBuffer.submit(
        completionCallback: (success) => _finishCommandSubmission(
          wd: watchdog,
          watchdogToken: token,
          submitStartUs: submitStartUs,
          completion: null,
          gatePaneKey: null,
          gateToken: null,
          recordDiagnostics: false,
          success: success,
        ),
      );
    } on Object {
      _finishCommandSubmission(
        wd: watchdog,
        watchdogToken: token,
        submitStartUs: submitStartUs,
        completion: null,
        gatePaneKey: null,
        gateToken: null,
        recordDiagnostics: false,
        success: false,
      );
      rethrow;
    }
  }

  void _submitFinalCommandBuffer(
    gpu.CommandBuffer commandBuffer, {
    required void Function() onSyncSubmitError,
    Completer<bool>? completion,
    required Object? gatePaneKey,
    required int? gateToken,
    required GpuFrameWatchdog? watchdog,
    List<String> activeCustomShaderIds = const <String>[],
  }) {
    final wd = watchdog;
    final watchdogToken = wd != null && activeCustomShaderIds.isNotEmpty
        ? wd.beginCommandSubmission(activeCustomShaderIds)
        : 0;
    final submitStartUs = _gpuTimerClock.elapsedMicroseconds;
    try {
      commandBuffer.submit(
        completionCallback: (success) => _finishCommandSubmission(
          wd: wd,
          watchdogToken: watchdogToken,
          submitStartUs: submitStartUs,
          completion: completion,
          gatePaneKey: gatePaneKey,
          gateToken: gateToken,
          recordDiagnostics: true,
          success: success,
        ),
      );
    } on Object {
      // Evict surface/ring so an unsubmitted present never poisons subsequent
      // frames.
      onSyncSubmitError();
      _finishCommandSubmission(
        wd: wd,
        watchdogToken: watchdogToken,
        submitStartUs: submitStartUs,
        completion: completion,
        gatePaneKey: gatePaneKey,
        gateToken: gateToken,
        recordDiagnostics: false,
        success: false,
      );
      rethrow;
    }
  }

  void _finishCommandSubmission({
    required GpuFrameWatchdog? wd,
    required int watchdogToken,
    required int submitStartUs,
    required Completer<bool>? completion,
    required Object? gatePaneKey,
    required int? gateToken,
    required bool recordDiagnostics,
    required bool success,
  }) {
    final rawElapsedUs = _gpuTimerClock.elapsedMicroseconds - submitStartUs;
    final elapsedUs = rawElapsedUs < 0 ? 0 : rawElapsedUs;
    if (recordDiagnostics) {
      _lastGpuCompletionUs = elapsedUs;
      if (ShaderPerfTrace.isEnabled) {
        ShaderPerfTrace.recordDurationUs(
          'FlutterGpu.gpuCompletionUs',
          elapsedUs,
        );
      }
    }
    if (gatePaneKey != null && gateToken != null) {
      _inFlightGate.recordCompletion(gatePaneKey, gateToken, elapsedUs);
    }
    if (watchdogToken != 0) {
      wd?.completeCommandSubmission(
        watchdogToken,
        success: success,
        gpuDuration: success ? Duration(microseconds: elapsedUs) : null,
      );
    }
    if (completion != null && !completion.isCompleted) {
      completion.complete(success);
    }
  }

  gpu.BufferView _ensureVertexBufferView() {
    final buffer = _fullscreenVertexBuffer ??= _context
        .createDeviceBufferWithCopy(
          _fullscreenTriangleVertices.buffer.asByteData(),
        );
    return gpu.BufferView(
      buffer,
      offsetInBytes: 0,
      lengthInBytes: buffer.sizeInBytes,
    );
  }

  gpu.Texture _ensureFallbackTexture() {
    final existing = _fallbackTexture;
    if (existing != null) return existing;
    final created = _context.createTexture(
      gpu.StorageMode.hostVisible,
      1,
      1,
      format: gpu.PixelFormat.r8g8b8a8UNormInt,
      enableRenderTargetUsage: false,
      enableShaderReadUsage: true,
    );
    created.overwrite(ByteData(4));
    _fallbackTexture = created;
    return created;
  }

  gpu.GpuImageSurface _createImageSurface(int width, int height) =>
      _context.createImageSurface(width, height, format: _renderColorFormat);

  gpu.Texture _createRingTargetTexture(int width, int height) =>
      _createRenderTargetTexture(width, height);

  gpu.Texture _createRenderTargetTexture(int width, int height) =>
      _context.createTexture(
        gpu.StorageMode.devicePrivate,
        width,
        height,
        format: _renderColorFormat,
        enableRenderTargetUsage: true,
        enableShaderReadUsage: true,
      );

  static gpu.Texture? _touchLruTexture(
    LinkedHashMap<ui.Image, gpu.Texture> cache,
    ui.Image image,
  ) {
    final existing = cache.remove(image);
    if (existing != null) {
      cache[image] = existing;
    }
    return existing;
  }

  static void _storeLruTexture(
    LinkedHashMap<ui.Image, gpu.Texture> cache,
    ui.Image image,
    gpu.Texture texture, {
    required int maxEntries,
  }) {
    cache.remove(image);
    while (cache.length >= maxEntries && cache.isNotEmpty) {
      cache.remove(cache.keys.first);
    }
    cache[image] = texture;
  }

  void _storeUploadedAtlasTexture(ui.Image image, gpu.Texture texture) =>
      _storeLruTexture(
        _uploadedAtlasTextures,
        image,
        texture,
        maxEntries: _maxUploadedAtlasTextures,
      );

  void _storeUploadedWallpaperTexture(ui.Image image, gpu.Texture texture) =>
      _storeLruTexture(
        _uploadedWallpaperTextures,
        image,
        texture,
        maxEntries: _maxUploadedWallpaperTextures,
      );

  void _storeUploadedInputTexture(ui.Image image, gpu.Texture texture) =>
      _storeLruTexture(
        _uploadedInputTextures,
        image,
        texture,
        maxEntries: _maxUploadedInputTextures,
      );

  void _storeUploadedKittyTexture(ui.Image image, gpu.Texture texture) =>
      _storeLruTexture(
        _uploadedKittyTextures,
        image,
        texture,
        maxEntries: _uploadedKittyCapacity,
      );

  Future<bool> _primeDirectPixelUploads({
    required ui.Image atlasImage,
    required ui.Image? wallpaperImage,
    required Iterable<ui.Image> kittyImages,
  }) async {
    final distinctKitty = LinkedHashSet<ui.Image>.identity()
      ..addAll(kittyImages);
    if (distinctKitty.length > _uploadedKittyCapacity) {
      _uploadedKittyCapacity = distinctKitty.length;
    }
    final pending = <Future<bool>>[
      if (!_uploadedAtlasTextures.containsKey(atlasImage))
        _primeUploadedImage(atlasImage, _storeUploadedAtlasTexture),
      if (wallpaperImage != null &&
          !_uploadedWallpaperTextures.containsKey(wallpaperImage))
        _primeUploadedImage(wallpaperImage, _storeUploadedWallpaperTexture),
      for (final kittyImage in distinctKitty)
        if (!_uploadedKittyTextures.containsKey(kittyImage))
          _primeUploadedImage(kittyImage, _storeUploadedKittyTexture),
    ];
    if (pending.isNotEmpty) {
      await Future.wait<bool>(pending);
    }
    if (_disposed) return false;
    return _uploadedAtlasTextures.containsKey(atlasImage) &&
        (wallpaperImage == null ||
            _uploadedWallpaperTextures.containsKey(wallpaperImage)) &&
        distinctKitty.every(_uploadedKittyTextures.containsKey);
  }

  Future<void> _primeAsyncPassImages({
    required ui.Image? inputImage,
    required ui.Image? wallpaperImage,
  }) async {
    final pending = <Future<bool>>[
      if (inputImage != null && !_uploadedInputTextures.containsKey(inputImage))
        _primeUploadedImage(inputImage, _storeUploadedInputTexture),
      if (wallpaperImage != null &&
          !_uploadedWallpaperTextures.containsKey(wallpaperImage))
        _primeUploadedImage(wallpaperImage, _storeUploadedWallpaperTexture),
    ];
    if (pending.isNotEmpty) {
      await Future.wait<bool>(pending);
    }
  }

  Future<bool> _primeUploadedImage(
    ui.Image image,
    void Function(ui.Image image, gpu.Texture texture) store,
  ) {
    final existing = _pixelUploadsInFlight[image];
    if (existing != null) return existing;
    late final Future<bool> future;
    future = _uploadImagePixelsOnce(image, store).whenComplete(() {
      if (identical(_pixelUploadsInFlight[image], future)) {
        _pixelUploadsInFlight.remove(image);
      }
    });
    _pixelUploadsInFlight[image] = future;
    return future;
  }

  Future<bool> _uploadImagePixelsOnce(
    ui.Image image,
    void Function(ui.Image image, gpu.Texture texture) store,
  ) async {
    ui.Image? cloned;
    try {
      cloned = image.clone();
      final bytes = await cloned.toByteData(format: ui.ImageByteFormat.rawRgba);
      if (_disposed || bytes == null) return false;
      final width = cloned.width;
      final height = cloned.height;
      if (width <= 0 || height <= 0) return false;
      final tex = _context.createTexture(
        gpu.StorageMode.hostVisible,
        width,
        height,
        format: gpu.PixelFormat.r8g8b8a8UNormInt,
        enableRenderTargetUsage: false,
        enableShaderReadUsage: true,
      );
      tex.overwrite(bytes);
      store(image, tex);
      return true;
    } on Object {
      return false;
    } finally {
      cloned?.dispose();
    }
  }

  gpu.Texture? _resolveInputImageTexture(ui.Image? image) {
    if (image == null) return null;
    if (_usePixelUploadForImages) {
      return _touchLruTexture(_uploadedInputTextures, image);
    }
    return _tryWrapImage(image);
  }

  gpu.Texture? _wrapCachedAtlasImage(ui.Image image) {
    final cached = _touchLruTexture(_uploadedAtlasTextures, image);
    if (cached != null) return cached;
    if (_usePixelUploadForImages) return null;
    final tex = _tryWrapImage(image);
    if (tex != null) {
      _storeUploadedAtlasTexture(image, tex);
    }
    return tex;
  }

  gpu.Texture? _wrapCachedWallpaperImage(ui.Image? image) {
    if (image == null) return null;
    final cached = _touchLruTexture(_uploadedWallpaperTextures, image);
    if (cached != null) return cached;
    if (_usePixelUploadForImages) return null;
    final tex = _tryWrapImage(image);
    if (tex != null) {
      _storeUploadedWallpaperTexture(image, tex);
    }
    return tex;
  }

  gpu.Texture? _tryWrapImage(ui.Image? image) {
    if (image == null || _usePixelUploadForImages) return null;
    try {
      return gpu.Texture.fromImage(_context, image);
    } on Object {
      return null;
    }
  }

  Future<gpu.ShaderLibrary> _loadShaderLibrary(
    String shaderId,
    ByteData bytes,
  ) async {
    try {
      final library = await gpu.ShaderLibrary.fromBytes(bytes);
      if (library == null) {
        throw ShaderCompileException(
          shaderId: shaderId,
          message: 'ShaderLibrary.fromBytes returned null.',
        );
      }
      return library;
    } on ShaderCompileException {
      rethrow;
    } on Object catch (error) {
      throw ShaderCompileException(
        shaderId: shaderId,
        message: 'Failed to load Impeller shader library: $error',
      );
    }
  }

  gpu.RenderPipeline _createPipeline(
    String shaderId,
    gpu.Shader vertexShader,
    gpu.Shader fragmentShader,
  ) {
    try {
      return _context.createRenderPipeline(vertexShader, fragmentShader);
    } on Object catch (error) {
      throw ShaderCompileException(
        shaderId: shaderId,
        message: 'Failed to create Impeller render pipeline: $error',
      );
    }
  }

  _GpuCompiledShaderHandle _requireOwnedHandle(CompiledShaderHandle handle) {
    if (handle is! _GpuCompiledShaderHandle ||
        handle.isDisposed ||
        !_handles.contains(handle)) {
      throw StateError(
        'Shader handle "${handle.id}" is disposed or does not belong to this '
        'FlutterGpuShaderBackend.',
      );
    }
    return handle;
  }

  void _handleDisposed(_GpuCompiledShaderHandle handle) {
    _handles.remove(handle);
    _pingPongRegistry.removeByOwnerTag(handle.id);
    _pingPongRegistry.remove(handle.id);
  }

  void _ensureNotDisposed() {
    if (_disposed) {
      throw StateError('FlutterGpuShaderBackend has been disposed.');
    }
  }
}

final class _CachedStaticSceneLayers {
  final gpu.Texture bgTexture;
  final gpu.Texture? fgTexture;
  final bool splitLayers;
  final int width;
  final int height;
  final int generation;
  final Float32List instanceData;
  final int instanceCount;
  final int bgEnd;
  final int italicStart;
  final int kittySplit;
  final gpu.Texture atlasTexture;
  final ui.Image? wallpaperImage;
  final gpu.Texture? wallpaperTexture;
  final List<GpuKittyQuad> kittyQuads;
  final List<gpu.Texture> kittyTextures;

  const _CachedStaticSceneLayers({
    required this.bgTexture,
    required this.fgTexture,
    required this.splitLayers,
    required this.width,
    required this.height,
    required this.generation,
    required this.instanceData,
    required this.instanceCount,
    required this.bgEnd,
    required this.italicStart,
    required this.kittySplit,
    required this.atlasTexture,
    required this.wallpaperImage,
    required this.wallpaperTexture,
    required this.kittyQuads,
    required this.kittyTextures,
  });

  bool matches({
    required int width,
    required int height,
    required GpuAtlasQuadBatch batch,
    required gpu.Texture atlasTexture,
    required ui.Image? wallpaperImage,
    required gpu.Texture? wallpaperTexture,
    required List<gpu.Texture> kittyTextures,
    required bool splitLayers,
  }) {
    if (this.splitLayers != splitLayers ||
        this.width != width ||
        this.height != height ||
        generation != batch.generation ||
        !identical(instanceData, batch.instanceData) ||
        instanceCount != batch.instanceCount ||
        bgEnd !=
            batch.bgEndInstanceIndex.clamp(0, batch.italicStartInstanceIndex) ||
        italicStart != batch.italicStartInstanceIndex ||
        kittySplit != batch.kittyInsertInstanceIndex ||
        !identical(this.atlasTexture, atlasTexture) ||
        !identical(this.wallpaperImage, wallpaperImage) ||
        !identical(this.wallpaperTexture, wallpaperTexture) ||
        this.kittyTextures.length != kittyTextures.length) {
      return false;
    }
    if (kittyTextures.isNotEmpty && !identical(kittyQuads, batch.kittyQuads)) {
      return false;
    }
    for (var i = 0; i < kittyTextures.length; i++) {
      if (!identical(this.kittyTextures[i], kittyTextures[i])) return false;
    }
    return true;
  }
}

final class _RenderedGpuRegion {
  final ShaderRegionPassInvocation pass;
  final gpu.Texture texture;

  const _RenderedGpuRegion({required this.pass, required this.texture});
}

final class _GpuInstanceSlotCache {
  final List<gpu.DeviceBuffer?> ring;
  int ringIndex = 0;
  gpu.DeviceBuffer? lastBuffer;
  Float32List? lastData;
  int lastGeneration = -1;
  int lastCount = -1;

  _GpuInstanceSlotCache(int ringLength)
    : ring = List<gpu.DeviceBuffer?>.filled(ringLength, null);
}

final class _PaneGpuUploadCache {
  final _GpuInstanceSlotCache staticGrid;
  final _GpuInstanceSlotCache transformed;
  final _GpuInstanceSlotCache regionMask;

  _PaneGpuUploadCache(int ringLength)
    : staticGrid = _GpuInstanceSlotCache(ringLength),
      transformed = _GpuInstanceSlotCache(ringLength),
      regionMask = _GpuInstanceSlotCache(ringLength);
}

final class _CachedGpuRegionMask {
  final gpu.Texture texture;
  final Float32List maskData;
  final int generation;
  final int startInstance;
  final int instanceCount;
  final int width;
  final int height;
  final gpu.Texture atlasTexture;

  const _CachedGpuRegionMask({
    required this.texture,
    required this.maskData,
    required this.generation,
    required this.startInstance,
    required this.instanceCount,
    required this.width,
    required this.height,
    required this.atlasTexture,
  });

  bool matches({
    required Float32List maskData,
    required int generation,
    required int startInstance,
    required int instanceCount,
    required int width,
    required int height,
    required gpu.Texture atlasTexture,
  }) =>
      identical(this.maskData, maskData) &&
      this.generation == generation &&
      this.startInstance == startInstance &&
      this.instanceCount == instanceCount &&
      this.width == width &&
      this.height == height &&
      identical(this.atlasTexture, atlasTexture);
}
