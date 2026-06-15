import 'dart:async';
import 'dart:math';
import '../../terminal/terminal.dart' as term;
import '../buffer.dart';
import '../layout.dart';
import '../renderer.dart';
import 'focus.dart';
import '../window.dart';
import '../termui_debug.dart';
import '../color.dart';
import '../style.dart';

/// An interface that indicates a widget or state can receive keyboard focus.
abstract interface class Focusable {
  /// Whether this object currently has keyboard focus.
  bool get focused;
}

/// An interface that indicates a widget or state can handle terminal keyboard events.
abstract interface class KeyEventHandler {
  /// Handles a keyboard event, returning true if the event was consumed.
  bool handleKeyEvent(term.KeyEvent event);
}

/// Defines keyboard inputs or signals that can terminate the prompt runner's execution.
enum PromptExitTrigger {
  /// Pressing the Enter key (carriage return `\r`, newline `\n`, or key string `'enter'`).
  enter,

  /// Pressing the Escape key (key string `'escape'`).
  escape,

  /// Pressing Ctrl+C (character code 3).
  controlC,

  /// Pressing Ctrl+D (character code 4, signifying EOF).
  controlD,
}

/// Defines the state outcome of the [PromptRunner] when an exit trigger is matched.
enum PromptExitAction {
  /// Resolves the prompt runner's future with the current value retrieved from [onComplete].
  complete,

  /// Resolves the prompt runner's future with `null`, signaling cancellation without error.
  cancel,

  /// Rejects the prompt runner's future by throwing a [PromptAbortedException].
  abort,
}

/// Defines the execution mode for the [PromptRunner].
enum ExecutionMode {
  /// The runner manages its own terminal event subscriptions, input handling, and terminal writing.
  standalone,

  /// The runner is controlled by an external manager, bypassing hardware hooks and direct terminal writing.
  managed,
}

/// Base exception thrown when a [PromptRunner] is aborted via [PromptExitAction.abort].
class PromptAbortedException implements Exception {
  /// The specific exit trigger that caused the abort.
  final PromptExitTrigger trigger;

  /// The raw key event that triggered the abort, if available.
  final term.KeyEvent? event;

  /// Descriptive message explaining why the runner aborted.
  final String message;

  /// Creates a new [PromptAbortedException].
  const PromptAbortedException({
    required this.trigger,
    this.event,
    this.message = 'Prompt runner aborted.',
  });

  @override
  String toString() =>
      'PromptAbortedException: $message (triggered by $trigger)';
}

/// Specialized exception for user keyboard interrupts (typically Ctrl+C).
class UserInterruptException extends PromptAbortedException {
  /// Creates a new [UserInterruptException].
  const UserInterruptException({
    super.event,
    super.message = 'User interrupted the prompt via Ctrl+C.',
  }) : super(trigger: PromptExitTrigger.controlC);
}

/// A helper class to run an interactive terminal prompt inline.
/// It encapsulates the event loop, rendering to an inline buffer, and lifecycle management.
///
/// Example:
/// ```dart
/// final name = await PromptRunner<String>(
///   terminal: terminal,
///   widget: Column([
///     const Text('Enter name:'),
///     TextField(controller: myController, focused: true),
///   ]),
///   exitConditions: {
///     PromptExitTrigger.enter: PromptExitAction.complete,
///     PromptExitTrigger.escape: PromptExitAction.cancel,
///   },
///   onComplete: () => myController.text,
/// ).run();
/// ```
class PromptRunner<T> implements SceneRenderer {
  /// The active terminal instance.
  final term.Terminal terminal;

  /// The root widget configuration to display.
  final Widget widget;

  /// The height constraint of the inline rendering block. If null, calculated dynamically.
  final int? height;

  /// An optional key event handler callback. Returns true if prompt is completed.
  final bool Function(term.KeyEvent event)? onKeyEvent;

  /// An optional completion callback returning the final value of type [T].
  final T Function()? onComplete;

  /// Whether to render in alternate screen mode.
  final bool alternateScreen;

  /// Callback after each frame is painted onto the buffer.
  final void Function(Buffer buffer)? onFramePainted;

  /// Mapping of exit triggers to their corresponding actions.
  final Map<PromptExitTrigger, PromptExitAction> exitConditions;

  /// The execution mode of this runner.
  final ExecutionMode mode;

  /// Default exit conditions mapping.
  static const Map<PromptExitTrigger, PromptExitAction> defaultExitConditions =
      {
        PromptExitTrigger.controlC: PromptExitAction.abort,
        PromptExitTrigger.enter: PromptExitAction.complete,
      };

  Completer<T?>? _completer;
  Element? _rootElement;
  bool _isDisposed = false;
  Point<int>? _lastMousePosition;
  Element? _mouseCaptureElement;
  BuildOwner? _buildOwner;

  Buffer? _currentBuffer;
  Renderer? _renderer;
  int _width = 0;
  int _computedHeight = 0;

  /// Exposes the root element of the mounted widget tree for testing.
  Element? get rootElement => _rootElement;

  /// Exposes whether the prompt runner is disposed.
  bool get isDisposed => _isDisposed;

  @override
  /// Exposes the current buffer containing the rendered output.
  Buffer? get currentBuffer => _currentBuffer;

  @override
  bool get wantsMouseTracking => debugPaintHoverEnabled;

  @override
  bool get wantsAlternateScreen => alternateScreen;

  @override
  bool get showsCursor => false;

  @override
  Point<int>? get requestedCursorPosition => null;

  /// Creates a new [PromptRunner].
  PromptRunner({
    required this.terminal,
    required this.widget,
    this.height,
    Map<PromptExitTrigger, PromptExitAction>? exitConditions,
    this.onKeyEvent,
    this.onComplete,
    this.alternateScreen = false,
    this.onFramePainted,
    this.mode = ExecutionMode.standalone,
  }) : exitConditions = exitConditions ?? defaultExitConditions;

  /// Public programmatic abort.
  void abort([Object? exception]) {
    if (_isDisposed) return;
    _isDisposed = true;
    final activeCompleter = _completer;
    if (activeCompleter != null && !activeCompleter.isCompleted) {
      activeCompleter.completeError(
        exception ??
            const PromptAbortedException(
              trigger: PromptExitTrigger.controlC,
              message: 'Prompt runner aborted programmatically.',
            ),
      );
    }
  }

  /// Public programmatic dispose/cleanup.
  void dispose() {
    if (_isDisposed) return;
    _isDisposed = true;
    final activeCompleter = _completer;
    if (activeCompleter != null && !activeCompleter.isCompleted) {
      activeCompleter.complete(null);
    }
  }

  /// Helper to detect exit triggers case-insensitively.
  PromptExitTrigger? _detectTrigger(term.KeyEvent event) {
    // Check Ctrl+C (code unit 3 or character 'c' with control modifier)
    if ((event.key.length == 1 && event.key.codeUnits[0] == 3) ||
        (event.key.toLowerCase() == 'c' &&
            event.modifiers.contains(term.Modifier.control))) {
      return PromptExitTrigger.controlC;
    }

    // Check Ctrl+D (code unit 4 or character 'd' with control modifier)
    if ((event.key.length == 1 && event.key.codeUnits[0] == 4) ||
        (event.key.toLowerCase() == 'd' &&
            event.modifiers.contains(term.Modifier.control))) {
      return PromptExitTrigger.controlD;
    }

    // Check Escape
    if (event.key.toLowerCase() == 'escape' ||
        event.type == term.KeyType.escape) {
      return PromptExitTrigger.escape;
    }

    // Check Enter
    if (event.key.toLowerCase() == 'enter' ||
        event.type == term.KeyType.enter ||
        event.key == '\n' ||
        event.key == '\r') {
      return PromptExitTrigger.enter;
    }

    return null;
  }

  /// Helper to handle the matched exit trigger action.
  void _handleAction(PromptExitTrigger trigger, term.KeyEvent event) {
    final action = exitConditions[trigger];
    if (action == null) return;

    final comp = _completer;
    if (comp == null || comp.isCompleted) return;

    switch (action) {
      case PromptExitAction.complete:
        comp.complete(onComplete?.call());
        break;
      case PromptExitAction.cancel:
        comp.complete(null);
        break;
      case PromptExitAction.abort:
        final exception = trigger == PromptExitTrigger.controlC
            ? UserInterruptException(event: event)
            : PromptAbortedException(trigger: trigger, event: event);
        comp.completeError(exception);
        break;
    }
  }

  /// Recalculates layout and paints the widget tree to the internal buffer.
  void draw() {
    if (_isDisposed) return;
    final rootElement = _rootElement;
    final buffer = _currentBuffer;
    if (rootElement == null || buffer == null) return;

    // Rebuild the element tree to consume any new state modifications.
    _buildOwner?.buildScope();

    buffer.clear();
    // Render the rebuilt element tree on our double buffer canvas.
    rootElement.layout(BoxConstraints.tight(Size(_width, _computedHeight)));
    rootElement.paint(buffer, Offset.zero);

    if (debugPaintHoverEnabled && _lastMousePosition != null) {
      final hovered = _findHoveredElement(rootElement, _lastMousePosition);
      if (hovered != null) {
        _highlightHoveredElement(buffer, hovered);
      }
    }

    if (debugPaintSizeEnabled) {
      _drawElementOutlines(rootElement, buffer, Offset.zero);
    }

    onFramePainted?.call(buffer);

    if (mode == ExecutionMode.standalone) {
      final b = terminal.backend;
      try {
        (b as dynamic).buffer = buffer;
      } catch (_) {
        // Ignore if backend doesn't support a buffer setter (e.g. real/stub backend)
      }

      final sb = StringBuffer();
      _renderer?.render(buffer, sb);
      if (sb.isNotEmpty) {
        b.write(sb.toString());
      }
    }
  }

  /// Forces a rebuild of the element tree and repaints to the internal buffer.
  void pump() {
    if (_rootElement != null) {
      _rootElement!.markNeedsBuild();
    }
    draw();
  }

  /// Starts the inline prompt loop and returns a Future containing the final result.
  Future<T?> run() async {
    final termSize = await terminal.size;
    _width = termSize.x;

    // Autosize the height dynamically if not explicitly specified.
    _computedHeight =
        height ??
        (alternateScreen ? termSize.y : widget.getIntrinsicHeight(_width));

    // Create a temporary buffer and inline renderer.
    _currentBuffer = Buffer.blank(_width, _computedHeight);
    _renderer = Renderer(
      _width,
      _computedHeight,
      mode: alternateScreen
          ? RenderingMode.alternateScreen
          : RenderingMode.inline,
    );

    _completer = Completer<T?>();
    _isDisposed = false;

    // Wrap the widget tree in a PromptScope to expose the clean completion API
    final scopedWidget = PromptScope(
      onDone: (result) {
        final comp = _completer;
        if (comp != null && !comp.isCompleted) {
          comp.complete(result as T?);
        }
      },
      child: FocusScope(autofocus: true, child: widget),
    );

    _buildOwner = BuildOwner(onNeedVisualUpdate: draw);

    final rootElement = scopedWidget.createElement();
    rootElement.owner = _buildOwner;
    rootElement.mount(null);
    _rootElement = rootElement;

    if (mode == ExecutionMode.standalone && debugPaintHoverEnabled) {
      terminal.enableMouseTracking();
    }

    // Initial frame draw
    rootElement.markNeedsBuild();
    draw();

    StreamSubscription<Point<int>>? sizeSubscription;
    StreamSubscription<term.InputEvent>? subscription;

    if (mode == ExecutionMode.standalone) {
      sizeSubscription = terminal.watchSize().listen((size) {
        if (_isDisposed) return;
        _width = size.x;
        _computedHeight =
            height ??
            (alternateScreen ? size.y : widget.getIntrinsicHeight(_width));
        _currentBuffer?.resize(_width, _computedHeight);
        _renderer = Renderer(
          _width,
          _computedHeight,
          mode: alternateScreen
              ? RenderingMode.alternateScreen
              : RenderingMode.inline,
        );
        rootElement.markNeedsBuild();
        draw();
      });

      subscription = terminal.events.listen(
        (event) {
          if (_completer!.isCompleted) return;

          if (event is term.KeyEvent) {
            var isDone = false;

            // Step 1: Custom Interceptor
            if (onKeyEvent != null) {
              isDone = onKeyEvent!(event);
            }

            // Step 2: Widget Event Routing
            if (!isDone) {
              isDone = _routeKeyEvent(rootElement, event);
            }

            // Step 3: Standard & System Exit Evaluation
            if (!isDone) {
              final trigger = _detectTrigger(event);
              if (trigger != null && exitConditions.containsKey(trigger)) {
                _handleAction(trigger, event);
                return;
              }
            }

            if (isDone) {
              rootElement.markNeedsBuild();
            }

            // Force a redraw to reflect any selections or edits.
            draw();
          } else if (event is term.MouseEvent) {
            if (debugPaintHoverEnabled) {
              _lastMousePosition = Point<int>(event.x, event.y);
            }
            var isDone = false;
            if (_mouseCaptureElement != null &&
                (event.type == term.MouseEventType.drag ||
                    event.type == term.MouseEventType.release)) {
              final captureElement = _mouseCaptureElement!;
              final absOffset = _getAbsoluteOffset(captureElement);
              final sx = event.x - 1;
              final sy = event.y - 1;
              final localX = sx - absOffset.dx;
              final localY = sy - absOffset.dy;

              isDone = _routeToElement(captureElement, event, localX, localY);

              if (event.type == term.MouseEventType.release) {
                _mouseCaptureElement = null;
              }
            } else {
              isDone = _routeMouseEvent(rootElement, event, Offset.zero);
            }

            if (isDone || debugPaintHoverEnabled) {
              draw();
            }
          }
        },
        onDone: () {
          if (_completer != null && !_completer!.isCompleted) {
            _completer!.complete(null);
          }
        },
        onError: (e, stack) {
          if (!_completer!.isCompleted) {
            _completer!.completeError(e, stack);
          }
        },
      );
    }

    try {
      return await _completer!.future;
    } finally {
      _isDisposed = true;
      sizeSubscription?.cancel();
      subscription?.cancel();
      // Restore cursor visibility
      if (mode == ExecutionMode.standalone) {
        terminal.showCursor();
        if (debugPaintHoverEnabled) {
          terminal.disableMouseTracking();
        }
      }
      _rootElement?.unmount();
    }
  }

  /// Programmatically resizes the runner viewport and updates layout/buffers.
  void resize(int width, int height) {
    _width = width;
    _computedHeight = height;
    _currentBuffer?.resize(width, height);
    _renderer = Renderer(
      width,
      height,
      mode: alternateScreen
          ? RenderingMode.alternateScreen
          : RenderingMode.inline,
    );

    final rootElement = _rootElement;
    if (rootElement != null) {
      _updateWindowManagers(rootElement, width, height);
      rootElement.markNeedsBuild();
    }
    draw();
  }

  void _updateWindowManagers(Element element, int width, int height) {
    final w = element.widget;
    try {
      final dynamic dynWidget = w;
      if (dynWidget.windowManager != null) {
        final dynamic wm = dynWidget.windowManager;
        wm.screenSize = Size(width, height);
      }
    } catch (_) {}

    if (element is StatefulElement) {
      final state = element.state;
      try {
        final dynamic dynState = state;
        if (dynState.windowManager != null) {
          final dynamic wm = dynState.windowManager;
          wm.screenSize = Size(width, height);
        }
      } catch (_) {}
    }

    element.visitChildren((child) {
      _updateWindowManagers(child, width, height);
    });
  }

  /// Recursively walks the element tree to find the focused element and route the key event.
  bool _routeKeyEvent(Element element, term.KeyEvent event) {
    final primaryFocus = FocusManager.instance.primaryFocus;
    if (primaryFocus != null) {
      if (primaryFocus.bubbleKeyEvent(event)) {
        return true;
      }
    }

    final elWidget = element.widget;
    bool isFocused = false;
    if (elWidget is Focusable) {
      isFocused = (elWidget as Focusable).focused;
    }

    if (element is StatefulElement) {
      final state = element.state;
      if (state is Focusable) {
        isFocused = isFocused || (state as Focusable).focused;
      }
    }

    bool consumed = false;

    if (isFocused) {
      var handledByState = false;
      if (element is StatefulElement) {
        final state = element.state;
        if (state is KeyEventHandler) {
          if ((state as KeyEventHandler).handleKeyEvent(event)) {
            consumed = true;
          }
          handledByState = true;
        }
      }
      if (!handledByState) {
        if (elWidget is KeyEventHandler) {
          if ((elWidget as KeyEventHandler).handleKeyEvent(event)) {
            consumed = true;
          }
        }
      }
    }

    if (consumed) return true;

    bool childConsumed = false;
    element.visitChildren((child) {
      if (!childConsumed) {
        childConsumed = _routeKeyEvent(child, event);
      }
    });

    return childConsumed;
  }

  /// Recursively walks the element tree to route a mouse event spatially.
  bool _routeMouseEvent(
    Element element,
    term.MouseEvent event,
    Offset parentOffset,
  ) {
    final absOffset = parentOffset + element.relativeOffset;
    final sx = event.x - 1;
    final sy = event.y - 1;

    // Check if the mouse is within the element's bounding box
    final inside =
        sx >= absOffset.dx &&
        sx < absOffset.dx + element.size.width &&
        sy >= absOffset.dy &&
        sy < absOffset.dy + element.size.height;

    if (!inside) {
      return false;
    }

    // Traverse children in reverse order (topmost first, e.g. Stack children at the end are on top)
    final children = <Element>[];
    element.visitChildren((child) {
      children.add(child);
    });

    for (final child in children.reversed) {
      final childConsumed = _routeMouseEvent(child, event, absOffset);
      if (childConsumed) {
        return true;
      }
    }

    final localX = sx - absOffset.dx.toInt();
    final localY = sy - absOffset.dy.toInt();

    final handled = _routeToElement(element, event, localX, localY);
    if (handled) {
      if (event.type == term.MouseEventType.press) {
        _mouseCaptureElement = element;
      }
      return true;
    }

    return false;
  }
}

/// Extension on [term.Terminal] to print a widget inline using the double-buffered renderer layout.
extension PrintWidgetExtension on term.Terminal {
  /// Renders and prints the given [widget] to standard output at the current inline cursor position.
  void printWidget(Widget widget) {
    var width = backend.size.x;
    if (width <= 0) {
      width = 80;
    }

    final height = widget.getIntrinsicHeight(width);

    final buffer = Buffer.blank(width, height);
    final element = widget.createElement();
    element.mount(null);
    element.layout(BoxConstraints.tight(Size(width, height)));
    element.paint(buffer, Offset.zero);
    if (debugPaintSizeEnabled) {
      _drawElementOutlines(element, buffer, Offset.zero);
    }
    element.unmount();

    final renderer = Renderer(width, height, mode: RenderingMode.inline);
    final sb = StringBuffer();
    renderer.render(buffer, sb);
    if (sb.isNotEmpty) {
      backend.write(sb.toString());
    }
  }
}

/// An inherited widget that abstracts prompt completion and lifecycle controls,
/// shielding descendant widgets from any low-level/internal event buses.
///
/// Example:
/// ```dart
/// class MySubmitButton extends Widget {
///   @override
///   void render(Buffer buffer, Rect area) { ... }
///
///   bool handleKeyEvent(KeyEvent event) {
///     if (event.key == 'enter') {
///       PromptScope.of(context)?.done('submitted_value');
///       return true;
///     }
///     return false;
///   }
/// }
/// ```
class PromptScope extends InheritedWidget {
  /// The callback invoked to signal completion to the parent [PromptRunner].
  final void Function(Object? result) _onDone;

  /// Creates a [PromptScope] with the given [onDone] callback and [child].
  const PromptScope({
    required void Function(Object? result) onDone,
    required super.child,
  }) : _onDone = onDone;

  /// Obtains the nearest [PromptScope] from the build context.
  static PromptScope? of(BuildContext context) {
    return context.dependOnInheritedWidgetOfExactType<PromptScope>();
  }

  /// Programmatically completes the current prompt, returning an optional [result].
  ///
  /// This signals the managing [PromptRunner] to stop its run loop, teardown
  /// its resources, and resolve the Future returned by [PromptRunner.run] with [result].
  ///
  /// Subsequent calls to this method after the prompt has already completed are safe no-ops.
  void done([Object? result]) {
    _onDone(result);
  }

  @override
  bool updateShouldNotify(PromptScope oldWidget) => false;
}

void _drawBoxOutline(Buffer buffer, Offset offset, Size size, Style style) {
  final ox = offset.dx;
  final oy = offset.dy;
  final w = size.width;
  final h = size.height;

  if (w <= 0 || h <= 0) return;

  if (w == 1 && h == 1) {
    _safeSetCell(buffer, ox, oy, '¤', style);
    return;
  }

  // Draw horizontal edges
  for (var x = ox + 1; x < ox + w - 1; x++) {
    _safeSetCell(buffer, x, oy, '─', style);
    _safeSetCell(buffer, x, oy + h - 1, '─', style);
  }

  // Draw vertical edges
  for (var y = oy + 1; y < oy + h - 1; y++) {
    _safeSetCell(buffer, ox, y, '│', style);
    _safeSetCell(buffer, ox + w - 1, y, '│', style);
  }

  // Draw corners
  _safeSetCell(buffer, ox, oy, '┌', style);
  if (w > 1) {
    _safeSetCell(buffer, ox + w - 1, oy, '┐', style);
  }
  if (h > 1) {
    _safeSetCell(buffer, ox, oy + h - 1, '└', style);
  }
  if (w > 1 && h > 1) {
    _safeSetCell(buffer, ox + w - 1, oy + h - 1, '┘', style);
  }
}

void _safeSetCell(Buffer buffer, int x, int y, String char, Style style) {
  final cell = buffer.getCell(x, y);
  if (cell != null) {
    cell.char = char;
    cell.style = style;
  }
}

void _drawElementOutlines(
  Element element,
  Buffer buffer,
  Offset absoluteOffset,
) {
  final size = element.size;
  // Alternate colors based on element depth: even depth gets Cyan, odd depth gets Yellow.
  final color = (element.depth % 2 == 0)
      ? const Color(0, 255, 255)
      : const Color(255, 255, 0);
  final style = Style(foreground: color);

  _drawBoxOutline(buffer, absoluteOffset, size, style);

  element.visitChildren((child) {
    _drawElementOutlines(child, buffer, absoluteOffset + child.relativeOffset);
  });
}

Element? _findHoveredElement(
  Element rootElement,
  Point<int>? lastMousePosition,
) {
  if (lastMousePosition == null) return null;
  return _findDeepestElementAt(rootElement, Offset.zero, lastMousePosition);
}

Element? _findDeepestElementAt(
  Element element,
  Offset absoluteOffset,
  Point<int> mousePos,
) {
  final px = mousePos.x - 1;
  final py = mousePos.y - 1;

  final ox = absoluteOffset.dx;
  final oy = absoluteOffset.dy;
  final w = element.size.width;
  final h = element.size.height;

  if (px < ox || px >= ox + w || py < oy || py >= oy + h) {
    return null;
  }

  Element? deepestChild;
  element.visitChildren((child) {
    final childOffset = absoluteOffset + child.relativeOffset;
    final childDeepest = _findDeepestElementAt(child, childOffset, mousePos);
    if (childDeepest != null) {
      deepestChild = childDeepest;
    }
  });

  return deepestChild ?? element;
}

Offset _getAbsoluteOffset(Element element) {
  var offset = Offset.zero;
  Element? current = element;
  while (current != null) {
    offset = offset + current.relativeOffset;
    current = current.parent;
  }
  return offset;
}

void _highlightHoveredElement(Buffer buffer, Element element) {
  final offset = _getAbsoluteOffset(element);
  final w = element.size.width;
  final h = element.size.height;
  final ox = offset.dx;
  final oy = offset.dy;

  for (var y = oy; y < oy + h; y++) {
    for (var x = ox; x < ox + w; x++) {
      final cell = buffer.getCell(x, y);
      if (cell != null) {
        cell.style = Style(
          foreground: cell.style.foreground,
          background: const Color(255, 0, 255), // Magenta background
          modifiers: cell.style.modifiers & ~Modifier.transparent,
        );
      }
    }
  }
}

bool _routeToElement(
  Element element,
  term.MouseEvent event,
  int localX,
  int localY,
) {
  if (element is StatefulElement) {
    final state = element.state;
    try {
      (state as dynamic).handleMouseEvent(event, localX, localY);
      return true;
    } catch (_) {
      // Ignored if not supported
    }
  }

  try {
    (element as dynamic).handleMouseEvent(event, localX, localY);
    return true;
  } catch (_) {
    // Ignored if not supported
  }

  final elWidget = element.widget;
  try {
    (elWidget as dynamic).handleMouseEvent(event, localX, localY);
    return true;
  } catch (_) {
    // Ignored if not supported
  }

  return false;
}

/// Defines sizing policies for layout layers in a compositing scene.
enum LayerSizing {
  /// Matches the dimensions of the terminal screen/viewport.
  fullscreen,

  /// Calculates dimensions dynamically based on child widget intrinsic height and width.
  intrinsic,

  /// Uses hardcoded dimensions.
  fixed,
}

/// A contract defining terminal state requests from a runner or layer.
abstract interface class TerminalStateRequest {
  /// Whether mouse tracking features are requested.
  bool get wantsMouseTracking;

  /// Whether alternate screen buffer mode is requested.
  bool get wantsAlternateScreen;

  /// Whether the hardware terminal cursor should be shown.
  bool get showsCursor;

  /// The requested cursor coordinates, if any.
  Point<int>? get requestedCursorPosition;
}

/// An interface representing a rendering system in a composited scene.
abstract interface class SceneRenderer implements TerminalStateRequest {
  /// The current rendering output buffer.
  Buffer? get currentBuffer;
}

/// Represents a single renderable layer inside a composited terminal scene.
class SceneLayer {
  /// The renderer managing this layer.
  final SceneRenderer renderer;

  /// The sizing policy for this layer.
  final LayerSizing sizing;

  /// The horizontal column coordinate of the layer's top-left corner.
  int x;

  /// The vertical row coordinate of the layer's top-left corner.
  int y;

  /// The stacking order index of the layer.
  int zIndex;

  /// Creates a new [SceneLayer] with the given [renderer], [sizing], and placement parameters.
  SceneLayer({
    required this.renderer,
    required this.sizing,
    this.x = 0,
    this.y = 0,
    this.zIndex = 0,
  });
}
