import '../buffer.dart';
import '../layout.dart';

/// A widget that wraps another widget and inserts padding around it.
class Padding extends Widget {
  /// The widget below this widget in the tree.
  final Widget child;

  /// The amount of space by which to inset the child.
  final EdgeInsets padding;

  /// Creates a [Padding] widget that insets its child.
  const Padding({required this.child, required this.padding});

  @override
  Element createElement() => PaddingElement(this);

  @override
  void render(Buffer buffer, Rect area) {
    final childWidth = area.width - padding.left - padding.right;
    final childHeight = area.height - padding.top - padding.bottom;

    if (childWidth <= 0 || childHeight <= 0) return;

    final childArea = Rect(
      area.x + padding.left,
      area.y + padding.top,
      childWidth,
      childHeight,
    );

    final childViewport = Viewport(buffer, childArea);
    child.render(childViewport, Rect(0, 0, childWidth, childHeight));
  }
}

/// An element that represents a [Padding] widget.
class PaddingElement extends Element {
  /// The instantiated element corresponding to the child widget.
  Element? childElement;

  /// Creates an element for the [Padding] widget.
  PaddingElement(Padding super.widget);

  @override
  void visitChildren(void Function(Element child) visitor) {
    if (childElement != null) visitor(childElement!);
  }

  @override
  void render(Buffer buffer, Rect area) {
    final paddingWidget = widget as Padding;
    final childWidth =
        area.width - paddingWidget.padding.left - paddingWidget.padding.right;
    final childHeight =
        area.height - paddingWidget.padding.top - paddingWidget.padding.bottom;

    if (childWidth <= 0 || childHeight <= 0) return;

    final childArea = Rect(
      area.x + paddingWidget.padding.left,
      area.y + paddingWidget.padding.top,
      childWidth,
      childHeight,
    );

    if (childElement != null &&
        childElement!.widget.runtimeType == paddingWidget.child.runtimeType) {
      childElement!.update(paddingWidget.child);
    } else {
      childElement = paddingWidget.child.createElement();
      childElement!.mount(this);
    }

    final childViewport = Viewport(buffer, childArea);
    childElement!.render(childViewport, Rect(0, 0, childWidth, childHeight));
  }
}
