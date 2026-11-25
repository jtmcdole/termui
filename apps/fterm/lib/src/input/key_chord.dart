import 'package:flutter/foundation.dart' show TargetPlatform;
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:termui/terminal/event.dart' as ev;

typedef _KeyTable = ({
  Map<String, LogicalKeyboardKey> aliases,
  Map<LogicalKeyboardKey, String> names,
  Set<LogicalKeyboardKey> shiftSafe,
  Map<LogicalKeyboardKey, LogicalKeyboardKey> norm,
});

/// Canonicalized keyboard shortcut chord (key + modifier set) for `fterm`
/// passthrough ("ignored") shortcuts.
final class KeyChord {
  /// Canonical [LogicalKeyboardKey] for this chord.
  final LogicalKeyboardKey key;

  /// Unmodifiable, canonicalized modifier set (`control`, `alt`, `shift`, `meta`).
  final Set<ev.Modifier> modifiers;

  /// Creates a [KeyChord] with [key] and a canonicalized copy of [modifiers].
  factory KeyChord({
    required LogicalKeyboardKey key,
    required Set<ev.Modifier> modifiers,
  }) => KeyChord._(key: key, modifiers: _canonicalModifierSet(modifiers));

  const KeyChord._({required this.key, required this.modifiers});

  static ev.Modifier? _parseModifier(String token) => switch (token) {
    'ctrl' || 'control' => .control,
    'alt' || 'opt' || 'option' => .alt,
    'shift' => .shift,
    'meta' || 'cmd' || 'command' || 'super' || 'win' || 'windows' => .meta,
    _ => null,
  };

  static const _functionalSpecs = <(LogicalKeyboardKey, String, List<String>)>[
    (.arrowLeft, 'ArrowLeft', ['left']),
    (.arrowRight, 'ArrowRight', ['right']),
    (.arrowUp, 'ArrowUp', ['up']),
    (.arrowDown, 'ArrowDown', ['down']),
    (.tab, 'Tab', []),
    (.enter, 'Enter', ['return']),
    (.escape, 'Escape', ['esc']),
    (.backspace, 'Backspace', []),
    (.delete, 'Delete', ['del']),
    (.insert, 'Insert', ['ins']),
    (.home, 'Home', []),
    (.end, 'End', []),
    (.pageUp, 'PageUp', ['pgup']),
    (.pageDown, 'PageDown', ['pgdn']),
  ];

  static const _printableSpecs = <(LogicalKeyboardKey, String, List<String>)>[
    (.space, 'Space', []),
    (.equal, 'Equal', ['=', 'plus', '+']),
    (.minus, 'Minus', ['-']),
    (.comma, 'Comma', [',']),
    (.period, 'Period', ['.']),
    (.slash, 'Slash', ['/']),
    (.backslash, 'Backslash', [r'\']),
    (.bracketLeft, 'BracketLeft', ['[']),
    (.bracketRight, 'BracketRight', [']']),
    (.backquote, 'Backquote', ['`']),
    (.semicolon, 'Semicolon', [';']),
    (.quoteSingle, 'Quote', ["'"]),
  ];

  static final _KeyTable _table = _buildKeyTable();

  static LogicalKeyboardKey _keyAt(LogicalKeyboardKey base, int offset) =>
      LogicalKeyboardKey.findKeyByKeyId(base.keyId + offset)!;

  static _KeyTable _buildKeyTable() {
    final aliases = <String, LogicalKeyboardKey>{};
    final names = <LogicalKeyboardKey, String>{};
    final shiftSafe = <LogicalKeyboardKey>{};
    final norm = <LogicalKeyboardKey, LogicalKeyboardKey>{
      for (var i = 0; i < 10; i++) _keyAt(.numpad0, i): _keyAt(.digit0, i),
      .numpadEnter: .enter,
      .add: .equal,
      .numpadAdd: .equal,
      .numpadSubtract: .minus,
      .numpadDecimal: .period,
      .numpadDivide: .slash,
      .quote: .quoteSingle,
    };

    void add(
      LogicalKeyboardKey k,
      String n, [
      List<String> ex = const [],
      bool safe = false,
    ]) {
      names[k] = n;
      aliases[n.toLowerCase()] = k;
      for (final a in ex) {
        aliases[a] = k;
      }
      if (safe) shiftSafe.add(k);
    }

    final upperA = 'A'.codeUnitAt(0);
    for (var i = 0; i < 26; i++) {
      add(_keyAt(.keyA, i), String.fromCharCode(upperA + i));
    }
    for (var i = 0; i < 10; i++) {
      add(_keyAt(.digit0, i), '$i');
    }
    for (var i = 0; i < 12; i++) {
      add(_keyAt(.f1, i), 'F${i + 1}', const [], true);
    }
    for (final (k, name, extra) in _functionalSpecs) {
      add(k, name, extra, true);
    }
    for (final (k, name, extra) in _printableSpecs) {
      add(k, name, extra);
    }
    return (aliases: aliases, names: names, shiftSafe: shiftSafe, norm: norm);
  }

  /// Parses a `+`-delimited shortcut (`Ctrl+Shift+I`, `Ctrl++`), returning
  /// `null` when malformed or rejected by the safe-modifier guardrail.
  static KeyChord? tryParse(String raw) {
    final tokens = _tokenize(raw);
    if (tokens == null) return null;
    final mods = <ev.Modifier>{};
    LogicalKeyboardKey? key;
    for (final token in tokens) {
      final lower = token.toLowerCase();
      if (_parseModifier(lower) case final mod?) {
        mods.add(mod);
        continue;
      }
      final parsedKey = _table.aliases[lower];
      if (parsedKey == null || key != null) return null;
      key = parsedKey;
    }
    return key != null && _hasSafeModifiers(key, mods)
        ? KeyChord._(key: key, modifiers: _canonicalModifierSet(mods))
        : null;
  }

  /// Creates a [KeyChord] from a live key event, normalizing numpad/symbol keys
  /// and rejecting standalone modifiers or unsafe modifier combinations.
  static KeyChord? fromKeyEvent(LogicalKeyboardKey key, Set<ev.Modifier> mods) {
    final k = _table.norm[key] ?? key;
    return _table.names.containsKey(k) && _hasSafeModifiers(k, mods)
        ? KeyChord._(key: k, modifiers: _canonicalModifierSet(mods))
        : null;
  }

  /// Parses and deduplicates [rawEntries] in order, returning valid chords and
  /// any entries that failed [tryParse].
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

  /// Returns `true` when [key] and [mods] match this chord exactly.
  bool matches(LogicalKeyboardKey key, Set<ev.Modifier> mods) =>
      this.key == key &&
      modifiers.length == mods.length &&
      modifiers.containsAll(mods);

  /// Formats this chord in canonical `Ctrl+Alt+Shift+Meta+<Key>` order.
  String toCanonicalString() => _format('Alt', 'Meta');

  /// Formats this chord with platform-appropriate modifier labels.
  String toDisplayString({required TargetPlatform platform}) =>
      switch (platform) {
        .macOS || .iOS => _format('Option', 'Cmd'),
        .windows => _format('Alt', 'Win'),
        .linux => _format('Alt', 'Super'),
        .android || .fuchsia => _format('Alt', 'Meta'),
      };

  String _format(String altLabel, String metaLabel) {
    final label =
        _table.names[key] ??
        (key.keyLabel.isNotEmpty
            ? key.keyLabel
            : 'Key(0x${key.keyId.toRadixString(16)})');
    if (modifiers.isEmpty) return label;
    return [
      if (modifiers.contains(ev.Modifier.control)) 'Ctrl',
      if (modifiers.contains(ev.Modifier.alt)) altLabel,
      if (modifiers.contains(ev.Modifier.shift)) 'Shift',
      if (modifiers.contains(ev.Modifier.meta)) metaLabel,
      label,
    ].join('+');
  }

  static Set<ev.Modifier> _canonicalModifierSet(Set<ev.Modifier> m) =>
      Set<ev.Modifier>.unmodifiable({
        if (m.contains(ev.Modifier.control)) ev.Modifier.control,
        if (m.contains(ev.Modifier.alt)) ev.Modifier.alt,
        if (m.contains(ev.Modifier.shift)) ev.Modifier.shift,
        if (m.contains(ev.Modifier.meta)) ev.Modifier.meta,
      });

  static List<String>? _tokenize(String raw) {
    var source = raw.trim();
    if (source.isEmpty) return null;
    var hasTrailingPlus = false;
    if (source.endsWith('+')) {
      final before = source.substring(0, source.length - 1).trimRight();
      if (!before.endsWith('+')) return null;
      source = before.substring(0, before.length - 1);
      if (source.trim().isEmpty) return null;
      hasTrailingPlus = true;
    }
    final tokens = <String>[];
    for (final part in source.split('+')) {
      final token = part.trim();
      if (token.isEmpty) return null;
      tokens.add(token);
    }
    if (hasTrailingPlus) tokens.add('+');
    return tokens;
  }

  static bool _hasSafeModifiers(LogicalKeyboardKey k, Set<ev.Modifier> m) =>
      m.isNotEmpty &&
      (m.contains(ev.Modifier.control) ||
          m.contains(ev.Modifier.alt) ||
          m.contains(ev.Modifier.meta) ||
          _table.shiftSafe.contains(k));

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is KeyChord && matches(other.key, other.modifiers));

  @override
  int get hashCode => Object.hash(key, Object.hashAll(modifiers));

  @override
  String toString() => 'KeyChord(${toCanonicalString()})';
}
