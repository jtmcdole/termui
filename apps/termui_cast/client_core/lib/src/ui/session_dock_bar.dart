import 'dart:async';
import 'dart:math';

import 'package:clock/clock.dart';
import 'package:termui/termui.dart';
import 'package:termui_cast_protocol/termui_cast_protocol.dart';

import '../models.dart';
import 'dialog_theme.dart';
import 'dock_gesture_tracker.dart';
import 'dock_tab_layout.dart';
import 'view_model_scene_renderer.dart';

/// Chrome layer renderer displaying multi-PTY tabs (`top` or `left`),
/// lifecycle countdowns (`⏳`, `⏻`, `💀`), `[x]` dismissal, overflow scrolling,
/// click-and-drag reordering, and `[Stats]`, `[?]`, and `[Dock]` controls.
final class SessionDockBar extends ViewModelSceneRenderer {
  /// Height in rows when docked at the top edge.
  static const int topBarHeight = 1;

  /// Width in columns when docked at the left edge.
  static const int leftSidebarWidth = 22;

  static const int _minInlineNoticeCols = 24;

  static final RegExp _controlChars = RegExp(r'[\x00-\x1F\x7F-\x9F]');

  static const Style _barStyle = Style(
    foreground: Color(200, 210, 225),
    background: Color(24, 28, 36),
  );
  static const Style _inactiveDeadTabStyle = Style(
    foreground: Color(225, 195, 198),
    background: Color(96, 22, 30),
  );
  static const Style _inactiveCountdownTabStyle = Style(
    foreground: Color(20, 24, 32),
    background: Color(178, 138, 54),
  );
  static const Style _dismissYellowBadgeStyle = Style(
    foreground: Color(255, 245, 235),
    background: Color(120, 72, 18),
    modifiers: Modifier.bold,
  );
  static const Style _dismissRedBadgeStyle = Style(
    foreground: Color(255, 240, 240),
    background: Color(64, 12, 18),
    modifiers: Modifier.bold,
  );
  static const Style _dropSlotStyle = Style(
    foreground: Color(82, 96, 122),
    background: Color(18, 21, 28),
  );
  static const DockTabDragData _defaultAnchorDragData = DockTabDragData(
    sessionId: SessionId(''),
    label: '',
    widthCols: 0,
    grabOffsetCols: 0,
    globalMousePosition: Point<int>(1, 1),
    style: _barStyle,
  );

  /// Callback invoked when the user clicks an auth/connection banner to re-open the modal.
  void Function()? onRequestConnectionPrompt;

  /// Callback invoked when the user clicks `[?]` to open the chords help modal.
  void Function()? onRequestChordsHelp;

  /// Callback invoked when the user clicks `[Stats]` to open the Stats for Nerds modal.
  void Function()? onRequestStats;

  /// Callback invoked when the user clicks `[⚙]` to open the Settings modal.
  void Function()? onRequestSettings;

  /// Callback invoked when the user double-clicks a tab to request renaming it.
  void Function(SessionId sessionId)? onRequestRenameSession;

  /// Callback invoked when a captured dock pointer gesture finishes and PTY focus should be restored.
  void Function()? onReleasePointerFocus;

  /// Optional key event delegate invoked when this dock layer holds scene focus.
  bool Function(KeyEvent event)? onKeyEvent;

  final DockGestureTracker _gestureTracker;
  late final StackElement _dragRootElement;
  final List<DockHitRegion> _chromeHitRegions = [];
  DockTabLayout _tabLayout = .empty;
  int _topScrollCols = 0;
  int _leftScrollRows = 0;
  SessionId? _lastObservedActiveId;
  DockPosition? _lastObservedDock;
  TerminalColorTheme? _lastResolvedTheme;
  WorkspaceChromeTheme _cachedChromeTheme = WorkspaceChromeTheme.defaultDark;

  /// Creates a session dock renderer bound to [viewModel].
  SessionDockBar({
    required super.viewModel,
    Clock? clock,
    this.onRequestConnectionPrompt,
    this.onRequestChordsHelp,
    this.onRequestStats,
    this.onRequestSettings,
    this.onRequestRenameSession,
    this.onReleasePointerFocus,
    this.onKeyEvent,
  }) : _gestureTracker = DockGestureTracker(clock: clock),
       super(initialWidth: 80, initialHeight: topBarHeight) {
    _dragRootElement =
        Stack([_buildAnchorDraggable()]).createElement() as StackElement
          ..mount(null);
    render();
  }

  /// Whether a mouse press or drag gesture is currently active on the dock.
  bool get hasActivePointerGesture => _gestureTracker.hasActiveGesture;

  /// Current horizontal scroll offset in columns when docked at [DockPosition.top].
  int get topScrollOffsetCols => _topScrollCols;

  /// Current vertical scroll offset in rows when docked at [DockPosition.left].
  int get leftScrollOffsetRows => _leftScrollRows;

  /// Latest computed tab layout snapshot for hit-testing and inspection.
  DockTabLayout get tabLayout => _tabLayout;

  /// Whether [session] was initiated by this dock instance's anchor element.
  bool ownsDragSession(DragSession? session) =>
      session != null && session.sourceElement == _anchorDraggableElement;

  /// Whether [DragDropManager.activeSession] belongs to this dock instance.
  bool get ownsActiveDragSession =>
      ownsDragSession(DragDropManager.activeSession);

  /// Cancels any in-progress tab drag and restores the tab's pre-drag index.
  bool cancelActiveDrag() {
    final rollback = _gestureTracker.cancelActiveDrag();
    if (rollback == null) return false;
    if (ownsActiveDragSession) {
      DragDropManager.cancelDrag();
    }
    if (!viewModel.moveSession(rollback.sessionId, rollback.originalIndex)) {
      render();
    }
    return true;
  }

  WorkspaceChromeTheme get _chromeTheme {
    final activeTheme = viewModel.activeTerminalTheme;
    if (!identical(activeTheme, _lastResolvedTheme) &&
        activeTheme != _lastResolvedTheme) {
      _lastResolvedTheme = activeTheme;
      _cachedChromeTheme = WorkspaceChromeTheme.fromTerminalTheme(activeTheme);
    }
    return _cachedChromeTheme;
  }

  @override
  bool get wantsMouseTracking => true;

  @override
  bool get wantsAlternateScreen => false;

  @override
  void render() {
    if (isDisposed) return;
    _chromeHitRegions.clear();
    _tabLayout = .empty;
    final buffer = Buffer.blank(width, height);
    _fillSolidBackground(buffer);
    switch (viewModel.dockPosition) {
      case .left:
        _paintLeftSidebar(buffer);
      case .top:
        _paintTopBar(buffer);
      case .hidden:
        if (viewModel.hasAttentionBanner) {
          _paintTopBar(buffer);
        }
    }
    _abortOrphanedDragIfNeeded();
    commitBuffer(buffer);
  }

  void _abortOrphanedDragIfNeeded() {
    final draggingId = _gestureTracker.draggingSessionId;
    if (draggingId == null) return;
    if (viewModel.dockPosition == .hidden ||
        viewModel.hasAttentionBanner ||
        _tabLayout.indexOf(draggingId) == null) {
      _gestureTracker.cancelActiveDrag();
      if (ownsActiveDragSession) {
        DragDropManager.cancelDrag();
      }
    }
  }

  void _syncDragTargetTree() {
    _dragRootElement
      ..update(
        Stack([
          _buildAnchorDraggable(),
          for (final tab in _tabLayout.visibleTabs)
            Positioned(
              left: tab.x,
              top: tab.y,
              width: tab.visibleCols,
              height: 1,
              child: DragTarget<DockTabDragData>(
                builder: (_, _, _) =>
                    SizedBox(width: tab.visibleCols, height: 1),
              ),
            ),
        ]),
      )
      ..layout(BoxConstraints.tight(Size(width, height)));
  }

  static Draggable<DockTabDragData> _buildAnchorDraggable() =>
      const Draggable<DockTabDragData>(
        data: _defaultAnchorDragData,
        child: SizedBox(width: 1, height: 1),
      );

  Element get _anchorDraggableElement => _dragRootElement.childElements.first;

  void _fillSolidBackground(Buffer buffer) {
    final blankLine = ' ' * buffer.width;
    final style = _chromeTheme.barStyle;
    for (var y = 0; y < buffer.height; y++) {
      buffer.writeString(0, y, blankLine, style);
    }
  }

  void _paintTopBar(Buffer buffer) {
    final maxTabX = _paintTopRightControls(buffer);

    if (viewModel.hasAttentionBanner) {
      _paintTopAttentionBanner(buffer, maxTabX);
      return;
    }

    final sessions = viewModel.sessions;
    final usedWidth = sessions.isEmpty
        ? _paintTopEmptyLabel(buffer, maxTabX)
        : _paintTopTabs(buffer, maxTabX);

    if (viewModel.clipboardNotice case final notice?) {
      _paintTopClipboardNotice(buffer, notice, usedWidth, maxTabX);
    }
  }

  void _paintTopAttentionBanner(Buffer buffer, int maxTabX) {
    final bannerText = DockTabLayout.clipAndPadRight(
      viewModel.statusBanner ?? ' ! Disconnected',
      maxTabX,
    );
    buffer.writeString(
      0,
      0,
      bannerText,
      _bannerStyleFor(viewModel.connectionState, _chromeTheme),
    );
    _chromeHitRegions.add(
      DockHitRegion(x0: 0, y0: 0, x1: maxTabX, y1: 1, action: .openPrompt),
    );
  }

  int _paintTopEmptyLabel(Buffer buffer, int maxTabX) {
    final (emptyText, usedCols) = DockTabLayout.clipWithWidth(
      _emptySessionsLabel(),
      maxTabX,
    );
    buffer.writeString(0, 0, emptyText, _chromeTheme.barStyle);
    return min(usedCols + 1, maxTabX);
  }

  void _paintTopClipboardNotice(
    Buffer buffer,
    String notice,
    int usedWidth,
    int maxTabX,
  ) {
    if (maxTabX <= 0) return;
    final safeNotice = notice.replaceAll(_controlChars, '');
    final remainingCols = maxTabX - usedWidth;
    final warningStyle = _chromeTheme.warningBannerStyle;
    if (remainingCols >= _minInlineNoticeCols) {
      buffer.writeString(
        usedWidth,
        0,
        DockTabLayout.clipAndPadRight(safeNotice, remainingCols),
        warningStyle,
      );
      _chromeHitRegions.add(
        DockHitRegion(
          x0: usedWidth,
          y0: 0,
          x1: maxTabX,
          y1: 1,
          action: .dismissNotice,
        ),
      );
      return;
    }

    _tabLayout = .empty;
    buffer.writeString(
      0,
      0,
      DockTabLayout.clipAndPadRight(safeNotice, maxTabX),
      warningStyle,
    );
    _chromeHitRegions.add(
      DockHitRegion(x0: 0, y0: 0, x1: maxTabX, y1: 1, action: .dismissNotice),
    );
  }

  int _paintTopRightControls(Buffer buffer) {
    const toggleLabel = '[Dock]';
    if (buffer.width < toggleLabel.length + 2) {
      return buffer.width;
    }
    final toggleX = buffer.width - toggleLabel.length;
    buffer.writeString(toggleX, 0, toggleLabel, _chromeTheme.toggleStyle);
    _chromeHitRegions.add(
      DockHitRegion(
        x0: toggleX,
        y0: 0,
        x1: buffer.width,
        y1: 1,
        action: .cycleDock,
      ),
    );

    if (buffer.width < 40) {
      return toggleX - 1;
    }

    const helpLabel = '[?]';
    final helpX = toggleX - 1 - helpLabel.length;
    buffer.writeString(helpX, 0, helpLabel, _chromeTheme.actionButtonStyle);
    _chromeHitRegions.add(
      DockHitRegion(
        x0: helpX,
        y0: 0,
        x1: helpX + helpLabel.length,
        y1: 1,
        action: .openHelp,
      ),
    );

    const statsLabel = '[Stats]';
    final statsX = helpX - 1 - statsLabel.length;
    buffer.writeString(statsX, 0, statsLabel, _chromeTheme.actionButtonStyle);
    _chromeHitRegions.add(
      DockHitRegion(
        x0: statsX,
        y0: 0,
        x1: statsX + statsLabel.length,
        y1: 1,
        action: .openStats,
      ),
    );

    const settingsLabel = '[⚙]';
    final settingsX = statsX - 1 - settingsLabel.length;
    buffer.writeString(
      settingsX,
      0,
      settingsLabel,
      _chromeTheme.actionButtonStyle,
    );
    _chromeHitRegions.add(
      DockHitRegion(
        x0: settingsX,
        y0: 0,
        x1: settingsX + settingsLabel.length,
        y1: 1,
        action: .openSettings,
      ),
    );

    return _paintTopScrollbackPill(buffer, settingsX - 1);
  }

  String? _scrollbackPillLabel() {
    final lines = viewModel.activeScrollOffsetLines;
    if (lines <= 0) return null;
    final cols = viewModel.activeScrollOffsetCols;
    return cols > 0 ? '[↑$lines →$cols]' : '[↑$lines]';
  }

  int _paintTopScrollbackPill(Buffer buffer, int availableEndX) {
    final pillLabel = _scrollbackPillLabel();
    if (pillLabel == null || buffer.width < 52) return availableEndX;
    final pillX = availableEndX - pillLabel.length;
    if (pillX <= 2) return availableEndX;
    buffer.writeString(pillX, 0, pillLabel, _chromeTheme.toggleStyle);
    _chromeHitRegions.add(
      DockHitRegion(
        x0: pillX,
        y0: 0,
        x1: pillX + pillLabel.length,
        y1: 1,
        action: .snapToBottom,
      ),
    );
    return pillX - 1;
  }

  int _paintTopTabs(Buffer buffer, int maxTabX) {
    _tabLayout = DockTabLayout.computeTop(
      specs: _buildTabSpecs(),
      maxTabX: maxTabX,
      scrollOffsetCols: _topScrollCols,
      ensureVisibleId: _consumeEnsureVisibleId(),
    );
    _topScrollCols = _tabLayout.clampedScrollOffset;
    _paintRenderedTabs(buffer, _tabLayout.visibleTabs);
    _paintOverflowControls(buffer, _tabLayout.overflowControls);
    return _tabLayout.usedCols;
  }

  void _paintLeftSidebar(Buffer buffer) {
    final innerW = max(1, buffer.width - 1);
    final borderStyle = _chromeTheme.barStyle;
    for (var y = 0; y < buffer.height; y++) {
      buffer.writeString(buffer.width - 1, y, '│', borderStyle);
    }

    _paintLeftHeaderControls(buffer, innerW);

    if (buffer.height >= 2) {
      buffer.writeString(0, 1, '${'─' * innerW}┤', borderStyle);
    }

    if (viewModel.hasAttentionBanner) {
      _paintLeftBanner(buffer, innerW);
      return;
    }

    var sessionStartRow = 2;
    if (viewModel.clipboardNotice case final notice?) {
      sessionStartRow = _paintLeftClipboardNotice(buffer, notice, innerW);
    }
    sessionStartRow = _paintLeftScrollbackPill(buffer, innerW, sessionStartRow);

    _paintLeftSessionRows(buffer, innerW, sessionStartRow);
  }

  int _paintLeftScrollbackPill(Buffer buffer, int innerW, int row) {
    final pillLabel = _scrollbackPillLabel();
    if (pillLabel == null || row >= buffer.height) return row;
    buffer.writeString(
      0,
      row,
      DockTabLayout.clipAndPadRight(' $pillLabel', innerW),
      _chromeTheme.toggleStyle,
    );
    _chromeHitRegions.add(
      DockHitRegion(
        x0: 0,
        y0: row,
        x1: innerW,
        y1: row + 1,
        action: .snapToBottom,
      ),
    );
    return row + 1;
  }

  int _paintLeftClipboardNotice(Buffer buffer, String notice, int innerW) {
    if (buffer.height < 3) return 2;
    final lineBudget = innerW > 2 ? innerW - 2 : innerW;
    final lines = _wrapSidebarNotice(notice, lineBudget);
    if (lines.isEmpty) return 2;

    final maxNoticeRows = min(lines.length, buffer.height - 2);
    final warningStyle = _chromeTheme.warningBannerStyle;
    for (var i = 0; i < maxNoticeRows; i++) {
      final paddedLine = innerW > 2 ? ' ${lines[i]}' : lines[i];
      buffer.writeString(
        0,
        2 + i,
        DockTabLayout.clipAndPadRight(paddedLine, innerW),
        warningStyle,
      );
    }
    final endRow = 2 + maxNoticeRows;
    _chromeHitRegions.add(
      DockHitRegion(
        x0: 0,
        y0: 2,
        x1: innerW,
        y1: endRow,
        action: .dismissNotice,
      ),
    );
    return endRow;
  }

  void _paintLeftSessionRows(Buffer buffer, int innerW, int startRow) {
    final sessions = viewModel.sessions;
    if (sessions.isEmpty) {
      if (startRow < buffer.height) {
        final emptyRow = DockTabLayout.clipAndPadRight(
          _emptySessionsLabel(),
          innerW,
        );
        buffer.writeString(0, startRow, emptyRow, _chromeTheme.barStyle);
      }
      return;
    }

    _tabLayout = DockTabLayout.computeLeft(
      specs: _buildTabSpecs(),
      innerWidth: innerW,
      startRow: startRow,
      totalHeight: buffer.height,
      scrollOffsetRows: _leftScrollRows,
      ensureVisibleId: _consumeEnsureVisibleId(),
    );
    _leftScrollRows = _tabLayout.clampedScrollOffset;
    _paintRenderedTabs(buffer, _tabLayout.visibleTabs);
    _paintOverflowControls(buffer, _tabLayout.overflowControls);
  }

  List<DockTabItemSpec> _buildTabSpecs() {
    final sessions = viewModel.sessions;
    final activeId = viewModel.activeSessionId;
    return [
      for (var i = 0; i < sessions.length; i++)
        DockTabItemSpec(
          id: sessions[i].id,
          index: i,
          title: sessions[i].title,
          isActive: sessions[i].id == activeId,
          status: viewModel.tabStatusOf(sessions[i].id),
        ),
    ];
  }

  SessionId? _consumeEnsureVisibleId() {
    final activeId = viewModel.activeSessionId;
    final dock = viewModel.dockPosition;
    final changed =
        activeId != _lastObservedActiveId || dock != _lastObservedDock;
    _lastObservedActiveId = activeId;
    _lastObservedDock = dock;
    return changed ? activeId : null;
  }

  void _paintRenderedTabs(Buffer buffer, List<DockRenderedTab> tabs) {
    final draggingId = _gestureTracker.draggingSessionId;
    for (final tab in tabs) {
      if (tab.spec.id == draggingId) {
        buffer.writeString(tab.x, tab.y, '░' * tab.visibleCols, _dropSlotStyle);
        continue;
      }
      final style = _tabStyleFor(tab.spec, _chromeTheme);
      buffer.writeString(tab.x, tab.y, tab.visibleText, style);
      if (tab.dismissColSpan case (final cx0, _)) {
        final badgeStyle = tab.spec.status.phase == .dead
            ? _dismissRedBadgeStyle
            : _dismissYellowBadgeStyle;
        buffer.writeString(cx0, tab.y, '[x]', badgeStyle);
      }
    }
  }

  static Style _tabStyleFor(
    DockTabItemSpec spec,
    WorkspaceChromeTheme chromeTheme,
  ) => switch ((spec.status.phase, spec.isActive)) {
    (.live, true) => chromeTheme.activeTabStyle,
    (.live, false) => chromeTheme.inactiveTabStyle,
    (.disconnectedCountdown || .exitedCountdown, true) =>
      chromeTheme.warningBannerStyle,
    (.disconnectedCountdown || .exitedCountdown, false) =>
      _inactiveCountdownTabStyle,
    (.dead, true) => chromeTheme.errorBannerStyle,
    (.dead, false) => _inactiveDeadTabStyle,
  };

  void _paintOverflowControls(
    Buffer buffer,
    List<DockOverflowControl> controls,
  ) {
    for (final ctrl in controls) {
      final style = ctrl.enabled
          ? _chromeTheme.actionButtonStyle
          : _chromeTheme.disabledOverflowStyle;
      buffer.writeString(ctrl.x, ctrl.y, ctrl.text, style);
    }
  }

  static List<String> _wrapSidebarNotice(String rawNotice, int maxLineCols) {
    final trimmed = rawNotice.replaceAll(_controlChars, '').trim();
    if (trimmed.isEmpty || maxLineCols <= 0) return const [];
    final (firstClip, _) = DockTabLayout.clipWithWidth(trimmed, maxLineCols);
    if (firstClip.length == trimmed.length) return [trimmed];

    final (line1, rest) = _splitFirstNoticeLine(trimmed, firstClip);
    if (rest.isEmpty) return [line1];
    final (line2, _) = DockTabLayout.clipWithWidth(rest, maxLineCols);
    return line2.isEmpty ? [line1] : [line1, line2];
  }

  static (String line1, String rest) _splitFirstNoticeLine(
    String trimmed,
    String firstClip,
  ) {
    if (trimmed.codeUnitAt(firstClip.length) == 0x20) {
      return (
        firstClip.trimRight(),
        trimmed.substring(firstClip.length).trimLeft(),
      );
    }
    final breakIdx = firstClip.lastIndexOf(' ');
    if (breakIdx > 0) {
      return (
        firstClip.substring(0, breakIdx).trimRight(),
        trimmed.substring(breakIdx + 1).trimLeft(),
      );
    }
    return (firstClip, trimmed.substring(firstClip.length).trimLeft());
  }

  void _paintLeftHeaderControls(Buffer buffer, int innerW) {
    const dockLabel = '[Dock]';
    const statsLabel = '[Stats]';
    const helpLabel = '[?]';
    const settingsLabel = '[⚙]';
    const minControlsW =
        dockLabel.length +
        1 +
        statsLabel.length +
        1 +
        helpLabel.length +
        settingsLabel.length;

    if (innerW >= minControlsW) {
      const dockX = 0;
      buffer.writeString(dockX, 0, dockLabel, _chromeTheme.toggleStyle);
      _chromeHitRegions.add(
        const DockHitRegion(
          x0: dockX,
          y0: 0,
          x1: dockX + dockLabel.length,
          y1: 1,
          action: .cycleDock,
        ),
      );

      const statsX = dockX + dockLabel.length + 1;
      buffer.writeString(statsX, 0, statsLabel, _chromeTheme.actionButtonStyle);
      _chromeHitRegions.add(
        const DockHitRegion(
          x0: statsX,
          y0: 0,
          x1: statsX + statsLabel.length,
          y1: 1,
          action: .openStats,
        ),
      );

      const helpX = statsX + statsLabel.length + 1;
      buffer.writeString(helpX, 0, helpLabel, _chromeTheme.actionButtonStyle);
      _chromeHitRegions.add(
        const DockHitRegion(
          x0: helpX,
          y0: 0,
          x1: helpX + helpLabel.length,
          y1: 1,
          action: .openHelp,
        ),
      );

      const settingsX = helpX + helpLabel.length;
      buffer.writeString(
        settingsX,
        0,
        settingsLabel,
        _chromeTheme.actionButtonStyle,
      );
      _chromeHitRegions.add(
        const DockHitRegion(
          x0: settingsX,
          y0: 0,
          x1: settingsX + settingsLabel.length,
          y1: 1,
          action: .openSettings,
        ),
      );
      return;
    }

    final toggleText = DockTabLayout.clipAndPadRight(' [Dock: left]', innerW);
    buffer.writeString(0, 0, toggleText, _chromeTheme.toggleStyle);
    _chromeHitRegions.add(
      DockHitRegion(x0: 0, y0: 0, x1: innerW, y1: 1, action: .cycleDock),
    );
  }

  void _paintLeftBanner(Buffer buffer, int innerW) {
    final state = viewModel.connectionState;
    final style = _bannerStyleFor(state, _chromeTheme);
    final headline = switch (state) {
      .authFailed => ' ! Auth failed',
      .reconnecting => ' ! Reconnecting...',
      _ => ' ! Disconnected',
    };
    if (buffer.height >= 3) {
      buffer.writeString(
        0,
        2,
        DockTabLayout.clipAndPadRight(headline, innerW),
        style,
      );
      _chromeHitRegions.add(
        DockHitRegion(
          x0: 0,
          y0: 2,
          x1: innerW,
          y1: min(buffer.height, 4),
          action: .openPrompt,
        ),
      );
    }
    if (buffer.height >= 4) {
      buffer.writeString(
        0,
        3,
        DockTabLayout.clipAndPadRight(' [Connect (Enter)]', innerW),
        style,
      );
    }
  }

  static Style _bannerStyleFor(
    ClientConnectionState state,
    WorkspaceChromeTheme chromeTheme,
  ) => state == .authFailed
      ? chromeTheme.errorBannerStyle
      : chromeTheme.warningBannerStyle;

  String _emptySessionsLabel() {
    if (viewModel.connectionState == .connecting) {
      return ' Connecting...';
    }
    final activeId = viewModel.activeSessionId;
    final exitCode = activeId == null ? null : viewModel.exitCodeOf(activeId);
    return exitCode == null
        ? ' No active sessions'
        : ' No active sessions (exit $exitCode)';
  }

  @override
  bool handleKeyEvent(KeyEvent event) => onKeyEvent?.call(event) ?? false;

  @override
  bool handleMouseEvent(MouseEvent event) {
    final wasDragging = _gestureTracker.draggingSessionId != null;
    final result = _gestureTracker.handleMouseEvent(
      event: event,
      width: width,
      height: height,
      dock: viewModel.dockPosition,
      layout: _tabLayout,
      chromeHitRegions: _chromeHitRegions,
    );
    if (!result.handled) return false;

    _dispatchGestureResult(result);
    if (result.restorePtyFocus) {
      if (wasDragging && result is! DockGestureCancelDrag) {
        if (ownsActiveDragSession) {
          DragDropManager.drop();
        }
        render();
      }
      onReleasePointerFocus?.call();
    }
    if (result case DockGestureRename(:final sessionId)) {
      onRequestRenameSession?.call(sessionId);
    }
    return true;
  }

  void _dispatchGestureResult(DockGestureResult result) {
    switch (result) {
      case DockGestureActivate(:final action, :final sessionId):
        _executeDockAction(action, sessionId);
      case DockGestureScroll(:final delta):
        _scrollOverflowBy(delta);
      case final DockGestureReorder reorder:
        _applyDragReorder(reorder);
      case final DockGestureCancelDrag cancel:
        _applyCancelledDragRollback(cancel);
      case DockGestureDismiss(:final sessionId):
        unawaited(viewModel.dismissSession(sessionId));
      case DockGestureIgnored() || DockGestureConsumed() || DockGestureRename():
        break;
    }
  }

  void _applyCancelledDragRollback(DockGestureCancelDrag cancel) {
    if (ownsActiveDragSession) {
      DragDropManager.cancelDrag();
    }
    if (!viewModel.moveSession(cancel.sessionId, cancel.originalIndex)) {
      render();
    }
  }

  void _executeDockAction(DockHitAction action, SessionId? sessionId) {
    switch (action) {
      case .openPrompt:
        onRequestConnectionPrompt?.call();
      case .openHelp:
        onRequestChordsHelp?.call();
      case .openStats:
        onRequestStats?.call();
      case .openSettings:
        onRequestSettings?.call();
      case .dismissNotice:
        viewModel.dismissClipboardNotice();
      case .snapToBottom:
        viewModel.scrollActiveToBottom();
      case .cycleDock:
        viewModel.setDockPosition(
          viewModel.dockPosition == .top ? .left : .top,
        );
      case .scrollPrev:
        _scrollOverflowBy(-_overflowStepForCurrentDock());
      case .scrollNext:
        _scrollOverflowBy(_overflowStepForCurrentDock());
      case .selectSession:
        if (sessionId != null) {
          unawaited(viewModel.selectSession(sessionId));
        }
      case .dismissSession:
        break;
    }
  }

  int _overflowStepForCurrentDock() => viewModel.dockPosition == .top
      ? DockTabLayout.topScrollStepCols
      : DockTabLayout.leftScrollStepRows;

  void _scrollOverflowBy(int delta) {
    if (delta == 0 || !_tabLayout.hasOverflow) return;
    if (viewModel.dockPosition == .top) {
      final next = (_topScrollCols + delta).clamp(
        0,
        _tabLayout.maxScrollOffset,
      );
      if (next == _topScrollCols) return;
      _topScrollCols = next;
    } else if (viewModel.dockPosition == .left) {
      final next = (_leftScrollRows + delta).clamp(
        0,
        _tabLayout.maxScrollOffset,
      );
      if (next == _leftScrollRows) return;
      _leftScrollRows = next;
    } else {
      return;
    }
    render();
  }

  void _applyDragReorder(DockGestureReorder reorder) {
    final scrolled = _nudgeOverflowOnDrag(reorder.edgeScrollDirection);
    var resolvedTarget = reorder.targetIndex;
    if (scrolled) {
      render();
      resolvedTarget = _clampTargetAfterEdgeScroll(
        resolvedTarget,
        reorder.edgeScrollDirection,
      );
    }
    var didRender = scrolled;
    if (resolvedTarget != null &&
        viewModel.moveSession(reorder.sessionId, resolvedTarget)) {
      didRender = true;
    }
    if (!didRender) {
      render();
    }
    _syncDragDropManager(reorder);
  }

  void _syncDragDropManager(DockGestureReorder reorder) {
    final dragData = _buildDragDataFor(
      reorder.sessionId,
      reorder.grabOffsetCols,
      reorder.globalPosition,
    );
    if (dragData == null) {
      if (ownsActiveDragSession) {
        DragDropManager.cancelDrag();
      }
      return;
    }
    _syncDragTargetTree();
    final projected = _projectDockPoint(reorder.localX, reorder.localY);
    final listener = DragDropManager.onDragSessionChanged;
    DragDropManager.onDragSessionChanged = null;
    try {
      DragDropManager.startDrag(
        DragSession(
          data: dragData,
          sourceElement: _anchorDraggableElement,
          startMousePosition: reorder.startGlobalPosition,
          currentMousePosition: projected,
        ),
      );
      DragDropManager.updateDrag(projected);
      DragDropManager.activeSession?.currentMousePosition =
          reorder.globalPosition;
    } finally {
      DragDropManager.onDragSessionChanged = listener;
    }
    listener?.call(DragDropManager.activeSession);
  }

  DockTabDragData? _buildDragDataFor(
    SessionId sessionId,
    int grabOffsetCols,
    Point<int> globalMousePosition,
  ) {
    for (final spec in _buildTabSpecs()) {
      if (spec.id != sessionId) continue;
      final (label, widthCols) = DockTabLayout.formatFloatingPill(
        spec,
        dock: viewModel.dockPosition,
        innerWidth: max(1, width - 1),
      );
      return DockTabDragData(
        sessionId: sessionId,
        label: label,
        widthCols: widthCols,
        grabOffsetCols: grabOffsetCols,
        globalMousePosition: globalMousePosition,
        style: _tabStyleFor(spec, _chromeTheme),
      );
    }
    return null;
  }

  Point<int> _projectDockPoint(int localX, int localY) {
    final start = _tabLayout.viewportStart;
    final end = max(start, _tabLayout.viewportEnd - 1);
    if (viewModel.dockPosition == .left) {
      final int clampedY = localY.clamp(start, end);
      return Point<int>(1, clampedY + 1);
    }
    final int clampedX = localX.clamp(start, end);
    return Point<int>(clampedX + 1, 1);
  }

  bool _nudgeOverflowOnDrag(int edgeScrollDirection) {
    if (edgeScrollDirection == 0 || !_tabLayout.hasOverflow) return false;
    final delta = edgeScrollDirection * _overflowStepForCurrentDock();
    if (viewModel.dockPosition == .top) {
      final next = (_topScrollCols + delta).clamp(
        0,
        _tabLayout.maxScrollOffset,
      );
      if (next == _topScrollCols) return false;
      _topScrollCols = next;
      return true;
    }
    if (viewModel.dockPosition == .left) {
      final next = (_leftScrollRows + delta).clamp(
        0,
        _tabLayout.maxScrollOffset,
      );
      if (next == _leftScrollRows) return false;
      _leftScrollRows = next;
      return true;
    }
    return false;
  }

  int? _clampTargetAfterEdgeScroll(int? targetIndex, int edgeScrollDirection) {
    final visible = _tabLayout.visibleTabs;
    if (visible.isEmpty) return targetIndex;
    if (edgeScrollDirection > 0) {
      final lastVisible = visible.last.spec.index;
      return targetIndex == null ? lastVisible : max(targetIndex, lastVisible);
    }
    final firstVisible = visible.first.spec.index;
    return targetIndex == null ? firstVisible : min(targetIndex, firstVisible);
  }

  @override
  void resize(int width, int height) {
    if (isDisposed) return;
    final changed = updateDimensions(width, height);
    if (!changed && currentBuffer != null) return;
    render();
  }

  @override
  void dispose() {
    if (ownsActiveDragSession) {
      DragDropManager.cancelDrag();
    }
    if (_dragRootElement.mounted) {
      _dragRootElement.unmount();
    }
    _chromeHitRegions.clear();
    _tabLayout = .empty;
    super.dispose();
  }
}
