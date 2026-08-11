import 'dart:io';
import 'package:args/args.dart';
import 'package:termui_tinpot/termui_tinpot.dart';
import 'package:test/test.dart';

void main() {
  group('CLI Background Flag Parsing - parseBackgroundColor', () {
    group('8-digit ARGB hex', () {
      test('parses opaque black (FF000000)', () {
        final result = parseBackgroundColor('FF000000');
        expect(result, equals(0xFF000000));
      });

      test('parses Dart blue (FF00001F)', () {
        final result = parseBackgroundColor('FF00001F');
        expect(result, equals(0xFF00001F));
      });

      test('parses opaque white (FFFFFFFF)', () {
        final result = parseBackgroundColor('FFFFFFFF');
        expect(result, equals(0xFFFFFFFF));
      });

      test('parses fully transparent black (00000000)', () {
        final result = parseBackgroundColor('00000000');
        expect(result, equals(0x00000000));
      });

      test('parses semi-transparent red (80FF0000)', () {
        final result = parseBackgroundColor('80FF0000');
        expect(result, equals(0x80FF0000));
      });
    });

    group('6-digit RGB hex (defaults alpha to 0xFF)', () {
      test('parses 6-digit black (000000) as FF000000', () {
        final result = parseBackgroundColor('000000');
        expect(result, equals(0xFF000000));
      });

      test('parses 6-digit blue (00001F) as FF00001F', () {
        final result = parseBackgroundColor('00001F');
        expect(result, equals(0xFF00001F));
      });

      test('parses 6-digit red (FF0000) as FFFF0000', () {
        final result = parseBackgroundColor('FF0000');
        expect(result, equals(0xFFFF0000));
      });

      test('parses 6-digit white (FFFFFF) as FFFFFFFF', () {
        final result = parseBackgroundColor('FFFFFF');
        expect(result, equals(0xFFFFFFFF));
      });
    });

    group('Prefixed hex (# and 0x / 0X)', () {
      test('parses # prefixed 8-digit hex (#FF00001F)', () {
        final result = parseBackgroundColor('#FF00001F');
        expect(result, equals(0xFF00001F));
      });

      test('parses # prefixed 6-digit hex (#000000)', () {
        final result = parseBackgroundColor('#000000');
        expect(result, equals(0xFF000000));
      });

      test('parses 0x prefixed 8-digit hex (0xFF000000)', () {
        final result = parseBackgroundColor('0xFF000000');
        expect(result, equals(0xFF000000));
      });

      test('parses 0x prefixed 6-digit hex (0x000000)', () {
        final result = parseBackgroundColor('0x000000');
        expect(result, equals(0xFF000000));
      });

      test('parses 0X prefixed uppercase hex (0XFF00001F)', () {
        final result = parseBackgroundColor('0XFF00001F');
        expect(result, equals(0xFF00001F));
      });

      test('parses # prefixed 6-digit blue (#00001F)', () {
        final result = parseBackgroundColor('#00001F');
        expect(result, equals(0xFF00001F));
      });
    });

    group('Lowercase and mixed-case hex', () {
      test('parses lowercase 8-digit hex (ff00001f)', () {
        final result = parseBackgroundColor('ff00001f');
        expect(result, equals(0xFF00001F));
      });

      test('parses lowercase 6-digit hex (00001f)', () {
        final result = parseBackgroundColor('00001f');
        expect(result, equals(0xFF00001F));
      });

      test('parses lowercase prefixed hex (#ff00001f)', () {
        final result = parseBackgroundColor('#ff00001f');
        expect(result, equals(0xFF00001F));
      });

      test('parses lowercase 0x prefixed hex (0xff000000)', () {
        final result = parseBackgroundColor('0xff000000');
        expect(result, equals(0xFF000000));
      });

      test('parses mixed-case hex (Ff00001f)', () {
        final result = parseBackgroundColor('Ff00001f');
        expect(result, equals(0xFF00001F));
      });
    });

    group('Null, empty, and omitted option handling', () {
      test('returns null for null input', () {
        final result = parseBackgroundColor(null);
        expect(result, isNull);
      });

      test('returns null for empty string', () {
        final result = parseBackgroundColor('');
        expect(result, isNull);
      });

      test('returns null for whitespace-only string', () {
        final result = parseBackgroundColor('   ');
        expect(result, isNull);
      });
    });

    group('Invalid format strings (throws FormatException)', () {
      test('throws FormatException for non-hex characters (GGGGGG)', () {
        expect(
          () => parseBackgroundColor('GGGGGG'),
          throwsA(isA<FormatException>()),
        );
      });

      test('throws FormatException for 5-digit hex string (12345)', () {
        expect(
          () => parseBackgroundColor('12345'),
          throwsA(isA<FormatException>()),
        );
      });

      test('throws FormatException for 7-digit hex string (1234567)', () {
        expect(
          () => parseBackgroundColor('1234567'),
          throwsA(isA<FormatException>()),
        );
      });

      test('throws FormatException for 9-digit hex string (123456789)', () {
        expect(
          () => parseBackgroundColor('123456789'),
          throwsA(isA<FormatException>()),
        );
      });

      test('throws FormatException for arbitrary string (xyz)', () {
        expect(
          () => parseBackgroundColor('xyz'),
          throwsA(isA<FormatException>()),
        );
      });

      test('throws FormatException for short # prefixed hex (#123)', () {
        expect(
          () => parseBackgroundColor('#123'),
          throwsA(isA<FormatException>()),
        );
      });

      test('throws FormatException for invalid 0x prefixed hex (0xZZZZZZ)', () {
        expect(
          () => parseBackgroundColor('0xZZZZZZ'),
          throwsA(isA<FormatException>()),
        );
      });
    });

    group('CLI ArgParser Integration for --background option', () {
      late ArgParser parser;

      setUp(() {
        parser = ArgParser()
          ..addOption(
            'background',
            abbr: 'b',
            help: 'Background color hex string (e.g. FF000000)',
          );
      });

      test('parses --background flag with 8-digit hex', () {
        final results = parser.parse(['--background', 'FF000000']);
        final bgStr = results['background'] as String?;
        final parsedColor = parseBackgroundColor(bgStr);
        expect(parsedColor, equals(0xFF000000));
      });

      test('parses short flag -b with 8-digit hex', () {
        final results = parser.parse(['-b', 'FF00001F']);
        final bgStr = results['background'] as String?;
        final parsedColor = parseBackgroundColor(bgStr);
        expect(parsedColor, equals(0xFF00001F));
      });

      test('parses omitted --background flag as null', () {
        final results = parser.parse(['image.png']);
        final bgStr = results['background'] as String?;
        final parsedColor = parseBackgroundColor(bgStr);
        expect(parsedColor, isNull);
      });

      test('parses --background with # prefix', () {
        final results = parser.parse(['--background', '#FF00001F']);
        final bgStr = results['background'] as String?;
        final parsedColor = parseBackgroundColor(bgStr);
        expect(parsedColor, equals(0xFF00001F));
      });
    });

    group('CLI Process Execution for --background option', () {
      late String binPath;
      late String assetPath;

      setUpAll(() {
        final rootDir = Directory.current.path;
        binPath = '$rootDir/bin/tinpot.dart';
        assetPath = '$rootDir/test/assets/omega_Gate.png';
      });

      test(
        'CLI exits with code 1 on malformed --background hex string',
        () async {
          final result = await Process.run(Platform.executable, [
            binPath,
            assetPath,
            '--background',
            'GGGGGG',
          ]);
          expect(result.exitCode, equals(1));
          expect(result.stderr.toString(), contains('Error: Invalid'));
        },
      );

      test(
        'CLI exits with code 1 on invalid length --background hex string',
        () async {
          final result = await Process.run(Platform.executable, [
            binPath,
            assetPath,
            '--background',
            '12345',
          ]);
          expect(result.exitCode, equals(1));
          expect(result.stderr.toString(), contains('Error: Invalid'));
        },
      );
    });
  });
}
