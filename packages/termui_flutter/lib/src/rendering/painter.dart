import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:characters/characters.dart';
import 'package:clock/clock.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart' hide SelectionPoint;
import 'package:flutter/scheduler.dart';
import 'package:termui/ui/buffer.dart';
import 'package:termui/ui/color.dart' show ColorIntExtension;
import 'package:termui/ui/glyph_cell_list.dart';
import 'package:termui/ui/style.dart';
import 'package:termui/ui/terminal_palette.dart';
import 'package:termui/ui/widgets/display/kitty_image.dart';
import 'package:termui/ui/widgets/interactive/selection_controller.dart';
import 'atlas.dart';
import 'atlas_quad_table.dart';
import 'staging_cache.dart';

/// Reusable per-frame typed sink for writing visual overrides across hovered
/// hyperlink cells without allocating per-cell records or closures.
final class HoveredLinkCellStyles {
  Uint32List _fgArgb = Uint32List(0);
  Uint32List _bgArgb = Uint32List(0);
  Uint32List _ulArgb = Uint32List(0);
  Uint32List _modifiers = Uint32List(0);
  Uint8List _flags = Uint8List(0);

  static const int _hasFg = 1 << 0;
  static const int _hasBg = 1 << 1;
  static const int _hasUl = 1 << 2;
  static const int _hasMods = 1 << 3;

  int _length = 0;
  bool _hasUniformBg = false;
  int _uniformBgArgb = 0;
  bool _hasUniformMods = false;
  int _uniformModifiers = 0;
  bool _hasPerCellBg = false;
  bool _hasPerCellMods = false;

  /// Whether cell underlines reuse the cell's overridden foreground color
  /// unless explicitly overridden via [setUnderlineColor].
  bool underlineMatchesForeground = false;

  /// Number of cells in the active hovered link range.
  int get length => _length;

  /// Prepares capacity for [cellCount] cells and clears all override flags.
  @visibleForTesting
  void reset(int cellCount) {
    final clamped = math.max(0, cellCount);
    _length = clamped;
    _hasUniformBg = false;
    _uniformBgArgb = 0;
    _hasUniformMods = false;
    _uniformModifiers = 0;
    _hasPerCellBg = false;
    _hasPerCellMods = false;
    underlineMatchesForeground = false;
    if (clamped > _flags.length) {
      _fgArgb = Uint32List(clamped);
      _bgArgb = Uint32List(clamped);
      _ulArgb = Uint32List(clamped);
      _modifiers = Uint32List(clamped);
      _flags = Uint8List(clamped);
    } else {
      _flags.fillRange(0, clamped, 0);
    }
  }

  /// Clears active overrides without shrinking allocated backing arrays.
  @visibleForTesting
  void clear() {
    _length = 0;
    _hasUniformBg = false;
    _uniformBgArgb = 0;
    _hasUniformMods = false;
    _uniformModifiers = 0;
    _hasPerCellBg = false;
    _hasPerCellMods = false;
    underlineMatchesForeground = false;
  }

  /// Sets the foreground ARGB color for hovered cell [index].
  void setForeground(int index, int argb) {
    if (index < 0 || index >= _length) return;
    _fgArgb[index] = argb;
    _flags[index] |= _hasFg;
  }

  /// Sets the background ARGB color for hovered cell [index].
  void setBackground(int index, int argb) {
    if (index < 0 || index >= _length) return;
    _bgArgb[index] = argb;
    _flags[index] |= _hasBg;
    _hasPerCellBg = true;
  }

  /// Fills the background ARGB color across `[start, end)` hovered cells
  /// (defaults to `[0, length)` in O(1) time).
  void fillBackground(int argb, [int start = 0, int? end]) {
    final s = start.clamp(0, _length);
    final e = (end ?? _length).clamp(s, _length);
    if (s == 0 && e == _length) {
      _hasUniformBg = true;
      _uniformBgArgb = argb;
      if (_hasPerCellBg) {
        for (var i = 0; i < _length; i++) {
          _flags[i] &= ~_hasBg;
        }
        _hasPerCellBg = false;
      }
      return;
    }
    for (var i = s; i < e; i++) {
      _bgArgb[i] = argb;
      _flags[i] |= _hasBg;
    }
    if (s < e) {
      _hasPerCellBg = true;
    }
  }

  /// Sets the underline ARGB color for hovered cell [index].
  void setUnderlineColor(int index, int argb) {
    if (index < 0 || index >= _length) return;
    _ulArgb[index] = argb;
    _flags[index] |= _hasUl;
  }

  /// Sets additional [Modifier] bits ORed onto hovered cell [index].
  void setModifiers(int index, int modifiers) {
    if (index < 0 || index >= _length) return;
    _modifiers[index] = modifiers;
    _flags[index] |= _hasMods;
    _hasPerCellMods = true;
  }

  /// Fills additional [Modifier] bits across `[start, end)` hovered cells
  /// (defaults to `[0, length)` in O(1) time).
  void fillModifiers(int modifiers, [int start = 0, int? end]) {
    final s = start.clamp(0, _length);
    final e = (end ?? _length).clamp(s, _length);
    if (s == 0 && e == _length) {
      _hasUniformMods = true;
      _uniformModifiers = modifiers;
      if (_hasPerCellMods) {
        for (var i = 0; i < _length; i++) {
          _flags[i] &= ~_hasMods;
        }
        _hasPerCellMods = false;
      }
      return;
    }
    for (var i = s; i < e; i++) {
      _modifiers[i] = modifiers;
      _flags[i] |= _hasMods;
    }
    if (s < e) {
      _hasPerCellMods = true;
    }
  }

  /// Returns the overridden foreground ARGB color at [index], or `null` if unset.
  int? foregroundAt(int index) =>
      index >= 0 && index < _length && (_flags[index] & _hasFg) != 0
      ? _fgArgb[index]
      : null;

  /// Returns the overridden background ARGB color at [index], or `null` if unset.
  int? backgroundAt(int index) {
    if (index < 0 || index >= _length) return null;
    if ((_flags[index] & _hasBg) != 0) return _bgArgb[index];
    return _hasUniformBg ? _uniformBgArgb : null;
  }

  /// Returns the overridden underline ARGB color at [index], or `null` if unset.
  int? underlineColorAt(int index) {
    if (index < 0 || index >= _length) return null;
    if ((_flags[index] & _hasUl) != 0) return _ulArgb[index];
    return underlineMatchesForeground ? foregroundAt(index) : null;
  }

  /// Returns the overridden modifier bits at [index], or `null` if unset.
  int? modifiersAt(int index) {
    if (index < 0 || index >= _length) return null;
    if ((_flags[index] & _hasMods) != 0) return _modifiers[index];
    return _hasUniformMods ? _uniformModifiers : null;
  }
}

/// Client callback invoked once per painted frame when [link] is hovered,
/// writing per-cell overrides across `[0, cellCount)` into [styles] at [timestamp].
typedef HoveredLinkStyler =
    void Function(
      ResolvedTerminalLink link,
      int cellCount,
      DateTime timestamp,
      HoveredLinkCellStyles styles,
    );

/// Computes the total terminal cell width spanned by [text], counting wide
/// graphemes as `2` cells and normal graphemes as `1`.
int countGraphemeDisplayCells(String text) {
  var total = 0;
  for (final grapheme in text.characters) {
    total += isWideGrapheme(grapheme) ? 2 : 1;
  }
  return total;
}

@pragma('vm:prefer-inline')
bool _isBlockCode(int code) => code >= 0x2580 && code <= 0x2590;

@pragma('vm:prefer-inline')
bool _isProceduralCode(int code) => switch (code) {
  0x2580 ||
  0x2584 ||
  (>= 0x2588 && <= 0x2593) ||
  0x2500 ||
  0x2502 ||
  0x250C ||
  0x2510 ||
  0x2514 ||
  0x2518 ||
  0x251C ||
  0x2524 ||
  0x252C ||
  0x2534 ||
  0x253C ||
  0x2550 ||
  0x2551 ||
  0x2554 ||
  0x2557 ||
  0x255A ||
  0x255D => true,
  _ => false,
};

@pragma('vm:prefer-inline')
bool _isColorEmojiCode(int code) =>
    code == 0xFE0F || (code >= 0x1F300 && code <= 0x1FAFF);

@pragma('vm:prefer-inline')
bool _needsGlyphOverhangCode(
  int code, {
  required bool isBold,
  required bool isItalic,
}) {
  if (_isProceduralCode(code)) return false;
  if (isItalic) return true;
  if (code >= 0x20 && code <= 0x7E) {
    return isBold && (code == 0x26 || code == 0x57 || code == 0x59);
  }
  return code > 0x7E;
}

bool _isBlockCharacter(String char) {
  if (char.isEmpty) return false;
  return _isBlockCode(char.codeUnitAt(0));
}

bool _needsGlyphOverhang(
  String char, {
  required bool isBold,
  required bool isItalic,
}) {
  if (char.isEmpty || isProceduralAtlasCharacter(char)) return false;
  if (isItalic) return true;
  if (char.length == 1) {
    final code = char.codeUnitAt(0);
    if (code >= 0x20 && code <= 0x7E) {
      return isBold && (code == 0x26 || code == 0x57 || code == 0x59);
    }
    return code > 0x7E;
  }
  return true;
}

const Set<String> _knownLigatures = {
  // 4-character
  '<!--', '->>>', '<<<-', '<==>', '<-->',
  // 3-character
  '===', '!==', '=/=', '=>>', '==>', '<==', '<=>', '<->',
  '<--', '-->', '<<-', '->>', '...', '..<', ':::',
  '///', '/**', '***', '<|>', '<*>', '<+>', r'<$>',
  // 2-character
  '->', '<-', '=>', '<=', '>=', '==', '!=', ':=',
  '::', '..', '??', '?.', '||', '&&', '++', '--',
  '**', '~~', '~>', '~=', '<>', '</', '/>', '/*',
  '*/', '//', '<|', '|>', '[|', '|]', '{|', '|}',
  '##', '%%', '@@', '!!',
};

@pragma('vm:prefer-inline')
bool _isLigatureCode(int c) =>
    (c >= 0x21 && c <= 0x2F) ||
    (c >= 0x3A && c <= 0x40) ||
    (c >= 0x5B && c <= 0x5F) ||
    (c >= 0x7B && c <= 0x7E);

/// Determines if a given grapheme cluster character represents a color emoji.
bool isColorEmoji(String char) {
  if (char.isEmpty) return false;
  // Fast-path single UTF-16 code units: emoji >= U+1F300 require surrogate pairs,
  // leaving standalone U+FE0F (VS16 emoji presentation selector) as the only match.
  if (char.length == 1) return char.codeUnitAt(0) == 0xFE0F;
  var hasVs16 = false;
  for (var i = 0; i < char.length; i++) {
    final cu = char.codeUnitAt(i);
    if (cu == 0xFE0E) return false; // VS15 forces monochrome text presentation.
    if (cu == 0xFE0F) hasVs16 = true; // VS16 requests color emoji presentation.
  }
  if (hasVs16) return true;
  final code = char.runes.first;
  return code >= 0x1F300 && code <= 0x1FAFF;
}

AtlasDecorationKind? _underlineKindForStyle(UnderlineStyle style) =>
    switch (style) {
      UnderlineStyle.none => null,
      UnderlineStyle.single => AtlasDecorationKind.underlineSingle,
      UnderlineStyle.doubleLine => AtlasDecorationKind.underlineDouble,
      UnderlineStyle.curly => AtlasDecorationKind.underlineCurly,
      UnderlineStyle.dotted => AtlasDecorationKind.underlineDotted,
      UnderlineStyle.dashed => AtlasDecorationKind.underlineDashed,
    };

/// A custom painter that renders a terminal buffer using a texture atlas.
///
/// It draws both the cell backgrounds, foreground glyphs, and pre-baked
/// decoration sprites onto a Flutter [Canvas]. To optimize performance and
/// prevent GPU command buffer overflow when drawing large grids, the painter
/// batches draw calls using [Canvas.drawRawAtlas] in chunks of 2048 sprites
/// and optionally caches clean rows across frames via [stagingCache].
///
/// If a character is not found in the [atlas] (e.g. dynamic unicode or emojis
/// being loaded), it triggers [onMissingGlyphs] and falls back to rendering
/// with individual text painters stored in [fallbackPainters].
final class TuiAtlasPainter extends CustomPainter {
  /// Optional listenable driving canvas repaints without rebuilding the widget subtree.
  final Listenable? repaint;

  /// The buffer containing the current layout state to paint.
  final Buffer buffer;

  /// The pre-rasterized texture map for fast grapheme rendering.
  final GlyphAtlas atlas;

  /// Optional persistent row-staging cache reused across frames and rebuilds.
  final TuiAtlasStagingCache? stagingCache;

  /// Optional per-cell override mask (`cols * rows`); non-zero entries suppress
  /// static foreground and decoration emission while preserving cell backgrounds.
  final Uint8List? cellOverrideMask;

  /// Optional pre-laid-out [TextPainter] for [composingText] cached outside `paint()`.
  final TextPainter? composingPainter;

  /// Optional callback invoked when unrecognized glyphs are requested.
  final void Function(List<String>)? onMissingGlyphs;

  /// Optional callback invoked with exact `(char, GlyphStyleVariant)` pairs for lazy on-demand rasterization.
  final void Function(List<(String, GlyphStyleVariant)>)? onMissingStyledGlyphs;

  /// Optional callback invoked at the start of [paint] before reading caches.
  final VoidCallback? onBeforePaint;

  /// Cache of individual [TextPainter] objects for glyphs absent in the main atlas.
  final Map<(String, bool, bool, bool, Color), TextPainter> fallbackPainters;

  TuiAtlasStagingCache? _ephemeralCache;

  static final Paint _atlasSpritePaint = Paint()
    ..filterQuality = FilterQuality.none;
  static final Paint _emojiSpritePaint = Paint();
  final Paint _defaultBgPaint = Paint();
  final Paint _dimPaint = Paint();
  final Paint _borderPaint = Paint()..strokeWidth = 1.0;
  final Paint _composingBgPaint = Paint();
  final Paint _composingUnderlinePaint = Paint()..strokeWidth = 1.5;
  final Paint _italicPaint = Paint()..filterQuality = FilterQuality.low;
  final Paint _kittyPaint = Paint()
    ..style = PaintingStyle.fill
    ..filterQuality = FilterQuality.low;

  /// The primary font family used for rendering text.
  final String fontFamily;

  /// The fallback font families.
  final List<String>? fontFamilyFallback;

  /// Enables sub-pixel bleeding to prevent gaps during fractional transformations. Defaults to kIsWeb.
  final bool enableBleed;

  /// Optional controller managing active text selection state.
  final TerminalSelectionController? selectionController;

  /// Virtual row index mapped to screen row `0` (`0` when un-scrolled or no scrollback).
  final int topVirtualRow;

  /// Optional live getter overriding [topVirtualRow] on each paint pass.
  final int Function()? topVirtualRowProvider;

  int get _effectiveTopVirtualRow =>
      topVirtualRowProvider?.call() ?? topVirtualRow;

  final math.Point<int>? _selectionStart;
  final math.Point<int>? _selectionEnd;
  final (int, int)? _selectionColBounds;

  /// Optional inclusive start coordinate `(col, row)` of an active mouse text selection.
  math.Point<int>? get selectionStart {
    if (_selectionStart != null) return _selectionStart;
    final anchor = selectionController?.anchor;
    final focus = selectionController?.focus;
    if (anchor == null || focus == null) return null;
    return math.Point<int>(anchor.col, anchor.row);
  }

  /// Optional inclusive end coordinate `(col, row)` of an active mouse text selection.
  math.Point<int>? get selectionEnd {
    if (_selectionEnd != null) return _selectionEnd;
    final anchor = selectionController?.anchor;
    final focus = selectionController?.focus;
    if (anchor == null || focus == null) return null;
    return math.Point<int>(focus.col, focus.row);
  }

  /// Optional inclusive `(minCol, maxCol)` horizontal bounds of the active selection region.
  (int, int)? get selectionColBounds {
    if (_selectionColBounds != null) return _selectionColBounds;
    final region = selectionController?.region;
    if (region == null) return null;
    return (region.minCol, region.maxCol);
  }

  /// Whether the active selection uses rectangular box mode (`Alt+Drag`).
  final bool selectionBoxMode;

  /// Optional pre-decoded GPU textures for registered [KittyImageData] entries.
  final Map<KittyImageData, ui.Image> kittyImages;

  /// Optional pre-decoded GPU textures keyed by `(KittyImageRegistry, imageId)` so resized or updated placements keep rendering on GPU within the same pane without leaking across panes.
  final Map<(KittyImageRegistry, int), ui.Image> kittyImagesById;

  /// Enables multi-cell ligatures. Defaults to false.
  final bool enableLigatures;

  /// Cache of individual [TextPainter] objects for multi-cell ligatures.
  final Map<(String, bool, bool, Color), TextPainter> ligaturePainters;

  /// Maximum entries retained in [ligaturePainters] before LRU eviction.
  static const int maxLigaturePainters = 128;

  static const int _selectionBgArgb = 0xFF264F78;
  static const int _decorationMask =
      Modifier.underline | Modifier.crossedOut | Modifier.overline;

  final HoveredLinkCellStyles _hoveredLinkStyles = HoveredLinkCellStyles();

  /// Constructs a [TuiAtlasPainter] targeting the supplied [buffer].
  TuiAtlasPainter({
    this.repaint,
    required this.buffer,
    required this.atlas,
    required this.fontFamily,
    this.fontFamilyFallback,
    required this.fallbackPainters,
    required this.onMissingGlyphs,
    this.onMissingStyledGlyphs,
    this.onBeforePaint,
    this.stagingCache,
    this.cellOverrideMask,
    this.composingPainter,
    this.enableBleed = kIsWeb,
    this.enableLigatures = false,
    Map<(String, bool, bool, Color), TextPainter>? ligaturePainters,
    this.selectionController,
    this.topVirtualRow = 0,
    this.topVirtualRowProvider,
    math.Point<int>? selectionStart,
    math.Point<int>? selectionEnd,
    (int, int)? selectionColBounds,
    this.selectionBoxMode = false,
    this.hoveredLink,
    this.hoveredLinkRowSpans,
    this.hoveredLinkStyler,
    this.kittyImages = const {},
    this.kittyImagesById = const {},
    this.defaultForegroundArgb = 0xFFFFFFFF,
    this.defaultBackgroundArgb = 0xFF000000,
    this.faintOpacity = 140 / 255,
    this.palette = TerminalColorTheme.termuiDark,
    this.activePtyCols,
    this.activePtyRows,
    this.outOfBoundsDimColor,
    this.composingText = '',
    this.cursorCol = 0,
    this.cursorRow = 0,
  }) : _selectionStart = selectionStart,
       _selectionEnd = selectionEnd,
       _selectionColBounds = selectionColBounds,
       ligaturePainters =
           ligaturePainters ?? <(String, bool, bool, Color), TextPainter>{},
       super(repaint: repaint);

  /// Active hovered link span highlighted while link-open modifiers are held.
  final ResolvedTerminalLink? hoveredLink;

  /// Optional per-row inclusive column spans for [hoveredLink].
  final List<TerminalLinkRowSpan>? hoveredLinkRowSpans;

  /// Optional client-supplied per-cell style override for [hoveredLink].
  final HoveredLinkStyler? hoveredLinkStyler;

  /// Default ARGB foreground color substituted when a cell has `fg == 0`.
  final int defaultForegroundArgb;

  /// Default ARGB background color substituted when a cell has `bg == 0`.
  final int defaultBackgroundArgb;

  /// Opacity multiplier in `(0.0, 1.0]` applied to `Modifier.dim` cells.
  final double faintOpacity;

  /// Palette used to resolve [ColorIntExtension.isAnsiIndexed] cell colors.
  final TerminalColorTheme palette;

  /// Active clamped PTY width in columns; cells at `x >= activePtyCols` are dimmed.
  final int? activePtyCols;

  /// Active clamped PTY height in rows; cells at `y >= activePtyRows` are dimmed.
  final int? activePtyRows;

  /// Optional scrim color applied over cells outside [activePtyCols] and [activePtyRows].
  final Color? outOfBoundsDimColor;

  /// Active IME pre-edit composition string rendered underlined at `(cursorCol, cursorRow)`.
  final String composingText;

  /// Zero-based cursor column where [composingText] begins.
  final int cursorCol;

  /// Zero-based cursor row where [composingText] is painted.
  final int cursorRow;

  void _drawRawAtlasInChunks(
    Canvas canvas,
    ui.Image image,
    Float32List transforms,
    Float32List rects,
    Int32List? colors,
    int totalSprites,
    Paint paint,
  ) {
    const int chunkSize = 2048;
    for (int i = 0; i < totalSprites; i += chunkSize) {
      final int end = (i + chunkSize < totalSprites)
          ? i + chunkSize
          : totalSprites;
      final Float32List transformsSub = Float32List.sublistView(
        transforms,
        i * 4,
        end * 4,
      );
      final Float32List rectsSub = Float32List.sublistView(
        rects,
        i * 4,
        end * 4,
      );
      final Int32List? colorsSub = colors != null
          ? Int32List.sublistView(colors, i, end)
          : null;

      canvas.drawRawAtlas(
        image,
        transformsSub,
        rectsSub,
        colorsSub,
        colorsSub != null ? BlendMode.modulate : BlendMode.srcOver,
        null,
        paint,
      );
    }
  }

  @override
  void paint(Canvas canvas, Size size) {
    onBeforePaint?.call();
    try {
      final cols = buffer.width;
      final rows = buffer.height;
      final count = cols * rows;
      final cache =
          stagingCache ?? (_ephemeralCache ??= TuiAtlasStagingCache());
      final internals = stagingCacheInternalsOf(cache);
      internals.ensureGridCapacity(cols, rows);

      final geo = _AtlasGeometry.fromAtlas(atlas, enableBleed: enableBleed);
      if (rows > 0 && cols > 0) {
        _prepareSelectionRows(internals, cols, rows);
        _prepareHoveredLinkRows(internals, cols, rows);
      }

      _stageGridCells(cache, internals, geo, useRowCache: stagingCache != null);

      final staged = internals.active;
      _scheduleMissingGlyphCallbacks(staged);
      _paintStagedPasses(canvas, size, geo, staged, count);
    } finally {
      _hoveredLinkStyles.clear();
    }
  }

  void _paintStagedPasses(
    Canvas canvas,
    Size size,
    _AtlasGeometry geo,
    StagingBufferSet staged,
    int count,
  ) {
    if (count > 0 && (defaultBackgroundArgb >>> 24) != 0) {
      _defaultBgPaint.color = Color(defaultBackgroundArgb);
      canvas.drawRect(
        Rect.fromLTWH(
          0.0,
          0.0,
          buffer.width * geo.cellWidth,
          buffer.height * geo.cellHeight,
        ),
        _defaultBgPaint,
      );
    }

    if (staged.bgCount > 0) {
      _drawRawAtlasInChunks(
        canvas,
        atlas.image,
        staged.bgTransforms,
        staged.bgRects,
        staged.bgColors,
        staged.bgCount,
        _atlasSpritePaint,
      );
    }

    if (staged.fgCount > 0) {
      _drawRawAtlasInChunks(
        canvas,
        atlas.image,
        staged.fgTransforms,
        staged.fgRects,
        staged.fgColors,
        staged.fgCount,
        _atlasSpritePaint,
      );
    }

    if (staged.emojiCount > 0) {
      _drawRawAtlasInChunks(
        canvas,
        atlas.image,
        staged.emojiTransforms,
        staged.emojiRects,
        null,
        staged.emojiCount,
        _emojiSpritePaint,
      );
    }

    if (staged.italicCount > 0) {
      _paintItalicAtlasCells(canvas, staged, geo);
    }

    if (staged.fallbackCount > 0) {
      _paintFallbackCells(canvas, staged);
    }

    if (staged.ligatureCount > 0) {
      _paintLigatureCells(canvas, staged);
    }

    if (staged.decoCount > 0) {
      _drawRawAtlasInChunks(
        canvas,
        atlas.image,
        staged.decoTransforms,
        staged.decoRects,
        staged.decoColors,
        staged.decoCount,
        _atlasSpritePaint,
      );
    }

    if (activePtyCols != null || activePtyRows != null) {
      _paintOutOfBoundsDimming(canvas, size, geo);
    }

    if (composingText.isNotEmpty) {
      _paintComposingOverlay(canvas, size, geo);
    }
  }

  void _prepareSelectionRows(
    StagingCacheInternals internals,
    int cols,
    int rows,
  ) {
    final starts = internals.rowSelStart;
    final ends = internals.rowSelEnd;
    final hashes = internals.rowSelHash;
    final ctrl = selectionController;
    if (ctrl != null) {
      _fillControllerSelectionRows(ctrl, starts, ends, hashes, cols, rows);
      return;
    }
    final a = _selectionStart;
    final b = _selectionEnd;
    if (a == null || b == null) {
      starts.fillRange(0, rows, -1);
      ends.fillRange(0, rows, -2);
      hashes.fillRange(0, rows, 0);
      return;
    }
    _fillManualSelectionRows(a, b, starts, ends, hashes, cols, rows);
  }

  void _fillControllerSelectionRows(
    TerminalSelectionController ctrl,
    Int32List starts,
    Int32List ends,
    Int32List hashes,
    int cols,
    int rows,
  ) {
    final a = ctrl.anchor;
    final b = ctrl.focus;
    if (a == null || b == null) {
      starts.fillRange(0, rows, -1);
      ends.fillRange(0, rows, -2);
      hashes.fillRange(0, rows, 0);
      return;
    }
    final topVirtual = _effectiveTopVirtualRow;
    final region = ctrl.region;
    final minCol = region != null ? math.max(0, region.minCol) : 0;
    final maxCol = region != null
        ? math.min(cols - 1, region.maxCol)
        : (cols - 1);
    final mode = ctrl.mode;
    final (start, end) = (a.row < b.row || (a.row == b.row && a.col <= b.col))
        ? (a, b)
        : (b, a);
    final minSelRow = math.min(a.row, b.row);
    final maxSelRow = math.max(a.row, b.row);

    for (var y = 0; y < rows; y++) {
      final vy = y + topVirtual;
      final inRegion =
          region == null || (vy >= region.minRow && vy <= region.maxRow);
      if (!inRegion || vy < minSelRow || vy > maxSelRow || minCol > maxCol) {
        starts[y] = -1;
        ends[y] = -2;
        hashes[y] = 0;
        continue;
      }
      final (rawStart, rawEnd) = _controllerRowColBounds(
        mode,
        vy,
        a,
        b,
        start,
        end,
        minCol,
        maxCol,
      );
      _recordRowSelectionSpan(starts, ends, hashes, y, rawStart, rawEnd, cols);
    }
  }

  static (int, int) _controllerRowColBounds(
    SelectionMode mode,
    int vy,
    SelectionPoint a,
    SelectionPoint b,
    SelectionPoint start,
    SelectionPoint end,
    int minCol,
    int maxCol,
  ) => switch (mode) {
    SelectionMode.block => (
      math.max(minCol, math.min(a.col, b.col)),
      math.min(maxCol, math.max(a.col, b.col)),
    ),
    SelectionMode.line => (minCol, maxCol),
    SelectionMode.character || SelectionMode.word => _streamRowBounds(
      vy,
      start.row,
      start.col,
      end.row,
      end.col,
      minCol,
      maxCol,
    ),
  };

  static (int, int) _streamRowBounds(
    int row,
    int startRow,
    int startCol,
    int endRow,
    int endCol,
    int minCol,
    int maxCol,
  ) {
    if (startRow == endRow) {
      return (math.max(minCol, startCol), math.min(maxCol, endCol));
    }
    if (row == startRow) return (math.max(minCol, startCol), maxCol);
    if (row == endRow) return (minCol, math.min(maxCol, endCol));
    return (minCol, maxCol);
  }

  void _fillManualSelectionRows(
    math.Point<int> a,
    math.Point<int> b,
    Int32List starts,
    Int32List ends,
    Int32List hashes,
    int cols,
    int rows,
  ) {
    final (start, end) = (a.y < b.y || (a.y == b.y && a.x <= b.x))
        ? (a, b)
        : (b, a);
    final minCol = _selectionColBounds?.$1 ?? 0;
    final maxCol = _selectionColBounds?.$2 ?? (cols - 1);
    final boxOrSingleRow = selectionBoxMode || start.y == end.y;
    final boxMinX = math.min(start.x, end.x);
    final boxMaxX = math.max(start.x, end.x);

    for (var y = 0; y < rows; y++) {
      if (y < start.y || y > end.y) {
        starts[y] = -1;
        ends[y] = -2;
        hashes[y] = 0;
        continue;
      }
      final (rawStart, rawEnd) = boxOrSingleRow
          ? (boxMinX, boxMaxX)
          : _streamRowBounds(y, start.y, start.x, end.y, end.x, minCol, maxCol);
      _recordRowSelectionSpan(starts, ends, hashes, y, rawStart, rawEnd, cols);
    }
  }

  static void _recordRowSelectionSpan(
    Int32List starts,
    Int32List ends,
    Int32List hashes,
    int row,
    int rawStart,
    int rawEnd,
    int cols,
  ) {
    final cs = rawStart < 0 ? 0 : rawStart;
    final ce = rawEnd >= cols ? cols - 1 : rawEnd;
    if (cs > ce) {
      starts[row] = -1;
      ends[row] = -2;
      hashes[row] = 0;
      return;
    }
    starts[row] = cs;
    ends[row] = ce;
    hashes[row] = ((cs + 1) << 16) | ((ce + 1) & 0xFFFF);
  }

  void _prepareHoveredLinkRows(
    StagingCacheInternals internals,
    int cols,
    int rows,
  ) {
    final starts = internals.rowLinkStart;
    final ends = internals.rowLinkEnd;
    final offsets = internals.rowLinkBaseOffset;
    final hashes = internals.rowLinkHash;
    starts.fillRange(0, rows, -1);
    ends.fillRange(0, rows, -2);
    offsets.fillRange(0, rows, 0);
    for (var y = 0; y < rows; y++) {
      hashes[y] = 0;
    }

    final link = hoveredLink;
    if (link == null) {
      _hoveredLinkStyles.clear();
      return;
    }

    final cellCount = hoveredLinkRowSpans != null
        ? _populateExplicitLinkRowSpans(
            hoveredLinkRowSpans!,
            starts,
            ends,
            offsets,
            cols,
            rows,
          )
        : _populateLinearLinkRowSpans(link, starts, ends, offsets, cols, rows);

    if (cellCount <= 0) {
      _hoveredLinkStyles.clear();
      return;
    }

    _invokeHoveredLinkStyler(link, cellCount);
    for (var y = 0; y < rows; y++) {
      if (starts[y] >= 0) {
        hashes[y] = _computeHoveredLinkRowHash(starts[y], ends[y], offsets[y]);
      }
    }
  }

  int _populateExplicitLinkRowSpans(
    List<TerminalLinkRowSpan> rowSpans,
    Int32List starts,
    Int32List ends,
    Int32List offsets,
    int cols,
    int rows,
  ) {
    var offset = 0;
    for (final span in rowSpans) {
      if (span.row < 0 || span.row >= rows) continue;
      if (span.startCol >= cols || span.endCol < 0) continue;
      final startCol = span.startCol.clamp(0, cols - 1);
      final endCol = span.endCol.clamp(0, cols - 1);
      if (endCol < startCol) continue;
      starts[span.row] = startCol;
      ends[span.row] = endCol;
      offsets[span.row] = offset;
      offset += endCol - startCol + 1;
    }
    return offset;
  }

  int _populateLinearLinkRowSpans(
    ResolvedTerminalLink link,
    Int32List starts,
    Int32List ends,
    Int32List offsets,
    int cols,
    int rows,
  ) {
    if (link.endRow < 0 || link.startRow >= rows) return 0;
    if (link.startRow == link.endRow &&
        (link.startCol >= cols || link.endCol < 0)) {
      return 0;
    }
    final startRow = link.startRow < 0 ? 0 : link.startRow;
    final startCol = link.startRow < 0 ? 0 : link.startCol.clamp(0, cols - 1);
    final endRow = link.endRow >= rows ? rows - 1 : link.endRow;
    final endCol = link.endRow >= rows
        ? cols - 1
        : link.endCol.clamp(0, cols - 1);
    final startIdx = startRow * cols + startCol;
    final endIdx = endRow * cols + endCol;
    if (endIdx < startIdx) return 0;

    var offset = 0;
    for (var y = startRow; y <= endRow; y++) {
      final rowStartCol = y == startRow ? startCol : 0;
      final rowEndCol = y == endRow ? endCol : cols - 1;
      starts[y] = rowStartCol;
      ends[y] = rowEndCol;
      offsets[y] = offset;
      offset += rowEndCol - rowStartCol + 1;
    }
    return endIdx - startIdx + 1;
  }

  void _invokeHoveredLinkStyler(ResolvedTerminalLink link, int cellCount) {
    final styler = hoveredLinkStyler;
    if (styler == null) {
      _hoveredLinkStyles.clear();
      return;
    }
    _hoveredLinkStyles.reset(cellCount);
    try {
      styler(link, cellCount, clock.now(), _hoveredLinkStyles);
    } on Object catch (error, stackTrace) {
      _hoveredLinkStyles.clear();
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: stackTrace,
          library: 'termui_flutter',
          context: ErrorDescription('while invoking hoveredLinkStyler'),
        ),
      );
    }
  }

  int _computeHoveredLinkRowHash(int startCol, int endCol, int baseOffset) {
    var h = TuiAtlasStagingCache.mixPair(0x517CC1B7, startCol, endCol);
    h = TuiAtlasStagingCache.mixWord(h, baseOffset);
    final styles = _hoveredLinkStyles;
    if (styles.length <= 0) {
      return TuiAtlasStagingCache.finalizeHash(h);
    }
    final count = endCol - startCol + 1;
    for (var i = 0; i < count; i++) {
      final idx = baseOffset + i;
      final fg = styles.foregroundAt(idx);
      final bg = styles.backgroundAt(idx);
      final ul = styles.underlineColorAt(idx);
      final mods = styles.modifiersAt(idx);
      final presence =
          (fg != null ? 1 : 0) |
          (bg != null ? 2 : 0) |
          (ul != null ? 4 : 0) |
          (mods != null ? 8 : 0);
      h = TuiAtlasStagingCache.mixWord(h, presence);
      if (presence != 0) {
        h = TuiAtlasStagingCache.mixPair(h, fg ?? 0, bg ?? 0);
        h = TuiAtlasStagingCache.mixPair(h, ul ?? 0, mods ?? 0);
      }
    }
    return TuiAtlasStagingCache.finalizeHash(h);
  }

  int _computeConfigHash(StagingCacheInternals internals) {
    var h = TuiAtlasStagingCache.mixPair(
      0x9E3779B9,
      identityHashCode(atlas),
      identityHashCode(atlas.image),
    );
    h = TuiAtlasStagingCache.mixPair(
      h,
      defaultForegroundArgb,
      defaultBackgroundArgb,
    );
    h = TuiAtlasStagingCache.mixPair(
      h,
      faintOpacity.hashCode,
      internals.hashPalette(palette),
    );
    h = TuiAtlasStagingCache.mixPair(
      h,
      fontFamily.hashCode,
      internals.hashFontFallback(fontFamilyFallback),
    );
    h = TuiAtlasStagingCache.mixWord(
      h,
      (enableBleed ? 1 : 0) | (enableLigatures ? 2 : 0),
    );
    return TuiAtlasStagingCache.finalizeHash(h);
  }

  void _stageGridCells(
    TuiAtlasStagingCache cache,
    StagingCacheInternals internals,
    _AtlasGeometry geo, {
    required bool useRowCache,
  }) {
    final cols = buffer.width;
    final rows = buffer.height;
    if (cols <= 0 || rows <= 0) {
      internals.active.resetCounts();
      internals.recordAllHits(0);
      return;
    }

    if (!useRowCache) {
      internals.invalidateAllRows();
    }

    final configHash = _computeConfigHash(internals);
    final (firstDirty, lastClean, hits) = _evaluateRowFingerprints(
      cache,
      internals,
      cols,
      rows,
      configHash,
    );

    if (firstDirty == rows) {
      internals.recordAllHits(rows);
      return;
    }

    if (lastClean < firstDirty) {
      final dst = internals.beginTailUpdate(firstDirty);
      for (var y = firstDirty; y < rows; y++) {
        _stageRow(dst, internals, y, cols, geo);
      }
    } else {
      final dst = internals.beginCompaction();
      _compactAndStageRows(dst, internals.active, internals, cols, rows, geo);
      internals.finishCompaction();
    }

    internals.commitFrame(rows, hits, rows - hits);
  }

  (int firstDirty, int lastClean, int hits) _evaluateRowFingerprints(
    TuiAtlasStagingCache cache,
    StagingCacheInternals internals,
    int cols,
    int rows,
    int configHash,
  ) {
    final trackBleed = enableBleed && (defaultBackgroundArgb >>> 24) == 0xFF;
    final rowSelHashes = internals.rowSelHash;
    final rowLinkHashes = internals.rowLinkHash;
    final rowIsClean = internals.rowIsClean;
    final nextFull = internals.nextFullFingerprints;
    final nextContent = internals.nextContentFingerprints;

    var firstDirty = rows;
    var lastClean = -1;
    var hits = 0;
    var prevBgMaskHash = 0;

    for (var y = 0; y < rows; y++) {
      final contentFp = cache.computeRowFingerprint(
        buffer: buffer,
        row: y,
        selectionHash: rowSelHashes[y],
        hoveredLinkHash: rowLinkHashes[y],
        configHash: configHash,
        cellOverrideMask: cellOverrideMask,
        mixCellUris: enableLigatures,
      );
      final fullFp = trackBleed && prevBgMaskHash != 0
          ? TuiAtlasStagingCache.finalizeHash(
              TuiAtlasStagingCache.mixWord(contentFp, prevBgMaskHash),
            )
          : contentFp;
      nextContent[y] = contentFp;
      nextFull[y] = fullFp;

      final isClean = internals.isRowClean(y, fullFp);
      rowIsClean[y] = isClean ? 1 : 0;
      if (isClean) {
        hits++;
        lastClean = y;
      } else if (firstDirty == rows) {
        firstDirty = y;
      }

      if (trackBleed) {
        prevBgMaskHash = _resolveRowBgMaskHash(internals, y, cols, contentFp);
      }
    }
    return (firstDirty, lastClean, hits);
  }

  int _resolveRowBgMaskHash(
    StagingCacheInternals internals,
    int row,
    int cols,
    int contentFp,
  ) {
    if (internals.isRowContentClean(row, contentFp)) {
      return internals.rowBgMaskHashes[row];
    }
    final bgMaskHash = _updateRowNonDefaultBgMask(internals, row, cols);
    internals.rowBgMaskHashes[row] = bgMaskHash;
    return bgMaskHash;
  }

  int _updateRowNonDefaultBgMask(
    StagingCacheInternals internals,
    int row,
    int cols,
  ) {
    final codes = buffer.glyphCodes;
    final glyphCells = buffer.glyphCellList;
    final attrs = buffer.attributes;
    final mask = internals.nonDefaultBgMask;
    final selStart = internals.rowSelStart[row];
    final selEnd = internals.rowSelEnd[row];
    final linkStart = internals.rowLinkStart[row];
    final linkEnd = internals.rowLinkEnd[row];
    final linkBase = internals.rowLinkBaseOffset[row];
    final rowStart = row * cols;

    var hash = 0;
    for (var x = 0; x < cols; x++) {
      final idx = rowStart + x;
      final attrBase = idx * 3;
      final fgArgb = attrs[attrBase];
      final bgArgb = attrs[attrBase + 1];
      final modifiers = attrs[attrBase + 2];
      final isKitty = _isKittyCode(codes[idx], modifiers, glyphCells);
      final isReverse = !isKitty && Modifier.has(modifiers, Modifier.reverse);
      final isSelected = !isKitty && x >= selStart && x <= selEnd;
      final linkIdx =
          (!isKitty && !isSelected && x >= linkStart && x <= linkEnd)
          ? linkBase + (x - linkStart)
          : -1;
      final resolvedBg =
          (linkIdx >= 0 ? _hoveredLinkStyles.backgroundAt(linkIdx) : null) ??
          _resolveBgColor(
            bgArgb,
            fgArgb,
            isReverse: isReverse,
            isSelected: isSelected,
          );
      final isNonDefault = resolvedBg != defaultBackgroundArgb;
      mask[idx] = isNonDefault ? 1 : 0;
      if (isNonDefault) {
        hash = TuiAtlasStagingCache.mixWord(hash, x + 1);
      }
    }
    return hash == 0 ? 0 : TuiAtlasStagingCache.finalizeHash(hash);
  }

  void _compactAndStageRows(
    StagingBufferSet dst,
    StagingBufferSet src,
    StagingCacheInternals internals,
    int cols,
    int rows,
    _AtlasGeometry geo,
  ) {
    final rowIsClean = internals.rowIsClean;
    var y = 0;
    while (y < rows) {
      if (rowIsClean[y] != 0) {
        final runStart = y;
        do {
          y++;
        } while (y < rows && rowIsClean[y] != 0);
        dst.copyCleanRowRange(src, runStart, y);
      } else {
        _stageRow(dst, internals, y, cols, geo);
        y++;
      }
    }
  }

  void _stageRow(
    StagingBufferSet dst,
    StagingCacheInternals internals,
    int y,
    int cols,
    _AtlasGeometry geo,
  ) {
    dst.beginRow(y);
    final codes = buffer.glyphCodes;
    final glyphCells = buffer.glyphCellList;
    final attrs = buffer.attributes;
    final screenY = y * geo.cellHeight;
    final rowStart = y * cols;
    final selStart = internals.rowSelStart[y];
    final selEnd = internals.rowSelEnd[y];
    final linkStart = internals.rowLinkStart[y];
    final linkEnd = internals.rowLinkEnd[y];
    final linkBase = internals.rowLinkBaseOffset[y];
    final overrideMask = cellOverrideMask;
    final maskLen = overrideMask?.length ?? 0;

    var x = 0;
    while (x < cols) {
      if (enableLigatures) {
        final lig = _detectLigature(
          x,
          y,
          rowStart,
          cols,
          codes,
          attrs,
          selStart,
          selEnd,
          linkStart,
          linkEnd,
          overrideMask,
          maskLen,
        );
        if (lig != null) {
          _stageLigatureRun(
            dst,
            internals,
            lig.$1,
            lig.$2,
            x,
            y,
            rowStart,
            screenY,
            geo,
            selStart,
            selEnd,
          );
          x += lig.$2;
          continue;
        }
      }

      final idx = rowStart + x;
      final isOverridden =
          overrideMask != null && idx < maskLen && overrideMask[idx] != 0;
      _stageSingleCell(
        dst,
        internals,
        x,
        y,
        idx,
        codes,
        glyphCells,
        attrs,
        screenY,
        geo,
        selStart: selStart,
        selEnd: selEnd,
        linkStart: linkStart,
        linkEnd: linkEnd,
        linkBase: linkBase,
        isOverridden: isOverridden,
      );
      x++;
    }
    dst.endRow(y);
  }

  @pragma('vm:prefer-inline')
  bool _isKittyCode(int code, int modifiers, GlyphCellList glyphCells) {
    if (Modifier.has(modifiers, Modifier.kittyPlaceholder) ||
        code == kittyPlaceholderCodePoint) {
      return true;
    }
    if ((code & GlyphCellList.clusterFlag) == 0) return false;
    final char = glyphCells.decodeCode(code);
    return char.length >= 2 && char.startsWith(kittyPlaceholderChar);
  }

  bool _isKittyCell(String char, int modifiers) =>
      Modifier.has(modifiers, Modifier.kittyPlaceholder) ||
      (char.length >= 2 && char.startsWith(kittyPlaceholderChar));

  void _stageSingleCell(
    StagingBufferSet dst,
    StagingCacheInternals internals,
    int x,
    int y,
    int idx,
    Uint32List codes,
    GlyphCellList glyphCells,
    Uint32List attrs,
    double screenY,
    _AtlasGeometry geo, {
    required int selStart,
    required int selEnd,
    required int linkStart,
    required int linkEnd,
    required int linkBase,
    required bool isOverridden,
  }) {
    final code = codes[idx];
    final attrBase = idx * 3;
    final fgArgb = attrs[attrBase];
    final bgArgb = attrs[attrBase + 1];
    final modifiers = attrs[attrBase + 2];
    final isKitty = _isKittyCode(code, modifiers, glyphCells);
    final isReverse = !isKitty && Modifier.has(modifiers, Modifier.reverse);
    final isSelected = !isKitty && x >= selStart && x <= selEnd;
    final linkIdx = (!isKitty && !isSelected && x >= linkStart && x <= linkEnd)
        ? linkBase + (x - linkStart)
        : -1;
    final isHoveredLink = linkIdx >= 0;
    final screenX = x * geo.cellWidth;

    final resolvedBg =
        (isHoveredLink ? _hoveredLinkStyles.backgroundAt(linkIdx) : null) ??
        _resolveBgColor(
          bgArgb,
          fgArgb,
          isReverse: isReverse,
          isSelected: isSelected,
        );
    _stageBackgroundSprite(
      dst,
      internals,
      x,
      y,
      idx,
      buffer.width,
      screenX,
      screenY,
      resolvedBg,
      geo,
    );

    if (isOverridden ||
        (Modifier.has(modifiers, Modifier.hidden) && !isSelected)) {
      return;
    }

    final resolvedFg =
        (isHoveredLink ? _hoveredLinkStyles.foregroundAt(linkIdx) : null) ??
        _resolveFgColor(
          fgArgb,
          bgArgb,
          modifiers: modifiers,
          isReverse: isReverse,
          isSelected: isSelected,
        );
    final effectiveModifiers = isHoveredLink
        ? (modifiers |
              (_hoveredLinkStyles.modifiersAt(linkIdx) ?? Modifier.underline))
        : modifiers;

    if (code != GlyphCellList.wideContinuationCode &&
        code != GlyphCellList.spaceCode) {
      _stageForegroundCode(
        dst,
        code: code,
        glyphCells: glyphCells,
        gridCol: x,
        gridRow: y,
        modifiers: effectiveModifiers,
        fgArgb: fgArgb,
        bgArgb: bgArgb,
        resolvedFg: resolvedFg,
        screenX: screenX,
        screenY: screenY,
        geo: geo,
      );
    }

    if ((effectiveModifiers & _decorationMask) != 0) {
      _stageCodeDecorations(
        dst,
        code: code,
        glyphCells: glyphCells,
        cellIdx: idx,
        screenX: screenX,
        screenY: screenY,
        modifiers: effectiveModifiers,
        resolvedFg: resolvedFg,
        linkIdx: linkIdx,
        geo: geo,
      );
    }
  }

  void _stageCodeDecorations(
    StagingBufferSet dst, {
    required int code,
    required GlyphCellList glyphCells,
    required int cellIdx,
    required double screenX,
    required double screenY,
    required int modifiers,
    required int resolvedFg,
    required int linkIdx,
    required _AtlasGeometry geo,
  }) {
    if (code == GlyphCellList.wideContinuationCode) return;
    final isWide = (code & GlyphCellList.clusterFlag) == 0
        ? isWideCodePoint(code)
        : isWideGrapheme(glyphCells.decodeCode(code));
    _stageCellDecorations(
      dst,
      cellIdx: cellIdx,
      isWide: isWide,
      screenX: screenX,
      screenY: screenY,
      modifiers: modifiers,
      resolvedFg: resolvedFg,
      overrideUlArgb: linkIdx >= 0
          ? _hoveredLinkStyles.underlineColorAt(linkIdx)
          : null,
      geo: geo,
    );
  }

  (String, int)? _detectLigature(
    int startX,
    int y,
    int rowStart,
    int cols,
    Uint32List codes,
    Uint32List attrs,
    int selStart,
    int selEnd,
    int linkStart,
    int linkEnd,
    Uint8List? overrideMask,
    int maskLen,
  ) {
    if (startX + 1 >= cols) return null;
    final firstIdx = rowStart + startX;
    if (!_isLigatureCode(codes[firstIdx])) return null;
    if (overrideMask != null &&
        firstIdx < maskLen &&
        overrideMask[firstIdx] != 0) {
      return null;
    }
    if (startX >= linkStart && startX <= linkEnd) return null;

    final maxLen = math.min(4, cols - startX);
    for (var len = maxLen; len >= 2; len--) {
      final match = _checkLigatureCandidate(
        startX,
        rowStart,
        len,
        codes,
        attrs,
        selStart,
        selEnd,
        linkStart,
        linkEnd,
        overrideMask,
        maskLen,
      );
      if (match != null) return (match, len);
    }
    return null;
  }

  String? _checkLigatureCandidate(
    int startX,
    int rowStart,
    int len,
    Uint32List codes,
    Uint32List attrs,
    int selStart,
    int selEnd,
    int linkStart,
    int linkEnd,
    Uint8List? overrideMask,
    int maskLen,
  ) {
    final firstIdx = rowStart + startX;
    final firstAttr = firstIdx * 3;
    final firstMods = attrs[firstAttr + 2];
    final firstSelected = startX >= selStart && startX <= selEnd;
    if (Modifier.has(firstMods, Modifier.hidden) && !firstSelected) {
      return null;
    }

    final firstFg = attrs[firstAttr];
    final firstBg = attrs[firstAttr + 1];
    final hasUl = buffer.hasUnderlineColors;
    final hasUris = buffer.hasUris;
    final firstUl = hasUl ? buffer.getUnderlineColorAt(firstIdx) : 0;
    final firstUri = hasUris ? buffer.getUriAt(firstIdx) : null;

    for (var i = 1; i < len; i++) {
      final curX = startX + i;
      final curIdx = rowStart + curX;
      if (!_isLigatureCellEligible(
        curX,
        curIdx,
        codes,
        attrs,
        firstFg,
        firstBg,
        firstMods,
        firstUl,
        firstUri,
        firstSelected,
        selStart,
        selEnd,
        linkStart,
        linkEnd,
        overrideMask,
        maskLen,
        hasUl: hasUl,
        hasUris: hasUris,
      )) {
        return null;
      }
    }

    final text = String.fromCharCodes(codes, firstIdx, firstIdx + len);
    return _knownLigatures.contains(text) ? text : null;
  }

  bool _isLigatureCellEligible(
    int x,
    int idx,
    Uint32List codes,
    Uint32List attrs,
    int firstFg,
    int firstBg,
    int firstMods,
    int firstUl,
    String? firstUri,
    bool firstSelected,
    int selStart,
    int selEnd,
    int linkStart,
    int linkEnd,
    Uint8List? overrideMask,
    int maskLen, {
    required bool hasUl,
    required bool hasUris,
  }) {
    if (x >= linkStart && x <= linkEnd) return false;
    if (overrideMask != null && idx < maskLen && overrideMask[idx] != 0) {
      return false;
    }
    if (!_isLigatureCode(codes[idx])) return false;
    final attrBase = idx * 3;
    if (attrs[attrBase] != firstFg ||
        attrs[attrBase + 1] != firstBg ||
        attrs[attrBase + 2] != firstMods) {
      return false;
    }
    if ((x >= selStart && x <= selEnd) != firstSelected) return false;
    if (hasUl && buffer.getUnderlineColorAt(idx) != firstUl) return false;
    if (hasUris && buffer.getUriAt(idx) != firstUri) return false;
    return true;
  }

  void _stageLigatureRun(
    StagingBufferSet dst,
    StagingCacheInternals internals,
    String text,
    int len,
    int startX,
    int y,
    int rowStart,
    double screenY,
    _AtlasGeometry geo,
    int selStart,
    int selEnd,
  ) {
    final firstIdx = rowStart + startX;
    final attrs = buffer.attributes;
    final firstAttr = firstIdx * 3;
    final firstFg = attrs[firstAttr];
    final firstBg = attrs[firstAttr + 1];
    final firstMods = attrs[firstAttr + 2];
    final isReverse = Modifier.has(firstMods, Modifier.reverse);
    final isSelected = startX >= selStart && startX <= selEnd;
    final resolvedBg = _resolveBgColor(
      firstBg,
      firstFg,
      isReverse: isReverse,
      isSelected: isSelected,
    );

    final resolvedFg = _resolveFgColor(
      firstFg,
      firstBg,
      modifiers: firstMods,
      isReverse: isReverse,
      isSelected: isSelected,
    );

    final isBold = Modifier.has(firstMods, Modifier.bold);
    final isItalic = Modifier.has(firstMods, Modifier.italic);
    final atlasRect = atlas.rectFor(text, isBold: isBold, isItalic: isItalic);
    if (atlasRect != null) {
      _stageQuadTextSprite(
        dst,
        screenX: startX * geo.cellWidth,
        screenY: screenY,
        l: atlasRect.left,
        t: atlasRect.top,
        r: atlasRect.right,
        b: atlasRect.bottom,
        fgColor: resolvedFg,
        geo: geo,
        isProceduralBlock: false,
        needsOverhang: _needsGlyphOverhang(
          text,
          isBold: isBold,
          isItalic: isItalic,
        ),
      );
    } else {
      dst.addLigatureCell(
        text: text,
        x: startX * geo.cellWidth,
        y: screenY,
        w: len * geo.cellWidth,
        h: geo.cellHeight,
        resolvedFg: resolvedFg,
        isBold: isBold,
        isItalic: isItalic,
      );
    }

    final hasDecorations = (firstMods & _decorationMask) != 0;
    for (var i = 0; i < len; i++) {
      final x = startX + i;
      final idx = rowStart + x;
      final screenX = x * geo.cellWidth;
      _stageBackgroundSprite(
        dst,
        internals,
        x,
        y,
        idx,
        buffer.width,
        screenX,
        screenY,
        resolvedBg,
        geo,
      );
      if (hasDecorations) {
        _stageCellDecorations(
          dst,
          cellIdx: idx,
          isWide: false,
          screenX: screenX,
          screenY: screenY,
          modifiers: firstMods,
          resolvedFg: resolvedFg,
          geo: geo,
        );
      }
    }
  }

  TextPainter _getLigaturePainter(
    String text,
    bool isBold,
    bool isItalic,
    Color color,
  ) {
    final key = (text, isBold, isItalic, color);
    final existing = ligaturePainters.remove(key);
    if (existing != null) {
      ligaturePainters[key] = existing;
      return existing;
    }
    while (ligaturePainters.length >= maxLigaturePainters) {
      final oldestKey = ligaturePainters.keys.first;
      ligaturePainters.remove(oldestKey)?.dispose();
    }

    final painter = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          fontFamily: fontFamily,
          fontFamilyFallback: fontFamilyFallback,
          fontFeatures: const [
            ui.FontFeature.enable('liga'),
            ui.FontFeature.enable('calt'),
            ui.FontFeature.enable('dlig'),
          ],
          fontSize: atlas.fontSize,
          color: color,
          fontWeight: isBold ? FontWeight.bold : FontWeight.normal,
          fontStyle: isItalic ? FontStyle.italic : FontStyle.normal,
          letterSpacing: 0.0,
          height: 1.0,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    ligaturePainters[key] = painter;
    return painter;
  }

  void _stageCellDecorations(
    StagingBufferSet dst, {
    required int cellIdx,
    required bool isWide,
    required double screenX,
    required double screenY,
    required int modifiers,
    required int resolvedFg,
    int? overrideUlArgb,
    required _AtlasGeometry geo,
  }) {
    if (Modifier.has(modifiers, Modifier.overline)) {
      _stageDecorationSprite(
        dst,
        AtlasDecorationKind.overline,
        isWide: isWide,
        screenX: screenX,
        screenY: screenY,
        colorArgb: resolvedFg,
        geo: geo,
      );
    }
    if (Modifier.has(modifiers, Modifier.crossedOut)) {
      _stageDecorationSprite(
        dst,
        AtlasDecorationKind.strikethrough,
        isWide: isWide,
        screenX: screenX,
        screenY: screenY,
        colorArgb: resolvedFg,
        geo: geo,
      );
    }
    if (!Modifier.has(modifiers, Modifier.underline)) return;
    final ulKind = _underlineKindForStyle(
      Modifier.getUnderlineStyle(modifiers),
    );
    if (ulKind == null) return;
    final resolvedUl = _resolveUnderlineColor(
      cellIdx,
      resolvedFg,
      overrideUlArgb,
    );
    _stageDecorationSprite(
      dst,
      ulKind,
      isWide: isWide,
      screenX: screenX,
      screenY: screenY,
      colorArgb: resolvedUl,
      geo: geo,
    );
  }

  int _resolveUnderlineColor(int cellIdx, int resolvedFg, int? overrideUlArgb) {
    if (overrideUlArgb != null) return overrideUlArgb;
    if (!buffer.hasUnderlineColors) return resolvedFg;
    final ulArgb = buffer.getUnderlineColorAt(cellIdx);
    return ulArgb != 0 ? palette.resolvePackedColor(ulArgb) : resolvedFg;
  }

  void _stageDecorationSprite(
    StagingBufferSet dst,
    AtlasDecorationKind kind, {
    required bool isWide,
    required double screenX,
    required double screenY,
    required int colorArgb,
    required _AtlasGeometry geo,
  }) {
    final quadTable = atlas.quadTable;
    final quadOffset = quadTable.decorationQuadOffset(kind, isWide: isWide);
    if (quadOffset >= 0) {
      final quads = quadTable.ltrbQuads;
      dst.addDecoSprite(
        geo.fgScaleBlock,
        screenX,
        screenY,
        quads[quadOffset],
        quads[quadOffset + 1],
        quads[quadOffset + 2],
        quads[quadOffset + 3],
        colorArgb,
      );
      return;
    }
    _stageFallbackDecorationStrip(
      dst,
      kind,
      isWide: isWide,
      screenX: screenX,
      screenY: screenY,
      colorArgb: colorArgb,
      geo: geo,
    );
  }

  void _stageFallbackDecorationStrip(
    StagingBufferSet dst,
    AtlasDecorationKind kind, {
    required bool isWide,
    required double screenX,
    required double screenY,
    required int colorArgb,
    required _AtlasGeometry geo,
  }) {
    final stripBottom = math.min(
      geo.whiteRect3,
      geo.whiteRect1 + geo.devicePixelRatio,
    );
    final yOffset = switch (kind) {
      AtlasDecorationKind.overline => 0.0,
      AtlasDecorationKind.strikethrough =>
        (geo.cellHeight * 0.5).floorToDouble(),
      AtlasDecorationKind.underlineDouble => geo.cellHeight - 3.0,
      AtlasDecorationKind.underlineSingle ||
      AtlasDecorationKind.underlineCurly ||
      AtlasDecorationKind.underlineDotted ||
      AtlasDecorationKind.underlineDashed => geo.cellHeight - 2.0,
    };
    _emitWhiteStrip(
      dst,
      screenX,
      screenY + yOffset,
      stripBottom,
      colorArgb,
      geo,
      isWide: isWide,
    );
    if (kind == AtlasDecorationKind.underlineDouble) {
      _emitWhiteStrip(
        dst,
        screenX,
        screenY + geo.cellHeight - 1.0,
        stripBottom,
        colorArgb,
        geo,
        isWide: isWide,
      );
    }
  }

  void _emitWhiteStrip(
    StagingBufferSet dst,
    double screenX,
    double screenY,
    double stripBottom,
    int colorArgb,
    _AtlasGeometry geo, {
    required bool isWide,
  }) {
    dst.addDecoSprite(
      geo.fgScaleBlock,
      screenX,
      screenY,
      geo.whiteRect0,
      geo.whiteRect1,
      geo.whiteRect2,
      stripBottom,
      colorArgb,
    );
    if (isWide) {
      dst.addDecoSprite(
        geo.fgScaleBlock,
        screenX + geo.cellWidth,
        screenY,
        geo.whiteRect0,
        geo.whiteRect1,
        geo.whiteRect2,
        stripBottom,
        colorArgb,
      );
    }
  }

  static bool _hasNonDefaultBgPredecessor(
    Uint8List mask,
    int x,
    int y,
    int idx,
    int cols,
  ) {
    if (x > 0 && mask[idx - 1] != 0) return true;
    if (y == 0) return false;
    final prevRowIdx = idx - cols;
    if (mask[prevRowIdx] != 0) return true;
    if (x > 0 && mask[prevRowIdx - 1] != 0) return true;
    return x + 1 < cols && mask[prevRowIdx + 1] != 0;
  }

  void _stageBackgroundSprite(
    StagingBufferSet dst,
    StagingCacheInternals internals,
    int x,
    int y,
    int idx,
    int cols,
    double screenX,
    double screenY,
    int bgColor,
    _AtlasGeometry geo,
  ) {
    final isNonDefault = bgColor != defaultBackgroundArgb;
    if (!isNonDefault) {
      if (!enableBleed ||
          (defaultBackgroundArgb >>> 24) != 0xFF ||
          !_hasNonDefaultBgPredecessor(
            internals.nonDefaultBgMask,
            x,
            y,
            idx,
            cols,
          )) {
        return;
      }
    }

    dst.addBgSprite(
      geo.bgScaleBlock,
      screenX - geo.bleedBgLogical,
      screenY - geo.bleedBgLogical,
      geo.bgRect0,
      geo.bgRect1,
      geo.bgRect2,
      geo.bgRect3,
      bgColor,
    );
  }

  void _stageForegroundCode(
    StagingBufferSet dst, {
    required int code,
    required GlyphCellList glyphCells,
    required int gridCol,
    required int gridRow,
    required int modifiers,
    required int fgArgb,
    required int bgArgb,
    required int resolvedFg,
    required double screenX,
    required double screenY,
    required _AtlasGeometry geo,
  }) {
    final isBold = Modifier.has(modifiers, Modifier.bold);
    final isItalic = Modifier.has(modifiers, Modifier.italic);
    final variantBits = (isBold ? 1 : 0) | (isItalic ? 2 : 0);

    if ((code & GlyphCellList.clusterFlag) != 0) {
      _stageForegroundCluster(
        dst,
        char: glyphCells.decodeCode(code),
        gridCol: gridCol,
        gridRow: gridRow,
        modifiers: modifiers,
        fgArgb: fgArgb,
        bgArgb: bgArgb,
        resolvedFg: resolvedFg,
        screenX: screenX,
        screenY: screenY,
        geo: geo,
        isBold: isBold,
        isItalic: isItalic,
      );
      return;
    }

    final quadTable = atlas.quadTable;
    final quadOffset = quadTable.quadOffsetForCode(
      code,
      variantBits: variantBits,
    );
    if (quadOffset < 0) {
      _stageFallbackCell(
        dst,
        char: glyphCells.decodeCode(code),
        variantIndex: variantBits,
        gridCol: gridCol,
        gridRow: gridRow,
        modifiers: modifiers,
        fgArgb: fgArgb,
        bgArgb: bgArgb,
        resolvedFg: resolvedFg,
        screenX: screenX,
        screenY: screenY,
        geo: geo,
      );
      return;
    }

    final quads = quadTable.ltrbQuads;
    final l = quads[quadOffset];
    final t = quads[quadOffset + 1];
    final r = quads[quadOffset + 2];
    final b = quads[quadOffset + 3];

    if (_isColorEmojiCode(code)) {
      _stageEmojiQuad(dst, screenX, screenY, l, t, r, b, geo);
      return;
    }

    final isBlock = _isBlockCode(code);
    final hasNativeStyle =
        variantBits == 0 ||
        quadOffset != quadTable.quadOffsetForCode(code, variantBits: 0);
    if (!isBlock && !hasNativeStyle) {
      dst.addMissingStyledGlyph(glyphCells.decodeCode(code), variantBits);
    }

    if (!isBlock && isItalic && !hasNativeStyle) {
      dst.addItalicCell(
        l,
        t,
        r,
        b,
        screenX,
        screenY,
        resolvedFg,
        isBold: isBold,
      );
      return;
    }

    final isProceduralBlock = isBlock && _isProceduralCode(code);
    final needsOverhang = _needsGlyphOverhangCode(
      code,
      isBold: isBold,
      isItalic: isItalic,
    );
    _stageQuadTextSprite(
      dst,
      screenX: screenX,
      screenY: screenY,
      l: l,
      t: t,
      r: r,
      b: b,
      fgColor: resolvedFg,
      geo: geo,
      isProceduralBlock: isProceduralBlock,
      needsOverhang: needsOverhang,
    );
    if (!isBlock && isBold && !hasNativeStyle) {
      _stageQuadTextSprite(
        dst,
        screenX: screenX + 0.6,
        screenY: screenY,
        l: l,
        t: t,
        r: r,
        b: b,
        fgColor: resolvedFg,
        geo: geo,
        isProceduralBlock: false,
        needsOverhang: needsOverhang,
      );
    }
  }

  void _stageForegroundCluster(
    StagingBufferSet dst, {
    required String char,
    required int gridCol,
    required int gridRow,
    required int modifiers,
    required int fgArgb,
    required int bgArgb,
    required int resolvedFg,
    required double screenX,
    required double screenY,
    required _AtlasGeometry geo,
    required bool isBold,
    required bool isItalic,
  }) {
    final variant = GlyphStyleVariant.fromFlags(
      isBold: isBold,
      isItalic: isItalic,
    );
    final sourceRect = atlas.rectFor(char, isBold: isBold, isItalic: isItalic);
    if (sourceRect == null) {
      _stageFallbackCell(
        dst,
        char: char,
        variantIndex: variant.index,
        gridCol: gridCol,
        gridRow: gridRow,
        modifiers: modifiers,
        fgArgb: fgArgb,
        bgArgb: bgArgb,
        resolvedFg: resolvedFg,
        screenX: screenX,
        screenY: screenY,
        geo: geo,
      );
      return;
    }

    final l = sourceRect.left;
    final t = sourceRect.top;
    final r = sourceRect.right;
    final b = sourceRect.bottom;
    if (isColorEmoji(char)) {
      _stageEmojiQuad(dst, screenX, screenY, l, t, r, b, geo);
      return;
    }

    final isBlock = _isBlockCharacter(char);
    final hasNativeStyle =
        variant == GlyphStyleVariant.regular ||
        atlas.hasNativeVariant(char, variant);
    if (!isBlock && !hasNativeStyle) {
      dst.addMissingStyledGlyph(char, variant.index);
    }
    if (!isBlock && isItalic && !hasNativeStyle) {
      dst.addItalicCell(
        l,
        t,
        r,
        b,
        screenX,
        screenY,
        resolvedFg,
        isBold: isBold,
      );
      return;
    }

    final needsOverhang = _needsGlyphOverhang(
      char,
      isBold: isBold,
      isItalic: isItalic,
    );
    _stageQuadTextSprite(
      dst,
      screenX: screenX,
      screenY: screenY,
      l: l,
      t: t,
      r: r,
      b: b,
      fgColor: resolvedFg,
      geo: geo,
      isProceduralBlock: isBlock && isProceduralAtlasCharacter(char),
      needsOverhang: needsOverhang,
    );
    if (!isBlock && isBold && !hasNativeStyle) {
      _stageQuadTextSprite(
        dst,
        screenX: screenX + 0.6,
        screenY: screenY,
        l: l,
        t: t,
        r: r,
        b: b,
        fgColor: resolvedFg,
        geo: geo,
        isProceduralBlock: false,
        needsOverhang: needsOverhang,
      );
    }
  }

  void _stageEmojiQuad(
    StagingBufferSet dst,
    double screenX,
    double screenY,
    double l,
    double t,
    double r,
    double b,
    _AtlasGeometry geo,
  ) {
    final expand = geo.canExpandQuad(l, t, r, b);
    final padPhys = expand ? geo.overhangFgPhysical : 0.0;
    final padLogical = expand ? geo.overhangFgLogical : 0.0;
    dst.addEmojiSprite(
      geo.fgScaleBlock,
      screenX - padLogical,
      screenY - padLogical,
      l - padPhys,
      t - padPhys,
      r + padPhys,
      b + padPhys,
    );
  }

  void _stageQuadTextSprite(
    StagingBufferSet dst, {
    required double screenX,
    required double screenY,
    required double l,
    required double t,
    required double r,
    required double b,
    required int fgColor,
    required _AtlasGeometry geo,
    required bool isProceduralBlock,
    required bool needsOverhang,
  }) {
    final double padPhys;
    final double padLogical;
    if (isProceduralBlock) {
      padPhys = geo.bleedFgPhysicalBlock;
      padLogical = geo.bleedFgLogicalBlock;
    } else if (needsOverhang && geo.canExpandQuad(l, t, r, b)) {
      padPhys = geo.overhangFgPhysical;
      padLogical = geo.overhangFgLogical;
    } else {
      padPhys = 0.0;
      padLogical = 0.0;
    }

    dst.addFgSprite(
      geo.fgScaleBlock,
      screenX - padLogical,
      screenY - padLogical,
      l - padPhys,
      t - padPhys,
      r + padPhys,
      b + padPhys,
      fgColor,
    );
  }

  void _stageFallbackCell(
    StagingBufferSet dst, {
    required String char,
    required int variantIndex,
    required int gridCol,
    required int gridRow,
    required int modifiers,
    required int fgArgb,
    required int bgArgb,
    required int resolvedFg,
    required double screenX,
    required double screenY,
    required _AtlasGeometry geo,
  }) {
    final isKitty = _isKittyCell(char, modifiers);
    if (!isKitty) {
      dst.addMissingGlyph(char);
      dst.addMissingStyledGlyph(char, variantIndex);
    }
    dst.addFallbackCell(
      char: char,
      gridCol: gridCol,
      gridRow: gridRow,
      modifiers: modifiers,
      fgArgb: fgArgb,
      bgArgb: bgArgb,
      resolvedFg: resolvedFg,
      x: screenX,
      y: screenY,
      w: isKitty
          ? geo.cellWidth
          : (isWideGrapheme(char) ? 2 * geo.cellWidth : geo.cellWidth),
      h: geo.cellHeight,
    );
  }

  void _scheduleMissingGlyphCallbacks(StagingBufferSet staged) {
    final notifyPlain = staged.missingGlyphCount > 0 && onMissingGlyphs != null;
    final notifyStyled =
        staged.missingStyledCount > 0 && onMissingStyledGlyphs != null;
    if (!notifyPlain && !notifyStyled) return;
    final plainCopy = notifyPlain
        ? staged.missingGlyphs.sublist(0, staged.missingGlyphCount)
        : null;
    final styledCopy = notifyStyled
        ? <(String, GlyphStyleVariant)>[
            for (var i = 0; i < staged.missingStyledCount; i++)
              (
                staged.missingStyledChars[i],
                GlyphStyleVariant.values[staged.missingStyledVariants[i]],
              ),
          ]
        : null;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (plainCopy != null) onMissingGlyphs!(plainCopy);
      if (styledCopy != null) onMissingStyledGlyphs!(styledCopy);
    });
  }

  void _paintItalicAtlasCells(
    Canvas canvas,
    StagingBufferSet staged,
    _AtlasGeometry geo,
  ) {
    final paint = _italicPaint;
    final srcRects = staged.italicSrcRects;
    final positions = staged.italicPositions;
    final colors = staged.italicColors;
    final flags = staged.italicFlags;
    final count = staged.italicCount;

    for (var i = 0; i < count; i++) {
      final rBase = i << 2;
      final l = srcRects[rBase];
      final t = srcRects[rBase + 1];
      final r = srcRects[rBase + 2];
      final b = srcRects[rBase + 3];
      final pBase = i << 1;
      final x = positions[pBase];
      final y = positions[pBase + 1];
      final isBold = (flags[i] & 1) != 0;

      paint.colorFilter = ColorFilter.mode(
        Color(colors[i]),
        BlendMode.modulate,
      );
      final expand = geo.canExpandQuad(l, t, r, b);
      final padPhys = expand ? geo.overhangFgPhysical : 0.0;
      final srcRect = Rect.fromLTRB(
        l - padPhys,
        t - padPhys,
        r + padPhys,
        b + padPhys,
      );
      final padLogical = expand ? geo.overhangFgLogical : 0.0;
      final dstW = srcRect.width * geo.fgScaleBlock;
      final dstH = srcRect.height * geo.fgScaleBlock;
      canvas.save();
      try {
        canvas.translate(x + geo.cellWidth * 0.14, y);
        canvas.skew(-0.18, 0.0);
        canvas.drawImageRect(
          atlas.image,
          srcRect,
          Rect.fromLTWH(-padLogical, -padLogical, dstW, dstH),
          paint,
        );
        if (isBold) {
          canvas.drawImageRect(
            atlas.image,
            srcRect,
            Rect.fromLTWH(0.6 - padLogical, -padLogical, dstW, dstH),
            paint,
          );
        }
      } finally {
        canvas.restore();
      }
    }
  }

  void _paintFallbackCells(Canvas canvas, StagingBufferSet staged) {
    final count = staged.fallbackCount;
    var i = 0;
    while (i < count) {
      final char = staged.fallbackChars[i];
      final mods = staged.fallbackAttrs[i << 2];
      if (_isKittyCell(char, mods)) {
        i = _paintKittyCellOrRun(canvas, _kittyPaint, staged, i);
        continue;
      }
      _paintSingleFallbackGlyph(canvas, staged, i);
      i++;
    }
  }

  void _paintLigatureCells(Canvas canvas, StagingBufferSet staged) {
    final texts = staged.ligatureTexts;
    final rects = staged.ligatureRects;
    final colors = staged.ligatureColors;
    final flags = staged.ligatureFlags;
    final count = staged.ligatureCount;
    for (var i = 0; i < count; i++) {
      final rBase = i << 2;
      final x = rects[rBase];
      final y = rects[rBase + 1];
      final w = rects[rBase + 2];
      final h = rects[rBase + 3];
      final tp = _getLigaturePainter(
        texts[i],
        (flags[i] & 1) != 0,
        (flags[i] & 2) != 0,
        Color(colors[i]),
      );
      final offsetX = (w - tp.width) / 2;
      final offsetY = (h - tp.height) / 2;
      tp.paint(canvas, Offset(x + offsetX, y + offsetY));
    }
  }

  void _paintSingleFallbackGlyph(
    Canvas canvas,
    StagingBufferSet staged,
    int idx,
  ) {
    final char = staged.fallbackChars[idx];
    final aBase = idx << 2;
    final modifiers = staged.fallbackAttrs[aBase];
    final resolvedFg = staged.fallbackAttrs[aBase + 3];
    final x = staged.fallbackRects[aBase];
    final y = staged.fallbackRects[aBase + 1];
    final w = staged.fallbackRects[aBase + 2];
    final h = staged.fallbackRects[aBase + 3];

    final color = Color(resolvedFg);
    final isBold = Modifier.has(modifiers, Modifier.bold);
    final isItalic = Modifier.has(modifiers, Modifier.italic);
    final isDim = Modifier.has(modifiers, Modifier.dim);

    final cached = fallbackPainters[(char, isBold, isItalic, isDim, color)];
    if (cached != null) {
      _paintFallbackTextPainter(canvas, char, x, y, w, h, cached);
      return;
    }

    final transient = TextPainter(
      text: TextSpan(
        text: char,
        style: TextStyle(
          fontFamily: fontFamily,
          fontFamilyFallback: fontFamilyFallback,
          fontSize: atlas.fontSize,
          color: color,
          fontWeight: isBold ? FontWeight.bold : FontWeight.normal,
          fontStyle: isItalic ? FontStyle.italic : FontStyle.normal,
          letterSpacing: 0.0,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    try {
      _paintFallbackTextPainter(canvas, char, x, y, w, h, transient);
    } finally {
      transient.dispose();
    }
  }

  void _paintFallbackTextPainter(
    Canvas canvas,
    String char,
    double x,
    double y,
    double w,
    double h,
    TextPainter tp,
  ) {
    final overhang = atlas.actualOverhang;
    final rawDx = (w - tp.width) / 2;
    final dx = rawDx < 0.0 && char.length > 1 && !isColorEmoji(char)
        ? 0.0
        : rawDx;
    final dy =
        atlas.standardBaseline -
        tp.computeDistanceToActualBaseline(TextBaseline.alphabetic);

    canvas.save();
    try {
      canvas.clipRect(
        Rect.fromLTWH(
          x - overhang,
          y - overhang,
          w + 2 * overhang,
          h + 2 * overhang,
        ),
      );
      tp.paint(canvas, Offset(x + dx, y + dy));
    } finally {
      canvas.restore();
    }
  }

  int _paintKittyCellOrRun(
    Canvas canvas,
    Paint paint,
    StagingBufferSet staged,
    int index,
  ) {
    final char = staged.fallbackChars[index];
    final coords = parseKittyPlaceholderCell(char);
    if (coords == null) return index + 1;

    final gBase = index << 1;
    final gridCol = staged.fallbackGridCoords[gBase];
    final gridRow = staged.fallbackGridCoords[gBase + 1];
    final aBase = index << 2;
    final fgArgb = staged.fallbackAttrs[aBase + 1];
    final x = staged.fallbackRects[aBase];
    final y = staged.fallbackRects[aBase + 1];
    final w = staged.fallbackRects[aBase + 2];
    final h = staged.fallbackRects[aBase + 3];

    final imageId = extractKittyCellImageId(char, fgArgb);
    final registry = buffer.lookupKittyRegistry(gridCol, gridRow);
    final data = registry.lookupImage(imageId);
    if (data == null ||
        data.gridCols <= 0 ||
        data.gridRows <= 0 ||
        coords.row >= data.gridRows ||
        coords.col >= data.gridCols) {
      return index + 1;
    }

    final gpuImage = kittyImages[data] ?? kittyImagesById[(registry, imageId)];
    if (gpuImage == null) {
      _paintKittySubpixels(
        canvas,
        paint,
        x,
        y,
        w,
        h,
        data,
        coords.row,
        coords.col,
      );
      return index + 1;
    }

    final count = staged.fallbackCount;
    var endIdx = index + 1;
    var lastTileCol = coords.col;
    var lastGridCol = gridCol;
    while (endIdx < count &&
        _isNextKittyRunCell(
          staged,
          endIdx,
          data: data,
          imageId: imageId,
          expectedGridRow: gridRow,
          expectedGridCol: lastGridCol + 1,
          expectedTileRow: coords.row,
          expectedTileCol: lastTileCol + 1,
        )) {
      lastTileCol++;
      lastGridCol++;
      endIdx++;
    }
    final runCols = lastTileCol - coords.col + 1;
    final tileW = gpuImage.width / data.gridCols;
    final tileH = gpuImage.height / data.gridRows;
    paint.color = const Color(0xFFFFFFFF);
    canvas.drawImageRect(
      gpuImage,
      Rect.fromLTWH(
        coords.col * tileW,
        coords.row * tileH,
        runCols * tileW,
        tileH,
      ),
      Rect.fromLTWH(x, y, runCols * w + 0.25, h + 0.25),
      paint,
    );
    return endIdx;
  }

  bool _isNextKittyRunCell(
    StagingBufferSet staged,
    int index, {
    required KittyImageData data,
    required int imageId,
    required int expectedGridRow,
    required int expectedGridCol,
    required int expectedTileRow,
    required int expectedTileCol,
  }) {
    final char = staged.fallbackChars[index];
    final aBase = index << 2;
    if (!_isKittyCell(char, staged.fallbackAttrs[aBase])) return false;
    final gBase = index << 1;
    final gridCol = staged.fallbackGridCoords[gBase];
    final gridRow = staged.fallbackGridCoords[gBase + 1];
    if (gridRow != expectedGridRow || gridCol != expectedGridCol) return false;
    final coords = parseKittyPlaceholderCell(char);
    if (coords == null ||
        coords.row != expectedTileRow ||
        coords.col != expectedTileCol) {
      return false;
    }
    final nextId = extractKittyCellImageId(
      char,
      staged.fallbackAttrs[aBase + 1],
    );
    if (nextId != imageId) return false;
    return identical(buffer.lookupKittyImage(gridCol, gridRow, nextId), data);
  }

  void _paintKittySubpixels(
    Canvas canvas,
    Paint paint,
    double cellX,
    double cellY,
    double cellW,
    double cellH,
    KittyImageData data,
    int tileRow,
    int tileCol,
  ) {
    if (data.format == KittyImageData.formatPng) return;
    final stepsX = math.min(
      2,
      math.max(1, data.pixelWidth ~/ math.max(1, data.gridCols)),
    );
    final stepsY = math.min(
      4,
      math.max(1, data.pixelHeight ~/ math.max(1, data.gridRows)),
    );
    final subW = cellW / stepsX;
    final subH = cellH / stepsY;

    for (var sy = 0; sy < stepsY; sy++) {
      final normY = (tileRow + (sy + 0.5) / stepsY) / data.gridRows;
      final py = (normY * data.pixelHeight).floor().clamp(
        0,
        data.pixelHeight - 1,
      );
      _paintKittySubpixelRow(
        canvas,
        paint,
        cellX,
        data,
        tileCol,
        stepsX,
        subW,
        subH,
        py * data.pixelWidth * 4,
        cellY + sy * subH,
      );
    }
  }

  void _paintKittySubpixelRow(
    Canvas canvas,
    Paint paint,
    double cellX,
    KittyImageData data,
    int tileCol,
    int stepsX,
    double subW,
    double subH,
    int rowBase,
    double dstY,
  ) {
    final rgba = data.rgbaPixels;
    var sx = 0;
    while (sx < stepsX) {
      final argb = _sampleKittySubpixelArgb(
        rgba,
        rowBase,
        data.pixelWidth,
        data.gridCols,
        tileCol,
        sx,
        stepsX,
      );
      if (argb == 0) {
        sx++;
        continue;
      }
      var runEnd = sx + 1;
      while (runEnd < stepsX &&
          _sampleKittySubpixelArgb(
                rgba,
                rowBase,
                data.pixelWidth,
                data.gridCols,
                tileCol,
                runEnd,
                stepsX,
              ) ==
              argb) {
        runEnd++;
      }
      paint.color = Color(argb);
      canvas.drawRect(
        Rect.fromLTWH(
          cellX + sx * subW,
          dstY,
          (runEnd - sx) * subW + 0.25,
          subH + 0.25,
        ),
        paint,
      );
      sx = runEnd;
    }
  }

  int _sampleKittySubpixelArgb(
    Uint8List rgba,
    int rowBase,
    int pixelWidth,
    int gridCols,
    int tileCol,
    int sx,
    int stepsX,
  ) {
    final normX = (tileCol + (sx + 0.5) / stepsX) / gridCols;
    final px = (normX * pixelWidth).floor().clamp(0, pixelWidth - 1);
    final pIdx = rowBase + px * 4;
    if (pIdx + 3 >= rgba.length) return 0;
    final a = rgba[pIdx + 3];
    if (a == 0) return 0;
    return (a << 24) |
        (rgba[pIdx] << 16) |
        (rgba[pIdx + 1] << 8) |
        rgba[pIdx + 2];
  }

  static bool _isDarkArgb(int argb) {
    final r = (argb >> 16) & 0xFF;
    final g = (argb >> 8) & 0xFF;
    final b = argb & 0xFF;
    return (0.299 * r + 0.587 * g + 0.114 * b) < 128.0;
  }

  void _paintOutOfBoundsDimming(Canvas canvas, Size size, _AtlasGeometry geo) {
    final activeX = activePtyCols != null
        ? (math.max(0, activePtyCols!) * geo.cellWidth).clamp(0.0, size.width)
        : size.width;
    final activeY = activePtyRows != null
        ? (math.max(0, activePtyRows!) * geo.cellHeight).clamp(0.0, size.height)
        : size.height;
    if (activeX >= size.width && activeY >= size.height) return;

    _dimPaint.color = outOfBoundsDimColor ?? const Color(0x80000000);
    if (activeX < size.width && activeY > 0) {
      canvas.drawRect(
        Rect.fromLTRB(activeX, 0.0, size.width, activeY),
        _dimPaint,
      );
    }
    if (activeY < size.height) {
      canvas.drawRect(
        Rect.fromLTRB(0.0, activeY, size.width, size.height),
        _dimPaint,
      );
    }

    _borderPaint.color = _isDarkArgb(defaultBackgroundArgb)
        ? const Color(0x33FFFFFF)
        : const Color(0x33000000);
    if (activeX < size.width && activeY > 0) {
      final bx = math.min(size.width - 0.5, activeX + 0.5);
      final bottom = activeY < size.height
          ? math.min(size.height, activeY + 1.0)
          : size.height;
      canvas.drawLine(Offset(bx, 0.0), Offset(bx, bottom), _borderPaint);
    }
    if (activeY < size.height && activeX > 0) {
      final by = math.min(size.height - 0.5, activeY + 0.5);
      canvas.drawLine(Offset(0.0, by), Offset(activeX, by), _borderPaint);
    }
  }

  void _paintComposingOverlay(Canvas canvas, Size size, _AtlasGeometry geo) {
    final maxCols = math.max(1, (size.width / geo.cellWidth).floor());
    final maxRows = math.max(1, (size.height / geo.cellHeight).floor());
    final col = cursorCol.clamp(0, maxCols - 1);
    final row = cursorRow.clamp(0, maxRows - 1);
    final originX = col * geo.cellWidth;
    final originY = row * geo.cellHeight;
    final availWidth = math.max(geo.cellWidth, size.width - originX);

    final fgColor = Color(defaultForegroundArgb);
    final bgColor = Color(defaultBackgroundArgb);
    final cachedTp = composingPainter;
    final tp =
        cachedTp ??
        (TextPainter(
          text: TextSpan(
            text: composingText,
            style: TextStyle(
              fontFamily: fontFamily,
              fontFamilyFallback: fontFamilyFallback,
              fontSize: atlas.fontSize,
              color: fgColor,
              height: 1.0,
            ),
          ),
          textDirection: TextDirection.ltr,
        )..layout());

    try {
      final cellSpan = countGraphemeDisplayCells(composingText);
      final rawWidth = math.max(cellSpan * geo.cellWidth, tp.width);
      final overlayWidth = math.min(availWidth, rawWidth);
      final overlayRect = Rect.fromLTWH(
        originX,
        originY,
        overlayWidth,
        geo.cellHeight,
      );

      canvas.save();
      canvas.clipRect(overlayRect);
      _composingBgPaint.color = bgColor;
      canvas.drawRect(overlayRect, _composingBgPaint);
      final offsetY = (geo.cellHeight - tp.height) / 2;
      tp.paint(canvas, Offset(originX, originY + offsetY));
      final underlineY = originY + geo.cellHeight - 1.5;
      _composingUnderlinePaint.color = fgColor;
      canvas.drawLine(
        Offset(originX, underlineY),
        Offset(originX + overlayWidth, underlineY),
        _composingUnderlinePaint,
      );
      canvas.restore();
    } finally {
      if (cachedTp == null) {
        tp.dispose();
      }
    }
  }

  /// Resolves the effective ARGB background for a cell.
  static int resolveCellBackgroundArgb(
    int bgArgb,
    int fgArgb, {
    required bool isReverse,
    bool isSelected = false,
    int defaultForegroundArgb = 0xFFFFFFFF,
    int defaultBackgroundArgb = 0xFF000000,
    TerminalColorTheme palette = TerminalColorTheme.termuiDark,
  }) {
    if (isSelected) return _selectionBgArgb;
    final raw = isReverse ? fgArgb : bgArgb;
    if (raw == 0) {
      return isReverse ? defaultForegroundArgb : defaultBackgroundArgb;
    }
    return palette.resolvePackedColor(raw);
  }

  /// Resolves the effective ARGB foreground for a cell, applying
  /// [Modifier.dim] with [faintOpacity].
  static int resolveCellForegroundArgb(
    int fgArgb,
    int bgArgb, {
    required int modifiers,
    required bool isReverse,
    bool isSelected = false,
    int defaultForegroundArgb = 0xFFFFFFFF,
    int defaultBackgroundArgb = 0xFF000000,
    double faintOpacity = 140 / 255,
    TerminalColorTheme palette = TerminalColorTheme.termuiDark,
  }) {
    if (isSelected && Modifier.has(modifiers, Modifier.hidden)) {
      return defaultForegroundArgb;
    }
    final raw = isReverse ? bgArgb : fgArgb;
    final resolved = raw == 0
        ? (isReverse ? defaultBackgroundArgb : defaultForegroundArgb)
        : palette.resolvePackedColor(raw);
    if (Modifier.has(modifiers, Modifier.dim)) {
      final a = (((resolved >> 24) & 0xFF) * faintOpacity).round().clamp(
        0,
        255,
      );
      return (a << 24) | (resolved & 0x00FFFFFF);
    }
    return resolved;
  }

  int _resolveBgColor(
    int bgArgb,
    int fgArgb, {
    required bool isReverse,
    bool isSelected = false,
  }) => resolveCellBackgroundArgb(
    bgArgb,
    fgArgb,
    isReverse: isReverse,
    isSelected: isSelected,
    defaultForegroundArgb: defaultForegroundArgb,
    defaultBackgroundArgb: defaultBackgroundArgb,
    palette: palette,
  );

  int _resolveFgColor(
    int fgArgb,
    int bgArgb, {
    required int modifiers,
    required bool isReverse,
    bool isSelected = false,
  }) => resolveCellForegroundArgb(
    fgArgb,
    bgArgb,
    modifiers: modifiers,
    isReverse: isReverse,
    isSelected: isSelected,
    defaultForegroundArgb: defaultForegroundArgb,
    defaultBackgroundArgb: defaultBackgroundArgb,
    faintOpacity: faintOpacity,
    palette: palette,
  );

  @override
  bool shouldRepaint(covariant TuiAtlasPainter oldDelegate) =>
      repaint == null ||
      oldDelegate.buffer != buffer ||
      oldDelegate.atlas != atlas ||
      oldDelegate.repaint != repaint ||
      oldDelegate.stagingCache != stagingCache ||
      oldDelegate.cellOverrideMask != cellOverrideMask ||
      oldDelegate.composingPainter != composingPainter ||
      oldDelegate.fontFamily != fontFamily ||
      !listEquals(oldDelegate.fontFamilyFallback, fontFamilyFallback) ||
      oldDelegate.fallbackPainters != fallbackPainters ||
      oldDelegate.enableBleed != enableBleed ||
      oldDelegate.enableLigatures != enableLigatures ||
      (oldDelegate.ligaturePainters != ligaturePainters &&
          (oldDelegate.ligaturePainters.isNotEmpty ||
              ligaturePainters.isNotEmpty)) ||
      oldDelegate.selectionController != selectionController ||
      oldDelegate.topVirtualRow != topVirtualRow ||
      oldDelegate.topVirtualRowProvider != topVirtualRowProvider ||
      oldDelegate._selectionStart != _selectionStart ||
      oldDelegate._selectionEnd != _selectionEnd ||
      oldDelegate._selectionColBounds != _selectionColBounds ||
      oldDelegate.selectionBoxMode != selectionBoxMode ||
      oldDelegate.hoveredLink != hoveredLink ||
      !listEquals(oldDelegate.hoveredLinkRowSpans, hoveredLinkRowSpans) ||
      oldDelegate.hoveredLinkStyler != hoveredLinkStyler ||
      (hoveredLink != null && hoveredLinkStyler != null) ||
      oldDelegate.kittyImages != kittyImages ||
      oldDelegate.kittyImagesById != kittyImagesById ||
      oldDelegate.defaultForegroundArgb != defaultForegroundArgb ||
      oldDelegate.defaultBackgroundArgb != defaultBackgroundArgb ||
      oldDelegate.faintOpacity != faintOpacity ||
      oldDelegate.palette != palette ||
      oldDelegate.activePtyCols != activePtyCols ||
      oldDelegate.activePtyRows != activePtyRows ||
      oldDelegate.outOfBoundsDimColor != outOfBoundsDimColor ||
      oldDelegate.composingText != composingText ||
      oldDelegate.cursorCol != cursorCol ||
      oldDelegate.cursorRow != cursorRow ||
      (oldDelegate.onMissingGlyphs == null) != (onMissingGlyphs == null) ||
      (oldDelegate.onMissingStyledGlyphs == null) !=
          (onMissingStyledGlyphs == null) ||
      (oldDelegate.onBeforePaint == null) != (onBeforePaint == null);
}

final class _AtlasGeometry {
  final double cellWidth;
  final double cellHeight;
  final double devicePixelRatio;
  final double bleedBgLogical;
  final double bleedFgPhysicalBlock;
  final double bleedFgLogicalBlock;
  final double overhangFgPhysical;
  final double overhangFgLogical;
  final double atlasPhysWidth;
  final double atlasPhysHeight;
  final double bgScaleBlock;
  final double fgScaleBlock;
  final double bgRect0;
  final double bgRect1;
  final double bgRect2;
  final double bgRect3;
  final double whiteRect0;
  final double whiteRect1;
  final double whiteRect2;
  final double whiteRect3;

  const _AtlasGeometry({
    required this.cellWidth,
    required this.cellHeight,
    required this.devicePixelRatio,
    required this.bleedBgLogical,
    required this.bleedFgPhysicalBlock,
    required this.bleedFgLogicalBlock,
    required this.overhangFgPhysical,
    required this.overhangFgLogical,
    required this.atlasPhysWidth,
    required this.atlasPhysHeight,
    required this.bgScaleBlock,
    required this.fgScaleBlock,
    required this.bgRect0,
    required this.bgRect1,
    required this.bgRect2,
    required this.bgRect3,
    required this.whiteRect0,
    required this.whiteRect1,
    required this.whiteRect2,
    required this.whiteRect3,
  });

  @pragma('vm:prefer-inline')
  bool canExpandQuad(double l, double t, double r, double b) =>
      overhangFgPhysical > 0.0 &&
      l >= overhangFgPhysical &&
      t >= overhangFgPhysical &&
      r + overhangFgPhysical <= atlasPhysWidth &&
      b + overhangFgPhysical <= atlasPhysHeight;

  factory _AtlasGeometry.fromAtlas(
    GlyphAtlas atlas, {
    required bool enableBleed,
  }) {
    final cellWidth = atlas.cellWidth;
    final cellHeight = atlas.cellHeight;
    final dpr = atlas.devicePixelRatio;
    final quadTable = atlas.quadTable;
    final whiteOff = quadTable.quadOffsetForCode(0xFFFF, variantBits: 0);
    final double whiteX;
    final double whiteY;
    final double whiteRight;
    final double whiteBottom;
    if (whiteOff >= 0) {
      final quads = quadTable.ltrbQuads;
      whiteX = quads[whiteOff];
      whiteY = quads[whiteOff + 1];
      whiteRight = quads[whiteOff + 2];
      whiteBottom = quads[whiteOff + 3];
    } else {
      final bgRect = atlas.charRects['\uFFFF']!;
      whiteX = bgRect.left;
      whiteY = bgRect.top;
      whiteRight = bgRect.right;
      whiteBottom = bgRect.bottom;
    }
    final whiteW = whiteRight - whiteX;

    final bleedPhysical = enableBleed ? (0.5 * dpr).ceilToDouble() : 0.0;
    final bleedBgLogical = bleedPhysical * (cellWidth / whiteW);
    final bleedFgLogicalBlock = bleedPhysical / dpr;
    final overhangFgPhysical = (GlyphAtlas.overhang * dpr).floorToDouble();
    final overhangFgLogical = overhangFgPhysical / dpr;
    final atlasPhysWidth = atlas.image.width.toDouble();
    final atlasPhysHeight = atlas.image.height.toDouble();
    final bgScaleBlock = cellWidth / whiteW;
    final fgScaleBlock = 1.0 / dpr;

    return _AtlasGeometry(
      cellWidth: cellWidth,
      cellHeight: cellHeight,
      devicePixelRatio: dpr,
      bleedBgLogical: bleedBgLogical,
      bleedFgPhysicalBlock: bleedPhysical,
      bleedFgLogicalBlock: bleedFgLogicalBlock,
      overhangFgPhysical: overhangFgPhysical,
      overhangFgLogical: overhangFgLogical,
      atlasPhysWidth: atlasPhysWidth,
      atlasPhysHeight: atlasPhysHeight,
      bgScaleBlock: bgScaleBlock,
      fgScaleBlock: fgScaleBlock,
      bgRect0: whiteX - bleedPhysical,
      bgRect1: whiteY - bleedPhysical,
      bgRect2: whiteRight + bleedPhysical,
      bgRect3: whiteBottom + bleedPhysical,
      whiteRect0: whiteX,
      whiteRect1: whiteY,
      whiteRect2: whiteRight,
      whiteRect3: whiteBottom,
    );
  }
}
