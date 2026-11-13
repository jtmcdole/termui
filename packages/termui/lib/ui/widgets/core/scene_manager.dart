import 'dart:async';
import 'package:characters/characters.dart';
import 'package:clock/clock.dart';
import 'dart:collection';
import 'dart:math';
import 'package:termui/termui.dart';

/// Manages multiple visual layers in a terminal windowing system,
/// handles rendering composition and hardware sync.
class SceneManager implements Reassemblable {
  static final int _traceKeyEventId = Tracer.registerString(
    'SceneManager:handleKeyEvent',
  );
  static final int _traceMouseEventId = Tracer.registerString(
    'SceneManager:handleMouseEvent',
  );
  static final int _traceRenderId = Tracer.registerString(
    'SceneManager:render',
  );

  /// The hardware/platform terminal wrapper.
  final Terminal terminal;

  /// The rendering mode for the compositor.
  final RenderingMode renderingMode;

  /// The list of layers to composite and render.
  late final List<SceneLayer> layers;

  SceneLayer? _focusedLayer;
  final List<SceneLayer> _focusStack = [];
  final Set<SceneLayer> _nonFocusableLayers = {};
  int _focusEpoch = 0;

  void _requestRunnerFocus(SceneLayer layer) {
    if (layer.renderer case final PromptRunner<Object?> runner) {
      runner.requestFocus();
    }
  }

  /// The currently focused layer, if any. Used to sync hardware state.
  SceneLayer? get focusedLayer => _focusedLayer;
  set focusedLayer(SceneLayer? layer) {
    _focusEpoch++;
    if (_focusedLayer == layer) return;
    _focusedLayer = layer;
    if (layer != null) {
      _focusStack.remove(layer);
      _focusStack.add(layer);
      _requestRunnerFocus(layer);
    }
  }

  /// Whether mouse tracking is explicitly forced/enabled.
  bool enableMouseTracking = false;

  /// Whether [debugToggleKey] toggles visual debug overlays for this scene.
  bool enableDebugToggleKey = true;

  /// Optional callback invoked whenever a composited frame is completely rendered.
  void Function(Buffer buffer)? onFrameRedrawn;

  /// Optional callback to intercept key events before they are routed to the focused layer.
  /// If this returns true, the event is consumed and not propagated.
  bool Function(KeyEvent event)? onKeyEvent;

  /// Optional callback to intercept paste events before they are routed to the focused layer.
  /// If this returns true, the event is consumed and not propagated.
  bool Function(PasteEvent event)? onPasteEvent;

  bool _isDisposed = false;
  bool _renderScheduled = false;
  final Set<ListenableSceneRenderer> _activeRenderers = {};
  late final void Function() _handleLayerVisualUpdate = scheduleRender;
  final Map<SceneRenderer, Point<int>> _lastRequestedSizes = {};
  bool _isRendering = false;
  bool _renderRequestedWhileRendering = false;

  final Compositor _compositor = Compositor();
  final List<_TouchFeedback> _activeTouches = [];

  /// Exposes the sub-pixel ripple manager for composite drop effects and click feedback.
  final SubpixelRippleManager rippleManager = SubpixelRippleManager();

  Timer? _debugTouchTimer;
  Renderer? _renderer;
  Buffer? _targetBuffer;

  StreamSubscription<InputEvent>? _eventsSubscription;
  StreamSubscription<Point<int>>? _sizeSubscription;

  SceneLayer? _draggingLayer;
  SceneLayer? _resizingLayer;
  int _resizeCorner = 0; // 0: None, 1: TL, 2: TR, 3: BL, 4: BR
  int _layerStartWidth = 0;
  int _layerStartHeight = 0;
  SceneLayer? _capturedMouseLayer;
  int _dragStartX = 0;
  int _dragStartY = 0;
  int _layerStartX = 0;
  int _layerStartY = 0;

  int? _globalMouseX;
  int? _globalMouseY;
  bool _isGlobalMouseDown = false;

  /// Exposes the internal renderer.
  Renderer? get renderer => _renderer;

  bool? _lastShowsCursor;
  bool? _lastWantsMouseTracking;

  /// Creates a new SceneManager attached to the given [terminal].
  SceneManager(this.terminal, {this.renderingMode = RenderingMode.inline}) {
    layers = _SceneLayerList(this);
    _eventsSubscription = terminal.events.listen(_handleInputEvent);
    _sizeSubscription = terminal.watchSize().listen(_handleSizeEvent);
    TermuiBinding.register(this);
  }

  void _resizeRenderer(SceneRenderer renderer, int w, int h) {
    final targetSize = Point<int>(w, h);
    if (_lastRequestedSizes[renderer] != targetSize) {
      _lastRequestedSizes[renderer] = targetSize;
      renderer.resize(w, h);
    }
  }

  void _handleSizeEvent(Point<int> newSize) {
    final width = newSize.x;
    final height = newSize.y;
    if (width <= 0 || height <= 0) return;

    for (final layer in layers) {
      if (layer.sizing == LayerSizing.fullscreen) {
        layer.x = 0;
        layer.y = 0;
        _resizeRenderer(layer.renderer, width, height);
      }
      layer.onResize?.call(newSize);
    }
    render();
  }

  void _cleanOrphanedLayers() {
    if (focusedLayer != null && !layers.contains(focusedLayer)) {
      focusedLayer = null;
    }
    if (_draggingLayer != null && !layers.contains(_draggingLayer)) {
      _draggingLayer = null;
    }
    if (_capturedMouseLayer != null && !layers.contains(_capturedMouseLayer)) {
      _capturedMouseLayer = null;
    }
  }

  void _onLayerRemoved(SceneLayer layer) {
    _lastRequestedSizes.remove(layer.renderer);
    _nonFocusableLayers.remove(layer);
    _focusStack.remove(layer);

    SceneLayer? restoredLayer;
    if (focusedLayer == layer) {
      _focusedLayer = null; // Bypass setter to prevent redundant stack changes
      while (_focusStack.isNotEmpty) {
        final candidate = _focusStack.last;
        if (layers.contains(candidate)) {
          _focusedLayer = candidate;
          _requestRunnerFocus(candidate);
          restoredLayer = candidate;
          break;
        }
        _focusStack.removeLast();
      }
    }

    if (_draggingLayer == layer) _draggingLayer = null;
    if (_capturedMouseLayer == layer) _capturedMouseLayer = null;
    if (_resizingLayer == layer) {
      _resizingLayer = null;
      _resizeCorner = 0;
    }
    _syncLayerListeners();
    restoredLayer?.onFocus?.call();
  }

  List<SceneLayer> _getSortedLayers() {
    final packed = [
      for (var i = 0; i < layers.length; i++) (layer: layers[i], index: i),
    ];
    packed.sort((a, b) {
      final cmp = b.layer.zIndex.compareTo(a.layer.zIndex);
      if (cmp != 0) return cmp;
      return b.index.compareTo(a.index);
    });
    return [for (final p in packed) p.layer];
  }

  SceneLayer? _lastHoveredLayer;

  /// Handles a keyboard event and routes it to the focused layer.
  void handleKeyEvent(KeyEvent event) {
    Tracer.record(
      _traceKeyEventId,
      Phase.begin,
      TraceCategory.events,
      metadata: {'key': event.traceKey},
    );
    try {
      _routeKeyEvent(event);
    } finally {
      Tracer.record(_traceKeyEventId, Phase.end, TraceCategory.events);
    }
  }

  void _routeKeyEvent(KeyEvent event) {
    if (event.eventType == KeyEventType.release) {
      focusedLayer?.renderer.handleKeyEvent(event);
      return;
    }

    if (enableDebugToggleKey &&
        debugToggleKey != null &&
        event == debugToggleKey) {
      debugShowTouchesEnabled = !debugShowTouchesEnabled;
      debugPaintHoverEnabled = !debugPaintHoverEnabled;
      debugMouseCursorEnabled = !debugMouseCursorEnabled;
      debugPaintLayerBordersEnabled = !debugPaintLayerBordersEnabled;
      scheduleRender();
      return;
    }

    if (onKeyEvent?.call(event) ?? false) {
      return;
    }

    final handled = focusedLayer?.renderer.handleKeyEvent(event) ?? false;
    if (!handled) {
      _clearHoverState();
    }
  }

  void _clearHoverState() {
    _globalMouseX = null;
    _globalMouseY = null;
    if (_lastHoveredLayer != null) {
      final localEvent = MouseEvent(
        x: -1,
        y: -1,
        globalX: -1,
        globalY: -1,
        button: MouseButton.none,
        type: MouseEventType.move,
        modifiers: const {},
      );
      _lastHoveredLayer!.renderer.handleMouseEvent(localEvent);
      _lastHoveredLayer = null;
    }
  }

  /// Handles a mouse event, performing hit testing and routing to layers.
  void handleMouseEvent(MouseEvent event) {
    final meta = <String, String>{
      'button': event.button.name,
      'type': event.type.name,
      'pos': '${event.x},${event.y}',
      if (event.modifiers.isNotEmpty)
        'modifiers': [for (final m in event.modifiers) m.name].join('+'),
    };

    Tracer.record(
      _traceMouseEventId,
      Phase.begin,
      TraceCategory.events,
      metadata: meta,
    );
    try {
      _globalMouseX = event.x - 1;
      _globalMouseY = event.y - 1;
      _isGlobalMouseDown =
          event.type == MouseEventType.press ||
          event.type == MouseEventType.drag;
      _recordDebugTouch(event);

      final didRender = switch (event.type) {
        MouseEventType.press => _handleMousePress(event),
        MouseEventType.drag => _handleMouseDrag(event),
        MouseEventType.release => _handleMouseRelease(event),
        _ => _handleMouseHover(event),
      };

      if (debugMouseCursorEnabled && !didRender) {
        render();
      }
    } finally {
      Tracer.record(_traceMouseEventId, Phase.end, TraceCategory.events);
    }
  }

  void _recordDebugTouch(MouseEvent event) {
    if (!debugShowTouchesEnabled) return;
    if (event.type != MouseEventType.press &&
        event.type != MouseEventType.release) {
      return;
    }
    _activeTouches.add(
      _TouchFeedback(
        x: _globalMouseX!,
        y: _globalMouseY!,
        button: event.button,
        type: event.type,
        startTime: clock.now().millisecondsSinceEpoch,
      ),
    );
    addRipple(Point<int>(event.x, event.y));
  }

  MouseEvent _toLocalMouseEvent(SceneLayer layer, MouseEvent event) =>
      MouseEvent(
        x: event.x - layer.x,
        y: event.y - layer.y,
        globalX: event.globalX ?? event.x,
        globalY: event.globalY ?? event.y,
        pixelX: event.pixelX,
        pixelY: event.pixelY,
        button: event.button,
        type: event.type,
        modifiers: event.modifiers,
      );

  static bool _containsLayerPoint(
    SceneLayer layer,
    Buffer buf,
    int mouseX,
    int mouseY,
  ) =>
      mouseX >= layer.x &&
      mouseX < layer.x + buf.width &&
      mouseY >= layer.y &&
      mouseY < layer.y + buf.height;

  static int _detectResizeCorner(
    SceneLayer layer,
    Buffer buf,
    int mouseX,
    int mouseY,
  ) {
    final onLeft = mouseX == layer.x;
    final onRight = mouseX == layer.x + buf.width - 1;
    final onTop = mouseY == layer.y;
    final onBottom = mouseY == layer.y + buf.height - 1;
    if (onLeft && onTop) return 1;
    if (onRight && onTop) return 2;
    if (onLeft && onBottom) return 3;
    if (onRight && onBottom) return 4;
    return 0;
  }

  bool _handleMousePress(MouseEvent event) {
    final mouseX = event.x - 1;
    final mouseY = event.y - 1;
    final focusBeforePress = focusedLayer;
    final focusEpochBeforePress = _focusEpoch;

    SceneLayer? hitLayer;
    for (final layer in _getSortedLayers()) {
      final (stop, candidate) = _probeLayerPress(layer, mouseX, mouseY, event);
      if (stop) {
        hitLayer = candidate;
        break;
      }
    }

    _reconcilePressHit(
      hitLayer: hitLayer,
      button: event.button,
      focusBeforePress: focusBeforePress,
      focusEpochBeforePress: focusEpochBeforePress,
    );
    return false;
  }

  (bool stop, SceneLayer? hitLayer) _probeLayerPress(
    SceneLayer layer,
    int mouseX,
    int mouseY,
    MouseEvent event,
  ) {
    if (!layer.hitTestable) return (false, null);
    final buf = layer.renderer.currentBuffer;
    if (buf == null || !_containsLayerPoint(layer, buf, mouseX, mouseY)) {
      return (false, null);
    }

    final corner = layer.resizable
        ? _detectResizeCorner(layer, buf, mouseX, mouseY)
        : 0;
    if (corner != 0) {
      _beginLayerResize(layer, buf, corner, event);
      return (true, layer);
    }

    final localX = mouseX - layer.x;
    final localY = mouseY - layer.y;
    final isOpaque =
        (buf.getModifiers(localX, localY) & Modifier.transparent) == 0;
    final handled = layer.renderer.handleMouseEvent(
      _toLocalMouseEvent(layer, event),
    );
    if (handled || layer.draggable) {
      if (layer.draggable && layers.contains(layer)) {
        _beginLayerDrag(layer, event);
      }
      return (true, layer);
    }
    if (isOpaque) {
      return (true, layer.mouseOpaque ? layer : null);
    }
    return (false, null);
  }

  void _beginLayerResize(
    SceneLayer layer,
    Buffer buf,
    int corner,
    MouseEvent event,
  ) {
    _resizingLayer = layer;
    _resizeCorner = corner;
    _dragStartX = event.x;
    _dragStartY = event.y;
    _layerStartX = layer.x;
    _layerStartY = layer.y;
    _layerStartWidth = layer.width ?? buf.width;
    _layerStartHeight = layer.height ?? buf.height;
  }

  void _beginLayerDrag(SceneLayer layer, MouseEvent event) {
    _draggingLayer = layer;
    _dragStartX = event.x;
    _dragStartY = event.y;
    _layerStartX = layer.x;
    _layerStartY = layer.y;
  }

  bool _handleMouseDrag(MouseEvent event) {
    if (_resizingLayer != null) {
      _performLayerResize(event);
      return true;
    }
    if (_draggingLayer != null) {
      _draggingLayer!.x = _layerStartX + (event.x - _dragStartX);
      _draggingLayer!.y = _layerStartY + (event.y - _dragStartY);
      render();
      return true;
    }
    if (_capturedMouseLayer case final captured?) {
      captured.renderer.handleMouseEvent(_toLocalMouseEvent(captured, event));
    }
    return false;
  }

  void _performLayerResize(MouseEvent event) {
    final movesLeft = _resizeCorner == 1 || _resizeCorner == 3;
    final movesTop = _resizeCorner == 1 || _resizeCorner == 2;
    final dx = _clampResizeDelta(
      event.x - _dragStartX,
      _layerStartWidth,
      10,
      movesStartEdge: movesLeft,
    );
    final dy = _clampResizeDelta(
      event.y - _dragStartY,
      _layerStartHeight,
      5,
      movesStartEdge: movesTop,
    );

    final newX = movesLeft ? _layerStartX + dx : _layerStartX;
    final newY = movesTop ? _layerStartY + dy : _layerStartY;
    final newW = movesLeft ? _layerStartWidth - dx : _layerStartWidth + dx;
    final newH = movesTop ? _layerStartHeight - dy : _layerStartHeight + dy;

    final layer = _resizingLayer!;
    layer.x = newX;
    layer.y = newY;
    layer.width = newW;
    layer.height = newH;
    _resizeRenderer(layer.renderer, newW, newH);
    render();
  }

  static int _clampResizeDelta(
    int delta,
    int startSize,
    int minSize, {
    required bool movesStartEdge,
  }) {
    if (movesStartEdge) {
      return startSize - delta < minSize ? startSize - minSize : delta;
    }
    return startSize + delta < minSize ? minSize - startSize : delta;
  }

  bool _handleMouseRelease(MouseEvent event) {
    if (_resizingLayer != null) {
      _resizingLayer = null;
      _resizeCorner = 0;
      _capturedMouseLayer = null;
      return false;
    }
    final targetLayer = _draggingLayer ?? _capturedMouseLayer;
    if (targetLayer != null) {
      targetLayer.renderer.handleMouseEvent(
        _toLocalMouseEvent(targetLayer, event),
      );
    }
    _draggingLayer = null;
    _capturedMouseLayer = null;
    return false;
  }

  bool _handleMouseHover(MouseEvent event) {
    final hitLayer = _findHoveredLayer(event.x - 1, event.y - 1, event);
    if (_lastHoveredLayer != null && _lastHoveredLayer != hitLayer) {
      _lastHoveredLayer!.renderer.handleMouseEvent(
        MouseEvent(
          x: -1,
          y: -1,
          globalX: event.globalX ?? event.x,
          globalY: event.globalY ?? event.y,
          button: event.button,
          type: event.type,
          modifiers: event.modifiers,
        ),
      );
    }
    _lastHoveredLayer = hitLayer;
    return false;
  }

  SceneLayer? _findHoveredLayer(int mouseX, int mouseY, MouseEvent event) {
    for (final layer in _getSortedLayers()) {
      if (!layer.hitTestable) continue;
      final buf = layer.renderer.currentBuffer;
      if (buf == null || !_containsLayerPoint(layer, buf, mouseX, mouseY)) {
        continue;
      }

      final localX = mouseX - layer.x;
      final localY = mouseY - layer.y;
      final isOpaque =
          (buf.getModifiers(localX, localY) & Modifier.transparent) == 0;
      if (layer.renderer.handleMouseEvent(_toLocalMouseEvent(layer, event))) {
        return layer;
      }
      if (isOpaque) {
        return layer.mouseOpaque ? layer : null;
      }
    }
    return null;
  }

  void _cancelPressCapture(SceneLayer? layer, MouseButton button) {
    _draggingLayer = null;
    _resizingLayer = null;
    _resizeCorner = 0;
    _capturedMouseLayer = null;
    DragDropManager.cancelDrag();
    if (layer != null && layers.contains(layer)) {
      layer.renderer.handleMouseEvent(
        MouseEvent(
          x: -1,
          y: -1,
          globalX: -1,
          globalY: -1,
          button: button,
          type: MouseEventType.release,
          modifiers: const {},
        ),
      );
    }
  }

  void _reconcilePressHit({
    required SceneLayer? hitLayer,
    required MouseButton button,
    required SceneLayer? focusBeforePress,
    required int focusEpochBeforePress,
  }) {
    if (hitLayer == null || !layers.contains(hitLayer)) {
      _cancelPressCapture(null, button);
      return;
    }
    if (_nonFocusableLayers.contains(hitLayer)) {
      _capturedMouseLayer = hitLayer;
      return;
    }

    final focusChanged =
        _focusEpoch != focusEpochBeforePress && focusedLayer != hitLayer;
    if (focusChanged) {
      _cancelPressCapture(hitLayer, button);
      if (focusedLayer != null && focusBeforePress != hitLayer) {
        _focusStack.remove(hitLayer);
        _focusStack.insert(_focusStack.length - 1, hitLayer);
      }
      return;
    }

    _capturedMouseLayer = hitLayer;
    if (focusedLayer != hitLayer) {
      focusedLayer = hitLayer;
    }
    if (focusBeforePress == hitLayer) return;

    final epochBeforeOnFocus = _focusEpoch;
    hitLayer.onFocus?.call();
    final lostFocusInCallback =
        _focusEpoch != epochBeforeOnFocus && focusedLayer != hitLayer;
    if (!layers.contains(hitLayer) || lostFocusInCallback) {
      _cancelPressCapture(hitLayer, button);
      return;
    }
    scheduleRender();
  }

  /// Spawns a new expanding touch ripple at [position] and triggers composite rendering.
  void addRipple(
    Point<int> position, {
    Color color = Colors.white,
    int durationMs = 500,
  }) {
    rippleManager.addRipple(position, color: color, durationMs: durationMs);
    _startRippleTimer();
  }

  void _startRippleTimer() {
    if (_debugTouchTimer != null && _debugTouchTimer!.isActive) return;
    _debugTouchTimer = Timer.periodic(const Duration(milliseconds: 16), (
      timer,
    ) {
      final now = clock.now().millisecondsSinceEpoch;
      _activeTouches.removeWhere((t) => now - t.startTime > 500);
      rippleManager.updateRipples(now);
      scheduleRender();
      if (_activeTouches.isEmpty && !rippleManager.hasActiveRipples) {
        timer.cancel();
        _debugTouchTimer = null;
      }
    });
  }

  /// Handles a paste event and routes it to the focused layer.
  void handlePasteEvent(PasteEvent event) {
    if (onPasteEvent?.call(event) ?? false) {
      return;
    }
    final r = focusedLayer?.renderer;
    if (r != null && !r.handlePasteEvent(event)) {
      for (final char in event.text.characters) {
        r.handleKeyEvent(KeyEvent(char, KeyType.character));
      }
    }
  }

  void _handleInputEvent(InputEvent event) {
    _cleanOrphanedLayers();
    switch (event) {
      case final KeyEvent e:
        handleKeyEvent(e);
      case final MouseEvent e:
        handleMouseEvent(e);
      case final PasteEvent e:
        handlePasteEvent(e);
      case FocusInEvent():
      case FocusOutEvent():
      case CursorPositionReportEvent():
      case KittyGraphicsEvent():
      case KittyKeyboardEvent():
      case AudioApcReplyEvent():
        break;
    }
  }

  /// Composites all active layers into a single flattened terminal output
  /// and writes it to the terminal.
  void render() {
    if (_isDisposed) return;
    if (_isRendering) {
      _renderRequestedWhileRendering = true;
      return;
    }
    _isRendering = true;
    try {
      _renderScheduled = false;
      Tracer.record(_traceRenderId, Phase.begin, TraceCategory.compositor);
      try {
        _renderFrame();
      } finally {
        Tracer.record(_traceRenderId, Phase.end, TraceCategory.compositor);
      }
    } finally {
      _isRendering = false;
      if (_renderRequestedWhileRendering) {
        _renderRequestedWhileRendering = false;
        scheduleRender();
      }
    }
  }

  void _renderFrame() {
    _cleanOrphanedLayers();
    _renderDirtyLayers();

    final (width, height) = _resolveViewportSize();
    final renderer = _renderer ??= Renderer(width, height, mode: renderingMode);
    final layeredBuffers = _collectLayeredBuffers(width, height);
    final target = _prepareTargetBuffer(width, height);

    // Any scheduleRender() calls triggered synchronously by r.render() or
    // _resizeRenderer() above are satisfied by the composite pass below.
    _renderRequestedWhileRendering = false;

    // The Compositor natively handles occlusion culling and off-screen
    // effect layer resolution using recursive saveLayer/backdrop filter patterns.
    _compositor.composite(target: target, layers: layeredBuffers);
    _paintDebugMouseCursor(target);
    _renderDebugOverlays(target);
    _flushRenderedFrame(renderer, target);
    _syncHardwareState(width, height);
  }

  void _renderDirtyLayers() {
    for (final layer in layers) {
      final r = layer.renderer;
      if (r is ListenableSceneRenderer && r.isDirty) {
        r.render();
      }
    }
  }

  (int width, int height) _resolveViewportSize() {
    final size = terminal.backend.size;
    if (size.x <= 0 || size.y <= 0) return (80, 24);
    return (size.x, size.y);
  }

  Buffer _prepareTargetBuffer(int width, int height) {
    final target = _targetBuffer ??= Buffer(width, height);
    if (target.width != width || target.height != height) {
      target.resize(width, height);
    }
    target.clear();
    return target;
  }

  List<LayeredBuffer> _collectLayeredBuffers(int width, int height) {
    final layeredBuffers = <LayeredBuffer>[];
    for (final layer in layers) {
      _syncLayerSize(layer, width, height);
      final buffer = layer.renderer.currentBuffer;
      if (buffer == null) continue;

      layeredBuffers.add(
        LayeredBuffer(
          buffer: buffer,
          x: layer.x,
          y: layer.y,
          zIndex: layer.zIndex,
        ),
      );
      if (debugPaintLayerBordersEnabled) {
        _appendDebugLayerBorders(layeredBuffers, layer, buffer);
      }
    }
    return layeredBuffers;
  }

  void _syncLayerSize(SceneLayer layer, int width, int height) {
    if (layer.sizing == LayerSizing.fullscreen) {
      if (layer.width != width || layer.height != height) {
        layer.width = width;
        layer.height = height;
        _resizeRenderer(layer.renderer, width, height);
      }
      return;
    }
    final layerW = layer.width;
    final layerH = layer.height;
    if (layerW == null || layerH == null) return;
    final buf = layer.renderer.currentBuffer;
    if (buf == null || buf.width != layerW || buf.height != layerH) {
      _resizeRenderer(layer.renderer, layerW, layerH);
    }
  }

  static void _appendDebugLayerBorders(
    List<LayeredBuffer> layeredBuffers,
    SceneLayer layer,
    Buffer buffer,
  ) {
    final w = buffer.width;
    final h = buffer.height;
    const style = Style(foreground: Colors.yellow, modifiers: Modifier.bold);

    final top = Buffer(w + 2, 1)..writeString(0, 0, '┌${'─' * w}┐', style);
    final bottom = Buffer(w + 2, 1)..writeString(0, 0, '└${'─' * w}┘', style);
    final left = Buffer(1, h);
    final right = Buffer(1, h);
    for (var y = 0; y < h; y++) {
      left.writeString(0, y, '│', style);
      right.writeString(0, y, '│', style);
    }

    layeredBuffers.addAll([
      LayeredBuffer(
        buffer: top,
        x: layer.x - 1,
        y: layer.y - 1,
        zIndex: layer.zIndex,
      ),
      LayeredBuffer(
        buffer: bottom,
        x: layer.x - 1,
        y: layer.y + h,
        zIndex: layer.zIndex,
      ),
      LayeredBuffer(
        buffer: left,
        x: layer.x - 1,
        y: layer.y,
        zIndex: layer.zIndex,
      ),
      LayeredBuffer(
        buffer: right,
        x: layer.x + w,
        y: layer.y,
        zIndex: layer.zIndex,
      ),
    ]);
  }

  void _paintDebugMouseCursor(Buffer target) {
    final globalMouseX = _globalMouseX;
    final globalMouseY = _globalMouseY;
    if (!debugMouseCursorEnabled ||
        globalMouseX == null ||
        globalMouseY == null) {
      return;
    }
    final cursorStyle = Style(
      foreground: _isGlobalMouseDown
          ? const Color(255, 0, 0)
          : const Color(0, 255, 255),
      modifiers: Modifier.bold,
    );
    target.writeString(globalMouseX, globalMouseY, '⦿', cursorStyle);
  }

  void _flushRenderedFrame(Renderer renderer, Buffer target) {
    final sb = StringBuffer();
    renderer.render(target, sb);
    final backend = terminal.backend;
    if (backend is BufferedTerminalBackend) {
      backend.buffer = target;
    }
    backend.write(sb.toString());
    onFrameRedrawn?.call(target);
  }

  void _syncHardwareState(int width, int height) {
    final focused = focusedLayer;
    final req = focused?.renderer;
    final wantsMouseTracking =
        enableMouseTracking ||
        (req?.wantsMouseTracking ?? false) ||
        layers.any((layer) => layer.draggable) ||
        debugMouseCursorEnabled;

    final cursorPos = _resolveVisibleCursor(focused, width, height);
    final effectiveShowsCursor = cursorPos != null;

    if (effectiveShowsCursor != _lastShowsCursor) {
      if (effectiveShowsCursor) {
        terminal.showCursor();
      } else {
        terminal.hideCursor();
      }
      _lastShowsCursor = effectiveShowsCursor;
    }

    if (wantsMouseTracking != _lastWantsMouseTracking) {
      if (wantsMouseTracking) {
        terminal.enableMouseTracking();
      } else {
        terminal.disableMouseTracking();
      }
      _lastWantsMouseTracking = wantsMouseTracking;
    }

    if (cursorPos != null) {
      terminal.goto(x: cursorPos.x + 1, y: cursorPos.y + 1);
    }
  }

  static Point<int>? _resolveVisibleCursor(
    SceneLayer? focused,
    int width,
    int height,
  ) {
    final req = focused?.renderer;
    if (req == null || !req.showsCursor) return null;
    final pos = req.requestedCursorPosition;
    if (pos == null) return null;
    final absX = (focused?.x ?? 0) + pos.x;
    final absY = (focused?.y ?? 0) + pos.y;
    if (absX < 0 || absX >= width || absY < 0 || absY >= height) return null;
    return Point<int>(absX, absY);
  }

  /// Clears resources and restores terminal hardware state if modified.
  void dispose() {
    TermuiBinding.unregister(this);
    _isDisposed = true;
    _eventsSubscription?.cancel();
    _eventsSubscription = null;
    _sizeSubscription?.cancel();
    _sizeSubscription = null;
    _debugTouchTimer?.cancel();

    if (_lastShowsCursor == false) {
      terminal.showCursor();
    }
    if (_lastWantsMouseTracking == true) {
      terminal.disableMouseTracking();
    }
    for (final layer in layers) {
      layer.renderer.dispose();
    }
    layers.clear();
    _lastRequestedSizes.clear();
    _nonFocusableLayers.clear();
    focusedLayer = null;
    _draggingLayer = null;
    _capturedMouseLayer = null;
    _globalMouseX = null;
    _globalMouseY = null;
    _isGlobalMouseDown = false;
    _renderer = null;
    _targetBuffer = null;
  }

  /// Schedules a render pass to recomposite layers, coalescing multiple requests.
  void scheduleRender() {
    if (_isRendering) {
      _renderRequestedWhileRendering = true;
      return;
    }
    if (_isDisposed || _renderScheduled) return;
    _renderScheduled = true;
    scheduleMicrotask(() {
      if (_isDisposed || !_renderScheduled) return;
      _renderScheduled = false;
      render();
    });
  }

  /// Called during hot reload to force all layers and widget trees to rebuild and repaint.
  @override
  void reassemble() {
    for (final layer in layers) {
      final r = layer.renderer;
      if (r is PromptRunner) {
        r.reassemble();
      }
    }
    scheduleRender();
  }

  void _syncLayerListeners() {
    final currentRenderers = {
      for (final layer in layers)
        if (layer.renderer case final ListenableSceneRenderer r) r,
    };

    for (final r in _activeRenderers) {
      if (!currentRenderers.contains(r)) {
        r.onNeedVisualUpdate = null;
      }
    }

    for (final r in currentRenderers) {
      if (!_activeRenderers.contains(r)) {
        r.onNeedVisualUpdate = _handleLayerVisualUpdate;
      }
    }

    _activeRenderers.clear();
    _activeRenderers.addAll(currentRenderers);
  }

  /// Displays a modal dialog by adding it as a higher layer.
  ///
  /// Returns a [Future] that completes with the dialog result, or `null` if
  /// [barrierDismissible] is `true` and the user clicks the barrier or presses
  /// unhandled `Escape`.
  Future<T?> showDialog<T>({
    required WidgetBuilder builder,
    bool barrierDismissible = true,
    double barrierScalar = 0.5,
    Color? barrierColor,
    Color? defaultForeground,
    Color? defaultBackground,
    TerminalColorTheme palette = TerminalColorTheme.legacyVga,
    int width = 40,
    int height = 10,
  }) {
    final completer = Completer<T?>();

    final runner = PromptRunner<T>(
      terminal: terminal,
      widget: Builder(builder: builder),
      exitConditions: {
        ...PromptRunner.defaultExitConditions,
        if (barrierDismissible) .escape: .cancel,
      },
      alternateScreen: false,
      mode: .managed,
    );

    final barrierWidget = Stack([
      Positioned(
        left: 0,
        top: 0,
        right: 0,
        bottom: 0,
        child: DimmingBarrier(
          scalar: barrierScalar,
          barrierColor: barrierColor,
          defaultForeground: defaultForeground,
          defaultBackground: defaultBackground,
          palette: palette,
        ),
      ),
      if (barrierDismissible)
        Positioned(
          left: 0,
          top: 0,
          right: 0,
          bottom: 0,
          child: ModalDismissBarrier(
            onDismiss: runner.abort,
            child: const SizedBox.expand(),
          ),
        ),
    ]);

    final barrierRunner = PromptRunner<void>(
      terminal: terminal,
      widget: barrierWidget,
      exitConditions: const {},
      alternateScreen: false,
      mode: .managed,
    );

    final baseZIndex = 1000 + layers.length * 2;

    final barrierLayer = SceneLayer(
      renderer: barrierRunner,
      sizing: .fullscreen,
      zIndex: baseZIndex,
    );
    _nonFocusableLayers.add(barrierLayer);

    final terminalSize = terminal.backend.size;
    final x = max(0, (terminalSize.x - width) ~/ 2);
    final y = max(0, (terminalSize.y - height) ~/ 2);

    late final SceneLayer dialogLayer;
    dialogLayer = SceneLayer(
      renderer: runner,
      sizing: .fixed,
      x: x,
      y: y,
      width: width,
      height: height,
      zIndex: baseZIndex + 1,
      onResize: (newSize) {
        dialogLayer.x = max(0, (newSize.x - width) ~/ 2);
        dialogLayer.y = max(0, (newSize.y - height) ~/ 2);
      },
    );

    layers.add(barrierLayer);
    layers.add(dialogLayer);
    focusedLayer = dialogLayer;

    barrierRunner.run();
    runner
        .run()
        .then((result) {
          completer.complete(result);
        })
        .catchError((Object err, StackTrace stack) {
          if (err is PromptAbortedException) {
            completer.complete(null);
          } else {
            completer.completeError(err, stack);
          }
        })
        .whenComplete(() {
          layers.remove(dialogLayer);
          layers.remove(barrierLayer);
          runner.dispose();
          barrierRunner.dispose();
          render();
        });

    render();
    return completer.future;
  }

  void _renderDebugOverlays(Buffer target) {
    _paintFocusedLayerBadge(target);
    _paintHoverDebugOutline(target);
    _paintTouchIndicators(target);
    rippleManager.paint(target);
  }

  void _paintFocusedLayerBadge(Buffer target) {
    final fLayer = focusedLayer;
    if (!debugPaintLayerBordersEnabled || fLayer == null) return;
    final fBuf = fLayer.renderer.currentBuffer;
    if (fBuf == null || fBuf.width < 4) return;
    const style = Style(foreground: Color(255, 255, 0));
    target.writeString(fLayer.x + fBuf.width - 4, fLayer.y, '[🧐]', style);
  }

  void _paintHoverDebugOutline(Buffer target) {
    final mx = _globalMouseX;
    final my = _globalMouseY;
    if (!debugPaintHoverEnabled || mx == null || my == null) return;

    const style = Style(
      foreground: Color(255, 0, 255),
      background: Color(255, 0, 255),
    );
    for (final layer in _getSortedLayers()) {
      final buf = layer.renderer.currentBuffer;
      if (buf == null || !_containsLayerPoint(layer, buf, mx, my)) continue;
      target.writeString(layer.x, layer.y, '╔', style);
      target.writeString(layer.x + buf.width - 1, layer.y, '╗', style);
      target.writeString(layer.x, layer.y + buf.height - 1, '╚', style);
      target.writeString(
        layer.x + buf.width - 1,
        layer.y + buf.height - 1,
        '╝',
        style,
      );
      return;
    }
  }

  void _paintTouchIndicators(Buffer target) {
    if (!debugShowTouchesEnabled || _activeTouches.isEmpty) return;
    final now = clock.now().millisecondsSinceEpoch;

    for (final touch in _activeTouches) {
      final elapsed = now - touch.startTime;
      if (elapsed > 500) continue;
      final indicator = _touchIndicatorGlyph(touch);
      if (indicator.isEmpty) continue;

      final colorValue = (255 * (1.0 - elapsed / 500.0)).round().clamp(0, 255);
      final style = Style(
        foreground: Color(colorValue, colorValue, colorValue),
      );
      target.writeString(touch.x, touch.y, indicator, style);
    }
  }

  static String _touchIndicatorGlyph(_TouchFeedback touch) =>
      switch ((touch.type, touch.button)) {
        (MouseEventType.press, MouseButton.middle) => '❷',
        (MouseEventType.press, MouseButton.right) => '❸',
        (MouseEventType.press, MouseButton.wheelUp) => '↑',
        (MouseEventType.press, MouseButton.wheelDown) => '↓',
        (MouseEventType.press, _) => '❶',
        (MouseEventType.release, MouseButton.middle) => '②',
        (MouseEventType.release, MouseButton.right) => '③',
        (MouseEventType.release, _) => '①',
        _ => '',
      };
}

class _TouchFeedback {
  final int x;
  final int y;
  final MouseButton button;
  final MouseEventType type;
  final int startTime;

  _TouchFeedback({
    required this.x,
    required this.y,
    required this.button,
    required this.type,
    required this.startTime,
  });
}

class _SceneLayerList extends ListBase<SceneLayer> {
  final List<SceneLayer> _inner = [];
  final SceneManager _manager;

  _SceneLayerList(this._manager);

  @override
  int get length => _inner.length;

  @override
  set length(int newLength) {
    if (newLength < _inner.length) {
      for (var i = newLength; i < _inner.length; i++) {
        _manager._onLayerRemoved(_inner[i]);
      }
    }
    _inner.length = newLength;
    _manager._syncLayerListeners();
  }

  @override
  SceneLayer operator [](int index) => _inner[index];

  @override
  void operator []=(int index, SceneLayer value) {
    final old = _inner[index];
    _inner[index] = value;
    _manager._onLayerRemoved(old);
    _manager._syncLayerListeners();
  }

  @override
  void add(SceneLayer element) {
    _inner.add(element);
    _manager._syncLayerListeners();
  }

  @override
  void addAll(Iterable<SceneLayer> iterable) {
    _inner.addAll(iterable);
    _manager._syncLayerListeners();
  }

  @override
  bool remove(Object? element) {
    if (element case SceneLayer layer) {
      final index = _inner.indexOf(layer);
      if (index != -1) {
        removeAt(index);
        return true;
      }
    }
    return false;
  }

  @override
  SceneLayer removeAt(int index) {
    final result = _inner.removeAt(index);
    _manager._onLayerRemoved(result);
    return result;
  }

  @override
  void clear() {
    final temp = List<SceneLayer>.from(_inner);
    _inner.clear();
    for (final layer in temp) {
      _manager._onLayerRemoved(layer);
    }
  }

  @override
  void insert(int index, SceneLayer element) {
    _inner.insert(index, element);
    _manager._syncLayerListeners();
  }

  @override
  void insertAll(int index, Iterable<SceneLayer> iterable) {
    _inner.insertAll(index, iterable);
    _manager._syncLayerListeners();
  }

  @override
  void removeRange(int start, int end) {
    final removed = _inner.sublist(start, end);
    _inner.removeRange(start, end);
    for (final layer in removed) {
      _manager._onLayerRemoved(layer);
    }
  }

  @override
  void replaceRange(int start, int end, Iterable<SceneLayer> replacement) {
    final removed = _inner.sublist(start, end);
    _inner.replaceRange(start, end, replacement);
    for (final layer in removed) {
      _manager._onLayerRemoved(layer);
    }
    _manager._syncLayerListeners();
  }

  @override
  void fillRange(int start, int end, [SceneLayer? fillValue]) {
    final removed = _inner.sublist(start, end);
    _inner.fillRange(start, end, fillValue);
    for (final layer in removed) {
      _manager._onLayerRemoved(layer);
    }
    _manager._syncLayerListeners();
  }

  @override
  void setRange(
    int start,
    int end,
    Iterable<SceneLayer> iterable, [
    int skipCount = 0,
  ]) {
    final removed = _inner.sublist(start, end);
    _inner.setRange(start, end, iterable, skipCount);
    for (final layer in removed) {
      _manager._onLayerRemoved(layer);
    }
    _manager._syncLayerListeners();
  }

  @override
  void setAll(int index, Iterable<SceneLayer> iterable) {
    final len = iterable.length;
    final removed = _inner.sublist(index, index + len);
    _inner.setAll(index, iterable);
    for (final layer in removed) {
      _manager._onLayerRemoved(layer);
    }
    _manager._syncLayerListeners();
  }

  @override
  void removeWhere(bool Function(SceneLayer element) test) {
    final removed = [
      for (final layer in _inner)
        if (test(layer)) layer,
    ];
    _inner.removeWhere(test);
    for (final layer in removed) {
      _manager._onLayerRemoved(layer);
    }
    _manager._syncLayerListeners();
  }

  @override
  void retainWhere(bool Function(SceneLayer element) test) {
    final removed = [
      for (final layer in _inner)
        if (!test(layer)) layer,
    ];
    _inner.retainWhere(test);
    for (final layer in removed) {
      _manager._onLayerRemoved(layer);
    }
    _manager._syncLayerListeners();
  }

  @override
  void sort([int Function(SceneLayer a, SceneLayer b)? compare]) {
    _inner.sort(compare);
    _manager.scheduleRender();
  }

  @override
  void shuffle([Random? random]) {
    _inner.shuffle(random);
    _manager.scheduleRender();
  }

  @override
  SceneLayer removeLast() {
    final result = _inner.removeLast();
    _manager._onLayerRemoved(result);
    return result;
  }
}
