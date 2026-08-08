import 'dart:math' as math;
import 'dart:typed_data';
import 'package:image/image.dart' as img;
import 'package:termui/termui.dart';
import 'cell_quantizer.dart';
import 'symbol_map.dart';

typedef TinpotOutputCell = ({
  String character,
  int fgColorArgb,
  int bgColorArgb,
});

class TermuiTinpot {
  final SymbolMap symbolMap;
  final int workFactor;

  static final int _traceConvertId = Tracer.registerString('Tinpot:convert');
  static final int _traceResizeId = Tracer.registerString('Tinpot:copyResize');
  static final int _traceRowId = Tracer.registerString('Tinpot:quantizeRow');

  TermuiTinpot({SymbolMap? symbolMap, this.workFactor = 5})
    : symbolMap = symbolMap ?? SymbolMap();

  late final List<SymbolCandidate> candidates = symbolMap.blockSymbols
      .where(
        (s) =>
            s.codePoint == 0x0020 ||
            (s.codePoint >= 0x2580 && s.codePoint <= 0x259F) ||
            (s.codePoint >= 0x2500 &&
                s.codePoint <= 0x257F &&
                !(s.codePoint >= 0x2504 &&
                    s.codePoint <= 0x250B) && // Exclude triple/quadruple dashes
                !(s.codePoint >= 0x254C &&
                    s.codePoint <= 0x254F) && // Exclude double dashes
                !(s.codePoint >= 0x2574 && s.codePoint <= 0x257B)),
      ) // Exclude single/half dashes (TAG_DOT)
      .toList();

  /// Scales the image to match the terminal aspect ratio and grid size.
  /// Each terminal cell is 8x8 pixels.
  img.Image scaleImage(img.Image image, int columns, int rows) {
    if (columns <= 0 || rows <= 0) return img.Image(width: 0, height: 0);

    final targetWidth = columns * 8;
    final targetHeight = rows * 8;

    Tracer.record(_traceResizeId, Phase.begin, TraceCategory.paint);
    final scaled = img.copyResize(
      image,
      width: targetWidth,
      height: targetHeight,
      interpolation: img.Interpolation.linear,
    );
    Tracer.record(_traceResizeId, Phase.end, TraceCategory.paint);

    return scaled;
  }

  /// Quantizes an already-scaled image (sized exactly to columns*8 x rows*8) into a Buffer.
  Buffer quantizeScaledImage(
    img.Image scaled,
    int columns,
    int rows, {
    Buffer? targetBuffer,
    bool useMedian = false,
    bool useDin99d = false,
  }) {
    if (columns <= 0 || rows <= 0 || scaled.width == 0 || scaled.height == 0) {
      return Buffer.blank(0, 0);
    }

    Tracer.record(_traceConvertId, Phase.begin, TraceCategory.paint);

    final quantizer = CellQuantizer(workFactor: workFactor);
    final pixelsRgb = Uint32List(64);
    final quantizeResult = QuantizeResult();

    final buffer = targetBuffer ?? Buffer.blank(columns, rows);

    final int paintRows = math.min(rows, buffer.height);
    final int paintCols = math.min(columns, buffer.width);

    final int imgWidth = scaled.width;
    final Uint8List bytes = scaled.getBytes(order: img.ChannelOrder.rgba);

    for (int cellY = 0; cellY < paintRows; cellY++) {
      Tracer.record(_traceRowId, Phase.begin, TraceCategory.paint);
      for (int cellX = 0; cellX < paintCols; cellX++) {
        int pIdx = 0;

        for (int py = 0; py < 8; py++) {
          final int rowOffset = ((cellY * 8 + py) * imgWidth) * 4;
          final int cellXOffset = (cellX * 8) * 4;
          int rawIdx = rowOffset + cellXOffset;

          for (int px = 0; px < 8; px++) {
            var r = bytes[rawIdx];
            var g = bytes[rawIdx + 1];
            var b = bytes[rawIdx + 2];
            var a = bytes[rawIdx + 3];
            rawIdx += 4;

            // Alpha composite over black background (0, 0, 0)
            if (a < 255) {
              // Fast division by 255 using (val * 257) >> 16
              r = (r * a * 257) >> 16;
              g = (g * a * 257) >> 16;
              b = (b * a * 257) >> 16;
            }

            pixelsRgb[pIdx++] = (0xFF << 24) | (r << 16) | (g << 8) | b;
          }
        }

        // Quantize cell extracting average colors and finding the best block character
        quantizer.quantize(
          pixelsRgb,
          candidates,
          quantizeResult,
          useMedian: useMedian,
          useDin99d: useDin99d,
        );

        buffer.setCell(
          cellX,
          cellY,
          quantizeResult.character,
          quantizeResult.fgColorArgb,
          quantizeResult.bgColorArgb,
          Modifier.transparent,
        );
      }
      Tracer.record(_traceRowId, Phase.end, TraceCategory.paint);
    }

    Tracer.record(_traceConvertId, Phase.end, TraceCategory.paint);

    return buffer;
  }

  /// Converts an image directly into a native [Buffer] of [columns] by [rows].
  /// If [targetBuffer] is provided, cell values are written into [targetBuffer].
  Buffer convertBuffer(
    img.Image image,
    int columns,
    int rows, {
    Buffer? targetBuffer,
    bool useMedian = false,
    bool useDin99d = false,
  }) {
    final scaled = scaleImage(image, columns, rows);
    return quantizeScaledImage(
      scaled,
      columns,
      rows,
      targetBuffer: targetBuffer,
      useMedian: useMedian,
      useDin99d: useDin99d,
    );
  }
}
