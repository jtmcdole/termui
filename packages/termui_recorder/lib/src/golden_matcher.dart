import 'package:file/local.dart';
import 'package:test/test.dart';
import 'package:termui/ui/buffer.dart';
import 'ansi_screenshot.dart';

/// Creates a matcher that asserts the layout of a [Buffer] matches the
/// contents of a saved ANSI golden file.
///
/// Specify [environment] to override system environment variables (useful in testing).
Matcher matchesAnsiGolden(
  String goldenPath, {
  Map<String, String>? environment,
}) {
  return _AnsiGoldenMatcher(goldenPath, environment: environment);
}

class _AnsiGoldenMatcher extends Matcher {
  final String goldenPath;
  final Map<String, String> _environment;
  final _fs = const LocalFileSystem();

  _AnsiGoldenMatcher(this.goldenPath, {Map<String, String>? environment})
    : _environment = environment ?? const {};

  @override
  bool matches(dynamic item, Map matchState) {
    if (item is! Buffer) return false;

    final currentAnsi = AnsiScreenshot.capture(item);
    final goldenFile = _fs.file(goldenPath);

    final updateGoldens =
        _environment['GENERATE_GOLDENS'] == 'true' ||
        _environment['UPDATE_GOLDENS'] == 'true';

    if (updateGoldens) {
      goldenFile.createSync(recursive: true);
      goldenFile.writeAsStringSync(currentAnsi);
      return true;
    }

    if (!goldenFile.existsSync()) {
      final failPath = '$goldenPath.fail';
      final failedFile = _fs.file(failPath);
      failedFile.createSync(recursive: true);
      failedFile.writeAsStringSync(currentAnsi);
      matchState['failure'] =
          'Golden file does not exist at $goldenPath - see $failPath';
      return false;
    }

    final expectedAnsi = goldenFile.readAsStringSync();
    if (currentAnsi != expectedAnsi) {
      matchState['failure'] =
          'Mismatch detected. Diff:\n${_getDiff(expectedAnsi, currentAnsi)}';
      return false;
    }

    return true;
  }

  @override
  Description describe(Description description) =>
      description.add('matches golden file at $goldenPath');

  @override
  Description describeMismatch(
    dynamic item,
    Description mismatchDescription,
    Map matchState,
    bool verbose,
  ) {
    return mismatchDescription.add(
      matchState['failure'] as String? ?? 'Buffer mismatch',
    );
  }

  String _getDiff(String expected, String actual) {
    final expLines = expected.split('\n');
    final actLines = actual.split('\n');
    final result = StringBuffer();
    for (var i = 0; i < expLines.length || i < actLines.length; i++) {
      final exp = i < expLines.length ? expLines[i] : '(EOF)';
      final act = i < actLines.length ? actLines[i] : '(EOF)';
      if (exp != act) {
        result.writeln('Line ${i + 1}:');
        result.writeln('- $exp');
        result.writeln('+ $act');
      }
    }
    return result.toString();
  }
}
