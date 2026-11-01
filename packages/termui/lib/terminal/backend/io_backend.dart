import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:termui/terminal/raw/terminal.dart' as raw;

import 'terminal_backend.dart';

/// Returns the platform-specific terminal backend for Dart VM (IO).
TerminalBackend getPlatformBackend() => IoTerminalBackend();

/// A terminal backend implementation using `dart:io` and FFI.
class IoTerminalBackend implements TerminalBackend {
  @override
  bool get isWindows => Platform.isWindows;

  /// The low-level raw terminal instance.
  final raw.Terminal rawTerminal;
  late final StreamController<List<int>> _rawInputController =
      StreamController<List<int>>.broadcast(onListen: _ensureInputStarted);

  StreamSubscription<List<int>>? _inputSubscription;

  /// Creates a new IO terminal backend.
  ///
  /// An optional [rawTerminal] override supports hermetic testing without
  /// touching process `stdin` or OS console handles.
  IoTerminalBackend({raw.Terminal? rawTerminal})
    : rawTerminal = rawTerminal ?? raw.Terminal();

  void _ensureInputStarted() {
    if (_inputSubscription != null || _rawInputController.isClosed) return;
    _inputSubscription = rawTerminal.openInputStream().listen(
      _rawInputController.add,
      onError: _rawInputController.addError,
      onDone: _rawInputController.close,
    );
  }

  @override
  Stream<List<int>> get rawInput => _rawInputController.stream;

  @override
  void write(String data) {
    stdout.write(data);
  }

  @override
  Point<int> get size {
    return rawTerminal.getScreenBufferSize();
  }

  @override
  Stream<Point<int>> watchSize() {
    late StreamController<Point<int>> controller;
    Timer? timer;
    StreamSubscription<ProcessSignal>? sigwinchSubscription;

    controller = StreamController<Point<int>>(
      onListen: () {
        var last = rawTerminal.getScreenBufferSize();

        if (Platform.isWindows) {
          timer = Timer.periodic(const Duration(milliseconds: 500), (_) {
            final peek = rawTerminal.getScreenBufferSize();
            if (peek != last) {
              last = peek;
              controller.add(peek);
            }
          });
        } else {
          sigwinchSubscription = ProcessSignal.sigwinch.watch().listen((_) {
            final peek = rawTerminal.getScreenBufferSize();
            if (peek != last) {
              last = peek;
              controller.add(peek);
            }
          });
        }
      },
      onCancel: () {
        timer?.cancel();
        sigwinchSubscription?.cancel();
      },
    );

    return controller.stream;
  }

  @override
  void enableRawMode() {
    rawTerminal.enableRawMode();
  }

  @override
  void disableRawMode() {
    rawTerminal.disableRawMode();
  }

  @override
  void dispose() {
    _inputSubscription?.cancel();
    _inputSubscription = null;
    _rawInputController.close();
  }
}
