import 'dart:io';
import 'package:args/args.dart';
import 'package:image/image.dart' as img;
import 'package:termui/termui.dart';
import 'package:termui_tinpot/termui_tinpot.dart';

Future<int> runTinpotCli(
  List<String> arguments, {
  StringSink? out,
  StringSink? err,
}) async {
  final outSink = out ?? stdout;
  final errSink = err ?? stderr;
  final parser = _buildTinpotArgParser();

  final ArgResults argResults;
  final int? backgroundColor;
  try {
    argResults = parser.parse(arguments);
    backgroundColor = parseBackgroundColor(argResults['background'] as String?);
  } on FormatException catch (e) {
    errSink.writeln('Error: ${e.message}');
    outSink.writeln(parser.usage);
    return 1;
  } catch (e) {
    errSink.writeln(e);
    outSink.writeln(parser.usage);
    return 1;
  }

  final isHelp = argResults['help'] as bool;
  if (isHelp || argResults.rest.isEmpty) {
    outSink.writeln('Usage: tinpot [options] <image_path>');
    outSink.writeln(parser.usage);
    return isHelp ? 0 : 1;
  }

  final maxColumns = _parsePositiveDimension(
    argResults['width'] as String,
    optionName: 'width',
    err: errSink,
    parser: parser,
  );
  if (maxColumns == null) return 64;

  final maxRows = _parsePositiveDimension(
    argResults['height'] as String,
    optionName: 'height',
    err: errSink,
    parser: parser,
  );
  if (maxRows == null) return 64;

  final imagePath = argResults.rest.first;
  final file = File(imagePath);
  if (!file.existsSync()) {
    errSink.writeln('Error: File not found: $imagePath');
    return 1;
  }

  final imageBytes = await file.readAsBytes();
  final image = img.decodeImage(imageBytes);
  if (image == null) {
    errSink.writeln('Error: Could not decode image.');
    return 1;
  }

  final workFactor = (int.tryParse(argResults['work'] as String) ?? 5).clamp(
    1,
    9,
  );
  final (columns, rows) = _resolveTargetGridSize(
    image.width,
    image.height,
    maxColumns,
    maxRows,
  );

  final engine = TermuiTinpot(workFactor: workFactor);
  final bufferGrid = engine.convertBuffer(
    image,
    columns,
    rows,
    useDin99d: argResults['din99d'] as bool,
    useMedian: argResults['median'] as bool,
    backgroundColorArgb: backgroundColor,
  );

  outSink.write(_formatBufferAnsi(bufferGrid));
  return 0;
}

ArgParser _buildTinpotArgParser() {
  return ArgParser()
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
    ..addOption(
      'background',
      abbr: 'b',
      help: 'Background color for transparent pixels (e.g. FF000000 or 000000)',
    )
    ..addFlag(
      'din99d',
      help: 'Use DIN99d perceptual color math instead of RGB',
      defaultsTo: false,
    )
    ..addFlag(
      'median',
      help: 'Use median color extraction instead of average',
      defaultsTo: false,
    )
    ..addOption(
      'work',
      help: 'Work factor for shape evaluation (1-9, defaults to 5)',
      defaultsTo: '5',
    )
    ..addFlag(
      'help',
      abbr: '?',
      negatable: false,
      help: 'Print this usage information.',
    );
}

int? _parsePositiveDimension(
  String rawValue, {
  required String optionName,
  required StringSink err,
  required ArgParser parser,
}) {
  final parsed = int.tryParse(rawValue);
  if (parsed == null || parsed <= 0) {
    err.writeln(
      'Error: Invalid --$optionName "$rawValue". Must be a positive integer.',
    );
    err.writeln('Usage: tinpot [options] <image_path>');
    err.writeln(parser.usage);
    return null;
  }
  return parsed;
}

(int, int) _resolveTargetGridSize(
  int imageWidth,
  int imageHeight,
  int maxColumns,
  int maxRows,
) {
  final imageAspect = imageWidth / imageHeight;
  var columns = maxColumns;
  var rows = (columns / (imageAspect * 2.0)).round();

  if (rows > maxRows) {
    rows = maxRows;
    columns = (rows * imageAspect * 2.0).round();
  }

  return (columns < 1 ? 1 : columns, rows < 1 ? 1 : rows);
}

String _formatBufferAnsi(Buffer bufferGrid) {
  final buffer = StringBuffer();
  for (var y = 0; y < bufferGrid.height; y++) {
    for (var x = 0; x < bufferGrid.width; x++) {
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
  return buffer.toString();
}
