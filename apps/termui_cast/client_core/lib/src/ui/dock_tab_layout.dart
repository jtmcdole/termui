import 'dart:math';

import 'package:characters/characters.dart';
import 'package:meta/meta.dart';
import 'package:termui/termui.dart';
import 'package:termui_cast_protocol/termui_cast_protocol.dart';

import '../models.dart';
import '../session_tab_strip.dart';

/// Interactive action associated with a [DockHitRegion] in `SessionDockBar`.
enum DockHitAction {
  /// Selects and activates [DockHitRegion.sessionId].
  selectSession,

  /// Dismisses an ended [DockHitRegion.sessionId] (`[x]`) on pointer release.
  dismissSession,

  /// Scrolls the overflowing tab strip backward (`◀` or `▲`).
  scrollPrev,

  /// Scrolls the overflowing tab strip forward (`▶` or `▼`).
  scrollNext,

  /// Toggles the dock placement (`top <-> left`).
  cycleDock,

  /// Opens the connection prompt modal.
  openPrompt,

  /// Opens the leader chords help modal.
  openHelp,

  /// Opens the Stats for Nerds telemetry modal.
  openStats,

  /// Opens the workspace Settings modal.
  openSettings,

  /// Dismisses an active transient clipboard or security notice.
  dismissNotice,

  /// Snaps the active session's scrollback viewport back to the live bottom.
  snapToBottom;

  /// Whether activating this action opens a modal dialog on `SceneManager`.
  bool get opensModal =>
      this == .openPrompt ||
      this == .openHelp ||
      this == .openStats ||
      this == .openSettings;
}

/// Rectangular 0-based hit-test region within `SessionDockBar`.
@immutable
final class DockHitRegion {
  /// Inclusive left column.
  final int x0;

  /// Inclusive top row.
  final int y0;

  /// Exclusive right column.
  final int x1;

  /// Exclusive bottom row.
  final int y1;

  /// Action triggered when this region is activated.
  final DockHitAction action;

  /// Associated [SessionId] for tab or `[x]` regions, else `null`.
  final SessionId? sessionId;

  /// Creates an immutable dock hit-test region.
  const DockHitRegion({
    required this.x0,
    required this.y0,
    required this.x1,
    required this.y1,
    required this.action,
    this.sessionId,
  });

  /// Whether 0-based dock cell `([x], [y])` lies inside this region.
  bool contains(int x, int y) => x >= x0 && x < x1 && y >= y0 && y < y1;
}

/// Input specification for laying out a single session tab.
@immutable
final class DockTabItemSpec {
  /// Session identifier.
  final SessionId id;

  /// 0-based display ordinal in the ordered tab strip.
  final int index;

  /// Raw session title.
  final String title;

  /// Whether this tab is currently selected.
  final bool isActive;

  /// Computed lifecycle and countdown snapshot for this tab.
  final SessionTabStatus status;

  /// Creates an input tab specification.
  const DockTabItemSpec({
    required this.id,
    required this.index,
    required this.title,
    required this.isActive,
    required this.status,
  });
}

/// Positioned, column-sliced tab ready to paint into a `SessionDockBar` buffer.
@immutable
final class DockRenderedTab {
  /// Source tab specification.
  final DockTabItemSpec spec;

  /// 0-based buffer column where [visibleText] begins.
  final int x;

  /// 0-based buffer row where [visibleText] is drawn.
  final int y;

  /// Display-width-clipped label slice to write at `([x], [y])`.
  final String visibleText;

  /// Display column width of [visibleText].
  final int visibleCols;

  /// Inclusive start coordinate along the dock's primary axis.
  final int primaryStart;

  /// Exclusive end coordinate along the dock's primary axis.
  final int primaryEnd;

  /// Visible `(x0, x1)` column span of `[x]` when fully visible, else `null`.
  final (int x0, int x1)? dismissColSpan;

  /// Creates a positioned tab render descriptor.
  const DockRenderedTab({
    required this.spec,
    required this.x,
    required this.y,
    required this.visibleText,
    required this.visibleCols,
    required this.primaryStart,
    required this.primaryEnd,
    this.dismissColSpan,
  });
}

/// Overflow scroll button or indicator rendered alongside overflowing tabs.
@immutable
final class DockOverflowControl {
  /// 0-based buffer column.
  final int x;

  /// 0-based buffer row.
  final int y;

  /// Formatted glyph or row text.
  final String text;

  /// Whether scrolling further in [action]'s direction is currently possible.
  final bool enabled;

  /// Scroll direction action (`scrollPrev` or `scrollNext`).
  final DockHitAction action;

  /// Creates an overflow scroll control descriptor.
  const DockOverflowControl({
    required this.x,
    required this.y,
    required this.text,
    required this.enabled,
    required this.action,
  });
}

/// Payload carried by [DragSession.data] when dragging a session tab via [DragDropManager].
@immutable
final class DockTabDragData {
  /// Session being dragged.
  final SessionId sessionId;

  /// Formatted pill text rendered in the floating ghost layer (e.g. `' 1:alpha '`).
  final String label;

  /// Display width of [label] in terminal columns.
  final int widthCols;

  /// Grab offset in columns from the tab's left edge.
  final int grabOffsetCols;

  /// 1-based global mouse coordinate of the current drag pointer.
  final Point<int> globalMousePosition;

  /// Foreground/background style of the dragged tab pill.
  final Style style;

  /// Creates a tab drag payload for [DragDropManager].
  const DockTabDragData({
    required this.sessionId,
    required this.label,
    required this.widthCols,
    required this.grabOffsetCols,
    required this.globalMousePosition,
    required this.style,
  });
}

/// Immutable layout snapshot for `SessionDockBar`'s tab strip and overflow controls.
final class DockTabLayout {
  /// Step size in columns per wheel/button action in [DockPosition.top].
  static const int topScrollStepCols = 8;

  /// Step size in rows per wheel/button action in [DockPosition.left].
  static const int leftScrollStepRows = 1;

  static const int _maxEndedTopTitleCols = 28;
  static const int _topStepperWidth = 4;
  static final RegExp _controlChars = RegExp(r'[\x00-\x1F\x7F-\x9F]');

  /// Dock orientation that produced this layout.
  final DockPosition dock;

  /// Visible tabs after applying [clampedScrollOffset].
  final List<DockRenderedTab> visibleTabs;

  /// Overflow scroll buttons (`◀`/`▶` or `▲`/`▼`) when [hasOverflow] is `true`.
  final List<DockOverflowControl> overflowControls;

  /// Ordered hit-test regions (`[x]` precedes tab body so `[x]` wins cleanly).
  final List<DockHitRegion> hitRegions;

  /// Clamped scroll offset (columns in `.top`, rows in `.left`).
  final int clampedScrollOffset;

  /// Maximum valid scroll offset (`0` when all tabs fit).
  final int maxScrollOffset;

  /// Rightmost column occupied by tabs and overflow controls in `.top`.
  final int usedCols;

  /// Inclusive start coordinate of the scrollable tab viewport on the primary axis.
  final int viewportStart;

  /// Exclusive end coordinate of the scrollable tab viewport on the primary axis.
  final int viewportEnd;

  final List<SessionId> _allTabIds;

  const DockTabLayout._({
    required this.dock,
    required List<SessionId> allTabIds,
    required this.visibleTabs,
    required this.overflowControls,
    required this.hitRegions,
    required this.clampedScrollOffset,
    required this.maxScrollOffset,
    required this.usedCols,
    required this.viewportStart,
    required this.viewportEnd,
  }) : _allTabIds = allTabIds;

  /// Empty layout placeholder used before first render or when hidden.
  static const DockTabLayout empty = DockTabLayout._(
    dock: .top,
    allTabIds: [],
    visibleTabs: [],
    overflowControls: [],
    hitRegions: [],
    clampedScrollOffset: 0,
    maxScrollOffset: 0,
    usedCols: 0,
    viewportStart: 0,
    viewportEnd: 0,
  );

  /// Whether tabs exceed the available dock viewport.
  bool get hasOverflow => maxScrollOffset > 0;

  /// Returns the 0-based strip index of [id] across all tabs, or `null` when absent.
  int? indexOf(SessionId id) {
    final idx = _allTabIds.indexOf(id);
    return idx >= 0 ? idx : null;
  }

  /// Returns the visible [DockRenderedTab] for [id], or `null` when scrolled out of view.
  DockRenderedTab? renderedTabFor(SessionId id) {
    for (final tab in visibleTabs) {
      if (tab.spec.id == id) return tab;
    }
    return null;
  }

  /// Formats the floating drag-ghost pill text and column width for [spec].
  static (String label, int widthCols) formatFloatingPill(
    DockTabItemSpec spec, {
    required DockPosition dock,
    required int innerWidth,
  }) {
    if (dock == .left && innerWidth > 0) {
      final rendered = _buildLeftRenderedTab(spec, innerWidth, 0);
      return (rendered.visibleText, rendered.visibleCols);
    }
    final safeTitle = spec.title.replaceAll(_controlChars, '');
    final (text, cols, _) = _formatTopTabLabel(spec, safeTitle);
    return (text, cols);
  }

  /// Returns the first [DockHitRegion] containing `([localX], [localY])`, or `null`.
  DockHitRegion? hitTest(int localX, int localY) {
    for (final region in hitRegions) {
      if (region.contains(localX, localY)) return region;
    }
    return null;
  }

  /// Computes a new target index when dragging [draggedId] to [primaryCoord],
  /// or `null` when [draggedId] has not crossed an adjacent tab's midpoint.
  int? targetIndexForDrag(SessionId draggedId, int primaryCoord) {
    final currentIndex = indexOf(draggedId);
    if (currentIndex == null) return null;

    var target = currentIndex;
    for (final other in visibleTabs) {
      target = _stepDragTarget(other, currentIndex, primaryCoord, target);
    }
    return target == currentIndex ? null : target;
  }

  static int _stepDragTarget(
    DockRenderedTab other,
    int currentIndex,
    int primaryCoord,
    int target,
  ) {
    final otherIdx = other.spec.index;
    if (otherIdx > currentIndex) {
      final midForward = (other.primaryStart + other.primaryEnd) ~/ 2;
      if (primaryCoord >= midForward && otherIdx > target) return otherIdx;
    } else if (otherIdx < currentIndex) {
      final midBackward = (other.primaryStart + other.primaryEnd - 1) ~/ 2;
      if (primaryCoord <= midBackward && otherIdx < target) return otherIdx;
    }
    return target;
  }

  /// Lays out horizontal tabs and optional `◀`/`▶` controls inside `0..[maxTabX]`.
  static DockTabLayout computeTop({
    required List<DockTabItemSpec> specs,
    required int maxTabX,
    required int scrollOffsetCols,
    SessionId? ensureVisibleId,
  }) {
    if (specs.isEmpty || maxTabX <= 0) {
      return DockTabLayout._(
        dock: .top,
        allTabIds: const [],
        visibleTabs: const [],
        overflowControls: const [],
        hitRegions: const [],
        clampedScrollOffset: 0,
        maxScrollOffset: 0,
        usedCols: 0,
        viewportStart: 0,
        viewportEnd: max(0, maxTabX),
      );
    }

    final measured = _measureNaturalTopTabs(specs);
    final totalNaturalCols = measured.last.natX1;
    final overflows = totalNaturalCols > maxTabX;
    final showStepper = overflows && maxTabX >= 8;
    final tabsViewportCols = showStepper ? maxTabX - _topStepperWidth : maxTabX;
    final maxScroll = overflows
        ? max(0, totalNaturalCols - tabsViewportCols)
        : 0;
    final scroll = _resolveTopScrollOffset(
      measured: measured,
      initialScroll: scrollOffsetCols,
      tabsViewportCols: tabsViewportCols,
      maxScroll: maxScroll,
      ensureVisibleId: ensureVisibleId,
    );

    final visibleTabs = <DockRenderedTab>[];
    final hitRegions = <DockHitRegion>[];
    var rightmostPaintedX = 0;

    for (final item in measured) {
      final screenTab = _projectTopTab(item, scroll, tabsViewportCols);
      if (screenTab == null) continue;
      visibleTabs.add(screenTab);
      rightmostPaintedX = max(
        rightmostPaintedX,
        screenTab.x + screenTab.visibleCols + 1,
      );
      _appendTabHitRegions(hitRegions, screenTab);
    }

    final controls = <DockOverflowControl>[];
    if (showStepper) {
      _appendTopStepper(
        controls: controls,
        hitRegions: hitRegions,
        stepperX: tabsViewportCols,
        scroll: scroll,
        maxScroll: maxScroll,
      );
      rightmostPaintedX = maxTabX;
    }

    return DockTabLayout._(
      dock: .top,
      allTabIds: [for (final s in specs) s.id],
      visibleTabs: visibleTabs,
      overflowControls: controls,
      hitRegions: hitRegions,
      clampedScrollOffset: scroll,
      maxScrollOffset: maxScroll,
      usedCols: min(rightmostPaintedX, maxTabX),
      viewportStart: 0,
      viewportEnd: tabsViewportCols,
    );
  }

  /// Lays out vertical session rows and optional `▲`/`▼` indicators in `.left`.
  static DockTabLayout computeLeft({
    required List<DockTabItemSpec> specs,
    required int innerWidth,
    required int startRow,
    required int totalHeight,
    required int scrollOffsetRows,
    SessionId? ensureVisibleId,
  }) {
    final availableRows = max(0, totalHeight - startRow);
    if (specs.isEmpty || innerWidth <= 0 || availableRows <= 0) {
      return DockTabLayout._(
        dock: .left,
        allTabIds: const [],
        visibleTabs: const [],
        overflowControls: const [],
        hitRegions: const [],
        clampedScrollOffset: 0,
        maxScrollOffset: 0,
        usedCols: max(0, innerWidth),
        viewportStart: startRow,
        viewportEnd: totalHeight,
      );
    }

    final overflows = specs.length > availableRows;
    final showIndicators = overflows && availableRows >= 3;
    final listStartRow = showIndicators ? startRow + 1 : startRow;
    final listRows = showIndicators ? availableRows - 2 : availableRows;
    final maxScroll = max(0, specs.length - listRows);
    final scrollRow = _resolveLeftScrollRow(
      specs: specs,
      initialScroll: scrollOffsetRows,
      listRows: listRows,
      maxScroll: maxScroll,
      ensureVisibleId: ensureVisibleId,
    );

    final visibleTabs = <DockRenderedTab>[];
    final hitRegions = <DockHitRegion>[];
    final endIndex = min(specs.length, scrollRow + listRows);

    for (var i = scrollRow; i < endIndex; i++) {
      final row = listStartRow + (i - scrollRow);
      final tab = _buildLeftRenderedTab(specs[i], innerWidth, row);
      visibleTabs.add(tab);
      if (tab.dismissColSpan case (final cx0, final cx1)) {
        hitRegions.add(
          DockHitRegion(
            x0: cx0,
            y0: row,
            x1: cx1,
            y1: row + 1,
            action: .dismissSession,
            sessionId: tab.spec.id,
          ),
        );
      }
      final bodyEndX = tab.dismissColSpan?.$1 ?? innerWidth;
      if (bodyEndX > 0) {
        hitRegions.add(
          DockHitRegion(
            x0: 0,
            y0: row,
            x1: bodyEndX,
            y1: row + 1,
            action: .selectSession,
            sessionId: tab.spec.id,
          ),
        );
      }
    }

    final controls = <DockOverflowControl>[];
    if (showIndicators) {
      _appendLeftIndicators(
        controls: controls,
        hitRegions: hitRegions,
        innerWidth: innerWidth,
        topRow: startRow,
        bottomRow: totalHeight - 1,
        hiddenAbove: scrollRow,
        hiddenBelow: specs.length - endIndex,
      );
    }

    return DockTabLayout._(
      dock: .left,
      allTabIds: [for (final s in specs) s.id],
      visibleTabs: visibleTabs,
      overflowControls: controls,
      hitRegions: hitRegions,
      clampedScrollOffset: scrollRow,
      maxScrollOffset: maxScroll,
      usedCols: innerWidth,
      viewportStart: listStartRow,
      viewportEnd: listStartRow + listRows,
    );
  }

  static List<_MeasuredTopTab> _measureNaturalTopTabs(
    List<DockTabItemSpec> specs,
  ) {
    final result = <_MeasuredTopTab>[];
    var cursor = 0;
    for (final spec in specs) {
      final safeTitle = spec.title.replaceAll(_controlChars, '');
      final (fullText, cols, hasClose) = _formatTopTabLabel(spec, safeTitle);
      result.add((
        spec: spec,
        fullText: fullText,
        natX0: cursor,
        natX1: cursor + cols,
        hasDismiss: hasClose,
      ));
      cursor += cols + 1;
    }
    return result;
  }

  static (String text, int cols, bool hasClose) _formatTopTabLabel(
    DockTabItemSpec spec,
    String safeTitle,
  ) {
    if (spec.status.isLive) {
      final raw = ' ${spec.index + 1}:$safeTitle ';
      return (raw, displayWidth(raw), false);
    }
    final (clippedTitle, _) = clipWithWidth(safeTitle, _maxEndedTopTitleCols);
    final prefix = spec.isActive ? '▸' : ' ';
    final raw =
        '$prefix${spec.index + 1}:$clippedTitle ${spec.status.statusChip} [x]';
    return (raw, displayWidth(raw), true);
  }

  static int _resolveTopScrollOffset({
    required List<_MeasuredTopTab> measured,
    required int initialScroll,
    required int tabsViewportCols,
    required int maxScroll,
    required SessionId? ensureVisibleId,
  }) {
    if (maxScroll <= 0 || tabsViewportCols <= 0) return 0;
    var scroll = initialScroll.clamp(0, maxScroll);
    if (ensureVisibleId == null) return scroll;
    for (final item in measured) {
      if (item.spec.id != ensureVisibleId) continue;
      if (item.natX0 < scroll) {
        scroll = item.natX0;
      } else if (item.natX1 > scroll + tabsViewportCols) {
        scroll = min(item.natX0, item.natX1 - tabsViewportCols);
      }
      break;
    }
    return scroll.clamp(0, maxScroll);
  }

  static DockRenderedTab? _projectTopTab(
    _MeasuredTopTab item,
    int scroll,
    int viewportCols,
  ) {
    final visStart = max(item.natX0, scroll);
    final visEnd = min(item.natX1, scroll + viewportCols);
    if (visEnd <= visStart) return null;

    final skipInTab = visStart - item.natX0;
    final takeCols = visEnd - visStart;
    final sliced = sliceColumns(item.fullText, skipInTab, takeCols);
    final screenX = visStart - scroll;

    (int, int)? dismissSpan;
    if (item.hasDismiss) {
      final closeNatX0 = item.natX1 - 3;
      if (closeNatX0 >= scroll && item.natX1 <= scroll + viewportCols) {
        dismissSpan = (closeNatX0 - scroll, item.natX1 - scroll);
      }
    }

    return DockRenderedTab(
      spec: item.spec,
      x: screenX,
      y: 0,
      visibleText: sliced,
      visibleCols: takeCols,
      primaryStart: screenX,
      primaryEnd: screenX + takeCols,
      dismissColSpan: dismissSpan,
    );
  }

  static void _appendTabHitRegions(
    List<DockHitRegion> hitRegions,
    DockRenderedTab tab,
  ) {
    if (tab.dismissColSpan case (final cx0, final cx1)) {
      hitRegions.add(
        DockHitRegion(
          x0: cx0,
          y0: 0,
          x1: cx1,
          y1: 1,
          action: .dismissSession,
          sessionId: tab.spec.id,
        ),
      );
    }
    final bodyEnd = tab.dismissColSpan?.$1 ?? (tab.x + tab.visibleCols);
    if (bodyEnd > tab.x) {
      hitRegions.add(
        DockHitRegion(
          x0: tab.x,
          y0: 0,
          x1: bodyEnd,
          y1: 1,
          action: .selectSession,
          sessionId: tab.spec.id,
        ),
      );
    }
  }

  static void _appendTopStepper({
    required List<DockOverflowControl> controls,
    required List<DockHitRegion> hitRegions,
    required int stepperX,
    required int scroll,
    required int maxScroll,
  }) {
    final canPrev = scroll > 0;
    final canNext = scroll < maxScroll;
    controls
      ..add(
        DockOverflowControl(
          x: stepperX,
          y: 0,
          text: ' ◀',
          enabled: canPrev,
          action: .scrollPrev,
        ),
      )
      ..add(
        DockOverflowControl(
          x: stepperX + 2,
          y: 0,
          text: ' ▶',
          enabled: canNext,
          action: .scrollNext,
        ),
      );
    hitRegions
      ..add(
        DockHitRegion(
          x0: stepperX,
          y0: 0,
          x1: stepperX + 2,
          y1: 1,
          action: .scrollPrev,
        ),
      )
      ..add(
        DockHitRegion(
          x0: stepperX + 2,
          y0: 0,
          x1: stepperX + _topStepperWidth,
          y1: 1,
          action: .scrollNext,
        ),
      );
  }

  static int _resolveLeftScrollRow({
    required List<DockTabItemSpec> specs,
    required int initialScroll,
    required int listRows,
    required int maxScroll,
    required SessionId? ensureVisibleId,
  }) {
    if (maxScroll <= 0 || listRows <= 0) return 0;
    var scroll = initialScroll.clamp(0, maxScroll);
    if (ensureVisibleId == null) return scroll;
    for (var i = 0; i < specs.length; i++) {
      if (specs[i].id != ensureVisibleId) continue;
      if (i < scroll) {
        scroll = i;
      } else if (i >= scroll + listRows) {
        scroll = i - listRows + 1;
      }
      break;
    }
    return scroll.clamp(0, maxScroll);
  }

  static DockRenderedTab _buildLeftRenderedTab(
    DockTabItemSpec spec,
    int innerWidth,
    int row,
  ) {
    final safeTitle = spec.title.replaceAll(_controlChars, '');
    if (spec.status.isLive) {
      final text = clipAndPadRight(' ${spec.index + 1}:$safeTitle', innerWidth);
      return DockRenderedTab(
        spec: spec,
        x: 0,
        y: row,
        visibleText: text,
        visibleCols: innerWidth,
        primaryStart: row,
        primaryEnd: row + 1,
      );
    }

    final prefix = spec.isActive ? '▌' : ' ';
    if (innerWidth >= 13) {
      final headCols = innerWidth - 10;
      final head = clipAndPadRight(
        '$prefix${spec.index + 1}:$safeTitle',
        headCols,
      );
      return DockRenderedTab(
        spec: spec,
        x: 0,
        y: row,
        visibleText: '$head ${spec.status.statusChip} [x]',
        visibleCols: innerWidth,
        primaryStart: row,
        primaryEnd: row + 1,
        dismissColSpan: (innerWidth - 3, innerWidth),
      );
    }
    if (innerWidth >= 4) {
      final head = clipAndPadRight(
        '$prefix${spec.index + 1}:$safeTitle',
        innerWidth - 3,
      );
      return DockRenderedTab(
        spec: spec,
        x: 0,
        y: row,
        visibleText: '$head[x]',
        visibleCols: innerWidth,
        primaryStart: row,
        primaryEnd: row + 1,
        dismissColSpan: (innerWidth - 3, innerWidth),
      );
    }
    return DockRenderedTab(
      spec: spec,
      x: 0,
      y: row,
      visibleText: clipAndPadRight('${spec.index + 1}:$safeTitle', innerWidth),
      visibleCols: innerWidth,
      primaryStart: row,
      primaryEnd: row + 1,
    );
  }

  static void _appendLeftIndicators({
    required List<DockOverflowControl> controls,
    required List<DockHitRegion> hitRegions,
    required int innerWidth,
    required int topRow,
    required int bottomRow,
    required int hiddenAbove,
    required int hiddenBelow,
  }) {
    final upLabel = hiddenAbove > 0 ? ' ▲ $hiddenAbove more' : ' ▲';
    final downLabel = hiddenBelow > 0 ? ' ▼ $hiddenBelow more' : ' ▼';
    controls
      ..add(
        DockOverflowControl(
          x: 0,
          y: topRow,
          text: clipAndPadRight(upLabel, innerWidth),
          enabled: hiddenAbove > 0,
          action: .scrollPrev,
        ),
      )
      ..add(
        DockOverflowControl(
          x: 0,
          y: bottomRow,
          text: clipAndPadRight(downLabel, innerWidth),
          enabled: hiddenBelow > 0,
          action: .scrollNext,
        ),
      );
    hitRegions
      ..add(
        DockHitRegion(
          x0: 0,
          y0: topRow,
          x1: innerWidth,
          y1: topRow + 1,
          action: .scrollPrev,
        ),
      )
      ..add(
        DockHitRegion(
          x0: 0,
          y0: bottomRow,
          x1: innerWidth,
          y1: bottomRow + 1,
          action: .scrollNext,
        ),
      );
  }

  /// Measures the terminal display width of [value] in cells.
  static int displayWidth(String value) {
    var cols = 0;
    for (final grapheme in value.characters) {
      final w = graphemeWidth(grapheme);
      if (w > 0) cols += w;
    }
    return cols;
  }

  /// Clips [value] to at most [maxCols] display columns.
  static (String text, int cols) clipWithWidth(String value, int maxCols) {
    if (maxCols <= 0 || value.isEmpty) return ('', 0);
    final sb = StringBuffer();
    var usedCols = 0;
    for (final grapheme in value.characters) {
      final w = graphemeWidth(grapheme);
      if (w <= 0) continue;
      if (usedCols + w > maxCols) break;
      sb.write(grapheme);
      usedCols += w;
    }
    return ('$sb', usedCols);
  }

  /// Clips [value] to [targetCols] display columns and right-pads with spaces.
  static String clipAndPadRight(String value, int targetCols) {
    if (targetCols <= 0) return '';
    final (clipped, usedCols) = clipWithWidth(value, targetCols);
    if (usedCols >= targetCols) return clipped;
    return '$clipped${' ' * (targetCols - usedCols)}';
  }

  /// Extracts an exact [takeCols]-wide display slice starting at [skipCols],
  /// healing split wide graphemes at slice boundaries with `' '`.
  static String sliceColumns(String value, int skipCols, int takeCols) {
    if (takeCols <= 0 || value.isEmpty) return ' ' * max(0, takeCols);
    final sb = StringBuffer();
    var col = 0;
    var written = 0;
    final sliceEnd = skipCols + takeCols;

    for (final grapheme in value.characters) {
      final w = graphemeWidth(grapheme);
      if (w <= 0) continue;
      written += _writeSlicedGrapheme(
        sb: sb,
        grapheme: grapheme,
        width: w,
        col: col,
        skipCols: skipCols,
        sliceEnd: sliceEnd,
        remaining: takeCols - written,
      );
      col += w;
      if (written >= takeCols) break;
    }

    if (written < takeCols) {
      sb.write(' ' * (takeCols - written));
    }
    return '$sb';
  }

  static int _writeSlicedGrapheme({
    required StringBuffer sb,
    required String grapheme,
    required int width,
    required int col,
    required int skipCols,
    required int sliceEnd,
    required int remaining,
  }) {
    final nextCol = col + width;
    if (nextCol <= skipCols) return 0;
    if (col < skipCols) {
      final pad = min(nextCol - skipCols, remaining);
      sb.write(' ' * pad);
      return pad;
    }
    if (nextCol > sliceEnd) {
      sb.write(' ' * remaining);
      return remaining;
    }
    sb.write(grapheme);
    return width;
  }
}

typedef _MeasuredTopTab = ({
  DockTabItemSpec spec,
  String fullText,
  int natX0,
  int natX1,
  bool hasDismiss,
});
