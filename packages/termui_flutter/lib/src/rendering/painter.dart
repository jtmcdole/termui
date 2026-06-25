import 'dart:ui' as ui;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' hide Color;
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:termui/ui/buffer.dart';
import 'package:termui/ui/style.dart';
import 'atlas.dart';

bool _isBlockCharacter(String char) {
  if (char.isEmpty) return false;
  final code = char.codeUnitAt(0);
  if (code >= 0x2580 && code <= 0x2590) return true;
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
class TuiAtlasPainter extends CustomPainter {
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

  /// Constructs a [TuiAtlasPainter] targeting the supplied [buffer].
  TuiAtlasPainter({
    required this.buffer,
    required this.atlas,
    required this.fallbackPainters,
    this.onMissingGlyphs,
  });

  void _drawRawAtlasInChunks(
    Canvas canvas,
    ui.Image image,
    Float32List transforms,
    Float32List rects,
    Int32List colors,
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
      final Int32List colorsSub = Int32List.sublistView(colors, i, end);

      canvas.drawRawAtlas(
        image,
        transformsSub,
        rectsSub,
        colorsSub,
        BlendMode.modulate,
        null,
        paint,
      );
    }
  }

  @override
  void paint(Canvas canvas, Size size) {
    final cols = buffer.width;
    final rows = buffer.height;
    final cellWidth = atlas.cellWidth;
    final cellHeight = atlas.cellHeight;
    final count = cols * rows;

    if (_transformsBg == null || _transformsBg!.length != count * 4) {
      _transformsBg = Float32List(count * 4);
      _rectsBg = Float32List(count * 4);
      _colorsBg = Int32List(count);

      _transformsFg = Float32List(count * 4);
      _rectsFg = Float32List(count * 4);
      _colorsFg = Int32List(count);
    }

    final bgRect = atlas.charRects['\uFFFF']!;
    final whiteX = bgRect.left;
    final whiteY = bgRect.top;
    final whiteW = bgRect.width;
    final whiteH = bgRect.height;

    var fgSpriteCount = 0;
    final fallbackCells = <_FallbackCell>[];
    final missingGlyphs = <String>[];

    const bleedBg = 0.5;

    for (var y = 0; y < rows; y++) {
      for (var x = 0; x < cols; x++) {
        final char = buffer.getCharacter(x, y);
        final bgArgb = buffer.getBackground(x, y);
        final fgArgb = buffer.getForeground(x, y);
        final modifiers = buffer.getModifiers(x, y);

        final idx = y * cols + x;
        final screenX = x * cellWidth;
        final screenY = y * cellHeight;

        // Background
        final bgScale = cellWidth / whiteW;
        _transformsBg![idx * 4 + 0] = bgScale;
        _transformsBg![idx * 4 + 1] = 0.0;
        _transformsBg![idx * 4 + 2] = screenX - bleedBg * bgScale;
        _transformsBg![idx * 4 + 3] = screenY - bleedBg * bgScale;

        _rectsBg![idx * 4 + 0] = whiteX - bleedBg;
        _rectsBg![idx * 4 + 1] = whiteY - bleedBg;
        _rectsBg![idx * 4 + 2] = whiteX + whiteW + bleedBg;
        _rectsBg![idx * 4 + 3] = whiteY + whiteH + bleedBg;

        final isReverse = Modifier.has(modifiers, Modifier.reverse);
        final bgCol = isReverse
            ? (fgArgb == 0 ? null : fgArgb)
            : (bgArgb == 0 ? null : bgArgb);
        _colorsBg![idx] = bgCol ?? (isReverse ? 0xFFFFFFFF : 0xFF000000);

        // Foreground
        if (char.isNotEmpty && char != ' ') {
          final sourceRect = atlas.charRects[char];

          if (sourceRect != null) {
            final fgIdx = fgSpriteCount;
            fgSpriteCount++;

            final bleedFg = _isBlockCharacter(char) ? 0.5 : 0.0;

            final fgScale = cellWidth / atlas.cellWidth;
            _transformsFg![fgIdx * 4 + 0] = fgScale;
            _transformsFg![fgIdx * 4 + 1] = 0.0;
            _transformsFg![fgIdx * 4 + 2] = screenX - bleedFg * fgScale;
            _transformsFg![fgIdx * 4 + 3] = screenY - bleedFg * fgScale;

            _rectsFg![fgIdx * 4 + 0] = sourceRect.left - bleedFg;
            _rectsFg![fgIdx * 4 + 1] = sourceRect.top - bleedFg;
            _rectsFg![fgIdx * 4 + 2] = sourceRect.right + bleedFg;
            _rectsFg![fgIdx * 4 + 3] = sourceRect.bottom + bleedFg;

            final fgCol = isReverse
                ? (bgArgb == 0 ? null : bgArgb)
                : (fgArgb == 0 ? null : fgArgb);
            _colorsFg![fgIdx] = fgCol ?? (isReverse ? 0xFF000000 : 0xFFFFFFFF);
          } else {
            missingGlyphs.add(char);

            fallbackCells.add(
              _FallbackCell(
                char: char,
                modifiers: modifiers,
                fgArgb: fgArgb,
                bgArgb: bgArgb,
                x: screenX,
                y: screenY,
                w: isWideGrapheme(char) ? 2 * cellWidth : cellWidth,
                h: cellHeight,
              ),
            );
          }
        }
      }
    }

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
      Paint()..filterQuality = kIsWeb ? FilterQuality.none : FilterQuality.low,
    );

    if (fgSpriteCount > 0) {
      _drawRawAtlasInChunks(
        canvas,
        atlas.image,
        _transformsFg!,
        _rectsFg!,
        _colorsFg!,
        fgSpriteCount,
        Paint()
          ..filterQuality = kIsWeb ? FilterQuality.none : FilterQuality.low,
      );
    }

    if (!kIsWeb && fallbackCells.isNotEmpty) {
      for (final fc in fallbackCells) {
        final isReverse = Modifier.has(fc.modifiers, Modifier.reverse);
        final fgCol = isReverse
            ? (fc.bgArgb == 0 ? null : fc.bgArgb)
            : (fc.fgArgb == 0 ? null : fc.fgArgb);
        final color = fgCol != null
            ? Color(fgCol)
            : (isReverse ? Colors.black : Colors.white);

        final isBold = Modifier.has(fc.modifiers, Modifier.bold);
        final isDim = Modifier.has(fc.modifiers, Modifier.dim);

        final key = (fc.char, isBold, isDim, color);
        final tp = fallbackPainters[key];
        if (tp != null) {
          final offsetX = (fc.w - tp.width) / 2;
          final offsetY = (fc.h - tp.height) / 2;
          tp.paint(canvas, Offset(fc.x + offsetX, fc.y + offsetY));
        }
      }
    }
  }

  @override
  bool shouldRepaint(covariant TuiAtlasPainter oldDelegate) => true;
}

class _FallbackCell {
  final String char;
  final int modifiers;
  final int fgArgb;
  final int bgArgb;
  final double x;
  final double y;
  final double w;
  final double h;

  _FallbackCell({
    required this.char,
    required this.modifiers,
    required this.fgArgb,
    required this.bgArgb,
    required this.x,
    required this.y,
    required this.w,
    required this.h,
  });
}
