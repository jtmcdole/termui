// coverage:ignore-file
// ignore_for_file: public_member_api_docs

import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:termui/src/terminal/windows_console_input.dart';
import 'package:win32/win32.dart';

import 'terminal.dart';

const int _inputRecordBatchSize = 64;

bool _drainWindowsConsoleBatch(
  HANDLE inputHandle,
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
  }
  if (batch.isNotEmpty) {
    sendPort.send(batch.takeBytes());
  }
  return ok;
}

void _windowsInputReaderEntry((int, SendPort) args) {
  final (inputAddress, sendPort) = args;
  final inputHandle = HANDLE(Pointer.fromAddress(inputAddress));
  final decoder = WindowsConsoleInputDecoder();
  final arena = Arena();

  try {
    final records = arena<INPUT_RECORD>(_inputRecordBatchSize);
    final countPtr = arena<Uint32>();

    while (true) {
      final wait = WaitForSingleObject(inputHandle, 20).value;
      if (wait == WAIT_TIMEOUT) {
        sleep(const Duration(milliseconds: 10));
        continue;
      }
      if (wait != WAIT_OBJECT_0) break;
      if (!_drainWindowsConsoleBatch(
        inputHandle,
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
  Stream<List<int>> openInputStream() {
    ReceivePort? receivePort;
    Isolate? isolate;
    late final StreamController<List<int>> controller;
    controller = StreamController<List<int>>(
      onListen: () async {
        final port = ReceivePort();
        receivePort = port;
        port.listen((message) {
          if (message == null) {
            port.close();
            unawaited(controller.close());
          } else if (message is List<int>) {
            controller.add(message);
          }
        }, onDone: controller.close);
        isolate = await Isolate.spawn(_windowsInputReaderEntry, (
          inputHandle.address,
          port.sendPort,
        ));
      },
      onCancel: () {
        receivePort?.close();
        isolate?.kill(priority: Isolate.immediate);
      },
    );
    return controller.stream;
  }

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
