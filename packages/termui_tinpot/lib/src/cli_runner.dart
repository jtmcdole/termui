import 'dart:io';
import 'package:args/args.dart';
import 'package:image/image.dart' as img;
import 'package:termui_tinpot/termui_tinpot.dart';
import 'cli_utils.dart';

Future<int> runTinpotCli(List<String> arguments, {StringSink? out, StringSink? err}) async {
  out ??= stdout;
  err ??= stderr;

  final parser = ArgParser()
    ..addOption('width', abbr: 'w', help: 'Output width in characters', defaultsTo: '80')
    ..addOption('height', abbr: 'h', help: 'Output height in characters', defaultsTo: '40')
    ..addOption('background', abbr: 'b', help: 'Background color for transparent pixels (e.g. FF000000 or 000000)')
    ..addFlag('din99d', help: 'Use DIN99d perceptual color math instead of RGB', defaultsTo: false)
    ..addFlag('median', help: 'Use median color extraction instead of average', defaultsTo: false)
    ..addOption('work', help: 'Work factor for shape evaluation (1-9, defaults to 5)', defaultsTo: '5')
    ..addFlag('help', abbr: '?', negatable: false, help: 'Print this usage information.');

  ArgResults argResults;
  int? backgroundColor;
  try {
    argResults = parser.parse(arguments);
    backgroundColor = parseBackgroundColor(argResults['background'] as String?);
  } on FormatException catch (e) {
    err.writeln('Error: ${e.message}');
    out.writeln(parser.usage);
    return 1;
  } catch (e) {
    err.writeln(e);
    out.writeln(parser.usage);
    return 1;
  }

  if (argResults['help'] as bool || argResults.rest.isEmpty) {
    out.writeln('Usage: tinpot [options] <image_path>');
    out.writeln(parser.usage);
    return argResults['help'] as bool ? 0 : 1;
  }

  final imagePath = argResults.rest.first;
  final file = File(imagePath);
  if (!file.existsSync()) {
    err.writeln('Error: File not found: $imagePath');
    return 1;
  }

  final imageBytes = await file.readAsBytes();
  final image = img.decodeImage(imageBytes);
  if (image == null) {
    err.writeln('Error: Could not decode image.');
    return 1;
  }

  final int maxColumns = int.parse(argResults['width'] as String);
  final int maxRows = int.parse(argResults['height'] as String);
  int workFactor = int.tryParse(argResults['work'] as String) ?? 5;
  if (workFactor < 1) workFactor = 1;
  if (workFactor > 9) workFactor = 9;

  final double imageAspect = image.width / image.height;

  int columns = maxColumns;
  int rows = (columns / (imageAspect * 2.0)).round();

  if (rows > maxRows) {
    rows = maxRows;
    columns = (rows * imageAspect * 2.0).round();
  }

  if (columns < 1) columns = 1;
  if (rows < 1) rows = 1;

  final engine = TermuiTinpot(workFactor: workFactor);
  final bufferGrid = engine.convertBuffer(
    image,
    columns,
    rows,
    useDin99d: argResults['din99d'] as bool,
    useMedian: argResults['median'] as bool,
    backgroundColorArgb: backgroundColor,
  );

  final buffer = StringBuffer();
  for (int y = 0; y < bufferGrid.height; y++) {
    for (int x = 0; x < bufferGrid.width; x++) {
      final fgColorArgb = bufferGrid.getForeground(x, y);
      final bgColorArgb = bufferGrid.getBackground(x, y);
      final character = bufferGrid.getCharacter(x, y);

      final fgR = (fgColorArgb >> 16) & 0xFF;
      final fgG = (fgColorArgb >> 8) & 0xFF;
      final fgB = fgColorArgb & 0xFF;

      final bgR = (bgColorArgb >> 16) & 0xFF;
      final bgG = (bgColorArgb >> 8) & 0xFF;
      final bgB = bgColorArgb & 0xFF;

      buffer.write('\x1B[38;2;$fgR;$fgG;${fgB}m');
      buffer.write('\x1B[48;2;$bgR;$bgG;${bgB}m');
      buffer.write(character);
    }
    buffer.write('\x1B[0m\n');
  }

  out.write(buffer.toString());
  return 0;
}
