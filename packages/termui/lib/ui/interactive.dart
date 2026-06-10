import 'dart:math';

/// Represents an interactive UI element.
abstract class Interactive {
  /// Called when the element becomes active.
  void onActive();

  /// Called when the element is triggered (e.g., Enter key).
  void onEnter();

  /// Called when the element becomes inactive.
  void onInactive();

  /// Creates a new interactive element.
  Interactive();
}

/// A specific item within a menu.
class MenuItem extends Interactive {
  /// The label or text of the menu item.
  String item;

  /// The local position of this menu item within the menu.
  Point<int> position;

  final Function()? _onEnter;

  /// Creates a new [MenuItem].
  MenuItem({required this.item, required this.position, Function()? onActivate})
    : _onEnter = onActivate;

  @override
  void onActive() {}

  @override
  void onEnter() {
    _onEnter?.call();
  }

  @override
  void onInactive() {}
}
