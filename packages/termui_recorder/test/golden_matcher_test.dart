import 'dart:convert';
import 'dart:io';
import 'package:archive/archive.dart';
import 'package:test/test.dart';
import 'package:termui/ui/buffer.dart';
import 'package:termui_recorder/termui_recorder.dart';

void main() {
  group('matchesAnsiGolden', () {
    late Directory tempDir;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('termui_golden_test');
    });

    tearDown(() {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('fails when golden file does not exist', () {
      final buffer = Buffer.blank(5, 1);
      buffer.writeString(0, 0, 'Test', .empty);

      final goldenPath = '${tempDir.path}/non_existent.ansi';

      expect(() {
        expect(buffer, matchesAnsiGolden(goldenPath, environment: {}));
      }, throwsA(isA<TestFailure>()));
    });

    test('creates golden file automatically when GENERATE_GOLDENS is true', () {
      final buffer = Buffer.blank(5, 1);
      buffer.writeString(0, 0, 'Test', .empty);

      final goldenPath = '${tempDir.path}/auto_created.ansi';

      expect(
        buffer,
        matchesAnsiGolden(
          goldenPath,
          environment: {'GENERATE_GOLDENS': 'true'},
        ),
      );

      final file = File(goldenPath);
      expect(file.existsSync(), isTrue);
      expect(file.readAsStringSync(), equals(AnsiScreenshot.capture(buffer)));
    });

    test(
      'matches correctly when golden file exists and content is identical',
      () {
        final buffer = Buffer.blank(5, 1);
        buffer.writeString(0, 0, 'Test', .empty);

        final goldenPath = '${tempDir.path}/existing.ansi';
        final file = File(goldenPath)..createSync(recursive: true);
        file.writeAsStringSync(AnsiScreenshot.capture(buffer));

        expect(buffer, matchesAnsiGolden(goldenPath));
      },
    );

    test(
      'fails when golden file content differs and generates fail/diff/cast outputs',
      () {
        final buffer = Buffer.blank(5, 1);
        buffer.writeString(0, 0, 'Test', .empty);

        final goldenPath = '${tempDir.path}/diff.ansi';
        final file = File(goldenPath)..createSync(recursive: true);
        file.writeAsStringSync('DiffContent\n');

        TestFailure? failure;
        try {
          expect(buffer, matchesAnsiGolden(goldenPath));
        } on TestFailure catch (e) {
          failure = e;
        }

        expect(failure, isNotNull);
        expect(failure!.message, contains('Mismatch detected for golden file'));
        expect(failure.message, contains('Actual output saved to:'));
        expect(failure.message, contains('Highlighted diff saved to:'));
        expect(
          failure.message,
          contains('Play comparison slideshow cast with:'),
        );
        expect(
          failure.message,
          contains('dart run termui_recorder:termui_play'),
        );

        // Check that files are written
        final failPath = '$goldenPath.fail';
        final diffPath = '$goldenPath.diff';
        final castPath = '$goldenPath.cast';

        expect(File(failPath).existsSync(), isTrue);
        expect(File(diffPath).existsSync(), isTrue);
        expect(File(castPath).existsSync(), isTrue);

        // Verify actual contents
        expect(
          File(failPath).readAsStringSync(),
          equals(AnsiScreenshot.capture(buffer)),
        );
        expect(
          File(diffPath).readAsStringSync(),
          contains('48;2;128;0;0m'),
        ); // Mismatches highlighted in red

        // Verify Gzipped Asciicast contents
        final castBytes = File(castPath).readAsBytesSync();
        final decodedBytes = GZipDecoder().decodeBytes(castBytes);
        final castContent = utf8.decode(decodedBytes);
        final castLines = castContent.trim().split('\n');

        expect(
          castLines.length,
          greaterThanOrEqualTo(4),
        ); // Header + 3 frames + optional action events

        final headerJson = jsonDecode(castLines[0]) as Map<String, dynamic>;
        expect(headerJson['version'], equals(3));
        expect(headerJson['term']['cols'], equals(5));
        expect(headerJson['term']['rows'], equals(1));

        // The last line should represent the final frame output event
        final lastLineJson = jsonDecode(castLines.last) as List<dynamic>;
        expect(lastLineJson[1], equals('o')); // output sequence
      },
    );
  });
}
