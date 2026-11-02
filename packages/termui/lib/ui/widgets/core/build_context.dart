import 'dart:async';
import 'package:termui/termui.dart';

/// A handle to the location of a [Widget] in the element tree.
abstract interface class BuildContext {
  /// The widget associated with this context.
  Widget get widget;

  /// Obtains the nearest inherited widget of the given type [T].
  T? dependOnInheritedWidgetOfExactType<T extends InheritedWidget>();

  /// Accesses the active build context from the current Zone.
  static BuildContext? get current =>
      Zone.current[#buildContext] as BuildContext?;
}
