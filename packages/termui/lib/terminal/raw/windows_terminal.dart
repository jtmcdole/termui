// coverage:ignore-file
// ignore_for_file: public_member_api_docs

import 'dart:async';
import 'dart:ffi';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:termui/src/terminal/windows_console_input.dart';
import 'package:win32/win32.dart';

import 'terminal.dart';

bool _hasConsoleInputHandle(HANDLE handle) {
  if (handle == INVALID_HANDLE_VALUE || handle == nullptr) return false;
  final modePtr = calloc<Uint32>();
  try {
    return GetConsoleMode(handle, modePtr).value;
  } finally {
    calloc.free(modePtr);
  }
}

HANDLE _createManualResetEvent() {
  final Win32Result(value: stopEvent, :error) = CreateEvent(
    null,
    true,
    false,
    null,
  );
  if (stopEvent == nullptr || stopEvent == INVALID_HANDLE_VALUE) {
    throw WindowsException(error.toHRESULT());
  }
  return stopEvent;
}

const int _inputRecordBatchSize = 64;
const WAIT_EVENT _stopSignaled = WAIT_OBJECT_0;
const WAIT_EVENT _inputSignaled = WAIT_EVENT(1);

bool _drainWindowsConsoleBatch(
  HANDLE inputHandle,
  HANDLE stopEvent,
  Pointer<INPUT_RECORD> records,
  Pointer<Uint32> countPtr,
  WindowsConsoleInputDecoder decoder,
  SendPort sendPort,
) {
  final batch = BytesBuilder(copy: false);
  var ok = true;
  while (true) {
    if (!GetNumberOfConsoleInputEvents(inputHandle, countPtr).value) {
      ok = false;
      break;
    }
    final available = countPtr.value;
    if (available == 0) break;
    final toRead = min(available, _inputRecordBatchSize);
    if (!ReadConsoleInput(inputHandle, records, toRead, countPtr).value) {
      ok = false;
      break;
    }
    final read = countPtr.value;
    if (read == 0) break;
    batch.add(decoder.decode(records, read));
    if (WaitForSingleObject(stopEvent, 0).value == _stopSignaled) {
      return true;
    }
  }
  if (batch.isNotEmpty) {
    sendPort.send(batch.takeBytes());
  }
  return ok;
}

void _windowsInputReaderEntry((int, int, SendPort) args) {
  final (inputAddress, stopAddress, sendPort) = args;
  final inputHandle = HANDLE(Pointer.fromAddress(inputAddress));
  final stopEvent = HANDLE(Pointer.fromAddress(stopAddress));
  final decoder = WindowsConsoleInputDecoder();
  final arena = Arena();

  try {
    final handles = arena<Pointer>(2)
      ..[0] = stopEvent
      ..[1] = inputHandle;
    final records = arena<INPUT_RECORD>(_inputRecordBatchSize);
    final countPtr = arena<Uint32>();

    while (true) {
      final wait = WaitForMultipleObjects(2, handles, false, INFINITE).value;
      if (wait == _stopSignaled) return;
      if (wait != _inputSignaled) break;
      if (!_drainWindowsConsoleBatch(
        inputHandle,
        stopEvent,
        records,
        countPtr,
        decoder,
        sendPort,
      )) {
        break;
      }
    }

    final trailing = decoder.flush();
    if (trailing.isNotEmpty) {
      sendPort.send(trailing);
    }
    sendPort.send(null);
  } finally {
    arena.releaseAll();
  }
}

class WindowsTerminal implements Terminal {
  WindowsTerminal() {
    outputHandle = GetStdHandle(STD_OUTPUT_HANDLE).value;
    inputHandle = GetStdHandle(STD_INPUT_HANDLE).value;
  }

  late final HANDLE inputHandle;
  late final HANDLE outputHandle;
  int? _origInputMode;
  int? _origOutputMode;

  @override
  Stream<List<int>> openInputStream() => WindowsConsoleInputSession(
    inputHandle,
    hasConsole: _hasConsoleInputHandle,
    createStopEvent: _createManualResetEvent,
    signalStopEvent: SetEvent,
    closeStopEvent: CloseHandle,
    spawnReader: (inputAddress, stopAddress, dataPort, exitPort) =>
        Isolate.spawn(_windowsInputReaderEntry, (
          inputAddress,
          stopAddress,
          dataPort,
        ), onExit: exitPort),
  ).stream;

  @override
  void enableRawMode() {
    final pInMode = calloc<Uint32>();
    final pOutMode = calloc<Uint32>();
    try {
      if (GetConsoleMode(inputHandle, pInMode).value) {
        _origInputMode ??= pInMode.value;
        final dwInMode = configureWindowsRawInputMode(pInMode.value);
        SetConsoleMode(inputHandle, dwInMode);
      }
      if (GetConsoleMode(outputHandle, pOutMode).value) {
        _origOutputMode ??= pOutMode.value;
        final dwOutMode = pOutMode.value | ENABLE_VIRTUAL_TERMINAL_PROCESSING;
        SetConsoleMode(outputHandle, CONSOLE_MODE(dwOutMode));
      }
    } finally {
      calloc.free(pInMode);
      calloc.free(pOutMode);
    }
  }

  @override
  void disableRawMode() {
    if (_origInputMode case final origInputMode?) {
      final restoreMode = configureWindowsRestoreInputMode(origInputMode);
      SetConsoleMode(inputHandle, restoreMode);
      _origInputMode = null;
    }
    if (_origOutputMode case final origOutputMode?) {
      SetConsoleMode(outputHandle, CONSOLE_MODE(origOutputMode));
      _origOutputMode = null;
    }
  }

  @override
  Point<int> getScreenBufferSize() {
    final buff = calloc<CONSOLE_SCREEN_BUFFER_INFO>();
    try {
      if (!GetConsoleScreenBufferInfo(outputHandle, buff).value) {
        return const Point(-1, -1);
      }
      return Point(
        buff.ref.srWindow.Right - buff.ref.srWindow.Left + 1,
        buff.ref.srWindow.Bottom - buff.ref.srWindow.Top + 1,
      );
    } finally {
      calloc.free(buff);
    }
  }
}
