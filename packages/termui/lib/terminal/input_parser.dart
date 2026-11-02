import 'dart:convert';
import 'package:characters/characters.dart';
import 'event.dart';

/// A reactive input parser that converts byte streams from stdin into high-level
/// [InputEvent]s. It handles standard ASCII, CSI escape sequences (including Alt shortcuts,
/// arrow keys, functional keys), SGR/X10 mouse protocols, bracketed paste, and focus events.
class InputParser {
  /// Maximum buffered bytes retained in a single bracketed paste chunk (1 MiB).
  static const int maxPasteBytes = 1024 * 1024;

  /// Maximum length of a single CSI escape sequence before discarding as malformed.
  static const int maxCsiBytes = 256;

  static final RegExp _sgrMouseRegex = RegExp(
    r'^\x1b\[<(\d+);(\d+);(\d+)[Mm]$',
  );

  final List<int> _buffer = [];
  bool _isPasting = false;
  bool _pasteFlushed = false;
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
    var offset = 0;

    while (offset < _buffer.length) {
      final step = _isPasting
          ? _consumeBracketedPaste(offset, events)
          : _buffer[offset] == 27
          ? _consumeEscapeSequence(offset, events)
          : _consumeNonEscapeByte(offset, events);
      offset = step.offset;
      if (step.stop) break;
    }

    if (offset > 0) {
      _buffer.removeRange(0, offset);
    }

    return events;
  }

  ({int offset, bool stop}) _consumeBracketedPaste(
    int offset,
    List<InputEvent> events,
  ) {
    final endIdx = _findPasteEnd(offset);
    if (endIdx == -1) {
      final remaining = _buffer.length - offset;
      final safeLength = remaining >= 6 ? remaining - 5 : 0;
      if (safeLength > 0) {
        _appendPasteSlice(offset, offset + safeLength, events);
      }
      return (offset: offset + safeLength, stop: true);
    }

    _appendPasteSlice(offset, endIdx, events);
    if (_pasteBuffer.isNotEmpty || !_pasteFlushed) {
      events.add(PasteEvent(utf8.decode(_pasteBuffer, allowMalformed: true)));
      _pasteBuffer.clear();
    }
    _isPasting = false;
    _pasteFlushed = false;
    return (offset: endIdx + 6, stop: false);
  }

  int _findPasteEnd(int offset) {
    // End of bracketed paste: \x1b[201~ (bytes: 27, 91, 50, 48, 49, 126)
    for (var i = offset; i <= _buffer.length - 6; i++) {
      if (_buffer[i] == 27 &&
          _buffer[i + 1] == 91 &&
          _buffer[i + 2] == 50 &&
          _buffer[i + 3] == 48 &&
          _buffer[i + 4] == 49 &&
          _buffer[i + 5] == 126) {
        return i;
      }
    }
    return -1;
  }

  void _appendPasteSlice(int start, int end, List<InputEvent> events) {
    var cur = start;
    while (cur < end) {
      final space = maxPasteBytes - _pasteBuffer.length;
      final take = (end - cur) < space ? (end - cur) : space;
      _pasteBuffer.addAll(_buffer.getRange(cur, cur + take));
      cur += take;
      if (_pasteBuffer.length >= maxPasteBytes) {
        events.add(PasteEvent(utf8.decode(_pasteBuffer, allowMalformed: true)));
        _pasteBuffer.clear();
        _pasteFlushed = true;
      }
    }
  }

  ({int offset, bool stop}) _consumeNonEscapeByte(
    int offset,
    List<InputEvent> events,
  ) {
    final b = _buffer[offset];
    if (b >= 0x80) {
      return _consumeUtf8Sequence(offset, events);
    }
    if (b == 8 || b == 127) {
      events.add(_decodeBackspace(b));
      return (offset: offset + 1, stop: false);
    }
    final event = switch (b) {
      9 => const KeyEvent('\t', KeyType.tab),
      10 || 13 => const KeyEvent('\n', KeyType.enter),
      >= 1 && <= 26 => KeyEvent(
        String.fromCharCode(b + 96),
        KeyType.character,
        modifiers: const {Modifier.control},
      ),
      _ => KeyEvent(String.fromCharCode(b), KeyType.character),
    };
    events.add(event);
    return (offset: offset + 1, stop: false);
  }

  KeyEvent _decodeBackspace(int byte) {
    if (!_backspaceDetected) {
      _backspaceIs8 = (byte == 8);
      _backspaceDetected = true;
    }
    final expected = _backspaceIs8 ? 8 : 127;
    if (byte == expected) {
      return const KeyEvent('backspace', KeyType.backspace);
    }
    return const KeyEvent(
      'backspace',
      KeyType.backspace,
      modifiers: {Modifier.control},
    );
  }

  ({int offset, bool stop}) _consumeUtf8Sequence(
    int offset,
    List<InputEvent> events,
  ) {
    var utf8End = offset;
    var incomplete = false;
    while (utf8End < _buffer.length && _buffer[utf8End] >= 0x80) {
      final seqLen = _utf8ByteLength(_buffer[utf8End]);
      if (utf8End + seqLen > _buffer.length) {
        incomplete = true;
        break;
      }
      utf8End += seqLen;
    }
    if (utf8End > offset) {
      final decoded = utf8.decode(
        _buffer.sublist(offset, utf8End),
        allowMalformed: true,
      );
      for (final grapheme in decoded.characters) {
        events.add(KeyEvent(grapheme, KeyType.character));
      }
    }
    return (offset: utf8End, stop: incomplete);
  }

  static int _utf8ByteLength(int lead) {
    if ((lead & 0xE0) == 0xC0) return 2;
    if ((lead & 0xF0) == 0xE0) return 3;
    if ((lead & 0xF8) == 0xF0) return 4;
    return 1;
  }

  ({int offset, bool stop}) _consumeEscapeSequence(
    int offset,
    List<InputEvent> events,
  ) {
    final remaining = _buffer.length - offset;
    if (remaining == 1) {
      // Since TTY delivers full sequences together, a single ESC means standalone ESC.
      events.add(const KeyEvent('escape', KeyType.escape));
      return (offset: offset + 1, stop: true);
    }

    final second = _buffer[offset + 1];
    if (second == 91) {
      return _consumeCsiSequence(offset, events);
    }
    if (second == 79) {
      return _consumeSs3Sequence(offset, events);
    }

    events.add(
      KeyEvent(
        String.fromCharCode(second),
        KeyType.character,
        modifiers: const {Modifier.alt},
      ),
    );
    return (offset: offset + 2, stop: false);
  }

  ({int offset, bool stop}) _consumeSs3Sequence(
    int offset,
    List<InputEvent> events,
  ) {
    final remaining = _buffer.length - offset;
    if (remaining == 2) {
      events.add(
        const KeyEvent('O', KeyType.character, modifiers: {Modifier.alt}),
      );
      return (offset: offset + 2, stop: true);
    }
    events.add(_parseSs3Key(_buffer[offset + 2]));
    return (offset: offset + 3, stop: false);
  }

  ({int offset, bool stop}) _consumeCsiSequence(
    int offset,
    List<InputEvent> events,
  ) {
    final remaining = _buffer.length - offset;
    if (remaining == 2) {
      events.add(
        const KeyEvent('[', KeyType.character, modifiers: {Modifier.alt}),
      );
      return (offset: offset + 2, stop: true);
    }

    final scanIdx = _scanCsiBody(offset + 2);
    if (scanIdx >= _buffer.length) {
      // Incomplete CSI: discard if it exceeds maxCsiBytes, otherwise wait for more bytes.
      return remaining > maxCsiBytes
          ? (offset: _buffer.length, stop: false)
          : (offset: offset, stop: true);
    }

    final termByte = _buffer[scanIdx];
    if (termByte < 0x40 || termByte > 0x7E) {
      // Aborted CSI (e.g. interrupted by a new ESC or control byte): discard prefix.
      return (offset: scanIdx, stop: false);
    }

    if (scanIdx - offset + 1 > maxCsiBytes) {
      // Oversized/runaway CSI sequence: discard through its terminator.
      return (offset: scanIdx + 1, stop: false);
    }

    return _dispatchCompleteCsi(offset, scanIdx, termByte, events);
  }

  int _scanCsiBody(int start) {
    var i = start;
    while (i < _buffer.length && _buffer[i] >= 0x20 && _buffer[i] <= 0x3F) {
      i++;
    }
    return i;
  }

  ({int offset, bool stop}) _dispatchCompleteCsi(
    int offset,
    int termIdx,
    int termByte,
    List<InputEvent> events,
  ) {
    final seqStr = String.fromCharCodes(_buffer.getRange(offset, termIdx + 1));
    if (seqStr.startsWith('\x1b[<')) {
      final mouseEvent = _parseSgrMouse(seqStr, termByte);
      if (mouseEvent != null) events.add(mouseEvent);
      return (offset: termIdx + 1, stop: false);
    }
    if (seqStr.startsWith('\x1b[M')) {
      if (_buffer.length - offset < 6) {
        return (offset: offset, stop: true);
      }
      events.add(_parseX10Mouse(_buffer.sublist(offset + 3, offset + 6)));
      return (offset: offset + 6, stop: false);
    }
    final csiEvent = _parseCsiKey(seqStr, termByte);
    if (csiEvent != null) events.add(csiEvent);
    return (offset: termIdx + 1, stop: false);
  }

  MouseEvent? _parseSgrMouse(String seq, int termByte) {
    final match = _sgrMouseRegex.firstMatch(seq);
    if (match == null) return null;

    final btnVal = int.parse(match.group(1)!);
    final x = int.parse(match.group(2)!);
    final y = int.parse(match.group(3)!);

    final mods = _decodeMouseModifiers(btnVal);
    if ((btnVal & 64) != 0) {
      final wheel = (btnVal & 1) == 0
          ? MouseButton.wheelUp
          : MouseButton.wheelDown;
      return MouseEvent(
        x: x,
        y: y,
        button: wheel,
        type: MouseEventType.press,
        modifiers: mods,
      );
    }

    final button = _decodeMouseButton(btnVal & 3);
    final isDrag = (btnVal & 32) != 0;
    final type = _decodeSgrMouseType(termByte, button, isDrag);
    return MouseEvent(x: x, y: y, button: button, type: type, modifiers: mods);
  }

  static Set<Modifier> _decodeMouseModifiers(int btnVal) => {
    if ((btnVal & 4) != 0) Modifier.shift,
    if ((btnVal & 8) != 0) Modifier.alt,
    if ((btnVal & 16) != 0) Modifier.control,
  };

  static MouseButton _decodeMouseButton(int btnCode) => switch (btnCode) {
    0 => MouseButton.left,
    1 => MouseButton.middle,
    2 => MouseButton.right,
    _ => MouseButton.none,
  };

  static MouseEventType _decodeSgrMouseType(
    int termByte,
    MouseButton button,
    bool isDrag,
  ) {
    if (termByte == 109) return MouseEventType.release;
    if (button == MouseButton.none) return MouseEventType.move;
    if (isDrag) return MouseEventType.drag;
    return MouseEventType.press;
  }

  MouseEvent _parseX10Mouse(List<int> bytes) {
    final buttonVal = bytes[0] - 32;
    final x = bytes[1] - 32;
    final y = bytes[2] - 32;

    final mods = _decodeMouseModifiers(buttonVal);
    if ((buttonVal & 64) != 0) {
      final wheel = (buttonVal & 1) == 0
          ? MouseButton.wheelUp
          : MouseButton.wheelDown;
      return MouseEvent(
        x: x,
        y: y,
        button: wheel,
        type: MouseEventType.press,
        modifiers: mods,
      );
    }

    final btnCode = buttonVal & 3;
    final button = _decodeMouseButton(btnCode);
    final isDrag = (buttonVal & 32) != 0;
    final type = switch (btnCode) {
      3 => MouseEventType.release,
      _ when isDrag => MouseEventType.drag,
      _ => MouseEventType.press,
    };

    return MouseEvent(x: x, y: y, button: button, type: type, modifiers: mods);
  }

  InputEvent? _parseCsiKey(String seq, int termByte) {
    final paramsStr = seq.substring(2, seq.length - 1);
    if (paramsStr.isNotEmpty) {
      final prefix = paramsStr.codeUnitAt(0);
      // Ignore DEC/Kitty private/device CSI responses ('<', '=', '>', '?').
      if (prefix >= 0x3C && prefix <= 0x3F) {
        return null;
      }
    }

    final params = [
      if (paramsStr.isNotEmpty)
        for (final p in paramsStr.split(';'))
          int.tryParse(p.split(':').first) ?? 1,
    ];
    final mods = _decodeCsiModifiers(params);

    return switch (termByte) {
      90 => KeyEvent(
        'backtab',
        KeyType.tab,
        modifiers: mods.isEmpty ? const {Modifier.shift} : mods,
      ),
      73 => const FocusInEvent(),
      79 => const FocusOutEvent(),
      65 => KeyEvent('up', KeyType.up, modifiers: mods),
      66 => KeyEvent('down', KeyType.down, modifiers: mods),
      67 => KeyEvent('right', KeyType.right, modifiers: mods),
      68 => KeyEvent('left', KeyType.left, modifiers: mods),
      72 => KeyEvent('home', KeyType.home, modifiers: mods),
      70 => KeyEvent('end', KeyType.end, modifiers: mods),
      82 => _parseCursorPositionReport(seq, params),
      117 => _parseKittyKey(seq, params, mods),
      126 => _parseCsiTildeKey(seq, params, mods),
      _ => KeyEvent(seq, KeyType.character),
    };
  }

  static Set<Modifier> _decodeCsiModifiers(List<int> params) {
    if (params.length < 2) return <Modifier>{};
    final modVal = params[1] - 1;
    return {
      if ((modVal & 1) != 0) Modifier.shift,
      if ((modVal & 2) != 0) Modifier.alt,
      if ((modVal & 4) != 0) Modifier.control,
      if ((modVal & 8) != 0) Modifier.meta,
    };
  }

  static InputEvent _parseCursorPositionReport(String seq, List<int> params) {
    if (params.length >= 2) {
      return CursorPositionReportEvent(params[1], params[0]);
    }
    return KeyEvent(seq, KeyType.character);
  }

  static InputEvent _parseKittyKey(
    String seq,
    List<int> params,
    Set<Modifier> mods,
  ) {
    if (params.isNotEmpty && (params[0] == 127 || params[0] == 8)) {
      return KeyEvent('backspace', KeyType.backspace, modifiers: mods);
    }
    return KeyEvent(seq, KeyType.character);
  }

  InputEvent? _parseCsiTildeKey(
    String seq,
    List<int> params,
    Set<Modifier> mods,
  ) {
    if (params.isEmpty) return const KeyEvent('~', KeyType.character);
    final keyNum = params[0];
    if (keyNum == 200) {
      _isPasting = true;
      _pasteFlushed = false;
      _pasteBuffer.clear();
      return null;
    }
    final mapped = _tildeKeyMap[keyNum];
    if (mapped != null) {
      return KeyEvent(mapped.$1, mapped.$2, modifiers: mods);
    }
    return KeyEvent(seq, KeyType.character);
  }

  static const Map<int, (String, KeyType)> _tildeKeyMap = {
    1: ('home', KeyType.home),
    2: ('insert', KeyType.insert),
    3: ('delete', KeyType.delete),
    4: ('end', KeyType.end),
    5: ('pageUp', KeyType.pageUp),
    6: ('pageDown', KeyType.pageDown),
    7: ('home', KeyType.home),
    8: ('end', KeyType.end),
    11: ('f1', KeyType.f1),
    12: ('f2', KeyType.f2),
    13: ('f3', KeyType.f3),
    14: ('f4', KeyType.f4),
    15: ('f5', KeyType.f5),
    17: ('f6', KeyType.f6),
    18: ('f7', KeyType.f7),
    19: ('f8', KeyType.f8),
    20: ('f9', KeyType.f9),
    21: ('f10', KeyType.f10),
    23: ('f11', KeyType.f11),
    24: ('f12', KeyType.f12),
    127: ('backspace', KeyType.backspace),
  };

  InputEvent _parseSs3Key(int term) => switch (term) {
    80 => const KeyEvent('f1', KeyType.f1),
    81 => const KeyEvent('f2', KeyType.f2),
    82 => const KeyEvent('f3', KeyType.f3),
    83 => const KeyEvent('f4', KeyType.f4),
    _ => KeyEvent(String.fromCharCode(term), KeyType.character),
  };
}
