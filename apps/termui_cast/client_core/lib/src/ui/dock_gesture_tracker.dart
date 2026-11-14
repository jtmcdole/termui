import 'dart:math';

import 'package:clock/clock.dart';
import 'package:meta/meta.dart';
import 'package:termui/termui.dart';
import 'package:termui_cast_protocol/termui_cast_protocol.dart';

import '../models.dart';
import 'dock_tab_layout.dart';

/// Result emitted by [DockGestureTracker.handleMouseEvent] for `SessionDockBar`.
@immutable
sealed class DockGestureResult {
  /// Whether `SessionDockBar` consumed the mouse event.
  final bool handled;

  /// Whether pointer capture just ended and keyboard focus should return to PTY.
  final bool restorePtyFocus;

  const DockGestureResult({
    required this.handled,
    this.restorePtyFocus = false,
  });
}

/// Event was ignored or outside the dock while no gesture was active.
final class DockGestureIgnored extends DockGestureResult {
  /// Singleton ignored outcome.
  const DockGestureIgnored() : super(handled: false);
}

/// Event was consumed with no additional domain command.
final class DockGestureConsumed extends DockGestureResult {
  /// Creates a consumed gesture outcome.
  const DockGestureConsumed({super.restorePtyFocus = false})
    : super(handled: true);
}

/// Immediate dock control or tab selection triggered on pointer press.
final class DockGestureActivate extends DockGestureResult {
  /// Triggered hit-region action.
  final DockHitAction action;

  /// Target session when [action] is [DockHitAction.selectSession].
  final SessionId? sessionId;

  /// Creates an immediate control activation outcome.
  const DockGestureActivate({
    required this.action,
    this.sessionId,
    super.restorePtyFocus = false,
  }) : super(handled: true);
}

/// Mouse wheel scroll step along the dock's overflow axis.
final class DockGestureScroll extends DockGestureResult {
  /// Signed scroll delta (`< 0` backward/up/left, `> 0` forward/down/right).
  final int delta;

  /// Creates a scroll gesture outcome.
  const DockGestureScroll(this.delta) : super(handled: true);
}

/// Live tab reorder step during an active click-and-drag gesture.
final class DockGestureReorder extends DockGestureResult {
  /// Session tab being dragged.
  final SessionId sessionId;

  /// New 0-based index in the tab strip, or `null` when no midpoint was crossed.
  final int? targetIndex;

  /// Optional overflow scroll nudge (`-1`, `0`, or `+1`) when dragging at edges.
  final int edgeScrollDirection;

  /// Grab offset in columns from the tab's left edge.
  final int grabOffsetCols;

  /// 0-based dock-local X coordinate of the pointer.
  final int localX;

  /// 0-based dock-local Y coordinate of the pointer.
  final int localY;

  /// 1-based global mouse coordinate where the tab press started.
  final Point<int> startGlobalPosition;

  /// 1-based global mouse coordinate of the current drag event.
  final Point<int> globalPosition;

  /// Creates a tab reorder outcome.
  const DockGestureReorder({
    required this.sessionId,
    required this.targetIndex,
    this.edgeScrollDirection = 0,
    required this.grabOffsetCols,
    required this.localX,
    required this.localY,
    required this.startGlobalPosition,
    required this.globalPosition,
  }) : super(handled: true);
}

/// Cancelled click-and-drag gesture requiring rollback to [originalIndex].
final class DockGestureCancelDrag extends DockGestureResult {
  /// Session tab whose drag was cancelled.
  final SessionId sessionId;

  /// Original 0-based index before the drag started.
  final int originalIndex;

  /// Creates a drag-cancellation rollback outcome.
  const DockGestureCancelDrag({
    required this.sessionId,
    required this.originalIndex,
  }) : super(handled: true, restorePtyFocus: true);
}

/// Confirmed `[x]` tab dismissal on pointer release inside the `[x]` hit box.
final class DockGestureDismiss extends DockGestureResult {
  /// Ended session to dismiss.
  final SessionId sessionId;

  /// Creates a confirmed `[x]` dismiss outcome.
  const DockGestureDismiss(this.sessionId)
    : super(handled: true, restorePtyFocus: true);
}

/// Confirmed double-click on a tab requesting the rename modal.
final class DockGestureRename extends DockGestureResult {
  /// Target session whose tab was double-clicked.
  final SessionId sessionId;

  /// Creates a double-click rename outcome.
  const DockGestureRename(this.sessionId)
    : super(handled: true, restorePtyFocus: true);
}

/// Pure-Dart pointer state machine disambiguating tab click, double-click
/// rename, click-and-drag reorder (including perpendicular mouse drift), `[x]`
/// release dismissal, and overflow wheel scrolling.
final class DockGestureTracker {
  /// Maximum interval between two tab releases to count as a double-click.
  static const Duration defaultDoubleClickWindow = Duration(milliseconds: 350);

  /// Horizontal drag threshold in columns before reordering starts in `.top`.
  static const int topDragThresholdCols = 2;

  /// Vertical drag threshold in rows before reordering starts in `.left`.
  static const int leftDragThresholdRows = 1;

  static final Clock _zoneClock = Clock(() => clock.now());

  final Clock _clock;

  /// Maximum interval between two non-drag releases on the same tab.
  final Duration doubleClickWindow;

  _ActiveGesture? _active;
  _LastTabRelease? _lastRelease;

  /// Creates a gesture tracker with an optional injected [Clock].
  DockGestureTracker({
    Clock? clock,
    this.doubleClickWindow = defaultDoubleClickWindow,
  }) : _clock = clock ?? _zoneClock;

  /// Whether a left-button press or drag is currently captured by the dock.
  bool get hasActiveGesture => _active != null;

  /// Session currently being dragged past the drag threshold, or `null`.
  SessionId? get draggingSessionId => switch (_active) {
    _TabPressGesture(:final sessionId, isDragging: true) => sessionId,
    _ => null,
  };

  /// Cancels any active press/drag gesture, returning the original tab index
  /// if a live drag reorder should be rolled back (e.g. on `Escape`).
  ({SessionId sessionId, int originalIndex})? cancelActiveDrag() {
    final current = _active;
    _active = null;
    if (current is _TabPressGesture && current.isDragging) {
      return (
        sessionId: current.sessionId,
        originalIndex: current.initialIndex,
      );
    }
    return null;
  }

  /// Processes a 1-based [MouseEvent] against `([width], [height])` and [layout].
  DockGestureResult handleMouseEvent({
    required MouseEvent event,
    required int width,
    required int height,
    required DockPosition dock,
    required DockTabLayout layout,
    required List<DockHitRegion> chromeHitRegions,
  }) {
    if (_isSyntheticCancelRelease(event)) {
      return _handleSyntheticCancel();
    }

    final localX = event.x - 1;
    final localY = event.y - 1;
    final inBounds = _isInBounds(localX, localY, width, height);
    if (_active == null && !inBounds) {
      return const DockGestureIgnored();
    }
    if (_isWheelPress(event)) {
      return _handleWheel(event.button, dock);
    }

    return _dispatchPointerEvent(
      event: event,
      localX: localX,
      localY: localY,
      inBounds: inBounds,
      dock: dock,
      layout: layout,
      chromeHitRegions: chromeHitRegions,
    );
  }

  static bool _isSyntheticCancelRelease(MouseEvent event) =>
      event.type == .release && event.x == -1 && event.y == -1;

  DockGestureResult _handleSyntheticCancel() {
    final rollback = cancelActiveDrag();
    if (rollback != null) {
      return DockGestureCancelDrag(
        sessionId: rollback.sessionId,
        originalIndex: rollback.originalIndex,
      );
    }
    return const DockGestureConsumed(restorePtyFocus: true);
  }

  static bool _isInBounds(int localX, int localY, int width, int height) =>
      localX >= 0 && localY >= 0 && localX < width && localY < height;

  static bool _isWheelPress(MouseEvent event) =>
      event.type == .press &&
      (event.button == .wheelUp || event.button == .wheelDown);

  DockGestureResult _dispatchPointerEvent({
    required MouseEvent event,
    required int localX,
    required int localY,
    required bool inBounds,
    required DockPosition dock,
    required DockTabLayout layout,
    required List<DockHitRegion> chromeHitRegions,
  }) => switch (event.type) {
    .press when event.button == .left && inBounds => _handleLeftPress(
      event: event,
      localX: localX,
      localY: localY,
      dock: dock,
      layout: layout,
      chromeHitRegions: chromeHitRegions,
    ),
    .drag when _active != null => _handleDrag(
      event: event,
      localX: localX,
      localY: localY,
      dock: dock,
      layout: layout,
    ),
    .release when _active != null => _handleRelease(
      localX: localX,
      localY: localY,
      inBounds: inBounds,
      dock: dock,
      layout: layout,
    ),
    .release when inBounds => const DockGestureConsumed(restorePtyFocus: true),
    _ =>
      _active != null
          ? const DockGestureConsumed()
          : const DockGestureIgnored(),
  };

  DockGestureResult _handleWheel(MouseButton button, DockPosition dock) {
    final step = dock == .top
        ? DockTabLayout.topScrollStepCols
        : DockTabLayout.leftScrollStepRows;
    return DockGestureScroll(button == .wheelUp ? -step : step);
  }

  DockGestureResult _handleLeftPress({
    required MouseEvent event,
    required int localX,
    required int localY,
    required DockPosition dock,
    required DockTabLayout layout,
    required List<DockHitRegion> chromeHitRegions,
  }) {
    final hit =
        layout.hitTest(localX, localY) ??
        _hitTestList(chromeHitRegions, localX, localY);
    if (hit == null) {
      _lastRelease = null;
      _active = const _PassivePressGesture();
      return const DockGestureConsumed();
    }

    if (hit.action == .dismissSession && hit.sessionId != null) {
      _lastRelease = null;
      _active = _DismissPressGesture(sessionId: hit.sessionId!);
      return const DockGestureConsumed();
    }

    if (hit.action == .selectSession && hit.sessionId != null) {
      final sessionId = hit.sessionId!;
      final primary = dock == .top ? localX : localY;
      final tabIndex = layout.indexOf(sessionId) ?? 0;
      _active = _TabPressGesture(
        sessionId: sessionId,
        initialIndex: tabIndex,
        startPrimary: primary,
        grabOffsetCols: _computeGrabOffsetCols(sessionId, localX, layout),
        startGlobal: _globalPointOf(event),
      );
      return DockGestureActivate(action: .selectSession, sessionId: sessionId);
    }

    _lastRelease = null;
    if (!hit.action.opensModal) {
      _active = const _PassivePressGesture();
    }
    return DockGestureActivate(
      action: hit.action,
      sessionId: hit.sessionId,
      restorePtyFocus: false,
    );
  }

  static int _computeGrabOffsetCols(
    SessionId sessionId,
    int localX,
    DockTabLayout layout,
  ) {
    final tab = layout.renderedTabFor(sessionId);
    if (tab == null) return 0;
    return (localX - tab.x).clamp(0, max(0, tab.visibleCols - 1));
  }

  static Point<int> _globalPointOf(MouseEvent event) =>
      Point<int>(event.globalX ?? event.x, event.globalY ?? event.y);

  DockGestureResult _handleDrag({
    required MouseEvent event,
    required int localX,
    required int localY,
    required DockPosition dock,
    required DockTabLayout layout,
  }) {
    final current = _active;
    if (current is! _TabPressGesture) {
      return const DockGestureConsumed();
    }

    final rawPrimary = dock == .top ? localX : localY;
    final threshold = dock == .top
        ? topDragThresholdCols
        : leftDragThresholdRows;
    if (!current.isDragging &&
        (rawPrimary - current.startPrimary).abs() >= threshold) {
      current.isDragging = true;
      _lastRelease = null;
    }
    if (!current.isDragging || layout.viewportEnd <= layout.viewportStart) {
      return const DockGestureConsumed();
    }

    final clampedPrimary = rawPrimary.clamp(
      layout.viewportStart,
      layout.viewportEnd - 1,
    );
    final edgeDir = _computeEdgeScroll(rawPrimary, layout);
    final targetIndex = layout.targetIndexForDrag(
      current.sessionId,
      clampedPrimary,
    );
    return DockGestureReorder(
      sessionId: current.sessionId,
      targetIndex: targetIndex,
      edgeScrollDirection: edgeDir,
      grabOffsetCols: current.grabOffsetCols,
      localX: localX,
      localY: localY,
      startGlobalPosition: current.startGlobal,
      globalPosition: _globalPointOf(event),
    );
  }

  DockGestureResult _handleRelease({
    required int localX,
    required int localY,
    required bool inBounds,
    required DockPosition dock,
    required DockTabLayout layout,
  }) {
    final finished = _active;
    _active = null;

    if (finished is _DismissPressGesture) {
      if (!inBounds) {
        return const DockGestureConsumed(restorePtyFocus: true);
      }
      final hit = layout.hitTest(localX, localY);
      if (hit != null &&
          hit.action == .dismissSession &&
          hit.sessionId == finished.sessionId) {
        return DockGestureDismiss(finished.sessionId);
      }
      return const DockGestureConsumed(restorePtyFocus: true);
    }

    if (finished is _TabPressGesture && !finished.isDragging && inBounds) {
      final primary = dock == .top ? localX : localY;
      final now = _clock.now();
      final prev = _lastRelease;
      if (prev != null &&
          prev.sessionId == finished.sessionId &&
          now.difference(prev.at) <= doubleClickWindow &&
          (primary - prev.primary).abs() <= 2) {
        _lastRelease = null;
        return DockGestureRename(finished.sessionId);
      }
      _lastRelease = _LastTabRelease(
        sessionId: finished.sessionId,
        at: now,
        primary: primary,
      );
    }

    return const DockGestureConsumed(restorePtyFocus: true);
  }

  static int _computeEdgeScroll(int rawPrimary, DockTabLayout layout) {
    if (!layout.hasOverflow) return 0;
    if (rawPrimary <= layout.viewportStart && layout.clampedScrollOffset > 0) {
      return -1;
    }
    if (rawPrimary >= layout.viewportEnd - 1 &&
        layout.clampedScrollOffset < layout.maxScrollOffset) {
      return 1;
    }
    return 0;
  }

  static DockHitRegion? _hitTestList(
    List<DockHitRegion> regions,
    int x,
    int y,
  ) {
    for (final region in regions) {
      if (region.contains(x, y)) return region;
    }
    return null;
  }
}

sealed class _ActiveGesture {
  const _ActiveGesture();
}

final class _PassivePressGesture extends _ActiveGesture {
  const _PassivePressGesture();
}

final class _DismissPressGesture extends _ActiveGesture {
  final SessionId sessionId;
  const _DismissPressGesture({required this.sessionId});
}

final class _TabPressGesture extends _ActiveGesture {
  final SessionId sessionId;
  final int initialIndex;
  final int startPrimary;
  final int grabOffsetCols;
  final Point<int> startGlobal;
  bool isDragging = false;

  _TabPressGesture({
    required this.sessionId,
    required this.initialIndex,
    required this.startPrimary,
    required this.grabOffsetCols,
    required this.startGlobal,
  });
}

final class _LastTabRelease {
  final SessionId sessionId;
  final DateTime at;
  final int primary;

  const _LastTabRelease({
    required this.sessionId,
    required this.at,
    required this.primary,
  });
}
