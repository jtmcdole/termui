import 'dart:async';
import 'dart:collection';
import 'dart:js_interop';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'dart:ui_web' as ui_web;

import 'package:termui/ui/shader_region.dart';
import 'package:web/web.dart' as web;

import 'gpu_atlas_batch.dart';
import 'gpu_atlas_shaders.dart';
import 'gpu_frame_watchdog.dart';
import 'perf_trace.dart';
import 'shader_backend.dart';
import 'shader_diagnostic_parser.dart';
import 'shader_resource_pools.dart';
import 'shader_spec.dart';
import 'shadertoy_glsl_shim.dart';

/// Flutter Web [TerminalShaderBackend] backed by a single reusable
/// `OffscreenCanvas` WebGL2 context (zero PlatformViews, compatible with both
/// CanvasKit and Skwasm).
///
/// Compiles Ghostty-shimmed GLSL ES 3.00 fragment shaders, binds the shared
/// `std140` [ShadertoyGlslShim.uniformBlockName] UBO, maintains per-key
/// ping-pong FBOs for `iPrevFrame`, handles `webglcontextlost` /
/// `webglcontextrestored` recovery, and exports frames via
/// `OffscreenCanvas.transferToImageBitmap` plus
/// `ui_web.createImageFromImageBitmap`.
final class WebGl2ShaderBackend
    implements
        DirectTerminalShaderBackend,
        WatchdogBindableShaderBackend,
        DiagnosableShaderBackend {
  static const int _uboBindingPoint = 0;
  static const int _maxParallelCompilePolls = 240;
  static const int _maxKittyTextureCacheEntries = 32;

  static final Float32List _fullscreenTriangleVertices = Float32List.fromList(
    <double>[-1.0, -1.0, 3.0, -1.0, -1.0, 3.0],
  );
  static final Uint8List _transparentPixel = Uint8List.fromList(<int>[
    0,
    0,
    0,
    0,
  ]);
  static final int _webgl2PrefixLineOffset = _computePrefixLineOffset();

  final web.OffscreenCanvas _canvas;
  final web.WebGL2RenderingContext _gl;
  final Uint8List _uniformBytes = Uint8List(
    ShadertoyGlslShim.uniformBufferByteLength,
  );
  late final ByteData _uniformByteData = ByteData.sublistView(_uniformBytes);

  late final JSExportedDartFunction _contextLostHandler;
  late final JSExportedDartFunction _contextRestoredHandler;

  final Set<_WebGl2ShaderHandle> _handles = <_WebGl2ShaderHandle>{};
  late final GpuPingPongRegistry<_GlFboTarget> _prevFrameTargets =
      GpuPingPongRegistry<_GlFboTarget>(
        maxEntries: 32,
        onEvict: _deleteFboTargetIfContextAlive,
      );
  late final WebGlRegionTargetPool<_GlFboTarget> _regionTargets =
      WebGlRegionTargetPool<_GlFboTarget>(
        maxEntries: 32,
        onDelete: _deleteFboTargetIfContextAlive,
      );

  web.WebGLShader? _vertexShader;
  web.WebGLVertexArrayObject? _vao;
  web.WebGLBuffer? _vertexBuffer;
  web.WebGLBuffer? _ubo;
  web.WebGLTexture? _dummyTexture;

  web.WebGLTexture? _inputTexture;
  int _inputWidth = 0;
  int _inputHeight = 0;
  ui.Image? _cachedInputImage;

  web.WebGLTexture? _wallpaperTexture;
  int _wallpaperWidth = 0;
  int _wallpaperHeight = 0;
  ui.Image? _cachedWallpaperImage;

  web.WebGLProgram? _atlasProgram;
  web.WebGLUniformLocation? _atlasViewportLoc;
  web.WebGLBuffer? _atlasUnitQuadBuffer;
  web.WebGLVertexArrayObject? _atlasVao;
  web.WebGLBuffer? _atlasInstanceBuffer;
  int _atlasInstanceCapBytes = 0;
  web.WebGLVertexArrayObject? _singleQuadVao;
  web.WebGLBuffer? _singleQuadInstanceBuffer;
  final Float32List _singleQuadScratch = Float32List(
    GpuAtlasQuadBatch.floatsPerInstance,
  );
  web.WebGLTexture? _atlasTexture;
  int _atlasWidth = 0;
  int _atlasHeight = 0;
  ui.Image? _cachedAtlasImage;
  int _atlasFilterMode = web.WebGL2RenderingContext.LINEAR;

  final LinkedHashMap<ui.Image, _GlCachedTexture> _kittyTextures =
      LinkedHashMap<ui.Image, _GlCachedTexture>.identity();
  final Map<ui.Image, Future<bool>> _primingInFlight =
      Map<ui.Image, Future<bool>>.identity();

  Float32List? _uploadedInstanceData;
  int _uploadedGeneration = -1;
  int _uploadedInstanceCount = -1;

  web.WebGLVertexArrayObject? _transformedVao;
  web.WebGLBuffer? _transformedInstanceBuffer;
  int _transformedInstanceCapBytes = 0;
  Float32List? _uploadedTransformedData;
  int _uploadedTransformedGeneration = -1;
  int _uploadedTransformedCount = -1;

  web.WebGLVertexArrayObject? _regionMaskVao;
  web.WebGLBuffer? _regionMaskInstanceBuffer;
  int _regionMaskInstanceCapBytes = 0;
  Float32List? _uploadedRegionMaskData;
  int _uploadedRegionMaskGeneration = -1;
  int _uploadedRegionMaskCount = -1;

  _GlFboTarget? _scratchTarget;
  _GlFboTarget? _chainTarget;
  _GlFboTarget? _sceneTarget;

  /// Optional per-pane GPU frame watchdog receiving `EXT_disjoint_timer_query_webgl2`
  /// elapsed timings and `webglcontextlost` notifications.
  @override
  GpuFrameWatchdog? watchdog;

  final Set<GpuFrameWatchdog> _activeWatchdogs =
      Set<GpuFrameWatchdog>.identity();
  bool _hasTimerQueryExt = false;
  web.WebGLQuery? _pendingTimerQuery;
  List<String> _pendingTimerShaderIds = const <String>[];
  GpuFrameWatchdog? _pendingTimerWatchdog;
  int _lastGpuCompletionUs = 0;

  bool _hasParallelCompile = false;
  bool _coreInitialized = false;
  bool _directAtlasInitialized = false;
  bool _directAtlasInitFailed = false;
  bool _contextLost = false;
  bool _disposed = false;
  String? _gpuRenderer;

  WebGl2ShaderBackend._(this._canvas, this._gl) {
    _contextLostHandler = _onContextLost.toJS;
    _contextRestoredHandler = _onContextRestored.toJS;
    _canvas.addEventListener('webglcontextlost', _contextLostHandler);
    _canvas.addEventListener('webglcontextrestored', _contextRestoredHandler);
    _gpuRenderer = _queryGpuRenderer(_gl);
  }

  static String? _queryGpuRenderer(web.WebGL2RenderingContext gl) {
    try {
      final debugExt = gl.getExtension('WEBGL_debug_renderer_info');
      final raw = debugExt != null
          ? gl.getParameter(
              web.WEBGL_debug_renderer_info.UNMASKED_RENDERER_WEBGL,
            )
          : gl.getParameter(web.WebGL2RenderingContext.RENDERER);
      if (raw != null && raw.isA<JSString>()) {
        final text = (raw as JSString).toDart.trim();
        if (text.isNotEmpty) return text;
      }
    } on Object {
      // Best-effort diagnostics; browsers may restrict renderer strings.
    }
    return null;
  }

  /// Attempts to construct a [WebGl2ShaderBackend] backed by a reusable
  /// `OffscreenCanvas` WebGL2 context.
  ///
  /// Returns `null` without throwing if `OffscreenCanvas` or `webgl2` context
  /// creation is unavailable or fails.
  static WebGl2ShaderBackend? tryCreate() {
    try {
      final canvas = web.OffscreenCanvas(1, 1);
      final attrs = web.WebGLContextAttributes(
        alpha: true,
        depth: false,
        stencil: false,
        antialias: false,
        premultipliedAlpha: true,
        preserveDrawingBuffer: false,
        powerPreference: 'high-performance',
      );
      final rawContext = canvas.getContext('webgl2', attrs);
      if (rawContext == null || !rawContext.isA<web.WebGL2RenderingContext>()) {
        return null;
      }
      final gl = rawContext as web.WebGL2RenderingContext;
      if (gl.isContextLost()) {
        return null;
      }
      return WebGl2ShaderBackend._(canvas, gl);
    } on Object {
      return null;
    }
  }

  @override
  ShaderBackendKind get kind => ShaderBackendKind.webGl2;

  @override
  bool get supportsCustomGlsl => true;

  @override
  bool get supportsSyncBackground => true;

  @override
  bool get supportsDirectTerminalRender =>
      !_disposed && !_directAtlasInitFailed;

  @override
  ShaderBackendDiagnostics readDiagnostics() {
    var fboTargets = _prevFrameTargets.length * 2 + _regionTargets.length * 3;
    if (_scratchTarget != null) fboTargets++;
    if (_chainTarget != null) fboTargets++;
    if (_sceneTarget != null) fboTargets++;
    return ShaderBackendDiagnostics(
      backingTextureCount: fboTargets,
      surfaceCount: _disposed ? 0 : 1,
      lastGpuCompletionUs: _lastGpuCompletionUs,
      gpuRenderer: _gpuRenderer,
    );
  }

  bool get _isContextUnavailable =>
      _disposed || _contextLost || _gl.isContextLost();

  @override
  Future<CompiledShaderHandle> compile(
    String id,
    String shadertoyGlsl, {
    bool usesPrevFrame = false,
  }) async {
    if (_disposed) {
      throw StateError('WebGl2ShaderBackend has been disposed.');
    }
    final shimmed = ShadertoyGlslShim.shim(shadertoyGlsl, shaderId: id);
    final effectivePrevFrame = usesPrevFrame || shimmed.analysis.usesPrevFrame;

    web.WebGLProgram? program;
    if (!_isContextUnavailable) {
      if (!_ensureCoreResources()) {
        throw ShaderCompileException(
          shaderId: id,
          message: 'Failed to initialize WebGL2 rendering resources.',
        );
      }
      program = await _compileAndLinkAsync(
        id,
        shimmed.webgl2FragmentGlsl,
        userSource: shadertoyGlsl,
      );
      if (_disposed) {
        if (!_gl.isContextLost()) {
          _gl.deleteProgram(program);
        }
        throw StateError('WebGl2ShaderBackend has been disposed.');
      }
    }

    final handle = _WebGl2ShaderHandle(
      backend: this,
      id: id,
      requestedPrevFrame: usesPrevFrame,
      usesPrevFrame: effectivePrevFrame,
      userSource: shadertoyGlsl,
      webgl2FragmentGlsl: shimmed.webgl2FragmentGlsl,
      program: program,
    );
    _handles.add(handle);
    return handle;
  }

  @override
  Future<void> reload(CompiledShaderHandle handle, String shadertoyGlsl) async {
    final glHandle = _requireOwnHandle(handle);
    final shimmed = ShadertoyGlslShim.shim(
      shadertoyGlsl,
      shaderId: glHandle.id,
    );
    final effectivePrevFrame =
        glHandle.requestedPrevFrame || shimmed.analysis.usesPrevFrame;

    if (_isContextUnavailable) {
      glHandle.userSource = shadertoyGlsl;
      glHandle.webgl2FragmentGlsl = shimmed.webgl2FragmentGlsl;
      glHandle.usesPrevFrame = effectivePrevFrame;
      glHandle.program = null;
      return;
    }
    if (!_ensureCoreResources()) {
      throw ShaderCompileException(
        shaderId: glHandle.id,
        message: 'Failed to initialize WebGL2 rendering resources.',
      );
    }

    // Compile the replacement program first so a failure leaves the previous
    // active WebGLProgram intact.
    final nextProgram = await _compileAndLinkAsync(
      glHandle.id,
      shimmed.webgl2FragmentGlsl,
      userSource: shadertoyGlsl,
    );
    if (_disposed || glHandle.isDisposed) {
      if (!_gl.isContextLost()) {
        _gl.deleteProgram(nextProgram);
      }
      return;
    }
    final previousProgram = glHandle.program;
    glHandle.program = nextProgram;
    glHandle.userSource = shadertoyGlsl;
    glHandle.webgl2FragmentGlsl = shimmed.webgl2FragmentGlsl;
    glHandle.usesPrevFrame = effectivePrevFrame;
    if (previousProgram != null && !_gl.isContextLost()) {
      _gl.deleteProgram(previousProgram);
    }
  }

  @override
  ui.Image? renderBackgroundSync({
    required List<ShaderPassInvocation> passes,
    required ui.Size physicalSize,
    ui.Image? wallpaperImage,
    GpuFrameWatchdog? watchdog,
  }) {
    if (_isContextUnavailable || passes.isEmpty) return null;
    final effectiveWatchdog = watchdog ?? this.watchdog;
    _trackActiveWatchdog(effectiveWatchdog);
    final dims = _resolveDimensions(physicalSize);
    if (dims == null) return null;

    if (wallpaperImage == null) {
      _cachedWallpaperImage = null;
    } else if (!identical(wallpaperImage, _cachedWallpaperImage)) {
      // Uncached ui.Image pixel readback is async on Web; let callers fall
      // back to renderPassesAsync once to populate the cached texture.
      return null;
    }

    if (!_ensureCoreResources()) return null;
    final rendered = _executePasses(
      passes,
      width: dims.$1,
      height: dims.$2,
      hasInputTexture: false,
      hasWallpaperTexture: wallpaperImage != null,
    );
    return rendered ? _exportCanvasImageSync() : null;
  }

  @override
  Future<ui.Image?> renderPassesAsync({
    required List<ShaderPassInvocation> passes,
    required ui.Size physicalSize,
    ui.Image? inputImage,
    ui.Image? wallpaperImage,
    GpuFrameWatchdog? watchdog,
  }) async {
    if (_isContextUnavailable || passes.isEmpty) return null;
    final effectiveWatchdog = watchdog ?? this.watchdog;
    _trackActiveWatchdog(effectiveWatchdog);
    final dims = _resolveDimensions(physicalSize);
    if (dims == null) return null;

    final needsInputUpload =
        inputImage != null && !identical(inputImage, _cachedInputImage);
    final needsWallpaperUpload =
        wallpaperImage != null &&
        !identical(wallpaperImage, _cachedWallpaperImage);
    // Start both cloned readbacks synchronously before any await so callers
    // disposing either ui.Image mid-frame cannot invalidate the second read.
    final inputFuture = needsInputUpload ? _readImageRgba(inputImage) : null;
    final wallpaperFuture = needsWallpaperUpload
        ? _readImageRgba(wallpaperImage)
        : null;
    final inputData = inputFuture != null ? await inputFuture : null;
    final wallpaperData = wallpaperFuture != null
        ? await wallpaperFuture
        : null;

    if (_isContextUnavailable) return null;
    if (!_ensureCoreResources()) return null;

    final hasInput = _syncInputTexture(inputImage, inputData, needsInputUpload);
    final hasWallpaper = _syncWallpaperTexture(
      wallpaperImage,
      wallpaperData,
      needsWallpaperUpload,
    );

    final rendered = _executePasses(
      passes,
      width: dims.$1,
      height: dims.$2,
      hasInputTexture: hasInput,
      hasWallpaperTexture: hasWallpaper,
    );
    if (!rendered) return null;
    return _exportCanvasImageAsync();
  }

  @override
  Future<bool> prepareDirectResources({
    required ui.Image atlasImage,
    ui.Image? wallpaperImage,
    Iterable<ui.Image> kittyImages = const <ui.Image>[],
  }) async {
    if (_isContextUnavailable || _directAtlasInitFailed) return false;

    final pending = <Future<bool>>[
      if (!_isAtlasTextureReady(atlasImage))
        _primeImageDeduplicated(atlasImage, _syncAtlasTexture),
      if (!_isWallpaperTextureReady(wallpaperImage))
        _primeImageDeduplicated(
          wallpaperImage!,
          (image, data) => _syncWallpaperTexture(image, data, true),
        ),
      for (final kittyImage in kittyImages)
        if (!_kittyTextures.containsKey(kittyImage))
          _primeImageDeduplicated(kittyImage, _syncKittyTexture),
    ];

    if (pending.isNotEmpty) {
      await Future.wait(pending);
    }
    if (_isContextUnavailable ||
        !_ensureCoreResources() ||
        !_ensureDirectAtlasResources()) {
      return false;
    }

    return _isAtlasTextureReady(atlasImage) &&
        _isWallpaperTextureReady(wallpaperImage) &&
        kittyImages.every(_kittyTextures.containsKey);
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
    final tracing = ShaderPerfTrace.isEnabled;
    final spanStart = tracing
        ? ShaderPerfTrace.beginSpan('WebGl2.renderDirect')
        : 0;
    try {
      return _renderTerminalFrameSyncImpl(
        backgroundPasses: backgroundPasses,
        foregroundPasses: foregroundPasses,
        physicalSize: physicalSize,
        atlasImage: atlasImage,
        batch: batch,
        wallpaperImage: wallpaperImage,
        watchdog: watchdog,
      );
    } finally {
      if (tracing) {
        ShaderPerfTrace.endSpan('WebGl2.renderDirect', spanStart);
      }
    }
  }

  ui.Image? _renderTerminalFrameSyncImpl({
    required List<ShaderPassInvocation> backgroundPasses,
    required List<ShaderPassInvocation> foregroundPasses,
    required ui.Size physicalSize,
    required ui.Image atlasImage,
    required GpuAtlasQuadBatch batch,
    ui.Image? wallpaperImage,
    GpuFrameWatchdog? watchdog,
  }) {
    if (_isContextUnavailable || _directAtlasInitFailed) return null;
    final effectiveWatchdog = watchdog ?? this.watchdog;
    _trackActiveWatchdog(effectiveWatchdog);
    final dims = _resolveDimensions(physicalSize);
    if (dims == null ||
        !_areDirectTexturesPrimed(atlasImage, wallpaperImage, batch) ||
        !_ensureCoreResources() ||
        !_ensureDirectAtlasResources()) {
      return null;
    }

    final width = dims.$1;
    final height = dims.$2;
    _ensureCanvasSize(width, height);
    _pollPendingTimerQuery();

    final customIds = _collectActiveCustomShaderIds(
      effectiveWatchdog,
      backgroundPasses,
      foregroundPasses,
      batch.regionPasses,
    );
    final timerQuery = _beginTimerQueryIfNeeded(effectiveWatchdog, customIds);

    final hasForeground = foregroundPasses.isNotEmpty;
    if (hasForeground && !_ensureSceneTarget(width, height)) {
      _endTimerQuery(timerQuery, effectiveWatchdog, customIds);
      return null;
    }
    final sceneFbo = hasForeground ? _sceneTarget!.framebuffer : null;

    if (!_renderDirectBackgroundStage(
      backgroundPasses: backgroundPasses,
      wallpaperImage: wallpaperImage,
      sceneFbo: sceneFbo,
      width: width,
      height: height,
    )) {
      _endTimerQuery(timerQuery, effectiveWatchdog, customIds);
      return null;
    }

    _renderDirectTerminalStage(
      batch: batch,
      sceneFbo: sceneFbo,
      width: width,
      height: height,
      hasWallpaperTexture: wallpaperImage != null,
    );

    if (hasForeground &&
        !_renderDirectForegroundStage(
          foregroundPasses: foregroundPasses,
          hasWallpaperTexture: wallpaperImage != null,
          width: width,
          height: height,
        )) {
      _endTimerQuery(timerQuery, effectiveWatchdog, customIds);
      return null;
    }

    _endTimerQuery(timerQuery, effectiveWatchdog, customIds);
    return _exportCanvasImageSync();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _canvas.removeEventListener('webglcontextlost', _contextLostHandler);
    _canvas.removeEventListener(
      'webglcontextrestored',
      _contextRestoredHandler,
    );
    final canDelete = !_contextLost && !_gl.isContextLost();
    _invalidateGpuResources(deleteObjects: canDelete);
    for (final handle in _handles) {
      handle.markDisposed();
    }
    _handles.clear();
    _activeWatchdogs.clear();
  }

  void _disposeHandle(_WebGl2ShaderHandle handle) {
    if (handle.isDisposed) return;
    handle.markDisposed();
    _handles.remove(handle);
    final canDelete = !_disposed && !_contextLost && !_gl.isContextLost();
    final program = handle.program;
    handle.program = null;
    if (program != null && canDelete) {
      _gl.deleteProgram(program);
    }
    _prevFrameTargets.removeByOwnerTag(handle.id, invokeOnEvict: canDelete);
    _prevFrameTargets.remove(handle.id, invokeOnEvict: canDelete);
  }

  void _deleteFboTargetIfContextAlive(_GlFboTarget target) {
    if (_contextLost || _gl.isContextLost()) return;
    target.delete(_gl);
  }

  void _trackActiveWatchdog(GpuFrameWatchdog? wd) {
    if (wd == null || wd.isDisposed) return;
    _activeWatchdogs.removeWhere((item) => item.isDisposed);
    _activeWatchdogs.add(wd);
  }

  _WebGl2ShaderHandle _requireOwnHandle(CompiledShaderHandle handle) {
    if (_disposed) {
      throw StateError('WebGl2ShaderBackend has been disposed.');
    }
    if (handle is! _WebGl2ShaderHandle ||
        !identical(handle.backend, this) ||
        handle.isDisposed) {
      throw StateError(
        'Shader handle "${handle.id}" is disposed or does not belong to this '
        'WebGl2ShaderBackend.',
      );
    }
    return handle;
  }

  void _onContextLost(web.Event event) {
    event.preventDefault();
    _contextLost = true;
    _invalidateGpuResources(deleteObjects: false);
    final targets = Set<GpuFrameWatchdog>.identity()..addAll(_activeWatchdogs);
    if (watchdog != null) targets.add(watchdog!);
    _activeWatchdogs.removeWhere((item) => item.isDisposed);
    for (final wd in targets) {
      if (!wd.isDisposed) wd.reportWebGlContextLost();
    }
  }

  void _onContextRestored(web.Event event) {
    if (_disposed) return;
    _contextLost = false;
    _directAtlasInitFailed = false;
    _invalidateGpuResources(deleteObjects: false);
  }

  void _invalidateGpuResources({required bool deleteObjects}) {
    for (final handle in _handles) {
      final program = handle.program;
      handle.program = null;
      if (deleteObjects && program != null) {
        _gl.deleteProgram(program);
      }
    }
    _deleteTransientTargets(deleteObjects: deleteObjects);
    if (deleteObjects) {
      _deleteCoreObjects();
    }
    _vertexShader = null;
    _vao = null;
    _vertexBuffer = null;
    _ubo = null;
    _dummyTexture = null;
    _inputTexture = null;
    _inputWidth = 0;
    _inputHeight = 0;
    _cachedInputImage = null;
    _wallpaperTexture = null;
    _wallpaperWidth = 0;
    _wallpaperHeight = 0;
    _cachedWallpaperImage = null;
    _atlasProgram = null;
    _atlasViewportLoc = null;
    _atlasUnitQuadBuffer = null;
    _atlasVao = null;
    _atlasInstanceBuffer = null;
    _atlasInstanceCapBytes = 0;
    _singleQuadVao = null;
    _singleQuadInstanceBuffer = null;
    _atlasTexture = null;
    _atlasWidth = 0;
    _atlasHeight = 0;
    _cachedAtlasImage = null;
    _atlasFilterMode = web.WebGL2RenderingContext.LINEAR;
    _kittyTextures.clear();
    _uploadedInstanceData = null;
    _uploadedGeneration = -1;
    _uploadedInstanceCount = -1;
    _transformedVao = null;
    _transformedInstanceBuffer = null;
    _transformedInstanceCapBytes = 0;
    _uploadedTransformedData = null;
    _uploadedTransformedGeneration = -1;
    _uploadedTransformedCount = -1;
    _regionMaskVao = null;
    _regionMaskInstanceBuffer = null;
    _regionMaskInstanceCapBytes = 0;
    _uploadedRegionMaskData = null;
    _uploadedRegionMaskGeneration = -1;
    _uploadedRegionMaskCount = -1;
    _pendingTimerQuery = null;
    _pendingTimerShaderIds = const <String>[];
    _hasTimerQueryExt = false;
    _hasParallelCompile = false;
    _coreInitialized = false;
    _directAtlasInitialized = false;
  }

  void _deleteTransientTargets({required bool deleteObjects}) {
    if (deleteObjects) {
      _scratchTarget?.delete(_gl);
      _chainTarget?.delete(_gl);
      _sceneTarget?.delete(_gl);
      if (_pendingTimerQuery != null) _gl.deleteQuery(_pendingTimerQuery);
    }
    _scratchTarget = null;
    _chainTarget = null;
    _sceneTarget = null;
    _pendingTimerQuery = null;
    _pendingTimerShaderIds = const <String>[];
    _pendingTimerWatchdog = null;
    _lastGpuCompletionUs = 0;
    _regionTargets.clear(invokeOnDelete: deleteObjects);
    _prevFrameTargets.clear(invokeOnEvict: deleteObjects);
  }

  void _deleteCoreObjects() {
    if (_vertexShader != null) _gl.deleteShader(_vertexShader);
    if (_vao != null) _gl.deleteVertexArray(_vao);
    if (_vertexBuffer != null) _gl.deleteBuffer(_vertexBuffer);
    if (_ubo != null) _gl.deleteBuffer(_ubo);
    if (_dummyTexture != null) _gl.deleteTexture(_dummyTexture);
    if (_inputTexture != null) _gl.deleteTexture(_inputTexture);
    if (_wallpaperTexture != null) _gl.deleteTexture(_wallpaperTexture);
    _deleteDirectAtlasObjects();
  }

  void _deleteDirectAtlasObjects() {
    if (_atlasProgram != null) _gl.deleteProgram(_atlasProgram);
    if (_atlasVao != null) _gl.deleteVertexArray(_atlasVao);
    if (_atlasUnitQuadBuffer != null) _gl.deleteBuffer(_atlasUnitQuadBuffer);
    if (_atlasInstanceBuffer != null) _gl.deleteBuffer(_atlasInstanceBuffer);
    if (_transformedVao != null) _gl.deleteVertexArray(_transformedVao);
    if (_transformedInstanceBuffer != null) {
      _gl.deleteBuffer(_transformedInstanceBuffer);
    }
    if (_regionMaskVao != null) _gl.deleteVertexArray(_regionMaskVao);
    if (_regionMaskInstanceBuffer != null) {
      _gl.deleteBuffer(_regionMaskInstanceBuffer);
    }
    if (_singleQuadVao != null) _gl.deleteVertexArray(_singleQuadVao);
    if (_singleQuadInstanceBuffer != null) {
      _gl.deleteBuffer(_singleQuadInstanceBuffer);
    }
    if (_atlasTexture != null) _gl.deleteTexture(_atlasTexture);
    for (final cached in _kittyTextures.values) {
      _gl.deleteTexture(cached.texture);
    }
  }

  bool _ensureCoreResources() {
    if (_coreInitialized) return true;
    if (_isContextUnavailable) return false;

    _gl.disable(web.WebGL2RenderingContext.BLEND);
    _gl.disable(web.WebGL2RenderingContext.DEPTH_TEST);
    _gl.disable(web.WebGL2RenderingContext.STENCIL_TEST);
    _gl.disable(web.WebGL2RenderingContext.CULL_FACE);
    _gl.disable(web.WebGL2RenderingContext.SCISSOR_TEST);
    _gl.pixelStorei(web.WebGL2RenderingContext.UNPACK_ALIGNMENT, 1);
    _gl.pixelStorei(web.WebGL2RenderingContext.UNPACK_FLIP_Y_WEBGL, 0);
    _gl.pixelStorei(
      web.WebGL2RenderingContext.UNPACK_PREMULTIPLY_ALPHA_WEBGL,
      0,
    );

    _hasParallelCompile =
        _gl.getExtension('KHR_parallel_shader_compile') != null;
    _hasTimerQueryExt =
        _gl.getExtension('EXT_disjoint_timer_query_webgl2') != null;

    if (!_initFullscreenVao() ||
        !_initUniformBuffer() ||
        !_initDummyTexture() ||
        !_initSharedVertexShader()) {
      _invalidateGpuResources(deleteObjects: !_gl.isContextLost());
      return false;
    }
    _coreInitialized = true;
    return true;
  }

  bool _initFullscreenVao() {
    final vao = _gl.createVertexArray();
    final vbo = _gl.createBuffer();
    if (vao == null || vbo == null) return false;
    _vao = vao;
    _vertexBuffer = vbo;
    _gl.bindVertexArray(vao);
    _gl.bindBuffer(web.WebGL2RenderingContext.ARRAY_BUFFER, vbo);
    _gl.bufferData(
      web.WebGL2RenderingContext.ARRAY_BUFFER,
      _fullscreenTriangleVertices.toJS,
      web.WebGL2RenderingContext.STATIC_DRAW,
    );
    _gl.enableVertexAttribArray(0);
    _gl.vertexAttribPointer(
      0,
      2,
      web.WebGL2RenderingContext.FLOAT,
      false,
      0,
      0,
    );
    _gl.bindVertexArray(null);
    _gl.bindBuffer(web.WebGL2RenderingContext.ARRAY_BUFFER, null);
    return true;
  }

  bool _initUniformBuffer() {
    final ubo = _gl.createBuffer();
    if (ubo == null) return false;
    _ubo = ubo;
    _gl.bindBuffer(web.WebGL2RenderingContext.UNIFORM_BUFFER, ubo);
    _gl.bufferData(
      web.WebGL2RenderingContext.UNIFORM_BUFFER,
      ShadertoyGlslShim.uniformBufferByteLength.toJS,
      web.WebGL2RenderingContext.DYNAMIC_DRAW,
    );
    _gl.bindBufferBase(
      web.WebGL2RenderingContext.UNIFORM_BUFFER,
      _uboBindingPoint,
      ubo,
    );
    _gl.bindBuffer(web.WebGL2RenderingContext.UNIFORM_BUFFER, null);
    return true;
  }

  bool _initDummyTexture() {
    final tex = _createConfiguredTexture();
    if (tex == null) return false;
    _dummyTexture = tex;
    _gl.bindTexture(web.WebGL2RenderingContext.TEXTURE_2D, tex);
    _gl.texImage2D(
      web.WebGL2RenderingContext.TEXTURE_2D,
      0,
      web.WebGL2RenderingContext.RGBA,
      1.toJS,
      1.toJS,
      0.toJS,
      web.WebGL2RenderingContext.RGBA,
      web.WebGL2RenderingContext.UNSIGNED_BYTE,
      _transparentPixel.toJS,
    );
    _gl.bindTexture(web.WebGL2RenderingContext.TEXTURE_2D, null);
    return true;
  }

  bool _initSharedVertexShader() {
    final shader = _gl.createShader(web.WebGL2RenderingContext.VERTEX_SHADER);
    if (shader == null) return false;
    _gl.shaderSource(shader, ShadertoyGlslShim.webgl2VertexShaderSource);
    _gl.compileShader(shader);
    if (!_asJsBool(
      _gl.getShaderParameter(shader, web.WebGL2RenderingContext.COMPILE_STATUS),
    )) {
      _gl.deleteShader(shader);
      return false;
    }
    _vertexShader = shader;
    return true;
  }

  Future<web.WebGLProgram> _compileAndLinkAsync(
    String shaderId,
    String fragmentGlsl, {
    required String userSource,
  }) async {
    final prepared = _startProgramLink(shaderId, fragmentGlsl);
    final program = prepared.$1;
    final fragShader = prepared.$2;
    try {
      if (_hasParallelCompile) {
        await _awaitParallelLinkCompletion(program);
      }
      return _finalizeProgramLink(
        shaderId,
        program,
        fragShader,
        userSource: userSource,
      );
    } on Object {
      if (!_gl.isContextLost()) {
        _gl.deleteShader(fragShader);
        _gl.deleteProgram(program);
      }
      rethrow;
    }
  }

  web.WebGLProgram _compileAndLinkSync(
    String shaderId,
    String fragmentGlsl, {
    required String userSource,
  }) {
    final prepared = _startProgramLink(shaderId, fragmentGlsl);
    final program = prepared.$1;
    final fragShader = prepared.$2;
    try {
      return _finalizeProgramLink(
        shaderId,
        program,
        fragShader,
        userSource: userSource,
      );
    } on Object {
      if (!_gl.isContextLost()) {
        _gl.deleteShader(fragShader);
        _gl.deleteProgram(program);
      }
      rethrow;
    }
  }

  (web.WebGLProgram, web.WebGLShader) _startProgramLink(
    String shaderId,
    String fragmentGlsl,
  ) {
    final vertShader = _vertexShader;
    if (vertShader == null) {
      throw ShaderCompileException(
        shaderId: shaderId,
        message: 'Shared WebGL2 vertex shader is not initialized.',
      );
    }
    final fragShader = _gl.createShader(
      web.WebGL2RenderingContext.FRAGMENT_SHADER,
    );
    final program = _gl.createProgram();
    if (fragShader == null || program == null) {
      if (fragShader != null) _gl.deleteShader(fragShader);
      if (program != null) _gl.deleteProgram(program);
      throw ShaderCompileException(
        shaderId: shaderId,
        message: 'Failed to allocate WebGL2 shader or program object.',
      );
    }
    _gl.shaderSource(fragShader, fragmentGlsl);
    _gl.compileShader(fragShader);
    _gl.attachShader(program, vertShader);
    _gl.attachShader(program, fragShader);
    _gl.linkProgram(program);
    return (program, fragShader);
  }

  Future<void> _awaitParallelLinkCompletion(web.WebGLProgram program) async {
    for (var i = 0; i < _maxParallelCompilePolls; i++) {
      if (_isContextUnavailable) return;
      final completed = _asJsBool(
        _gl.getProgramParameter(
          program,
          web.KHR_parallel_shader_compile.COMPLETION_STATUS_KHR,
        ),
      );
      if (completed) return;
      await Future<void>.delayed(Duration.zero);
    }
  }

  web.WebGLProgram _finalizeProgramLink(
    String shaderId,
    web.WebGLProgram program,
    web.WebGLShader fragShader, {
    required String userSource,
  }) {
    if (_isContextUnavailable) {
      throw ShaderCompileException(
        shaderId: shaderId,
        message: 'WebGL2 context was lost during shader compilation.',
      );
    }
    final linked = _asJsBool(
      _gl.getProgramParameter(program, web.WebGL2RenderingContext.LINK_STATUS),
    );
    if (!linked) {
      throw _buildCompileException(
        shaderId,
        program,
        fragShader,
        userSource: userSource,
      );
    }
    _gl.detachShader(program, fragShader);
    _gl.deleteShader(fragShader);
    _configureProgramBindings(program);
    return program;
  }

  void _configureProgramBindings(web.WebGLProgram program) {
    final blockIndex = _gl.getUniformBlockIndex(
      program,
      ShadertoyGlslShim.uniformBlockName,
    );
    if (blockIndex != web.WebGL2RenderingContext.INVALID_INDEX) {
      _gl.uniformBlockBinding(program, blockIndex, _uboBindingPoint);
    }
    _gl.useProgram(program);
    _bindSamplerIfActive(program, 'iChannel0', 0);
    _bindSamplerIfActive(program, 'iChannel1', 1);
    _bindSamplerIfActive(program, 'iPrevFrame', 2);
    _gl.useProgram(null);
  }

  void _bindSamplerIfActive(
    web.WebGLProgram program,
    String uniformName,
    int textureUnit,
  ) {
    final loc = _gl.getUniformLocation(program, uniformName);
    if (loc != null) {
      _gl.uniform1i(loc, textureUnit);
    }
  }

  ShaderCompileException _buildCompileException(
    String shaderId,
    web.WebGLProgram program,
    web.WebGLShader fragShader, {
    String userSource = '',
  }) {
    final fragCompiled = _asJsBool(
      _gl.getShaderParameter(
        fragShader,
        web.WebGL2RenderingContext.COMPILE_STATUS,
      ),
    );
    final rawLog = fragCompiled
        ? (_gl.getProgramInfoLog(program) ?? 'WebGL2 program link failed.')
        : (_gl.getShaderInfoLog(fragShader) ??
              'WebGL2 fragment shader compilation failed.');
    final trimmedLog = rawLog.replaceAll('\u0000', '').trim();
    final diagnostics = parseWebGlDiagnostics(
      trimmedLog,
      userSource: userSource,
      prefixLineOffset: _webgl2PrefixLineOffset,
    );
    final firstError = firstErrorDiagnostic(diagnostics);
    final firstLine = firstError?.message ?? _firstNonEmptyLine(trimmedLog);
    return ShaderCompileException(
      shaderId: shaderId,
      message: firstLine.isEmpty
          ? 'WebGL2 shader compilation failed.'
          : firstLine,
      lineNumber: firstError?.line,
      compilerLog: trimmedLog.isEmpty ? null : trimmedLog,
      diagnostics: diagnostics,
    );
  }

  bool _executePasses(
    List<ShaderPassInvocation> passes, {
    required int width,
    required int height,
    required bool hasInputTexture,
    required bool hasWallpaperTexture,
    web.WebGLTexture? initialChannel0,
    web.WebGLFramebuffer? finalFramebuffer,
  }) {
    if (_canvas.width != width || _canvas.height != height) {
      _canvas.width = width;
      _canvas.height = height;
    }

    for (var i = 0; i < passes.length; i++) {
      final ok = _executeSinglePass(
        passes[i],
        passIndex: i,
        isLast: i == passes.length - 1,
        width: width,
        height: height,
        hasInputTexture: hasInputTexture,
        hasWallpaperTexture: hasWallpaperTexture,
        initialChannel0: initialChannel0,
        finalFramebuffer: finalFramebuffer,
      );
      if (!ok) return false;
    }
    return true;
  }

  bool _executeSinglePass(
    ShaderPassInvocation pass, {
    required int passIndex,
    required bool isLast,
    required int width,
    required int height,
    required bool hasInputTexture,
    required bool hasWallpaperTexture,
    web.WebGLTexture? initialChannel0,
    web.WebGLFramebuffer? finalFramebuffer,
  }) {
    final handle = pass.handle;
    if (handle is! _WebGl2ShaderHandle ||
        !identical(handle.backend, this) ||
        handle.isDisposed) {
      return false;
    }
    final program = _ensureProgramForHandle(handle);
    if (program == null) return false;

    final usesPrevFrame = handle.usesPrevFrame;
    final prevSlot = usesPrevFrame
        ? _prevFrameTargets.tryAcquire(
            pass.prevFrameKey ?? handle.id,
            width,
            height,
            _createFboTarget,
            ownerTag: handle.id,
          )
        : null;
    if (usesPrevFrame && prevSlot == null) return false;

    final needsScratchFbo = !isLast || usesPrevFrame;
    if (needsScratchFbo && !_ensureScratchTarget(width, height)) {
      return false;
    }

    _uploadUniformBlock(pass.uniforms);
    _bindPassTextures(
      channel0: _resolveChannel0Texture(
        passIndex,
        hasInputTexture,
        initialChannel0: initialChannel0,
      ),
      channel1: hasWallpaperTexture ? _wallpaperTexture : _dummyTexture,
      prevFrame: prevSlot?.readTexture?.texture ?? _dummyTexture,
    );
    _drawFullscreenPass(
      program,
      framebuffer: needsScratchFbo
          ? _scratchTarget!.framebuffer
          : finalFramebuffer,
      width: width,
      height: height,
    );

    if (!needsScratchFbo) return true;
    return _finalizeScratchPass(
      isLast: isLast,
      width: width,
      height: height,
      prevSlot: prevSlot,
      finalFramebuffer: finalFramebuffer,
    );
  }

  web.WebGLProgram? _ensureProgramForHandle(_WebGl2ShaderHandle handle) {
    final existing = handle.program;
    if (existing != null) return existing;
    try {
      final compiled = _compileAndLinkSync(
        handle.id,
        handle.webgl2FragmentGlsl,
        userSource: handle.userSource,
      );
      handle.program = compiled;
      return compiled;
    } on Object {
      return null;
    }
  }

  web.WebGLTexture? _resolveChannel0Texture(
    int passIndex,
    bool hasInputTexture, {
    web.WebGLTexture? initialChannel0,
  }) {
    if (passIndex > 0) {
      return _chainTarget?.texture ?? _dummyTexture;
    }
    if (initialChannel0 != null) {
      return initialChannel0;
    }
    return hasInputTexture ? (_inputTexture ?? _dummyTexture) : _dummyTexture;
  }

  void _uploadUniformBlock(TerminalShaderUniforms uniforms) {
    // External ui.Image uploads keep UNPACK_FLIP_Y_WEBGL = 0 (top-left origin),
    // and intermediate/iPrevFrame FBO blits flip Y into matching top-left
    // orientation so all three samplers share flipUvY = true consistently.
    ShadertoyGlslShim.packUniformsStd140(
      uniforms,
      _uniformByteData,
      flipUvY: true,
    );
    _gl.bindBuffer(web.WebGL2RenderingContext.UNIFORM_BUFFER, _ubo);
    _gl.bufferSubData(
      web.WebGL2RenderingContext.UNIFORM_BUFFER,
      0,
      _uniformBytes.toJS,
    );
    _gl.bindBufferBase(
      web.WebGL2RenderingContext.UNIFORM_BUFFER,
      _uboBindingPoint,
      _ubo,
    );
    _gl.bindBuffer(web.WebGL2RenderingContext.UNIFORM_BUFFER, null);
  }

  void _bindPassTextures({
    required web.WebGLTexture? channel0,
    required web.WebGLTexture? channel1,
    required web.WebGLTexture? prevFrame,
  }) {
    _gl.activeTexture(web.WebGL2RenderingContext.TEXTURE0);
    _gl.bindTexture(
      web.WebGL2RenderingContext.TEXTURE_2D,
      channel0 ?? _dummyTexture,
    );
    _gl.activeTexture(web.WebGL2RenderingContext.TEXTURE1);
    _gl.bindTexture(
      web.WebGL2RenderingContext.TEXTURE_2D,
      channel1 ?? _dummyTexture,
    );
    _gl.activeTexture(web.WebGL2RenderingContext.TEXTURE2);
    _gl.bindTexture(
      web.WebGL2RenderingContext.TEXTURE_2D,
      prevFrame ?? _dummyTexture,
    );
  }

  void _drawFullscreenPass(
    web.WebGLProgram program, {
    required web.WebGLFramebuffer? framebuffer,
    required int width,
    required int height,
  }) {
    _gl.bindFramebuffer(web.WebGL2RenderingContext.FRAMEBUFFER, framebuffer);
    _gl.viewport(0, 0, width, height);
    _gl.clearColor(0.0, 0.0, 0.0, 0.0);
    _gl.clear(web.WebGL2RenderingContext.COLOR_BUFFER_BIT);
    _gl.useProgram(program);
    _gl.bindVertexArray(_vao);
    _gl.drawArrays(web.WebGL2RenderingContext.TRIANGLES, 0, 3);
    _gl.bindVertexArray(null);
    _gl.useProgram(null);
  }

  bool _finalizeScratchPass({
    required bool isLast,
    required int width,
    required int height,
    required GpuPingPongSlot<_GlFboTarget>? prevSlot,
    web.WebGLFramebuffer? finalFramebuffer,
  }) {
    final scratch = _scratchTarget;
    if (scratch == null) return false;
    _unbindSamplerTextures();

    if (prevSlot != null) {
      _blitFramebuffer(
        scratch.framebuffer,
        prevSlot.writeTexture.framebuffer,
        width: width,
        height: height,
        flipY: true,
      );
      prevSlot.commitWriteAndSwap();
    }

    if (!isLast) {
      if (!_ensureChainTarget(width, height)) return false;
      _blitFramebuffer(
        scratch.framebuffer,
        _chainTarget!.framebuffer,
        width: width,
        height: height,
        flipY: true,
      );
    } else {
      _blitFramebuffer(
        scratch.framebuffer,
        finalFramebuffer,
        width: width,
        height: height,
        flipY: false,
      );
    }
    return true;
  }

  void _unbindSamplerTextures() {
    _gl.activeTexture(web.WebGL2RenderingContext.TEXTURE0);
    _gl.bindTexture(web.WebGL2RenderingContext.TEXTURE_2D, null);
    _gl.activeTexture(web.WebGL2RenderingContext.TEXTURE1);
    _gl.bindTexture(web.WebGL2RenderingContext.TEXTURE_2D, null);
    _gl.activeTexture(web.WebGL2RenderingContext.TEXTURE2);
    _gl.bindTexture(web.WebGL2RenderingContext.TEXTURE_2D, null);
  }

  void _blitFramebuffer(
    web.WebGLFramebuffer readFbo,
    web.WebGLFramebuffer? drawFbo, {
    required int width,
    required int height,
    required bool flipY,
  }) {
    _gl.bindFramebuffer(web.WebGL2RenderingContext.READ_FRAMEBUFFER, readFbo);
    _gl.bindFramebuffer(web.WebGL2RenderingContext.DRAW_FRAMEBUFFER, drawFbo);
    _gl.blitFramebuffer(
      0,
      0,
      width,
      height,
      0,
      flipY ? height : 0,
      width,
      flipY ? 0 : height,
      web.WebGL2RenderingContext.COLOR_BUFFER_BIT,
      web.WebGL2RenderingContext.NEAREST,
    );
    _gl.bindFramebuffer(web.WebGL2RenderingContext.READ_FRAMEBUFFER, null);
    _gl.bindFramebuffer(web.WebGL2RenderingContext.DRAW_FRAMEBUFFER, null);
  }

  bool _ensureScratchTarget(int width, int height) {
    final existing = _scratchTarget;
    if (existing != null && existing.matches(width, height)) return true;
    existing?.delete(_gl);
    _scratchTarget = _createFboTarget(width, height);
    return _scratchTarget != null;
  }

  bool _ensureChainTarget(int width, int height) {
    final existing = _chainTarget;
    if (existing != null && existing.matches(width, height)) return true;
    existing?.delete(_gl);
    _chainTarget = _createFboTarget(width, height);
    return _chainTarget != null;
  }

  bool _ensureSceneTarget(int width, int height) {
    final existing = _sceneTarget;
    if (existing != null && existing.matches(width, height)) return true;
    existing?.delete(_gl);
    _sceneTarget = _createFboTarget(width, height);
    return _sceneTarget != null;
  }

  Future<bool> _primeImageDeduplicated(
    ui.Image image,
    bool Function(ui.Image image, RgbaImagePixels? data) uploader,
  ) {
    final existing = _primingInFlight[image];
    if (existing != null) return existing;
    final future = _primeImageOnce(image, uploader);
    _primingInFlight[image] = future;
    return future;
  }

  Future<bool> _primeImageOnce(
    ui.Image image,
    bool Function(ui.Image image, RgbaImagePixels? data) uploader,
  ) async {
    try {
      final data = await _readImageRgba(image);
      if (_isContextUnavailable || data == null) return false;
      if (!_ensureCoreResources()) return false;
      return uploader(image, data);
    } on Object {
      return false;
    } finally {
      _primingInFlight.remove(image);
    }
  }

  bool _syncAtlasTexture(ui.Image image, RgbaImagePixels? data) {
    if (data == null) return false;
    final tracing = ShaderPerfTrace.isEnabled;
    final spanStart = tracing
        ? ShaderPerfTrace.beginSpan('WebGl2.atlasUpload')
        : 0;
    try {
      final uploaded = _uploadRgbaTexture(
        existing: _atlasTexture,
        existingWidth: _atlasWidth,
        existingHeight: _atlasHeight,
        width: data.width,
        height: data.height,
        rgbaData: data.bytes,
      );
      if (uploaded == null) return false;
      _atlasTexture = uploaded;
      _atlasWidth = data.width;
      _atlasHeight = data.height;
      _cachedAtlasImage = image;
      _atlasFilterMode = web.WebGL2RenderingContext.LINEAR;
      return true;
    } finally {
      if (tracing) {
        ShaderPerfTrace.endSpan('WebGl2.atlasUpload', spanStart);
      }
    }
  }

  bool _syncKittyTexture(ui.Image image, RgbaImagePixels? data) {
    if (data == null) return false;
    final existing = _kittyTextures.remove(image);
    final uploaded = _uploadRgbaTexture(
      existing: existing?.texture,
      existingWidth: existing?.width ?? 0,
      existingHeight: existing?.height ?? 0,
      width: data.width,
      height: data.height,
      rgbaData: data.bytes,
    );
    if (uploaded == null) return false;
    _kittyTextures[image] = _GlCachedTexture(
      texture: uploaded,
      width: data.width,
      height: data.height,
    );
    while (_kittyTextures.length > _maxKittyTextureCacheEntries) {
      final oldestKey = _kittyTextures.keys.first;
      final evicted = _kittyTextures.remove(oldestKey);
      if (evicted != null && !_gl.isContextLost()) {
        _gl.deleteTexture(evicted.texture);
      }
    }
    return true;
  }

  bool _isAtlasTextureReady(ui.Image atlasImage) =>
      identical(atlasImage, _cachedAtlasImage) && _atlasTexture != null;

  bool _isWallpaperTextureReady(ui.Image? wallpaperImage) =>
      wallpaperImage == null ||
      (identical(wallpaperImage, _cachedWallpaperImage) &&
          _wallpaperTexture != null);

  void _ensureCanvasSize(int width, int height) {
    if (_canvas.width != width || _canvas.height != height) {
      _canvas.width = width;
      _canvas.height = height;
    }
  }

  bool _renderDirectForegroundStage({
    required List<ShaderPassInvocation> foregroundPasses,
    required bool hasWallpaperTexture,
    required int width,
    required int height,
  }) {
    final tracing = ShaderPerfTrace.isEnabled;
    final spanStart = tracing
        ? ShaderPerfTrace.beginSpan('WebGl2.fgPasses')
        : 0;
    try {
      if (!_ensureChainTarget(width, height)) return false;
      _blitFramebuffer(
        _sceneTarget!.framebuffer,
        _chainTarget!.framebuffer,
        width: width,
        height: height,
        flipY: true,
      );
      return _executePasses(
        foregroundPasses,
        width: width,
        height: height,
        hasInputTexture: true,
        hasWallpaperTexture: hasWallpaperTexture,
        initialChannel0: _chainTarget!.texture,
        finalFramebuffer: null,
      );
    } finally {
      if (tracing) {
        ShaderPerfTrace.endSpan('WebGl2.fgPasses', spanStart);
      }
    }
  }

  bool _areDirectTexturesPrimed(
    ui.Image atlasImage,
    ui.Image? wallpaperImage,
    GpuAtlasQuadBatch batch,
  ) {
    if (!_isAtlasTextureReady(atlasImage) ||
        !_isWallpaperTextureReady(wallpaperImage)) {
      return false;
    }
    for (final quad in batch.kittyQuads) {
      if (!_kittyTextures.containsKey(quad.image)) return false;
    }
    return true;
  }

  bool _ensureDirectAtlasResources() {
    if (_directAtlasInitialized) return true;
    if (_isContextUnavailable || _directAtlasInitFailed) return false;

    if (!_initDirectAtlasProgram() || !_initDirectAtlasBuffers()) {
      _directAtlasInitFailed = true;
      return false;
    }
    _directAtlasInitialized = true;
    return true;
  }

  bool _initDirectAtlasProgram() {
    final vert = _compileInlineShader(
      web.WebGL2RenderingContext.VERTEX_SHADER,
      GpuAtlasShaders.webgl2VertexSource,
    );
    final frag = _compileInlineShader(
      web.WebGL2RenderingContext.FRAGMENT_SHADER,
      GpuAtlasShaders.webgl2FragmentSource,
    );
    final program = _gl.createProgram();
    if (vert == null || frag == null || program == null) {
      if (vert != null) _gl.deleteShader(vert);
      if (frag != null) _gl.deleteShader(frag);
      if (program != null) _gl.deleteProgram(program);
      return false;
    }
    _gl.attachShader(program, vert);
    _gl.attachShader(program, frag);
    _gl.linkProgram(program);
    final linked = _asJsBool(
      _gl.getProgramParameter(program, web.WebGL2RenderingContext.LINK_STATUS),
    );
    _gl.detachShader(program, vert);
    _gl.detachShader(program, frag);
    _gl.deleteShader(vert);
    _gl.deleteShader(frag);
    if (!linked) {
      _gl.deleteProgram(program);
      return false;
    }
    _atlasProgram = program;
    _atlasViewportLoc = _gl.getUniformLocation(
      program,
      GpuAtlasShaders.viewportUniformName,
    );
    _gl.useProgram(program);
    _bindSamplerIfActive(program, GpuAtlasShaders.atlasSamplerName, 0);
    _gl.useProgram(null);
    return true;
  }

  web.WebGLShader? _compileInlineShader(int type, String source) {
    final shader = _gl.createShader(type);
    if (shader == null) return null;
    _gl.shaderSource(shader, source);
    _gl.compileShader(shader);
    if (!_asJsBool(
      _gl.getShaderParameter(shader, web.WebGL2RenderingContext.COMPILE_STATUS),
    )) {
      _gl.deleteShader(shader);
      return null;
    }
    return shader;
  }

  bool _initDirectAtlasBuffers() {
    final unitVbo = _gl.createBuffer();
    final instVbo = _gl.createBuffer();
    final atlasVao = _gl.createVertexArray();
    final singleVbo = _gl.createBuffer();
    final singleVao = _gl.createVertexArray();
    if (unitVbo == null ||
        instVbo == null ||
        atlasVao == null ||
        singleVbo == null ||
        singleVao == null) {
      if (unitVbo != null) _gl.deleteBuffer(unitVbo);
      if (instVbo != null) _gl.deleteBuffer(instVbo);
      if (atlasVao != null) _gl.deleteVertexArray(atlasVao);
      if (singleVbo != null) _gl.deleteBuffer(singleVbo);
      if (singleVao != null) _gl.deleteVertexArray(singleVao);
      return false;
    }

    _gl.bindBuffer(web.WebGL2RenderingContext.ARRAY_BUFFER, unitVbo);
    _gl.bufferData(
      web.WebGL2RenderingContext.ARRAY_BUFFER,
      GpuAtlasShaders.unitQuadVertices.toJS,
      web.WebGL2RenderingContext.STATIC_DRAW,
    );

    const initialCapBytes = 256 * GpuAtlasQuadBatch.bytesPerInstance;
    _gl.bindBuffer(web.WebGL2RenderingContext.ARRAY_BUFFER, instVbo);
    _gl.bufferData(
      web.WebGL2RenderingContext.ARRAY_BUFFER,
      initialCapBytes.toJS,
      web.WebGL2RenderingContext.DYNAMIC_DRAW,
    );

    _gl.bindBuffer(web.WebGL2RenderingContext.ARRAY_BUFFER, singleVbo);
    _gl.bufferData(
      web.WebGL2RenderingContext.ARRAY_BUFFER,
      GpuAtlasQuadBatch.bytesPerInstance.toJS,
      web.WebGL2RenderingContext.DYNAMIC_DRAW,
    );

    _configureInstancedQuadVao(atlasVao, unitVbo, instVbo);
    _configureInstancedQuadVao(singleVao, unitVbo, singleVbo);

    _atlasUnitQuadBuffer = unitVbo;
    _atlasInstanceBuffer = instVbo;
    _atlasInstanceCapBytes = initialCapBytes;
    _atlasVao = atlasVao;
    _singleQuadInstanceBuffer = singleVbo;
    _singleQuadVao = singleVao;
    return _initDynamicInstanceBuffers(unitVbo);
  }

  bool _initDynamicInstanceBuffers(web.WebGLBuffer unitVbo) {
    final xformVbo = _gl.createBuffer();
    final xformVao = _gl.createVertexArray();
    final maskVbo = _gl.createBuffer();
    final maskVao = _gl.createVertexArray();
    if (xformVbo == null ||
        xformVao == null ||
        maskVbo == null ||
        maskVao == null) {
      if (xformVbo != null) _gl.deleteBuffer(xformVbo);
      if (xformVao != null) _gl.deleteVertexArray(xformVao);
      if (maskVbo != null) _gl.deleteBuffer(maskVbo);
      if (maskVao != null) _gl.deleteVertexArray(maskVao);
      return false;
    }
    const dynCapBytes = 64 * GpuAtlasQuadBatch.bytesPerInstance;
    _gl.bindBuffer(web.WebGL2RenderingContext.ARRAY_BUFFER, xformVbo);
    _gl.bufferData(
      web.WebGL2RenderingContext.ARRAY_BUFFER,
      dynCapBytes.toJS,
      web.WebGL2RenderingContext.DYNAMIC_DRAW,
    );
    _gl.bindBuffer(web.WebGL2RenderingContext.ARRAY_BUFFER, maskVbo);
    _gl.bufferData(
      web.WebGL2RenderingContext.ARRAY_BUFFER,
      dynCapBytes.toJS,
      web.WebGL2RenderingContext.DYNAMIC_DRAW,
    );
    _configureInstancedQuadVao(xformVao, unitVbo, xformVbo);
    _configureInstancedQuadVao(maskVao, unitVbo, maskVbo);
    _transformedInstanceBuffer = xformVbo;
    _transformedVao = xformVao;
    _transformedInstanceCapBytes = dynCapBytes;
    _regionMaskInstanceBuffer = maskVbo;
    _regionMaskVao = maskVao;
    _regionMaskInstanceCapBytes = dynCapBytes;
    return true;
  }

  void _configureInstancedQuadVao(
    web.WebGLVertexArrayObject vao,
    web.WebGLBuffer unitVbo,
    web.WebGLBuffer instanceVbo,
  ) {
    _gl.bindVertexArray(vao);
    _gl.bindBuffer(web.WebGL2RenderingContext.ARRAY_BUFFER, unitVbo);
    _gl.enableVertexAttribArray(0);
    _gl.vertexAttribPointer(
      0,
      2,
      web.WebGL2RenderingContext.FLOAT,
      false,
      0,
      0,
    );
    _gl.vertexAttribDivisor(0, 0);

    _gl.bindBuffer(web.WebGL2RenderingContext.ARRAY_BUFFER, instanceVbo);
    _bindInstanceAttribOffsets(0);
    for (var loc = 1; loc <= 4; loc++) {
      _gl.enableVertexAttribArray(loc);
      _gl.vertexAttribDivisor(loc, 1);
    }
    _gl.bindVertexArray(null);
    _gl.bindBuffer(web.WebGL2RenderingContext.ARRAY_BUFFER, null);
  }

  void _bindInstanceAttribOffsets(int startInstance) {
    const stride = GpuAtlasQuadBatch.bytesPerInstance;
    final baseOffset = startInstance * stride;
    for (var loc = 1; loc <= 4; loc++) {
      _gl.vertexAttribPointer(
        loc,
        4,
        web.WebGL2RenderingContext.FLOAT,
        false,
        stride,
        baseOffset + (loc - 1) * 16,
      );
    }
  }

  bool _renderDirectBackgroundStage({
    required List<ShaderPassInvocation> backgroundPasses,
    required ui.Image? wallpaperImage,
    required web.WebGLFramebuffer? sceneFbo,
    required int width,
    required int height,
  }) {
    final tracing = ShaderPerfTrace.isEnabled;
    final spanStart = tracing
        ? ShaderPerfTrace.beginSpan('WebGl2.bgPasses')
        : 0;
    try {
      if (backgroundPasses.isNotEmpty) {
        return _executePasses(
          backgroundPasses,
          width: width,
          height: height,
          hasInputTexture: false,
          hasWallpaperTexture: wallpaperImage != null,
          finalFramebuffer: sceneFbo,
        );
      }

      _gl.bindFramebuffer(web.WebGL2RenderingContext.FRAMEBUFFER, sceneFbo);
      _gl.viewport(0, 0, width, height);
      _gl.clearColor(0.0, 0.0, 0.0, 0.0);
      _gl.clear(web.WebGL2RenderingContext.COLOR_BUFFER_BIT);
      if (wallpaperImage == null || _wallpaperTexture == null) return true;

      final uv = GpuAtlasShaders.computeCoverUvRect(
        imageWidth: wallpaperImage.width.toDouble(),
        imageHeight: wallpaperImage.height.toDouble(),
        viewportWidth: width.toDouble(),
        viewportHeight: height.toDouble(),
      );
      GpuAtlasShaders.writeTexturedQuadInstance(
        _singleQuadScratch,
        dstX: 0.0,
        dstY: 0.0,
        dstWidth: width.toDouble(),
        dstHeight: height.toDouble(),
        u0: uv.u0,
        v0: uv.v0,
        u1: uv.u1,
        v1: uv.v1,
      );
      _gl.useProgram(_atlasProgram);
      _gl.uniform2f(_atlasViewportLoc, width.toDouble(), height.toDouble());
      _drawSingleTexturedQuad(_wallpaperTexture!);
      _gl.bindVertexArray(null);
      _gl.useProgram(null);
      _unbindSamplerTextures();
      return true;
    } finally {
      if (tracing) {
        ShaderPerfTrace.endSpan('WebGl2.bgPasses', spanStart);
      }
    }
  }

  void _renderDirectTerminalStage({
    required GpuAtlasQuadBatch batch,
    required web.WebGLFramebuffer? sceneFbo,
    required int width,
    required int height,
    required bool hasWallpaperTexture,
  }) {
    if (batch.regionPasses.isEmpty && _regionTargets.length > 0) {
      _regionTargets.removePane(
        batch.paneKey,
        invokeOnDelete: !_isContextUnavailable,
      );
    }
    if (batch.instanceCount <= 0 &&
        batch.kittyQuads.isEmpty &&
        batch.transformedInstanceCount <= 0 &&
        batch.regionPasses.isEmpty) {
      return;
    }

    _uploadDirectInstanceBuffers(batch);
    final tracing = ShaderPerfTrace.isEnabled;
    final passStart = tracing
        ? ShaderPerfTrace.beginSpan('WebGl2.atlasPass')
        : 0;
    _bindDirectSceneBlendState(sceneFbo, width, height);

    try {
      _drawDirectTerminalSlices(
        batch: batch,
        sceneFbo: sceneFbo,
        width: width,
        height: height,
        hasWallpaperTexture: hasWallpaperTexture,
      );
    } finally {
      _gl.disable(web.WebGL2RenderingContext.BLEND);
      _gl.bindVertexArray(null);
      _gl.useProgram(null);
      _unbindSamplerTextures();
      if (tracing) {
        ShaderPerfTrace.endSpan('WebGl2.atlasPass', passStart);
      }
    }
  }

  void _uploadDirectInstanceBuffers(GpuAtlasQuadBatch batch) {
    final tracing = ShaderPerfTrace.isEnabled;
    final uploadStart = tracing
        ? ShaderPerfTrace.beginSpan('WebGl2.instanceUpload')
        : 0;
    try {
      _uploadAtlasInstancesIfNeeded(batch);
      _uploadTransformedInstancesIfNeeded(batch);
      _uploadRegionMaskInstancesIfNeeded(batch);
    } finally {
      if (tracing) {
        ShaderPerfTrace.endSpan('WebGl2.instanceUpload', uploadStart);
      }
    }
  }

  void _drawDirectTerminalSlices({
    required GpuAtlasQuadBatch batch,
    required web.WebGLFramebuffer? sceneFbo,
    required int width,
    required int height,
    required bool hasWallpaperTexture,
  }) {
    final bgEnd = batch.bgEndInstanceIndex.clamp(
      0,
      batch.italicStartInstanceIndex,
    );
    final italicStart = batch.italicStartInstanceIndex;
    final kittySplit = batch.kittyInsertInstanceIndex;
    final total = batch.instanceCount;
    final underXform = batch.transformedUnderGlyphCount.clamp(
      0,
      batch.transformedInstanceCount,
    );

    if (bgEnd > 0) {
      _drawAtlasSlice(0, bgEnd, filter: web.WebGL2RenderingContext.NEAREST);
    }
    _renderDirectRegionStage(
      batch: batch,
      stageFilter: ShaderRegionStage.underGlyphs,
      sceneFbo: sceneFbo,
      width: width,
      height: height,
      hasWallpaperTexture: hasWallpaperTexture,
    );
    if (underXform > 0) {
      _drawTransformedSlice(0, underXform);
    }
    if (italicStart > bgEnd) {
      _drawAtlasSlice(
        bgEnd,
        italicStart - bgEnd,
        filter: web.WebGL2RenderingContext.NEAREST,
      );
    }
    if (kittySplit > italicStart) {
      _drawAtlasSlice(
        italicStart,
        kittySplit - italicStart,
        filter: web.WebGL2RenderingContext.LINEAR,
      );
    }
    if (batch.kittyQuads.isNotEmpty) {
      _drawKittyQuads(batch.kittyQuads);
    }
    if (total > kittySplit) {
      _drawAtlasSlice(
        kittySplit,
        total - kittySplit,
        filter: web.WebGL2RenderingContext.NEAREST,
      );
    }
    if (batch.transformedInstanceCount > underXform) {
      _drawTransformedSlice(
        underXform,
        batch.transformedInstanceCount - underXform,
      );
    }
    _renderDirectRegionStage(
      batch: batch,
      stageFilter: ShaderRegionStage.replaceGlyphs,
      sceneFbo: sceneFbo,
      width: width,
      height: height,
      hasWallpaperTexture: hasWallpaperTexture,
    );
    _renderDirectRegionStage(
      batch: batch,
      stageFilter: ShaderRegionStage.overGlyphs,
      sceneFbo: sceneFbo,
      width: width,
      height: height,
      hasWallpaperTexture: hasWallpaperTexture,
    );
  }

  void _bindDirectSceneBlendState(
    web.WebGLFramebuffer? sceneFbo,
    int width,
    int height,
  ) {
    _gl.bindFramebuffer(web.WebGL2RenderingContext.FRAMEBUFFER, sceneFbo);
    _gl.viewport(0, 0, width, height);
    _gl.enable(web.WebGL2RenderingContext.BLEND);
    _gl.blendFunc(
      web.WebGL2RenderingContext.ONE,
      web.WebGL2RenderingContext.ONE_MINUS_SRC_ALPHA,
    );
    _gl.useProgram(_atlasProgram);
    _gl.uniform2f(_atlasViewportLoc, width.toDouble(), height.toDouble());
  }

  void _renderDirectRegionStage({
    required GpuAtlasQuadBatch batch,
    required ShaderRegionStage stageFilter,
    required web.WebGLFramebuffer? sceneFbo,
    required int width,
    required int height,
    required bool hasWallpaperTexture,
  }) {
    if (batch.regionPasses.isEmpty) return;
    var renderedAny = false;
    for (final regionPass in batch.regionPasses) {
      if (regionPass.stage != stageFilter) continue;
      final slice = _findRegionMaskSlice(
        batch.regionMaskSlices,
        regionPass.regionId,
      );
      if (slice == null) continue;
      _executeAndCompositeRegionPass(
        batch: batch,
        regionPass: regionPass,
        slice: slice,
        sceneFbo: sceneFbo,
        sceneWidth: width,
        sceneHeight: height,
        hasWallpaperTexture: hasWallpaperTexture,
      );
      renderedAny = true;
    }
    if (renderedAny) {
      _bindDirectSceneBlendState(sceneFbo, width, height);
    }
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

  void _executeAndCompositeRegionPass({
    required GpuAtlasQuadBatch batch,
    required ShaderRegionPassInvocation regionPass,
    required GpuRegionMaskSlice slice,
    required web.WebGLFramebuffer? sceneFbo,
    required int sceneWidth,
    required int sceneHeight,
    required bool hasWallpaperTexture,
  }) {
    final mw = regionPass.outputRectPhysical.width.round();
    final mh = regionPass.outputRectPhysical.height.round();
    if (mw <= 0 || mh <= 0) return;

    final acquired = _regionTargets.acquire(
      paneKey: batch.paneKey,
      regionId: regionPass.regionId,
      width: mw,
      height: mh,
      maskData: batch.regionMaskInstanceData,
      maskGeneration: batch.regionMaskGeneration,
      startInstance: slice.startInstance,
      instanceCount: slice.instanceCount,
      atlasToken: _atlasTexture,
      createTarget: _createFboTarget,
    );
    if (acquired == null) return;
    final targets = acquired.entry;

    if (!acquired.maskCacheHit) {
      // 1. Render only glyphs inside sourceRects into tight uGlyphMask FBO.
      _gl.bindFramebuffer(
        web.WebGL2RenderingContext.FRAMEBUFFER,
        targets.mask.framebuffer,
      );
      _gl.viewport(0, 0, mw, mh);
      _gl.clearColor(0.0, 0.0, 0.0, 0.0);
      _gl.clear(web.WebGL2RenderingContext.COLOR_BUFFER_BIT);
      if (slice.instanceCount > 0) {
        _gl.enable(web.WebGL2RenderingContext.BLEND);
        _gl.blendFunc(
          web.WebGL2RenderingContext.ONE,
          web.WebGL2RenderingContext.ONE_MINUS_SRC_ALPHA,
        );
        _gl.useProgram(_atlasProgram);
        _gl.uniform2f(_atlasViewportLoc, mw.toDouble(), mh.toDouble());
        _drawRegionMaskSlice(slice.startInstance, slice.instanceCount);
        _gl.disable(web.WebGL2RenderingContext.BLEND);
      }
      _gl.bindVertexArray(null);
      _gl.useProgram(null);
      _unbindSamplerTextures();

      // 2. Flip uGlyphMask into top-left origin matching ShadertoyGlslShim.
      _blitFramebuffer(
        targets.mask.framebuffer,
        targets.maskFlipped.framebuffer,
        width: mw,
        height: mh,
        flipY: true,
      );
    }

    // 3. Execute region fragment shader synchronously with prevFrameKey.
    final ok = _executeSinglePass(
      regionPass.toPassInvocation(),
      passIndex: 0,
      isLast: true,
      width: mw,
      height: mh,
      hasInputTexture: true,
      hasWallpaperTexture: hasWallpaperTexture,
      initialChannel0: targets.maskFlipped.texture,
      finalFramebuffer: targets.out.framebuffer,
    );
    if (!ok) return;

    // 4. Composite tight region output onto sceneFbo at outputRectPhysical.
    _bindDirectSceneBlendState(sceneFbo, sceneWidth, sceneHeight);
    final dst = regionPass.outputRectPhysical;
    GpuAtlasShaders.writeTexturedQuadInstance(
      _singleQuadScratch,
      dstX: dst.left,
      dstY: dst.top,
      dstWidth: dst.width,
      dstHeight: dst.height,
      u0: 0.0,
      v0: 1.0,
      u1: 1.0,
      v1: 0.0,
    );
    _drawSingleTexturedQuad(targets.out.texture);
  }

  void _uploadTransformedInstancesIfNeeded(GpuAtlasQuadBatch batch) {
    final count = batch.transformedInstanceCount;
    if (count <= 0) return;
    if (identical(batch.transformedInstanceData, _uploadedTransformedData) &&
        batch.transformedGeneration == _uploadedTransformedGeneration &&
        count == _uploadedTransformedCount) {
      return;
    }
    _transformedInstanceCapBytes = _uploadDynamicInstanceBuffer(
      buffer: _transformedInstanceBuffer,
      currentCapBytes: _transformedInstanceCapBytes,
      data: batch.transformedInstanceData,
      count: count,
    );
    _uploadedTransformedData = batch.transformedInstanceData;
    _uploadedTransformedGeneration = batch.transformedGeneration;
    _uploadedTransformedCount = count;
  }

  void _uploadRegionMaskInstancesIfNeeded(GpuAtlasQuadBatch batch) {
    final count = batch.regionMaskInstanceCount;
    if (count <= 0) return;
    if (identical(batch.regionMaskInstanceData, _uploadedRegionMaskData) &&
        batch.regionMaskGeneration == _uploadedRegionMaskGeneration &&
        count == _uploadedRegionMaskCount) {
      return;
    }
    _regionMaskInstanceCapBytes = _uploadDynamicInstanceBuffer(
      buffer: _regionMaskInstanceBuffer,
      currentCapBytes: _regionMaskInstanceCapBytes,
      data: batch.regionMaskInstanceData,
      count: count,
    );
    _uploadedRegionMaskData = batch.regionMaskInstanceData;
    _uploadedRegionMaskGeneration = batch.regionMaskGeneration;
    _uploadedRegionMaskCount = count;
  }

  int _uploadDynamicInstanceBuffer({
    required web.WebGLBuffer? buffer,
    required int currentCapBytes,
    required Float32List data,
    required int count,
  }) {
    final byteLength = count * GpuAtlasQuadBatch.bytesPerInstance;
    final activeSlice = Float32List.sublistView(
      data,
      0,
      count * GpuAtlasQuadBatch.floatsPerInstance,
    );
    _gl.bindBuffer(web.WebGL2RenderingContext.ARRAY_BUFFER, buffer);
    var cap = currentCapBytes;
    if (byteLength > cap) {
      cap = cap == 0 ? byteLength : cap;
      while (cap < byteLength) {
        cap <<= 1;
      }
      _gl.bufferData(
        web.WebGL2RenderingContext.ARRAY_BUFFER,
        cap.toJS,
        web.WebGL2RenderingContext.DYNAMIC_DRAW,
      );
    }
    _gl.bufferSubData(
      web.WebGL2RenderingContext.ARRAY_BUFFER,
      0,
      activeSlice.toJS,
    );
    _gl.bindBuffer(web.WebGL2RenderingContext.ARRAY_BUFFER, null);
    return cap;
  }

  void _drawTransformedSlice(int startInstance, int count) {
    final atlasTex = _atlasTexture;
    if (atlasTex == null || count <= 0) return;
    _bindAtlasTextureWithFilter(atlasTex, web.WebGL2RenderingContext.LINEAR);
    _gl.bindVertexArray(_transformedVao);
    _gl.bindBuffer(
      web.WebGL2RenderingContext.ARRAY_BUFFER,
      _transformedInstanceBuffer,
    );
    _bindInstanceAttribOffsets(startInstance);
    _gl.drawArraysInstanced(web.WebGL2RenderingContext.TRIANGLES, 0, 6, count);
  }

  void _drawRegionMaskSlice(int startInstance, int count) {
    final atlasTex = _atlasTexture;
    if (atlasTex == null || count <= 0) return;
    _bindAtlasTextureWithFilter(atlasTex, web.WebGL2RenderingContext.LINEAR);
    _gl.bindVertexArray(_regionMaskVao);
    _gl.bindBuffer(
      web.WebGL2RenderingContext.ARRAY_BUFFER,
      _regionMaskInstanceBuffer,
    );
    _bindInstanceAttribOffsets(startInstance);
    _gl.drawArraysInstanced(web.WebGL2RenderingContext.TRIANGLES, 0, 6, count);
  }

  void _bindAtlasTextureWithFilter(web.WebGLTexture atlasTex, int filter) {
    _gl.activeTexture(web.WebGL2RenderingContext.TEXTURE0);
    _gl.bindTexture(web.WebGL2RenderingContext.TEXTURE_2D, atlasTex);
    if (_atlasFilterMode != filter) {
      _gl.texParameteri(
        web.WebGL2RenderingContext.TEXTURE_2D,
        web.WebGL2RenderingContext.TEXTURE_MIN_FILTER,
        filter,
      );
      _gl.texParameteri(
        web.WebGL2RenderingContext.TEXTURE_2D,
        web.WebGL2RenderingContext.TEXTURE_MAG_FILTER,
        filter,
      );
      _atlasFilterMode = filter;
    }
  }

  List<String> _collectActiveCustomShaderIds(
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

  void _pollPendingTimerQuery() {
    final query = _pendingTimerQuery;
    if (query == null || !_hasTimerQueryExt) return;
    final available = _asJsBool(
      _gl.getQueryParameter(
        query,
        web.WebGL2RenderingContext.QUERY_RESULT_AVAILABLE,
      ),
    );
    if (!available) return;
    final disjoint = _asJsBool(
      _gl.getParameter(web.EXT_disjoint_timer_query_webgl2.GPU_DISJOINT_EXT),
    );
    final rawNs = _gl.getQueryParameter(
      query,
      web.WebGL2RenderingContext.QUERY_RESULT,
    );
    final ns = rawNs != null && rawNs.isA<JSNumber>()
        ? (rawNs as JSNumber).toDartInt
        : -1;
    final ids = _pendingTimerShaderIds;
    final targetWatchdog = _pendingTimerWatchdog;
    _pendingTimerQuery = null;
    _pendingTimerShaderIds = const <String>[];
    _pendingTimerWatchdog = null;
    _gl.deleteQuery(query);
    if (ns < 0 || disjoint) return;
    final elapsedUs = ns ~/ 1000;
    _lastGpuCompletionUs = elapsedUs;
    if (ShaderPerfTrace.isEnabled) {
      ShaderPerfTrace.recordDurationUs('WebGl2.gpuTimer', elapsedUs);
    }
    if (ids.isNotEmpty) {
      targetWatchdog?.recordWebGlTimerQueryResult(
        ns,
        customShaderIds: ids,
        disjoint: false,
      );
    }
  }

  web.WebGLQuery? _beginTimerQueryIfNeeded(
    GpuFrameWatchdog? wd,
    List<String> customIds,
  ) {
    if (!_hasTimerQueryExt || _pendingTimerQuery != null) {
      return null;
    }
    final needsWatchdog = wd != null && customIds.isNotEmpty;
    if (!needsWatchdog && !ShaderPerfTrace.isEnabled) {
      return null;
    }
    final query = _gl.createQuery();
    if (query == null) return null;
    _gl.beginQuery(web.EXT_disjoint_timer_query_webgl2.TIME_ELAPSED_EXT, query);
    return query;
  }

  void _endTimerQuery(
    web.WebGLQuery? query,
    GpuFrameWatchdog? wd,
    List<String> customIds,
  ) {
    if (query == null) return;
    _gl.endQuery(web.EXT_disjoint_timer_query_webgl2.TIME_ELAPSED_EXT);
    _pendingTimerQuery = query;
    _pendingTimerShaderIds = customIds;
    _pendingTimerWatchdog = wd;
  }

  void _uploadAtlasInstancesIfNeeded(GpuAtlasQuadBatch batch) {
    final count = batch.instanceCount;
    if (count <= 0) return;
    if (identical(batch.instanceData, _uploadedInstanceData) &&
        batch.generation == _uploadedGeneration &&
        count == _uploadedInstanceCount) {
      return;
    }

    final byteLength = count * GpuAtlasQuadBatch.bytesPerInstance;
    final activeFloats = count * GpuAtlasQuadBatch.floatsPerInstance;
    final activeSlice = Float32List.sublistView(
      batch.instanceData,
      0,
      activeFloats,
    );
    _gl.bindBuffer(
      web.WebGL2RenderingContext.ARRAY_BUFFER,
      _atlasInstanceBuffer,
    );
    if (byteLength > _atlasInstanceCapBytes) {
      var nextCap = _atlasInstanceCapBytes == 0
          ? byteLength
          : _atlasInstanceCapBytes;
      while (nextCap < byteLength) {
        nextCap <<= 1;
      }
      _gl.bufferData(
        web.WebGL2RenderingContext.ARRAY_BUFFER,
        nextCap.toJS,
        web.WebGL2RenderingContext.DYNAMIC_DRAW,
      );
      _atlasInstanceCapBytes = nextCap;
    }
    _gl.bufferSubData(
      web.WebGL2RenderingContext.ARRAY_BUFFER,
      0,
      activeSlice.toJS,
    );
    _gl.bindBuffer(web.WebGL2RenderingContext.ARRAY_BUFFER, null);
    _uploadedInstanceData = batch.instanceData;
    _uploadedGeneration = batch.generation;
    _uploadedInstanceCount = count;
  }

  void _drawAtlasSlice(int startInstance, int count, {required int filter}) {
    final atlasTex = _atlasTexture;
    if (atlasTex == null || count <= 0) return;
    _gl.activeTexture(web.WebGL2RenderingContext.TEXTURE0);
    _gl.bindTexture(web.WebGL2RenderingContext.TEXTURE_2D, atlasTex);
    if (_atlasFilterMode != filter) {
      _gl.texParameteri(
        web.WebGL2RenderingContext.TEXTURE_2D,
        web.WebGL2RenderingContext.TEXTURE_MIN_FILTER,
        filter,
      );
      _gl.texParameteri(
        web.WebGL2RenderingContext.TEXTURE_2D,
        web.WebGL2RenderingContext.TEXTURE_MAG_FILTER,
        filter,
      );
      _atlasFilterMode = filter;
    }
    _gl.bindVertexArray(_atlasVao);
    _gl.bindBuffer(
      web.WebGL2RenderingContext.ARRAY_BUFFER,
      _atlasInstanceBuffer,
    );
    _bindInstanceAttribOffsets(startInstance);
    _gl.drawArraysInstanced(web.WebGL2RenderingContext.TRIANGLES, 0, 6, count);
  }

  void _drawKittyQuads(List<GpuKittyQuad> quads) {
    for (final quad in quads) {
      final cached = _kittyTextures.remove(quad.image);
      if (cached == null) continue;
      _kittyTextures[quad.image] = cached;
      GpuAtlasShaders.writeTexturedQuadInstance(
        _singleQuadScratch,
        dstX: quad.dstX,
        dstY: quad.dstY,
        dstWidth: quad.dstWidth,
        dstHeight: quad.dstHeight,
        u0: quad.u0,
        v0: quad.v0,
        u1: quad.u1,
        v1: quad.v1,
      );
      _drawSingleTexturedQuad(cached.texture);
    }
  }

  void _drawSingleTexturedQuad(web.WebGLTexture texture) {
    _gl.activeTexture(web.WebGL2RenderingContext.TEXTURE0);
    _gl.bindTexture(web.WebGL2RenderingContext.TEXTURE_2D, texture);
    _gl.bindVertexArray(_singleQuadVao);
    _gl.bindBuffer(
      web.WebGL2RenderingContext.ARRAY_BUFFER,
      _singleQuadInstanceBuffer,
    );
    _gl.bufferSubData(
      web.WebGL2RenderingContext.ARRAY_BUFFER,
      0,
      _singleQuadScratch.toJS,
    );
    _gl.drawArraysInstanced(web.WebGL2RenderingContext.TRIANGLES, 0, 6, 1);
  }

  _GlFboTarget? _createFboTarget(int width, int height) {
    final texture = _createConfiguredTexture();
    final fbo = _gl.createFramebuffer();
    if (texture == null || fbo == null) {
      if (texture != null) _gl.deleteTexture(texture);
      if (fbo != null) _gl.deleteFramebuffer(fbo);
      return null;
    }
    _gl.bindTexture(web.WebGL2RenderingContext.TEXTURE_2D, texture);
    _gl.texImage2D(
      web.WebGL2RenderingContext.TEXTURE_2D,
      0,
      web.WebGL2RenderingContext.RGBA8,
      width.toJS,
      height.toJS,
      0.toJS,
      web.WebGL2RenderingContext.RGBA,
      web.WebGL2RenderingContext.UNSIGNED_BYTE,
      null,
    );
    _gl.bindFramebuffer(web.WebGL2RenderingContext.FRAMEBUFFER, fbo);
    _gl.framebufferTexture2D(
      web.WebGL2RenderingContext.FRAMEBUFFER,
      web.WebGL2RenderingContext.COLOR_ATTACHMENT0,
      web.WebGL2RenderingContext.TEXTURE_2D,
      texture,
      0,
    );
    final status = _gl.checkFramebufferStatus(
      web.WebGL2RenderingContext.FRAMEBUFFER,
    );
    if (status != web.WebGL2RenderingContext.FRAMEBUFFER_COMPLETE) {
      _gl.bindFramebuffer(web.WebGL2RenderingContext.FRAMEBUFFER, null);
      _gl.bindTexture(web.WebGL2RenderingContext.TEXTURE_2D, null);
      _gl.deleteFramebuffer(fbo);
      _gl.deleteTexture(texture);
      return null;
    }
    _gl.viewport(0, 0, width, height);
    _gl.clearColor(0.0, 0.0, 0.0, 0.0);
    _gl.clear(web.WebGL2RenderingContext.COLOR_BUFFER_BIT);
    _gl.bindFramebuffer(web.WebGL2RenderingContext.FRAMEBUFFER, null);
    _gl.bindTexture(web.WebGL2RenderingContext.TEXTURE_2D, null);
    return _GlFboTarget(
      framebuffer: fbo,
      texture: texture,
      width: width,
      height: height,
    );
  }

  Future<RgbaImagePixels?> _readImageRgba(ui.Image? image) =>
      readImageRgbaSafely(image);

  bool _syncInputTexture(
    ui.Image? image,
    RgbaImagePixels? data,
    bool needsUpload,
  ) {
    if (image == null) {
      _cachedInputImage = null;
      return false;
    }
    if (!needsUpload) {
      return _inputTexture != null;
    }
    if (data == null) return false;
    final uploaded = _uploadRgbaTexture(
      existing: _inputTexture,
      existingWidth: _inputWidth,
      existingHeight: _inputHeight,
      width: data.width,
      height: data.height,
      rgbaData: data.bytes,
    );
    if (uploaded == null) return false;
    _inputTexture = uploaded;
    _inputWidth = data.width;
    _inputHeight = data.height;
    _cachedInputImage = image;
    return true;
  }

  bool _syncWallpaperTexture(
    ui.Image? image,
    RgbaImagePixels? data,
    bool needsUpload,
  ) {
    if (image == null) {
      _cachedWallpaperImage = null;
      return false;
    }
    if (!needsUpload) {
      return _wallpaperTexture != null;
    }
    if (data == null) return false;
    final uploaded = _uploadRgbaTexture(
      existing: _wallpaperTexture,
      existingWidth: _wallpaperWidth,
      existingHeight: _wallpaperHeight,
      width: data.width,
      height: data.height,
      rgbaData: data.bytes,
    );
    if (uploaded == null) return false;
    _wallpaperTexture = uploaded;
    _wallpaperWidth = data.width;
    _wallpaperHeight = data.height;
    _cachedWallpaperImage = image;
    return true;
  }

  web.WebGLTexture? _uploadRgbaTexture({
    required web.WebGLTexture? existing,
    required int existingWidth,
    required int existingHeight,
    required int width,
    required int height,
    required ByteData rgbaData,
  }) {
    if (width <= 0 || height <= 0) return null;
    final expectedBytes = width * height * 4;
    if (rgbaData.lengthInBytes < expectedBytes) return null;

    final texture = existing ?? _createConfiguredTexture();
    if (texture == null) return null;
    final pixels = rgbaData.buffer.asUint8List(
      rgbaData.offsetInBytes,
      expectedBytes,
    );

    _gl.bindTexture(web.WebGL2RenderingContext.TEXTURE_2D, texture);
    if (existing != null &&
        existingWidth == width &&
        existingHeight == height) {
      _gl.texSubImage2D(
        web.WebGL2RenderingContext.TEXTURE_2D,
        0,
        0,
        0,
        width.toJS,
        height.toJS,
        web.WebGL2RenderingContext.RGBA.toJS,
        web.WebGL2RenderingContext.UNSIGNED_BYTE,
        pixels.toJS,
      );
    } else {
      _gl.texImage2D(
        web.WebGL2RenderingContext.TEXTURE_2D,
        0,
        web.WebGL2RenderingContext.RGBA,
        width.toJS,
        height.toJS,
        0.toJS,
        web.WebGL2RenderingContext.RGBA,
        web.WebGL2RenderingContext.UNSIGNED_BYTE,
        pixels.toJS,
      );
    }
    _gl.bindTexture(web.WebGL2RenderingContext.TEXTURE_2D, null);
    return texture;
  }

  web.WebGLTexture? _createConfiguredTexture() {
    final texture = _gl.createTexture();
    if (texture == null) return null;
    _gl.bindTexture(web.WebGL2RenderingContext.TEXTURE_2D, texture);
    _gl.texParameteri(
      web.WebGL2RenderingContext.TEXTURE_2D,
      web.WebGL2RenderingContext.TEXTURE_WRAP_S,
      web.WebGL2RenderingContext.CLAMP_TO_EDGE,
    );
    _gl.texParameteri(
      web.WebGL2RenderingContext.TEXTURE_2D,
      web.WebGL2RenderingContext.TEXTURE_WRAP_T,
      web.WebGL2RenderingContext.CLAMP_TO_EDGE,
    );
    _gl.texParameteri(
      web.WebGL2RenderingContext.TEXTURE_2D,
      web.WebGL2RenderingContext.TEXTURE_MIN_FILTER,
      web.WebGL2RenderingContext.LINEAR,
    );
    _gl.texParameteri(
      web.WebGL2RenderingContext.TEXTURE_2D,
      web.WebGL2RenderingContext.TEXTURE_MAG_FILTER,
      web.WebGL2RenderingContext.LINEAR,
    );
    _gl.bindTexture(web.WebGL2RenderingContext.TEXTURE_2D, null);
    return texture;
  }

  ui.Image? _exportCanvasImageSync() {
    final tracing = ShaderPerfTrace.isEnabled;
    final transferStart = tracing
        ? ShaderPerfTrace.beginSpan('WebGl2.transferBitmap')
        : 0;
    final web.ImageBitmap bitmap;
    try {
      bitmap = _canvas.transferToImageBitmap();
    } finally {
      if (tracing) {
        ShaderPerfTrace.endSpan('WebGl2.transferBitmap', transferStart);
      }
    }
    final createStart = tracing
        ? ShaderPerfTrace.beginSpan('WebGl2.createImage')
        : 0;
    try {
      final imageOrFuture = ui_web.createImageFromImageBitmap(bitmap);
      if (imageOrFuture is ui.Image) {
        return imageOrFuture;
      }
      unawaited(imageOrFuture.then((image) => image.dispose()));
      return null;
    } on Object {
      bitmap.close();
      return null;
    } finally {
      if (tracing) {
        ShaderPerfTrace.endSpan('WebGl2.createImage', createStart);
      }
    }
  }

  Future<ui.Image?> _exportCanvasImageAsync() async {
    final bitmap = _canvas.transferToImageBitmap();
    try {
      return await ui_web.createImageFromImageBitmap(bitmap);
    } on Object {
      bitmap.close();
      return null;
    }
  }

  static (int, int)? _resolveDimensions(ui.Size physicalSize) {
    if (!physicalSize.width.isFinite || !physicalSize.height.isFinite) {
      return null;
    }
    final width = physicalSize.width.round();
    final height = physicalSize.height.round();
    if (width <= 0 || height <= 0) return null;
    return (width, height);
  }

  static bool _asJsBool(JSAny? value) =>
      value != null && value.isA<JSBoolean>() && (value as JSBoolean).toDart;

  static int _computePrefixLineOffset() {
    const sentinel = 'void mainImage(out vec4 fragColor, in vec2 fragCoord) {}';
    final shimmed = ShadertoyGlslShim.shim(sentinel);
    final idx = shimmed.webgl2FragmentGlsl.indexOf(sentinel);
    if (idx <= 0) return 0;
    var newlines = 0;
    for (var i = 0; i < idx; i++) {
      if (shimmed.webgl2FragmentGlsl.codeUnitAt(i) == 0x0A) {
        newlines++;
      }
    }
    return newlines;
  }

  static String _firstNonEmptyLine(String text) {
    for (final line in text.split('\n')) {
      final trimmed = line.trim();
      if (trimmed.isNotEmpty) return trimmed;
    }
    return '';
  }
}

final class _WebGl2ShaderHandle implements CompiledShaderHandle {
  final WebGl2ShaderBackend backend;

  @override
  final String id;

  final bool requestedPrevFrame;

  @override
  bool usesPrevFrame;

  String userSource;
  String webgl2FragmentGlsl;
  web.WebGLProgram? program;
  bool _disposed = false;

  _WebGl2ShaderHandle({
    required this.backend,
    required this.id,
    required this.requestedPrevFrame,
    required this.usesPrevFrame,
    required this.userSource,
    required this.webgl2FragmentGlsl,
    required this.program,
  });

  bool get isDisposed => _disposed;

  void markDisposed() {
    _disposed = true;
  }

  @override
  void dispose() {
    backend._disposeHandle(this);
  }
}

final class _GlCachedTexture {
  final web.WebGLTexture texture;
  final int width;
  final int height;

  const _GlCachedTexture({
    required this.texture,
    required this.width,
    required this.height,
  });
}

final class _GlFboTarget {
  final web.WebGLFramebuffer framebuffer;
  final web.WebGLTexture texture;
  final int width;
  final int height;

  const _GlFboTarget({
    required this.framebuffer,
    required this.texture,
    required this.width,
    required this.height,
  });

  bool matches(int targetWidth, int targetHeight) =>
      width == targetWidth && height == targetHeight;

  void delete(web.WebGL2RenderingContext gl) {
    gl.deleteFramebuffer(framebuffer);
    gl.deleteTexture(texture);
  }
}
