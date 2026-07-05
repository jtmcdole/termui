import 'package:termui/termui.dart';
import 'package:termui/terminal/event.dart' as evt;

/// A widget that intercepts keyboard events when it or its children have focus.
class KeyboardListener extends StatefulWidget {
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
  State<KeyboardListener> createState() => _KeyboardListenerState();
}

class _KeyboardListenerState extends State<KeyboardListener>
    with FocusableStateMixin<KeyboardListener>
    implements KeyEventHandler {
  @override
  bool get isWidgetFocused => true; // Always participate in focus if focusNode is attached

  @override
  FocusNode get focusNode => widget.focusNode;

  @override
  String get focusNodeIdPrefix => 'keyboard_listener';

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
