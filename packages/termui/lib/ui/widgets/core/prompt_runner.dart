import 'dart:async';
import 'dart:math';
import 'package:termui/termui.dart';
import 'package:termui/terminal/terminal.dart' as term;

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
class PromptRunner<T> implements ListenableSceneRenderer, Reassemblable {
  static final int _traceKeyEventId = Tracer.registerString(
    'PromptRunner:handleKeyEvent',
  );
  static final int _traceMouseEventId = Tracer.registerString(
    'PromptRunner:handleMouseEvent',
  );

  /// The active terminal instance.
  final term.Terminal terminal;

  Widget _widget;

  /// The root widget configuration to display.
  Widget get widget => _widget;
  set widget(Widget value) {
    if (_widget == value) return;
    _widget = value;
    final rootElement = _rootElement;
    if (rootElement != null) {
      final scopedWidget = PromptScope(
        onDone: (result) {
          final comp = _completer;
          if (comp != null && !comp.isCompleted) {
            comp.complete(result as T?);
          }
        },
        child: FocusScope(autofocus: true, child: _widget),
      );
      rootElement.update(scopedWidget);

      if (!alternateScreen && mode == ExecutionMode.standalone) {
        _computedHeight = _widget.getIntrinsicHeight(_width);
        _currentBuffer?.resize(_width, _computedHeight);
        _renderer = Renderer(
          _width,
          _computedHeight,
          mode: alternateScreen
              ? RenderingMode.alternateScreen
              : RenderingMode.inline,
        );
      }
      render();
    }
  }

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

  /// Static hook called when a prompt runner starts running.
  static void Function(PromptRunner<dynamic> runner)? onPromptStarted;

  /// Static hook called when a prompt runner ends/disposes.
  static void Function(PromptRunner<dynamic> runner)? onPromptEnded;

  Completer<T?>? _completer;
  Element? _rootElement;
  bool _isDisposed = false;
  void Function()? _onNeedVisualUpdate;

  @override
  void Function()? get onNeedVisualUpdate => _onNeedVisualUpdate;

  @override
  set onNeedVisualUpdate(void Function()? value) {
    _onNeedVisualUpdate = value;
  }

  @override
  bool get isDirty => _buildOwner?.isDirtyElements.isNotEmpty ?? false;

  /// Exposes whether a draw frame is currently scheduled.
  bool get hasScheduledFrame => _drawScheduled;

  Point<int>? _lastMousePosition;
  Element? _mouseCaptureElement;
  BuildOwner? _buildOwner;
  bool _drawScheduled = false;

  void _scheduleRender() {
    if (_drawScheduled) return;
    _drawScheduled = true;
    scheduleMicrotask(() {
      _drawScheduled = false;
      render();
    });
  }

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
    required Widget widget,
    Map<PromptExitTrigger, PromptExitAction>? exitConditions,
    this.onKeyEvent,
    this.onComplete,
    this.alternateScreen = false,
    this.onFramePainted,
    this.mode = ExecutionMode.standalone,
  }) : _widget = widget,
       exitConditions = exitConditions ?? defaultExitConditions;

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
  @override
  void dispose() {
    if (_isDisposed) return;
    _isDisposed = true;
    if (mode == ExecutionMode.standalone) {
      TermuiBinding.unregister(this);
    }
    onPromptEnded?.call(this);

    // Unmount element tree so focus nodes and states can clean up
    _rootElement?.unmount();
    _rootElement = null;

    final activeCompleter = _completer;
    if (activeCompleter != null && !activeCompleter.isCompleted) {
      activeCompleter.complete(null);
    }

    onNeedVisualUpdate = null;
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
  @override
  void render() {
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

    onFramePainted?.call(buffer);
    onNeedVisualUpdate?.call();

    if (mode == ExecutionMode.standalone) {
      final b = terminal.backend;
      if (b is BufferedTerminalBackend) {
        b.buffer = buffer;
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
    final rootElement = _rootElement;
    if (rootElement != null) {
      rootElement.markNeedsBuild();
    }
    render();
  }

  /// Called during hot reload to force the entire widget tree to rebuild and repaint.
  @override
  void reassemble() {
    _rootElement?.reassemble();
    _scheduleRender();
  }

  /// Starts the inline prompt loop and returns a Future containing the final result.
  Future<T?> run() async {
    onPromptStarted?.call(this);

    if (mode == ExecutionMode.standalone) {
      TermuiBinding.register(this);
      final termSize = await terminal.size;
      _width = termSize.x;
      _computedHeight = alternateScreen
          ? termSize.y
          : widget.getIntrinsicHeight(_width);
      if (alternateScreen) {
        terminal.enterAlternateScreen();
      }
    } else {
      if (_width <= 0) {
        _width = 80;
      }
      if (_computedHeight <= 0) {
        _computedHeight = widget.getIntrinsicHeight(_width);
      }
    }

    StreamSubscription<Point<int>>? sizeSubscription;
    StreamSubscription<term.InputEvent>? subscription;

    try {
      // Create a temporary buffer and inline renderer.
      _currentBuffer = Buffer.blank(_width, _computedHeight);
      _renderer = Renderer(
        _width,
        _computedHeight,
        mode: alternateScreen
            ? RenderingMode.alternateScreen
            : RenderingMode.inline,
      );

      final completer = Completer<T?>();
      _completer = completer;
      _isDisposed = false;

      // Wrap the widget tree in a PromptScope to expose the clean completion API
      final scopedWidget = PromptScope(
        onDone: (result) {
          if (!completer.isCompleted) {
            completer.complete(result as T?);
          }
        },
        child: FocusScope(autofocus: true, child: widget),
      );

      _buildOwner = BuildOwner(onNeedVisualUpdate: _scheduleRender);

      final rootElement = scopedWidget.createElement();
      rootElement.owner = _buildOwner;
      rootElement.mount(null);
      _rootElement = rootElement;

      if (mode == ExecutionMode.standalone && debugPaintHoverEnabled) {
        terminal.enableMouseTracking();
      }

      // Initial frame draw
      rootElement.markNeedsBuild();
      render();

      if (mode == ExecutionMode.standalone) {
        sizeSubscription = terminal.watchSize().listen((size) {
          if (_isDisposed) return;
          _width = size.x;
          _computedHeight = alternateScreen
              ? size.y
              : widget.getIntrinsicHeight(_width);
          _currentBuffer?.resize(_width, _computedHeight);
          _renderer = Renderer(
            _width,
            _computedHeight,
            mode: alternateScreen
                ? RenderingMode.alternateScreen
                : RenderingMode.inline,
          );
          rootElement.markNeedsBuild();
          render();
        });

        subscription = terminal.events.listen(
          (event) {
            if (event is term.KeyEvent) {
              handleKeyEvent(event);
            } else if (event is term.MouseEvent) {
              handleMouseEvent(event);
            }
          },
          onDone: () {
            if (!completer.isCompleted) {
              completer.complete(null);
            }
          },
          onError: (e, stack) {
            if (!completer.isCompleted) {
              completer.completeError(e, stack);
            }
          },
        );
      }

      return await completer.future;
    } finally {
      if (mode == ExecutionMode.standalone) {
        TermuiBinding.unregister(this);
      }
      final wasDisposedBefore = _isDisposed;
      _isDisposed = true;
      if (!wasDisposedBefore) {
        onPromptEnded?.call(this);
      }
      sizeSubscription?.cancel();
      subscription?.cancel();
      // Restore cursor visibility
      if (mode == ExecutionMode.standalone) {
        if (alternateScreen) {
          terminal.exitAlternateScreen();
        }
        terminal.showCursor();
        if (debugPaintHoverEnabled) {
          terminal.disableMouseTracking();
        }
      }
      _rootElement?.unmount();
      _rootElement = null;
    }
  }

  /// Programmatically resizes the runner viewport and updates layout/buffers.
  @override
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
      rootElement.markNeedsBuild();
    }
    render();
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

    final isMoveOrDragOrRelease =
        event.type == term.MouseEventType.move ||
        event.type == term.MouseEventType.drag ||
        event.type == term.MouseEventType.release;

    if (!inside && !isMoveOrDragOrRelease) {
      return false;
    }

    if (element is AbsorbPointerElement &&
        (element.widget as AbsorbPointer).absorbing &&
        inside) {
      final localX = sx - absOffset.dx.toInt();
      final localY = sy - absOffset.dy.toInt();
      _routeToElement(element, event, localX, localY);
      return true;
    }

    // Traverse children in reverse order (topmost first, e.g. Stack children at the end are on top)
    final children = <Element>[];
    element.visitChildren((child) {
      children.add(child);
    });

    bool childConsumed = false;
    for (final child in children.reversed) {
      final consumed = _routeMouseEvent(child, event, absOffset);
      if (consumed) {
        childConsumed = true;
        if (!isMoveOrDragOrRelease) {
          break;
        }
      }
    }

    if (childConsumed && inside) {
      return true;
    }

    final localX = sx - absOffset.dx.toInt();
    final localY = sy - absOffset.dy.toInt();

    final handled = _routeToElement(element, event, localX, localY);
    if (handled) {
      if (event.type == term.MouseEventType.press) {
        _mouseCaptureElement = element;
      }
      return inside;
    }

    return childConsumed && inside;
  }

  @override
  bool handleKeyEvent(term.KeyEvent event) {
    Tracer.record(
      _traceKeyEventId,
      Phase.begin,
      TraceCategory.events,
      metadata: {'key': event.logicalKey},
    );
    try {
      final completer = _completer;
      if (completer == null || completer.isCompleted) return false;

      var isDone = false;
      final rootElement = _rootElement;
      if (rootElement == null) return false;

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
        if (_detectTrigger(event) case final trigger?) {
          if (exitConditions.containsKey(trigger)) {
            _handleAction(trigger, event);
            return true;
          }
        }
      }

      if (isDone) {
        rootElement.markNeedsBuild();
      }
      return isDone;
    } finally {
      Tracer.record(_traceKeyEventId, Phase.end, TraceCategory.events);
    }
  }

  @override
  void handleMouseEvent(term.MouseEvent event) {
    Tracer.record(_traceMouseEventId, Phase.begin, TraceCategory.events);
    try {
      final completer = _completer;
      if (completer == null || completer.isCompleted) return;

      if (debugPaintHoverEnabled) {
        _lastMousePosition = Point<int>(event.x, event.y);
      }
      var isDone = false;
      final rootElement = _rootElement;
      if (rootElement == null) return;

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
        _scheduleRender();
      }
    } finally {
      Tracer.record(_traceMouseEventId, Phase.end, TraceCategory.events);
    }
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
  buffer.setAttributes(
    x,
    y,
    char: char,
    fg: style.foreground?.argb ?? 0,
    bg: style.background?.argb ?? 0,
    modifiers: style.modifiers,
  );
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
  if (element.size.width <= 0 || element.size.height <= 0) return;
  final offset = _getAbsoluteOffset(element);

  final left = max(0, offset.dx - 1);
  final top = max(0, offset.dy - 1);
  final right = min(buffer.width - 1, offset.dx + element.size.width);
  final bottom = min(buffer.height - 1, offset.dy + element.size.height);

  final expandedOffset = Offset(left, top);
  final expandedSize = Size(right - left + 1, bottom - top + 1);

  const style = Style(
    foreground: Color(255, 0, 255), // Magenta
    modifiers: Modifier.bold,
  );

  _drawBoxOutline(buffer, expandedOffset, expandedSize, style);

  final typeName = element.widget.runtimeType.toString();
  final label = ' $typeName ';

  const labelStyle = Style(
    foreground: Color(255, 255, 255), // White
    background: Color(255, 0, 255), // Magenta
    modifiers: Modifier.bold,
  );

  final int badgeY;
  if (bottom == buffer.height - 1) {
    badgeY = top;
  } else {
    badgeY = bottom;
  }

  final badgeX = max(0, min(left + 1, buffer.width - label.length));

  buffer.writeString(badgeX, badgeY, label, labelStyle);
}

bool _routeToElement(
  Element element,
  term.MouseEvent event,
  int localX,
  int localY,
) {
  final area = Rect(0, 0, element.size.width, element.size.height);

  bool tryRoute(Object handler) {
    if (handler case final MouseEventHandlerWithArea h) {
      h.handleMouseEvent(event, localX, localY, area);
      return true;
    }
    if (handler case final MouseEventHandler h) {
      h.handleMouseEvent(event, localX, localY);
      return true;
    }
    return false;
  }

  if (element is StatefulElement && tryRoute(element.state)) {
    return true;
  }
  if (tryRoute(element)) {
    return true;
  }
  if (tryRoute(element.widget)) {
    return true;
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

  /// Handles key events routed to this renderer. Returns true if handled.
  bool handleKeyEvent(term.KeyEvent event);

  /// Handles mouse events routed to this renderer.
  void handleMouseEvent(term.MouseEvent event);

  /// Resizes the renderer viewport and updates layout/buffers.
  void resize(int width, int height);

  /// Cleans up resources.
  void dispose();
}

/// An interface for [SceneRenderer]s that can notify their manager when they need a visual update.
abstract interface class ListenableSceneRenderer implements SceneRenderer {
  /// Callback triggered when this renderer's visual content changes and needs to be composited/repainted.
  void Function()? get onNeedVisualUpdate;
  set onNeedVisualUpdate(void Function()? value);

  /// Whether the renderer needs a visual rebuild/update.
  bool get isDirty;

  /// Forces a rebuild/paint of the renderer.
  void render();
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

  /// The width of this layer, if fixed.
  int? width;

  /// The height of this layer, if fixed.
  int? height;

  /// The stacking order index of the layer.
  int zIndex;

  /// Whether this layer is draggable via mouse click-and-drag.
  bool draggable;

  /// Whether this layer can be resized by dragging its corners.
  bool resizable;

  /// Optional callback invoked when the terminal is resized.
  void Function(Point<int> newSize)? onResize;

  /// Creates a new [SceneLayer] with the given [renderer], [sizing], and placement parameters.
  SceneLayer({
    required this.renderer,
    required this.sizing,
    this.x = 0,
    this.y = 0,
    this.width,
    this.height,
    this.zIndex = 0,
    this.draggable = false,
    this.resizable = false,
    this.onResize,
  }) {
    if (sizing == LayerSizing.fixed && width != null && height != null) {
      renderer.resize(width!, height!);
    }
  }
}
