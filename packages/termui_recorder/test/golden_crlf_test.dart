import 'package:file/local.dart';
import 'package:test/test.dart';
import 'package:termui/ui/buffer.dart';
import 'package:termui/ui/style.dart';
import 'package:termui_recorder/src/golden_matcher.dart';

void main() {
  test('Golden matcher fails on CRLF differences', () {
    final fs = const LocalFileSystem();
    final tempDir = fs.systemTempDirectory.createTempSync('termui_crlf_test');

    try {
      final file = tempDir.childFile('test_golden.ansi');
      final goldenPath = file.path;

      // Simulate a Windows checked-out file with CRLF
      file.writeAsStringSync('Hello\r\nWorld\r\n');

      final buffer = Buffer.blank(5, 2);
      buffer.writeString(0, 0, 'Hello', const Style());
      buffer.writeString(0, 1, 'World', const Style());

      // matchesAnsiGolden normally uses matches(dynamic item, Map matchState)
      final matcher = matchesAnsiGolden(goldenPath);
      final matchState = {};
      final matches = matcher.matches(buffer, matchState);

      // The bug is fixed, matches should return true
      expect(matches, isTrue);
    } finally {
      tempDir.deleteSync(recursive: true);
    }
  });
}
