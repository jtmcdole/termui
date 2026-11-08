import 'dart:math' as math;
import 'dart:typed_data';

import 'package:termui/termui.dart';

/// An immutable snapshot of a single primary-screen row evicted into scrollback.
final class ScrollbackLine {
  /// The terminal column width when this line was evicted.
  final int width;

  /// Cell graphemes, trimmed of trailing default-styled blank spaces.
  final List<String> characters;

  /// Packed `[fg, bg, modifiers]` attributes (`length == characters.length * 3`).
  final Uint32List attributes;

  /// Optional per-cell SGR 58 underline colors (`null` when all `0`).
  final Uint32List? underlineColors;

  /// Optional per-cell OSC 8 hyperlink URIs (`null` when all `null`).
  final List<String?>? uris;

  /// Whether this row began via right-margin auto-wrap from the preceding row.
  final bool isWrapped;

  /// Creates an immutable [ScrollbackLine].
  ScrollbackLine({
    required this.width,
    required this.characters,
    required this.attributes,
    this.underlineColors,
    this.uris,
    this.isWrapped = false,
  }) : assert(attributes.length == characters.length * 3);

  /// Captures row [row] from [buffer], trimming trailing default blank cells.
  factory ScrollbackLine.fromBufferRow(
    Buffer buffer,
    int row, {
    required bool isWrapped,
  }) {
    final rowWidth = buffer.width;
    final rowStart = row * rowWidth;
    final trimmedLen = _findTrimmedLength(buffer, rowStart, rowWidth);
    if (trimmedLen == 0) {
      return ScrollbackLine(
        width: rowWidth,
        characters: const [],
        attributes: Uint32List(0),
        isWrapped: isWrapped,
      );
    }

    final chars = List<String>.generate(
      trimmedLen,
      (i) => buffer.characters[rowStart + i],
      growable: false,
    );
    final attrs = buffer.attributes.sublist(
      rowStart * 3,
      (rowStart + trimmedLen) * 3,
    );
    final rowEnd = rowStart + trimmedLen;
    return ScrollbackLine(
      width: rowWidth,
      characters: chars,
      attributes: attrs,
      underlineColors: buffer.sliceUnderlineColors(rowStart, rowEnd),
      uris: buffer.sliceUris(rowStart, rowEnd),
      isWrapped: isWrapped,
    );
  }

  static int _findTrimmedLength(Buffer buffer, int rowStart, int width) {
    for (var col = width - 1; col >= 0; col--) {
      if (!_isDefaultBlankCell(buffer, rowStart + col)) {
        return col + 1;
      }
    }
    return 0;
  }

  static bool _isDefaultBlankCell(Buffer buffer, int cellIdx) {
    if (buffer.characters[cellIdx] != ' ') return false;
    if (buffer.getUnderlineColorAt(cellIdx) != 0 ||
        buffer.getUriAt(cellIdx) != null) {
      return false;
    }
    final attrIdx = cellIdx * 3;
    final mod = buffer.attributes[attrIdx + 2];
    return buffer.attributes[attrIdx] == 0 &&
        buffer.attributes[attrIdx + 1] == 0 &&
        (mod == Modifier.none || mod == Modifier.transparent);
  }
}

/// Fixed-capacity O(1) ring buffer of evicted primary-screen [ScrollbackLine]s.
final class ScrollbackBuffer {
  /// Maximum number of retained scrollback lines (`0` disables retention).
  final int maxLines;

  List<ScrollbackLine?> _ring = const [];
  int _head = 0;
  int _count = 0;
  int _clearSeq = 0;
  int _oldestLine = 0;
  int _totalLines = 0;

  /// Creates a scrollback ring buffer retaining up to [maxLines] lines.
  ScrollbackBuffer({required int maxLines}) : maxLines = math.max(0, maxLines);

  /// Monotonic counter incremented whenever [clear] wipes the ring buffer.
  int get clearSeq => _clearSeq;

  /// Virtual line index of the oldest retained line (`oldestLine <= totalLines`).
  int get oldestLine => _oldestLine;

  /// Total number of lines evicted since creation or the last [clear].
  int get totalLines => _totalLines;

  /// Number of lines currently retained in the ring (`totalLines - oldestLine`).
  int get retainedLines => _count;

  /// Alias for [retainedLines] matching standard Dart collection length.
  int get length => _count;

  /// Whether no lines are currently retained.
  bool get isEmpty => _count == 0;

  /// Advances line counters by [count] discarded rows when `maxLines == 0`.
  void advanceDiscarded(int count) {
    if (count <= 0) return;
    _totalLines += count;
    if (maxLines == 0) {
      _oldestLine = _totalLines;
    }
  }

  /// Appends [line] to the ring, evicting the oldest line when full.
  void push(ScrollbackLine line) {
    _totalLines++;
    if (maxLines == 0) {
      _oldestLine = _totalLines;
      return;
    }
    if (_count < maxLines) {
      _ensureCapacity(_count + 1);
      _ring[(_head + _count) % _ring.length] = line;
      _count++;
      return;
    }
    _ring[_head] = line;
    _head = (_head + 1) % _ring.length;
    _oldestLine++;
  }

  void _ensureCapacity(int needed) {
    if (_ring.length >= needed) return;
    final doubled = _ring.isEmpty ? math.min(maxLines, 64) : _ring.length * 2;
    final nextCap = math.min(maxLines, math.max(needed, doubled));
    final nextRing = List<ScrollbackLine?>.filled(nextCap, null);
    for (var i = 0; i < _count; i++) {
      nextRing[i] = _ring[(_head + i) % _ring.length];
    }
    _ring = nextRing;
    _head = 0;
  }

  /// Returns the line at virtual index [lineIndex], or `null` if evicted/out of range.
  ScrollbackLine? operator [](int lineIndex) {
    if (lineIndex < _oldestLine || lineIndex >= _totalLines) return null;
    return _ring[(_head + (lineIndex - _oldestLine)) % _ring.length];
  }

  /// Returns up to [count] retained lines starting at virtual index [startLine].
  List<ScrollbackLine> slice(int startLine, int count) {
    if (count <= 0 || _count == 0 || startLine >= _totalLines) return const [];
    if (startLine <= _oldestLine - count) return const [];
    final clampedStart = math.max(startLine, _oldestLine);
    final take = math.min(
      count - (clampedStart - startLine),
      _totalLines - clampedStart,
    );
    if (take <= 0) return const [];
    return [for (var i = 0; i < take; i++) this[clampedStart + i]!];
  }

  /// Wipes all retained lines, resets line counters to `0`, and increments [clearSeq].
  void clear() {
    _clearSeq++;
    _ring = const [];
    _head = 0;
    _count = 0;
    _oldestLine = 0;
    _totalLines = 0;
  }
}
