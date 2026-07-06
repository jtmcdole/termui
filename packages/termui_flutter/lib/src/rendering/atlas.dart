import 'dart:async';
import 'dart:ui' as ui;
import 'package:flutter/material.dart' hide Color;
import 'package:termui/ui/buffer.dart';

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
/// final paint = Paint()..color = Colors.white;
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
  final code = char.isNotEmpty ? char.codeUnitAt(0) : 0;

  // Block elements
  if (code == 0x2588) {
    // █
    canvas.drawRect(
      Rect.fromLTWH(
        paintX - padding,
        paintY - padding,
        w + 2 * padding,
        h + 2 * padding,
      ),
      paint,
    );
    return true;
  }
  if (code == 0x258F) {
    // ▏
    canvas.drawRect(
      Rect.fromLTWH(
        paintX - padding,
        paintY - padding,
        w * 1 / 8 + padding,
        h + 2 * padding,
      ),
      paint,
    );
    return true;
  }
  if (code == 0x258E) {
    // ▎
    canvas.drawRect(
      Rect.fromLTWH(
        paintX - padding,
        paintY - padding,
        w * 2 / 8 + padding,
        h + 2 * padding,
      ),
      paint,
    );
    return true;
  }
  if (code == 0x258D) {
    // ▍
    canvas.drawRect(
      Rect.fromLTWH(
        paintX - padding,
        paintY - padding,
        w * 3 / 8 + padding,
        h + 2 * padding,
      ),
      paint,
    );
    return true;
  }
  if (code == 0x258C) {
    // ▌
    canvas.drawRect(
      Rect.fromLTWH(
        paintX - padding,
        paintY - padding,
        w * 4 / 8 + padding,
        h + 2 * padding,
      ),
      paint,
    );
    return true;
  }
  if (code == 0x258B) {
    // ▋
    canvas.drawRect(
      Rect.fromLTWH(
        paintX - padding,
        paintY - padding,
        w * 5 / 8 + padding,
        h + 2 * padding,
      ),
      paint,
    );
    return true;
  }
  if (code == 0x258A) {
    // ▊
    canvas.drawRect(
      Rect.fromLTWH(
        paintX - padding,
        paintY - padding,
        w * 6 / 8 + padding,
        h + 2 * padding,
      ),
      paint,
    );
    return true;
  }
  if (code == 0x2589) {
    // ▉
    canvas.drawRect(
      Rect.fromLTWH(
        paintX - padding,
        paintY - padding,
        w * 7 / 8 + padding,
        h + 2 * padding,
      ),
      paint,
    );
    return true;
  }
  if (code == 0x2590) {
    // ▐
    canvas.drawRect(
      Rect.fromLTWH(
        paintX + w * 4 / 8,
        paintY - padding,
        w * 4 / 8 + padding,
        h + 2 * padding,
      ),
      paint,
    );
    return true;
  }
  if (code == 0x2580) {
    // ▀
    canvas.drawRect(
      Rect.fromLTWH(
        paintX - padding,
        paintY - padding,
        w + 2 * padding,
        h * 0.5 + padding,
      ),
      paint,
    );
    return true;
  }
  if (code == 0x2584) {
    // ▄
    canvas.drawRect(
      Rect.fromLTWH(
        paintX - padding,
        paintY + h * 0.5,
        w + 2 * padding,
        h * 0.5 + padding,
      ),
      paint,
    );
    return true;
  }

  // Shades
  if (code == 0x2591) {
    // ░
    final originalColor = paint.color;
    paint.color = originalColor.withAlpha(64);
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
  if (code == 0x2592) {
    // ▒
    final originalColor = paint.color;
    paint.color = originalColor.withAlpha(128);
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
  if (code == 0x2593) {
    // ▓
    final originalColor = paint.color;
    paint.color = originalColor.withAlpha(192);
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

  // Thin Single Line Box Drawing
  final halfW = w / 2;
  final halfH = h / 2;
  final thickness = 1.2;

  void drawHLine(double xStart, double xEnd) {
    canvas.drawRect(
      Rect.fromLTRB(
        xStart,
        paintY + halfH - thickness / 2,
        xEnd,
        paintY + halfH + thickness / 2,
      ),
      paint,
    );
  }

  void drawVLine(double yStart, double yEnd) {
    canvas.drawRect(
      Rect.fromLTRB(
        paintX + halfW - thickness / 2,
        yStart,
        paintX + halfW + thickness / 2,
        yEnd,
      ),
      paint,
    );
  }

  if (code == 0x2500) {
    // ─
    drawHLine(paintX - padding, paintX + w + padding);
    return true;
  }
  if (code == 0x2502) {
    // │
    drawVLine(paintY - padding, paintY + h + padding);
    return true;
  }
  if (code == 0x250C) {
    // ┌
    drawHLine(paintX + halfW, paintX + w + padding);
    drawVLine(paintY + halfH, paintY + h + padding);
    return true;
  }
  if (code == 0x2510) {
    // ┐
    drawHLine(paintX - padding, paintX + halfW);
    drawVLine(paintY + halfH, paintY + h + padding);
    return true;
  }
  if (code == 0x2514) {
    // └
    drawHLine(paintX + halfW, paintX + w + padding);
    drawVLine(paintY - padding, paintY + halfH);
    return true;
  }
  if (code == 0x2518) {
    // ┘
    drawHLine(paintX - padding, paintX + halfW);
    drawVLine(paintY - padding, paintY + halfH);
    return true;
  }
  if (code == 0x251C) {
    // ├
    drawHLine(paintX + halfW, paintX + w + padding);
    drawVLine(paintY - padding, paintY + h + padding);
    return true;
  }
  if (code == 0x2524) {
    // ┤
    drawHLine(paintX - padding, paintX + halfW);
    drawVLine(paintY - padding, paintY + h + padding);
    return true;
  }
  if (code == 0x252C) {
    // ┬
    drawHLine(paintX - padding, paintX + w + padding);
    drawVLine(paintY + halfH, paintY + h + padding);
    return true;
  }
  if (code == 0x2534) {
    // ┴
    drawHLine(paintX - padding, paintX + w + padding);
    drawVLine(paintY - padding, paintY + halfH);
    return true;
  }
  if (code == 0x253C) {
    // ┼
    drawHLine(paintX - padding, paintX + w + padding);
    drawVLine(paintY - padding, paintY + h + padding);
    return true;
  }

  // Double Line Box Drawing
  final dThickness = 1.0;
  final dGap = 2.0;

  void drawDoubleHLine(double xStart, double xEnd) {
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

  void drawDoubleVLine(double yStart, double yEnd) {
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

  if (code == 0x2550) {
    // ═
    drawDoubleHLine(paintX - padding, paintX + w + padding);
    return true;
  }
  if (code == 0x2551) {
    // ║
    drawDoubleVLine(paintY - padding, paintY + h + padding);
    return true;
  }
  if (code == 0x2554) {
    // ╔
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
    return true;
  }
  if (code == 0x2557) {
    // ╗
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
    return true;
  }
  if (code == 0x255A) {
    // ╚
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
    return true;
  }
  if (code == 0x255D) {
    // ╝
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
    return true;
  }

  return false;
}

/// A cached texture atlas containing rasterized glyphs for terminal rendering.
///
/// The atlas organises characters in a [numCols] (32) column grid. When a cell
/// needs to draw a character, the renderer reads its coordinates from
/// [charRects] and draws a sub-image from the unified [image] texture.
///
/// If new/unseen characters (e.g., emojis or foreign scripts) are encountered
/// during execution, [addGlyphs] allows dynamically growing the atlas.
///
/// | Parameter | Type | Description |
/// | :--- | :--- | :--- |
/// | `image` | [ui.Image] | The composite texture containing all rasterized characters. |
/// | `charRects` | [Map]<[String], [Rect]> | Mapping from a character to its bounding box in the texture. |
/// | `cellWidth` | [double] | Standard monospaced column width. |
/// | `cellHeight` | [double] | Standard monospaced row height. |
/// | `fontSize` | [double] | Point size used to measure/render text. |
/// | `fontFamily` | [String] | Typeface name used for font lookup. |
/// | `fontFamilyFallback` | [List<String>?] | Fallback font families. |
/// | `nextGridIndex` | [int] | The next free cell slot index in the grid. |
///
/// ### Example Usage
///
/// ```dart
/// final newAtlas = await atlas.addGlyphs(['🍔', '🍕']);
/// final sourceRect = newAtlas.charRects['🍔'];
/// ```
class GlyphAtlas {
  /// The composite texture containing all rasterized characters.
  final ui.Image image;

  /// Mapping from a character to its bounding box in the texture.
  final Map<String, Rect> charRects;

  /// Standard monospaced column width.
  final double cellWidth;

  /// Standard monospaced row height.
  final double cellHeight;

  /// Point size used to measure/render text.
  final double fontSize;

  /// Typeface name used for font lookup.
  final String fontFamily;

  /// Fallback typeface names used for font lookup.
  final List<String>? fontFamilyFallback;

  /// The next free cell slot index in the grid.
  final int nextGridIndex;

  /// Number of columns allocated in the atlas grid.
  final int numCols = 32;

  /// Blank padding added around each glyph to prevent texture bleed.
  static const double padding = 2.0;

  /// Total width of a grid column, including padding.
  double get colWidth => cellWidth + 2 * padding;

  /// Total height of a grid row, including padding.
  double get rowHeight => cellHeight + 2 * padding;

  /// Creates a new [GlyphAtlas] instance.
  GlyphAtlas({
    required this.image,
    required this.charRects,
    required this.cellWidth,
    required this.cellHeight,
    required this.fontSize,
    required this.fontFamily,
    this.fontFamilyFallback,
    required this.nextGridIndex,
  });

  /// Dynamically rasterizes and appends [newGlyphs] to this atlas.
  Future<GlyphAtlas> addGlyphs(List<String> newGlyphs) async {
    await Future.microtask(() {});
    final list = <_GlyphMeasure>[];
    for (final char in newGlyphs) {
      final tp = TextPainter(
        text: TextSpan(
          text: char,
          style: TextStyle(
            fontSize: fontSize,
            fontFamily: fontFamily,
            fontFamilyFallback: fontFamilyFallback,
            color: Colors.white,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      final isDouble = isWideGrapheme(char);
      list.add(_GlyphMeasure(char, tp, isDouble));
    }

    var currentIdx = nextGridIndex;
    final updatedRects = Map<String, Rect>.from(charRects);
    final List<_PlacedGlyph> placedGlyphs = [];

    for (final gm in list) {
      var col = currentIdx % numCols;
      if (gm.isDouble && col == numCols - 1) {
        currentIdx++;
        col = currentIdx % numCols;
      }
      final row = currentIdx ~/ numCols;
      placedGlyphs.add(
        _PlacedGlyph(gm.char, gm.painter, gm.isDouble, col, row),
      );
      currentIdx += gm.isDouble ? 2 : 1;
    }

    final totalGlyphs = currentIdx;
    final numRows = (totalGlyphs / numCols).ceil();
    final atlasWidth = (numCols * colWidth).ceil().toDouble();
    final atlasHeight = (numRows * rowHeight).ceil().toDouble();

    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);

    canvas.drawImage(image, Offset.zero, Paint());

    final testPainter = TextPainter(
      text: TextSpan(
        text: 'A',
        style: TextStyle(
          fontSize: fontSize,
          fontFamily: fontFamily,
          fontFamilyFallback: fontFamilyFallback,
          color: Colors.white,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    final standardBaseline = testPainter.computeDistanceToActualBaseline(
      TextBaseline.alphabetic,
    );

    for (final pg in placedGlyphs) {
      final x = pg.col * colWidth;
      final y = pg.row * rowHeight;
      final targetWidth = pg.isDouble ? 2 * cellWidth : cellWidth;
      final targetSlotWidth = pg.isDouble ? 2 * colWidth : colWidth;

      canvas.save();
      canvas.clipRect(Rect.fromLTWH(x, y, targetSlotWidth, rowHeight));

      bool drawn = drawProceduralCharacter(
        canvas,
        x + padding,
        y + padding,
        targetWidth,
        cellHeight,
        padding,
        pg.char,
        Paint()..color = Colors.white,
      );

      if (!drawn) {
        final charBaseline = pg.painter.computeDistanceToActualBaseline(
          TextBaseline.alphabetic,
        );
        final dx = (targetWidth - pg.painter.width) / 2;
        final dy = standardBaseline - charBaseline;
        pg.painter.paint(canvas, Offset(x + padding + dx, y + padding + dy));
      }

      canvas.restore();
      updatedRects[pg.char] = Rect.fromLTWH(
        x + padding,
        y + padding,
        targetWidth,
        cellHeight,
      );
    }

    final picture = recorder.endRecording();
    final newImage = await picture.toImage(
      atlasWidth.toInt(),
      atlasHeight.toInt(),
    );

    image.dispose();

    return GlyphAtlas(
      image: newImage,
      charRects: updatedRects,
      cellWidth: cellWidth,
      cellHeight: cellHeight,
      fontSize: fontSize,
      fontFamily: fontFamily,
      fontFamilyFallback: fontFamilyFallback,
      nextGridIndex: totalGlyphs,
    );
  }
}

class _GlyphMeasure {
  final String char;
  final TextPainter painter;
  final bool isDouble;
  _GlyphMeasure(this.char, this.painter, this.isDouble);
}

class _PlacedGlyph {
  final String char;
  final TextPainter painter;
  final bool isDouble;
  final int col;
  final int row;
  _PlacedGlyph(this.char, this.painter, this.isDouble, this.col, this.row);
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
class GlyphAtlasGenerator {
  /// Blank padding added around each glyph.
  static const double padding = 2.0;

  /// Generates an empty [GlyphAtlas].
  static Future<GlyphAtlas> generateEmpty({
    required double fontSize,
    required String fontFamily,
    List<String>? fontFamilyFallback,
  }) async {
    await Future.microtask(() {});
    final testPainter = TextPainter(
      text: TextSpan(
        text: 'A',
        style: TextStyle(
          fontSize: fontSize,
          fontFamily: fontFamily,
          fontFamilyFallback: fontFamilyFallback,
          color: Colors.white,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();

    final cellWidth = testPainter.width.ceilToDouble();
    final cellHeight = testPainter.height.ceilToDouble();

    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);

    // Draw a tiny 1x1 transparent image for the empty atlas
    canvas.drawRect(
      const Rect.fromLTWH(0, 0, 1, 1),
      Paint()..color = const ui.Color(0x00000000),
    );
    final picture = recorder.endRecording();
    final image = await picture.toImage(1, 1);

    return GlyphAtlas(
      image: image,
      charRects: {},
      cellWidth: cellWidth,
      cellHeight: cellHeight,
      fontSize: fontSize,
      fontFamily: fontFamily,
      fontFamilyFallback: fontFamilyFallback,
      nextGridIndex: 0,
    );
  }

  /// Generates a new standard [GlyphAtlas] texture by rendering characters.
  static Future<GlyphAtlas> generate({
    required double fontSize,
    required String fontFamily,
    List<String>? fontFamilyFallback,
  }) async {
    await Future.microtask(() {});
    final testPainter = TextPainter(
      text: TextSpan(
        text: 'A',
        style: TextStyle(
          fontSize: fontSize,
          fontFamily: fontFamily,
          fontFamilyFallback: fontFamilyFallback,
          color: Colors.white,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();

    final cellWidth = testPainter.width.ceilToDouble();
    final cellHeight = testPainter.height.ceilToDouble();
    final standardBaseline = testPainter.computeDistanceToActualBaseline(
      TextBaseline.alphabetic,
    );

    final colWidth = cellWidth + 2 * padding;
    final rowHeight = cellHeight + 2 * padding;

    final glyphs = <int>[];

    for (var i = 32; i <= 126; i++) {
      glyphs.add(i);
    }

    for (var i = 0x2500; i <= 0x257F; i++) {
      glyphs.add(i);
    }

    for (var i = 0x2580; i <= 0x259F; i++) {
      glyphs.add(i);
    }

    for (var i = 0x2800; i <= 0x28FF; i++) {
      glyphs.add(i);
    }

    final extraCodePoints = [
      0xf1,
      0x2019,
      0x2022,
      0x2122,
      0x25b6,
      0x25bc,
      0x25cb,
      0x25cf,
    ];
    glyphs.addAll(extraCodePoints);

    final numCols = 32;
    final List<_PlacedGlyph> placedGlyphs = [];
    var currentIdx = 0;

    for (var i = 0; i < glyphs.length; i++) {
      final code = glyphs[i];
      final char = String.fromCharCode(code);
      final tp = TextPainter(
        text: TextSpan(
          text: char,
          style: TextStyle(
            fontSize: fontSize,
            fontFamily: fontFamily,
            fontFamilyFallback: fontFamilyFallback,
            color: Colors.white,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      final isDouble = isWideGrapheme(char);

      var col = currentIdx % numCols;
      if (isDouble && col == numCols - 1) {
        currentIdx++;
        col = currentIdx % numCols;
      }
      final row = currentIdx ~/ numCols;
      placedGlyphs.add(_PlacedGlyph(char, tp, isDouble, col, row));
      currentIdx += isDouble ? 2 : 1;
    }

    final whiteIdx = currentIdx;
    final whiteCol = whiteIdx % numCols;
    final whiteRow = whiteIdx ~/ numCols;
    final whiteX = whiteCol * colWidth;
    final whiteY = whiteRow * rowHeight;
    currentIdx += 1;

    final totalGlyphs = currentIdx;
    final numRows = (totalGlyphs / numCols).ceil();

    final atlasWidth = (numCols * colWidth).ceil().toDouble();
    final atlasHeight = (numRows * rowHeight).ceil().toDouble();

    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    final charRects = <String, Rect>{};

    for (final pg in placedGlyphs) {
      final x = pg.col * colWidth;
      final y = pg.row * rowHeight;
      final targetWidth = pg.isDouble ? 2 * cellWidth : cellWidth;
      final targetSlotWidth = pg.isDouble ? 2 * colWidth : colWidth;

      canvas.save();
      canvas.clipRect(Rect.fromLTWH(x, y, targetSlotWidth, rowHeight));

      bool drawn = drawProceduralCharacter(
        canvas,
        x + padding,
        y + padding,
        targetWidth,
        cellHeight,
        padding,
        pg.char,
        Paint()..color = Colors.white,
      );

      if (!drawn) {
        final charBaseline = pg.painter.computeDistanceToActualBaseline(
          TextBaseline.alphabetic,
        );
        final dx = (targetWidth - pg.painter.width) / 2;
        final dy = standardBaseline - charBaseline;
        pg.painter.paint(canvas, Offset(x + padding + dx, y + padding + dy));
      }

      canvas.restore();
      charRects[pg.char] = Rect.fromLTWH(
        x + padding,
        y + padding,
        targetWidth,
        cellHeight,
      );
    }

    canvas.save();
    canvas.clipRect(Rect.fromLTWH(whiteX, whiteY, colWidth, rowHeight));
    canvas.drawRect(
      Rect.fromLTWH(whiteX, whiteY, colWidth, rowHeight),
      Paint()..color = Colors.white,
    );
    canvas.restore();
    charRects['\uFFFF'] = Rect.fromLTWH(
      whiteX + padding,
      whiteY + padding,
      cellWidth,
      cellHeight,
    );

    final picture = recorder.endRecording();
    final image = await picture.toImage(
      atlasWidth.toInt(),
      atlasHeight.toInt(),
    );

    return GlyphAtlas(
      image: image,
      charRects: charRects,
      cellWidth: cellWidth,
      cellHeight: cellHeight,
      fontSize: fontSize,
      fontFamily: fontFamily,
      fontFamilyFallback: fontFamilyFallback,
      nextGridIndex: totalGlyphs,
    );
  }
}
