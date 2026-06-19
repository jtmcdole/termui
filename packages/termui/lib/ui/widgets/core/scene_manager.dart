import 'dart:async';
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
  final List<SceneLayer> layers = [];

  /// The currently focused layer, if any. Used to sync hardware state.
  SceneLayer? focusedLayer;

  /// Whether mouse tracking is explicitly forced/enabled.
  bool enableMouseTracking = false;

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
    _eventsSubscription = terminal.events.listen(_handleInputEvent);
    _sizeSubscription = terminal.watchSize().listen(_handleSizeEvent);
  }

  void _handleSizeEvent(Point<int> newSize) {
    final width = newSize.x;
    final height = newSize.y;
    if (width <= 0 || height <= 0) return;

    for (final layer in layers) {
      if (layer.sizing == LayerSizing.fullscreen) {
        layer.x = 0;
        layer.y = 0;
        layer.renderer.resize(width, height);
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

  List<SceneLayer> _getSortedLayers() {
    final sorted = List<SceneLayer>.from(layers);
    final originalIndices = {
      for (var i = 0; i < layers.length; i++) layers[i]: i,
    };
    sorted.sort((a, b) {
      final cmp = b.zIndex.compareTo(a.zIndex);
      if (cmp != 0) return cmp;
      return originalIndices[b]!.compareTo(originalIndices[a]!);
    });
    return sorted;
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
          _resizingLayer!.renderer.resize(newW, newH);
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

    if (event is KeyEvent) {
      handleKeyEvent(event);
    } else if (event is MouseEvent) {
      handleMouseEvent(event);
    }
  }

  /// Composites all active layers into a single flattened terminal output
  /// and writes it to the terminal.
  void render() {
    Tracer.record(_traceRenderId, Phase.begin, TraceCategory.compositor);
    try {
      _cleanOrphanedLayers();

      final size = terminal.backend.size;
      var width = size.x;
      var height = size.y;
      if (width <= 0 || height <= 0) {
        width = 80;
        height = 24;
      }

      _renderer ??= Renderer(width, height, mode: renderingMode);

      final layeredBuffers = <LayeredBuffer>[];
      for (final layer in layers) {
        if (layer.sizing == LayerSizing.fullscreen) {
          if (layer.width != width || layer.height != height) {
            layer.width = width;
            layer.height = height;
            layer.renderer.resize(width, height);
          }
        } else {
          final buf = layer.renderer.currentBuffer;
          if (buf == null ||
              buf.width != layer.width ||
              buf.height != layer.height) {
            if (layer.width != null && layer.height != null) {
              layer.renderer.resize(layer.width!, layer.height!);
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

      _compositor.composite(target: target, layers: layeredBuffers);

      if (debugMouseCursorEnabled &&
          _globalMouseX != null &&
          _globalMouseY != null) {
        final cursorStyle = Style(
          foreground: _isGlobalMouseDown
              ? const Color(255, 0, 0)
              : const Color(0, 255, 255),
          modifiers: Modifier.bold,
        );
        target.writeString(_globalMouseX!, _globalMouseY!, '⦿', cursorStyle);
      }

      final sb = StringBuffer();
      _renderer!.render(target, sb);
      try {
        (terminal.backend as dynamic).buffer = target;
      } catch (_) {}
      terminal.backend.write(sb.toString());

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
  }

  /// Clears resources and restores terminal hardware state if modified.
  void dispose() {
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
    layers.clear();
    focusedLayer = null;
    _draggingLayer = null;
    _capturedMouseLayer = null;
    _globalMouseX = null;
    _globalMouseY = null;
    _isGlobalMouseDown = false;
    _renderer = null;
    _targetBuffer = null;
  }
}

Buffer _cloneBufferWithBorder(Buffer source) {
  final copy = Buffer(source.width, source.height);
  for (var y = 0; y < source.height; y++) {
    for (var x = 0; x < source.width; x++) {
      final cell = source.getCell(x, y);
      if (cell != null) {
        copy.setCell(x, y, cell.clone());
      }
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
      final cell = copy.getCell(x, y);
      if (cell != null) {
        if (cell.char == '') {
          if (x - 1 >= 0) {
            final prev = copy.getCell(x - 1, y);
            if (prev != null && isWideGrapheme(prev.char)) {
              prev.char = ' ';
            }
          }
        } else if (isWideGrapheme(cell.char)) {
          if (x + 1 < w) {
            final next = copy.getCell(x + 1, y);
            if (next != null && next.char == '') {
              next.char = ' ';
            }
          }
        }
      }
      copy.setCell(x, y, Cell(char, borderStyle));
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
