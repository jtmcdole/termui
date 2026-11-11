import 'dart:math' as math;

import 'color.dart';

/// Overall luminance polarity of a terminal color theme.
enum TerminalBrightness {
  /// Dark-background terminal palette.
  dark,

  /// Light-background terminal palette.
  light,
}

/// User-defined hex color overrides applied on top of a [TerminalColorTheme].
final class CustomPaletteOverrides {
  /// Empty override set leaving the underlying preset untouched.
  static const CustomPaletteOverrides empty = CustomPaletteOverrides();

  /// Optional override for the default foreground color.
  final Color? foreground;

  /// Optional override for the default background color.
  final Color? background;

  /// Optional override for the cursor fill color.
  final Color? cursorColor;

  /// Optional override for the text color drawn inside a block cursor.
  final Color? cursorTextColor;

  /// Optional override for selection highlight background.
  final Color? selectionBackground;

  /// Optional override for selection highlight text color.
  final Color? selectionForeground;

  /// Optional overrides for ANSI palette slots `0..15`.
  final Map<int, Color> ansiOverrides;

  /// Creates an immutable set of palette overrides.
  const CustomPaletteOverrides({
    this.foreground,
    this.background,
    this.cursorColor,
    this.cursorTextColor,
    this.selectionBackground,
    this.selectionForeground,
    this.ansiOverrides = const {},
  });

  /// Whether no semantic or ANSI slot overrides are set.
  bool get isEmpty =>
      foreground == null &&
      background == null &&
      cursorColor == null &&
      cursorTextColor == null &&
      selectionBackground == null &&
      selectionForeground == null &&
      ansiOverrides.isEmpty;

  /// Returns a copy with [ansiIndex] (`0..15`) set to [color] (or cleared when `null`).
  CustomPaletteOverrides withAnsiSlot(int ansiIndex, Color? color) {
    if (ansiIndex < 0 || ansiIndex > 15) return this;
    final nextMap = <int, Color>{...ansiOverrides};
    if (color == null) {
      nextMap.remove(ansiIndex);
    } else {
      nextMap[ansiIndex] = color;
    }
    return CustomPaletteOverrides(
      foreground: foreground,
      background: background,
      cursorColor: cursorColor,
      cursorTextColor: cursorTextColor,
      selectionBackground: selectionBackground,
      selectionForeground: selectionForeground,
      ansiOverrides: Map<int, Color>.unmodifiable(nextMap),
    );
  }

  /// Returns a copy with one named semantic override updated (`clear*` clears to `null`).
  CustomPaletteOverrides copyWith({
    Color? foreground,
    bool clearForeground = false,
    Color? background,
    bool clearBackground = false,
    Color? cursorColor,
    bool clearCursorColor = false,
    Color? cursorTextColor,
    bool clearCursorTextColor = false,
    Color? selectionBackground,
    bool clearSelectionBackground = false,
    Color? selectionForeground,
    bool clearSelectionForeground = false,
    Map<int, Color>? ansiOverrides,
  }) => CustomPaletteOverrides(
    foreground: clearForeground ? null : (foreground ?? this.foreground),
    background: clearBackground ? null : (background ?? this.background),
    cursorColor: clearCursorColor ? null : (cursorColor ?? this.cursorColor),
    cursorTextColor: clearCursorTextColor
        ? null
        : (cursorTextColor ?? this.cursorTextColor),
    selectionBackground: clearSelectionBackground
        ? null
        : (selectionBackground ?? this.selectionBackground),
    selectionForeground: clearSelectionForeground
        ? null
        : (selectionForeground ?? this.selectionForeground),
    ansiOverrides: ansiOverrides == null
        ? this.ansiOverrides
        : Map<int, Color>.unmodifiable(ansiOverrides),
  );

  /// Serializes active overrides to `#RRGGBB` hex strings.
  Map<String, Object?> toJson() => {
    if (foreground != null) 'foreground': formatHexRgb(foreground!),
    if (background != null) 'background': formatHexRgb(background!),
    if (cursorColor != null) 'cursorColor': formatHexRgb(cursorColor!),
    if (cursorTextColor != null)
      'cursorTextColor': formatHexRgb(cursorTextColor!),
    if (selectionBackground != null)
      'selectionBackground': formatHexRgb(selectionBackground!),
    if (selectionForeground != null)
      'selectionForeground': formatHexRgb(selectionForeground!),
    if (ansiOverrides.isNotEmpty)
      'ansi': {
        for (final entry in ansiOverrides.entries)
          if (entry.key >= 0 && entry.key <= 15)
            '${entry.key}': formatHexRgb(entry.value),
      },
  };

  /// Parses overrides from a JSON map, ignoring invalid entries safely.
  static CustomPaletteOverrides fromJson(Object? raw) {
    if (raw is! Map<Object?, Object?>) return empty;
    return CustomPaletteOverrides(
      foreground: _parseColorField(raw['foreground']),
      background: _parseColorField(raw['background']),
      cursorColor: _parseColorField(raw['cursorColor']),
      cursorTextColor: _parseColorField(raw['cursorTextColor']),
      selectionBackground: _parseColorField(raw['selectionBackground']),
      selectionForeground: _parseColorField(raw['selectionForeground']),
      ansiOverrides: _parseAnsiOverridesMap(raw['ansi']),
    );
  }

  static Color? _parseColorField(Object? raw) =>
      raw is String ? parseHexRgb(raw) : null;

  static Map<int, Color> _parseAnsiOverridesMap(Object? raw) {
    if (raw is! Map<Object?, Object?>) return const {};
    final parsed = <int, Color>{};
    for (final entry in raw.entries) {
      final keyStr = entry.key;
      final valStr = entry.value;
      if (keyStr is! String || valStr is! String) continue;
      final slot = int.tryParse(keyStr);
      final color = parseHexRgb(valStr);
      if (slot != null && slot >= 0 && slot <= 15 && color != null) {
        parsed[slot] = color;
      }
    }
    return Map<int, Color>.unmodifiable(parsed);
  }

  static bool _isAsciiHexDigit(int unit) => switch (unit) {
    >= 0x30 && <= 0x39 || >= 0x41 && <= 0x46 || >= 0x61 && <= 0x66 => true,
    _ => false,
  };

  /// Parses `#RRGGBB` or `RRGGBB` hex strings into an opaque [Color].
  static Color? parseHexRgb(String raw) {
    final trimmed = raw.trim();
    final hex = trimmed.startsWith('#') ? trimmed.substring(1) : trimmed;
    if (hex.length != 6) return null;
    for (var i = 0; i < 6; i++) {
      if (!_isAsciiHexDigit(hex.codeUnitAt(i))) return null;
    }
    final rgb = int.tryParse(hex, radix: 16);
    if (rgb == null) return null;
    return Color.argb(0xFF000000 | rgb);
  }

  /// Formats [color] as `#RRGGBB` uppercase hex.
  static String formatHexRgb(Color color) {
    final r = color.r.toRadixString(16).padLeft(2, '0').toUpperCase();
    final g = color.g.toRadixString(16).padLeft(2, '0').toUpperCase();
    final b = color.b.toRadixString(16).padLeft(2, '0').toUpperCase();
    return '#$r$g$b';
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! CustomPaletteOverrides) return false;
    if (foreground != other.foreground ||
        background != other.background ||
        cursorColor != other.cursorColor ||
        cursorTextColor != other.cursorTextColor ||
        selectionBackground != other.selectionBackground ||
        selectionForeground != other.selectionForeground ||
        ansiOverrides.length != other.ansiOverrides.length) {
      return false;
    }
    for (final entry in ansiOverrides.entries) {
      if (other.ansiOverrides[entry.key] != entry.value) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hash(
    foreground,
    background,
    cursorColor,
    cursorTextColor,
    selectionBackground,
    selectionForeground,
    Object.hashAllUnordered([
      for (final entry in ansiOverrides.entries)
        Object.hash(entry.key, entry.value),
    ]),
  );
}

/// Complete terminal color theme pairing default fg/bg, cursor, selection,
/// and the 16-color ANSI palette.
final class TerminalColorTheme {
  /// Stable preset identifier (for example `'termui_dark'`).
  final String id;

  /// Human-readable display name.
  final String name;

  /// Polarity of this theme (`dark` or `light`).
  final TerminalBrightness brightness;

  /// Default text foreground color when cell `fg == 0`.
  final Color foreground;

  /// Default canvas background color when cell `bg == 0`.
  final Color background;

  /// Cursor fill color.
  final Color cursorColor;

  /// Text color rendered inside a solid block cursor.
  final Color cursorTextColor;

  /// Selection highlight background color.
  final Color selectionBackground;

  /// Optional explicit selection foreground color (`null` preserves cell fg).
  final Color? selectionForeground;

  /// 16 ANSI colors (`0..7` normal, `8..15` bright).
  final List<Color> ansi;

  /// Creates an immutable terminal color theme.
  const TerminalColorTheme({
    required this.id,
    required this.name,
    required this.brightness,
    required this.foreground,
    required this.background,
    required this.cursorColor,
    required this.cursorTextColor,
    required this.selectionBackground,
    this.selectionForeground,
    required this.ansi,
  });

  /// Classic VGA 16-color palette on `#000000` / `#FFFFFF`.
  static const TerminalColorTheme legacyVga = TerminalColorTheme(
    id: 'legacy_vga',
    name: 'Legacy VGA',
    brightness: .dark,
    foreground: Color(255, 255, 255),
    background: Color(0, 0, 0),
    cursorColor: Color(255, 255, 255),
    cursorTextColor: Color(0, 0, 0),
    selectionBackground: Color(0x26, 0x4F, 0x78),
    ansi: [
      Color(0x00, 0x00, 0x00),
      Color(0xAA, 0x00, 0x00),
      Color(0x00, 0xAA, 0x00),
      Color(0xAA, 0xAA, 0x00),
      Color(0x00, 0x00, 0xAA),
      Color(0xAA, 0x00, 0xAA),
      Color(0x00, 0xAA, 0xAA),
      Color(0xAA, 0xAA, 0xAA),
      Color(0x55, 0x55, 0x55),
      Color(0xFF, 0x55, 0x55),
      Color(0x55, 0xFF, 0x55),
      Color(0xFF, 0xFF, 0x55),
      Color(0x55, 0x55, 0xFF),
      Color(0xFF, 0x55, 0xFF),
      Color(0x55, 0xFF, 0xFF),
      Color(0xFF, 0xFF, 0xFF),
    ],
  );

  /// Default dark theme with accessible ANSI 4 folder blue (`#5294E2`).
  static const TerminalColorTheme termuiDark = TerminalColorTheme(
    id: 'termui_dark',
    name: 'TermUI Dark',
    brightness: .dark,
    foreground: Color(0xE6, 0xED, 0xF3),
    background: Color(0x14, 0x17, 0x1F),
    cursorColor: Color(0x62, 0xD1, 0x96),
    cursorTextColor: Color(0x14, 0x17, 0x1F),
    selectionBackground: Color(0x26, 0x4F, 0x78),
    ansi: [
      Color(0x1E, 0x22, 0x2A),
      Color(0xE0, 0x6C, 0x75),
      Color(0x62, 0xD1, 0x96),
      Color(0xE5, 0xC0, 0x7B),
      Color(0x52, 0x94, 0xE2),
      Color(0xC6, 0x78, 0xDD),
      Color(0x56, 0xB6, 0xC2),
      Color(0xAB, 0xB2, 0xBF),
      Color(0x5C, 0x63, 0x70),
      Color(0xFF, 0x7B, 0x85),
      Color(0x7E, 0xE7, 0xAD),
      Color(0xFF, 0xD8, 0x8A),
      Color(0x79, 0xB8, 0xFF),
      Color(0xDF, 0x9B, 0xFF),
      Color(0x7C, 0xE0, 0xEC),
      Color(0xF0, 0xF6, 0xFC),
    ],
  );

  /// Clean light theme with dark-ink ANSI hues for daytime readability.
  static const TerminalColorTheme termuiLight = TerminalColorTheme(
    id: 'termui_light',
    name: 'TermUI Light',
    brightness: .light,
    foreground: Color(0x1F, 0x23, 0x28),
    background: Color(0xF6, 0xF8, 0xFA),
    cursorColor: Color(0x09, 0x69, 0xDA),
    cursorTextColor: Color(0xFF, 0xFF, 0xFF),
    selectionBackground: Color(0xB6, 0xE3, 0xFF),
    selectionForeground: Color(0x1F, 0x23, 0x28),
    ansi: [
      Color(0x24, 0x29, 0x2F),
      Color(0xCF, 0x22, 0x2E),
      Color(0x11, 0x63, 0x29),
      Color(0x9A, 0x67, 0x00),
      Color(0x09, 0x69, 0xDA),
      Color(0x82, 0x50, 0xDF),
      Color(0x1B, 0x7C, 0x83),
      Color(0x57, 0x60, 0x6A),
      Color(0x4C, 0x55, 0x61),
      Color(0xA4, 0x0E, 0x26),
      Color(0x1A, 0x7F, 0x37),
      Color(0x7D, 0x53, 0x00),
      Color(0x05, 0x50, 0xAE),
      Color(0x66, 0x39, 0xBA),
      Color(0x13, 0x68, 0x73),
      Color(0x32, 0x38, 0x3F),
    ],
  );

  /// High-contrast dark theme targeting WCAG AAA (>= 7:1) across ANSI slots.
  static const TerminalColorTheme highContrastDark = TerminalColorTheme(
    id: 'high_contrast_dark',
    name: 'High Contrast Dark',
    brightness: .dark,
    foreground: Color(0xFF, 0xFF, 0xFF),
    background: Color(0x00, 0x00, 0x00),
    cursorColor: Color(0x00, 0xFF, 0x9C),
    cursorTextColor: Color(0x00, 0x00, 0x00),
    selectionBackground: Color(0x2B, 0x5C, 0x8F),
    selectionForeground: Color(0xFF, 0xFF, 0xFF),
    ansi: [
      Color(0x1C, 0x1C, 0x1C),
      Color(0xFF, 0x6B, 0x6B),
      Color(0x4E, 0xF0, 0x7F),
      Color(0xFF, 0xE0, 0x42),
      Color(0x6E, 0xB6, 0xFF),
      Color(0xEE, 0x82, 0xFF),
      Color(0x47, 0xD1, 0xFF),
      Color(0xE5, 0xE5, 0xE5),
      Color(0x9E, 0x9E, 0x9E),
      Color(0xFF, 0x8F, 0x8F),
      Color(0x80, 0xFF, 0xA8),
      Color(0xFF, 0xF0, 0x80),
      Color(0x99, 0xCE, 0xFF),
      Color(0xF6, 0xB3, 0xFF),
      Color(0x8A, 0xE2, 0xFF),
      Color(0xFF, 0xFF, 0xFF),
    ],
  );

  /// High-contrast light theme targeting WCAG AAA (>= 7:1) across ANSI slots.
  static const TerminalColorTheme highContrastLight = TerminalColorTheme(
    id: 'high_contrast_light',
    name: 'High Contrast Light',
    brightness: .light,
    foreground: Color(0x00, 0x00, 0x00),
    background: Color(0xFF, 0xFF, 0xFF),
    cursorColor: Color(0x00, 0x3D, 0xB8),
    cursorTextColor: Color(0xFF, 0xFF, 0xFF),
    selectionBackground: Color(0x99, 0xCC, 0xFF),
    selectionForeground: Color(0x00, 0x00, 0x00),
    ansi: [
      Color(0x00, 0x00, 0x00),
      Color(0xA8, 0x00, 0x00),
      Color(0x00, 0x63, 0x1E),
      Color(0x70, 0x45, 0x00),
      Color(0x00, 0x3D, 0xB8),
      Color(0x75, 0x00, 0x94),
      Color(0x00, 0x57, 0x6E),
      Color(0x4A, 0x4A, 0x4A),
      Color(0x3B, 0x3B, 0x3B),
      Color(0x8F, 0x00, 0x00),
      Color(0x00, 0x52, 0x18),
      Color(0x5E, 0x3A, 0x00),
      Color(0x00, 0x31, 0x99),
      Color(0x60, 0x00, 0x7A),
      Color(0x00, 0x47, 0x5C),
      Color(0x52, 0x52, 0x52),
    ],
  );

  /// Canonical Solarized Dark palette.
  static const TerminalColorTheme solarizedDark = TerminalColorTheme(
    id: 'solarized_dark',
    name: 'Solarized Dark',
    brightness: .dark,
    foreground: Color(0x83, 0x94, 0x96),
    background: Color(0x00, 0x2B, 0x36),
    cursorColor: Color(0x93, 0xA1, 0xA1),
    cursorTextColor: Color(0x00, 0x2B, 0x36),
    selectionBackground: Color(0x07, 0x36, 0x42),
    selectionForeground: Color(0x93, 0xA1, 0xA1),
    ansi: [
      Color(0x07, 0x36, 0x42),
      Color(0xDC, 0x32, 0x2F),
      Color(0x85, 0x99, 0x00),
      Color(0xB5, 0x89, 0x00),
      Color(0x26, 0x8B, 0xD2),
      Color(0xD3, 0x36, 0x82),
      Color(0x2A, 0xA1, 0x98),
      Color(0xEE, 0xE8, 0xD5),
      Color(0x00, 0x2B, 0x36),
      Color(0xCB, 0x4B, 0x16),
      Color(0x58, 0x6E, 0x75),
      Color(0x65, 0x7B, 0x83),
      Color(0x83, 0x94, 0x96),
      Color(0x6C, 0x71, 0xC4),
      Color(0x93, 0xA1, 0xA1),
      Color(0xFD, 0xF6, 0xE3),
    ],
  );

  /// Canonical Solarized Light palette.
  static const TerminalColorTheme solarizedLight = TerminalColorTheme(
    id: 'solarized_light',
    name: 'Solarized Light',
    brightness: .light,
    foreground: Color(0x65, 0x7B, 0x83),
    background: Color(0xFD, 0xF6, 0xE3),
    cursorColor: Color(0x58, 0x6E, 0x75),
    cursorTextColor: Color(0xFD, 0xF6, 0xE3),
    selectionBackground: Color(0xEE, 0xE8, 0xD5),
    selectionForeground: Color(0x58, 0x6E, 0x75),
    ansi: [
      Color(0x07, 0x36, 0x42),
      Color(0xDC, 0x32, 0x2F),
      Color(0x85, 0x99, 0x00),
      Color(0xB5, 0x89, 0x00),
      Color(0x26, 0x8B, 0xD2),
      Color(0xD3, 0x36, 0x82),
      Color(0x2A, 0xA1, 0x98),
      Color(0xEE, 0xE8, 0xD5),
      Color(0x00, 0x2B, 0x36),
      Color(0xCB, 0x4B, 0x16),
      Color(0x58, 0x6E, 0x75),
      Color(0x65, 0x7B, 0x83),
      Color(0x83, 0x94, 0x96),
      Color(0x6C, 0x71, 0xC4),
      Color(0x93, 0xA1, 0xA1),
      Color(0xFD, 0xF6, 0xE3),
    ],
  );

  /// Catppuccin Mocha dark palette.
  static const TerminalColorTheme catppuccinMocha = TerminalColorTheme(
    id: 'catppuccin_mocha',
    name: 'Catppuccin Mocha',
    brightness: .dark,
    foreground: Color(0xCD, 0xD6, 0xF4),
    background: Color(0x1E, 0x1E, 0x2E),
    cursorColor: Color(0xF5, 0xE0, 0xDC),
    cursorTextColor: Color(0x1E, 0x1E, 0x2E),
    selectionBackground: Color(0x45, 0x47, 0x5A),
    selectionForeground: Color(0xCD, 0xD6, 0xF4),
    ansi: [
      Color(0x45, 0x47, 0x5A),
      Color(0xF3, 0x8B, 0xA8),
      Color(0xA6, 0xE3, 0xA1),
      Color(0xF9, 0xE2, 0xAF),
      Color(0x89, 0xB4, 0xFA),
      Color(0xF5, 0xC2, 0xE7),
      Color(0x94, 0xE2, 0xD5),
      Color(0xBA, 0xC2, 0xDE),
      Color(0x58, 0x5B, 0x70),
      Color(0xF3, 0x8B, 0xA8),
      Color(0xA6, 0xE3, 0xA1),
      Color(0xF9, 0xE2, 0xAF),
      Color(0x89, 0xB4, 0xFA),
      Color(0xF5, 0xC2, 0xE7),
      Color(0x94, 0xE2, 0xD5),
      Color(0xA6, 0xAD, 0xC8),
    ],
  );

  /// Gruvbox Dark palette.
  static const TerminalColorTheme gruvboxDark = TerminalColorTheme(
    id: 'gruvbox_dark',
    name: 'Gruvbox Dark',
    brightness: .dark,
    foreground: Color(0xEB, 0xDB, 0xB2),
    background: Color(0x28, 0x28, 0x28),
    cursorColor: Color(0xEB, 0xDB, 0xB2),
    cursorTextColor: Color(0x28, 0x28, 0x28),
    selectionBackground: Color(0x50, 0x49, 0x45),
    selectionForeground: Color(0xEB, 0xDB, 0xB2),
    ansi: [
      Color(0x28, 0x28, 0x28),
      Color(0xCC, 0x24, 0x1D),
      Color(0x98, 0x97, 0x1A),
      Color(0xD7, 0x99, 0x21),
      Color(0x45, 0x85, 0x88),
      Color(0xB1, 0x62, 0x86),
      Color(0x68, 0x9D, 0x6A),
      Color(0xA8, 0x99, 0x84),
      Color(0x92, 0x83, 0x74),
      Color(0xFB, 0x49, 0x34),
      Color(0xB8, 0xBB, 0x26),
      Color(0xFA, 0xBD, 0x2F),
      Color(0x83, 0xA5, 0x98),
      Color(0xD3, 0x86, 0x9B),
      Color(0x8E, 0xC0, 0x7C),
      Color(0xEB, 0xDB, 0xB2),
    ],
  );

  /// All 8 built-in presets ordered for UI selection.
  static const List<TerminalColorTheme> presets = [
    termuiDark,
    highContrastDark,
    solarizedDark,
    catppuccinMocha,
    gruvboxDark,
    termuiLight,
    highContrastLight,
    solarizedLight,
  ];

  /// Looks up a built-in preset by [id], or returns `null` when unknown.
  static TerminalColorTheme? byId(String id) {
    for (final preset in presets) {
      if (preset.id == id) return preset;
    }
    return null;
  }

  /// Resolves an ANSI 256-color index (`0..255`) using this theme's 16-color
  /// palette for slots `0..15` and standard xterm-256 cube/grayscale math above.
  Color resolveAnsi256(int index) {
    if (index < 0 || index > 255) return foreground;
    if (index < 16) return ansi[index];
    if (index < 232) {
      final cube = index - 16;
      final r = (cube ~/ 36) % 6;
      final g = (cube ~/ 6) % 6;
      final b = cube % 6;
      return Color(
        r == 0 ? 0 : r * 40 + 55,
        g == 0 ? 0 : g * 40 + 55,
        b == 0 ? 0 : b * 40 + 55,
      );
    }
    final gray = (index - 232) * 10 + 8;
    return Color(gray, gray, gray);
  }

  /// Resolves a packed ARGB or [Color.ansi] integer against this theme.
  int resolvePackedColor(int packedColor) {
    if (packedColor.isAnsiIndexed) {
      return resolveAnsi256(packedColor.ansiIndex).argb;
    }
    return packedColor;
  }

  /// Returns a derived theme with [overrides] applied.
  TerminalColorTheme withOverrides(CustomPaletteOverrides overrides) {
    if (overrides.isEmpty) return this;
    final nextAnsi = List<Color>.unmodifiable([
      for (var i = 0; i < 16; i++) overrides.ansiOverrides[i] ?? ansi[i],
    ]);
    return TerminalColorTheme(
      id: id,
      name: name,
      brightness: brightness,
      foreground: overrides.foreground ?? foreground,
      background: overrides.background ?? background,
      cursorColor: overrides.cursorColor ?? cursorColor,
      cursorTextColor: overrides.cursorTextColor ?? cursorTextColor,
      selectionBackground: overrides.selectionBackground ?? selectionBackground,
      selectionForeground: overrides.selectionForeground ?? selectionForeground,
      ansi: nextAnsi,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! TerminalColorTheme) return false;
    if (id != other.id ||
        name != other.name ||
        brightness != other.brightness ||
        foreground != other.foreground ||
        background != other.background ||
        cursorColor != other.cursorColor ||
        cursorTextColor != other.cursorTextColor ||
        selectionBackground != other.selectionBackground ||
        selectionForeground != other.selectionForeground) {
      return false;
    }
    for (var i = 0; i < 16; i++) {
      if (ansi[i] != other.ansi[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hash(
    id,
    name,
    brightness,
    foreground,
    background,
    cursorColor,
    cursorTextColor,
    selectionBackground,
    selectionForeground,
    Object.hashAll(ansi),
  );
}

/// Pure-Dart WCAG 2.1 contrast and OKLab lightness helpers for ANSI colors.
abstract final class TerminalContrast {
  /// Returns relative luminance (`0.0..1.0`) per WCAG 2.1.
  static double relativeLuminance(Color color) {
    final r = _linearizeSrgb(color.r / 255.0);
    final g = _linearizeSrgb(color.g / 255.0);
    final b = _linearizeSrgb(color.b / 255.0);
    return 0.2126 * r + 0.7152 * g + 0.0722 * b;
  }

  /// Returns WCAG 2.1 contrast ratio (`1.0..21.0`) between [a] and [b].
  static double contrastRatio(Color a, Color b) {
    final la = relativeLuminance(a);
    final lb = relativeLuminance(b);
    final lighter = math.max(la, lb);
    final darker = math.min(la, lb);
    return (lighter + 0.05) / (darker + 0.05);
  }

  /// Whether [grapheme] is a space, box-drawing, block element, or Powerline
  /// symbol whose exact color should not be contrast-shifted.
  static bool shouldSkipContrastAdjustment(String grapheme) {
    if (grapheme.isEmpty || grapheme == ' ') return true;
    final rune = grapheme.runes.first;
    if (rune >= 0x2500 && rune <= 0x259F) return true;
    if (rune >= 0xE0B0 && rune <= 0xE0D7) return true;
    return false;
  }

  /// Adjusts [fg] lightness in OKLab until contrast against [bg] meets
  /// [minRatio] (`1.0..21.0`), preserving hue as much as the sRGB gamut allows.
  ///
  /// When [hasExplicitBackground] is `true`, intentional `fg == bg` spoiler
  /// cells are preserved unchanged. When `false`, ANSI foregrounds that collide
  /// with the default theme background are adjusted to meet [minRatio].
  static Color enforceMinimumContrast(
    Color fg,
    Color bg, {
    required double minRatio,
    bool hasExplicitBackground = false,
  }) {
    if (minRatio <= 1.0) return fg;
    if (hasExplicitBackground && fg.r == bg.r && fg.g == bg.g && fg.b == bg.b) {
      return fg;
    }
    if (contrastRatio(fg, bg) >= minRatio) return fg;

    final goLighter =
        contrastRatio(Colors.white, bg) >= contrastRatio(Colors.black, bg);
    final (initialPassL, fallback) = goLighter
        ? (1.0, Colors.white)
        : (0.0, Colors.black);
    final (startL, a, b) = _srgbToOklab(fg);
    var failL = startL;
    var passL = initialPassL;
    var best = fallback;

    for (var i = 0; i < 10; i++) {
      final mid = (failL + passL) * 0.5;
      final candidate = _oklabToSrgb(mid, a, b);
      if (contrastRatio(candidate, bg) >= minRatio) {
        best = candidate;
        passL = mid;
      } else {
        failL = mid;
      }
    }
    return best;
  }

  /// Returns either [preferredText] or a high-contrast black/white fallback for
  /// drawing text over [fill].
  static Color ensureReadableTextOn(Color preferredText, Color fill) {
    if (contrastRatio(preferredText, fill) >= 3.0) return preferredText;
    return contrastRatio(Colors.white, fill) >=
            contrastRatio(Colors.black, fill)
        ? Colors.white
        : Colors.black;
  }

  static double _linearizeSrgb(double channel) => channel <= 0.04045
      ? channel / 12.92
      : math.pow((channel + 0.055) / 1.055, 2.4).toDouble();

  static int _encodeSrgbByte(double linear) {
    final clamped = linear.clamp(0.0, 1.0);
    final gamma = clamped <= 0.0031308
        ? 12.92 * clamped
        : 1.055 * math.pow(clamped, 1.0 / 2.4).toDouble() - 0.055;
    return (gamma * 255.0).round().clamp(0, 255);
  }

  static double _cbrt(double x) => x >= 0
      ? math.pow(x, 1.0 / 3.0).toDouble()
      : -math.pow(-x, 1.0 / 3.0).toDouble();

  static (double l, double a, double b) _srgbToOklab(Color c) {
    final r = _linearizeSrgb(c.r / 255.0);
    final g = _linearizeSrgb(c.g / 255.0);
    final b = _linearizeSrgb(c.b / 255.0);

    final l = _cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b);
    final m = _cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b);
    final s = _cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b);

    return (
      0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
      1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
      0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s,
    );
  }

  static Color _oklabToSrgb(double lVal, double aVal, double bVal) {
    final l_ = lVal + 0.3963377774 * aVal + 0.2158037573 * bVal;
    final m_ = lVal - 0.1055613458 * aVal - 0.0638541728 * bVal;
    final s_ = lVal - 0.0894841775 * aVal - 1.2914855480 * bVal;

    final l = l_ * l_ * l_;
    final m = m_ * m_ * m_;
    final s = s_ * s_ * s_;

    final rLin = 4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s;
    final gLin = -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s;
    final bLin = -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s;

    return Color(
      _encodeSrgbByte(rLin),
      _encodeSrgbByte(gLin),
      _encodeSrgbByte(bLin),
    );
  }
}
