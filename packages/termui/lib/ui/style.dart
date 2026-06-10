import 'color.dart';

/// Text modifiers represented as a bitmask for performance.
abstract class Modifier {
  /// No modifiers applied.
  static const int none = 0;

  /// Bold text modifier.
  static const int bold = 1 << 0;

  /// Dim or faint text modifier.
  static const int dim = 1 << 1;

  /// Italic text modifier.
  static const int italic = 1 << 2;

  /// Underlined text modifier.
  static const int underline = 1 << 3;

  /// Blinking text modifier.
  static const int blink = 1 << 4;

  /// Reversed foreground and background modifier.
  static const int reverse = 1 << 5;

  /// Hidden text modifier.
  static const int hidden = 1 << 6;

  /// Crossed-out or strikethrough text modifier.
  static const int crossedOut = 1 << 7;

  /// Transparency modifier for layer compositing.
  static const int transparent = 1 << 8;

  /// Returns true if [modifier] is active in [mask].
  static bool has(int mask, int modifier) => (mask & modifier) != 0;
}

/// A class representing style attributes for terminal output.
class Style {
  /// The foreground color of the text.
  final Color? foreground;

  /// The background color of the cell.
  final Color? background;

  /// A bitmask of style modifiers applied to the cell.
  final int modifiers;

  /// Creates a style with the specified colors and modifiers.
  const Style({
    this.foreground,
    this.background,
    this.modifiers = Modifier.none,
  });

  /// The default opaque style with no colors or modifiers.
  static const Style empty = Style();

  /// A special transparent style.
  static const Style transparent = Style(modifiers: Modifier.transparent);

  /// Merges another style onto this one.
  ///
  /// Attributes in [other] take precedence if they are not null or default.
  Style merge(Style other) {
    var nextModifiers = modifiers | other.modifiers;
    // Clear transparent bit if merging with a style that is not transparent.
    if (!Modifier.has(other.modifiers, Modifier.transparent)) {
      nextModifiers &= ~Modifier.transparent;
    }
    return Style(
      foreground: other.foreground ?? foreground,
      background: other.background ?? background,
      modifiers: nextModifiers,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is Style &&
        other.foreground == foreground &&
        other.background == background &&
        other.modifiers == modifiers;
  }

  @override
  int get hashCode => Object.hash(foreground, background, modifiers);

  @override
  String toString() {
    return 'Style(fg: $foreground, bg: $background, mod: $modifiers)';
  }
}
