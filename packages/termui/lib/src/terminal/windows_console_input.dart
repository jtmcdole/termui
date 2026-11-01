import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:win32/win32.dart';

/// Computes the Windows console input mode flags required for raw VT input.
///
/// Clears line buffering, echo, Ctrl+C processing, window resize events, and
/// QuickEdit mouse selection, while enabling extended flags, mouse capture,
/// and virtual terminal input sequences.
CONSOLE_MODE configureWindowsRawInputMode(int origMode) => CONSOLE_MODE(
  (origMode &
          ~(ENABLE_ECHO_INPUT |
              ENABLE_PROCESSED_INPUT |
              ENABLE_LINE_INPUT |
              ENABLE_WINDOW_INPUT |
              ENABLE_QUICK_EDIT_MODE)) |
      ENABLE_EXTENDED_FLAGS |
      ENABLE_MOUSE_INPUT |
      ENABLE_VIRTUAL_TERMINAL_INPUT,
);

/// Computes the Windows console input mode flags used when restoring
/// [origMode].
///
/// Includes [ENABLE_EXTENDED_FLAGS] so Win32 applies the saved
/// [ENABLE_QUICK_EDIT_MODE] and [ENABLE_INSERT_MODE] bits.
CONSOLE_MODE configureWindowsRestoreInputMode(int origMode) =>
    CONSOLE_MODE(origMode | ENABLE_EXTENDED_FLAGS);

/// Coordinates a single-subscription Windows console input stream backed by a
/// worker isolate and a Win32 manual-reset stop event.
final class WindowsConsoleInputSession {
  /// Creates a console input session over [inputHandle] using OS callbacks.
  WindowsConsoleInputSession(
    this._inputHandle, {
    required bool Function(HANDLE handle) hasConsole,
    required HANDLE Function() createStopEvent,
    required void Function(HANDLE stopEvent) signalStopEvent,
    required void Function(HANDLE stopEvent) closeStopEvent,
    required Future<void> Function(
      int inputAddress,
      int stopAddress,
      SendPort dataPort,
      SendPort exitPort,
    )
    spawnReader,
  }) : _hasConsole = hasConsole,
       _createStopEvent = createStopEvent,
       _signalStopEvent = signalStopEvent,
       _closeStopEvent = closeStopEvent,
       _spawnReader = spawnReader;

  final HANDLE _inputHandle;
  final bool Function(HANDLE handle) _hasConsole;
  final HANDLE Function() _createStopEvent;
  final void Function(HANDLE stopEvent) _signalStopEvent;
  final void Function(HANDLE stopEvent) _closeStopEvent;
  final Future<void> Function(
    int inputAddress,
    int stopAddress,
    SendPort dataPort,
    SendPort exitPort,
  )
  _spawnReader;

  late final StreamController<List<int>> _controller =
      StreamController<List<int>>(onListen: _onListen, onCancel: _onCancel);

  final Completer<void> _exitCompleter = Completer<void>();
  ReceivePort? _dataPort;
  ReceivePort? _exitPort;
  HANDLE? _stopEvent;
  bool _cancelled = false;

  /// The single-subscription byte stream emitted by this session.
  Stream<List<int>> get stream => _controller.stream;

  Future<void> _onListen() async {
    if (!_hasConsole(_inputHandle)) {
      unawaited(_controller.close());
      return;
    }

    final HANDLE stopEvent;
    try {
      stopEvent = _createStopEvent();
    } catch (error, stackTrace) {
      _controller.addError(error, stackTrace);
      unawaited(_controller.close());
      return;
    }

    final dataPort = ReceivePort();
    final exitPort = ReceivePort();
    _dataPort = dataPort;
    _exitPort = exitPort;
    _stopEvent = stopEvent;

    dataPort.listen(_onData);
    exitPort.listen((_) => _release());

    try {
      await _spawnReader(
        _inputHandle.address,
        stopEvent.address,
        dataPort.sendPort,
        exitPort.sendPort,
      );
    } catch (error, stackTrace) {
      if (!_cancelled && !_controller.isClosed) {
        _controller.addError(error, stackTrace);
      }
      _release();
    }
  }

  void _onData(Object? message) {
    if (_cancelled || _controller.isClosed) return;
    if (message == null) {
      _dataPort?.close();
      _dataPort = null;
      unawaited(_controller.close());
    } else if (message is List<int>) {
      _controller.add(message);
    }
  }

  void _release() {
    _exitPort?.close();
    _exitPort = null;
    _dataPort?.close();
    _dataPort = null;
    if (_stopEvent case final stopEvent?) {
      _stopEvent = null;
      _closeStopEvent(stopEvent);
    }
    if (!_exitCompleter.isCompleted) {
      _exitCompleter.complete();
    }
    if (!_cancelled && !_controller.isClosed) {
      unawaited(_controller.close());
    }
  }

  Future<void>? _onCancel() {
    _cancelled = true;
    if (_stopEvent case final stopEvent?) {
      _signalStopEvent(stopEvent);
    }
    _dataPort?.close();
    _dataPort = null;
    return _exitPort != null ? _exitCompleter.future : null;
  }
}

/// Decodes Win32 console [INPUT_RECORD] batches into UTF-8 byte chunks.
///
/// Filters for key-down [KEY_EVENT] records (plus Alt+Numpad [VK_MENU] key-up
/// compositions) with non-zero UTF-16 code units, honors `wRepeatCount`, and
/// stitches UTF-16 surrogate pairs split across consecutive batches.
final class WindowsConsoleInputDecoder {
  static final Uint8List _emptyBytes = Uint8List(0);
  static final Uint8List _replacementBytes = utf8.encode('\uFFFD');

  int? _pendingHighSurrogate;

  static bool _isHighSurrogate(int unit) => unit >= 0xD800 && unit <= 0xDBFF;

  static bool _isLowSurrogate(int unit) => unit >= 0xDC00 && unit <= 0xDFFF;

  void _appendCodeUnit(List<int> out, int unit, int repeat) {
    if (_pendingHighSurrogate case final high?) {
      _pendingHighSurrogate = null;
      if (_isLowSurrogate(unit)) {
        for (var i = 0; i < repeat; i++) {
          out
            ..add(high)
            ..add(unit);
        }
        return;
      }
      out.add(0xFFFD);
    }
    if (_isHighSurrogate(unit)) {
      _pendingHighSurrogate = unit;
      return;
    }
    for (var i = 0; i < repeat; i++) {
      out.add(unit);
    }
  }

  /// Decodes [count] console records from [records] into UTF-8 bytes.
  Uint8List decode(Pointer<INPUT_RECORD> records, int count) {
    final codeUnits = <int>[];
    for (var i = 0; i < count; i++) {
      final record = records[i];
      if (record.EventType != KEY_EVENT) continue;
      final key = record.KeyEvent;
      final codeUnit = key.UnicodeChar;
      if (codeUnit == 0 || (!key.bKeyDown && key.wVirtualKeyCode != VK_MENU)) {
        continue;
      }
      _appendCodeUnit(codeUnits, codeUnit, max(1, key.wRepeatCount));
    }
    if (codeUnits.isEmpty) return _emptyBytes;
    return utf8.encode(String.fromCharCodes(codeUnits));
  }

  /// Flushes any trailing unpaired high surrogate as `U+FFFD`.
  Uint8List flush() {
    if (_pendingHighSurrogate == null) return _emptyBytes;
    _pendingHighSurrogate = null;
    return _replacementBytes;
  }
}
