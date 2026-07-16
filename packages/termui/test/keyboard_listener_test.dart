import 'package:termui/termui.dart';
import 'package:termui_test/termui_test.dart';
import 'package:test/test.dart';
import 'package:fake_async/fake_async.dart';

void main() {
  test('KeyboardListener focuses and intercepts events', () {
    fakeAsync((async) {
      FocusManager.instance.setPrimaryFocus(null);
      final focusNode = FocusNode(id: 'test');
      bool gotS = false;

      final widget = KeyboardListener(
        focusNode: focusNode,
        onKeyEvent: (event) {
          if (event.baseKey == TermKey.s) {
            gotS = true;
            return true;
          }
          return false;
        },
        child: const SizedBox(width: 10, height: 10),
      );

      final backend = MockTerminalBackend();
      final terminal = Terminal(backend);

      final runner = PromptRunner(
        terminal: terminal,
        widget: widget,
        alternateScreen: false,
        mode: ExecutionMode.managed,
      );

      // ignore: unawaited_futures
      runner.run().catchError((_) {});
      async.elapse(const Duration(milliseconds: 10));

      focusNode.requestFocus();

      final handled = runner.handleKeyEvent(
        KeyEvent('s', KeyType.character, modifiers: {}),
      );

      expect(handled, isTrue);
      expect(gotS, isTrue);

      runner.abort();
      async.flushMicrotasks();
    });
  });
}
