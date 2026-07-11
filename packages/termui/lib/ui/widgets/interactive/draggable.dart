import 'dart:math';
import 'package:termui/termui.dart';

/// A wrapper widget that makes a child draggable inside a terminal window.
class Draggable<T> extends Widget {
  /// The payload data bound to the draggable widget.
  final T data;

  /// The child widget to display.
  final Widget child;

  /// Creates a [Draggable] widget.
  const Draggable({required this.data, required this.child, super.key});

  @override
  Element createElement() => DraggableElement(this);

  @override
  int getIntrinsicHeight(int width) => child.getIntrinsicHeight(width);

  @override
  int getIntrinsicWidth(int height) => child.getIntrinsicWidth(height);
}

/// The element that coordinates and intercepts mouse drag events for [Draggable].
class DraggableElement extends SingleChildElement implements MouseEventHandler {
  /// Creates a [DraggableElement].
  DraggableElement(Draggable super.widget);

  @override
  Widget? get childWidget => (widget as Draggable).child;

  @override
  Size performLayout(BoxConstraints constraints) {
    if (childElement != null) {
      return childElement!.layout(constraints);
    }
    return Size(constraints.minWidth, constraints.minHeight);
  }

  @override
  void unmount() {
    DragDropManager.unregisterSource(this);
    super.unmount();
  }

  @override
  void handleMouseEvent(MouseEvent event, int localX, int localY) {
    if (event.type == MouseEventType.press) {
      final session = DragSession(
        data: (widget as Draggable).data as Object,
        sourceElement: this,
        startMousePosition: Point<int>(event.x, event.y),
        currentMousePosition: Point<int>(event.x, event.y),
      );
      DragDropManager.startDrag(session);
    } else if (event.type == MouseEventType.drag) {
      DragDropManager.updateDrag(Point<int>(event.x, event.y));
    } else if (event.type == MouseEventType.release) {
      DragDropManager.drop();
    }
  }
}
