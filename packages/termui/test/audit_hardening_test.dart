import 'package:test/test.dart';
import 'package:termui/ui/buffer.dart';
import 'package:termui/ui/style.dart';
import 'package:termui/ui/layout.dart';
import 'package:termui/ui/window.dart';
import 'package:termui/ui/event.dart';
import 'package:termui/ui/widget_toolkit.dart';

class MockWidget extends Widget {
  bool rendered = false;
  Rect? renderedArea;

  @override
  void render(Buffer buffer, Rect area) {
    rendered = true;
    renderedArea = area;
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
      row.render(buffer, const Rect(0, 0, 0, 10));
      expect(mock.rendered, isFalse);

      final col = Column(items);
      col.render(buffer, const Rect(0, 0, 10, -5));
      expect(mock.rendered, isFalse);

      final stack = Stack([mock]);
      stack.render(buffer, const Rect(0, 0, -2, 0));
      expect(mock.rendered, isFalse);
    });

    test(
      'Window rendering early-exits or fallback-clears on small/negative size',
      () {
        final buffer = Buffer(10, 10);
        final child = MockWidget();
        final win = Window(
          title: 'Title',
          bounds: const Rect(0, 0, 1, 5),
          child: child,
        );

        // Width of 1 (too small for borders) should not crash and should not render child
        win.render(buffer, const Rect(0, 0, 10, 10));
        expect(child.rendered, isFalse);

        // Width/height <= 0 should return immediately
        final winZero = Window(
          title: 'Title',
          bounds: const Rect(0, 0, 0, 0),
          child: child,
        );
        winZero.render(buffer, const Rect(0, 0, 10, 10));
        expect(child.rendered, isFalse);
      },
    );
  });

  group('TUI Hardening - Grapheme & Emojis Safety', () {
    test('Window title layout clipping handles emojis safely', () {
      final buffer = Buffer(20, 5);
      final win = Window(
        title: 'Hello 🌟 World', // 13 characters with emoji
        bounds: const Rect(0, 0, 10, 5), // w=10, maxTitleLen=6, cutLen=3
        child: MockWidget(),
      );

      // Should clip the title safely without throwing a RangeError/ArgumentError
      expect(
        () => win.render(buffer, const Rect(0, 0, 20, 5)),
        returnsNormally,
      );
      expect(win.isPositionOnTitle(3, 0), isTrue);
    });

    test('Label and Paragraph wrap and clip emojis correctly', () {
      final buffer = Buffer(10, 5);

      final label = const Text('🌟✨💫🔥');
      expect(
        () => label.render(buffer, const Rect(0, 0, 3, 1)),
        returnsNormally,
      );

      // Paragraph wrapping of long emoji sequences
      final paragraph = Text('🌟✨ 💫🔥💥⚡️🌈');
      expect(
        () => paragraph.render(buffer, const Rect(0, 0, 4, 5)),
        returnsNormally,
      );
    });

    test('ListWidget, Table, and NumberSelector handle emojis safely', () {
      final buffer = Buffer(20, 10);

      final list = ListWidget(['🌟 item 1', '🔥 item 2']);
      expect(
        () => list.render(buffer, const Rect(0, 0, 10, 5)),
        returnsNormally,
      );

      final table = Table(
        headers: ['Header 🌟', 'Header 2'],
        rows: [
          ['Row 1 🌟', 'Data 1'],
        ],
        columnWidths: [10, 8],
      );
      expect(
        () => table.render(buffer, const Rect(0, 0, 20, 5)),
        returnsNormally,
      );

      final selector = NumberSelector(
        label: 'Selector 🌟',
        value: 5,
        min: 0,
        max: 10,
      );
      expect(
        () => selector.render(buffer, const Rect(0, 0, 20, 1)),
        returnsNormally,
      );
    });
  });

  group('TUI Hardening - Nested Focus Node Event Routing', () {
    test('WindowManager handleKeyEvent walks up nested focus paths', () {
      final manager = WindowManager();

      final winFocusNode = FocusNode(id: 'winFocus');
      final childFocusNode = FocusNode(id: 'childFocus');

      winFocusNode.addChild(childFocusNode);

      var keyReceived = false;
      final win = Window(
        title: 'Target Win',
        bounds: const Rect(0, 0, 20, 10),
        child: MockWidget(),
        focusNode: winFocusNode,
        onKeyEvent: (event) {
          keyReceived = true;
        },
      );

      manager.addWindow(win);

      // Request focus for nested child focus node
      childFocusNode.requestFocus();

      // The leaf node should be the child focus node
      expect(manager.rootFocusNode.findFocusedLeaf(), equals(childFocusNode));

      // Send keyboard event
      final handled = manager.handleKeyEvent(
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
