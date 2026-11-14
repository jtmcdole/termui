import 'dart:math';

import 'package:meta/meta.dart';
import 'package:termui_cast_protocol/termui_cast_protocol.dart';

/// Visual lifecycle phase of a tab rendered in [SessionTabStrip].
enum TabVisualPhase {
  /// Connected and active on the relay server.
  live,

  /// Disconnected and within the 30-second `⏳` grace window.
  disconnectedCountdown,

  /// Exited cleanly and within the 30-second `⏻` grace window.
  exitedCountdown,

  /// Past the 30-second grace window (`💀`), retained until `[x]` dismissal.
  dead;

  /// Whether this phase represents a live connected session.
  bool get isLive => this == .live;
}

/// Immutable lifecycle snapshot of a session tab at a specific [DateTime] instant.
@immutable
final class SessionTabStatus {
  /// Duration an ended tab displays `⏳` or `⏻` before transitioning to `💀`.
  static const Duration gracePeriod = Duration(seconds: 30);

  /// Fixed display-column width of every non-live [statusChip].
  static const int statusChipCols = 5;

  /// Canonical status of a live running tab.
  static const SessionTabStatus live = SessionTabStatus(phase: .live);

  /// Current visual phase of the tab.
  final TabVisualPhase phase;

  /// Remaining countdown seconds (`30..1`) during the grace window, else `null`.
  final int? remainingSeconds;

  /// Recorded exit code for ended tabs, or `null` while [isLive].
  final int? exitCode;

  /// Creates an immutable tab status snapshot.
  const SessionTabStatus({
    required this.phase,
    this.remainingSeconds,
    this.exitCode,
  });

  /// Computes the [SessionTabStatus] at [now] from [closeReason], [endedAt], and [exitCode].
  factory SessionTabStatus.compute({
    required SessionCloseReason? closeReason,
    required DateTime? endedAt,
    required int? exitCode,
    required DateTime now,
  }) {
    if (closeReason == null || endedAt == null) return live;
    final elapsedMs = now.difference(endedAt).inMilliseconds;
    if (elapsedMs >= gracePeriod.inMilliseconds) {
      return SessionTabStatus(phase: .dead, exitCode: exitCode);
    }
    final remainingMs = gracePeriod.inMilliseconds - max(0, elapsedMs);
    final secs = ((remainingMs + 999) ~/ 1000).clamp(1, 30);
    final countdownPhase = closeReason == .exited
        ? TabVisualPhase.exitedCountdown
        : TabVisualPhase.disconnectedCountdown;
    return SessionTabStatus(
      phase: countdownPhase,
      remainingSeconds: secs,
      exitCode: exitCode,
    );
  }

  /// Whether the tab is live and eligible for interactive input or rename.
  bool get isLive => phase.isLive;

  /// Fixed 5-column status chip (`⏳29s`, `⏻ 29s`, `💀   `), or `''` when live.
  String get statusChip {
    final secs = '${(remainingSeconds ?? 1).clamp(1, 99)}'.padLeft(2);
    return switch (phase) {
      .live => '',
      .disconnectedCountdown => '⏳${secs}s',
      .exitedCountdown => '⏻ ${secs}s',
      .dead => '💀   ',
    };
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SessionTabStatus &&
          other.phase == phase &&
          other.remainingSeconds == remainingSeconds &&
          other.exitCode == exitCode;

  @override
  int get hashCode => Object.hash(phase, remainingSeconds, exitCode);
}

/// Pure-Dart ordered tab strip tracking live and retained ended sessions,
/// custom user drag order, 30-second grace countdowns, and LRU dead-tab caps.
final class SessionTabStrip {
  /// Default maximum number of ended tabs retained before LRU eviction.
  static const int defaultMaxRetainedEndedTabs = 32;

  /// Maximum number of non-active ended tabs retained simultaneously.
  final int maxRetainedEndedTabs;

  final List<SessionId> _order = [];
  final Map<SessionId, _TabRecord> _records = {};
  List<SessionSummary>? _cachedSessions;

  /// Creates an empty ordered tab strip with [maxRetainedEndedTabs] retention cap.
  SessionTabStrip({int maxRetainedEndedTabs = defaultMaxRetainedEndedTabs})
    : maxRetainedEndedTabs = max(0, maxRetainedEndedTabs);

  /// Number of live and retained ended tabs in the strip.
  int get length => _order.length;

  /// Whether the strip currently holds zero tabs.
  bool get isEmpty => _order.isEmpty;

  /// Ordered [SessionSummary] list matching user drag order.
  List<SessionSummary> get sessions =>
      _cachedSessions ??= List<SessionSummary>.unmodifiable([
        for (final id in _order) _records[id]!.summary,
      ]);

  /// Whether [id] is present in the strip (either live or retained ended).
  bool contains(SessionId id) => _records.containsKey(id);

  /// Whether [id] is currently live on the relay server.
  bool isLive(SessionId id) {
    final record = _records[id];
    return record != null && record.closeReason == null;
  }

  /// Latest exit code recorded for [id], or `null` while live or unknown.
  int? exitCodeOf(SessionId id) => _records[id]?.exitCode;

  /// Returns the [SessionSummary] for [id], or `null` when absent.
  SessionSummary? summaryOf(SessionId id) => _records[id]?.summary;

  /// Computes the [SessionTabStatus] for [id] at [now].
  SessionTabStatus statusOf(SessionId id, DateTime now) {
    final record = _records[id];
    if (record == null) return SessionTabStatus.live;
    return SessionTabStatus.compute(
      closeReason: record.closeReason,
      endedAt: record.endedAt,
      exitCode: record.exitCode,
      now: now,
    );
  }

  /// Whether at least one retained tab is currently within its 30-second countdown.
  bool hasActiveCountdown(DateTime now) {
    for (final record in _records.values) {
      final endedAt = record.endedAt;
      if (record.closeReason != null &&
          endedAt != null &&
          now.difference(endedAt) < SessionTabStatus.gracePeriod) {
        return true;
      }
    }
    return false;
  }

  /// Reconciles an authoritative relay [incoming] directory without clobbering
  /// user tab order, reclaiming reconnected [SessionId]s in place and marking
  /// vanished live tabs as [SessionCloseReason.disconnected].
  ///
  /// Returns any ended [SessionId]s evicted by the [maxRetainedEndedTabs] cap.
  List<SessionId> reconcileDirectory(
    List<SessionSummary> incoming, {
    required DateTime now,
    required SessionId? activeSessionId,
  }) {
    final incomingIds = <SessionId>{for (final summary in incoming) summary.id};
    for (final summary in incoming) {
      _upsertLiveSummary(summary);
    }
    for (final id in _order) {
      if (!incomingIds.contains(id)) {
        _markDisconnectedIfLive(_records[id]!, now);
      }
    }
    _cachedSessions = null;
    return _evictOverflowEnded(now: now, protectedId: activeSessionId);
  }

  void _upsertLiveSummary(SessionSummary summary) {
    final existing = _records[summary.id];
    if (existing != null) {
      existing
        ..summary = summary
        ..closeReason = null
        ..endedAt = null
        ..exitCode = null;
      return;
    }
    _order.add(summary.id);
    _records[summary.id] = _TabRecord(summary: summary);
  }

  static void _markDisconnectedIfLive(_TabRecord record, DateTime now) {
    if (record.closeReason != null) return;
    record
      ..closeReason = .disconnected
      ..endedAt = now
      ..exitCode = -1;
  }

  /// Marks [id] as ended with [reason] and [exitCode] at [now].
  ///
  /// Preserves an earlier [SessionCloseReason.exited] transition if a subsequent
  /// socket disconnect arrives for the same session.
  List<SessionId> markEnded(
    SessionId id, {
    required SessionCloseReason reason,
    required int exitCode,
    required DateTime now,
    required SessionId? activeSessionId,
  }) {
    final record = _records[id];
    if (record == null) return const [];
    if (record.closeReason == .exited && reason == .disconnected) {
      return const [];
    }
    if (record.closeReason == null) {
      record.endedAt = now;
    }
    record
      ..closeReason = reason
      ..exitCode = exitCode;
    return _evictOverflowEnded(now: now, protectedId: activeSessionId);
  }

  /// Marks every currently live tab as [SessionCloseReason.disconnected] at [now]
  /// when the viewer's own relay connection drops.
  List<SessionId> markAllLiveDisconnected({
    required DateTime now,
    required SessionId? activeSessionId,
  }) {
    var mutated = false;
    for (final record in _records.values) {
      if (record.closeReason == null) {
        record
          ..closeReason = .disconnected
          ..endedAt = now
          ..exitCode = -1;
        mutated = true;
      }
    }
    if (!mutated) return const [];
    return _evictOverflowEnded(now: now, protectedId: activeSessionId);
  }

  /// Evaluates LRU eviction at [now] as countdowns expire into `💀`.
  List<SessionId> pruneOverflowAt(
    DateTime now, {
    required SessionId? activeSessionId,
  }) => _evictOverflowEnded(now: now, protectedId: activeSessionId);

  /// Moves [id] to [targetIndex] in the tab order, returning `true` when changed.
  bool moveTab(SessionId id, int targetIndex) {
    final currentIndex = _order.indexOf(id);
    if (currentIndex < 0 || _order.length <= 1) return false;
    final clampedTarget = targetIndex.clamp(0, _order.length - 1);
    if (clampedTarget == currentIndex) return false;
    _order
      ..removeAt(currentIndex)
      ..insert(clampedTarget, id);
    _cachedSessions = null;
    return true;
  }

  /// Dismisses an ended tab [id] (`[x]`), returning `false` if [id] is live or absent.
  bool dismiss(SessionId id) {
    final record = _records[id];
    if (record == null || record.closeReason == null) return false;
    _records.remove(id);
    _order.remove(id);
    _cachedSessions = null;
    return true;
  }

  /// Chooses the adjacent [SessionId] to select before dismissing [dismissedId],
  /// or `null` when [dismissedId] is the sole remaining tab.
  SessionId? adjacentSessionAfterDismiss(SessionId dismissedId) {
    final idx = _order.indexOf(dismissedId);
    if (idx < 0 || _order.length <= 1) return null;
    return idx + 1 < _order.length ? _order[idx + 1] : _order[idx - 1];
  }

  /// Removes all live and retained tabs from the strip.
  void clear() {
    _order.clear();
    _records.clear();
    _cachedSessions = null;
  }

  List<SessionId> _evictOverflowEnded({
    required DateTime now,
    required SessionId? protectedId,
  }) {
    var endedCount = _countEnded();
    if (endedCount <= maxRetainedEndedTabs) return const [];

    final evicted = <SessionId>[];
    while (endedCount > maxRetainedEndedTabs) {
      final victim = _findOldestDeadVictim(now, protectedId);
      if (victim == null) break;
      _records.remove(victim);
      _order.remove(victim);
      evicted.add(victim);
      endedCount--;
    }
    if (evicted.isNotEmpty) {
      _cachedSessions = null;
    }
    return evicted;
  }

  /// Returns the [SessionId] at `currentIndex + delta` (wrapping around), or
  /// `null` when the tab strip is empty.
  SessionId? cycleSessionId(SessionId? currentId, int delta) {
    if (_order.isEmpty) return null;
    final idx = currentId == null ? 0 : _order.indexOf(currentId);
    final baseIdx = idx < 0 ? 0 : idx;
    final nextIdx =
        (baseIdx + delta % _order.length + _order.length) % _order.length;
    return _order[nextIdx];
  }

  int _countEnded() {
    var count = 0;
    for (final record in _records.values) {
      if (record.closeReason != null) count++;
    }
    return count;
  }

  SessionId? _findOldestDeadVictim(DateTime now, SessionId? protectedId) {
    SessionId? oldestId;
    DateTime? oldestTime;
    for (final id in _order) {
      if (id == protectedId) continue;
      final record = _records[id]!;
      final endedAt = record.endedAt;
      if (record.closeReason == null || endedAt == null) continue;
      if (now.difference(endedAt) < SessionTabStatus.gracePeriod) continue;
      if (oldestTime == null || endedAt.isBefore(oldestTime)) {
        oldestTime = endedAt;
        oldestId = id;
      }
    }
    return oldestId;
  }
}

final class _TabRecord {
  SessionSummary summary;
  SessionCloseReason? closeReason;
  DateTime? endedAt;
  int? exitCode;

  _TabRecord({required this.summary});
}
