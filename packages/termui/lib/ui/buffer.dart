import 'dart:math';
import 'dart:typed_data';
import 'package:characters/characters.dart';
import '../perf/tracer.dart';
import 'style.dart';

/// A single cell in the terminal buffer.
///
/// It only contains [char] and [style], minimizing memory allocation overhead.
class Cell {
  /// The single grapheme cluster character for this cell.
  String char;

  /// The style applied to this cell (includes transparency bit).
  Style style;

  /// Creates a cell with the given [char] and [style].
  Cell(this.char, this.style);

  /// Creates a cell initialized as a transparent space.
  Cell.empty() : char = ' ', style = Style.transparent;

  /// Creates a cell initialized as a solid space with empty style.
  Cell.blank() : char = ' ', style = Style.empty;

  /// Returns true if this cell has the transparent modifier active.
  bool get isTransparent => Modifier.has(style.modifiers, Modifier.transparent);

  /// Clones the cell.
  Cell clone() => Cell(char, style);

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is Cell && other.char == char && other.style == style;
  }

  @override
  int get hashCode => Object.hash(char, style);

  @override
  String toString() {
    return "Cell('$char', style: $style)";
  }
}

/// A 2D grid of [Cell]s representing a draw buffer.
class Buffer {
  static final int _traceClearId = Tracer.registerString('Buffer:clear');
  static final int _traceResizeId = Tracer.registerString('Buffer:resize');

  /// The width of the buffer in columns.
  int width;

  /// The height of the buffer in rows.
  int height;

  /// The flat list of cells representing the 2D grid.
  List<Cell> cells;

  /// Creates a new buffer of [width] by [height] initialized with transparent empty cells.
  Buffer(this.width, this.height)
    : cells = List.generate(width * height, (_) => Cell.empty());

  /// Creates a new buffer of [width] by [height] initialized with solid blank cells.
  Buffer.blank(this.width, this.height)
    : cells = List.generate(width * height, (_) => Cell.blank());

  int _index(int x, int y) => y * width + x;

  /// Gets the cell at ([x], [y]). Returns null if coordinates are out of bounds.
  Cell? getCell(int x, int y) {
    if (x < 0 || x >= width || y < 0 || y >= height) return null;
    return cells[_index(x, y)];
  }

  /// Sets the cell at ([x], [y]) to [cell]. Does nothing if coordinates are out of bounds.
  void setCell(int x, int y, Cell cell) {
    if (x < 0 || x >= width || y < 0 || y >= height) return;
    cells[_index(x, y)] = cell;
  }

  /// Resets all cells in the buffer to transparent empty cells.
  void clear() {
    Tracer.record(_traceClearId, Phase.begin, TraceCategory.paint);
    try {
      for (var i = 0; i < cells.length; i++) {
        final cell = cells[i];
        if (cell.char != ' ' || cell.style != Style.transparent) {
          cell.char = ' ';
          cell.style = Style.transparent;
        }
      }
    } finally {
      Tracer.record(_traceClearId, Phase.end, TraceCategory.paint);
    }
  }

  /// Fills the entire buffer with a copy of [cell].
  void fill(Cell cell) {
    for (var i = 0; i < cells.length; i++) {
      final targetCell = cells[i];
      targetCell.char = cell.char;
      targetCell.style = cell.style;
    }
  }

  /// Resizes the buffer to the new dimensions, preserving existing content where it fits.
  void resize(int newWidth, int newHeight) {
    Tracer.record(_traceResizeId, Phase.begin, TraceCategory.layout);
    try {
      newWidth = max(0, newWidth);
      newHeight = max(0, newHeight);
      final newCells = List.generate(newWidth * newHeight, (_) => Cell.empty());
      for (var y = 0; y < newHeight; y++) {
        for (var x = 0; x < newWidth; x++) {
          final targetIdx = y * newWidth + x;
          if (x < width && y < height) {
            final sourceCell = cells[_index(x, y)];
            newCells[targetIdx].char = sourceCell.char;
            newCells[targetIdx].style = sourceCell.style;
          }
        }
      }
      width = newWidth;
      height = newHeight;
      cells = newCells;
    } finally {
      Tracer.record(_traceResizeId, Phase.end, TraceCategory.layout);
    }
  }

  /// Writes styled [text] to the buffer starting at ([x], [y]).
  ///
  /// Newlines (`\n`) will wrap to [y] + 1 at the starting column [x].
  /// Any characters that fall out of bounds are clipped.
  void writeString(int x, int y, String text, Style style) {
    final startX = x;
    final chars = text.characters;
    var currentX = x;
    var currentY = y;

    for (final char in chars) {
      if (char == '\n') {
        currentX = startX;
        currentY++;
        continue;
      }
      if (currentX >= 0 &&
          currentX < width &&
          currentY >= 0 &&
          currentY < height) {
        // Clear potential wide char we are about to overwrite
        final cell = cells[_index(currentX, currentY)];
        if (cell.char == '') {
          if (currentX - 1 >= 0) {
            final prevCell = cells[_index(currentX - 1, currentY)];
            if (isWideGrapheme(prevCell.char)) {
              prevCell.char = ' ';
            }
          }
        } else if (isWideGrapheme(cell.char)) {
          if (currentX + 1 < width) {
            final nextCell = cells[_index(currentX + 1, currentY)];
            if (nextCell.char == '') {
              nextCell.char = ' ';
            }
          }
        }

        final isWide = isWideGrapheme(char);
        if (isWide && currentX == width - 1) {
          // Can't fit wide character in the last column, write a space instead
          final cell = cells[_index(currentX, currentY)];
          cell.char = ' ';
          cell.style = Style(
            foreground: style.foreground,
            background: style.background ?? cell.style.background,
            modifiers: style.modifiers,
          );
          currentX += 1;
        } else {
          final cell = cells[_index(currentX, currentY)];
          cell.char = char;
          cell.style = Style(
            foreground: style.foreground,
            background: style.background ?? cell.style.background,
            modifiers: style.modifiers,
          );
          if (isWide) {
            if (currentX + 1 < width) {
              // Clear potential wide char we are overwriting in the next cell
              final nextCell = cells[_index(currentX + 1, currentY)];
              if (isWideGrapheme(nextCell.char) && currentX + 2 < width) {
                final nextNextCell = cells[_index(currentX + 2, currentY)];
                if (nextNextCell.char == '') {
                  nextNextCell.char = ' ';
                }
              }
              nextCell.char = '';
              nextCell.style = Style(
                foreground: style.foreground,
                background: style.background ?? nextCell.style.background,
                modifiers: style.modifiers,
              );
            }
            currentX += 2;
          } else {
            currentX += 1;
          }
        }
      } else {
        currentX += 1;
      }
    }
  }
}

/// A buffer positioned in a 2D space with a Z-index for layering.
class LayeredBuffer {
  /// The underlying buffer content for this layer.
  final Buffer buffer;

  /// The x coordinate offset of this layer.
  final int x;

  /// The y coordinate offset of this layer.
  final int y;

  /// The z-index used for occlusion ordering (higher is on top).
  final int zIndex;

  /// Creates a layered buffer positioned at [x], [y] with an optional [zIndex].
  LayeredBuffer({
    required this.buffer,
    required this.x,
    required this.y,
    this.zIndex = 0,
  });
}

/// Composites multiple layered buffers onto a single target buffer.
class Compositor {
  static final int _traceCompositeId = Tracer.registerString(
    'Compositor:composite',
  );

  /// Flattens [layers] onto [target] in descending Z-index order (topmost first).
  ///
  /// Uses a bit-packed Uint32List occlusion map to prevent redundant writes and
  /// supports early exit if all destination cells are covered by opaque cells.
  void composite({
    required Buffer target,
    required List<LayeredBuffer> layers,
  }) {
    Tracer.record(_traceCompositeId, Phase.begin, TraceCategory.compositor);
    try {
      if (layers.isEmpty) return;

      // Stable sort in descending order (highest zIndex first)
      final sortedLayers = List<LayeredBuffer>.from(layers);
      final originalIndices = {
        for (var i = 0; i < layers.length; i++) layers[i]: i,
      };
      sortedLayers.sort((a, b) {
        final cmp = b.zIndex.compareTo(a.zIndex);
        if (cmp != 0) return cmp;
        return originalIndices[b]!.compareTo(originalIndices[a]!);
      });

      final totalCells = target.width * target.height;
      final written = Uint32List((totalCells + 31) >> 5);
      var remainingTargetCells = totalCells;

      for (final layer in sortedLayers) {
        if (remainingTargetCells <= 0) break; // Early exit: everything covered

        final buf = layer.buffer;
        final ox = layer.x;
        final oy = layer.y;

        for (var ly = 0; ly < buf.height; ly++) {
          final ty = oy + ly;
          if (ty < 0 || ty >= target.height) continue;

          for (var lx = 0; lx < buf.width; lx++) {
            final tx = ox + lx;
            if (tx < 0 || tx >= target.width) continue;

            final targetIdx = ty * target.width + tx;
            final word = targetIdx >> 5;
            final bit = targetIdx & 31;

            if ((written[word] & (1 << bit)) != 0) {
              continue; // Already covered by a higher layer
            }

            final sourceCell = buf.getCell(lx, ly);
            if (sourceCell == null || sourceCell.isTransparent) continue;

            final targetCell = target.cells[targetIdx];
            targetCell.char = sourceCell.char;
            targetCell.style = sourceCell.style;
            written[word] |= (1 << bit);
            remainingTargetCells--;
          }
        }
      }
    } finally {
      Tracer.record(_traceCompositeId, Phase.end, TraceCategory.compositor);
    }
  }
}

/// Returns true if the given grapheme cluster is a double-width (wide) character.
bool isWideGrapheme(String grapheme) {
  if (grapheme.isEmpty) return false;
  final codePoint = grapheme.runes.first;

  // CJK Unified Ideographs & Extension A
  if (codePoint >= 0x4E00 && codePoint <= 0x9FFF) return true;
  if (codePoint >= 0x3400 && codePoint <= 0x4DBF) return true;

  // Hangul Syllables
  if (codePoint >= 0xAC00 && codePoint <= 0xD7AF) return true;

  // CJK Symbols and Punctuation, Hiragana, Katakana, Hangul Compatibility Jamo, etc.
  if (codePoint >= 0x3000 && codePoint <= 0x31FF) return true;

  // Fullwidth Forms
  if (codePoint >= 0xFF01 && codePoint <= 0xFF60) return true;
  if (codePoint >= 0xFFE0 && codePoint <= 0xFFE6) return true;

  // Emojis & Miscellaneous Symbols and Pictographs
  if (codePoint >= 0x1F300 && codePoint <= 0x1F9FF) return true;
  if (codePoint >= 0x1FA00 && codePoint <= 0x1FAFF) return true;

  // CJK Unified Ideographs Extension B-F
  if (codePoint >= 0x20000 && codePoint <= 0x2EBEF) return true;

  // CJK Compatibility Ideographs
  if (codePoint >= 0xF900 && codePoint <= 0xFAFF) return true;

  // Additional CJK/Emoji ranges:
  if (codePoint >= 0x1100 && codePoint <= 0x11FF) return true; // Hangul Jamo
  if (codePoint >= 0x2E80 && codePoint <= 0x2FFF) {
    return true; // CJK Radicals Supplement & Kangxi Radicals etc
  }
  if (codePoint >= 0x1F000 && codePoint <= 0x1F2FF) return true;

  return false;
}
