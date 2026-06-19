import 'package:termui/termui.dart';

/// A widget that wraps another widget and inserts padding around it.
///
/// Example usage:
/// ```dart
/// final paddedText = Padding(
///   padding: EdgeInsets.all(2),
///   child: Text('Padded Content'),
/// );
/// ```
class Padding extends Widget {
  /// The widget below this widget in the tree.
  final Widget child;

  /// The amount of space by which to inset the child.
  final EdgeInsets padding;

  /// Creates a [Padding] widget that insets its child.
  const Padding({super.key, required this.child, required this.padding});

  @override
  Element createElement() => PaddingElement(this);

  @override
  int getIntrinsicHeight(int width) {
    final childWidth = width - padding.left - padding.right;
    final w = childWidth < 0 ? 0 : childWidth;
    return child.getIntrinsicHeight(w) + padding.top + padding.bottom;
  }
}

/// An element that represents a [Padding] widget.
class PaddingElement extends Element {
  /// The instantiated element corresponding to the child widget.
  Element? childElement;

  /// Creates an element for the [Padding] widget.
  PaddingElement(Padding super.widget);

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
    final paddingWidget = widget as Padding;
    if (childElement != null &&
        childElement!.widget.runtimeType == paddingWidget.child.runtimeType) {
      childElement!.update(paddingWidget.child);
    } else {
      childElement?.unmount();
      childElement = paddingWidget.child.createElement();
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
    final paddingWidget = widget as Padding;
    final padding = paddingWidget.padding;

    final doubleWidth = padding.left + padding.right;
    final doubleHeight = padding.top + padding.bottom;

    final childMinWidth = constraints.minWidth - doubleWidth < 0
        ? 0
        : constraints.minWidth - doubleWidth;
    final childMaxWidth = constraints.maxWidth == BoxConstraints.infinity
        ? BoxConstraints.infinity
        : (constraints.maxWidth - doubleWidth < 0
              ? 0
              : constraints.maxWidth - doubleWidth);
    final childMinHeight = constraints.minHeight - doubleHeight < 0
        ? 0
        : constraints.minHeight - doubleHeight;
    final childMaxHeight = constraints.maxHeight == BoxConstraints.infinity
        ? BoxConstraints.infinity
        : (constraints.maxHeight - doubleHeight < 0
              ? 0
              : constraints.maxHeight - doubleHeight);

    final childConstraints = BoxConstraints(
      minWidth: childMinWidth,
      maxWidth: childMaxWidth,
      minHeight: childMinHeight,
      maxHeight: childMaxHeight,
    );

    if (childElement != null) {
      final childSize = childElement!.layout(childConstraints);
      childElement!.relativeOffset = Offset(padding.left, padding.top);
      return Size(
        childSize.width + doubleWidth,
        childSize.height + doubleHeight,
      );
    }

    return Size(doubleWidth, doubleHeight);
  }

  @override
  void performPaint(Buffer buffer, Offset offset) {
    final paddingWidget = widget as Padding;
    final padding = paddingWidget.padding;
    final doubleWidth = padding.left + padding.right;
    final doubleHeight = padding.top + padding.bottom;
    if (size.width > doubleWidth &&
        size.height > doubleHeight &&
        childElement != null) {
      childElement!.paint(buffer, offset + childElement!.relativeOffset);
    }
  }

  @override
  void visitChildren(void Function(Element child) visitor) {
    if (childElement != null) visitor(childElement!);
  }
}
