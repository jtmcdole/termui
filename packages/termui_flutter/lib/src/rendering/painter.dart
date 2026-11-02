import 'dart:ui' as ui;
import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:termui/ui/buffer.dart';
import 'package:termui/ui/style.dart';
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
    final missingGlyphs = <String>[];

    final (fgSpriteCount, emojiSpriteCount) = _stageGridCells(
      geo,
      fallbackCells,
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
        Paint(), // No ColorFilter, preserves native emoji colors!
      );
    }

    if (fallbackCells.isNotEmpty) {
      _paintFallbackCells(canvas, fallbackCells);
    }
  }

  void _ensureBatchBuffers(int count) {
    if (_transformsBg != null && _transformsBg!.length == count * 4) return;

    _transformsBg = Float32List(count * 4);
    _rectsBg = Float32List(count * 4);
    _colorsBg = Int32List(count);

    _transformsFg = Float32List(count * 4);
    _rectsFg = Float32List(count * 4);
    _colorsFg = Int32List(count);

    _transformsEmoji = Float32List(count * 4);
    _rectsEmoji = Float32List(count * 4);
  }

  (int, int) _stageGridCells(
    _AtlasGeometry geo,
    List<_FallbackCell> fallbackCells,
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

        if (char.isEmpty || char == ' ') continue;

        (fgSpriteCount, emojiSpriteCount) = _stageForegroundCell(
          char: char,
          modifiers: modifiers,
          fgArgb: fgArgb,
          bgArgb: bgArgb,
          isReverse: isReverse,
          screenX: screenX,
          screenY: screenY,
          fgSpriteCount: fgSpriteCount,
          emojiSpriteCount: emojiSpriteCount,
          geo: geo,
          fallbackCells: fallbackCells,
          missingGlyphs: missingGlyphs,
        );
      }
    }

    return (fgSpriteCount, emojiSpriteCount);
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
    required int modifiers,
    required int fgArgb,
    required int bgArgb,
    required bool isReverse,
    required double screenX,
    required double screenY,
    required int fgSpriteCount,
    required int emojiSpriteCount,
    required _AtlasGeometry geo,
    required List<_FallbackCell> fallbackCells,
    required List<String> missingGlyphs,
  }) {
    final sourceRect = atlas.charRects[char];
    if (sourceRect == null) {
      _stageFallbackCell(
        missingGlyphs,
        fallbackCells,
        char: char,
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

    _stageTextSprite(
      fgSpriteCount,
      char,
      screenX,
      screenY,
      sourceRect,
      _resolveFgColor(fgArgb, bgArgb, isReverse: isReverse),
      geo,
    );
    return (fgSpriteCount + 1, emojiSpriteCount);
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

  void _stageFallbackCell(
    List<String> missingGlyphs,
    List<_FallbackCell> fallbackCells, {
    required String char,
    required int modifiers,
    required int fgArgb,
    required int bgArgb,
    required double screenX,
    required double screenY,
    required _AtlasGeometry geo,
  }) {
    missingGlyphs.add(char);
    fallbackCells.add(
      _FallbackCell(
        char: char,
        fontFamily: fontFamily,
        fontFamilyFallback: fontFamilyFallback,
        modifiers: modifiers,
        fgArgb: fgArgb,
        bgArgb: bgArgb,
        x: screenX,
        y: screenY,
        w: isWideGrapheme(char) ? 2 * geo.cellWidth : geo.cellWidth,
        h: geo.cellHeight,
      ),
    );
  }

  void _paintFallbackCells(Canvas canvas, List<_FallbackCell> fallbackCells) {
    for (final fc in fallbackCells) {
      final isReverse = Modifier.has(fc.modifiers, Modifier.reverse);
      final color = Color(
        _resolveFgColor(fc.fgArgb, fc.bgArgb, isReverse: isReverse),
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
    required bool isReverse,
  }) {
    if (isReverse) {
      return bgArgb == 0 ? 0xFF000000 : bgArgb;
    }
    return fgArgb == 0 ? 0xFFFFFFFF : fgArgb;
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

final class _FallbackCell {
  final String char;
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
