import 'dart:async';
import 'package:fake_async/fake_async.dart';
import 'package:termui/termui.dart';
import 'package:termui_test/termui_test.dart';
import 'package:test/test.dart';

class AsyncTestWidget extends StatefulWidget {
  final Future<void> future;
  const AsyncTestWidget({required this.future, super.key});

  @override
  State<AsyncTestWidget> createState() => _AsyncTestWidgetState();
}

class _AsyncTestWidgetState extends State<AsyncTestWidget> {
  String _status = 'Loading...';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    await widget.future;
    if (mounted) {
      setState(() {
        _status = 'Loaded!';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Text(_status);
  }
}

void main() {
  group('ExecutionMode.managed Async setState Tests', () {
    late MockTerminalBackend backend;
    late MockTerminal terminal;
    late SceneManager sceneManager;

    setUp(() {
      FocusManager.instance.setPrimaryFocus(null);
      backend = MockTerminalBackend();
      terminal = MockTerminal(backend);
      sceneManager = SceneManager(terminal);
    });

    tearDown(() {
      sceneManager.dispose();
      FocusManager.instance.setPrimaryFocus(null);
    });

    test('automatic repaint propagation on async setState', () {
      fakeAsync((async) {
        final completer = Completer<void>();

        final runner = PromptRunner<void>(
          terminal: terminal,
          widget: AsyncTestWidget(future: completer.future),
          mode: ExecutionMode.managed,
        );

        final layer = SceneLayer(
          renderer: runner,
          sizing: LayerSizing.fixed,
          x: 0,
          y: 0,
          width: 20,
          height: 1,
        );

        sceneManager.layers.add(layer);

        // Start runner
        unawaited(runner.run());
        async.flushMicrotasks();

        // Perform initial composition
        sceneManager.render();

        final initialFront = sceneManager.renderer!.frontBuffer;
        // Verify loading text is present
        expect(initialFront.getCharacter(0, 0), equals('L'));
        expect(initialFront.getCharacter(9, 0), equals('.'));

        // Complete the async operation
        completer.complete();
        async.flushMicrotasks();

        // The scene manager should have automatically repainted
        final updatedFront = sceneManager.renderer!.frontBuffer;
        expect(updatedFront.getCharacter(0, 0), equals('L'));
        expect(updatedFront.getCharacter(1, 0), equals('o'));
        expect(updatedFront.getCharacter(2, 0), equals('a'));
        expect(updatedFront.getCharacter(3, 0), equals('d'));
        expect(updatedFront.getCharacter(4, 0), equals('e'));
        expect(updatedFront.getCharacter(5, 0), equals('d'));
        expect(updatedFront.getCharacter(6, 0), equals('!'));
        expect(updatedFront.getCharacter(7, 0), equals(' '));
      });
    });

    test('releasing update listener on layer removal', () {
      final runner = PromptRunner<void>(
        terminal: terminal,
        widget: const Text('Layer'),
        mode: ExecutionMode.managed,
      );

      final layer = SceneLayer(
        renderer: runner,
        sizing: LayerSizing.fixed,
        x: 0,
        y: 0,
        width: 10,
        height: 1,
      );

      expect(runner.onNeedVisualUpdate, isNull);

      sceneManager.layers.add(layer);
      expect(runner.onNeedVisualUpdate, isNotNull);

      sceneManager.layers.remove(layer);
      expect(runner.onNeedVisualUpdate, isNull);
    });

    test('other list mutating operations work without throwing', () {
      final runner1 = PromptRunner<void>(
        terminal: terminal,
        widget: const Text('L1'),
        mode: ExecutionMode.managed,
      );
      final runner2 = PromptRunner<void>(
        terminal: terminal,
        widget: const Text('L2'),
        mode: ExecutionMode.managed,
      );

      final layer1 = SceneLayer(
        renderer: runner1,
        sizing: LayerSizing.fixed,
        x: 0,
        y: 0,
        width: 10,
        height: 1,
      );
      final layer2 = SceneLayer(
        renderer: runner2,
        sizing: LayerSizing.fixed,
        x: 0,
        y: 0,
        width: 10,
        height: 1,
      );

      // insertAll should not throw a type cast error
      expect(
        () => sceneManager.layers.insertAll(0, [layer1, layer2]),
        returnsNormally,
      );
      expect(sceneManager.layers.length, equals(2));
      expect(runner1.onNeedVisualUpdate, isNotNull);
      expect(runner2.onNeedVisualUpdate, isNotNull);

      // removeWhere should update listeners correctly
      sceneManager.layers.removeWhere((l) => l == layer1);
      expect(sceneManager.layers.length, equals(1));
      expect(runner1.onNeedVisualUpdate, isNull);
      expect(runner2.onNeedVisualUpdate, isNotNull);
    });
  });
}
