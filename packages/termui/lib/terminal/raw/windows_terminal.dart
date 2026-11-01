// coverage:ignore-file
// ignore_for_file: public_member_api_docs

import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';

import 'package:ffi/ffi.dart';
import 'package:termui/src/terminal/windows_console_input.dart';
import 'package:win32/win32.dart';

import 'terminal.dart';

void _windowsInputReaderEntry((int, SendPort) args) {
  final (inputAddress, sendPort) = args;
  final inputHandle = HANDLE(Pointer.fromAddress(inputAddress));
  final buffer = calloc<Uint16>(256);
  final numRead = calloc<Uint32>();

  try {
    while (true) {
      final waitResult = WaitForSingleObject(inputHandle, 20);
      if (waitResult.value != WAIT_OBJECT_0) {
        sleep(const Duration(milliseconds: 10));
        continue;
      }
      final result = ReadConsole(inputHandle, buffer, 256, numRead, nullptr);
      if (result.value && numRead.value > 0) {
        sendPort.send([for (var i = 0; i < numRead.value; i++) buffer[i]]);
      }
    }
  } finally {
    calloc.free(buffer);
    calloc.free(numRead);
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
          if (message is List<int>) {
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
