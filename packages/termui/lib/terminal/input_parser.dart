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

  static const int _maxOscBytes = 1_400_000;
  static const int _maxApcBytes = 1_400_000;

  static final RegExp _sgrMouseRegex = RegExp(
    r'^\x1b\[<(\d+);(\d+);(\d+)[Mm]$',
  );
  static final RegExp _whitespaceRegex = RegExp(r'\s+');
  static final RegExp _kittyIdRegex = RegExp(r'i=(\d+)');

  final List<int> _buffer = [];
  bool _isPasting = false;
  bool _pasteFlushed = false;
  final List<int> _pasteBuffer = [];
  bool _isReadingOsc = false;
  bool _oscOverflowed = false;
  final List<int> _oscBuffer = [];
  bool _isReadingApc = false;
  bool _apcOverflowed = false;
  final List<int> _apcBuffer = [];

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
      final step = _consumeStep(offset, events);
      offset = step.offset;
      if (step.stop) break;
    }

    if (offset > 0) {
      _buffer.removeRange(0, offset);
    }

    return events;
  }

  ({int offset, bool stop}) _consumeStep(int offset, List<InputEvent> events) {
    if (_isPasting) return _consumeBracketedPaste(offset, events);
    if (_isReadingOsc) return _consumeOscSequence(offset, events);
    if (_isReadingApc) return _consumeApcSequence(offset, events);
    if (_buffer[offset] == 27) return _consumeEscapeSequence(offset, events);
    return _consumeNonEscapeByte(offset, events);
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
        final flushEnd = _safeUtf8FlushEnd(_pasteBuffer);
        events.add(
          PasteEvent(
            utf8.decode(
              _pasteBuffer.sublist(0, flushEnd),
              allowMalformed: true,
            ),
          ),
        );
        _pasteBuffer.removeRange(0, flushEnd);
        _pasteFlushed = true;
      }
    }
  }

  static int _safeUtf8FlushEnd(List<int> buf) {
    final len = buf.length;
    if (len == 0 || buf[len - 1] < 0x80) return len;
    var leadIdx = len - 1;
    while (leadIdx > 0 && len - leadIdx < 4 && (buf[leadIdx] & 0xC0) == 0x80) {
      leadIdx--;
    }
    if ((buf[leadIdx] & 0xC0) == 0x80) return len;
    final expected = _utf8ByteLength(buf[leadIdx]);
    return (len - leadIdx < expected) ? leadIdx : len;
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
    if (second == 93) {
      return _consumeOscStart(offset, events);
    }
    if (second == 0x5F) {
      return _consumeApcStart(offset, events);
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

  ({int offset, bool stop}) _consumeApcStart(
    int offset,
    List<InputEvent> events,
  ) {
    final remaining = _buffer.length - offset;
    if (remaining == 2 || _buffer[offset + 2] != 0x47) {
      events.add(
        const KeyEvent('_', KeyType.character, modifiers: {Modifier.alt}),
      );
      return (offset: offset + 2, stop: false);
    }
    _isReadingApc = true;
    _apcOverflowed = false;
    _apcBuffer.clear();
    return (offset: offset + 2, stop: false);
  }

  ({int offset, bool stop}) _consumeApcSequence(
    int offset,
    List<InputEvent> events,
  ) {
    for (var i = offset; i < _buffer.length; i++) {
      final b = _buffer[i];
      if (b == 0x07) {
        _finishApc(events);
        return (offset: i + 1, stop: false);
      }
      if (b == 0x18 || b == 0x1A) {
        _resetApc();
        return (offset: i + 1, stop: false);
      }
      if (b == 0x1B) {
        return _handleApcEscape(i, events);
      }
      _appendApcByte(b);
    }
    return (offset: _buffer.length, stop: true);
  }

  ({int offset, bool stop}) _handleApcEscape(
    int escIndex,
    List<InputEvent> events,
  ) {
    if (escIndex + 1 >= _buffer.length) {
      return (offset: escIndex, stop: true);
    }
    if (_buffer[escIndex + 1] == 0x5C) {
      _finishApc(events);
      return (offset: escIndex + 2, stop: false);
    }
    _resetApc();
    return (offset: escIndex, stop: false);
  }

  void _appendApcByte(int byte) {
    if (_apcOverflowed) return;
    if (_apcBuffer.length < _maxApcBytes) {
      _apcBuffer.add(byte);
    } else {
      _apcBuffer.clear();
      _apcOverflowed = true;
    }
  }

  void _finishApc(List<InputEvent> events) {
    if (!_apcOverflowed) {
      _dispatchApcPayload(_apcBuffer, events);
    }
    _resetApc();
  }

  void _resetApc() {
    _isReadingApc = false;
    _apcOverflowed = false;
    _apcBuffer.clear();
  }

  void _dispatchApcPayload(List<int> bytes, List<InputEvent> events) {
    final payload = String.fromCharCodes(bytes);
    if (!payload.startsWith('G') && !payload.startsWith('_G')) return;
    // Expected format: Gi=<id>;<status> or G<key>=<val>...;<status>
    final semi = payload.indexOf(';');
    final controlPart = semi >= 0 ? payload.substring(0, semi) : payload;
    final statusPart = semi >= 0 ? payload.substring(semi + 1) : '';

    final idMatch = _kittyIdRegex.firstMatch(controlPart);
    final imageId = idMatch != null ? int.tryParse(idMatch.group(1)!) : null;

    if (imageId != null || statusPart.isNotEmpty) {
      events.add(
        KittyGraphicsEvent(
          imageId: imageId ?? 0,
          supported: statusPart.toUpperCase() == 'OK',
          message: statusPart,
        ),
      );
    }
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
      if (prefix >= 0x3C && prefix <= 0x3F) {
        return _parsePrivateCsi(paramsStr, prefix, termByte);
      }
    }
    if (termByte == 117) return _parseKittyKey(seq, paramsStr);

    final params = _parseCsiMainParams(paramsStr);
    final mods = _decodeCsiModifiers(params);
    final evType = _extractCsiEventType(paramsStr);

    return switch (termByte) {
      90 => KeyEvent(
        'backtab',
        KeyType.tab,
        modifiers: mods.isEmpty ? const {Modifier.shift} : mods,
        eventType: evType,
      ),
      73 => const FocusInEvent(),
      79 => const FocusOutEvent(),
      65 => KeyEvent('up', KeyType.up, modifiers: mods, eventType: evType),
      66 => KeyEvent('down', KeyType.down, modifiers: mods, eventType: evType),
      67 => KeyEvent(
        'right',
        KeyType.right,
        modifiers: mods,
        eventType: evType,
      ),
      68 => KeyEvent('left', KeyType.left, modifiers: mods, eventType: evType),
      72 => KeyEvent('home', KeyType.home, modifiers: mods, eventType: evType),
      70 => KeyEvent('end', KeyType.end, modifiers: mods, eventType: evType),
      80 => KeyEvent('f1', KeyType.f1, modifiers: mods, eventType: evType),
      81 => KeyEvent('f2', KeyType.f2, modifiers: mods, eventType: evType),
      83 => KeyEvent('f4', KeyType.f4, modifiers: mods, eventType: evType),
      82 => _parseRSequence(paramsStr, params, mods, evType),
      126 => _parseCsiTildeKey(seq, params, mods, evType),
      _ => KeyEvent(seq, KeyType.character),
    };
  }

  static InputEvent? _parsePrivateCsi(
    String paramsStr,
    int prefix,
    int termByte,
  ) {
    if (prefix == 0x3F && termByte == 117) {
      final rawFlags = paramsStr.substring(1).split(';').first;
      final flags = int.tryParse(rawFlags);
      if (flags != null) return KittyKeyboardEvent(flags: flags);
    }
    return null;
  }

  static List<int> _parseCsiMainParams(String paramsStr) => [
    if (paramsStr.isNotEmpty)
      for (final p in paramsStr.split(';'))
        int.tryParse(p.split(':').first) ?? 1,
  ];

  static KeyEventType _extractCsiEventType(String paramsStr) {
    if (!paramsStr.contains(':')) return KeyEventType.press;
    final parts = paramsStr.split(';');
    final target = parts.length >= 2 ? parts[1] : parts[0];
    final sub = target.split(':');
    if (sub.length < 2) return KeyEventType.press;
    return _decodeEventTypeCode(int.tryParse(sub[1]) ?? 1);
  }

  static KeyEventType _decodeEventTypeCode(int code) => switch (code) {
    2 => KeyEventType.repeat,
    3 => KeyEventType.release,
    _ => KeyEventType.press,
  };

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

  static InputEvent _parseRSequence(
    String paramsStr,
    List<int> params,
    Set<Modifier> mods,
    KeyEventType eventType,
  ) {
    if (params.length >= 2 && !paramsStr.contains(':')) {
      return CursorPositionReportEvent(params[1], params[0]);
    }
    return KeyEvent('f3', KeyType.f3, modifiers: mods, eventType: eventType);
  }

  static InputEvent _parseKittyKey(String seq, String paramsStr) {
    if (paramsStr.isEmpty) return KeyEvent(seq, KeyType.character);
    final parts = paramsStr.split(';');
    final (codepoint, shifted, baseLayout) = _parseKittyCodepoints(parts[0]);
    final (mods, eventType) = _decodeKittyModifiersAndEvent(parts);
    final (keyName, keyType) = _resolveKittyKey(codepoint);
    return KeyEvent(
      keyName,
      keyType,
      modifiers: mods,
      eventType: eventType,
      shiftedCodepoint: shifted,
      baseLayoutCodepoint: baseLayout,
    );
  }

  static (int, int?, int?) _parseKittyCodepoints(String codePart) {
    final sub = codePart.split(':');
    final codepoint = int.tryParse(sub[0]) ?? 0;
    final shifted = sub.length >= 2 && sub[1].isNotEmpty
        ? int.tryParse(sub[1])
        : null;
    final baseLayout = sub.length >= 3 && sub[2].isNotEmpty
        ? int.tryParse(sub[2])
        : null;
    return (codepoint, shifted, baseLayout);
  }

  static (Set<Modifier>, KeyEventType) _decodeKittyModifiersAndEvent(
    List<String> parts,
  ) {
    var modNum = 1;
    var eventType = KeyEventType.press;
    if (parts.length >= 2) {
      final modSub = parts[1].split(':');
      modNum = int.tryParse(modSub[0]) ?? 1;
      if (modSub.length >= 2) {
        eventType = _decodeEventTypeCode(int.tryParse(modSub[1]) ?? 1);
      }
    }
    final modVal = modNum - 1;
    final mods = <Modifier>{
      if ((modVal & 1) != 0) Modifier.shift,
      if ((modVal & 2) != 0) Modifier.alt,
      if ((modVal & 4) != 0) Modifier.control,
      if ((modVal & 8) != 0 || (modVal & 32) != 0) Modifier.meta,
    };
    return (mods, eventType);
  }

  static (String, KeyType) _resolveKittyKey(int codepoint) {
    final mapped = _kittyKeyMap[codepoint];
    if (mapped != null) return mapped;
    if (codepoint > 0) {
      return (String.fromCharCode(codepoint), KeyType.character);
    }
    return ('', KeyType.character);
  }

  static const Map<int, (String, KeyType)> _kittyKeyMap = {
    13: ('enter', KeyType.enter),
    27: ('escape', KeyType.escape),
    9: ('tab', KeyType.tab),
    127: ('backspace', KeyType.backspace),
    8: ('backspace', KeyType.backspace),
    57344: ('\x1b', KeyType.escape),
    57345: ('\r', KeyType.enter),
    57346: ('\t', KeyType.tab),
    57347: ('\x7f', KeyType.backspace),
    57348: ('', KeyType.insert),
    57349: ('', KeyType.delete),
    57350: ('', KeyType.arrowLeft),
    57351: ('', KeyType.arrowRight),
    57352: ('', KeyType.arrowUp),
    57353: ('', KeyType.arrowDown),
    57354: ('', KeyType.pageUp),
    57355: ('', KeyType.pageDown),
    57356: ('', KeyType.home),
    57357: ('', KeyType.end),
    57364: ('', KeyType.f1),
    57365: ('', KeyType.f2),
    57366: ('', KeyType.f3),
    57367: ('', KeyType.f4),
    57368: ('', KeyType.f5),
    57369: ('', KeyType.f6),
    57370: ('', KeyType.f7),
    57371: ('', KeyType.f8),
    57372: ('', KeyType.f9),
    57373: ('', KeyType.f10),
    57374: ('', KeyType.f11),
    57375: ('', KeyType.f12),
  };

  InputEvent? _parseCsiTildeKey(
    String seq,
    List<int> params,
    Set<Modifier> mods,
    KeyEventType eventType,
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
      return KeyEvent(
        mapped.$1,
        mapped.$2,
        modifiers: mods,
        eventType: eventType,
      );
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

  ({int offset, bool stop}) _consumeOscStart(
    int offset,
    List<InputEvent> events,
  ) {
    final remaining = _buffer.length - offset;
    if (remaining == 2) {
      events.add(
        const KeyEvent(']', KeyType.character, modifiers: {Modifier.alt}),
      );
      return (offset: offset + 2, stop: true);
    }
    final third = _buffer[offset + 2];
    if (third < 0x30 || third > 0x39) {
      events.add(
        const KeyEvent(']', KeyType.character, modifiers: {Modifier.alt}),
      );
      return (offset: offset + 2, stop: false);
    }
    _isReadingOsc = true;
    _oscOverflowed = false;
    _oscBuffer.clear();
    return (offset: offset + 2, stop: false);
  }

  ({int offset, bool stop}) _consumeOscSequence(
    int offset,
    List<InputEvent> events,
  ) {
    for (var i = offset; i < _buffer.length; i++) {
      final b = _buffer[i];
      if (b == 0x07) {
        _finishOsc(events);
        return (offset: i + 1, stop: false);
      }
      if (b == 0x18 || b == 0x1A) {
        _resetOsc();
        return (offset: i + 1, stop: false);
      }
      if (b == 0x1B) {
        return _handleOscEscape(i, events);
      }
      _appendOscByte(b);
    }
    return (offset: _buffer.length, stop: true);
  }

  ({int offset, bool stop}) _handleOscEscape(
    int escIndex,
    List<InputEvent> events,
  ) {
    if (escIndex + 1 >= _buffer.length) {
      return (offset: escIndex, stop: true);
    }
    if (_buffer[escIndex + 1] == 0x5C) {
      _finishOsc(events);
      return (offset: escIndex + 2, stop: false);
    }
    _resetOsc();
    return (offset: escIndex, stop: false);
  }

  void _appendOscByte(int byte) {
    if (_oscOverflowed) return;
    if (_oscBuffer.length < _maxOscBytes) {
      _oscBuffer.add(byte);
    } else {
      _oscBuffer.clear();
      _oscOverflowed = true;
    }
  }

  void _finishOsc(List<InputEvent> events) {
    if (!_oscOverflowed) {
      final paste = _decodeOsc52();
      if (paste != null) events.add(paste);
    }
    _resetOsc();
  }

  void _resetOsc() {
    _isReadingOsc = false;
    _oscOverflowed = false;
    _oscBuffer.clear();
  }

  PasteEvent? _decodeOsc52() {
    final payload = utf8.decode(_oscBuffer, allowMalformed: true);
    if (!payload.startsWith('52;')) return null;
    final semi = payload.indexOf(';', 3);
    if (semi < 0) return null;
    final cleaned = payload
        .substring(semi + 1)
        .replaceAll(_whitespaceRegex, '');
    if (cleaned.isEmpty || cleaned == '?') return null;
    try {
      final bytes = base64.decode(base64.normalize(cleaned));
      if (bytes.length > maxPasteBytes) return null;
      final text = utf8.decode(bytes, allowMalformed: true);
      if (utf8.encode(text).length > maxPasteBytes) return null;
      return PasteEvent(text);
    } on FormatException {
      return null;
    }
  }
}
