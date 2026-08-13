import 'dart:convert';
import 'dart:io';
import 'package:clock/clock.dart';
import 'package:file/local.dart';
import 'package:test/test.dart';
import 'package:termui/ui/buffer.dart';
import 'package:termui/ui/color.dart';
import 'package:termui/ui/style.dart';
import 'ansi_parser.dart';
import 'ansi_screenshot.dart';
import 'asciicast_recorder.dart';

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

final class _AnsiGoldenMatcher extends Matcher {
  final String goldenPath;
  final Map<String, String> _environment;
  final _fs = const LocalFileSystem();

  _AnsiGoldenMatcher(this.goldenPath, {Map<String, String>? environment})
    : _environment = environment ?? Platform.environment;

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
    final expectedAnsiNormalized = const LineSplitter()
        .convert(expectedAnsi)
        .join('\n');
    final currentAnsiNormalized = const LineSplitter()
        .convert(currentAnsi)
        .join('\n');

    if (currentAnsiNormalized != expectedAnsiNormalized) {
      final failPath = '$goldenPath.fail';
      final failedFile = _fs.file(failPath);
      failedFile.createSync(recursive: true);
      failedFile.writeAsStringSync(currentAnsi);

      // 1. Generate diff buffer by parsing expected ANSI
      final expectedBuffer = AnsiParser.parse(
        expectedAnsi,
        width: item.width,
        height: item.height,
      );
      final diffBuffer = Buffer.blank(item.width, item.height);

      for (var y = 0; y < item.height; y++) {
        for (var x = 0; x < item.width; x++) {
          final actChar = item.getCharacter(x, y);
          final actFg = item.getForeground(x, y);
          final actBg = item.getBackground(x, y);
          final actModifiers = item.getModifiers(x, y);

          final expChar = expectedBuffer.getCharacter(x, y);
          final expFg = expectedBuffer.getForeground(x, y);
          final expBg = expectedBuffer.getBackground(x, y);
          final expModifiers = expectedBuffer.getModifiers(x, y);

          final isMatch =
              actChar == expChar &&
              actFg == expFg &&
              actBg == expBg &&
              actModifiers == expModifiers;

          if (isMatch) {
            diffBuffer.setAttributes(
              x,
              y,
              char: actChar,
              fg: actFg,
              bg: actBg,
              modifiers: actModifiers,
            );
          } else {
            // Highlight mismatched cell with red background
            diffBuffer.setAttributes(
              x,
              y,
              char: actChar.isEmpty || actChar == '' ? ' ' : actChar,
              fg: Colors.white.argb,
              bg: const Color(128, 0, 0).argb,
              modifiers: Modifier.none,
            );
          }
        }
      }

      final diffAnsi = AnsiScreenshot.capture(diffBuffer);
      final diffPath = '$goldenPath.diff';
      final diffFile = _fs.file(diffPath);
      diffFile.createSync(recursive: true);
      diffFile.writeAsStringSync(diffAnsi);

      // 2. Generate asciicast slideshow (.cast)
      final castPath = '$goldenPath.cast';
      final castFile = _fs.file(castPath);
      final writer = FileAsciicastWriter(castFile);
      final recorder = AsciicastRecorder(
        writer,
        width: item.width,
        height: item.height,
      );

      withClock(Clock.fixed(DateTime(2026, 1, 1, 12, 0, 0)), () {
        recorder.recordFrame(expectedBuffer, ['Expected Golden State']);
      });
      withClock(Clock.fixed(DateTime(2026, 1, 1, 12, 0, 2)), () {
        recorder.recordFrame(item, ['Actual (Failed)']);
      });
      withClock(Clock.fixed(DateTime(2026, 1, 1, 12, 0, 4)), () {
        recorder.recordFrame(diffBuffer, [
          'Diff Highlights (Mismatches in Red)',
        ]);
      });
      recorder.close();

      matchState['failure'] =
          'Mismatch detected for golden file at $goldenPath.\n'
          '  - Actual output saved to: $failPath\n'
          '  - Highlighted diff saved to: $diffPath\n'
          '  - Play comparison slideshow cast with:\n'
          '    dart run termui_recorder:termui_play --paused --keep-alive $castPath\n'
          '    (Use [Space] to pause/play, [Right Arrow] to step forwards, [Left Arrow] to step backwards)\n\n'
          'Diff:\n${_getDiff(expectedAnsi, currentAnsi)}';

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
