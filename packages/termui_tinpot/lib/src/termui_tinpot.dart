import 'package:image/image.dart' as img;
import 'symbol_map.dart';
import 'cell_quantizer.dart';
import 'dart:typed_data';

typedef TinpotOutputCell = ({
  String character,
  int fgColorArgb,
  int bgColorArgb,
});

class TermuiTinpot {
  final SymbolMap symbolMap;

  TermuiTinpot({SymbolMap? symbolMap}) : symbolMap = symbolMap ?? SymbolMap();

  /// Converts an image into a grid of terminal characters.
  /// [columns] and [rows] define the size of the output grid.
  /// Each character cell corresponds to an 8x8 pixel block internally.
  List<List<TinpotOutputCell>> convert(
    img.Image image,
    int columns,
    int rows, {
    bool useMedian = false,
    bool useDin99d = false,
  }) {
    if (columns <= 0 || rows <= 0) return [];

    // 1. Scale the image to match the terminal aspect ratio and grid size.
    // Each terminal cell is 8x8 pixels.
    final targetWidth = columns * 8;
    final targetHeight = rows * 8;

    final scaled = img.copyResize(
      image,
      width: targetWidth,
      height: targetHeight,
      interpolation: img.Interpolation.linear,
    );

    // Restrict candidates to canonical blocks used by WASM to avoid thin rendering of upper/right blocks
    final canonicalBlocks = {
      0x0020, // Space
      0x2581, 0x2582, 0x2583, 0x2584, 0x2585, 0x2586, 0x2587, // Lower blocks
      0x2589, 0x258a, 0x258b, 0x258c, 0x258d, 0x258e, 0x258f, // Left blocks
      0x2596, 0x2597, 0x2598, 0x259d, // Quadrants
      0x259A, // Quadrant upper left and lower right (▚)
      0x259E, // Quadrant upper right and lower left (▞)
    };

    final candidates = symbolMap.blockSymbols
        .where(
          (s) =>
              canonicalBlocks.contains(s.codePoint) ||
              (s.codePoint >= 0x2500 &&
                  s.codePoint <= 0x257F &&
                  !(s.codePoint >= 0x2504 &&
                      s.codePoint <=
                          0x250B) && // Exclude triple/quadruple dashes
                  !(s.codePoint >= 0x254C &&
                      s.codePoint <= 0x254F) && // Exclude double dashes
                  !(s.codePoint >= 0x2574 && s.codePoint <= 0x257B)),
        ) // Exclude single/half dashes (TAG_DOT)
        .toList();

    final quantizer = CellQuantizer();
    final pixelsRgb = Uint32List(64);
    
    final grid = <List<TinpotOutputCell>>[];

    for (int cellY = 0; cellY < rows; cellY++) {
      final row = <TinpotOutputCell>[];
      for (int cellX = 0; cellX < columns; cellX++) {
        int pIdx = 0;

        for (int py = 0; py < 8; py++) {
          for (int px = 0; px < 8; px++) {
            final pixel = scaled.getPixel(cellX * 8 + px, cellY * 8 + py);

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

        // Quantize cell extracting average colors and exhaustively finding the best shape
        row.add(quantizer.quantize(
          pixelsRgb,
          candidates,
          useMedian: useMedian,
          useDin99d: useDin99d,
        ));
      }
      grid.add(row);
    }

    return grid;
  }
}
