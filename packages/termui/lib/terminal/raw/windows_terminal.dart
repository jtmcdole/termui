// coverage:ignore-file
// ignore_for_file: public_member_api_docs

import 'dart:ffi';
import 'dart:math';

import 'package:ffi/ffi.dart';

import 'terminal.dart';
import 'package:win32/win32.dart';

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
  void enableRawMode() {
    final pInMode = calloc<Uint32>();
    final pOutMode = calloc<Uint32>();
    try {
      if (GetConsoleMode(inputHandle, pInMode).value) {
        _origInputMode ??= pInMode.value;
        final dwInMode =
            (pInMode.value &
                ~(ENABLE_ECHO_INPUT |
                    ENABLE_PROCESSED_INPUT |
                    ENABLE_LINE_INPUT |
                    ENABLE_WINDOW_INPUT)) |
            ENABLE_VIRTUAL_TERMINAL_INPUT;
        SetConsoleMode(inputHandle, CONSOLE_MODE(dwInMode));
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
    if (_origInputMode != null) {
      SetConsoleMode(inputHandle, CONSOLE_MODE(_origInputMode!));
      _origInputMode = null;
    }
    if (_origOutputMode != null) {
      SetConsoleMode(outputHandle, CONSOLE_MODE(_origOutputMode!));
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
