import 'dart:convert';

import 'package:checks/checks.dart';
import 'package:termui/termui.dart';
import 'package:termui_cast_protocol/termui_cast_protocol.dart';
import 'package:termui_caster_cli/src/authoritative_terminal.dart';
import 'package:termui_caster_cli/src/caster_service.dart';
import 'package:test/test.dart';

void main() {
  group('CasterConfig --color-scheme parsing', () {
    test('parses default dark color-scheme', () {
      final config = CasterConfig.fromArgs([
        '--session-id',
        'test-1',
        '--',
        'echo',
        'hello',
      ]);
      check(config).isNotNull();
      check(config!.colorScheme).equals(TerminalBrightness.dark);
    });

    test('parses explicit light color-scheme flag', () {
      final config = CasterConfig.fromArgs([
        '--session-id',
        'test-1',
        '--color-scheme',
        'light',
        '--',
        'echo',
        'hello',
      ]);
      check(config).isNotNull();
      check(config!.colorScheme).equals(TerminalBrightness.light);
    });

    test('parses TERMUI_CAST_COLOR_SCHEME environment variable', () {
      final config = CasterConfig.fromArgs(
        ['--session-id', 'test-1', '--', 'echo', 'hello'],
        environment: {'TERMUI_CAST_COLOR_SCHEME': 'light'},
      );
      check(config).isNotNull();
      check(config!.colorScheme).equals(TerminalBrightness.light);
    });

    test('rejects invalid color-scheme value', () {
      check(
        () => CasterConfig.fromArgs([
          '--session-id',
          'test-1',
          '--color-scheme',
          'solarized',
          '--',
          'echo',
          'hello',
        ]),
      ).throws<FormatException>();
    });
  });

  group('AuthoritativeTerminal emitIndexedColors: true', () {
    test('preserves Color.ansi tokens for basic ANSI colors', () {
      final auth = AuthoritativeTerminal(
        sessionId: const SessionId('test-session'),
        initialCols: 80,
        initialRows: 24,
      );
      addTearDown(auth.dispose);

      auth.writeOutput(utf8.encode('\x1b[34mdir\x1b[0m'));
      final fg = auth.buffer.getForeground(0, 0);
      check(fg.isAnsiIndexed).equals(true);
      check(fg.ansiIndex).equals(4);
    });

    test('answers CSI ? 996 n from initialTheme brightness', () {
      String? reply;
      final auth = AuthoritativeTerminal(
        sessionId: const SessionId('test-session'),
        initialCols: 80,
        initialRows: 24,
        initialTheme: TerminalColorTheme.termuiLight,
      );
      addTearDown(auth.dispose);
      auth.onTerminalReply = (r) => reply = r;

      auth.writeOutput(utf8.encode('\x1b[?996n'));
      // Light brightness replies ?997;2n
      check(reply).equals('\x1b[?997;2n');
    });
  });
}
