import 'package:termui/termui.dart';
import 'package:termui_test/termui_test.dart';
import 'package:test/test.dart';

class TestStatefulWidget extends StatefulWidget {
  final int value;

  const TestStatefulWidget({required this.value, super.key});

  @override
  State<TestStatefulWidget> createState() => TestStatefulWidgetState();
}

class TestStatefulWidgetState extends State<TestStatefulWidget> {
  int reassembleCount = 0;
  int buildCount = 0;

  @override
  void reassemble() {
    super.reassemble();
    reassembleCount++;
  }

  @override
  Widget build(BuildContext context) {
    buildCount++;
    return Text(
      'Value: ${widget.value}, Reassemble: $reassembleCount, Build: $buildCount',
    );
  }
}

void main() {
  group('Hot Reload Reassemble', () {
    test('reassemble propagates down the tree', () async {
      final terminal = MockTerminalBackend();
      final runner = PromptRunner<void>(
        terminal: Terminal(terminal),
        widget: const TestStatefulWidget(value: 1),
        mode: ExecutionMode.managed,
      );

      runner.run();
      await Future.delayed(Duration.zero); // Let the first frame render

      final rootElement = runner.rootElement!;
      final statefulElement = findElement<StatefulElement>(
        rootElement,
        (e) => e.widget is TestStatefulWidget,
      );
      expect(statefulElement, isNotNull);

      final state =
          (statefulElement as StatefulElement).state as TestStatefulWidgetState;
      expect(state.reassembleCount, 0);
      expect(state.buildCount, 1);

      // Trigger hot reload reassemble
      runner.reassemble();
      await Future.delayed(
        Duration.zero,
      ); // Allow microtask to process scheduleRender

      expect(state.reassembleCount, 1);
      expect(state.buildCount, 2);

      runner.dispose();
    });
  });
}

Element? findElement<T extends Element>(
  Element root,
  bool Function(Element) predicate,
) {
  if (root is T && predicate(root)) return root;
  Element? found;
  root.visitChildren((child) {
    if (found != null) return;
    found = findElement<T>(child, predicate);
  });
  return found;
}
