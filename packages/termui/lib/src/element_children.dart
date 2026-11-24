import 'package:termui/ui/widgets/core/element.dart';
import 'package:termui/ui/widgets/core/widget.dart';

/// Reconciles [currentChildren] against [newWidgets] for [parent], updating
/// compatible elements in place and mounting/unmounting the rest.
List<Element> reconcileChildElements(
  Element parent,
  List<Element> currentChildren,
  List<Widget> newWidgets,
) {
  final newElements = <Element>[];
  for (var i = 0; i < newWidgets.length; i++) {
    final childWidget = newWidgets[i];
    if (i < currentChildren.length &&
        Widget.canUpdate(currentChildren[i].widget, childWidget)) {
      currentChildren[i].update(childWidget);
      newElements.add(currentChildren[i]);
    } else {
      if (i < currentChildren.length) {
        currentChildren[i].unmount();
      }
      final newEl = childWidget.createElement();
      newEl.mount(parent);
      newElements.add(newEl);
    }
  }
  for (var i = newWidgets.length; i < currentChildren.length; i++) {
    currentChildren[i].unmount();
  }
  return newElements;
}
