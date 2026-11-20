import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show visibleForTesting;

/// Procedural cell decoration sprites pre-baked into a `GlyphAtlas`.
enum AtlasDecorationKind {
  /// Horizontal bar at the top edge of the cell (`SGR 53`).
  overline,

  /// Horizontal bar centered vertically across the cell (`SGR 9`).
  strikethrough,

  /// Single straight underline near the bottom edge of the cell (`SGR 4:1`).
  underlineSingle,

  /// Double straight underline near the bottom edge of the cell (`SGR 4:2`).
  underlineDouble,

  /// Cycle-quantized sinusoidal curly underline (`SGR 4:3`).
  underlineCurly,

  /// Cycle-quantized dotted underline (`SGR 4:4`).
  underlineDotted,

  /// Cycle-quantized dashed underline (`SGR 4:5`).
  underlineDashed,
}

/// Flat typed-array quad lookup table for scalar glyph codes and cell
/// decorations in a `GlyphAtlas`.
///
/// Direct `Int32List` tables serve ASCII (`0x20..0x7E`), Box/Block
/// (`0x2500..0x259F`), and Braille (`0x2800..0x28FF`) in a single array read,
/// while all other scalar Unicode code points resolve through a power-of-two
/// open-addressed integer hash table without boxing records or `String` keys.
final class AtlasQuadTable {
  /// First ASCII scalar code point stored in the direct ASCII table.
  static const int asciiStart = 0x20;

  /// Last ASCII scalar code point stored in the direct ASCII table.
  static const int asciiEnd = 0x7E;

  /// First Box Drawing / Block Elements code point in the direct table.
  static const int boxBlockStart = 0x2500;

  /// Last Box Drawing / Block Elements code point in the direct table.
  static const int boxBlockEnd = 0x259F;

  /// First Braille Patterns code point in the direct table.
  static const int brailleStart = 0x2800;

  /// Last Braille Patterns code point in the direct table.
  static const int brailleEnd = 0x28FF;

  static const int _maxUnicodeScalar = 0x10FFFF;
  static const int _asciiCount = asciiEnd - asciiStart + 1;
  static const int _boxBlockCount = boxBlockEnd - boxBlockStart + 1;
  static const int _brailleCount = brailleEnd - brailleStart + 1;
  static const int _decorationSlotCount = 14;

  /// Packed `[left, top, right, bottom]` physical texel coordinates (`4` floats
  /// per quad entry).
  final Float32List ltrbQuads;

  final Int32List _asciiOffsets;
  final Int32List _boxBlockOffsets;
  final Int32List _brailleOffsets;
  final Int32List _decorationOffsets;
  final Int32List _hashKeys;
  final Int32List _hashValues;
  final int _hashMask;
  final int _hashCount;

  AtlasQuadTable._({
    required this.ltrbQuads,
    required this._asciiOffsets,
    required this._boxBlockOffsets,
    required this._brailleOffsets,
    required this._decorationOffsets,
    required Int32List hashKeys,
    required this._hashValues,
    required this._hashCount,
  }) : _hashKeys = hashKeys,
       _hashMask = hashKeys.length - 1;

  /// Number of quad entries stored in [ltrbQuads].
  int get quadCount => ltrbQuads.length >> 2;

  /// Power-of-two capacity of the open-addressed hash table (testing helper).
  @visibleForTesting
  int get debugHashCapacity => _hashKeys.length;

  /// Number of occupied entries in the open-addressed hash table (testing helper).
  @visibleForTesting
  int get debugHashCount => _hashCount;

  /// Returns `quadIndex * 4` into [ltrbQuads] for [packedGlyphCode] and
  /// [variantBits] (`0 = regular`, `1 = bold`, `2 = italic`, `3 = boldItalic`),
  /// or `-1` when absent or when [packedGlyphCode] is not a scalar code point.
  ///
  /// When a styled variant (`variantBits != 0`) is absent, falls back to the
  /// regular (`0`) variant to match `GlyphAtlas.rectFor`.
  int quadOffsetForCode(int packedGlyphCode, {required int variantBits}) {
    if (packedGlyphCode <= 0 || packedGlyphCode > _maxUnicodeScalar) {
      return -1;
    }
    final variant = variantBits & 3;
    if (packedGlyphCode >= asciiStart && packedGlyphCode <= asciiEnd) {
      return _asciiOffsets[((packedGlyphCode - asciiStart) << 2) | variant];
    }
    if (packedGlyphCode >= boxBlockStart && packedGlyphCode <= boxBlockEnd) {
      return _boxBlockOffsets[((packedGlyphCode - boxBlockStart) << 2) |
          variant];
    }
    if (packedGlyphCode >= brailleStart && packedGlyphCode <= brailleEnd) {
      return _brailleOffsets[((packedGlyphCode - brailleStart) << 2) | variant];
    }
    final direct = _lookupHash((packedGlyphCode << 2) | variant);
    if (direct >= 0 || variant == 0) return direct;
    return _lookupHash(packedGlyphCode << 2);
  }

  /// Returns `quadIndex * 4` into [ltrbQuads] for procedural cell decoration
  /// [kind] at 1-cell (`isWide: false`) or 2-cell (`isWide: true`) width, or
  /// `-1` when decoration sprites were not baked into this atlas.
  int decorationQuadOffset(AtlasDecorationKind kind, {required bool isWide}) =>
      _decorationOffsets[(kind.index << 1) | (isWide ? 1 : 0)];

  int _lookupHash(int key) {
    final keys = _hashKeys;
    final mask = _hashMask;
    var slot = _hashKey(key) & mask;
    while (true) {
      final existing = keys[slot];
      if (existing == key) return _hashValues[slot];
      if (existing == 0) return -1;
      slot = (slot + 1) & mask;
    }
  }

  /// Avalanche hash for 23-bit packed `(codePoint << 2) | variantBits` keys.
  ///
  /// The intermediate product (`<= 0x43FFFF * 0x45D9F3B < 2^49`) stays exact
  /// inside IEEE-754 53-bit integers on Dart Web as well as native 64-bit VM.
  static int _hashKey(int key) {
    var h = key;
    h = ((h ^ (h >>> 16)) * 0x45D9F3B) & 0x7FFFFFFF;
    h = h ^ (h >>> 16);
    return h;
  }
}

/// Incremental builder that produces an immutable [AtlasQuadTable].
final class AtlasQuadTableBuilder {
  Float32List _quadData;
  int _quadFloatLength = 0;

  final Int32List _asciiOffsets = Int32List(AtlasQuadTable._asciiCount * 4)
    ..fillRange(0, AtlasQuadTable._asciiCount * 4, -1);
  final Int32List _boxBlockOffsets = Int32List(
    AtlasQuadTable._boxBlockCount * 4,
  )..fillRange(0, AtlasQuadTable._boxBlockCount * 4, -1);
  final Int32List _brailleOffsets = Int32List(AtlasQuadTable._brailleCount * 4)
    ..fillRange(0, AtlasQuadTable._brailleCount * 4, -1);
  final Int32List _decorationOffsets = Int32List(
    AtlasQuadTable._decorationSlotCount,
  )..fillRange(0, AtlasQuadTable._decorationSlotCount, -1);

  Int32List _hashKeys;
  Int32List _hashValues;
  int _hashCount = 0;

  /// Creates an [AtlasQuadTableBuilder] with optional initial typed-array
  /// capacities.
  AtlasQuadTableBuilder({
    int initialQuadCapacity = 64,
    int initialHashCapacity = 16,
  }) : _quadData = Float32List(math.max(4, initialQuadCapacity) * 4),
       _hashKeys = Int32List(_nextPowerOfTwo(initialHashCapacity)),
       _hashValues = Int32List(_nextPowerOfTwo(initialHashCapacity)) {
    _hashValues.fillRange(0, _hashValues.length, -1);
  }

  static int _nextPowerOfTwo(int minCapacity) {
    var cap = 4;
    while (cap < minCapacity) {
      cap <<= 1;
    }
    return cap;
  }

  int _appendQuad(double left, double top, double right, double bottom) {
    final offset = _quadFloatLength;
    if (offset + 4 > _quadData.length) {
      final grown = Float32List(_quadData.length << 1);
      grown.setRange(0, offset, _quadData);
      _quadData = grown;
    }
    _quadData[offset] = left;
    _quadData[offset + 1] = top;
    _quadData[offset + 2] = right;
    _quadData[offset + 3] = bottom;
    _quadFloatLength = offset + 4;
    return offset;
  }

  /// Records a physical texel [rect] for scalar [codePoint] and [variantBits].
  void putCodePoint(
    int codePoint, {
    required int variantBits,
    required ui.Rect rect,
  }) {
    if (codePoint <= 0 || codePoint > AtlasQuadTable._maxUnicodeScalar) {
      return;
    }
    final variant = variantBits & 3;
    final offset = _appendQuad(rect.left, rect.top, rect.right, rect.bottom);
    if (codePoint >= AtlasQuadTable.asciiStart &&
        codePoint <= AtlasQuadTable.asciiEnd) {
      _asciiOffsets[((codePoint - AtlasQuadTable.asciiStart) << 2) | variant] =
          offset;
      return;
    }
    if (codePoint >= AtlasQuadTable.boxBlockStart &&
        codePoint <= AtlasQuadTable.boxBlockEnd) {
      _boxBlockOffsets[((codePoint - AtlasQuadTable.boxBlockStart) << 2) |
              variant] =
          offset;
      return;
    }
    if (codePoint >= AtlasQuadTable.brailleStart &&
        codePoint <= AtlasQuadTable.brailleEnd) {
      _brailleOffsets[((codePoint - AtlasQuadTable.brailleStart) << 2) |
              variant] =
          offset;
      return;
    }
    _insertHash((codePoint << 2) | variant, offset);
  }

  /// Records a physical texel [rect] for procedural decoration [kind] at 1-cell
  /// (`isWide: false`) or 2-cell (`isWide: true`) width.
  void putDecoration(
    AtlasDecorationKind kind, {
    required bool isWide,
    required ui.Rect rect,
  }) {
    final offset = _appendQuad(rect.left, rect.top, rect.right, rect.bottom);
    _decorationOffsets[(kind.index << 1) | (isWide ? 1 : 0)] = offset;
  }

  void _insertHash(int key, int quadOffset) {
    if ((_hashCount + 1) * 2 > _hashKeys.length) {
      _growHashTable();
    }
    final mask = _hashKeys.length - 1;
    var slot = AtlasQuadTable._hashKey(key) & mask;
    while (true) {
      final existing = _hashKeys[slot];
      if (existing == 0) {
        _hashKeys[slot] = key;
        _hashValues[slot] = quadOffset;
        _hashCount++;
        return;
      }
      if (existing == key) {
        _hashValues[slot] = quadOffset;
        return;
      }
      slot = (slot + 1) & mask;
    }
  }

  void _growHashTable() {
    final oldKeys = _hashKeys;
    final oldValues = _hashValues;
    final newCap = oldKeys.length << 1;
    final newKeys = Int32List(newCap);
    final newValues = Int32List(newCap)..fillRange(0, newCap, -1);
    final mask = newCap - 1;
    for (var i = 0; i < oldKeys.length; i++) {
      final key = oldKeys[i];
      if (key == 0) continue;
      var slot = AtlasQuadTable._hashKey(key) & mask;
      while (newKeys[slot] != 0) {
        slot = (slot + 1) & mask;
      }
      newKeys[slot] = key;
      newValues[slot] = oldValues[i];
    }
    _hashKeys = newKeys;
    _hashValues = newValues;
  }

  static void _fillDirectTableFallbacks(Int32List table) {
    for (var base = 0; base < table.length; base += 4) {
      final regular = table[base];
      if (regular < 0) continue;
      if (table[base | 1] < 0) table[base | 1] = regular;
      if (table[base | 2] < 0) table[base | 2] = regular;
      if (table[base | 3] < 0) table[base | 3] = regular;
    }
  }

  /// Builds an immutable [AtlasQuadTable] from all entries added so far.
  AtlasQuadTable build() {
    final ascii = Int32List.fromList(_asciiOffsets);
    final boxBlock = Int32List.fromList(_boxBlockOffsets);
    final braille = Int32List.fromList(_brailleOffsets);
    _fillDirectTableFallbacks(ascii);
    _fillDirectTableFallbacks(boxBlock);
    _fillDirectTableFallbacks(braille);
    final quads = Float32List(_quadFloatLength);
    quads.setRange(0, _quadFloatLength, _quadData);
    return AtlasQuadTable._(
      ltrbQuads: quads,
      asciiOffsets: ascii,
      boxBlockOffsets: boxBlock,
      brailleOffsets: braille,
      decorationOffsets: Int32List.fromList(_decorationOffsets),
      hashKeys: Int32List.fromList(_hashKeys),
      hashValues: Int32List.fromList(_hashValues),
      hashCount: _hashCount,
    );
  }
}
