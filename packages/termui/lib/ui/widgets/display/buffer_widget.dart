import 'dart:math';
import 'package:termui/termui.dart';

/// A display widget that paints a [Buffer] directly onto the parent terminal canvas.
class BufferWidget extends Widget {
  /// The source buffer to render.
  final Buffer buffer;

  /// Creates a [BufferWidget] configured to paint [buffer].
  const BufferWidget({super.key, required this.buffer});

  @override
  Element createElement() => BufferWidgetElement(this);
}

/// The element managing layout and painting lifecycle for a [BufferWidget].
class BufferWidgetElement extends Element {
  /// Creates a [BufferWidgetElement] for the given [widget].
  BufferWidgetElement(BufferWidget super.widget);

  @override
  Size performLayout(BoxConstraints constraints) {
    final w = widget as BufferWidget;
    return constraints.constrain(Size(w.buffer.width, w.buffer.height));
  }

  @override
  void performPaint(Buffer buffer, Offset offset) {
    final w = widget as BufferWidget;
    final src = w.buffer;
    if (src.width <= 0 || src.height <= 0) return;

    final ox = offset.dx;
    final oy = offset.dy;

    final clip = buffer.activeClip;
    final minX = max(0, clip.left - ox);
    final maxX = min(src.width, clip.right - ox);
    final minY = max(0, clip.top - oy);
    final maxY = min(src.height, clip.bottom - oy);

    if (minX >= maxX || minY >= maxY) return;

    final srcChars = src.characters;
    final srcAttrs = src.attributes;
    final dstChars = buffer.characters;
    final dstAttrs = buffer.attributes;
    final srcWidth = src.width;
    final dstWidth = buffer.width;

    for (int y = minY; y < maxY; y++) {
      final srcRowOffset = y * srcWidth;
      final dstRowOffset = (oy + y) * dstWidth;

      final srcStart = srcRowOffset + minX;
      final srcEnd = srcRowOffset + maxX;
      final dstStart = dstRowOffset + ox + minX;
      final count = maxX - minX;

      dstChars.setRange(dstStart, dstStart + count, srcChars, srcStart);

      final srcAttrStart = srcStart * 3;
      final srcAttrEnd = srcEnd * 3;
      final dstAttrStart = dstStart * 3;
      final attrCount = (srcAttrEnd - srcAttrStart);

      dstAttrs.setRange(
        dstAttrStart,
        dstAttrStart + attrCount,
        srcAttrs,
        srcAttrStart,
      );
    }
  }
}
