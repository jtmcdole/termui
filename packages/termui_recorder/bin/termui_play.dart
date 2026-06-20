import 'dart:convert';
import 'dart:io';
import 'package:args/args.dart';
import 'package:archive/archive.dart';
import 'package:file/local.dart';
import 'package:termui_recorder/termui_recorder.dart';

/// The entrypoint for the termui_play command-line tool.
Future<void> main(List<String> args) async {
  final parser = ArgParser()
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

  final ArgResults results;
  try {
    results = parser.parse(args);
  } catch (e) {
    print('Error parsing arguments: $e');
    _printUsage(parser);
    return;
  }

  if (results['help'] as bool) {
    _printUsage(parser);
    return;
  }

  final rest = results.rest;
  if (rest.isEmpty) {
    print('Error: Missing input .cast file path.');
    _printUsage(parser);
    return;
  }

  final filePath = rest[0];
  final fs = LocalFileSystem();
  final file = fs.file(filePath);
  if (!file.existsSync()) {
    print('Error: File does not exist at $filePath');
    return;
  }

  final speedStr = results['speed'] as String;
  final speed = double.tryParse(speedStr) ?? 1.0;
  final interactive = !(results['non-interactive'] as bool);
  final paused = results['paused'] as bool;
  final noCloseAtEnd = results['keep-alive'] as bool;

  final bytes = file.readAsBytesSync();
  String data;
  try {
    data = utf8.decode(GZipDecoder().decodeBytes(bytes));
  } catch (_) {
    // Fallback to plain text if not gzipped
    data = utf8.decode(bytes);
  }

  final player = AsciicastPlayer(data);

  try {
    await player.play(
      speedMultiplier: speed,
      interactive: interactive,
      paused: paused,
      noCloseAtEnd: noCloseAtEnd,
    );
    exit(0);
  } catch (e) {
    print('Error during playback: $e');
    exit(1);
  }
}

void _printUsage(ArgParser parser) {
  print('Usage: dart run termui_recorder:termui_play [options] <input.cast>\n');
  print('Options:');
  print(parser.usage);
}
