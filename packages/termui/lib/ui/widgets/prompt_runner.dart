import 'dart:async';
import '../../terminal/terminal.dart' as term;
import '../buffer.dart';
import '../layout.dart';
import '../renderer.dart';
import 'focus.dart';
import '../window.dart';

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
class PromptRunner<T> {
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

  /// Default exit conditions mapping.
  static const Map<PromptExitTrigger, PromptExitAction> defaultExitConditions =
      {
        PromptExitTrigger.controlC: PromptExitAction.abort,
        PromptExitTrigger.enter: PromptExitAction.complete,
      };

  Completer<T?>? _completer;
  Element? _rootElement;
  bool _isDisposed = false;

  /// Exposes the root element of the mounted widget tree for testing.
  Element? get rootElement => _rootElement;

  /// Exposes whether the prompt runner is disposed.
  bool get isDisposed => _isDisposed;

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

  /// Starts the inline prompt loop and returns a Future containing the final result.
  Future<T?> run() async {
    final termSize = await terminal.size;
    var width = termSize.x;

    // Autosize the height dynamically if not explicitly specified.
    var computedHeight =
        height ??
        (alternateScreen ? termSize.y : widget.getIntrinsicHeight(width));

    // Create a temporary buffer and inline renderer.
    var buffer = Buffer.blank(width, computedHeight);
    var renderer = Renderer(
      width,
      computedHeight,
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

    // Mount the widget tree element persistently so states and focus configuration
    // are retained between keyboard event loop iterations.
    final rootElement = scopedWidget.createElement()..mount(null);
    _rootElement = rootElement;

    void draw() {
      if (_isDisposed) return;
      // Rebuild the element tree to consume any new state modifications.
      BuildOwner.buildScope();

      buffer.clear();
      // Render the rebuilt element tree on our double buffer canvas.
      rootElement.layout(BoxConstraints.tight(Size(width, computedHeight)));
      rootElement.paint(buffer, Offset.zero);

      onFramePainted?.call(buffer);

      final sb = StringBuffer();
      renderer.render(buffer, sb);
      if (sb.isNotEmpty) {
        terminal.backend.write(sb.toString());
      }
    }

    // Connect the static repainter callback so that inner setState() invocations
    // (e.g. from typing inside a TextField) trigger screen updates.
    State.onNeedRepaint = draw;

    // Initial frame draw
    BuildOwner.markNeedsBuild(rootElement);
    draw();

    final sizeSubscription = terminal.watchSize().listen((size) {
      if (_isDisposed) return;
      width = size.x;
      computedHeight =
          height ??
          (alternateScreen ? size.y : widget.getIntrinsicHeight(width));
      buffer.resize(width, computedHeight);
      renderer = Renderer(
        width,
        computedHeight,
        mode: alternateScreen
            ? RenderingMode.alternateScreen
            : RenderingMode.inline,
      );
      BuildOwner.markNeedsBuild(rootElement);
      draw();
    });

    final subscription = terminal.events.listen(
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
            BuildOwner.markNeedsBuild(rootElement);
          }

          // Force a redraw to reflect any selections or edits.
          draw();
        } else if (event is term.MouseEvent) {
          final isDone = _routeMouseEvent(rootElement, event, Offset.zero);
          if (isDone) {
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

    try {
      return await _completer!.future;
    } finally {
      _isDisposed = true;
      sizeSubscription.cancel();
      subscription.cancel();
      // Restore cursor visibility
      terminal.showCursor();
      // Reset the repaint handler to avoid leaks.
      State.onNeedRepaint = null;
      _rootElement?.unmount();
    }
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

    final elWidget = element.widget;
    final localX = sx - absOffset.dx.toInt();
    final localY = sy - absOffset.dy.toInt();

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

    try {
      (elWidget as dynamic).handleMouseEvent(event, localX, localY);
      return true;
    } catch (_) {
      // Ignored if not supported
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
