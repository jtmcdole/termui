import 'dart:typed_data';

import 'package:termui/termui.dart';

/// Selection of system brightness or explicit dark/light mode for terminal themes.
enum ThemeAppearanceMode {
  /// Match the operating system brightness.
  system,

  /// Always use the configured dark theme.
  dark,

  /// Always use the configured light theme.
  light,
}

/// User-configurable terminal theme and contrast settings.
final class TerminalThemeSettings {
  /// Default dark theme preset identifier.
  static const String defaultDarkThemeId = 'termui_dark';

  /// Default light theme preset identifier.
  static const String defaultLightThemeId = 'termui_light';

  /// Appearance mode controlling whether system brightness or explicit dark/light is active.
  final ThemeAppearanceMode appearanceMode;

  /// Identifier of the preset used when dark brightness is active.
  final String darkThemeId;

  /// Identifier of the preset used when light brightness is active.
  final String lightThemeId;

  /// Minimum WCAG contrast ratio enforced on ANSI indexed colors (`1.0..21.0`).
  final double minimumContrast;

  /// Whether `Modifier.bold` on ANSI `0..7` remaps to bright ANSI `8..15`.
  final bool boldIsBright;

  /// Opacity multiplier for faint/dim text (`0.25..1.0`).
  final double faintOpacity;

  /// Whether block cursor foreground and background invert when cell colors match cursor colors.
  final bool smartCursorColor;

  /// User-defined color overrides on top of the active preset.
  final CustomPaletteOverrides customOverrides;

  /// Creates terminal theme settings with calibrated defaults.
  const TerminalThemeSettings({
    this.appearanceMode = .system,
    this.darkThemeId = defaultDarkThemeId,
    this.lightThemeId = defaultLightThemeId,
    this.minimumContrast = 1.0,
    this.boldIsBright = false,
    this.faintOpacity = 0.55,
    this.smartCursorColor = true,
    this.customOverrides = CustomPaletteOverrides.empty,
  });

  /// Resolves the active [TerminalColorTheme] for [platformBrightness] with [customOverrides] applied.
  TerminalColorTheme resolveActiveTheme(TerminalBrightness platformBrightness) {
    final isDark = switch (appearanceMode) {
      .system => platformBrightness == .dark,
      .dark => true,
      .light => false,
    };
    final themeId = isDark ? darkThemeId : lightThemeId;
    final fallbackPreset = isDark
        ? TerminalColorTheme.termuiDark
        : TerminalColorTheme.termuiLight;
    final preset = TerminalColorTheme.byId(themeId) ?? fallbackPreset;
    return preset.withOverrides(customOverrides);
  }

  /// Returns a copy of these settings with specified fields replaced.
  TerminalThemeSettings copyWith({
    ThemeAppearanceMode? appearanceMode,
    String? darkThemeId,
    String? lightThemeId,
    double? minimumContrast,
    bool? boldIsBright,
    double? faintOpacity,
    bool? smartCursorColor,
    CustomPaletteOverrides? customOverrides,
  }) => TerminalThemeSettings(
    appearanceMode: appearanceMode ?? this.appearanceMode,
    darkThemeId: darkThemeId ?? this.darkThemeId,
    lightThemeId: lightThemeId ?? this.lightThemeId,
    minimumContrast: _clampFinite(
      minimumContrast,
      min: 1.0,
      max: 21.0,
      fallback: this.minimumContrast.isFinite ? this.minimumContrast : 1.0,
    ),
    boldIsBright: boldIsBright ?? this.boldIsBright,
    faintOpacity: _clampFinite(
      faintOpacity,
      min: 0.25,
      max: 1.0,
      fallback: this.faintOpacity.isFinite ? this.faintOpacity : 0.55,
    ),
    smartCursorColor: smartCursorColor ?? this.smartCursorColor,
    customOverrides: customOverrides ?? this.customOverrides,
  );

  static double _clampFinite(
    double? value, {
    required double min,
    required double max,
    required double fallback,
  }) => value == null || !value.isFinite ? fallback : value.clamp(min, max);

  /// Serializes theme settings to a JSON map.
  Map<String, Object?> toJson() => {
    'appearanceMode': appearanceMode.name,
    'darkThemeId': darkThemeId,
    'lightThemeId': lightThemeId,
    'minimumContrast': minimumContrast,
    'boldIsBright': boldIsBright,
    'faintOpacity': faintOpacity,
    'smartCursorColor': smartCursorColor,
    if (!customOverrides.isEmpty) 'customOverrides': customOverrides.toJson(),
  };

  /// Parses settings from a JSON map with resilient fallbacks on invalid data.
  static TerminalThemeSettings fromJson(Object? raw) {
    if (raw is! Map<Object?, Object?>) return const TerminalThemeSettings();
    final ThemeAppearanceMode appearanceMode = switch (raw['appearanceMode']) {
      'system' => .system,
      'dark' => .dark,
      'light' => .light,
      _ => .system,
    };
    final darkId = raw['darkThemeId'];
    final lightId = raw['lightThemeId'];
    final minContrastRaw = raw['minimumContrast'];
    final boldIsBrightRaw = raw['boldIsBright'];
    final faintOpacityRaw = raw['faintOpacity'];
    final smartCursorColorRaw = raw['smartCursorColor'];

    return TerminalThemeSettings(
      appearanceMode: appearanceMode,
      darkThemeId: darkId is String && darkId.isNotEmpty
          ? darkId
          : defaultDarkThemeId,
      lightThemeId: lightId is String && lightId.isNotEmpty
          ? lightId
          : defaultLightThemeId,
      minimumContrast: _clampFinite(
        minContrastRaw is num ? minContrastRaw.toDouble() : null,
        min: 1.0,
        max: 21.0,
        fallback: 1.0,
      ),
      boldIsBright: boldIsBrightRaw is bool && boldIsBrightRaw,
      faintOpacity: _clampFinite(
        faintOpacityRaw is num ? faintOpacityRaw.toDouble() : null,
        min: 0.25,
        max: 1.0,
        fallback: 0.55,
      ),
      smartCursorColor: smartCursorColorRaw is! bool || smartCursorColorRaw,
      customOverrides: CustomPaletteOverrides.fromJson(raw['customOverrides']),
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TerminalThemeSettings &&
          other.appearanceMode == appearanceMode &&
          other.darkThemeId == darkThemeId &&
          other.lightThemeId == lightThemeId &&
          other.minimumContrast == minimumContrast &&
          other.boldIsBright == boldIsBright &&
          other.faintOpacity == faintOpacity &&
          other.smartCursorColor == smartCursorColor &&
          other.customOverrides == customOverrides;

  @override
  int get hashCode => Object.hash(
    appearanceMode,
    darkThemeId,
    lightThemeId,
    minimumContrast,
    boldIsBright,
    faintOpacity,
    smartCursorColor,
    customOverrides,
  );
}

/// Resolves raw cell colors against a [TerminalColorTheme] and [TerminalThemeSettings].
///
/// Precomputes 256-entry normal and bold OKLab contrast lookup tables against
/// [TerminalColorTheme.background] once per theme/settings switch, and caches
/// explicit `(fg, bg)` pairs for $O(1)$ per-cell composition.
final class TerminalColorResolver {
  static const int _maxExplicitBgCacheEntries = 1024;

  /// Active theme providing the 16-color ANSI palette and default colors.
  final TerminalColorTheme theme;

  /// User theme preferences (contrast, boldIsBright, smart cursor).
  final TerminalThemeSettings settings;

  final Uint32List _defaultBgNormalLut;
  final Uint32List _defaultBgBoldLut;
  final Map<int, int> _explicitBgCache = <int, int>{};
  final Uint32List _scratchCellAttrs = Uint32List(3);

  /// Creates a color resolver for [theme] and [settings].
  TerminalColorResolver({required this.theme, required this.settings})
    : _defaultBgNormalLut = _buildDefaultBgLut(theme, settings, isBold: false),
      _defaultBgBoldLut = _buildDefaultBgLut(theme, settings, isBold: true);

  static Uint32List _buildDefaultBgLut(
    TerminalColorTheme theme,
    TerminalThemeSettings settings, {
    required bool isBold,
  }) {
    final lut = Uint32List(256);
    final minRatio = settings.minimumContrast;
    final enforce = minRatio.isFinite && minRatio > 1.0;
    final bg = theme.background;
    for (var i = 0; i < 256; i++) {
      final mappedIdx = settings.boldIsBright && isBold && i < 8 ? i + 8 : i;
      final base = theme.resolveAnsi256(mappedIdx);
      lut[i] = enforce
          ? TerminalContrast.enforceMinimumContrast(
              base,
              bg,
              minRatio: minRatio,
              hasExplicitBackground: false,
            ).argb
          : base.argb;
    }
    return lut;
  }

  /// Resolves the cell's `(fg, bg)` attribute integers for display.
  ///
  /// Leaves `fg == 0` and `bg == 0` as `0` for default styling, passes 24-bit truecolor
  /// through untouched, remaps `Color.ansi` indexed colors against [theme], and enforces
  /// [TerminalThemeSettings.minimumContrast] against the effective visual background.
  (int fg, int bg) resolveCellColors({
    required int rawFg,
    required int rawBg,
    required int modifiers,
    required String grapheme,
  }) {
    resolveCellInto(
      rawFg: rawFg,
      rawBg: rawBg,
      modifiers: modifiers,
      grapheme: grapheme,
      outAttributes: _scratchCellAttrs,
      attrOffset: 0,
    );
    return (_scratchCellAttrs[0], _scratchCellAttrs[1]);
  }

  /// Resolves the cell's display colors and writes `(fg, bg, modifiers)` into
  /// [outAttributes] starting at [attrOffset] without allocating a Record.
  void resolveCellInto({
    required int rawFg,
    required int rawBg,
    required int modifiers,
    required String grapheme,
    required Uint32List outAttributes,
    required int attrOffset,
  }) {
    outAttributes[attrOffset + 2] = modifiers;
    if (rawFg == 0 && rawBg == 0) {
      outAttributes[attrOffset] = 0;
      outAttributes[attrOffset + 1] = 0;
      return;
    }
    final isFgIndexed = rawFg.isAnsiIndexed;
    final isBgIndexed = rawBg.isAnsiIndexed;
    if (!isFgIndexed && !isBgIndexed) {
      outAttributes[attrOffset] = rawFg;
      outAttributes[attrOffset + 1] = rawBg;
      return;
    }

    if (Modifier.has(modifiers, Modifier.reverse)) {
      _resolveReverseCellInto(
        rawFg: rawFg,
        rawBg: rawBg,
        modifiers: modifiers,
        grapheme: grapheme,
        outAttributes: outAttributes,
        attrOffset: attrOffset,
      );
      return;
    }

    final outBg = isBgIndexed
        ? theme.resolveAnsi256(rawBg.ansiIndex).argb
        : rawBg;
    outAttributes[attrOffset + 1] = outBg;
    if (!isFgIndexed) {
      outAttributes[attrOffset] = rawFg;
      return;
    }

    final fgIdx = rawFg.ansiIndex;
    final mappedIdx = _mappedFgIndex(fgIdx, modifiers);
    if (TerminalContrast.shouldSkipContrastAdjustment(grapheme)) {
      outAttributes[attrOffset] = theme.resolveAnsi256(mappedIdx).argb;
      return;
    }
    if (rawBg == 0) {
      final lut = Modifier.has(modifiers, Modifier.bold)
          ? _defaultBgBoldLut
          : _defaultBgNormalLut;
      outAttributes[attrOffset] = lut[fgIdx];
      return;
    }
    outAttributes[attrOffset] = _resolveIndexedOnExplicitBg(
      mappedIdx,
      outBg,
      hasExplicitBackground: true,
    );
  }

  int _mappedFgIndex(int fgIdx, int modifiers) =>
      settings.boldIsBright &&
          fgIdx < 8 &&
          Modifier.has(modifiers, Modifier.bold)
      ? fgIdx + 8
      : fgIdx;

  void _resolveReverseCellInto({
    required int rawFg,
    required int rawBg,
    required int modifiers,
    required String grapheme,
    required Uint32List outAttributes,
    required int attrOffset,
  }) {
    final isFgIndexed = rawFg.isAnsiIndexed;
    final isBgIndexed = rawBg.isAnsiIndexed;
    final mappedFgIdx = isFgIndexed
        ? _mappedFgIndex(rawFg.ansiIndex, modifiers)
        : -1;
    final skipContrast = TerminalContrast.shouldSkipContrastAdjustment(
      grapheme,
    );

    // Under Modifier.reverse, rawFg is the visual background (0 -> theme.foreground)
    // and rawBg is the visual foreground (0 -> theme.background).
    var outFg = mappedFgIdx >= 0
        ? theme.resolveAnsi256(mappedFgIdx).argb
        : rawFg;
    if (isBgIndexed) {
      final bgIdx = rawBg.ansiIndex;
      outAttributes[attrOffset] = outFg;
      if (skipContrast) {
        outAttributes[attrOffset + 1] = theme.resolveAnsi256(bgIdx).argb;
        return;
      }
      final visualBgArgb = outFg == 0 ? theme.foreground.argb : outFg;
      outAttributes[attrOffset + 1] = _resolveIndexedOnExplicitBg(
        bgIdx,
        visualBgArgb,
        hasExplicitBackground: rawFg != 0,
      );
      return;
    }
    if (mappedFgIdx >= 0 && !skipContrast) {
      final visualFgArgb = rawBg == 0 ? theme.background.argb : rawBg;
      outFg = _resolveIndexedOnExplicitBg(
        mappedFgIdx,
        visualFgArgb,
        hasExplicitBackground: rawBg != 0,
      );
    }
    outAttributes[attrOffset] = outFg;
    outAttributes[attrOffset + 1] = rawBg;
  }

  int _resolveIndexedOnExplicitBg(
    int mappedIdx,
    int effectiveBgArgb, {
    required bool hasExplicitBackground,
  }) {
    final minRatio = settings.minimumContrast;
    if (!minRatio.isFinite || minRatio <= 1.0) {
      return theme.resolveAnsi256(mappedIdx).argb;
    }
    final key =
        ((hasExplicitBackground ? 256 : 0) + mappedIdx) * 0x1000000 +
        (effectiveBgArgb & 0x00FFFFFF);
    if (_explicitBgCache[key] case final cached?) return cached;
    final resolved = TerminalContrast.enforceMinimumContrast(
      theme.resolveAnsi256(mappedIdx),
      Color.argb(effectiveBgArgb),
      minRatio: minRatio,
      hasExplicitBackground: hasExplicitBackground,
    ).argb;
    if (_explicitBgCache.length >= _maxExplicitBgCacheEntries) {
      _explicitBgCache.clear();
    }
    _explicitBgCache[key] = resolved;
    return resolved;
  }

  /// Resolves the cursor fill color and text color for a cursor at `(cellFg, cellBg)`.
  (int cursorColor, int cursorTextColor) resolveCursorColors({
    required int cellFg,
    required int cellBg,
  }) {
    if (!settings.smartCursorColor) {
      return (theme.cursorColor.argb, theme.cursorTextColor.argb);
    }

    final effectiveBg = _resolveEffectiveColor(cellBg, theme.background);
    final effectiveFg = _resolveEffectiveColor(cellFg, theme.foreground);

    final defaultCursor = theme.cursorColor;
    if (TerminalContrast.contrastRatio(defaultCursor, effectiveBg) >= 4.5) {
      return (
        defaultCursor.argb,
        _readableTextAtLeast45(theme.cursorTextColor, defaultCursor).argb,
      );
    }

    final invertedCursor =
        TerminalContrast.contrastRatio(effectiveFg, effectiveBg) >= 4.5
        ? effectiveFg
        : _readableTextAtLeast45(effectiveFg, effectiveBg);
    return (
      invertedCursor.argb,
      _readableTextAtLeast45(effectiveBg, invertedCursor).argb,
    );
  }

  Color _resolveEffectiveColor(int rawColor, Color fallback) {
    if (rawColor == 0) return fallback;
    return rawColor.isAnsiIndexed
        ? theme.resolveAnsi256(rawColor.ansiIndex)
        : Color.argb(rawColor);
  }

  static Color _readableTextAtLeast45(Color preferred, Color fill) {
    if (TerminalContrast.contrastRatio(preferred, fill) >= 4.5) {
      return preferred;
    }
    return TerminalContrast.contrastRatio(Colors.white, fill) >=
            TerminalContrast.contrastRatio(Colors.black, fill)
        ? Colors.white
        : Colors.black;
  }
}
