import 'dart:async';
import 'package:termui/termui.dart';

/// Undocumented public member.
abstract interface class BuildContext {
  /// The widget associated with this context.
  Widget get widget;

  /// Obtains the nearest inherited widget of the given type [T].
  T? dependOnInheritedWidgetOfExactType<T extends InheritedWidget>();

  /// Accesses the active build context from the current Zone.
  static BuildContext? get current =>
      Zone.current[#buildContext] as BuildContext?;
}

/// A unique identifier for [Widget] configurations.
