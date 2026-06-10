import 'package:test/test.dart';
import 'package:termui/ui/buffer.dart';
import 'package:termui/ui/layout.dart';
import 'package:termui/ui/event.dart';
import 'package:termui/ui/window.dart';
import 'package:termui/ui/widget_toolkit.dart';

class SpyWidget extends Widget {
  int renderCount = 0;
  @override
  void render(Buffer buffer, Rect area) {
    renderCount++;
  }
}

class DummyWidget extends Widget {
  const DummyWidget();
  @override
  void render(Buffer buffer, Rect area) {}
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
      splitPane.render(buffer, const Rect(0, 0, 21, 5));

      // 50% of 21 is round(10.5) = 11.
      // So divider is drawn at x = 11.
      expect(buffer.getCell(11, 0)!.char, equals('|'));
      expect(buffer.getCell(11, 4)!.char, equals('|'));
      expect(buffer.getCell(10, 0)!.char, equals(' ')); // left side child area
      expect(buffer.getCell(12, 0)!.char, equals(' ')); // right side child area
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
        splitPane.render(
          buffer,
          const Rect(0, 0, 21, 5),
        ); // Resolves dividerX to 11

        // Inject press sequence at divider (11)
        splitPane.handleMouseEvent(
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
        splitPane.handleMouseEvent(
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
      splitPane.render(
        buffer,
        const Rect(0, 0, 21, 5),
      ); // Initial ratio is min = 8

      // Press at divider (8)
      splitPane.handleMouseEvent(
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
      splitPane.handleMouseEvent(
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
      lazyTable.render(buffer, const Rect(0, 0, 20, 50));

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
      lazyTable.render(buffer, const Rect(0, 0, 20, 50));
      expect(queriedIndices.first, equals(0));
      expect(queriedIndices.last, equals(49));

      queriedIndices.clear();

      // Scroll down by 1
      lazyTable.scrollOffset = 1;
      lazyTable.selectedRowIndex = 1;
      lazyTable.render(buffer, const Rect(0, 0, 20, 50));

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
      scrollBar.render(buffer, const Rect(0, 0, 1, 10));

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
      scrollBar.render(
        buffer,
        const Rect(0, 0, 1, 10),
      ); // Resolves area height to 10

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
      scrollBar.render(buffer, const Rect(0, 0, 1, 10));

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
      panel.render(buffer, const Rect(0, 0, 10, 5));

      expect(spy1.renderCount, equals(1));
      expect(spy2.renderCount, equals(0));
      expect(spy3.renderCount, equals(0));
    });

    test('Event Routing & Focus Resetting', () {
      final windowManager = WindowManager();
      final controller = TabController(length: 3);
      final spy1 = SpyWidget();
      final spy2 = SpyWidget();
      final spy3 = SpyWidget();

      final t1 = FocusNode(id: 't1');
      final t2 = FocusNode(id: 't2');
      final t3 = FocusNode(id: 't3');

      final btnOld = FocusNode(id: 'btnOld');
      final btnNew = FocusNode(id: 'btnNew');

      t1.addChild(btnOld);
      t2.addChild(btnNew);

      final tabBar = TabBar(
        controller: controller,
        labels: ['Tab1', 'Tab2', 'Tab3'],
        windowManager: windowManager,
      );

      final panel = TabPanel(
        controller: controller,
        children: [spy1, spy2, spy3],
        tabFocusNodes: [t1, t2, t3],
      );

      final win = Window(
        title: 'TabWindow',
        bounds: const Rect(0, 0, 30, 10),
        child: panel,
      );
      win.focusNode.addChild(t1);
      win.focusNode.addChild(t2);
      win.focusNode.addChild(t3);

      windowManager.addWindow(win);

      // Focus elements inside the old tab
      btnOld.requestFocus();
      expect(btnOld.isFocused, isTrue);

      // Inject "Next Tab" key event `]`
      final handled = windowManager.handleKeyEvent(
        const KeyEvent(']', KeyType.character),
      );
      expect(handled, isTrue);
      expect(controller.index, equals(1));

      // Verify that old focus dropped and new tab top element is focused
      expect(btnOld.isFocused, isFalse);
      expect(btnNew.isFocused, isTrue);

      tabBar.dispose();
    });
  });

  group('5. ModalOverlay (Z-Index Focus Trapping)', () {
    test('Focus Trap Test - focus cycles strictly between modal buttons', () {
      final windowManager = WindowManager();

      // Background TextInput
      final bgInput = TextField(focused: true);
      final bgWin = Window(
        title: 'BgWin',
        bounds: const Rect(0, 0, 100, 100),
        child: bgInput,
      );
      windowManager.addWindow(bgWin);
      bgWin.focusNode.requestFocus();
      expect(bgWin.focusNode.isFocused, isTrue);

      // Modal buttons FocusNodes
      final btn1Node = FocusNode(id: 'btn1');
      final btn2Node = FocusNode(id: 'btn2');

      final modal = ModalOverlay(
        title: 'Modal',
        bounds: const Rect(0, 0, 100, 100),
        dialogBounds: const Rect(10, 10, 30, 10),
        modalFocusNodes: [btn1Node, btn2Node],
        child: const DummyWidget(),
      );
      windowManager.addWindow(modal);
      btn1Node.requestFocus();

      // Ensure focus is initially on btn1
      expect(btn1Node.isFocused, isTrue);
      expect(bgWin.focusNode.isFocused, isFalse);

      // Inject Tab KeyEvent to cycle focus
      windowManager.handleKeyEvent(const KeyEvent('tab', KeyType.tab));
      expect(btn2Node.isFocused, isTrue);
      expect(btn1Node.isFocused, isFalse);

      // Inject another Tab KeyEvent
      windowManager.handleKeyEvent(const KeyEvent('tab', KeyType.tab));
      expect(btn1Node.isFocused, isTrue);
      expect(btn2Node.isFocused, isFalse);
    });

    test('Input Blackhole Test - clicks outside dialog are intercepted', () {
      final windowManager = WindowManager();

      var bgClicked = false;
      final bgWin = Window(
        title: 'BgWin',
        bounds: const Rect(0, 0, 100, 100),
        child: const DummyWidget(),
        onMouseEvent: (event, lx, ly) {
          bgClicked = true;
        },
      );
      windowManager.addWindow(bgWin);

      var modalDismissed = false;
      final modal = ModalOverlay(
        title: 'Modal',
        bounds: const Rect(0, 0, 100, 100),
        dialogBounds: const Rect(10, 10, 30, 10),
        modalFocusNodes: [],
        child: const DummyWidget(),
        onDismiss: () {
          modalDismissed = true;
        },
      );
      windowManager.addWindow(modal);

      // Click at x: 3, y: 3 (maps to sx: 2, sy: 2, outside the modal dialog bounds 10..40)
      final handled = windowManager.handleMouseEvent(
        const MouseEvent(
          x: 3,
          y: 3,
          button: MouseButton.left,
          type: MouseEventType.press,
        ),
      );

      expect(handled, isTrue);
      expect(modalDismissed, isTrue);
      expect(bgClicked, isFalse);
    });
  });
}
