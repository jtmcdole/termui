import 'dart:io';
import 'package:test/test.dart';
import 'package:termui/ui/buffer.dart';
import 'package:termui/ui/style.dart';
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
      buffer.writeString(0, 0, 'Test', Style.empty);

      final goldenPath = '${tempDir.path}/non_existent.ansi';

      expect(() {
        expect(buffer, matchesAnsiGolden(goldenPath, environment: {}));
      }, throwsA(isA<TestFailure>()));
    });

    test('creates golden file automatically when GENERATE_GOLDENS is true', () {
      final buffer = Buffer.blank(5, 1);
      buffer.writeString(0, 0, 'Test', Style.empty);

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
        buffer.writeString(0, 0, 'Test', Style.empty);

        final goldenPath = '${tempDir.path}/existing.ansi';
        final file = File(goldenPath)..createSync(recursive: true);
        file.writeAsStringSync(AnsiScreenshot.capture(buffer));

        expect(buffer, matchesAnsiGolden(goldenPath));
      },
    );

    test('fails when golden file content differs', () {
      final buffer = Buffer.blank(5, 1);
      buffer.writeString(0, 0, 'Test', Style.empty);

      final goldenPath = '${tempDir.path}/diff.ansi';
      final file = File(goldenPath)..createSync(recursive: true);
      file.writeAsStringSync('DiffContent\n');

      expect(() {
        expect(buffer, matchesAnsiGolden(goldenPath));
      }, throwsA(isA<TestFailure>()));
    });
  });
}
