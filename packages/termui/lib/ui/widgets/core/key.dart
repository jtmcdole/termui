import 'package:termui/termui.dart';

/// Undocumented public member.
abstract class Key {
  /// Initializes a key.
  const Key();
}

/// A key that is unique across the entire element tree.
/// Global keys allow widgets to be uniquely identified and retrieved from
/// the registry.
class GlobalKey<T extends State<StatefulWidget>> extends Key {
  /// Undocumented public member.
  static final Map<GlobalKey, Element> registry = {};

  /// Initializes a global key.
  const GlobalKey() : super();

  /// Retrieves the current [State] associated with the widget registered with this key.
  T? get currentState {
    final element = registry[this];
    if (element is StatefulElement) {
      return element.state as T?;
    }
    return null;
  }

  /// Retrieves the [BuildContext] / [Element] registered with this key.
  BuildContext? get currentContext => registry[this];

  /// Retrieves the [Widget] configuration registered with this key.
  Widget? get currentWidget => registry[this]?.widget;
}

/// A concrete subclass of [Key] for matching widgets by a value.
class ValueKey<T> extends Key {
  /// The value associated with this key.
  final T value;

  /// Creates a [ValueKey] wrapping the given [value].
  const ValueKey(this.value);

  @override
  bool operator ==(Object other) {
    if (other.runtimeType != runtimeType) return false;
    return other is ValueKey<T> && other.value == value;
  }

  @override
  int get hashCode => Object.hash(runtimeType, value);

  @override
  String toString() => 'ValueKey($value)';
}

/// Abstract base class for all renderable widgets.
