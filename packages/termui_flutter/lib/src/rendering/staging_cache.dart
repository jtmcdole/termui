import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show listEquals;
import 'package:termui/ui/buffer.dart';
import 'package:termui/ui/glyph_cell_list.dart';
import 'package:termui/ui/terminal_palette.dart';

/// Persistent per-row staging cache and reusable typed-array pool for
/// `TuiAtlasPainter`.
///
/// Owns contiguous `Float32List` / `Int32List` draw buffers across frames,
/// hashes each row's packed cell words, selection bounds, hovered link state,
/// optional `cellOverrideMask`, and theme/atlas configuration, and compacts
/// unchanged row slices via `TypedData.setRange` so clean rows skip restaging.
final class TuiAtlasStagingCache {
  static const bool _isJsNumber = identical(0, 0.0);
  static const int _fnvPrime = _isJsNumber ? 0x10001 : 0x100000001b3;
  static const int _fnvOffset = _isJsNumber
      ? 0x811C9DC5
      : (0xCBF29CE4 << 32) | 0x84222325;
  static const int _foldShift = _isJsNumber ? 15 : 31;
  static const int _finalShiftA = _isJsNumber ? 16 : 33;
  static const int _finalShiftB = _isJsNumber ? 13 : 29;
  static const int _finalMul = _isJsNumber ? 0x10001 : 0x165667B19E377;

  final StagingCacheInternals _internals = StagingCacheInternals();

  /// Creates an empty [TuiAtlasStagingCache].
  TuiAtlasStagingCache();

  /// Grid width in columns currently allocated in this cache.
  int get cols => _internals.cols;

  /// Grid height in rows currently allocated in this cache.
  int get rows => _internals.rows;

  /// Number of clean rows served from cache during the most recent paint pass.
  int get lastRowHits => _internals.lastRowHits;

  /// Number of dirty rows freshly staged during the most recent paint pass.
  int get lastRowMisses => _internals.lastRowMisses;

  /// Monotonically increasing generation counter incremented whenever staged
  /// sprite buffers change (grid resize, invalidation, or dirty row staging).
  ///
  /// GPU backends compare this value to skip redundant vertex/instance buffer
  /// uploads on pure animation (`iTime`) frames whose terminal cells did not
  /// change.
  int get generation => _internals.generation;

  /// Ensures internal per-row metadata and backing buffers can hold a
  /// `[cols] x [rows]` grid, invalidating cached rows when dimensions change.
  void ensureGridCapacity(int cols, int rows) =>
      _internals.ensureGridCapacity(cols, rows);

  /// Marks all cached rows invalid without releasing allocated typed arrays.
  void invalidateAllRows() => _internals.invalidateAllRows();

  /// Mixes a 32-bit or 64-bit [word] into running [hash].
  @pragma('vm:prefer-inline')
  static int mixWord(int hash, int word) {
    final x = hash ^ word;
    return (x ^ (x >>> _foldShift)) * _fnvPrime;
  }

  /// Mixes two 32-bit unsigned values [a] and [b] into running [hash].
  @pragma('vm:prefer-inline')
  static int mixPair(int hash, int a, int b) {
    final combined = _isJsNumber ? (a * 0x10001) ^ b : (a << 32) | b;
    final x = hash ^ combined;
    return (x ^ (x >>> _foldShift)) * _fnvPrime;
  }

  /// Finalizes [hash] with an avalanche step.
  @pragma('vm:prefer-inline')
  static int finalizeHash(int hash) {
    var h = hash ^ (hash >>> _finalShiftA);
    h *= _finalMul;
    return h ^ (h >>> _finalShiftB);
  }

  /// Computes a row fingerprint for [row] of [buffer], mixing packed
  /// `glyphCodes`, `attributes`, `underlineColors`, optional
  /// [cellOverrideMask], [selectionHash], [hoveredLinkHash], [configHash],
  /// and optional [prevRowBgMaskHash].
  int computeRowFingerprint({
    required Buffer buffer,
    required int row,
    required int selectionHash,
    required int hoveredLinkHash,
    required int configHash,
    Uint8List? cellOverrideMask,
    int prevRowBgMaskHash = 0,
    bool mixCellUris = false,
  }) {
    final width = buffer.width;
    final rowStart = row * width;
    final rowEnd = rowStart + width;
    final codes = buffer.glyphCodes;
    final attrs = buffer.attributes;
    final glyphCells = buffer.glyphCellList;

    var h = _fnvOffset;
    h = mixWord(h, configHash);
    h = mixWord(h, selectionHash);
    h = mixWord(h, hoveredLinkHash);
    if (prevRowBgMaskHash != 0) {
      h = mixWord(h, prevRowBgMaskHash);
    }

    if (!glyphCells.hasClusters) {
      h = _hashRowFast(h, codes, attrs, rowStart, rowEnd);
    } else {
      h = _hashRowWithClusters(h, glyphCells, codes, attrs, rowStart, rowEnd);
    }
    if (buffer.hasUnderlineColors) {
      h = _hashRowUnderlineColors(h, buffer, rowStart, rowEnd);
    }
    if (cellOverrideMask != null && cellOverrideMask.isNotEmpty) {
      h = _hashRowOverrideMask(h, cellOverrideMask, rowStart, rowEnd);
    }
    if (mixCellUris && buffer.hasUris) {
      h = _hashRowUris(h, buffer, rowStart, rowEnd);
    }
    return finalizeHash(h);
  }

  @pragma('vm:prefer-inline')
  static int _hashRowFast(
    int hash,
    Uint32List codes,
    Uint32List attrs,
    int rowStart,
    int rowEnd,
  ) {
    var h = hash;
    for (var i = rowStart, a = rowStart * 3; i < rowEnd; i++, a += 3) {
      h = mixPair(h, codes[i], attrs[a]);
      h = mixPair(h, attrs[a + 1], attrs[a + 2]);
    }
    return h;
  }

  static int _hashRowWithClusters(
    int hash,
    GlyphCellList glyphCells,
    Uint32List codes,
    Uint32List attrs,
    int rowStart,
    int rowEnd,
  ) {
    var h = hash;
    for (var i = rowStart, a = rowStart * 3; i < rowEnd; i++, a += 3) {
      final rawCode = codes[i];
      final effectiveCode = (rawCode & GlyphCellList.clusterFlag) == 0
          ? rawCode
          : (GlyphCellList.clusterFlag |
                (glyphCells.decodeCode(rawCode).hashCode & 0x7FFFFFFF));
      h = mixPair(h, effectiveCode, attrs[a]);
      h = mixPair(h, attrs[a + 1], attrs[a + 2]);
    }
    return h;
  }

  static int _hashRowUnderlineColors(
    int hash,
    Buffer buffer,
    int rowStart,
    int rowEnd,
  ) {
    var h = hash;
    for (var i = rowStart; i < rowEnd; i++) {
      final ul = buffer.getUnderlineColorAt(i);
      if (ul != 0) h = mixPair(h, i - rowStart + 1, ul);
    }
    return h;
  }

  static int _hashRowOverrideMask(
    int hash,
    Uint8List mask,
    int rowStart,
    int rowEnd,
  ) {
    final limit = math.min(rowEnd, mask.length);
    var h = hash;
    for (var i = rowStart; i < limit; i++) {
      final m = mask[i];
      if (m != 0) h = mixPair(h, i - rowStart + 0x10000, m);
    }
    return h;
  }

  static int _hashRowUris(int hash, Buffer buffer, int rowStart, int rowEnd) {
    var h = hash;
    for (var i = rowStart; i < rowEnd; i++) {
      final uri = buffer.getUriAt(i);
      if (uri != null) h = mixPair(h, i - rowStart + 0x20000, uri.hashCode);
    }
    return h;
  }
}

/// Package-internal accessor exposing [TuiAtlasStagingCache]'s backing buffers
/// to `TuiAtlasPainter` without leaking internal typed arrays into the public
/// barrel API.
StagingCacheInternals stagingCacheInternalsOf(TuiAtlasStagingCache cache) =>
    cache._internals;

/// Package-internal mutable staging state owned by a [TuiAtlasStagingCache].
final class StagingCacheInternals {
  /// Grid width in columns currently allocated.
  int cols = 0;

  /// Grid height in rows currently allocated.
  int rows = 0;

  /// Cached row hits recorded on the most recent paint pass.
  int lastRowHits = 0;

  /// Dirty row misses recorded on the most recent paint pass.
  int lastRowMisses = 0;

  /// Monotonic counter incremented when staged sprite contents change.
  int generation = 0;

  StagingBufferSet _active = StagingBufferSet();
  StagingBufferSet? _spare;

  /// Active contiguous sprite and per-row slice buffers for the current frame.
  StagingBufferSet get active => _active;

  /// Per-cell non-default background mask (`cols * rows`) for `enableBleed`.
  Uint8List nonDefaultBgMask = Uint8List(0);

  /// Cached per-row full fingerprints (including predecessor bleed hash).
  List<int> rowFingerprints = const [];

  /// Cached per-row cell-content fingerprints (excluding predecessor bleed).
  List<int> rowContentFingerprints = const [];

  /// Cached per-row non-default background mask hashes for `enableBleed`.
  List<int> rowBgMaskHashes = const [];

  /// Per-row validity flags (`0 = invalid`, `1 = valid`).
  Uint8List rowValid = Uint8List(0);

  /// Inclusive starting selection column per row (`-1` when unselected).
  Int32List rowSelStart = Int32List(0);

  /// Inclusive ending selection column per row (`-2` when unselected).
  Int32List rowSelEnd = Int32List(0);

  /// Precomputed per-row selection span hash.
  Int32List rowSelHash = Int32List(0);

  /// Inclusive starting hovered-link column per row (`-1` when none).
  Int32List rowLinkStart = Int32List(0);

  /// Inclusive ending hovered-link column per row (`-2` when none).
  Int32List rowLinkEnd = Int32List(0);

  /// Base index into `HoveredLinkCellStyles` for each hovered-link row.
  Int32List rowLinkBaseOffset = Int32List(0);

  /// Precomputed per-row hovered-link override hash.
  List<int> rowLinkHash = const [];

  /// Per-row cache-hit flags for the current paint pass (`0 = miss`, `1 = hit`).
  Uint8List rowIsClean = Uint8List(0);

  /// Scratch full fingerprints computed for the current paint pass.
  List<int> nextFullFingerprints = const [];

  /// Scratch content-only fingerprints computed for the current paint pass.
  List<int> nextContentFingerprints = const [];

  TerminalColorTheme? _lastPalette;
  int _lastPaletteHash = 0;
  List<String>? _lastFontFallback;
  int _lastFontFallbackHash = 0;

  /// Returns the cached hash for [palette], avoiding per-frame list hashing.
  int hashPalette(TerminalColorTheme palette) {
    if (!identical(palette, _lastPalette)) {
      _lastPalette = palette;
      _lastPaletteHash = palette.hashCode;
    }
    return _lastPaletteHash;
  }

  /// Returns the cached hash for [fallback], avoiding per-frame list hashing.
  int hashFontFallback(List<String>? fallback) {
    if (fallback == null) return 0;
    if (!identical(fallback, _lastFontFallback)) {
      if (_lastFontFallback == null ||
          !listEquals(_lastFontFallback, fallback)) {
        _lastFontFallbackHash = Object.hashAll(fallback);
      }
      _lastFontFallback = fallback;
    }
    return _lastFontFallbackHash;
  }

  /// Ensures per-row metadata and active staging arrays fit `[newCols] x [newRows]`.
  void ensureGridCapacity(int newCols, int newRows) {
    final safeCols = math.max(0, newCols);
    final safeRows = math.max(0, newRows);
    if (safeCols == cols && safeRows == rows) return;

    cols = safeCols;
    rows = safeRows;
    final cellCount = safeCols * safeRows;
    nonDefaultBgMask = Uint8List(cellCount);
    rowFingerprints = List<int>.filled(safeRows, 0);
    rowContentFingerprints = List<int>.filled(safeRows, 0);
    rowBgMaskHashes = List<int>.filled(safeRows, 0);
    rowValid = Uint8List(safeRows);

    rowSelStart = Int32List(safeRows);
    rowSelEnd = Int32List(safeRows);
    rowSelHash = Int32List(safeRows);
    rowLinkStart = Int32List(safeRows);
    rowLinkEnd = Int32List(safeRows);
    rowLinkBaseOffset = Int32List(safeRows);
    rowLinkHash = List<int>.filled(safeRows, 0);
    rowIsClean = Uint8List(safeRows);
    nextFullFingerprints = List<int>.filled(safeRows, 0);
    nextContentFingerprints = List<int>.filled(safeRows, 0);

    _active.ensureGridCapacity(safeRows, cellCount);
    _spare?.ensureRowCapacity(safeRows);
    generation++;
  }

  /// Marks every row invalid without reallocating backing buffers.
  void invalidateAllRows() {
    if (rowValid.isNotEmpty) {
      rowValid.fillRange(0, rowValid.length, 0);
    }
    generation++;
  }

  /// Whether [row] is valid and matches [fullFingerprint].
  @pragma('vm:prefer-inline')
  bool isRowClean(int row, int fullFingerprint) =>
      rowValid[row] != 0 && rowFingerprints[row] == fullFingerprint;

  /// Whether [row] is valid and its own cell content matches [contentFingerprint].
  @pragma('vm:prefer-inline')
  bool isRowContentClean(int row, int contentFingerprint) =>
      rowValid[row] != 0 && rowContentFingerprints[row] == contentFingerprint;

  /// Records a full cache-hit frame without touching sprite arrays.
  void recordAllHits(int rowCount) {
    lastRowHits = rowCount;
    lastRowMisses = 0;
  }

  /// Prepares [active] for in-place tail updates starting at [firstDirtyRow].
  StagingBufferSet beginTailUpdate(int firstDirtyRow) {
    if (firstDirtyRow <= 0) {
      _active.resetCounts();
    } else {
      _active.truncateAfterRow(firstDirtyRow - 1);
    }
    return _active;
  }

  /// Prepares the spare buffer set for interior row compaction.
  StagingBufferSet beginCompaction() {
    final spare = _spare ??= StagingBufferSet();
    spare
      ..ensureRowCapacity(rows)
      ..resetCounts();
    return spare;
  }

  /// Promotes the compacted spare buffer set to [active].
  void finishCompaction() {
    final prev = _active;
    _active = _spare!;
    _spare = prev;
  }

  /// Commits all per-row fingerprints and hit/miss counters after staging.
  void commitFrame(int rowCount, int hits, int misses) {
    for (var y = 0; y < rowCount; y++) {
      rowFingerprints[y] = nextFullFingerprints[y];
      rowContentFingerprints[y] = nextContentFingerprints[y];
      rowValid[y] = 1;
    }
    lastRowHits = hits;
    lastRowMisses = misses;
    if (misses > 0) {
      generation++;
    }
  }
}

/// Reusable contiguous typed-array buffers and per-row slice tables for one
/// staged frame of `TuiAtlasPainter`.
final class StagingBufferSet {
  /// Packed `RSTransform` values for background sprites (`4` floats/sprite).
  Float32List bgTransforms = Float32List(0);

  /// Packed source LTRB texel coordinates for background sprites.
  Float32List bgRects = Float32List(0);

  /// Packed ARGB tint colors for background sprites.
  Int32List bgColors = Int32List(0);
  int _bgCap = 0;

  /// Active number of staged background sprites.
  int bgCount = 0;

  /// Starting sprite index in the bg arrays for each row.
  Int32List rowBgStart = Int32List(0);

  /// Sprite count in the bg arrays for each row.
  Int32List rowBgCount = Int32List(0);

  /// Packed `RSTransform` values for foreground/decoration sprites.
  Float32List fgTransforms = Float32List(0);

  /// Packed source LTRB texel coordinates for foreground/decoration sprites.
  Float32List fgRects = Float32List(0);

  /// Packed ARGB tint colors for foreground/decoration sprites.
  Int32List fgColors = Int32List(0);
  int _fgCap = 0;

  /// Active number of staged foreground and decoration sprites.
  int fgCount = 0;

  /// Starting sprite index in the fg arrays for each row.
  Int32List rowFgStart = Int32List(0);

  /// Sprite count in the fg arrays for each row.
  Int32List rowFgCount = Int32List(0);

  /// Packed `RSTransform` values for batched cell decoration sprites.
  Float32List decoTransforms = Float32List(0);

  /// Packed source LTRB texel coordinates for batched cell decoration sprites.
  Float32List decoRects = Float32List(0);

  /// Packed ARGB tint colors for batched cell decoration sprites.
  Int32List decoColors = Int32List(0);
  int _decoCap = 0;

  /// Active number of staged cell decoration sprites.
  int decoCount = 0;

  /// Starting sprite index in the decoration arrays for each row.
  Int32List rowDecoStart = Int32List(0);

  /// Sprite count in the decoration arrays for each row.
  Int32List rowDecoCount = Int32List(0);

  /// Packed `RSTransform` values for color emoji sprites.
  Float32List emojiTransforms = Float32List(0);

  /// Packed source LTRB texel coordinates for color emoji sprites.
  Float32List emojiRects = Float32List(0);
  int _emojiCap = 0;

  /// Active number of staged color emoji sprites.
  int emojiCount = 0;

  /// Starting sprite index in the emoji arrays for each row.
  Int32List rowEmojiStart = Int32List(0);

  /// Sprite count in the emoji arrays for each row.
  Int32List rowEmojiCount = Int32List(0);

  /// Packed source LTRB texel rects for synthetic-skewed italic atlas cells.
  Float32List italicSrcRects = Float32List(0);

  /// Packed `(x, y)` logical coordinates for synthetic italic atlas cells.
  Float32List italicPositions = Float32List(0);

  /// Packed ARGB tint colors for synthetic italic atlas cells.
  Int32List italicColors = Int32List(0);

  /// Packed bit flags (`bit 0 = isBold`) for synthetic italic atlas cells.
  Uint8List italicFlags = Uint8List(0);
  int _italicCap = 0;

  /// Active number of staged synthetic italic atlas cells.
  int italicCount = 0;

  /// Starting entry index in the italic arrays for each row.
  Int32List rowItalicStart = Int32List(0);

  /// Entry count in the italic arrays for each row.
  Int32List rowItalicCount = Int32List(0);

  /// Reusable list of grapheme strings for unbaked fallback / Kitty cells.
  final List<String> fallbackChars = <String>[];

  /// Packed `(gridCol, gridRow)` coordinates for fallback / Kitty cells.
  Int32List fallbackGridCoords = Int32List(0);

  /// Packed `(modifiers, fgArgb, bgArgb, resolvedFg)` tuples for fallback cells.
  Int32List fallbackAttrs = Int32List(0);

  /// Packed `(x, y, w, h)` logical bounds for fallback / Kitty cells.
  Float32List fallbackRects = Float32List(0);
  int _fallbackCap = 0;

  /// Active number of staged fallback / Kitty cells.
  int fallbackCount = 0;

  /// Starting entry index in the fallback arrays for each row.
  Int32List rowFallbackStart = Int32List(0);

  /// Entry count in the fallback arrays for each row.
  Int32List rowFallbackCount = Int32List(0);

  /// Reusable list of ligature run strings for non-prebaked ligatures.
  final List<String> ligatureTexts = <String>[];

  /// Packed `(x, y, w, h)` logical bounds for fallback ligature runs.
  Float32List ligatureRects = Float32List(0);

  /// Packed ARGB foreground colors for fallback ligature runs.
  Int32List ligatureColors = Int32List(0);

  /// Packed bit flags (`bit 0 = isBold`, `bit 1 = isItalic`) for ligature runs.
  Uint8List ligatureFlags = Uint8List(0);
  int _ligatureCap = 0;

  /// Active number of staged fallback ligature runs.
  int ligatureCount = 0;

  /// Starting entry index in the ligature arrays for each row.
  Int32List rowLigatureStart = Int32List(0);

  /// Entry count in the ligature arrays for each row.
  Int32List rowLigatureCount = Int32List(0);

  /// Reusable list of unbaked plain glyph strings for post-frame callback.
  final List<String> missingGlyphs = <String>[];

  /// Active number of staged missing plain glyphs.
  int missingGlyphCount = 0;

  /// Starting entry index in [missingGlyphs] for each row.
  Int32List rowMissingStart = Int32List(0);

  /// Entry count in [missingGlyphs] for each row.
  Int32List rowMissingCount = Int32List(0);

  /// Reusable list of unbaked styled glyph strings for post-frame callback.
  final List<String> missingStyledChars = <String>[];

  /// `GlyphStyleVariant.index` values parallel to [missingStyledChars].
  Uint8List missingStyledVariants = Uint8List(0);
  int _missingStyledCap = 0;

  /// Active number of staged missing styled glyph pairs.
  int missingStyledCount = 0;

  /// Starting entry index in [missingStyledChars] for each row.
  Int32List rowMissingStyledStart = Int32List(0);

  /// Entry count in [missingStyledChars] for each row.
  Int32List rowMissingStyledCount = Int32List(0);

  /// Ensures row slice tables and baseline bg/fg sprite capacities fit.
  void ensureGridCapacity(int rows, int cellCount) {
    ensureRowCapacity(rows);
    if (cellCount > _bgCap) {
      ensureBgCapacity(cellCount);
    }
    if (cellCount * 2 > _fgCap) {
      ensureFgCapacity(cellCount * 2);
    }
  }

  /// Ensures per-row slice start/count tables fit [rows].
  void ensureRowCapacity(int rows) {
    if (rowBgStart.length >= rows) return;
    rowBgStart = Int32List(rows);
    rowBgCount = Int32List(rows);
    rowFgStart = Int32List(rows);
    rowFgCount = Int32List(rows);
    rowDecoStart = Int32List(rows);
    rowDecoCount = Int32List(rows);
    rowEmojiStart = Int32List(rows);
    rowEmojiCount = Int32List(rows);
    rowItalicStart = Int32List(rows);
    rowItalicCount = Int32List(rows);
    rowFallbackStart = Int32List(rows);
    rowFallbackCount = Int32List(rows);
    rowLigatureStart = Int32List(rows);
    rowLigatureCount = Int32List(rows);
    rowMissingStart = Int32List(rows);
    rowMissingCount = Int32List(rows);
    rowMissingStyledStart = Int32List(rows);
    rowMissingStyledCount = Int32List(rows);
  }

  /// Resets all logical sprite/entry counts to zero without reallocating.
  void resetCounts() {
    bgCount = 0;
    fgCount = 0;
    decoCount = 0;
    emojiCount = 0;
    italicCount = 0;
    fallbackCount = 0;
    ligatureCount = 0;
    missingGlyphCount = 0;
    missingStyledCount = 0;
  }

  /// Truncates all logical counts to the end of [row], retaining rows `0..row`.
  void truncateAfterRow(int row) {
    bgCount = rowBgStart[row] + rowBgCount[row];
    fgCount = rowFgStart[row] + rowFgCount[row];
    decoCount = rowDecoStart[row] + rowDecoCount[row];
    emojiCount = rowEmojiStart[row] + rowEmojiCount[row];
    italicCount = rowItalicStart[row] + rowItalicCount[row];
    fallbackCount = rowFallbackStart[row] + rowFallbackCount[row];
    ligatureCount = rowLigatureStart[row] + rowLigatureCount[row];
    missingGlyphCount = rowMissingStart[row] + rowMissingCount[row];
    missingStyledCount =
        rowMissingStyledStart[row] + rowMissingStyledCount[row];
  }

  /// Marks the start offset of [row] across all staging channels.
  @pragma('vm:prefer-inline')
  void beginRow(int row) {
    rowBgStart[row] = bgCount;
    rowFgStart[row] = fgCount;
    rowDecoStart[row] = decoCount;
    rowEmojiStart[row] = emojiCount;
    rowItalicStart[row] = italicCount;
    rowFallbackStart[row] = fallbackCount;
    rowLigatureStart[row] = ligatureCount;
    rowMissingStart[row] = missingGlyphCount;
    rowMissingStyledStart[row] = missingStyledCount;
  }

  /// Finalizes the per-row sprite/entry counts for [row].
  @pragma('vm:prefer-inline')
  void endRow(int row) {
    rowBgCount[row] = bgCount - rowBgStart[row];
    rowFgCount[row] = fgCount - rowFgStart[row];
    rowDecoCount[row] = decoCount - rowDecoStart[row];
    rowEmojiCount[row] = emojiCount - rowEmojiStart[row];
    rowItalicCount[row] = italicCount - rowItalicStart[row];
    rowFallbackCount[row] = fallbackCount - rowFallbackStart[row];
    rowLigatureCount[row] = ligatureCount - rowLigatureStart[row];
    rowMissingCount[row] = missingGlyphCount - rowMissingStart[row];
    rowMissingStyledCount[row] =
        missingStyledCount - rowMissingStyledStart[row];
  }

  static int _grownCapacity(int current, int required, int minCapacity) {
    var cap = current < minCapacity ? minCapacity : current;
    while (cap < required) {
      cap <<= 1;
    }
    return cap;
  }

  static Float32List _growFloat32(Float32List old, int newLen, int copyLen) {
    final next = Float32List(newLen);
    if (copyLen > 0) next.setRange(0, copyLen, old);
    return next;
  }

  static Int32List _growInt32(Int32List old, int newLen, int copyLen) {
    final next = Int32List(newLen);
    if (copyLen > 0) next.setRange(0, copyLen, old);
    return next;
  }

  static Uint8List _growUint8(Uint8List old, int newLen, int copyLen) {
    final next = Uint8List(newLen);
    if (copyLen > 0) next.setRange(0, copyLen, old);
    return next;
  }

  /// Ensures capacity for at least [required] background sprites.
  void ensureBgCapacity(int required) {
    if (required <= _bgCap) return;
    final nextCap = _grownCapacity(_bgCap, required, 64);
    bgTransforms = _growFloat32(bgTransforms, nextCap * 4, bgCount * 4);
    bgRects = _growFloat32(bgRects, nextCap * 4, bgCount * 4);
    bgColors = _growInt32(bgColors, nextCap, bgCount);
    _bgCap = nextCap;
  }

  /// Ensures capacity for at least [required] foreground sprites.
  void ensureFgCapacity(int required) {
    if (required <= _fgCap) return;
    final nextCap = _grownCapacity(_fgCap, required, 128);
    fgTransforms = _growFloat32(fgTransforms, nextCap * 4, fgCount * 4);
    fgRects = _growFloat32(fgRects, nextCap * 4, fgCount * 4);
    fgColors = _growInt32(fgColors, nextCap, fgCount);
    _fgCap = nextCap;
  }

  /// Ensures capacity for at least [required] decoration sprites.
  void ensureDecoCapacity(int required) {
    if (required <= _decoCap) return;
    final nextCap = _grownCapacity(_decoCap, required, 64);
    decoTransforms = _growFloat32(decoTransforms, nextCap * 4, decoCount * 4);
    decoRects = _growFloat32(decoRects, nextCap * 4, decoCount * 4);
    decoColors = _growInt32(decoColors, nextCap, decoCount);
    _decoCap = nextCap;
  }

  /// Ensures capacity for at least [required] emoji sprites.
  void ensureEmojiCapacity(int required) {
    if (required <= _emojiCap) return;
    final nextCap = _grownCapacity(_emojiCap, required, 16);
    emojiTransforms = _growFloat32(
      emojiTransforms,
      nextCap * 4,
      emojiCount * 4,
    );
    emojiRects = _growFloat32(emojiRects, nextCap * 4, emojiCount * 4);
    _emojiCap = nextCap;
  }

  /// Ensures capacity for at least [required] synthetic italic atlas cells.
  void ensureItalicCapacity(int required) {
    if (required <= _italicCap) return;
    final nextCap = _grownCapacity(_italicCap, required, 16);
    italicSrcRects = _growFloat32(italicSrcRects, nextCap * 4, italicCount * 4);
    italicPositions = _growFloat32(
      italicPositions,
      nextCap * 2,
      italicCount * 2,
    );
    italicColors = _growInt32(italicColors, nextCap, italicCount);
    italicFlags = _growUint8(italicFlags, nextCap, italicCount);
    _italicCap = nextCap;
  }

  /// Ensures capacity for at least [required] fallback / Kitty cells.
  void ensureFallbackCapacity(int required) {
    if (required <= _fallbackCap) return;
    final nextCap = _grownCapacity(_fallbackCap, required, 16);
    fallbackGridCoords = _growInt32(
      fallbackGridCoords,
      nextCap * 2,
      fallbackCount * 2,
    );
    fallbackAttrs = _growInt32(fallbackAttrs, nextCap * 4, fallbackCount * 4);
    fallbackRects = _growFloat32(fallbackRects, nextCap * 4, fallbackCount * 4);
    _fallbackCap = nextCap;
  }

  /// Ensures capacity for at least [required] fallback ligature runs.
  void ensureLigatureCapacity(int required) {
    if (required <= _ligatureCap) return;
    final nextCap = _grownCapacity(_ligatureCap, required, 16);
    ligatureRects = _growFloat32(ligatureRects, nextCap * 4, ligatureCount * 4);
    ligatureColors = _growInt32(ligatureColors, nextCap, ligatureCount);
    ligatureFlags = _growUint8(ligatureFlags, nextCap, ligatureCount);
    _ligatureCap = nextCap;
  }

  void _ensureMissingStyledCapacity(int required) {
    if (required <= _missingStyledCap) return;
    final nextCap = _grownCapacity(_missingStyledCap, required, 16);
    missingStyledVariants = _growUint8(
      missingStyledVariants,
      nextCap,
      missingStyledCount,
    );
    _missingStyledCap = nextCap;
  }

  /// Appends one background sprite to the bg batch.
  @pragma('vm:prefer-inline')
  void addBgSprite(
    double scale,
    double tx,
    double ty,
    double l,
    double t,
    double r,
    double b,
    int color,
  ) {
    final idx = bgCount;
    if (idx >= _bgCap) ensureBgCapacity(idx + 1);
    final base = idx << 2;
    bgTransforms[base] = scale;
    bgTransforms[base + 1] = 0.0;
    bgTransforms[base + 2] = tx;
    bgTransforms[base + 3] = ty;
    bgRects[base] = l;
    bgRects[base + 1] = t;
    bgRects[base + 2] = r;
    bgRects[base + 3] = b;
    bgColors[idx] = color;
    bgCount = idx + 1;
  }

  /// Appends one foreground glyph sprite to the fg batch.
  @pragma('vm:prefer-inline')
  void addFgSprite(
    double scale,
    double tx,
    double ty,
    double l,
    double t,
    double r,
    double b,
    int color,
  ) {
    final idx = fgCount;
    if (idx >= _fgCap) ensureFgCapacity(idx + 1);
    final base = idx << 2;
    fgTransforms[base] = scale;
    fgTransforms[base + 1] = 0.0;
    fgTransforms[base + 2] = tx;
    fgTransforms[base + 3] = ty;
    fgRects[base] = l;
    fgRects[base + 1] = t;
    fgRects[base + 2] = r;
    fgRects[base + 3] = b;
    fgColors[idx] = color;
    fgCount = idx + 1;
  }

  /// Appends one cell decoration sprite (underline, overline, strikethrough)
  /// to the decoration batch drawn over all glyph passes.
  @pragma('vm:prefer-inline')
  void addDecoSprite(
    double scale,
    double tx,
    double ty,
    double l,
    double t,
    double r,
    double b,
    int color,
  ) {
    final idx = decoCount;
    if (idx >= _decoCap) ensureDecoCapacity(idx + 1);
    final base = idx << 2;
    decoTransforms[base] = scale;
    decoTransforms[base + 1] = 0.0;
    decoTransforms[base + 2] = tx;
    decoTransforms[base + 3] = ty;
    decoRects[base] = l;
    decoRects[base + 1] = t;
    decoRects[base + 2] = r;
    decoRects[base + 3] = b;
    decoColors[idx] = color;
    decoCount = idx + 1;
  }

  /// Appends one color emoji sprite to the emoji batch.
  @pragma('vm:prefer-inline')
  void addEmojiSprite(
    double scale,
    double tx,
    double ty,
    double l,
    double t,
    double r,
    double b,
  ) {
    final idx = emojiCount;
    if (idx >= _emojiCap) ensureEmojiCapacity(idx + 1);
    final base = idx << 2;
    emojiTransforms[base] = scale;
    emojiTransforms[base + 1] = 0.0;
    emojiTransforms[base + 2] = tx;
    emojiTransforms[base + 3] = ty;
    emojiRects[base] = l;
    emojiRects[base + 1] = t;
    emojiRects[base + 2] = r;
    emojiRects[base + 3] = b;
    emojiCount = idx + 1;
  }

  /// Appends one synthetic-skewed italic atlas cell.
  void addItalicCell(
    double l,
    double t,
    double r,
    double b,
    double x,
    double y,
    int color, {
    required bool isBold,
  }) {
    final idx = italicCount;
    if (idx >= _italicCap) ensureItalicCapacity(idx + 1);
    final rBase = idx << 2;
    italicSrcRects[rBase] = l;
    italicSrcRects[rBase + 1] = t;
    italicSrcRects[rBase + 2] = r;
    italicSrcRects[rBase + 3] = b;
    final pBase = idx << 1;
    italicPositions[pBase] = x;
    italicPositions[pBase + 1] = y;
    italicColors[idx] = color;
    italicFlags[idx] = isBold ? 1 : 0;
    italicCount = idx + 1;
  }

  /// Appends one unbaked fallback or Kitty placeholder cell.
  void addFallbackCell({
    required String char,
    required int gridCol,
    required int gridRow,
    required int modifiers,
    required int fgArgb,
    required int bgArgb,
    required int resolvedFg,
    required double x,
    required double y,
    required double w,
    required double h,
  }) {
    final idx = fallbackCount;
    if (idx >= _fallbackCap) ensureFallbackCapacity(idx + 1);
    _writeStringSlot(fallbackChars, idx, char);
    final gBase = idx << 1;
    fallbackGridCoords[gBase] = gridCol;
    fallbackGridCoords[gBase + 1] = gridRow;
    final aBase = idx << 2;
    fallbackAttrs[aBase] = modifiers;
    fallbackAttrs[aBase + 1] = fgArgb;
    fallbackAttrs[aBase + 2] = bgArgb;
    fallbackAttrs[aBase + 3] = resolvedFg;
    fallbackRects[aBase] = x;
    fallbackRects[aBase + 1] = y;
    fallbackRects[aBase + 2] = w;
    fallbackRects[aBase + 3] = h;
    fallbackCount = idx + 1;
  }

  /// Appends one non-prebaked multi-cell ligature run.
  void addLigatureCell({
    required String text,
    required double x,
    required double y,
    required double w,
    required double h,
    required int resolvedFg,
    required bool isBold,
    required bool isItalic,
  }) {
    final idx = ligatureCount;
    if (idx >= _ligatureCap) ensureLigatureCapacity(idx + 1);
    _writeStringSlot(ligatureTexts, idx, text);
    final rBase = idx << 2;
    ligatureRects[rBase] = x;
    ligatureRects[rBase + 1] = y;
    ligatureRects[rBase + 2] = w;
    ligatureRects[rBase + 3] = h;
    ligatureColors[idx] = resolvedFg;
    ligatureFlags[idx] = (isBold ? 1 : 0) | (isItalic ? 2 : 0);
    ligatureCount = idx + 1;
  }

  /// Records a missing plain glyph string for post-frame callback dispatch.
  void addMissingGlyph(String char) {
    _writeStringSlot(missingGlyphs, missingGlyphCount++, char);
  }

  /// Records a missing styled `(char, variantIndex)` pair for post-frame callback dispatch.
  void addMissingStyledGlyph(String char, int variantIndex) {
    final idx = missingStyledCount;
    if (idx >= _missingStyledCap) _ensureMissingStyledCapacity(idx + 1);
    _writeStringSlot(missingStyledChars, idx, char);
    missingStyledVariants[idx] = variantIndex;
    missingStyledCount = idx + 1;
  }

  static void _writeStringSlot(List<String> list, int index, String value) {
    if (index < list.length) {
      list[index] = value;
    } else {
      list.add(value);
    }
  }

  static void _copyStringRange(
    List<String> dst,
    int dstStart,
    List<String> src,
    int srcStart,
    int count,
  ) {
    final required = dstStart + count;
    while (dst.length < required) {
      dst.add('');
    }
    dst.setRange(dstStart, required, src, srcStart);
  }

  static void _shiftRowSliceTable(
    Int32List dstStart,
    Int32List dstCount,
    Int32List srcStart,
    Int32List srcCount,
    int startRow,
    int endRow,
    int delta,
  ) {
    for (var y = startRow; y < endRow; y++) {
      dstStart[y] = srcStart[y] + delta;
      dstCount[y] = srcCount[y];
    }
  }

  /// Copies a contiguous range `[startRow, endRow)` of clean rows from [src]
  /// into this buffer set via batched `setRange` copies.
  void copyCleanRowRange(StagingBufferSet src, int startRow, int endRow) {
    _copyBgRun(src, startRow, endRow);
    _copyFgRun(src, startRow, endRow);
    _copyDecoRun(src, startRow, endRow);
    _copyEmojiRun(src, startRow, endRow);
    _copyItalicRun(src, startRow, endRow);
    _copyFallbackRun(src, startRow, endRow);
    _copyLigatureRun(src, startRow, endRow);
    _copyMissingRun(src, startRow, endRow);
    _copyMissingStyledRun(src, startRow, endRow);
  }

  void _copyBgRun(StagingBufferSet src, int startRow, int endRow) {
    final srcStart = src.rowBgStart[startRow];
    final last = endRow - 1;
    final count = (src.rowBgStart[last] + src.rowBgCount[last]) - srcStart;
    final dstStart = bgCount;
    if (count > 0) {
      ensureBgCapacity(dstStart + count);
      bgTransforms.setRange(
        dstStart << 2,
        (dstStart + count) << 2,
        src.bgTransforms,
        srcStart << 2,
      );
      bgRects.setRange(
        dstStart << 2,
        (dstStart + count) << 2,
        src.bgRects,
        srcStart << 2,
      );
      bgColors.setRange(dstStart, dstStart + count, src.bgColors, srcStart);
      bgCount = dstStart + count;
    }
    _shiftRowSliceTable(
      rowBgStart,
      rowBgCount,
      src.rowBgStart,
      src.rowBgCount,
      startRow,
      endRow,
      dstStart - srcStart,
    );
  }

  void _copyFgRun(StagingBufferSet src, int startRow, int endRow) {
    final srcStart = src.rowFgStart[startRow];
    final last = endRow - 1;
    final count = (src.rowFgStart[last] + src.rowFgCount[last]) - srcStart;
    final dstStart = fgCount;
    if (count > 0) {
      ensureFgCapacity(dstStart + count);
      fgTransforms.setRange(
        dstStart << 2,
        (dstStart + count) << 2,
        src.fgTransforms,
        srcStart << 2,
      );
      fgRects.setRange(
        dstStart << 2,
        (dstStart + count) << 2,
        src.fgRects,
        srcStart << 2,
      );
      fgColors.setRange(dstStart, dstStart + count, src.fgColors, srcStart);
      fgCount = dstStart + count;
    }
    _shiftRowSliceTable(
      rowFgStart,
      rowFgCount,
      src.rowFgStart,
      src.rowFgCount,
      startRow,
      endRow,
      dstStart - srcStart,
    );
  }

  void _copyDecoRun(StagingBufferSet src, int startRow, int endRow) {
    final srcStart = src.rowDecoStart[startRow];
    final last = endRow - 1;
    final count = (src.rowDecoStart[last] + src.rowDecoCount[last]) - srcStart;
    final dstStart = decoCount;
    if (count > 0) {
      ensureDecoCapacity(dstStart + count);
      decoTransforms.setRange(
        dstStart << 2,
        (dstStart + count) << 2,
        src.decoTransforms,
        srcStart << 2,
      );
      decoRects.setRange(
        dstStart << 2,
        (dstStart + count) << 2,
        src.decoRects,
        srcStart << 2,
      );
      decoColors.setRange(dstStart, dstStart + count, src.decoColors, srcStart);
      decoCount = dstStart + count;
    }
    _shiftRowSliceTable(
      rowDecoStart,
      rowDecoCount,
      src.rowDecoStart,
      src.rowDecoCount,
      startRow,
      endRow,
      dstStart - srcStart,
    );
  }

  void _copyEmojiRun(StagingBufferSet src, int startRow, int endRow) {
    final srcStart = src.rowEmojiStart[startRow];
    final last = endRow - 1;
    final count =
        (src.rowEmojiStart[last] + src.rowEmojiCount[last]) - srcStart;
    final dstStart = emojiCount;
    if (count > 0) {
      ensureEmojiCapacity(dstStart + count);
      emojiTransforms.setRange(
        dstStart << 2,
        (dstStart + count) << 2,
        src.emojiTransforms,
        srcStart << 2,
      );
      emojiRects.setRange(
        dstStart << 2,
        (dstStart + count) << 2,
        src.emojiRects,
        srcStart << 2,
      );
      emojiCount = dstStart + count;
    }
    _shiftRowSliceTable(
      rowEmojiStart,
      rowEmojiCount,
      src.rowEmojiStart,
      src.rowEmojiCount,
      startRow,
      endRow,
      dstStart - srcStart,
    );
  }

  void _copyItalicRun(StagingBufferSet src, int startRow, int endRow) {
    final srcStart = src.rowItalicStart[startRow];
    final last = endRow - 1;
    final count =
        (src.rowItalicStart[last] + src.rowItalicCount[last]) - srcStart;
    final dstStart = italicCount;
    if (count > 0) {
      ensureItalicCapacity(dstStart + count);
      italicSrcRects.setRange(
        dstStart << 2,
        (dstStart + count) << 2,
        src.italicSrcRects,
        srcStart << 2,
      );
      italicPositions.setRange(
        dstStart << 1,
        (dstStart + count) << 1,
        src.italicPositions,
        srcStart << 1,
      );
      italicColors.setRange(
        dstStart,
        dstStart + count,
        src.italicColors,
        srcStart,
      );
      italicFlags.setRange(
        dstStart,
        dstStart + count,
        src.italicFlags,
        srcStart,
      );
      italicCount = dstStart + count;
    }
    _shiftRowSliceTable(
      rowItalicStart,
      rowItalicCount,
      src.rowItalicStart,
      src.rowItalicCount,
      startRow,
      endRow,
      dstStart - srcStart,
    );
  }

  void _copyFallbackRun(StagingBufferSet src, int startRow, int endRow) {
    final srcStart = src.rowFallbackStart[startRow];
    final last = endRow - 1;
    final count =
        (src.rowFallbackStart[last] + src.rowFallbackCount[last]) - srcStart;
    final dstStart = fallbackCount;
    if (count > 0) {
      ensureFallbackCapacity(dstStart + count);
      _copyStringRange(
        fallbackChars,
        dstStart,
        src.fallbackChars,
        srcStart,
        count,
      );
      fallbackGridCoords.setRange(
        dstStart << 1,
        (dstStart + count) << 1,
        src.fallbackGridCoords,
        srcStart << 1,
      );
      fallbackAttrs.setRange(
        dstStart << 2,
        (dstStart + count) << 2,
        src.fallbackAttrs,
        srcStart << 2,
      );
      fallbackRects.setRange(
        dstStart << 2,
        (dstStart + count) << 2,
        src.fallbackRects,
        srcStart << 2,
      );
      fallbackCount = dstStart + count;
    }
    _shiftRowSliceTable(
      rowFallbackStart,
      rowFallbackCount,
      src.rowFallbackStart,
      src.rowFallbackCount,
      startRow,
      endRow,
      dstStart - srcStart,
    );
  }

  void _copyLigatureRun(StagingBufferSet src, int startRow, int endRow) {
    final srcStart = src.rowLigatureStart[startRow];
    final last = endRow - 1;
    final count =
        (src.rowLigatureStart[last] + src.rowLigatureCount[last]) - srcStart;
    final dstStart = ligatureCount;
    if (count > 0) {
      ensureLigatureCapacity(dstStart + count);
      _copyStringRange(
        ligatureTexts,
        dstStart,
        src.ligatureTexts,
        srcStart,
        count,
      );
      ligatureRects.setRange(
        dstStart << 2,
        (dstStart + count) << 2,
        src.ligatureRects,
        srcStart << 2,
      );
      ligatureColors.setRange(
        dstStart,
        dstStart + count,
        src.ligatureColors,
        srcStart,
      );
      ligatureFlags.setRange(
        dstStart,
        dstStart + count,
        src.ligatureFlags,
        srcStart,
      );
      ligatureCount = dstStart + count;
    }
    _shiftRowSliceTable(
      rowLigatureStart,
      rowLigatureCount,
      src.rowLigatureStart,
      src.rowLigatureCount,
      startRow,
      endRow,
      dstStart - srcStart,
    );
  }

  void _copyMissingRun(StagingBufferSet src, int startRow, int endRow) {
    final srcStart = src.rowMissingStart[startRow];
    final last = endRow - 1;
    final count =
        (src.rowMissingStart[last] + src.rowMissingCount[last]) - srcStart;
    final dstStart = missingGlyphCount;
    if (count > 0) {
      _copyStringRange(
        missingGlyphs,
        dstStart,
        src.missingGlyphs,
        srcStart,
        count,
      );
      missingGlyphCount = dstStart + count;
    }
    _shiftRowSliceTable(
      rowMissingStart,
      rowMissingCount,
      src.rowMissingStart,
      src.rowMissingCount,
      startRow,
      endRow,
      dstStart - srcStart,
    );
  }

  void _copyMissingStyledRun(StagingBufferSet src, int startRow, int endRow) {
    final srcStart = src.rowMissingStyledStart[startRow];
    final last = endRow - 1;
    final count =
        (src.rowMissingStyledStart[last] + src.rowMissingStyledCount[last]) -
        srcStart;
    final dstStart = missingStyledCount;
    if (count > 0) {
      _ensureMissingStyledCapacity(dstStart + count);
      _copyStringRange(
        missingStyledChars,
        dstStart,
        src.missingStyledChars,
        srcStart,
        count,
      );
      missingStyledVariants.setRange(
        dstStart,
        dstStart + count,
        src.missingStyledVariants,
        srcStart,
      );
      missingStyledCount = dstStart + count;
    }
    _shiftRowSliceTable(
      rowMissingStyledStart,
      rowMissingStyledCount,
      src.rowMissingStyledStart,
      src.rowMissingStyledCount,
      startRow,
      endRow,
      dstStart - srcStart,
    );
  }
}
