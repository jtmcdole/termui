import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:termui/terminal/event.dart' as ev;
import 'package:termui/termui.dart' show TerminalSelectionController;
import 'package:termui_cast_protocol/termui_cast_protocol.dart';
import 'package:termui_pty/termui_pty.dart';

import 'models.dart';
import 'session_slot.dart';
import 'workspace_buffer_compositor.dart';

/// Manages pointer gestures, text selection, drag auto-scroll, and link-hover
/// animation for `CastWorkspaceViewModel`.
final class WorkspacePointerController {
  static const int _pasteChunkBytes = 65536;
  static const double _ptyCellPixelW = 8.0;
  static const double _ptyCellPixelH = 16.0;
  static const int _unboundedMaxVirtualRow = 0x3FFFFFFF;
  static final RegExp _lineEndings = RegExp(r'\r\n|\n');
  static final RegExp _controlChars = RegExp(r'[\x00-\x1F\x7F-\x9F]');
  static final RegExp _windowsDrivePath = RegExp(r'^/[A-Za-z]:/');

  /// Tick interval for mouse-selection drag-to-edge auto-scrolling.
  final Duration dragAutoScrollInterval;

  /// Tick interval for the Rainbow Road link-hover wave while `Ctrl`/`Cmd` is held.
  final Duration linkHoverAnimationInterval;

  /// Returns whether the owning view model has been disposed.
  final bool Function() isDisposed;

  /// Returns the currently active [SessionSlot], or `null`.
  final SessionSlot? Function() activeSlot;

  /// Returns the current PTY viewport column count.
  final int Function() viewportCols;

  /// Returns the current PTY viewport row count.
  final int Function() viewportRows;

  /// Returns the viewer's rendered `(width, height)` cell size in logical pixels.
  final (double width, double height) Function() cellPixelSize;

  /// Returns whether copy-on-select is currently enabled.
  final bool Function() copyOnSelect;

  /// Returns whether a hidden-dock clipboard notice banner occupies row 0.
  final bool Function() isHiddenClipboardNoticeVisible;

  /// Dismisses the active clipboard notice banner.
  final void Function() dismissClipboardNotice;

  /// Copies the current non-empty selection to the host clipboard.
  final bool Function() copySelectionToClipboard;

  /// Copies a sanitized `file://` `OSC 8` local path to the clipboard with a toast.
  final void Function(String localPath) onCopyFileLink;

  /// Scrolls the active session by the given line delta.
  final bool Function(int deltaLines) scrollActiveBy;

  /// Sends encoded mouse or alternate-scroll input bytes to the active session.
  final void Function(SessionId sessionId, List<int> bytes) sendInput;

  /// Returns the current external URL opener callback, if configured.
  final void Function(Uri url)? Function() onOpenUrl;

  /// Refreshes hover state and notifies visual listeners.
  final void Function() onNotifyVisualListeners;

  /// Emits a visual change without recomputing hover state.
  final void Function() onEmitVisualChange;

  TerminalSelection? _detachedSelection;
  SelectionRegion? _gesturePaneRegion;
  Point<int>? _lastHoverCell;
  Set<ev.Modifier> _hoverModifiers = const {};
  MatchedTerminalUrl? _hoveredLink;
  Timer? _linkHoverAnimationTimer;
  Timer? _dragAutoScrollTimer;
  int _dragAutoScrollStep = 0;
  ev.MouseEvent? _lastDragMouseEvent;
  bool _selectingWithMouse = false;
  bool _suppressHiddenNoticeGesture = false;
  bool _suppressLinkClickGesture = false;

  /// Creates a pointer, selection, and link-hover controller.
  WorkspacePointerController({
    required this.dragAutoScrollInterval,
    required this.linkHoverAnimationInterval,
    required this.isDisposed,
    required this.activeSlot,
    required this.viewportCols,
    required this.viewportRows,
    required this.cellPixelSize,
    required this.copyOnSelect,
    required this.isHiddenClipboardNoticeVisible,
    required this.dismissClipboardNotice,
    required this.copySelectionToClipboard,
    required this.onCopyFileLink,
    required this.scrollActiveBy,
    required this.sendInput,
    required this.onOpenUrl,
    required this.onNotifyVisualListeners,
    required this.onEmitVisualChange,
  });

  /// Active client-side text selection on the current session, if any.
  TerminalSelection? get activeSelection {
    final slot = activeSlot();
    if (slot == null) return _detachedSelection;
    final ctrl = slot.selectionController;
    final a = ctrl.anchor;
    final b = ctrl.focus;
    if (a == null || b == null) return null;
    return TerminalSelection(
      anchor: Point<int>(a.col, a.row),
      focus: Point<int>(b.col, b.row),
      mode: ctrl.mode,
      region: ctrl.region,
    );
  }

  /// Currently hovered URL match when `Ctrl` or `Cmd` is held, or `null`.
  MatchedTerminalUrl? get hoveredLink => _hoveredLink;

  /// Cancels any active drag auto-scroll timer.
  void cancelDragAutoScroll() {
    _dragAutoScrollTimer?.cancel();
    _dragAutoScrollTimer = null;
    _dragAutoScrollStep = 0;
    _lastDragMouseEvent = null;
  }

  /// Clears the current selection without emitting a redundant notification.
  void resetSelection() {
    cancelDragAutoScroll();
    _cancelLinkHoverAnimation();
    _detachedSelection = null;
    _gesturePaneRegion = null;
    _hoveredLink = null;
    final slot = activeSlot();
    slot?.selectionController.clearSelection();
    slot?.hoveredLink = null;
    _selectingWithMouse = false;
  }

  /// Resets all selection, hover, and gesture state.
  void resetAll() {
    cancelDragAutoScroll();
    _cancelLinkHoverAnimation();
    _detachedSelection = null;
    _gesturePaneRegion = null;
    final slot = activeSlot();
    slot?.selectionController.clearSelection();
    slot?.hoveredLink = null;
    _selectingWithMouse = false;
    _lastHoverCell = null;
    _hoverModifiers = const {};
    _hoveredLink = null;
    _suppressHiddenNoticeGesture = false;
    _suppressLinkClickGesture = false;
  }

  /// Clears the current client-side terminal selection and notifies listeners if needed.
  void clearSelection() {
    cancelDragAutoScroll();
    _selectingWithMouse = false;
    _gesturePaneRegion = null;
    final previous = activeSelection;
    if (previous == null) return;
    _detachedSelection = null;
    activeSlot()?.selectionController.clearSelection();
    if (!previous.isCollapsed) {
      onNotifyVisualListeners();
    }
  }

  /// Updates the active keyboard [modifiers] for stationary pointer link-hover detection.
  void updateHoverModifiers(Set<ev.Modifier> modifiers) {
    if (isDisposed() || _modifiersEqual(_hoverModifiers, modifiers)) return;
    _hoverModifiers = Set<ev.Modifier>.unmodifiable(modifiers);
    refreshHoveredLink();
  }

  /// Clears the last recorded pointer cell when the cursor exits the terminal viewport.
  void clearMouseHover() {
    if (isDisposed() || _lastHoverCell == null) return;
    _lastHoverCell = null;
    refreshHoveredLink();
  }

  static bool _modifiersEqual(Set<ev.Modifier> a, Set<ev.Modifier> b) =>
      a.length == b.length && a.containsAll(b);

  /// Recomputes [hoveredLink] and emits a visual change if it changed.
  void refreshHoveredLink() {
    final previous = _hoveredLink;
    syncHoveredLinkState();
    if (_hoveredLink != previous) {
      onEmitVisualChange();
    }
  }

  /// Recomputes [hoveredLink] and synchronizes the rainbow animation timer.
  void syncHoveredLinkState() {
    _hoveredLink = _computeHoveredLink();
    activeSlot()?.hoveredLink = _hoveredLink;
    _syncLinkHoverAnimationTimer();
  }

  MatchedTerminalUrl? _computeHoveredLink() {
    final cell = _lastHoverCell;
    if (isDisposed() ||
        cell == null ||
        _selectingWithMouse ||
        !_isLinkHoverModifier(_hoverModifiers)) {
      return null;
    }
    if (isHiddenClipboardNoticeVisible() && cell.y == 0) {
      return null;
    }
    final match = WorkspaceBufferCompositor.matchUrlAtCell(
      activeSlot(),
      cell.x,
      cell.y,
    );
    if (match == null) return null;
    if (match.url.scheme.toLowerCase() == 'file') return match;
    return onOpenUrl() != null ? match : null;
  }

  static bool _isLinkHoverModifier(Set<ev.Modifier> mods) =>
      !mods.contains(ev.Modifier.shift) &&
      !mods.contains(ev.Modifier.alt) &&
      (mods.contains(ev.Modifier.control) || mods.contains(ev.Modifier.meta));

  void _syncLinkHoverAnimationTimer() {
    if (isDisposed() ||
        _hoveredLink == null ||
        linkHoverAnimationInterval <= Duration.zero) {
      _cancelLinkHoverAnimation();
      return;
    }
    if (_linkHoverAnimationTimer != null) return;
    _linkHoverAnimationTimer = Timer.periodic(
      linkHoverAnimationInterval,
      (_) => _onLinkHoverAnimationTick(),
    );
  }

  void _onLinkHoverAnimationTick() {
    if (isDisposed() || _hoveredLink == null) {
      _cancelLinkHoverAnimation();
      return;
    }
    onEmitVisualChange();
  }

  void _cancelLinkHoverAnimation() {
    _linkHoverAnimationTimer?.cancel();
    _linkHoverAnimationTimer = null;
  }

  /// Routes [event] to hidden-banner dismissal, URL opening, scrollback, selection, or PTY mouse encoding.
  bool handlePtyMouseEvent(ev.MouseEvent event) {
    _recordMouseHoverPosition(event);
    try {
      if (_consumeHiddenNoticeMouse(event)) return true;
      if (_consumeLinkClickMouse(event)) return true;
      final slot = activeSlot();
      if (_handleLocalScrollWheel(slot, event)) return true;
      if (_handleLocalMouseSelection(slot, event)) return true;
      return encodeAndSendMouse(event);
    } finally {
      refreshHoveredLink();
    }
  }

  void _recordMouseHoverPosition(ev.MouseEvent event) {
    if (event.type == .drag) {
      _lastHoverCell = null;
    } else if (event.type == .move) {
      _lastHoverCell = event.x < 1 || event.y < 1
          ? null
          : Point<int>(event.x - 1, event.y - 1);
    }
    _hoverModifiers = Set<ev.Modifier>.unmodifiable(event.modifiers);
  }

  bool _handleLocalScrollWheel(SessionSlot? slot, ev.MouseEvent event) {
    if (event.type != ev.MouseEventType.press ||
        (event.button != ev.MouseButton.wheelUp &&
            event.button != ev.MouseButton.wheelDown)) {
      return false;
    }
    if (!SessionSlot.canLocalScroll(slot)) return false;
    final shiftHeld = event.modifiers.contains(ev.Modifier.shift);
    final shouldScrollLocal =
        slot!.state == .unsubscribed ||
        shiftHeld ||
        slot.scrollOffsetLines > 0 ||
        !slot.modes.mouseTracking;
    if (!shouldScrollLocal) return false;
    final step = event.button == ev.MouseButton.wheelUp ? 3 : -3;
    scrollActiveBy(step);
    if (_selectingWithMouse) {
      _applySelectionFocusFromEvent(slot, event);
    }
    return true;
  }

  bool _consumeHiddenNoticeMouse(ev.MouseEvent event) {
    if (_suppressHiddenNoticeGesture) {
      if (event.type == .drag) return true;
      if (event.type == .release) {
        _suppressHiddenNoticeGesture = false;
        return true;
      }
      _suppressHiddenNoticeGesture = false;
    }
    if (!_isHiddenNoticePress(event)) return false;
    _selectingWithMouse = false;
    _suppressHiddenNoticeGesture = true;
    dismissClipboardNotice();
    return true;
  }

  bool _isHiddenNoticePress(ev.MouseEvent event) =>
      isHiddenClipboardNoticeVisible() &&
      event.x >= 1 &&
      event.y == 1 &&
      event.button == .left &&
      event.type == .press;

  bool _consumeLinkClickMouse(ev.MouseEvent event) {
    if (_suppressLinkClickGesture) {
      if (event.type == .drag) return true;
      if (event.button == .wheelUp || event.button == .wheelDown) {
        return false;
      }
      _suppressLinkClickGesture = false;
      if (event.type == .release) return true;
    }
    if (!_isLinkClickPress(event)) return false;
    final match = WorkspaceBufferCompositor.matchUrlAtCell(
      activeSlot(),
      event.x - 1,
      event.y - 1,
    );
    if (match == null) return false;
    final url = match.url;
    if (url.scheme.toLowerCase() == 'file') {
      final localPath = _extractSanitizedFilePath(url);
      if (localPath.isEmpty) return false;
      _latchConsumedLinkClick();
      onCopyFileLink(localPath);
      return true;
    }
    final opener = onOpenUrl();
    if (opener == null) return false;
    _latchConsumedLinkClick();
    opener(url);
    return true;
  }

  void _latchConsumedLinkClick() {
    cancelDragAutoScroll();
    _selectingWithMouse = false;
    _suppressLinkClickGesture = true;
  }

  static String _extractSanitizedFilePath(Uri url) {
    String decoded;
    try {
      decoded = [
        for (final seg in url.path.split('/')) Uri.decodeComponent(seg),
      ].join('/');
    } on ArgumentError {
      decoded = url.path;
    }
    if (_windowsDrivePath.hasMatch(decoded)) {
      decoded = decoded.substring(1);
    }
    return decoded.replaceAll(_controlChars, '').trim();
  }

  static bool _isLinkClickPress(ev.MouseEvent event) {
    if (event.type != .press || event.x < 1 || event.y < 1) return false;
    final mods = event.modifiers;
    if (mods.contains(ev.Modifier.shift) || mods.contains(ev.Modifier.alt)) {
      return false;
    }
    return switch (event.button) {
      .left =>
        mods.contains(ev.Modifier.control) || mods.contains(ev.Modifier.meta),
      .right => mods.contains(ev.Modifier.control),
      _ => false,
    };
  }

  /// Encodes [event] as SGR/SGR-Pixels/X10 mouse bytes or alternate-scroll cursor keys.
  bool encodeAndSendMouse(ev.MouseEvent event) {
    final slot = activeSlot();
    if (slot == null || slot.state == .unsubscribed) return false;
    if (_canForwardMouse(slot, event)) {
      if (event.x < 1 || event.y < 1) return false;
      final usePixels = slot.modes.sgrPixelsMouse;
      final (px, py) = usePixels
          ? _normalizePtyPixels(event, cellPixelSize())
          : (null, null);
      final encoded = InputEncoder.encode(
        event,
        sgrMouse: slot.modes.sgrMouse,
        sgrPixels: usePixels,
        pixelX: px,
        pixelY: py,
      );
      if (encoded.isEmpty) return false;
      sendInput(slot.id, latin1.encode(encoded));
      return true;
    }
    return _forwardAlternateScrollIfApplicable(slot, event);
  }

  static (int?, int?) _normalizePtyPixels(
    ev.MouseEvent event,
    (double width, double height) viewerCellPx,
  ) {
    if (event.x < 1 || event.y < 1) return (null, null);
    final cellW = viewerCellPx.$1 > 0 ? viewerCellPx.$1 : _ptyCellPixelW;
    final cellH = viewerCellPx.$2 > 0 ? viewerCellPx.$2 : _ptyCellPixelH;
    final localCol = event.x - 1;
    final localRow = event.y - 1;
    final globalCol = max(0, (event.globalX ?? event.x) - 1);
    final globalRow = max(0, (event.globalY ?? event.y) - 1);
    final fracX = _subCellFraction(event.pixelX, globalCol, cellW);
    final fracY = _subCellFraction(event.pixelY, globalRow, cellH);
    final ptyPxX = max(
      1,
      (localCol * _ptyCellPixelW + (fracX * _ptyCellPixelW).floor() + 1)
          .round(),
    );
    final ptyPxY = max(
      1,
      (localRow * _ptyCellPixelH + (fracY * _ptyCellPixelH).floor() + 1)
          .round(),
    );
    return (ptyPxX, ptyPxY);
  }

  static double _subCellFraction(
    int? oneBasedGlobalPx,
    int zeroBasedGlobalCell,
    double cellSizePx,
  ) {
    if (oneBasedGlobalPx == null || cellSizePx <= 0) return 0.0;
    final offsetInCell =
        (oneBasedGlobalPx - 1) - zeroBasedGlobalCell * cellSizePx;
    return (offsetInCell / cellSizePx).clamp(0.0, 0.999999);
  }

  /// Encodes a paste [event] (wrapping in `DECSET 2004` brackets when active)
  /// and returns `(bytes, exceedsLimit)` against [maxPasteBytes].
  ({Uint8List? bytes, bool exceedsLimit}) encodePastePayload(
    ev.PasteEvent event, {
    required int maxPasteBytes,
  }) {
    final slot = activeSlot();
    if (slot == null || slot.state == .unsubscribed || event.text.isEmpty) {
      return (bytes: null, exceedsLimit: false);
    }
    final normalized = ev.PasteEvent(event.text.replaceAll(_lineEndings, '\r'));
    final bracketed = slot.modes.bracketedPaste;
    final encoded = InputEncoder.encode(normalized, bracketedPaste: bracketed);
    if (encoded.isEmpty) return (bytes: null, exceedsLimit: false);
    final bytes = Uint8List.fromList(utf8.encode(encoded));
    final payloadBytes = bracketed ? bytes.length - 12 : bytes.length;
    if (payloadBytes > maxPasteBytes) {
      return (bytes: null, exceedsLimit: true);
    }
    return (bytes: bytes, exceedsLimit: false);
  }

  /// Sends [bytes] in UTF-8 boundary-safe chunks of at most `64 KiB`.
  void sendChunkedInput(SessionId sessionId, Uint8List bytes) {
    var offset = 0;
    while (offset < bytes.length) {
      final end = _nextUtf8ChunkEnd(bytes, offset, _pasteChunkBytes);
      sendInput(sessionId, Uint8List.sublistView(bytes, offset, end));
      offset = end;
    }
  }

  static int _nextUtf8ChunkEnd(Uint8List bytes, int offset, int maxChunkBytes) {
    if (bytes.length - offset <= maxChunkBytes) return bytes.length;
    var end = offset + maxChunkBytes;
    while (end > offset && (bytes[end] & 0xC0) == 0x80) {
      end--;
    }
    return end == offset ? offset + maxChunkBytes : end;
  }

  bool _forwardAlternateScrollIfApplicable(
    SessionSlot slot,
    ev.MouseEvent event,
  ) {
    if (slot.modes.mouseTracking ||
        !slot.modes.altScreen ||
        !slot.modes.alternateScroll ||
        event.type != ev.MouseEventType.press) {
      return false;
    }
    if (event.button != ev.MouseButton.wheelUp &&
        event.button != ev.MouseButton.wheelDown) {
      return false;
    }
    final encoded = InputEncoder.encodeAlternateScroll(
      event.button,
      applicationCursorKeys: slot.modes.appCursorKeys,
    );
    if (encoded.isEmpty) return false;
    sendInput(slot.id, utf8.encode(encoded));
    return true;
  }

  bool _handleLocalMouseSelection(SessionSlot? slot, ev.MouseEvent event) =>
      switch (event.type) {
        .press when event.button == ev.MouseButton.left => _beginMouseSelection(
          slot,
          event,
        ),
        .drag when _selectingWithMouse => _updateMouseSelection(slot, event),
        .release when _selectingWithMouse => _finishMouseSelection(),
        _ => false,
      };

  bool _beginMouseSelection(SessionSlot? slot, ev.MouseEvent event) {
    if (event.x < 1 || event.y < 1) return false;
    if (_canForwardMouse(slot, event) &&
        !event.modifiers.contains(ev.Modifier.shift)) {
      clearSelection();
      return false;
    }
    final previous = activeSelection;
    final cell = _clampCellToGrid(slot, event.x - 1, event.y - 1);
    final mode = event.modifiers.contains(ev.Modifier.alt)
        ? SelectionMode.box
        : SelectionMode.normal;
    _selectingWithMouse = true;
    if (slot != null) {
      _gesturePaneRegion = _resolveVirtualSelectionRegion(slot, event);
      final region = mode == .box ? null : _gesturePaneRegion;
      slot.selectionController
        ..startSelection(cell.x, cell.y, mode: mode, region: region)
        ..updateSelection(cell.x, cell.y, mode: mode);
    } else {
      _gesturePaneRegion = null;
      _detachedSelection = TerminalSelection(
        anchor: cell,
        focus: cell,
        mode: mode,
      );
    }
    if (previous != null && !previous.isCollapsed) {
      onNotifyVisualListeners();
    }
    return true;
  }

  SelectionRegion? _resolveVirtualSelectionRegion(
    SessionSlot slot,
    ev.MouseEvent event,
  ) {
    final visibleBuf = WorkspaceBufferCompositor.composeViewportCells(slot);
    if (visibleBuf == null || visibleBuf.width <= 0 || visibleBuf.height <= 0) {
      return null;
    }
    final rawX = (event.x - 1).clamp(0, visibleBuf.width - 1);
    final rawY = (event.y - 1).clamp(0, visibleBuf.height - 1);
    final screenRegion = TerminalSelectionController.resolveRegionForCell(
      visibleBuf,
      rawX,
      rawY,
    );
    if (screenRegion == null) return null;
    final leftCol = slot.scrollOffsetCols;
    if (screenRegion.minRow == 0 &&
        screenRegion.maxRow == visibleBuf.height - 1) {
      return SelectionRegion(
        minCol: leftCol + screenRegion.minCol,
        maxCol: leftCol + screenRegion.maxCol,
        minRow: 0,
        maxRow: _unboundedMaxVirtualRow,
      );
    }
    return screenRegion.translate(dCol: leftCol, dRow: slot.topVirtualRow);
  }

  bool _updateMouseSelection(SessionSlot? slot, ev.MouseEvent event) {
    if (activeSelection == null) return true;
    _applySelectionFocusFromEvent(slot, event);
    _updateDragAutoScroll(slot, event);
    return true;
  }

  void _applySelectionFocusFromEvent(SessionSlot? slot, ev.MouseEvent event) {
    final current = activeSelection;
    if (current == null) return;
    final cell = _clampCellToGrid(slot, event.x - 1, event.y - 1);
    final mode = event.modifiers.contains(ev.Modifier.alt)
        ? SelectionMode.box
        : SelectionMode.normal;
    if (slot != null) {
      _updateSlotSelectionFocus(slot, current.anchor, cell, mode);
    } else {
      _detachedSelection = TerminalSelection(
        anchor: current.anchor,
        focus: cell,
        mode: mode,
      );
    }
    final next = activeSelection;
    if (next == null || next == current) return;
    if (!current.isCollapsed || !next.isCollapsed) {
      onNotifyVisualListeners();
    }
  }

  void _updateSlotSelectionFocus(
    SessionSlot slot,
    Point<int> anchor,
    Point<int> focus,
    SelectionMode mode,
  ) {
    final ctrl = slot.selectionController;
    final desiredRegion = mode == .box ? null : _gesturePaneRegion;
    if (ctrl.region != desiredRegion) {
      ctrl
        ..startSelection(anchor.x, anchor.y, mode: mode, region: desiredRegion)
        ..updateSelection(focus.x, focus.y, mode: mode);
      return;
    }
    ctrl.updateSelection(focus.x, focus.y, mode: mode);
  }

  void _updateDragAutoScroll(SessionSlot? slot, ev.MouseEvent event) {
    _lastDragMouseEvent = event;
    final step = _computeDragAutoScrollStep(slot, event);
    if (step == 0 || dragAutoScrollInterval <= Duration.zero) {
      cancelDragAutoScroll();
      return;
    }
    if (_dragAutoScrollTimer != null && _dragAutoScrollStep == step) return;
    _dragAutoScrollTimer?.cancel();
    _dragAutoScrollStep = step;
    _dragAutoScrollTimer = Timer.periodic(
      dragAutoScrollInterval,
      (_) => _onDragAutoScrollTick(),
    );
  }

  int _computeDragAutoScrollStep(SessionSlot? slot, ev.MouseEvent event) {
    final current = activeSelection;
    if (current == null || !SessionSlot.canLocalScroll(slot)) {
      return 0;
    }
    final maxRows = max(1, slot!.buffer?.height ?? viewportRows());
    if (maxRows < 3) return 0;
    final topVirtual = slot.topVirtualRow;
    final clampedRow = event.y.clamp(1, maxRows);
    if (event.y < 1 || (clampedRow == 1 && current.anchor.y > topVirtual)) {
      return slot.scrollOffsetLines < slot.maxScrollableLines ? 1 : 0;
    }
    final bottomVirtual = topVirtual + maxRows - 1;
    if (slot.scrollOffsetLines > 0 &&
        (event.y > maxRows ||
            (clampedRow == maxRows && current.anchor.y < bottomVirtual))) {
      return -1;
    }
    return 0;
  }

  void _onDragAutoScrollTick() {
    final slot = activeSlot();
    final lastEvent = _lastDragMouseEvent;
    if (isDisposed() ||
        !_selectingWithMouse ||
        activeSelection == null ||
        slot == null ||
        lastEvent == null ||
        _dragAutoScrollStep == 0) {
      cancelDragAutoScroll();
      return;
    }
    if (!scrollActiveBy(_dragAutoScrollStep)) {
      cancelDragAutoScroll();
      return;
    }
    _applySelectionFocusFromEvent(slot, lastEvent);
  }

  bool _finishMouseSelection() {
    cancelDragAutoScroll();
    _selectingWithMouse = false;
    _gesturePaneRegion = null;
    final current = activeSelection;
    if (current == null) return true;
    if (current.isCollapsed) {
      _detachedSelection = null;
      activeSlot()?.selectionController.clearSelection();
      return true;
    }
    if (copyOnSelect()) {
      copySelectionToClipboard();
    }
    return true;
  }

  Point<int> _clampCellToGrid(SessionSlot? slot, int rawX, int rawY) {
    final maxCols = max(1, slot?.buffer?.width ?? viewportCols());
    final maxRows = max(1, slot?.buffer?.height ?? viewportRows());
    final topVirtual = slot == null ? 0 : slot.topVirtualRow;
    final leftVirtual = slot?.scrollOffsetCols ?? 0;
    return Point<int>(
      leftVirtual + rawX.clamp(0, maxCols - 1),
      topVirtual + rawY.clamp(0, maxRows - 1),
    );
  }

  static bool _canForwardMouse(SessionSlot? slot, ev.MouseEvent event) {
    if (slot == null || slot.state == .unsubscribed) return false;
    if (!slot.modes.mouseTracking) return false;
    if (event.type == ev.MouseEventType.move &&
        event.button == ev.MouseButton.none) {
      return false;
    }
    return true;
  }
}
