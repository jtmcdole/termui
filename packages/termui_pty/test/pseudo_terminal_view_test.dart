import 'package:termui/termui.dart';
import 'package:test/test.dart';
import 'package:pty2/pty2.dart';
import 'dart:async';
import 'dart:io';
import 'package:termui_test/termui_test.dart';
import 'package:termui_pty/termui_pty.dart';

class MockPty implements PseudoTerminal {
  final _outController = StreamController<String>.broadcast();
  final _exitCodeCompleter = Completer<int>();
  List<String> written = [];

  @override
  void ackProcessed() {}

  @override
  Future<int> get exitCode => _exitCodeCompleter.future;

  @override
  void init() {}

  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    if (!_exitCodeCompleter.isCompleted) {
      _exitCodeCompleter.complete(0);
    }
    return true;
  }

  @override
  Stream<String> get out => _outController.stream;

  @override
  void resize(int width, int height) {}

  @override
  void write(String input) {
    written.add(input);
  }

  void simulateOutput(String output) {
    _outController.add(output);
  }

  void simulateExit([int code = 0]) {
    if (!_exitCodeCompleter.isCompleted) {
      _exitCodeCompleter.complete(code);
    }
    _outController.close();
  }
}

void main() {
  setUp(() {
    FocusManager.instance.setPrimaryFocus(null);
  });

  test('PseudoTerminalView renders PTY output and routes keys', () {
    final mockPty = MockPty();
    final tester = TerminalTester();

    tester.run(() async {
      final platformView = PseudoTerminalView(pty: mockPty);

      await tester.pumpWidget(platformView);
      await tester.pump();

      // Simulate ansi output
      mockPty.simulateOutput('\x1b[1;1HHello');
      await tester.pump();

      // Assert it prints Hello
      expect(tester.buffer!.characters.join(''), contains('Hello'));

      // Unmount the widget so Focus bindings detach and don't leave timers
      await tester.pumpWidget(const SizedBox());
    });
  });

  test(
    'PseudoTerminalView completes enclosing PromptRunner when PTY process exits',
    () {
      final tester = TerminalTester();

      tester.run(() async {
        final mockPty = MockPty();
        final runner = PromptRunner<int>(
          terminal: tester.terminal,
          alternateScreen: false,
          widget: SizedBox.expand(child: PseudoTerminalView(pty: mockPty)),
        );
        addTearDown(() => runner.abort());

        var completed = false;
        Object? exitResult;
        final runFuture = runner.run().then((res) {
          completed = true;
          exitResult = res;
        });

        await tester.pump(const Duration(milliseconds: 50));
        expect(completed, isFalse);

        // Simulate user pressing 'q' inside top, which is forwarded to the PTY
        // and causes the PTY process to exit with a non-zero status after EOF.
        tester.sendKey(LogicalKey('q', 'q'));
        await tester.pump(const Duration(milliseconds: 50));
        expect(mockPty.written, contains('q'));

        mockPty.simulateExit(42);
        await tester.pump(const Duration(milliseconds: 50));

        expect(completed, isTrue);
        expect(exitResult, equals(42));
        await runFuture;
      });
    },
  );
}
