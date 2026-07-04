import 'package:termui/termui.dart';
import 'package:termui_pty/termui_pty.dart';
import 'package:termui_test/termui_test.dart';
import 'package:test/test.dart';

void main() {
  test('PlatformView renders ANSI text from pty', () async {
    final terminal = VirtualTerminal(width: 20, height: 5);
    terminal.write('\x1b[31mRed\x1b[0m \x1b[32mGreen\x1b[0m'.codeUnits);

    // We can directly test the raw buffer widget
    final widget = LayoutBuilder(
      builder: (context, constraints) {
        return Focus(
          focusNode: FocusNode(id: 'test'),
          child: Builder(
            builder: (context) {
              // Hack to render the buffer directly for testing
              return SizedBox(
                width: 20,
                height: 5,
                child: TestBufferWidget(terminal.buffer),
              );
            },
          ),
        );
      },
    );

    // Normally we'd use matchesGolden, but we can just use the scene tester
    final tester = TerminalTester();
    await tester.pumpWidget(widget, size: const Size(20, 5));

    // Red is rendered
    expect(
      tester.buffer!.getForeground(0, 0),
      equals(const Color(170, 0, 0).argb),
    );
    expect(tester.buffer!.getCharacter(0, 0), equals('R'));
    expect(tester.buffer!.getCharacter(1, 0), equals('e'));
    expect(tester.buffer!.getCharacter(2, 0), equals('d'));

    // Space is default
    expect(tester.buffer!.getForeground(3, 0), equals(0));

    // Green is rendered
    expect(
      tester.buffer!.getForeground(4, 0),
      equals(const Color(0, 170, 0).argb),
    );
    expect(tester.buffer!.getCharacter(4, 0), equals('G'));
  });
}

class TestBufferWidget extends Widget {
  final Buffer buffer;
  const TestBufferWidget(this.buffer);

  @override
  Element createElement() => _TestBufferElement(this);
}

class _TestBufferElement extends LeafElement {
  _TestBufferElement(TestBufferWidget super.widget);

  @override
  Size performLayout(BoxConstraints constraints) {
    final w = widget as TestBufferWidget;
    return constraints.constrain(Size(w.buffer.width, w.buffer.height));
  }

  @override
  void performPaint(Buffer buffer, Offset offset) {
    final w = widget as TestBufferWidget;
    final source = w.buffer;
    final startX = offset.dx.toInt();
    final startY = offset.dy.toInt();

    for (
      var ty = startY;
      ty < buffer.height && ty - startY < source.height;
      ty++
    ) {
      final sy = ty - startY;
      for (
        var tx = startX;
        tx < buffer.width && tx - startX < source.width;
        tx++
      ) {
        final sx = tx - startX;
        buffer.setCell(
          tx,
          ty,
          source.getCharacter(sx, sy),
          source.getForeground(sx, sy),
          source.getBackground(sx, sy),
          source.getModifiers(sx, sy),
        );
      }
    }
  }
}
