import 'package:termui/termui.dart';

/// A widget that absorbs pointer events.
///
/// When [absorbing] is true, this widget prevents its subtree from receiving
/// pointer events by terminating event routing at this level.
class AbsorbPointer extends Widget {
  /// The widget below this widget in the tree.
  final Widget child;

  /// Whether this widget absorbs pointer events.
  final bool absorbing;

  /// Creates a widget that absorbs pointer events.
  const AbsorbPointer({super.key, required this.child, this.absorbing = true});

  @override
  Element createElement() => AbsorbPointerElement(this);

  @override
  int getIntrinsicHeight(int width) => child.getIntrinsicHeight(width);

  @override
  int getIntrinsicWidth(int height) => child.getIntrinsicWidth(height);
}

/// Element for [AbsorbPointer] that handles pointer event absorption.
class AbsorbPointerElement extends SingleChildElement
    implements MouseEventHandler {
  /// Creates an absorbing pointer element.
  AbsorbPointerElement(AbsorbPointer super.widget);

  @override
  Widget? get childWidget => (widget as AbsorbPointer).child;

  @override
  Size performLayout(BoxConstraints constraints) {
    if (childElement != null) {
      final size = childElement!.layout(constraints);
      childElement!.relativeOffset = Offset.zero;
      return size;
    }
    return constraints.constrain(Size.zero);
  }

  @override
  void handleMouseEvent(MouseEvent event, int localX, int localY) {
    // Absorbs pointer events and does not propagate them to children.
  }
}
