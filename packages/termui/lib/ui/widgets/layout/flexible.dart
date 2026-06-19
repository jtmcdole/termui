import 'package:termui/termui.dart';

/// Undocumented public member.
class Flexible extends Widget {
  /// The flex factor to use for this child.
  final int flex;

  /// The child widget.
  final Widget child;

  /// Creates a widget that controls how a child of a [Row] or [Column] flexes.
  const Flexible({this.flex = 1, required this.child});

  @override
  Element createElement() => FlexibleElement(this);

  @override
  int getIntrinsicHeight(int width) {
    return child.getIntrinsicHeight(width);
  }
}

/// An element that manages a [Flexible] widget.
class FlexibleElement extends Element {
  /// The child element.
  Element? childElement;

  /// Creates a flexible element for a [Flexible] widget.
  FlexibleElement(Flexible super.widget);

  @override
  void mount(Element? parent) {
    super.mount(parent);
    rebuild();
  }

  @override
  void update(Widget newWidget) {
    super.update(newWidget);
    rebuild();
  }

  @override
  void rebuild() {
    final flex = widget as Flexible;
    if (childElement != null &&
        childElement!.widget.runtimeType == flex.child.runtimeType) {
      childElement!.update(flex.child);
    } else {
      childElement?.unmount();
      childElement = flex.child.createElement();
      childElement!.mount(this);
    }
  }

  @override
  void unmount() {
    childElement?.unmount();
    super.unmount();
  }

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
  void performPaint(Buffer buffer, Offset offset) {
    if (childElement != null) {
      childElement!.paint(buffer, offset + childElement!.relativeOffset);
    }
  }

  @override
  void visitChildren(void Function(Element child) visitor) {
    if (childElement != null) visitor(childElement!);
  }
}

/// An [Expanded] widget forces its child to consume all remaining space in a [Row] or [Column].
class Expanded extends Flexible {
  /// Creates an expanded widget.
  const Expanded({super.flex = 1, required super.child});
}

/// Represents a relative alignment in 2D space.
