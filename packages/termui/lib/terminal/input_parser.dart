import 'event.dart';

/// A reactive input parser that converts byte streams from stdin into high-level
/// [InputEvent]s. It handles standard ASCII, CSI escape sequences (including Alt shortcuts,
/// arrow keys, functional keys), SGR/X10 mouse protocols, bracketed paste, and focus events.
class InputParser {
  final List<int> _buffer = [];
  bool _isPasting = false;
  final List<int> _pasteBuffer = [];

  /// Indicates if the parser is running in a Windows environment.
  final bool isWindows;
  bool _backspaceDetected = false;
  late bool _backspaceIs8;

  /// Creates a new [InputParser].
  InputParser({this.isWindows = false}) {
    _backspaceIs8 = isWindows;
  }

  /// Parses a chunk of bytes and returns all decoded [InputEvent]s.
  List<InputEvent> parse(List<int> chunk) {
    _buffer.addAll(chunk);
    final events = <InputEvent>[];

    while (_buffer.isNotEmpty) {
      if (_isPasting) {
        // Look for end of bracketed paste: \x1b[201~ (bytes: 27, 91, 50, 48, 49, 126)
        int endIdx = -1;
        for (var i = 0; i <= _buffer.length - 6; i++) {
          if (_buffer[i] == 27 &&
              _buffer[i + 1] == 91 &&
              _buffer[i + 2] == 50 &&
              _buffer[i + 3] == 48 &&
              _buffer[i + 4] == 49 &&
              _buffer[i + 5] == 126) {
            endIdx = i;
            break;
          }
        }

        if (endIdx == -1) {
          final safeLength = _buffer.length >= 6 ? _buffer.length - 5 : 0;
          if (safeLength > 0) {
            _pasteBuffer.addAll(_buffer.sublist(0, safeLength));
            _buffer.removeRange(0, safeLength);
          }
          break;
        } else {
          _pasteBuffer.addAll(_buffer.sublist(0, endIdx));
          events.add(PasteEvent(String.fromCharCodes(_pasteBuffer)));
          _pasteBuffer.clear();
          _isPasting = false;
          _buffer.removeRange(0, endIdx + 6);
        }
        continue;
      }

      if (_buffer[0] != 27) {
        final b = _buffer.removeAt(0);

        if (b == 8 || b == 127) {
          if (!_backspaceDetected) {
            _backspaceIs8 = (b == 8);
            _backspaceDetected = true;
          }

          if (b == (_backspaceIs8 ? 8 : 127)) {
            events.add(const KeyEvent('backspace', KeyType.backspace));
          } else {
            events.add(
              const KeyEvent(
                'backspace',
                KeyType.backspace,
                modifiers: {Modifier.control},
              ),
            );
          }
        } else if (b == 9) {
          events.add(const KeyEvent('\t', KeyType.tab));
        } else if (b == 10 || b == 13) {
          events.add(const KeyEvent('\n', KeyType.enter));
        } else if (b >= 1 && b <= 26) {
          final char = String.fromCharCode(b + 96);
          events.add(
            KeyEvent(
              char,
              KeyType.character,
              modifiers: const {Modifier.control},
            ),
          );
        } else {
          final char = String.fromCharCode(b);
          events.add(KeyEvent(char, KeyType.character));
        }
      } else {
        if (_buffer.length == 1) {
          // Since TTY delivers full sequences together, a single ESC here means standalone ESC
          _buffer.removeAt(0);
          events.add(const KeyEvent('escape', KeyType.escape));
          break;
        }

        final second = _buffer[1];
        if (second == 91) {
          int termIdx = -1;
          for (var i = 2; i < _buffer.length; i++) {
            final b = _buffer[i];
            if (b >= 0x40 && b <= 0x7E) {
              termIdx = i;
              break;
            }
          }

          if (termIdx == -1) {
            break;
          }

          final seqBytes = _buffer.sublist(0, termIdx + 1);
          final termByte = seqBytes.last;
          final seqStr = String.fromCharCodes(seqBytes);

          if (seqStr.startsWith('\x1b[<')) {
            _buffer.removeRange(0, termIdx + 1);
            final mouseEvent = _parseSgrMouse(seqStr, termByte);
            if (mouseEvent != null) {
              events.add(mouseEvent);
            }
          } else if (seqStr.startsWith('\x1b[M')) {
            if (_buffer.length < 6) {
              break;
            }
            final x10Bytes = _buffer.sublist(3, 6);
            _buffer.removeRange(0, 6);
            events.add(_parseX10Mouse(x10Bytes));
          } else {
            _buffer.removeRange(0, termIdx + 1);
            final csiEvent = _parseCsiKey(seqStr, termByte);
            if (csiEvent != null) {
              events.add(csiEvent);
            }
          }
        } else if (second == 79) {
          if (_buffer.length < 3) {
            break;
          }
          final term = _buffer[2];
          _buffer.removeRange(0, 3);
          events.add(_parseSs3Key(term));
        } else {
          _buffer.removeRange(0, 2);
          final charStr = String.fromCharCode(second);
          events.add(
            KeyEvent(
              charStr,
              KeyType.character,
              modifiers: const {Modifier.alt},
            ),
          );
        }
      }
    }

    return events;
  }

  MouseEvent? _parseSgrMouse(String seq, int termByte) {
    final match = RegExp(r'^\x1b\[<(\d+);(\d+);(\d+)[Mm]$').firstMatch(seq);
    if (match == null) return null;

    final btnVal = int.parse(match.group(1)!);
    final x = int.parse(match.group(2)!);
    final y = int.parse(match.group(3)!);

    final mods = <Modifier>{};
    if ((btnVal & 4) != 0) mods.add(Modifier.shift);
    if ((btnVal & 8) != 0) mods.add(Modifier.alt);
    if ((btnVal & 16) != 0) mods.add(Modifier.control);

    final isDrag = (btnVal & 32) != 0;
    final isWheel = (btnVal & 64) != 0;

    MouseButton button;
    MouseEventType type;

    if (isWheel) {
      button = (btnVal & 1) == 0 ? MouseButton.wheelUp : MouseButton.wheelDown;
      type = MouseEventType.press;
    } else {
      final buttonCode = btnVal & 3;
      if (buttonCode == 0) {
        button = MouseButton.left;
      } else if (buttonCode == 1) {
        button = MouseButton.middle;
      } else if (buttonCode == 2) {
        button = MouseButton.right;
      } else {
        button = MouseButton.none;
      }

      if (termByte == 109) {
        type = MouseEventType.release;
      } else if (button == MouseButton.none) {
        type = MouseEventType.move;
      } else if (isDrag) {
        type = MouseEventType.drag;
      } else {
        type = MouseEventType.press;
      }
    }

    return MouseEvent(x: x, y: y, button: button, type: type, modifiers: mods);
  }

  MouseEvent _parseX10Mouse(List<int> bytes) {
    final b = bytes[0];
    final col = bytes[1];
    final row = bytes[2];

    final x = col - 32;
    final y = row - 32;

    final buttonVal = b - 32;

    final mods = <Modifier>{};
    if ((buttonVal & 4) != 0) mods.add(Modifier.shift);
    if ((buttonVal & 8) != 0) mods.add(Modifier.alt);
    if ((buttonVal & 16) != 0) mods.add(Modifier.control);

    final isDrag = (buttonVal & 32) != 0;
    final isWheel = (buttonVal & 64) != 0;

    MouseButton button;
    MouseEventType type;

    if (isWheel) {
      button = (buttonVal & 1) == 0
          ? MouseButton.wheelUp
          : MouseButton.wheelDown;
      type = MouseEventType.press;
    } else {
      final btnCode = buttonVal & 3;
      if (btnCode == 0) {
        button = MouseButton.left;
      } else if (btnCode == 1) {
        button = MouseButton.middle;
      } else if (btnCode == 2) {
        button = MouseButton.right;
      } else {
        button = MouseButton.none;
      }

      if (btnCode == 3) {
        type = MouseEventType.release;
      } else if (isDrag) {
        type = MouseEventType.drag;
      } else {
        type = MouseEventType.press;
      }
    }

    return MouseEvent(x: x, y: y, button: button, type: type, modifiers: mods);
  }

  InputEvent? _parseCsiKey(String seq, int termByte) {
    final paramsStr = seq.substring(2, seq.length - 1);
    final params = paramsStr.isEmpty
        ? <int>[]
        : paramsStr.split(';').map(int.parse).toList();

    final mods = <Modifier>{};
    if (params.length >= 2) {
      final modVal = params[1] - 1;
      if ((modVal & 1) != 0) mods.add(Modifier.shift);
      if ((modVal & 2) != 0) mods.add(Modifier.alt);
      if ((modVal & 4) != 0) mods.add(Modifier.control);
      if ((modVal & 8) != 0) mods.add(Modifier.meta);
    }

    switch (termByte) {
      case 90:
        return KeyEvent(
          'backtab',
          KeyType.tab,
          modifiers: mods.isEmpty ? const {Modifier.shift} : mods,
        );
      case 73:
        return const FocusInEvent();
      case 79:
        return const FocusOutEvent();
      case 65:
        return KeyEvent('up', KeyType.up, modifiers: mods);
      case 66:
        return KeyEvent('down', KeyType.down, modifiers: mods);
      case 67:
        return KeyEvent('right', KeyType.right, modifiers: mods);
      case 68:
        return KeyEvent('left', KeyType.left, modifiers: mods);
      case 72:
        return KeyEvent('home', KeyType.home, modifiers: mods);
      case 70:
        return KeyEvent('end', KeyType.end, modifiers: mods);
      case 117: // 'u' - Kitty / CSI u keyboard protocol
        if (params.isNotEmpty) {
          final keyNum = params[0];
          if (keyNum == 127 || keyNum == 8) {
            return KeyEvent('backspace', KeyType.backspace, modifiers: mods);
          }
        }
        break;
      case 126:
        if (params.isEmpty) return const KeyEvent('~', KeyType.character);
        final keyNum = params[0];
        switch (keyNum) {
          case 127:
            return KeyEvent('backspace', KeyType.backspace, modifiers: mods);
          case 200:
            _isPasting = true;
            _pasteBuffer.clear();
            return null;
          case 1:
          case 7:
            return KeyEvent('home', KeyType.home, modifiers: mods);
          case 2:
            return KeyEvent('insert', KeyType.insert, modifiers: mods);
          case 3:
            return KeyEvent('delete', KeyType.delete, modifiers: mods);
          case 4:
          case 8:
            return KeyEvent('end', KeyType.end, modifiers: mods);
          case 5:
            return KeyEvent('pageUp', KeyType.pageUp, modifiers: mods);
          case 6:
            return KeyEvent('pageDown', KeyType.pageDown, modifiers: mods);
          case 11:
            return KeyEvent('f1', KeyType.f1, modifiers: mods);
          case 12:
            return KeyEvent('f2', KeyType.f2, modifiers: mods);
          case 13:
            return KeyEvent('f3', KeyType.f3, modifiers: mods);
          case 14:
            return KeyEvent('f4', KeyType.f4, modifiers: mods);
          case 15:
            return KeyEvent('f5', KeyType.f5, modifiers: mods);
          case 17:
            return KeyEvent('f6', KeyType.f6, modifiers: mods);
          case 18:
            return KeyEvent('f7', KeyType.f7, modifiers: mods);
          case 19:
            return KeyEvent('f8', KeyType.f8, modifiers: mods);
          case 20:
            return KeyEvent('f9', KeyType.f9, modifiers: mods);
          case 21:
            return KeyEvent('f10', KeyType.f10, modifiers: mods);
          case 23:
            return KeyEvent('f11', KeyType.f11, modifiers: mods);
          case 24:
            return KeyEvent('f12', KeyType.f12, modifiers: mods);
        }
    }

    return KeyEvent(seq, KeyType.character);
  }

  InputEvent _parseSs3Key(int term) {
    switch (term) {
      case 80:
        return const KeyEvent('f1', KeyType.f1);
      case 81:
        return const KeyEvent('f2', KeyType.f2);
      case 82:
        return const KeyEvent('f3', KeyType.f3);
      case 83:
        return const KeyEvent('f4', KeyType.f4);
    }
    return KeyEvent(String.fromCharCode(term), KeyType.character);
  }
}
