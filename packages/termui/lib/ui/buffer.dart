import 'package:termui/termui.dart';
import 'dart:math';
import 'dart:typed_data';
import 'package:characters/characters.dart';

/// Blends two ARGB colors.
int blendColor(int top, int bottom) {
  if (bottom == 0) return top;
  if (top == 0) return bottom;

  final aTop = (top >> 24) & 0xFF;
  if (aTop == 255) return top;

  final rTop = (top >> 16) & 0xFF;
  final gTop = (top >> 8) & 0xFF;
  final bTop = top & 0xFF;

  final aBottom = (bottom >> 24) & 0xFF;
  final rBottom = (bottom >> 16) & 0xFF;
  final gBottom = (bottom >> 8) & 0xFF;
  final bBottom = bottom & 0xFF;

  final invAlpha = 255 - aTop;
  final effectiveBottomA = (aBottom * invAlpha) ~/ 255;
  final outA = aTop + effectiveBottomA;
  if (outA == 0) return 0;

  final outR = (rTop * aTop + rBottom * effectiveBottomA) ~/ outA;
  final outG = (gTop * aTop + gBottom * effectiveBottomA) ~/ outA;
  final outB = (bTop * aTop + bBottom * effectiveBottomA) ~/ outA;

  return (outA << 24) | (outR << 16) | (outG << 8) | outB;
}

int _premultiplyBlack(int color) {
  final a = (color >> 24) & 0xFF;
  if (a == 255) return color;
  if (a == 0) return 0xFF000000;
  final r = ((color >> 16) & 0xFF) * a ~/ 255;
  final g = ((color >> 8) & 0xFF) * a ~/ 255;
  final b = (color & 0xFF) * a ~/ 255;
  return 0xFF000000 | (r << 16) | (g << 8) | b;
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

  /// Single unified data array for fg, bg, and modifiers.
  /// layout: [fg, bg, mod, fg, bg, mod...]
  Uint32List attributes;

  /// Lazily allocated array of per-cell SGR 58 underline colors (`0` = default foreground).
  Uint32List? _underlineColors;

  /// Whether any cell in this buffer has a non-zero custom underline color.
  bool get hasUnderlineColors => _underlineColors != null;

  /// The list of terminal effects registered in this buffer.
  final List<RegisteredEffect> effects = [];

  /// Whether cell attribute writes alpha-blend colors over existing cells when
  /// a per-call `blend` argument is omitted.
  final bool defaultBlend;

  final int _emptyModifiers;

  /// Adds a terminal effect to this buffer.
  void addEffect(RegisteredEffect effect) {
    effects.add(effect);
  }

  /// Creates a new buffer of [width] by [height] initialized with transparent empty cell data.
  Buffer(this.width, this.height, {this.defaultBlend = true})
    : _emptyModifiers = Modifier.transparent,
      characters = List.filled(width * height, ' '),
      attributes = Uint32List(width * height * 3) {
    for (var i = 2; i < attributes.length; i += 3) {
      attributes[i] = Modifier.transparent;
    }
  }

  /// Creates a new buffer of [width] by [height] initialized with solid blank cell data.
  Buffer.blank(this.width, this.height, {this.defaultBlend = true})
    : _emptyModifiers = Modifier.none,
      characters = List.filled(width * height, ' '),
      attributes = Uint32List(width * height * 3);

  /// Stack of active canvas clip rectangles.
  final List<Rect> _clipStack = [];

  late Rect _boundsClip = Rect(0, 0, width, height);

  /// Returns the current active clip rectangle, defaulting to full buffer bounds if stack is empty.
  Rect get activeClip => _clipStack.isEmpty ? _boundsClip : _clipStack.last;

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

  /// Gets the SGR 58 underline color at ([x], [y]), or `0` when using the foreground color.
  int getUnderlineColor(int x, int y) {
    final ul = _underlineColors;
    if (ul == null || !isCellValid(x, y)) return 0;
    return ul[y * width + x];
  }

  /// Sets the SGR 58 underline color at ([x], [y]) (`0` resets to default foreground).
  void setUnderlineColor(int x, int y, int ulColor) {
    if (!isCellValid(x, y)) return;
    _setUnderlineColorAt(y * width + x, ulColor);
  }

  @pragma('vm:prefer-inline')
  void _setUnderlineColorAt(int cellIdx, int ulColor) {
    if (ulColor == 0 && _underlineColors == null) return;
    (_underlineColors ??= Uint32List(width * height))[cellIdx] = ulColor;
  }

  /// Sets character at coordinates.
  ///
  /// **Performance Warning:**
  /// Invoking individual property setters ([setCharacter], [setForeground], etc.)
  /// inside a per-cell hot render loop causes severe thrashing due to redundant
  /// bounds checking and method overhead. Prefer using [setCell] to write all
  /// attributes at once. For massive regional updates, manipulate the raw 1D arrays
  /// ([characters] and [attributes]) directly via `List.setRange()`.
  void setCharacter(int x, int y, String char) {
    if (isCellValid(x, y)) {
      characters[y * width + x] = char;
    }
  }

  /// Sets foreground color at coordinates.
  ///
  /// **Performance Warning:**
  /// Invoking individual property setters ([setCharacter], [setForeground], etc.)
  /// inside a per-cell hot render loop causes severe thrashing due to redundant
  /// bounds checking and method overhead. Prefer using [setCell] to write all
  /// attributes at once. For massive regional updates, manipulate the raw 1D arrays
  /// ([characters] and [attributes]) directly via `List.setRange()`.
  void setForeground(int x, int y, int fg) {
    if (isCellValid(x, y)) {
      attributes[(y * width + x) * 3 + 0] = blendColor(
        fg,
        attributes[(y * width + x) * 3 + 0],
      );
    }
  }

  /// Sets background color at coordinates.
  ///
  /// **Performance Warning:**
  /// Invoking individual property setters ([setCharacter], [setForeground], etc.)
  /// inside a per-cell hot render loop causes severe thrashing due to redundant
  /// bounds checking and method overhead. Prefer using [setCell] to write all
  /// attributes at once. For massive regional updates, manipulate the raw 1D arrays
  /// ([characters] and [attributes]) directly via `List.setRange()`.
  void setBackground(int x, int y, int bg) {
    if (isCellValid(x, y)) {
      attributes[(y * width + x) * 3 + 1] = blendColor(
        bg,
        attributes[(y * width + x) * 3 + 1],
      );
    }
  }

  /// Sets modifiers at coordinates.
  ///
  /// **Performance Warning:**
  /// Invoking individual property setters ([setCharacter], [setForeground], etc.)
  /// inside a per-cell hot render loop causes severe thrashing due to redundant
  /// bounds checking and method overhead. Prefer using [setCell] to write all
  /// attributes at once. For massive regional updates, manipulate the raw 1D arrays
  /// ([characters] and [attributes]) directly via `List.setRange()`.
  void setModifiers(int x, int y, int mod) {
    if (isCellValid(x, y)) {
      attributes[(y * width + x) * 3 + 2] = mod;
    }
  }

  @pragma('vm:prefer-inline')
  void _resetCell(int cellIdx) {
    characters[cellIdx] = ' ';
    final attrIdx = cellIdx * 3;
    attributes[attrIdx + 0] = 0;
    attributes[attrIdx + 1] = 0;
    attributes[attrIdx + 2] = _emptyModifiers;
    _underlineColors?[cellIdx] = 0;
  }

  @pragma('vm:prefer-inline')
  void _writeCellAttributes(
    int attrIdx, {
    int? fg,
    int? bg,
    int? modifiers,
    int? underlineColor,
    required bool blend,
  }) {
    if (fg != null) {
      attributes[attrIdx + 0] = blend
          ? blendColor(fg, attributes[attrIdx + 0])
          : fg;
    }
    if (bg != null) {
      attributes[attrIdx + 1] = blend
          ? blendColor(bg, attributes[attrIdx + 1])
          : bg;
    }
    if (modifiers != null) {
      attributes[attrIdx + 2] = modifiers;
    }
    if (underlineColor != null &&
        (underlineColor != 0 || _underlineColors != null)) {
      (_underlineColors ??= Uint32List(width * height))[attrIdx ~/ 3] =
          underlineColor;
    }
  }

  @pragma('vm:prefer-inline')
  void _clearSplitWideEdges(int rowOffset, int startX, int endX, String char) {
    if (char == '') return;
    final rowStart = rowOffset + startX;
    if (startX > 0 &&
        characters[rowStart] == '' &&
        isWideGrapheme(characters[rowStart - 1])) {
      _resetCell(rowStart - 1);
    }
    final rowEnd = rowOffset + endX;
    if (endX < width && characters[rowEnd] == '') {
      _resetCell(rowEnd);
    }
  }

  /// Sets character, colors, and modifiers at coordinates.
  ///
  /// When [blend] is `true` (or omitted when [defaultBlend] is `true`), [fg]
  /// and [bg] are alpha-blended over existing cell colors. When `false`, they
  /// replace existing colors directly so `0` resets to the terminal default.
  void setCell(
    int x,
    int y,
    String char,
    int fg,
    int bg,
    int mod, {
    bool? blend,
    int underlineColor = 0,
  }) {
    if (isCellValid(x, y)) {
      final useBlend = blend ?? defaultBlend;
      final cellIdx = y * width + x;
      final idx = cellIdx * 3;
      characters[cellIdx] = char;
      attributes[idx + 0] = useBlend ? blendColor(fg, attributes[idx + 0]) : fg;
      attributes[idx + 1] = useBlend ? blendColor(bg, attributes[idx + 1]) : bg;
      attributes[idx + 2] = mod;
      if (underlineColor != 0 || _underlineColors != null) {
        (_underlineColors ??= Uint32List(width * height))[cellIdx] =
            underlineColor;
      }
    }
  }

  @pragma('vm:prefer-inline')
  void _resetOverwrittenWideAt(int x, int charIdx) {
    if (characters[charIdx] == '') {
      if (x > 0 && isWideGrapheme(characters[charIdx - 1])) {
        _resetCell(charIdx - 1);
      }
    } else if (isWideGrapheme(characters[charIdx])) {
      if (x + 1 < width && characters[charIdx + 1] == '') {
        _resetCell(charIdx + 1);
      }
    }
  }

  @pragma('vm:prefer-inline')
  void _placeWideContinuationAt(int x, int charIdx) {
    final nextIdx = charIdx + 1;
    if (isWideGrapheme(characters[nextIdx]) &&
        x + 2 < width &&
        characters[charIdx + 2] == '') {
      _resetCell(charIdx + 2);
    }
    characters[nextIdx] = '';
  }

  /// Sets the cell attributes at ([x], [y]). Does nothing if coordinates are out of bounds.
  void setAttributes(
    int x,
    int y, {
    String? char,
    int? fg,
    int? bg,
    int? modifiers,
    int? underlineColor,
    bool? blend,
  }) {
    if (!isCellValid(x, y)) return;
    final useBlend = blend ?? defaultBlend;
    final charIdx = y * width + x;
    final isWide = char != null && char != '' && isWideGrapheme(char);
    if (char != null) {
      if (char != '') _resetOverwrittenWideAt(x, charIdx);
      characters[charIdx] = char;
      if (isWide && x + 1 < width) _placeWideContinuationAt(x, charIdx);
    }
    _writeCellAttributes(
      charIdx * 3,
      fg: fg,
      bg: bg,
      modifiers: modifiers,
      underlineColor: underlineColor,
      blend: useBlend,
    );
    if (isWide && x + 1 < width) {
      _writeCellAttributes(
        (charIdx + 1) * 3,
        fg: fg,
        bg: bg,
        modifiers: modifiers,
        underlineColor: underlineColor,
        blend: useBlend,
      );
    }
  }

  /// Resets all cells in the buffer to transparent empty cells.
  void clear() {
    Tracer.record(_traceClearId, Phase.begin, TraceCategory.paint);
    try {
      characters.fillRange(0, characters.length, ' ');
      attributes.fillRange(0, attributes.length, 0);
      _underlineColors?.fillRange(0, _underlineColors!.length, 0);
      for (var i = 2; i < attributes.length; i += 3) {
        attributes[i] = Modifier.transparent;
      }
      effects.clear();
    } finally {
      Tracer.record(_traceClearId, Phase.end, TraceCategory.paint);
    }
  }

  /// Fills the entire buffer with the specified attributes.
  void fillAttributes({
    String? char,
    int? fg,
    int? bg,
    int? modifiers,
    int? underlineColor,
    bool? blend,
  }) {
    if (char != null) characters.fillRange(0, characters.length, char);
    if (fg == null &&
        bg == null &&
        modifiers == null &&
        underlineColor == null) {
      return;
    }
    final useBlend = blend ?? defaultBlend;
    for (var i = 0; i < characters.length; i++) {
      _writeCellAttributes(
        i * 3,
        fg: fg,
        bg: bg,
        modifiers: modifiers,
        underlineColor: underlineColor,
        blend: useBlend,
      );
    }
  }

  /// Fills a rectangular region with the given character and attributes.
  void fillRect(
    Rect rect, {
    String? char,
    int? fg,
    int? bg,
    int? modifiers,
    int? underlineColor,
    bool? blend,
  }) {
    final clipped = _clipStack.isEmpty ? rect : activeClip.intersect(rect);
    if (clipped.width <= 0 || clipped.height <= 0) return;

    final startX = max(0, clipped.left);
    final startY = max(0, clipped.top);
    final endX = min(width, clipped.right);
    final endY = min(height, clipped.bottom);
    if (startX >= endX || startY >= endY) return;

    if (char != null) {
      for (var y = startY; y < endY; y++) {
        final rowOffset = y * width;
        _clearSplitWideEdges(rowOffset, startX, endX, char);
        characters.fillRange(rowOffset + startX, rowOffset + endX, char);
      }
    }

    if (fg == null &&
        bg == null &&
        modifiers == null &&
        underlineColor == null) {
      return;
    }
    final useBlend = blend ?? defaultBlend;
    for (var y = startY; y < endY; y++) {
      final rowOffset = y * width;
      for (var x = startX; x < endX; x++) {
        _writeCellAttributes(
          (rowOffset + x) * 3,
          fg: fg,
          bg: bg,
          modifiers: modifiers,
          underlineColor: underlineColor,
          blend: useBlend,
        );
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
      final oldUl = _underlineColors;
      final newUl = oldUl != null ? Uint32List(newWidth * newHeight) : null;

      if (_emptyModifiers != 0) {
        for (var i = 2; i < newAttributes.length; i += 3) {
          newAttributes[i] = _emptyModifiers;
        }
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
          if (newUl != null && oldUl != null) {
            newUl.setRange(
              targetCharStart,
              targetCharStart + overlapWidth,
              oldUl,
              sourceCharStart,
            );
          }

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
      _underlineColors = newUl;
      _boundsClip = Rect(0, 0, width, height);
    } finally {
      Tracer.record(_traceResizeId, Phase.end, TraceCategory.layout);
    }
  }

  @pragma('vm:prefer-inline')
  static bool _isPureAscii(String text) {
    final len = text.length;
    for (var i = 0; i < len; i++) {
      if (text.codeUnitAt(i) >= 128) return false;
    }
    return true;
  }

  @pragma('vm:prefer-inline')
  void _clearOverwrittenWideChar(int currentX, int idx) {
    if (characters[idx] == '') {
      if (currentX > 0 && isWideGrapheme(characters[idx - 1])) {
        characters[idx - 1] = ' ';
      }
    } else if (isWideGrapheme(characters[idx])) {
      if (currentX + 1 < width && characters[idx + 1] == '') {
        characters[idx + 1] = ' ';
      }
    }
  }

  @pragma('vm:prefer-inline')
  void _writeStyledCellRaw(
    int idx,
    String char,
    int fg,
    int bg,
    int modifiers,
    int ulColor,
    bool hasFg,
    bool hasBg,
  ) {
    characters[idx] = char;
    final attrIdx = idx * 3;
    attributes[attrIdx + 0] = hasFg ? fg : 0;
    if (hasBg) {
      attributes[attrIdx + 1] = blendColor(bg, attributes[attrIdx + 1]);
    }
    attributes[attrIdx + 2] = modifiers;
    if (ulColor != 0 || _underlineColors != null) {
      (_underlineColors ??= Uint32List(width * height))[idx] = ulColor;
    }
  }

  void _writeAsciiString(int x, int y, String text, Style style) {
    var currentX = x;
    var currentY = y;
    final fg = style.foreground?.argb ?? 0;
    final bg = style.background?.argb ?? 0;
    final ulColor = style.underlineColor?.argb ?? 0;
    final modifiers = style.modifiers;
    final hasFg = style.foreground != null;
    final hasBg = style.background != null;
    final len = text.length;

    for (var i = 0; i < len; i++) {
      final codeUnit = text.codeUnitAt(i);
      if (codeUnit == 10) {
        currentX = x;
        currentY++;
        continue;
      }
      if (isCellValid(currentX, currentY)) {
        final idx = currentY * width + currentX;
        _clearOverwrittenWideChar(currentX, idx);
        _writeStyledCellRaw(
          idx,
          String.fromCharCode(codeUnit),
          fg,
          bg,
          modifiers,
          ulColor,
          hasFg,
          hasBg,
        );
      }
      currentX++;
    }
  }

  void _writeGraphemeAt(
    int currentX,
    int currentY,
    String char,
    bool isWide,
    int fg,
    int bg,
    int modifiers,
    int ulColor,
    bool hasFg,
    bool hasBg,
  ) {
    if (!isCellValid(currentX, currentY)) return;
    final idx = currentY * width + currentX;
    _clearOverwrittenWideChar(currentX, idx);
    if (isWide &&
        (currentX == width - 1 || !isCellValid(currentX + 1, currentY))) {
      // Can't fit wide character in the last column or clip edge, write a space instead
      _writeStyledCellRaw(idx, ' ', fg, bg, modifiers, ulColor, hasFg, hasBg);
      return;
    }
    _writeStyledCellRaw(idx, char, fg, bg, modifiers, ulColor, hasFg, hasBg);
    if (!isWide || currentX + 1 >= width) return;
    final nextIdx = idx + 1;
    if (isWideGrapheme(characters[nextIdx]) &&
        currentX + 2 < width &&
        characters[idx + 2] == '') {
      characters[idx + 2] = ' ';
    }
    _writeStyledCellRaw(nextIdx, '', fg, bg, modifiers, ulColor, hasFg, hasBg);
  }

  /// Writes styled [text] to the buffer starting at ([x], [y]).
  ///
  /// Newlines (`\n`) will wrap to [y] + 1 at the starting column [x].
  /// Any characters that fall out of bounds are clipped.
  void writeString(int x, int y, String text, Style style) {
    // Fast-path for pure ASCII text: no wide characters, no variation selectors,
    // and no multi-code-unit grapheme clusters.
    if (_isPureAscii(text)) {
      _writeAsciiString(x, y, text, style);
      return;
    }

    var currentX = x;
    var currentY = y;
    final fg = style.foreground?.argb ?? 0;
    final bg = style.background?.argb ?? 0;
    final ulColor = style.underlineColor?.argb ?? 0;
    final modifiers = style.modifiers;
    final hasFg = style.foreground != null;
    final hasBg = style.background != null;

    for (final char in text.characters) {
      if (char == '\n') {
        currentX = x;
        currentY++;
        continue;
      }
      final charWidth = graphemeWidth(char);
      if (charWidth == 0) continue;
      _writeGraphemeAt(
        currentX,
        currentY,
        char,
        charWidth == 2,
        fg,
        bg,
        modifiers,
        ulColor,
        hasFg,
        hasBg,
      );
      currentX += charWidth;
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

      // Premultiply final alpha against black for any remaining transparent pixels.
      final attrs = target.attributes;
      final len = attrs.length;
      for (var i = 0; i < len; i += 3) {
        final fg = attrs[i];
        if (fg != 0 && ((fg >> 24) & 0xFF) != 255) {
          attrs[i] = _premultiplyBlack(fg);
        }
        final bg = attrs[i + 1];
        if (bg != 0 && ((bg >> 24) & 0xFF) != 255) {
          attrs[i + 1] = _premultiplyBlack(bg);
        }
      }
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
      final masks = _CompositeMasks(target.width * target.height);
      if (initializeMasksFromTarget) {
        _initMasksFromTarget(target, masks);
      }

      for (var i = startIndex; i < sortedLayers.length; i++) {
        if (masks.remainingBg <= 0) break;
        final layer = sortedLayers[i];
        if (layer.buffer.effects.isNotEmpty) {
          _compositeEffectLayer(target, sortedLayers, i, masks);
          break;
        }
        _blendRegionIntoTarget(target, layer.buffer, layer.x, layer.y, masks);
      }
    } finally {
      Tracer.record(
        _traceCompositeRecursiveId,
        Phase.end,
        TraceCategory.compositor,
      );
    }
  }

  static void _initMasksFromTarget(Buffer target, _CompositeMasks masks) {
    final totalCells = target.width * target.height;
    for (var i = 0; i < totalCells; i++) {
      final attrIdx = i * 3;
      if ((target.attributes[attrIdx + 2] & Modifier.transparent) != 0) {
        continue;
      }
      final maskBit = 1 << (i & 31);
      final word = i >> 5;
      final char = target.characters[i];
      final fgAlpha = (target.attributes[attrIdx] >> 24) & 0xFF;
      final bgAlpha = (target.attributes[attrIdx + 1] >> 24) & 0xFF;

      if ((char != ' ' && char != '') || bgAlpha == 255) {
        masks.charWritten[word] |= maskBit;
      }
      if (fgAlpha == 255 || bgAlpha == 255) {
        masks.fgWritten[word] |= maskBit;
      }
      if (bgAlpha == 255) {
        masks.bgWritten[word] |= maskBit;
        masks.remainingBg--;
      }
    }
  }

  void _compositeEffectLayer(
    Buffer target,
    List<LayeredBuffer> sortedLayers,
    int index,
    _CompositeMasks masks,
  ) {
    final layer = sortedLayers[index];
    final tempBuffer = _rentBuffer(target.width, target.height);
    try {
      _compositeOpaqueContent(tempBuffer, layer);
      if (index + 1 < sortedLayers.length) {
        _compositeRecursive(
          tempBuffer,
          sortedLayers,
          index + 1,
          initializeMasksFromTarget: true,
        );
      }
      _applyLayerEffects(tempBuffer, layer);
      _blendRegionIntoTarget(
        target,
        tempBuffer,
        0,
        0,
        masks,
        skipZeroBgWhenCharUnoccluded: true,
      );
    } finally {
      _poolIndex--;
    }
  }

  static void _applyLayerEffects(Buffer tempBuffer, LayeredBuffer layer) {
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
  }

  static void _blendRegionIntoTarget(
    Buffer target,
    Buffer source,
    int ox,
    int oy,
    _CompositeMasks masks, {
    bool skipZeroBgWhenCharUnoccluded = false,
  }) {
    final startX = max(0, ox);
    final endX = min(target.width, ox + source.width);
    final startY = max(0, oy);
    final endY = min(target.height, oy + source.height);
    if (startX >= endX || startY >= endY) return;

    for (var ty = startY; ty < endY; ty++) {
      final sourceRowOffset = (ty - oy) * source.width;
      var targetIdx = ty * target.width + startX;
      for (var tx = startX; tx < endX; tx++, targetIdx++) {
        _blendCellIntoTarget(
          target,
          targetIdx,
          source,
          sourceRowOffset + (tx - ox),
          masks,
          skipZeroBgWhenCharUnoccluded: skipZeroBgWhenCharUnoccluded,
        );
      }
    }
  }

  @pragma('vm:prefer-inline')
  static void _blendCellIntoTarget(
    Buffer target,
    int targetIdx,
    Buffer source,
    int sourceIdx,
    _CompositeMasks masks, {
    required bool skipZeroBgWhenCharUnoccluded,
  }) {
    final word = targetIdx >> 5;
    final maskBit = 1 << (targetIdx & 31);
    final charOccluded = (masks.charWritten[word] & maskBit) != 0;
    var fgOccluded = (masks.fgWritten[word] & maskBit) != 0;
    final bgOccluded = (masks.bgWritten[word] & maskBit) != 0;
    if (charOccluded && fgOccluded && bgOccluded) return;

    final sourceAttrIdx = sourceIdx * 3;
    final sourceMods = source.attributes[sourceAttrIdx + 2];
    if ((sourceMods & Modifier.transparent) != 0) return;

    final sourceFg = source.attributes[sourceAttrIdx];
    final sourceBg = source.attributes[sourceAttrIdx + 1];
    final targetAttrIdx = targetIdx * 3;

    if (!charOccluded) {
      fgOccluded = _applyCompositeChar(
        target,
        targetIdx,
        targetAttrIdx,
        source.characters[sourceIdx],
        sourceFg,
        sourceBg,
        sourceMods,
        source._underlineColors?[sourceIdx] ?? 0,
        masks,
        word,
        maskBit,
        fgOccluded,
      );
    }
    if (!fgOccluded) {
      _applyCompositeFg(
        target,
        targetAttrIdx,
        sourceFg,
        sourceMods,
        masks,
        word,
        maskBit,
      );
    }
    if (!bgOccluded) {
      _applyCompositeBg(
        target,
        targetAttrIdx,
        sourceBg,
        masks,
        word,
        maskBit,
        skipZeroBg: skipZeroBgWhenCharUnoccluded && !charOccluded,
      );
    }
  }

  @pragma('vm:prefer-inline')
  static bool _applyCompositeChar(
    Buffer target,
    int targetIdx,
    int targetAttrIdx,
    String sourceChar,
    int sourceFg,
    int sourceBg,
    int sourceMods,
    int sourceUlColor,
    _CompositeMasks masks,
    int word,
    int maskBit,
    bool fgOccluded,
  ) {
    if (sourceChar != ' ') {
      target.characters[targetIdx] = sourceChar;
      target.attributes[targetAttrIdx + 2] = sourceMods;
      target._setUnderlineColorAt(targetIdx, sourceUlColor);
      masks.charWritten[word] |= maskBit;
      return fgOccluded;
    }
    if (((sourceBg >> 24) & 0xFF) == 255) {
      target.characters[targetIdx] = ' ';
      target.attributes[targetAttrIdx + 2] = sourceMods;
      target._setUnderlineColorAt(targetIdx, sourceUlColor);
      masks.charWritten[word] |= maskBit;
      if (!fgOccluded && sourceFg == 0) {
        masks.fgWritten[word] |= maskBit;
        return true;
      }
    }
    return fgOccluded;
  }

  @pragma('vm:prefer-inline')
  static void _applyCompositeFg(
    Buffer target,
    int targetAttrIdx,
    int sourceFg,
    int sourceMods,
    _CompositeMasks masks,
    int word,
    int maskBit,
  ) {
    final blendedFg = blendColor(target.attributes[targetAttrIdx], sourceFg);
    target.attributes[targetAttrIdx] = blendedFg;
    target.attributes[targetAttrIdx + 2] |= sourceMods;
    if (((blendedFg >> 24) & 0xFF) == 255 || ((sourceFg >> 24) & 0xFF) == 255) {
      masks.fgWritten[word] |= maskBit;
    }
  }

  @pragma('vm:prefer-inline')
  static void _applyCompositeBg(
    Buffer target,
    int targetAttrIdx,
    int sourceBg,
    _CompositeMasks masks,
    int word,
    int maskBit, {
    required bool skipZeroBg,
  }) {
    if (skipZeroBg && ((sourceBg >> 24) & 0xFF) == 0) return;
    final blendedBg = blendColor(
      target.attributes[targetAttrIdx + 1],
      sourceBg,
    );
    target.attributes[targetAttrIdx + 1] = blendedBg;
    if (((blendedBg >> 24) & 0xFF) == 255) {
      masks.bgWritten[word] |= maskBit;
      masks.remainingBg--;
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
      if (startX >= endX || startY >= endY) return;

      for (var ty = startY; ty < endY; ty++) {
        final sourceRowOffset = (ty - oy) * buf.width;
        var targetIdx = ty * target.width + startX;
        for (var tx = startX; tx < endX; tx++, targetIdx++) {
          _blendOpaqueCell(target, targetIdx, buf, sourceRowOffset + (tx - ox));
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

  @pragma('vm:prefer-inline')
  static void _blendOpaqueCell(
    Buffer target,
    int targetIdx,
    Buffer buf,
    int sourceIdx,
  ) {
    final sourceAttrIdx = sourceIdx * 3;
    final sourceMods = buf.attributes[sourceAttrIdx + 2];
    if ((sourceMods & Modifier.transparent) != 0) return;

    final sourceChar = buf.characters[sourceIdx];
    final sourceFg = buf.attributes[sourceAttrIdx];
    final sourceBg = buf.attributes[sourceAttrIdx + 1];
    final targetAttrIdx = targetIdx * 3;
    final currentChar = target.characters[targetIdx];
    final targetIsEmptyChar = currentChar == ' ' || currentChar == '';

    if (targetIsEmptyChar &&
        (sourceChar != ' ' || ((sourceBg >> 24) & 0xFF) == 255)) {
      target.characters[targetIdx] = sourceChar;
      target.attributes[targetAttrIdx + 2] = sourceMods;
      target._setUnderlineColorAt(
        targetIdx,
        buf._underlineColors?[sourceIdx] ?? 0,
      );
    }

    target.attributes[targetAttrIdx] = blendColor(
      sourceFg,
      target.attributes[targetAttrIdx],
    );
    target.attributes[targetAttrIdx + 2] |= sourceMods;
    target.attributes[targetAttrIdx + 1] = blendColor(
      sourceBg,
      target.attributes[targetAttrIdx + 1],
    );
  }
}

final class _CompositeMasks {
  final Uint32List fgWritten;
  final Uint32List bgWritten;
  final Uint32List charWritten;
  int remainingBg;

  _CompositeMasks(int totalCells)
    : fgWritten = Uint32List((totalCells + 31) >> 5),
      bgWritten = Uint32List((totalCells + 31) >> 5),
      charWritten = Uint32List((totalCells + 31) >> 5),
      remainingBg = totalCells;
}

/// Returns the physical terminal column width of [grapheme] (0, 1, or 2).
int graphemeWidth(String grapheme) {
  if (grapheme.isEmpty) return 0;
  if (isZeroWidthGrapheme(grapheme)) return 0;
  if (isWideGrapheme(grapheme)) return 2;
  return 1;
}

/// Returns true if the grapheme cluster represents a zero-width character
/// (non-spacing marks, format controls, zero-width spaces, or soft hyphens).
bool isZeroWidthGrapheme(String grapheme) {
  final len = grapheme.length;
  if (len == 0) return true;

  if (len == 1) {
    final cu = grapheme.codeUnitAt(0);
    return isZeroWidthCodePoint(cu);
  }

  // If the cluster starts with a zero-width code point and contains no visible base char
  final cu0 = grapheme.codeUnitAt(0);
  if (isZeroWidthCodePoint(cu0)) {
    for (var i = 1; i < len; i++) {
      if (!isZeroWidthCodePoint(grapheme.codeUnitAt(i))) return false;
    }
    return true;
  }

  return false;
}

/// Returns true if the given code point occupies 0 terminal cells.
bool isZeroWidthCodePoint(int codePoint) {
  if (codePoint <= 0x1F) return codePoint >= 0;
  if (codePoint < 0x7F) return false;
  return codePoint < 0x2000
      ? _isZeroWidthBelow2000(codePoint)
      : _isZeroWidthFrom2000(codePoint);
}

bool _isZeroWidthBelow2000(int codePoint) {
  // C1 control characters (0x7F..0x9F) and Soft Hyphen (0x00AD)
  if (codePoint <= 0x9F || codePoint == 0x00AD) return true;
  // Combining Diacritical Marks, Cyrillic, Hebrew, and isolated Hangul Jamo
  if (codePoint >= 0x0300 && codePoint <= 0x036F) return true;
  if (codePoint >= 0x0483 && codePoint <= 0x0489) return true;
  if (codePoint >= 0x0591 && codePoint <= 0x05BD) return true;
  return codePoint >= 0x1160 && codePoint <= 0x11FF;
}

bool _isZeroWidthFrom2000(int codePoint) {
  // Format controls, BiDi controls, word joiners, variation selectors, BOM, tags
  if (codePoint >= 0x200B && codePoint <= 0x200F) return true;
  if (codePoint >= 0x202A && codePoint <= 0x202E) return true;
  if (codePoint >= 0x2060 && codePoint <= 0x206F) return true;
  if (codePoint >= 0xFE00 && codePoint <= 0xFE0F) return true;
  if (codePoint == 0xFEFF) return true;
  if (codePoint >= 0xFFF9 && codePoint <= 0xFFFB) return true;
  return codePoint >= 0xE0000 && codePoint <= 0xE007F;
}

/// Returns true if the given grapheme cluster is a double-width (wide) character.
///
/// [Optimization Note - Zero-Allocation Fast-Path]:
/// 1. For single BMP characters (length == 1), checks if the code unit is >= 0x1100
///    (the lowest wide character in Unicode is Hangul Jamo U+1100). If < 0x1100,
///    exits in a single CPU comparison without any heap allocations.
/// 2. For multi-code-unit graphemes, scans code units directly for Variation Selector-16
///    (0xFE0F), Combining Enclosing Keycap (0x20E3), or Zero-Width Joiner (0x200D),
///    which force 2-column emoji presentation.
/// 3. For SMP characters (surrogate pairs), decodes the first code point via bitwise math.
/// This implementation achieves zero Runes/Iterator allocations in hot render loops.
bool isWideGrapheme(String grapheme) {
  final len = grapheme.length;
  if (len == 0) return false;

  final cu0 = grapheme.codeUnitAt(0);
  // Fast-path: single BMP character
  if (len == 1) {
    return cu0 >= 0x1100 && isWideCodePoint(cu0);
  }

  // Extract first code point (decode surrogate pair if SMP)
  var firstRune = cu0;
  if (cu0 >= 0xD800 && cu0 <= 0xDBFF && len >= 2) {
    final cu1 = grapheme.codeUnitAt(1);
    if (cu1 >= 0xDC00 && cu1 <= 0xDFFF) {
      firstRune = 0x10000 + ((cu0 & 0x3FF) << 10) + (cu1 & 0x3FF);
    }
  }

  // Multi-code-unit cluster:
  // 1. Combining Enclosing Keycap (0x20E3): makes keycap sequences (e.g. 1️⃣, #️⃣) wide (2 cells).
  // 2. Variation Selector-16 (0xFE0F): forces emoji presentation (wide) for symbols/pictographs (firstRune >= 0x2000).
  // 3. Zero-Width Joiner (0x200D): joins emoji sequences (e.g. 👩‍💻, 👨‍👩‍👧‍👦, 🐱‍👤) into a single wide emoji.
  //    Only applies to emoji sequences where firstRune >= 0x2000 (not Latin letters with ZWJ).
  for (var i = 1; i < len; i++) {
    final cu = grapheme.codeUnitAt(i);
    if (cu == 0x20E3) return true;
    if ((cu == 0xFE0F || cu == 0x200D) && firstRune >= 0x2000) return true;
  }

  return isWideCodePoint(firstRune);
}

/// The 126 contiguous Unicode 16.0 ranges for Wide (W), Fullwidth (F),
/// and Emoji_Presentation=Yes code points.
final Uint32List _wideRangeStarts = Uint32List.fromList([
  0x1100,
  0x231A,
  0x2329,
  0x23E9,
  0x23F0,
  0x23F3,
  0x25FD,
  0x2614,
  0x2630,
  0x2648,
  0x267F,
  0x268A,
  0x2693,
  0x26A1,
  0x26AA,
  0x26BD,
  0x26C4,
  0x26CE,
  0x26D4,
  0x26EA,
  0x26F2,
  0x26F5,
  0x26FA,
  0x26FD,
  0x2705,
  0x270A,
  0x2728,
  0x274C,
  0x274E,
  0x2753,
  0x2757,
  0x2795,
  0x27B0,
  0x27BF,
  0x2B1B,
  0x2B50,
  0x2B55,
  0x2E80,
  0x2E9B,
  0x2F00,
  0x2FF0,
  0x3041,
  0x3099,
  0x3105,
  0x3131,
  0x3190,
  0x31EF,
  0x3220,
  0x3250,
  0xA490,
  0xA960,
  0xAC00,
  0xF900,
  0xFE10,
  0xFE30,
  0xFE54,
  0xFE68,
  0xFF01,
  0xFFE0,
  0x16FE0,
  0x16FF0,
  0x17000,
  0x18CFF,
  0x18D80,
  0x18E00,
  0x191A0,
  0x1AFF0,
  0x1AFF5,
  0x1AFFD,
  0x1B000,
  0x1B132,
  0x1B150,
  0x1B155,
  0x1B164,
  0x1B170,
  0x1D300,
  0x1D360,
  0x1F004,
  0x1F0CF,
  0x1F18E,
  0x1F191,
  0x1F1AE,
  0x1F1E6,
  0x1F210,
  0x1F240,
  0x1F250,
  0x1F260,
  0x1F300,
  0x1F32D,
  0x1F337,
  0x1F37E,
  0x1F3A0,
  0x1F3CF,
  0x1F3E0,
  0x1F3F4,
  0x1F3F8,
  0x1F440,
  0x1F442,
  0x1F4FF,
  0x1F54B,
  0x1F550,
  0x1F57A,
  0x1F595,
  0x1F5A4,
  0x1F5FB,
  0x1F680,
  0x1F6CC,
  0x1F6D0,
  0x1F6D5,
  0x1F6DC,
  0x1F6EB,
  0x1F6F4,
  0x1F7DA,
  0x1F7E0,
  0x1F7F0,
  0x1F90C,
  0x1F93C,
  0x1F947,
  0x1FA70,
  0x1FA80,
  0x1FAC8,
  0x1FACC,
  0x1FADF,
  0x1FAEF,
  0x20000,
  0x30000,
]);

final Uint32List _wideRangeEnds = Uint32List.fromList([
  0x115F,
  0x231B,
  0x232A,
  0x23EC,
  0x23F0,
  0x23F3,
  0x25FE,
  0x2615,
  0x2637,
  0x2653,
  0x267F,
  0x268F,
  0x2693,
  0x26A1,
  0x26AB,
  0x26BE,
  0x26C5,
  0x26CE,
  0x26D4,
  0x26EA,
  0x26F3,
  0x26F5,
  0x26FA,
  0x26FD,
  0x2705,
  0x270B,
  0x2728,
  0x274C,
  0x274E,
  0x2755,
  0x2757,
  0x2797,
  0x27B0,
  0x27BF,
  0x2B1C,
  0x2B50,
  0x2B55,
  0x2E99,
  0x2EF3,
  0x2FD5,
  0x303E,
  0x3096,
  0x30FF,
  0x312F,
  0x318E,
  0x31E5,
  0x321E,
  0x3247,
  0xA48C,
  0xA4C6,
  0xA97C,
  0xD7A3,
  0xFAFF,
  0xFE19,
  0xFE52,
  0xFE66,
  0xFE6B,
  0xFF60,
  0xFFE6,
  0x16FE4,
  0x16FF6,
  0x18CDA,
  0x18D20,
  0x18DF2,
  0x19191,
  0x191D2,
  0x1AFF3,
  0x1AFFB,
  0x1AFFE,
  0x1B128,
  0x1B132,
  0x1B152,
  0x1B155,
  0x1B168,
  0x1B2FB,
  0x1D356,
  0x1D376,
  0x1F004,
  0x1F0CF,
  0x1F18E,
  0x1F19A,
  0x1F1AE,
  0x1F202,
  0x1F23B,
  0x1F248,
  0x1F251,
  0x1F265,
  0x1F320,
  0x1F335,
  0x1F37C,
  0x1F393,
  0x1F3CA,
  0x1F3D3,
  0x1F3F0,
  0x1F3F4,
  0x1F43E,
  0x1F440,
  0x1F4FC,
  0x1F53D,
  0x1F54E,
  0x1F567,
  0x1F57A,
  0x1F596,
  0x1F5A4,
  0x1F64F,
  0x1F6C5,
  0x1F6CC,
  0x1F6D2,
  0x1F6D9,
  0x1F6DF,
  0x1F6EC,
  0x1F6FC,
  0x1F7DA,
  0x1F7EB,
  0x1F7F0,
  0x1F93A,
  0x1F945,
  0x1F9FF,
  0x1FA7C,
  0x1FAC6,
  0x1FAC8,
  0x1FADD,
  0x1FAEB,
  0x1FAFA,
  0x2FFFD,
  0x3FFFD,
]);

/// Checks if a single code point represents a wide character.
bool isWideCodePoint(int codePoint) {
  // Lowest wide character in Unicode is Hangul Jamo (0x1100).
  // Everything below 0x1100 (ASCII, Latin Extended, Cyrillic, Greek, Hebrew, Arabic) is 1 cell.
  if (codePoint < 0x1100) return false;

  // Ultra-fast paths for high-frequency CJK and Hangul text (99% of wide characters in real text)
  if (codePoint >= 0x4E00 && codePoint <= 0x9FFF) return true; // CJK Main
  if (codePoint >= 0xAC00 && codePoint <= 0xD7A3) {
    return true; // Hangul Syllables
  }
  if (codePoint >= 0x20000 && codePoint <= 0x2FFFD) {
    return true; // Plane 2 (Ext B..F, I)
  }
  if (codePoint >= 0x30000 && codePoint <= 0x3FFFD) {
    return true; // Plane 3 (Ext G..H)
  }

  // Binary search over remaining Unicode 16.0 wide intervals (max 7 iterations)
  int low = 0;
  int high = _wideRangeStarts.length - 1;
  while (low <= high) {
    final mid = (low + high) >> 1;
    if (codePoint < _wideRangeStarts[mid]) {
      high = mid - 1;
    } else if (codePoint > _wideRangeEnds[mid]) {
      low = mid + 1;
    } else {
      return true;
    }
  }

  return false;
}

typedef _AnsiStyle = ({int fg, int bg, int mods});
typedef _ParsedAnsiCell = ({String char, int fg, int bg, int mods});

const _AnsiStyle _defaultAnsiStyle = (fg: 0, bg: 0, mods: Modifier.none);
const _ParsedAnsiCell _blankParsedCell = (
  char: ' ',
  fg: 0,
  bg: 0,
  mods: Modifier.none,
);

const List<(int bit, int setCode)> _ansiModifierSetCodes = [
  (Modifier.bold, 1),
  (Modifier.dim, 2),
  (Modifier.italic, 3),
  (Modifier.underline, 4),
  (Modifier.blink, 5),
  (Modifier.reverse, 7),
  (Modifier.hidden, 8),
  (Modifier.crossedOut, 9),
];

/// Extensions for serializing [Buffer] to and from ANSI sequence strings.
extension BufferAnsiSerialization on Buffer {
  /// Parses an ANSI sequence string (supporting 24-bit SGR color codes,
  /// modifiers, and `\r` carriage returns) into a [Buffer].
  ///
  /// When [width] or [height] are provided, the returned [Buffer] is sized to
  /// those dimensions and cells beyond the target bounds are clipped.
  static Buffer fromAnsi(String ansiText, {int? width, int? height}) {
    final rows = <List<_ParsedAnsiCell>>[];
    var currentRow = <_ParsedAnsiCell>[];
    var col = 0;
    var hasLineContent = false;
    var style = _defaultAnsiStyle;

    var idx = 0;
    final len = ansiText.length;

    while (idx < len) {
      final cu = ansiText.codeUnitAt(idx);
      if (cu == 0x1B) {
        final escaped = _consumeAnsiEscape(ansiText, idx, style);
        idx = escaped.nextIdx;
        style = escaped.style;
      } else if (_isStandaloneCarriageReturn(ansiText, idx, cu)) {
        col = 0;
        hasLineContent = true;
        idx++;
      } else if (cu == 0x0D || cu == 0x0A) {
        rows.add(currentRow);
        currentRow = <_ParsedAnsiCell>[];
        col = 0;
        hasLineContent = false;
        idx += cu == 0x0D ? 2 : 1;
      } else {
        final step = _readNextGrapheme(ansiText, idx, cu);
        if (step == null) break;
        col = _writeParsedGrapheme(currentRow, col, step.char, style);
        hasLineContent = true;
        idx = step.nextIdx;
      }
    }

    if (currentRow.isNotEmpty || hasLineContent) {
      rows.add(currentRow);
    }

    return _materializeParsedRows(rows, width: width, height: height);
  }

  static bool _isStandaloneCarriageReturn(String text, int idx, int cu) =>
      cu == 0x0D &&
      (idx + 1 >= text.length || text.codeUnitAt(idx + 1) != 0x0A);

  static ({int nextIdx, _AnsiStyle style}) _consumeAnsiEscape(
    String ansiText,
    int escIdx,
    _AnsiStyle style,
  ) {
    final len = ansiText.length;
    var idx = escIdx + 1;
    if (idx >= len || ansiText.codeUnitAt(idx) != 0x5B) {
      return (nextIdx: idx, style: style);
    }
    idx++;
    final start = idx;
    while (idx < len && !_isCsiFinalByte(ansiText.codeUnitAt(idx))) {
      idx++;
    }
    if (idx >= len) {
      return (nextIdx: idx, style: style);
    }
    final command = ansiText.codeUnitAt(idx);
    final nextStyle = command == 0x6D
        ? _applySgrParams(ansiText.substring(start, idx), style)
        : style;
    return (nextIdx: idx + 1, style: nextStyle);
  }

  static bool _isCsiFinalByte(int byte) => byte >= 0x40 && byte <= 0x7E;

  static _AnsiStyle _applySgrParams(String paramsStr, _AnsiStyle initial) {
    if (paramsStr.isEmpty || paramsStr == '0') {
      return _defaultAnsiStyle;
    }
    var style = initial;
    var pIdx = 0;
    while (pIdx < paramsStr.length) {
      final semi = _nextSemicolon(paramsStr, pIdx);
      final code = int.tryParse(paramsStr.substring(pIdx, semi)) ?? 0;
      if (code == 38 || code == 48) {
        final parsedColor = _parseTrueColorSgr(paramsStr, semi + 1);
        pIdx = parsedColor.nextIdx;
        if (parsedColor.argb != null) {
          style = code == 38
              ? (fg: parsedColor.argb!, bg: style.bg, mods: style.mods)
              : (fg: style.fg, bg: parsedColor.argb!, mods: style.mods);
        }
      } else {
        style = _applySingleSgrCode(code, style);
        pIdx = semi + 1;
      }
    }
    return style;
  }

  static int _nextSemicolon(String s, int from) {
    final idx = s.indexOf(';', from);
    return idx == -1 ? s.length : idx;
  }

  static ({int? argb, int nextIdx}) _parseTrueColorSgr(
    String paramsStr,
    int typeStart,
  ) {
    if (typeStart >= paramsStr.length) {
      return (argb: null, nextIdx: paramsStr.length);
    }
    final s2 = _nextSemicolon(paramsStr, typeStart);
    final type = int.tryParse(paramsStr.substring(typeStart, s2)) ?? 0;
    if (type != 2) {
      return (argb: null, nextIdx: s2 + 1);
    }

    var cursor = s2 + 1;
    final channels = <int>[];
    for (var i = 0; i < 3; i++) {
      if (cursor >= paramsStr.length) {
        return (argb: null, nextIdx: paramsStr.length);
      }
      final next = _nextSemicolon(paramsStr, cursor);
      channels.add(int.tryParse(paramsStr.substring(cursor, next)) ?? 0);
      cursor = next + 1;
    }
    final argb =
        (0xFF << 24) |
        ((channels[0] & 0xFF) << 16) |
        ((channels[1] & 0xFF) << 8) |
        (channels[2] & 0xFF);
    return (argb: argb, nextIdx: cursor);
  }

  static _AnsiStyle _applySingleSgrCode(int code, _AnsiStyle s) =>
      switch (code) {
        0 => _defaultAnsiStyle,
        1 => (fg: s.fg, bg: s.bg, mods: s.mods | Modifier.bold),
        2 => (fg: s.fg, bg: s.bg, mods: s.mods | Modifier.dim),
        3 => (fg: s.fg, bg: s.bg, mods: s.mods | Modifier.italic),
        4 => (fg: s.fg, bg: s.bg, mods: s.mods | Modifier.underline),
        5 => (fg: s.fg, bg: s.bg, mods: s.mods | Modifier.blink),
        7 => (fg: s.fg, bg: s.bg, mods: s.mods | Modifier.reverse),
        8 => (fg: s.fg, bg: s.bg, mods: s.mods | Modifier.hidden),
        9 => (fg: s.fg, bg: s.bg, mods: s.mods | Modifier.crossedOut),
        22 => (
          fg: s.fg,
          bg: s.bg,
          mods: s.mods & ~(Modifier.bold | Modifier.dim),
        ),
        23 => (fg: s.fg, bg: s.bg, mods: s.mods & ~Modifier.italic),
        24 => (fg: s.fg, bg: s.bg, mods: s.mods & ~Modifier.underline),
        25 => (fg: s.fg, bg: s.bg, mods: s.mods & ~Modifier.blink),
        27 => (fg: s.fg, bg: s.bg, mods: s.mods & ~Modifier.reverse),
        28 => (fg: s.fg, bg: s.bg, mods: s.mods & ~Modifier.hidden),
        29 => (fg: s.fg, bg: s.bg, mods: s.mods & ~Modifier.crossedOut),
        39 => (fg: 0, bg: s.bg, mods: s.mods),
        49 => (fg: s.fg, bg: 0, mods: s.mods),
        _ => s,
      };

  static ({String char, int nextIdx})? _readNextGrapheme(
    String ansiText,
    int idx,
    int codeUnit,
  ) {
    if (codeUnit < 128) {
      return (char: String.fromCharCode(codeUnit), nextIdx: idx + 1);
    }
    final range = CharacterRange.at(ansiText, idx);
    if (!range.moveNext()) return null;
    final grapheme = range.current;
    return (char: grapheme, nextIdx: idx + grapheme.length);
  }

  static int _writeParsedGrapheme(
    List<_ParsedAnsiCell> row,
    int col,
    String char,
    _AnsiStyle style,
  ) {
    final w = graphemeWidth(char);
    if (w == 0) return col;
    _clearSplitParsedWideAt(row, col);
    _putParsedCell(row, col, (
      char: char,
      fg: style.fg,
      bg: style.bg,
      mods: style.mods,
    ));
    if (w == 2) {
      _clearSplitParsedWideAt(row, col + 1);
      _putParsedCell(row, col + 1, (
        char: '',
        fg: style.fg,
        bg: style.bg,
        mods: style.mods,
      ));
    }
    return col + w;
  }

  static void _clearSplitParsedWideAt(List<_ParsedAnsiCell> row, int col) {
    if (col >= row.length) return;
    if (row[col].char == '' && col > 0 && isWideGrapheme(row[col - 1].char)) {
      row[col - 1] = _blankParsedCell;
    } else if (isWideGrapheme(row[col].char) &&
        col + 1 < row.length &&
        row[col + 1].char == '') {
      row[col + 1] = _blankParsedCell;
    }
  }

  static void _putParsedCell(
    List<_ParsedAnsiCell> row,
    int col,
    _ParsedAnsiCell cell,
  ) {
    while (row.length < col) {
      row.add(_blankParsedCell);
    }
    if (col < row.length) {
      row[col] = cell;
    } else {
      row.add(cell);
    }
  }

  static Buffer _materializeParsedRows(
    List<List<_ParsedAnsiCell>> rows, {
    int? width,
    int? height,
  }) {
    var maxCols = 0;
    for (final row in rows) {
      if (row.length > maxCols) maxCols = row.length;
    }

    final targetWidth = width != null ? max(0, width) : maxCols;
    final targetHeight = height != null ? max(0, height) : rows.length;
    final buffer = Buffer.blank(targetWidth, targetHeight);
    final rowLimit = min(rows.length, targetHeight);

    for (var y = 0; y < rowLimit; y++) {
      _copyParsedRow(buffer, y, rows[y], targetWidth);
    }
    return buffer;
  }

  static void _copyParsedRow(
    Buffer buffer,
    int y,
    List<_ParsedAnsiCell> row,
    int targetWidth,
  ) {
    final charsArray = buffer.characters;
    final attrsArray = buffer.attributes;
    final rowOffset = y * targetWidth;
    final colLimit = min(row.length, targetWidth);

    for (var x = 0; x < colLimit; x++) {
      final cell = row[x];
      final idx = rowOffset + x;
      final clippedWide =
          x + 1 >= targetWidth && cell.char != '' && isWideGrapheme(cell.char);
      charsArray[idx] = clippedWide ? ' ' : cell.char;
      final attrIdx = idx * 3;
      attrsArray[attrIdx] = cell.fg;
      attrsArray[attrIdx + 1] = cell.bg;
      attrsArray[attrIdx + 2] = cell.mods;
    }
  }

  /// Serializes this [Buffer] grid into an ANSI escape sequence string.
  ///
  /// When [trimTrailingSpaces] is `true` (default), unstyled trailing blank and
  /// wide-padding cells (`bg == 0 && mods == 0`) are trimmed on each row.
  /// When [resetLineEndings] is `true`, `\x1b[0m` is emitted before `\n` on any
  /// row where an SGR style is active.
  String toAnsiString({
    bool trimTrailingSpaces = true,
    bool resetLineEndings = false,
  }) {
    final sb = StringBuffer();
    var activeStyle = _defaultAnsiStyle;

    for (var y = 0; y < height; y++) {
      final lastCol = trimTrailingSpaces ? _lastContentCol(y) : width - 1;
      activeStyle = _writeAnsiRowCells(sb, y, lastCol, activeStyle);
      if (resetLineEndings && activeStyle != _defaultAnsiStyle) {
        sb.write('\x1b[0m');
        activeStyle = _defaultAnsiStyle;
      }
      sb.write('\n');
    }

    if (activeStyle != _defaultAnsiStyle) {
      sb.write('\x1b[0m');
    }
    return sb.toString();
  }

  int _lastContentCol(int y) {
    final rowOffset = y * width;
    for (var x = width - 1; x >= 0; x--) {
      final idx = rowOffset + x;
      final char = characters[idx];
      final attrIdx = idx * 3;
      final isBlankUnstyled =
          (char == ' ' || char == '') &&
          attributes[attrIdx + 1] == 0 &&
          attributes[attrIdx + 2] == 0;
      if (!isBlankUnstyled) return x;
    }
    return -1;
  }

  _AnsiStyle _writeAnsiRowCells(
    StringBuffer sb,
    int y,
    int lastCol,
    _AnsiStyle initialStyle,
  ) {
    var activeStyle = initialStyle;
    final rowOffset = y * width;

    for (var x = 0; x <= lastCol; x++) {
      final idx = rowOffset + x;
      final char = characters[idx];
      // Wide character padding cells are represented by empty strings. Skip them.
      if (char == '') continue;

      final attrIdx = idx * 3;
      final cellStyle = (
        fg: attributes[attrIdx],
        bg: attributes[attrIdx + 1],
        mods: attributes[attrIdx + 2],
      );
      activeStyle = _writeAnsiStyleTransition(sb, activeStyle, cellStyle);
      sb.write(char);
    }
    return activeStyle;
  }

  static _AnsiStyle _writeAnsiStyleTransition(
    StringBuffer sb,
    _AnsiStyle current,
    _AnsiStyle target,
  ) {
    if (current == target) return current;
    if (target == _defaultAnsiStyle) {
      sb.write('\x1b[0m');
      return _defaultAnsiStyle;
    }

    final effective = _needsFullSgrReset(current, target)
        ? _emitFullSgrReset(sb)
        : current;

    final codes = <String>[
      if (target.fg != effective.fg && target.fg != 0)
        _rgbSgrSegment(38, target.fg),
      if (target.bg != effective.bg && target.bg != 0)
        _rgbSgrSegment(48, target.bg),
      for (final (bit, code) in _ansiModifierSetCodes)
        if ((target.mods & bit) != 0 && (effective.mods & bit) == 0) '$code',
    ];

    if (codes.isNotEmpty) {
      sb
        ..write('\x1b[')
        ..write(codes.join(';'))
        ..write('m');
    }
    return target;
  }

  static bool _needsFullSgrReset(_AnsiStyle current, _AnsiStyle target) {
    final colorCleared =
        (current.fg != 0 && target.fg == 0) ||
        (current.bg != 0 && target.bg == 0);
    final modCleared = ((current.mods & 0xFF) & ~(target.mods & 0xFF)) != 0;
    return colorCleared || modCleared;
  }

  static _AnsiStyle _emitFullSgrReset(StringBuffer sb) {
    sb.write('\x1b[0m');
    return _defaultAnsiStyle;
  }

  static String _rgbSgrSegment(int prefix, int argb) =>
      '$prefix;2;${(argb >> 16) & 0xFF};${(argb >> 8) & 0xFF};${argb & 0xFF}';
}
