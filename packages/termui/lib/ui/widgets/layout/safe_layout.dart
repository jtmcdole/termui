import 'package:termui/termui.dart';

/// A layout widget that checks constraints and renders a fallback message
/// (or custom fallback widget) if the terminal space is below the minimum required dimensions.
class SafeLayout extends Widget {
  /// The child widget to display when layout constraints are met.
  final Widget child;

  /// The minimum width required for the child widget.
  final int minWidth;

  /// The minimum height required for the child widget.
  final int minHeight;

  /// Optional custom fallback widget to display when constraints are violated.
  /// If not provided, defaults to a centered, red, bold "Screen too small!" text.
  final Widget? fallback;

  /// Creates a [SafeLayout] widget.
  const SafeLayout({
    super.key,
    required this.child,
    this.minWidth = 50,
    this.minHeight = 12,
    this.fallback,
  });

  @override
  Element createElement() => SafeLayoutElement(this);

  @override
  int getIntrinsicHeight(int width) => child.getIntrinsicHeight(width);
}

/// The element managing the lifecycle, constraints, and painting of [SafeLayout].
class SafeLayoutElement extends Element {
  /// Element for the fallback widget.
  Element? fallbackElement;

  /// Element for the main child widget.
  Element? childElement;

  /// Whether the constraints are currently violated, displaying the fallback widget.
  bool useFallback = false;

  /// Creates a [SafeLayoutElement].
  SafeLayoutElement(SafeLayout super.widget);

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
    final sl = widget as SafeLayout;
    final fallbackWidget =
        sl.fallback ??
        Center(
          child: Text(
            'Screen too small!',
            style: const Style(
              foreground: Colors.red,
              modifiers: Modifier.bold,
            ),
          ),
        );

    if (fallbackElement != null &&
        fallbackElement!.widget.runtimeType == fallbackWidget.runtimeType) {
      fallbackElement!.update(fallbackWidget);
    } else {
      fallbackElement?.unmount();
      fallbackElement = fallbackWidget.createElement();
      fallbackElement!.mount(this);
    }

    if (childElement != null &&
        childElement!.widget.runtimeType == sl.child.runtimeType) {
      childElement!.update(sl.child);
    } else {
      childElement?.unmount();
      childElement = sl.child.createElement();
      childElement!.mount(this);
    }
  }

  @override
  void visitChildren(void Function(Element child) visitor) {
    if (useFallback) {
      if (fallbackElement != null) visitor(fallbackElement!);
    } else {
      if (childElement != null) visitor(childElement!);
    }
  }

  @override
  Size performLayout(BoxConstraints constraints) {
    final sl = widget as SafeLayout;
    final w = constraints.maxWidth == BoxConstraints.infinity
        ? 0
        : constraints.maxWidth;
    final h = constraints.maxHeight == BoxConstraints.infinity
        ? 0
        : constraints.maxHeight;

    if (w < sl.minWidth || h < sl.minHeight) {
      useFallback = true;
      if (fallbackElement != null) {
        fallbackElement!.layout(constraints);
      }
    } else {
      useFallback = false;
      if (childElement != null) {
        childElement!.layout(constraints);
      }
    }
    return constraints.constrain(Size(w, h));
  }

  @override
  void unmount() {
    childElement?.unmount();
    fallbackElement?.unmount();
    super.unmount();
  }

  @override
  void performPaint(Buffer buffer, Offset offset) {
    if (useFallback) {
      fallbackElement?.paint(buffer, offset);
    } else {
      childElement?.paint(buffer, offset);
    }
  }
}
