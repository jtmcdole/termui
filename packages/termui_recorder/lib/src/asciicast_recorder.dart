import 'dart:convert';
import 'package:termui/ui/buffer.dart';
import 'package:termui/ui/renderer.dart';

/// A recorder that captures terminal frame states and serializes them
/// into the Asciinema Asciicast v2 format.
class AsciicastRecorder {
  /// The column width of the recorded terminal session.
  final int width;

  /// The row height of the recorded terminal session.
  final int height;

  final StringSink _outputSink;
  late final DateTime _startTime;
  late final Renderer _renderer;
  bool _headerWritten = false;

  /// Creates a new [AsciicastRecorder] writing to the specified [outputSink].
  AsciicastRecorder(
    StringSink outputSink, {
    required this.width,
    required this.height,
  }) : _outputSink = outputSink {
    _startTime = DateTime.now();
    _renderer = Renderer(width, height, mode: RenderingMode.alternateScreen);
  }

  /// Writes the Asciicast header chunk.
  void _writeHeader() {
    final header = {
      'version': 2,
      'width': width,
      'height': height,
      'timestamp': _startTime.millisecondsSinceEpoch ~/ 1000,
      'env': {'TERM': 'xterm-256color', 'SHELL': '/bin/sh'},
    };
    _outputSink.write('${jsonEncode(header)}\n');
    _headerWritten = true;
  }

  /// Records a frame change from the given [buffer] by diff-rendering it and
  /// capturing the output ANSI escape payload.
  void recordFrame(Buffer buffer) {
    if (!_headerWritten) {
      _writeHeader();
    }

    final frameOutput = StringBuffer();
    _renderer.render(buffer, frameOutput);

    final deltaAnsi = frameOutput.toString();
    if (deltaAnsi.isEmpty) return; // No updates drawn

    final elapsed = DateTime.now().difference(_startTime);
    final elapsedSeconds = elapsed.inMicroseconds / 1000000.0;

    final eventRow = [
      elapsedSeconds,
      'o', // Output sequence type
      deltaAnsi,
    ];

    _outputSink.write('${jsonEncode(eventRow)}\n');
  }
}
