import 'dart:async';
import 'dart:collection';
import 'dart:js_interop';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'dart:ui_web' as ui_web;

import 'package:web/web.dart' as web;

import 'gpu_atlas_batch.dart';
import 'gpu_atlas_shaders.dart';
import 'shader_backend.dart';
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
final class WebGl2ShaderBackend implements DirectTerminalShaderBackend {
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
  static final RegExp _angleLinePattern = RegExp(
    r'(?:ERROR|WARNING):\s*\d+:(\d+):',
  );
  static final RegExp _mesaLinePattern = RegExp(
    r'^\s*\d+:(\d+)\s*(?:\(\d+\))?:',
    multiLine: true,
  );
  static final RegExp _genericLinePattern = RegExp(
    r'\bline\s+(\d+)\b',
    caseSensitive: false,
  );
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
  final Map<String, _GlPingPongTarget> _prevFrameTargets =
      <String, _GlPingPongTarget>{};

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

  _GlFboTarget? _scratchTarget;
  _GlFboTarget? _chainTarget;
  _GlFboTarget? _sceneTarget;

  bool _hasParallelCompile = false;
  bool _coreInitialized = false;
  bool _directAtlasInitialized = false;
  bool _directAtlasInitFailed = false;
  bool _contextLost = false;
  bool _disposed = false;

  WebGl2ShaderBackend._(this._canvas, this._gl) {
    _contextLostHandler = _onContextLost.toJS;
    _contextRestoredHandler = _onContextRestored.toJS;
    _canvas.addEventListener('webglcontextlost', _contextLostHandler);
    _canvas.addEventListener('webglcontextrestored', _contextRestoredHandler);
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
      program = await _compileAndLinkAsync(id, shimmed.webgl2FragmentGlsl);
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
    );
    if (_disposed || glHandle.isDisposed) {
      if (!_gl.isContextLost()) {
        _gl.deleteProgram(nextProgram);
      }
      return;
    }
    final previousProgram = glHandle.program;
    glHandle.program = nextProgram;
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
  }) {
    if (_isContextUnavailable || passes.isEmpty) return null;
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
  }) async {
    if (_isContextUnavailable || passes.isEmpty) return null;
    final dims = _resolveDimensions(physicalSize);
    if (dims == null) return null;

    final needsInputUpload =
        inputImage != null && !identical(inputImage, _cachedInputImage);
    final inputData = needsInputUpload
        ? await _readImageRgba(inputImage)
        : null;
    final needsWallpaperUpload =
        wallpaperImage != null &&
        !identical(wallpaperImage, _cachedWallpaperImage);
    final wallpaperData = needsWallpaperUpload
        ? await _readImageRgba(wallpaperImage)
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
  }) {
    if (_isContextUnavailable || _directAtlasInitFailed) return null;
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

    final hasForeground = foregroundPasses.isNotEmpty;
    if (hasForeground && !_ensureSceneTarget(width, height)) return null;
    final sceneFbo = hasForeground ? _sceneTarget!.framebuffer : null;

    if (!_renderDirectBackgroundStage(
      backgroundPasses: backgroundPasses,
      wallpaperImage: wallpaperImage,
      sceneFbo: sceneFbo,
      width: width,
      height: height,
    )) {
      return null;
    }

    _renderDirectTerminalStage(
      batch: batch,
      sceneFbo: sceneFbo,
      width: width,
      height: height,
    );

    if (hasForeground &&
        !_renderDirectForegroundStage(
          foregroundPasses: foregroundPasses,
          hasWallpaperTexture: wallpaperImage != null,
          width: width,
          height: height,
        )) {
      return null;
    }

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
    final prevTarget = _prevFrameTargets.remove(handle.id);
    if (prevTarget != null && canDelete) {
      prevTarget.delete(_gl);
    }
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
    _hasParallelCompile = false;
    _coreInitialized = false;
    _directAtlasInitialized = false;
  }

  void _deleteTransientTargets({required bool deleteObjects}) {
    if (deleteObjects) {
      _scratchTarget?.delete(_gl);
      _chainTarget?.delete(_gl);
      _sceneTarget?.delete(_gl);
      for (final target in _prevFrameTargets.values) {
        target.delete(_gl);
      }
    }
    _scratchTarget = null;
    _chainTarget = null;
    _sceneTarget = null;
    _prevFrameTargets.clear();
  }

  void _deleteCoreObjects() {
    if (_vertexShader != null) _gl.deleteShader(_vertexShader);
    if (_vao != null) _gl.deleteVertexArray(_vao);
    if (_vertexBuffer != null) _gl.deleteBuffer(_vertexBuffer);
    if (_ubo != null) _gl.deleteBuffer(_ubo);
    if (_dummyTexture != null) _gl.deleteTexture(_dummyTexture);
    if (_inputTexture != null) _gl.deleteTexture(_inputTexture);
    if (_wallpaperTexture != null) _gl.deleteTexture(_wallpaperTexture);
    if (_atlasProgram != null) _gl.deleteProgram(_atlasProgram);
    if (_atlasVao != null) _gl.deleteVertexArray(_atlasVao);
    if (_atlasUnitQuadBuffer != null) _gl.deleteBuffer(_atlasUnitQuadBuffer);
    if (_atlasInstanceBuffer != null) _gl.deleteBuffer(_atlasInstanceBuffer);
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
    String fragmentGlsl,
  ) async {
    final prepared = _startProgramLink(shaderId, fragmentGlsl);
    final program = prepared.$1;
    final fragShader = prepared.$2;
    try {
      if (_hasParallelCompile) {
        await _awaitParallelLinkCompletion(program);
      }
      return _finalizeProgramLink(shaderId, program, fragShader);
    } on Object {
      if (!_gl.isContextLost()) {
        _gl.deleteShader(fragShader);
        _gl.deleteProgram(program);
      }
      rethrow;
    }
  }

  web.WebGLProgram _compileAndLinkSync(String shaderId, String fragmentGlsl) {
    final prepared = _startProgramLink(shaderId, fragmentGlsl);
    final program = prepared.$1;
    final fragShader = prepared.$2;
    try {
      return _finalizeProgramLink(shaderId, program, fragShader);
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
    web.WebGLShader fragShader,
  ) {
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
      throw _buildCompileException(shaderId, program, fragShader);
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
    web.WebGLShader fragShader,
  ) {
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
    final trimmedLog = rawLog.trim();
    final lineNumber = _parseInfoLogLineNumber(trimmedLog);
    final firstLine = _firstNonEmptyLine(trimmedLog);
    return ShaderCompileException(
      shaderId: shaderId,
      message: firstLine.isEmpty
          ? 'WebGL2 shader compilation failed.'
          : firstLine,
      lineNumber: lineNumber,
      compilerLog: trimmedLog.isEmpty ? null : trimmedLog,
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
    final prevTarget = usesPrevFrame
        ? _ensurePrevFrameTarget(pass.prevFrameKey ?? handle.id, width, height)
        : null;
    if (usesPrevFrame && prevTarget == null) return false;

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
      prevFrame: prevTarget?.readTexture ?? _dummyTexture,
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
      prevTarget: prevTarget,
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
    required _GlPingPongTarget? prevTarget,
    web.WebGLFramebuffer? finalFramebuffer,
  }) {
    final scratch = _scratchTarget;
    if (scratch == null) return false;
    _unbindSamplerTextures();

    if (prevTarget != null) {
      _blitFramebuffer(
        scratch.framebuffer,
        prevTarget.writeFramebuffer,
        width: width,
        height: height,
        flipY: true,
      );
      prevTarget.swap();
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
    bool Function(ui.Image image, ByteData? data) uploader,
  ) {
    final existing = _primingInFlight[image];
    if (existing != null) return existing;
    final future = _primeImageOnce(image, uploader);
    _primingInFlight[image] = future;
    return future;
  }

  Future<bool> _primeImageOnce(
    ui.Image image,
    bool Function(ui.Image image, ByteData? data) uploader,
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

  bool _syncAtlasTexture(ui.Image image, ByteData? data) {
    if (data == null) return false;
    final uploaded = _uploadRgbaTexture(
      existing: _atlasTexture,
      existingWidth: _atlasWidth,
      existingHeight: _atlasHeight,
      width: image.width,
      height: image.height,
      rgbaData: data,
    );
    if (uploaded == null) return false;
    _atlasTexture = uploaded;
    _atlasWidth = image.width;
    _atlasHeight = image.height;
    _cachedAtlasImage = image;
    _atlasFilterMode = web.WebGL2RenderingContext.LINEAR;
    return true;
  }

  bool _syncKittyTexture(ui.Image image, ByteData? data) {
    if (data == null) return false;
    final existing = _kittyTextures.remove(image);
    final uploaded = _uploadRgbaTexture(
      existing: existing?.texture,
      existingWidth: existing?.width ?? 0,
      existingHeight: existing?.height ?? 0,
      width: image.width,
      height: image.height,
      rgbaData: data,
    );
    if (uploaded == null) return false;
    _kittyTextures[image] = _GlCachedTexture(
      texture: uploaded,
      width: image.width,
      height: image.height,
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
  }

  void _renderDirectTerminalStage({
    required GpuAtlasQuadBatch batch,
    required web.WebGLFramebuffer? sceneFbo,
    required int width,
    required int height,
  }) {
    if (batch.instanceCount <= 0 && batch.kittyQuads.isEmpty) return;

    _uploadAtlasInstancesIfNeeded(batch);
    _gl.bindFramebuffer(web.WebGL2RenderingContext.FRAMEBUFFER, sceneFbo);
    _gl.viewport(0, 0, width, height);
    _gl.enable(web.WebGL2RenderingContext.BLEND);
    _gl.blendFunc(
      web.WebGL2RenderingContext.ONE,
      web.WebGL2RenderingContext.ONE_MINUS_SRC_ALPHA,
    );
    _gl.useProgram(_atlasProgram);
    _gl.uniform2f(_atlasViewportLoc, width.toDouble(), height.toDouble());

    try {
      final italicStart = batch.italicStartInstanceIndex;
      final kittySplit = batch.kittyInsertInstanceIndex;
      final total = batch.instanceCount;

      if (italicStart > 0) {
        _drawAtlasSlice(
          0,
          italicStart,
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
    } finally {
      _gl.disable(web.WebGL2RenderingContext.BLEND);
      _gl.bindVertexArray(null);
      _gl.useProgram(null);
      _unbindSamplerTextures();
    }
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

  _GlPingPongTarget? _ensurePrevFrameTarget(String key, int width, int height) {
    final existing = _prevFrameTargets[key];
    if (existing != null && existing.matches(width, height)) {
      return existing;
    }
    existing?.delete(_gl);
    final front = _createFboTarget(width, height);
    final back = _createFboTarget(width, height);
    if (front == null || back == null) {
      front?.delete(_gl);
      back?.delete(_gl);
      _prevFrameTargets.remove(key);
      return null;
    }
    final pair = _GlPingPongTarget(front, back);
    _prevFrameTargets[key] = pair;
    return pair;
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

  Future<ByteData?> _readImageRgba(ui.Image? image) async {
    if (image == null) return null;
    return image.toByteData(format: ui.ImageByteFormat.rawRgba);
  }

  bool _syncInputTexture(ui.Image? image, ByteData? data, bool needsUpload) {
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
      width: image.width,
      height: image.height,
      rgbaData: data,
    );
    if (uploaded == null) return false;
    _inputTexture = uploaded;
    _inputWidth = image.width;
    _inputHeight = image.height;
    _cachedInputImage = image;
    return true;
  }

  bool _syncWallpaperTexture(
    ui.Image? image,
    ByteData? data,
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
      width: image.width,
      height: image.height,
      rgbaData: data,
    );
    if (uploaded == null) return false;
    _wallpaperTexture = uploaded;
    _wallpaperWidth = image.width;
    _wallpaperHeight = image.height;
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
    final bitmap = _canvas.transferToImageBitmap();
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

  static int? _parseInfoLogLineNumber(String log) {
    final match =
        _angleLinePattern.firstMatch(log) ??
        _mesaLinePattern.firstMatch(log) ??
        _genericLinePattern.firstMatch(log);
    final raw = match == null ? null : int.tryParse(match.group(1)!);
    if (raw == null || raw <= 0) return null;
    final adjusted = raw - _webgl2PrefixLineOffset;
    return adjusted >= 1 ? adjusted : raw;
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

  String webgl2FragmentGlsl;
  web.WebGLProgram? program;
  bool _disposed = false;

  _WebGl2ShaderHandle({
    required this.backend,
    required this.id,
    required this.requestedPrevFrame,
    required this.usesPrevFrame,
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

final class _GlPingPongTarget {
  _GlFboTarget _read;
  _GlFboTarget _write;

  _GlPingPongTarget(this._read, this._write);

  web.WebGLTexture get readTexture => _read.texture;

  web.WebGLFramebuffer get writeFramebuffer => _write.framebuffer;

  bool matches(int width, int height) =>
      _read.matches(width, height) && _write.matches(width, height);

  void swap() {
    final prevRead = _read;
    _read = _write;
    _write = prevRead;
  }

  void delete(web.WebGL2RenderingContext gl) {
    _read.delete(gl);
    _write.delete(gl);
  }
}
