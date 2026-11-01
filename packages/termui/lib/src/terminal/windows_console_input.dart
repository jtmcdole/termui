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
