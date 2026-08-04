import 'dart:io';
import 'package:args/args.dart';
import 'package:image/image.dart' as img;
import 'package:termui_tinpot/termui_tinpot.dart';

void main(List<String> arguments) async {
  final parser = ArgParser()
    ..addOption(
      'width',
      abbr: 'w',
      help: 'Output width in characters',
      defaultsTo: '80',
    )
    ..addOption(
      'height',
      abbr: 'h',
      help: 'Output height in characters',
      defaultsTo: '40',
    )
    ..addFlag(
      'help',
      abbr: '?',
      negatable: false,
      help: 'Print this usage information.',
    );

  ArgResults argResults;
  try {
    argResults = parser.parse(arguments);
  } catch (e) {
    print(e);
    print(parser.usage);
    exit(1);
  }

  if (argResults['help'] as bool || argResults.rest.isEmpty) {
    print('Usage: tinpot [options] <image_path>');
    print(parser.usage);
    exit(argResults['help'] as bool ? 0 : 1);
  }

  final imagePath = argResults.rest.first;
  final file = File(imagePath);
  if (!file.existsSync()) {
    print('Error: File not found: $imagePath');
    exit(1);
  }

  final imageBytes = await file.readAsBytes();
  final image = img.decodeImage(imageBytes);
  if (image == null) {
    print('Error: Could not decode image.');
    exit(1);
  }

  final int maxColumns = int.parse(argResults['width'] as String);
  final int maxRows = int.parse(argResults['height'] as String);

  final double imageAspect = image.width / image.height;

  // Calculate grid size preserving aspect ratio.
  // Terminal cells have a physical aspect ratio of approximately 1:2 (width:height).
  // So the physical aspect ratio of the output is columns / (rows * 2).
  // We want columns / (rows * 2) == imageAspect.
  int columns = maxColumns;
  int rows = (columns / (imageAspect * 2.0)).round();

  // If calculating by width exceeds the max height, scale by height instead.
  if (rows > maxRows) {
    rows = maxRows;
    columns = (rows * imageAspect * 2.0).round();
  }

  // Ensure minimum size
  if (columns < 1) columns = 1;
  if (rows < 1) rows = 1;

  final engine = TermuiTinpot();
  final grid = engine.convert(image, columns, rows);

  final buffer = StringBuffer();

  // We map the RGB colors to ANSI 24-bit escape codes.
  for (int y = 0; y < grid.length; y++) {
    for (int x = 0; x < grid[y].length; x++) {
      final cell = grid[y][x];

      final fgR = (cell.fgColorArgb >> 16) & 0xFF;
      final fgG = (cell.fgColorArgb >> 8) & 0xFF;
      final fgB = cell.fgColorArgb & 0xFF;

      final bgR = (cell.bgColorArgb >> 16) & 0xFF;
      final bgG = (cell.bgColorArgb >> 8) & 0xFF;
      final bgB = cell.bgColorArgb & 0xFF;

      // Escape code: ESC[38;2;R;G;Bm for FG, ESC[48;2;R;G;Bm for BG
      buffer.write('\x1B[38;2;$fgR;$fgG;${fgB}m');
      buffer.write('\x1B[48;2;$bgR;$bgG;${bgB}m');
      buffer.write(cell.character);
    }
    // Reset formatting at the end of the line
    buffer.write('\x1B[0m\n');
  }

  stdout.write(buffer.toString());
}
