import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:termui/ui/buffer.dart';
import 'package:termui/ui/style.dart';
import 'package:termui/ui/widgets/display/kitty_image.dart';
import 'atlas.dart';

bool _isBlockCharacter(String char) {
  if (char.isEmpty) return false;
  final code = char.codeUnitAt(0);
  return code >= 0x2580 && code <= 0x2590;
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

  /// Cache of individual [TextPainter] objects for glyphs absent in the main atlas.
  final Map<(String, bool, bool, Color), TextPainter> fallbackPainters;

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

  /// Constructs a [TuiAtlasPainter] targeting the supplied [buffer].
  TuiAtlasPainter({
    required this.buffer,
    required this.atlas,
    required this.fontFamily,
    this.fontFamilyFallback,
    required this.fallbackPainters,
    required this.onMissingGlyphs,
    this.enableBleed = kIsWeb,
  });

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
    final missingGlyphs = <String>[];

    final (fgSpriteCount, emojiSpriteCount) = _stageGridCells(
      geo,
      fallbackCells,
      italicCells,
      decorations,
      missingGlyphs,
    );

    if (missingGlyphs.isNotEmpty && onMissingGlyphs != null) {
      SchedulerBinding.instance.addPostFrameCallback((_) {
        onMissingGlyphs!(missingGlyphs);
      });
    }

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

    if (decorations.isNotEmpty) {
      _paintDecorations(canvas, decorations);
    }
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

  (int, int) _stageGridCells(
    _AtlasGeometry geo,
    List<_FallbackCell> fallbackCells,
    List<_ItalicAtlasCell> italicCells,
    List<_CellDecoration> decorations,
    List<String> missingGlyphs,
  ) {
    final cols = buffer.width;
    final rows = buffer.height;
    var fgSpriteCount = 0;
    var emojiSpriteCount = 0;

    for (var y = 0; y < rows; y++) {
      final screenY = y * geo.cellHeight;
      for (var x = 0; x < cols; x++) {
        final char = buffer.getCharacter(x, y);
        final bgArgb = buffer.getBackground(x, y);
        final fgArgb = buffer.getForeground(x, y);
        final modifiers = buffer.getModifiers(x, y);
        final isReverse = Modifier.has(modifiers, Modifier.reverse);

        final idx = y * cols + x;
        final screenX = x * geo.cellWidth;

        _stageBackgroundSprite(
          idx,
          screenX,
          screenY,
          _resolveBgColor(bgArgb, fgArgb, isReverse: isReverse),
          geo,
        );

        final resolvedFg = _resolveFgColor(
          fgArgb,
          bgArgb,
          modifiers: modifiers,
          isReverse: isReverse,
        );

        if (Modifier.has(modifiers, Modifier.hidden)) {
          continue;
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
          continue;
        }

        (fgSpriteCount, emojiSpriteCount) = _stageForegroundCell(
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
        );
      }
    }

    return (fgSpriteCount, emojiSpriteCount);
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
    decorations.add(
      _CellDecoration(
        x: screenX,
        y: screenY,
        w: isWideGrapheme(char) ? 2 * geo.cellWidth : geo.cellWidth,
        h: geo.cellHeight,
        modifiers: modifiers,
        fgColor: resolvedFg,
        ulColor: ulArgb != 0 ? ulArgb : resolvedFg,
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
  }) {
    final sourceRect = atlas.charRects[char];
    if (sourceRect == null) {
      _stageFallbackCell(
        missingGlyphs,
        fallbackCells,
        char: char,
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
    if (!isBlock && Modifier.has(modifiers, Modifier.italic)) {
      italicCells.add(
        _ItalicAtlasCell(
          sourceRect: sourceRect,
          x: screenX,
          y: screenY,
          color: resolvedFg,
          isBold: Modifier.has(modifiers, Modifier.bold),
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
    if (!isBlock && Modifier.has(modifiers, Modifier.bold)) {
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
    List<_FallbackCell> fallbackCells, {
    required String char,
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
    final kittyPaint = Paint()..style = PaintingStyle.fill;
    for (final fc in fallbackCells) {
      if (_isKittyCell(fc.char, fc.modifiers)) {
        _paintKittyPlaceholderCell(canvas, kittyPaint, fc);
        continue;
      }
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
      final isDim = Modifier.has(fc.modifiers, Modifier.dim);

      final tp = fallbackPainters[(fc.char, isBold, isDim, color)];
      if (tp != null) {
        final offsetX = (fc.w - tp.width) / 2;
        final offsetY = (fc.h - tp.height) / 2;
        tp.paint(canvas, Offset(fc.x + offsetX, fc.y + offsetY));
      }
    }
  }

  void _paintKittyPlaceholderCell(
    Canvas canvas,
    Paint paint,
    _FallbackCell fc,
  ) {
    final coords = parseKittyPlaceholderCell(fc.char);
    if (coords == null) return;
    final imageId =
        (((coords.imageIdMsb ?? 0) & 0xFF) << 24) | (fc.fgArgb & 0xFFFFFF);
    final data = buffer.lookupKittyImage(fc.gridCol, fc.gridRow, imageId);
    if (data == null ||
        data.gridCols <= 0 ||
        data.gridRows <= 0 ||
        coords.row >= data.gridRows ||
        coords.col >= data.gridCols) {
      return;
    }
    _paintKittySubpixels(canvas, paint, fc, data, coords.row, coords.col);
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
      4,
      math.max(1, data.pixelWidth ~/ math.max(1, data.gridCols)),
    );
    final stepsY = math.min(
      8,
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

  static int _resolveBgColor(
    int bgArgb,
    int fgArgb, {
    required bool isReverse,
  }) {
    if (isReverse) {
      return fgArgb == 0 ? 0xFFFFFFFF : fgArgb;
    }
    return bgArgb == 0 ? 0xFF000000 : bgArgb;
  }

  static int _resolveFgColor(
    int fgArgb,
    int bgArgb, {
    required int modifiers,
    required bool isReverse,
  }) {
    final raw = isReverse
        ? (bgArgb == 0 ? 0xFF000000 : bgArgb)
        : (fgArgb == 0 ? 0xFFFFFFFF : fgArgb);
    if (Modifier.has(modifiers, Modifier.dim)) {
      final a = (((raw >> 24) & 0xFF) * 140) ~/ 255;
      return (a << 24) | (raw & 0x00FFFFFF);
    }
    return raw;
  }

  @override
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
