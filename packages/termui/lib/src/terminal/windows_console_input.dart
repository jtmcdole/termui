import 'dart:convert';
import 'dart:ffi';
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
