import 'package:termui/termui.dart';
import 'package:termui/terminal/event.dart' as evt;

/// A widget that intercepts keyboard events when it or its children have focus.
class KeyboardListener extends StatefulWidget implements Focusable {
  /// The widget below this widget in the tree.
  final Widget child;

  /// The focus node to use for this listener.
  final FocusNode focusNode;

  /// Called whenever a key event is received.
  /// If it returns true, the event is considered handled.
  final bool Function(evt.KeyEvent event)? onKeyEvent;

  /// Creates a new keyboard listener widget.
  const KeyboardListener({
    super.key,
    required this.child,
    required this.focusNode,
    this.onKeyEvent,
  });

  @override
  bool get focused => focusNode.hasFocus;

  @override
  State<KeyboardListener> createState() => _KeyboardListenerState();
}

class _KeyboardListenerState extends State<KeyboardListener>
    implements KeyEventHandler {
  @override
  void initState() {
    super.initState();
    widget.focusNode.onKeyEvent = widget.onKeyEvent;
  }

  @override
  void didUpdateWidget(KeyboardListener oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.focusNode != oldWidget.focusNode ||
        widget.onKeyEvent != oldWidget.onKeyEvent) {
      oldWidget.focusNode.onKeyEvent = null;
      widget.focusNode.onKeyEvent = widget.onKeyEvent;
    }
  }

  @override
  void dispose() {
    widget.focusNode.onKeyEvent = null;
    super.dispose();
  }

  @override
  bool handleKeyEvent(evt.KeyEvent event) {
    if (widget.onKeyEvent?.call(event) ?? false) {
      return true;
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    return widget.child;
  }
}
