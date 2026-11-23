import 'dart:collection';
import 'dart:typed_data';

/// Fixed-length list of terminal cell graphemes backed by packed 32-bit codes.
///
/// Each cell stores either:
/// - `0` ([wideContinuationCode]) for the trailing cell of a double-width
///   character (`''`),
/// - an unboxed Unicode scalar value (`1..0x10FFFF`, excluding UTF-16
///   surrogates `0xD800..0xDFFF`), or
/// - a cluster tag (`[clusterFlag] | id`) pointing into a deduplicated per-list
///   grapheme table for multi-codepoint clusters, `'\x00'`, and unpaired
///   surrogates.
///
/// Exposing `List<String>` via [ListBase] preserves backward compatibility with
/// callers indexing or slicing `Buffer.characters`, while [codesView] provides
/// zero-allocation read access to the underlying `Uint32List`.
final class GlyphCellList extends ListBase<String> {
  /// High bit set on packed cell codes that reference the cluster side table.
  static const int clusterFlag = 0x80000000;

  /// Bitmask extracting the cluster table index when [clusterFlag] is set.
  static const int payloadMask = 0x7FFFFFFF;

  /// Packed code representing the empty trailing cell (`''`) of a wide glyph.
  static const int wideContinuationCode = 0;

  /// Packed code representing a single ASCII space (`' '`, U+0020).
  static const int spaceCode = 0x20;

  /// Minimum cluster table entries required before sparse compaction runs.
  static const int compactionMinEntries = 1024;

  static final List<String> _asciiTable = List<String>.generate(
    128,
    String.fromCharCode,
    growable: false,
  );

  final Uint32List _codes;

  /// Unmodifiable view over the packed cell codes in this list.
  ///
  /// Callers must mutate through [setCodeAt], [fillCodeRange], [copyCellsFrom],
  /// or [List] methods so cluster accounting and cross-buffer remapping remain
  /// accurate.
  late final Uint32List codesView = _codes.asUnmodifiableView();

  final List<String> _clusterStrings = <String>[];
  final Map<String, int> _clusterIds = <String, int>{};
  int _liveClusterCells = 0;

  /// Creates a fixed-length [GlyphCellList] of [length] cells filled with
  /// [fillCode].
  ///
  /// Throws an [ArgumentError] if [length] is negative or if [fillCode] has
  /// [clusterFlag] set.
  GlyphCellList.filled(int length, {int fillCode = spaceCode})
    : _codes = Uint32List(RangeError.checkNotNegative(length, 'length')) {
    if ((fillCode & clusterFlag) != 0) {
      throw ArgumentError.value(
        fillCode,
        'fillCode',
        'Cannot initialize GlyphCellList with a cluster code',
      );
    }
    if (length > 0 && fillCode != wideContinuationCode) {
      _codes.fillRange(0, length, fillCode);
    }
  }

  /// Whether any multi-codepoint or special cluster strings are interned in
  /// this list's cluster table.
  bool get hasClusters => _clusterStrings.isNotEmpty;

  @override
  int get length => _codes.length;

  @override
  set length(int newLength) => throw UnsupportedError(
    'Cannot change length of a fixed-length GlyphCellList',
  );

  @override
  String operator [](int index) => decodeCode(_codes[index]);

  @override
  void operator []=(int index, String value) {
    setCodeAt(index, encodeGrapheme(value));
  }

  /// Encodes [grapheme] into a packed 32-bit cell code, interning clusters and
  /// special code units in this list's side table when necessary.
  int encodeGrapheme(String grapheme) {
    final len = grapheme.length;
    if (len == 0) return wideContinuationCode;
    if (len == 1) {
      final cu = grapheme.codeUnitAt(0);
      if (cu != 0 && (cu < 0xD800 || cu > 0xDFFF)) return cu;
      return _internCluster(grapheme);
    }
    if (len == 2) {
      final cu0 = grapheme.codeUnitAt(0);
      final cu1 = grapheme.codeUnitAt(1);
      if (cu0 >= 0xD800 && cu0 <= 0xDBFF && cu1 >= 0xDC00 && cu1 <= 0xDFFF) {
        return 0x10000 + ((cu0 & 0x3FF) << 10) + (cu1 & 0x3FF);
      }
    }
    return _internCluster(grapheme);
  }

  /// Decodes a packed 32-bit cell code from this list back into its [String].
  String decodeCode(int packedCode) {
    if (packedCode == wideContinuationCode) return '';
    if ((packedCode & clusterFlag) != 0) {
      return _clusterStrings[packedCode & payloadMask];
    }
    if (packedCode >= 0 && packedCode < 128) {
      return _asciiTable[packedCode];
    }
    return String.fromCharCode(packedCode);
  }

  int _internCluster(String grapheme) {
    final existing = _clusterIds[grapheme];
    if (existing != null) return clusterFlag | existing;
    final id = _clusterStrings.length;
    assert(id <= payloadMask, 'Cluster table capacity exceeded');
    _clusterStrings.add(grapheme);
    _clusterIds[grapheme] = id;
    return clusterFlag | id;
  }

  void _setCodeRaw(int index, int scalarCode) {
    final prevIsCluster = (_codes[index] & clusterFlag) != 0;
    final nextIsCluster = (scalarCode & clusterFlag) != 0;
    if (prevIsCluster != nextIsCluster) {
      _liveClusterCells += nextIsCluster ? 1 : -1;
    }
    _codes[index] = scalarCode;
  }

  /// Writes packed [scalarCode] at [index] while maintaining live cluster counts
  /// and triggering sparse compaction if needed.
  void setCodeAt(int index, int scalarCode) {
    final prevIsCluster = (_codes[index] & clusterFlag) != 0;
    _setCodeRaw(index, scalarCode);
    if (prevIsCluster && _clusterStrings.length > compactionMinEntries) {
      compactClustersIfSparse();
    }
  }

  /// Fills `[start, end)` with packed [scalarCode], maintaining live cluster
  /// counts and clearing or compacting the cluster table when appropriate.
  void fillCodeRange(int start, int end, int scalarCode) {
    RangeError.checkValidRange(start, end, _codes.length);
    if (start == end) return;
    final nextIsCluster = (scalarCode & clusterFlag) != 0;
    if (start == 0 && end == _codes.length && !nextIsCluster) {
      _codes.fillRange(0, end, scalarCode);
      if (_clusterStrings.isNotEmpty) {
        _clusterStrings.clear();
        _clusterIds.clear();
        _liveClusterCells = 0;
      }
      return;
    }
    if (_liveClusterCells > 0) {
      _liveClusterCells -= _countClusterCells(start, end);
    }
    _codes.fillRange(start, end, scalarCode);
    if (nextIsCluster) {
      _liveClusterCells += end - start;
    }
    if (_clusterStrings.length > compactionMinEntries) {
      compactClustersIfSparse();
    }
  }

  int _countClusterCells(int start, int end) {
    var count = 0;
    for (var i = start; i < end; i++) {
      if ((_codes[i] & clusterFlag) != 0) count++;
    }
    return count;
  }

  /// Copies [count] cells from [source] starting at [srcStart] into this list
  /// starting at [dstStart].
  ///
  /// Overlapping copies within the same list (`identical(source, this)`) and
  /// fast scalar-only copies use `_codes.setRange`, while cross-list copies from
  /// a [source] containing live clusters remap cluster IDs safely into this
  /// list's cluster table.
  void copyCellsFrom(
    GlyphCellList source,
    int dstStart,
    int srcStart,
    int count,
  ) {
    RangeError.checkNotNegative(count, 'count');
    RangeError.checkValidRange(dstStart, dstStart + count, _codes.length);
    RangeError.checkValidRange(
      srcStart,
      srcStart + count,
      source._codes.length,
    );
    if (count == 0) return;

    if (identical(source, this) || source._liveClusterCells == 0) {
      _copyDirectRange(source, dstStart, srcStart, count);
    } else {
      _copyForeignClusterRange(source, dstStart, srcStart, count);
    }
    if (_clusterStrings.length > compactionMinEntries) {
      compactClustersIfSparse();
    }
  }

  void _copyDirectRange(
    GlyphCellList source,
    int dstStart,
    int srcStart,
    int count,
  ) {
    final dstEnd = dstStart + count;
    final hasSelfClusters = identical(source, this) && _liveClusterCells > 0;
    if (_liveClusterCells > 0) {
      _liveClusterCells -= _countClusterCells(dstStart, dstEnd);
    }
    _codes.setRange(dstStart, dstEnd, source._codes, srcStart);
    if (hasSelfClusters) {
      _liveClusterCells += _countClusterCells(dstStart, dstEnd);
    }
  }

  void _copyForeignClusterRange(
    GlyphCellList source,
    int dstStart,
    int srcStart,
    int count,
  ) {
    final srcCodes = source._codes;
    final srcClusters = source._clusterStrings;
    for (var i = 0; i < count; i++) {
      final rawCode = srcCodes[srcStart + i];
      final dstCode = (rawCode & clusterFlag) != 0
          ? _internCluster(srcClusters[rawCode & payloadMask])
          : rawCode;
      _setCodeRaw(dstStart + i, dstCode);
    }
  }

  /// Runs a full-buffer liveness scan and rebuilds the cluster side table
  /// whenever `_clusterStrings.length > max(compactionMinEntries, _liveClusterCells * 2)`.
  void compactClustersIfSparse() {
    final threshold = _liveClusterCells * 2 > compactionMinEntries
        ? _liveClusterCells * 2
        : compactionMinEntries;
    if (_clusterStrings.length <= threshold) return;

    final newStrings = <String>[];
    final newIds = <String, int>{};
    var liveCount = 0;
    for (var i = 0; i < _codes.length; i++) {
      final code = _codes[i];
      if ((code & clusterFlag) == 0) continue;
      liveCount++;
      final grapheme = _clusterStrings[code & payloadMask];
      var newId = newIds[grapheme];
      if (newId == null) {
        newId = newStrings.length;
        newStrings.add(grapheme);
        newIds[grapheme] = newId;
      }
      _codes[i] = clusterFlag | newId;
    }
    _clusterStrings
      ..clear()
      ..addAll(newStrings);
    _clusterIds
      ..clear()
      ..addAll(newIds);
    _liveClusterCells = liveCount;
  }

  @override
  void fillRange(int start, int end, [String? fill]) {
    RangeError.checkValidRange(start, end, _codes.length);
    final value = ArgumentError.checkNotNull(fill, 'fill');
    if (start == end) return;
    fillCodeRange(start, end, encodeGrapheme(value));
  }

  @override
  void setRange(
    int start,
    int end,
    Iterable<String> iterable, [
    int skipCount = 0,
  ]) {
    RangeError.checkValidRange(start, end, _codes.length);
    RangeError.checkNotNegative(skipCount, 'skipCount');
    final count = end - start;
    if (count == 0) return;
    if (iterable is GlyphCellList) {
      copyCellsFrom(iterable, start, skipCount, count);
      return;
    }
    _setRangeFromStrings(start, count, iterable, skipCount);
    if (_clusterStrings.length > compactionMinEntries) {
      compactClustersIfSparse();
    }
  }

  void _setRangeFromStrings(
    int start,
    int count,
    Iterable<String> iterable,
    int skipCount,
  ) {
    if (iterable is List<String>) {
      if (skipCount + count > iterable.length) {
        throw StateError('Too few elements');
      }
      for (var i = 0; i < count; i++) {
        _setCodeRaw(start + i, encodeGrapheme(iterable[skipCount + i]));
      }
      return;
    }
    final it = iterable.skip(skipCount).iterator;
    for (var i = 0; i < count; i++) {
      if (!it.moveNext()) throw StateError('Too few elements');
      _setCodeRaw(start + i, encodeGrapheme(it.current));
    }
  }
}
