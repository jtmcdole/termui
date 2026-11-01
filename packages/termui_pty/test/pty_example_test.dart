import 'dart:async';
import 'dart:io';
import 'package:termui/termui.dart';
import 'package:termui_pty/termui_pty.dart';
import 'package:termui_test/termui_test.dart';
import 'package:test/test.dart';
import 'package:pty2/pty2.dart';

class MockPseudoTerminal implements PseudoTerminal {
  final _outCtrl = StreamController<String>.broadcast();
  final _exitCompleter = Completer<int>();

  @override
  Stream<String> get out => _outCtrl.stream;
  @override
  void write(String data) {}
  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    if (!_exitCompleter.isCompleted) {
      _exitCompleter.complete(0);
    }
    _outCtrl.close();
    return true;
  }

  @override
  Future<int> get exitCode => _exitCompleter.future;
  @override
  void resize(int columns, int rows) {}
  @override
  void ackProcessed() {}
  @override
  void init() {}
}

void main() {
  test('PromptRunner debug toggles and draws cursor', () {
    final tester = TerminalTester();

    tester.run(() async {
      final pty = MockPseudoTerminal();

      final runner = PromptRunner<Object?>(
        terminal: tester.terminal,
        alternateScreen: false,
        widget: SizedBox.expand(child: PseudoTerminalView(pty: pty)),
      );

      final runFuture = runner.run();

      await tester.pump(const Duration(milliseconds: 100));

      expect(debugShowTouchesEnabled, isFalse);

      // Feed Ctrl+O
      tester.sendKey(LogicalKey('o', 'o'), control: true);

      await tester.pump(const Duration(milliseconds: 100));

      expect(debugShowTouchesEnabled, isTrue);

      // Send SGR mouse move to 10, 10 (which parses as x=10, y=10 in 1-based, or maybe 0-based?)
      // We will just send x=10, y=10 and check all nearby characters!
      tester.sendString('\x1b[<35;10;10M');

      await tester.pump(const Duration(milliseconds: 100));

      final backend = tester.terminal.backend as BufferedTerminalBackend;
      final buffer = backend.buffer!;

      bool found = false;
      for (int y = 0; y < buffer.height; y++) {
        for (int x = 0; x < buffer.width; x++) {
          if (buffer.getCharacter(x, y) == '⦿') {
            print('Found cursor at \$x, \$y');
            found = true;
          }
        }
      }
      expect(found, isTrue);

      runner.abort();
      await runFuture.catchError((_) => null);
    });
  });
}
