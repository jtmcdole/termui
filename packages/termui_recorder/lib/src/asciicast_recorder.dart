import 'dart:convert';
import 'package:file/file.dart';
import 'package:clock/clock.dart';
import 'package:termui/ui/buffer.dart';
import 'package:termui/ui/renderer.dart';
import 'package:archive/archive.dart';

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
  final StringBuffer _buffer = StringBuffer();

  /// Creates a [FileAsciicastWriter] wrapping the given [file].
  FileAsciicastWriter(File file) : _file = file {
    if (_file.existsSync()) {
      _file.deleteSync();
    }
    _file.createSync(recursive: true);
  }

  @override
  void writeLine(String line) {
    _buffer.writeln(line);
  }

  @override
  void close() {
    final bytes = utf8.encode(_buffer.toString());
    final compressed = GZipEncoder().encode(bytes);
    _file.writeAsBytesSync(compressed);
  }
}

/// A writer that sends Asciicast lines to a [StringSink].
class StringSinkAsciicastWriter implements AsciicastWriter {
  final StringSink _sink;

  /// Creates a [StringSinkAsciicastWriter] wrapping the given [sink].
  StringSinkAsciicastWriter(this._sink);

  @override
  void writeLine(String line) {
    _sink.writeln(line);
  }

  @override
  void close() {
    // No-op for StringSink
  }
}

/// A recorder that captures terminal frame states and serializes them
/// into the Asciinema Asciicast v3 format.
class AsciicastRecorder {
  /// The column width of the recorded terminal session.
  int width;

  /// The row height of the recorded terminal session.
  int height;

  final AsciicastWriter _writer;
  DateTime? _startTime;
  DateTime? _lastEventTime;
  late final Renderer _renderer;
  bool _headerWritten = false;
  int? _lastRecordedWidth;
  int? _lastRecordedHeight;

  /// Creates a new [AsciicastRecorder] writing to the specified [writer].
  AsciicastRecorder(
    AsciicastWriter writer, {
    required this.width,
    required this.height,
  }) : _writer = writer {
    _renderer = Renderer(width, height, mode: RenderingMode.alternateScreen);
  }

  /// Writes the Asciicast header chunk in v3 format.
  void _writeHeader() {
    final header = {
      'version': 3,
      'term': {'cols': width, 'rows': height},
      'timestamp': _startTime!.millisecondsSinceEpoch ~/ 1000,
    };
    _writer.writeLine(jsonEncode(header));
    _headerWritten = true;
    _lastRecordedWidth = width;
    _lastRecordedHeight = height;
  }

  /// Records a frame change from the given [buffer] by diff-rendering it and
  /// capturing the output ANSI escape payload.
  ///
  /// Optionally accepts [actions] performed in this frame.
  void recordFrame(Buffer buffer, [List<String>? actions]) {
    final now = clock.now();
    _startTime ??= now;
    _lastEventTime ??= now;

    if (!_headerWritten) {
      width = buffer.width;
      height = buffer.height;
      _writeHeader();
    }

    final elapsed = now.difference(_lastEventTime!);
    final intervalSeconds = elapsed.inMicroseconds / 1000000.0;

    if (_lastRecordedWidth != buffer.width || _lastRecordedHeight != buffer.height) {
      width = buffer.width;
      height = buffer.height;
      _lastRecordedWidth = buffer.width;
      _lastRecordedHeight = buffer.height;

      final resizeRow = [
        intervalSeconds,
        'r',
        {'cols': buffer.width, 'rows': buffer.height},
      ];
      _writer.writeLine(jsonEncode(resizeRow));
    }

    final frameOutput = StringBuffer();
    _renderer.render(buffer, frameOutput);

    final deltaAnsi = frameOutput.toString();
    if (deltaAnsi.isEmpty) return; // No updates drawn

    _lastEventTime = now;

    if (actions != null && actions.isNotEmpty) {
      final joinedActions = actions.join(', ');
      final actionRow = [
        0.0, // Attach metadata exactly at the same tick (0.0 interval from the previous event)
        'd', // Custom actions metadata code
        'Actions: $joinedActions',
      ];
      _writer.writeLine(jsonEncode(actionRow));
    }

    final eventRow = [
      intervalSeconds,
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
