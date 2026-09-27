import 'package:fake_async/fake_async.dart';
import 'package:test/test.dart';
import 'package:termui_recorder/termui_recorder.dart';

void main() {
  group('AsciicastPlayer', () {
    test('parses and plays back .cast events correctly', () {
      fakeAsync((async) {
        final castContent =
            '{"version": 2, "width": 80, "height": 24, "timestamp": 1234567890}\n'
            '[0.1, "o", "Hello"]\n'
            '[0.2, "o", " World!"]\n';

        final sb = StringBuffer();
        final player = AsciicastPlayer(castContent, stdout: sb);

        // At 10.0x speed, event 1 (0.1s) is scheduled at 10ms,
        // and event 2 (0.2s) is scheduled at 20ms.
        player.play(speedMultiplier: 10.0, interactive: false);

        // Before any time elapses, no output is produced.
        expect(sb.toString(), equals(''));

        // Advance 10ms: first event should be emitted.
        async.elapse(const Duration(milliseconds: 10));
        expect(sb.toString(), equals('Hello'));

        // Advance another 10ms (20ms total): second event should be emitted.
        async.elapse(const Duration(milliseconds: 10));
        expect(sb.toString(), equals('Hello World!'));
      });
    });

    test('ignores non-output event types and malformed lines', () {
      fakeAsync((async) {
        final castContent =
            '{"version": 2, "width": 80, "height": 24}\n'
            '[0.05, "i", "input data"]\n' // Ignore input events
            'invalid json line\n' // Ignore malformed lines
            '[0.1, "o", "Valid Output"]\n';

        final sb = StringBuffer();
        final player = AsciicastPlayer(castContent, stdout: sb);

        player.play(speedMultiplier: 10.0, interactive: false);
        async.elapse(const Duration(milliseconds: 15));
        expect(sb.toString(), equals('Valid Output'));
      });
    });

    test('intercepts "d" events and does not write them to stdout', () {
      fakeAsync((async) {
        final castContent =
            '{"version": 2, "width": 80, "height": 24}\n'
            '[0.1, "d", "Actions: Type: Hello"]\n' // Metadata event
            '[0.1, "o", "Visible Output"]\n';

        final sb = StringBuffer();
        final player = AsciicastPlayer(castContent, stdout: sb);

        player.play(speedMultiplier: 10.0, interactive: false);
        async.elapse(const Duration(milliseconds: 15));
        // The "d" event should not be in the output, only "Visible Output"
        expect(sb.toString(), equals('Visible Output'));
      });
    });

    test('safely falls back to 1.0x speed when speedMultiplier <= 0', () {
      fakeAsync((async) {
        final castContent =
            '{"version": 2, "width": 80, "height": 24}\n'
            '[0.1, "o", "Zero Speed Safe"]\n';

        final sb = StringBuffer();
        final player = AsciicastPlayer(castContent, stdout: sb);

        player.play(speedMultiplier: 0.0, interactive: false);
        // At fallback speed 1.0x, 0.1s event arrives at 100ms
        async.elapse(const Duration(milliseconds: 50));
        expect(sb.toString(), equals(''));

        async.elapse(const Duration(milliseconds: 50));
        expect(sb.toString(), equals('Zero Speed Safe'));
      });
    });
  });
}
