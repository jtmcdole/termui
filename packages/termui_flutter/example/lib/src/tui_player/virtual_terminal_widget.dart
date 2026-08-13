import 'dart:math';
import 'package:termui/termui.dart';
import 'package:termui_pty/termui_pty.dart';

/// A custom termui Widget that renders cells from a [VirtualTerminal] onto the compositor [Buffer].
final class VirtualTerminalWidget extends Widget {
  /// The virtual terminal instance containing the buffer to render.
  final VirtualTerminal virtualTerminal;

  /// Creates a [VirtualTerminalWidget].
  const VirtualTerminalWidget({super.key, required this.virtualTerminal});

  @override
  Element createElement() => _VirtualTerminalElement(this);
}

final class _VirtualTerminalElement extends Element {
  _VirtualTerminalElement(VirtualTerminalWidget super.widget);

  void _handleTerminalUpdate() {
    markNeedsBuild();
  }

  @override
  void mount(Element? parent) {
    super.mount(parent);
    (widget as VirtualTerminalWidget).virtualTerminal.addListener(
      _handleTerminalUpdate,
    );
  }

  @override
  void update(Widget newWidget) {
    final oldTerminal = (widget as VirtualTerminalWidget).virtualTerminal;
    final newTerminal = (newWidget as VirtualTerminalWidget).virtualTerminal;
    if (oldTerminal != newTerminal) {
      oldTerminal.removeListener(_handleTerminalUpdate);
      newTerminal.addListener(_handleTerminalUpdate);
    }
    super.update(newWidget);
  }

  @override
  void unmount() {
    (widget as VirtualTerminalWidget).virtualTerminal.removeListener(
      _handleTerminalUpdate,
    );
    super.unmount();
  }

  @override
  Size performLayout(BoxConstraints constraints) {
    final terminalWidget = widget as VirtualTerminalWidget;
    final w = terminalWidget.virtualTerminal.width;
    final h = terminalWidget.virtualTerminal.height;
    return constraints.constrain(Size(w, h));
  }

  @override
  void performPaint(Buffer buffer, Offset offset) {
    final terminalWidget = widget as VirtualTerminalWidget;
    final vt = terminalWidget.virtualTerminal;
    final termW = vt.width;
    final termH = vt.height;
    final termBuffer = vt.buffer;

    final srcChars = termBuffer.characters;
    final srcAttrs = termBuffer.attributes;
    final destChars = buffer.characters;
    final destAttrs = buffer.attributes;

    final destW = buffer.width;
    final destH = buffer.height;
    final startX = offset.dx;
    final startY = offset.dy;

    final clipX = startX.clamp(0, destW);
    final clipY = startY.clamp(0, destH);
    final srcOffsetX = clipX - startX;
    final srcOffsetY = clipY - startY;
    final overlapW = min(termW - srcOffsetX, destW - clipX);
    final overlapH = min(termH - srcOffsetY, destH - clipY);

    if (overlapW <= 0 || overlapH <= 0) return;

    for (var y = 0; y < overlapH; y++) {
      final sy = srcOffsetY + y;
      final ty = clipY + y;
      final srcCharRowStart = sy * termW + srcOffsetX;
      final destCharRowStart = ty * destW + clipX;

      destChars.setRange(
        destCharRowStart,
        destCharRowStart + overlapW,
        srcChars,
        srcCharRowStart,
      );

      final srcAttrRowStart = srcCharRowStart * 3;
      final destAttrRowStart = destCharRowStart * 3;
      destAttrs.setRange(
        destAttrRowStart,
        destAttrRowStart + overlapW * 3,
        srcAttrs,
        srcAttrRowStart,
      );
    }
  }
}
