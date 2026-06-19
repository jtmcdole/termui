import 'package:termui/termui.dart';

/// An abstract element that manages a widget with at most one child.
abstract class SingleChildElement extends Element {
  /// The child element.
  Element? childElement;

  /// Creates a single child element.
  SingleChildElement(super.widget);

  /// Subclasses must provide the child widget from their specific [Widget].
  Widget? get childWidget;

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
    final cw = childWidget;
    if (cw != null) {
      if (childElement != null && Widget.canUpdate(childElement!.widget, cw)) {
        childElement!.update(cw);
      } else {
        childElement?.unmount();
        childElement = cw.createElement();
        childElement!.mount(this);
      }
    } else {
      childElement?.unmount();
      childElement = null;
    }
  }

  @override
  void unmount() {
    childElement?.unmount();
    super.unmount();
  }

  @override
  void visitChildren(void Function(Element element) visitor) {
    if (childElement != null) visitor(childElement!);
  }
}
