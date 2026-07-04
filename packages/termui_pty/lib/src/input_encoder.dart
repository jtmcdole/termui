import 'package:termui/terminal/event.dart' as ev;

/// Encodes high-level `termui` [ev.InputEvent] objects into raw ANSI/VT100 byte strings.
/// These strings can be written to a PTY's `write()` method.
class InputEncoder {
  /// Encodes a single event into an ANSI string.
  static String encode(ev.InputEvent event) {
    if (event is ev.KeyEvent) {
      return _encodeKeyEvent(event);
    } else if (event is ev.MouseEvent) {
      return _encodeMouseEvent(event);
    } else if (event is ev.PasteEvent) {
      return event.text; // Pasted text is just sent raw
    }
    return '';
  }

  static String _encodeKeyEvent(ev.KeyEvent event) {
    if (event.type == ev.KeyType.character) {
      var char = event.key;

      if (event.modifiers.contains(ev.Modifier.control)) {
        if (char.isNotEmpty) {
          final code = char.codeUnitAt(0);
          // Map a-z (97-122) to ^A-^Z (1-26)
          if (code >= 97 && code <= 122) {
            return String.fromCharCode(code - 96);
          }
          // Map A-Z (65-90) to ^A-^Z (1-26)
          if (code >= 65 && code <= 90) {
            return String.fromCharCode(code - 64);
          }
        }
      }

      if (event.modifiers.contains(ev.Modifier.alt)) {
        // Alt prefixes with ESC
        return '\x1b$char';
      }

      return char;
    }

    switch (event.type) {
      case ev.KeyType.up:
        return '\x1b[A';
      case ev.KeyType.down:
        return '\x1b[B';
      case ev.KeyType.right:
        return '\x1b[C';
      case ev.KeyType.left:
        return '\x1b[D';
      case ev.KeyType.enter:
        return '\r';
      case ev.KeyType.backspace:
        return '\x7f';
      case ev.KeyType.tab:
        return '\t';
      case ev.KeyType.escape:
        return '\x1b';
      case ev.KeyType.home:
        return '\x1b[H';
      case ev.KeyType.end:
        return '\x1b[F';
      case ev.KeyType.pageUp:
        return '\x1b[5~';
      case ev.KeyType.pageDown:
        return '\x1b[6~';
      case ev.KeyType.delete:
        return '\x1b[3~';
      case ev.KeyType.insert:
        return '\x1b[2~';
      case ev.KeyType.f1:
        return '\x1bOP';
      case ev.KeyType.f2:
        return '\x1bOQ';
      case ev.KeyType.f3:
        return '\x1bOR';
      case ev.KeyType.f4:
        return '\x1bOS';
      case ev.KeyType.f5:
        return '\x1b[15~';
      case ev.KeyType.f6:
        return '\x1b[17~';
      case ev.KeyType.f7:
        return '\x1b[18~';
      case ev.KeyType.f8:
        return '\x1b[19~';
      case ev.KeyType.f9:
        return '\x1b[20~';
      case ev.KeyType.f10:
        return '\x1b[21~';
      case ev.KeyType.f11:
        return '\x1b[23~';
      case ev.KeyType.f12:
        return '\x1b[24~';
      default:
        return '';
    }
  }

  static String _encodeMouseEvent(ev.MouseEvent event) {
    int cb = 0;

    // Mouse movement adds 32
    if (event.type == ev.MouseEventType.move ||
        event.type == ev.MouseEventType.drag) {
      cb |= 32;
    }

    switch (event.button) {
      case ev.MouseButton.left:
        break;
      case ev.MouseButton.middle:
        cb |= 1;
        break;
      case ev.MouseButton.right:
        cb |= 2;
        break;
      case ev.MouseButton.none:
        cb |= 3;
        break;
      case ev.MouseButton.wheelUp:
        cb |= 64;
        break;
      case ev.MouseButton.wheelDown:
        cb |= 65;
        break;
    }

    if (event.modifiers.contains(ev.Modifier.shift)) cb |= 4;
    if (event.modifiers.contains(ev.Modifier.meta)) cb |= 8;
    if (event.modifiers.contains(ev.Modifier.control)) cb |= 16;

    final release = event.type == ev.MouseEventType.release ? 'm' : 'M';

    // SGR Mouse format
    return '\x1b[<$cb;${event.x};${event.y}$release';
  }
}
