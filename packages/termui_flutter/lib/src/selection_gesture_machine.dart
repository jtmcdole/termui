import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart' show kDoubleTapTimeout;
import 'package:hierarchical_state_machine/hierarchical_state_machine.dart';
import 'package:termui/terminal/event.dart' as term;
import 'package:termui/ui/buffer.dart';
import 'package:termui/ui/style.dart';
import 'package:termui/ui/widgets/interactive/selection_controller.dart';

/// States of the [SelectionGestureMachine] hierarchical state machine.
enum SelectionGestureState {
  /// Top-level composite root state.
  root,

  /// Resting state with no active pointer gesture and no retained selection.
  idle,

  /// Completed selection retained on screen (`copyOnSelect == false`).
  selected,

  /// Left-button gesture routed to a mouse-tracking TUI (`?1000`/`?1002`/`?1003`).
  ptyTracking,

  /// `Ctrl`/`Cmd`+click (or macOS `Ctrl`+right-click) armed on a hyperlink.
  linkClicking,

  /// Composite parent of all active local pointer-selection gestures.
  selecting,

  /// Primary mouse down at anchor; awaiting drag past initial tap cell.
  pressing,

  /// Active stream/character drag selection.
  draggingStream,

  /// Active rectangular block/box drag selection (`Alt` held).
  draggingBlock,

  /// Active word-snapped selection (double-click and optional word-drag).
  draggingWord,
}

/// Events driving [SelectionGestureMachine].
enum SelectionGestureEvent {
  /// Primary mouse button pressed on a cell.
  leftDown,

  /// Secondary mouse button pressed (`macOS` `Ctrl+RightClick` link check).
  rightDown,

  /// Pointer dragged while a button is held, or viewport scrolled mid-gesture.
  pointerDrag,

  /// Primary mouse button released.
  leftUp,

  /// Secondary mouse button released.
  rightUp,

  /// Active pointer gesture cancelled (`PointerCancelEvent`).
  pointerCancel,

  /// Active selection copied via keyboard shortcut.
  copyShortcut,

  /// Armed hyperlink gesture disarmed without cancelling physical button suppression.
  disarmLinks,

  /// Selection reset due to mode toggle, scrollback clear, or alt-screen switch.
  reset,
}

/// Payload delivered with [SelectionGestureEvent.leftDown] and [SelectionGestureEvent.rightDown].
typedef SelectionPointerDown = ({
  int col,
  int row,
  int topVirtualRow,
  Buffer? buffer,
  String? hoveredUri,
  bool builtinSelectionEnabled,
  bool builtinLinkOpenEnabled,
  bool mouseTracking,
  bool openVerticalScrollback,
  bool isShift,
  bool isAlt,
  bool isLinkModifier,
  bool isMacCtrlRightClick,
  DateTime now,
});

/// Payload delivered with [SelectionGestureEvent.pointerDrag].
typedef SelectionPointerDrag = ({
  int col,
  int row,
  int rawRow,
  int effRows,
  int topVirtualRow,
  Buffer? buffer,
  bool builtinSelectionEnabled,
  bool isAlt,
});

/// Payload delivered with [SelectionGestureEvent.leftUp] and [SelectionGestureEvent.rightUp].
typedef SelectionPointerUp = ({
  int col,
  int row,
  String? hoveredUri,
  bool builtinSelectionEnabled,
  bool builtinLinkOpenEnabled,
  bool copyOnSelect,
  bool isLinkModifier,
});

/// Hierarchical state machine governing terminal pointer selection, word
/// double-tap, box/stream drag modes, edge auto-scroll, hyperlink click arming,
/// and PTY mouse-tracking suppression.
final class SelectionGestureMachine {
  /// Selection model mutated by gesture transitions.
  final TerminalSelectionController controller;

  /// Callback invoked to extract, copy, and clear the active selection.
  final VoidCallback onCopySelection;

  /// Callback invoked when a valid `Ctrl`/`Cmd` hyperlink click completes.
  final void Function(String uri) onOpenUrl;

  /// Optional callback invoked periodically while dragging above or below the viewport.
  void Function(int rowDelta)? onEdgeAutoScroll;

  /// Maximum interval between two taps on the same virtual cell for word selection.
  final Duration doubleTapTimeout;

  /// Tick cadence for out-of-bounds top/bottom edge auto-scrolling.
  final Duration autoScrollInterval;

  late final Machine<SelectionGestureState, SelectionGestureEvent> _machine;

  SelectionGestureState _activeLeaf = .idle;
  term.MouseButton _linkButton = .left;
  ({int col, int row})? _linkPressCell;
  ({int col, int virtualRow})? _lastTapVirtualCell;
  DateTime? _lastTapAt;
  ({int col, int row, int rawRow})? _lastDragScreenCell;
  bool _suppressLeftPty = false;
  bool _suppressRightLink = false;
  bool _cancelEmitsPtyRelease = false;
  Timer? _autoScrollTimer;
  int _autoScrollDelta = 0;

  /// Creates and starts a [SelectionGestureMachine].
  SelectionGestureMachine({
    required this.controller,
    required this.onCopySelection,
    required this.onOpenUrl,
    this.onEdgeAutoScroll,
    this.doubleTapTimeout = kDoubleTapTimeout,
    this.autoScrollInterval = const Duration(milliseconds: 50),
  }) {
    final blueprint =
        MachineBlueprint<SelectionGestureState, SelectionGestureEvent>(
          name: 'terminal-selection-gesture',
          root: .composite(
            id: .root,
            initial: .idle,
            on: {
              .leftDown: _leftDownTransitions(),
              .reset: .to(target: .idle, action: _onReset),
              .copyShortcut: .to(target: .idle, action: _onCopyShortcut),
              .pointerCancel: .any([
                .to(
                  target: .idle,
                  guard: _isInPtyTracking,
                  action: _onPtyCancel,
                ),
                .to(
                  target: .idle,
                  guard: _isInSelecting,
                  action: _onSelectingCancel,
                ),
                .to(
                  target: .idle,
                  guard: _isInLinkClicking,
                  action: _onLinkCancel,
                ),
                .to(target: .idle, action: _onLinkCancel),
              ]),
            },
            children: [
              _buildIdleState(),
              _buildSelectedState(),
              _buildPtyTrackingState(),
              _buildLinkClickingState(),
              _buildSelectingState(),
            ],
          ),
        );
    final (compiled, _) = blueprint.compile();
    _machine = compiled!..start();
  }

  /// Active leaf state of the gesture machine.
  SelectionGestureState get state => _activeLeaf;

  /// Whether a pointer selection gesture is currently held down (`selecting` composite).
  bool get isSelectingGesture => switch (_activeLeaf) {
    .pressing || .draggingStream || .draggingBlock || .draggingWord => true,
    _ => false,
  };

  /// Whether an active selection drag (excluding stationary `.pressing`) is in progress.
  bool get isDraggingSelection => switch (_activeLeaf) {
    .draggingStream || .draggingBlock || .draggingWord => true,
    _ => false,
  };

  /// Most recent screen `(col, row, rawRow)` observed during an active selection gesture.
  ({int col, int row, int rawRow})? get lastDragScreenCell =>
      _lastDragScreenCell;

  /// Dispatches [event] with optional [data] to the state machine synchronously.
  void dispatch(SelectionGestureEvent event, [Object? data]) {
    unawaited(_machine.handle(event, data));
  }

  /// Consumes whether the current left-button [type] event should be withheld from the PTY.
  bool consumeLeftPtySuppression(term.MouseEventType type) {
    final suppress =
        _suppressLeftPty &&
        (type == .press || type == .drag || type == .release);
    if (type == .release) {
      _suppressLeftPty = false;
    }
    return suppress;
  }

  /// Consumes whether a macOS `Ctrl+RightClick` [type] event should be withheld from the PTY.
  bool consumeRightLinkSuppression(
    term.MouseButton button,
    term.MouseEventType type,
  ) {
    if (button != .right || !_suppressRightLink) return false;
    if (type == .release) {
      _suppressRightLink = false;
    }
    return true;
  }

  /// Consumes whether the last [SelectionGestureEvent.pointerCancel] requires a synthetic PTY release.
  bool consumeCancelPtyRelease() {
    final emit = _cancelEmitsPtyRelease;
    _cancelEmitsPtyRelease = false;
    return emit;
  }

  /// Clears armed hyperlink press state when built-in link opening is disabled.
  void disarmLinks() {
    _linkPressCell = null;
    if (_activeLeaf == .linkClicking) {
      dispatch(.disarmLinks);
    }
  }

  /// Stops the state machine and cancels any active edge auto-scroll timer.
  void dispose() {
    _stopAutoScroll();
    _machine.stop();
  }

  BasicBlueprint<SelectionGestureState, SelectionGestureEvent>
  _buildIdleState() => .composite(
    id: .idle,
    entry: () => _activeLeaf = .idle,
    on: {
      .rightDown: _rightDownTransition(),
      .pointerDrag: .to(action: _disarmIdleLinkIfMoved),
      .leftUp: .to(action: _finishIdleRelease),
    },
  );

  BasicBlueprint<SelectionGestureState, SelectionGestureEvent>
  _buildSelectedState() => .composite(
    id: .selected,
    entry: () => _activeLeaf = .selected,
    on: {.rightDown: _rightDownTransition()},
  );

  BasicBlueprint<SelectionGestureState, SelectionGestureEvent>
  _buildPtyTrackingState() => .composite(
    id: .ptyTracking,
    entry: () => _activeLeaf = .ptyTracking,
    on: {.leftUp: .to(target: .idle)},
  );

  BasicBlueprint<SelectionGestureState, SelectionGestureEvent>
  _buildLinkClickingState() => .composite(
    id: .linkClicking,
    entry: () => _activeLeaf = .linkClicking,
    on: {
      .disarmLinks: .to(target: .idle, action: _disarmLinkPress),
      .pointerDrag: .to(action: _disarmLinkIfMoved),
      .leftUp: .to(
        target: .idle,
        guard: _isLeftLinkGesture,
        action: _finishLinkClickRelease,
      ),
      .rightUp: .to(
        target: .idle,
        guard: _isRightLinkGesture,
        action: _finishLinkClickRelease,
      ),
    },
  );

  BasicBlueprint<SelectionGestureState, SelectionGestureEvent>
  _buildSelectingState() => .composite(
    id: .selecting,
    initial: .pressing,
    exit: _exitSelecting,
    children: [
      .composite(
        id: .pressing,
        entry: () => _activeLeaf = .pressing,
        on: {
          .pointerDrag: .any([
            .to(guard: _isJitterOnTapCell, action: _onJitterDrag),
            .to(
              target: .draggingBlock,
              guard: _isDragAlt,
              action: _applyBlockDrag,
            ),
            .to(target: .draggingStream, action: _applyStreamDrag),
          ]),
          .leftUp: .to(target: .idle, action: _finishPressWithoutDrag),
        },
      ),
      .composite(
        id: .draggingStream,
        entry: () => _activeLeaf = .draggingStream,
        on: {
          .pointerDrag: .any([
            .to(
              target: .draggingBlock,
              guard: _isDragAlt,
              action: _applyBlockDrag,
            ),
            .to(action: _applyStreamDrag),
          ]),
          .leftUp: _completedSelectionReleaseTransitions(),
        },
      ),
      .composite(
        id: .draggingBlock,
        entry: () => _activeLeaf = .draggingBlock,
        on: {
          .pointerDrag: .any([
            .to(
              target: .draggingStream,
              guard: _isDragNotAlt,
              action: _applyStreamDrag,
            ),
            .to(action: _applyBlockDrag),
          ]),
          .leftUp: _completedSelectionReleaseTransitions(),
        },
      ),
      .composite(
        id: .draggingWord,
        entry: () => _activeLeaf = .draggingWord,
        on: {
          .pointerDrag: .to(action: _applyWordDrag),
          .leftUp: _completedSelectionReleaseTransitions(),
        },
      ),
    ],
  );

  TransitionBlueprint<SelectionGestureState, SelectionGestureEvent>
  _leftDownTransitions() => .any([
    .to(
      target: .linkClicking,
      guard: _isLeftLinkClick,
      action: _armLeftLinkClick,
    ),
    .to(
      target: .ptyTracking,
      guard: _isPtyMousePress,
      action: _enterPtyTracking,
    ),
    .to(
      target: .idle,
      guard: _isDisabledSelectionPress,
      action: _onDisabledSelectionPress,
    ),
    .to(target: .idle, guard: _isGraphicPress, action: _onGraphicPress),
    .to(
      target: .draggingWord,
      guard: _isDoubleTapWordPress,
      action: _startWordSelection,
    ),
    .to(target: .pressing, action: _startPressSelection),
  ]);

  TransitionBlueprint<SelectionGestureState, SelectionGestureEvent>
  _rightDownTransition() => .to(
    target: .linkClicking,
    guard: _isRightLinkClick,
    action: _armRightLinkClick,
  );

  TransitionBlueprint<SelectionGestureState, SelectionGestureEvent>
  _completedSelectionReleaseTransitions() => .any([
    .to(
      target: .idle,
      guard: _isCopyOnSelectRelease,
      action: _onCopyAndClearRelease,
    ),
    .to(target: .selected, action: _disarmLinkPress),
  ]);

  bool _isInPtyTracking(SelectionGestureEvent? _, Object? _) =>
      _activeLeaf == .ptyTracking;
  bool _isInSelecting(SelectionGestureEvent? _, Object? _) =>
      isSelectingGesture;
  bool _isInLinkClicking(SelectionGestureEvent? _, Object? _) =>
      _activeLeaf == .linkClicking;
  bool _isLeftLinkGesture(SelectionGestureEvent? _, Object? _) =>
      _linkButton == .left;
  bool _isRightLinkGesture(SelectionGestureEvent? _, Object? _) =>
      _linkButton == .right;

  static bool _isLeftLinkClick(SelectionGestureEvent? _, Object? raw) {
    final d = raw! as SelectionPointerDown;
    return d.builtinLinkOpenEnabled &&
        d.isLinkModifier &&
        d.hoveredUri != null &&
        d.hoveredUri!.isNotEmpty;
  }

  static bool _isRightLinkClick(SelectionGestureEvent? _, Object? raw) {
    final d = raw! as SelectionPointerDown;
    return d.builtinLinkOpenEnabled &&
        d.isMacCtrlRightClick &&
        d.hoveredUri != null &&
        d.hoveredUri!.isNotEmpty;
  }

  static bool _isPtyMousePress(SelectionGestureEvent? _, Object? raw) {
    final d = raw! as SelectionPointerDown;
    return d.mouseTracking && !(d.isShift && d.builtinSelectionEnabled);
  }

  static bool _isDisabledSelectionPress(SelectionGestureEvent? _, Object? raw) {
    final d = raw! as SelectionPointerDown;
    return !d.builtinSelectionEnabled;
  }

  static bool _isGraphicPress(SelectionGestureEvent? _, Object? raw) {
    final d = raw! as SelectionPointerDown;
    return _isGraphicCanvasPress(d.buffer, d.row, _resolveStartRegion(d));
  }

  bool _isDoubleTapWordPress(SelectionGestureEvent? _, Object? raw) {
    final d = raw! as SelectionPointerDown;
    if (d.isAlt || d.buffer == null) return false;
    final lastAt = _lastTapAt;
    if (lastAt == null || d.now.difference(lastAt) > doubleTapTimeout) {
      return false;
    }
    final leadCol = _resolveTapLeadCol(d.buffer, d.col, d.row);
    return _lastTapVirtualCell ==
        (col: leadCol, virtualRow: d.topVirtualRow + d.row);
  }

  bool _isJitterOnTapCell(SelectionGestureEvent? _, Object? raw) {
    final d = raw! as SelectionPointerDrag;
    if (!d.builtinSelectionEnabled) return true;
    if (controller.hasSelection) return false;
    if (d.rawRow < 0 || d.rawRow >= d.effRows) return false;
    final leadCol = _resolveTapLeadCol(d.buffer, d.col, d.row);
    return _lastTapVirtualCell ==
        (col: leadCol, virtualRow: d.topVirtualRow + d.row);
  }

  static bool _isDragAlt(SelectionGestureEvent? _, Object? raw) {
    final d = raw! as SelectionPointerDrag;
    return d.builtinSelectionEnabled && d.isAlt;
  }

  static bool _isDragNotAlt(SelectionGestureEvent? _, Object? raw) {
    final d = raw! as SelectionPointerDrag;
    return d.builtinSelectionEnabled && !d.isAlt;
  }

  static bool _isCopyOnSelectRelease(SelectionGestureEvent? _, Object? raw) =>
      (raw! as SelectionPointerUp).copyOnSelect;

  void _onReset(SelectionGestureEvent? _, Object? _) {
    _clearGestureState();
    controller.clearSelection();
  }

  void _onPtyCancel(SelectionGestureEvent? _, Object? _) {
    _resetAllLatches();
    _cancelEmitsPtyRelease = true;
    controller.clearSelection();
  }

  void _onSelectingCancel(SelectionGestureEvent? _, Object? _) {
    _resetAllLatches();
    controller.clearSelection();
  }

  void _onLinkCancel(SelectionGestureEvent? _, Object? _) {
    _resetAllLatches();
  }

  void _clearGestureState() {
    _stopAutoScroll();
    _linkPressCell = null;
    _lastTapAt = null;
    _lastTapVirtualCell = null;
    _lastDragScreenCell = null;
    _cancelEmitsPtyRelease = false;
  }

  void _resetAllLatches() {
    _clearGestureState();
    _suppressLeftPty = false;
    _suppressRightLink = false;
  }

  void _exitSelecting() {
    _stopAutoScroll();
    _lastDragScreenCell = null;
  }

  void _armLeftLinkClick(SelectionGestureEvent? _, Object? raw) {
    final d = raw! as SelectionPointerDown;
    _linkButton = .left;
    _linkPressCell = (col: d.col, row: d.row);
    _suppressLeftPty = d.mouseTracking;
  }

  void _armRightLinkClick(SelectionGestureEvent? _, Object? raw) {
    final d = raw! as SelectionPointerDown;
    _linkButton = .right;
    _linkPressCell = (col: d.col, row: d.row);
    _suppressRightLink = true;
  }

  void _enterPtyTracking(SelectionGestureEvent? _, Object? _) {
    _linkPressCell = null;
    _lastTapAt = null;
    _lastTapVirtualCell = null;
    _suppressLeftPty = false;
    controller.clearSelection();
  }

  void _onDisabledSelectionPress(SelectionGestureEvent? _, Object? raw) {
    final d = raw! as SelectionPointerDown;
    _suppressLeftPty = false;
    _linkPressCell = d.builtinLinkOpenEnabled ? (col: d.col, row: d.row) : null;
  }

  void _onGraphicPress(SelectionGestureEvent? _, Object? raw) {
    final d = raw! as SelectionPointerDown;
    _linkPressCell = null;
    _lastTapAt = null;
    _lastTapVirtualCell = null;
    _suppressLeftPty = d.mouseTracking;
    controller.clearSelection();
  }

  void _startWordSelection(SelectionGestureEvent? _, Object? raw) {
    final d = raw! as SelectionPointerDown;
    final region = _resolveStartRegion(d);
    final leadCol = _resolveTapLeadCol(d.buffer, d.col, d.row);
    _suppressLeftPty = d.mouseTracking;
    _linkPressCell = d.builtinLinkOpenEnabled ? (col: d.col, row: d.row) : null;
    _lastTapAt = null;
    _lastTapVirtualCell = null;
    _lastDragScreenCell = (col: d.col, row: d.row, rawRow: d.row);
    controller.selectWord(
      d.buffer!,
      leadCol,
      d.row,
      region: region,
      topVirtualRow: d.topVirtualRow,
    );
  }

  void _startPressSelection(SelectionGestureEvent? _, Object? raw) {
    final d = raw! as SelectionPointerDown;
    final mode = d.isAlt ? SelectionMode.block : SelectionMode.stream;
    final region = _resolveStartRegion(d);
    final leadCol = _resolveTapLeadCol(d.buffer, d.col, d.row);
    _suppressLeftPty = d.mouseTracking;
    _linkPressCell = d.builtinLinkOpenEnabled ? (col: d.col, row: d.row) : null;
    _lastTapAt = d.now;
    _lastTapVirtualCell = (col: leadCol, virtualRow: d.topVirtualRow + d.row);
    _lastDragScreenCell = (col: d.col, row: d.row, rawRow: d.row);
    controller.startSelection(
      d.col,
      d.topVirtualRow + d.row,
      mode: mode,
      region: region,
    );
  }

  void _onJitterDrag(SelectionGestureEvent? _, Object? raw) {
    final d = raw! as SelectionPointerDrag;
    _disarmLinkIfCellChanged(d.col, d.row);
  }

  void _applyStreamDrag(SelectionGestureEvent? _, Object? raw) {
    final d = raw! as SelectionPointerDrag;
    if (!d.builtinSelectionEnabled) return;
    _disarmLinkIfCellChanged(d.col, d.row);
    _lastTapAt = null;
    _lastDragScreenCell = (col: d.col, row: d.row, rawRow: d.rawRow);
    controller.updateSelection(
      d.col,
      d.topVirtualRow + d.row,
      mode: SelectionMode.stream,
    );
    _syncEdgeAutoScroll(d);
  }

  void _applyBlockDrag(SelectionGestureEvent? _, Object? raw) {
    final d = raw! as SelectionPointerDrag;
    if (!d.builtinSelectionEnabled) return;
    _disarmLinkIfCellChanged(d.col, d.row);
    _lastTapAt = null;
    _lastDragScreenCell = (col: d.col, row: d.row, rawRow: d.rawRow);
    controller.updateSelection(
      d.col,
      d.topVirtualRow + d.row,
      mode: SelectionMode.block,
    );
    _syncEdgeAutoScroll(d);
  }

  void _applyWordDrag(SelectionGestureEvent? _, Object? raw) {
    final d = raw! as SelectionPointerDrag;
    if (!d.builtinSelectionEnabled) return;
    _disarmLinkIfCellChanged(d.col, d.row);
    _lastDragScreenCell = (col: d.col, row: d.row, rawRow: d.rawRow);
    final buf = d.buffer;
    if (buf != null) {
      controller.updateWordSelection(
        buf,
        d.col,
        d.row,
        topVirtualRow: d.topVirtualRow,
      );
    }
    _syncEdgeAutoScroll(d);
  }

  void _disarmIdleLinkIfMoved(SelectionGestureEvent? _, Object? raw) {
    final d = raw! as SelectionPointerDrag;
    _disarmLinkIfCellChanged(d.col, d.row);
  }

  void _disarmLinkIfMoved(SelectionGestureEvent? _, Object? raw) {
    final d = raw! as SelectionPointerDrag;
    _disarmLinkIfCellChanged(d.col, d.row);
  }

  void _disarmLinkIfCellChanged(int col, int row) {
    if (_linkPressCell != null && _linkPressCell != (col: col, row: row)) {
      _linkPressCell = null;
    }
  }

  void _disarmLinkPress(SelectionGestureEvent? _, Object? _) {
    _linkPressCell = null;
  }

  void _finishIdleRelease(SelectionGestureEvent? _, Object? raw) {
    _maybeOpenClickedLink(raw! as SelectionPointerUp);
  }

  void _finishPressWithoutDrag(SelectionGestureEvent? _, Object? raw) {
    final up = raw! as SelectionPointerUp;
    if (up.builtinSelectionEnabled) {
      controller.clearSelection();
    }
    _maybeOpenClickedLink(up);
  }

  void _finishLinkClickRelease(SelectionGestureEvent? _, Object? raw) {
    final up = raw! as SelectionPointerUp;
    if (_linkButton == .left && up.builtinSelectionEnabled) {
      controller.clearSelection();
    }
    _maybeOpenClickedLink(up);
  }

  void _onCopyAndClearRelease(SelectionGestureEvent? _, Object? _) {
    _linkPressCell = null;
    onCopySelection();
  }

  void _onCopyShortcut(SelectionGestureEvent? _, Object? _) {
    _linkPressCell = null;
    onCopySelection();
  }

  void _maybeOpenClickedLink(SelectionPointerUp up) {
    final clicked = _linkPressCell == (col: up.col, row: up.row);
    _linkPressCell = null;
    final uri = up.hoveredUri;
    if (up.builtinLinkOpenEnabled &&
        clicked &&
        uri != null &&
        uri.isNotEmpty &&
        up.isLinkModifier) {
      onOpenUrl(uri);
    }
  }

  void _syncEdgeAutoScroll(SelectionPointerDrag d) {
    final callback = onEdgeAutoScroll;
    if (callback == null || d.effRows <= 0) {
      _stopAutoScroll();
      return;
    }
    if (d.rawRow < 0) {
      _autoScrollDelta = d.rawRow.clamp(-5, -1);
    } else if (d.rawRow >= d.effRows) {
      _autoScrollDelta = (d.rawRow - d.effRows + 1).clamp(1, 5);
    } else {
      _stopAutoScroll();
      return;
    }
    _autoScrollTimer ??= Timer.periodic(
      autoScrollInterval,
      (_) => _tickEdgeAutoScroll(),
    );
  }

  void _tickEdgeAutoScroll() {
    if (!isSelectingGesture || _autoScrollDelta == 0) {
      _stopAutoScroll();
      return;
    }
    onEdgeAutoScroll?.call(_autoScrollDelta);
  }

  void _stopAutoScroll() {
    _autoScrollTimer?.cancel();
    _autoScrollTimer = null;
    _autoScrollDelta = 0;
  }

  static SelectionRegion? _resolveStartRegion(SelectionPointerDown d) {
    final buf = d.buffer;
    if (buf == null) return null;
    final mode = d.isAlt ? SelectionMode.block : SelectionMode.stream;
    return TerminalSelectionController.resolveRegionForCell(
      buf,
      d.col,
      d.row,
      mode: mode,
      topVirtualRow: d.topVirtualRow,
      openVerticalScrollback: d.openVerticalScrollback,
    );
  }

  static int _resolveTapLeadCol(Buffer? buf, int col, int row) {
    if (buf == null || col <= 0 || col >= buf.width) return col;
    if (row < 0 || row >= buf.height) return col;
    return buf.getCharacter(col, row).isEmpty ? col - 1 : col;
  }

  static bool _isGraphicCanvasPress(
    Buffer? buf,
    int row,
    SelectionRegion? region,
  ) {
    if (buf == null || row < 0 || row >= buf.height) return false;
    final minCol = region?.minCol ?? 0;
    final maxCol = region?.maxCol ?? (buf.width - 1);
    var halfBlocks = 0;
    for (var x = minCol; x <= maxCol; x++) {
      if (Modifier.has(buf.getModifiers(x, row), Modifier.kittyPlaceholder)) {
        return true;
      }
      final ch = buf.getCharacter(x, row);
      if (ch == '▀' || ch == '▄') {
        halfBlocks++;
        if (halfBlocks >= 8) return true;
      }
    }
    return false;
  }
}
