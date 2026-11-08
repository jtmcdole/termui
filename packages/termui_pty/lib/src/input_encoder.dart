import 'package:termui/terminal/event.dart' as ev;

typedef _KittyFlags = ({
  bool disambiguate,
  bool reportEvents,
  bool reportAlternates,
  bool reportAll,
  bool reportText,
});

/// Encodes high-level `termui` [ev.InputEvent] objects into raw ANSI/VT100 byte strings.
/// These strings can be written to a PTY's `write()` method.
abstract final class InputEncoder {
  // matches c0 controls (except \t, \n, \r), del (0x7f), and c1 controls (0x80-0x9f).
  static final RegExp _unsafePasteControls = RegExp(
    r'[\x00-\x08\x0B\x0C\x0E-\x1F\x7F-\x9F]',
  );

  /// Encodes a single event into an ANSI string.
  static String encode(
    ev.InputEvent event, {
    bool bracketedPaste = false,
    bool applicationCursorKeys = false,
    bool sgrMouse = true,
    bool sgrPixels = false,
    int kittyKeyboardFlags = 0,
    int? pixelX,
    int? pixelY,
  }) => switch (event) {
    ev.KeyEvent key => _encodeKeyRoot(
      key,
      applicationCursorKeys: applicationCursorKeys,
      kittyKeyboardFlags: kittyKeyboardFlags,
    ),
    ev.MouseEvent mouse => _encodeMouseEvent(
      mouse,
      sgrMouse: sgrMouse,
      sgrPixels: sgrPixels,
      pixelX: pixelX,
      pixelY: pixelY,
    ),
    ev.PasteEvent paste => _encodePasteEvent(
      paste,
      bracketedPaste: bracketedPaste,
    ),
    _ => '',
  };

  static String _encodeKeyRoot(
    ev.KeyEvent key, {
    required bool applicationCursorKeys,
    required int kittyKeyboardFlags,
  }) {
    if (key.eventType == ev.KeyEventType.release &&
        (kittyKeyboardFlags & 2) == 0) {
      return '';
    }
    return _encodeKittyKeyEvent(key, kittyKeyboardFlags) ??
        (applicationCursorKeys && key.modifiers.isEmpty
            ? _encodeApplicationCursorKey(key.type)
            : null) ??
        _encodeKeyEvent(key);
  }

  /// Encodes terminal focus-in (`\x1b[I`) or focus-out (`\x1b[O`) events for
  /// `DECSET 1004` focus reporting mode.
  static String encodeFocus({required bool focused}) =>
      focused ? '\x1b[I' : '\x1b[O';

  /// Encodes mouse wheel events for Alternate Scroll mode (`DECSET 1007`).
  static String encodeAlternateScroll(
    ev.MouseButton button, {
    int lines = 1,
    bool applicationCursorKeys = false,
  }) {
    if (lines <= 0) return '';
    final seq = switch ((button, applicationCursorKeys)) {
      (ev.MouseButton.wheelUp, true) => '\x1bOA',
      (ev.MouseButton.wheelUp, false) => '\x1b[A',
      (ev.MouseButton.wheelDown, true) => '\x1bOB',
      (ev.MouseButton.wheelDown, false) => '\x1b[B',
      _ => '',
    };
    return seq.isEmpty ? '' : seq * lines;
  }

  static String _encodePasteEvent(
    ev.PasteEvent event, {
    required bool bracketedPaste,
  }) {
    if (!bracketedPaste) return event.text;
    var safe = event.text.replaceAll('\x9b', '\x1b[');
    while (safe.contains('\x1b[201~') || safe.contains('\x1b[200~')) {
      safe = safe.replaceAll('\x1b[201~', '').replaceAll('\x1b[200~', '');
    }
    safe = safe.replaceAll(_unsafePasteControls, '');
    return '\x1b[200~$safe\x1b[201~';
  }

  static String? _encodeApplicationCursorKey(ev.KeyType type) => switch (type) {
    ev.KeyType.up => '\x1bOA',
    ev.KeyType.down => '\x1bOB',
    ev.KeyType.right => '\x1bOC',
    ev.KeyType.left => '\x1bOD',
    ev.KeyType.home => '\x1bOH',
    ev.KeyType.end => '\x1bOF',
    _ => null,
  };

  static _KittyFlags _parseKittyFlags(int rawFlags) {
    final flags = rawFlags & 0x1F;
    return (
      disambiguate: (flags & 1) != 0,
      reportEvents: (flags & 2) != 0,
      reportAlternates: (flags & 4) != 0,
      reportAll: (flags & 8) != 0,
      reportText: (flags & 16) != 0,
    );
  }

  static String? _encodeKittyKeyEvent(ev.KeyEvent key, int rawFlags) {
    if ((rawFlags & 0x1F) == 0) return null;
    final kf = _parseKittyFlags(rawFlags);
    final modBits = _encodeKittyModifierBits(key);
    final modParam = 1 + modBits;
    final hasEventSub =
        kf.reportEvents && key.eventType != ev.KeyEventType.press;
    final evNum = key.eventType == ev.KeyEventType.repeat ? 2 : 3;
    final modAndEvent = hasEventSub ? '$modParam:$evNum' : '$modParam';

    if (_letterFunctionalFinal(key.type) case final ch?) {
      return _encodeKittyLetterFunctional(
        key.type,
        ch,
        kf: kf,
        modParam: modParam,
        hasEventSub: hasEventSub,
        modAndEvent: modAndEvent,
      );
    }
    if (_tildeFunctionalCode(key.type) case final code?) {
      return _encodeKittyTildeFunctional(
        key.type,
        code,
        kf: kf,
        modParam: modParam,
        hasEventSub: hasEventSub,
        modAndEvent: modAndEvent,
      );
    }
    if (_specialCsiUCode(key.type) case final code?) {
      return _encodeKittySpecialCsiU(
        key.type,
        code,
        kf: kf,
        modBits: modBits,
        modParam: modParam,
        hasEventSub: hasEventSub,
        modAndEvent: modAndEvent,
      );
    }
    if (key.type == ev.KeyType.character) {
      return _encodeKittyCharacterKey(
        key,
        kf: kf,
        modBits: modBits,
        modParam: modParam,
        hasEventSub: hasEventSub,
        modAndEvent: modAndEvent,
      );
    }
    return null;
  }

  static String? _letterFunctionalFinal(ev.KeyType type) => switch (type) {
    ev.KeyType.up => 'A',
    ev.KeyType.down => 'B',
    ev.KeyType.right => 'C',
    ev.KeyType.left => 'D',
    ev.KeyType.home => 'H',
    ev.KeyType.end => 'F',
    ev.KeyType.f1 => 'P',
    ev.KeyType.f2 => 'Q',
    ev.KeyType.f4 => 'S',
    _ => null,
  };

  static int? _tildeFunctionalCode(ev.KeyType type) => switch (type) {
    ev.KeyType.insert => 2,
    ev.KeyType.delete => 3,
    ev.KeyType.pageUp => 5,
    ev.KeyType.pageDown => 6,
    ev.KeyType.f3 => 13,
    ev.KeyType.f5 => 15,
    ev.KeyType.f6 => 17,
    ev.KeyType.f7 => 18,
    ev.KeyType.f8 => 19,
    ev.KeyType.f9 => 20,
    ev.KeyType.f10 => 21,
    ev.KeyType.f11 => 23,
    ev.KeyType.f12 => 24,
    _ => null,
  };

  static int? _specialCsiUCode(ev.KeyType type) => switch (type) {
    ev.KeyType.escape => 27,
    ev.KeyType.enter => 13,
    ev.KeyType.tab => 9,
    ev.KeyType.backspace => 127,
    _ => null,
  };

  static bool _isSs3FunctionKey(ev.KeyType type) =>
      type == ev.KeyType.f1 || type == ev.KeyType.f2 || type == ev.KeyType.f4;

  static String? _encodeKittyLetterFunctional(
    ev.KeyType type,
    String ch, {
    required _KittyFlags kf,
    required int modParam,
    required bool hasEventSub,
    required String modAndEvent,
  }) {
    if (modParam > 1 || hasEventSub) {
      return '\x1b[1;$modAndEvent$ch';
    }
    if (_isSs3FunctionKey(type)) {
      return (kf.disambiguate || kf.reportAll) ? '\x1b[$ch' : null;
    }
    return kf.reportAll ? '\x1b[$ch' : null;
  }

  static String? _encodeKittyTildeFunctional(
    ev.KeyType type,
    int code, {
    required _KittyFlags kf,
    required int modParam,
    required bool hasEventSub,
    required String modAndEvent,
  }) {
    if (modParam > 1 || hasEventSub) {
      return '\x1b[$code;$modAndEvent~';
    }
    if (type == ev.KeyType.f3) {
      return (kf.disambiguate || kf.reportAll) ? '\x1b[13~' : null;
    }
    return '\x1b[$code~';
  }

  static String? _encodeKittySpecialCsiU(
    ev.KeyType type,
    int code, {
    required _KittyFlags kf,
    required int modBits,
    required int modParam,
    required bool hasEventSub,
    required String modAndEvent,
  }) {
    if (type == ev.KeyType.escape) {
      final encodeEsc =
          kf.disambiguate || kf.reportAll || modBits != 0 || hasEventSub;
      if (!encodeEsc) return null;
      return (modParam == 1 && !hasEventSub)
          ? '\x1b[27u'
          : '\x1b[27;${modAndEvent}u';
    }
    if (modBits == 0 && !kf.reportAll && !hasEventSub) {
      return null;
    }
    if (!kf.disambiguate && !kf.reportAll && !hasEventSub) {
      return null;
    }
    return (modParam == 1 && !hasEventSub)
        ? '\x1b[${code}u'
        : '\x1b[$code;${modAndEvent}u';
  }

  static String? _encodeKittyCharacterKey(
    ev.KeyEvent key, {
    required _KittyFlags kf,
    required int modBits,
    required int modParam,
    required bool hasEventSub,
    required String modAndEvent,
  }) {
    if (key.key.isEmpty) return null;
    final codePart = _formatCharacterCodePart(
      key,
      reportAlternates: kf.reportAlternates,
    );
    final hasNonShiftMod = (modBits & ~1) != 0;

    if (!kf.reportAll) {
      if (!hasNonShiftMod) {
        return hasEventSub ? '\x1b[$codePart;${modAndEvent}u' : null;
      }
      if (kf.disambiguate || hasEventSub) {
        return '\x1b[$codePart;${modAndEvent}u';
      }
      return null;
    }

    if (kf.reportText &&
        !hasNonShiftMod &&
        key.eventType != ev.KeyEventType.release) {
      final textPart = key.key.runes.join(':');
      return '\x1b[$codePart;$modAndEvent;${textPart}u';
    }
    return (modParam == 1 && !hasEventSub)
        ? '\x1b[${codePart}u'
        : '\x1b[$codePart;${modAndEvent}u';
  }

  static String _formatCharacterCodePart(
    ev.KeyEvent key, {
    required bool reportAlternates,
  }) {
    final rune = key.key.runes.first;
    final isShifted = key.modifiers.contains(ev.Modifier.shift);
    final isAsciiUpper =
        isShifted && key.key.length == 1 && rune >= 65 && rune <= 90;
    final baseCodepoint = isAsciiUpper ? rune + 32 : rune;
    if (!reportAlternates) return '$baseCodepoint';

    final rawShifted = isAsciiUpper
        ? (key.shiftedCodepoint ?? rune)
        : (isShifted ? key.shiftedCodepoint : null);
    final shifted = (rawShifted != null && rawShifted != baseCodepoint)
        ? rawShifted
        : null;
    final rawBase = key.baseLayoutCodepoint;
    final baseLayout = (rawBase != null && rawBase != baseCodepoint)
        ? rawBase
        : null;

    return switch ((shifted, baseLayout)) {
      (final s?, final b?) => '$baseCodepoint:$s:$b',
      (final s?, null) => '$baseCodepoint:$s',
      (null, final b?) => '$baseCodepoint::$b',
      (null, null) => '$baseCodepoint',
    };
  }

  static int _encodeKittyModifierBits(ev.KeyEvent key) {
    var modBits = 0;
    if (key.modifiers.contains(ev.Modifier.shift) ||
        (key.type == ev.KeyType.tab && key.key == 'backtab')) {
      modBits |= 1;
    }
    if (key.modifiers.contains(ev.Modifier.alt)) modBits |= 2;
    if (key.modifiers.contains(ev.Modifier.control)) modBits |= 4;
    if (key.modifiers.contains(ev.Modifier.meta)) modBits |= 8;
    return modBits;
  }

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
    if (event.modifiers.contains(ev.Modifier.meta)) {
      return '';
    }
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

  static bool _isNonPressWheel(ev.MouseEvent event) =>
      (event.button == ev.MouseButton.wheelUp ||
          event.button == ev.MouseButton.wheelDown) &&
      event.type != ev.MouseEventType.press;

  static String _encodeMouseEvent(
    ev.MouseEvent event, {
    bool sgrMouse = true,
    bool sgrPixels = false,
    int? pixelX,
    int? pixelY,
  }) {
    final resolvedPx = pixelX ?? event.pixelX;
    final resolvedPy = pixelY ?? event.pixelY;
    final targetX = sgrPixels ? (resolvedPx ?? event.x) : event.x;
    final targetY = sgrPixels ? (resolvedPy ?? event.y) : event.y;
    if (targetX < 1 || targetY < 1 || _isNonPressWheel(event)) return '';

    final cb = _encodeMouseButtonBits(event);
    if (!sgrMouse && !sgrPixels) return _encodeX10Mouse(event, cb);

    final release = event.type == ev.MouseEventType.release ? 'm' : 'M';
    return '\x1b[<$cb;$targetX;$targetY$release';
  }

  static int _encodeMouseButtonBits(ev.MouseEvent event) {
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
    return cb;
  }

  static String _encodeX10Mouse(ev.MouseEvent event, int cb) {
    if (event.x > 223 ||
        event.y > 223 ||
        event.type == ev.MouseEventType.move) {
      return '';
    }
    final wireCb = event.type == ev.MouseEventType.release
        ? (cb & ~0x03) | 3
        : cb;
    return String.fromCharCodes([
      0x1B,
      0x5B,
      0x4D,
      32 + wireCb,
      32 + event.x,
      32 + event.y,
    ]);
  }
}
