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
    if (columns <= 0 || rows <= 0) return Buffer.blank(0, 0);

    Tracer.record(_traceConvertId, Phase.begin, TraceCategory.paint);

    // 1. Scale the image to match the terminal aspect ratio and grid size.
    // Each terminal cell is 8x8 pixels.
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

    final quantizer = CellQuantizer(workFactor: workFactor);
    final pixelsRgb = Uint32List(64);

    final buffer = targetBuffer ?? Buffer.blank(columns, rows);

    final p = scaled.getPixel(0, 0);

    final int paintRows = math.min(rows, buffer.height);
    final int paintCols = math.min(columns, buffer.width);
    for (int cellY = 0; cellY < paintRows; cellY++) {
      Tracer.record(_traceRowId, Phase.begin, TraceCategory.paint);
      for (int cellX = 0; cellX < paintCols; cellX++) {
        int pIdx = 0;

        for (int py = 0; py < 8; py++) {
          for (int px = 0; px < 8; px++) {
            final pixel = scaled.getPixel(cellX * 8 + px, cellY * 8 + py, p);

            var a = pixel.a.toInt();
            var r = pixel.r.toInt();
            var g = pixel.g.toInt();
            var b = pixel.b.toInt();

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
        final cell = quantizer.quantize(
          pixelsRgb,
          candidates,
          useMedian: useMedian,
          useDin99d: useDin99d,
        );

        buffer.setCell(
          cellX,
          cellY,
          cell.character,
          cell.fgColorArgb,
          cell.bgColorArgb,
          Modifier.transparent,
        );
      }
      Tracer.record(_traceRowId, Phase.end, TraceCategory.paint);
    }

    Tracer.record(_traceConvertId, Phase.end, TraceCategory.paint);

    return buffer;
  }

  /// Converts an image into a grid of [TinpotOutputCell].
  List<List<TinpotOutputCell>> convert(
    img.Image image,
    int columns,
    int rows, {
    bool useMedian = false,
    bool useDin99d = false,
  }) {
    final buffer = convertBuffer(
      image,
      columns,
      rows,
      useMedian: useMedian,
      useDin99d: useDin99d,
    );

    final grid = <List<TinpotOutputCell>>[];
    for (int y = 0; y < buffer.height; y++) {
      final row = <TinpotOutputCell>[];
      for (int x = 0; x < buffer.width; x++) {
        row.add((
          character: buffer.getCharacter(x, y),
          fgColorArgb: buffer.getForeground(x, y),
          bgColorArgb: buffer.getBackground(x, y),
        ));
      }
      grid.add(row);
    }

    return grid;
  }
}
