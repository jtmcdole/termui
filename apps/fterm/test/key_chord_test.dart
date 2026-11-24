import 'package:flutter/foundation.dart' show TargetPlatform;
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:fterm/src/input/key_chord.dart';

LogicalKeyboardKey _keyAt(LogicalKeyboardKey base, int i) =>
    LogicalKeyboardKey.findKeyByKeyId(base.keyId + i)!;

void main() {
  group('KeyChord.tryParse', () {
    test('normalizes modifier aliases, key aliases, whitespace, and order', () {
      const pairs = {
        'ctrl+shift+i': 'Ctrl+Shift+I',
        'CONTROL + alt + shift + cmd + a': 'Ctrl+Alt+Shift+Meta+A',
        'Option+Command+Left': 'Alt+Meta+ArrowLeft',
        'opt+win+right': 'Alt+Meta+ArrowRight',
        'Super+Windows+Ctrl+Ctrl+Up': 'Ctrl+Meta+ArrowUp',
        'Shift+Ctrl+Down': 'Ctrl+Shift+ArrowDown',
        'meta+return': 'Meta+Enter',
        'ctrl+esc': 'Ctrl+Escape',
        'alt+del': 'Alt+Delete',
        'shift+ins': 'Shift+Insert',
        'ctrl+pgup': 'Ctrl+PageUp',
        'ctrl+pgdn': 'Ctrl+PageDown',
        'Ctrl++': 'Ctrl+Equal',
        'Ctrl + +': 'Ctrl+Equal',
        'Ctrl+Plus': 'Ctrl+Equal',
        'Ctrl+=': 'Ctrl+Equal',
        'Ctrl+Shift++': 'Ctrl+Shift+Equal',
        'Ctrl+-': 'Ctrl+Minus',
        'Meta+,': 'Meta+Comma',
        'Ctrl+.': 'Ctrl+Period',
        'Ctrl+/': 'Ctrl+Slash',
        r'Ctrl+\': 'Ctrl+Backslash',
        'Ctrl+[': 'Ctrl+BracketLeft',
        'Ctrl+]': 'Ctrl+BracketRight',
        'Ctrl+`': 'Ctrl+Backquote',
        'Ctrl+;': 'Ctrl+Semicolon',
        "Ctrl+'": 'Ctrl+Quote',
      };
      for (final MapEntry(:key, :value) in pairs.entries) {
        expect(KeyChord.tryParse(key)?.toCanonicalString(), equals(value));
      }
    });

    test('enforces safe-modifier guardrail and rejects malformed specs', () {
      final rejected = [
        '',
        '   ',
        'Ctrl+ + +',
        ...'|+|++|Ctrl+|+A|Ctrl++A|Ctrl|Ctrl+Shift|A|F12|Escape|Shift+A|Shift+0'
                '|Shift+Space|Shift+=|Shift+/|Ctrl+A+B|Ctrl+UnknownKey'
            .split('|'),
      ];
      for (final raw in rejected) {
        expect(KeyChord.tryParse(raw), isNull, reason: 'raw="$raw"');
      }
      const shiftSafe =
          'F1 F12 ArrowLeft Tab Enter Escape Backspace Delete Insert Home End '
          'PageUp PageDown';
      for (final key in shiftSafe.split(' ')) {
        expect(KeyChord.tryParse('Shift+$key'), isNotNull, reason: key);
      }
    });

    test('round-trips all 74 supported keys losslessly', () {
      final rangeKeys = [
        for (var i = 0; i < 26; i++)
          (_keyAt(.keyA, i), String.fromCharCode(65 + i)),
        for (var i = 0; i < 10; i++) (_keyAt(.digit0, i), '$i'),
        for (var i = 0; i < 12; i++) (_keyAt(.f1, i), 'F${i + 1}'),
      ];
      expect(rangeKeys[25].$1, equals(LogicalKeyboardKey.keyZ));
      expect(rangeKeys[35].$1, equals(LogicalKeyboardKey.digit9));
      expect(rangeKeys[47].$1, equals(LogicalKeyboardKey.f12));
      for (final (key, name) in rangeKeys) {
        final chord = KeyChord(key: key, modifiers: const {.control});
        expect(chord.toCanonicalString(), equals('Ctrl+$name'));
        expect(KeyChord.tryParse('Ctrl+$name'), equals(chord));
      }

      const specials =
          'ArrowLeft ArrowRight ArrowUp ArrowDown Tab Space Enter Escape '
          'Backspace Delete Insert Home End PageUp PageDown Equal Minus Comma '
          'Period Slash Backslash BracketLeft BracketRight Backquote Semicolon '
          'Quote';
      final specialNames = specials.split(' ');
      expect(rangeKeys.length + specialNames.length, equals(74));
      for (final name in specialNames) {
        final parsed = KeyChord.tryParse('Ctrl+$name')!;
        expect(parsed.toCanonicalString(), equals('Ctrl+$name'));
        expect(
          KeyChord(key: parsed.key, modifiers: const {.control}),
          equals(parsed),
        );
      }
    });
  });

  group('KeyChord.fromKeyEvent, matches, display, and parseAll', () {
    test('normalizes numpad/symbol keys and rejects unsafe input', () {
      final pairs = <(LogicalKeyboardKey, LogicalKeyboardKey)>[
        for (var i = 0; i < 10; i++) (_keyAt(.numpad0, i), _keyAt(.digit0, i)),
        (.numpadEnter, .enter),
        (.add, .equal),
        (.numpadAdd, .equal),
        (.numpadSubtract, .minus),
        (.numpadDecimal, .period),
        (.numpadDivide, .slash),
        (.quote, .quoteSingle),
      ];
      for (final (rawKey, expectedKey) in pairs) {
        expect(
          KeyChord.fromKeyEvent(rawKey, const {.control}),
          equals(KeyChord(key: expectedKey, modifiers: const {.control})),
        );
      }
      expect(KeyChord.fromKeyEvent(.controlLeft, const {.control}), isNull);
      expect(KeyChord.fromKeyEvent(.capsLock, const {.control}), isNull);
      expect(KeyChord.fromKeyEvent(.keyA, const {}), isNull);
      expect(KeyChord.fromKeyEvent(.keyA, const {.shift}), isNull);
      expect(
        KeyChord.fromKeyEvent(.f12, const {.shift}),
        equals(KeyChord(key: .f12, modifiers: const {.shift})),
      );
    });

    test(
      'matches, value semantics, unmodifiable mods, and fallback labels',
      () {
        final a = KeyChord(key: .keyI, modifiers: {.shift, .control});
        final b = KeyChord.tryParse('ctrl+shift+i')!;
        expect(a, equals(b));
        expect(a.hashCode, equals(b.hashCode));
        expect(a.toString(), equals('KeyChord(Ctrl+Shift+I)'));
        expect(() => a.modifiers.add(.meta), throwsUnsupportedError);
        expect(a.matches(.keyI, const {.control, .shift}), isTrue);
        expect(a.matches(.keyI, const {.control}), isFalse);
        expect(a.matches(.keyK, const {.control, .shift}), isFalse);
        expect(
          KeyChord(key: .f12, modifiers: const {}).toCanonicalString(),
          'F12',
        );
        expect(
          KeyChord(
            key: .exclamation,
            modifiers: const {.alt},
          ).toCanonicalString(),
          'Alt+!',
        );
        expect(
          KeyChord(
            key: const LogicalKeyboardKey(0x00100000099),
            modifiers: const {},
          ).toCanonicalString(),
          'Key(0x100000099)',
        );
      },
    );

    test('toDisplayString formats platform labels for all TargetPlatforms', () {
      final chord = KeyChord.tryParse('Ctrl+Alt+Shift+Meta+ArrowLeft')!;
      const expected = {
        TargetPlatform.macOS: 'Ctrl+Option+Shift+Cmd+ArrowLeft',
        TargetPlatform.iOS: 'Ctrl+Option+Shift+Cmd+ArrowLeft',
        TargetPlatform.windows: 'Ctrl+Alt+Shift+Win+ArrowLeft',
        TargetPlatform.linux: 'Ctrl+Alt+Shift+Super+ArrowLeft',
        TargetPlatform.android: 'Ctrl+Alt+Shift+Meta+ArrowLeft',
        TargetPlatform.fuchsia: 'Ctrl+Alt+Shift+Meta+ArrowLeft',
      };
      for (final MapEntry(:key, :value) in expected.entries) {
        expect(chord.toDisplayString(platform: key), equals(value));
      }
    });

    test('parseAll deduplicates in order and reports invalid entries', () {
      final res = KeyChord.parseAll(
        'shift+ctrl+i,Ctrl+Shift+I,bad,cmd+left,Meta+ArrowLeft,Shift+A,Alt+F4'
            .split(','),
      );
      expect(
        res.chords,
        equals([
          KeyChord.tryParse('Ctrl+Shift+I')!,
          KeyChord.tryParse('Meta+ArrowLeft')!,
          KeyChord.tryParse('Alt+F4')!,
        ]),
      );
      expect(res.invalid, equals(const ['bad', 'Shift+A']));
    });
  });
}
