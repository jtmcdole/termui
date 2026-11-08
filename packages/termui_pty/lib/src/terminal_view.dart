import 'dart:math' as math;
import 'package:termui/termui.dart';
import 'package:termui/terminal/event.dart' as ev;
import 'virtual_terminal.dart';
import 'input_encoder.dart';

/// A pure UI widget that renders a VirtualTerminal and emits input events.
class TerminalView extends StatelessWidget {
  /// The terminal state model to render.
  final VirtualTerminal terminal;

  /// Optional focus node for managing keyboard focus.
  final FocusNode? focusNode;

  /// Callback fired when the terminal receives encoded user input (keys/mouse).
  final void Function(String data)? onInput;

  /// Whether the terminal should automatically request focus.
  final bool autofocus;

  /// Optional cell pixel width used for SGR-Pixels mouse coordinate scaling.
  final int? cellPixelWidth;

  /// Optional cell pixel height used for SGR-Pixels mouse coordinate scaling.
  final int? cellPixelHeight;

  /// Creates a TerminalView that delegates event wiring to the caller.
  const TerminalView({
    super.key,
    required this.terminal,
    this.focusNode,
    this.onInput,
    this.autofocus = true,
    this.cellPixelWidth,
    this.cellPixelHeight,
  });

  @override
  bool get wantsKeyReleaseEvents => (terminal.kittyKeyboardFlags & 2) != 0;

  @override
  int getIntrinsicHeight(int width) => terminal.height;

  @override
  int getIntrinsicWidth(int height) => terminal.width;

  /// Encodes and forwards keyboard input to [onInput].
  bool handleKeyEvent(ev.KeyEvent event) {
    final str = InputEncoder.encode(
      event,
      bracketedPaste: terminal.bracketedPasteMode,
      applicationCursorKeys: terminal.applicationCursorKeys,
      kittyKeyboardFlags: terminal.kittyKeyboardFlags,
    );
    if (str.isEmpty) return false;
    onInput?.call(str);
    return true;
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: focusNode,
      autofocus: autofocus,
      wantsKeyReleaseEvents: wantsKeyReleaseEvents,
      onKeyEvent: handleKeyEvent,
      child: _TerminalBufferWidget(
        terminal: terminal,
        focusNode: focusNode,
        onInput: onInput,
        cellPixelWidth: cellPixelWidth,
        cellPixelHeight: cellPixelHeight,
      ),
    );
  }
}

class _TerminalBufferWidget extends Widget {
  final VirtualTerminal terminal;
  final FocusNode? focusNode;
  final void Function(String data)? onInput;
  final int? cellPixelWidth;
  final int? cellPixelHeight;

  const _TerminalBufferWidget({
    required this.terminal,
    this.focusNode,
    this.onInput,
    this.cellPixelWidth,
    this.cellPixelHeight,
  });

  @override
  Element createElement() => _TerminalBufferElement(this);

  @override
  int getIntrinsicHeight(int width) => terminal.height;

  @override
  int getIntrinsicWidth(int height) => terminal.width;
}

class _TerminalBufferElement extends LeafElement implements MouseEventHandler {
  _TerminalBufferElement(_TerminalBufferWidget super.widget);

  bool _lastWantsKeyRelease = false;

  @override
  void mount(Element? parent) {
    super.mount(parent);
    final w = widget as _TerminalBufferWidget;
    _lastWantsKeyRelease = (w.terminal.kittyKeyboardFlags & 2) != 0;
    w.terminal.addListener(_handleTerminalChange);
  }

  @override
  void unmount() {
    final w = widget as _TerminalBufferWidget;
    w.terminal.removeListener(_handleTerminalChange);
    super.unmount();
  }

  @override
  void update(Widget newWidget) {
    final oldWidget = widget as _TerminalBufferWidget;
    final newW = newWidget as _TerminalBufferWidget;
    if (oldWidget.terminal != newW.terminal) {
      oldWidget.terminal.removeListener(_handleTerminalChange);
      newW.terminal.addListener(_handleTerminalChange);
    }
    _lastWantsKeyRelease = (newW.terminal.kittyKeyboardFlags & 2) != 0;
    super.update(newWidget);
  }

  void _handleTerminalChange() {
    final w = widget as _TerminalBufferWidget;
    final wantsRelease = (w.terminal.kittyKeyboardFlags & 2) != 0;
    if (wantsRelease != _lastWantsKeyRelease) {
      _lastWantsKeyRelease = wantsRelease;
      var ancestor = parent;
      while (ancestor != null) {
        if (ancestor.widget is TerminalView) {
          ancestor.markNeedsBuild();
          break;
        }
        ancestor = ancestor.parent;
      }
    }
    markNeedsBuild();
  }

  @override
  Size performLayout(BoxConstraints constraints) {
    final w = widget as _TerminalBufferWidget;
    return constraints.constrain(Size(w.terminal.width, w.terminal.height));
  }

  @override
  void handleMouseEvent(ev.MouseEvent event, int localX, int localY) {
    final w = widget as _TerminalBufferWidget;
    w.focusNode?.requestFocus();
    final vt = w.terminal;

    if (!vt.mouseTrackingEnabled) {
      _handleUntrackedMouseEvent(w, vt, event);
      return;
    }

    final (pixelX, pixelY) = _resolveLocalPixels(w, event, localX, localY);
    final translatedEvent = ev.MouseEvent(
      x: localX + 1,
      y: localY + 1,
      globalX: event.globalX,
      globalY: event.globalY,
      pixelX: pixelX,
      pixelY: pixelY,
      button: event.button,
      type: event.type,
      modifiers: event.modifiers,
    );
    final str = InputEncoder.encode(
      translatedEvent,
      sgrMouse: vt.sgrMouseMode,
      sgrPixels: vt.sgrPixelsMouseMode,
      pixelX: pixelX,
      pixelY: pixelY,
    );
    if (str.isNotEmpty) {
      w.onInput?.call(str);
    }
  }

  static void _handleUntrackedMouseEvent(
    _TerminalBufferWidget w,
    VirtualTerminal vt,
    ev.MouseEvent event,
  ) {
    if (event.type != ev.MouseEventType.press) return;
    if (!vt.isUsingAlternateScreen || !vt.alternateScrollMode) return;
    final seq = InputEncoder.encodeAlternateScroll(
      event.button,
      applicationCursorKeys: vt.applicationCursorKeys,
    );
    if (seq.isNotEmpty) w.onInput?.call(seq);
  }

  static (int, int) _resolveLocalPixels(
    _TerminalBufferWidget w,
    ev.MouseEvent event,
    int localX,
    int localY,
  ) {
    final cellW = w.cellPixelWidth ?? w.terminal.cellPixelWidth;
    final cellH = w.cellPixelHeight ?? w.terminal.cellPixelHeight;
    if (event.pixelX case final px?) {
      if (event.pixelY case final py?) {
        final originCols = ((event.globalX ?? event.x) - 1) - localX;
        final originRows = ((event.globalY ?? event.y) - 1) - localY;
        return (
          math.max(1, px - originCols * cellW),
          math.max(1, py - originRows * cellH),
        );
      }
    }
    return (localX * cellW + 1, localY * cellH + 1);
  }

  @override
  void performPaint(Buffer buffer, Offset offset) {
    final w = widget as _TerminalBufferWidget;
    final source = w.terminal.buffer;

    final startX = offset.dx.toInt();
    final startY = offset.dy.toInt();
    final endX = (startX + source.width).clamp(0, buffer.width);
    final endY = (startY + source.height).clamp(0, buffer.height);
    if (startX >= endX || startY >= endY) return;

    final rowLength = endX - startX;
    buffer.registerKittyRegistry(
      Rect(startX, startY, rowLength, endY - startY),
      w.terminal.imageRegistry,
    );

    final transparent = w.terminal.transparentBackground;

    for (var ty = startY; ty < endY; ty++) {
      final sy = ty - startY;
      final targetStartIdx = ty * buffer.width + startX;
      final sourceStartIdx = sy * source.width;
      _paintBufferRow(
        buffer,
        source,
        targetStartIdx,
        sourceStartIdx,
        rowLength,
        transparent: transparent,
      );
    }
  }

  static void _paintBufferRow(
    Buffer buffer,
    Buffer source,
    int targetStartIdx,
    int sourceStartIdx,
    int rowLength, {
    required bool transparent,
  }) {
    if (!transparent) {
      buffer.characters.setRange(
        targetStartIdx,
        targetStartIdx + rowLength,
        source.characters,
        sourceStartIdx,
      );
      final targetAttrStart = targetStartIdx * 3;
      final sourceAttrStart = sourceStartIdx * 3;
      buffer.attributes.setRange(
        targetAttrStart,
        targetAttrStart + rowLength * 3,
        source.attributes,
        sourceAttrStart,
      );
      buffer.copyCellAuxRangeFrom(
        source,
        targetStartIdx,
        sourceStartIdx,
        rowLength,
      );
    } else {
      var tIdx = targetStartIdx;
      var sIdx = sourceStartIdx;
      for (var i = 0; i < rowLength; i++, tIdx++, sIdx++) {
        final sAttrIdx = sIdx * 3;
        if ((source.attributes[sAttrIdx + 2] & Modifier.transparent) == 0) {
          buffer.characters[tIdx] = source.characters[sIdx];
          final tAttrIdx = tIdx * 3;
          buffer.attributes[tAttrIdx + 0] = source.attributes[sAttrIdx + 0];
          buffer.attributes[tAttrIdx + 1] = source.attributes[sAttrIdx + 1];
          buffer.attributes[tAttrIdx + 2] = source.attributes[sAttrIdx + 2];
          buffer.copyCellAuxAt(source, tIdx, sIdx);
        }
      }
    }
  }
}
