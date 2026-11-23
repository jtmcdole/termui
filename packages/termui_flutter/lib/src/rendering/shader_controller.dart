import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';

import 'builtin_shaders.dart';
import 'shader_backend.dart';
import 'shader_backend_factory.dart';
import 'shader_spec.dart';
import 'shadertoy_glsl_shim.dart';

/// Factory creating a [TerminalShaderBackend] for an optional runtime override.
typedef ShaderBackendFactory = TerminalShaderBackend Function(
  ShaderBackendKind? override,
);

/// Asynchronous loader returning Ghostty Shadertoy GLSL source for [path].
typedef ShaderSourceLoader = Future<String> Function(String path);

/// Coordinates GPU shader backend selection, pass compilation, live custom
/// `.glsl` hot-reload, wallpaper texture lifecycle, and compile diagnostics.
///
/// Multiple `TerminalSurface` panes can share one [TerminalShaderController].
/// Superseded wallpaper [ui.Image] textures are always disposed in a post-frame
/// callback via [SchedulerBinding.addPostFrameCallback] so sibling panes never
/// sample a disposed texture mid-frame.
final class TerminalShaderController extends ChangeNotifier {
  final ShaderBackendFactory _backendFactory;

  TerminalShaderBackend _backend;
  ShaderBackendKind? _backendOverride;

  final Map<String, CompiledShaderHandle> _handles =
      <String, CompiledShaderHandle>{};
  final Map<String, ShadertoyGlslAnalysis> _analyses =
      <String, ShadertoyGlslAnalysis>{};
  final Map<String, String> _compiledSources = <String, String>{};
  final List<ui.Image> _pendingImageDisposals = <ui.Image>[];

  TerminalShaderConfig _activeConfig = TerminalShaderConfig.empty;
  ShaderSourceLoader? _lastSourceLoader;
  ShaderCompileException? _lastCompileError;
  ui.Image? _wallpaperImage;

  Future<void> _operationChain = Future<void>.value();
  int _wallpaperGeneration = 0;
  bool _postFrameDisposalScheduled = false;
  bool _ambientTicksPaused = false;
  bool _disposed = false;

  /// Creates a [TerminalShaderController].
  ///
  /// Pass [backend] or [backendFactory] in tests to inject a deterministic
  /// [TerminalShaderBackend]; otherwise defaults to
  /// [createTerminalShaderBackend].
  TerminalShaderController({
    TerminalShaderBackend? backend,
    ShaderBackendFactory? backendFactory,
    ShaderBackendKind? initialBackendOverride,
  }) : _backendFactory =
           backendFactory ??
           ((override) => createTerminalShaderBackend(override: override)),
       _backendOverride = initialBackendOverride,
       _backend =
           backend ??
           (backendFactory != null
               ? backendFactory(initialBackendOverride)
               : createTerminalShaderBackend(override: initialBackendOverride));

  /// Active platform shader backend.
  TerminalShaderBackend get backend => _backend;

  /// Kind of the active shader backend (`flutterGpu`, `webGl2`, or `disabled`).
  ShaderBackendKind get backendKind => _backend.kind;

  /// Current runtime backend override (`null` selects automatically).
  ShaderBackendKind? get backendOverride => _backendOverride;

  /// Whether the active backend compiles and executes custom GLSL shaders.
  bool get supportsCustomGlsl => _backend.supportsCustomGlsl;

  /// Whether the active backend supports synchronous background pass painting.
  bool get supportsSyncBackground => _backend.supportsSyncBackground;

  /// Whether any currently active pass statically references `iTime`,
  /// `iTimeDelta`, or `iFrame`.
  bool get anyPassUsesTime =>
      _analyses.values.any((analysis) => analysis.usesTime);

  /// Whether any currently active pass statically references `iMouse`.
  bool get anyPassUsesMouse =>
      _analyses.values.any((analysis) => analysis.usesMouse);

  /// Most recent compilation or validation error, cleared on the next clean
  /// compile or reload.
  ShaderCompileException? get lastCompileError => _lastCompileError;

  /// Active decoded wallpaper [ui.Image] managed by this controller, if any.
  ui.Image? get wallpaperImage => _wallpaperImage;

  /// Most recently synchronized [TerminalShaderConfig].
  TerminalShaderConfig get activeConfig => _activeConfig;

  /// Whether [dispose] has been called on this controller.
  bool get isDisposed => _disposed;

  /// Whether continuous ambient shader ticks are temporarily paused (for
  /// example while the host OS window is inside a modal Win32 move/resize loop).
  bool get ambientTicksPaused => _ambientTicksPaused;

  /// Pauses or resumes continuous ambient shader ticks across all attached
  /// [TerminalShaderHost] panes without rebuilding the widget tree.
  void setAmbientTicksPaused(bool paused) {
    if (_disposed || _ambientTicksPaused == paused) return;
    _ambientTicksPaused = paused;
    notifyListeners();
  }

  /// Number of superseded wallpaper images waiting for post-frame disposal.
  @visibleForTesting
  int get debugPendingImageDisposalCount => _pendingImageDisposals.length;

  /// Returns the compiled handle for pass [id], or `null` if not compiled.
  CompiledShaderHandle? handleForPass(String id) => _handles[id];

  /// Returns the static GLSL analysis for pass [id], or `null` if unavailable.
  ShadertoyGlslAnalysis? analysisForPass(String id) => _analyses[id];

  /// Synchronizes compiled pass handles to match [config].
  ///
  /// Removed passes have their handles disposed cleanly. Passes whose source
  /// is unchanged keep their existing compiled handle. Custom `.glsl` files
  /// are resolved asynchronously via [sourceLoader].
  Future<void> syncConfig(
    TerminalShaderConfig config, {
    ShaderSourceLoader? sourceLoader,
  }) => _enqueue(
    () => _syncConfigInternal(
      config,
      sourceLoader: sourceLoader,
      forceReloadCustom: false,
      forceReloadAll: false,
    ),
  );

  /// Re-reads and hot-reloads custom shader passes in [config] (or
  /// [activeConfig] when omitted).
  ///
  /// When a custom `.glsl` fails validation or compilation, the previously
  /// active [CompiledShaderHandle] remains intact, [lastCompileError] records
  /// the failure, and listeners are notified. Passing [includeBuiltin] as
  /// `true` forces recompilation of built-in presets as well.
  Future<void> reloadCustomShaders({
    TerminalShaderConfig? config,
    ShaderSourceLoader? sourceLoader,
    bool includeBuiltin = false,
  }) => _enqueue(
    () => _syncConfigInternal(
      config ?? _activeConfig,
      sourceLoader: sourceLoader,
      forceReloadCustom: true,
      forceReloadAll: includeBuiltin,
    ),
  );

  /// Switches the runtime [ShaderBackendKind] override, cleanly disposing the
  /// previous backend and recompiling any active shader passes.
  Future<void> setBackendOverride(
    ShaderBackendKind? override, {
    ShaderSourceLoader? sourceLoader,
  }) => _enqueue(
    () => _switchBackendOverrideInternal(override, sourceLoader: sourceLoader),
  );

  /// Replaces the managed wallpaper [ui.Image], deferring disposal of the
  /// superseded image to a post-frame callback.
  void setWallpaperImage(ui.Image? image) {
    if (_disposed) {
      image?.dispose();
      return;
    }
    _wallpaperGeneration++;
    _swapWallpaperImage(image);
  }

  /// Decodes encoded PNG/JPEG/WebP [bytes] into a GPU [ui.Image] and installs
  /// it as [wallpaperImage], disposing superseded textures post-frame.
  Future<void> setWallpaperBytes(Uint8List bytes) async {
    if (_disposed) return;
    final generation = ++_wallpaperGeneration;
    ui.Codec? codec;
    try {
      codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      final decoded = frame.image;
      if (_disposed || generation != _wallpaperGeneration) {
        decoded.dispose();
        return;
      }
      _swapWallpaperImage(decoded);
    } finally {
      codec?.dispose();
    }
  }

  /// Clears [wallpaperImage] and disposes the previous image post-frame.
  void clearWallpaperImage() => setWallpaperImage(null);

  /// Clears any recorded [lastCompileError] diagnostic.
  void clearLastCompileError() {
    if (_disposed || _lastCompileError == null) return;
    _lastCompileError = null;
    notifyListeners();
  }

  /// Records a runtime GPU pipeline link or draw [error] without tearing down
  /// unaffected panes or crashing the paint loop.
  void reportRuntimeError(ShaderCompileException error) {
    if (_disposed) return;
    final current = _lastCompileError;
    if (current != null &&
        current.shaderId == error.shaderId &&
        current.message == error.message) {
      return;
    }
    _lastCompileError = error;
    final scheduler = SchedulerBinding.instance;
    if (scheduler.schedulerPhase == SchedulerPhase.persistentCallbacks) {
      scheduler.addPostFrameCallback((_) {
        if (!_disposed) {
          notifyListeners();
        }
      });
      return;
    }
    notifyListeners();
  }

  Future<void> _enqueue(Future<void> Function() action) {
    if (_disposed) return Future<void>.value();
    final next = _operationChain.then((_) => _runIfActive(action));
    _operationChain = next.catchError((Object _) {});
    return next;
  }

  Future<void> _runIfActive(Future<void> Function() action) async {
    if (_disposed) return;
    await action();
  }

  Future<void> _switchBackendOverrideInternal(
    ShaderBackendKind? override, {
    ShaderSourceLoader? sourceLoader,
  }) async {
    if (_disposed || _backendOverride == override) return;
    _backendOverride = override;
    if (sourceLoader != null) {
      _lastSourceLoader = sourceLoader;
    }

    _disposeAllHandles();
    _analyses.clear();
    _compiledSources.clear();
    final oldBackend = _backend;
    _backend = _backendFactory(override);
    oldBackend.dispose();
    _lastCompileError = null;
    notifyListeners();

    if (!_activeConfig.isEmpty) {
      await _syncConfigInternal(
        _activeConfig,
        sourceLoader: _lastSourceLoader,
        forceReloadCustom: true,
        forceReloadAll: true,
      );
    }
  }

  Future<void> _syncConfigInternal(
    TerminalShaderConfig config, {
    required ShaderSourceLoader? sourceLoader,
    required bool forceReloadCustom,
    required bool forceReloadAll,
  }) async {
    if (_disposed) return;
    _activeConfig = config;
    if (sourceLoader != null) {
      _lastSourceLoader = sourceLoader;
    }
    final activeSpecs = _collectActiveSpecs(config);
    _pruneRemovedPasses(activeSpecs);

    ShaderCompileException? firstError;
    for (final spec in activeSpecs) {
      if (_disposed) return;
      final forceReload =
          forceReloadAll || (forceReloadCustom && _isCustomPass(spec));
      final error = await _syncSinglePass(
        spec,
        sourceLoader: _lastSourceLoader,
        forceReload: forceReload,
      );
      firstError ??= error;
    }

    if (_disposed) return;
    _lastCompileError = firstError;
    notifyListeners();
  }

  static List<ShaderPassSpec> _collectActiveSpecs(TerminalShaderConfig config) {
    if (!config.enabled) return const <ShaderPassSpec>[];
    return <ShaderPassSpec>[
      ...config.backgroundPasses,
      ...config.foregroundPasses,
    ];
  }

  static bool _isCustomPass(ShaderPassSpec spec) =>
      (spec.customSourcePath != null &&
          spec.customSourcePath!.trim().isNotEmpty) ||
      (spec.inlineGlsl != null && spec.inlineGlsl!.isNotEmpty);

  void _pruneRemovedPasses(List<ShaderPassSpec> activeSpecs) {
    final activeIds = <String>{for (final spec in activeSpecs) spec.id};
    final staleIds = <String>[
      for (final id in _handles.keys)
        if (!activeIds.contains(id)) id,
    ];
    for (final id in staleIds) {
      _handles.remove(id)?.dispose();
      _analyses.remove(id);
      _compiledSources.remove(id);
    }
    _analyses.removeWhere((id, _) => !activeIds.contains(id));
    _compiledSources.removeWhere((id, _) => !activeIds.contains(id));
  }

  Future<ShaderCompileException?> _syncSinglePass(
    ShaderPassSpec spec, {
    required ShaderSourceLoader? sourceLoader,
    required bool forceReload,
  }) async {
    try {
      final source = await _resolvePassSource(spec, sourceLoader);
      if (source == null || _disposed) return null;

      final existing = _handles[spec.id];
      if (existing != null &&
          !forceReload &&
          _compiledSources[spec.id] == source) {
        return null;
      }

      final analysis = ShadertoyGlslShim.analyze(source, shaderId: spec.id);
      await _compileOrReloadPass(spec, existing, source, analysis);
      return null;
    } on ShaderCompileException catch (error) {
      return error;
    } on Object catch (error) {
      return ShaderCompileException(shaderId: spec.id, message: '$error');
    }
  }

  Future<String?> _resolvePassSource(
    ShaderPassSpec spec,
    ShaderSourceLoader? sourceLoader,
  ) async {
    final inline = spec.inlineGlsl;
    if (inline != null && inline.isNotEmpty) {
      return inline;
    }
    final customPath = spec.customSourcePath?.trim();
    if (customPath != null && customPath.isNotEmpty) {
      if (sourceLoader == null) {
        throw ShaderCompileException(
          shaderId: spec.id,
          message:
              'No custom shader source loader configured for "$customPath".',
        );
      }
      return sourceLoader(customPath);
    }
    final preset = spec.preset;
    if (preset == null || preset == TerminalShaderPreset.none) {
      return null;
    }
    return BuiltinShaders.sourceForPreset(preset);
  }

  Future<void> _compileOrReloadPass(
    ShaderPassSpec spec,
    CompiledShaderHandle? existing,
    String source,
    ShadertoyGlslAnalysis analysis,
  ) async {
    final activeBackend = _backend;
    if (existing != null) {
      await activeBackend.reload(existing, source);
      if (_disposed || !identical(activeBackend, _backend)) return;
      _analyses[spec.id] = analysis;
      _compiledSources[spec.id] = source;
      return;
    }

    final handle = await activeBackend.compile(
      spec.id,
      source,
      usesPrevFrame: spec.usesPrevFrame || analysis.usesPrevFrame,
    );
    if (_disposed || !identical(activeBackend, _backend)) {
      handle.dispose();
      return;
    }
    _handles[spec.id] = handle;
    _analyses[spec.id] = analysis;
    _compiledSources[spec.id] = source;
  }

  void _swapWallpaperImage(ui.Image? nextImage) {
    if (identical(_wallpaperImage, nextImage)) return;
    final previous = _wallpaperImage;
    _wallpaperImage = nextImage;
    notifyListeners();
    if (previous != null) {
      _scheduleImageDisposal(previous);
    }
  }

  void _scheduleImageDisposal(ui.Image image) {
    if (_disposed) {
      image.dispose();
      return;
    }
    _pendingImageDisposals.add(image);
    if (_postFrameDisposalScheduled) return;
    _postFrameDisposalScheduled = true;
    final scheduler = SchedulerBinding.instance;
    scheduler.addPostFrameCallback((_) => _flushPendingImageDisposals());
    if (scheduler.schedulerPhase == SchedulerPhase.idle) {
      scheduler.ensureVisualUpdate();
    }
  }

  void _flushPendingImageDisposals() {
    _postFrameDisposalScheduled = false;
    if (_pendingImageDisposals.isEmpty) return;
    for (final image in _pendingImageDisposals) {
      image.dispose();
    }
    _pendingImageDisposals.clear();
  }

  void _disposeAllHandles() {
    final handles = _handles.values.toList(growable: false);
    _handles.clear();
    for (final handle in handles) {
      handle.dispose();
    }
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _wallpaperGeneration++;
    _disposeAllHandles();
    _analyses.clear();
    _compiledSources.clear();
    _backend.dispose();
    _wallpaperImage?.dispose();
    _wallpaperImage = null;
    _flushPendingImageDisposals();
    super.dispose();
  }
}
