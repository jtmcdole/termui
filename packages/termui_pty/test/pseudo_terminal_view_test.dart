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
    final tester = TerminalTester();

    tester.run(() async {
      final mockPty = MockPty();
      final platformView = PseudoTerminalView(pty: mockPty);

      await tester.pumpWidget(platformView);
      await tester.pump();

      // Simulate ansi output
      mockPty.simulateOutput('\x1b[1;1HHello');
      await tester.pump();

      // Assert it prints Hello
      expect(tester.buffer!.characters.join(''), contains('Hello'));

      // Terminal query replies (e.g. DSR 5n) are written back to the PTY while active,
      // and suppressed once exitCode completes.
      mockPty.simulateOutput('\x1b[5n');
      await tester.pump();
      expect(mockPty.written, contains('\x1b[0n'));
      mockPty.written.clear();
      mockPty.kill();
      await tester.pump(const Duration(milliseconds: 1));
      mockPty.simulateOutput('\x1b[5n');
      await tester.pump();
      expect(mockPty.written, isEmpty);

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

  test(
    'PseudoTerminalView didUpdateWidget swaps pty subscription and focusNode cleanly',
    () {
      final tester = TerminalTester();

      tester.run(() async {
        final pty1 = MockPty();
        final pty2 = MockPty();
        final externalFocus = FocusNode(id: 'external_pty_focus');
        addTearDown(externalFocus.dispose);

        late void Function(PseudoTerminal, FocusNode?) updateChild;

        final runner = PromptRunner<int>(
          terminal: tester.terminal,
          alternateScreen: false,
          widget: _PtyHostSwitcher(
            initialPty: pty1,
            onReady: (updater) => updateChild = updater,
          ),
        );
        addTearDown(runner.abort);

        final runFuture = runner.run();
        await tester.pump(const Duration(milliseconds: 50));

        final backend = tester.terminal.backend as MockTerminalBackend;
        pty1.simulateOutput('\x1b[1;1HFirstPty©');
        await tester.pump(const Duration(milliseconds: 50));
        expect(backend.writes.join(), contains('FirstPty©'));

        tester.sendKey(LogicalKey('a', 'a'));
        await tester.pump(const Duration(milliseconds: 50));
        expect(pty1.written, contains('a'));

        // Swap to pty2 and an external FocusNode via didUpdateWidget
        updateChild(pty2, externalFocus);
        await tester.pump(const Duration(milliseconds: 50));
        externalFocus.requestFocus();
        await tester.pump(const Duration(milliseconds: 50));

        // Output from old pty1 must no longer be subscribed
        pty1.written.clear();
        backend.writes.clear();
        pty1.simulateOutput('\x1b[2;1HStaleOutput');
        pty2.simulateOutput('\x1b[2;1HSecondPty');
        await tester.pump(const Duration(milliseconds: 50));
        expect(backend.writes.join(), isNot(contains('StaleOutput')));
        expect(backend.writes.join(), contains('SecondPty'));

        tester.sendKey(LogicalKey('z', 'z'));
        await tester.pump(const Duration(milliseconds: 50));
        expect(pty2.written, contains('z'));
        expect(pty1.written, isEmpty);

        // Swap back to null focusNode (internally owned) without disposing externalFocus
        updateChild(pty2, null);
        await tester.pump(const Duration(milliseconds: 50));
        expect(() => externalFocus.requestFocus(), returnsNormally);

        pty2.simulateExit(7);
        await tester.pump(const Duration(milliseconds: 50));
        expect(await runFuture, equals(7));
      });
    },
  );
}

class _PtyHostSwitcher extends StatefulWidget {
  final PseudoTerminal initialPty;
  final void Function(void Function(PseudoTerminal, FocusNode?) updater)
  onReady;

  const _PtyHostSwitcher({required this.initialPty, required this.onReady});

  @override
  State<_PtyHostSwitcher> createState() => _PtyHostSwitcherState();
}

class _PtyHostSwitcherState extends State<_PtyHostSwitcher> {
  late PseudoTerminal _pty = widget.initialPty;
  FocusNode? _focusNode;

  @override
  void initState() {
    super.initState();
    widget.onReady((nextPty, nextFocus) {
      if (!mounted) return;
      setState(() {
        _pty = nextPty;
        _focusNode = nextFocus;
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox.expand(
      child: PseudoTerminalView(pty: _pty, focusNode: _focusNode),
    );
  }
}
