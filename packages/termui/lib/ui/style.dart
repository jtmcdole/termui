import 'color.dart';

/// Visual style variants for underlined terminal text (SGR `4:x` and `21`).
enum UnderlineStyle {
  /// No underline (`4:0` or `24`).
  none(0),

  /// Standard single underline (`4` or `4:1`).
  single(1 << Modifier.underlineStyleShift),

  /// Double underline (`21` or `4:2`).
  doubleLine(2 << Modifier.underlineStyleShift),

  /// Curly / wavy undercurl (`4:3`).
  curly(3 << Modifier.underlineStyleShift),

  /// Dotted underline (`4:4`).
  dotted(4 << Modifier.underlineStyleShift),

  /// Dashed underline (`4:5`).
  dashed(5 << Modifier.underlineStyleShift);

  /// Pre-shifted modifier bitfield for constant initialization.
  final int bitMask;

  const UnderlineStyle(this.bitMask);
}

/// Text modifiers represented as a bitmask for performance.
abstract class Modifier {
  /// No modifiers applied.
  static const int none = 0;

  /// Bold text modifier (SGR 1).
  static const int bold = 1 << 0;

  /// Dim or faint text modifier (SGR 2).
  static const int dim = 1 << 1;

  /// Italic text modifier (SGR 3).
  static const int italic = 1 << 2;

  /// Underlined text modifier (SGR 4).
  static const int underline = 1 << 3;

  /// Blinking text modifier (SGR 5).
  static const int blink = 1 << 4;

  /// Reversed foreground and background modifier (SGR 7).
  static const int reverse = 1 << 5;

  /// Hidden text modifier (SGR 8).
  static const int hidden = 1 << 6;

  /// Crossed-out or strikethrough text modifier (SGR 9).
  static const int crossedOut = 1 << 7;

  /// Transparency modifier for layer compositing.
  static const int transparent = 1 << 8;

  /// Overlined text modifier (SGR 53).
  static const int overline = 1 << 9;

  /// Bit shift for packing [UnderlineStyle] into a modifier mask.
  static const int underlineStyleShift = 10;

  /// Bitmask covering the 3-bit [UnderlineStyle] field (`bits 10..12`).
  static const int underlineStyleMask = 0x7 << underlineStyleShift;

  /// Single underline modifier (`SGR 4` / `4:1`).
  static const int underlineSingle = underline | (1 << underlineStyleShift);

  /// Double underline modifier (`SGR 21` / `4:2`).
  static const int underlineDouble = underline | (2 << underlineStyleShift);

  /// Curly / wavy undercurl modifier (`SGR 4:3`).
  static const int underlineCurly = underline | (3 << underlineStyleShift);

  /// Dotted underline modifier (`SGR 4:4`).
  static const int underlineDotted = underline | (4 << underlineStyleShift);

  /// Dashed underline modifier (`SGR 4:5`).
  static const int underlineDashed = underline | (5 << underlineStyleShift);

  /// Returns true if [modifier] is active in [mask].
  static bool has(int mask, int modifier) => (mask & modifier) != 0;

  /// Encodes [style] into [mask], setting or clearing [underline] accordingly.
  static int withUnderlineStyle(int mask, UnderlineStyle style) {
    if (style == UnderlineStyle.none) {
      return mask & ~(underline | underlineStyleMask);
    }
    return (mask & ~underlineStyleMask) | underline | style.bitMask;
  }

  /// Extracts the active [UnderlineStyle] from [mask].
  static UnderlineStyle getUnderlineStyle(int mask) {
    if (!has(mask, underline)) return UnderlineStyle.none;
    final raw = (mask & underlineStyleMask) >> underlineStyleShift;
    if (raw <= 0 || raw >= UnderlineStyle.values.length) {
      return UnderlineStyle.single;
    }
    return UnderlineStyle.values[raw];
  }
}

/// A class representing style attributes for terminal output.
class Style {
  /// The foreground color of the text.
  final Color? foreground;

  /// The background color of the cell.
  final Color? background;

  /// Optional SGR 58 custom underline color. When null, the foreground color is used.
  final Color? underlineColor;

  /// A bitmask of style modifiers applied to the cell.
  final int modifiers;

  /// Creates a style with the specified colors, modifiers, and optional [underlineStyle].
  const Style({
    this.foreground,
    this.background,
    this.underlineColor,
    int modifiers = Modifier.none,
    UnderlineStyle? underlineStyle,
  }) : modifiers = underlineStyle == null
           ? modifiers
           : (underlineStyle == UnderlineStyle.none
                 ? (modifiers &
                       ~(Modifier.underline | Modifier.underlineStyleMask))
                 : ((modifiers & ~Modifier.underlineStyleMask) |
                       (underlineStyle == UnderlineStyle.single
                           ? Modifier.underlineSingle
                           : underlineStyle == UnderlineStyle.doubleLine
                           ? Modifier.underlineDouble
                           : underlineStyle == UnderlineStyle.curly
                           ? Modifier.underlineCurly
                           : underlineStyle == UnderlineStyle.dotted
                           ? Modifier.underlineDotted
                           : Modifier.underlineDashed)));

  /// The active [UnderlineStyle] decoded from [modifiers].
  UnderlineStyle get underlineStyle => Modifier.getUnderlineStyle(modifiers);

  /// The default opaque style with no colors or modifiers.
  static const Style empty = Style();

  /// A special transparent style.
  static const Style transparent = Style(modifiers: Modifier.transparent);

  /// Merges another style onto this one.
  ///
  /// Attributes in [other] take precedence if they are not null or default.
  Style merge(Style other) {
    var nextModifiers = modifiers | other.modifiers;
    if ((other.modifiers & Modifier.underlineStyleMask) != 0) {
      nextModifiers =
          (nextModifiers & ~Modifier.underlineStyleMask) |
          (other.modifiers & Modifier.underlineStyleMask);
    }
    // Clear transparent bit if merging with a style that is not transparent.
    if (!Modifier.has(other.modifiers, Modifier.transparent)) {
      nextModifiers &= ~Modifier.transparent;
    }
    return Style(
      foreground: other.foreground ?? foreground,
      background: other.background ?? background,
      underlineColor: other.underlineColor ?? underlineColor,
      modifiers: nextModifiers,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is Style &&
        other.foreground == foreground &&
        other.background == background &&
        other.underlineColor == underlineColor &&
        other.modifiers == modifiers;
  }

  @override
  int get hashCode =>
      Object.hash(foreground, background, underlineColor, modifiers);

  @override
  String toString() {
    if (underlineColor != null) {
      return 'Style(fg: $foreground, bg: $background, ul: $underlineColor, mod: $modifiers)';
    }
    return 'Style(fg: $foreground, bg: $background, mod: $modifiers)';
  }
}
