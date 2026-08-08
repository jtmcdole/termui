import 'dart:typed_data';
import 'package:image/image.dart' as img;
import 'package:termui_tinpot/src/termui_tinpot.dart';
import 'package:termui_tinpot/src/cell_quantizer.dart';
import 'package:termui_tinpot/src/symbol_map.dart';
import 'package:test/test.dart';

void main() {
  group('TermuiTinpot Core Methods', () {
    late TermuiTinpot tinpot;

    setUp(() {
      tinpot = TermuiTinpot(workFactor: 1);
    });

    test('convertBuffer works correctly', () {
      final image = img.Image(width: 8, height: 8);
      // Fill image with some color to verify conversion
      for (int i = 0; i < 64; i++) {
        image.setPixelRgb(i % 8, i ~/ 8, 255, 0, 0);
      }

      final buffer = tinpot.convertBuffer(image, 1, 1);
      expect(buffer.width, 1);
      expect(buffer.height, 1);
      // Should pick a block character, e.g., full block
      expect(buffer.getCharacter(0, 0), isNotEmpty);
    });

    test('convert with din99 and median', () {
      final image = img.Image(width: 16, height: 16);
      for (int i = 0; i < 256; i++) {
        image.setPixelRgb(i % 16, i ~/ 16, 0, 0, 255);
      }

      final buffer = tinpot.convertBuffer(
        image,
        2,
        2,
        useDin99d: true,
        useMedian: true,
      );
      expect(buffer.width, 2);
      expect(buffer.height, 2);
    });
  });

  group('CellQuantizer edge cases', () {
    test('quantize with useMedian=true branches', () {
      final quantizer = CellQuantizer(workFactor: 1);
      final pixelsRgb = Uint32List(64);
      // Create a gradient to test median finding across dominant channels
      for (int i = 0; i < 64; i++) {
        pixelsRgb[i] = (0xFF << 24) | (i << 16) | (i << 8) | i; // Grayscale
      }
      final candidates = SymbolMap().blockSymbols;

      // Force different median dominants by messing with RGB
      for (int c = 0; c < 3; c++) {
        for (int i = 0; i < 64; i++) {
          int r = c == 0 ? i * 4 : i;
          int g = c == 1 ? i * 4 : i;
          int b = c == 2 ? i * 4 : i;
          pixelsRgb[i] = (0xFF << 24) | (r << 16) | (g << 8) | b;
        }
        final result = QuantizeResult();
        quantizer.quantize(pixelsRgb, candidates, result, useMedian: true);
        expect(result.character, isNotEmpty);
      }
    });

    test('quantize early exit on flat image', () {
      final quantizer = CellQuantizer(workFactor: 1);
      final pixelsRgb = Uint32List(64);
      for (int i = 0; i < 64; i++) {
        pixelsRgb[i] = (0xFF << 24) | (255 << 16) | (255 << 8) | 255;
      }
      final candidates = SymbolMap().blockSymbols;
      final result = QuantizeResult();
      quantizer.quantize(pixelsRgb, candidates, result, useMedian: true);
      expect(result.character == '█' || result.character == ' ', isTrue);
    });
  });
}
