import 'package:benchmark_harness/benchmark_harness.dart';
import 'package:termui_pty/termui_pty.dart';
import 'package:termui/termui.dart';

class CompositingBenchmark extends BenchmarkBase {
  late VirtualTerminal terminal;
  late LeafElement element;
  late Buffer targetBuffer;

  CompositingBenchmark() : super('CompositingBenchmark');

  @override
  void setup() {
    terminal = VirtualTerminal(width: 80, height: 24);

    final sb = StringBuffer();
    for (var i = 0; i < 24; i++) {
      sb.write('\x1b[31mTop process 1\x1b[0m\n');
    }
    terminal.write(sb.toString().codeUnits);

    final widget = _RawTerminalBufferWidget(buffer: terminal.buffer);
    element = widget.createElement() as _RawTerminalBufferElement;
    targetBuffer = Buffer(100, 30);
  }

  @override
  void run() {
    // 1000 compositions
    for (var i = 0; i < 1000; i++) {
      element.performPaint(targetBuffer, const Offset(10, 5));
    }
  }

  @override
  void teardown() {
    // Teardown
  }
}

class _RawTerminalBufferWidget extends Widget {
  final Buffer buffer;

  const _RawTerminalBufferWidget({required this.buffer});

  @override
  Element createElement() => _RawTerminalBufferElement(this);
}

class _RawTerminalBufferElement extends LeafElement {
  _RawTerminalBufferElement(_RawTerminalBufferWidget super.widget);

  @override
  Size performLayout(BoxConstraints constraints) {
    return constraints.constrain(Size(80, 24));
  }

  @override
  void performPaint(Buffer buffer, Offset offset) {
    final w = widget as _RawTerminalBufferWidget;
    final source = w.buffer;

    final startX = offset.dx.toInt();
    final startY = offset.dy.toInt();
    final endX = (startX + source.width).clamp(0, buffer.width);
    final endY = (startY + source.height).clamp(0, buffer.height);

    if (startX < endX && startY < endY) {
      for (var ty = startY; ty < endY; ty++) {
        final sy = ty - startY;
        for (var tx = startX; tx < endX; tx++) {
          final sx = tx - startX;

          final char = source.getCharacter(sx, sy);
          final fg = source.getForeground(sx, sy);
          final bg = source.getBackground(sx, sy);
          final mod = source.getModifiers(sx, sy);

          if ((mod & Modifier.transparent) == 0) {
            buffer.setCell(tx, ty, char, fg, bg, mod);
          }
        }
      }
    }
  }
}

void main() {
  CompositingBenchmark().report();
}
