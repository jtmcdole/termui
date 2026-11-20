import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_gpu/gpu.dart' as gpu;

import 'impellerc_compiler_stub.dart'
    if (dart.library.io) 'impellerc_compiler_io.dart';
import 'shader_backend.dart';
import 'shader_spec.dart';
import 'shadertoy_glsl_shim.dart';

/// Rounds [byteSize] up to the nearest multiple of [alignment] (clamping
/// non-positive alignments to `1`).
int alignUniformByteSize(int byteSize, int alignment) {
  if (byteSize <= 0) return 0;
  final step = alignment <= 1 ? 1 : alignment;
  final remainder = byteSize % step;
  return remainder == 0 ? byteSize : byteSize + (step - remainder);
}

/// Packs [uniformsList] into one contiguous [ByteData] where every pass begins
/// at a byte offset aligned to [minimumUniformByteAlignment].
({ByteData data, int alignedStride}) packAlignedUniformBatch(
  List<TerminalShaderUniforms> uniformsList, {
  required int minimumUniformByteAlignment,
}) {
  final stride = alignUniformByteSize(
    ShadertoyGlslShim.uniformBufferByteLength,
    minimumUniformByteAlignment,
  );
  final data = ByteData(uniformsList.length * stride);
  for (var i = 0; i < uniformsList.length; i++) {
    ShadertoyGlslShim.packUniformsStd140(
      uniformsList[i],
      data,
      byteOffset: i * stride,
    );
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

/// Immutable integer pixel dimensions key for GPU surface and scratch pools.
final class GpuTextureSizeKey {
  /// Texture width in physical pixels.
  final int width;

  /// Texture height in physical pixels.
  final int height;

  /// Creates a texture dimension key.
  const GpuTextureSizeKey(this.width, this.height);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is GpuTextureSizeKey &&
          other.width == width &&
          other.height == height;

  @override
  int get hashCode => Object.hash(width, height);
}

/// Bounded LRU pool keyed by [GpuTextureSizeKey] used for `GpuImageSurface`
/// instances and multi-pass scratch texture pairs.
final class GpuSizePool<T extends Object> {
  /// Maximum number of distinct dimension entries retained simultaneously.
  final int maxEntries;

  final LinkedHashMap<GpuTextureSizeKey, T> _entries =
      LinkedHashMap<GpuTextureSizeKey, T>();

  /// Creates a bounded GPU resource pool.
  GpuSizePool({this.maxEntries = 4});

  /// Number of entries currently retained in this pool.
  int get length => _entries.length;

  /// Returns an existing resource for `(width, height)`, or invokes [create]
  /// and inserts it while evicting the least-recently-used entry if full.
  T obtain(int width, int height, T Function(int width, int height) create) {
    final key = GpuTextureSizeKey(width, height);
    final existing = _entries.remove(key);
    if (existing != null) {
      _entries[key] = existing;
      return existing;
    }
    if (_entries.length >= maxEntries && _entries.isNotEmpty) {
      _entries.remove(_entries.keys.first);
    }
    final created = create(width, height);
    _entries[key] = created;
    return created;
  }

  /// Removes the entry for `(width, height)` if present.
  void remove(int width, int height) {
    _entries.remove(GpuTextureSizeKey(width, height));
  }

  /// Clears all retained resources.
  void clear() {
    _entries.clear();
  }
}

/// Active ping-pong texture pair for a single `prevFrameKey`.
final class GpuPingPongSlot<T extends Object> {
  /// Pixel width of both backing textures.
  final int width;

  /// Pixel height of both backing textures.
  final int height;

  /// First backing texture in the alternating pair.
  final T first;

  /// Second backing texture in the alternating pair.
  final T second;

  int _readIndex = 0;
  bool _hasHistory = false;

  /// Creates a ping-pong pair wrapping two identically sized textures.
  GpuPingPongSlot({
    required this.width,
    required this.height,
    required this.first,
    required this.second,
  });

  /// Whether at least one frame has been rendered into this ping-pong pair.
  bool get hasHistory => _hasHistory;

  /// Previously rendered texture for `iPrevFrame`, or `null` before the first
  /// frame has been written (avoiding reads from uninitialized VRAM).
  T? get readTexture {
    if (!_hasHistory) return null;
    return _readIndex == 0 ? first : second;
  }

  /// Destination texture for the current frame's write.
  T get writeTexture => _readIndex == 0 ? second : first;

  /// Marks [writeTexture] as valid and swaps it into [readTexture] for the
  /// next frame.
  void commitWriteAndSwap() {
    _hasHistory = true;
    _readIndex = 1 - _readIndex;
  }
}

/// Bounded registry managing per-`prevFrameKey` ping-pong texture pairs across
/// resizes and dynamic region lifetimes.
final class GpuPingPongRegistry<T extends Object> {
  /// Maximum number of persistent `prevFrameKey` pairs kept alive.
  final int maxEntries;

  final LinkedHashMap<String, GpuPingPongSlot<T>> _slots =
      LinkedHashMap<String, GpuPingPongSlot<T>>();

  /// Creates a ping-pong texture registry.
  GpuPingPongRegistry({this.maxEntries = 16});

  /// Number of active ping-pong pairs.
  int get length => _slots.length;

  /// Acquires the ping-pong pair for [key] at `(width, height)`, reallocating
  /// via [allocateTexture] if absent or if the dimensions changed.
  GpuPingPongSlot<T> acquire(
    String key,
    int width,
    int height,
    T Function(int width, int height) allocateTexture,
  ) {
    final existing = _slots.remove(key);
    if (existing != null &&
        existing.width == width &&
        existing.height == height) {
      _slots[key] = existing;
      return existing;
    }
    if (_slots.length >= maxEntries && _slots.isNotEmpty) {
      _slots.remove(_slots.keys.first);
    }
    final created = GpuPingPongSlot<T>(
      width: width,
      height: height,
      first: allocateTexture(width, height),
      second: allocateTexture(width, height),
    );
    _slots[key] = created;
    return created;
  }

  /// Removes a specific `prevFrameKey` entry if present.
  void remove(String key) {
    _slots.remove(key);
  }

  /// Clears all ping-pong texture pairs.
  void clear() {
    _slots.clear();
  }
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
    reflectionCache.invalidate();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    reflectionCache.invalidate();
    onDispose(this);
  }
}

/// Desktop Impeller shader backend built on `package:flutter_gpu` and
/// out-of-process `impellerc` `.shaderbundle` compilation.
final class FlutterGpuShaderBackend implements TerminalShaderBackend {
  static final Float32List _fullscreenTriangleVertices = Float32List.fromList(
    <double>[-1.0, -1.0, 3.0, -1.0, -1.0, 3.0],
  );

  static final gpu.SamplerOptions _linearClampSampler = gpu.SamplerOptions(
    minFilter: gpu.MinMagFilter.linear,
    magFilter: gpu.MinMagFilter.linear,
    mipFilter: gpu.MipFilter.nearest,
    widthAddressMode: gpu.SamplerAddressMode.clampToEdge,
    heightAddressMode: gpu.SamplerAddressMode.clampToEdge,
  );

  static const int _uboRingLength = 3;

  final ImpellercCompiler _compiler;
  final gpu.GpuContext _context;

  final Set<_GpuCompiledShaderHandle> _handles = <_GpuCompiledShaderHandle>{};
  final GpuSizePool<gpu.GpuImageSurface> _backgroundSurfacePool =
      GpuSizePool<gpu.GpuImageSurface>(maxEntries: 4);
  final GpuSizePool<gpu.GpuImageSurface> _foregroundSurfacePool =
      GpuSizePool<gpu.GpuImageSurface>(maxEntries: 4);
  final GpuSizePool<(gpu.Texture, gpu.Texture)> _scratchPool =
      GpuSizePool<(gpu.Texture, gpu.Texture)>(maxEntries: 4);
  final GpuPingPongRegistry<gpu.Texture> _pingPongRegistry =
      GpuPingPongRegistry<gpu.Texture>(maxEntries: 16);
  final List<gpu.DeviceBuffer?> _uboRing = List<gpu.DeviceBuffer?>.filled(
    _uboRingLength,
    null,
  );
  int _uboRingIndex = 0;

  gpu.DeviceBuffer? _fullscreenVertexBuffer;
  gpu.Texture? _fallbackTexture;
  bool _disposed = false;

  /// Creates a Desktop `flutter_gpu` shader backend.
  FlutterGpuShaderBackend({
    ImpellercCompiler? compiler,
    gpu.GpuContext? context,
  }) : _compiler = compiler ?? ImpellercCompiler(),
       _context = context ?? gpu.gpuContext;

  /// Probes `gpu.gpuContext` and returns a [FlutterGpuShaderBackend], or
  /// `null` without throwing if Impeller/`flutter_gpu` is unavailable (such as
  /// under Skia Desktop or `flutter test` software rendering).
  static FlutterGpuShaderBackend? tryCreate({ImpellercCompiler? compiler}) {
    try {
      final context = gpu.gpuContext;
      if (context.minimumUniformByteAlignment <= 0) {
        return null;
      }
      return FlutterGpuShaderBackend(compiler: compiler, context: context);
    } on Object {
      return null;
    }
  }

  @override
  ShaderBackendKind get kind => ShaderBackendKind.flutterGpu;

  @override
  bool get supportsCustomGlsl => _compiler.isAvailable;

  @override
  bool get supportsSyncBackground => true;

  @override
  Future<CompiledShaderHandle> compile(
    String id,
    String shadertoyGlsl, {
    bool usesPrevFrame = false,
  }) async {
    _ensureNotDisposed();
    final compiled = await _compiler.compile(shadertoyGlsl, shaderId: id);
    final library = await _loadShaderLibrary(id, compiled.bytes);
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
  }) => _renderPasses(
    passes: passes,
    physicalSize: physicalSize,
    inputImage: null,
    wallpaperImage: wallpaperImage,
  );

  @override
  Future<ui.Image?> renderPassesAsync({
    required List<ShaderPassInvocation> passes,
    required ui.Size physicalSize,
    ui.Image? inputImage,
    ui.Image? wallpaperImage,
  }) async {
    final completion = Completer<bool>();
    final image = _renderPasses(
      passes: passes,
      physicalSize: physicalSize,
      inputImage: inputImage,
      wallpaperImage: wallpaperImage,
      completion: completion,
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
    _scratchPool.clear();
    _pingPongRegistry.clear();
    for (var i = 0; i < _uboRing.length; i++) {
      _uboRing[i] = null;
    }
    _fullscreenVertexBuffer = null;
    _fallbackTexture = null;
  }

  ui.Image? _renderPasses({
    required List<ShaderPassInvocation> passes,
    required ui.Size physicalSize,
    required ui.Image? inputImage,
    required ui.Image? wallpaperImage,
    Completer<bool>? completion,
  }) {
    if (_disposed || passes.isEmpty) return null;
    if (_hasQuarantinedPass(passes)) return null;
    final width = physicalSize.width.round();
    final height = physicalSize.height.round();
    if (width <= 0 || height <= 0) return null;

    final inputTexture = _tryWrapImage(inputImage);
    if (inputImage != null && inputTexture == null) {
      return null;
    }
    final wallpaperTexture = _tryWrapImage(wallpaperImage);
    final surfacePool = inputImage == null
        ? _backgroundSurfacePool
        : _foregroundSurfacePool;
    final surface = surfacePool.obtain(
      width,
      height,
      (w, h) => _context.createImageSurface(w, h),
    );
    return _executeSurfaceRender(
      surface: surface,
      surfacePool: surfacePool,
      passes: passes,
      width: width,
      height: height,
      inputTexture: inputTexture,
      wallpaperTexture: wallpaperTexture,
      completion: completion,
    );
  }

  bool _hasQuarantinedPass(List<ShaderPassInvocation> passes) {
    for (final pass in passes) {
      final handle = pass.handle;
      if (handle is _GpuCompiledShaderHandle && handle.isPipelineFailed) {
        return true;
      }
    }
    return false;
  }

  ui.Image? _executeSurfaceRender({
    required gpu.GpuImageSurface surface,
    required GpuSizePool<gpu.GpuImageSurface> surfacePool,
    required List<ShaderPassInvocation> passes,
    required int width,
    required int height,
    required gpu.Texture? inputTexture,
    required gpu.Texture? wallpaperTexture,
    Completer<bool>? completion,
  }) {
    final surfaceFrame = surface.acquireNextFrame();
    var presented = false;
    final pendingSwaps = <GpuPingPongSlot<gpu.Texture>>[];
    try {
      final batch = packAlignedUniformBatch(<TerminalShaderUniforms>[
        for (final pass in passes) pass.uniforms,
      ], minimumUniformByteAlignment: _context.minimumUniformByteAlignment);
      final uboBuffer = _stageUniformBuffer(batch.data);
      final vertexView = _ensureVertexBufferView();
      final fallback = _ensureFallbackTexture();

      final finalCommandBuffer = _encodePassChain(
        passes: passes,
        width: width,
        height: height,
        uboBuffer: uboBuffer,
        uboStride: batch.alignedStride,
        vertexView: vertexView,
        fallback: fallback,
        inputTexture: inputTexture,
        wallpaperTexture: wallpaperTexture,
        finalSurfaceTexture: surfaceFrame.colorTexture,
        pendingSwaps: pendingSwaps,
      );

      surfaceFrame.present(finalCommandBuffer);
      presented = true;
      _submitCommandBuffer(
        finalCommandBuffer,
        surfacePool,
        width,
        height,
        completion: completion,
      );
      for (final slot in pendingSwaps) {
        slot.commitWriteAndSwap();
      }
      return surface.currentImage;
    } finally {
      if (!presented) {
        surfaceFrame.discard();
      }
    }
  }

  gpu.CommandBuffer _encodePassChain({
    required List<ShaderPassInvocation> passes,
    required int width,
    required int height,
    required gpu.DeviceBuffer uboBuffer,
    required int uboStride,
    required gpu.BufferView vertexView,
    required gpu.Texture fallback,
    required gpu.Texture? inputTexture,
    required gpu.Texture? wallpaperTexture,
    required gpu.Texture finalSurfaceTexture,
    required List<GpuPingPongSlot<gpu.Texture>> pendingSwaps,
  }) {
    var currentInput = inputTexture ?? fallback;
    final channel1 = wallpaperTexture ?? fallback;

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
              )
            : null;
        final target = _selectPassTarget(
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
          uboOffset: i * uboStride,
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
      submitIntermediate: (commandBuffer) => commandBuffer.submit(),
      encodeCopyToSurface: (commandBuffer, source, destination) {
        commandBuffer.copyTextureToTexture(
          gpu.TextureRegion(source),
          gpu.TextureDestinationRegion(destination),
        );
      },
    );
  }

  gpu.Texture _selectPassTarget({
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
    final pair = _scratchPool.obtain(
      width,
      height,
      (w, h) =>
          (_createRenderTargetTexture(w, h), _createRenderTargetTexture(w, h)),
    );
    return passIndex.isEven ? pair.$1 : pair.$2;
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
    final slot = handle.fragmentShader.getUniformSlot(
      ShadertoyGlslShim.uniformBlockName,
    );
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
      final slot = handle.fragmentShader.getUniformSlot(samplerName);
      renderPass.bindTexture(slot, texture, sampler: _linearClampSampler);
    });
  }

  gpu.DeviceBuffer _stageUniformBuffer(ByteData data) {
    final slotIndex = _uboRingIndex;
    _uboRingIndex = (_uboRingIndex + 1) % _uboRingLength;
    final requiredBytes = data.lengthInBytes;
    var buffer = _uboRing[slotIndex];
    if (buffer == null || buffer.sizeInBytes < requiredBytes) {
      buffer = _context.createDeviceBuffer(
        gpu.StorageMode.hostVisible,
        requiredBytes,
      );
      _uboRing[slotIndex] = buffer;
    }
    buffer.overwrite(data);
    buffer.flush(offsetInBytes: 0, lengthInBytes: requiredBytes);
    return buffer;
  }

  void _submitCommandBuffer(
    gpu.CommandBuffer commandBuffer,
    GpuSizePool<gpu.GpuImageSurface> surfacePool,
    int width,
    int height, {
    Completer<bool>? completion,
  }) {
    try {
      if (completion == null) {
        commandBuffer.submit();
      } else {
        commandBuffer.submit(
          completionCallback: (success) {
            if (!completion.isCompleted) {
              completion.complete(success);
            }
          },
        );
      }
    } on Object {
      // Evict surface so an unsubmitted present never poisons subsequent frames.
      surfacePool.remove(width, height);
      if (completion != null && !completion.isCompleted) {
        completion.complete(false);
      }
      rethrow;
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

  gpu.Texture _createRenderTargetTexture(int width, int height) =>
      _context.createTexture(
        gpu.StorageMode.devicePrivate,
        width,
        height,
        format: _context.defaultColorFormat,
        enableRenderTargetUsage: true,
        enableShaderReadUsage: true,
      );

  gpu.Texture? _tryWrapImage(ui.Image? image) {
    if (image == null) return null;
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
    _pingPongRegistry.remove(handle.id);
  }

  void _ensureNotDisposed() {
    if (_disposed) {
      throw StateError('FlutterGpuShaderBackend has been disposed.');
    }
  }
}
