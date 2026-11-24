import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
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
}
