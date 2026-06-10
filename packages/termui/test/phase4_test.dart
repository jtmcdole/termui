import 'package:test/test.dart';
import 'package:termui/ui/buffer.dart';
import 'package:termui/ui/style.dart';
import 'package:termui/ui/layout.dart';
import 'package:termui/ui/event.dart';
import 'package:termui/ui/window.dart';

class SimpleWidget extends Widget {
  const SimpleWidget();
  @override
  void render(Buffer buffer, Rect area) {
    buffer.writeString(0, 0, 'X', Style.empty);
  }
}

void main() {
  group('Focus Tree Tests', () {
    test('Focus request propagates and unfocuses siblings', () {
      final root = FocusNode(id: 'root');
      final child1 = FocusNode(id: 'child1');
      final child2 = FocusNode(id: 'child2');
      final leaf1 = FocusNode(id: 'leaf1');

      root.addChild(child1);
      root.addChild(child2);
      child1.addChild(leaf1);

      // Initially nothing is focused
      expect(root.findFocusedLeaf(), isNull);

      // Request focus on leaf1
      leaf1.requestFocus();

      expect(root.isFocused, isTrue);
      expect(child1.isFocused, isTrue);
      expect(leaf1.isFocused, isTrue);
      expect(child2.isFocused, isFalse);
      expect(root.findFocusedLeaf(), equals(leaf1));

      // Request focus on child2
      child2.requestFocus();

      expect(child2.isFocused, isTrue);
      expect(child1.isFocused, isFalse);
      expect(leaf1.isFocused, isFalse);
      expect(root.findFocusedLeaf(), equals(child2));
    });
  });

  group('Hit-Testing & Coordinate Translation', () {
    test('Topmost window hit-test and coordinates', () {
      final manager = WindowManager();

      final w1 = Window(
        title: 'Win1',
        bounds: const Rect(2, 2, 5, 5),
        zIndex: 1,
        child: const SimpleWidget(),
      );

      final w2 = Window(
        title: 'Win2',
        bounds: const Rect(3, 3, 5, 5),
        zIndex: 2,
        child: const SimpleWidget(),
      );

      manager.addWindow(w1);
      manager.addWindow(w2);

      // Coordinates (4, 4) overlap both. w2 has higher Z-index so it should receive the hit.
      final hitWin = manager.findWindowAt(4, 4);
      expect(hitWin, equals(w2));

      // Coordinate (2, 2) is only on w1.
      final hitWin2 = manager.findWindowAt(2, 2);
      expect(hitWin2, equals(w1));

      // Click at (12, 13) translates to 0-indexed screen coordinate (11, 12).
      // On testWin (bounds 10, 10), this translates to:
      // localX = 11 - 10 = 1
      // localY = 12 - 10 = 2
      int callbackX = -1;
      int callbackY = -1;
      var called = false;

      final testWin = Window(
        title: 'Test',
        bounds: const Rect(10, 10, 5, 5),
        child: const SimpleWidget(),
        onMouseEvent: (event, lx, ly) {
          called = true;
          callbackX = lx;
          callbackY = ly;
        },
      );
      manager.addWindow(testWin);

      final mouseEvent = const MouseEvent(
        x: 12,
        y: 13,
        button: MouseButton.left,
        type: MouseEventType.press,
      );

      final handled = manager.handleMouseEvent(mouseEvent);
      expect(handled, isTrue);
      expect(called, isTrue);
      expect(callbackX, equals(1));
      expect(callbackY, equals(2));
      expect(testWin.focusNode.isFocused, isTrue);
    });

    test(
      'isDraggingOrResizing state transitions during dragging and resizing',
      () {
        final manager = WindowManager();
        final win = Window(
          title: 'Win',
          bounds: const Rect(2, 2, 10, 10),
          child: const SimpleWidget(),
        );
        manager.addWindow(win);

        expect(manager.isDraggingOrResizing, isFalse);

        // Press on the title bar (sx = 4, sy = 2, localX = 2, localY = 0)
        final pressEvent = const MouseEvent(
          x: 5,
          y: 3,
          button: MouseButton.left,
          type: MouseEventType.press,
        );
        manager.handleMouseEvent(pressEvent);

        expect(manager.isDraggingOrResizing, isTrue);

        // Drag mouse
        final dragEvent = const MouseEvent(
          x: 6,
          y: 3,
          button: MouseButton.left,
          type: MouseEventType.drag,
        );
        manager.handleMouseEvent(dragEvent);
        expect(manager.isDraggingOrResizing, isTrue);

        // Release mouse
        final releaseEvent = const MouseEvent(
          x: 6,
          y: 3,
          button: MouseButton.left,
          type: MouseEventType.release,
        );
        expect(releaseEvent, isNotNull); // dummy check
        manager.handleMouseEvent(releaseEvent);
        expect(manager.isDraggingOrResizing, isFalse);
      },
    );

    test('Window resizing bounds updates correctly on corner drag', () {
      final manager = WindowManager();
      final win = Window(
        title: 'Win',
        bounds: const Rect(2, 2, 10, 10),
        child: const SimpleWidget(),
      );
      manager.addWindow(win);

      // Click at bottom-right corner of the window (localX = 9, localY = 9)
      // window bounds is 2, 2, 10, 10.
      // sx = 2 + 10 - 1 = 11.
      // sy = 2 + 10 - 1 = 11.
      // event.x = sx + 1 = 12.
      // event.y = sy + 1 = 12.
      final pressEvent = const MouseEvent(
        x: 12,
        y: 12,
        button: MouseButton.left,
        type: MouseEventType.press,
      );
      manager.handleMouseEvent(pressEvent);

      expect(manager.isDraggingOrResizing, isTrue);

      // Drag to x = 14, y = 14 (sx = 13, sy = 13)
      final dragEvent = const MouseEvent(
        x: 14,
        y: 14,
        button: MouseButton.left,
        type: MouseEventType.drag,
      );
      manager.handleMouseEvent(dragEvent);

      // The new width should be: sx - b.x + 1 = 13 - 2 + 1 = 12.
      // The new height should be: sy - b.y + 1 = 13 - 2 + 1 = 12.
      expect(win.bounds.width, equals(12));
      expect(win.bounds.height, equals(12));
    });

    test('Window resizing works when clicking near the corner (tolerance)', () {
      final manager = WindowManager();
      final win = Window(
        title: 'Win',
        bounds: const Rect(2, 2, 10, 10),
        child: const SimpleWidget(),
      );
      manager.addWindow(win);

      expect(manager.isDraggingOrResizing, isFalse);

      // Click 1 cell to the left of the bottom-right corner (localX = 8, localY = 9)
      // sx = 2 + 8 = 10.
      // sy = 2 + 9 = 11.
      // event.x = sx + 1 = 11.
      // event.y = sy + 1 = 12.
      final pressEvent = const MouseEvent(
        x: 11,
        y: 12,
        button: MouseButton.left,
        type: MouseEventType.press,
      );
      manager.handleMouseEvent(pressEvent);

      expect(manager.isDraggingOrResizing, isTrue);
    });
  });

  group('Visual Border Drawing Tests', () {
    test('Window borders and contents placement', () {
      final buffer = Buffer.blank(15, 10);
      final win = Window(
        title: 'A',
        bounds: const Rect(1, 1, 10, 5),
        child: const SimpleWidget(),
      );

      win.render(buffer, const Rect(0, 0, 15, 10));

      // Window bounds: (1, 1) to (10, 5) on buffer
      // Top border corner at (1, 1) is '┌'
      expect(buffer.getCell(1, 1)!.char, equals('┌'));
      // Top border horizontal line at (2, 1) is '─'
      expect(buffer.getCell(2, 1)!.char, equals('─'));
      // Title 'A' overlay at (5, 1) - centered: ((10 - 3) / 2).floor() = 3. 3 + 1 offset in buffer = 4. Wait, title starts at index 3 in window, so index 3+1=4 is ' ', index 4+1=5 is 'A'
      expect(buffer.getCell(5, 1)!.char, equals('A'));

      // Bottom corner at (1, 5) is '└'
      expect(buffer.getCell(1, 5)!.char, equals('└'));

      // Content child (SimpleWidget writes 'X' at (0, 0) relative to content viewport)
      // Content viewport starts at (1, 1) relative to window, which is (2, 2) relative to root buffer
      expect(buffer.getCell(2, 2)!.char, equals('X'));
    });
  });
}
