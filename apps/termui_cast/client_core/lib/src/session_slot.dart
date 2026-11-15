import 'dart:async';
import 'dart:collection';
import 'dart:math';
import 'dart:typed_data';

import 'package:clock/clock.dart';
import 'package:hierarchical_state_machine/hierarchical_state_machine.dart';
import 'package:termui/termui.dart';
import 'package:termui_cast_protocol/termui_cast_protocol.dart';
import 'package:termui_pty/termui_pty.dart' show DirtyCellSpan;

import 'models.dart';
import 'scrollback_page_cache.dart';

export 'package:termui_pty/termui_pty.dart' show DirtyCellSpan;

/// Per-session synchronization states managed by `CastWorkspaceViewModel`.
enum ClientSessionSyncState {
  /// Composite HSM root state.
  root,

  /// Not subscribed to live updates.
  unsubscribed,

  /// Subscribed and waiting for an authoritative [BufferSnapshotFrame].
  awaitingKeyframe,

  /// Hydrated and applying sequenced [BufferDeltaFrame] updates.
  synchronized,
}

/// Internal HSM events driving a [SessionSlot] state machine.
enum SessionSyncEvent {
  /// Subscribe to live session updates.
  subscribe,

  /// Unsubscribe from live session updates.
  unsubscribe,

  /// Apply an authoritative [BufferSnapshot].
  snapshot,

  /// Apply a sequenced [BufferDelta] or detect a sequence gap.
  delta,

  /// Recover from a corrupt compressed session frame via a fresh keyframe.
  corruptFrame,
}

/// Per-session state holder and hierarchical state machine (`unsubscribed` ->
/// `awaitingKeyframe` -> `synchronized`) for a single remote PTY tab.
final class SessionSlot {
  /// Maximum queued [DirtyCellSpan] entries retained before promoting to a full sync.
  static const int maxDirtySpans = 64;

  /// Remote session identifier.
  final SessionId id;

  /// Paged primary-screen scrollback cache for this session.
  final ScrollbackPageCache scrollbackCache;

  /// Per-session cell selection controller.
  final TerminalSelectionController selectionController =
      TerminalSelectionController();

  /// Per-session scoped Kitty Graphics (`APC G`) texture registry.
  final KittyImageRegistry kittyRegistry = KittyImageRegistry();

  /// Currently hovered hyperlink on this session when `Ctrl`/`Cmd` is held.
  MatchedTerminalUrl? hoveredLink;

  /// Callback invoked when a snapshot, delta, or scrollback chunk mutates the view.
  final void Function() onVisualChange;

  /// Callback invoked when a resize or buffer reset invalidates active selection.
  final void Function() onClearSelection;

  /// Callback invoked when a delta sequence gap requires a fresh keyframe.
  final void Function() onRequestKeyframe;

  /// Callback invoked to fetch missing scrollback pages from the relay.
  final void Function(RequestScrollbackFrame frame) onRequestScrollback;

  /// Latest tab title reported by the directory.
  String title = '';

  /// Latest live shell title (`OSC 0`/`OSC 2`) reported via [ShellTitleFrame].
  String shellTitle = '';

  /// Explicit user-pinned tab title from directory metadata, or `null` if unpinned.
  String? pinnedTitle;

  /// Fallback unpinned directory title preserved across empty `ShellTitleFrame('')` resets.
  String directoryTitle = '';

  /// Last known column count from directory or snapshot metadata.
  int summaryCols = 80;

  /// Last known row count from directory or snapshot metadata.
  int summaryRows = 24;

  /// Active remote PTY width in columns (may be smaller than local pane size).
  int activePtyCols = 80;

  /// Active remote PTY height in rows (may be smaller than local pane size).
  int activePtyRows = 24;

  /// Unread terminal bell (`BEL`) counter for this session.
  int bellCount = 0;

  /// Hydrated live terminal screen buffer, or `null` before the first snapshot.
  Buffer? buffer;

  /// Packed bitset of soft-wrapped rows in [buffer].
  Uint8List liveWrappedRows = Uint8List(0);

  /// Latest applied frame sequence number (`0` when unhydrated).
  int seq = 0;

  /// Number of lines scrolled up into primary scrollback (`0` at live bottom).
  int scrollOffsetLines = 0;

  /// Number of columns panned right while viewing wide scrollback lines.
  int scrollOffsetCols = 0;

  /// Whether the initial tail scrollback page prefetch has been triggered.
  bool didInitialPrefetch = false;

  /// Latest cursor coordinates and visibility.
  CursorState cursor = CursorState.origin;

  /// Latest active terminal input modes.
  TerminalModes modes = TerminalModes.defaults;

  /// Process exit code if the session exited, or `null` while running.
  int? exitCode;

  /// Whether the session ended due to process exit rather than transport drop.
  bool endedByExit = false;

  /// Current synchronization state of [machine].
  ClientSessionSyncState state = .unsubscribed;

  Timer? _scrollbackRetryTimer;
  Timer? _inactiveTimer;
  Timer? _corruptRetryTimer;
  Duration _corruptRetryDelay = .zero;
  int _renderRevision = 0;
  int _fullSyncRevision = 0;
  final List<DirtyCellSpan> _dirtySpans = <DirtyCellSpan>[];
  late final List<DirtyCellSpan> _dirtySpansView =
      UnmodifiableListView<DirtyCellSpan>(_dirtySpans);

  /// Backing hierarchical state machine.
  late final Machine<ClientSessionSyncState, SessionSyncEvent> machine;

  /// Creates and starts a [SessionSlot] state machine.
  SessionSlot({
    required this.id,
    required Clock clock,
    required Duration requestTimeout,
    required this.onVisualChange,
    required this.onClearSelection,
    required this.onRequestKeyframe,
    required this.onRequestScrollback,
  }) : scrollbackCache = ScrollbackPageCache(
         clock: clock,
         requestTimeout: requestTimeout,
       ) {
    final blueprint =
        MachineBlueprint<ClientSessionSyncState, SessionSyncEvent>(
          name: 'client-session-${id.value}',
          root: .composite(
            id: .root,
            initial: .unsubscribed,
            children: [
              .composite(
                id: .unsubscribed,
                entry: _enterUnsubscribed,
                on: {
                  .subscribe: .to(
                    target: .awaitingKeyframe,
                    action: _onSubscribe,
                  ),
                },
              ),
              .composite(
                id: .awaitingKeyframe,
                entry: _enterAwaitingKeyframe,
                on: {
                  .snapshot: .to(target: .synchronized, action: _applySnapshot),
                  .corruptFrame: .to(action: _onCorruptFrame),
                  .unsubscribe: .to(target: .unsubscribed),
                },
              ),
              .composite(
                id: .synchronized,
                entry: () => state = .synchronized,
                on: {
                  .snapshot: .to(action: _applySnapshot),
                  .delta: .to(
                    target: .awaitingKeyframe,
                    guard: _tryApplyOrDetectGap,
                    action: _onGapDetected,
                  ),
                  .corruptFrame: .to(
                    target: .awaitingKeyframe,
                    action: _onCorruptFrame,
                  ),
                  .unsubscribe: .to(target: .unsubscribed),
                },
              ),
            ],
          ),
        );
    final (compiled, _) = blueprint.compile();
    machine = compiled!..start();
  }

  /// Effective column width of the hydrated buffer or directory summary.
  int get currentCols => buffer?.width ?? summaryCols;

  /// Effective row height of the hydrated buffer or directory summary.
  int get currentRows => buffer?.height ?? summaryRows;

  /// Monotonic revision incremented on every visual buffer or cursor update.
  int get renderRevision => _renderRevision;

  /// Revision of the most recent update requiring full viewport recomposition.
  int get fullSyncRevision => _fullSyncRevision;

  /// Bounded read-only view of dirty cell spans recorded since the last full sync.
  List<DirtyCellSpan> get dirtySpans => _dirtySpansView;

  /// Whether the active display title is explicitly pinned by a user rename.
  bool get isUserPinned => pinnedTitle != null;

  /// Resolved display title preferring [pinnedTitle], then [shellTitle], then [title].
  String get effectiveTitle {
    final pinned = pinnedTitle;
    if (pinned != null) return pinned;
    if (shellTitle.isNotEmpty) return shellTitle;
    return title.isNotEmpty ? title : directoryTitle;
  }

  /// Records an inbound terminal bell (`BEL`) event and notifies visual listeners.
  void recordBell() {
    bellCount++;
    onVisualChange();
  }

  /// Clears unread [bellCount] when acknowledged by user focus.
  void clearBellCount() {
    if (bellCount == 0) return;
    bellCount = 0;
    onVisualChange();
  }

  /// Applies a live [ShellTitleFrame] update without overriding [pinnedTitle].
  void applyShellTitle(String nextShellTitle) {
    shellTitle = nextShellTitle;
    if (pinnedTitle == null) {
      title = nextShellTitle.isNotEmpty ? nextShellTitle : directoryTitle;
    }
    onVisualChange();
  }

  /// Virtual row index corresponding to the top row of the current viewport.
  int get topVirtualRow => scrollbackCache.totalLines - scrollOffsetLines;

  /// Maximum lines this session can scroll up in its current state.
  int get maxScrollableLines => state == .unsubscribed
      ? max(scrollOffsetLines, scrollbackCache.offlineScrollableLines)
      : scrollbackCache.retainedLines;

  /// Whether primary-screen local scrollback is currently available on [slot].
  static bool canLocalScroll(SessionSlot? slot) {
    if (slot == null || slot.modes.altScreen) return false;
    if (slot.state != .unsubscribed) return true;
    return slot.buffer != null && slot.maxScrollableLines > 0;
  }

  /// Whether row [liveY] in [buffer] is soft-wrapped into the next row.
  bool isLiveRowWrapped(int liveY) =>
      unpackWrappedRow(liveWrappedRows, currentRows, liveY);

  /// Maximum horizontal column pan offset across visible scrollback rows.
  int maxHorizontalPanCols(int fallbackCols, int fallbackRows) {
    if (modes.altScreen || scrollOffsetLines <= 0) return 0;
    final cols = max(1, buffer?.width ?? fallbackCols);
    final rows = max(1, buffer?.height ?? fallbackRows);
    final topVirtual = topVirtualRow;
    final totalLines = scrollbackCache.totalLines;
    var maxRowWidth = cols;
    for (var screenY = 0; screenY < rows; screenY++) {
      final virtualY = topVirtual + screenY;
      if (virtualY < totalLines) {
        final cells = scrollbackCache.rowAt(virtualY)?.characters;
        if (cells != null) {
          final rowCols = _rowDisplayColumns(cells);
          if (rowCols > maxRowWidth) maxRowWidth = rowCols;
        }
      }
    }
    return max(0, maxRowWidth - cols);
  }

  static int _rowDisplayColumns(List<String> cells) {
    var width = 0;
    for (var i = 0; i < cells.length; i++) {
      final cell = cells[i];
      if (cell.isEmpty) {
        final precededByWide =
            i > 0 && cells[i - 1].isNotEmpty && graphemeWidth(cells[i - 1]) > 1;
        if (!precededByWide) {
          width += 1;
        }
        continue;
      }
      width += max(1, graphemeWidth(cell));
    }
    return width;
  }

  /// Clamps [scrollOffsetCols] to [maxHorizontalPanCols].
  void clampHorizontalPan(int fallbackCols, int fallbackRows) {
    scrollOffsetCols = scrollOffsetCols.clamp(
      0,
      maxHorizontalPanCols(fallbackCols, fallbackRows),
    );
  }

  /// Scrolls this slot's primary viewport by [deltaLines] (`> 0` up into history,
  /// `< 0` down toward live bottom) and returns `true` when the offset changed.
  bool scrollBy(
    int deltaLines, {
    required int viewportCols,
    required int viewportRows,
  }) {
    if (!canLocalScroll(this) || deltaLines == 0) return false;
    final nextOffset = (scrollOffsetLines + deltaLines).clamp(
      0,
      maxScrollableLines,
    );
    if (nextOffset == scrollOffsetLines) return false;
    scrollOffsetLines = nextOffset;
    clampHorizontalPan(viewportCols, viewportRows);
    if (nextOffset > 0 && state == .synchronized) {
      prefetchScrollbackIfNeeded();
    }
    return true;
  }

  /// Snaps this slot's viewport back to the live bottom (`lines = 0, cols = 0`).
  bool scrollToBottom() {
    if (scrollOffsetLines == 0 && scrollOffsetCols == 0) return false;
    scrollOffsetLines = 0;
    scrollOffsetCols = 0;
    return true;
  }

  /// Pans this slot's scrolled-up primary viewport horizontally by [deltaCols].
  bool panHorizontalBy(
    int deltaCols, {
    required int viewportCols,
    required int viewportRows,
  }) {
    if ((state == .unsubscribed && buffer == null) ||
        modes.altScreen ||
        scrollOffsetLines <= 0 ||
        deltaCols == 0) {
      return false;
    }
    final maxColsOffset = maxHorizontalPanCols(viewportCols, viewportRows);
    final nextCols = (scrollOffsetCols + deltaCols).clamp(0, maxColsOffset);
    if (nextCols == scrollOffsetCols) return false;
    scrollOffsetCols = nextCols;
    return true;
  }

  /// Applies a live [SessionSummary] from a directory update, resetting if the
  /// slot had previously exited.
  void applyDirectorySummary(SessionSummary entry) {
    if (endedByExit) {
      resetForRestartedProcess();
      onClearSelection();
    }
    title = entry.title;
    if (entry.isUserPinned) {
      pinnedTitle = entry.title;
    } else {
      pinnedTitle = null;
      if (shellTitle.isEmpty || directoryTitle.isEmpty) {
        directoryTitle = entry.title;
      }
    }
    summaryCols = entry.cols;
    summaryRows = entry.rows;
    if (buffer == null) {
      activePtyCols = entry.cols;
      activePtyRows = entry.rows;
    }
    exitCode = null;
  }

  /// Transitions this slot when the remote PTY exits or disconnects.
  void handleSessionEnded({required bool exited, int? exitCode}) {
    if (exitCode != null && (!endedByExit || exited)) {
      this.exitCode = exitCode;
    }
    if (exited) {
      endedByExit = true;
    }
    seq = 0;
    scrollbackCache.clearInFlight();
    _cancelRetryTimer();
    _resetCorruptRetry();
    if (state != .unsubscribed) {
      unawaited(machine.handle(.unsubscribe));
    }
  }

  /// Clears exited state and cached buffers when a session ID is reused by a restarted caster.
  void resetForRestartedProcess() {
    endedByExit = false;
    exitCode = null;
    seq = 0;
    buffer = null;
    liveWrappedRows = Uint8List(0);
    shellTitle = '';
    pinnedTitle = null;
    bellCount = 0;
    activePtyCols = summaryCols;
    activePtyRows = summaryRows;
    scrollOffsetLines = 0;
    scrollOffsetCols = 0;
    didInitialPrefetch = false;
    hoveredLink = null;
    selectionController.clearSelection();
    kittyRegistry.clearImages();
    scrollbackCache.reset();
    _cancelRetryTimer();
    _resetCorruptRetry();
    _markFullSync();
  }

  void _enterUnsubscribed() {
    state = .unsubscribed;
    cancelInactiveTimer();
    _cancelRetryTimer();
    _resetCorruptRetry();
  }

  /// Cancels any pending background-tab inactivity suspension timer.
  void cancelInactiveTimer() {
    _inactiveTimer?.cancel();
    _inactiveTimer = null;
  }

  /// Schedules [onFire] after [grace] while this slot is subscribed in the background.
  void scheduleInactiveSuspend(Duration grace, void Function() onFire) {
    cancelInactiveTimer();
    if (state == .unsubscribed || grace <= .zero) return;
    _inactiveTimer = Timer(grace, () {
      _inactiveTimer = null;
      onFire();
    });
  }

  void _enterAwaitingKeyframe() {
    state = .awaitingKeyframe;
    _cancelRetryTimer();
  }

  void _onSubscribe(SessionSyncEvent? _, Object? _) {
    seq = 0;
    exitCode = null;
  }

  void _applySnapshot(SessionSyncEvent? _, Object? data) {
    final wasSynchronized = state == .synchronized;
    state = .synchronized;
    _resetCorruptRetry();
    final snapshot = data as BufferSnapshot;
    final prevBuffer = buffer;
    // Skip only exact duplicate snapshots at identical viewport dimensions;
    // a restarted caster or freshly resized snapshot at the same seq must apply.
    if (wasSynchronized &&
        prevBuffer != null &&
        snapshot.seq == seq &&
        prevBuffer.width == snapshot.cols &&
        prevBuffer.height == snapshot.rows) {
      return;
    }
    final prevAltScreen = modes.altScreen;
    final prevTotalLines = scrollbackCache.totalLines;
    final dimsChanged =
        prevBuffer != null &&
        (prevBuffer.width != snapshot.cols ||
            prevBuffer.height != snapshot.rows);
    buffer = snapshot.toBuffer()
      ..registerKittyRegistry(
        Rect(0, 0, snapshot.cols, snapshot.rows),
        kittyRegistry,
      );
    liveWrappedRows = snapshot.wrappedRows;
    seq = snapshot.seq;
    cursor = snapshot.cursor;
    modes = snapshot.modes;
    summaryCols = snapshot.cols;
    summaryRows = snapshot.rows;
    activePtyCols = snapshot.cols;
    activePtyRows = snapshot.rows;
    _replaceKittyImages(snapshot.kittyImages);
    scrollbackCache.clearInFlight();
    _cancelRetryTimer();
    final invalidated = scrollbackCache.updateWindow(snapshot.scrollback);
    _updateScrollOffsetAfterWindowChange(
      prevTotalLines: prevTotalLines,
      prevAltScreen: prevAltScreen,
      nextAltScreen: snapshot.modes.altScreen,
      invalidated: invalidated,
    );
    if (dimsChanged) {
      onClearSelection();
    }
    _markFullSync();
    _prefetchAfterSnapshot();
    onVisualChange();
  }

  void _prefetchAfterSnapshot() {
    if (modes.altScreen || scrollbackCache.retainedLines == 0) return;
    if (scrollOffsetLines > 0) {
      prefetchScrollbackIfNeeded();
      return;
    }
    if (!didInitialPrefetch) {
      didInitialPrefetch = true;
      final tailStart = max(
        scrollbackCache.oldestLine,
        scrollbackCache.totalLines - ScrollbackPageCache.pageSize,
      );
      _dispatchPlannedRequests(tailStart, scrollbackCache.totalLines);
      _syncRetryTimer();
    }
  }

  /// Applies valid deltas in place and returns `false` to stay in `synchronized`,
  /// or returns `true` on sequence/dimension mismatch to transition to `awaitingKeyframe`.
  bool _tryApplyOrDetectGap(SessionSyncEvent? _, Object? data) {
    final delta = data as BufferDelta;
    if (delta.seq <= seq) return false;
    final targetBuffer = buffer;
    if (targetBuffer == null) return true;

    final applied = BufferFrameCodec.applyDelta(
      buffer: targetBuffer,
      currentSeq: seq,
      delta: delta,
    );
    if (!applied) return true;

    _applyDeltaKittyChanges(delta);
    final prevAltScreen = modes.altScreen;
    final prevTotalLines = scrollbackCache.totalLines;
    liveWrappedRows = delta.wrappedRows;
    seq = delta.seq;
    cursor = delta.cursor;
    modes = delta.modes;
    activePtyCols = delta.cols;
    activePtyRows = delta.rows;
    final hasKittyMutation =
        delta.clearKittyImages ||
        (delta.kittyRemovals?.isNotEmpty ?? false) ||
        (delta.kittyUpserts?.isNotEmpty ?? false);
    final invalidated = scrollbackCache.updateWindow(delta.scrollback);
    _updateScrollOffsetAfterWindowChange(
      prevTotalLines: prevTotalLines,
      prevAltScreen: prevAltScreen,
      nextAltScreen: delta.modes.altScreen,
      invalidated: invalidated,
    );
    _recordDeltaRevision(
      delta.runs,
      forceFullSync:
          hasKittyMutation ||
          invalidated ||
          prevAltScreen != delta.modes.altScreen,
    );
    if (scrollOffsetLines > 0 && !modes.altScreen) {
      prefetchScrollbackIfNeeded();
    }
    onVisualChange();
    return false;
  }

  void _markFullSync() {
    _renderRevision += 1;
    _fullSyncRevision = _renderRevision;
    _dirtySpans.clear();
  }

  void _recordDeltaRevision(List<CellRun> runs, {required bool forceFullSync}) {
    _renderRevision += 1;
    if (forceFullSync || _dirtySpans.length + runs.length > maxDirtySpans) {
      _fullSyncRevision = _renderRevision;
      _dirtySpans.clear();
      return;
    }
    final rev = _renderRevision;
    for (final run in runs) {
      _dirtySpans.add((
        revision: rev,
        start: run.startIndex,
        length: run.characters.length,
      ));
    }
  }

  void _updateScrollOffsetAfterWindowChange({
    required int prevTotalLines,
    required bool prevAltScreen,
    required bool nextAltScreen,
    required bool invalidated,
  }) {
    if (invalidated) {
      scrollOffsetLines = 0;
      scrollOffsetCols = 0;
      didInitialPrefetch = false;
      onClearSelection();
      return;
    }
    if (prevAltScreen != nextAltScreen) {
      scrollOffsetLines = 0;
      scrollOffsetCols = 0;
      onClearSelection();
      return;
    }
    if (scrollOffsetLines > 0) {
      final added = max(0, scrollbackCache.totalLines - prevTotalLines);
      scrollOffsetLines = (scrollOffsetLines + added).clamp(
        0,
        scrollbackCache.retainedLines,
      );
      clampHorizontalPan(currentCols, currentRows);
    } else {
      scrollOffsetCols = 0;
    }
  }

  /// Requests any uncached scrollback pages intersecting the current viewport or lookahead window.
  void prefetchScrollbackIfNeeded() {
    if (state != .synchronized ||
        modes.altScreen ||
        scrollOffsetLines <= 0 ||
        scrollbackCache.retainedLines == 0) {
      _syncRetryTimer();
      return;
    }
    final visTop = max(scrollbackCache.oldestLine, topVirtualRow);
    final visEnd = min(scrollbackCache.totalLines, visTop + currentRows);
    prefetchScrollbackForRange(visTop, visEnd);
  }

  /// Requests uncached scrollback pages intersecting `[startLine, endLine)` plus
  /// a 1-page upward lookahead, keeping the retry timer armed.
  void prefetchScrollbackForRange(int startLine, int endLine) {
    if (state != .synchronized ||
        modes.altScreen ||
        scrollbackCache.retainedLines == 0) {
      _syncRetryTimer();
      return;
    }
    final clampedStart = startLine.clamp(
      scrollbackCache.oldestLine,
      scrollbackCache.totalLines,
    );
    final clampedEnd = endLine.clamp(clampedStart, scrollbackCache.totalLines);
    _dispatchPlannedRequests(clampedStart, clampedEnd);
    final lookaheadStart = max(
      scrollbackCache.oldestLine,
      clampedStart - ScrollbackPageCache.pageSize,
    );
    _dispatchPlannedRequests(lookaheadStart, clampedStart);
    _syncRetryTimer();
  }

  void _dispatchPlannedRequests(int startLine, int endLine) {
    for (final req in scrollbackCache.planRequests(
      sessionId: id,
      startLine: startLine,
      endLine: endLine,
    )) {
      onRequestScrollback(req);
    }
  }

  void _syncRetryTimer() {
    _cancelRetryTimer();
    if (state != .synchronized) return;
    final delay = scrollbackCache.nextExpiryDelay();
    if (delay == null) return;
    _scrollbackRetryTimer = Timer(delay, prefetchScrollbackIfNeeded);
  }

  void _cancelRetryTimer() {
    _scrollbackRetryTimer?.cancel();
    _scrollbackRetryTimer = null;
  }

  /// Ingests an incoming [ScrollbackChunkFrame] and triggers follow-up prefetches.
  void ingestScrollbackChunk(ScrollbackChunkFrame chunk) {
    if (state != .synchronized) return;
    if (!scrollbackCache.ingestChunk(chunk)) {
      _syncRetryTimer();
      return;
    }
    scrollOffsetLines = scrollOffsetLines.clamp(
      0,
      scrollbackCache.retainedLines,
    );
    clampHorizontalPan(currentCols, currentRows);
    _markFullSync();
    prefetchScrollbackIfNeeded();
    onVisualChange();
  }

  void _onGapDetected(SessionSyncEvent? _, Object? _) {
    _cancelRetryTimer();
    onRequestKeyframe();
    onVisualChange();
  }

  void _onCorruptFrame(SessionSyncEvent? _, Object? _) {
    _cancelRetryTimer();
    if (_corruptRetryDelay == .zero) {
      _corruptRetryDelay = const Duration(milliseconds: 250);
      onRequestKeyframe();
    } else if (_corruptRetryTimer == null) {
      final delay = _corruptRetryDelay;
      final doubledMs = delay.inMilliseconds * 2;
      _corruptRetryDelay = Duration(milliseconds: min(doubledMs, 5000));
      _corruptRetryTimer = Timer(delay, _fireCorruptKeyframeRetry);
    }
    onVisualChange();
  }

  void _fireCorruptKeyframeRetry() {
    _corruptRetryTimer = null;
    if (state != .awaitingKeyframe) return;
    onRequestKeyframe();
  }

  void _resetCorruptRetry() {
    _corruptRetryTimer?.cancel();
    _corruptRetryTimer = null;
    _corruptRetryDelay = .zero;
  }

  void _replaceKittyImages(List<KittyImagePayload>? images) {
    kittyRegistry.clearImages();
    if (images == null) return;
    for (final payload in images) {
      kittyRegistry.registerImage(payload.toImageData());
    }
  }

  void _applyDeltaKittyChanges(BufferDelta delta) {
    if (delta.clearKittyImages) {
      kittyRegistry.clearImages();
    }
    if (delta.kittyRemovals case final removals?) {
      for (final imageId in removals) {
        kittyRegistry.unregisterImage(imageId);
      }
    }
    if (delta.kittyUpserts case final upserts?) {
      for (final payload in upserts) {
        kittyRegistry.registerImage(payload.toImageData());
      }
    }
  }

  /// Stops timers and the backing state machine.
  void dispose() {
    cancelInactiveTimer();
    _cancelRetryTimer();
    _resetCorruptRetry();
    hoveredLink = null;
    selectionController.dispose();
    kittyRegistry.clearImages();
    machine.stop();
  }
}
