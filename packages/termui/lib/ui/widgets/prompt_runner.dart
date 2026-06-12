import 'dart:io';
import '../../terminal/terminal.dart' as term;
import '../buffer.dart';
import '../layout.dart';
import '../renderer.dart';

/// A helper class to run an interactive terminal prompt inline.
/// It encapsulates the event loop, rendering to an inline buffer, and lifecycle management.
class PromptRunner<T> {
  /// The active terminal instance.
  final term.Terminal terminal;

  /// The root widget configuration to display.
  final Widget widget;

  /// The height constraint of the inline rendering block. If null, calculated dynamically.
  final int? height;

  /// Whether pressing Enter automatically completes/confirms the prompt.
  final bool completeOnEnter;

  /// An optional key event handler callback. Returns true if prompt is completed.
  final bool Function(term.KeyEvent event)? onKeyEvent;

  /// An optional completion callback returning the final value of type [T].
  final T Function()? onComplete;

  /// Creates a new [PromptRunner].
  PromptRunner({
    required this.terminal,
    required this.widget,
    this.height,
    this.completeOnEnter = true,
    this.onKeyEvent,
    this.onComplete,
  });

  /// Starts the inline prompt loop and returns a Future containing the final result.
  Future<T?> run() async {
    final termSize = await terminal.size;
    final width = termSize.x;

    // Autosize the height dynamically if not explicitly specified.
    final computedHeight = height ?? widget.getIntrinsicHeight(width);

    // Create a temporary buffer and inline renderer.
    final buffer = Buffer.blank(width, computedHeight);
    final renderer = Renderer(
      width,
      computedHeight,
      mode: RenderingMode.inline,
    );

    // Mount the widget tree element persistently so states and focus configuration
    // are retained between keyboard event loop iterations.
    final rootElement = widget.createElement()..mount(null);

    void draw() {
      // Rebuild the element tree to consume any new state modifications.
      final el = rootElement;
      if (el is StatefulElement) {
        el.rebuild();
      } else if (el is StatelessElement) {
        el.rebuild();
      } else {
        try {
          (el as dynamic).rebuild();
        } catch (_) {}
      }

      buffer.clear();
      // Render the rebuilt element tree on our double buffer canvas.
      rootElement.render(buffer, Rect(0, 0, width, computedHeight));

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
    draw();

    try {
      await for (final event in terminal.events) {
        if (event is term.KeyEvent) {
          // Cleanly catch Ctrl+C to restore cursor and exit
          if (event.key.length == 1 && event.key.codeUnits[0] == 3) {
            terminal.showCursor();
            exit(0);
          }

          var isDone = false;

          // 1. Let custom interceptor handle the key event first
          if (onKeyEvent != null) {
            isDone = onKeyEvent!(event);
          }

          // 2. If not custom-intercepted, route the event down to the focused widgets
          if (!isDone) {
            _routeKeyEvent(rootElement, event);
          }

          // 3. Check if we should auto-complete on Enter
          if (completeOnEnter &&
              (event.key == 'enter' ||
                  event.key == '\n' ||
                  event.key == '\r')) {
            isDone = true;
          }

          // Force a redraw to reflect any selections or edits.
          draw();

          if (isDone) {
            break;
          }
        }
      }
    } finally {
      // Reset the repaint handler to avoid leaks.
      State.onNeedRepaint = null;
    }

    if (onComplete != null) {
      return onComplete!();
    }
    return null;
  }

  /// Recursively walks the element tree to find the focused element and route the key event.
  void _routeKeyEvent(Element element, term.KeyEvent event) {
    final widget = element.widget;
    bool isFocused = false;
    try {
      isFocused = (widget as dynamic).focused == true;
    } catch (_) {}

    if (element is StatefulElement) {
      try {
        isFocused =
            isFocused || (element.state as dynamic).widget.focused == true;
      } catch (_) {}
    }

    if (isFocused) {
      var handledByState = false;
      if (element is StatefulElement) {
        try {
          (element.state as dynamic).handleKeyEvent(event);
          handledByState = true;
        } catch (_) {}
      }
      if (!handledByState) {
        try {
          (widget as dynamic).handleKeyEvent(event);
        } catch (_) {}
      }
    }

    element.visitChildren((child) {
      _routeKeyEvent(child, event);
    });
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
    element.render(buffer, Rect(0, 0, width, height));
    element.unmount();

    final renderer = Renderer(width, height, mode: RenderingMode.inline);
    final sb = StringBuffer();
    renderer.render(buffer, sb);
    if (sb.isNotEmpty) {
      backend.write(sb.toString());
    }
  }
}
