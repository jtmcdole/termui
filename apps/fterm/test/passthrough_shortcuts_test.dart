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
          'invalid',
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

  group('FtermPreferences metaKeyMode & passthroughShortcuts', () {
    test('defaults to auto metaKeyMode and empty passthroughShortcuts', () {
      const defaults = FtermPreferences.defaults;
      expect(defaults.metaKeyMode, equals(FtermMetaKeyMode.auto));
      expect(defaults.passthroughShortcuts, isEmpty);
    });

    test('round-trips metaKeyMode and canonicalized passthroughShortcuts through JSON', () {
      final ctrlShiftI = KeyChord.tryParse('Ctrl+Shift+I')!;
      final altF4 = KeyChord.tryParse('Alt+F4')!;
      final metaLeft = KeyChord.tryParse('Cmd+ArrowLeft')!;

      for (final mode in FtermMetaKeyMode.values) {
        final prefs = FtermPreferences.defaults.copyWith(
          metaKeyMode: mode,
          passthroughShortcuts: [ctrlShiftI, altF4, metaLeft],
        );
        final encoded = prefs.toJsonString();
        final rawMap = jsonDecode(encoded) as Map<String, Object?>;
        expect(rawMap['metaKeyMode'], equals(mode.wireName));
        expect(
          rawMap['passthroughShortcuts'],
          equals(const ['Ctrl+Shift+I', 'Alt+F4', 'Meta+ArrowLeft']),
        );

        final decoded = FtermPreferences.fromJsonString(encoded);
        expect(decoded, equals(prefs));
        expect(decoded.hashCode, equals(prefs.hashCode));
        expect(decoded.metaKeyMode, equals(mode));
        expect(
          decoded.passthroughShortcuts,
          equals([ctrlShiftI, altF4, metaLeft]),
        );
      }
    });

    test('ignores malformed, non-string, and duplicate entries in persisted JSON without crashing', () {
      final decoded = FtermPreferences.fromJsonString(
        jsonEncode(<String, Object?>{
          'metaKeyMode': 'pass_through',
          'passthroughShortcuts': [
            42,
            null,
            true,
            '',
            'not-a-chord',
            'Shift+A', // unsafe printable shift chord
            'shift+ctrl+i',
            'Ctrl+Shift+I', // duplicate in canonical form
            'cmd+left',
            'Meta+ArrowLeft', // duplicate alias
            'Alt+F4',
          ],
        }),
      );

      expect(decoded.metaKeyMode, equals(FtermMetaKeyMode.passThrough));
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

      // Non-list JSON value degrades safely to empty list.
      final nonList = FtermPreferences.fromJsonString(
        jsonEncode(<String, Object?>{
          'metaKeyMode': 'unknown_mode',
          'passthroughShortcuts': 'Ctrl+Shift+I',
        }),
      );
      expect(nonList.metaKeyMode, equals(FtermMetaKeyMode.auto));
      expect(nonList.passthroughShortcuts, isEmpty);
    });

    test('copyWith deduplicates in order and wraps passthroughShortcuts as unmodifiable', () {
      final ctrlShiftI = KeyChord.tryParse('Ctrl+Shift+I')!;
      final altF4 = KeyChord.tryParse('Alt+F4')!;
      final mutableSource = <KeyChord>[ctrlShiftI, altF4, ctrlShiftI];

      final prefs = FtermPreferences.defaults.copyWith(
        passthroughShortcuts: mutableSource,
      );
      mutableSource.add(KeyChord.tryParse('Ctrl+K')!);

      expect(prefs.passthroughShortcuts, equals([ctrlShiftI, altF4]));
      expect(
        () => prefs.passthroughShortcuts.add(KeyChord.tryParse('Ctrl+L')!),
        throwsUnsupportedError,
      );

      // Clearing back to empty yields empty list cleanly.
      final cleared = prefs.copyWith(passthroughShortcuts: const []);
      expect(cleared.passthroughShortcuts, isEmpty);
    });

    test('operator == and hashCode account for metaKeyMode and passthroughShortcuts', () {
      final ctrlShiftI = KeyChord.tryParse('Ctrl+Shift+I')!;
      final altF4 = KeyChord.tryParse('Alt+F4')!;

      final a = FtermPreferences.defaults.copyWith(
        metaKeyMode: FtermMetaKeyMode.kitty,
        passthroughShortcuts: [ctrlShiftI, altF4],
      );
      final aCopy = FtermPreferences.defaults.copyWith(
        metaKeyMode: FtermMetaKeyMode.kitty,
        passthroughShortcuts: [ctrlShiftI, altF4],
      );
      final diffMode = a.copyWith(metaKeyMode: FtermMetaKeyMode.passThrough);
      final diffOrder = a.copyWith(passthroughShortcuts: [altF4, ctrlShiftI]);
      final diffList = a.copyWith(passthroughShortcuts: [ctrlShiftI]);

      expect(a, equals(aCopy));
      expect(a.hashCode, equals(aCopy.hashCode));
      expect(a, isNot(equals(diffMode)));
      expect(a, isNot(equals(diffOrder)));
      expect(a, isNot(equals(diffList)));
    });
  });
}
