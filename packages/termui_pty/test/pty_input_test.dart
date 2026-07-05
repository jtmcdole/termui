import 'dart:async';
import 'dart:io';
import 'package:termui/termui.dart';
import 'package:termui_pty/termui_pty.dart';
import 'package:termui_test/termui_test.dart';
import 'package:test/test.dart';
import 'package:pty2/pty2.dart';

class MockPseudoTerminal implements PseudoTerminal {
  final _outCtrl = StreamController<String>.broadcast();
  final writtenData = <String>[];

  @override
  Stream<String> get out => _outCtrl.stream;

  @override
  void write(String data) {
    writtenData.add(data);
  }

  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) => true;

  @override
  Future<int> get exitCode => Future.value(0);

  @override
  void resize(int columns, int rows) {}

  @override
  void ackProcessed() {}

  @override
  void init() {}
}

void main() {
  test('PseudoTerminalView forwards mouse and keyboard events to PTY', () {
    debugShowTouchesEnabled = false;
    final tester = TerminalTester();
    final pty = MockPseudoTerminal();

    tester.run(() async {
      final runner = PromptRunner(
        terminal: tester.terminal,
        alternateScreen: false,
        widget: SizedBox.expand(child: PseudoTerminalView(pty: pty)),
      );

      final runFuture = runner.run();
      await tester.pump(const Duration(milliseconds: 100));

      // Send 'A' via keyboard
      tester.sendKey(LogicalKey('A', 'a'));
      await tester.pump(const Duration(milliseconds: 100));

      // Enable mouse tracking in the VirtualTerminal (like a real program would)
      pty._outCtrl.add('\x1b[?1000h\x1b[?1006h');
      await tester.pump(const Duration(milliseconds: 100));

      // Send a mouse event at x=10, y=5.
      // PseudoTerminalView should receive this and encode it to SGR format.
      // SGR Mouse format: \x1b[<cb;x;yM
      // A left click (button 0) at x=10, y=5 is \x1b[<0;10;5M
      tester.sendString('\x1b[<0;10;5M');
      await tester.pump(const Duration(milliseconds: 100));

      final outputString = pty.writtenData.join();

      // We expect 'a' (from keyboard) and then the encoded mouse event
      // PseudoTerminalView encodes mouse events into SGR format: \x1b[<0;10;5M
      expect(outputString, contains('A'));
      expect(outputString, contains('\x1b[<0;10;5M'));

      runner.abort();
      await runFuture.catchError((_) {});
    });
  });
}
