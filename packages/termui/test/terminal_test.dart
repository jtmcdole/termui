import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:test/test.dart';
import 'package:termui/terminal/terminal.dart';
import 'package:termui/terminal/input_parser.dart';
import 'package:termui_test/termui_test.dart';

class _OrderTrackingBackend implements TerminalBackend {
  final List<String> log = [];
  final StreamController<List<int>> _input =
      StreamController<List<int>>.broadcast();
  bool disposed = false;

  @override
  bool get isWindows => false;

  @override
  Point<int> get size => const Point(80, 24);

  @override
  Stream<Point<int>> watchSize() => const Stream.empty();

  @override
  Stream<List<int>> get rawInput => _input.stream;

  void emitRaw(List<int> bytes) => _input.add(bytes);

  @override
  void enableRawMode() {
    log.add('enableRawMode');
  }

  @override
  void disableRawMode() {
    log.add('disableRawMode');
  }

  @override
  void write(String text) {
    if (disposed) {
      throw StateError('write called after backend.dispose(): $text');
    }
    log.add('write:$text');
  }

  @override
  void dispose() {
    disposed = true;
    log.add('dispose');
    _input.close();
  }
}

void main() {
  group('Terminal.runGuarded & dispose Tests', () {
    test('runGuarded executes body and cleans up on success', () async {
      var executed = false;
      final backend = _OrderTrackingBackend();
      final result = await Terminal.runGuarded((terminal) {
        executed = true;
        return 42;
      }, backend: backend);
      expect(executed, isTrue);
      expect(result, 42);
      expect(backend.disposed, isTrue);
    });

    test('runGuarded cleans up and rethrows on exception', () async {
      final backend = _OrderTrackingBackend();
      await expectLater(
        Terminal.runGuarded((terminal) {
          throw Exception('Test Crash');
        }, backend: backend),
        throwsA(isA<Exception>()),
      );
      expect(backend.disposed, isTrue);
    });

    test(
      'Terminal.dispose resets active modes before disabling raw mode and guards double-dispose',
      () {
        final backend = _OrderTrackingBackend();
        final terminal = Terminal(backend);
        terminal.enterAlternateScreen();
        terminal.enableMouseTracking();
        terminal.enableBracketedPaste();
        terminal.hideCursor();
        backend.log.clear();

        terminal.dispose();
        terminal.dispose(); // Second call must be a no-op.

        expect(backend.log, [
          'write:${Terminal.disableBracketedPasteSequence}',
          'write:${Terminal.disableMouseTrackingSequence}',
          'write:${Terminal.exitAlternateScreenSequence}',
          'write:${Terminal.showCursorSequence}',
          'disableRawMode',
          'dispose',
        ]);
      },
    );

    test(
      'Terminal.runGuarded resets active modes before backend.dispose when callback throws',
      () async {
        final backend = _OrderTrackingBackend();
        await expectLater(
          Terminal.runGuarded((terminal) async {
            terminal.enterAlternateScreen();
            terminal.enableMouseTracking();
            terminal.enableBracketedPaste();
            terminal.hideCursor();
            backend.log.clear();
            throw StateError('Callback failure');
          }, backend: backend),
          throwsA(isA<StateError>()),
        );

        expect(backend.log, [
          'write:${Terminal.disableBracketedPasteSequence}',
          'write:${Terminal.disableMouseTrackingSequence}',
          'write:${Terminal.exitAlternateScreenSequence}',
          'write:${Terminal.showCursorSequence}',
          'disableRawMode',
          'dispose',
        ]);
      },
    );

    test(
      'Terminal size and watchSize do not throw and return correct types',
      () async {
        final backend = MockTerminalBackend();
        final terminal = Terminal(backend);
        final size = await terminal.size;
        expect(size.x, greaterThan(0));
        expect(size.y, greaterThan(0));

        final sizeStream = terminal.watchSize();
        expect(sizeStream, isA<Stream<Object?>>());
        terminal.dispose();
      },
    );
  });

  group('CSI Resilience & Overflow Tests', () {
    test(
      'ignores private DEC/Kitty CSI responses and parses empty/Kitty subparams cleanly',
      () {
        final parser = InputParser();

        // Private device attribute / Kitty responses (?, >, =, <).
        expect(
          parser.parse('\x1b[?1;2c\x1b[>0;276;0c\x1b[=1u\x1b[<1u'.codeUnits),
          isEmpty,
        );

        // Empty param \x1b[;5A (Ctrl+Up) followed by Kitty subparam \x1b[97;1:3u and normal 'k'.
        final events = parser.parse('\x1b[;5A\x1b[97;1:3uk'.codeUnits);
        expect(events, hasLength(3));
        expect(events[0], isA<KeyEvent>());
        final up = events[0] as KeyEvent;
        expect(up.type, KeyType.up);
        expect(up.modifiers, contains(Modifier.control));

        expect(events[1], isA<KeyEvent>());
        expect(events[2], isA<KeyEvent>());
        expect((events[2] as KeyEvent).key, 'k');
      },
    );

    test(
      'discards runaway CSI sequences exceeding maxCsiBytes without wedging',
      () {
        final parser = InputParser();

        // Incomplete runaway CSI (> maxCsiBytes with no terminator), then normal keystroke.
        final runawayIncomplete =
            '\x1b[${'0' * (InputParser.maxCsiBytes + 50)}';
        expect(parser.parse(runawayIncomplete.codeUnits), isEmpty);

        final afterIncomplete = parser.parse('z'.codeUnits);
        expect(afterIncomplete, hasLength(1));
        expect((afterIncomplete.first as KeyEvent).key, 'z');

        // Terminated oversized CSI in a single chunk followed immediately by 'q'.
        final runawayTerminated = '\x1b[${'1;' * (InputParser.maxCsiBytes)}Aq';
        final events = parser.parse(runawayTerminated.codeUnits);
        expect(events, hasLength(1));
        expect((events.first as KeyEvent).key, 'q');
      },
    );

    test('caps/flushes oversized bracketed paste without unbounded growth', () {
      final parser = InputParser();
      expect(parser.parse('\x1b[200~'.codeUnits), isEmpty);

      final halfChunk = List<int>.filled(
        (InputParser.maxPasteBytes ~/ 2) + 64,
        97,
      );
      final firstEvents = parser.parse(halfChunk);
      expect(firstEvents, isEmpty);

      // Pushing past maxPasteBytes flushes a bounded PasteEvent chunk immediately.
      final secondEvents = parser.parse(halfChunk);
      expect(secondEvents, hasLength(1));
      expect(secondEvents.first, isA<PasteEvent>());
      expect(
        (secondEvents.first as PasteEvent).text.length,
        InputParser.maxPasteBytes,
      );

      // Closing paste emits the remaining tail and resumes normal key parsing.
      final tailEvents = parser.parse('\x1b[201~x'.codeUnits);
      expect(tailEvents, hasLength(2));
      expect(tailEvents[0], isA<PasteEvent>());
      expect((tailEvents[0] as PasteEvent).text.length, 128);
      expect(tailEvents[1], isA<KeyEvent>());
      expect((tailEvents[1] as KeyEvent).key, 'x');
    });
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

    test(
      'setClipboard and requestPaste emit OSC 52 sequences and respect dispose',
      () {
        final backend = MockTerminalBackend();
        final terminal = MockTerminal(backend);

        terminal.setClipboard('hi');
        expect(backend.writes.last, equals('\x1b]52;c;aGk=\x1b\\'));

        terminal.requestPaste();
        expect(backend.writes.last, equals('\x1b]52;c;?\x1b\\'));

        final countBeforeDispose = backend.writes.length;
        terminal.dispose();
        terminal.setClipboard('ignored');
        terminal.requestPaste();
        expect(backend.writes, hasLength(countBeforeDispose));
      },
    );

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

    test(
      'InputParser decodes OSC 52 replies (BEL, ST, and chunked) as PasteEvent',
      () {
        final parser = InputParser();

        final b64Bel = base64.encode(utf8.encode('clip bel 🚀'));
        final belEvents = parser.parse(utf8.encode('\x1b]52;c;$b64Bel\x07'));
        expect(belEvents, hasLength(1));
        expect(
          belEvents.single,
          isA<PasteEvent>().having((e) => e.text, 'text', 'clip bel 🚀'),
        );

        // Unpadded base64 and ST (\x1b\\) terminator.
        final stEvents = parser.parse(utf8.encode('\x1b]52;p;aGk\x1b\\'));
        expect(stEvents, hasLength(1));
        expect(
          stEvents.single,
          isA<PasteEvent>().having((e) => e.text, 'text', 'hi'),
        );

        // Chunked across multiple parse() calls, including split ST (\x1b then \\) + trailing key.
        expect(parser.parse(utf8.encode('\x1b]5')), isEmpty);
        expect(parser.parse(utf8.encode('2;c;SGVs')), isEmpty);
        expect(parser.parse(utf8.encode('bG8=\x1b')), isEmpty);
        final chunkedEvents = parser.parse(utf8.encode('\\Z'));
        expect(chunkedEvents, hasLength(2));
        expect(
          chunkedEvents[0],
          isA<PasteEvent>().having((e) => e.text, 'text', 'Hello'),
        );
        expect(
          chunkedEvents[1],
          isA<KeyEvent>().having((e) => e.key, 'key', 'Z'),
        );
      },
    );

    test(
      'InputParser handles standalone ESC ], CAN/SUB OSC aborts, non-52 OSC, and >1.4M overflow',
      () {
        final parser = InputParser();

        // Standalone ESC ] -> Alt+], and coalesced ESC ] + non-digit bytes emit Alt+] + keys.
        final altBracket = parser.parse('\x1b]'.codeUnits);
        expect(altBracket, hasLength(1));
        expect(
          altBracket.single,
          isA<KeyEvent>().having((e) => e.key, 'key', ']').having(
            (e) => e.modifiers,
            'modifiers',
            {Modifier.alt},
          ),
        );

        final coalescedAltBracket = parser.parse(utf8.encode('\x1b]ls\r'));
        expect(coalescedAltBracket, hasLength(4));
        expect(
          coalescedAltBracket[0],
          isA<KeyEvent>().having((e) => e.key, 'key', ']').having(
            (e) => e.modifiers,
            'modifiers',
            {Modifier.alt},
          ),
        );
        expect((coalescedAltBracket[1] as KeyEvent).key, equals('l'));
        expect((coalescedAltBracket[2] as KeyEvent).key, equals('s'));
        expect(
          (coalescedAltBracket[3] as KeyEvent).type,
          equals(KeyType.enter),
        );

        // CAN (0x18) and SUB (0x1A) abort OSC without leaking base64 as keystrokes.
        final canEvents = parser.parse('\x1b]52;c;aGk=\x18k'.codeUnits);
        expect(canEvents, hasLength(1));
        expect(
          canEvents.single,
          isA<KeyEvent>().having((e) => e.key, 'key', 'k'),
        );

        final subEvents = parser.parse('\x1b]52;c;aGk=\x1am'.codeUnits);
        expect(subEvents, hasLength(1));
        expect(
          subEvents.single,
          isA<KeyEvent>().having((e) => e.key, 'key', 'm'),
        );

        // Non-52 OSC, '?' query, empty payload, and invalid base64 are silently dropped.
        expect(parser.parse('\x1b]0;window title\x07'.codeUnits), isEmpty);
        expect(
          parser.parse('\x1b]11;rgb:0000/0000/0000\x1b\\'.codeUnits),
          isEmpty,
        );
        expect(parser.parse('\x1b]52;c;?\x07'.codeUnits), isEmpty);
        expect(parser.parse('\x1b]52;c;\x07'.codeUnits), isEmpty);
        expect(parser.parse('\x1b]52;c;!!!\x07'.codeUnits), isEmpty);

        // > 1 MiB decoded OSC 52 bytes or U+FFFD expansion > 1 MiB is rejected.
        final overOneMiBB64 = base64.encode(List<int>.filled(1048577, 0x41));
        expect(
          parser.parse(utf8.encode('\x1b]52;c;$overOneMiBB64\x07')),
          isEmpty,
        );
        final expansionB64 = base64.encode(List<int>.filled(500000, 0xFF));
        expect(
          parser.parse(utf8.encode('\x1b]52;c;$expansionB64\x07')),
          isEmpty,
        );

        // > 1.4M byte OSC sequence across chunks is discarded without OOM or keystroke leak.
        expect(parser.parse('\x1b]52;c;'.codeUnits), isEmpty);
        final halfChunk = List<int>.filled(800000, 0x41);
        expect(parser.parse(halfChunk), isEmpty);
        expect(parser.parse(halfChunk), isEmpty);
        final afterOverflow = parser.parse('\x07q'.codeUnits);
        expect(afterOverflow, hasLength(1));
        expect(
          afterOverflow.single,
          isA<KeyEvent>().having((e) => e.key, 'key', 'q'),
        );

        // > 1 MiB multi-byte UTF-8 bracketed paste splits cleanly on UTF-8 boundaries.
        final largeMultibyte = 'x${'é' * 600000}';
        final pasteEvents = parser.parse(
          utf8.encode('\x1b[200~$largeMultibyte\x1b[201~'),
        );
        expect(pasteEvents, hasLength(2));
        final rejoined = pasteEvents
            .cast<PasteEvent>()
            .map((e) => e.text)
            .join();
        expect(rejoined, equals(largeMultibyte));
        expect(rejoined.contains('\uFFFD'), isFalse);
      },
    );

    test(
      'InputParser emits AudioApcReplyEvent and Terminal routes it exclusively to audioApcReplies',
      () async {
        final parser = InputParser();
        final parsed = parser.parse('\x1b_Aa=waver,q=7;AAAA\x1b\\k'.codeUnits);
        expect(parsed, hasLength(2));
        expect(
          parsed[0],
          equals(const AudioApcReplyEvent('Aa=waver,q=7;AAAA')),
        );
        expect(
          parsed[0].hashCode,
          equals(const AudioApcReplyEvent('Aa=waver,q=7;AAAA').hashCode),
        );
        expect(
          parsed[0].toString(),
          equals('AudioApcReplyEvent(payload: Aa=waver,q=7;AAAA)'),
        );
        expect(parsed[1], isA<KeyEvent>().having((e) => e.key, 'key', 'k'));

        // Other ESC _ A payloads do not emit AudioApcReplyEvent.
        expect(parser.parse('\x1b_Aa=wave,q=7;\x1b\\'.codeUnits), isEmpty);

        final backend = _OrderTrackingBackend();
        final terminal = Terminal(backend);
        final events = <InputEvent>[];
        final replies = <String>[];
        var repliesDone = false;
        final eventSub = terminal.events.listen(events.add);
        final replySub = terminal.audioApcReplies.listen(
          replies.add,
          onDone: () => repliesDone = true,
        );

        backend.emitRaw(utf8.encode('\x1b_Aa=waver,q=11;TEST\x1b\\x'));
        await Future<void>.delayed(Duration.zero);

        expect(replies, equals(['Aa=waver,q=11;TEST']));
        expect(events, equals([const KeyEvent('x', KeyType.character)]));

        final posFuture = terminal.cursorPosition();
        await Future<void>.delayed(Duration.zero);
        backend.emitRaw(utf8.encode('\x1b[12;34R'));
        expect(await posFuture, equals(const Point<int>(34, 12)));

        await eventSub.cancel();
        terminal.dispose();
        await Future<void>.delayed(Duration.zero);
        expect(repliesDone, isTrue);
        await replySub.cancel();
      },
    );
  });
}
