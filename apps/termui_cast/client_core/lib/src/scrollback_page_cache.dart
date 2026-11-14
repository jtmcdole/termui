import 'dart:collection';
import 'dart:math';

import 'package:clock/clock.dart';
import 'package:termui_cast_protocol/termui_cast_protocol.dart';

typedef _PendingScrollbackFetch = ({
  int clearSeq,
  int startLine,
  int count,
  DateTime expiresAt,
});

/// Client-side LRU page cache and request coalescer for primary-screen
/// scrollback rows fetched on demand from the caster.
final class ScrollbackPageCache {
  /// Number of virtual scrollback lines per cached page (`128`).
  static const int pageSize = ScrollbackChunkFrame.maxChunkRows;

  /// Maximum number of scrollback rows retained per session (`2048`).
  static const int maxCachedRows = 2048;

  /// Maximum concurrent in-flight [RequestScrollbackFrame]s per session.
  static const int maxInFlight = 2;

  /// Deadline before an unacknowledged scrollback request slot is reclaimed.
  static const Duration requestTimeout = Duration(seconds: 2);

  static final Clock _zoneClock = Clock(() => clock.now());

  final Clock _clock;
  final Duration _requestTimeout;

  int _clearSeq = 0;
  int _oldestLine = 0;
  int _totalLines = 0;
  int _nextRequestId = 1;
  int _cachedRowCount = 0;

  final LinkedHashMap<int, Map<int, EncodedScrollbackRow>> _pages =
      LinkedHashMap<int, Map<int, EncodedScrollbackRow>>();
  final Map<int, _PendingScrollbackFetch> _inFlight = {};

  /// Creates a page cache using [clock] and [requestTimeout] for in-flight
  /// request timeouts.
  ScrollbackPageCache({
    Clock? clock,
    Duration requestTimeout = ScrollbackPageCache.requestTimeout,
  }) : _clock = clock ?? _zoneClock,
       _requestTimeout = requestTimeout;

  /// Current authoritative `clearSeq` generation of cached rows.
  int get clearSeq => _clearSeq;

  /// Virtual line index of the oldest scrollback line retained by the caster.
  int get oldestLine => _oldestLine;

  /// Total number of primary lines evicted by the caster since start/clear.
  int get totalLines => _totalLines;

  /// Number of scrollback lines currently retained by the caster.
  int get retainedLines => max(0, _totalLines - _oldestLine);

  /// Maximum contiguous scrollback line offset from the bottom when offline.
  int get offlineScrollableLines {
    var line = _totalLines - 1;
    while (line >= _oldestLine &&
        (_pages[line ~/ pageSize]?.containsKey(line) ?? false)) {
      line--;
    }
    return _totalLines - 1 - line;
  }

  /// Whether at least one [RequestScrollbackFrame] is currently awaiting a reply.
  bool get hasInFlight => _inFlight.isNotEmpty;

  /// Resets all cached pages, in-flight requests, and window counters to `0`.
  void reset() {
    _clearSeq = 0;
    _oldestLine = 0;
    _totalLines = 0;
    _pages.clear();
    _inFlight.clear();
    _cachedRowCount = 0;
  }

  /// Updates the authoritative [ScrollbackWindow] metadata from a snapshot or delta.
  ///
  /// Returns `true` when `clearSeq` changed or the window regressed (for example,
  /// after a caster restart at `clearSeq == 0`) and invalidated cached rows.
  bool updateWindow(ScrollbackWindow window) {
    final regressed =
        window.clearSeq != _clearSeq ||
        window.totalLines < _totalLines ||
        window.oldestLine < _oldestLine;
    if (regressed) {
      _clearSeq = window.clearSeq;
      _oldestLine = window.oldestLine;
      _totalLines = window.totalLines;
      _pages.clear();
      _inFlight.clear();
      _cachedRowCount = 0;
      return true;
    }
    _oldestLine = window.oldestLine;
    _totalLines = window.totalLines;
    _pruneEvictedLines();
    return false;
  }

  /// Clears all pending in-flight requests (e.g. after a keyframe snapshot or
  /// caster reconnect) so stalled slots never block future fetches.
  void clearInFlight() {
    _inFlight.clear();
  }

  /// Prunes already-expired in-flight slots and returns the remaining delay
  /// until the earliest active in-flight request expires, or `null` if none.
  Duration? nextExpiryDelay() {
    if (_inFlight.isEmpty) return null;
    final now = _clock.now();
    _inFlight.removeWhere((_, req) => !now.isBefore(req.expiresAt));
    if (_inFlight.isEmpty) return null;
    DateTime? earliest;
    for (final req in _inFlight.values) {
      if (earliest == null || req.expiresAt.isBefore(earliest)) {
        earliest = req.expiresAt;
      }
    }
    if (earliest == null) return null;
    final remaining = earliest.difference(now);
    return remaining.isNegative ? Duration.zero : remaining;
  }

  /// Returns the cached row at [virtualRow], or `null` if uncached/out of range.
  EncodedScrollbackRow? rowAt(int virtualRow) {
    if (virtualRow < _oldestLine || virtualRow >= _totalLines) return null;
    final pageIdx = virtualRow ~/ pageSize;
    final page = _pages[pageIdx];
    if (page == null) return null;
    final row = page[virtualRow];
    if (row == null) return null;
    _touchPage(pageIdx, page);
    return row;
  }

  /// Looks up the SGR 58 underline color at `([virtualRow], [col])` in cached scrollback.
  int underlineColorAt(int virtualRow, int col) =>
      rowAt(virtualRow)?.underlineColorAtCol(col) ?? 0;

  /// Looks up the sanitized `OSC 8` URI at `([virtualRow], [col])` in cached scrollback.
  String? uriAt(int virtualRow, int col) => rowAt(virtualRow)?.uriAtCol(col);

  /// Stores a received [ScrollbackChunkFrame] if its `clearSeq` matches.
  ///
  /// Returns `true` when at least one row or window bound was updated.
  bool ingestChunk(ScrollbackChunkFrame chunk) {
    final pending = _inFlight.remove(chunk.requestId);
    if (chunk.clearSeq != _clearSeq) return false;
    if (pending != null && chunk.startLine > pending.startLine) {
      _oldestLine = max(_oldestLine, chunk.startLine);
      _pruneEvictedLines();
    }
    for (var i = 0; i < chunk.rows.length; i++) {
      final line = chunk.startLine + i;
      if (line < _oldestLine || line >= _totalLines) continue;
      _putRow(line, chunk.rows[i]);
    }
    _evictOldestPagesIfNeeded();
    return true;
  }

  /// Plans up to [maxInFlight] [RequestScrollbackFrame]s covering missing rows
  /// in `[startLine, endLine)` while coalescing gaps and skipping in-flight ranges.
  List<RequestScrollbackFrame> planRequests({
    required SessionId sessionId,
    required int startLine,
    required int endLine,
  }) {
    final now = _clock.now();
    _inFlight.removeWhere((_, req) => !now.isBefore(req.expiresAt));
    if (_inFlight.length >= maxInFlight) return const [];
    final clampedStart = max(_oldestLine, startLine);
    final clampedEnd = min(_totalLines, endLine);
    if (clampedStart >= clampedEnd) return const [];

    final frames = <RequestScrollbackFrame>[];
    var cursor = clampedStart;
    while (cursor < clampedEnd && _inFlight.length < maxInFlight) {
      if (_isCoveredOrInFlight(cursor)) {
        cursor++;
        continue;
      }
      final gapStart = cursor;
      final limit = min(clampedEnd, gapStart + pageSize);
      while (cursor < limit && !_isCoveredOrInFlight(cursor)) {
        cursor++;
      }
      frames.add(_allocateRequest(sessionId, gapStart, cursor - gapStart, now));
    }
    return frames;
  }

  RequestScrollbackFrame _allocateRequest(
    SessionId sessionId,
    int startLine,
    int count,
    DateTime now,
  ) {
    final reqId = _nextRequestId;
    _nextRequestId = (_nextRequestId + 1) & 0x7FFFFFFF;
    if (_nextRequestId == 0) _nextRequestId = 1;
    _inFlight[reqId] = (
      clearSeq: _clearSeq,
      startLine: startLine,
      count: count,
      expiresAt: now.add(_requestTimeout),
    );
    return RequestScrollbackFrame(
      sessionId: sessionId,
      requestId: reqId,
      clearSeq: _clearSeq,
      startLine: startLine,
      count: count,
    );
  }

  bool _isCoveredOrInFlight(int virtualRow) {
    final page = _pages[virtualRow ~/ pageSize];
    if (page != null && page.containsKey(virtualRow)) return true;
    for (final req in _inFlight.values) {
      if (virtualRow >= req.startLine &&
          virtualRow < req.startLine + req.count) {
        return true;
      }
    }
    return false;
  }

  void _putRow(int virtualRow, EncodedScrollbackRow row) {
    final pageIdx = virtualRow ~/ pageSize;
    final page = _pages.putIfAbsent(
      pageIdx,
      () => <int, EncodedScrollbackRow>{},
    );
    if (!page.containsKey(virtualRow)) {
      _cachedRowCount++;
    }
    page[virtualRow] = row;
    _touchPage(pageIdx, page);
  }

  void _touchPage(int pageIdx, Map<int, EncodedScrollbackRow> page) {
    _pages.remove(pageIdx);
    _pages[pageIdx] = page;
  }

  void _pruneEvictedLines() {
    if (_pages.isEmpty) return;
    final minPageIdx = _oldestLine ~/ pageSize;
    final toRemove = <int>[];
    for (final entry in _pages.entries) {
      if (entry.key < minPageIdx) {
        toRemove.add(entry.key);
      } else if (entry.key == minPageIdx) {
        entry.value.removeWhere((line, _) {
          if (line >= _oldestLine) return false;
          _cachedRowCount--;
          return true;
        });
        if (entry.value.isEmpty) toRemove.add(entry.key);
      }
    }
    for (final pageIdx in toRemove) {
      final removed = _pages.remove(pageIdx);
      if (removed != null) _cachedRowCount -= removed.length;
    }
  }

  void _evictOldestPagesIfNeeded() {
    while (_cachedRowCount > maxCachedRows && _pages.isNotEmpty) {
      final oldestKey = _pages.keys.first;
      final removed = _pages.remove(oldestKey);
      if (removed != null) _cachedRowCount -= removed.length;
    }
  }
}

/// Per-cell auxiliary attribute accessors on cached [EncodedScrollbackRow] entries.
extension EncodedScrollbackRowAuxAccess on EncodedScrollbackRow {
  /// Returns the SGR 58 underline color at 0-based [col], or `0` when unset.
  int underlineColorAtCol(int col) {
    if (col < 0 || col >= characters.length) return 0;
    return underlineColors?[col] ?? 0;
  }

  /// Returns the sanitized `OSC 8` URI at 0-based [col], or `null` when unset.
  String? uriAtCol(int col) {
    final runs = uriRuns;
    if (runs == null || col < 0 || col >= characters.length) return null;
    for (final run in runs) {
      if (col >= run.start && col < run.start + run.length) {
        final clean = clampOsc8Uri(run.uri);
        return clean.isEmpty ? null : clean;
      }
    }
    return null;
  }

  /// Expands [uriRuns] into a per-cell URI list of length `characters.length`,
  /// or returns `null` when no valid `OSC 8` runs exist on this row.
  List<String?>? expandUris() {
    final runs = uriRuns;
    if (runs == null || runs.isEmpty || characters.isEmpty) return null;
    List<String?>? expanded;
    for (final run in runs) {
      final clean = clampOsc8Uri(run.uri);
      if (clean.isEmpty || run.start < 0 || run.length <= 0) continue;
      final end = min(characters.length, run.start + run.length);
      if (run.start >= end) continue;
      final target = expanded ??= List<String?>.filled(characters.length, null);
      target.fillRange(run.start, end, clean);
    }
    return expanded;
  }
}
