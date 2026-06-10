// coverage:ignore-file

import 'dart:io';
import 'dart:math';

import 'unix_terminal.dart';
import 'windows_terminal.dart';

/// Interface for the underlying native terminal.
abstract class Terminal {
  /// Creates a new terminal instance suitable for the current platform.
  factory Terminal() => Platform.isWindows ? WindowsTerminal() : UnixTerminal();

  /// Enables raw mode which allows us to process each keypress as it comes in.
  /// https://viewsourcecode.org/snaptoken/kilo/02.enteringRawMode.html
  void enableRawMode();

  /// Disables raw mode and restores the terminal’s original attributes.
  void disableRawMode();

  /// Returns the current size of the terminal screen buffer as a [Point],
  /// where `x` is the number of columns and `y` is the number of rows.
  Point<int> getScreenBufferSize();
}
