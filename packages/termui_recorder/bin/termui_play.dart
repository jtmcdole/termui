import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:args/args.dart';
import 'package:file/file.dart';
import 'package:file/local.dart';
import 'package:termui_recorder/termui_recorder.dart';

const int _maxDecompressedCastBytes = 256 * 1024 * 1024;

/// The entrypoint for the termui_play command-line tool.
Future<void> main(List<String> args) async {
  exitCode = await runTermuiPlayCli(args);
}

/// Runs the `termui_play` CLI and returns its process exit code.
Future<int> runTermuiPlayCli(
  List<String> args, {
  StringSink? out,
  StringSink? err,
  FileSystem fs = const LocalFileSystem(),
}) async {
  final outSink = out ?? stdout;
  final errSink = err ?? stderr;
  final parser = _buildArgParser();
  final ArgResults results;
  try {
    results = parser.parse(args);
  } catch (e) {
    errSink.writeln('Error parsing arguments: $e');
    _printUsage(parser, sink: errSink);
    return 64;
  }

  if (results['help'] as bool) {
    _printUsage(parser, sink: outSink);
    return 0;
  }

  if (results.rest case [final filePath, ...]) {
    return _runPlayback(filePath, results, err: errSink, fs: fs);
  }
  errSink.writeln('Error: Missing input .cast file path.');
  _printUsage(parser, sink: errSink);
  return 64;
}

ArgParser _buildArgParser() {
  return ArgParser()
    ..addOption(
      'speed',
      abbr: 's',
      help:
          'Playback speed multiplier (e.g. 2.0 for double speed, 0.5 for half speed)',
      defaultsTo: '1.0',
    )
    ..addFlag(
      'non-interactive',
      abbr: 'n',
      help: 'Disable interactive controls and status bar overlays',
      defaultsTo: false,
    )
    ..addFlag(
      'paused',
      abbr: 'p',
      help: 'Start playback in a paused state',
      defaultsTo: false,
    )
    ..addFlag(
      'keep-alive',
      abbr: 'k',
      help: 'Do not close the player when playback reaches the end',
      defaultsTo: false,
    )
    ..addFlag(
      'help',
      abbr: 'h',
      help: 'Show usage instructions',
      negatable: false,
    );
}

Future<int> _runPlayback(
  String filePath,
  ArgResults results, {
  required StringSink err,
  required FileSystem fs,
}) async {
  final speedStr = results['speed'] as String;
  final parsedSpeed = double.tryParse(speedStr);
  if (parsedSpeed == null || !parsedSpeed.isFinite || parsedSpeed <= 0) {
    err.writeln(
      'Error: Invalid --speed value "$speedStr". Must be a finite number > 0.',
    );
    return 64;
  }

  final file = fs.file(filePath);
  if (!file.existsSync()) {
    err.writeln('Error: File does not exist at $filePath');
    return 66;
  }

  final interactive = !(results['non-interactive'] as bool);
  final paused = results['paused'] as bool;
  final noCloseAtEnd = results['keep-alive'] as bool;

  final String data;
  try {
    final bytes = await file.readAsBytes();
    data = _decodeCastBytes(bytes);
  } catch (e) {
    err.writeln('Error reading cast file: $e');
    return 1;
  }

  final player = AsciicastPlayer(data);
  try {
    await player.play(
      speedMultiplier: parsedSpeed,
      interactive: interactive,
      paused: paused,
      noCloseAtEnd: noCloseAtEnd,
    );
    return 0;
  } catch (e) {
    err.writeln('Error during playback: $e');
    return 1;
  }
}

String _decodeCastBytes(Uint8List bytes) {
  final isGzip = bytes.length >= 2 && bytes[0] == 0x1f && bytes[1] == 0x8b;
  if (!isGzip) {
    return utf8.decode(bytes);
  }
  final outSink = _BoundedByteSink(_maxDecompressedCastBytes);
  final inSink = gzip.decoder.startChunkedConversion(outSink);
  const chunkSize = 64 * 1024;
  for (var offset = 0; offset < bytes.length; offset += chunkSize) {
    final end = offset + chunkSize < bytes.length
        ? offset + chunkSize
        : bytes.length;
    inSink.addSlice(bytes, offset, end, false);
  }
  inSink.close();
  return utf8.decode(outSink.builder.takeBytes());
}

final class _BoundedByteSink implements Sink<List<int>> {
  final int maxBytes;
  final BytesBuilder builder = BytesBuilder(copy: false);
  int _total = 0;

  _BoundedByteSink(this.maxBytes);

  @override
  void add(List<int> data) {
    _total += data.length;
    if (_total > maxBytes) {
      throw FormatException(
        'GZip decompressed size exceeds limit of $maxBytes bytes.',
      );
    }
    builder.add(data);
  }

  @override
  void close() {}
}

void _printUsage(ArgParser parser, {required StringSink sink}) {
  sink.writeln(
    'Usage: dart run termui_recorder:termui_play [options] <input.cast>\n',
  );
  sink.writeln('Options:');
  sink.writeln(parser.usage);
}
