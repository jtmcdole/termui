import 'package:flutter/foundation.dart' show TargetPlatform;
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:termui/terminal/event.dart' as ev;

/// A canonicalized keyboard shortcut chord (key + modifier set) used for
/// user-configured passthrough ("ignored") shortcuts in `fterm`.
final class KeyChord {
  /// The canonical [LogicalKeyboardKey] for this chord.
  final LogicalKeyboardKey key;

  /// The unmodifiable, canonicalized modifier set for this chord, ordered
  /// deterministically as `control`, `alt`, `shift`, `meta`.
  final Set<ev.Modifier> modifiers;

  /// Creates a [KeyChord] with [key] and an unmodifiable, canonicalized copy of
  /// [modifiers].
  factory KeyChord({
    required LogicalKeyboardKey key,
    required Set<ev.Modifier> modifiers,
  }) => KeyChord._(key: key, modifiers: _canonicalModifierSet(modifiers));

  const KeyChord._({required this.key, required this.modifiers});

  static const List<Set<ev.Modifier>> _canonicalModifierSets = [
    <ev.Modifier>{},
    <ev.Modifier>{.control},
    <ev.Modifier>{.alt},
    <ev.Modifier>{.control, .alt},
    <ev.Modifier>{.shift},
    <ev.Modifier>{.control, .shift},
    <ev.Modifier>{.alt, .shift},
    <ev.Modifier>{.control, .alt, .shift},
    <ev.Modifier>{.meta},
    <ev.Modifier>{.control, .meta},
    <ev.Modifier>{.alt, .meta},
    <ev.Modifier>{.control, .alt, .meta},
    <ev.Modifier>{.shift, .meta},
    <ev.Modifier>{.control, .shift, .meta},
    <ev.Modifier>{.alt, .shift, .meta},
    <ev.Modifier>{.control, .alt, .shift, .meta},
  ];

  static const Map<String, ev.Modifier> _modifierAliases = {
    'ctrl': .control,
    'control': .control,
    'alt': .alt,
    'opt': .alt,
    'option': .alt,
    'shift': .shift,
    'meta': .meta,
    'cmd': .meta,
    'command': .meta,
    'super': .meta,
    'win': .meta,
    'windows': .meta,
  };

  static final Map<String, LogicalKeyboardKey> _keyAliases = {
    'a': .keyA,
    'b': .keyB,
    'c': .keyC,
    'd': .keyD,
    'e': .keyE,
    'f': .keyF,
    'g': .keyG,
    'h': .keyH,
    'i': .keyI,
    'j': .keyJ,
    'k': .keyK,
    'l': .keyL,
    'm': .keyM,
    'n': .keyN,
    'o': .keyO,
    'p': .keyP,
    'q': .keyQ,
    'r': .keyR,
    's': .keyS,
    't': .keyT,
    'u': .keyU,
    'v': .keyV,
    'w': .keyW,
    'x': .keyX,
    'y': .keyY,
    'z': .keyZ,
    '0': .digit0,
    '1': .digit1,
    '2': .digit2,
    '3': .digit3,
    '4': .digit4,
    '5': .digit5,
    '6': .digit6,
    '7': .digit7,
    '8': .digit8,
    '9': .digit9,
    'f1': .f1,
    'f2': .f2,
    'f3': .f3,
    'f4': .f4,
    'f5': .f5,
    'f6': .f6,
    'f7': .f7,
    'f8': .f8,
    'f9': .f9,
    'f10': .f10,
    'f11': .f11,
    'f12': .f12,
    'arrowleft': .arrowLeft,
    'left': .arrowLeft,
    'arrowright': .arrowRight,
    'right': .arrowRight,
    'arrowup': .arrowUp,
    'up': .arrowUp,
    'arrowdown': .arrowDown,
    'down': .arrowDown,
    'tab': .tab,
    'space': .space,
    'enter': .enter,
    'return': .enter,
    'escape': .escape,
    'esc': .escape,
    'backspace': .backspace,
    'delete': .delete,
    'del': .delete,
    'insert': .insert,
    'ins': .insert,
    'home': .home,
    'end': .end,
    'pageup': .pageUp,
    'pgup': .pageUp,
    'pagedown': .pageDown,
    'pgdn': .pageDown,
    'equal': .equal,
    '=': .equal,
    'plus': .equal,
    '+': .equal,
    'minus': .minus,
    '-': .minus,
    'comma': .comma,
    ',': .comma,
    'period': .period,
    '.': .period,
    'slash': .slash,
    '/': .slash,
    'backslash': .backslash,
    r'\': .backslash,
    'bracketleft': .bracketLeft,
    '[': .bracketLeft,
    'bracketright': .bracketRight,
    ']': .bracketRight,
    'backquote': .backquote,
    '`': .backquote,
    'semicolon': .semicolon,
    ';': .semicolon,
    'quote': .quoteSingle,
    "'": .quoteSingle,
  };

  static final Map<LogicalKeyboardKey, String> _canonicalKeyNames = {
    .keyA: 'A',
    .keyB: 'B',
    .keyC: 'C',
    .keyD: 'D',
    .keyE: 'E',
    .keyF: 'F',
    .keyG: 'G',
    .keyH: 'H',
    .keyI: 'I',
    .keyJ: 'J',
    .keyK: 'K',
    .keyL: 'L',
    .keyM: 'M',
    .keyN: 'N',
    .keyO: 'O',
    .keyP: 'P',
    .keyQ: 'Q',
    .keyR: 'R',
    .keyS: 'S',
    .keyT: 'T',
    .keyU: 'U',
    .keyV: 'V',
    .keyW: 'W',
    .keyX: 'X',
    .keyY: 'Y',
    .keyZ: 'Z',
    .digit0: '0',
    .digit1: '1',
    .digit2: '2',
    .digit3: '3',
    .digit4: '4',
    .digit5: '5',
    .digit6: '6',
    .digit7: '7',
    .digit8: '8',
    .digit9: '9',
    .f1: 'F1',
    .f2: 'F2',
    .f3: 'F3',
    .f4: 'F4',
    .f5: 'F5',
    .f6: 'F6',
    .f7: 'F7',
    .f8: 'F8',
    .f9: 'F9',
    .f10: 'F10',
    .f11: 'F11',
    .f12: 'F12',
    .arrowLeft: 'ArrowLeft',
    .arrowRight: 'ArrowRight',
    .arrowUp: 'ArrowUp',
    .arrowDown: 'ArrowDown',
    .tab: 'Tab',
    .space: 'Space',
    .enter: 'Enter',
    .escape: 'Escape',
    .backspace: 'Backspace',
    .delete: 'Delete',
    .insert: 'Insert',
    .home: 'Home',
    .end: 'End',
    .pageUp: 'PageUp',
    .pageDown: 'PageDown',
    .equal: 'Equal',
    .minus: 'Minus',
    .comma: 'Comma',
    .period: 'Period',
    .slash: 'Slash',
    .backslash: 'Backslash',
    .bracketLeft: 'BracketLeft',
    .bracketRight: 'BracketRight',
    .backquote: 'Backquote',
    .semicolon: 'Semicolon',
    .quoteSingle: 'Quote',
  };

  static final Set<LogicalKeyboardKey> _shiftSafeKeys = {
    .f1,
    .f2,
    .f3,
    .f4,
    .f5,
    .f6,
    .f7,
    .f8,
    .f9,
    .f10,
    .f11,
    .f12,
    .arrowLeft,
    .arrowRight,
    .arrowUp,
    .arrowDown,
    .tab,
    .enter,
    .escape,
    .backspace,
    .delete,
    .insert,
    .home,
    .end,
    .pageUp,
    .pageDown,
  };

  static final Map<LogicalKeyboardKey, LogicalKeyboardKey> _keyNormalizations =
      {
        .numpad0: .digit0,
        .numpad1: .digit1,
        .numpad2: .digit2,
        .numpad3: .digit3,
        .numpad4: .digit4,
        .numpad5: .digit5,
        .numpad6: .digit6,
        .numpad7: .digit7,
        .numpad8: .digit8,
        .numpad9: .digit9,
        .numpadEnter: .enter,
        .add: .equal,
        .numpadAdd: .equal,
        .numpadSubtract: .minus,
        .numpadDecimal: .period,
        .numpadDivide: .slash,
        .quote: .quoteSingle,
      };

  static final Set<LogicalKeyboardKey> _tabDigitKeys = {
    .digit1,
    .digit2,
    .digit3,
    .digit4,
    .digit5,
    .digit6,
    .digit7,
    .digit8,
    .digit9,
  };

  /// Parses a `+`-delimited shortcut specification such as `Ctrl+Shift+I`,
  /// `Cmd+ArrowLeft`, or `Ctrl++`.
  ///
  /// Returns `null` when [raw] is empty, malformed, contains unknown or
  /// multiple non-modifier keys, omits a key, or fails the safe-modifier
  /// guardrail (unmodified keys and `Shift+<printable>` are rejected so typing
  /// cannot be broken).
  static KeyChord? tryParse(String raw) {
    final tokens = _tokenize(raw);
    if (tokens == null) return null;

    final modifiers = <ev.Modifier>{};
    LogicalKeyboardKey? key;
    for (final token in tokens) {
      final lower = token.toLowerCase();
      final mod = _modifierAliases[lower];
      if (mod != null) {
        modifiers.add(mod);
        continue;
      }
      final parsedKey = _keyAliases[lower];
      if (parsedKey == null || key != null) return null;
      key = parsedKey;
    }

    if (key == null || !_hasSafeModifiers(key, modifiers)) return null;
    return KeyChord._(key: key, modifiers: _canonicalModifierSet(modifiers));
  }

  /// Creates a [KeyChord] from a live key event capture (such as the Settings
  /// UI "Record chord" control), normalizing numpad variants and rejecting
  /// standalone modifiers, unsupported keys, and unsafe modifier combinations.
  static KeyChord? fromKeyEvent(
    LogicalKeyboardKey key,
    Set<ev.Modifier> modifiers,
  ) {
    final normalized = _keyNormalizations[key] ?? key;
    if (!_canonicalKeyNames.containsKey(normalized)) return null;
    if (!_hasSafeModifiers(normalized, modifiers)) return null;
    return KeyChord._(
      key: normalized,
      modifiers: _canonicalModifierSet(modifiers),
    );
  }

  /// Parses and deduplicates [rawEntries] in order, returning valid [KeyChord]s
  /// alongside any raw entries that failed [tryParse].
  static ({List<KeyChord> chords, List<String> invalid}) parseAll(
    Iterable<String> rawEntries,
  ) {
    final seen = <KeyChord>{};
    final chords = <KeyChord>[];
    final invalid = <String>[];
    for (final raw in rawEntries) {
      final parsed = tryParse(raw);
      if (parsed == null) {
        invalid.add(raw);
      } else if (seen.add(parsed)) {
        chords.add(parsed);
      }
    }
    return (chords: chords, invalid: invalid);
  }

  /// Returns `true` when [chord] overlaps a built-in `fterm` shortcut on the
  /// given [platform] and web/desktop target ([isWeb]).
  static bool collidesWithBuiltinShortcut(
    KeyChord chord, {
    required TargetPlatform platform,
    required bool isWeb,
  }) {
    if (_isUniversalBuiltin(chord) || _isFontZoomBuiltin(chord, platform)) {
      return true;
    }
    if (isWeb) return false;
    return _isDesktopBuiltin(chord, platform);
  }

  /// Returns `true` when [key] and [mods] match this chord exactly.
  ///
  /// Designed for O(1), allocation-free checks on the hot key-handling path.
  bool matches(LogicalKeyboardKey key, Set<ev.Modifier> mods) =>
      this.key == key &&
      modifiers.length == mods.length &&
      modifiers.containsAll(mods);

  /// Formats this chord in canonical `Ctrl+Alt+Shift+Meta+<Key>` order.
  ///
  /// Every valid [KeyChord] satisfies
  /// `KeyChord.tryParse(chord.toCanonicalString()) == chord`.
  String toCanonicalString() => _format(altLabel: 'Alt', metaLabel: 'Meta');

  /// Formats this chord with platform-appropriate modifier labels for UI
  /// display (for example `Cmd`/`Option` on macOS, `Win` on Windows, and
  /// `Super` on Linux).
  String toDisplayString({required TargetPlatform platform}) {
    final (altLabel, metaLabel) = switch (platform) {
      .macOS || .iOS => ('Option', 'Cmd'),
      .windows => ('Alt', 'Win'),
      .linux => ('Alt', 'Super'),
      .android || .fuchsia => ('Alt', 'Meta'),
    };
    return _format(altLabel: altLabel, metaLabel: metaLabel);
  }

  String _format({required String altLabel, required String metaLabel}) {
    final keyLabel =
        _canonicalKeyNames[key] ??
        (key.keyLabel.isNotEmpty
            ? key.keyLabel
            : 'Key(0x${key.keyId.toRadixString(16)})');
    if (modifiers.isEmpty) return keyLabel;
    final parts = <String>[
      if (modifiers.contains(ev.Modifier.control)) 'Ctrl',
      if (modifiers.contains(ev.Modifier.alt)) altLabel,
      if (modifiers.contains(ev.Modifier.shift)) 'Shift',
      if (modifiers.contains(ev.Modifier.meta)) metaLabel,
      keyLabel,
    ];
    return parts.join('+');
  }

  static Set<ev.Modifier> _canonicalModifierSet(Set<ev.Modifier> mods) {
    var mask = 0;
    if (mods.contains(ev.Modifier.control)) mask |= 1;
    if (mods.contains(ev.Modifier.alt)) mask |= 2;
    if (mods.contains(ev.Modifier.shift)) mask |= 4;
    if (mods.contains(ev.Modifier.meta)) mask |= 8;
    return _canonicalModifierSets[mask];
  }

  static List<String>? _tokenize(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return null;

    var source = trimmed;
    var hasTrailingPlusKey = false;
    if (source.endsWith('+')) {
      final beforeTrailing = source.substring(0, source.length - 1).trimRight();
      if (!beforeTrailing.endsWith('+')) return null;
      source = beforeTrailing.substring(0, beforeTrailing.length - 1);
      if (source.trim().isEmpty) return null;
      hasTrailingPlusKey = true;
    }

    final parts = source.split('+');
    final tokens = <String>[];
    for (final part in parts) {
      final token = part.trim();
      if (token.isEmpty) return null;
      tokens.add(token);
    }
    if (hasTrailingPlusKey) {
      tokens.add('+');
    }
    return tokens;
  }

  static bool _hasSafeModifiers(
    LogicalKeyboardKey key,
    Set<ev.Modifier> modifiers,
  ) {
    if (modifiers.isEmpty) return false;
    if (modifiers.contains(ev.Modifier.control) ||
        modifiers.contains(ev.Modifier.alt) ||
        modifiers.contains(ev.Modifier.meta)) {
      return true;
    }
    return _shiftSafeKeys.contains(key);
  }

  static bool _hasExactMods(
    Set<ev.Modifier> actual,
    Set<ev.Modifier> expected,
  ) => actual.length == expected.length && actual.containsAll(expected);

  static bool _isUniversalBuiltin(KeyChord chord) {
    final mods = chord.modifiers;
    if (chord.key == .backslash && _hasExactMods(mods, const {.control})) {
      return true;
    }
    if (chord.key == .f12 &&
        (mods.isEmpty || _hasExactMods(mods, const {.shift}))) {
      return true;
    }
    return _isClipboardBuiltin(chord);
  }

  static bool _isClipboardBuiltin(KeyChord chord) {
    final mods = chord.modifiers;
    return switch (chord.key) {
      .keyC =>
        _hasExactMods(mods, const {.meta}) ||
            _hasExactMods(mods, const {.control, .shift}),
      .keyV =>
        _hasExactMods(mods, const {.meta}) ||
            _hasExactMods(mods, const {.meta, .shift}) ||
            _hasExactMods(mods, const {.control, .shift}),
      .insert =>
        _hasExactMods(mods, const {.control}) ||
            _hasExactMods(mods, const {.shift}),
      _ => false,
    };
  }

  static bool _isFontZoomBuiltin(KeyChord chord, TargetPlatform platform) {
    final mods = chord.modifiers;
    final baseMods = platform == .macOS
        ? const <ev.Modifier>{.meta}
        : const <ev.Modifier>{.control};
    final shiftMods = platform == .macOS
        ? const <ev.Modifier>{.meta, .shift}
        : const <ev.Modifier>{.control, .shift};
    if (_hasExactMods(mods, baseMods)) {
      return chord.key == .equal || chord.key == .minus || chord.key == .digit0;
    }
    return chord.key == .equal && _hasExactMods(mods, shiftMods);
  }

  static bool _isDesktopBuiltin(KeyChord chord, TargetPlatform platform) {
    final key = chord.key;
    final mods = chord.modifiers;
    if (_hasExactMods(mods, const {.control, .shift}) &&
        (key == .f5 || key == .f9 || key == .f10)) {
      return true;
    }
    return switch (platform) {
      .macOS => _isMacDesktopBuiltin(key, mods),
      .linux || .windows => _isLinuxWindowsDesktopBuiltin(key, mods),
      _ => false,
    };
  }

  static bool _isMacDesktopBuiltin(
    LogicalKeyboardKey key,
    Set<ev.Modifier> mods,
  ) {
    if (_hasExactMods(mods, const {.meta, .shift})) {
      return key == .keyD;
    }
    if (!_hasExactMods(mods, const {.meta})) return false;
    return _tabDigitKeys.contains(key) ||
        key == .keyT ||
        key == .keyW ||
        key == .keyD ||
        key == .comma;
  }

  static bool _isLinuxWindowsDesktopBuiltin(
    LogicalKeyboardKey key,
    Set<ev.Modifier> mods,
  ) {
    if (!_hasExactMods(mods, const {.control, .shift})) return false;
    return _tabDigitKeys.contains(key) ||
        key == .keyT ||
        key == .keyW ||
        key == .keyD ||
        key == .keyE ||
        key == .comma;
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is KeyChord &&
          other.key == key &&
          identical(other.modifiers, modifiers));

  @override
  int get hashCode => Object.hash(key, modifiers);

  @override
  String toString() => 'KeyChord(${toCanonicalString()})';
}
