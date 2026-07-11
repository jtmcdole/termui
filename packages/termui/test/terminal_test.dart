import 'dart:convert';
import 'package:test/test.dart';
import 'package:termui/terminal/terminal.dart';
import 'package:termui/terminal/input_parser.dart';
import 'package:termui_test/termui_test.dart';

void main() {
  group('Terminal.runGuarded Tests', () {
    test('runGuarded executes body and cleans up on success', () async {
      var executed = false;
      final result = await Terminal.runGuarded((terminal) {
        executed = true;
        return 42;
      });
      expect(executed, isTrue);
      expect(result, 42);
    });

    test('runGuarded cleans up and rethrows on exception', () async {
      expect(
        Terminal.runGuarded((terminal) {
          throw Exception('Test Crash');
        }),
        throwsA(isA<Exception>()),
      );
    });

    test(
      'Terminal size and watchSize do not throw and return correct types',
      () async {
        final terminal = Terminal();
        final size = await terminal.size;
        expect(size.x, greaterThan(0));
        expect(size.y, greaterThan(0));

        final sizeStream = terminal.watchSize();
        expect(sizeStream, isA<Stream>());
        terminal.dispose();
      },
    );
  });

  group('Bracketed Paste Tests', () {
    test('enableBracketedPaste and disableBracketedPaste write sequences', () {
      final backend = MockTerminalBackend();
      final terminal = MockTerminal(backend);

      expect(terminal.pasteTrackingEnabled, isFalse);

      terminal.enableBracketedPaste();
      expect(backend.writes, contains(Terminal.enableBracketedPasteSequence));
      expect(terminal.pasteTrackingEnabled, isTrue);

      backend.clearStdout();

      terminal.disableBracketedPaste();
      expect(backend.writes, contains(Terminal.disableBracketedPasteSequence));
      expect(terminal.pasteTrackingEnabled, isFalse);
    });

    test('InputParser decodes UTF-8 pastes correctly', () {
      final parser = InputParser();
      // Start paste
      expect(parser.parse('\x1b[200~'.codeUnits), isEmpty);

      // 'hello 🎉' in UTF-8 bytes: [104, 101, 108, 108, 111, 32, 240, 159, 142, 137]
      final content = utf8.encode('hello 🎉');
      expect(parser.parse(content), isEmpty);

      // End paste
      final events = parser.parse('\x1b[201~'.codeUnits);
      expect(events, hasLength(1));
      expect(events.first, isA<PasteEvent>());
      expect((events.first as PasteEvent).text, equals('hello 🎉'));
    });

    test('InputParser handles chunked oddball pastes correctly', () {
      final parser = InputParser();

      // Chunk 1: Start sequence and part of paste
      // 'Start\n'
      final chunk1 = [...'\x1b[200~Start\n'.codeUnits];
      expect(parser.parse(chunk1), isEmpty);

      // Chunk 2: ESC and control sequences that shouldn't end the paste
      // 'Esc\x1bInside\x1b[A'
      final chunk2 = [...'Esc\x1bInside\x1b[A'.codeUnits];
      expect(parser.parse(chunk2), isEmpty);

      // Chunk 3: End sequence in parts
      final chunk3 = '\x1b[201'.codeUnits;
      expect(parser.parse(chunk3), isEmpty);

      final chunk4 = '~Extra'.codeUnits;
      final events = parser.parse(chunk4);

      // The paste event should have the entire accumulated text,
      // and subsequent text ('Extra') is parsed as a regular key event.
      expect(events, hasLength(6));
      expect(events[0], isA<PasteEvent>());
      expect(
        (events[0] as PasteEvent).text,
        equals('Start\nEsc\x1bInside\x1b[A'),
      );
      expect(events[1], isA<KeyEvent>());
      expect((events[1] as KeyEvent).key, equals('E'));
      expect((events[2] as KeyEvent).key, equals('x'));
      expect((events[3] as KeyEvent).key, equals('t'));
      expect((events[4] as KeyEvent).key, equals('r'));
      expect((events[5] as KeyEvent).key, equals('a'));
    });
  });
}
