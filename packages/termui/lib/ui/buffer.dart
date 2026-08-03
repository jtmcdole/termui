import 'package:termui/termui.dart';
import 'dart:math';
import 'dart:typed_data';
import 'package:characters/characters.dart';

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

  /// Single unified data array for fg, bg, and modifiers.
  /// layout: [fg, bg, mod, fg, bg, mod...]
  Uint32List attributes;

  /// The list of terminal effects registered in this buffer.
  final List<RegisteredEffect> effects = [];

  /// Adds a terminal effect to this buffer.
  void addEffect(RegisteredEffect effect) {
    effects.add(effect);
  }

  /// Creates a new buffer of [width] by [height] initialized with transparent empty cell data.
  Buffer(this.width, this.height)
    : characters = List.filled(width * height, ' '),
      attributes = Uint32List(width * height * 3) {
    for (var i = 2; i < attributes.length; i += 3) {
      attributes[i] = Modifier.transparent;
    }
  }

  /// Creates a new buffer of [width] by [height] initialized with solid blank cell data.
  Buffer.blank(this.width, this.height)
    : characters = List.filled(width * height, ' '),
      attributes = Uint32List(width * height * 3);

  /// Stack of active canvas clip rectangles.
  final List<Rect> _clipStack = [];

  /// Returns the current active clip rectangle, defaulting to full buffer bounds if stack is empty.
  Rect get activeClip =>
      _clipStack.isEmpty ? Rect(0, 0, width, height) : _clipStack.last;

  /// Pushes a new clip rectangle onto the stack, intersecting it with the current active clip.
  void pushClip(Rect clipRect) {
    _clipStack.add(activeClip.intersect(clipRect));
  }

  /// Pops the most recently pushed clip rectangle from the stack.
  void popClip() {
    if (_clipStack.isNotEmpty) {
      _clipStack.removeLast();
    }
  }

  /// Whether cell ([x], [y]) is valid and inside the current active clip bounds.
  bool isCellValid(int x, int y) {
    if (x < 0 || x >= width || y < 0 || y >= height) return false;
    if (_clipStack.isEmpty) return true;
    return _clipStack.last.contains(x, y);
  }

  /// Gets the character at ([x], [y]). Returns a space if coordinates are out of bounds.
  String getCharacter(int x, int y) {
    if (!isCellValid(x, y)) return ' ';
    return characters[y * width + x];
  }

  /// Gets the foreground color at ([x], [y]). Returns 0 if coordinates are out of bounds.
  int getForeground(int x, int y) {
    if (!isCellValid(x, y)) return 0;
    return attributes[(y * width + x) * 3 + 0];
  }

  /// Gets the background color at ([x], [y]). Returns 0 if coordinates are out of bounds.
  int getBackground(int x, int y) {
    if (!isCellValid(x, y)) return 0;
    return attributes[(y * width + x) * 3 + 1];
  }

  /// Gets the modifiers at ([x], [y]). Returns transparent if coordinates are out of bounds.
  int getModifiers(int x, int y) {
    if (!isCellValid(x, y)) {
      return Modifier.transparent;
    }
    return attributes[(y * width + x) * 3 + 2];
  }

  /// Sets character at coordinates.
  void setCharacter(int x, int y, String char) {
    if (isCellValid(x, y)) {
      characters[y * width + x] = char;
    }
  }

  /// Sets foreground color at coordinates.
  void setForeground(int x, int y, int fg) {
    if (isCellValid(x, y)) {
      attributes[(y * width + x) * 3 + 0] = fg;
    }
  }

  /// Sets background color at coordinates.
  void setBackground(int x, int y, int bg) {
    if (isCellValid(x, y)) {
      attributes[(y * width + x) * 3 + 1] = bg;
    }
  }

  /// Sets modifiers at coordinates.
  void setModifiers(int x, int y, int mod) {
    if (isCellValid(x, y)) {
      attributes[(y * width + x) * 3 + 2] = mod;
    }
  }

  /// Sets character, colors, and modifiers at coordinates.
  void setCell(int x, int y, String char, int fg, int bg, int mod) {
    if (isCellValid(x, y)) {
      final idx = (y * width + x) * 3;
      characters[y * width + x] = char;
      attributes[idx + 0] = fg;
      attributes[idx + 1] = bg;
      attributes[idx + 2] = mod;
    }
  }

  /// Sets the cell attributes at ([x], [y]). Does nothing if coordinates are out of bounds.
  void setAttributes(
    int x,
    int y, {
    String? char,
    int? fg,
    int? bg,
    int? modifiers,
  }) {
    if (!isCellValid(x, y)) return;
    final idx = (y * width + x) * 3;
    if (char != null) characters[y * width + x] = char;
    if (fg != null) attributes[idx + 0] = fg;
    if (bg != null) attributes[idx + 1] = bg;
    if (modifiers != null) attributes[idx + 2] = modifiers;
  }

  /// Resets all cells in the buffer to transparent empty cells.
  void clear() {
    Tracer.record(_traceClearId, Phase.begin, TraceCategory.paint);
    try {
      characters.fillRange(0, characters.length, ' ');
      attributes.fillRange(0, attributes.length, 0);
      for (var i = 2; i < attributes.length; i += 3) {
        attributes[i] = Modifier.transparent;
      }
      effects.clear();
    } finally {
      Tracer.record(_traceClearId, Phase.end, TraceCategory.paint);
    }
  }

  /// Fills the entire buffer with the specified attributes.
  void fillAttributes({String? char, int? fg, int? bg, int? modifiers}) {
    if (char != null) characters.fillRange(0, characters.length, char);
    if (fg != null || bg != null || modifiers != null) {
      for (var i = 0; i < characters.length; i++) {
        final idx = i * 3;
        if (fg != null) attributes[idx + 0] = fg;
        if (bg != null) attributes[idx + 1] = bg;
        if (modifiers != null) attributes[idx + 2] = modifiers;
      }
    }
  }

  /// Fills a rectangular region with the given character and attributes.
  void fillRect(Rect rect, {String? char, int? fg, int? bg, int? modifiers}) {
    final clipped = _clipStack.isEmpty ? rect : activeClip.intersect(rect);
    if (clipped.width <= 0 || clipped.height <= 0) return;

    final startX = max(0, clipped.left);
    final startY = max(0, clipped.top);
    final endX = min(width, clipped.right);
    final endY = min(height, clipped.bottom);
    if (startX >= endX || startY >= endY) return;

    if (char != null) {
      for (var y = startY; y < endY; y++) {
        final rowStart = y * width + startX;
        final rowEnd = y * width + endX;
        characters.fillRange(rowStart, rowEnd, char);
      }
    }

    if (fg != null || bg != null || modifiers != null) {
      for (var y = startY; y < endY; y++) {
        final rowOffset = y * width;
        for (var x = startX; x < endX; x++) {
          final idx = rowOffset + x;
          final attrIdx = idx * 3;
          if (fg != null) attributes[attrIdx + 0] = fg;
          if (bg != null) attributes[attrIdx + 1] = bg;
          if (modifiers != null) attributes[attrIdx + 2] = modifiers;
        }
      }
    }
  }

  /// Draws a patterned caution tape in the specified rectangular bounds.
  void drawCautionTape(Rect rect, int offsetX, int offsetY) {
    final clipped = _clipStack.isEmpty ? rect : activeClip.intersect(rect);
    if (clipped.width <= 0 || clipped.height <= 0) return;

    final startX = max(0, clipped.left);
    final startY = max(0, clipped.top);
    final endX = min(width, clipped.right);
    final endY = min(height, clipped.bottom);
    if (startX >= endX || startY >= endY) return;

    final yellow = 0xFFFCD116;
    final charcoal = 0xFF36454F;

    for (var y = startY; y < endY; y++) {
      final ly = y - offsetY;
      final rowOffset = y * width;
      for (var x = startX; x < endX; x++) {
        final lx = x - offsetX;
        final mod = ((lx - ly) % 3 + 3) % 3;
        final char = mod == 0 ? '\u259C' : (mod == 1 ? '\u2599' : ' ');
        final idx = rowOffset + x;
        characters[idx] = char;
        final attrIdx = idx * 3;
        attributes[attrIdx + 0] = yellow;
        attributes[attrIdx + 1] = charcoal;
      }
    }
  }

  /// Resizes the buffer to the new dimensions, preserving existing content where it fits.
  void resize(int newWidth, int newHeight) {
    Tracer.record(_traceResizeId, Phase.begin, TraceCategory.layout);
    try {
      newWidth = max(0, newWidth);
      newHeight = max(0, newHeight);
      final newChars = List.filled(newWidth * newHeight, ' ');
      final newAttributes = Uint32List(newWidth * newHeight * 3);

      for (var i = 2; i < newAttributes.length; i += 3) {
        newAttributes[i] = Modifier.transparent;
      }

      final overlapWidth = min(width, newWidth);
      final overlapHeight = min(height, newHeight);

      if (overlapWidth > 0 && overlapHeight > 0) {
        for (var y = 0; y < overlapHeight; y++) {
          final targetCharStart = y * newWidth;
          final sourceCharStart = y * width;
          newChars.setRange(
            targetCharStart,
            targetCharStart + overlapWidth,
            characters,
            sourceCharStart,
          );

          final targetAttrStart = y * newWidth * 3;
          final sourceAttrStart = y * width * 3;
          newAttributes.setRange(
            targetAttrStart,
            targetAttrStart + overlapWidth * 3,
            attributes,
            sourceAttrStart,
          );
        }
      }

      width = newWidth;
      height = newHeight;
      characters = newChars;
      attributes = newAttributes;
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
    var currentX = x;
    var currentY = y;

    if (text.runes.length == text.length) {
      final len = text.length;
      final fg = style.foreground?.argb ?? 0;
      final bg = style.background?.argb ?? 0;
      final modifiers = style.modifiers;
      final hasFg = style.foreground != null;
      final hasBg = style.background != null;

      for (var i = 0; i < len; i++) {
        final codeUnit = text.codeUnitAt(i);
        if (codeUnit == 10) {
          // '\n'
          currentX = startX;
          currentY++;
          continue;
        }
        if (isCellValid(currentX, currentY)) {
          final idx = currentY * width + currentX;
          final char = String.fromCharCode(codeUnit);

          // Clear potential wide char we are about to overwrite
          if (characters[idx] == '') {
            if (currentX - 1 >= 0) {
              final prevIdx = idx - 1;
              if (isWideGrapheme(characters[prevIdx])) {
                characters[prevIdx] = ' ';
              }
            }
          } else if (isWideGrapheme(characters[idx])) {
            if (currentX + 1 < width) {
              final nextIdx = idx + 1;
              if (characters[nextIdx] == '') {
                characters[nextIdx] = ' ';
              }
            }
          }

          final isWide = isWideCodePoint(codeUnit);
          if (isWide && currentX == width - 1) {
            characters[idx] = ' ';
            final attrIdx = idx * 3;
            attributes[attrIdx + 0] = hasFg ? fg : 0;
            if (hasBg) attributes[attrIdx + 1] = bg;
            attributes[attrIdx + 2] = modifiers;
            currentX += 1;
          } else {
            characters[idx] = char;
            final attrIdx = idx * 3;
            attributes[attrIdx + 0] = hasFg ? fg : 0;
            if (hasBg) attributes[attrIdx + 1] = bg;
            attributes[attrIdx + 2] = modifiers;
            if (isWide) {
              if (currentX + 1 < width) {
                final nextIdx = idx + 1;
                // Clear potential wide char we are overwriting in the next cell
                if (isWideGrapheme(characters[nextIdx]) &&
                    currentX + 2 < width) {
                  final nextNextIdx = idx + 2;
                  if (characters[nextNextIdx] == '') {
                    characters[nextNextIdx] = ' ';
                  }
                }
                characters[nextIdx] = '';
                final nextAttrIdx = nextIdx * 3;
                attributes[nextAttrIdx + 0] = hasFg ? fg : 0;
                if (hasBg) attributes[nextAttrIdx + 1] = bg;
                attributes[nextAttrIdx + 2] = modifiers;
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
      return;
    }

    final chars = text.characters;
    final fg = style.foreground?.argb ?? 0;
    final bg = style.background?.argb ?? 0;
    final modifiers = style.modifiers;
    final hasFg = style.foreground != null;
    final hasBg = style.background != null;

    for (final char in chars) {
      if (char == '\n') {
        currentX = startX;
        currentY++;
        continue;
      }
      if (isCellValid(currentX, currentY)) {
        final idx = currentY * width + currentX;
        // Clear potential wide char we are about to overwrite
        if (characters[idx] == '') {
          if (currentX - 1 >= 0) {
            final prevIdx = idx - 1;
            if (isWideGrapheme(characters[prevIdx])) {
              characters[prevIdx] = ' ';
            }
          }
        } else if (isWideGrapheme(characters[idx])) {
          if (currentX + 1 < width) {
            final nextIdx = idx + 1;
            if (characters[nextIdx] == '') {
              characters[nextIdx] = ' ';
            }
          }
        }

        final isWide = isWideGrapheme(char);
        if (isWide && currentX == width - 1) {
          // Can't fit wide character in the last column, write a space instead
          characters[idx] = ' ';
          final attrIdx = idx * 3;
          attributes[attrIdx + 0] = hasFg ? fg : 0;
          if (hasBg) attributes[attrIdx + 1] = bg;
          attributes[attrIdx + 2] = modifiers;
          currentX += 1;
        } else {
          characters[idx] = char;
          final attrIdx = idx * 3;
          attributes[attrIdx + 0] = hasFg ? fg : 0;
          if (hasBg) attributes[attrIdx + 1] = bg;
          attributes[attrIdx + 2] = modifiers;
          if (isWide) {
            if (currentX + 1 < width) {
              final nextIdx = idx + 1;
              // Clear potential wide char we are overwriting in the next cell
              if (isWideGrapheme(characters[nextIdx]) && currentX + 2 < width) {
                final nextNextIdx = idx + 2;
                if (characters[nextNextIdx] == '') {
                  characters[nextNextIdx] = ' ';
                }
              }
              characters[nextIdx] = '';
              final nextAttrIdx = nextIdx * 3;
              attributes[nextAttrIdx + 0] = hasFg ? fg : 0;
              if (hasBg) attributes[nextAttrIdx + 1] = bg;
              attributes[nextAttrIdx + 2] = modifiers;
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
      final indexedLayers = List.generate(layers.length, (i) => (i, layers[i]));
      indexedLayers.sort((a, b) {
        final cmp = b.$2.zIndex.compareTo(a.$2.zIndex);
        if (cmp != 0) return cmp;
        return b.$1.compareTo(a.$1);
      });
      final sortedLayers = List.generate(
        indexedLayers.length,
        (i) => indexedLayers[i].$2,
      );

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
              (target.attributes[i * 3 + 2] & Modifier.transparent) != 0;
          if (!isTransparent) {
            final word = i >> 5;
            final bit = i & 31;
            // Foreground is considered written if the cell is not transparent
            fgWritten[word] |= (1 << bit);
            remainingFg--;

            if (target.attributes[i * 3 + 1] != 0) {
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

              final sourceAttrIdx = targetIdx * 3;
              final sourceIsTransparent =
                  (tempBuffer.attributes[sourceAttrIdx + 2] &
                      Modifier.transparent) !=
                  0;
              if (sourceIsTransparent) continue;

              final sourceBg = tempBuffer.attributes[sourceAttrIdx + 1];
              final targetAttrIdx = targetIdx * 3;

              if (!fgOccluded && !bgOccluded && sourceBg != 0) {
                target.characters[targetIdx] = tempBuffer.characters[targetIdx];
                target.attributes[targetAttrIdx + 0] =
                    tempBuffer.attributes[sourceAttrIdx + 0];
                target.attributes[targetAttrIdx + 1] = sourceBg;
                target.attributes[targetAttrIdx + 2] =
                    tempBuffer.attributes[sourceAttrIdx + 2];
                fgWritten[word] |= (1 << bit);
                bgWritten[word] |= (1 << bit);
                remainingFg--;
                remainingBg--;
              } else {
                if (!fgOccluded) {
                  target.characters[targetIdx] =
                      tempBuffer.characters[targetIdx];
                  target.attributes[targetAttrIdx + 0] =
                      tempBuffer.attributes[sourceAttrIdx + 0];
                  target.attributes[targetAttrIdx + 2] =
                      tempBuffer.attributes[sourceAttrIdx + 2];
                  fgWritten[word] |= (1 << bit);
                  remainingFg--;
                }

                if (!bgOccluded && sourceBg != 0) {
                  target.attributes[targetAttrIdx + 1] = sourceBg;
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

          // No effects on this layer. Fast path: Composite directly to target with pre-calculated bounds.
          final startX = max(0, ox);
          final endX = min(target.width, ox + buf.width);
          final startY = max(0, oy);
          final endY = min(target.height, oy + buf.height);

          if (startX < endX && startY < endY) {
            for (var ty = startY; ty < endY; ty++) {
              final ly = ty - oy;
              final sourceRowOffset = ly * buf.width;
              var targetIdx = ty * target.width + startX;
              for (var tx = startX; tx < endX; tx++, targetIdx++) {
                final word = targetIdx >> 5;
                final bit = targetIdx & 31;

                final fgOccluded = (fgWritten[word] & (1 << bit)) != 0;
                final bgOccluded = (bgWritten[word] & (1 << bit)) != 0;

                if (fgOccluded && bgOccluded) continue; // Fully occluded

                final lx = tx - ox;
                final sourceIdx = sourceRowOffset + lx;
                final sourceAttrIdx = sourceIdx * 3;
                final sourceIsTransparent =
                    (buf.attributes[sourceAttrIdx + 2] &
                        Modifier.transparent) !=
                    0;
                if (sourceIsTransparent) continue;

                final sourceBg = buf.attributes[sourceAttrIdx + 1];
                final targetAttrIdx = targetIdx * 3;

                if (!fgOccluded && !bgOccluded && sourceBg != 0) {
                  // Fast path: write both!
                  target.characters[targetIdx] = buf.characters[sourceIdx];
                  target.attributes[targetAttrIdx + 0] =
                      buf.attributes[sourceAttrIdx + 0];
                  target.attributes[targetAttrIdx + 1] = sourceBg;
                  target.attributes[targetAttrIdx + 2] =
                      buf.attributes[sourceAttrIdx + 2];
                  fgWritten[word] |= (1 << bit);
                  bgWritten[word] |= (1 << bit);
                  remainingFg--;
                  remainingBg--;
                } else {
                  // Slow path: independent foreground/background blending
                  if (!fgOccluded) {
                    target.characters[targetIdx] = buf.characters[sourceIdx];
                    target.attributes[targetAttrIdx + 0] =
                        buf.attributes[sourceAttrIdx + 0];
                    target.attributes[targetAttrIdx + 2] =
                        buf.attributes[sourceAttrIdx + 2];
                    fgWritten[word] |= (1 << bit);
                    remainingFg--;
                  }

                  if (!bgOccluded && sourceBg != 0) {
                    target.attributes[targetAttrIdx + 1] = sourceBg;
                    bgWritten[word] |= (1 << bit);
                    remainingBg--;
                  }
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

      final startX = max(0, ox);
      final endX = min(target.width, ox + buf.width);
      final startY = max(0, oy);
      final endY = min(target.height, oy + buf.height);

      if (startX < endX && startY < endY) {
        for (var ty = startY; ty < endY; ty++) {
          final ly = ty - oy;
          final sourceRowOffset = ly * buf.width;
          var targetIdx = ty * target.width + startX;
          for (var tx = startX; tx < endX; tx++, targetIdx++) {
            final lx = tx - ox;
            final sourceIdx = sourceRowOffset + lx;
            final sourceAttrIdx = sourceIdx * 3;
            final sourceIsTransparent =
                (buf.attributes[sourceAttrIdx + 2] & Modifier.transparent) != 0;
            if (sourceIsTransparent) continue;

            final bg = buf.attributes[sourceAttrIdx + 1];
            final targetAttrIdx = targetIdx * 3;
            target.characters[targetIdx] = buf.characters[sourceIdx];
            target.attributes[targetAttrIdx + 0] =
                buf.attributes[sourceAttrIdx + 0];
            if (bg != 0) {
              target.attributes[targetAttrIdx + 1] = bg;
            }
            target.attributes[targetAttrIdx + 2] =
                buf.attributes[sourceAttrIdx + 2];
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
///
/// [Optimization Note - ASCII Fast-Path]:
/// Since the overwhelming majority of characters in typical TUI applications are standard ASCII
/// (alphanumeric characters, punctuation, spaces), we check the first codeUnit. If it is < 128,
/// we bypass the expensive grapheme cluster iterator/rune inspection and Unicode range checks entirely.
bool isWideGrapheme(String grapheme) {
  if (grapheme.isEmpty) return false;
  return isWideCodePoint(grapheme.runes.first);
}

/// Checks if a single code point represents a wide character.
bool isWideCodePoint(int codePoint) {
  if (codePoint < 128) return false;

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
