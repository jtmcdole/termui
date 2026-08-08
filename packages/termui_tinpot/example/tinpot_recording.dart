// ignore_for_file: avoid_print
import 'package:file/local.dart';
import 'package:image/image.dart' as img;
import 'package:termui/ui/buffer.dart';
import 'package:termui_recorder/termui_recorder.dart';
import 'package:termui_tinpot/termui_tinpot.dart';
import 'package:clock/clock.dart';

void main() async {
  final imageBytes = await LocalFileSystem()
      .file('test/assets/omega_Gate.png')
      .readAsBytes();
  final image = img.decodeImage(imageBytes);
  if (image == null) {
    print('Failed to decode image');
    return;
  }

  // Use workFactor 9 as requested for precomputed animations
  final engine = TermuiTinpot(workFactor: 9);

  // Use .cast.gz since FileAsciicastWriter always gzips the output
  final file = LocalFileSystem().file('omega_growth.cast.gz');
  final writer = FileAsciicastWriter(file);
  final recorder = AsciicastRecorder(writer, width: 90, height: 45);

  print('Recording to omega_growth.cast.gz...');

  final double imageAspect = image.width / image.height;

  DateTime virtualTime = DateTime(2025, 1, 1, 12, 0, 0);

  for (int columns = 2; columns <= 90; columns++) {
    int rows = (columns / (imageAspect * 2.0)).round();
    if (rows < 1) rows = 1;

    final buffer = Buffer(90, 45);

    // Clear buffer with spaces
    for (int y = 0; y < 45; y++) {
      for (int x = 0; x < 90; x++) {
        buffer.setCharacter(x, y, ' ');
        buffer.setModifiers(x, y, 0); // Not transparent
      }
    }

    final grid = engine.convertBuffer(image, columns, rows, useDin99d: true);

    int startX = (90 - columns) ~/ 2;
    int startY = (45 - rows) ~/ 2;

    for (int y = 0; y < grid.height; y++) {
      for (int x = 0; x < grid.width; x++) {
        int bx = startX + x;
        int by = startY + y;
        if (bx >= 0 && bx < 90 && by >= 0 && by < 45) {
          buffer.setCharacter(bx, by, grid.getCharacter(x, y));
          buffer.setForeground(bx, by, grid.getForeground(x, y));
          buffer.setBackground(bx, by, grid.getBackground(x, y));
          buffer.setModifiers(bx, by, 0);
        }
      }
    }

    // Advance virtual time by 500ms before recording the frame
    virtualTime = virtualTime.add(const Duration(milliseconds: 33));

    withClock(Clock.fixed(virtualTime), () {
      recorder.recordFrame(buffer);
    });

    print('Recorded frame columns: $columns');
  }

  print('\nFinished recording.');
  recorder.close();
}
