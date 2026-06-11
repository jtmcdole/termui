import 'dart:io';
import 'package:test/test.dart';
import 'package:termui_recorder/termui_recorder.dart';

void main() {
  group('AsciicastPlayer', () {
    late File tempFile;

    setUp(() {
      tempFile = File(
        '${Directory.systemTemp.path}/temp_test_cast_${DateTime.now().microsecondsSinceEpoch}.cast',
      );
    });

    tearDown(() {
      if (tempFile.existsSync()) {
        tempFile.deleteSync();
      }
    });

    test('parses and plays back .cast events correctly', () async {
      // 1. Write mock .cast file
      final castContent =
          '{"version": 2, "width": 80, "height": 24, "timestamp": 1234567890}\n'
          '[0.1, "o", "Hello"]\n'
          '[0.2, "o", " World!"]\n';
      tempFile.writeAsStringSync(castContent);

      // 2. Playback to a StringBuffer
      final sb = StringBuffer();
      final player = AsciicastPlayer(tempFile, stdout: sb);

      final start = DateTime.now();
      await player.play(speedMultiplier: 10.0, interactive: false);
      final duration = DateTime.now().difference(start);

      // Verify outputs
      expect(sb.toString(), equals('Hello World!'));
      // Plays quickly because speed multiplier is 10.0
      expect(duration.inMilliseconds, lessThan(200));
    });

    test('ignores non-output event types and malformed lines', () async {
      final castContent =
          '{"version": 2, "width": 80, "height": 24}\n'
          '[0.05, "i", "input data"]\n' // Ignore input events
          'invalid json line\n' // Ignore malformed lines
          '[0.1, "o", "Valid Output"]\n';
      tempFile.writeAsStringSync(castContent);

      final sb = StringBuffer();
      final player = AsciicastPlayer(tempFile, stdout: sb);

      await player.play(speedMultiplier: 10.0, interactive: false);
      expect(sb.toString(), equals('Valid Output'));
    });
  });
}
