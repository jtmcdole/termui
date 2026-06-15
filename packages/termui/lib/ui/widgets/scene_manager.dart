import 'dart:async';
import 'dart:math';

import '../../terminal/terminal.dart';
import '../buffer.dart';
import '../renderer.dart';
import 'prompt_runner.dart';

/// Manages multiple visual layers in a terminal windowing system,
/// handles rendering composition and hardware sync.
class SceneManager {
  /// The hardware/platform terminal wrapper.
  final Terminal terminal;

  /// The list of layers to composite and render.
  final List<SceneLayer> layers = [];

  /// The currently focused layer, if any. Used to sync hardware state.
  SceneLayer? focusedLayer;

  final Compositor _compositor = Compositor();
  Renderer? _renderer;
  Buffer? _targetBuffer;

  StreamSubscription<InputEvent>? _eventsSubscription;
  StreamSubscription<Point<int>>? _sizeSubscription;

  /// Exposes the internal renderer.
  Renderer? get renderer => _renderer;

  bool? _lastShowsCursor;
  bool? _lastWantsMouseTracking;

  /// Creates a new scene manager on [terminal].
  SceneManager(this.terminal) {
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

  void _handleInputEvent(InputEvent event) {
    if (event is KeyEvent) {
      focusedLayer?.renderer.handleKeyEvent(event);
    } else if (event is MouseEvent) {
      final mouseX = event.x - 1;
      final mouseY = event.y - 1;

      final sortedLayers = List<SceneLayer>.from(layers)
        ..sort((a, b) => b.zIndex.compareTo(a.zIndex));

      for (final layer in sortedLayers) {
        final buf = layer.renderer.currentBuffer;
        if (buf == null) continue;

        if (mouseX >= layer.x &&
            mouseX < layer.x + buf.width &&
            mouseY >= layer.y &&
            mouseY < layer.y + buf.height) {
          if (event.type == MouseEventType.press && focusedLayer != layer) {
            focusedLayer = layer;
          }

          final localX = mouseX - layer.x;
          final localY = mouseY - layer.y;
          final localEvent = MouseEvent(
            x: localX + 1,
            y: localY + 1,
            button: event.button,
            type: event.type,
            modifiers: event.modifiers,
          );

          layer.renderer.handleMouseEvent(localEvent);
          break; // Stop routing after hitting the topmost layer
        }
      }
    }
  }

  /// Composites all active layers into a single flattened terminal output
  /// and writes it to the terminal.
  void render() {
    final size = terminal.backend.size;
    var width = size.x;
    var height = size.y;
    if (width <= 0 || height <= 0) {
      width = 80;
      height = 24;
    }

    _renderer ??= Renderer(width, height);

    final layeredBuffers = <LayeredBuffer>[];
    for (final layer in layers) {
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
    }

    final target = _targetBuffer ??= Buffer(width, height);
    if (target.width != width || target.height != height) {
      target.resize(width, height);
    }
    target.clear();

    _compositor.composite(target: target, layers: layeredBuffers);

    final sb = StringBuffer();
    _renderer!.render(target, sb);
    terminal.backend.write(sb.toString());

    // Hardware state sync based on focused layer's requests.
    final focused = focusedLayer;
    final req = focused?.renderer;

    final showsCursor = req?.showsCursor ?? false;
    final wantsMouseTracking = req?.wantsMouseTracking ?? false;

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
    _renderer = null;
    _targetBuffer = null;
  }
}
