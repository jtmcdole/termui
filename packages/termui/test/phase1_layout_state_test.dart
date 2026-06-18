import 'package:test/test.dart';
import 'package:termui/ui/buffer.dart';
import 'package:termui/ui/style.dart';
import 'package:termui/ui/layout.dart';
import 'package:termui/ui/widget_toolkit.dart';

class TestWidget extends Widget {
  final String char;
  const TestWidget(this.char);

  @override
  Element createElement() => TestWidgetElement(this);
}

class TestWidgetElement extends Element {
  TestWidgetElement(TestWidget super.widget);

  @override
  Size performLayout(BoxConstraints constraints) {
    final w = constraints.maxWidth == BoxConstraints.infinity
        ? 0
        : constraints.maxWidth;
    final h = constraints.maxHeight == BoxConstraints.infinity
        ? 0
        : constraints.maxHeight;
    return constraints.constrain(Size(w, h));
  }

  @override
  void performPaint(Buffer buffer, Offset offset) {
    final w = widget as TestWidget;
    final area = Rect(offset.dx, offset.dy, size.width, size.height);
    if (w.char.length == 1) {
      for (var y = 0; y < area.height; y++) {
        for (var x = 0; x < area.width; x++) {
          buffer.setCell(area.x + x, area.y + y, Cell(w.char, Style.empty));
        }
      }
    } else {
      buffer.writeString(area.x, area.y, w.char, Style.empty);
    }
  }
}

// Stateful Test Widget
class CounterWidget extends StatefulWidget {
  final String prefix;
  const CounterWidget({required this.prefix});

  @override
  State createState() => _CounterWidgetState();
}

class _CounterWidgetState extends State<CounterWidget> {
  int count = 0;

  void increment() {
    setState(() {
      count++;
    });
  }

  @override
  Widget build(BuildContext context) {
    return TestWidget('${widget.prefix}$count');
  }
}

// Inherited Test Widget
class ThemeColor extends InheritedWidget {
  final String colorName;
  const ThemeColor({required this.colorName, required super.child});

  static ThemeColor? of(BuildContext context) {
    return context.dependOnInheritedWidgetOfExactType<ThemeColor>();
  }

  @override
  bool updateShouldNotify(ThemeColor oldWidget) {
    return colorName != oldWidget.colorName;
  }
}

class ThemeDisplay extends StatelessWidget {
  const ThemeDisplay();

  @override
  Widget build(BuildContext context) {
    final theme = ThemeColor.of(context);
    return TestWidget(theme?.colorName ?? 'None');
  }
}

void main() {
  group('EdgeInsets Tests', () {
    test('Constructors and properties', () {
      const e1 = EdgeInsets.all(2);
      expect(e1.left, 2);
      expect(e1.top, 2);
      expect(e1.right, 2);
      expect(e1.bottom, 2);

      const e2 = EdgeInsets.symmetric(vertical: 3, horizontal: 4);
      expect(e2.left, 4);
      expect(e2.top, 3);
      expect(e2.right, 4);
      expect(e2.bottom, 3);

      const e3 = EdgeInsets.only(left: 1, bottom: 2);
      expect(e3.left, 1);
      expect(e3.top, 0);
      expect(e3.right, 0);
      expect(e3.bottom, 2);
    });
  });

  group('Padding & EdgeInsets integration', () {
    test('Padding shrunken rendering', () {
      final buffer = Buffer.blank(6, 4);
      final padding = Padding(
        padding: const EdgeInsets.fromLTRB(2, 1, 1, 1),
        child: const TestWidget('X'),
      );

      final elementWrapper = ElementWidget(padding);
      elementWrapper.layout(BoxConstraints.tight(const Size(6, 4)));
      elementWrapper.paint(buffer, Offset.zero);

      // Rect bounds: left=2, top=1, right=1, bottom=1.
      // Width = 6 - 2 - 1 = 3. Height = 4 - 1 - 1 = 2.
      // Filled area relative to buffer: x in [2, 4], y in [1, 2].
      expect(buffer.getCell(0, 0)!.char, ' ');
      expect(buffer.getCell(2, 1)!.char, 'X');
      expect(buffer.getCell(3, 1)!.char, 'X');
      expect(buffer.getCell(4, 1)!.char, 'X');
      expect(buffer.getCell(5, 1)!.char, ' ');
      expect(buffer.getCell(2, 3)!.char, ' ');
    });
  });

  group('Row & Column Layout Tests', () {
    test('Row flex and sized children', () {
      final buffer = Buffer.blank(10, 1);
      final row = Row([
        const SizedBox(width: 2, child: TestWidget('A')),
        const Expanded(child: TestWidget('B')),
        const Flexible(flex: 2, child: TestWidget('C')),
      ]);

      final elementWrapper = ElementWidget(row);
      elementWrapper.layout(BoxConstraints.tight(const Size(10, 1)));
      elementWrapper.paint(buffer, Offset.zero);

      // Total width = 10.
      // Sized child width = 2. Remaining width = 8.
      // Total flex = 1 + 2 = 3.
      // B flex 1: floor(8 * 1 / 3) = 2.
      // C flex 2: remainder/allocated = 6.
      // So:
      // A (size 2): index 0, 1
      // B (flex 1, size 2): index 2, 3
      // C (flex 2, size 6): index 4, 5, 6, 7, 8, 9
      expect(buffer.getCell(0, 0)!.char, 'A');
      expect(buffer.getCell(1, 0)!.char, 'A');
      expect(buffer.getCell(2, 0)!.char, 'B');
      expect(buffer.getCell(3, 0)!.char, 'B');
      expect(buffer.getCell(4, 0)!.char, 'C');
      expect(buffer.getCell(9, 0)!.char, 'C');
    });

    test('Column flex layout', () {
      final buffer = Buffer.blank(1, 6);
      final column = Column([
        const SizedBox(height: 2, child: TestWidget('A')),
        const Expanded(child: TestWidget('B')),
      ]);

      final elementWrapper = ElementWidget(column);
      elementWrapper.layout(BoxConstraints.tight(const Size(1, 6)));
      elementWrapper.paint(buffer, Offset.zero);

      // Total height = 6.
      // Sized child = 2. Remaining = 4.
      // B takes remainder = 4.
      // y=0, 1 -> A
      // y=2, 3, 4, 5 -> B
      expect(buffer.getCell(0, 0)!.char, 'A');
      expect(buffer.getCell(0, 1)!.char, 'A');
      expect(buffer.getCell(0, 2)!.char, 'B');
      expect(buffer.getCell(0, 5)!.char, 'B');
    });
  });

  group('Stack & Positioned Layout Tests', () {
    test('Overlapping and Positioned coordinates', () {
      final buffer = Buffer.blank(5, 5);
      final stack = Stack([
        const TestWidget('A'),
        const Positioned(
          left: 1,
          top: 2,
          width: 2,
          height: 1,
          child: TestWidget('B'),
        ),
      ]);

      final elementWrapper = ElementWidget(stack);
      elementWrapper.layout(BoxConstraints.tight(const Size(5, 5)));
      elementWrapper.paint(buffer, Offset.zero);

      // Base: A fills entire 5x5.
      // Overlay: B renders at x: [1, 2], y: 2.
      expect(buffer.getCell(0, 0)!.char, 'A');
      expect(buffer.getCell(1, 2)!.char, 'B');
      expect(buffer.getCell(2, 2)!.char, 'B');
      expect(buffer.getCell(3, 2)!.char, 'A');
    });
  });

  group('Align & Center Tests', () {
    test('Center aligns child in buffer', () {
      final buffer = Buffer.blank(5, 5);
      final center = Center(
        child: const SizedBox(width: 1, height: 1, child: TestWidget('X')),
      );

      final elementWrapper = ElementWidget(center);
      elementWrapper.layout(BoxConstraints.tight(const Size(5, 5)));
      elementWrapper.paint(buffer, Offset.zero);

      // Buffer size 5x5. Child size 1x1.
      // Centered: remaining = 4. offset = 4 / 2 = 2.
      // Centered cell at (2, 2)
      expect(buffer.getCell(2, 2)!.char, 'X');
      expect(buffer.getCell(1, 2)!.char, ' ');
      expect(buffer.getCell(2, 1)!.char, ' ');
    });
  });

  group('State Management & Reactivity', () {
    test('StatefulWidget mounts, renders, and setState triggers update', () {
      final buffer = Buffer.blank(10, 1);
      final widget = const CounterWidget(prefix: 'val:');

      // Create an Element tree and mount it
      final element = widget.createElement();
      element.mount(null);

      // Render initial state
      element.layout(BoxConstraints.tight(const Size(10, 1)));
      element.paint(buffer, Offset.zero);
      expect(buffer.getCell(0, 0)!.char, 'v');
      expect(buffer.getCell(4, 0)!.char, '0');

      // Increment state
      final state = (element as StatefulElement).state as _CounterWidgetState;
      state.increment();

      // Render updated state
      element.layout(BoxConstraints.tight(const Size(10, 1)));
      element.paint(buffer, Offset.zero);
      expect(buffer.getCell(4, 0)!.char, '1');
    });
  });

  group('InheritedWidget Tests', () {
    test('Inherited value propagation', () {
      final buffer = Buffer.blank(5, 1);
      final widget = const ThemeColor(colorName: 'R', child: ThemeDisplay());

      final element = widget.createElement();
      element.mount(null);

      element.layout(BoxConstraints.tight(const Size(5, 1)));
      element.paint(buffer, Offset.zero);
      expect(buffer.getCell(0, 0)!.char, 'R');
    });
  });
}
