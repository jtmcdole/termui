import 'dart:io';
import 'package:args/args.dart';
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
    exit(1);
  }

  if (results['help'] as bool) {
    _printUsage(parser);
    exit(0);
  }

  final rest = results.rest;
  if (rest.isEmpty) {
    print('Error: Missing input .cast file path.');
    _printUsage(parser);
    exit(1);
  }

  final filePath = rest[0];
  final file = File(filePath);
  if (!file.existsSync()) {
    print('Error: File does not exist at $filePath');
    exit(1);
  }

  final speedStr = results['speed'] as String;
  final speed = double.tryParse(speedStr) ?? 1.0;
  final interactive = !(results['non-interactive'] as bool);

  final player = AsciicastPlayer(file);

  try {
    await player.play(speedMultiplier: speed, interactive: interactive);
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
