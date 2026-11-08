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

    if (buffer is Viewport) {
      _paintIntoViewport(src, buffer, ox, oy);
      return;
    }

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
    final count = maxX - minX;

    for (var y = minY; y < maxY; y++) {
      final srcStart = y * srcWidth + minX;
      final dstStart = (oy + y) * dstWidth + ox + minX;

      dstChars.setRange(dstStart, dstStart + count, srcChars, srcStart);
      dstAttrs.setRange(
        dstStart * 3,
        (dstStart + count) * 3,
        srcAttrs,
        srcStart * 3,
      );
      buffer.copyCellAuxRangeFrom(src, dstStart, srcStart, count);
    }
    buffer.propagateMetadataFrom(src, dx: ox, dy: oy, clip: clip);
  }

  void _paintIntoViewport(Buffer src, Viewport vp, int ox, int oy) {
    final minX = max(0, -ox);
    final maxX = min(src.width, vp.width - ox);
    final minY = max(0, -oy);
    final maxY = min(src.height, vp.height - oy);
    if (minX >= maxX || minY >= maxY) return;

    for (var y = minY; y < maxY; y++) {
      for (var x = minX; x < maxX; x++) {
        vp.setCell(
          ox + x,
          oy + y,
          src.getCharacter(x, y),
          src.getForeground(x, y),
          src.getBackground(x, y),
          src.getModifiers(x, y),
          blend: false,
          underlineColor: src.getUnderlineColor(x, y),
          uri: src.getUri(x, y),
        );
      }
    }
    vp.propagateMetadataFrom(src, dx: ox, dy: oy);
  }
}
