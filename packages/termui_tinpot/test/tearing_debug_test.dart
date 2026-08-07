import 'dart:io';
import 'package:image/image.dart' as img;
import 'package:test/test.dart';
import 'package:termui_tinpot/termui_tinpot.dart';

void main() {
  group('Tearing Debug & Line 8/9 Inspection Tests', () {
    test(
      'omega_Gate.png y=8 (0-indexed line 9) middle cell is black space',
      () async {
        final file = File('test/assets/omega_Gate.png');
        expect(
          file.existsSync(),
          isTrue,
          reason: 'test/assets/omega_Gate.png must exist',
        );

        final bytes = await file.readAsBytes();
        final image = img.decodeImage(bytes);
        expect(image, isNotNull);

        final double imageAspect = image!.width / image.height;
        const int columns = 68;
        final int rows = (columns / (imageAspect * 2.0)).round();

        final engine = TermuiTinpot(workFactor: 9);
        final buffer = engine.convertBuffer(
          image,
          columns,
          rows,
          useDin99d: true,
        );

        print('\n--- Inspection Grid (x=30..38, y=6..10) ---');
        for (int y = 6; y <= 10; y++) {
          final lineSb = StringBuffer('y=${y.toString().padLeft(2)}: ');
          for (int x = 30; x <= 38; x++) {
            final c = buffer.getCharacter(x, y);
            lineSb.write(c == ' ' ? '·' : c);
          }
          print(lineSb.toString());
        }

        // Inspect y = 8 (0-indexed 8th row, 9th line), x = 34
        const int targetY = 8;
        const int targetX = 34;

        final char = buffer.getCharacter(targetX, targetY);
        final fg = buffer.getForeground(targetX, targetY);
        final bg = buffer.getBackground(targetX, targetY);

        final fgR = (fg >> 16) & 0xFF, fgG = (fg >> 8) & 0xFF, fgB = fg & 0xFF;
        final bgR = (bg >> 16) & 0xFF, bgG = (bg >> 8) & 0xFF, bgB = bg & 0xFF;

        print('\nTarget Cell Details (x=$targetX, y=$targetY):');
        print('  character: "$char" (codePoint: ${char.codeUnits})');
        print(
          '  fgColor: 0x${fg.toRadixString(16).padLeft(8, '0')} (RGB: $fgR, $fgG, $fgB)',
        );
        print(
          '  bgColor: 0x${bg.toRadixString(16).padLeft(8, '0')} (RGB: $bgR, $bgG, $bgB)',
        );

        // Assert that y=8 x=34 inside inner gate arch is space ' ' and dark background
        expect(
          char,
          equals(' '),
          reason:
              'Target cell at y=$targetY, x=$targetX inside arch must be space',
        );
        expect(
          bgR,
          lessThanOrEqualTo(15),
          reason: 'Target cell bg R should be dark/black',
        );
        expect(
          bgG,
          lessThanOrEqualTo(15),
          reason: 'Target cell bg G should be dark/black',
        );
        expect(
          bgB,
          lessThanOrEqualTo(15),
          reason: 'Target cell bg B should be dark/black',
        );
      },
    );
  });
}
