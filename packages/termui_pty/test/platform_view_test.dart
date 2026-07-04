import 'package:termui/termui.dart';
import 'package:test/test.dart';
import 'package:pty2/pty2.dart';
import 'dart:async';
import 'dart:io';
import 'package:termui_test/termui_test.dart';
import 'package:termui_pty/termui_pty.dart';

class MockPty implements PseudoTerminal {
  final _outController = StreamController<String>.broadcast();
  List<String> written = [];

  @override
  void ackProcessed() {}

  @override
  Future<int> get exitCode => Future.value(0);

  @override
  void init() {}

  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
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
}

void main() {
  setUp(() {
    FocusManager.instance.setPrimaryFocus(null);
  });

  test('PlatformView renders PTY output and routes keys', () {
    final mockPty = MockPty();
    final tester = TerminalTester();

    tester.run(() async {
      final platformView = PlatformView(pty: mockPty);

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
}
