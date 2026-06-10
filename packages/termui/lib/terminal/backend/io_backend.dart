import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';

import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart';

import 'terminal_backend.dart';
import 'package:termui/terminal/raw/terminal.dart' as raw;

/// Returns the platform-specific terminal backend for Dart VM (IO).
TerminalBackend getPlatformBackend() => IoTerminalBackend();

/// A terminal backend implementation using `dart:io` and FFI.
class IoTerminalBackend implements TerminalBackend {
  @override
  bool get isWindows => Platform.isWindows;

  /// The low-level raw terminal instance.
  final rawTerminal = raw.Terminal();
  final _rawInputController = StreamController<List<int>>.broadcast();

  StreamSubscription<List<int>>? _stdinSubscription;
  ReceivePort? _windowsReceivePort;
  Isolate? _windowsInputIsolate;

  static Stream<List<int>>? _stdinBroadcast;
  static Stream<List<int>> get _stdinStream =>
      _stdinBroadcast ??= stdin.asBroadcastStream();

  /// Creates a new IO terminal backend.
  IoTerminalBackend() {
    if (Platform.isWindows) {
      _startWindowsInputReader();
    } else {
      _stdinSubscription = _stdinStream.listen(
        (List<int> chunk) {
          _rawInputController.add(chunk);
        },
        onDone: () {
          _rawInputController.close();
        },
      );
    }
  }

  void _startWindowsInputReader() async {
    _windowsReceivePort = ReceivePort();
    _windowsInputIsolate = await Isolate.spawn(
      _windowsInputReaderEntry,
      _windowsReceivePort!.sendPort,
    );
    _windowsReceivePort!.listen(
      (dynamic message) {
        if (message is List<int>) {
          _rawInputController.add(message);
        }
      },
      onDone: () {
        _rawInputController.close();
      },
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
    StreamSubscription? sigwinchSubscription;

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
    _stdinSubscription?.cancel();
    _windowsReceivePort?.close();
    _windowsInputIsolate?.kill(priority: Isolate.immediate);
    _rawInputController.close();
  }
}

void _windowsInputReaderEntry(SendPort sendPort) {
  final inputHandle = GetStdHandle(STD_INPUT_HANDLE);
  final buffer = calloc<Uint16>(256);
  final numRead = calloc<Uint32>();

  try {
    while (true) {
      // Wait for input to be available on stdin with a timeout of 20ms
      final waitResult = WaitForSingleObject(inputHandle, 20);
      const waitObject0 = 0;
      if (waitResult == waitObject0) {
        final result = ReadConsole(inputHandle, buffer, 256, numRead, nullptr);

        if (result != 0 && numRead.value > 0) {
          final chars = <int>[];
          for (var i = 0; i < numRead.value; i++) {
            chars.add(buffer[i]);
          }
          sendPort.send(chars);
        }
      } else {
        // Sleep briefly to yield CPU and let event loop process isolate signals
        sleep(const Duration(milliseconds: 10));
      }
    }
  } catch (_) {
    // Ignore errors on exit
  } finally {
    free(buffer);
    free(numRead);
  }
}
