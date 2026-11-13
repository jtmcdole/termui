import 'package:termui/termui.dart';
import 'dart:math';
import 'dart:typed_data';
import 'package:characters/characters.dart';

/// Blends two ARGB colors (resolving [Color.ansi] indices via legacy VGA when
/// blended under a translucent overlay).
int blendColor(int top, int bottom) {
  if (bottom == 0) return top;
  if (top == 0) return bottom;
  if (top.isAnsiIndexed) return top;

  final aTop = (top >> 24) & 0xFF;
  if (aTop == 255) return top;

  final resolvedBottom = bottom.isAnsiIndexed
      ? TerminalColorTheme.legacyVga.resolveAnsi256(bottom.ansiIndex).argb
      : bottom;

  final rTop = (top >> 16) & 0xFF;
  final gTop = (top >> 8) & 0xFF;
  final bTop = top & 0xFF;

  final aBottom = (resolvedBottom >> 24) & 0xFF;
  final rBottom = (resolvedBottom >> 16) & 0xFF;
  final gBottom = (resolvedBottom >> 8) & 0xFF;
  final bBottom = resolvedBottom & 0xFF;

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
  if (color.isAnsiIndexed) return color;
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

  /// Lazily allocated array of per-cell OSC 8 hyperlink URIs (`null` = no link).
  List<String?>? _uris;

  /// Whether any cell in this buffer has a non-null OSC 8 hyperlink URI.
  bool get hasUris => _uris != null;

  /// The list of terminal effects registered in this buffer.
  final List<RegisteredEffect> effects = [];

  /// Selectable sub-regions registered during the current paint pass.
  final List<Rect> selectableRegions = [];

  final List<int> _selectableRegionZIndices = [];

  final List<({Rect bounds, KittyImageRegistry registry})>
  _scopedKittyRegistries = [];

  /// Whether any Kitty image is registered in [KittyImageRegistry.global] or a
  /// scoped registry attached to this buffer.
  bool get hasKittyImages {
    if (KittyImageRegistry.global.hasImages) return true;
    for (final entry in _scopedKittyRegistries) {
      if (entry.registry.hasImages) return true;
    }
    return false;
  }

  /// Whether cell attribute writes alpha-blend colors over existing cells when
  /// a per-call `blend` argument is omitted.
  final bool defaultBlend;

  final int _emptyModifiers;

  /// Adds a terminal effect to this buffer.
  void addEffect(RegisteredEffect effect) {
    effects.add(effect);
  }

  /// Registers a selectable rectangular [region] in buffer coordinates with optional [zIndex].
  void registerSelectableRegion(Rect region, {int zIndex = 0}) {
    final clipped = _boundsClip.intersect(region);
    if (clipped.width <= 0 || clipped.height <= 0) return;
    final existingIdx = selectableRegions.indexOf(clipped);
    if (existingIdx >= 0) {
      if (zIndex > _selectableRegionZIndices[existingIdx]) {
        _selectableRegionZIndices[existingIdx] = zIndex;
      }
      return;
    }
    selectableRegions.add(clipped);
    _selectableRegionZIndices.add(zIndex);
  }

  /// Layer z-index recorded for `selectableRegions[index]` (`0` by default).
  int selectableRegionZIndexAt(int index) =>
      index >= 0 && index < _selectableRegionZIndices.length
      ? _selectableRegionZIndices[index]
      : 0;

  /// Registers a pane-scoped [KittyImageRegistry] for cells within [bounds].
  void registerKittyRegistry(Rect bounds, KittyImageRegistry registry) {
    final clipped = _boundsClip.intersect(bounds);
    if (clipped.width <= 0 || clipped.height <= 0) return;
    if (_scopedKittyRegistries.isNotEmpty) {
      final last = _scopedKittyRegistries.last;
      if (identical(last.registry, registry) &&
          _rectCovers(clipped, last.bounds)) {
        _scopedKittyRegistries[_scopedKittyRegistries.length - 1] = (
          bounds: clipped,
          registry: registry,
        );
        return;
      }
    }
    _scopedKittyRegistries.add((bounds: clipped, registry: registry));
  }

  static bool _rectCovers(Rect outer, Rect inner) =>
      outer.x <= inner.x &&
      outer.y <= inner.y &&
      outer.x + outer.width >= inner.x + inner.width &&
      outer.y + outer.height >= inner.y + inner.height;

  void _clipScopedRegistries() {
    for (var i = _scopedKittyRegistries.length - 1; i >= 0; i--) {
      final entry = _scopedKittyRegistries[i];
      final clipped = _boundsClip.intersect(entry.bounds);
      if (clipped.width <= 0 || clipped.height <= 0) {
        _scopedKittyRegistries.removeAt(i);
      } else {
        _scopedKittyRegistries[i] = (bounds: clipped, registry: entry.registry);
      }
    }
  }

  /// Resolves the active [KittyImageRegistry] covering ([x], [y]), falling back
  /// to [KittyImageRegistry.global] outside scoped regions.
  KittyImageRegistry lookupKittyRegistry(int x, int y) {
    for (var i = _scopedKittyRegistries.length - 1; i >= 0; i--) {
      final entry = _scopedKittyRegistries[i];
      if (entry.bounds.contains(x, y)) {
        return entry.registry;
      }
    }
    return KittyImageRegistry.global;
  }

  /// Looks up [imageId] using any scoped [KittyImageRegistry] covering ([x], [y]),
  /// falling back to [KittyImageRegistry.global] only outside scoped regions.
  KittyImageData? lookupKittyImage(int x, int y, int imageId) =>
      lookupKittyRegistry(x, y).lookupImage(imageId);

  /// Propagates region metadata (`effects`, `selectableRegions`, and scoped
  /// [KittyImageRegistry] bounds) from [source] translated by ([dx], [dy]) and
  /// clipped to [clip] (or [activeClip]).
  void propagateMetadataFrom(
    Buffer source, {
    int dx = 0,
    int dy = 0,
    Rect? clip,
    int? zIndex,
  }) {
    final effectiveClip = _boundsClip.intersect(clip ?? activeClip);
    if (effectiveClip.width <= 0 || effectiveClip.height <= 0) return;
    _propagateEffectsFrom(source, dx, dy, effectiveClip);
    _propagateSelectableRegionsFrom(source, dx, dy, effectiveClip, zIndex);
    _propagateRegistriesFrom(source, dx, dy, effectiveClip);
  }

  void _propagateSelectableRegionsFrom(
    Buffer source,
    int dx,
    int dy,
    Rect clip,
    int? zIndexOverride,
  ) {
    final regions = source.selectableRegions;
    for (var i = 0; i < regions.length; i++) {
      final reg = regions[i];
      final translated = Rect(
        dx + reg.x,
        dy + reg.y,
        reg.width,
        reg.height,
      ).intersect(clip);
      if (translated.width > 0 && translated.height > 0) {
        registerSelectableRegion(
          translated,
          zIndex: zIndexOverride ?? source.selectableRegionZIndexAt(i),
        );
      }
    }
  }

  void _propagateEffectsFrom(Buffer source, int dx, int dy, Rect clip) {
    for (final reg in source.effects) {
      final translated = Rect(
        dx + reg.bounds.x,
        dy + reg.bounds.y,
        reg.bounds.width,
        reg.bounds.height,
      ).intersect(clip);
      if (translated.width > 0 && translated.height > 0) {
        addEffect(
          RegisteredEffect(
            reg.effect,
            translated,
            reg.zIndex,
            reg.originalIndex,
          ),
        );
      }
    }
  }

  void _propagateRegistriesFrom(Buffer source, int dx, int dy, Rect clip) {
    if (source is Viewport) return;
    for (final entry in source._scopedKittyRegistries) {
      final translated = Rect(
        dx + entry.bounds.x,
        dy + entry.bounds.y,
        entry.bounds.width,
        entry.bounds.height,
      ).intersect(clip);
      if (translated.width > 0 && translated.height > 0) {
        registerKittyRegistry(translated, entry.registry);
      }
    }
  }

  /// Whether all cell channels (`char`, `fg`, `bg`, `modifiers`, `underlineColor`, `uri`)
  /// at ([x], [y]) match [other] at ([ox], [oy]).
  bool cellsEqual(int x, int y, Buffer other, int ox, int oy) =>
      getCharacter(x, y) == other.getCharacter(ox, oy) &&
      getForeground(x, y) == other.getForeground(ox, oy) &&
      getBackground(x, y) == other.getBackground(ox, oy) &&
      getModifiers(x, y) == other.getModifiers(ox, oy) &&
      getUnderlineColor(x, y) == other.getUnderlineColor(ox, oy) &&
      getUri(x, y) == other.getUri(ox, oy);

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

  /// Gets the OSC 8 hyperlink URI at ([x], [y]), or `null` when no link is set.
  String? getUri(int x, int y) {
    final uris = _uris;
    if (uris == null || !isCellValid(x, y)) return null;
    return uris[y * width + x];
  }

  /// Sets the OSC 8 hyperlink URI at ([x], [y]) (`null` clears the link).
  void setUri(int x, int y, String? uri) {
    if (!isCellValid(x, y)) return;
    _setUriAt(y * width + x, uri);
  }

  @pragma('vm:prefer-inline')
  void _setUriAt(int cellIdx, String? uri) {
    if ((uri == null || uri.isEmpty) && _uris == null) return;
    (_uris ??= List<String?>.filled(width * height, null))[cellIdx] =
        (uri != null && uri.isEmpty) ? null : uri;
  }

  /// Gets the SGR 58 underline color at flat index [cellIdx] (`0` when unset).
  @pragma('vm:prefer-inline')
  int getUnderlineColorAt(int cellIdx) => _underlineColors?[cellIdx] ?? 0;

  /// Sets the SGR 58 underline color at flat index [cellIdx].
  @pragma('vm:prefer-inline')
  void setUnderlineColorAt(int cellIdx, int ulColor) =>
      _setUnderlineColorAt(cellIdx, ulColor);

  /// Gets the OSC 8 hyperlink URI at flat index [cellIdx] (`null` when unset).
  @pragma('vm:prefer-inline')
  String? getUriAt(int cellIdx) => _uris?[cellIdx];

  /// Sets the OSC 8 hyperlink URI at flat index [cellIdx].
  @pragma('vm:prefer-inline')
  void setUriAt(int cellIdx, String? uri) => _setUriAt(cellIdx, uri);

  /// Copies SGR 58 underline color and OSC 8 URI from [source] at [srcIdx] to [dstIdx].
  @pragma('vm:prefer-inline')
  void copyCellAuxAt(Buffer source, int dstIdx, int srcIdx) {
    _setUnderlineColorAt(dstIdx, source.getUnderlineColorAt(srcIdx));
    _setUriAt(dstIdx, source.getUriAt(srcIdx));
  }

  /// Clears SGR 58 underline colors and OSC 8 URIs across `[start, end)`.
  void clearCellAuxRange(int start, int end) {
    if (start >= end) return;
    _underlineColors?.fillRange(start, end, 0);
    _uris?.fillRange(start, end, null);
  }

  /// Copies `[srcStart, srcStart + count)` auxiliary attributes from [source] to `[dstStart, dstStart + count)`.
  void copyCellAuxRangeFrom(
    Buffer source,
    int dstStart,
    int srcStart,
    int count,
  ) {
    if (count <= 0) return;
    final srcUl = source._underlineColors;
    if (srcUl != null) {
      (_underlineColors ??= Uint32List(
        width * height,
      )).setRange(dstStart, dstStart + count, srcUl, srcStart);
    } else {
      _underlineColors?.fillRange(dstStart, dstStart + count, 0);
    }
    final srcUris = source._uris;
    if (srcUris != null) {
      (_uris ??= List<String?>.filled(
        width * height,
        null,
      )).setRange(dstStart, dstStart + count, srcUris, srcStart);
    } else {
      _uris?.fillRange(dstStart, dstStart + count, null);
    }
  }

  /// Copies non-empty SGR 58 underline colors across `[start, end)`, or `null` if all `0`.
  Uint32List? sliceUnderlineColors(int start, int end) {
    final ul = _underlineColors;
    if (ul == null || start >= end) return null;
    for (var i = start; i < end; i++) {
      if (ul[i] != 0) return ul.sublist(start, end);
    }
    return null;
  }

  /// Copies non-empty OSC 8 URIs across `[start, end)`, or `null` if all `null`.
  List<String?>? sliceUris(int start, int end) {
    final uris = _uris;
    if (uris == null || start >= end) return null;
    for (var i = start; i < end; i++) {
      if (uris[i] != null) return uris.sublist(start, end);
    }
    return null;
  }

  /// Writes optional [underlineColors] and [uris] slices into `[dstStart, dstStart + count)`.
  void writeCellAuxSlices(
    int dstStart,
    int count, {
    Uint32List? underlineColors,
    List<String?>? uris,
  }) {
    if (count <= 0) return;
    _writeUnderlineColorSlice(dstStart, count, underlineColors);
    _writeUriSlice(dstStart, count, uris);
  }

  void _writeUnderlineColorSlice(int dstStart, int count, Uint32List? slice) {
    if (slice == null || slice.isEmpty) {
      _underlineColors?.fillRange(dstStart, dstStart + count, 0);
      return;
    }
    final dst = _underlineColors ??= Uint32List(width * height);
    final n = min(count, slice.length);
    dst.setRange(dstStart, dstStart + n, slice, 0);
    if (n < count) dst.fillRange(dstStart + n, dstStart + count, 0);
  }

  void _writeUriSlice(int dstStart, int count, List<String?>? slice) {
    if (slice == null || slice.isEmpty) {
      _uris?.fillRange(dstStart, dstStart + count, null);
      return;
    }
    final dst = _uris ??= List<String?>.filled(width * height, null);
    final n = min(count, slice.length);
    dst.setRange(dstStart, dstStart + n, slice, 0);
    if (n < count) dst.fillRange(dstStart + n, dstStart + count, null);
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
    _uris?[cellIdx] = null;
  }

  @pragma('vm:prefer-inline')
  void _writeCellAttributes(
    int attrIdx, {
    int? fg,
    int? bg,
    int? modifiers,
    int? underlineColor,
    String? uri,
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
    final cellIdx = attrIdx ~/ 3;
    if (underlineColor != null) _setUnderlineColorAt(cellIdx, underlineColor);
    if (uri != null) _setUriAt(cellIdx, uri);
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
    String? uri,
  }) {
    if (isCellValid(x, y)) {
      final useBlend = blend ?? defaultBlend;
      final cellIdx = y * width + x;
      final idx = cellIdx * 3;
      characters[cellIdx] = char;
      attributes[idx + 0] = useBlend ? blendColor(fg, attributes[idx + 0]) : fg;
      attributes[idx + 1] = useBlend ? blendColor(bg, attributes[idx + 1]) : bg;
      attributes[idx + 2] = mod;
      _setUnderlineColorAt(cellIdx, underlineColor);
      _setUriAt(cellIdx, uri);
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
    String? uri,
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
      uri: uri,
      blend: useBlend,
    );
    if (isWide && x + 1 < width) {
      _writeCellAttributes(
        (charIdx + 1) * 3,
        fg: fg,
        bg: bg,
        modifiers: modifiers,
        underlineColor: underlineColor,
        uri: uri,
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
      _uris?.fillRange(0, _uris!.length, null);
      for (var i = 2; i < attributes.length; i += 3) {
        attributes[i] = Modifier.transparent;
      }
      effects.clear();
      selectableRegions.clear();
      _selectableRegionZIndices.clear();
      _scopedKittyRegistries.clear();
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
    String? uri,
    bool? blend,
  }) {
    if (char != null) characters.fillRange(0, characters.length, char);
    if (fg == null &&
        bg == null &&
        modifiers == null &&
        underlineColor == null &&
        uri == null) {
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
        uri: uri,
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
    String? uri,
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
        underlineColor == null &&
        uri == null) {
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
          uri: uri,
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

    const yellow = 0xFFFCD116;
    const charcoal = 0xFF36454F;

    for (var y = startY; y < endY; y++) {
      final ly = y - offsetY;
      final rowOffset = y * width;
      for (var x = startX; x < endX; x++) {
        final idx = rowOffset + x;
        characters[idx] = _cautionChar(x - offsetX, ly);
        final attrIdx = idx * 3;
        attributes[attrIdx + 0] = yellow;
        attributes[attrIdx + 1] = charcoal;
        attributes[attrIdx + 2] = Modifier.none;
        _setUnderlineColorAt(idx, 0);
        _setUriAt(idx, null);
      }
    }
  }

  static String _cautionChar(int lx, int ly) =>
      switch (((lx - ly) % 3 + 3) % 3) {
        0 => '\u259C',
        1 => '\u2599',
        _ => ' ',
      };

  void _copyOverlappingRows(
    int newWidth,
    int overlapWidth,
    int overlapHeight,
    List<String> newChars,
    Uint32List newAttributes,
    Uint32List? oldUl,
    Uint32List? newUl,
    List<String?>? oldUris,
    List<String?>? newUris,
  ) {
    for (var y = 0; y < overlapHeight; y++) {
      final targetCharStart = y * newWidth;
      final sourceCharStart = y * width;
      newChars.setRange(
        targetCharStart,
        targetCharStart + overlapWidth,
        characters,
        sourceCharStart,
      );
      newUl?.setRange(
        targetCharStart,
        targetCharStart + overlapWidth,
        oldUl!,
        sourceCharStart,
      );
      newUris?.setRange(
        targetCharStart,
        targetCharStart + overlapWidth,
        oldUris!,
        sourceCharStart,
      );
      newAttributes.setRange(
        y * newWidth * 3,
        y * newWidth * 3 + overlapWidth * 3,
        attributes,
        y * width * 3,
      );
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
      final oldUris = _uris;
      final newUris = oldUris != null
          ? List<String?>.filled(newWidth * newHeight, null)
          : null;

      if (_emptyModifiers != 0) {
        for (var i = 2; i < newAttributes.length; i += 3) {
          newAttributes[i] = _emptyModifiers;
        }
      }

      final overlapWidth = min(width, newWidth);
      final overlapHeight = min(height, newHeight);

      if (overlapWidth > 0 && overlapHeight > 0) {
        _copyOverlappingRows(
          newWidth,
          overlapWidth,
          overlapHeight,
          newChars,
          newAttributes,
          oldUl,
          newUl,
          oldUris,
          newUris,
        );
      }

      width = newWidth;
      height = newHeight;
      characters = newChars;
      attributes = newAttributes;
      _underlineColors = newUl;
      _uris = newUris;
      _boundsClip = Rect(0, 0, width, height);
      _clipScopedRegistries();
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
        _resetCell(idx - 1);
      }
    } else if (isWideGrapheme(characters[idx])) {
      if (currentX + 1 < width && characters[idx + 1] == '') {
        _resetCell(idx + 1);
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
    String? uri,
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
    _setUnderlineColorAt(idx, ulColor);
    _setUriAt(idx, uri);
  }

  void _writeAsciiString(int x, int y, String text, Style style) {
    var currentX = x;
    var currentY = y;
    final fg = style.foreground?.argb ?? 0;
    final bg = style.background?.argb ?? 0;
    final ulColor = style.underlineColor?.argb ?? 0;
    final uri = style.uri;
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
          uri,
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
    String? uri,
    bool hasFg,
    bool hasBg,
  ) {
    if (!isCellValid(currentX, currentY)) return;
    final idx = currentY * width + currentX;
    _clearOverwrittenWideChar(currentX, idx);
    if (isWide &&
        (currentX == width - 1 || !isCellValid(currentX + 1, currentY))) {
      // Can't fit wide character in the last column or clip edge, write a space instead
      _writeStyledCellRaw(
        idx,
        ' ',
        fg,
        bg,
        modifiers,
        ulColor,
        uri,
        hasFg,
        hasBg,
      );
      return;
    }
    _writeStyledCellRaw(
      idx,
      char,
      fg,
      bg,
      modifiers,
      ulColor,
      uri,
      hasFg,
      hasBg,
    );
    if (!isWide || currentX + 1 >= width) return;
    final nextIdx = idx + 1;
    if (isWideGrapheme(characters[nextIdx]) &&
        currentX + 2 < width &&
        characters[idx + 2] == '') {
      _resetCell(idx + 2);
    }
    _writeStyledCellRaw(
      nextIdx,
      '',
      fg,
      bg,
      modifiers,
      ulColor,
      uri,
      hasFg,
      hasBg,
    );
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
    final uri = style.uri;
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
        uri,
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
      _propagateLayerMetadata(target, sortedLayers);
      _compositeRecursive(target, sortedLayers, 0);

      // Premultiply final alpha against black for any remaining transparent pixels.
      final attrs = target.attributes;
      final len = attrs.length;
      for (var i = 0; i < len; i += 3) {
        final fg = attrs[i];
        if (fg != 0 && fg.effectiveAlpha != 255) {
          attrs[i] = _premultiplyBlack(fg);
        }
        final bg = attrs[i + 1];
        if (bg != 0 && bg.effectiveAlpha != 255) {
          attrs[i + 1] = _premultiplyBlack(bg);
        }
      }
    } finally {
      Tracer.record(_traceCompositeId, Phase.end, TraceCategory.compositor);
    }
  }

  static void _propagateLayerMetadata(
    Buffer target,
    List<LayeredBuffer> sortedLayers,
  ) {
    for (var i = sortedLayers.length - 1; i >= 0; i--) {
      final layer = sortedLayers[i];
      _propagateLayerRegistries(target, layer);
      _propagateLayerSelectableRegions(target, layer);
    }
  }

  static void _propagateLayerRegistries(Buffer target, LayeredBuffer layer) {
    for (final entry in layer.buffer._scopedKittyRegistries) {
      target.registerKittyRegistry(
        Rect(
          layer.x + entry.bounds.x,
          layer.y + entry.bounds.y,
          entry.bounds.width,
          entry.bounds.height,
        ),
        entry.registry,
      );
    }
  }

  static void _propagateLayerSelectableRegions(
    Buffer target,
    LayeredBuffer layer,
  ) {
    for (final reg in layer.buffer.selectableRegions) {
      target.registerSelectableRegion(
        Rect(layer.x + reg.x, layer.y + reg.y, reg.width, reg.height),
        zIndex: layer.zIndex,
      );
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
      final fgAlpha = target.attributes[attrIdx].effectiveAlpha;
      final bgAlpha = target.attributes[attrIdx + 1].effectiveAlpha;

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
        source._uris?[sourceIdx],
        masks,
        word,
        maskBit,
        fgOccluded,
      );
    }
    if (!fgOccluded &&
        !(charOccluded && (sourceMods & Modifier.kittyPlaceholder) != 0)) {
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
    String? sourceUri,
    _CompositeMasks masks,
    int word,
    int maskBit,
    bool fgOccluded,
  ) {
    if (sourceChar != ' ') {
      target.characters[targetIdx] = sourceChar;
      target.attributes[targetAttrIdx + 2] = sourceMods;
      target._setUnderlineColorAt(targetIdx, sourceUlColor);
      target._setUriAt(targetIdx, sourceUri);
      masks.charWritten[word] |= maskBit;
      if ((sourceMods & Modifier.kittyPlaceholder) != 0) {
        target.attributes[targetAttrIdx] = sourceFg;
        masks.fgWritten[word] |= maskBit;
        return true;
      }
      return fgOccluded;
    }
    if (sourceBg.effectiveAlpha == 255) {
      target.characters[targetIdx] = ' ';
      target.attributes[targetAttrIdx + 2] = sourceMods;
      target._setUnderlineColorAt(targetIdx, sourceUlColor);
      target._setUriAt(targetIdx, sourceUri);
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
    target.attributes[targetAttrIdx + 2] = Modifier.mergeLayered(
      target.attributes[targetAttrIdx + 2],
      sourceMods,
    );
    if (blendedFg.effectiveAlpha == 255 || sourceFg.effectiveAlpha == 255) {
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
    if (skipZeroBg && sourceBg.effectiveAlpha == 0) return;
    final blendedBg = blendColor(
      target.attributes[targetAttrIdx + 1],
      sourceBg,
    );
    target.attributes[targetAttrIdx + 1] = blendedBg;
    if (blendedBg.effectiveAlpha == 255) {
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
        (sourceChar != ' ' || sourceBg.effectiveAlpha == 255)) {
      target.characters[targetIdx] = sourceChar;
      target.attributes[targetAttrIdx + 2] = sourceMods;
      target._setUnderlineColorAt(
        targetIdx,
        buf._underlineColors?[sourceIdx] ?? 0,
      );
      target._setUriAt(targetIdx, buf._uris?[sourceIdx]);
    }

    if (targetIsEmptyChar || (sourceMods & Modifier.kittyPlaceholder) == 0) {
      target.attributes[targetAttrIdx] = blendColor(
        sourceFg,
        target.attributes[targetAttrIdx],
      );
      target.attributes[targetAttrIdx + 2] = Modifier.mergeLayered(
        target.attributes[targetAttrIdx + 2],
        sourceMods,
      );
    }
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
  var i = 0;
  while (i < len) {
    var cp = grapheme.codeUnitAt(i++);
    if (cp >= 0xD800 && cp <= 0xDBFF && i < len) {
      final lo = grapheme.codeUnitAt(i);
      if (lo >= 0xDC00 && lo <= 0xDFFF) {
        cp = 0x10000 + ((cp & 0x3FF) << 10) + (lo & 0x3FF);
        i++;
      }
    }
    if (!isZeroWidthCodePoint(cp)) return false;
  }
  return true;
}

/// Returns true if the given code point occupies 0 terminal cells.
bool isZeroWidthCodePoint(int codePoint) {
  if (codePoint <= 0x1F) return codePoint >= 0;
  if (codePoint < 0x7F) return false;
  if (codePoint <= 0x9F) return true;
  if (codePoint >= 0x0300 && codePoint <= 0x036F) return true;
  var low = 0;
  var high = _zeroWidthRangeStarts.length - 1;
  while (low <= high) {
    final mid = (low + high) >> 1;
    if (codePoint < _zeroWidthRangeStarts[mid]) {
      high = mid - 1;
    } else if (codePoint > _zeroWidthRangeEnds[mid]) {
      low = mid + 1;
    } else {
      return true;
    }
  }
  return false;
}

final Uint32List _zeroWidthRangeStarts = Uint32List.fromList([
  0x00AD,
  0x0483,
  0x0591,
  0x05BF,
  0x05C1,
  0x05C4,
  0x05C7,
  0x0610,
  0x064B,
  0x0670,
  0x06D6,
  0x06DF,
  0x06E7,
  0x06EA,
  0x0711,
  0x0730,
  0x07EB,
  0x0816,
  0x081B,
  0x0825,
  0x0829,
  0x08D3,
  0x08E3,
  0x0951,
  0x09FE,
  0x0F82,
  0x0F86,
  0x1160,
  0x135D,
  0x17DD,
  0x193A,
  0x1A17,
  0x1A75,
  0x1AB0,
  0x1B6B,
  0x1CD0,
  0x1CD4,
  0x1CE2,
  0x1CED,
  0x1CF4,
  0x1CF8,
  0x1DC0,
  0x200B,
  0x202A,
  0x2060,
  0x20D0,
  0x2CEF,
  0x2DE0,
  0xFE00,
  0xFEFF,
  0xFFF9,
  0xE0000,
  0xE0100,
]);

final Uint32List _zeroWidthRangeEnds = Uint32List.fromList([
  0x00AD,
  0x0489,
  0x05BD,
  0x05BF,
  0x05C2,
  0x05C5,
  0x05C7,
  0x061A,
  0x065F,
  0x0670,
  0x06DC,
  0x06E4,
  0x06E8,
  0x06ED,
  0x0711,
  0x074A,
  0x07F3,
  0x0819,
  0x0823,
  0x0827,
  0x082D,
  0x08E1,
  0x0902,
  0x0957,
  0x09FE,
  0x0F84,
  0x0F87,
  0x11FF,
  0x135F,
  0x17DD,
  0x193A,
  0x1A18,
  0x1A7C,
  0x1ABE,
  0x1B73,
  0x1CD2,
  0x1CE0,
  0x1CE8,
  0x1CED,
  0x1CF4,
  0x1CF9,
  0x1DFF,
  0x200F,
  0x202E,
  0x206F,
  0x20FF,
  0x2CF1,
  0x2DFF,
  0xFE0F,
  0xFEFF,
  0xFFFB,
  0xE007F,
  0xE01EF,
]);

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

typedef _AnsiStyle = ({int fg, int bg, int mods, int ulColor, String? uri});
typedef _ToAnsiStyle = _AnsiStyle;
typedef _ParsedAnsiCell = ({
  String char,
  int fg,
  int bg,
  int mods,
  int ulColor,
  String? uri,
});

const _AnsiStyle _defaultAnsiStyle = (
  fg: 0,
  bg: 0,
  mods: Modifier.none,
  ulColor: 0,
  uri: null,
);
const _ToAnsiStyle _defaultToAnsiStyle = _defaultAnsiStyle;
const _ParsedAnsiCell _blankParsedCell = (
  char: ' ',
  fg: 0,
  bg: 0,
  mods: Modifier.none,
  ulColor: 0,
  uri: null,
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
  (Modifier.overline, 53),
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
    final idx = escIdx + 1;
    if (idx >= len) return (nextIdx: idx, style: style);
    final introducer = ansiText.codeUnitAt(idx);
    if (introducer == 0x5D) {
      return _consumeOscEscape(ansiText, idx + 1, style);
    }
    if (introducer != 0x5B) {
      return (nextIdx: idx, style: style);
    }
    return _consumeCsiEscape(ansiText, idx + 1, style);
  }

  static ({int nextIdx, _AnsiStyle style}) _consumeOscEscape(
    String ansiText,
    int start,
    _AnsiStyle style,
  ) {
    final end = _findOscPayloadEnd(ansiText, start);
    if (end.payloadEnd < 0) return (nextIdx: ansiText.length, style: style);
    final payload = ansiText.substring(start, end.payloadEnd);
    return (nextIdx: end.nextIdx, style: _applyOscPayload(payload, style));
  }

  static ({int payloadEnd, int nextIdx}) _findOscPayloadEnd(
    String text,
    int start,
  ) {
    for (var i = start; i < text.length; i++) {
      final cu = text.codeUnitAt(i);
      if (cu == 0x07) return (payloadEnd: i, nextIdx: i + 1);
      if (cu == 0x1B && i + 1 < text.length && text.codeUnitAt(i + 1) == 0x5C) {
        return (payloadEnd: i, nextIdx: i + 2);
      }
    }
    return (payloadEnd: -1, nextIdx: text.length);
  }

  static _AnsiStyle _applyOscPayload(String payload, _AnsiStyle style) {
    if (!payload.startsWith('8;')) return style;
    final secondSemi = payload.indexOf(';', 2);
    if (secondSemi == -1) return style;
    final uri = payload.substring(secondSemi + 1);
    return (
      fg: style.fg,
      bg: style.bg,
      mods: style.mods,
      ulColor: style.ulColor,
      uri: uri.isEmpty ? null : uri,
    );
  }

  static ({int nextIdx, _AnsiStyle style}) _consumeCsiEscape(
    String ansiText,
    int start,
    _AnsiStyle style,
  ) {
    final len = ansiText.length;
    var idx = start;
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

  static _AnsiStyle _resetSgrKeepingUri(_AnsiStyle s) =>
      (fg: 0, bg: 0, mods: Modifier.none, ulColor: 0, uri: s.uri);

  static _AnsiStyle _applySgrParams(String paramsStr, _AnsiStyle initial) {
    if (paramsStr.isEmpty || paramsStr == '0') {
      return _resetSgrKeepingUri(initial);
    }
    var style = initial;
    var pIdx = 0;
    while (pIdx < paramsStr.length) {
      final semi = _nextSemicolon(paramsStr, pIdx);
      final token = paramsStr.substring(pIdx, semi);
      if (token.contains(':')) {
        style = _applyColonSgrToken(token, style);
        pIdx = semi + 1;
        continue;
      }
      final code = int.tryParse(token) ?? 0;
      if (code == 38 || code == 48 || code == 58) {
        final parsedColor = _parseExtendedColorSgr(paramsStr, semi + 1);
        pIdx = parsedColor.nextIdx;
        if (parsedColor.argb != null) {
          style = _applyExtendedColorCode(code, parsedColor.argb!, style);
        }
      } else {
        style = _applySingleSgrCode(code, style);
        pIdx = semi + 1;
      }
    }
    return style;
  }

  static _AnsiStyle _applyExtendedColorCode(
    int code,
    int argb,
    _AnsiStyle s,
  ) => switch (code) {
    38 => (fg: argb, bg: s.bg, mods: s.mods, ulColor: s.ulColor, uri: s.uri),
    48 => (fg: s.fg, bg: argb, mods: s.mods, ulColor: s.ulColor, uri: s.uri),
    58 => (fg: s.fg, bg: s.bg, mods: s.mods, ulColor: argb, uri: s.uri),
    _ => s,
  };

  static _AnsiStyle _applyColonSgrToken(String token, _AnsiStyle s) {
    final parts = token.split(':');
    final head = int.tryParse(parts[0]) ?? -1;
    if (head == 4 && parts.length >= 2) {
      final sub = int.tryParse(parts[1]) ?? 0;
      if (sub <= 0 || sub >= UnderlineStyle.values.length) {
        final cleared =
            s.mods & ~(Modifier.underline | Modifier.underlineStyleMask);
        return (
          fg: s.fg,
          bg: s.bg,
          mods: cleared,
          ulColor: s.ulColor,
          uri: s.uri,
        );
      }
      final nextMods = Modifier.withUnderlineStyle(
        s.mods,
        UnderlineStyle.values[sub],
      );
      return (
        fg: s.fg,
        bg: s.bg,
        mods: nextMods,
        ulColor: s.ulColor,
        uri: s.uri,
      );
    }
    if ((head == 38 || head == 48 || head == 58) &&
        parts.length >= 3 &&
        parts[1] == '5') {
      final idx = int.tryParse(parts[2]);
      if (idx == null || idx < 0 || idx > 255) return s;
      return _applyExtendedColorCode(head, Color.ansi(idx).argb, s);
    }
    if ((head == 38 || head == 48 || head == 58) &&
        parts.length >= 5 &&
        parts[1] == '2') {
      final n = parts.length;
      final r = int.tryParse(parts[n - 3]) ?? 0;
      final g = int.tryParse(parts[n - 2]) ?? 0;
      final b = int.tryParse(parts[n - 1]) ?? 0;
      final argb =
          (0xFF << 24) | ((r & 0xFF) << 16) | ((g & 0xFF) << 8) | (b & 0xFF);
      return _applyExtendedColorCode(head, argb, s);
    }
    return s;
  }

  static int _nextSemicolon(String s, int from) {
    final idx = s.indexOf(';', from);
    return idx == -1 ? s.length : idx;
  }

  static ({int? argb, int nextIdx}) _parseExtendedColorSgr(
    String paramsStr,
    int typeStart,
  ) {
    if (typeStart >= paramsStr.length) {
      return (argb: null, nextIdx: paramsStr.length);
    }
    final s2 = _nextSemicolon(paramsStr, typeStart);
    final type = int.tryParse(paramsStr.substring(typeStart, s2)) ?? 0;
    if (type == 5) {
      if (s2 + 1 >= paramsStr.length) {
        return (argb: null, nextIdx: paramsStr.length);
      }
      final s3 = _nextSemicolon(paramsStr, s2 + 1);
      final idx = int.tryParse(paramsStr.substring(s2 + 1, s3));
      if (idx == null || idx < 0 || idx > 255) {
        return (argb: null, nextIdx: s3 + 1);
      }
      return (argb: Color.ansi(idx).argb, nextIdx: s3 + 1);
    }
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

  static _AnsiStyle _withMods(_AnsiStyle s, int mods) =>
      (fg: s.fg, bg: s.bg, mods: mods, ulColor: s.ulColor, uri: s.uri);

  static _AnsiStyle _applySingleSgrCode(int code, _AnsiStyle s) =>
      switch (code) {
        0 => _resetSgrKeepingUri(s),
        1 => _withMods(s, s.mods | Modifier.bold),
        2 => _withMods(s, s.mods | Modifier.dim),
        3 => _withMods(s, s.mods | Modifier.italic),
        4 => _withMods(
          s,
          (s.mods & ~Modifier.underlineStyleMask) | Modifier.underline,
        ),
        5 => _withMods(s, s.mods | Modifier.blink),
        7 => _withMods(s, s.mods | Modifier.reverse),
        8 => _withMods(s, s.mods | Modifier.hidden),
        9 => _withMods(s, s.mods | Modifier.crossedOut),
        21 => _withMods(
          s,
          Modifier.withUnderlineStyle(s.mods, UnderlineStyle.doubleLine),
        ),
        22 => _withMods(s, s.mods & ~(Modifier.bold | Modifier.dim)),
        23 => _withMods(s, s.mods & ~Modifier.italic),
        24 => _withMods(
          s,
          s.mods & ~(Modifier.underline | Modifier.underlineStyleMask),
        ),
        25 => _withMods(s, s.mods & ~Modifier.blink),
        27 => _withMods(s, s.mods & ~Modifier.reverse),
        28 => _withMods(s, s.mods & ~Modifier.hidden),
        29 => _withMods(s, s.mods & ~Modifier.crossedOut),
        >= 30 && <= 37 => _applyExtendedColorCode(
          38,
          Color.ansi(code - 30).argb,
          s,
        ),
        39 => (fg: 0, bg: s.bg, mods: s.mods, ulColor: s.ulColor, uri: s.uri),
        >= 40 && <= 47 => _applyExtendedColorCode(
          48,
          Color.ansi(code - 40).argb,
          s,
        ),
        49 => (fg: s.fg, bg: 0, mods: s.mods, ulColor: s.ulColor, uri: s.uri),
        53 => _withMods(s, s.mods | Modifier.overline),
        55 => _withMods(s, s.mods & ~Modifier.overline),
        59 => (fg: s.fg, bg: s.bg, mods: s.mods, ulColor: 0, uri: s.uri),
        >= 90 && <= 97 => _applyExtendedColorCode(
          38,
          Color.ansi(code - 90 + 8).argb,
          s,
        ),
        >= 100 && <= 107 => _applyExtendedColorCode(
          48,
          Color.ansi(code - 100 + 8).argb,
          s,
        ),
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
      ulColor: style.ulColor,
      uri: style.uri,
    ));
    if (w == 2) {
      _clearSplitParsedWideAt(row, col + 1);
      _putParsedCell(row, col + 1, (
        char: '',
        fg: style.fg,
        bg: style.bg,
        mods: style.mods,
        ulColor: style.ulColor,
        uri: style.uri,
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
      if (cell.ulColor != 0) buffer._setUnderlineColorAt(idx, cell.ulColor);
      if (cell.uri != null) buffer._setUriAt(idx, cell.uri);
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
    var activeStyle = _defaultToAnsiStyle;

    for (var y = 0; y < height; y++) {
      final lastCol = trimTrailingSpaces ? _lastContentCol(y) : width - 1;
      activeStyle = _writeAnsiRowCells(sb, y, lastCol, activeStyle);
      if (resetLineEndings && activeStyle != _defaultToAnsiStyle) {
        activeStyle = _resetToDefaultAnsiStyle(sb, activeStyle);
      }
      sb.write('\n');
    }

    if (activeStyle != _defaultToAnsiStyle) {
      _resetToDefaultAnsiStyle(sb, activeStyle);
    }
    return sb.toString();
  }

  static _ToAnsiStyle _resetToDefaultAnsiStyle(
    StringBuffer sb,
    _ToAnsiStyle current,
  ) {
    if (current.uri != null) {
      sb.write('\x1b]8;;\x1b\\');
    }
    if (current.fg != 0 ||
        current.bg != 0 ||
        current.mods != 0 ||
        current.ulColor != 0) {
      sb.write('\x1b[0m');
    }
    return _defaultToAnsiStyle;
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
          attributes[attrIdx + 2] == 0 &&
          (_uris == null || _uris![idx] == null);
      if (!isBlankUnstyled) return x;
    }
    return -1;
  }

  _ToAnsiStyle _writeAnsiRowCells(
    StringBuffer sb,
    int y,
    int lastCol,
    _ToAnsiStyle initialStyle,
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
        ulColor: _underlineColors == null ? 0 : _underlineColors![idx],
        uri: _uris == null ? null : _uris![idx],
      );
      activeStyle = _writeAnsiStyleTransition(sb, activeStyle, cellStyle);
      sb.write(char);
    }
    return activeStyle;
  }

  static _ToAnsiStyle _writeAnsiStyleTransition(
    StringBuffer sb,
    _ToAnsiStyle current,
    _ToAnsiStyle target,
  ) {
    if (current == target) return current;
    if (current.uri != target.uri) {
      sb.write('\x1b]8;;${sanitizeOsc8Uri(target.uri ?? '')}\x1b\\');
    }
    if (_isDefaultSgr(target)) {
      if (!_isDefaultSgr(current)) sb.write('\x1b[0m');
      return target;
    }

    final effective = _needsFullSgrReset(current, target)
        ? _emitFullSgrReset(sb, target.uri)
        : current;

    final codes = <String>[
      if (target.fg != effective.fg && target.fg != 0)
        _rgbSgrSegment(38, target.fg),
      if (target.bg != effective.bg && target.bg != 0)
        _rgbSgrSegment(48, target.bg),
      ..._collectModifierCodes(effective.mods, target.mods),
    ];

    if (codes.isNotEmpty) {
      sb
        ..write('\x1b[')
        ..write(codes.join(';'))
        ..write('m');
    }
    _emitColonSgrIfNeeded(sb, effective, target);
    return target;
  }

  static bool _isDefaultSgr(_ToAnsiStyle s) =>
      s.fg == 0 && s.bg == 0 && s.mods == Modifier.none && s.ulColor == 0;

  static List<String> _collectModifierCodes(int effMods, int tgtMods) {
    final tgtUl = Modifier.getUnderlineStyle(tgtMods);
    return [
      for (final (bit, code) in _ansiModifierSetCodes)
        if ((tgtMods & bit) != 0 &&
            (effMods & bit) == 0 &&
            (bit != Modifier.underline || tgtUl == UnderlineStyle.single))
          '$code',
    ];
  }

  static void _emitColonSgrIfNeeded(
    StringBuffer sb,
    _ToAnsiStyle effective,
    _ToAnsiStyle target,
  ) {
    final effUl = Modifier.getUnderlineStyle(effective.mods);
    final tgtUl = Modifier.getUnderlineStyle(target.mods);
    if (tgtUl != effUl && tgtUl.index >= 2) {
      sb.write('\x1b[4:${tgtUl.index}m');
    }
    if (target.ulColor != effective.ulColor && target.ulColor != 0) {
      if (target.ulColor.isAnsiIndexed) {
        sb.write('\x1b[58:5:${target.ulColor.ansiIndex}m');
        return;
      }
      final r = (target.ulColor >> 16) & 0xFF;
      final g = (target.ulColor >> 8) & 0xFF;
      final b = target.ulColor & 0xFF;
      sb.write('\x1b[58:2::$r:$g:${b}m');
    }
  }

  static bool _needsFullSgrReset(_ToAnsiStyle current, _ToAnsiStyle target) {
    const styleMask = 0xFF | Modifier.overline | Modifier.underlineStyleMask;
    final colorCleared =
        (current.fg != 0 && target.fg == 0) ||
        (current.bg != 0 && target.bg == 0) ||
        (current.ulColor != 0 && target.ulColor == 0);
    final modCleared =
        ((current.mods & styleMask) & ~(target.mods & styleMask)) != 0;
    return colorCleared || modCleared;
  }

  static _ToAnsiStyle _emitFullSgrReset(StringBuffer sb, String? uri) {
    sb.write('\x1b[0m');
    return (fg: 0, bg: 0, mods: Modifier.none, ulColor: 0, uri: uri);
  }

  static String _rgbSgrSegment(int prefix, int argb) {
    if (argb.isAnsiIndexed && (prefix == 38 || prefix == 48)) {
      return argb.ansiSgrParams(background: prefix == 48);
    }
    return '$prefix;2;${(argb >> 16) & 0xFF};${(argb >> 8) & 0xFF};${argb & 0xFF}';
  }
}
