import 'dart:async';
import 'package:termui/termui.dart';
import 'package:termui/terminal/event.dart' as ui;
import 'package:termui_test/termui_test.dart';
import 'package:test/test.dart';

class ClickableWidget extends Widget {
  final void Function() onClick;
  const ClickableWidget({required this.onClick});

  @override
  int getIntrinsicHeight(int width) => 10;

  @override
  Element createElement() => _ClickableElement(this);
}

class _ClickableElement extends Element implements MouseEventHandler {
  _ClickableElement(super.widget);

  @override
  Size performLayout(BoxConstraints constraints) {
    return constraints.constrain(const Size(10, 10));
  }

  @override
  void performPaint(Buffer buffer, Offset offset) {}

  @override
  void handleMouseEvent(ui.MouseEvent event, int localX, int localY) {
    if (event.type == ui.MouseEventType.press) {
      (widget as ClickableWidget).onClick();
    }
  }
}

void main() {
  group('AbsorbPointer Widget Tests', () {
    late MockTerminalBackend backend;
    late MockTerminal terminal;

    setUp(() {
      backend = MockTerminalBackend();
      terminal = MockTerminal(backend);
    });

    tearDown(() {
      terminal.dispose();
    });

    test(
      'AbsorbPointer with absorbing: true absorbs mouse press event',
      () async {
        var clicked = false;
        final runner = PromptRunner<void>(
          terminal: terminal,
          widget: AbsorbPointer(
            absorbing: true,
            child: ClickableWidget(
              onClick: () {
                clicked = true;
              },
            ),
          ),
        );

        final future = runner.run();
        await Future.delayed(const Duration(milliseconds: 10));

        // Inject press at x: 2, y: 2 (1-based, inside child widget)
        final click = const ui.MouseEvent(
          x: 2,
          y: 2,
          button: ui.MouseButton.left,
          type: ui.MouseEventType.press,
        );
        terminal.injectTestEvent(click);
        await Future.delayed(const Duration(milliseconds: 10));

        expect(clicked, isFalse);

        runner.dispose();
        await future;
      },
    );

    test(
      'AbsorbPointer with absorbing: false propagates mouse press event',
      () async {
        var clicked = false;
        final runner = PromptRunner<void>(
          terminal: terminal,
          widget: AbsorbPointer(
            absorbing: false,
            child: ClickableWidget(
              onClick: () {
                clicked = true;
              },
            ),
          ),
        );

        final future = runner.run();
        await Future.delayed(const Duration(milliseconds: 10));

        // Inject press at x: 2, y: 2
        final click = const ui.MouseEvent(
          x: 2,
          y: 2,
          button: ui.MouseButton.left,
          type: ui.MouseEventType.press,
        );
        terminal.injectTestEvent(click);
        await Future.delayed(const Duration(milliseconds: 10));

        expect(clicked, isTrue);

        runner.dispose();
        await future;
      },
    );
  });
}
