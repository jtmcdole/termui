import 'dart:io';
import 'dart:math';
import 'package:image/image.dart' as img;

class AsciiReconstructor {
  final Map<String, int> charToBitmap = {};

  AsciiReconstructor() {
    final mapContent = File('lib/src/symbol_map.dart').readAsStringSync();
    final regex = RegExp(
      r"SymbolCandidate\(\s*character:\s*'(.*?)',\s*bitmapHigh:\s*(0x[0-9a-fA-F]+),\s*bitmapLow:\s*(0x[0-9a-fA-F]+)",
    );
    for (final match in regex.allMatches(mapContent)) {
      String char = switch (match.group(1)!) {
        r"\'" => "'",
        r"\\" => r"\",
        final c => c,
      };

      int high = int.parse(match.group(2)!.substring(2), radix: 16);
      int low = int.parse(match.group(3)!.substring(2), radix: 16);
      final bitmap = (high << 32) | low;
      charToBitmap[char] = bitmap;
    }
    charToBitmap[' '] = 0; // Space
  }

  img.Image reconstruct(String asciiStr, int cols, int rows) {
    final image = img.Image(width: cols * 8, height: rows * 8, numChannels: 4);
    img.fill(image, color: img.ColorRgba8(0, 0, 0, 255));

    int fgR = 255, fgG = 255, fgB = 255;
    int bgR = 0, bgG = 0, bgB = 0;

    int cellX = 0;
    int cellY = 0;

    int i = 0;
    while (i < asciiStr.length && cellY < rows) {
      if (asciiStr[i] == '\n' || asciiStr[i] == '\r') {
        if (asciiStr[i] == '\n') {
          cellX = 0;
          cellY++;
        }
        i++;
        continue;
      }

      if (asciiStr[i] == '\x1B') {
        if (i + 1 < asciiStr.length && asciiStr[i + 1] == '[') {
          int end = asciiStr.indexOf('m', i);
          if (end != -1) {
            final seq = asciiStr.substring(i + 2, end);
            final parts = seq.split(';');
            int p = 0;
            while (p < parts.length) {
              if (parts[p] == '0') {
                fgR = 255;
                fgG = 255;
                fgB = 255;
                bgR = 0;
                bgG = 0;
                bgB = 0;
                p++;
              } else if (parts[p] == '39') {
                fgR = 255;
                fgG = 255;
                fgB = 255;
                p++;
              } else if (parts[p] == '49') {
                bgR = 0;
                bgG = 0;
                bgB = 0;
                p++;
              } else if (parts[p] == '38' &&
                  p + 2 < parts.length &&
                  parts[p + 1] == '2') {
                fgR = int.parse(parts[p + 2]);
                fgG = int.parse(parts[p + 3]);
                fgB = int.parse(parts[p + 4]);
                p += 5;
              } else if (parts[p] == '48' &&
                  p + 2 < parts.length &&
                  parts[p + 1] == '2') {
                bgR = int.parse(parts[p + 2]);
                bgG = int.parse(parts[p + 3]);
                bgB = int.parse(parts[p + 4]);
                p += 5;
              } else {
                p++;
              }
            }
            i = end + 1;
            continue;
          }
        }
      }

      bool found = false;
      String charStr = asciiStr[i];
      for (int len = 2; len >= 1; len--) {
        if (i + len <= asciiStr.length) {
          String sub = asciiStr.substring(i, i + len);
          if (charToBitmap.containsKey(sub)) {
            charStr = sub;
            found = true;
            i += len;
            break;
          }
        }
      }

      int bitmap = 0;
      if (!found) {
        charStr = asciiStr[i];
        int cp = charStr.codeUnitAt(0);
        bitmap = (cp == 0x20) ? 0 : (charToBitmap[charStr] ?? 0);
        i++;
      } else {
        bitmap = charToBitmap[charStr] ?? 0;
      }

      if (cellX < cols && cellY < rows) {
        int maskHigh = (bitmap / 0x100000000).floor();
        int maskLow = bitmap & 0xFFFFFFFF;

        for (int py = 0; py < 8; py++) {
          for (int px = 0; px < 8; px++) {
            int bitIdx = py * 8 + px;
            int bit;
            if (bitIdx < 32) {
              bit = (maskHigh >> (31 - bitIdx)) & 1;
            } else {
              bit = (maskLow >> (31 - (bitIdx - 32))) & 1;
            }

            if (bit == 1) {
              image.setPixelRgba(
                cellX * 8 + px,
                cellY * 8 + py,
                fgR,
                fgG,
                fgB,
                255,
              );
            } else {
              image.setPixelRgba(
                cellX * 8 + px,
                cellY * 8 + py,
                bgR,
                bgG,
                bgB,
                255,
              );
            }
          }
        }
        cellX++;
      }
    }
    return image;
  }
}

void main(List<String> args) {
  if (args.length < 2) {
    print('Usage: dart bin/diff_eval.dart <image.png> <output.ascii>');
    exit(1);
  }

  final origBytes = File(args[0]).readAsBytesSync();
  final origImage = img.decodeImage(origBytes)!;

  final asciiStr = File(args[1]).readAsStringSync();

  // Find grid size
  int cols = 0;
  int rows = 0;
  final lines = asciiStr.split('\n');
  for (var line in lines) {
    if (line.trim().isEmpty) continue;
    rows++;
    // Strip ansi to find cols
    final plain = line.replaceAll(RegExp(r'\x1B\[[0-9;]*m'), '');
    if (plain.runes.length > cols) cols = plain.runes.length;
  }

  print('Detected ASCII grid: ${cols}x$rows');

  final recon = AsciiReconstructor();
  final asciiImg = recon.reconstruct(asciiStr, cols, rows);

  // Scale original to match
  final scaledOrig = img.copyResize(
    origImage,
    width: cols * 8,
    height: rows * 8,
    interpolation: img.Interpolation.linear,
  );

  double mse = 0;
  int totalPixels = cols * 8 * rows * 8;

  for (int y = 0; y < rows * 8; y++) {
    for (int x = 0; x < cols * 8; x++) {
      final p1 = scaledOrig.getPixel(x, y);
      final p2 = asciiImg.getPixel(x, y);

      // Alpha composite p1 over black for fair comparison
      int a = p1.a.toInt();
      int r1 = (p1.r.toInt() * a) ~/ 255;
      int g1 = (p1.g.toInt() * a) ~/ 255;
      int b1 = (p1.b.toInt() * a) ~/ 255;

      int r2 = p2.r.toInt();
      int g2 = p2.g.toInt();
      int b2 = p2.b.toInt();

      mse += pow(r1 - r2, 2) + pow(g1 - g2, 2) + pow(b1 - b2, 2);
    }
  }

  mse /= (totalPixels * 3);
  print('MSE: $mse');

  // Save reconstructed images for visual inspection (stretch vertically to simulate 1:2 terminal aspect ratio)
  final visualImg = img.copyResize(
    asciiImg,
    width: cols * 8,
    height: rows * 16,
    interpolation: img.Interpolation.nearest,
  );
  File('${args[1]}.recon.png').writeAsBytesSync(img.encodePng(visualImg));
}
