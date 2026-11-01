import 'package:termui/terminal/event.dart' as ev;

/// Encodes high-level `termui` [ev.InputEvent] objects into raw ANSI/VT100 byte strings.
/// These strings can be written to a PTY's `write()` method.
abstract final class InputEncoder {
  /// Encodes a single event into an ANSI string.
  static String encode(ev.InputEvent event) => switch (event) {
    ev.KeyEvent key => _encodeKeyEvent(key),
    ev.MouseEvent mouse => _encodeMouseEvent(mouse),
    ev.PasteEvent paste => paste.text,
    _ => '',
  };

  static String _encodeKeyEvent(ev.KeyEvent event) => switch (event.type) {
    ev.KeyType.character => _encodeCharacterKey(event),
    ev.KeyType.up => '\x1b[A',
    ev.KeyType.down => '\x1b[B',
    ev.KeyType.right => '\x1b[C',
    ev.KeyType.left => '\x1b[D',
    ev.KeyType.enter => '\r',
    ev.KeyType.backspace => '\x7f',
    ev.KeyType.tab
        when event.modifiers.contains(ev.Modifier.shift) ||
            event.key == 'backtab' =>
      '\x1b[Z',
    ev.KeyType.tab => '\t',
    ev.KeyType.escape => '\x1b',
    ev.KeyType.home => '\x1b[H',
    ev.KeyType.end => '\x1b[F',
    ev.KeyType.pageUp => '\x1b[5~',
    ev.KeyType.pageDown => '\x1b[6~',
    ev.KeyType.delete => '\x1b[3~',
    ev.KeyType.insert => '\x1b[2~',
    ev.KeyType.f1 => '\x1bOP',
    ev.KeyType.f2 => '\x1bOQ',
    ev.KeyType.f3 => '\x1bOR',
    ev.KeyType.f4 => '\x1bOS',
    ev.KeyType.f5 => '\x1b[15~',
    ev.KeyType.f6 => '\x1b[17~',
    ev.KeyType.f7 => '\x1b[18~',
    ev.KeyType.f8 => '\x1b[19~',
    ev.KeyType.f9 => '\x1b[20~',
    ev.KeyType.f10 => '\x1b[21~',
    ev.KeyType.f11 => '\x1b[23~',
    ev.KeyType.f12 => '\x1b[24~',
  };

  static String _encodeCharacterKey(ev.KeyEvent event) {
    var out = event.key;
    if (event.modifiers.contains(ev.Modifier.control) && out.length == 1) {
      out = _encodeControlChar(out) ?? out;
    }
    if (event.modifiers.contains(ev.Modifier.alt) && out.isNotEmpty) {
      return '\x1b$out';
    }
    return out;
  }

  static String? _encodeControlChar(String char) {
    final code = char.codeUnitAt(0);
    if (code >= 97 && code <= 122) return String.fromCharCode(code - 96);
    if (code >= 65 && code <= 90) return String.fromCharCode(code - 64);
    return switch (char) {
      '@' || '2' || ' ' => '\x00',
      '[' => '\x1b',
      r'\' => '\x1c',
      ']' => '\x1d',
      '^' || '6' => '\x1e',
      '_' || '-' || '/' => '\x1f',
      '?' => '\x7f',
      _ => null,
    };
  }

  static String _encodeMouseEvent(ev.MouseEvent event) {
    if (event.x < 1 || event.y < 1) return '';

    var cb = switch (event.button) {
      ev.MouseButton.left => 0,
      ev.MouseButton.middle => 1,
      ev.MouseButton.right => 2,
      ev.MouseButton.none => 3,
      ev.MouseButton.wheelUp => 64,
      ev.MouseButton.wheelDown => 65,
    };

    if (event.type == ev.MouseEventType.move ||
        event.type == ev.MouseEventType.drag) {
      cb |= 32;
    }
    if (event.modifiers.contains(ev.Modifier.shift)) cb |= 4;
    if (event.modifiers.contains(ev.Modifier.alt) ||
        event.modifiers.contains(ev.Modifier.meta)) {
      cb |= 8;
    }
    if (event.modifiers.contains(ev.Modifier.control)) cb |= 16;

    final release = event.type == ev.MouseEventType.release ? 'm' : 'M';
    return '\x1b[<$cb;${event.x};${event.y}$release';
  }
}
