// coverage:ignore-file
// ignore_for_file: public_member_api_docs

import 'dart:ffi';
import 'dart:math';

import 'package:ffi/ffi.dart';

import 'terminal.dart';
import 'package:win32/win32.dart';

class WindowsTerminal implements Terminal {
  WindowsTerminal() {
    outputHandle = GetStdHandle(STD_OUTPUT_HANDLE);
    inputHandle = GetStdHandle(STD_INPUT_HANDLE);
  }

  late final int inputHandle;
  late final int outputHandle;

  @override
  void enableRawMode() {
    const dwMode =
        (~ENABLE_ECHO_INPUT) &
        (~ENABLE_PROCESSED_INPUT) &
        (~ENABLE_LINE_INPUT) &
        (~ENABLE_WINDOW_INPUT);
    SetConsoleMode(inputHandle, dwMode | ENABLE_VIRTUAL_TERMINAL_INPUT);
  }

  @override
  void disableRawMode() {
    const dwMode =
        ENABLE_ECHO_INPUT |
        ENABLE_EXTENDED_FLAGS |
        ENABLE_INSERT_MODE |
        ENABLE_LINE_INPUT |
        ENABLE_MOUSE_INPUT |
        ENABLE_PROCESSED_INPUT |
        ENABLE_QUICK_EDIT_MODE |
        ENABLE_VIRTUAL_TERMINAL_INPUT;
    SetConsoleMode(inputHandle, dwMode);
  }

  @override
  Point<int> getScreenBufferSize() {
    final buff = calloc<CONSOLE_SCREEN_BUFFER_INFO>();
    GetConsoleScreenBufferInfo(outputHandle, buff);

    final size = Point(
      buff.ref.srWindow.Right - buff.ref.srWindow.Left + 1,
      buff.ref.srWindow.Bottom - buff.ref.srWindow.Top + 1,
    );
    free(buff);
    return size;
  }
}
