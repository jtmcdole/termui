import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:termui_tinpot/src/cell_quantizer.dart';
import 'package:termui_tinpot/src/symbol_map.dart';

void main() {
  test('CellQuantizer picks lower block', () {
    final pixels = Uint32List(64);
    // Fill top half with black
    for (int i = 0; i < 32; i++) {
      pixels[i] = 0xFF000000;
    }
    // Fill bottom half with white
    for (int i = 32; i < 64; i++) {
      pixels[i] = 0xFFFFFFFF;
    }

    final candidates = [
      SymbolCandidate(
        codePoint: 0x2584,
        bitmapHigh: 0x00000000,
        bitmapLow: 0xFFFFFFFF,
        popcount: 32,
      ), // Lower half block
      SymbolCandidate(
        codePoint: 0x2588,
        bitmapHigh: 0xFFFFFFFF,
        bitmapLow: 0xFFFFFFFF,
        popcount: 64,
      ), // Full block
      SymbolCandidate(
        codePoint: 0x0020,
        bitmapHigh: 0x00000000,
        bitmapLow: 0x00000000,
        popcount: 0,
      ), // Space
    ];

    final quantizer = CellQuantizer();
    final result = quantizer.quantize(pixels, candidates);

    expect(result.character, '▄');
  });
}
