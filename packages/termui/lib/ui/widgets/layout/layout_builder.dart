import 'package:termui/termui.dart';

/// Signature for the builder callback used by [LayoutBuilder].
typedef LayoutWidgetBuilder =
    Widget Function(BuildContext context, BoxConstraints constraints);

/// A widget that builds a subtree based on the incoming layout constraints.
class LayoutBuilder extends Widget {
  /// The builder function that constructs the child widget.
  final LayoutWidgetBuilder builder;

  /// Creates a [LayoutBuilder].
  const LayoutBuilder({super.key, required this.builder});

  @override
  Element createElement() => LayoutBuilderElement(this);
}

/// The element that manages the lifecycle of a [LayoutBuilder].
class LayoutBuilderElement extends Element {
  Element? _child;

  /// Creates a layout builder element.
  LayoutBuilderElement(LayoutBuilder super.widget);

  @override
  void visitChildren(void Function(Element child) visitor) {
    if (_child != null) {
      visitor(_child!);
    }
  }

  @override
  void unmount() {
    _child?.unmount();
    super.unmount();
  }

  @override
  void update(Widget newWidget) {
    super.update(newWidget);
    rebuild();
  }

  @override
  void rebuild() {
    if (constraints != null) {
      final builderWidget = widget as LayoutBuilder;
      final childWidget = builderWidget.builder(this, constraints!);
      if (_child != null &&
          _child!.widget.runtimeType == childWidget.runtimeType) {
        _child!.update(childWidget);
      } else {
        _child?.unmount();
        _child = childWidget.createElement();
        _child!.mount(this);
      }
      _child!.layout(constraints!);
    }
  }

  @override
  Size performLayout(BoxConstraints constraints) {
    final builderWidget = widget as LayoutBuilder;

    // 1. Build Phase: Invoke builder callback using incoming constraints
    final childWidget = builderWidget.builder(this, constraints);

    // 2. Reconciliation Phase: Mount or update child element
    if (_child != null &&
        _child!.widget.runtimeType == childWidget.runtimeType) {
      _child!.update(childWidget);
    } else {
      _child?.unmount();
      _child = childWidget.createElement();
      _child!.mount(this);
    }

    // 3. Child Layout Phase: Run layout recursively on the child element tree
    final childSize = _child!.layout(constraints);
    return childSize;
  }

  @override
  void performPaint(Buffer buffer, Offset offset) {
    _child?.paint(buffer, offset);
  }
}
