import 'dart:async';
import 'dart:collection';
import 'dart:math';
import 'package:termui/termui.dart';

/// Manages multiple visual layers in a terminal windowing system,
/// handles rendering composition and hardware sync.
class SceneManager {
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

  /// The currently focused layer, if any. Used to sync hardware state.
  SceneLayer? focusedLayer;

  /// Whether mouse tracking is explicitly forced/enabled.
  bool enableMouseTracking = false;

  bool _isDisposed = false;
  bool _renderScheduled = false;
  final Set<ListenableSceneRenderer> _activeRenderers = {};
  late final void Function() _handleLayerVisualUpdate = scheduleRender;
  final Map<SceneRenderer, Point<int>> _lastRequestedSizes = {};
  bool _isRendering = false;

  final Compositor _compositor = Compositor();
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
    if (focusedLayer == layer) focusedLayer = null;
    if (_draggingLayer == layer) _draggingLayer = null;
    if (_capturedMouseLayer == layer) _capturedMouseLayer = null;
    if (_resizingLayer == layer) {
      _resizingLayer = null;
      _resizeCorner = 0;
    }
    _syncLayerListeners();
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
      metadata: {'key': event.logicalKey},
    );
    try {
      final handled = focusedLayer?.renderer.handleKeyEvent(event) ?? false;
      if (!handled) {
        _clearHoverState();
      }
    } finally {
      Tracer.record(_traceKeyEventId, Phase.end, TraceCategory.events);
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
    };
    if (event.modifiers.isNotEmpty) {
      meta['modifiers'] = event.modifiers.map((m) => m.name).join('+');
    }

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

      var didRender = false;

      if (event.type == MouseEventType.press) {
        final mouseX = event.x - 1;
        final mouseY = event.y - 1;

        final sortedLayers = _getSortedLayers();

        SceneLayer? hitLayer;
        for (final layer in sortedLayers) {
          final buf = layer.renderer.currentBuffer;
          if (buf == null) continue;

          if (mouseX >= layer.x &&
              mouseX < layer.x + buf.width &&
              mouseY >= layer.y &&
              mouseY < layer.y + buf.height) {
            hitLayer = layer;
            break;
          }
        }

        if (hitLayer != null) {
          _capturedMouseLayer = hitLayer;
          if (focusedLayer != hitLayer) {
            focusedLayer = hitLayer;
          }
          final buf = hitLayer.renderer.currentBuffer;
          final isTL = mouseX == hitLayer.x && mouseY == hitLayer.y;
          final isTR =
              mouseX == hitLayer.x + buf!.width - 1 && mouseY == hitLayer.y;
          final isBL =
              mouseX == hitLayer.x && mouseY == hitLayer.y + buf.height - 1;
          final isBR =
              mouseX == hitLayer.x + buf.width - 1 &&
              mouseY == hitLayer.y + buf.height - 1;

          if (hitLayer.resizable && (isTL || isTR || isBL || isBR)) {
            _resizingLayer = hitLayer;
            _resizeCorner = isTL
                ? 1
                : isTR
                ? 2
                : isBL
                ? 3
                : 4;
            _dragStartX = event.x;
            _dragStartY = event.y;
            _layerStartX = hitLayer.x;
            _layerStartY = hitLayer.y;
            _layerStartWidth = hitLayer.width ?? buf.width;
            _layerStartHeight = hitLayer.height ?? buf.height;
          } else if (hitLayer.draggable) {
            _draggingLayer = hitLayer;
            _dragStartX = event.x;
            _dragStartY = event.y;
            _layerStartX = hitLayer.x;
            _layerStartY = hitLayer.y;
          }

          if (_resizingLayer == null) {
            final localX = mouseX - hitLayer.x;
            final localY = mouseY - hitLayer.y;
            final localEvent = MouseEvent(
              x: localX + 1,
              y: localY + 1,
              globalX: event.globalX ?? event.x,
              globalY: event.globalY ?? event.y,
              button: event.button,
              type: event.type,
              modifiers: event.modifiers,
            );
            hitLayer.renderer.handleMouseEvent(localEvent);
          }
        }
      } else if (event.type == MouseEventType.drag) {
        if (_resizingLayer != null) {
          int dx = event.x - _dragStartX;
          int dy = event.y - _dragStartY;

          if (_resizeCorner == 1 || _resizeCorner == 3) {
            if (_layerStartWidth - dx < 10) dx = _layerStartWidth - 10;
          } else {
            if (_layerStartWidth + dx < 10) dx = 10 - _layerStartWidth;
          }

          if (_resizeCorner == 1 || _resizeCorner == 2) {
            if (_layerStartHeight - dy < 5) dy = _layerStartHeight - 5;
          } else {
            if (_layerStartHeight + dy < 5) dy = 5 - _layerStartHeight;
          }

          var newX = _layerStartX;
          var newY = _layerStartY;
          var newW = _layerStartWidth;
          var newH = _layerStartHeight;

          if (_resizeCorner == 1) {
            newX += dx;
            newY += dy;
            newW -= dx;
            newH -= dy;
          } else if (_resizeCorner == 2) {
            newY += dy;
            newW += dx;
            newH -= dy;
          } else if (_resizeCorner == 3) {
            newX += dx;
            newW -= dx;
            newH += dy;
          } else if (_resizeCorner == 4) {
            newW += dx;
            newH += dy;
          }

          _resizingLayer!.x = newX;
          _resizingLayer!.y = newY;
          _resizingLayer!.width = newW;
          _resizingLayer!.height = newH;
          _resizeRenderer(_resizingLayer!.renderer, newW, newH);
          render();
          didRender = true;
        } else if (_draggingLayer != null) {
          final dx = event.x - _dragStartX;
          final dy = event.y - _dragStartY;
          _draggingLayer!.x = _layerStartX + dx;
          _draggingLayer!.y = _layerStartY + dy;
          render();
          didRender = true;
        } else if (_capturedMouseLayer != null) {
          final mouseX = event.x - 1;
          final mouseY = event.y - 1;
          final localX = mouseX - _capturedMouseLayer!.x;
          final localY = mouseY - _capturedMouseLayer!.y;
          final localEvent = MouseEvent(
            x: localX + 1,
            y: localY + 1,
            globalX: event.globalX ?? event.x,
            globalY: event.globalY ?? event.y,
            button: event.button,
            type: event.type,
            modifiers: event.modifiers,
          );
          _capturedMouseLayer!.renderer.handleMouseEvent(localEvent);
        }
      } else if (event.type == MouseEventType.release) {
        if (_resizingLayer != null) {
          _resizingLayer = null;
          _resizeCorner = 0;
          _capturedMouseLayer = null;
        } else {
          final targetLayer = _draggingLayer ?? _capturedMouseLayer;
          if (targetLayer != null) {
            final mouseX = event.x - 1;
            final mouseY = event.y - 1;
            final localX = mouseX - targetLayer.x;
            final localY = mouseY - targetLayer.y;
            final localEvent = MouseEvent(
              x: localX + 1,
              y: localY + 1,
              globalX: event.globalX ?? event.x,
              globalY: event.globalY ?? event.y,
              button: event.button,
              type: event.type,
              modifiers: event.modifiers,
            );
            targetLayer.renderer.handleMouseEvent(localEvent);
          }
          _draggingLayer = null;
          _capturedMouseLayer = null;
        }
      } else {
        // For hover (move) events, perform hit-test and route
        final mouseX = event.x - 1;
        final mouseY = event.y - 1;

        final sortedLayers = _getSortedLayers();
        SceneLayer? hitLayer;

        for (final layer in sortedLayers) {
          final buf = layer.renderer.currentBuffer;
          if (buf == null) continue;

          if (mouseX >= layer.x &&
              mouseX < layer.x + buf.width &&
              mouseY >= layer.y &&
              mouseY < layer.y + buf.height) {
            hitLayer = layer;
            final localX = mouseX - layer.x;
            final localY = mouseY - layer.y;
            final localEvent = MouseEvent(
              x: localX + 1,
              y: localY + 1,
              globalX: event.globalX ?? event.x,
              globalY: event.globalY ?? event.y,
              button: event.button,
              type: event.type,
              modifiers: event.modifiers,
            );
            layer.renderer.handleMouseEvent(localEvent);
            break;
          }
        }

        if (_lastHoveredLayer != null && _lastHoveredLayer != hitLayer) {
          final localEvent = MouseEvent(
            x: -1,
            y: -1,
            globalX: event.globalX ?? event.x,
            globalY: event.globalY ?? event.y,
            button: event.button,
            type: event.type,
            modifiers: event.modifiers,
          );
          _lastHoveredLayer!.renderer.handleMouseEvent(localEvent);
        }
        _lastHoveredLayer = hitLayer;
      }

      if (debugMouseCursorEnabled && !didRender) {
        render();
      }
    } finally {
      Tracer.record(_traceMouseEventId, Phase.end, TraceCategory.events);
    }
  }

  void _handleInputEvent(InputEvent event) {
    _cleanOrphanedLayers();
    switch (event) {
      case final KeyEvent e:
        handleKeyEvent(e);
      case final MouseEvent e:
        handleMouseEvent(e);
    }
  }

  /// Composites all active layers into a single flattened terminal output
  /// and writes it to the terminal.
  void render() {
    _isRendering = true;
    try {
      _renderScheduled = false;
      Tracer.record(_traceRenderId, Phase.begin, TraceCategory.compositor);
      try {
        _cleanOrphanedLayers();

        for (final layer in layers) {
          final r = layer.renderer;
          if (r is ListenableSceneRenderer && r.isDirty) {
            r.render();
          }
        }

        final size = terminal.backend.size;
        var width = size.x;
        var height = size.y;
        if (width <= 0 || height <= 0) {
          width = 80;
          height = 24;
        }

        final renderer = _renderer ??= Renderer(
          width,
          height,
          mode: renderingMode,
        );

        final layeredBuffers = <LayeredBuffer>[];
        for (final layer in layers) {
          if (layer.sizing == LayerSizing.fullscreen) {
            if (layer.width != width || layer.height != height) {
              layer.width = width;
              layer.height = height;
              _resizeRenderer(layer.renderer, width, height);
            }
          } else {
            final buf = layer.renderer.currentBuffer;
            if (buf == null ||
                buf.width != layer.width ||
                buf.height != layer.height) {
              if (layer.width != null && layer.height != null) {
                _resizeRenderer(layer.renderer, layer.width!, layer.height!);
              }
            }
          }

          var buffer = layer.renderer.currentBuffer;
          if (buffer == null) continue;

          if (debugPaintLayerBordersEnabled) {
            buffer = _cloneBufferWithBorder(buffer);
          }

          layeredBuffers.add(
            LayeredBuffer(
              buffer: buffer,
              x: layer.x,
              y: layer.y,
              zIndex: layer.zIndex,
            ),
          );
        }

        final target = _targetBuffer ??= Buffer(width, height);
        if (target.width != width || target.height != height) {
          target.resize(width, height);
        }
        target.clear();

        // The Compositor natively handles occlusion culling and off-screen
        // effect layer resolution using recursive saveLayer/backdrop filter patterns.
        _compositor.composite(target: target, layers: layeredBuffers);

        final globalMouseX = _globalMouseX;
        final globalMouseY = _globalMouseY;
        if (debugMouseCursorEnabled &&
            globalMouseX != null &&
            globalMouseY != null) {
          final cursorStyle = Style(
            foreground: _isGlobalMouseDown
                ? const Color(255, 0, 0)
                : const Color(0, 255, 255),
            modifiers: Modifier.bold,
          );
          target.writeString(globalMouseX, globalMouseY, '⦿', cursorStyle);
        }

        final sb = StringBuffer();
        renderer.render(target, sb);
        final backend = terminal.backend;
        if (backend is BufferedTerminalBackend) {
          backend.buffer = target;
        }
        backend.write(sb.toString());

        // Hardware state sync based on focused layer's requests.
        final focused = focusedLayer;
        final req = focused?.renderer;

        final showsCursor = req?.showsCursor ?? false;
        final wantsMouseTracking =
            enableMouseTracking ||
            (req?.wantsMouseTracking ?? false) ||
            layers.any((layer) => layer.draggable) ||
            debugMouseCursorEnabled;

        var effectiveShowsCursor = showsCursor;
        int? absX;
        int? absY;

        if (showsCursor) {
          final pos = req?.requestedCursorPosition;
          if (pos != null) {
            absX = (focused?.x ?? 0) + pos.x;
            absY = (focused?.y ?? 0) + pos.y;
            if (absX < 0 || absX >= width || absY < 0 || absY >= height) {
              effectiveShowsCursor = false;
            }
          } else {
            effectiveShowsCursor = false;
          }
        }

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

        if (effectiveShowsCursor && absX != null && absY != null) {
          terminal.goto(x: absX + 1, y: absY + 1);
        }
      } finally {
        Tracer.record(_traceRenderId, Phase.end, TraceCategory.compositor);
      }
    } finally {
      _isRendering = false;
    }
  }

  /// Clears resources and restores terminal hardware state if modified.
  void dispose() {
    _isDisposed = true;
    _eventsSubscription?.cancel();
    _eventsSubscription = null;
    _sizeSubscription?.cancel();
    _sizeSubscription = null;

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
    if (_isRendering) return;
    if (_isDisposed || _renderScheduled) return;
    _renderScheduled = true;
    scheduleMicrotask(() {
      if (_isDisposed || !_renderScheduled) return;
      _renderScheduled = false;
      render();
    });
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
  /// Returns a Future that completes when the dialog is dismissed/completed.
  Future<T?> showDialog<T>({
    required WidgetBuilder builder,
    bool barrierDismissible = true,
    double barrierScalar = 0.5,
    int width = 40,
    int height = 10,
  }) {
    final completer = Completer<T?>();

    late final PromptRunner<T> runner;

    final barrierWidget = Stack([
      Positioned(
        left: 0,
        top: 0,
        right: 0,
        bottom: 0,
        child: DimmingBarrier(scalar: barrierScalar),
      ),
      Positioned(
        left: 0,
        top: 0,
        right: 0,
        bottom: 0,
        child: ModalDismissBarrier(
          onDismiss: () {
            if (barrierDismissible) {
              runner.abort();
            }
          },
          child: const SizedBox.expand(),
        ),
      ),
    ]);

    final barrierRunner = PromptRunner<void>(
      terminal: terminal,
      widget: barrierWidget,
      alternateScreen: false,
      mode: ExecutionMode.managed,
      onFramePainted: (_) => render(),
    );

    final dialogWidget = Builder(builder: builder);

    final previousFocusedLayer = focusedLayer;

    runner = PromptRunner<T>(
      terminal: terminal,
      widget: dialogWidget,
      alternateScreen: false,
      mode: ExecutionMode.managed,
      onFramePainted: (_) => render(),
    );

    final baseZIndex = 1000 + layers.length * 2;

    final barrierLayer = SceneLayer(
      renderer: barrierRunner,
      sizing: LayerSizing.fullscreen,
      zIndex: baseZIndex,
    );

    final terminalSize = terminal.backend.size;
    final x = (terminalSize.x - width) ~/ 2;
    final y = (terminalSize.y - height) ~/ 2;

    final dialogLayer = SceneLayer(
      renderer: runner,
      sizing: LayerSizing.fixed,
      x: x,
      y: y,
      width: width,
      height: height,
      zIndex: baseZIndex + 1,
    );

    layers.add(barrierLayer);
    layers.add(dialogLayer);
    focusedLayer = dialogLayer;
    render();

    barrierRunner.run();
    runner
        .run()
        .then((result) {
          completer.complete(result);
        })
        .catchError((err) {
          if (err is PromptAbortedException) {
            completer.complete(null);
          } else {
            completer.completeError(err);
          }
        })
        .whenComplete(() {
          layers.remove(dialogLayer);
          layers.remove(barrierLayer);
          runner.dispose();
          barrierRunner.dispose();
          if (focusedLayer == dialogLayer || focusedLayer == barrierLayer) {
            focusedLayer =
                previousFocusedLayer ??
                (layers.isNotEmpty ? layers.last : null);
          }
          render();
        });

    return completer.future;
  }
}

Buffer _cloneBufferWithBorder(Buffer source) {
  final copy = Buffer(source.width, source.height);
  for (var y = 0; y < source.height; y++) {
    for (var x = 0; x < source.width; x++) {
      copy.setAttributes(
        x,
        y,
        char: source.getCharacter(x, y),
        fg: source.getForeground(x, y),
        bg: source.getBackground(x, y),
        modifiers: source.getModifiers(x, y),
      );
    }
  }

  final w = source.width;
  final h = source.height;
  if (w > 0 && h > 0) {
    final borderStyle = const Style(
      foreground: Colors.yellow,
      modifiers: Modifier.bold,
    );

    final x2 = w - 1;
    final y2 = h - 1;

    void setBorderCell(int x, int y, String char) {
      final cellChar = copy.getCharacter(x, y);
      if (cellChar == '') {
        if (x - 1 >= 0) {
          final prevChar = copy.getCharacter(x - 1, y);
          if (isWideGrapheme(prevChar)) {
            copy.setAttributes(
              x - 1,
              y,
              char: ' ',
              fg: copy.getForeground(x - 1, y),
              bg: copy.getBackground(x - 1, y),
              modifiers: copy.getModifiers(x - 1, y),
            );
          }
        }
      } else if (isWideGrapheme(cellChar)) {
        if (x + 1 < w) {
          final nextChar = copy.getCharacter(x + 1, y);
          if (nextChar == '') {
            copy.setAttributes(
              x + 1,
              y,
              char: ' ',
              fg: copy.getForeground(x + 1, y),
              bg: copy.getBackground(x + 1, y),
              modifiers: copy.getModifiers(x + 1, y),
            );
          }
        }
      }
      copy.setAttributes(
        x,
        y,
        char: char,
        fg: borderStyle.foreground?.argb ?? 0,
        bg: borderStyle.background?.argb ?? 0,
        modifiers: borderStyle.modifiers,
      );
    }

    // Draw horizontal lines
    for (var x = 0; x < w; x++) {
      setBorderCell(x, 0, '─');
      setBorderCell(x, y2, '─');
    }
    // Draw vertical lines
    for (var y = 0; y < h; y++) {
      setBorderCell(0, y, '│');
      setBorderCell(x2, y, '│');
    }
    // Draw corners
    setBorderCell(0, 0, '┌');
    setBorderCell(x2, 0, '┐');
    setBorderCell(0, y2, '└');
    setBorderCell(x2, y2, '┘');
  }

  return copy;
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
    if (element is SceneLayer) {
      final index = _inner.indexOf(element);
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
    final removed = _inner.where(test).toList();
    _inner.removeWhere(test);
    for (final layer in removed) {
      _manager._onLayerRemoved(layer);
    }
    _manager._syncLayerListeners();
  }

  @override
  void retainWhere(bool Function(SceneLayer element) test) {
    final removed = _inner.where((e) => !test(e)).toList();
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
