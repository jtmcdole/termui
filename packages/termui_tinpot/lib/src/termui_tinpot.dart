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
  List<List<TinpotOutputCell>> convert(img.Image image, int columns, int rows) {
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

    // Only use block symbols to match WASM output (no braille noise)
    final candidates = symbolMap.blockSymbols;

    return [
      for (int cellY = 0; cellY < rows; cellY++)
        [
          for (int cellX = 0; cellX < columns; cellX++)
            () {
              final pixelsRgb = Uint32List(64);
              int pIdx = 0;

              for (int py = 0; py < 8; py++) {
                for (int px = 0; px < 8; px++) {
                  final pixel = scaled.getPixel(cellX * 8 + px, cellY * 8 + py);

                  var (a, r, g, b) = (
                    (pixel.aNormalized * 255).toInt(),
                    (pixel.rNormalized * 255).toInt(),
                    (pixel.gNormalized * 255).toInt(),
                    (pixel.bNormalized * 255).toInt(),
                  );

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
              return CellQuantizer.quantize(pixelsRgb, candidates);
            }(),
        ],
    ];
  }
}
