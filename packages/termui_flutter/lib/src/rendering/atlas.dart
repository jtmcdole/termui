import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart' hide Color;
import 'package:termui/ui/buffer.dart';

import 'atlas_quad_table.dart';

/// Returns whether [char] is rasterized procedurally by
/// [drawProceduralCharacter] rather than via font text shaping.
bool isProceduralAtlasCharacter(String char) {
  if (char.length != 1) return false;
  return switch (char.codeUnitAt(0)) {
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
}

/// Procedurally renders block, shade, and box-drawing characters on a Canvas.
///
/// By bypassing standard font rendering for specific character codes, this
/// function avoids anti-aliasing artifacts, line gaps, and kerning issues
/// that commonly affect monospaced terminal fonts when displaying box lines or
/// full blocks (e.g. `█`, `░`, `┌`, `═`).
///
/// Returns `true` if the character was drawn procedurally, or `false` if it
/// should fall back to standard text rendering.
///
/// | Parameter | Type | Description |
/// | :--- | :--- | :--- |
/// | `canvas` | [Canvas] | The canvas to draw the character on. |
/// | `paintX` | [double] | The X coordinate of the top-left corner of the cell. |
/// | `paintY` | [double] | The Y coordinate of the top-left corner of the cell. |
/// | `w` | [double] | The width of the cell. |
/// | `h` | [double] | The height of the cell. |
/// | `padding` | [double] | Overlap padding to prevent seams between cells. |
/// | `char` | [String] | The character (grapheme) to draw. |
/// | `paint` | [Paint] | The styling paint to apply. |
///
/// ### Example Usage
///
/// ```dart
/// final paint = Paint()..color = const ui.Color(0xFFFFFFFF);
/// final handled = drawProceduralCharacter(
///   canvas, 0.0, 0.0, 10.0, 20.0, 1.0, '█', paint,
/// );
/// if (!handled) {
///   // Fall back to standard rendering
/// }
/// ```
bool drawProceduralCharacter(
  Canvas canvas,
  double paintX,
  double paintY,
  double w,
  double h,
  double padding,
  String char,
  Paint paint,
) {
  if (char.length != 1) return false;
  final code = char.codeUnitAt(0);
  if (code >= 0x2580 && code <= 0x2590) {
    return _drawProceduralBlock(
      canvas,
      paintX,
      paintY,
      w,
      h,
      padding,
      code,
      paint,
    );
  }
  if (code >= 0x2591 && code <= 0x2593) {
    return _drawProceduralShade(
      canvas,
      paintX,
      paintY,
      w,
      h,
      padding,
      code,
      paint,
    );
  }
  if (code >= 0x2500 && code <= 0x253C) {
    return _drawThinBoxCharacter(
      canvas,
      paintX,
      paintY,
      w,
      h,
      padding,
      code,
      paint,
    );
  }
  if (code >= 0x2550 && code <= 0x255D) {
    return _drawDoubleBoxCharacter(
      canvas,
      paintX,
      paintY,
      w,
      h,
      padding,
      code,
      paint,
    );
  }
  return false;
}

bool _drawProceduralBlock(
  Canvas canvas,
  double paintX,
  double paintY,
  double w,
  double h,
  double padding,
  int code,
  Paint paint,
) {
  final Rect? rect = switch (code) {
    0x2588 => Rect.fromLTWH(
      paintX - padding,
      paintY - padding,
      w + 2 * padding,
      h + 2 * padding,
    ),
    0x258F => Rect.fromLTWH(
      paintX - padding,
      paintY - padding,
      w * 1 / 8 + padding,
      h + 2 * padding,
    ),
    0x258E => Rect.fromLTWH(
      paintX - padding,
      paintY - padding,
      w * 2 / 8 + padding,
      h + 2 * padding,
    ),
    0x258D => Rect.fromLTWH(
      paintX - padding,
      paintY - padding,
      w * 3 / 8 + padding,
      h + 2 * padding,
    ),
    0x258C => Rect.fromLTWH(
      paintX - padding,
      paintY - padding,
      w * 4 / 8 + padding,
      h + 2 * padding,
    ),
    0x258B => Rect.fromLTWH(
      paintX - padding,
      paintY - padding,
      w * 5 / 8 + padding,
      h + 2 * padding,
    ),
    0x258A => Rect.fromLTWH(
      paintX - padding,
      paintY - padding,
      w * 6 / 8 + padding,
      h + 2 * padding,
    ),
    0x2589 => Rect.fromLTWH(
      paintX - padding,
      paintY - padding,
      w * 7 / 8 + padding,
      h + 2 * padding,
    ),
    0x2590 => Rect.fromLTWH(
      paintX + w * 4 / 8,
      paintY - padding,
      w * 4 / 8 + padding,
      h + 2 * padding,
    ),
    0x2580 => Rect.fromLTWH(
      paintX - padding,
      paintY - padding,
      w + 2 * padding,
      h * 0.5 + padding,
    ),
    0x2584 => Rect.fromLTWH(
      paintX - padding,
      paintY + h * 0.5,
      w + 2 * padding,
      h * 0.5 + padding,
    ),
    _ => null,
  };
  if (rect == null) return false;
  canvas.drawRect(rect, paint);
  return true;
}

bool _drawProceduralShade(
  Canvas canvas,
  double paintX,
  double paintY,
  double w,
  double h,
  double padding,
  int code,
  Paint paint,
) {
  final int? alpha = switch (code) {
    0x2591 => 64,
    0x2592 => 128,
    0x2593 => 192,
    _ => null,
  };
  if (alpha == null) return false;
  final originalColor = paint.color;
  paint.color = originalColor.withAlpha(alpha);
  canvas.drawRect(
    Rect.fromLTWH(
      paintX - padding,
      paintY - padding,
      w + 2 * padding,
      h + 2 * padding,
    ),
    paint,
  );
  paint.color = originalColor;
  return true;
}

bool _drawThinBoxCharacter(
  Canvas canvas,
  double paintX,
  double paintY,
  double w,
  double h,
  double padding,
  int code,
  Paint paint,
) {
  final halfW = w / 2;
  final halfH = h / 2;
  const thickness = 1.2;

  void drawH(double x0, double x1) => canvas.drawRect(
    Rect.fromLTRB(
      x0,
      paintY + halfH - thickness / 2,
      x1,
      paintY + halfH + thickness / 2,
    ),
    paint,
  );
  void drawV(double y0, double y1) => canvas.drawRect(
    Rect.fromLTRB(
      paintX + halfW - thickness / 2,
      y0,
      paintX + halfW + thickness / 2,
      y1,
    ),
    paint,
  );

  switch (code) {
    case 0x2500:
      drawH(paintX - padding, paintX + w + padding);
    case 0x2502:
      drawV(paintY - padding, paintY + h + padding);
    case 0x250C:
      drawH(paintX + halfW, paintX + w + padding);
      drawV(paintY + halfH, paintY + h + padding);
    case 0x2510:
      drawH(paintX - padding, paintX + halfW);
      drawV(paintY + halfH, paintY + h + padding);
    case 0x2514:
      drawH(paintX + halfW, paintX + w + padding);
      drawV(paintY - padding, paintY + halfH);
    case 0x2518:
      drawH(paintX - padding, paintX + halfW);
      drawV(paintY - padding, paintY + halfH);
    case 0x251C:
      drawH(paintX + halfW, paintX + w + padding);
      drawV(paintY - padding, paintY + h + padding);
    case 0x2524:
      drawH(paintX - padding, paintX + halfW);
      drawV(paintY - padding, paintY + h + padding);
    case 0x252C:
      drawH(paintX - padding, paintX + w + padding);
      drawV(paintY + halfH, paintY + h + padding);
    case 0x2534:
      drawH(paintX - padding, paintX + w + padding);
      drawV(paintY - padding, paintY + halfH);
    case 0x253C:
      drawH(paintX - padding, paintX + w + padding);
      drawV(paintY - padding, paintY + h + padding);
    default:
      return false;
  }
  return true;
}

bool _drawDoubleBoxCharacter(
  Canvas canvas,
  double paintX,
  double paintY,
  double w,
  double h,
  double padding,
  int code,
  Paint paint,
) {
  final halfW = w / 2;
  final halfH = h / 2;
  const dThickness = 1.0;
  const dGap = 2.0;

  switch (code) {
    case 0x2550:
      _drawDoubleHLine(
        canvas,
        paintX,
        paintY,
        halfH,
        dGap,
        dThickness,
        paintX - padding,
        paintX + w + padding,
        paint,
      );
    case 0x2551:
      _drawDoubleVLine(
        canvas,
        paintX,
        halfW,
        dGap,
        dThickness,
        paintY - padding,
        paintY + h + padding,
        paint,
      );
    case 0x2554:
      _drawDoubleCornerTL(
        canvas,
        paintX,
        paintY,
        w,
        h,
        halfW,
        halfH,
        padding,
        dGap,
        dThickness,
        paint,
      );
    case 0x2557:
      _drawDoubleCornerTR(
        canvas,
        paintX,
        paintY,
        h,
        halfW,
        halfH,
        padding,
        dGap,
        dThickness,
        paint,
      );
    case 0x255A:
      _drawDoubleCornerBL(
        canvas,
        paintX,
        paintY,
        w,
        halfW,
        halfH,
        padding,
        dGap,
        dThickness,
        paint,
      );
    case 0x255D:
      _drawDoubleCornerBR(
        canvas,
        paintX,
        paintY,
        halfW,
        halfH,
        padding,
        dGap,
        dThickness,
        paint,
      );
    default:
      return false;
  }
  return true;
}

void _drawDoubleHLine(
  Canvas canvas,
  double paintX,
  double paintY,
  double halfH,
  double dGap,
  double dThickness,
  double xStart,
  double xEnd,
  Paint paint,
) {
  canvas.drawRect(
    Rect.fromLTRB(
      xStart,
      paintY + halfH - dGap / 2 - dThickness,
      xEnd,
      paintY + halfH - dGap / 2,
    ),
    paint,
  );
  canvas.drawRect(
    Rect.fromLTRB(
      xStart,
      paintY + halfH + dGap / 2,
      xEnd,
      paintY + halfH + dGap / 2 + dThickness,
    ),
    paint,
  );
}

void _drawDoubleVLine(
  Canvas canvas,
  double paintX,
  double halfW,
  double dGap,
  double dThickness,
  double yStart,
  double yEnd,
  Paint paint,
) {
  canvas.drawRect(
    Rect.fromLTRB(
      paintX + halfW - dGap / 2 - dThickness,
      yStart,
      paintX + halfW - dGap / 2,
      yEnd,
    ),
    paint,
  );
  canvas.drawRect(
    Rect.fromLTRB(
      paintX + halfW + dGap / 2,
      yStart,
      paintX + halfW + dGap / 2 + dThickness,
      yEnd,
    ),
    paint,
  );
}

void _drawDoubleCornerTL(
  Canvas canvas,
  double paintX,
  double paintY,
  double w,
  double h,
  double halfW,
  double halfH,
  double padding,
  double dGap,
  double dThickness,
  Paint paint,
) {
  canvas.drawRect(
    Rect.fromLTRB(
      paintX + halfW - dGap / 2 - dThickness,
      paintY + halfH - dGap / 2 - dThickness,
      paintX + w + padding,
      paintY + halfH - dGap / 2,
    ),
    paint,
  );
  canvas.drawRect(
    Rect.fromLTRB(
      paintX + halfW + dGap / 2,
      paintY + halfH + dGap / 2,
      paintX + w + padding,
      paintY + halfH + dGap / 2 + dThickness,
    ),
    paint,
  );
  canvas.drawRect(
    Rect.fromLTRB(
      paintX + halfW - dGap / 2 - dThickness,
      paintY + halfH - dGap / 2 - dThickness,
      paintX + halfW - dGap / 2,
      paintY + h + padding,
    ),
    paint,
  );
  canvas.drawRect(
    Rect.fromLTRB(
      paintX + halfW + dGap / 2,
      paintY + halfH + dGap / 2,
      paintX + halfW + dGap / 2 + dThickness,
      paintY + h + padding,
    ),
    paint,
  );
}

void _drawDoubleCornerTR(
  Canvas canvas,
  double paintX,
  double paintY,
  double h,
  double halfW,
  double halfH,
  double padding,
  double dGap,
  double dThickness,
  Paint paint,
) {
  canvas.drawRect(
    Rect.fromLTRB(
      paintX - padding,
      paintY + halfH - dGap / 2 - dThickness,
      paintX + halfW + dGap / 2 + dThickness,
      paintY + halfH - dGap / 2,
    ),
    paint,
  );
  canvas.drawRect(
    Rect.fromLTRB(
      paintX - padding,
      paintY + halfH + dGap / 2,
      paintX + halfW - dGap / 2,
      paintY + halfH + dGap / 2 + dThickness,
    ),
    paint,
  );
  canvas.drawRect(
    Rect.fromLTRB(
      paintX + halfW - dGap / 2 - dThickness,
      paintY + halfH + dGap / 2,
      paintX + halfW - dGap / 2,
      paintY + h + padding,
    ),
    paint,
  );
  canvas.drawRect(
    Rect.fromLTRB(
      paintX + halfW + dGap / 2,
      paintY + halfH - dGap / 2 - dThickness,
      paintX + halfW + dGap / 2 + dThickness,
      paintY + h + padding,
    ),
    paint,
  );
}

void _drawDoubleCornerBL(
  Canvas canvas,
  double paintX,
  double paintY,
  double w,
  double halfW,
  double halfH,
  double padding,
  double dGap,
  double dThickness,
  Paint paint,
) {
  canvas.drawRect(
    Rect.fromLTRB(
      paintX + halfW - dGap / 2 - dThickness,
      paintY + halfH + dGap / 2,
      paintX + w + padding,
      paintY + halfH + dGap / 2 + dThickness,
    ),
    paint,
  );
  canvas.drawRect(
    Rect.fromLTRB(
      paintX + halfW + dGap / 2,
      paintY + halfH - dGap / 2 - dThickness,
      paintX + w + padding,
      paintY + halfH - dGap / 2,
    ),
    paint,
  );
  canvas.drawRect(
    Rect.fromLTRB(
      paintX + halfW - dGap / 2 - dThickness,
      paintY - padding,
      paintX + halfW - dGap / 2,
      paintY + halfH + dGap / 2 + dThickness,
    ),
    paint,
  );
  canvas.drawRect(
    Rect.fromLTRB(
      paintX + halfW + dGap / 2,
      paintY - padding,
      paintX + halfW + dGap / 2 + dThickness,
      paintY + halfH - dGap / 2,
    ),
    paint,
  );
}

void _drawDoubleCornerBR(
  Canvas canvas,
  double paintX,
  double paintY,
  double halfW,
  double halfH,
  double padding,
  double dGap,
  double dThickness,
  Paint paint,
) {
  canvas.drawRect(
    Rect.fromLTRB(
      paintX - padding,
      paintY + halfH + dGap / 2,
      paintX + halfW + dGap / 2 + dThickness,
      paintY + halfH + dGap / 2 + dThickness,
    ),
    paint,
  );
  canvas.drawRect(
    Rect.fromLTRB(
      paintX - padding,
      paintY + halfH - dGap / 2 - dThickness,
      paintX + halfW - dGap / 2,
      paintY + halfH - dGap / 2,
    ),
    paint,
  );
  canvas.drawRect(
    Rect.fromLTRB(
      paintX + halfW - dGap / 2 - dThickness,
      paintY - padding,
      paintX + halfW - dGap / 2,
      paintY + halfH - dGap / 2,
    ),
    paint,
  );
  canvas.drawRect(
    Rect.fromLTRB(
      paintX + halfW + dGap / 2,
      paintY - padding,
      paintX + halfW + dGap / 2 + dThickness,
      paintY + halfH + dGap / 2 + dThickness,
    ),
    paint,
  );
}

/// Typographic style variants stored in [GlyphAtlas].
enum GlyphStyleVariant {
  /// Upright normal-weight style.
  regular,

  /// Upright bold-weight style.
  bold,

  /// Italic normal-weight style.
  italic,

  /// Italic bold-weight style.
  boldItalic;

  /// Whether this variant uses bold font weight.
  bool get isBold => this == bold || this == boldItalic;

  /// Whether this variant uses italic font style.
  bool get isItalic => this == italic || this == boldItalic;

  /// Resolves the [GlyphStyleVariant] matching [isBold] and [isItalic].
  static GlyphStyleVariant fromFlags({
    required bool isBold,
    required bool isItalic,
  }) => switch ((isBold, isItalic)) {
    (true, true) => boldItalic,
    (true, false) => bold,
    (false, true) => italic,
    (false, false) => regular,
  };
}

const List<String> _prebakedLigatures = [
  '->',
  '=>',
  '!=',
  '==',
  '<=',
  '>=',
  '===',
  '!==',
  '::',
  '|>',
  '&&',
  '||',
  '++',
  '--',
  '//',
  '??',
  '?.',
  '..',
  '...',
];

bool _isColorEmojiAtlas(String char) {
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

const List<ui.FontFeature> _atlasLigatureFontFeatures = [
  ui.FontFeature.enable('liga'),
  ui.FontFeature.enable('calt'),
  ui.FontFeature.enable('dlig'),
];

bool _isAsciiLigature(String char) =>
    char.length > 1 && char.codeUnits.every((c) => c >= 0x21 && c <= 0x7E);

TextPainter _createAtlasTextPainter({
  required String char,
  required double fontSize,
  required String fontFamily,
  List<String>? fontFamilyFallback,
  bool bold = false,
  bool italic = false,
}) {
  return TextPainter(
    text: TextSpan(
      text: char,
      style: TextStyle(
        fontSize: fontSize,
        fontFamily: fontFamily,
        fontFamilyFallback: fontFamilyFallback,
        fontFeatures: _isAsciiLigature(char)
            ? _atlasLigatureFontFeatures
            : null,
        color: const ui.Color(0xFFFFFFFF),
        fontWeight: bold ? FontWeight.bold : FontWeight.normal,
        fontStyle: italic ? FontStyle.italic : FontStyle.normal,
        letterSpacing: 0.0,
      ),
    ),
    textDirection: TextDirection.ltr,
  )..layout();
}

int _resolveGlyphCellSpan(String char) {
  if (_isColorEmojiAtlas(char)) {
    return isWideGrapheme(char) ? 2 : 1;
  }
  if (char.length > 1 && char.codeUnits.every((c) => c >= 0x21 && c <= 0x7E)) {
    return char.length;
  }
  return isWideGrapheme(char) ? 2 : 1;
}

(List<_PlacedGlyph>, int) _placeMeasuredGlyphs(
  List<_GlyphMeasure> measures, {
  required int startIndex,
  required int numCols,
}) {
  final placed = <_PlacedGlyph>[];
  var currentIdx = startIndex;
  for (final gm in measures) {
    var col = currentIdx % numCols;
    if (col + gm.cellSpan > numCols) {
      currentIdx += numCols - col;
      col = 0;
    }
    final row = currentIdx ~/ numCols;
    placed.add(
      _PlacedGlyph(
        gm.char,
        gm.painter,
        gm.cellSpan,
        col,
        row,
        variant: gm.variant,
      ),
    );
    currentIdx += gm.cellSpan;
  }
  return (placed, currentIdx);
}

void _rasterizePlacedGlyphs({
  required Canvas canvas,
  required List<_PlacedGlyph> placedGlyphs,
  required double colWidth,
  required double rowHeight,
  required double cellWidth,
  required double cellHeight,
  required double actualPadding,
  required double standardBaseline,
  required double devicePixelRatio,
  required Map<String, Rect> charRects,
  required Map<(String, bool, bool), Rect> styleRects,
  required Map<(String, GlyphStyleVariant), Rect> styledCharRects,
}) {
  for (final pg in placedGlyphs) {
    final (rect, procedural) = _paintSingleAtlasGlyph(
      canvas: canvas,
      pg: pg,
      colWidth: colWidth,
      rowHeight: rowHeight,
      cellWidth: cellWidth,
      cellHeight: cellHeight,
      actualPadding: actualPadding,
      standardBaseline: standardBaseline,
      devicePixelRatio: devicePixelRatio,
    );
    _recordAtlasGlyphRect(
      pg: pg,
      rect: rect,
      procedural: procedural,
      charRects: charRects,
      styleRects: styleRects,
      styledCharRects: styledCharRects,
    );
  }
}

(Rect, bool) _paintSingleAtlasGlyph({
  required Canvas canvas,
  required _PlacedGlyph pg,
  required double colWidth,
  required double rowHeight,
  required double cellWidth,
  required double cellHeight,
  required double actualPadding,
  required double standardBaseline,
  required double devicePixelRatio,
}) {
  final x = pg.col * colWidth;
  final y = pg.row * rowHeight;
  final targetWidth = pg.cellSpan * cellWidth;
  final proceduralPad =
      (1.0 * devicePixelRatio).ceilToDouble() / devicePixelRatio;
  final overhang =
      (GlyphAtlas.overhang * devicePixelRatio).floorToDouble() /
      devicePixelRatio;
  final isProcedural = isProceduralAtlasCharacter(pg.char);

  canvas.save();
  try {
    if (isProcedural) {
      canvas.clipRect(
        Rect.fromLTWH(
          x + actualPadding - proceduralPad,
          y + actualPadding - proceduralPad,
          targetWidth + 2 * proceduralPad,
          cellHeight + 2 * proceduralPad,
        ),
      );
      drawProceduralCharacter(
        canvas,
        x + actualPadding,
        y + actualPadding,
        targetWidth,
        cellHeight,
        proceduralPad,
        pg.char,
        Paint()..color = const ui.Color(0xFFFFFFFF),
      );
    } else {
      canvas.clipRect(
        Rect.fromLTWH(
          x + actualPadding - overhang,
          y + actualPadding - overhang,
          targetWidth + 2 * overhang,
          cellHeight + 2 * overhang,
        ),
      );
      final charBaseline = pg.painter.computeDistanceToActualBaseline(
        TextBaseline.alphabetic,
      );
      final rawDx = (targetWidth - pg.painter.width) / 2;
      final dx =
          rawDx < 0.0 &&
              pg.char.length > 1 &&
              !_isAsciiLigature(pg.char) &&
              !_isColorEmojiAtlas(pg.char)
          ? 0.0
          : rawDx;
      final dy = standardBaseline - charBaseline;
      pg.painter.paint(
        canvas,
        Offset(x + actualPadding + dx, y + actualPadding + dy),
      );
    }
  } finally {
    pg.painter.dispose();
    canvas.restore();
  }

  return (
    Rect.fromLTWH(
      (x + actualPadding) * devicePixelRatio,
      (y + actualPadding) * devicePixelRatio,
      targetWidth * devicePixelRatio,
      cellHeight * devicePixelRatio,
    ),
    isProcedural,
  );
}

void _recordAtlasGlyphRect({
  required _PlacedGlyph pg,
  required Rect rect,
  required bool procedural,
  required Map<String, Rect> charRects,
  required Map<(String, bool, bool), Rect> styleRects,
  required Map<(String, GlyphStyleVariant), Rect> styledCharRects,
}) {
  if (pg.variant == GlyphStyleVariant.regular) {
    charRects[pg.char] = rect;
  }
  styleRects[(pg.char, pg.variant.isBold, pg.variant.isItalic)] = rect;
  styledCharRects[(pg.char, pg.variant)] = rect;
  if (procedural || _isColorEmojiAtlas(pg.char)) {
    for (final v in GlyphStyleVariant.values) {
      styleRects[(pg.char, v.isBold, v.isItalic)] = rect;
      styledCharRects[(pg.char, v)] = rect;
    }
  }
}

Map<(String, GlyphStyleVariant), Rect> _deriveStyledCharRects(
  Map<(String, bool, bool), Rect> styleRects,
) => {
  for (final entry in styleRects.entries)
    (
      entry.key.$1,
      GlyphStyleVariant.fromFlags(isBold: entry.key.$2, isItalic: entry.key.$3),
    ): entry.value,
};

int _tryScalarCodePoint(String char) {
  final len = char.length;
  if (len == 1) {
    final cu = char.codeUnitAt(0);
    if (cu != 0 && (cu < 0xD800 || cu > 0xDFFF)) return cu;
    return -1;
  }
  if (len == 2) {
    final cu0 = char.codeUnitAt(0);
    final cu1 = char.codeUnitAt(1);
    if (cu0 >= 0xD800 && cu0 <= 0xDBFF && cu1 >= 0xDC00 && cu1 <= 0xDFFF) {
      return 0x10000 + ((cu0 & 0x3FF) << 10) + (cu1 & 0x3FF);
    }
  }
  return -1;
}

final class _PlacedDecoration {
  final AtlasDecorationKind kind;
  final bool isWide;
  final int cellSpan;
  final int col;
  final int row;

  const _PlacedDecoration(
    this.kind,
    this.isWide,
    this.cellSpan,
    this.col,
    this.row,
  );
}

(List<_PlacedDecoration>, int) _placeDecorationSprites({
  required int startIndex,
  required int numCols,
}) {
  final placed = <_PlacedDecoration>[];
  var currentIdx = startIndex;
  for (final kind in AtlasDecorationKind.values) {
    for (final isWide in const [false, true]) {
      final cellSpan = isWide ? 2 : 1;
      var col = currentIdx % numCols;
      if (col + cellSpan > numCols) {
        currentIdx += numCols - col;
        col = 0;
      }
      final row = currentIdx ~/ numCols;
      placed.add(_PlacedDecoration(kind, isWide, cellSpan, col, row));
      currentIdx += cellSpan;
    }
  }
  return (placed, currentIdx);
}

Map<(AtlasDecorationKind, bool), Rect> _rasterizeDecorationSprites({
  required Canvas canvas,
  required List<_PlacedDecoration> placedDecorations,
  required double colWidth,
  required double rowHeight,
  required double cellWidth,
  required double cellHeight,
  required double actualPadding,
  required double devicePixelRatio,
}) {
  final rects = <(AtlasDecorationKind, bool), Rect>{};
  for (final pd in placedDecorations) {
    final paintX = pd.col * colWidth + actualPadding;
    final paintY = pd.row * rowHeight + actualPadding;
    final spriteWidth = pd.cellSpan * cellWidth;

    canvas.save();
    try {
      canvas.clipRect(Rect.fromLTWH(paintX, paintY, spriteWidth, cellHeight));
      _drawDecorationSprite(
        canvas,
        pd.kind,
        paintX,
        paintY,
        spriteWidth,
        cellHeight,
        devicePixelRatio: devicePixelRatio,
      );
    } finally {
      canvas.restore();
    }

    rects[(pd.kind, pd.isWide)] = Rect.fromLTWH(
      paintX * devicePixelRatio,
      paintY * devicePixelRatio,
      spriteWidth * devicePixelRatio,
      cellHeight * devicePixelRatio,
    );
  }
  return rects;
}

void _drawDecorationSprite(
  Canvas canvas,
  AtlasDecorationKind kind,
  double x,
  double y,
  double w,
  double h, {
  required double devicePixelRatio,
}) {
  final fillPaint = Paint()
    ..color = const ui.Color(0xFFFFFFFF)
    ..style = PaintingStyle.fill
    ..isAntiAlias = false;
  switch (kind) {
    case AtlasDecorationKind.overline:
      canvas.drawRect(Rect.fromLTWH(x, y, w, 1.0), fillPaint);
    case AtlasDecorationKind.strikethrough:
      final midY = y + (h * 0.5).floorToDouble();
      canvas.drawRect(Rect.fromLTWH(x, midY, w, 1.0), fillPaint);
    case AtlasDecorationKind.underlineSingle:
      canvas.drawRect(Rect.fromLTWH(x, y + h - 2.0, w, 1.0), fillPaint);
    case AtlasDecorationKind.underlineDouble:
      canvas.drawRect(Rect.fromLTWH(x, y + h - 3.0, w, 1.0), fillPaint);
      canvas.drawRect(Rect.fromLTWH(x, y + h - 1.0, w, 1.0), fillPaint);
    case AtlasDecorationKind.underlineCurly:
      _drawCurlyDecorationSprite(canvas, x, y + h - 2.0, w);
    case AtlasDecorationKind.underlineDotted:
      _drawPeriodicSegmentedDecoration(
        canvas,
        fillPaint,
        x,
        y + h - 2.0,
        w,
        targetPeriod: 2.5,
        dutyCycle: 1.0 / 2.5,
        minDashWidth: 1.0 / devicePixelRatio,
      );
    case AtlasDecorationKind.underlineDashed:
      _drawPeriodicSegmentedDecoration(
        canvas,
        fillPaint,
        x,
        y + h - 2.0,
        w,
        targetPeriod: 4.0,
        dutyCycle: 2.5 / 4.0,
        minDashWidth: 1.0 / devicePixelRatio,
      );
  }
}

void _drawCurlyDecorationSprite(
  Canvas canvas,
  double x,
  double baseY,
  double w,
) {
  const targetPeriod = 4.0;
  const amplitude = 1.2;
  final cycles = math.max(1, (w / targetPeriod).round());
  final period = w / cycles;
  final halfPeriod = period * 0.5;
  // Extend one half-cycle past both horizontal bounds so the clipped sprite
  // crosses baseY at x and x + w with identical upward tangent and full stroke
  // thickness, allowing adjacent 1-cell and 2-cell sprites to tile seamlessly.
  final path = Path()..moveTo(x - halfPeriod, baseY);
  final totalHalfCycles = cycles * 2 + 2;
  for (var i = 0; i < totalHalfCycles; i++) {
    final segStart = x + (i - 1) * halfPeriod;
    final segEnd = segStart + halfPeriod;
    final midX = segStart + halfPeriod * 0.5;
    final controlY = baseY + (i.isOdd ? -amplitude : amplitude);
    path.quadraticBezierTo(midX, controlY, segEnd, baseY);
  }
  final strokePaint = Paint()
    ..color = const ui.Color(0xFFFFFFFF)
    ..style = PaintingStyle.stroke
    ..strokeWidth = 1.0
    ..isAntiAlias = true;
  canvas.drawPath(path, strokePaint);
}

void _drawPeriodicSegmentedDecoration(
  Canvas canvas,
  Paint paint,
  double x,
  double y,
  double w, {
  required double targetPeriod,
  required double dutyCycle,
  required double minDashWidth,
}) {
  final cycles = math.max(1, (w / targetPeriod).round());
  final period = w / cycles;
  final dash = math.min(period, math.max(minDashWidth, period * dutyCycle));
  final halfGap = (period - dash) * 0.5;
  for (var c = 0; c < cycles; c++) {
    canvas.drawRect(
      Rect.fromLTWH(x + c * period + halfGap, y, dash, 1.0),
      paint,
    );
  }
}

/// A cached texture atlas containing rasterized glyphs for terminal rendering.
///
/// The atlas organises characters in a [numCols] (64) column grid. When a cell
/// needs to draw a character, the renderer reads its coordinates from
/// [charRects] or [lookup] and draws a sub-image from the unified [image] texture.
///
/// If new/unseen characters (e.g., emojis or foreign scripts) are encountered
/// during execution, [addGlyphs] allows dynamically growing the atlas.
///
/// | Parameter | Type | Description |
/// | :--- | :--- | :--- |
/// | `image` | [ui.Image] | The composite texture containing all rasterized characters. |
/// | `charRects` | [Map]<[String], [Rect]> | Mapping from a character to its bounding box in the texture. |
/// | `styleRects` | [Map]<[(String, bool, bool)], [Rect]> | Mapping from (character, bold, italic) to its bounding box. |
/// | `cellWidth` | [double] | Standard monospaced column width. |
/// | `cellHeight` | [double] | Standard monospaced row height. |
/// | `fontSize` | [double] | Point size used to measure/render text. |
/// | `fontFamily` | [String] | Typeface name used for font lookup. |
/// | `fontFamilyFallback` | [List<String>?] | Fallback font families. |
/// | `nextGridIndex` | [int] | The next free cell slot index in the grid. |
/// | `numCols` | [int] | Number of columns allocated in the atlas grid (default 64). |
///
/// ### Example Usage
///
/// ```dart
/// final newAtlas = await atlas.addGlyphs(['🍔', '🍕']);
/// final sourceRect = newAtlas.lookup('A', bold: true);
/// ```
final class GlyphAtlas {
  /// The composite texture containing all rasterized characters.
  final ui.Image image;

  /// Mapping from a character to its bounding box in the texture (regular style).
  final Map<String, Rect> charRects;

  /// Mapping from (character, bold, italic) to its styled bounding box in the texture.
  final Map<(String, bool, bool), Rect> styleRects;

  /// Mapping from `(character, GlyphStyleVariant)` to its styled bounding box in the texture.
  final Map<(String, GlyphStyleVariant), Rect> styledCharRects;

  /// Standard monospaced column width.
  final double cellWidth;

  /// Standard monospaced row height.
  final double cellHeight;

  /// Standard alphabetic baseline offset from the top of a cell in logical pixels.
  final double standardBaseline;

  /// Point size used to measure/render text.
  final double fontSize;

  /// Typeface name used for font lookup.
  final String fontFamily;

  /// Fallback typeface names used for font lookup.
  final List<String>? fontFamilyFallback;

  /// The device pixel ratio used for rendering the atlas.
  final double devicePixelRatio;

  /// The next free cell slot index in the grid.
  final int nextGridIndex;

  /// Number of columns allocated in the atlas grid.
  final int numCols;

  static const int _asciiStart = 0x20;
  static const int _asciiEnd = 0x7E;
  static const int _asciiCount = _asciiEnd - _asciiStart + 1;

  final Map<String, Rect> _regularRects = <String, Rect>{};
  final Map<String, Rect> _boldRects = <String, Rect>{};
  final Map<String, Rect> _italicRects = <String, Rect>{};
  final Map<String, Rect> _boldItalicRects = <String, Rect>{};
  final List<Rect?> _asciiRects = List<Rect?>.filled(_asciiCount * 4, null);
  final Map<(AtlasDecorationKind, bool), Rect> _decorationRects;
  late final AtlasQuadTable _quadTable;

  /// Flat typed-array quad lookup table for scalar glyph codes and pre-baked
  /// cell decoration sprites in this atlas.
  AtlasQuadTable get quadTable => _quadTable;

  /// Blank padding added around each glyph to prevent texture bleed.
  static const double padding = 3.0;

  /// Maximum logical overhang rasterized outside each glyph's nominal cell bounds.
  static const double overhang = 2.0;

  /// The actual padding used, rounded to physical boundaries.
  double get actualPadding =>
      (GlyphAtlasGenerator.padding * devicePixelRatio).ceilToDouble() /
      devicePixelRatio;

  /// The actual overhang allowed outside nominal cell bounds, snapped to physical pixels.
  double get actualOverhang =>
      (overhang * devicePixelRatio).floorToDouble() / devicePixelRatio;

  /// Total width of a grid column, including padding.
  double get colWidth => cellWidth + 2 * actualPadding;

  /// Total height of a grid row, including padding.
  double get rowHeight => cellHeight + 2 * actualPadding;

  bool _isDisposed = false;

  /// Whether [dispose] has been called on this atlas.
  bool get isDisposed => _isDisposed;

  /// Idempotently disposes the underlying GPU [image] texture.
  void dispose() {
    if (_isDisposed) return;
    _isDisposed = true;
    image.dispose();
  }

  /// Creates a new [GlyphAtlas] instance.
  GlyphAtlas({
    required this.image,
    required this.charRects,
    Map<(String, bool, bool), Rect>? styleRects,
    Map<(String, GlyphStyleVariant), Rect>? styledCharRects,
    Map<(AtlasDecorationKind, bool), Rect>? decorationRects,
    required this.cellWidth,
    required this.cellHeight,
    double? standardBaseline,
    required this.fontSize,
    required this.fontFamily,
    this.fontFamilyFallback,
    this.devicePixelRatio = 1.0,
    required this.nextGridIndex,
    this.numCols = 64,
  }) : standardBaseline = standardBaseline ?? cellHeight * 0.8,
       styleRects = styleRects ?? const {},
       styledCharRects =
           styledCharRects ??
           (styleRects != null ? _deriveStyledCharRects(styleRects) : const {}),
       _decorationRects = decorationRects == null
           ? const {}
           : Map<(AtlasDecorationKind, bool), Rect>.unmodifiable(
               decorationRects,
             ) {
    _populateVariantMaps();
    _quadTable = _buildQuadTable();
  }

  AtlasQuadTable _buildQuadTable() {
    final builder = AtlasQuadTableBuilder(
      initialQuadCapacity:
          _regularRects.length +
          _boldRects.length +
          _italicRects.length +
          _boldItalicRects.length +
          _decorationRects.length,
    );
    _addVariantRectsToQuadTable(builder, _regularRects, 0);
    _addVariantRectsToQuadTable(builder, _boldRects, 1);
    _addVariantRectsToQuadTable(builder, _italicRects, 2);
    _addVariantRectsToQuadTable(builder, _boldItalicRects, 3);
    for (final entry in _decorationRects.entries) {
      builder.putDecoration(
        entry.key.$1,
        isWide: entry.key.$2,
        rect: entry.value,
      );
    }
    return builder.build();
  }

  static void _addVariantRectsToQuadTable(
    AtlasQuadTableBuilder builder,
    Map<String, Rect> rects,
    int variantBits,
  ) {
    for (final entry in rects.entries) {
      final codePoint = _tryScalarCodePoint(entry.key);
      if (codePoint >= 1) {
        builder.putCodePoint(
          codePoint,
          variantBits: variantBits,
          rect: entry.value,
        );
      }
    }
  }

  void _populateVariantMaps() {
    for (final entry in styleRects.entries) {
      final (char, isBold, isItalic) = entry.key;
      _mapForFlags(isBold, isItalic)[char] = entry.value;
    }
    for (final entry in styledCharRects.entries) {
      final (char, variant) = entry.key;
      _mapForVariant(variant)[char] = entry.value;
    }
    _regularRects.addAll(charRects);
    for (var code = _asciiStart; code <= _asciiEnd; code++) {
      final ch = String.fromCharCode(code);
      final regular = _regularRects[ch];
      final base = (code - _asciiStart) << 2;
      _asciiRects[base] = regular;
      _asciiRects[base | 1] = _boldRects[ch] ?? regular;
      _asciiRects[base | 2] = _italicRects[ch] ?? regular;
      _asciiRects[base | 3] = _boldItalicRects[ch] ?? regular;
    }
  }

  Map<String, Rect> _mapForFlags(bool isBold, bool isItalic) {
    if (!isBold) return isItalic ? _italicRects : _regularRects;
    return isItalic ? _boldItalicRects : _boldRects;
  }

  Map<String, Rect> _mapForVariant(GlyphStyleVariant variant) =>
      switch (variant) {
        GlyphStyleVariant.regular => _regularRects,
        GlyphStyleVariant.bold => _boldRects,
        GlyphStyleVariant.italic => _italicRects,
        GlyphStyleVariant.boldItalic => _boldItalicRects,
      };

  /// Whether this atlas contains a native rasterized entry for [char] in [variant].
  bool hasNativeVariant(String char, GlyphStyleVariant variant) =>
      _mapForVariant(variant).containsKey(char);

  /// Returns the atlas source [Rect] for [char] matching [isBold] and [isItalic].
  ///
  /// Falls back to the regular variant when a specialized styled variant is absent.
  Rect? rectFor(String char, {bool isBold = false, bool isItalic = false}) {
    final code = char.length == 1 ? char.codeUnitAt(0) : -1;
    if (code >= _asciiStart && code <= _asciiEnd) {
      final variant = (isBold ? 1 : 0) | (isItalic ? 2 : 0);
      return _asciiRects[((code - _asciiStart) << 2) | variant];
    }
    if (!isBold && !isItalic) {
      return _regularRects[char];
    }
    return _mapForFlags(isBold, isItalic)[char] ?? _regularRects[char];
  }

  /// Looks up the glyph rect for [char] matching the specified style variant.
  ///
  /// If the styled variant is not available, falls back to the regular variant.
  Rect? lookup(String char, {bool bold = false, bool italic = false}) =>
      rectFor(char, isBold: bold, isItalic: italic);

  /// Dynamically rasterizes and appends all style variants of [newGlyphs] to this atlas.
  Future<GlyphAtlas> addGlyphs(List<String> newGlyphs) {
    final styled = <(String, GlyphStyleVariant)>[];
    for (final char in newGlyphs) {
      if (_isColorEmojiAtlas(char)) {
        styled.add((char, GlyphStyleVariant.regular));
      } else {
        for (final variant in GlyphStyleVariant.values) {
          styled.add((char, variant));
        }
      }
    }
    return addStyledGlyphs(styled);
  }

  /// Dynamically rasterizes and appends only the requested `(char, variant)` pairs.
  Future<GlyphAtlas> addStyledGlyphs(
    List<(String, GlyphStyleVariant)> glyphs,
  ) async {
    await Future.microtask(() {});
    if (_isDisposed) return this;
    final measures = _measureDynamicStyledGlyphs(glyphs);
    if (measures.isEmpty) return this;

    final (placedGlyphs, totalGlyphs) = _placeMeasuredGlyphs(
      measures,
      startIndex: nextGridIndex,
      numCols: numCols,
    );

    final numRows = (totalGlyphs / numCols).ceil();
    final atlasWidth = (numCols * colWidth).ceil().toDouble();
    final atlasHeight = (numRows * rowHeight).ceil().toDouble();

    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.scale(devicePixelRatio);
    canvas.save();
    canvas.scale(1.0 / devicePixelRatio);
    canvas.drawImage(image, Offset.zero, Paint());
    canvas.restore();

    final updatedRects = Map<String, Rect>.from(charRects);
    final updatedStyleRects = Map<(String, bool, bool), Rect>.from(styleRects);
    final updatedStyledRects = Map<(String, GlyphStyleVariant), Rect>.from(
      styledCharRects,
    );

    _rasterizePlacedGlyphs(
      canvas: canvas,
      placedGlyphs: placedGlyphs,
      colWidth: colWidth,
      rowHeight: rowHeight,
      cellWidth: cellWidth,
      cellHeight: cellHeight,
      actualPadding: actualPadding,
      standardBaseline: standardBaseline,
      devicePixelRatio: devicePixelRatio,
      charRects: updatedRects,
      styleRects: updatedStyleRects,
      styledCharRects: updatedStyledRects,
    );

    final picture = recorder.endRecording();
    final newImage = await picture.toImage(
      (atlasWidth * devicePixelRatio).ceil(),
      (atlasHeight * devicePixelRatio).ceil(),
    );
    picture.dispose();
    if (_isDisposed) {
      newImage.dispose();
      return this;
    }

    return GlyphAtlas(
      image: newImage,
      charRects: updatedRects,
      styleRects: updatedStyleRects,
      styledCharRects: updatedStyledRects,
      decorationRects: _decorationRects,
      cellWidth: cellWidth,
      cellHeight: cellHeight,
      standardBaseline: standardBaseline,
      fontSize: fontSize,
      fontFamily: fontFamily,
      fontFamilyFallback: fontFamilyFallback,
      devicePixelRatio: devicePixelRatio,
      nextGridIndex: totalGlyphs,
      numCols: numCols,
    );
  }

  List<_GlyphMeasure> _measureDynamicStyledGlyphs(
    List<(String, GlyphStyleVariant)> glyphs,
  ) {
    final seen = <(String, GlyphStyleVariant)>{};
    final measures = <_GlyphMeasure>[];
    for (final (char, requestedVariant) in glyphs) {
      if (char.isEmpty) continue;
      final variant = _isColorEmojiAtlas(char)
          ? GlyphStyleVariant.regular
          : requestedVariant;
      if (styledCharRects.containsKey((char, variant)) ||
          !seen.add((char, variant))) {
        continue;
      }
      final tp = _createAtlasTextPainter(
        char: char,
        fontSize: fontSize,
        fontFamily: fontFamily,
        fontFamilyFallback: fontFamilyFallback,
        bold: variant.isBold,
        italic: variant.isItalic,
      );
      measures.add(
        _GlyphMeasure(char, tp, _resolveGlyphCellSpan(char), variant: variant),
      );
    }
    return measures;
  }
}

final class _GlyphMeasure {
  final String char;
  final TextPainter painter;
  final int cellSpan;
  final GlyphStyleVariant variant;

  _GlyphMeasure(
    this.char,
    this.painter,
    this.cellSpan, {
    this.variant = GlyphStyleVariant.regular,
  });
}

final class _PlacedGlyph {
  final String char;
  final TextPainter painter;
  final int cellSpan;
  final int col;
  final int row;
  final GlyphStyleVariant variant;

  _PlacedGlyph(
    this.char,
    this.painter,
    this.cellSpan,
    this.col,
    this.row, {
    this.variant = GlyphStyleVariant.regular,
  });
}

/// A generator that asynchronously produces a new [GlyphAtlas].
///
/// It measures the basic cell size for a monospaced font, generates coordinate
/// layouts, and draws common ASCII, block element, box-drawing, and braille
/// code points onto a single backing image texture using a [ui.PictureRecorder].
///
/// ### Example Usage
///
/// ```dart
/// final atlas = await GlyphAtlasGenerator.generate(
///   fontSize: 14.0,
///   fontFamily: 'Roboto Mono',
/// );
/// ```
abstract final class GlyphAtlasGenerator {
  /// Blank padding added around each glyph.
  static const double padding = 3.0;

  static const List<int> _initialCodePoints = [
    32,
    33,
    34,
    35,
    36,
    37,
    38,
    39,
    40,
    41,
    42,
    43,
    44,
    45,
    46,
    47,
    48,
    49,
    50,
    51,
    52,
    53,
    54,
    55,
    56,
    57,
    58,
    59,
    60,
    61,
    62,
    63,
    64,
    65,
    66,
    67,
    68,
    69,
    70,
    71,
    72,
    73,
    74,
    75,
    76,
    77,
    78,
    79,
    80,
    81,
    82,
    83,
    84,
    85,
    86,
    87,
    88,
    89,
    90,
    91,
    92,
    93,
    94,
    95,
    96,
    97,
    98,
    99,
    100,
    101,
    102,
    103,
    104,
    105,
    106,
    107,
    108,
    109,
    110,
    111,
    112,
    113,
    114,
    115,
    116,
    117,
    118,
    119,
    120,
    121,
    122,
    123,
    124,
    125,
    126,
    0xf1,
    0x2019,
    0x2022,
    0x2122,
    0x25b6,
    0x25bc,
    0x25cb,
    0x25cf,
  ];

  static ({
    double cellWidth,
    double cellHeight,
    double standardBaseline,
    double actualPadding,
    double colWidth,
    double rowHeight,
  })
  _measureFontCellMetrics({
    required double fontSize,
    required String fontFamily,
    List<String>? fontFamilyFallback,
    required double devicePixelRatio,
  }) {
    final testPainter = _createAtlasTextPainter(
      char: 'A',
      fontSize: fontSize,
      fontFamily: fontFamily,
      fontFamilyFallback: fontFamilyFallback,
    );
    final cellWidth =
        (testPainter.width * devicePixelRatio).ceilToDouble() /
        devicePixelRatio;
    final unroundedHeight = switch (testPainter.computeLineMetrics()) {
      [final first, ...] => math.max(
        testPainter.height,
        first.ascent + first.descent,
      ),
      [] => testPainter.height,
    };
    final cellHeight =
        (unroundedHeight * devicePixelRatio).ceilToDouble() / devicePixelRatio;
    final standardBaseline = testPainter.computeDistanceToActualBaseline(
      TextBaseline.alphabetic,
    );
    testPainter.dispose();

    final actualPadding =
        (padding * devicePixelRatio).ceilToDouble() / devicePixelRatio;
    return (
      cellWidth: cellWidth,
      cellHeight: cellHeight,
      standardBaseline: standardBaseline,
      actualPadding: actualPadding,
      colWidth: cellWidth + 2 * actualPadding,
      rowHeight: cellHeight + 2 * actualPadding,
    );
  }

  /// Generates an empty [GlyphAtlas].
  static Future<GlyphAtlas> generateEmpty({
    required double fontSize,
    required String fontFamily,
    List<String>? fontFamilyFallback,
    double devicePixelRatio = 1.0,
  }) async {
    await Future.microtask(() {});
    final m = _measureFontCellMetrics(
      fontSize: fontSize,
      fontFamily: fontFamily,
      fontFamilyFallback: fontFamilyFallback,
      devicePixelRatio: devicePixelRatio,
    );

    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.scale(devicePixelRatio);

    canvas.drawRect(
      Rect.fromLTWH(1.0, 1.0, m.colWidth - 2.0, m.rowHeight - 2.0),
      Paint()..color = const ui.Color(0xFFFFFFFF),
    );
    final whiteRect = Rect.fromLTWH(
      m.actualPadding * devicePixelRatio,
      m.actualPadding * devicePixelRatio,
      m.cellWidth * devicePixelRatio,
      m.cellHeight * devicePixelRatio,
    );
    final charRects = <String, Rect>{'\uFFFF': whiteRect};
    final styleRects = <(String, bool, bool), Rect>{
      for (final v in GlyphStyleVariant.values)
        ('\uFFFF', v.isBold, v.isItalic): whiteRect,
    };
    final styledCharRects = <(String, GlyphStyleVariant), Rect>{
      for (final v in GlyphStyleVariant.values) ('\uFFFF', v): whiteRect,
    };

    final picture = recorder.endRecording();
    final image = await picture.toImage(
      (m.colWidth * devicePixelRatio).ceil(),
      (m.rowHeight * devicePixelRatio).ceil(),
    );
    picture.dispose();

    return GlyphAtlas(
      image: image,
      charRects: charRects,
      styleRects: styleRects,
      styledCharRects: styledCharRects,
      cellWidth: m.cellWidth,
      cellHeight: m.cellHeight,
      standardBaseline: m.standardBaseline,
      fontSize: fontSize,
      fontFamily: fontFamily,
      fontFamilyFallback: fontFamilyFallback,
      devicePixelRatio: devicePixelRatio,
      nextGridIndex: 1,
      numCols: 64,
    );
  }

  static List<_GlyphMeasure> _measureInitialGlyphs({
    required double fontSize,
    required String fontFamily,
    List<String>? fontFamilyFallback,
  }) {
    final measures = <_GlyphMeasure>[];
    for (final code in _initialCodePoints) {
      final char = String.fromCharCode(code);
      final span = isWideGrapheme(char) ? 2 : 1;
      _appendAllStyleMeasures(
        measures,
        char: char,
        cellSpan: span,
        fontSize: fontSize,
        fontFamily: fontFamily,
        fontFamilyFallback: fontFamilyFallback,
      );
    }
    _appendRangeRegularMeasures(
      measures,
      start: 0x2500,
      end: 0x259F,
      fontSize: fontSize,
      fontFamily: fontFamily,
      fontFamilyFallback: fontFamilyFallback,
    );
    _appendRangeRegularMeasures(
      measures,
      start: 0x2800,
      end: 0x28FF,
      fontSize: fontSize,
      fontFamily: fontFamily,
      fontFamilyFallback: fontFamilyFallback,
    );
    for (final ligature in _prebakedLigatures) {
      _appendAllStyleMeasures(
        measures,
        char: ligature,
        cellSpan: ligature.length,
        fontSize: fontSize,
        fontFamily: fontFamily,
        fontFamilyFallback: fontFamilyFallback,
      );
    }
    return measures;
  }

  static void _appendAllStyleMeasures(
    List<_GlyphMeasure> out, {
    required String char,
    required int cellSpan,
    required double fontSize,
    required String fontFamily,
    List<String>? fontFamilyFallback,
  }) {
    for (final variant in GlyphStyleVariant.values) {
      final tp = _createAtlasTextPainter(
        char: char,
        fontSize: fontSize,
        fontFamily: fontFamily,
        fontFamilyFallback: fontFamilyFallback,
        bold: variant.isBold,
        italic: variant.isItalic,
      );
      out.add(_GlyphMeasure(char, tp, cellSpan, variant: variant));
    }
  }

  static void _appendRangeRegularMeasures(
    List<_GlyphMeasure> out, {
    required int start,
    required int end,
    required double fontSize,
    required String fontFamily,
    List<String>? fontFamilyFallback,
  }) {
    for (var code = start; code <= end; code++) {
      final char = String.fromCharCode(code);
      final tp = _createAtlasTextPainter(
        char: char,
        fontSize: fontSize,
        fontFamily: fontFamily,
        fontFamilyFallback: fontFamilyFallback,
      );
      out.add(_GlyphMeasure(char, tp, isWideGrapheme(char) ? 2 : 1));
    }
  }

  /// Generates a new standard [GlyphAtlas] texture by rendering characters.
  static Future<GlyphAtlas> generate({
    required double fontSize,
    required String fontFamily,
    List<String>? fontFamilyFallback,
    double devicePixelRatio = 1.0,
  }) async {
    await Future.microtask(() {});
    final m = _measureFontCellMetrics(
      fontSize: fontSize,
      fontFamily: fontFamily,
      fontFamilyFallback: fontFamilyFallback,
      devicePixelRatio: devicePixelRatio,
    );

    const numCols = 64;
    final measures = _measureInitialGlyphs(
      fontSize: fontSize,
      fontFamily: fontFamily,
      fontFamilyFallback: fontFamilyFallback,
    );
    final (placedGlyphs, whiteIdx) = _placeMeasuredGlyphs(
      measures,
      startIndex: 0,
      numCols: numCols,
    );

    final whiteX = (whiteIdx % numCols) * m.colWidth;
    final whiteY = (whiteIdx ~/ numCols) * m.rowHeight;
    final (placedDecorations, totalGlyphs) = _placeDecorationSprites(
      startIndex: whiteIdx + 1,
      numCols: numCols,
    );
    final numRows = (totalGlyphs / numCols).ceil();
    final atlasWidth = (numCols * m.colWidth).ceil().toDouble();
    final atlasHeight = (numRows * m.rowHeight).ceil().toDouble();

    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.scale(devicePixelRatio);
    final charRects = <String, Rect>{};
    final styleRects = <(String, bool, bool), Rect>{};
    final styledCharRects = <(String, GlyphStyleVariant), Rect>{};

    _rasterizePlacedGlyphs(
      canvas: canvas,
      placedGlyphs: placedGlyphs,
      colWidth: m.colWidth,
      rowHeight: m.rowHeight,
      cellWidth: m.cellWidth,
      cellHeight: m.cellHeight,
      actualPadding: m.actualPadding,
      standardBaseline: m.standardBaseline,
      devicePixelRatio: devicePixelRatio,
      charRects: charRects,
      styleRects: styleRects,
      styledCharRects: styledCharRects,
    );

    canvas.drawRect(
      Rect.fromLTWH(
        whiteX + 1.0,
        whiteY + 1.0,
        m.colWidth - 2.0,
        m.rowHeight - 2.0,
      ),
      Paint()..color = const ui.Color(0xFFFFFFFF),
    );
    final whiteRect = Rect.fromLTWH(
      (whiteX + m.actualPadding) * devicePixelRatio,
      (whiteY + m.actualPadding) * devicePixelRatio,
      m.cellWidth * devicePixelRatio,
      m.cellHeight * devicePixelRatio,
    );
    charRects['\uFFFF'] = whiteRect;
    for (final v in GlyphStyleVariant.values) {
      styleRects[('\uFFFF', v.isBold, v.isItalic)] = whiteRect;
      styledCharRects[('\uFFFF', v)] = whiteRect;
    }

    final decorationRects = _rasterizeDecorationSprites(
      canvas: canvas,
      placedDecorations: placedDecorations,
      colWidth: m.colWidth,
      rowHeight: m.rowHeight,
      cellWidth: m.cellWidth,
      cellHeight: m.cellHeight,
      actualPadding: m.actualPadding,
      devicePixelRatio: devicePixelRatio,
    );

    final picture = recorder.endRecording();
    final newImage = await picture.toImage(
      (atlasWidth * devicePixelRatio).ceil(),
      (atlasHeight * devicePixelRatio).ceil(),
    );
    picture.dispose();

    return GlyphAtlas(
      image: newImage,
      charRects: charRects,
      styleRects: styleRects,
      styledCharRects: styledCharRects,
      decorationRects: decorationRects,
      cellWidth: m.cellWidth,
      cellHeight: m.cellHeight,
      standardBaseline: m.standardBaseline,
      fontSize: fontSize,
      fontFamily: fontFamily,
      fontFamilyFallback: fontFamilyFallback,
      devicePixelRatio: devicePixelRatio,
      nextGridIndex: totalGlyphs,
      numCols: numCols,
    );
  }
}
