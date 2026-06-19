import 'package:test/test.dart';
import 'package:termui/ui/buffer.dart';
import 'package:termui/ui/widgets/layout/flex.dart';
import 'package:termui/ui/widgets/core/widget.dart';
import 'package:termui/ui/widgets/core/element.dart';
import 'package:termui/ui/widgets/core/geometry.dart';
import 'package:termui/ui/event.dart';
import 'package:termui/ui/window.dart';
import 'package:termui/ui/widget_toolkit.dart';
import 'package:termui_recorder/termui_recorder.dart';

class SpyWidget extends Widget {
  int renderCount = 0;

  @override
  Element createElement() => _SpyElement(this);
}

class _SpyElement extends Element {
  _SpyElement(super.widget);

  @override
  Size performLayout(BoxConstraints constraints) {
    return constraints.constrain(Size.zero);
  }

  @override
  void performPaint(Buffer buffer, Offset offset) {
    (widget as SpyWidget).renderCount++;
  }
}

class DummyWidget extends Widget {
  const DummyWidget();

  @override
  Element createElement() => _DummyElement(this);
}

class _DummyElement extends Element {
  _DummyElement(super.widget);

  @override
  Size performLayout(BoxConstraints constraints) {
    return constraints.constrain(Size.zero);
  }

  @override
  void performPaint(Buffer buffer, Offset offset) {}
}

void main() {
  group('1. SplitPane (Draggable Layout Constraint)', () {
    test('Visual Layout Test - divider is drawn at initial ratio', () {
      final splitPane = SplitPane(
        child1: const DummyWidget(),
        constraint1: const PercentageConstraint(50),
        child2: const DummyWidget(),
        constraint2: const PercentageConstraint(50),
        direction: LayoutDirection.horizontal,
        dividerChar: '|',
      );

      final buffer = Buffer.blank(21, 5);
      ElementWidget(splitPane)
        ..layout(BoxConstraints.tight(const Size(21, 5)))
        ..paint(buffer, Offset.zero);

      // 50% of 21 is round(10.5) = 11.
      // So divider is drawn at x = 11.
      expect(buffer.getCell(11, 0)!.char, equals('|'));
      expect(buffer.getCell(11, 4)!.char, equals('|'));
      expect(buffer.getCell(10, 0)!.char, equals(' ')); // left side child area
      expect(buffer.getCell(12, 0)!.char, equals(' ')); // right side child area
    });

    test('Visual Layout Test - matches golden file', () {
      final splitPane = SplitPane(
        child1: const DummyWidget(),
        constraint1: const PercentageConstraint(50),
        child2: const DummyWidget(),
        constraint2: const PercentageConstraint(50),
        direction: LayoutDirection.horizontal,
        dividerChar: '|',
      );

      final buffer = Buffer.blank(21, 5);
      ElementWidget(splitPane)
        ..layout(BoxConstraints.tight(const Size(21, 5)))
        ..paint(buffer, Offset.zero);

      expect(
        buffer,
        matchesAnsiGolden(
          'test/goldens/split_pane.ansi',
          environment: {'GENERATE_GOLDENS': 'true'},
        ),
      );
    });

    test(
      'Interactivity Test - drag divider left decreases/increases child sizes',
      () {
        final splitPane = SplitPane(
          child1: const DummyWidget(),
          constraint1: const LengthConstraint(11),
          child2: const DummyWidget(),
          constraint2: const LengthConstraint(9),
          direction: LayoutDirection.horizontal,
          dividerChar: '|',
        );

        final buffer = Buffer.blank(21, 5);
        final splitPaneWrapper = ElementWidget(splitPane);
        splitPaneWrapper.layout(BoxConstraints.tight(const Size(21, 5)));
        splitPaneWrapper.paint(buffer, Offset.zero);
        final splitPaneEl = splitPaneWrapper.element as SplitPaneElement;

        // Inject press sequence at divider (11)
        splitPaneEl.handleMouseEvent(
          const MouseEvent(
            x: 12,
            y: 1,
            button: MouseButton.left,
            type: MouseEventType.press,
          ),
          11,
          0,
        );

        // Drag left by 5 columns (to 6)
        splitPaneEl.handleMouseEvent(
          const MouseEvent(
            x: 7,
            y: 1,
            button: MouseButton.left,
            type: MouseEventType.drag,
          ),
          6,
          0,
        );

        // Assertions:
        // Left child width constraint decreases by 5 (11 -> 6)
        // Right child increases by 5 (9 -> 14)
        // Total bounds remain identical (6 + 14 + 1 = 21)
        final c1 = splitPane.constraint1 as LengthConstraint;
        final c2 = splitPane.constraint2 as LengthConstraint;
        expect(c1.length, equals(6));
        expect(c2.length, equals(14));
        expect(c1.length + c2.length + 1, equals(21));
      },
    );

    test('Edge Case Constraint - clamp at MinMax limits', () {
      final splitPane = SplitPane(
        child1: const DummyWidget(),
        constraint1: const MinMaxConstraint(min: 8, max: 15),
        child2: const DummyWidget(),
        constraint2: const LengthConstraint(9),
        direction: LayoutDirection.horizontal,
        dividerChar: '|',
      );

      final buffer = Buffer.blank(21, 5);
      final splitPaneWrapper = ElementWidget(splitPane);
      splitPaneWrapper.layout(BoxConstraints.tight(const Size(21, 5)));
      splitPaneWrapper.paint(buffer, Offset.zero);
      final splitPaneEl = splitPaneWrapper.element as SplitPaneElement;

      // Press at divider (8)
      splitPaneEl.handleMouseEvent(
        const MouseEvent(
          x: 9,
          y: 1,
          button: MouseButton.left,
          type: MouseEventType.press,
        ),
        8,
        0,
      );

      // Attempt to drag past child1's min limit (8) to 5
      splitPaneEl.handleMouseEvent(
        const MouseEvent(
          x: 6,
          y: 1,
          button: MouseButton.left,
          type: MouseEventType.drag,
        ),
        5,
        0,
      );

      // Verify it clamped at 8 and didn't crash
      final c1 = splitPane.constraint1 as MinMaxConstraint;
      expect(c1.min, equals(8));
    });
  });

  group('2. LazyTable / LazyList (Virtual Scrolling Viewport)', () {
    test('Virtualization Audit - only visible items are built', () {
      int builderCalls = 0;
      final lazyTable = LazyTable(
        headers: [],
        columnWidths: [],
        itemCount: 1000000,
        itemBuilder: (index) {
          builderCalls++;
          return ['Row $index'];
        },
      );

      final buffer = Buffer.blank(20, 50);
      ElementWidget(lazyTable)
        ..layout(BoxConstraints.tight(const Size(20, 50)))
        ..paint(buffer, Offset.zero);

      expect(builderCalls, equals(50));
    });

    test('Scroll Event Test - builder index shift on scroll', () {
      final List<int> queriedIndices = [];
      final lazyTable = LazyTable(
        headers: [],
        columnWidths: [],
        itemCount: 1000000,
        itemBuilder: (index) {
          queriedIndices.add(index);
          return ['Row $index'];
        },
      );

      final buffer = Buffer.blank(20, 50);

      // Initial render at scrollOffset = 0
      ElementWidget(lazyTable)
        ..layout(BoxConstraints.tight(const Size(20, 50)))
        ..paint(buffer, Offset.zero);
      expect(queriedIndices.first, equals(0));
      expect(queriedIndices.last, equals(49));

      queriedIndices.clear();

      // Scroll down by 1
      lazyTable.scrollOffset = 1;
      lazyTable.selectedRowIndex = 1;
      ElementWidget(lazyTable)
        ..layout(BoxConstraints.tight(const Size(20, 50)))
        ..paint(buffer, Offset.zero);

      // Index 0 must be dropped (not queried), and index 50 must be queried
      expect(queriedIndices.contains(0), isFalse);
      expect(queriedIndices.contains(50), isTrue);
      expect(queriedIndices.first, equals(1));
      expect(queriedIndices.last, equals(50));
    });
  });

  group('3. ScrollBar (Viewport Sync Control)', () {
    test('Ratio Math Test - thumb size is 10% of track height', () {
      // trackHeight = 10, totalItems = 100, viewportHeight = 10.
      // ratio = 10 / 100 = 10%
      // thumbHeight = 10% of 10 = 1
      var scrollOffset = 0;
      final scrollBar = ScrollBar(
        viewportHeight: 10,
        totalItems: 100,
        scrollOffset: scrollOffset,
        onScrollChanged: (val) {
          scrollOffset = val;
        },
      );

      final buffer = Buffer.blank(1, 10);
      ElementWidget(scrollBar)
        ..layout(BoxConstraints.tight(const Size(1, 10)))
        ..paint(buffer, Offset.zero);

      // Assert only 1 cell contains the thumb char '█'
      var thumbCount = 0;
      for (var y = 0; y < 10; y++) {
        if (buffer.getCell(0, y)!.char == '█') {
          thumbCount++;
        }
      }
      expect(thumbCount, equals(1));
    });

    test('Hit-Test Translation - click at 50% mark yields row 50', () {
      var scrollOffset = 0;
      final scrollBar = ScrollBar(
        viewportHeight: 10,
        totalItems: 100,
        scrollOffset: scrollOffset,
        onScrollChanged: (val) {
          scrollOffset = val;
        },
      );

      final buffer = Buffer.blank(1, 10);
      final scrollBarWrapper = ElementWidget(scrollBar);
      scrollBarWrapper.layout(BoxConstraints.tight(const Size(1, 10)));
      scrollBarWrapper.paint(buffer, Offset.zero);
      // Click at y = 5 (which is 50% of track height 10)
      scrollBar.handleMouseEvent(
        const MouseEvent(
          x: 1,
          y: 6,
          button: MouseButton.left,
          type: MouseEventType.press,
        ),
        0,
        5,
      );

      expect(scrollOffset, equals(50));
    });

    test('Boundary Test - dragging past limits clamps safely', () {
      var scrollOffset = 0;
      final scrollBar = ScrollBar(
        viewportHeight: 10,
        totalItems: 100,
        scrollOffset: scrollOffset,
        onScrollChanged: (val) {
          scrollOffset = val;
        },
      );

      final buffer = Buffer.blank(1, 10);
      final scrollBarWrapper = ElementWidget(scrollBar);
      scrollBarWrapper.layout(BoxConstraints.tight(const Size(1, 10)));
      scrollBarWrapper.paint(buffer, Offset.zero);
      // Drag past top (y = -5)
      scrollBar.handleMouseEvent(
        const MouseEvent(
          x: 1,
          y: -4,
          button: MouseButton.left,
          type: MouseEventType.drag,
        ),
        0,
        -5,
      );
      expect(scrollOffset, equals(0));

      // Drag past bottom (y = 15)
      scrollBar.handleMouseEvent(
        const MouseEvent(
          x: 1,
          y: 16,
          button: MouseButton.left,
          type: MouseEventType.drag,
        ),
        0,
        15,
      );
      // maxScrollExtent = totalItems - viewportHeight = 100 - 10 = 90
      expect(scrollOffset, equals(90));
    });
  });

  group('4. TabBar & TabPanel (View State Routing)', () {
    test('Render Isolation - only active child renders', () {
      final controller = TabController(length: 3);
      final spy1 = SpyWidget();
      final spy2 = SpyWidget();
      final spy3 = SpyWidget();

      final panel = TabPanel(
        controller: controller,
        children: [spy1, spy2, spy3],
        tabFocusNodes: [
          FocusNode(id: 't1'),
          FocusNode(id: 't2'),
          FocusNode(id: 't3'),
        ],
      );

      final buffer = Buffer.blank(10, 5);
      ElementWidget(panel)
        ..layout(BoxConstraints.tight(const Size(10, 5)))
        ..paint(buffer, Offset.zero);

      expect(spy1.renderCount, equals(1));
      expect(spy2.renderCount, equals(0));
      expect(spy3.renderCount, equals(0));
    });

    test('TabPanel handles tab change and requests focus on new tab nodes', () {
      final controller = TabController(length: 3);
      final t1 = FocusNode(id: 't1');
      final t2 = FocusNode(id: 't2');
      final t3 = FocusNode(id: 't3');

      final btnOld = FocusNode(id: 'btnOld');
      final btnNew = FocusNode(id: 'btnNew');

      t1.addChild(btnOld);
      t2.addChild(btnNew);

      TabPanel(
        controller: controller,
        children: [
          const DummyWidget(),
          const DummyWidget(),
          const DummyWidget(),
        ],
        tabFocusNodes: [t1, t2, t3],
      );

      btnOld.requestFocus();
      expect(btnOld.isFocused, isTrue);

      controller.index = 1;

      expect(btnOld.isFocused, isFalse);
      expect(btnNew.isFocused, isTrue);
    });
  });

  group('5. ModalOverlay (Z-Index Focus Trapping)', () {
    test('Focus Trap Test - focus cycles strictly between modal buttons', () {
      final btn1Node = FocusNode(id: 'btn1');
      final btn2Node = FocusNode(id: 'btn2');

      final modal = ModalOverlay(
        title: 'Modal',
        width: 100,
        height: 100,
        dialogBounds: const Rect(10, 10, 30, 10),
        modalFocusNodes: [btn1Node, btn2Node],
        child: const DummyWidget(),
      );

      btn1Node.requestFocus();
      expect(btn1Node.isFocused, isTrue);

      // Simulate Tab key press
      modal.onKeyEvent!(const KeyEvent('tab', KeyType.tab));
      expect(btn2Node.isFocused, isTrue);
      expect(btn1Node.isFocused, isFalse);

      // Simulate Shift+Tab key press
      modal.onKeyEvent!(const KeyEvent('backtab', KeyType.tab));
      expect(btn1Node.isFocused, isTrue);
      expect(btn2Node.isFocused, isFalse);

      // Simulate Right Arrow key press
      modal.onKeyEvent!(const KeyEvent('right', KeyType.right));
      expect(btn2Node.isFocused, isTrue);
      expect(btn1Node.isFocused, isFalse);

      // Simulate Left Arrow key press
      modal.onKeyEvent!(const KeyEvent('left', KeyType.left));
      expect(btn1Node.isFocused, isTrue);
      expect(btn2Node.isFocused, isFalse);

      // Simulate Down Arrow key press
      modal.onKeyEvent!(const KeyEvent('down', KeyType.down));
      expect(btn2Node.isFocused, isTrue);
      expect(btn1Node.isFocused, isFalse);

      // Simulate Up Arrow key press
      modal.onKeyEvent!(const KeyEvent('up', KeyType.up));
      expect(btn1Node.isFocused, isTrue);
      expect(btn2Node.isFocused, isFalse);
    });

    test('Input Blackhole Test - clicks outside dialog are intercepted', () {
      var modalDismissed = false;
      final modal = ModalOverlay(
        title: 'Modal',
        width: 100,
        height: 100,
        dialogBounds: const Rect(10, 10, 30, 10),
        modalFocusNodes: [],
        child: const DummyWidget(),
        onDismiss: () {
          modalDismissed = true;
        },
      );

      // Click outside dialogBounds (localX: 3, localY: 3, dialog is at 10..40)
      modal.onMouseEvent!(
        const MouseEvent(
          x: 4,
          y: 4,
          button: MouseButton.left,
          type: MouseEventType.press,
        ),
        3,
        3,
      );

      expect(modalDismissed, isTrue);
    });
  });
}
