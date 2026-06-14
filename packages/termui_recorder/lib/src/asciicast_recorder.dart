import 'dart:convert';
import 'package:file/file.dart';
import 'package:clock/clock.dart';
import 'package:termui/ui/buffer.dart';
import 'package:termui/ui/renderer.dart';

/// An interface for writing Asciicast stream data.
abstract interface class AsciicastWriter {
  /// Writes a single line to the output destination.
  void writeLine(String line);

  /// Closes the output destination.
  void close();
}

/// A writer that sends Asciicast lines to a standard [File] using synchronous I/O.
class FileAsciicastWriter implements AsciicastWriter {
  final File _file;

  /// Creates a [FileAsciicastWriter] wrapping the given [file].
  FileAsciicastWriter(File file) : _file = file {
    if (_file.existsSync()) {
      _file.deleteSync();
    }
    _file.createSync(recursive: true);
  }

  @override
  void writeLine(String line) {
    _file.writeAsStringSync(
      '$line\n',
      mode: FileMode.writeOnlyAppend,
      flush: true,
    );
  }

  @override
  void close() {
    // No-op as writes are performed synchronously and flushed immediately
  }
}

/// A writer that sends Asciicast lines to a [StringSink].
class StringSinkAsciicastWriter implements AsciicastWriter {
  final StringSink _sink;

  /// Creates a [StringSinkAsciicastWriter] wrapping the given [sink].
  StringSinkAsciicastWriter(this._sink);

  @override
  void writeLine(String line) {
    _sink.write('$line\n');
  }

  @override
  void close() {
    // No-op for StringSink
  }
}

/// A recorder that captures terminal frame states and serializes them
/// into the Asciinema Asciicast v2 format.
class AsciicastRecorder {
  /// The column width of the recorded terminal session.
  final int width;

  /// The row height of the recorded terminal session.
  final int height;

  final AsciicastWriter _writer;
  DateTime? _startTime;
  late final Renderer _renderer;
  bool _headerWritten = false;

  /// Creates a new [AsciicastRecorder] writing to the specified [writer].
  AsciicastRecorder(
    AsciicastWriter writer, {
    required this.width,
    required this.height,
  }) : _writer = writer {
    _renderer = Renderer(width, height, mode: RenderingMode.alternateScreen);
  }

  /// Writes the Asciicast header chunk.
  void _writeHeader() {
    final header = {
      'version': 2,
      'width': width,
      'height': height,
      'timestamp': _startTime!.millisecondsSinceEpoch ~/ 1000,
      'env': {'TERM': 'xterm-256color', 'SHELL': '/bin/sh'},
    };
    _writer.writeLine(jsonEncode(header));
    _headerWritten = true;
  }

  /// Records a frame change from the given [buffer] by diff-rendering it and
  /// capturing the output ANSI escape payload.
  ///
  /// Optionally accepts [actions] performed in this frame.
  void recordFrame(Buffer buffer, [List<String>? actions]) {
    _startTime ??= clock.now();

    if (!_headerWritten) {
      _writeHeader();
    }

    final elapsed = clock.now().difference(_startTime!);
    final elapsedSeconds = elapsed.inMicroseconds / 1000000.0;

    if (actions != null && actions.isNotEmpty) {
      final joinedActions = actions.join(', ');
      final actionRow = [
        elapsedSeconds,
        'd', // Custom actions metadata code
        'Actions: $joinedActions',
      ];
      _writer.writeLine(jsonEncode(actionRow));
    }

    final frameOutput = StringBuffer();
    _renderer.render(buffer, frameOutput);

    final deltaAnsi = frameOutput.toString();
    if (deltaAnsi.isEmpty) return; // No updates drawn

    final eventRow = [
      elapsedSeconds,
      'o', // Output sequence type
      deltaAnsi,
    ];

    _writer.writeLine(jsonEncode(eventRow));
  }

  /// Closes the recorder and its underlying writer.
  void close() {
    _writer.close();
  }
}
