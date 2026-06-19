import 'package:termui/termui.dart';

/// Undocumented public member.
class Align extends Widget {
  /// How to align the child.
  final Alignment alignment;

  /// The child widget.
  final Widget child;

  /// If non-null, sets its width to the child's width multiplied by this factor.
  final double? widthFactor;

  /// If non-null, sets its height to the child's height multiplied by this factor.
  final double? heightFactor;

  /// Creates an alignment widget.
  const Align({
    this.alignment = Alignment.center,
    this.widthFactor,
    this.heightFactor,
    required this.child,
  });

  @override
  Element createElement() => AlignElement(this);

  @override
  int getIntrinsicHeight(int width) {
    if (heightFactor != null) {
      return (child.getIntrinsicHeight(width) * heightFactor!).round();
    }
    return child.getIntrinsicHeight(width);
  }
}

/// An element that manages an [Align] widget.
class AlignElement extends Element {
  /// The child element.
  Element? childElement;

  /// Creates an align element for an [Align] widget.
  AlignElement(Align super.widget);

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
    final align = widget as Align;
    if (childElement != null &&
        childElement!.widget.runtimeType == align.child.runtimeType) {
      childElement!.update(align.child);
    } else {
      childElement?.unmount();
      childElement = align.child.createElement();
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
    final align = widget as Align;
    if (childElement != null) {
      final childConstraints = BoxConstraints(
        minWidth: 0,
        maxWidth: constraints.maxWidth,
        minHeight: 0,
        maxHeight: constraints.maxHeight,
      );
      final childSize = childElement!.layout(childConstraints);

      final parentWidth = align.widthFactor != null
          ? (childSize.width * align.widthFactor!).round().clamp(
              constraints.minWidth,
              constraints.maxWidth,
            )
          : (constraints.maxWidth == BoxConstraints.infinity
                ? childSize.width
                : constraints.maxWidth);
      final parentHeight = align.heightFactor != null
          ? (childSize.height * align.heightFactor!).round().clamp(
              constraints.minHeight,
              constraints.maxHeight,
            )
          : (constraints.maxHeight == BoxConstraints.infinity
                ? childSize.height
                : constraints.maxHeight);

      final childWidth = childSize.width.clamp(0, parentWidth);
      final childHeight = childSize.height.clamp(0, parentHeight);

      final double remainingWidth = (parentWidth - childWidth).toDouble();
      final int offsetX = (remainingWidth * (align.alignment.x + 1.0) / 2.0)
          .round();

      final double remainingHeight = (parentHeight - childHeight).toDouble();
      final int offsetY = (remainingHeight * (align.alignment.y + 1.0) / 2.0)
          .round();

      childElement!.relativeOffset = Offset(offsetX, offsetY);
      return Size(parentWidth, parentHeight);
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

/// A widget that centers its child within itself.
class Center extends Align {
  /// Creates a widget that centers its child.
  const Center({super.widthFactor, super.heightFactor, required super.child})
    : super(alignment: Alignment.center);
}

/// A bridge widget that maintains a persistent [Element] tree for its child.
///
/// Use this to embed reactive widgets (like [StatefulWidget]s or [InheritedWidget]s)
/// inside immediate-mode rendering loops that reconstruct the widget tree on every frame.
