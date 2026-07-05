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

  /// Creates a TerminalView that delegates event wiring to the caller.
  const TerminalView({
    super.key,
    required this.terminal,
    this.focusNode,
    this.onInput,
    this.autofocus = true,
  });

  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: focusNode,
      autofocus: autofocus,
      onKeyEvent: (event) {
        final str = InputEncoder.encode(event);
        if (str.isNotEmpty) {
          onInput?.call(str);
          return true;
        }
        return false;
      },
      child: _TerminalBufferWidget(
        terminal: terminal,
        focusNode: focusNode,
        onInput: onInput,
      ),
    );
  }
}

class _TerminalBufferWidget extends Widget {
  final VirtualTerminal terminal;
  final FocusNode? focusNode;
  final void Function(String data)? onInput;

  const _TerminalBufferWidget({
    required this.terminal,
    this.focusNode,
    this.onInput,
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

  @override
  void mount(Element? parent) {
    super.mount(parent);
    final w = widget as _TerminalBufferWidget;
    w.terminal.addListener(markNeedsBuild);
  }

  @override
  void unmount() {
    final w = widget as _TerminalBufferWidget;
    w.terminal.removeListener(markNeedsBuild);
    super.unmount();
  }

  @override
  void update(Widget newWidget) {
    final oldWidget = widget as _TerminalBufferWidget;
    final newW = newWidget as _TerminalBufferWidget;
    if (oldWidget.terminal != newW.terminal) {
      oldWidget.terminal.removeListener(markNeedsBuild);
      newW.terminal.addListener(markNeedsBuild);
    }
    super.update(newWidget);
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

    if (!w.terminal.mouseTrackingEnabled) {
      return;
    }

    // Convert local coordinates back to 1-indexed VT100 coordinates
    final translatedEvent = ev.MouseEvent(
      x: localX + 1,
      y: localY + 1,
      globalX: event.globalX,
      globalY: event.globalY,
      button: event.button,
      type: event.type,
      modifiers: event.modifiers,
    );
    final str = InputEncoder.encode(translatedEvent);
    if (str.isNotEmpty) {
      w.onInput?.call(str);
    }
  }

  @override
  void performPaint(Buffer buffer, Offset offset) {
    final w = widget as _TerminalBufferWidget;
    final source = w.terminal.buffer;

    final startX = offset.dx.toInt();
    final startY = offset.dy.toInt();
    final endX = (startX + source.width).clamp(0, buffer.width);
    final endY = (startY + source.height).clamp(0, buffer.height);

    if (startX < endX && startY < endY) {
      final rowLength = endX - startX;
      final transparent = w.terminal.transparentBackground;

      for (var ty = startY; ty < endY; ty++) {
        final sy = ty - startY;
        final targetStartIdx = ty * buffer.width + startX;
        final sourceStartIdx = sy * source.width;

        if (!transparent) {
          // Fast path: block copy entire rows
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
        } else {
          // Slow path: skip transparent cells but use direct array access
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
            }
          }
        }
      }
    }
  }
}
