import 'package:termui/termui.dart';
import 'package:termui_test/termui_test.dart';
import 'package:termui_recorder/termui_recorder.dart';
import 'package:test/test.dart';

class _TestBackground extends Widget {
  final Widget child;
  const _TestBackground({required this.child});
  @override
  Element createElement() => _TestBackgroundElement(this);
}

class _TestBackgroundElement extends SingleChildElement {
  _TestBackgroundElement(super.widget);

  @override
  Widget? get childWidget => (widget as _TestBackground).child;

  @override
  Size performLayout(BoxConstraints constraints) {
    if (childElement != null) {
      childElement!.relativeOffset = Offset.zero;
      return childElement!.layout(constraints);
    }
    return constraints.constrain(Size.zero);
  }

  @override
  void performPaint(Buffer buffer, Offset offset) {
    for (var y = 0; y < size.height; y++) {
      for (var x = 0; x < size.width; x++) {
        buffer.setAttributes(
          (offset.dx + x).toInt(),
          (offset.dy + y).toInt(),
          char: '\u2591',
          fg: 0xFF888888,
        );
      }
    }
    super.performPaint(buffer, offset);
  }
}

void main() {
  test('Column layout constraint violation should render visible warning', () {
    final tester = TerminalTester();
    tester.run(() async {
      final widget = ModalOverlay(
        title: 'Test Modal',
        width: 80,
        height: 24,
        dialogBounds: const Rect(10, 5, 60, 10),
        modalFocusNodes: const [],
        child: Column(List.generate(30, (i) => Text('Row $i'))),
      );

      await tester.pumpWidget(widget, size: const Size(80, 24));

      final buffer = tester.buffer!;
      final text = buffer.characters.join();
      final foundWarning = text.contains('\u259C') || text.contains('\u2599');

      expect(
        foundWarning,
        isTrue,
        reason: 'Expected a visual warning for layout overflow.',
      );
    });
  });

  test('Overflow caution tape renders correctly (Golden)', () {
    final tester = TerminalTester();
    tester.run(() async {
      // 50x30 terminal, overflowing widget in the middle taking half width/height
      final widget = Center(
        child: SizedBox(
          width: 25,
          height: 15,
          child: _TestBackground(
            child: Column(List.generate(30, (i) => Text('Overflowing Row $i'))),
          ),
        ),
      );

      await tester.pumpWidget(widget, size: const Size(50, 30));

      expect(
        tester.buffer,
        matchesAnsiGolden('test/goldens/overflow_caution_tape.ansi'),
      );
    });
  });
  test('Row overflow caution tape renders correctly (Golden)', () {
    final tester = TerminalTester();
    tester.run(() async {
      final widget = Center(
        child: SizedBox(
          width: 25,
          height: 15,
          child: _TestBackground(
            child: Row(
              List.generate(
                30,
                (i) => SizedBox(width: 5, child: Text('Col$i ')),
              ),
            ),
          ),
        ),
      );

      await tester.pumpWidget(widget, size: const Size(50, 30));

      expect(
        tester.buffer,
        matchesAnsiGolden('test/goldens/overflow_caution_tape_row.ansi'),
      );
    });
  });

  test('Multi-directional overflow caution tape renders correctly (Golden)', () {
    final tester = TerminalTester();
    tester.run(() async {
      final widget = Center(
        child: SizedBox(
          width: 25,
          height: 15,
          child: _TestBackground(
            child: Column(
              List.generate(
                30, // Overflow Bottom
                (i) => Row(
                  [
                    Text(
                      'Extremely Long Overflowing Row $i That Goes Off Screen',
                    ),
                  ],
                  mainAxisAlignment:
                      MainAxisAlignment.center, // Overflow Left and Right
                ),
              ),
            ),
          ),
        ),
      );

      await tester.pumpWidget(widget, size: const Size(50, 30));

      expect(
        tester.buffer,
        matchesAnsiGolden('test/goldens/overflow_caution_tape_multi.ansi'),
      );
    });
  });

  test('Omni-directional overflow caution tape renders correctly (Golden)', () {
    final tester = TerminalTester();
    tester.run(() async {
      final widget = Center(
        child: SizedBox(
          width: 25,
          height: 15,
          child: _TestBackground(
            child: Column(
              List.generate(
                30,
                (i) => Row(
                  [
                    Text(
                      'Extremely Long Overflowing Row $i That Goes Off Screen',
                    ),
                  ],
                  mainAxisAlignment:
                      MainAxisAlignment.center, // Overflow Left and Right
                ),
              ),
              mainAxisAlignment:
                  MainAxisAlignment.center, // Overflow Top and Bottom
            ),
          ),
        ),
      );

      await tester.pumpWidget(widget, size: const Size(50, 30));

      expect(
        tester.buffer,
        matchesAnsiGolden('test/goldens/overflow_caution_tape_omni.ansi'),
      );
    });
  });
}
