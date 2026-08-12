import 'package:test/test.dart';
import 'package:termui/termui.dart';
import 'package:termui_recorder/termui_recorder.dart';

class GradientBox extends Widget {
  final int width;
  final int height;
  final String char;
  final int startFg;
  final int endFg;
  final int startBg;
  final int endBg;

  const GradientBox({
    required this.width,
    required this.height,
    required this.char,
    required this.startFg,
    required this.endFg,
    required this.startBg,
    required this.endBg,
  });

  @override
  Element createElement() => GradientBoxElement(this);
}

class GradientBoxElement extends Element {
  GradientBoxElement(GradientBox super.widget);

  @override
  Size performLayout(BoxConstraints constraints) {
    final w = widget as GradientBox;
    return constraints.constrain(Size(w.width, w.height));
  }

  @override
  void performPaint(Buffer buffer, Offset offset) {
    final w = widget as GradientBox;

    for (int y = 0; y < w.height; y++) {
      for (int x = 0; x < w.width; x++) {
        double t = x / (w.width - 1);
        t = (t * 20).floor() / 20.0;

        int fgA = _lerp(w.startFg.a, w.endFg.a, t);
        int fgR = _lerp(w.startFg.r, w.endFg.r, t);
        int fgG = _lerp(w.startFg.g, w.endFg.g, t);
        int fgB = _lerp(w.startFg.b, w.endFg.b, t);
        int fg = (fgA << 24) | (fgR << 16) | (fgG << 8) | fgB;

        int bgA = _lerp(w.startBg.a, w.endBg.a, t);
        int bgR = _lerp(w.startBg.r, w.endBg.r, t);
        int bgG = _lerp(w.startBg.g, w.endBg.g, t);
        int bgB = _lerp(w.startBg.b, w.endBg.b, t);
        int bg = (bgA << 24) | (bgR << 16) | (bgG << 8) | bgB;

        buffer.setAttributes(
          offset.dx.toInt() + x,
          offset.dy.toInt() + y,
          char: w.char,
          fg: fg,
          bg: bg,
        );
      }
    }
  }

  int _lerp(int a, int b, double t) {
    return (a + (b - a) * t).round().clamp(0, 255);
  }
}

int makeColor(int a, int r, int g, int b) {
  return (a << 24) | (r << 16) | (g << 8) | b;
}

void main() {
  group('Stack Alpha Blending', () {
    test('blends background of single box', () {
      final stack = Stack([
        GradientBox(
          width: 50,
          height: 10,
          char: ' ',
          startFg: makeColor(255, 0, 0, 0),
          endFg: makeColor(255, 0, 0, 0),
          startBg: makeColor(255, 0, 0, 0), // black
          endBg: makeColor(255, 0, 0, 0),
        ),
        GradientBox(
          width: 50,
          height: 10,
          char: '+',
          startFg: makeColor(255, 255, 255, 0), // yellow
          endFg: makeColor(255, 255, 255, 0),
          startBg: makeColor(255, 0, 0, 255), // blue opaque
          endBg: makeColor(0, 0, 0, 255), // blue transparent
        ),
      ]);

      final buffer = Buffer.blank(50, 10);
      ElementWidget(stack)
        ..layout(BoxConstraints.tight(const Size(50, 10)))
        ..paint(buffer, Offset.zero);

      expect(
        buffer,
        matchesAnsiGolden(
          'test/goldens/stack_blend_single.ansi',
          environment: {'GENERATE_GOLDENS': 'true'},
        ),
      );
    });

    test('blends foreground and background of two boxes', () {
      final stack = Stack([
        GradientBox(
          width: 50,
          height: 10,
          char: ' ',
          startFg: makeColor(255, 0, 0, 0),
          endFg: makeColor(255, 0, 0, 0),
          startBg: makeColor(255, 0, 0, 0), // black
          endBg: makeColor(255, 0, 0, 0),
        ),
        GradientBox(
          width: 50,
          height: 10,
          char: '+',
          startFg: makeColor(255, 255, 255, 0), // yellow
          endFg: makeColor(255, 255, 255, 0),
          startBg: makeColor(255, 0, 0, 255), // blue opaque
          endBg: makeColor(0, 0, 0, 255), // blue transparent
        ),
        Positioned(
          left: 5,
          top: 2,
          child: GradientBox(
            width: 40,
            height: 5,
            char: '-',
            startFg: makeColor(255, 255, 0, 0), // red opaque
            endFg: makeColor(0, 255, 0, 0), // red transparent
            startBg: makeColor(0, 0, 255, 0), // green transparent
            endBg: makeColor(255, 0, 255, 0), // green opaque
          ),
        ),
      ]);

      final buffer = Buffer.blank(50, 10);
      ElementWidget(stack)
        ..layout(BoxConstraints.tight(const Size(50, 10)))
        ..paint(buffer, Offset.zero);

      expect(
        buffer,
        matchesAnsiGolden(
          'test/goldens/stack_blend_double.ansi',
          environment: {'GENERATE_GOLDENS': 'true'},
        ),
      );
    });
  });
}
