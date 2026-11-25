import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:fterm/src/input/key_chord.dart';
import 'package:fterm/src/settings_storage.dart';

void main() {
  group('FtermMetaKeyMode', () {
    test(
      'parses canonical wire names, snake_case alias, and unknown fallbacks',
      () {
        expect(
          FtermMetaKeyMode.fromWireName('auto'),
          equals(FtermMetaKeyMode.auto),
        );
        expect(
          FtermMetaKeyMode.fromWireName('passThrough'),
          equals(FtermMetaKeyMode.passThrough),
        );
        expect(
          FtermMetaKeyMode.fromWireName('pass_through'),
          equals(FtermMetaKeyMode.passThrough),
        );
        expect(
          FtermMetaKeyMode.fromWireName('kitty'),
          equals(FtermMetaKeyMode.kitty),
        );
        for (final unknown in const <Object?>[
          null,
          '',
          'AUTO',
          'bad',
          42,
          true,
        ]) {
          expect(
            FtermMetaKeyMode.fromWireName(unknown),
            equals(FtermMetaKeyMode.auto),
            reason: 'raw=$unknown',
          );
        }
      },
    );
  });

  group('FtermPreferences metaKeyMode', () {
    test('defaults to auto and round-trips every mode through JSON', () {
      expect(
        FtermPreferences.defaults.metaKeyMode,
        equals(FtermMetaKeyMode.auto),
      );
      for (final mode in FtermMetaKeyMode.values) {
        final prefs = FtermPreferences.defaults.copyWith(metaKeyMode: mode);
        final encoded = prefs.toJsonString();
        final rawMap = jsonDecode(encoded) as Map<String, Object?>;
        expect(rawMap['metaKeyMode'], equals(mode.wireName));

        final decoded = FtermPreferences.fromJsonString(encoded);
        expect(decoded, equals(prefs));
        expect(decoded.hashCode, equals(prefs.hashCode));
        expect(decoded.metaKeyMode, equals(mode));
      }

      final snakeCase = FtermPreferences.fromJsonString(
        jsonEncode(const <String, Object?>{'metaKeyMode': 'pass_through'}),
      );
      expect(snakeCase.metaKeyMode, equals(FtermMetaKeyMode.passThrough));

      final invalid = FtermPreferences.fromJsonString(
        jsonEncode(const <String, Object?>{'metaKeyMode': 'unknown_mode'}),
      );
      expect(invalid.metaKeyMode, equals(FtermMetaKeyMode.auto));
    });

    test('copyWith, ==, and hashCode account for metaKeyMode', () {
      final a = FtermPreferences.defaults.copyWith(metaKeyMode: .kitty);
      final aCopy = FtermPreferences.defaults.copyWith(metaKeyMode: .kitty);
      final b = a.copyWith(metaKeyMode: .passThrough);

      expect(a, equals(aCopy));
      expect(a.hashCode, equals(aCopy.hashCode));
      expect(a, isNot(equals(b)));
    });
  });

  group('FtermPreferences passthroughShortcuts', () {
    test('defaults empty and round-trips canonical chords through JSON', () {
      expect(FtermPreferences.defaults.passthroughShortcuts, isEmpty);
      final chords = [
        KeyChord.tryParse('Ctrl+Shift+I')!,
        KeyChord.tryParse('Alt+F4')!,
        KeyChord.tryParse('Cmd+Left')!,
      ];
      final prefs = FtermPreferences.defaults.copyWith(
        passthroughShortcuts: chords,
      );
      final encoded = prefs.toJsonString();
      final rawMap = jsonDecode(encoded) as Map<String, Object?>;
      expect(
        rawMap['passthroughShortcuts'],
        equals(const ['Ctrl+Shift+I', 'Alt+F4', 'Meta+ArrowLeft']),
      );
      final decoded = FtermPreferences.fromJsonString(encoded);
      expect(decoded, equals(prefs));
      expect(decoded.hashCode, equals(prefs.hashCode));
      expect(decoded.passthroughShortcuts, equals(chords));
    });

    test('tolerates malformed, non-string, non-list, and duplicate JSON', () {
      final rawEntries = <Object?>[
        42,
        null,
        true,
        '',
        'bad',
        'Shift+A',
        ...'shift+ctrl+i,Ctrl+Shift+I,cmd+left,Meta+ArrowLeft,Alt+F4'.split(
          ',',
        ),
      ];
      final decoded = FtermPreferences.fromJsonString(
        jsonEncode({'passthroughShortcuts': rawEntries}),
      );
      expect(
        decoded.passthroughShortcuts,
        equals([
          KeyChord.tryParse('Ctrl+Shift+I')!,
          KeyChord.tryParse('Meta+ArrowLeft')!,
          KeyChord.tryParse('Alt+F4')!,
        ]),
      );
      expect(
        () => decoded.passthroughShortcuts.add(KeyChord.tryParse('Ctrl+K')!),
        throwsUnsupportedError,
      );
      final nonList = FtermPreferences.fromJsonString(
        jsonEncode(const {'passthroughShortcuts': 'Ctrl+Shift+I'}),
      );
      expect(nonList.passthroughShortcuts, isEmpty);
    });

    test('copyWith deduplicates, wraps unmodifiable, and updates ==/hash', () {
      final i = KeyChord.tryParse('Ctrl+Shift+I')!;
      final f4 = KeyChord.tryParse('Alt+F4')!;
      final source = [i, f4, i];
      final a = FtermPreferences.defaults.copyWith(
        passthroughShortcuts: source,
      );
      source.add(KeyChord.tryParse('Ctrl+K')!);
      expect(a.passthroughShortcuts, equals([i, f4]));
      expect(() => a.passthroughShortcuts.add(i), throwsUnsupportedError);
      final aCopy = FtermPreferences.defaults.copyWith(
        passthroughShortcuts: [i, f4],
      );
      expect(a, equals(aCopy));
      expect(a.hashCode, equals(aCopy.hashCode));
      expect(a, isNot(equals(a.copyWith(passthroughShortcuts: [f4, i]))));
      expect(
        a.copyWith(passthroughShortcuts: const []).passthroughShortcuts,
        isEmpty,
      );
    });
  });
}
