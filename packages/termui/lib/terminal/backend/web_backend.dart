import 'dart:async';
import 'dart:math';

import 'terminal_backend.dart';

/// Returns the platform-specific terminal backend for the Web.
TerminalBackend getPlatformBackend() => WebTerminalBackend();

/// Returns whether the current terminal program is iTerm2.
bool isItermTerminal() => false;

/// A terminal backend implementation for web environments.
class WebTerminalBackend implements TerminalBackend {
  @override
  bool get isWindows => false;

  final _rawInputController = StreamController<List<int>>.broadcast();
  final _sizeController = StreamController<Point<int>>.broadcast();
  Point<int> _currentSize = const Point(80, 24);

  /// Allows the web container or terminal emulator to inject keystroke bytes.
  void injectInput(List<int> bytes) {
    if (!_rawInputController.isClosed) {
      _rawInputController.add(bytes);
    }
  }

  /// Allows the web container or terminal emulator to notify us of resizing.
  void updateSize(Point<int> newSize) {
    if (_currentSize != newSize) {
      _currentSize = newSize;
      if (!_sizeController.isClosed) {
        _sizeController.add(newSize);
      }
    }
  }

  /// Callback to capture ANSI escape sequence output.
  void Function(String)? onWrite;

  @override
  Stream<List<int>> get rawInput => _rawInputController.stream;

  @override
  void write(String data) {
    onWrite?.call(data);
  }

  @override
  Point<int> get size => _currentSize;

  @override
  Stream<Point<int>> watchSize() => _sizeController.stream;

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
