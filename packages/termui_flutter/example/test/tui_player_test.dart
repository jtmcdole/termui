import 'package:flutter_test/flutter_test.dart';
import 'package:termui_test/termui_test.dart';
import 'package:termui/termui.dart';
import 'package:example_flutter/src/tui_player/run_tui_player.dart';

void main() {
  setUp(() {
    FocusManager.instance.setPrimaryFocus(null);
  });

  group('TUI Player Integration Tests', () {
    test('TUI Player starts, renders frame, and exits on Ctrl+C', () async {
      final backend = MockTerminalBackend();
      final terminal = Terminal(backend);

      // Start the TUI player in the mock backend
      final playerFuture = runAsciicastPlayerTui(terminal);

      try {
        // Let initial frame renders complete
        await Future.delayed(const Duration(milliseconds: 100));

        // Assert player has rendered header bar and control strings
        final allWrites = backend.writes.join('');
        expect(allWrites.contains('TERMUI TUI PLAYER'), isTrue);
        expect(
          allWrites.contains('PLAYING') || allWrites.contains('PAUSED'),
          isTrue,
        );
        expect(allWrites.contains('Space'), isTrue); // Hint text

        // Inject Ctrl+C to terminate the PromptRunner loop
        backend.pushBytes('\x03'.codeUnits);
        await Future.delayed(const Duration(milliseconds: 100));
      } finally {
        terminal.dispose();
        await playerFuture;
      }
    });
  });
}
