/// Base class for all input events.
abstract class InputEvent {
  /// Creates an [InputEvent].
  const InputEvent();

  /// The key string representation.
  String get key => '';

  /// Active modifiers.
  Set<Modifier> get modifiers => const <Modifier>{};
}

/// Keyboard modifiers.
enum Modifier {
  /// Shift key.
  shift,

  /// Alt key.
  alt,

  /// Control key.
  control,

  /// Meta key.
  meta,
}

/// Helper function to compare two sets for equality without package:collection.
bool _setEquals<T>(Set<T> a, Set<T> b) {
  if (a.length != b.length) return false;
  return a.containsAll(b);
}

/// Types of keys that can be pressed.
enum KeyType {
  /// Regular character.
  character,

  /// Backspace key.
  backspace,

  /// Enter key.
  enter,

  /// Escape key.
  escape,

  /// Tab key.
  tab,

  /// Up arrow key.
  up,

  /// Down arrow key.
  down,

  /// Left arrow key.
  left,

  /// Right arrow key.
  right,

  /// Home key.
  home,

  /// End key.
  end,

  /// Page Up key.
  pageUp,

  /// Page Down key.
  pageDown,

  /// Delete key.
  delete,

  /// Insert key.
  insert,

  /// F1 key.
  f1,

  /// F2 key.
  f2,

  /// F3 key.
  f3,

  /// F4 key.
  f4,

  /// F5 key.
  f5,

  /// F6 key.
  f6,

  /// F7 key.
  f7,

  /// F8 key.
  f8,

  /// F9 key.
  f9,

  /// F10 key.
  f10,

  /// F11 key.
  f11,

  /// F12 key.
  f12,
}

/// A keyboard event.
class KeyEvent extends InputEvent {
  @override
  final String key;

  /// The type of key.
  final KeyType type;
  @override
  final Set<Modifier> modifiers;

  /// Creates a [KeyEvent].
  const KeyEvent(this.key, this.type, {this.modifiers = const <Modifier>{}});

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is KeyEvent &&
        other.key == key &&
        other.type == type &&
        _setEquals(other.modifiers, modifiers);
  }

  @override
  int get hashCode => Object.hash(key, type, Object.hashAll(modifiers));

  /// Returns a human-readable string combining modifiers and the key,
  /// e.g. "Control+W", "Alt+Shift+Enter", "A".
  String get logicalKey {
    final mods = <String>[];
    if (modifiers.contains(Modifier.control)) mods.add('Control');
    if (modifiers.contains(Modifier.alt)) mods.add('Alt');
    if (modifiers.contains(Modifier.meta)) mods.add('Meta');
    if (modifiers.contains(Modifier.shift)) mods.add('Shift');

    var keyName = key;
    if (type != KeyType.character) {
      final name = type.name;
      keyName = name.isNotEmpty
          ? '${name[0].toUpperCase()}${name.substring(1)}'
          : name;
    } else {
      keyName = keyName.toUpperCase();
    }

    if (mods.isEmpty) return keyName;
    return '${mods.join('+')}+$keyName';
  }

  @override
  String toString() => 'KeyEvent($key, type: $type, modifiers: $modifiers)';
}

/// Mouse buttons.
enum MouseButton {
  /// Left mouse button.
  left,

  /// Middle mouse button.
  middle,

  /// Right mouse button.
  right,

  /// Mouse wheel scroll up.
  wheelUp,

  /// Mouse wheel scroll down.
  wheelDown,

  /// No button pressed.
  none,
}

/// Mouse event type.
enum MouseEventType {
  /// Button press.
  press,

  /// Button release.
  release,

  /// Mouse drag.
  drag,

  /// Mouse move without buttons pressed.
  move,
}

/// A mouse event.
class MouseEvent extends InputEvent {
  /// Whether a button is actively pressed or dragging.
  bool get pressed =>
      type == MouseEventType.press || type == MouseEventType.drag;

  /// X coordinate (1-indexed terminal coordinate).
  final int x;

  /// Y coordinate (1-indexed terminal coordinate).
  final int y;

  /// Optional global X coordinate (1-indexed terminal coordinate).
  final int? globalX;

  /// Optional global Y coordinate (1-indexed terminal coordinate).
  final int? globalY;

  /// Which button was pressed.
  final MouseButton button;

  /// The type of mouse event.
  final MouseEventType type;

  @override
  final Set<Modifier> modifiers;

  /// Creates a [MouseEvent].
  const MouseEvent({
    required this.x,
    required this.y,
    this.globalX,
    this.globalY,
    required this.button,
    required this.type,
    this.modifiers = const <Modifier>{},
  });

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is MouseEvent &&
        other.x == x &&
        other.y == y &&
        other.globalX == globalX &&
        other.globalY == globalY &&
        other.button == button &&
        other.type == type &&
        _setEquals(other.modifiers, modifiers);
  }

  @override
  int get hashCode => Object.hash(
    x,
    y,
    globalX,
    globalY,
    button,
    type,
    Object.hashAll(modifiers),
  );

  @override
  String toString() {
    return 'MouseEvent(x: $x, y: $y, globalX: $globalX, globalY: $globalY, button: $button, type: $type, modifiers: $modifiers)';
  }
}

/// A bracketed paste event.
class PasteEvent extends InputEvent {
  /// The pasted text.
  final String text;

  /// Creates a [PasteEvent].
  const PasteEvent(this.text);
  @override
  String get key => text;

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is PasteEvent && other.text == text;

  @override
  int get hashCode => text.hashCode;

  @override
  String toString() => 'PasteEvent($text)';
}

/// Event fired when terminal receives focus.
class FocusInEvent extends InputEvent {
  /// Creates a [FocusInEvent].
  const FocusInEvent();

  @override
  bool operator ==(Object other) => other is FocusInEvent;

  @override
  int get hashCode => 0;

  @override
  String toString() => 'FocusInEvent';
}

/// Event fired when terminal loses focus.
class FocusOutEvent extends InputEvent {
  /// Creates a [FocusOutEvent].
  const FocusOutEvent();

  @override
  bool operator ==(Object other) => other is FocusOutEvent;

  @override
  int get hashCode => 1;

  @override
  String toString() => 'FocusOutEvent';
}

/// Event representing cursor position report.
class CursorPositionReportEvent extends InputEvent {
  /// X coordinate.
  final int x;

  /// Y coordinate.
  final int y;

  /// Creates a [CursorPositionReportEvent].
  const CursorPositionReportEvent(this.x, this.y);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CursorPositionReportEvent && other.x == x && other.y == y;

  @override
  int get hashCode => Object.hash(x, y);

  @override
  String toString() => 'CursorPositionReportEvent(x: $x, y: $y)';
}
