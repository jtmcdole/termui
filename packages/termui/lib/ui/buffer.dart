import 'package:termui/termui.dart';
import 'dart:math';
import 'dart:typed_data';
import 'package:characters/characters.dart';

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

/// A 2D grid of cell data stored in parallel flat lists.
class Buffer {
  static final int _traceClearId = Tracer.registerString('Buffer:clear');
  static final int _traceResizeId = Tracer.registerString('Buffer:resize');

  /// The width of the buffer in columns.
  int width;

  /// The height of the buffer in rows.
  int height;

  /// Flat list of characters representing the grid.
  List<String> characters;

  /// Flat list of packed 32-bit foreground colors.
  Uint32List fgColors;

  /// Flat list of packed 32-bit background colors.
  Uint32List bgColors;

  /// Flat list of packed 32-bit style modifier bitmasks.
  Uint32List modifiers;

  /// The list of terminal effects registered in this buffer.
  final List<RegisteredEffect> effects = [];

  /// Adds a terminal effect to this buffer.
  void addEffect(RegisteredEffect effect) {
    effects.add(effect);
  }

  /// Creates a new buffer of [width] by [height] initialized with transparent empty cell data.
  Buffer(this.width, this.height)
    : characters = List.filled(width * height, ' '),
      fgColors = Uint32List(width * height),
      bgColors = Uint32List(width * height),
      modifiers = Uint32List(width * height) {
    modifiers.fillRange(0, modifiers.length, Modifier.transparent);
  }

  /// Creates a new buffer of [width] by [height] initialized with solid blank cell data.
  Buffer.blank(this.width, this.height)
    : characters = List.filled(width * height, ' '),
      fgColors = Uint32List(width * height),
      bgColors = Uint32List(width * height),
      modifiers = Uint32List(width * height);

  int _index(int x, int y) => y * width + x;

  /// Gets the cell at ([x], [y]). Returns null if coordinates are out of bounds.
  Cell? getCell(int x, int y) {
    if (x < 0 || x >= width || y < 0 || y >= height) return null;
    return _VirtualCell(this, _index(x, y));
  }

  /// Sets the cell data at ([x], [y]) using [cell]. Does nothing if coordinates are out of bounds.
  void setCell(int x, int y, Cell cell) {
    if (x < 0 || x >= width || y < 0 || y >= height) return;
    final idx = _index(x, y);
    characters[idx] = cell.char;
    fgColors[idx] = cell.style.foreground?.argb ?? 0;
    bgColors[idx] = cell.style.background?.argb ?? 0;
    modifiers[idx] = cell.style.modifiers;
  }

  /// Resets all cells in the buffer to transparent empty cells.
  void clear() {
    Tracer.record(_traceClearId, Phase.begin, TraceCategory.paint);
    try {
      characters.fillRange(0, characters.length, ' ');
      fgColors.fillRange(0, fgColors.length, 0);
      bgColors.fillRange(0, bgColors.length, 0);
      modifiers.fillRange(0, modifiers.length, Modifier.transparent);
      effects.clear();
    } finally {
      Tracer.record(_traceClearId, Phase.end, TraceCategory.paint);
    }
  }

  /// Fills the entire buffer with a copy of [cell].
  void fill(Cell cell) {
    characters.fillRange(0, characters.length, cell.char);
    fgColors.fillRange(0, fgColors.length, cell.style.foreground?.argb ?? 0);
    bgColors.fillRange(0, bgColors.length, cell.style.background?.argb ?? 0);
    modifiers.fillRange(0, modifiers.length, cell.style.modifiers);
  }

  /// Resizes the buffer to the new dimensions, preserving existing content where it fits.
  void resize(int newWidth, int newHeight) {
    Tracer.record(_traceResizeId, Phase.begin, TraceCategory.layout);
    try {
      newWidth = max(0, newWidth);
      newHeight = max(0, newHeight);
      final newChars = List.filled(newWidth * newHeight, ' ');
      final newFg = Uint32List(newWidth * newHeight);
      final newBg = Uint32List(newWidth * newHeight);
      final newModifiers = Uint32List(newWidth * newHeight);

      newModifiers.fillRange(0, newModifiers.length, Modifier.transparent);

      for (var y = 0; y < newHeight; y++) {
        for (var x = 0; x < newWidth; x++) {
          final targetIdx = y * newWidth + x;
          if (x < width && y < height) {
            final sourceIdx = _index(x, y);
            newChars[targetIdx] = characters[sourceIdx];
            newFg[targetIdx] = fgColors[sourceIdx];
            newBg[targetIdx] = bgColors[sourceIdx];
            newModifiers[targetIdx] = modifiers[sourceIdx];
          }
        }
      }
      width = newWidth;
      height = newHeight;
      characters = newChars;
      fgColors = newFg;
      bgColors = newBg;
      modifiers = newModifiers;
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
        final idx = _index(currentX, currentY);
        // Clear potential wide char we are about to overwrite
        if (characters[idx] == '') {
          if (currentX - 1 >= 0) {
            final prevIdx = _index(currentX - 1, currentY);
            if (isWideGrapheme(characters[prevIdx])) {
              characters[prevIdx] = ' ';
            }
          }
        } else if (isWideGrapheme(characters[idx])) {
          if (currentX + 1 < width) {
            final nextIdx = _index(currentX + 1, currentY);
            if (characters[nextIdx] == '') {
              characters[nextIdx] = ' ';
            }
          }
        }

        final isWide = isWideGrapheme(char);
        if (isWide && currentX == width - 1) {
          // Can't fit wide character in the last column, write a space instead
          characters[idx] = ' ';
          fgColors[idx] = style.foreground?.argb ?? 0;
          bgColors[idx] = style.background?.argb ?? bgColors[idx];
          modifiers[idx] = style.modifiers;
          currentX += 1;
        } else {
          characters[idx] = char;
          fgColors[idx] = style.foreground?.argb ?? 0;
          bgColors[idx] = style.background?.argb ?? bgColors[idx];
          modifiers[idx] = style.modifiers;
          if (isWide) {
            if (currentX + 1 < width) {
              final nextIdx = _index(currentX + 1, currentY);
              // Clear potential wide char we are overwriting in the next cell
              if (isWideGrapheme(characters[nextIdx]) && currentX + 2 < width) {
                final nextNextIdx = _index(currentX + 2, currentY);
                if (characters[nextNextIdx] == '') {
                  characters[nextNextIdx] = ' ';
                }
              }
              characters[nextIdx] = '';
              fgColors[nextIdx] = style.foreground?.argb ?? 0;
              bgColors[nextIdx] = style.background?.argb ?? bgColors[nextIdx];
              modifiers[nextIdx] = style.modifiers;
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
  static final int _traceCompositeRecursiveId = Tracer.registerString(
    'Compositor:_compositeRecursive',
  );
  static final int _traceCompositeOpaqueContentId = Tracer.registerString(
    'Compositor:_compositeOpaqueContent',
  );

  final List<Buffer> _bufferPool = [];
  int _poolIndex = 0;

  Buffer _rentBuffer(int width, int height) {
    if (_poolIndex < _bufferPool.length) {
      final cached = _bufferPool[_poolIndex++];
      if (cached.width != width || cached.height != height) {
        cached.resize(width, height);
      } else {
        cached.clear();
      }
      return cached;
    }
    final newBuf = Buffer(width, height);
    _bufferPool.add(newBuf);
    _poolIndex++;
    return newBuf;
  }

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

      _poolIndex = 0;
      _compositeRecursive(target, sortedLayers, 0);
    } finally {
      Tracer.record(_traceCompositeId, Phase.end, TraceCategory.compositor);
    }
  }

  void _compositeRecursive(
    Buffer target,
    List<LayeredBuffer> sortedLayers,
    int startIndex, {
    bool initializeMasksFromTarget = false,
  }) {
    Tracer.record(
      _traceCompositeRecursiveId,
      Phase.begin,
      TraceCategory.compositor,
    );
    try {
      final totalCells = target.width * target.height;
      final fgWritten = Uint32List((totalCells + 31) >> 5);
      final bgWritten = Uint32List((totalCells + 31) >> 5);
      var remainingFg = totalCells;
      var remainingBg = totalCells;

      if (initializeMasksFromTarget) {
        // Initialize masks based on existing target content (e.g. from pre-filled effect layers)
        for (var i = 0; i < totalCells; i++) {
          final isTransparent =
              (target.modifiers[i] & Modifier.transparent) != 0;
          if (!isTransparent) {
            final word = i >> 5;
            final bit = i & 31;
            // Foreground is considered written if the cell is not transparent
            fgWritten[word] |= (1 << bit);
            remainingFg--;

            if (target.bgColors[i] != 0) {
              bgWritten[word] |= (1 << bit);
              remainingBg--;
            }
          }
        }
      }

      for (var i = startIndex; i < sortedLayers.length; i++) {
        if (remainingFg <= 0 && remainingBg <= 0) {
          break; // Early exit: everything covered
        }

        final layer = sortedLayers[i];

        if (layer.buffer.effects.isNotEmpty) {
          final tempBuffer = _rentBuffer(target.width, target.height);

          // 1. Composite this layer's content onto tempBuffer
          _compositeOpaqueContent(tempBuffer, layer);

          // 2. Recurse to resolve the remaining lower layers into tempBuffer
          if (i + 1 < sortedLayers.length) {
            _compositeRecursive(
              tempBuffer,
              sortedLayers,
              i + 1,
              initializeMasksFromTarget: true,
            );
          }

          // 3. Apply this layer's effects to the resolved background
          for (final effect in layer.buffer.effects) {
            final effectTraceId = Tracer.registerString(
              'Compositor:applyEffect:${effect.effect.runtimeType}',
            );
            Tracer.record(effectTraceId, Phase.begin, TraceCategory.compositor);
            try {
              effect.effect.applyEffect(
                tempBuffer,
                Rect(
                  layer.x + effect.bounds.x,
                  layer.y + effect.bounds.y,
                  effect.bounds.width,
                  effect.bounds.height,
                ),
              );
            } finally {
              Tracer.record(effectTraceId, Phase.end, TraceCategory.compositor);
            }
          }

          // Composite the mutated background onto our target (respecting occlusion)
          var targetIdx = 0;
          for (var ty = 0; ty < target.height; ty++) {
            for (var tx = 0; tx < target.width; tx++, targetIdx++) {
              final word = targetIdx >> 5;
              final bit = targetIdx & 31;

              final fgOccluded = (fgWritten[word] & (1 << bit)) != 0;
              final bgOccluded = (bgWritten[word] & (1 << bit)) != 0;

              if (fgOccluded && bgOccluded) continue; // Fully occluded

              final sourceIsTransparent =
                  (tempBuffer.modifiers[targetIdx] & Modifier.transparent) != 0;
              if (sourceIsTransparent) continue;

              final sourceBg = tempBuffer.bgColors[targetIdx];

              if (!fgOccluded && !bgOccluded && sourceBg != 0) {
                target.characters[targetIdx] = tempBuffer.characters[targetIdx];
                target.fgColors[targetIdx] = tempBuffer.fgColors[targetIdx];
                target.bgColors[targetIdx] = sourceBg;
                target.modifiers[targetIdx] = tempBuffer.modifiers[targetIdx];
                fgWritten[word] |= (1 << bit);
                bgWritten[word] |= (1 << bit);
                remainingFg--;
                remainingBg--;
              } else {
                if (!fgOccluded) {
                  target.characters[targetIdx] =
                      tempBuffer.characters[targetIdx];
                  target.fgColors[targetIdx] = tempBuffer.fgColors[targetIdx];
                  target.modifiers[targetIdx] = tempBuffer.modifiers[targetIdx];
                  fgWritten[word] |= (1 << bit);
                  remainingFg--;
                }

                if (!bgOccluded && sourceBg != 0) {
                  target.bgColors[targetIdx] = sourceBg;
                  bgWritten[word] |= (1 << bit);
                  remainingBg--;
                }
              }
            }
          }

          // We have processed all remaining layers in the recursive call
          break;
        } else {
          final buf = layer.buffer;
          final ox = layer.x;
          final oy = layer.y;

          // No effects on this layer. Fast path: Composite directly to target.
          for (var ly = 0; ly < buf.height; ly++) {
            final ty = oy + ly;
            if (ty < 0 || ty >= target.height) continue;

            var targetIdx = ty * target.width + ox;
            for (var lx = 0; lx < buf.width; lx++, targetIdx++) {
              final tx = ox + lx;
              if (tx < 0 || tx >= target.width) continue;

              final word = targetIdx >> 5;
              final bit = targetIdx & 31;

              final fgOccluded = (fgWritten[word] & (1 << bit)) != 0;
              final bgOccluded = (bgWritten[word] & (1 << bit)) != 0;

              if (fgOccluded && bgOccluded) continue; // Fully occluded

              final sourceIdx = ly * buf.width + lx;
              final sourceIsTransparent =
                  (buf.modifiers[sourceIdx] & Modifier.transparent) != 0;
              if (sourceIsTransparent) continue;

              final sourceBg = buf.bgColors[sourceIdx];

              if (!fgOccluded && !bgOccluded && sourceBg != 0) {
                // Fast path: write both!
                target.characters[targetIdx] = buf.characters[sourceIdx];
                target.fgColors[targetIdx] = buf.fgColors[sourceIdx];
                target.bgColors[targetIdx] = sourceBg;
                target.modifiers[targetIdx] = buf.modifiers[sourceIdx];
                fgWritten[word] |= (1 << bit);
                bgWritten[word] |= (1 << bit);
                remainingFg--;
                remainingBg--;
              } else {
                // Slow path: independent foreground/background blending
                if (!fgOccluded) {
                  target.characters[targetIdx] = buf.characters[sourceIdx];
                  target.fgColors[targetIdx] = buf.fgColors[sourceIdx];
                  target.modifiers[targetIdx] = buf.modifiers[sourceIdx];
                  fgWritten[word] |= (1 << bit);
                  remainingFg--;
                }

                if (!bgOccluded && sourceBg != 0) {
                  target.bgColors[targetIdx] = sourceBg;
                  bgWritten[word] |= (1 << bit);
                  remainingBg--;
                }
              }
            }
          }
        }
      }
    } finally {
      Tracer.record(
        _traceCompositeRecursiveId,
        Phase.end,
        TraceCategory.compositor,
      );
    }
  }

  void _compositeOpaqueContent(Buffer target, LayeredBuffer layer) {
    Tracer.record(
      _traceCompositeOpaqueContentId,
      Phase.begin,
      TraceCategory.compositor,
    );
    try {
      final buf = layer.buffer;
      final ox = layer.x;
      final oy = layer.y;

      for (var ly = 0; ly < buf.height; ly++) {
        final ty = oy + ly;
        if (ty < 0 || ty >= target.height) continue;

        var targetIdx = ty * target.width + ox;
        for (var lx = 0; lx < buf.width; lx++, targetIdx++) {
          final tx = ox + lx;
          if (tx < 0 || tx >= target.width) continue;

          final sourceIdx = ly * buf.width + lx;
          final sourceIsTransparent =
              (buf.modifiers[sourceIdx] & Modifier.transparent) != 0;
          if (sourceIsTransparent) continue;

          final bg = buf.bgColors[sourceIdx];
          if (bg != 0) {
            target.characters[targetIdx] = buf.characters[sourceIdx];
            target.fgColors[targetIdx] = buf.fgColors[sourceIdx];
            target.bgColors[targetIdx] = bg;
            target.modifiers[targetIdx] = buf.modifiers[sourceIdx];
          } else {
            target.characters[targetIdx] = buf.characters[sourceIdx];
            target.fgColors[targetIdx] = buf.fgColors[sourceIdx];
            target.modifiers[targetIdx] = buf.modifiers[sourceIdx];
          }
        }
      }
    } finally {
      Tracer.record(
        _traceCompositeOpaqueContentId,
        Phase.end,
        TraceCategory.compositor,
      );
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

/// A virtual proxy Cell that intercepts reads/writes and delegates them to the Buffer.
class _VirtualCell extends Cell {
  final Buffer _buffer;
  final int _index;

  _VirtualCell(this._buffer, this._index)
    : super(
        _buffer.characters[_index],
        Style(
          foreground: _buffer.fgColors[_index] != 0
              ? Color.argb(_buffer.fgColors[_index])
              : null,
          background: _buffer.bgColors[_index] != 0
              ? Color.argb(_buffer.bgColors[_index])
              : null,
          modifiers: _buffer.modifiers[_index],
        ),
      );

  @override
  String get char => _buffer.characters[_index];

  @override
  set char(String value) {
    super.char = value;
    _buffer.characters[_index] = value;
  }

  @override
  Style get style {
    return Style(
      foreground: _buffer.fgColors[_index] != 0
          ? Color.argb(_buffer.fgColors[_index])
          : null,
      background: _buffer.bgColors[_index] != 0
          ? Color.argb(_buffer.bgColors[_index])
          : null,
      modifiers: _buffer.modifiers[_index],
    );
  }

  @override
  set style(Style value) {
    super.style = value;
    _buffer.fgColors[_index] = value.foreground?.argb ?? 0;
    _buffer.bgColors[_index] = value.background?.argb ?? 0;
    _buffer.modifiers[_index] = value.modifiers;
  }
}
