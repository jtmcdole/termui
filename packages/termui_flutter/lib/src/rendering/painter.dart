import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:termui/ui/buffer.dart';
import 'package:termui/ui/color.dart' show ColorIntExtension;
import 'package:termui/ui/style.dart';
import 'package:termui/ui/terminal_palette.dart';
import 'package:termui/ui/widgets/display/kitty_image.dart';
import 'package:termui/ui/widgets/interactive/selection_controller.dart';
import 'atlas.dart';

bool _isBlockCharacter(String char) {
  if (char.isEmpty) return false;
  final code = char.codeUnitAt(0);
  return code >= 0x2580 && code <= 0x2590;
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

bool _isLigatureChar(String ch) {
  if (ch.length != 1) return false;
  final c = ch.codeUnitAt(0);
  return (c >= 0x21 && c <= 0x2F) ||
      (c >= 0x3A && c <= 0x40) ||
      (c >= 0x5B && c <= 0x5E) ||
      c == 0x5F ||
      (c >= 0x7B && c <= 0x7E);
}

/// Determines if a given grapheme cluster character represents a color emoji.
bool isColorEmoji(String char) {
  if (char.isEmpty) return false;
  if (char.runes.contains(0xFE0E)) return false;
  if (char.runes.contains(0xFE0F)) return true;
  final code = char.runes.first;
  if (code >= 0x1F300 && code <= 0x1FAFF) return true;
  return false;
}

/// A custom painter that renders a terminal buffer using a texture atlas.
///
/// It draws both the cell backgrounds and foreground glyphs onto a Flutter
/// [Canvas]. To optimize performance and prevent GPU command buffer overflow
/// when drawing large grids (which is common in TUI applications), the painter
/// batches draw calls using [Canvas.drawRawAtlas] and processes sprites in
/// chunks of 500.
///
/// If a character is not found in the [atlas] (e.g. dynamic unicode or emojis
/// being loaded), it triggers [onMissingGlyphs] and falls back to rendering
/// with individual text painters stored in [fallbackPainters].
///
/// ### Example Usage
///
/// ```dart
/// CustomPaint(
///   size: Size(800.0, 600.0),
///   painter: TuiAtlasPainter(
///     buffer: currentBuffer,
///     atlas: glyphAtlas,
///     fallbackPainters: myFallbackPaintersMap,
///     onMissingGlyphs: (glyphs) {
///       print('Need to load: $glyphs');
///     },
///   ),
/// )
/// ```
final class TuiAtlasPainter extends CustomPainter {
  /// The buffer containing the current layout state to paint.
  final Buffer buffer;

  /// The pre-rasterized texture map for fast grapheme rendering.
  final GlyphAtlas atlas;

  /// Optional callback invoked when unrecognized glyphs are requested.
  final void Function(List<String>)? onMissingGlyphs;

  /// Optional callback invoked with exact `(char, GlyphStyleVariant)` pairs for lazy dynamic rasterization.
  final void Function(List<(String, GlyphStyleVariant)>)? onMissingStyledGlyphs;

  /// Cache of individual [TextPainter] objects for glyphs absent in the main atlas.
  final Map<(String, bool, bool, bool, Color), TextPainter> fallbackPainters;

  Float32List? _transformsBg;
  Float32List? _rectsBg;
  Int32List? _colorsBg;

  Float32List? _transformsFg;
  Float32List? _rectsFg;
  Int32List? _colorsFg;

  Float32List? _transformsEmoji;
  Float32List? _rectsEmoji;

  /// The primary font family used for rendering text.
  final String fontFamily;

  /// The fallback font families.
  final List<String>? fontFamilyFallback;

  /// Enables sub-pixel bleeding to prevent gaps during fractional transformations. Defaults to kIsWeb.
  final bool enableBleed;

  /// Optional controller managing active text selection state.
  final TerminalSelectionController? selectionController;

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

  /// Constructs a [TuiAtlasPainter] targeting the supplied [buffer].
  TuiAtlasPainter({
    required this.buffer,
    required this.atlas,
    required this.fontFamily,
    this.fontFamilyFallback,
    required this.fallbackPainters,
    required this.onMissingGlyphs,
    this.onMissingStyledGlyphs,
    this.enableBleed = kIsWeb,
    this.enableLigatures = false,
    Map<(String, bool, bool, Color), TextPainter>? ligaturePainters,
    this.selectionController,
    math.Point<int>? selectionStart,
    math.Point<int>? selectionEnd,
    (int, int)? selectionColBounds,
    this.selectionBoxMode = false,
    this.kittyImages = const {},
    this.kittyImagesById = const {},
    this.defaultForegroundArgb = 0xFFFFFFFF,
    this.defaultBackgroundArgb = 0xFF000000,
    this.faintOpacity = 140 / 255,
    this.palette = TerminalColorTheme.termuiDark,
  }) : _selectionStart = selectionStart,
       _selectionEnd = selectionEnd,
       _selectionColBounds = selectionColBounds,
       ligaturePainters =
           ligaturePainters ?? <(String, bool, bool, Color), TextPainter>{};

  /// Default ARGB foreground color substituted when a cell has `fg == 0`.
  final int defaultForegroundArgb;

  /// Default ARGB background color substituted when a cell has `bg == 0`.
  final int defaultBackgroundArgb;

  /// Opacity multiplier in `(0.0, 1.0]` applied to `Modifier.dim` cells.
  final double faintOpacity;

  /// Palette used to resolve [ColorIntExtension.isAnsiIndexed] cell colors.
  final TerminalColorTheme palette;

  void _drawRawAtlasInChunks(
    Canvas canvas,
    ui.Image image,
    Float32List transforms,
    Float32List rects,
    Int32List? colors,
    int totalSprites,
    Paint paint,
  ) {
    const int chunkSize = 500;
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
    final count = buffer.width * buffer.height;
    _ensureBatchBuffers(count);

    final geo = _AtlasGeometry.fromAtlas(atlas, enableBleed: enableBleed);
    final fallbackCells = <_FallbackCell>[];
    final italicCells = <_ItalicAtlasCell>[];
    final decorations = <_CellDecoration>[];
    final ligatureCells = <_LigatureCell>[];
    final missingGlyphs = <String>[];
    final missingStyledGlyphs = <(String, GlyphStyleVariant)>[];

    final (fgSpriteCount, emojiSpriteCount) = _stageGridCells(
      geo,
      fallbackCells,
      italicCells,
      decorations,
      ligatureCells,
      missingGlyphs,
      missingStyledGlyphs,
    );

    _scheduleMissingGlyphCallbacks(missingGlyphs, missingStyledGlyphs);

    _drawRawAtlasInChunks(
      canvas,
      atlas.image,
      _transformsBg!,
      _rectsBg!,
      _colorsBg!,
      count,
      Paint()..filterQuality = FilterQuality.none,
    );

    if (fgSpriteCount > 0) {
      _drawRawAtlasInChunks(
        canvas,
        atlas.image,
        _transformsFg!,
        _rectsFg!,
        _colorsFg!,
        fgSpriteCount,
        Paint()..filterQuality = FilterQuality.none,
      );
    }

    if (emojiSpriteCount > 0) {
      _drawRawAtlasInChunks(
        canvas,
        atlas.image,
        _transformsEmoji!,
        _rectsEmoji!,
        null,
        emojiSpriteCount,
        Paint(),
      );
    }

    if (italicCells.isNotEmpty) {
      _paintItalicAtlasCells(canvas, italicCells, geo);
    }

    if (fallbackCells.isNotEmpty) {
      _paintFallbackCells(canvas, fallbackCells);
    }

    if (ligatureCells.isNotEmpty) {
      _paintLigatureCells(canvas, ligatureCells, geo);
    }

    if (decorations.isNotEmpty) {
      _paintDecorations(canvas, decorations);
    }
  }

  void _scheduleMissingGlyphCallbacks(
    List<String> missingGlyphs,
    List<(String, GlyphStyleVariant)> missingStyledGlyphs,
  ) {
    final notifyPlain = missingGlyphs.isNotEmpty && onMissingGlyphs != null;
    final notifyStyled =
        missingStyledGlyphs.isNotEmpty && onMissingStyledGlyphs != null;
    if (!notifyPlain && !notifyStyled) return;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (notifyPlain) onMissingGlyphs!(missingGlyphs);
      if (notifyStyled) onMissingStyledGlyphs!(missingStyledGlyphs);
    });
  }

  void _ensureBatchBuffers(int count) {
    if (_transformsBg != null && _transformsBg!.length == count * 4) return;

    _transformsBg = Float32List(count * 4);
    _rectsBg = Float32List(count * 4);
    _colorsBg = Int32List(count);

    // Allocate 2x capacity for foreground sprites to accommodate synthetic bold overstrike
    _transformsFg = Float32List(count * 8);
    _rectsFg = Float32List(count * 8);
    _colorsFg = Int32List(count * 2);

    _transformsEmoji = Float32List(count * 4);
    _rectsEmoji = Float32List(count * 4);
  }

  static const int _decorationMask =
      Modifier.underline | Modifier.crossedOut | Modifier.overline;

  bool _isCellSelected(int x, int y) {
    if (selectionController != null) {
      return selectionController!.isCellSelected(x, y);
    }
    final a = selectionStart;
    final b = selectionEnd;
    if (a == null || b == null) return false;
    final (start, end) = (a.y < b.y || (a.y == b.y && a.x <= b.x))
        ? (a, b)
        : (b, a);
    if (y < start.y || y > end.y) return false;
    if (selectionBoxMode || start.y == end.y) {
      return x >= math.min(start.x, end.x) && x <= math.max(start.x, end.x);
    }
    final minCol = selectionColBounds?.$1 ?? 0;
    final maxCol = selectionColBounds?.$2 ?? (buffer.width - 1);
    if (x < minCol || x > maxCol) return false;
    if (y == start.y) return x >= start.x;
    if (y == end.y) return x <= end.x;
    return true;
  }

  (int, int) _stageGridCells(
    _AtlasGeometry geo,
    List<_FallbackCell> fallbackCells,
    List<_ItalicAtlasCell> italicCells,
    List<_CellDecoration> decorations,
    List<_LigatureCell> ligatureCells,
    List<String> missingGlyphs,
    List<(String, GlyphStyleVariant)> missingStyledGlyphs,
  ) {
    final cols = buffer.width;
    final rows = buffer.height;
    var fgSpriteCount = 0;
    var emojiSpriteCount = 0;

    for (var y = 0; y < rows; y++) {
      final screenY = y * geo.cellHeight;
      var x = 0;
      while (x < cols) {
        if (enableLigatures) {
          final lig = _detectLigature(x, y, cols);
          if (lig != null) {
            fgSpriteCount = _stageLigatureRun(
              lig.$1,
              lig.$2,
              x,
              y,
              screenY,
              geo,
              decorations,
              ligatureCells,
              fgSpriteCount,
            );
            x += lig.$2;
            continue;
          }
        }

        (fgSpriteCount, emojiSpriteCount) = _stageSingleCell(
          x,
          y,
          screenY,
          geo,
          decorations,
          fallbackCells,
          italicCells,
          missingGlyphs,
          missingStyledGlyphs,
          fgSpriteCount,
          emojiSpriteCount,
        );
        x++;
      }
    }

    return (fgSpriteCount, emojiSpriteCount);
  }

  (int, int) _stageSingleCell(
    int x,
    int y,
    double screenY,
    _AtlasGeometry geo,
    List<_CellDecoration> decorations,
    List<_FallbackCell> fallbackCells,
    List<_ItalicAtlasCell> italicCells,
    List<String> missingGlyphs,
    List<(String, GlyphStyleVariant)> missingStyledGlyphs,
    int fgSpriteCount,
    int emojiSpriteCount,
  ) {
    final char = buffer.getCharacter(x, y);
    final bgArgb = buffer.getBackground(x, y);
    final fgArgb = buffer.getForeground(x, y);
    final modifiers = buffer.getModifiers(x, y);
    final isReverse = Modifier.has(modifiers, Modifier.reverse);

    final idx = y * buffer.width + x;
    final isSelected = !_isKittyCell(char, modifiers) && _isCellSelected(x, y);
    final screenX = x * geo.cellWidth;

    _stageBackgroundSprite(
      idx,
      screenX,
      screenY,
      _resolveBgColor(
        bgArgb,
        fgArgb,
        isReverse: isReverse,
        isSelected: isSelected,
      ),
      geo,
    );

    final resolvedFg = _resolveFgColor(
      fgArgb,
      bgArgb,
      modifiers: modifiers,
      isReverse: isReverse,
      isSelected: isSelected,
    );

    if (Modifier.has(modifiers, Modifier.hidden) && !isSelected) {
      return (fgSpriteCount, emojiSpriteCount);
    }

    _maybeStageDecoration(
      decorations,
      char: char,
      x: x,
      y: y,
      screenX: screenX,
      screenY: screenY,
      modifiers: modifiers,
      resolvedFg: resolvedFg,
      geo: geo,
    );

    if (char.isEmpty || char == ' ') {
      return (fgSpriteCount, emojiSpriteCount);
    }

    return _stageForegroundCell(
      char: char,
      gridCol: x,
      gridRow: y,
      modifiers: modifiers,
      fgArgb: fgArgb,
      bgArgb: bgArgb,
      resolvedFg: resolvedFg,
      screenX: screenX,
      screenY: screenY,
      fgSpriteCount: fgSpriteCount,
      emojiSpriteCount: emojiSpriteCount,
      geo: geo,
      fallbackCells: fallbackCells,
      italicCells: italicCells,
      missingGlyphs: missingGlyphs,
      missingStyledGlyphs: missingStyledGlyphs,
    );
  }

  (String, int)? _detectLigature(int startX, int y, int cols) {
    if (startX + 1 >= cols) return null;
    final maxLen = math.min(4, cols - startX);
    for (var len = maxLen; len >= 2; len--) {
      final match = _checkLigatureCandidate(startX, y, len);
      if (match != null) return (match, len);
    }
    return null;
  }

  String? _checkLigatureCandidate(int startX, int y, int len) {
    final firstChar = buffer.getCharacter(startX, y);
    if (!_isLigatureChar(firstChar)) return null;

    final firstMods = buffer.getModifiers(startX, y);
    final firstSelected = _isCellSelected(startX, y);
    if (Modifier.has(firstMods, Modifier.hidden) && !firstSelected) {
      return null;
    }

    final firstFg = buffer.getForeground(startX, y);
    final firstBg = buffer.getBackground(startX, y);
    final firstUl = buffer.getUnderlineColor(startX, y);
    final firstUri = buffer.getUri(startX, y);

    final sb = StringBuffer(firstChar);
    for (var i = 1; i < len; i++) {
      final curX = startX + i;
      final ch = buffer.getCharacter(curX, y);
      if (!_isLigatureChar(ch) ||
          !_cellMatchesLigatureRun(
            curX,
            y,
            firstFg,
            firstBg,
            firstMods,
            firstUl,
            firstUri,
            firstSelected,
          )) {
        return null;
      }
      sb.write(ch);
    }
    final text = sb.toString();
    return _knownLigatures.contains(text) ? text : null;
  }

  bool _cellMatchesLigatureRun(
    int x,
    int y,
    int fg,
    int bg,
    int mods,
    int underlineColor,
    String? uri,
    bool selected,
  ) =>
      buffer.getForeground(x, y) == fg &&
      buffer.getBackground(x, y) == bg &&
      buffer.getModifiers(x, y) == mods &&
      buffer.getUnderlineColor(x, y) == underlineColor &&
      buffer.getUri(x, y) == uri &&
      _isCellSelected(x, y) == selected;

  int _stageLigatureRun(
    String text,
    int len,
    int startX,
    int y,
    double screenY,
    _AtlasGeometry geo,
    List<_CellDecoration> decorations,
    List<_LigatureCell> ligatureCells,
    int fgSpriteCount,
  ) {
    final firstFg = buffer.getForeground(startX, y);
    final firstBg = buffer.getBackground(startX, y);
    final firstMods = buffer.getModifiers(startX, y);
    final isReverse = Modifier.has(firstMods, Modifier.reverse);
    final isSelected = _isCellSelected(startX, y);

    final resolvedBg = _resolveBgColor(
      firstBg,
      firstFg,
      isReverse: isReverse,
      isSelected: isSelected,
    );
    final isHiddenUnselected =
        Modifier.has(firstMods, Modifier.hidden) && !isSelected;

    if (isHiddenUnselected) {
      for (var i = 0; i < len; i++) {
        final x = startX + i;
        final idx = y * buffer.width + x;
        _stageBackgroundSprite(
          idx,
          x * geo.cellWidth,
          screenY,
          resolvedBg,
          geo,
        );
      }
      return fgSpriteCount;
    }

    final resolvedFg = _resolveFgColor(
      firstFg,
      firstBg,
      modifiers: firstMods,
      isReverse: isReverse,
      isSelected: isSelected,
    );

    for (var i = 0; i < len; i++) {
      final x = startX + i;
      final idx = y * buffer.width + x;
      final screenX = x * geo.cellWidth;
      _stageBackgroundSprite(idx, screenX, screenY, resolvedBg, geo);
      _maybeStageDecoration(
        decorations,
        char: buffer.getCharacter(x, y),
        x: x,
        y: y,
        screenX: screenX,
        screenY: screenY,
        modifiers: firstMods,
        resolvedFg: resolvedFg,
        geo: geo,
      );
    }

    final isBold = Modifier.has(firstMods, Modifier.bold);
    final isItalic = Modifier.has(firstMods, Modifier.italic);
    final atlasRect = atlas.rectFor(text, isBold: isBold, isItalic: isItalic);
    if (atlasRect != null) {
      _stageTextSprite(
        fgSpriteCount,
        text,
        startX * geo.cellWidth,
        screenY,
        atlasRect,
        resolvedFg,
        geo,
      );
      return fgSpriteCount + 1;
    }

    final tp = _getLigaturePainter(text, isBold, isItalic, Color(resolvedFg));
    ligatureCells.add(
      _LigatureCell(
        text: text,
        painter: tp,
        x: startX * geo.cellWidth,
        y: screenY,
        w: len * geo.cellWidth,
        h: geo.cellHeight,
      ),
    );
    return fgSpriteCount;
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

  void _maybeStageDecoration(
    List<_CellDecoration> decorations, {
    required String char,
    required int x,
    required int y,
    required double screenX,
    required double screenY,
    required int modifiers,
    required int resolvedFg,
    required _AtlasGeometry geo,
  }) {
    if (char.isEmpty || (modifiers & _decorationMask) == 0) return;
    final ulArgb = buffer.getUnderlineColor(x, y);
    final resolvedUl = ulArgb != 0
        ? palette.resolvePackedColor(ulArgb)
        : resolvedFg;
    decorations.add(
      _CellDecoration(
        x: screenX,
        y: screenY,
        w: isWideGrapheme(char) ? 2 * geo.cellWidth : geo.cellWidth,
        h: geo.cellHeight,
        modifiers: modifiers,
        fgColor: resolvedFg,
        ulColor: resolvedUl,
      ),
    );
  }

  void _stageBackgroundSprite(
    int idx,
    double screenX,
    double screenY,
    int bgColor,
    _AtlasGeometry geo,
  ) {
    final base = idx * 4;
    _transformsBg![base + 0] = geo.bgScaleBlock;
    _transformsBg![base + 1] = 0.0;
    _transformsBg![base + 2] = screenX - geo.bleedBgLogical;
    _transformsBg![base + 3] = screenY - geo.bleedBgLogical;

    _rectsBg![base + 0] = geo.bgRect0;
    _rectsBg![base + 1] = geo.bgRect1;
    _rectsBg![base + 2] = geo.bgRect2;
    _rectsBg![base + 3] = geo.bgRect3;

    _colorsBg![idx] = bgColor;
  }

  (int, int) _stageForegroundCell({
    required String char,
    required int gridCol,
    required int gridRow,
    required int modifiers,
    required int fgArgb,
    required int bgArgb,
    required int resolvedFg,
    required double screenX,
    required double screenY,
    required int fgSpriteCount,
    required int emojiSpriteCount,
    required _AtlasGeometry geo,
    required List<_FallbackCell> fallbackCells,
    required List<_ItalicAtlasCell> italicCells,
    required List<String> missingGlyphs,
    required List<(String, GlyphStyleVariant)> missingStyledGlyphs,
  }) {
    final isBold = Modifier.has(modifiers, Modifier.bold);
    final isItalic = Modifier.has(modifiers, Modifier.italic);
    final variant = GlyphStyleVariant.fromFlags(
      isBold: isBold,
      isItalic: isItalic,
    );
    final sourceRect = atlas.rectFor(char, isBold: isBold, isItalic: isItalic);
    if (sourceRect == null) {
      _stageFallbackCell(
        missingGlyphs,
        missingStyledGlyphs,
        fallbackCells,
        char: char,
        variant: variant,
        gridCol: gridCol,
        gridRow: gridRow,
        modifiers: modifiers,
        fgArgb: fgArgb,
        bgArgb: bgArgb,
        screenX: screenX,
        screenY: screenY,
        geo: geo,
      );
      return (fgSpriteCount, emojiSpriteCount);
    }

    if (isColorEmoji(char)) {
      _stageEmojiSprite(emojiSpriteCount, screenX, screenY, sourceRect, geo);
      return (fgSpriteCount, emojiSpriteCount + 1);
    }

    final isBlock = _isBlockCharacter(char);
    final hasNativeStyle =
        variant == GlyphStyleVariant.regular ||
        atlas.styledCharRects.containsKey((char, variant)) ||
        atlas.styleRects.containsKey((char, isBold, isItalic));
    if (!isBlock && !hasNativeStyle) {
      missingStyledGlyphs.add((char, variant));
    }

    if (!isBlock && isItalic && !hasNativeStyle) {
      italicCells.add(
        _ItalicAtlasCell(
          sourceRect: sourceRect,
          x: screenX,
          y: screenY,
          color: resolvedFg,
          isBold: isBold,
        ),
      );
      return (fgSpriteCount, emojiSpriteCount);
    }

    _stageTextSprite(
      fgSpriteCount,
      char,
      screenX,
      screenY,
      sourceRect,
      resolvedFg,
      geo,
    );
    var nextFgCount = fgSpriteCount + 1;
    if (!isBlock && isBold && !hasNativeStyle) {
      _stageTextSprite(
        nextFgCount,
        char,
        screenX + 0.6,
        screenY,
        sourceRect,
        resolvedFg,
        geo,
      );
      nextFgCount++;
    }
    return (nextFgCount, emojiSpriteCount);
  }

  void _stageEmojiSprite(
    int eIdx,
    double screenX,
    double screenY,
    Rect sourceRect,
    _AtlasGeometry geo,
  ) {
    final base = eIdx * 4;
    _transformsEmoji![base + 0] = geo.fgScaleBlock;
    _transformsEmoji![base + 1] = 0.0;
    _transformsEmoji![base + 2] = screenX;
    _transformsEmoji![base + 3] = screenY;

    _rectsEmoji![base + 0] = sourceRect.left;
    _rectsEmoji![base + 1] = sourceRect.top;
    _rectsEmoji![base + 2] = sourceRect.right;
    _rectsEmoji![base + 3] = sourceRect.bottom;
  }

  void _stageTextSprite(
    int fgIdx,
    String char,
    double screenX,
    double screenY,
    Rect sourceRect,
    int fgColor,
    _AtlasGeometry geo,
  ) {
    final isBlock = _isBlockCharacter(char);
    final bleedFgPhysical = isBlock ? geo.bleedFgPhysicalBlock : 0.0;
    final bleedFgLogical = isBlock ? geo.bleedFgLogicalBlock : 0.0;

    final base = fgIdx * 4;
    _transformsFg![base + 0] = geo.fgScaleBlock;
    _transformsFg![base + 1] = 0.0;
    _transformsFg![base + 2] = screenX - bleedFgLogical;
    _transformsFg![base + 3] = screenY - bleedFgLogical;

    _rectsFg![base + 0] = sourceRect.left - bleedFgPhysical;
    _rectsFg![base + 1] = sourceRect.top - bleedFgPhysical;
    _rectsFg![base + 2] = sourceRect.right + bleedFgPhysical;
    _rectsFg![base + 3] = sourceRect.bottom + bleedFgPhysical;

    _colorsFg![fgIdx] = fgColor;
  }

  bool _isKittyCell(String char, int modifiers) =>
      Modifier.has(modifiers, Modifier.kittyPlaceholder) ||
      char.startsWith(kittyPlaceholderChar);

  void _stageFallbackCell(
    List<String> missingGlyphs,
    List<(String, GlyphStyleVariant)> missingStyledGlyphs,
    List<_FallbackCell> fallbackCells, {
    required String char,
    required GlyphStyleVariant variant,
    required int gridCol,
    required int gridRow,
    required int modifiers,
    required int fgArgb,
    required int bgArgb,
    required double screenX,
    required double screenY,
    required _AtlasGeometry geo,
  }) {
    final isKitty = _isKittyCell(char, modifiers);
    if (!isKitty) {
      missingGlyphs.add(char);
      missingStyledGlyphs.add((char, variant));
    }
    fallbackCells.add(
      _FallbackCell(
        char: char,
        gridCol: gridCol,
        gridRow: gridRow,
        fontFamily: fontFamily,
        fontFamilyFallback: fontFamilyFallback,
        modifiers: modifiers,
        fgArgb: fgArgb,
        bgArgb: bgArgb,
        x: screenX,
        y: screenY,
        w: isKitty
            ? geo.cellWidth
            : (isWideGrapheme(char) ? 2 * geo.cellWidth : geo.cellWidth),
        h: geo.cellHeight,
      ),
    );
  }

  void _paintItalicAtlasCells(
    Canvas canvas,
    List<_ItalicAtlasCell> cells,
    _AtlasGeometry geo,
  ) {
    final paint = Paint()..filterQuality = FilterQuality.low;
    for (final ic in cells) {
      paint.colorFilter = ColorFilter.mode(Color(ic.color), BlendMode.modulate);
      final dstW = ic.sourceRect.width * geo.fgScaleBlock;
      final dstH = ic.sourceRect.height * geo.fgScaleBlock;
      canvas.save();
      canvas.translate(ic.x + geo.cellWidth * 0.14, ic.y);
      canvas.skew(-0.18, 0.0);
      canvas.drawImageRect(
        atlas.image,
        ic.sourceRect,
        Rect.fromLTWH(0, 0, dstW, dstH),
        paint,
      );
      if (ic.isBold) {
        canvas.drawImageRect(
          atlas.image,
          ic.sourceRect,
          Rect.fromLTWH(0.6, 0, dstW, dstH),
          paint,
        );
      }
      canvas.restore();
    }
  }

  void _paintFallbackCells(Canvas canvas, List<_FallbackCell> fallbackCells) {
    final kittyPaint = Paint()
      ..style = PaintingStyle.fill
      ..filterQuality = FilterQuality.low;
    var i = 0;
    while (i < fallbackCells.length) {
      final fc = fallbackCells[i];
      if (_isKittyCell(fc.char, fc.modifiers)) {
        i = _paintKittyCellOrRun(canvas, kittyPaint, fallbackCells, i);
        continue;
      }
      _paintSingleFallbackGlyph(canvas, fc);
      i++;
    }
  }

  void _paintLigatureCells(
    Canvas canvas,
    List<_LigatureCell> cells,
    _AtlasGeometry geo,
  ) {
    for (final lc in cells) {
      final offsetX = (lc.w - lc.painter.width) / 2;
      final offsetY = (lc.h - lc.painter.height) / 2;
      lc.painter.paint(canvas, Offset(lc.x + offsetX, lc.y + offsetY));
    }
  }

  void _paintSingleFallbackGlyph(Canvas canvas, _FallbackCell fc) {
    final isReverse = Modifier.has(fc.modifiers, Modifier.reverse);
    final color = Color(
      _resolveFgColor(
        fc.fgArgb,
        fc.bgArgb,
        modifiers: fc.modifiers,
        isReverse: isReverse,
      ),
    );
    final isBold = Modifier.has(fc.modifiers, Modifier.bold);
    final isItalic = Modifier.has(fc.modifiers, Modifier.italic);
    final isDim = Modifier.has(fc.modifiers, Modifier.dim);

    final tp = fallbackPainters[(fc.char, isBold, isItalic, isDim, color)];
    if (tp != null) {
      final offsetX = (fc.w - tp.width) / 2;
      final offsetY = (fc.h - tp.height) / 2;
      tp.paint(canvas, Offset(fc.x + offsetX, fc.y + offsetY));
    }
  }

  int _paintKittyCellOrRun(
    Canvas canvas,
    Paint paint,
    List<_FallbackCell> cells,
    int index,
  ) {
    final fc = cells[index];
    final coords = parseKittyPlaceholderCell(fc.char);
    if (coords == null) return index + 1;

    final imageId =
        (((coords.imageIdMsb ?? 0) & 0xFF) << 24) | (fc.fgArgb & 0xFFFFFF);
    final registry = buffer.lookupKittyRegistry(fc.gridCol, fc.gridRow);
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
      _paintKittySubpixels(canvas, paint, fc, data, coords.row, coords.col);
      return index + 1;
    }

    var endIdx = index + 1;
    var lastTileCol = coords.col;
    var lastGridCol = fc.gridCol;
    while (endIdx < cells.length &&
        _isNextKittyRunCell(
          cells[endIdx],
          data: data,
          imageId: imageId,
          expectedGridRow: fc.gridRow,
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
    canvas.drawImageRect(
      gpuImage,
      Rect.fromLTWH(
        coords.col * tileW,
        coords.row * tileH,
        runCols * tileW,
        tileH,
      ),
      Rect.fromLTWH(fc.x, fc.y, runCols * fc.w + 0.25, fc.h + 0.25),
      paint,
    );
    return endIdx;
  }

  bool _isNextKittyRunCell(
    _FallbackCell next, {
    required KittyImageData data,
    required int imageId,
    required int expectedGridRow,
    required int expectedGridCol,
    required int expectedTileRow,
    required int expectedTileCol,
  }) {
    if (!_isKittyCell(next.char, next.modifiers)) return false;
    if (next.gridRow != expectedGridRow || next.gridCol != expectedGridCol) {
      return false;
    }
    final coords = parseKittyPlaceholderCell(next.char);
    if (coords == null ||
        coords.row != expectedTileRow ||
        coords.col != expectedTileCol) {
      return false;
    }
    final nextId =
        (((coords.imageIdMsb ?? 0) & 0xFF) << 24) | (next.fgArgb & 0xFFFFFF);
    if (nextId != imageId) return false;
    final nextData = buffer.lookupKittyImage(
      next.gridCol,
      next.gridRow,
      nextId,
    );
    return identical(nextData, data);
  }

  void _paintKittySubpixels(
    Canvas canvas,
    Paint paint,
    _FallbackCell fc,
    KittyImageData data,
    int tileRow,
    int tileCol,
  ) {
    if (data.format == 100) return;
    final stepsX = math.min(
      2,
      math.max(1, data.pixelWidth ~/ math.max(1, data.gridCols)),
    );
    final stepsY = math.min(
      4,
      math.max(1, data.pixelHeight ~/ math.max(1, data.gridRows)),
    );
    final subW = fc.w / stepsX;
    final subH = fc.h / stepsY;

    for (var sy = 0; sy < stepsY; sy++) {
      final normY = (tileRow + (sy + 0.5) / stepsY) / data.gridRows;
      final py = (normY * data.pixelHeight).floor().clamp(
        0,
        data.pixelHeight - 1,
      );
      _paintKittySubpixelRow(
        canvas,
        paint,
        fc,
        data,
        tileCol,
        stepsX,
        subW,
        subH,
        py * data.pixelWidth * 4,
        fc.y + sy * subH,
      );
    }
  }

  void _paintKittySubpixelRow(
    Canvas canvas,
    Paint paint,
    _FallbackCell fc,
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
          fc.x + sx * subW,
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

  void _paintDecorations(Canvas canvas, List<_CellDecoration> decorations) {
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.0;

    for (final d in decorations) {
      if (Modifier.has(d.modifiers, Modifier.overline)) {
        paint.color = Color(d.fgColor);
        final topY = d.y + 0.5;
        canvas.drawLine(Offset(d.x, topY), Offset(d.x + d.w, topY), paint);
      }
      if (Modifier.has(d.modifiers, Modifier.crossedOut)) {
        paint.color = Color(d.fgColor);
        final midY = (d.y + d.h * 0.5).floorToDouble() + 0.5;
        canvas.drawLine(Offset(d.x, midY), Offset(d.x + d.w, midY), paint);
      }
      if (Modifier.has(d.modifiers, Modifier.underline)) {
        paint.color = Color(d.ulColor);
        _drawUnderlineVariant(
          canvas,
          paint,
          d.x,
          d.y,
          d.w,
          d.h,
          Modifier.getUnderlineStyle(d.modifiers),
        );
      }
    }
  }

  void _drawUnderlineVariant(
    Canvas canvas,
    Paint paint,
    double x,
    double y,
    double w,
    double h,
    UnderlineStyle style,
  ) {
    final baseY = y + h - 1.5;
    switch (style) {
      case UnderlineStyle.none:
        break;
      case UnderlineStyle.single:
        canvas.drawLine(Offset(x, baseY), Offset(x + w, baseY), paint);
      case UnderlineStyle.doubleLine:
        canvas.drawLine(
          Offset(x, y + h - 2.5),
          Offset(x + w, y + h - 2.5),
          paint,
        );
        canvas.drawLine(
          Offset(x, y + h - 0.5),
          Offset(x + w, y + h - 0.5),
          paint,
        );
      case UnderlineStyle.curly:
        _drawCurlyLine(canvas, paint, x, y + h - 2.0, w);
      case UnderlineStyle.dotted:
        _drawSegmentedLine(canvas, paint, x, baseY, w, dash: 1.0, gap: 1.5);
      case UnderlineStyle.dashed:
        _drawSegmentedLine(canvas, paint, x, baseY, w, dash: 2.5, gap: 1.5);
    }
  }

  void _drawCurlyLine(
    Canvas canvas,
    Paint paint,
    double x,
    double baseY,
    double w,
  ) {
    final path = Path()..moveTo(x, baseY);
    const step = 2.0;
    const amp = 1.2;
    var curX = x;
    var up = true;
    while (curX < x + w) {
      final nextX = (curX + step <= x + w) ? curX + step : x + w;
      final midX = (curX + nextX) * 0.5;
      path.quadraticBezierTo(midX, baseY + (up ? -amp : amp), nextX, baseY);
      curX = nextX;
      up = !up;
    }
    canvas.drawPath(path, paint);
  }

  void _drawSegmentedLine(
    Canvas canvas,
    Paint paint,
    double x,
    double baseY,
    double w, {
    required double dash,
    required double gap,
  }) {
    var curX = x;
    while (curX < x + w) {
      final endX = (curX + dash <= x + w) ? curX + dash : x + w;
      canvas.drawLine(Offset(curX, baseY), Offset(endX, baseY), paint);
      curX += dash + gap;
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
  // Buffer cells mutate in place across frames without changing identity.
  bool shouldRepaint(covariant TuiAtlasPainter oldDelegate) => true;
}

final class _AtlasGeometry {
  final double cellWidth;
  final double cellHeight;
  final double bleedBgLogical;
  final double bleedFgPhysicalBlock;
  final double bleedFgLogicalBlock;
  final double bgScaleBlock;
  final double fgScaleBlock;
  final double bgRect0;
  final double bgRect1;
  final double bgRect2;
  final double bgRect3;

  const _AtlasGeometry({
    required this.cellWidth,
    required this.cellHeight,
    required this.bleedBgLogical,
    required this.bleedFgPhysicalBlock,
    required this.bleedFgLogicalBlock,
    required this.bgScaleBlock,
    required this.fgScaleBlock,
    required this.bgRect0,
    required this.bgRect1,
    required this.bgRect2,
    required this.bgRect3,
  });

  factory _AtlasGeometry.fromAtlas(
    GlyphAtlas atlas, {
    required bool enableBleed,
  }) {
    final cellWidth = atlas.cellWidth;
    final cellHeight = atlas.cellHeight;
    final bgRect = atlas.charRects['\uFFFF']!;
    final whiteX = bgRect.left;
    final whiteY = bgRect.top;
    final whiteW = bgRect.width;
    final whiteH = bgRect.height;

    final bleedPhysical = enableBleed
        ? (0.5 * atlas.devicePixelRatio).ceilToDouble()
        : 0.0;
    final bleedBgLogical = bleedPhysical * (cellWidth / whiteW);
    final bleedFgLogicalBlock = bleedPhysical / atlas.devicePixelRatio;
    final bgScaleBlock = cellWidth / whiteW;
    final fgScaleBlock = (cellWidth / atlas.cellWidth) / atlas.devicePixelRatio;

    return _AtlasGeometry(
      cellWidth: cellWidth,
      cellHeight: cellHeight,
      bleedBgLogical: bleedBgLogical,
      bleedFgPhysicalBlock: bleedPhysical,
      bleedFgLogicalBlock: bleedFgLogicalBlock,
      bgScaleBlock: bgScaleBlock,
      fgScaleBlock: fgScaleBlock,
      bgRect0: whiteX - bleedPhysical,
      bgRect1: whiteY - bleedPhysical,
      bgRect2: whiteX + whiteW + bleedPhysical,
      bgRect3: whiteY + whiteH + bleedPhysical,
    );
  }
}

final class _ItalicAtlasCell {
  final Rect sourceRect;
  final double x;
  final double y;
  final int color;
  final bool isBold;

  const _ItalicAtlasCell({
    required this.sourceRect,
    required this.x,
    required this.y,
    required this.color,
    required this.isBold,
  });
}

final class _CellDecoration {
  final double x;
  final double y;
  final double w;
  final double h;
  final int modifiers;
  final int fgColor;
  final int ulColor;

  const _CellDecoration({
    required this.x,
    required this.y,
    required this.w,
    required this.h,
    required this.modifiers,
    required this.fgColor,
    required this.ulColor,
  });
}

final class _FallbackCell {
  final String char;
  final int gridCol;
  final int gridRow;
  final String fontFamily;
  final List<String>? fontFamilyFallback;
  final int modifiers;
  final int fgArgb;
  final int bgArgb;
  final double x;
  final double y;
  final double w;
  final double h;

  _FallbackCell({
    required this.char,
    required this.gridCol,
    required this.gridRow,
    required this.fontFamily,
    this.fontFamilyFallback,
    required this.modifiers,
    required this.fgArgb,
    required this.bgArgb,
    required this.x,
    required this.y,
    required this.w,
    required this.h,
  });
}

final class _LigatureCell {
  final String text;
  final TextPainter painter;
  final double x;
  final double y;
  final double w;
  final double h;

  const _LigatureCell({
    required this.text,
    required this.painter,
    required this.x,
    required this.y,
    required this.w,
    required this.h,
  });
}
