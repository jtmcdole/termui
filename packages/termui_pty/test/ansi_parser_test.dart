import 'package:termui/termui.dart';
import 'package:termui_pty/src/ansi_parser.dart';
import 'package:termui_pty/src/virtual_terminal.dart';
import 'package:test/test.dart';

class _TestTerminalHandler implements TerminalHandler {
  String? lastCsiCommand;
  List<int>? lastCsiParams;
  String? lastCsiIntermediate;
  List<List<int>?>? lastCsiSubparams;
  int oscCallCount = 0;
  int? lastOscCommand;
  String? lastOscPayload;
  final List<String> escCommands = [];
  final StringBuffer printedText = StringBuffer();

  @override
  void csi(
    String command,
    List<int> params, {
    String? intermediate,
    List<List<int>?>? subparams,
  }) {
    lastCsiCommand = command;
    lastCsiParams = params;
    lastCsiIntermediate = intermediate;
    lastCsiSubparams = subparams;
  }

  @override
  void esc(String command) {
    escCommands.add(command);
  }

  @override
  void execute(int charCode) {}

  @override
  void osc(int command, String payload) {
    oscCallCount++;
    lastOscCommand = command;
    lastOscPayload = payload;
  }

  @override
  void printText(String text) {
    printedText.write(text);
  }
}

void main() {
  group('VirtualTerminal SGR', () {
    test('Standard colors', () {
      final terminal = VirtualTerminal(width: 10, height: 1);

      // 31 is red
      terminal.write('\x1b[31mA'.codeUnits);
      expect(
        terminal.buffer.getForeground(0, 0),
        equals(const Color(170, 0, 0).argb),
      );

      // 44 is blue background
      terminal.write('\x1b[44mB'.codeUnits);
      expect(
        terminal.buffer.getForeground(1, 0),
        equals(const Color(170, 0, 0).argb),
      );
      expect(
        terminal.buffer.getBackground(1, 0),
        equals(const Color(0, 0, 170).argb),
      );

      // 0 resets
      terminal.write('\x1b[0mC'.codeUnits);
      expect(terminal.buffer.getForeground(2, 0), equals(0));
      expect(terminal.buffer.getBackground(2, 0), equals(0));
    });

    test('256 colors', () {
      final terminal = VirtualTerminal(width: 10, height: 1);

      // Foreground 256
      terminal.write('\x1b[38;5;196mA'.codeUnits);
      expect(
        terminal.buffer.getForeground(0, 0),
        equals(const Color(255, 0, 0).argb),
      );

      // Background 256
      terminal.write('\x1b[48;5;46mB'.codeUnits);
      expect(
        terminal.buffer.getBackground(1, 0),
        equals(const Color(0, 255, 0).argb),
      );
    });

    test('True colors', () {
      final terminal = VirtualTerminal(width: 10, height: 1);

      // Foreground true color
      terminal.write('\x1b[38;2;12;34;56mA'.codeUnits);
      expect(
        terminal.buffer.getForeground(0, 0),
        equals(const Color(12, 34, 56).argb),
      );

      // Background true color
      terminal.write('\x1b[48;2;65;43;21mB'.codeUnits);
      expect(
        terminal.buffer.getBackground(1, 0),
        equals(const Color(65, 43, 21).argb),
      );
    });

    test('Modifiers', () {
      final terminal = VirtualTerminal(width: 10, height: 1);

      terminal.write('\x1b[1mA'.codeUnits);
      expect(terminal.buffer.getModifiers(0, 0), equals(Modifier.bold));

      terminal.write('\x1b[3mB'.codeUnits);
      expect(
        terminal.buffer.getModifiers(1, 0),
        equals(Modifier.bold | Modifier.italic),
      );

      terminal.write('\x1b[22mC'.codeUnits);
      expect(terminal.buffer.getModifiers(2, 0), equals(Modifier.italic));
    });
  });

  group('VirtualTerminal Movement', () {
    test('Cursor Up (A)', () {
      final terminal = VirtualTerminal(width: 10, height: 5);
      terminal.write('\x1b[5;5H'.codeUnits); // 4,4 (0-indexed)
      expect(terminal.cursorX, 4);
      expect(terminal.cursorY, 4);

      terminal.write('\x1b[2AA'.codeUnits); // Up 2
      expect(terminal.buffer.getCharacter(4, 2), 'A');
    });

    test('Cursor Down (B)', () {
      final terminal = VirtualTerminal(width: 10, height: 5);
      terminal.write('\x1b[1;1H'.codeUnits);
      terminal.write('\x1b[3BA'.codeUnits);
      expect(terminal.buffer.getCharacter(0, 3), 'A');
    });

    test('Cursor Forward (C)', () {
      final terminal = VirtualTerminal(width: 10, height: 5);
      terminal.write('\x1b[1;1H'.codeUnits);
      terminal.write('\x1b[4CA'.codeUnits);
      expect(terminal.buffer.getCharacter(4, 0), 'A');
    });

    test('Cursor Back (D)', () {
      final terminal = VirtualTerminal(width: 10, height: 5);
      terminal.write('\x1b[1;5H'.codeUnits);
      terminal.write('\x1b[2DA'.codeUnits);
      expect(terminal.buffer.getCharacter(2, 0), 'A');
    });
  });

  group('VirtualTerminal Erase', () {
    test('Erase in Display (J)', () {
      final terminal = VirtualTerminal(width: 5, height: 5);
      for (var i = 0; i < 25; i++) {
        terminal.write('X'.codeUnits);
      }
      expect(terminal.buffer.characters.join(), equals('X' * 25));

      terminal.write('\x1b[3;3H'.codeUnits);
      terminal.write('\x1b[0J'.codeUnits); // Erase below
      expect(terminal.buffer.getCharacter(2, 2), ' ');
      expect(terminal.buffer.getCharacter(4, 4), ' ');
      expect(terminal.buffer.getCharacter(1, 2), 'X');
    });
  });

  group('AnsiParser CSI Intermediates', () {
    test(
      'Retains CSI parameters before intermediate bytes (e.g. \\x1b[2 q)',
      () {
        final handler = _TestTerminalHandler();
        final parser = AnsiParser(handler);

        parser.parse('\x1b[2 q');
        expect(handler.lastCsiCommand, equals('q'));
        expect(handler.lastCsiParams, equals([2]));
        expect(handler.lastCsiIntermediate, equals(' '));
      },
    );

    test(
      'Aborts unterminated or oversized OSC payloads without leaking to ground text',
      () {
        final handler = _TestTerminalHandler();
        final parser = AnsiParser(handler);

        // Non-52 OSC exceeding 8192 chars overflows and discards tail until BEL/ST.
        parser.parse('\x1b]0;${'A' * 8200}\x07');
        expect(handler.oscCallCount, equals(0));
        expect(handler.printedText.toString(), isEmpty);

        // Oversized OSC 52 (> 1.4M chars) discards tail without printing garbage to ground.
        parser.parse('\x1b]52;c;${'A' * 1450000}\x07');
        expect(handler.oscCallCount, equals(0));
        expect(handler.printedText.toString(), isEmpty);

        // Subsequent valid OSC within cap still parses cleanly.
        parser.parse('\x1b]2;ok-title\x07');
        expect(handler.oscCallCount, equals(1));
        expect(handler.lastOscCommand, equals(2));
        expect(handler.lastOscPayload, equals('ok-title'));
      },
    );

    test(
      'Handles split ST, non-ST ESC aborts, and C0 inside oscEscape cleanly',
      () {
        final handler = _TestTerminalHandler();
        final parser = AnsiParser(handler);

        // Split ST (\x1b then \\) dispatches OSC without leaking esc('\\').
        parser.parse('\x1b]52;c;aGk=\x1b');
        expect(handler.oscCallCount, equals(0));
        parser.parse('\\Z');
        expect(handler.oscCallCount, equals(1));
        expect(handler.lastOscCommand, equals(52));
        expect(handler.lastOscPayload, equals('c;aGk='));
        expect(handler.escCommands, isEmpty);
        expect(handler.printedText.toString(), equals('Z'));

        // Unterminated OSC followed by ESC [ (non-ST) aborts OSC and executes CSI.
        handler.printedText.clear();
        parser.parse('\x1b]0;unterminated\x1b[2 q');
        expect(handler.oscCallCount, equals(1));
        expect(handler.lastCsiCommand, equals('q'));
        expect(handler.lastCsiParams, equals([2]));
        expect(handler.lastCsiIntermediate, equals(' '));

        // C0 control inside oscEscape (\x1b\n\\) resets to ground without phantom osc(-1, '').
        parser.parse('\x1b]52;c;aGk=\x1b\n\\');
        expect(handler.oscCallCount, equals(1));
        expect(handler.printedText.toString(), equals(r'\'));
      },
    );

    test(
      'Parses colon-delimited subparameters while keeping pure semicolon sequences subparams-free',
      () {
        final handler = _TestTerminalHandler();
        final parser = AnsiParser(handler);

        // Pure semicolon sequence keeps subparams null.
        parser.parse('\x1b[1;38;2;10;20;30m');
        expect(handler.lastCsiCommand, equals('m'));
        expect(handler.lastCsiParams, equals([1, 38, 2, 10, 20, 30]));
        expect(handler.lastCsiSubparams, isNull);

        // Mixed semicolon + colon sequence aligns subparams length with params.
        parser.parse('\x1b[1;4:3;38:2::66:133:244;49m');
        expect(handler.lastCsiCommand, equals('m'));
        expect(handler.lastCsiParams, equals([1, 4, 38, 49]));
        expect(
          handler.lastCsiSubparams,
          equals([
            null,
            [3],
            [2, 0, 66, 133, 244],
            null,
          ]),
        );

        // Leading/trailing semicolons and trailing colons align params/subparams.
        parser.parse('\x1b[;4:3m');
        expect(handler.lastCsiParams, equals([0, 4]));
        expect(
          handler.lastCsiSubparams,
          equals([
            null,
            [3],
          ]),
        );

        parser.parse('\x1b[4:3;m');
        expect(handler.lastCsiParams, equals([4, 0]));
        expect(
          handler.lastCsiSubparams,
          equals([
            [3],
            null,
          ]),
        );

        parser.parse('\x1b[4:;1:m');
        expect(handler.lastCsiParams, equals([4, 1]));
        expect(
          handler.lastCsiSubparams,
          equals([
            [0],
            [0],
          ]),
        );

        // Leading colon at CSI entry (\x1b[:2m) and DEL ignored before '?' marker.
        parser.parse('\x1b[:2m');
        expect(handler.lastCsiParams, equals([0]));
        expect(
          handler.lastCsiSubparams,
          equals([
            [2],
          ]),
        );

        parser.parse('\x1b[\x7f?25h');
        expect(handler.lastCsiCommand, equals('h'));
        expect(handler.lastCsiIntermediate, equals('?'));
        expect(handler.lastCsiParams, equals([25]));
        expect(handler.lastCsiSubparams, isNull);

        // Caps both subparams per slot (16) and total CSI parameter slots (64).
        parser.parse('\x1b[38${':7' * 25}m');
        expect(handler.lastCsiParams, equals([38]));
        expect(handler.lastCsiSubparams, equals([List.filled(16, 7)]));

        parser.parse('\x1b[${'1:2;' * 80}m');
        expect(handler.lastCsiParams, equals(List.filled(64, 1)));
        expect(
          handler.lastCsiSubparams,
          equals(List<List<int>?>.filled(64, const [2])),
        );

        // Malformed private marker mid-param (\x1b[38?2m), digit after intermediate
        // (\x1b[38:2 0q), and CAN abort (\x1b[1:2\x18) reset CSI state cleanly.
        handler.lastCsiCommand = null;
        parser.parse('\x1b[38?2m\x1b[38:2 0q\x1b[1:2\x18OK');
        expect(handler.lastCsiCommand, isNull);
        expect('${handler.printedText}', equals('OK'));
      },
    );

    test(
      'Consumes DCS, SOS, PM, and APC control strings and unwraps tmux OSC passthrough without leaking to ground text',
      () {
        final handler = _TestTerminalHandler();
        final parser = AnsiParser(handler);

        // tmux DCS passthrough wrapping OSC 52 with inner BEL (\x07) and outer ST (\x1b\\).
        parser.parse('\x1bPtmux;\x1b\x1b]52;c;aGk=\x07\x1b\\');
        expect(handler.oscCallCount, equals(1));
        expect(handler.lastOscCommand, equals(52));
        expect(handler.lastOscPayload, equals('c;aGk='));
        expect('${handler.printedText}', isEmpty);
        expect(handler.escCommands, isEmpty);

        // tmux DCS passthrough wrapping OSC 52 with doubled inner ST (\x1b\x1b\\) and outer ST (\x1b\\),
        // fed one character at a time across split escape boundaries.
        const chunkedInput = '\x1bPtmux;\x1b\x1b]52;p;eHl6\x1b\x1b\\\x1b\\';
        for (var i = 0; i < chunkedInput.length; i++) {
          parser.parse(chunkedInput[i]);
        }
        expect(handler.oscCallCount, equals(2));
        expect(handler.lastOscCommand, equals(52));
        expect(handler.lastOscPayload, equals('p;eHl6'));
        expect('${handler.printedText}', isEmpty);

        // Non-OSC tmux passthrough (e.g. inner DCS with doubled ST), standard DCS, SOS, PM, APC, and 0x9C ST.
        parser.parse(
          '\x1bPtmux;\x1b\x1bP+q544e\x1b\x1b\\\x1b\\'
          '\x1bPq#0;2;0;0;0\r\n\x1b\\'
          '\x1bXsos-payload\x1b\\'
          '\x1b^pm-payload\x9c'
          '\x1b_Gi=31;AAAA\x1b\\Done',
        );
        expect(handler.oscCallCount, equals(2));
        expect(handler.escCommands, isEmpty);
        expect('${handler.printedText}', equals('Done'));

        // Unterminated inner OSC, inner OSC aborted by CSI/ESC, CAN (0x18), SUB (0x1A),
        // C0 in dcsEscape, and non-ST ESC [ abort DCS cleanly without dispatching OSC.
        handler.printedText.clear();
        parser.parse(
          '\x1bPtmux;\x1b\x1b]52;c;aGk=\x1b\\'
          '\x1bPtmux;\x1b\x1b]52;c;aGk=\x1b\x1b[2 q\x1b\\'
          '\x1bPtmux;\x1b\x1b]52;c;aGk=\x1b\x1b\x1b\\'
          '\x1bPtmux;\x1b\x1b]52;c;aGk=\x18'
          '\x1bPtmux;\x1b\x1b]52;c;aGk=\x1a'
          '\x1bPfoo\x1b\n'
          '\x1bPbar\x1b[3 qA',
        );
        expect(handler.oscCallCount, equals(2));
        expect(handler.lastCsiCommand, equals('q'));
        expect(handler.lastCsiParams, equals([3]));
        expect('${handler.printedText}', equals('A'));
      },
    );
  });
}
