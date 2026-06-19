import 'package:test/test.dart';
import 'package:termui/ui/buffer.dart';
import 'package:termui/ui/style.dart';
import 'package:termui/ui/widgets/layout/row.dart';
import 'package:termui/ui/widgets/layout/column.dart';
import 'package:termui/ui/widgets/layout/stack.dart';
import 'package:termui/ui/widgets/layout/flexible.dart';
import 'package:termui/ui/widgets/layout/flex.dart';
import 'package:termui/ui/widgets/core/widget.dart';
import 'package:termui/ui/widgets/core/element.dart';
import 'package:termui/ui/widgets/core/geometry.dart';
import 'package:termui/ui/widgets/core/viewport.dart';
import 'package:termui/ui/window.dart';
import 'package:termui/ui/event.dart';
import 'package:termui/ui/widget_toolkit.dart';

class MockWidget extends Widget {
  bool rendered = false;
  Rect? renderedArea;

  @override
  Element createElement() => MockElement(this);
}

class MockElement extends Element {
  MockElement(MockWidget super.widget);

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
    final w = widget as MockWidget;
    w.rendered = true;
    w.renderedArea = Rect(offset.dx, offset.dy, size.width, size.height);
  }
}

void main() {
  group('TUI Hardening - Zero/Negative Dimension Safety', () {
    test('splitRect clamps negative input bounds to zero', () {
      final area = const Rect(10, 10, -5, -5);
      final constraints = [
        const LengthConstraint(5),
        const PercentageConstraint(50),
        const FlexConstraint(1),
      ];
      final rects = splitRect(area, constraints, LayoutDirection.horizontal);
      expect(rects.length, equals(3));
      for (final r in rects) {
        expect(r.width, greaterThanOrEqualTo(0));
        expect(r.height, greaterThanOrEqualTo(0));
      }
    });

    test('Viewport clamps negative bounds dimensions to zero', () {
      final buffer = Buffer(10, 10);
      final viewport = Viewport(buffer, const Rect(2, 2, -2, -3));
      expect(viewport.width, equals(0));
      expect(viewport.height, equals(0));
      // Operations on zero-size viewport should clip safely
      expect(viewport.getCell(0, 0), isNull);
      viewport.setCell(0, 0, Cell('x', Style.empty));
      viewport.writeString(0, 0, 'hello', Style.empty);
      viewport.clear();
      viewport.fill(Cell('a', Style.empty));
    });

    test('Buffer.resize clamps negative new dimensions to zero', () {
      final buffer = Buffer(5, 5);
      buffer.resize(-2, -5);
      expect(buffer.width, equals(0));
      expect(buffer.height, equals(0));
      expect(buffer.cells.isEmpty, isTrue);
    });

    test('Row, Column, Stack early-exit on zero/negative render areas', () {
      final buffer = Buffer(10, 10);
      final mock = MockWidget();
      final items = [Flexible(child: mock)];

      final row = Row(items);
      final rowEl = row.createElement()..mount(null);
      rowEl.layout(BoxConstraints.tight(const Size(0, 10)));
      rowEl.paint(buffer, Offset.zero);
      expect(mock.rendered, isFalse);

      final col = Column(items);
      final colEl = col.createElement()..mount(null);
      colEl.layout(BoxConstraints.tight(const Size(10, -5)));
      colEl.paint(buffer, Offset.zero);
      expect(mock.rendered, isFalse);

      final stack = Stack([mock]);
      final stackEl = stack.createElement()..mount(null);
      stackEl.layout(BoxConstraints.tight(const Size(-2, 0)));
      stackEl.paint(buffer, Offset.zero);
      expect(mock.rendered, isFalse);
    });

    test(
      'Window rendering early-exits or fallback-clears on small/negative size',
      () {
        final buffer = Buffer(10, 10);
        final child = MockWidget();
        final win = Window(title: 'Title', width: 1, height: 5, child: child);

        // Width of 1 (too small for borders) should not crash and should not render child
        final winEl = win.createElement()..mount(null);
        winEl.layout(BoxConstraints.tight(Size(win.width, win.height)));
        winEl.paint(buffer, Offset.zero);
        expect(child.rendered, isFalse);

        // Width/height <= 0 should return immediately
        final winZero = Window(
          title: 'Title',
          width: 0,
          height: 0,
          child: child,
        );
        final winZeroEl = winZero.createElement()..mount(null);
        winZeroEl.layout(
          BoxConstraints.tight(Size(winZero.width, winZero.height)),
        );
        winZeroEl.paint(buffer, Offset.zero);
        expect(child.rendered, isFalse);
      },
    );
  });

  group('TUI Hardening - Grapheme & Emojis Safety', () {
    test('Window title layout clipping handles emojis safely', () {
      final buffer = Buffer(20, 5);
      final win = Window(
        title: 'Hello 🌟 World', // 13 characters with emoji
        width: 10,
        height: 5,
        child: MockWidget(),
      );

      // Should clip the title safely without throwing a RangeError/ArgumentError
      expect(() {
        final el = win.createElement()..mount(null);
        el.layout(BoxConstraints.tight(Size(win.width, win.height)));
        el.paint(buffer, Offset.zero);
      }, returnsNormally);
      expect(win.isPositionOnTitle(3, 0), isTrue);
    });

    test('Label and Paragraph wrap and clip emojis correctly', () {
      final buffer = Buffer(10, 5);

      final label = const Text('🌟✨💫🔥');
      expect(() {
        final el = label.createElement()..mount(null);
        el.layout(BoxConstraints.tight(const Size(3, 1)));
        el.paint(buffer, Offset.zero);
      }, returnsNormally);

      // Paragraph wrapping of long emoji sequences
      final paragraph = Text('🌟✨ 💫🔥💥⚡️🌈');
      expect(() {
        final el = paragraph.createElement()..mount(null);
        el.layout(BoxConstraints.tight(const Size(4, 5)));
        el.paint(buffer, Offset.zero);
      }, returnsNormally);
    });

    test('ListView, Table, and NumberSelector handle emojis safely', () {
      final buffer = Buffer(20, 10);

      final list = ListView.fromStrings(['🌟 item 1', '🔥 item 2']);
      expect(() {
        final el = list.createElement()..mount(null);
        el.layout(BoxConstraints.tight(const Size(10, 5)));
        el.paint(buffer, Offset.zero);
      }, returnsNormally);

      final table = Table(
        headers: ['Header 🌟', 'Header 2'],
        rows: [
          ['Row 1 🌟', 'Data 1'],
        ],
        columnWidths: [10, 8],
      );
      expect(() {
        final el = table.createElement()..mount(null);
        el.layout(BoxConstraints.tight(const Size(20, 5)));
        el.paint(buffer, Offset.zero);
      }, returnsNormally);

      final selector = NumberSelector(
        label: 'Selector 🌟',
        value: 5,
        min: 0,
        max: 10,
      );
      expect(() {
        final el = selector.createElement()..mount(null);
        el.layout(BoxConstraints.tight(const Size(20, 1)));
        el.paint(buffer, Offset.zero);
      }, returnsNormally);
    });
  });

  group('TUI Hardening - Nested Focus Node Event Routing', () {
    test('FocusNode bubbleKeyEvent walks up nested focus paths', () {
      final parentFocusNode = FocusNode(id: 'parentFocus');
      final childFocusNode = FocusNode(id: 'childFocus');

      parentFocusNode.addChild(childFocusNode);

      var keyReceived = false;
      parentFocusNode.onKeyEvent = (event) {
        keyReceived = true;
        return true;
      };

      // Request focus for nested child focus node
      childFocusNode.requestFocus();

      // Send keyboard event
      final handled = childFocusNode.bubbleKeyEvent(
        const KeyEvent('a', KeyType.character),
      );

      expect(handled, isTrue);
      expect(keyReceived, isTrue);
    });
  });

  group('TUI Hardening - Input Widget Hotkey Integration', () {
    test('TextField consumes character keys like h and q correctly', () {
      final input = TextField(value: '', focused: true);
      input.handleKeyEvent(const KeyEvent('h', KeyType.character));
      expect(input.value, equals('h'));
      input.handleKeyEvent(const KeyEvent('q', KeyType.character));
      expect(input.value, equals('hq'));
    });
  });
}
