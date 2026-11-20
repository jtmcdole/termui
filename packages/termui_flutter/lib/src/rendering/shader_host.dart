import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:clock/clock.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import 'gpu_atlas_batch.dart';
import 'shader_backend.dart';
import 'shader_controller.dart';
import 'shader_spec.dart';

/// Leaf host wrapping a terminal canvas with optional background wallpaper /
/// shader passes and foreground `iChannel0` post-processing passes.
///
/// When [config] is empty (disabled, or no background/foreground passes and no
/// wallpaper image), [build] returns [child] directly with zero extra widgets,
/// zero `RepaintBoundary` overhead, and zero `Ticker` registrations.
///
/// Time-varying animations route `iTime`, `iTimeDelta`, and `iFrame` ticks
/// exclusively through a leaf [ChangeNotifier] attached to the shader painters
/// so `TerminalSurface` and `TuiAtlasPainter` never rebuild or repaint on
/// `iTime` updates.
final class TerminalShaderHost extends StatefulWidget {
  /// Controller providing the active [TerminalShaderBackend], compiled shader
  /// handles, and optional managed wallpaper [ui.Image].
  final TerminalShaderController? controller;

  /// Active shader pass chains, animation policy, and optional wallpaper image.
  final TerminalShaderConfig config;

  /// Optional stable pane identifier prefixing per-pass `prevFrameKey` values
  /// so split panes isolate `iPrevFrame` ping-pong buffers.
  final String? paneKey;

  /// Current cursor bounding box in Y-down logical pixels relative to this
  /// host when [cursorRectLogicalProvider] is omitted.
  final Rect? cursorRectLogical;

  /// Optional live getter returning the cursor bounding box in Y-down logical
  /// pixels without requiring widget rebuilds.
  final Rect? Function()? cursorRectLogicalProvider;

  /// Current cursor ARGB fill color when [cursorColorArgbProvider] is omitted.
  final int cursorColorArgb;

  /// Optional live getter returning the cursor ARGB fill color.
  final int Function()? cursorColorArgbProvider;

  /// Active Ghostty cursor style constant (`0..3`, e.g.
  /// [TerminalShaderUniforms.cursorStyleBlock]).
  final int cursorStyle;

  /// Optional live getter returning the Ghostty cursor style constant.
  final int Function()? cursorStyleProvider;

  /// Whether the terminal cursor is currently visible.
  final bool cursorVisible;

  /// Optional live getter returning whether the cursor is visible.
  final bool Function()? cursorVisibleProvider;

  /// Whether this terminal pane currently holds keyboard focus (`iFocus`).
  final bool isFocused;

  /// Default terminal foreground ARGB color (`iForegroundColor`).
  final int foregroundArgb;

  /// Default terminal background ARGB color (`iBackgroundColor`).
  final int backgroundArgb;

  /// Full 256-color terminal ANSI palette in `0xAARRGGBB` format
  /// (`iPalette[256]`).
  final Uint32List? palette256Argb;

  /// Logical terminal cell width and height (`iCellSize` after DPR scaling).
  final Size cellSizeLogical;

  /// Optional listenable signalling terminal buffer or selection repaints
  /// (used to invalidate cached `iChannel0` captures and drive
  /// [ShaderAnimationMode.onActivity]).
  final Listenable? activityListenable;

  /// Monotonic integer activity counter driving
  /// [ShaderAnimationMode.onActivity] when updated across rebuilds.
  final int activitySignal;

  /// Idle timeout after which [ShaderAnimationMode.onActivity] stops ticking.
  final Duration activityTimeout;

  /// Optional callback staging the active terminal grid into a
  /// [GpuAtlasQuadBatch] for direct GPU-to-GPU rendering when the active
  /// backend implements [DirectTerminalShaderBackend].
  final GpuAtlasQuadBatch? Function(Size logicalSize, double devicePixelRatio)?
  directTerminalBatchProvider;

  /// Active glyph atlas image bound during direct GPU terminal rendering.
  final ui.Image? atlasImage;

  /// Device pixel ratio of [atlasImage] used to detect transient DPR rebuild
  /// mismatches and fall back cleanly until the atlas catches up.
  final double? atlasDevicePixelRatio;

  /// Explicit logical viewport size for direct GPU terminal rendering so
  /// pointer hit-testing and `F12` screenshots preserve exact cell geometry.
  final Size? directLogicalSize;

  /// Wrapped terminal canvas widget.
  final Widget child;

  /// Creates a [TerminalShaderHost].
  const TerminalShaderHost({
    super.key,
    this.controller,
    this.config = TerminalShaderConfig.empty,
    this.paneKey,
    this.cursorRectLogical,
    this.cursorRectLogicalProvider,
    this.cursorColorArgb = 0xFFFFFFFF,
    this.cursorColorArgbProvider,
    this.cursorStyle = TerminalShaderUniforms.cursorStyleBlock,
    this.cursorStyleProvider,
    this.cursorVisible = true,
    this.cursorVisibleProvider,
    this.isFocused = true,
    this.foregroundArgb = 0xFFE6EDF3,
    this.backgroundArgb = 0xFF0D1117,
    this.palette256Argb,
    this.cellSizeLogical = const Size(8.0, 16.0),
    this.activityListenable,
    this.activitySignal = 0,
    this.activityTimeout = const Duration(seconds: 2),
    this.directTerminalBatchProvider,
    this.atlasImage,
    this.atlasDevicePixelRatio,
    this.directLogicalSize,
    required this.child,
  });

  @override
  State<TerminalShaderHost> createState() => TerminalShaderHostState();
}

/// State backing [TerminalShaderHost], exposed for diagnostics and tests.
final class TerminalShaderHostState extends State<TerminalShaderHost>
    with SingleTickerProviderStateMixin {
  final GlobalKey _captureBoundaryKey = GlobalKey();
  final _ShaderFrameNotifier _frameNotifier = _ShaderFrameNotifier();
  final List<ui.Image> _pendingImageDisposals = <ui.Image>[];

  final Float32List _currentCursorXywh = Float32List(4);
  final Float32List _previousCursorXywh = Float32List(4);

  Ticker? _ticker;
  Timer? _activityTimer;
  Duration? _lastTickElapsed;

  bool _tickerModeEnabled = true;
  bool _hasRecentActivity = false;
  bool _cursorInitialized = false;
  bool _isFocused = true;
  bool _cursorVisible = true;
  bool _postFrameDisposalScheduled = false;
  bool _childCaptureDirty = true;
  bool _foregroundInFlight = false;
  bool _foregroundPending = false;
  bool _foregroundPostFrameScheduled = false;
  bool _backgroundInFlight = false;
  bool _backgroundPending = false;
  bool _backgroundPostFrameScheduled = false;
  bool _backgroundDirty = true;
  bool _directFallbackActive = false;
  bool _directFallbackScheduled = false;
  bool _directPrepareInFlight = false;
  _DirectFallbackReason _directFallbackReason = _DirectFallbackReason.none;

  double _devicePixelRatio = 1.0;
  double _timeSeconds = 0.0;
  double _deltaSeconds = 0.0;
  double _frameRate = 60.0;
  double _timeCursorChange = 0.0;
  double _timeFocusChange = 0.0;

  int _frameIndex = 0;
  int _currentCursorArgb = 0xFFFFFFFF;
  int _previousCursorArgb = 0xFFFFFFFF;
  int _currentCursorStyle = TerminalShaderUniforms.cursorStyleBlock;

  Size _lastLogicalSize = Size.zero;
  Size _cachedChildPhysicalSize = Size.zero;
  Size _pendingAsyncBgPhysicalSize = Size.zero;
  Size _directOutputLogicalSize = Size.zero;

  ui.Image? _backgroundOutputImage;
  ui.Image? _foregroundOutputImage;
  ui.Image? _cachedChildCapture;
  ui.Image? _directOutputImage;

  /// Number of superseded output images queued for post-frame disposal.
  @visibleForTesting
  int get debugPendingImageDisposalCount => _pendingImageDisposals.length;

  /// Whether the internal animation [Ticker] is currently active.
  @visibleForTesting
  bool get debugIsTickerActive => _ticker?.isActive ?? false;

  /// Current rendered foreground output image, if any.
  @visibleForTesting
  ui.Image? get debugForegroundOutputImage => _foregroundOutputImage;

  /// Whether unified direct GPU-to-GPU terminal rendering is currently active.
  @visibleForTesting
  bool get debugIsDirectModeActive => _isDirectModeActive;

  /// Current rendered direct GPU terminal frame image, if any.
  @visibleForTesting
  ui.Image? get debugDirectOutputImage => _directOutputImage;

  ui.Image? get _effectiveWallpaper =>
      widget.config.backgroundImage ?? widget.controller?.wallpaperImage;

  DirectTerminalShaderBackend? get _directBackend {
    if (!widget.config.enabled || !_isBackendActive) return null;
    final backend = widget.controller!.backend;
    return backend is DirectTerminalShaderBackend &&
            backend.supportsDirectTerminalRender
        ? backend
        : null;
  }

  bool get _canUseDirectTerminalRender =>
      _directBackend != null &&
      widget.directTerminalBatchProvider != null &&
      widget.atlasImage != null &&
      widget.directLogicalSize != null &&
      !widget.directLogicalSize!.isEmpty;

  bool get _isDirectModeActive =>
      _canUseDirectTerminalRender && !_directFallbackActive;

  bool get _isInactive =>
      !widget.config.enabled ||
      (widget.config.backgroundPasses.isEmpty &&
          widget.config.foregroundPasses.isEmpty &&
          _effectiveWallpaper == null);

  bool get _isBackendActive =>
      widget.controller != null &&
      widget.controller!.backendKind != ShaderBackendKind.disabled;

  bool get _hasCompiledBackgroundPasses =>
      _isBackendActive && _hasAnyCompiledPass(widget.config.backgroundPasses);

  bool get _hasCompiledForegroundPasses =>
      _isBackendActive && _hasAnyCompiledPass(widget.config.foregroundPasses);

  bool get _shouldAnimate {
    if (_isInactive || !_tickerModeEnabled || !_isBackendActive) return false;
    final ctrl = widget.controller;
    if (ctrl == null || !ctrl.anyPassUsesTime) return false;
    return switch (widget.config.animationMode) {
      ShaderAnimationMode.always => true,
      ShaderAnimationMode.focused => _isFocused,
      ShaderAnimationMode.onActivity => _hasRecentActivity,
      ShaderAnimationMode.staticOnly => false,
    };
  }

  bool _hasAnyCompiledPass(List<ShaderPassSpec> specs) {
    final ctrl = widget.controller;
    if (ctrl == null || specs.isEmpty) return false;
    for (final spec in specs) {
      if (ctrl.handleForPass(spec.id) != null) return true;
    }
    return false;
  }

  @override
  void initState() {
    super.initState();
    _isFocused = widget.isFocused;
    _currentCursorArgb =
        widget.cursorColorArgbProvider?.call() ?? widget.cursorColorArgb;
    _previousCursorArgb = _currentCursorArgb;
    _currentCursorStyle =
        widget.cursorStyleProvider?.call() ?? widget.cursorStyle;
    _cursorVisible =
        widget.cursorVisibleProvider?.call() ?? widget.cursorVisible;
    widget.controller?.addListener(_onControllerChanged);
    widget.activityListenable?.addListener(_onExternalActivity);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final nextTickerMode = TickerMode.valuesOf(context).enabled;
    final nextDpr = MediaQuery.maybeDevicePixelRatioOf(context) ?? 1.0;
    final dprChanged =
        nextDpr.isFinite && nextDpr > 0.0 && nextDpr != _devicePixelRatio;
    if (dprChanged) {
      _devicePixelRatio = nextDpr;
      _childCaptureDirty = true;
      _backgroundDirty = true;
      if (_directFallbackActive &&
          _directFallbackReason == _DirectFallbackReason.dprMismatch &&
          _isAtlasDprMatched) {
        _directFallbackActive = false;
        _directFallbackReason = _DirectFallbackReason.none;
      }
    }
    _tickerModeEnabled = nextTickerMode;
    _syncTicker();
  }

  bool get _isAtlasDprMatched {
    final atlasDpr = widget.atlasDevicePixelRatio;
    return atlasDpr == null || (atlasDpr - _devicePixelRatio).abs() <= 1e-3;
  }

  @override
  void didUpdateWidget(TerminalShaderHost oldWidget) {
    super.didUpdateWidget(oldWidget);
    _rebindListeners(oldWidget);
    _syncFocusTransition(oldWidget);
    _syncActivityAndDirtyFlags(oldWidget);
    _maybeRecoverDirectModeOnUpdate(oldWidget);
    _syncTicker();
    if (!_hasCompiledForegroundPasses && _foregroundOutputImage != null) {
      _replaceForegroundOutputImage(null);
    }
    if (!_hasCompiledBackgroundPasses && _backgroundOutputImage != null) {
      _replaceBackgroundOutputImage(null);
    }
    if (!_canUseDirectTerminalRender && _directOutputImage != null) {
      _replaceDirectOutputImage(null);
    }
    if (!_isDirectModeActive &&
        _hasCompiledForegroundPasses &&
        _childCaptureDirty) {
      _scheduleForegroundRender();
    }
  }

  void _maybeRecoverDirectModeOnUpdate(TerminalShaderHost oldWidget) {
    if (!_directFallbackActive ||
        !_canUseDirectTerminalRender ||
        _directPrepareInFlight) {
      return;
    }
    final atlasChanged = !identical(oldWidget.atlasImage, widget.atlasImage);
    final dprChanged =
        oldWidget.atlasDevicePixelRatio != widget.atlasDevicePixelRatio;
    final controllerChanged = !identical(
      oldWidget.controller,
      widget.controller,
    );
    if (controllerChanged) {
      _directFallbackActive = false;
      _directFallbackReason = _DirectFallbackReason.none;
      return;
    }
    if (_directFallbackReason == _DirectFallbackReason.dprMismatch &&
        (dprChanged || atlasChanged) &&
        _isAtlasDprMatched) {
      _directFallbackActive = false;
      _directFallbackReason = _DirectFallbackReason.none;
      return;
    }
    if (_directFallbackReason == _DirectFallbackReason.canvasOnly &&
        (atlasChanged || oldWidget.activitySignal != widget.activitySignal)) {
      _probeCanvasOnlyRecovery(callSetState: false);
    }
  }

  void _rebindListeners(TerminalShaderHost oldWidget) {
    if (!identical(oldWidget.controller, widget.controller)) {
      oldWidget.controller?.removeListener(_onControllerChanged);
      widget.controller?.addListener(_onControllerChanged);
      _backgroundDirty = true;
      _childCaptureDirty = true;
    }
    if (!identical(oldWidget.activityListenable, widget.activityListenable)) {
      oldWidget.activityListenable?.removeListener(_onExternalActivity);
      widget.activityListenable?.addListener(_onExternalActivity);
    }
  }

  void _syncFocusTransition(TerminalShaderHost oldWidget) {
    if (oldWidget.isFocused == widget.isFocused) return;
    _isFocused = widget.isFocused;
    _timeFocusChange = _timeSeconds;
    _backgroundDirty = true;
    _childCaptureDirty = true;
    if (widget.config.animationMode == ShaderAnimationMode.onActivity) {
      _recordActivityBurst();
    }
    _frameNotifier.notify();
  }

  void _syncActivityAndDirtyFlags(TerminalShaderHost oldWidget) {
    final activityChanged = oldWidget.activitySignal != widget.activitySignal;
    final cursorChanged =
        oldWidget.cursorRectLogical != widget.cursorRectLogical ||
        oldWidget.cursorColorArgb != widget.cursorColorArgb ||
        oldWidget.cursorStyle != widget.cursorStyle ||
        oldWidget.cursorVisible != widget.cursorVisible;
    final configChanged =
        oldWidget.config != widget.config ||
        oldWidget.foregroundArgb != widget.foregroundArgb ||
        oldWidget.backgroundArgb != widget.backgroundArgb ||
        oldWidget.cellSizeLogical != widget.cellSizeLogical ||
        !identical(oldWidget.atlasImage, widget.atlasImage) ||
        oldWidget.atlasDevicePixelRatio != widget.atlasDevicePixelRatio ||
        oldWidget.directLogicalSize != widget.directLogicalSize;

    if (activityChanged || cursorChanged) {
      _recordActivityBurst();
    }
    if (activityChanged || cursorChanged || configChanged) {
      _childCaptureDirty = true;
      _backgroundDirty = true;
      if (_lastLogicalSize.width > 0 && _lastLogicalSize.height > 0) {
        _syncCursorState(_lastLogicalSize);
      }
      _frameNotifier.notify();
    }
  }

  void _onControllerChanged() {
    if (!mounted) return;
    _backgroundDirty = true;
    _childCaptureDirty = true;
    if (_directFallbackActive &&
        _canUseDirectTerminalRender &&
        !_directPrepareInFlight &&
        _directFallbackReason != _DirectFallbackReason.canvasOnly) {
      _directFallbackActive = false;
      _directFallbackReason = _DirectFallbackReason.none;
    }
    _syncTicker();
    setState(() {});
    _frameNotifier.notify();
    if (!_isDirectModeActive && _hasCompiledForegroundPasses) {
      _scheduleForegroundRender();
    }
  }

  void _onExternalActivity() {
    if (!mounted || (_isInactive && !_canUseDirectTerminalRender)) return;
    _childCaptureDirty = true;
    if (_lastLogicalSize.width > 0 && _lastLogicalSize.height > 0) {
      _syncCursorState(_lastLogicalSize);
    }
    _recordActivityBurst();
    if (_isDirectModeActive) {
      _frameNotifier.notify();
      return;
    }
    if (_directFallbackActive &&
        _canUseDirectTerminalRender &&
        !_directPrepareInFlight &&
        _directFallbackReason == _DirectFallbackReason.canvasOnly &&
        _probeCanvasOnlyRecovery(callSetState: true)) {
      return;
    }
    _frameNotifier.notify();
    if (_hasCompiledForegroundPasses) {
      _scheduleForegroundRender();
    }
  }

  void _recordActivityBurst() {
    if (widget.config.animationMode != ShaderAnimationMode.onActivity) return;
    _hasRecentActivity = true;
    _activityTimer?.cancel();
    _activityTimer = Timer(widget.activityTimeout, _onActivityIdle);
    _syncTicker();
  }

  void _onActivityIdle() {
    _activityTimer = null;
    if (!mounted) return;
    _hasRecentActivity = false;
    _syncTicker();
  }

  void _syncTicker() {
    if (_shouldAnimate) {
      final ticker = _ticker ??= createTicker(_onTick);
      if (!ticker.isActive) {
        _lastTickElapsed = null;
        ticker.start();
      }
      return;
    }
    if (_ticker != null && _ticker!.isActive) {
      _ticker!.stop();
      _lastTickElapsed = null;
    }
  }

  void _onTick(Duration elapsed) {
    if (!mounted || !_shouldAnimate) {
      _syncTicker();
      return;
    }
    final double dt;
    if (_lastTickElapsed == null) {
      dt = (elapsed.inMicroseconds / 1e6).clamp(0.0, 0.25);
    } else {
      dt = ((elapsed - _lastTickElapsed!).inMicroseconds / 1e6).clamp(
        0.0,
        0.25,
      );
    }
    _lastTickElapsed = elapsed;
    _deltaSeconds = dt;
    _timeSeconds += dt;
    _frameIndex++;
    if (dt > 0.0) {
      _frameRate = (1.0 / dt).clamp(1.0, 240.0);
    }
    if (_isDirectModeActive) {
      if (_hasCompiledBackgroundPasses || _hasCompiledForegroundPasses) {
        _frameNotifier.notify();
      }
      return;
    }
    if (_hasCompiledBackgroundPasses) {
      _backgroundDirty = true;
      _frameNotifier.notify();
    }
    if (_hasCompiledForegroundPasses) {
      if (_hasCompiledBackgroundPasses) {
        _childCaptureDirty = true;
      }
      _scheduleForegroundRender();
    }
  }

  void _syncCursorState(Size logicalSize) {
    final rect =
        widget.cursorRectLogicalProvider?.call() ?? widget.cursorRectLogical;
    final color =
        widget.cursorColorArgbProvider?.call() ?? widget.cursorColorArgb;
    final style = widget.cursorStyleProvider?.call() ?? widget.cursorStyle;
    final visible =
        widget.cursorVisibleProvider?.call() ?? widget.cursorVisible;

    final dpr = _devicePixelRatio;
    final double left = rect == null ? 0.0 : rect.left * dpr;
    final double width = rect == null ? 0.0 : rect.width * dpr;
    final double height = rect == null ? 0.0 : rect.height * dpr;
    final double bottomY = rect == null
        ? 0.0
        : (logicalSize.height - rect.bottom) * dpr;

    if (!_cursorInitialized) {
      _writeXywh(_currentCursorXywh, left, bottomY, width, height);
      _writeXywh(_previousCursorXywh, left, bottomY, width, height);
      _currentCursorArgb = color;
      _previousCursorArgb = color;
      _currentCursorStyle = style;
      _cursorVisible = visible;
      _cursorInitialized = true;
      return;
    }

    final changed =
        _currentCursorXywh[0] != left ||
        _currentCursorXywh[1] != bottomY ||
        _currentCursorXywh[2] != width ||
        _currentCursorXywh[3] != height ||
        _currentCursorStyle != style ||
        _currentCursorArgb != color;
    if (changed) {
      _copyXywh(_currentCursorXywh, _previousCursorXywh);
      _previousCursorArgb = _currentCursorArgb;
      _writeXywh(_currentCursorXywh, left, bottomY, width, height);
      _currentCursorArgb = color;
      _currentCursorStyle = style;
      _timeCursorChange = _timeSeconds;
    }
    _cursorVisible = visible;
  }

  static void _writeXywh(
    Float32List dst,
    double x,
    double y,
    double w,
    double h,
  ) {
    dst[0] = x;
    dst[1] = y;
    dst[2] = w;
    dst[3] = h;
  }

  static void _copyXywh(Float32List src, Float32List dst) {
    dst[0] = src[0];
    dst[1] = src[1];
    dst[2] = src[2];
    dst[3] = src[3];
  }

  List<ShaderPassInvocation> _buildPassInvocations(
    List<ShaderPassSpec> specs,
    Size physicalSize,
  ) {
    final ctrl = widget.controller;
    if (ctrl == null || specs.isEmpty) return const <ShaderPassInvocation>[];
    final prefix = widget.paneKey == null ? '' : '${widget.paneKey}:';
    final invocations = <ShaderPassInvocation>[];
    for (final spec in specs) {
      final handle = ctrl.handleForPass(spec.id);
      if (handle == null) continue;
      invocations.add((
        handle: handle,
        uniforms: _buildUniforms(physicalSize, spec.params),
        prevFrameKey: '$prefix${spec.id}',
      ));
    }
    return invocations;
  }

  TerminalShaderUniforms _buildUniforms(Size physicalSize, Float32List params) {
    final now = clock.now();
    final secondsSinceMidnight =
        now.hour * 3600.0 +
        now.minute * 60.0 +
        now.second +
        now.millisecond / 1000.0;
    final date = Float32List.fromList(<double>[
      now.year.toDouble(),
      now.month.toDouble(),
      now.day.toDouble(),
      secondsSinceMidnight,
    ]);
    final wallpaper = _effectiveWallpaper;
    final channels = Float32List(12)
      ..[0] = physicalSize.width
      ..[1] = physicalSize.height
      ..[2] = 1.0
      ..[3] = wallpaper?.width.toDouble() ?? 0.0
      ..[4] = wallpaper?.height.toDouble() ?? 0.0
      ..[5] = wallpaper != null ? 1.0 : 0.0;

    return TerminalShaderUniforms(
      width: physicalSize.width,
      height: physicalSize.height,
      timeSeconds: _timeSeconds,
      deltaSeconds: _deltaSeconds,
      frameIndex: _frameIndex,
      frameRate: _frameRate,
      currentCursorXywh: _currentCursorXywh,
      previousCursorXywh: _previousCursorXywh,
      currentCursorArgb: _currentCursorArgb,
      previousCursorArgb: _previousCursorArgb,
      currentCursorStyle: _currentCursorStyle,
      timeCursorChange: _timeCursorChange,
      cursorVisible: _cursorVisible,
      isFocused: _isFocused,
      timeFocusChange: _timeFocusChange,
      foregroundArgb: widget.foregroundArgb,
      backgroundArgb: widget.backgroundArgb,
      palette256Argb: widget.palette256Argb,
      regionRect: Rect.fromLTWH(
        0.0,
        0.0,
        physicalSize.width,
        physicalSize.height,
      ),
      cellSize: Size(
        widget.cellSizeLogical.width * _devicePixelRatio,
        widget.cellSizeLogical.height * _devicePixelRatio,
      ),
      params: params,
      dateYmdSec: date,
      channelResolutions: channels,
    );
  }

  ui.Image? _renderBackgroundForPaint(Size logicalSize) {
    _recordLogicalSize(logicalSize);
    if (!_hasCompiledBackgroundPasses) {
      return null;
    }
    final physicalSize = Size(
      logicalSize.width * _devicePixelRatio,
      logicalSize.height * _devicePixelRatio,
    );
    if (physicalSize.width <= 0.0 || physicalSize.height <= 0.0) {
      return null;
    }
    final backend = widget.controller!.backend;
    if (backend.supportsSyncBackground) {
      final invocations = _buildPassInvocations(
        widget.config.backgroundPasses,
        physicalSize,
      );
      if (invocations.isNotEmpty) {
        final result = _tryRenderBackgroundSync(
          backend,
          invocations,
          physicalSize,
        );
        if (result.image != null) {
          _backgroundDirty = false;
          _replaceBackgroundOutputImage(result.image, notify: false);
          return result.image;
        }
        if (result.failed) {
          return _backgroundOutputImage;
        }
      }
    }
    if (_backgroundDirty || _backgroundOutputImage == null) {
      _backgroundDirty = false;
      _scheduleAsyncBackgroundRender(physicalSize);
    }
    return _backgroundOutputImage;
  }

  ({ui.Image? image, bool failed}) _tryRenderBackgroundSync(
    TerminalShaderBackend backend,
    List<ShaderPassInvocation> invocations,
    Size physicalSize,
  ) {
    try {
      return (
        image: backend.renderBackgroundSync(
          passes: invocations,
          physicalSize: physicalSize,
          wallpaperImage: _effectiveWallpaper,
        ),
        failed: false,
      );
    } on ShaderCompileException catch (error) {
      widget.controller?.reportRuntimeError(error);
      return (image: null, failed: true);
    } on Object catch (error) {
      widget.controller?.reportRuntimeError(
        ShaderCompileException(
          shaderId: invocations.first.handle.id,
          message: 'Background shader render failed: $error',
        ),
      );
      return (image: null, failed: true);
    }
  }

  void _recordLogicalSize(Size logicalSize) {
    final sizeChanged = logicalSize != _lastLogicalSize;
    _lastLogicalSize = logicalSize;
    _syncCursorState(logicalSize);
    if (sizeChanged) {
      _childCaptureDirty = true;
      _backgroundDirty = true;
    }
  }

  void _scheduleAsyncBackgroundRender(Size physicalSize) {
    _pendingAsyncBgPhysicalSize = physicalSize;
    if (_backgroundInFlight) {
      _backgroundPending = true;
      return;
    }
    if (_backgroundPostFrameScheduled) return;
    _backgroundPostFrameScheduled = true;
    final scheduler = SchedulerBinding.instance;
    if (scheduler.schedulerPhase == SchedulerPhase.idle) {
      scheduleMicrotask(() {
        _backgroundPostFrameScheduled = false;
        unawaited(_runAsyncBackgroundPipeline());
      });
      return;
    }
    scheduler.addPostFrameCallback((_) {
      _backgroundPostFrameScheduled = false;
      unawaited(_runAsyncBackgroundPipeline());
    });
  }

  Future<void> _runAsyncBackgroundPipeline() async {
    if (!mounted || !_hasCompiledBackgroundPasses || _backgroundInFlight) {
      return;
    }
    final physicalSize = _pendingAsyncBgPhysicalSize;
    if (physicalSize.width <= 0.0 || physicalSize.height <= 0.0) return;

    final invocations = _buildPassInvocations(
      widget.config.backgroundPasses,
      physicalSize,
    );
    if (invocations.isEmpty) return;

    _backgroundInFlight = true;
    _backgroundPending = false;
    try {
      final nextImage = await widget.controller!.backend.renderPassesAsync(
        passes: invocations,
        physicalSize: physicalSize,
        inputImage: null,
        wallpaperImage: _effectiveWallpaper,
      );
      if (!mounted) {
        nextImage?.dispose();
        return;
      }
      if (nextImage != null) {
        _replaceBackgroundOutputImage(nextImage);
      }
    } on ShaderCompileException catch (error) {
      widget.controller?.reportRuntimeError(error);
    } on Object catch (error) {
      widget.controller?.reportRuntimeError(
        ShaderCompileException(
          shaderId: invocations.first.handle.id,
          message: 'Background shader render failed: $error',
        ),
      );
    } finally {
      _backgroundInFlight = false;
      if (mounted && _backgroundPending && _hasCompiledBackgroundPasses) {
        _backgroundPending = false;
        _scheduleAsyncBackgroundRender(_pendingAsyncBgPhysicalSize);
      }
    }
  }

  void _onForegroundPaint(Size logicalSize) {
    _recordLogicalSize(logicalSize);
    if (!_hasCompiledForegroundPasses) return;
    if (_foregroundOutputImage == null || _childCaptureDirty) {
      _scheduleForegroundRender();
    }
  }

  void _scheduleForegroundRender() {
    if (!mounted || !_hasCompiledForegroundPasses) return;
    if (_foregroundInFlight) {
      _foregroundPending = true;
      return;
    }
    if (_foregroundPostFrameScheduled) return;
    _foregroundPostFrameScheduled = true;
    final scheduler = SchedulerBinding.instance;
    // Never capture in a microtask while _childCaptureDirty is true:
    // activityListenable notifies parent listeners before descendant
    // CustomPaint.markNeedsPaint runs, so debugNeedsPaint may still be false
    // until after the current synchronous notifyListeners() loop completes.
    if (scheduler.schedulerPhase == SchedulerPhase.idle &&
        !_childCaptureDirty &&
        _isCaptureBoundaryReady()) {
      scheduleMicrotask(() {
        _foregroundPostFrameScheduled = false;
        unawaited(_runForegroundPipeline());
      });
      return;
    }
    scheduler.addPostFrameCallback((_) {
      _foregroundPostFrameScheduled = false;
      unawaited(_runForegroundPipeline());
    });
    if (scheduler.schedulerPhase == SchedulerPhase.idle) {
      scheduler.ensureVisualUpdate();
    }
  }

  bool _isCaptureBoundaryReady() {
    final boundary =
        _captureBoundaryKey.currentContext?.findRenderObject()
            as RenderRepaintBoundary?;
    return boundary != null &&
        boundary.attached &&
        boundary.hasSize &&
        !boundary.debugNeedsPaint;
  }

  Future<void> _runForegroundPipeline() async {
    if (!mounted || !_hasCompiledForegroundPasses || _foregroundInFlight) {
      return;
    }
    final boundary =
        _captureBoundaryKey.currentContext?.findRenderObject()
            as RenderRepaintBoundary?;
    if (boundary == null ||
        !boundary.attached ||
        !boundary.hasSize ||
        boundary.debugNeedsPaint) {
      return;
    }

    final logicalSize = boundary.size;
    final physicalSize = Size(
      logicalSize.width * _devicePixelRatio,
      logicalSize.height * _devicePixelRatio,
    );
    if (physicalSize.width <= 0.0 || physicalSize.height <= 0.0) return;

    _foregroundInFlight = true;
    _foregroundPending = false;
    try {
      await _ensureChildCapture(boundary, physicalSize);
      if (!mounted || !_hasCompiledForegroundPasses) return;

      _lastLogicalSize = logicalSize;
      _syncCursorState(logicalSize);
      final invocations = _buildPassInvocations(
        widget.config.foregroundPasses,
        physicalSize,
      );
      if (invocations.isEmpty) return;

      final nextImage = await widget.controller!.backend.renderPassesAsync(
        passes: invocations,
        physicalSize: physicalSize,
        inputImage: _cachedChildCapture,
        wallpaperImage: _effectiveWallpaper,
      );
      if (!mounted) {
        nextImage?.dispose();
        return;
      }
      if (nextImage != null) {
        _replaceForegroundOutputImage(nextImage);
      }
    } on ShaderCompileException catch (error) {
      widget.controller?.reportRuntimeError(error);
    } on Object catch (error) {
      widget.controller?.reportRuntimeError(
        ShaderCompileException(
          shaderId: widget.config.foregroundPasses.first.id,
          message: 'Foreground shader render failed: $error',
        ),
      );
    } finally {
      _foregroundInFlight = false;
      if (mounted && _foregroundPending && _hasCompiledForegroundPasses) {
        _foregroundPending = false;
        _scheduleForegroundRender();
      }
    }
  }

  Future<void> _ensureChildCapture(
    RenderRepaintBoundary boundary,
    Size physicalSize,
  ) async {
    final needsCapture =
        _childCaptureDirty ||
        _cachedChildCapture == null ||
        _cachedChildPhysicalSize != physicalSize;
    if (!needsCapture) return;

    _childCaptureDirty = false;
    final captured = await boundary.toImage(pixelRatio: _devicePixelRatio);
    if (!mounted) {
      captured.dispose();
      return;
    }
    final previous = _cachedChildCapture;
    _cachedChildCapture = captured;
    _cachedChildPhysicalSize = physicalSize;
    if (previous != null && !identical(previous, captured)) {
      _scheduleImageDisposal(previous);
    }
  }

  void _replaceBackgroundOutputImage(ui.Image? next, {bool notify = true}) {
    if (identical(_backgroundOutputImage, next)) return;
    final previous = _backgroundOutputImage;
    _backgroundOutputImage = next;
    if (notify) {
      _frameNotifier.notify();
    }
    if (previous != null) {
      _scheduleImageDisposal(previous);
    }
  }

  void _replaceForegroundOutputImage(ui.Image? next) {
    if (identical(_foregroundOutputImage, next)) return;
    final previous = _foregroundOutputImage;
    _foregroundOutputImage = next;
    _frameNotifier.notify();
    if (previous != null) {
      _scheduleImageDisposal(previous);
    }
  }

  void _scheduleImageDisposal(ui.Image image) {
    if (!mounted) {
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

  @override
  void dispose() {
    _activityTimer?.cancel();
    _activityTimer = null;
    _ticker?.dispose();
    _ticker = null;
    widget.controller?.removeListener(_onControllerChanged);
    widget.activityListenable?.removeListener(_onExternalActivity);
    _backgroundOutputImage?.dispose();
    _backgroundOutputImage = null;
    _foregroundOutputImage?.dispose();
    _foregroundOutputImage = null;
    _directOutputImage?.dispose();
    _directOutputImage = null;
    _cachedChildCapture?.dispose();
    _cachedChildCapture = null;
    _flushPendingImageDisposals();
    _frameNotifier.dispose();
    super.dispose();
  }

  ui.Image? _renderDirectForPaint(Size logicalSize) {
    if (logicalSize.isEmpty) return null;
    _recordLogicalSize(logicalSize);
    _syncCursorState(logicalSize);

    final backend = _directBackend;
    final atlasImage = widget.atlasImage;
    final provider = widget.directTerminalBatchProvider;
    if (backend == null || atlasImage == null || provider == null) {
      _enterDirectFallbackPostFrame(_DirectFallbackReason.priming);
      return _directBridgeImageFor(logicalSize);
    }
    if (!_isAtlasDprMatched) {
      _enterDirectFallbackPostFrame(_DirectFallbackReason.dprMismatch);
      return _directBridgeImageFor(logicalSize);
    }

    final physicalSize = Size(
      logicalSize.width * _devicePixelRatio,
      logicalSize.height * _devicePixelRatio,
    );
    if (physicalSize.width <= 0.0 || physicalSize.height <= 0.0) return null;

    final batch = provider(logicalSize, _devicePixelRatio);
    if (batch == null || batch.hasCanvasOnlyContent) {
      _enterDirectFallbackPostFrame(_DirectFallbackReason.canvasOnly);
      return _directBridgeImageFor(logicalSize);
    }

    final bgInvocations = _hasCompiledBackgroundPasses
        ? _buildPassInvocations(widget.config.backgroundPasses, physicalSize)
        : const <ShaderPassInvocation>[];
    final fgInvocations = _hasCompiledForegroundPasses
        ? _buildPassInvocations(widget.config.foregroundPasses, physicalSize)
        : const <ShaderPassInvocation>[];

    final result = _tryRenderDirectSync(
      backend: backend,
      backgroundPasses: bgInvocations,
      foregroundPasses: fgInvocations,
      physicalSize: physicalSize,
      atlasImage: atlasImage,
      batch: batch,
    );
    if (result.image != null) {
      _directOutputLogicalSize = logicalSize;
      _replaceDirectOutputImage(result.image);
      return result.image;
    }

    if (!result.failed) {
      _prepareDirectResourcesAsync(backend, atlasImage, batch);
    }
    _enterDirectFallbackPostFrame(_DirectFallbackReason.priming);
    return _directBridgeImageFor(logicalSize);
  }

  ({ui.Image? image, bool failed}) _tryRenderDirectSync({
    required DirectTerminalShaderBackend backend,
    required List<ShaderPassInvocation> backgroundPasses,
    required List<ShaderPassInvocation> foregroundPasses,
    required Size physicalSize,
    required ui.Image atlasImage,
    required GpuAtlasQuadBatch batch,
  }) {
    try {
      return (
        image: backend.renderTerminalFrameSync(
          backgroundPasses: backgroundPasses,
          foregroundPasses: foregroundPasses,
          physicalSize: physicalSize,
          atlasImage: atlasImage,
          batch: batch,
          wallpaperImage: _effectiveWallpaper,
        ),
        failed: false,
      );
    } on ShaderCompileException catch (error) {
      widget.controller?.reportRuntimeError(error);
      return (image: null, failed: true);
    } on Object catch (error) {
      final firstId = foregroundPasses.isNotEmpty
          ? foregroundPasses.first.handle.id
          : (backgroundPasses.isNotEmpty
                ? backgroundPasses.first.handle.id
                : 'direct_gpu_atlas');
      widget.controller?.reportRuntimeError(
        ShaderCompileException(
          shaderId: firstId,
          message: 'Direct GPU terminal render failed: $error',
        ),
      );
      return (image: null, failed: true);
    }
  }

  void _prepareDirectResourcesAsync(
    DirectTerminalShaderBackend backend,
    ui.Image atlasImage,
    GpuAtlasQuadBatch batch,
  ) {
    if (_directPrepareInFlight) return;
    _directPrepareInFlight = true;
    final kittyImages = <ui.Image>[
      for (final quad in batch.kittyQuads) quad.image,
    ];
    unawaited(
      backend
          .prepareDirectResources(
            atlasImage: atlasImage,
            wallpaperImage: _effectiveWallpaper,
            kittyImages: kittyImages,
          )
          .then((ready) {
            _directPrepareInFlight = false;
            if (!mounted || !ready) return;
            if (_directFallbackReason == _DirectFallbackReason.priming) {
              _directFallbackReason = _DirectFallbackReason.none;
              if (_directFallbackActive) {
                setState(() {
                  _directFallbackActive = false;
                });
              }
            }
            _frameNotifier.notify();
          })
          .catchError((Object _) {
            _directPrepareInFlight = false;
          }),
    );
  }

  void _enterDirectFallbackPostFrame(_DirectFallbackReason reason) {
    _directFallbackReason = reason;
    if (_directFallbackActive || _directFallbackScheduled) return;
    _directFallbackScheduled = true;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _directFallbackScheduled = false;
      if (!mounted ||
          _directFallbackActive ||
          _directFallbackReason == _DirectFallbackReason.none) {
        return;
      }
      if (!_canUseDirectTerminalRender) return;
      setState(() {
        _directFallbackActive = true;
      });
      if (_hasCompiledForegroundPasses) {
        _childCaptureDirty = true;
        _scheduleForegroundRender();
      }
    });
  }

  bool _probeCanvasOnlyRecovery({required bool callSetState}) {
    final provider = widget.directTerminalBatchProvider;
    final size = widget.directLogicalSize;
    if (provider == null || size == null || size.isEmpty) return false;
    final probe = provider(size, _devicePixelRatio);
    if (probe == null || probe.hasCanvasOnlyContent) return false;
    if (callSetState) {
      setState(() {
        _directFallbackActive = false;
        _directFallbackReason = _DirectFallbackReason.none;
      });
    } else {
      _directFallbackActive = false;
      _directFallbackReason = _DirectFallbackReason.none;
    }
    _frameNotifier.notify();
    return true;
  }

  ui.Image? _directBridgeImageFor(Size logicalSize) =>
      _directOutputLogicalSize == logicalSize ? _directOutputImage : null;

  void _replaceDirectOutputImage(ui.Image? next) {
    final previous = _directOutputImage;
    if (identical(previous, next)) return;
    _directOutputImage = next;
    if (previous != null) {
      _scheduleImageDisposal(previous);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isDirectModeActive) {
      final logicalSize = widget.directLogicalSize!;
      return SizedBox.fromSize(
        size: logicalSize,
        child: RepaintBoundary(
          child: CustomPaint(
            size: logicalSize,
            painter: _DirectTerminalPainter(
              repaint: _frameNotifier,
              renderDirect: _renderDirectForPaint,
              backgroundColor: Color(widget.backgroundArgb | 0xFF000000),
            ),
          ),
        ),
      );
    }
    if (_isInactive) {
      return widget.child;
    }

    final hasBackground =
        _effectiveWallpaper != null || _hasCompiledBackgroundPasses;
    final Widget baseLayer = hasBackground
        ? Stack(
            fit: StackFit.passthrough,
            children: <Widget>[
              Positioned.fill(
                child: RepaintBoundary(
                  child: CustomPaint(
                    painter: _BackgroundShaderPainter(
                      repaint: _frameNotifier,
                      wallpaper: _effectiveWallpaper,
                      renderBackground: _renderBackgroundForPaint,
                    ),
                  ),
                ),
              ),
              widget.child,
            ],
          )
        : widget.child;

    if (!_hasCompiledForegroundPasses) {
      return baseLayer;
    }

    return Stack(
      fit: StackFit.passthrough,
      children: <Widget>[
        RepaintBoundary(key: _captureBoundaryKey, child: baseLayer),
        Positioned.fill(
          child: IgnorePointer(
            child: RepaintBoundary(
              child: CustomPaint(
                painter: _ForegroundShaderPainter(
                  repaint: _frameNotifier,
                  imageProvider: () => _foregroundOutputImage,
                  backgroundColor: Color(widget.backgroundArgb | 0xFF000000),
                  onPaintSize: _onForegroundPaint,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

final class _ShaderFrameNotifier extends ChangeNotifier {
  void notify() => notifyListeners();
}

enum _DirectFallbackReason { none, priming, canvasOnly, dprMismatch }

final class _DirectTerminalPainter extends CustomPainter {
  final ui.Image? Function(Size logicalSize) renderDirect;
  final Color backgroundColor;

  static final Paint _imagePaint = Paint()..filterQuality = FilterQuality.none;

  _DirectTerminalPainter({
    required Listenable repaint,
    required this.renderDirect,
    required this.backgroundColor,
  }) : super(repaint: repaint);

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final image = renderDirect(size);
    if (image == null) {
      canvas.drawRect(Offset.zero & size, Paint()..color = backgroundColor);
      return;
    }
    canvas.drawImageRect(
      image,
      Rect.fromLTWH(0.0, 0.0, image.width.toDouble(), image.height.toDouble()),
      Offset.zero & size,
      _imagePaint,
    );
  }

  @override
  bool? hitTest(Offset position) => true;

  @override
  bool shouldRepaint(covariant _DirectTerminalPainter oldDelegate) =>
      oldDelegate.backgroundColor != backgroundColor;
}

final class _BackgroundShaderPainter extends CustomPainter {
  final ui.Image? wallpaper;
  final ui.Image? Function(Size logicalSize) renderBackground;

  static final Paint _imagePaint = Paint()..filterQuality = FilterQuality.low;

  _BackgroundShaderPainter({
    required Listenable repaint,
    required this.wallpaper,
    required this.renderBackground,
  }) : super(repaint: repaint);

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final rendered = renderBackground(size);
    if (rendered != null) {
      canvas.drawImageRect(
        rendered,
        Rect.fromLTWH(
          0.0,
          0.0,
          rendered.width.toDouble(),
          rendered.height.toDouble(),
        ),
        Offset.zero & size,
        _imagePaint,
      );
      return;
    }
    final fallbackWallpaper = wallpaper;
    if (fallbackWallpaper != null) {
      _paintCoverImage(canvas, fallbackWallpaper, size);
    }
  }

  static void _paintCoverImage(Canvas canvas, ui.Image image, Size targetSize) {
    final imageSize = Size(image.width.toDouble(), image.height.toDouble());
    final fitted = applyBoxFit(BoxFit.cover, imageSize, targetSize);
    final srcRect = Alignment.center.inscribe(
      fitted.source,
      Offset.zero & imageSize,
    );
    final dstRect = Alignment.center.inscribe(
      fitted.destination,
      Offset.zero & targetSize,
    );
    canvas.drawImageRect(image, srcRect, dstRect, _imagePaint);
  }

  @override
  bool shouldRepaint(covariant _BackgroundShaderPainter oldDelegate) =>
      !identical(oldDelegate.wallpaper, wallpaper);
}

final class _ForegroundShaderPainter extends CustomPainter {
  final ui.Image? Function() imageProvider;
  final Color backgroundColor;
  final void Function(Size logicalSize) onPaintSize;

  static final Paint _imagePaint = Paint()..filterQuality = FilterQuality.low;

  _ForegroundShaderPainter({
    required Listenable repaint,
    required this.imageProvider,
    required this.backgroundColor,
    required this.onPaintSize,
  }) : super(repaint: repaint);

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    onPaintSize(size);
    final image = imageProvider();
    if (image == null) return;
    // Occlude the live un-shaded baseLayer underneath so translucent foreground
    // outputs (e.g. scanline with backgroundOpacity < 1.0) or distorted passes
    // (e.g. crt_lottes) never let a stale/raw cursor bleed through.
    canvas.drawRect(Offset.zero & size, Paint()..color = backgroundColor);
    canvas.drawImageRect(
      image,
      Rect.fromLTWH(0.0, 0.0, image.width.toDouble(), image.height.toDouble()),
      Offset.zero & size,
      _imagePaint,
    );
  }

  @override
  bool shouldRepaint(covariant _ForegroundShaderPainter oldDelegate) =>
      oldDelegate.backgroundColor != backgroundColor;
}
