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
        bitmap: 0x00000000FFFFFFFF,
        popcount: 32,
      ), // Lower half block
      SymbolCandidate(
        codePoint: 0x2588,
        bitmap: 0xFFFFFFFFFFFFFFFF,
        popcount: 64,
      ), // Full block
      SymbolCandidate(
        codePoint: 0x0020,
        bitmap: 0x0000000000000000,
        popcount: 0,
      ), // Space
    ];

    final quantizer = CellQuantizer();
    final result = quantizer.quantize(pixels, candidates);

    expect(result.character, '▄');
  });
}
