import '../terminal/event.dart';
import 'layout.dart';

export '../terminal/event.dart';

/// An interface that indicates a widget or state can receive keyboard focus.
abstract interface class Focusable {
  /// Whether this object currently has keyboard focus.
  bool get focused;
}

/// An interface that indicates a widget or state can handle terminal keyboard events.
abstract interface class KeyEventHandler {
  /// Handles a keyboard event, returning true if the event was consumed.
  bool handleKeyEvent(KeyEvent event);
}

/// An interface that indicates a widget or state can handle terminal mouse events.
abstract interface class MouseEventHandler {
  /// Handles a mouse event at local coordinates.
  void handleMouseEvent(MouseEvent event, int localX, int localY);
}

/// An interface that indicates a widget or state can handle terminal mouse events with an explicit area boundary.
abstract interface class MouseEventHandlerWithArea {
  /// Handles a mouse event at local coordinates and bounding area.
  void handleMouseEvent(MouseEvent event, int localX, int localY, Rect area);
}
