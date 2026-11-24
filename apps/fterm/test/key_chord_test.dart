import 'package:flutter/foundation.dart' show TargetPlatform;
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:fterm/src/input/key_chord.dart';
import 'package:termui/terminal/event.dart' as ev;

const List<TargetPlatform> _desktopPlatforms = [.macOS, .linux, .windows];

void main() {
  group('KeyChord.tryParse', _registerTryParseTests);
  group('KeyChord.fromKeyEvent', _registerFromKeyEventTests);
  group('KeyChord.matches and value semantics', _registerValueSemanticsTests);
  group('KeyChord canonical round-trip property', _registerRoundTripTests);
  group('KeyChord.toDisplayString', _registerDisplayStringTests);
  group('KeyChord.collidesWithBuiltinShortcut', _registerBuiltinCollisionTests);
  group('KeyChord.parseAll', _registerParseAllTests);
}

void _registerTryParseTests() {
  test('parses all modifier aliases case-insensitively', () {
    for (final raw in const ['ctrl+a', 'Ctrl+A', 'control+a', 'CONTROL+A']) {
      expect(
        KeyChord.tryParse(raw),
        KeyChord(key: .keyA, modifiers: const {.control}),
        reason: 'Expected $raw to parse as Ctrl+A',
      );
    }

    for (final raw in const [
      'alt+a',
      'Alt+A',
      'opt+a',
      'option+a',
      'OPTION+A',
    ]) {
      expect(
        KeyChord.tryParse(raw),
        KeyChord(key: .keyA, modifiers: const {.alt}),
        reason: 'Expected $raw to parse as Alt+A',
      );
    }

    for (final raw in const [
      'meta+a',
      'Meta+A',
      'cmd+a',
      'command+a',
      'super+a',
      'win+a',
      'windows+a',
      'WINDOWS+A',
    ]) {
      expect(
        KeyChord.tryParse(raw),
        KeyChord(key: .keyA, modifiers: const {.meta}),
        reason: 'Expected $raw to parse as Meta+A',
      );
    }

    expect(
      KeyChord.tryParse('SHIFT+Tab'),
      KeyChord(key: .tab, modifiers: const {.shift}),
    );
    expect(
      KeyChord.tryParse('  Ctrl + Alt + Shift + Meta + ArrowLeft  '),
      KeyChord(
        key: .arrowLeft,
        modifiers: const {.control, .alt, .shift, .meta},
      ),
    );
    // Duplicate modifier aliases deduplicate cleanly.
    expect(
      KeyChord.tryParse('Ctrl+Control+Cmd+Meta+K'),
      KeyChord(key: .keyK, modifiers: const {.control, .meta}),
    );
  });

  test('parses all key aliases and punctuation including Ctrl++', () {
    final cases = <String, LogicalKeyboardKey>{
      'Ctrl+ArrowLeft': .arrowLeft,
      'Ctrl+Left': .arrowLeft,
      'Ctrl+ArrowRight': .arrowRight,
      'Ctrl+Right': .arrowRight,
      'Ctrl+ArrowUp': .arrowUp,
      'Ctrl+Up': .arrowUp,
      'Ctrl+ArrowDown': .arrowDown,
      'Ctrl+Down': .arrowDown,
      'Ctrl+Tab': .tab,
      'Ctrl+Space': .space,
      'Ctrl+Enter': .enter,
      'Ctrl+Return': .enter,
      'Ctrl+Escape': .escape,
      'Ctrl+Esc': .escape,
      'Ctrl+Backspace': .backspace,
      'Ctrl+Delete': .delete,
      'Ctrl+Del': .delete,
      'Ctrl+Insert': .insert,
      'Ctrl+Ins': .insert,
      'Ctrl+Home': .home,
      'Ctrl+End': .end,
      'Ctrl+PageUp': .pageUp,
      'Ctrl+PgUp': .pageUp,
      'Ctrl+PageDown': .pageDown,
      'Ctrl+PgDn': .pageDown,
      'Ctrl+Equal': .equal,
      'Ctrl+=': .equal,
      'Ctrl+Plus': .equal,
      'Ctrl++': .equal,
      'Ctrl + +': .equal,
      'Ctrl+Minus': .minus,
      'Ctrl+-': .minus,
      'Ctrl+Comma': .comma,
      'Ctrl+,': .comma,
      'Ctrl+Period': .period,
      'Ctrl+.': .period,
      'Ctrl+Slash': .slash,
      'Ctrl+/': .slash,
      'Ctrl+Backslash': .backslash,
      r'Ctrl+\': .backslash,
      'Ctrl+BracketLeft': .bracketLeft,
      'Ctrl+[': .bracketLeft,
      'Ctrl+BracketRight': .bracketRight,
      'Ctrl+]': .bracketRight,
      'Ctrl+Backquote': .backquote,
      'Ctrl+`': .backquote,
      'Ctrl+Semicolon': .semicolon,
      'Ctrl+;': .semicolon,
      'Ctrl+Quote': .quoteSingle,
      "Ctrl+'": .quoteSingle,
    };

    for (final MapEntry(:key, :value) in cases.entries) {
      expect(
        KeyChord.tryParse(key),
        KeyChord(key: value, modifiers: const {.control}),
        reason: 'Expected $key to resolve to $value',
      );
    }

    expect(
      KeyChord.tryParse('Ctrl+Shift++'),
      KeyChord(key: .equal, modifiers: const {.control, .shift}),
    );
  });

  test('accepts Shift + functional keys', () {
    const shiftSafeKeys = <String, LogicalKeyboardKey>{
      'Shift+F1': .f1,
      'Shift+F12': .f12,
      'Shift+Tab': .tab,
      'Shift+Insert': .insert,
      'Shift+Delete': .delete,
      'Shift+Home': .home,
      'Shift+End': .end,
      'Shift+PageUp': .pageUp,
      'Shift+PageDown': .pageDown,
      'Shift+ArrowLeft': .arrowLeft,
      'Shift+ArrowRight': .arrowRight,
      'Shift+ArrowUp': .arrowUp,
      'Shift+ArrowDown': .arrowDown,
      'Shift+Escape': .escape,
      'Shift+Enter': .enter,
      'Shift+Backspace': .backspace,
    };

    for (final MapEntry(:key, :value) in shiftSafeKeys.entries) {
      expect(
        KeyChord.tryParse(key),
        KeyChord(key: value, modifiers: const {.shift}),
        reason: 'Expected $key to be accepted',
      );
    }
  });

  test('rejects unsafe, malformed, bare, unknown, and multi-key chords', () {
    const rejected = [
      '',
      '   ',
      '+',
      '++',
      'Ctrl+',
      'Ctrl+++',
      'Ctrl++A',
      '+Ctrl+A',
      'Ctrl+ +A',
      'Ctrl',
      'Alt',
      'Shift',
      'Meta',
      'Ctrl+Shift',
      'Alt+Meta',
      'a',
      'A',
      '0',
      'Enter',
      'Space',
      'ArrowLeft',
      'Tab',
      'Escape',
      'F1',
      'F12',
      '=',
      'Shift+A',
      'Shift+z',
      'Shift+1',
      'Shift+Space',
      'Shift+=',
      'Shift+-',
      'Shift+,',
      'Shift+.',
      'Shift+/',
      r'Shift+\',
      'Shift+[',
      'Shift+]',
      'Shift+`',
      'Shift+;',
      "Shift+'",
      'Ctrl+Unknown',
      'Ctrl+F13',
      'Hyper+A',
      'Ctrl+A+B',
      'Alt+F1+F2',
    ];

    for (final raw in rejected) {
      expect(
        KeyChord.tryParse(raw),
        isNull,
        reason: 'Expected "$raw" to be rejected',
      );
    }
  });
}

void _registerFromKeyEventTests() {
  test('creates chords for valid key events and normalizes numpad keys', () {
    expect(
      KeyChord.fromKeyEvent(.keyI, const {.control, .shift}),
      KeyChord(key: .keyI, modifiers: const {.control, .shift}),
    );
    expect(
      KeyChord.fromKeyEvent(.insert, const {.shift}),
      KeyChord(key: .insert, modifiers: const {.shift}),
    );

    final normalized = <LogicalKeyboardKey, LogicalKeyboardKey>{
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
    for (final MapEntry(:key, :value) in normalized.entries) {
      expect(
        KeyChord.fromKeyEvent(key, const {.control}),
        KeyChord(key: value, modifiers: const {.control}),
        reason: 'Expected $key to normalize to $value',
      );
    }
  });

  test(
    'rejects standalone modifiers, unsafe modifiers, and unsupported keys',
    () {
      const standaloneModifiers = <LogicalKeyboardKey>[
        .shiftLeft,
        .shiftRight,
        .shift,
        .controlLeft,
        .controlRight,
        .control,
        .altLeft,
        .altRight,
        .alt,
        .metaLeft,
        .metaRight,
        .meta,
        .capsLock,
      ];
      for (final modKey in standaloneModifiers) {
        expect(
          KeyChord.fromKeyEvent(modKey, const {.control}),
          isNull,
          reason: 'Expected standalone modifier $modKey to be rejected',
        );
      }

      expect(KeyChord.fromKeyEvent(.keyA, const {}), isNull);
      expect(KeyChord.fromKeyEvent(.enter, const {}), isNull);
      expect(KeyChord.fromKeyEvent(.f12, const {}), isNull);

      expect(KeyChord.fromKeyEvent(.keyA, const {.shift}), isNull);
      expect(KeyChord.fromKeyEvent(.space, const {.shift}), isNull);
      expect(KeyChord.fromKeyEvent(.digit1, const {.shift}), isNull);
      expect(KeyChord.fromKeyEvent(.numpad1, const {.shift}), isNull);

      expect(KeyChord.fromKeyEvent(.f13, const {.control}), isNull);
      expect(KeyChord.fromKeyEvent(.audioVolumeUp, const {.control}), isNull);
    },
  );
}

void _registerValueSemanticsTests() {
  test('matches exact key and exact modifier set only', () {
    final chord = KeyChord.tryParse('Ctrl+Shift+I')!;
    expect(chord.matches(.keyI, const {.control, .shift}), isTrue);
    expect(chord.matches(.keyI, const {.shift, .control}), isTrue);

    expect(chord.matches(.keyI, const {.control}), isFalse);
    expect(chord.matches(.keyI, const {.control, .shift, .alt}), isFalse);
    expect(chord.matches(.keyO, const {.control, .shift}), isFalse);
    expect(chord.matches(.keyI, const {}), isFalse);
  });

  test(
    'stores unmodifiable modifiers and implements ==, hashCode, toString',
    () {
      final mutable = <ev.Modifier>{.meta, .control};
      final chord = KeyChord(key: .arrowLeft, modifiers: mutable);
      mutable.add(.alt);

      expect(chord.modifiers, const <ev.Modifier>{.control, .meta});
      expect(() => chord.modifiers.add(.shift), throwsUnsupportedError);

      final parsed = KeyChord.tryParse('Cmd+Ctrl+Left')!;
      expect(chord, equals(parsed));
      expect(chord.hashCode, equals(parsed.hashCode));
      expect(chord.toCanonicalString(), 'Ctrl+Meta+ArrowLeft');
      expect(chord.toString(), 'KeyChord(Ctrl+Meta+ArrowLeft)');

      // Formatting fallback for unmodified or unmapped keys.
      expect(
        KeyChord(key: .f12, modifiers: const {}).toCanonicalString(),
        'F12',
      );
      expect(
        KeyChord(key: .f13, modifiers: const {.control}).toCanonicalString(),
        'Ctrl+F13',
      );
      expect(
        KeyChord(
          key: const LogicalKeyboardKey(0x200000123),
          modifiers: const {.control},
        ).toCanonicalString(),
        'Ctrl+Key(0x200000123)',
      );
    },
  );
}

void _registerRoundTripTests() {
  const allLetters = <LogicalKeyboardKey>[
    .keyA,
    .keyB,
    .keyC,
    .keyD,
    .keyE,
    .keyF,
    .keyG,
    .keyH,
    .keyI,
    .keyJ,
    .keyK,
    .keyL,
    .keyM,
    .keyN,
    .keyO,
    .keyP,
    .keyQ,
    .keyR,
    .keyS,
    .keyT,
    .keyU,
    .keyV,
    .keyW,
    .keyX,
    .keyY,
    .keyZ,
  ];
  const allDigits = <LogicalKeyboardKey>[
    .digit0,
    .digit1,
    .digit2,
    .digit3,
    .digit4,
    .digit5,
    .digit6,
    .digit7,
    .digit8,
    .digit9,
  ];
  const allFunctionKeys = <LogicalKeyboardKey>[
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
  ];
  const allShiftSafeNonF = <LogicalKeyboardKey>[
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
  ];
  const allPunctuationAndSpace = <LogicalKeyboardKey>[
    .space,
    .equal,
    .minus,
    .comma,
    .period,
    .slash,
    .backslash,
    .bracketLeft,
    .bracketRight,
    .backquote,
    .semicolon,
    .quoteSingle,
  ];
  const allSupportedKeys = <LogicalKeyboardKey>[
    ...allLetters,
    ...allDigits,
    ...allFunctionKeys,
    ...allShiftSafeNonF,
    ...allPunctuationAndSpace,
  ];
  const modifierCombos = <Set<ev.Modifier>>[
    {.control},
    {.alt},
    {.meta},
    {.control, .alt},
    {.control, .shift},
    {.control, .meta},
    {.alt, .shift},
    {.alt, .meta},
    {.shift, .meta},
    {.control, .alt, .shift},
    {.control, .alt, .meta},
    {.control, .shift, .meta},
    {.alt, .shift, .meta},
    {.control, .alt, .shift, .meta},
  ];

  test(
    'every supported key and valid modifier combo round-trips losslessly',
    () {
      final shiftSafeKeys = <LogicalKeyboardKey>{
        ...allFunctionKeys,
        ...allShiftSafeNonF,
      };
      for (final key in allSupportedKeys) {
        final combos = <Set<ev.Modifier>>[
          ...modifierCombos,
          if (shiftSafeKeys.contains(key)) const {.shift},
        ];
        for (final mods in combos) {
          final chord = KeyChord.fromKeyEvent(key, mods);
          expect(
            chord,
            isNotNull,
            reason: 'Expected ($key, $mods) to produce a valid KeyChord',
          );
          final canonical = chord!.toCanonicalString();
          final reparsed = KeyChord.tryParse(canonical);
          expect(
            reparsed,
            equals(chord),
            reason: 'Round-trip failed for "$canonical"',
          );
          expect(reparsed!.toCanonicalString(), equals(canonical));
        }
      }
    },
  );

  test('orders modifiers deterministically as Ctrl+Alt+Shift+Meta', () {
    final chord = KeyChord.tryParse('Meta+Shift+Alt+Ctrl+ArrowLeft')!;
    expect(chord.toCanonicalString(), 'Ctrl+Alt+Shift+Meta+ArrowLeft');
    expect(KeyChord.tryParse('Option+F4')!.toCanonicalString(), 'Alt+F4');
    expect(KeyChord.tryParse('Cmd+=')!.toCanonicalString(), 'Meta+Equal');
  });
}

void _registerDisplayStringTests() {
  test('formats platform-friendly modifier labels', () {
    final allMods = KeyChord.tryParse('Ctrl+Alt+Shift+Meta+ArrowLeft')!;
    expect(
      allMods.toDisplayString(platform: .macOS),
      'Ctrl+Option+Shift+Cmd+ArrowLeft',
    );
    expect(
      allMods.toDisplayString(platform: .iOS),
      'Ctrl+Option+Shift+Cmd+ArrowLeft',
    );
    expect(
      allMods.toDisplayString(platform: .windows),
      'Ctrl+Alt+Shift+Win+ArrowLeft',
    );
    expect(
      allMods.toDisplayString(platform: .linux),
      'Ctrl+Alt+Shift+Super+ArrowLeft',
    );
    expect(
      allMods.toDisplayString(platform: .android),
      'Ctrl+Alt+Shift+Meta+ArrowLeft',
    );
    expect(
      allMods.toDisplayString(platform: .fuchsia),
      'Ctrl+Alt+Shift+Meta+ArrowLeft',
    );
  });
}

void _expectCollisionForAllTargets(List<KeyChord> chords, bool expected) {
  for (final chord in chords) {
    for (final platform in _desktopPlatforms) {
      for (final isWeb in const [false, true]) {
        expect(
          KeyChord.collidesWithBuiltinShortcut(
            chord,
            platform: platform,
            isWeb: isWeb,
          ),
          expected,
          reason:
              'Expected ${chord.toCanonicalString()} collision=$expected on $platform (isWeb=$isWeb)',
        );
      }
    }
  }
}

void _registerBuiltinCollisionTests() {
  test(
    'detects universal leader, clipboard, and F12 collisions on all targets',
    () {
      _expectCollisionForAllTargets([
        KeyChord.tryParse(r'Ctrl+\')!,
        KeyChord.tryParse('Cmd+C')!,
        KeyChord.tryParse('Cmd+V')!,
        KeyChord.tryParse('Cmd+Shift+V')!,
        KeyChord.tryParse('Ctrl+Shift+C')!,
        KeyChord.tryParse('Ctrl+Shift+V')!,
        KeyChord.tryParse('Ctrl+Insert')!,
        KeyChord.tryParse('Shift+Insert')!,
        KeyChord(key: .f12, modifiers: const {}),
        KeyChord.tryParse('Shift+F12')!,
      ], true);
    },
  );

  test('detects platform-scoped font zoom collisions on web and desktop', () {
    final macZoom = <KeyChord>[
      KeyChord.tryParse('Cmd+=')!,
      KeyChord.tryParse('Cmd+Shift+=')!,
      KeyChord.tryParse('Cmd+-')!,
      KeyChord.tryParse('Cmd+0')!,
    ];
    final otherZoom = <KeyChord>[
      KeyChord.tryParse('Ctrl+=')!,
      KeyChord.tryParse('Ctrl+Shift+=')!,
      KeyChord.tryParse('Ctrl+-')!,
      KeyChord.tryParse('Ctrl+0')!,
    ];

    for (final isWeb in const [false, true]) {
      for (final chord in macZoom) {
        expect(
          KeyChord.collidesWithBuiltinShortcut(
            chord,
            platform: .macOS,
            isWeb: isWeb,
          ),
          isTrue,
        );
        expect(
          KeyChord.collidesWithBuiltinShortcut(
            chord,
            platform: .linux,
            isWeb: isWeb,
          ),
          isFalse,
        );
        expect(
          KeyChord.collidesWithBuiltinShortcut(
            chord,
            platform: .windows,
            isWeb: isWeb,
          ),
          isFalse,
        );
      }
      for (final chord in otherZoom) {
        expect(
          KeyChord.collidesWithBuiltinShortcut(
            chord,
            platform: .macOS,
            isWeb: isWeb,
          ),
          isFalse,
        );
        expect(
          KeyChord.collidesWithBuiltinShortcut(
            chord,
            platform: .linux,
            isWeb: isWeb,
          ),
          isTrue,
        );
        expect(
          KeyChord.collidesWithBuiltinShortcut(
            chord,
            platform: .windows,
            isWeb: isWeb,
          ),
          isTrue,
        );
      }
    }
  });

  test('detects desktop-only macOS shortcuts', () {
    final macDesktop = <KeyChord>[
      for (var d = 1; d <= 9; d++) KeyChord.tryParse('Cmd+$d')!,
      KeyChord.tryParse('Cmd+T')!,
      KeyChord.tryParse('Cmd+W')!,
      KeyChord.tryParse('Cmd+D')!,
      KeyChord.tryParse('Cmd+Shift+D')!,
      KeyChord.tryParse('Cmd+,')!,
    ];

    for (final chord in macDesktop) {
      expect(
        KeyChord.collidesWithBuiltinShortcut(
          chord,
          platform: .macOS,
          isWeb: false,
        ),
        isTrue,
      );
      expect(
        KeyChord.collidesWithBuiltinShortcut(
          chord,
          platform: .macOS,
          isWeb: true,
        ),
        isFalse,
      );
      expect(
        KeyChord.collidesWithBuiltinShortcut(
          chord,
          platform: .linux,
          isWeb: false,
        ),
        isFalse,
      );
      expect(
        KeyChord.collidesWithBuiltinShortcut(
          chord,
          platform: .windows,
          isWeb: false,
        ),
        isFalse,
      );
    }
  });

  test('detects desktop-only Linux/Windows shortcuts and dev F-keys', () {
    final linuxWinDesktop = <KeyChord>[
      for (var d = 1; d <= 9; d++) KeyChord.tryParse('Ctrl+Shift+$d')!,
      KeyChord.tryParse('Ctrl+Shift+T')!,
      KeyChord.tryParse('Ctrl+Shift+W')!,
      KeyChord.tryParse('Ctrl+Shift+D')!,
      KeyChord.tryParse('Ctrl+Shift+E')!,
      KeyChord.tryParse('Ctrl+Shift+,')!,
    ];

    for (final chord in linuxWinDesktop) {
      expect(
        KeyChord.collidesWithBuiltinShortcut(
          chord,
          platform: .linux,
          isWeb: false,
        ),
        isTrue,
      );
      expect(
        KeyChord.collidesWithBuiltinShortcut(
          chord,
          platform: .windows,
          isWeb: false,
        ),
        isTrue,
      );
      expect(
        KeyChord.collidesWithBuiltinShortcut(
          chord,
          platform: .linux,
          isWeb: true,
        ),
        isFalse,
      );
      expect(
        KeyChord.collidesWithBuiltinShortcut(
          chord,
          platform: .windows,
          isWeb: true,
        ),
        isFalse,
      );
      expect(
        KeyChord.collidesWithBuiltinShortcut(
          chord,
          platform: .macOS,
          isWeb: false,
        ),
        isFalse,
      );
    }

    final desktopDevFKeys = <KeyChord>[
      KeyChord.tryParse('Ctrl+Shift+F5')!,
      KeyChord.tryParse('Ctrl+Shift+F9')!,
      KeyChord.tryParse('Ctrl+Shift+F10')!,
    ];
    for (final chord in desktopDevFKeys) {
      for (final platform in _desktopPlatforms) {
        expect(
          KeyChord.collidesWithBuiltinShortcut(
            chord,
            platform: platform,
            isWeb: false,
          ),
          isTrue,
        );
        expect(
          KeyChord.collidesWithBuiltinShortcut(
            chord,
            platform: platform,
            isWeb: true,
          ),
          isFalse,
        );
      }
    }
  });

  test('returns false for non-colliding chords across all targets', () {
    _expectCollisionForAllTargets([
      KeyChord.tryParse('Ctrl+Alt+Meta+ArrowLeft')!,
      KeyChord.tryParse('Alt+F4')!,
      KeyChord.tryParse('Ctrl+O')!,
      KeyChord.tryParse('Ctrl+Shift+I')!,
      KeyChord.tryParse('Ctrl+Shift+P')!,
      KeyChord.tryParse('Alt+F12')!,
    ], false);
    expect(
      KeyChord.collidesWithBuiltinShortcut(
        KeyChord.tryParse('Cmd+T')!,
        platform: .android,
        isWeb: false,
      ),
      isFalse,
    );
  });
}

void _registerParseAllTests() {
  test('parses, deduplicates preserving order, and reports invalid tokens', () {
    final result = KeyChord.parseAll(const [
      'Ctrl+Alt+Meta+ArrowLeft',
      'bad-token',
      'control+opt+cmd+left',
      'Shift+A',
      'Alt+F4',
      '',
      'alt+f4',
      'Ctrl+Shift+I',
    ]);

    expect(result.chords, [
      KeyChord(key: .arrowLeft, modifiers: const {.control, .alt, .meta}),
      KeyChord(key: .f4, modifiers: const {.alt}),
      KeyChord(key: .keyI, modifiers: const {.control, .shift}),
    ]);
    expect(result.invalid, ['bad-token', 'Shift+A', '']);
  });

  test('handles empty input', () {
    final result = KeyChord.parseAll(const []);
    expect(result.chords, isEmpty);
    expect(result.invalid, isEmpty);
  });
}
