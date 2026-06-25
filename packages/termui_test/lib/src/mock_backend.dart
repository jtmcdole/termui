import 'dart:async';
import 'dart:math';
import 'package:termui/termui.dart';

/// A mock implementation of [TerminalBackend] for testing.
///
/// It intercepts stdout writes, stores them in a buffer, and allows pushing
/// raw ANSI/SGR escape sequences into the stdin/rawInput stream.
class MockTerminalBackend implements BufferedTerminalBackend {
  @override
  final bool isWindows;

  /// The active screen buffer painted by the prompt runner.
  @override
  Buffer? buffer;

  final StreamController<List<int>> _rawInputController =
      StreamController<List<int>>.broadcast();
  final StreamController<Point<int>> _sizeController =
      StreamController<Point<int>>.broadcast();

  final StringBuffer _stdoutBuffer = StringBuffer();
  final List<String> _writes = [];

  Point<int> _size;

  /// Creates a [MockTerminalBackend].
  MockTerminalBackend({this.isWindows = false, Point<int>? size})
    : _size = size ?? const Point(80, 24);

  @override
  Stream<List<int>> get rawInput => _rawInputController.stream;

  @override
  Point<int> get size => _size;

  /// Sets a new terminal size and notifies size watchers.
  set size(Point<int> newSize) {
    if (_size != newSize) {
      _size = newSize;
      _sizeController.add(newSize);
    }
  }

  @override
  Stream<Point<int>> watchSize() => _sizeController.stream;

  @override
  void write(String data) {
    _stdoutBuffer.write(data);
    _writes.add(data);
  }

  /// Injects raw input bytes into the terminal's input stream.
  void pushBytes(List<int> bytes) {
    _rawInputController.add(bytes);
  }

  /// Injects a raw string (including escape sequences) into the terminal's input stream.
  void pushString(String value) {
    pushBytes(value.codeUnits);
  }

  /// The accumulated string written to stdout.
  String get stdout => _stdoutBuffer.toString();

  /// The individual chunks written to stdout.
  List<String> get writes => _writes;

  /// Clears the accumulated stdout buffers.
  void clearStdout() {
    _stdoutBuffer.clear();
    _writes.clear();
  }

  @override
  void enableRawMode() {}

  @override
  void disableRawMode() {}

  @override
  void dispose() {
    _rawInputController.close();
    _sizeController.close();
  }
}
