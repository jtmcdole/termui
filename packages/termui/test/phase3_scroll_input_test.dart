import 'package:test/test.dart';
import 'package:termui/ui/buffer.dart';
import 'package:termui/ui/layout.dart';
import 'package:termui/ui/style.dart';
import 'package:termui/ui/event.dart' hide Modifier;
import 'package:termui/ui/event.dart' as ev show Modifier;
import 'package:termui/ui/widget_toolkit.dart';
import 'package:termui_recorder/termui_recorder.dart';

class SimpleTextWidget extends Widget {
  final String text;
  const SimpleTextWidget(this.text);

  @override
  void render(Buffer buffer, Rect area) {
    buffer.writeString(0, 0, text, Style.empty);
  }
}

void main() {
  group('DiscreteScrollController Tests', () {
    test('Initial offset and clamping logic', () {
      final controller = DiscreteScrollController(initialScrollOffset: 5);
      expect(controller.scrollOffset, equals(5));

      controller.totalExtent = 100;
      controller.viewportExtent = 20;

      controller.scrollOffset = 50;
      expect(controller.scrollOffset, equals(50));

      // Attempt to scroll beyond max extent
      controller.scrollOffset = 120;
      expect(controller.scrollOffset, equals(80)); // 100 - 20 = 80 max

      // Attempt to scroll negative
      controller.scrollOffset = -10;
      expect(controller.scrollOffset, equals(0));
    });

    test('Listener notification', () {
      final controller = DiscreteScrollController();
      controller.totalExtent = 50;
      controller.viewportExtent = 10;

      int listenerCount = 0;
      controller.addListener(() {
        listenerCount++;
      });

      controller.scrollOffset = 10;
      expect(listenerCount, equals(1));

      // Setting to the same offset should not trigger listener
      controller.scrollOffset = 10;
      expect(listenerCount, equals(1));
    });

    test('jumpTo jumps immediately', () {
      final controller = DiscreteScrollController();
      controller.totalExtent = 50;
      controller.viewportExtent = 10;
      controller.jumpTo(25);
      expect(controller.scrollOffset, equals(25));
    });
  });

  group('SingleChildScrollView Tests', () {
    test('Clipping and rendering of scroll view offset', () {
      final buffer = Buffer.blank(20, 5);
      buffer.clear();
      final controller = DiscreteScrollController(initialScrollOffset: 2);

      // Let's create a Column with 10 text lines of 1 height each
      final child = Column(
        List.generate(
          10,
          (i) => SizedBox(height: 1, child: SimpleTextWidget('Item $i')),
        ),
      );

      final scrollView = SingleChildScrollView(
        child: child,
        scrollDirection: LayoutDirection.vertical,
        controller: controller,
        childLength: 10,
      );

      // Render scroll view inside an area of height 5.
      scrollView.render(buffer, const Rect(0, 0, 20, 5));

      expect(
        buffer,
        matchesAnsiGolden(
          'test/goldens/scrollview_clipping.ansi',
          environment: {'GENERATE_GOLDENS': 'true'},
        ),
      );
    });
  });

  group('TextField Merged Input Tests', () {
    test('Single-line text insertion and backspace', () {
      final field = TextField(
        initialText: 'Hello',
        multiline: false,
        focused: true,
      );
      field.cursorColumn = 5; // move cursor to the end

      // Initially: 'Hello', cursor at 5 (end of line)
      expect(field.value, equals('Hello'));

      // Type ' World'
      for (final char in ' World'.split('')) {
        field.handleKeyEvent(KeyEvent(char, KeyType.character));
      }
      expect(field.value, equals('Hello World'));

      // Move left 3 times
      field.handleKeyEvent(const KeyEvent('left', KeyType.left));
      field.handleKeyEvent(const KeyEvent('left', KeyType.left));
      field.handleKeyEvent(const KeyEvent('left', KeyType.left));

      // Backspace (should delete 'o' of World, cursor was between 'r' and 'l')
      // 'Hello World' -> length 11, cursor was at 8. 'Hello Wo' + 'rld'.
      // Wait, let's see. 'Hello World' indices:
      // H:0, e:1, l:2, l:3, o:4,  :5, W:6, o:7, r:8, l:9, d:10
      // Cursor was at 11, move left 3 times -> cursor is at 8 (before 'r').
      // Backspace at 8 deletes char at 7 ('o').
      field.handleKeyEvent(const KeyEvent('backspace', KeyType.backspace));
      expect(field.value, equals('Hello Wrld'));
    });

    test('Multiline text field insertion and newlines', () {
      final field = TextField(
        initialText: 'Line 1',
        multiline: true,
        focused: true,
      );
      field.cursorColumn = 6; // move cursor to the end of 'Line 1'

      // Press enter
      field.handleKeyEvent(const KeyEvent('\n', KeyType.enter));
      expect(field.value, equals('Line 1\n'));

      // Type 'Line 2'
      for (final char in 'Line 2'.split('')) {
        field.handleKeyEvent(KeyEvent(char, KeyType.character));
      }
      expect(field.value, equals('Line 1\nLine 2'));

      // Undo last type (since we save state on character insertions occasionally or on enter/actions)
      // Note: TextField saves state on actions, backspaces, or on type character (if state wasn't dirty).
      // Let's verify undo/redo.
      field.handleKeyEvent(
        const KeyEvent(
          'z',
          KeyType.character,
          modifiers: {ev.Modifier.control},
        ),
      );
      expect(field.value, equals('Line 1\nLine '));

      field.handleKeyEvent(
        const KeyEvent(
          'y',
          KeyType.character,
          modifiers: {ev.Modifier.control},
        ),
      );
      expect(field.value, equals('Line 1\nLine 2'));
    });
  });

  group('Interactive Widgets Tests', () {
    test('Checkbox toggle key/mouse', () {
      bool checkboxVal = false;
      Checkbox getCheckbox({required bool focused}) => Checkbox(
        value: checkboxVal,
        label: 'Agree',
        focused: focused,
        onChanged: (v) => checkboxVal = v,
      );

      // Verify rendering
      final buffer = Buffer.blank(15, 1);
      buffer.clear();
      getCheckbox(focused: false).render(buffer, const Rect(0, 0, 15, 1));
      expect(
        buffer,
        matchesAnsiGolden(
          'test/goldens/checkbox_unselected.ansi',
          environment: {'GENERATE_GOLDENS': 'true'},
        ),
      );

      // Handle click
      getCheckbox(focused: true).handleMouseEvent(
        const MouseEvent(
          x: 1,
          y: 1,
          button: MouseButton.left,
          type: MouseEventType.press,
        ),
        0,
        0,
      );
      expect(checkboxVal, isTrue);

      // Render again
      buffer.clear();
      getCheckbox(focused: false).render(buffer, const Rect(0, 0, 15, 1));
      expect(
        buffer,
        matchesAnsiGolden(
          'test/goldens/checkbox_selected.ansi',
          environment: {'GENERATE_GOLDENS': 'true'},
        ),
      );

      // Handle Key Space
      getCheckbox(
        focused: true,
      ).handleKeyEvent(const KeyEvent(' ', KeyType.character));
      expect(checkboxVal, isFalse);
    });

    test('Radio select key/mouse', () {
      String groupVal = 'A';
      Radio<String> getRadio(String val, {required bool focused}) =>
          Radio<String>(
            value: val,
            groupValue: groupVal,
            label: 'Option $val',
            focused: focused,
            onChanged: (v) => groupVal = v,
          );

      final buffer = Buffer.blank(15, 1);
      buffer.clear();
      getRadio('B', focused: false).render(buffer, const Rect(0, 0, 15, 1));
      expect(
        buffer,
        matchesAnsiGolden(
          'test/goldens/radio_unselected.ansi',
          environment: {'GENERATE_GOLDENS': 'true'},
        ),
      );

      // Press Enter to select
      getRadio(
        'B',
        focused: true,
      ).handleKeyEvent(const KeyEvent('\n', KeyType.enter));
      expect(groupVal, equals('B'));

      buffer.clear();
      getRadio('B', focused: false).render(buffer, const Rect(0, 0, 15, 1));
      expect(
        buffer,
        matchesAnsiGolden(
          'test/goldens/radio_selected.ansi',
          environment: {'GENERATE_GOLDENS': 'true'},
        ),
      );
    });

    test('Switch toggle key/mouse', () {
      bool switchVal = false;
      Switch getSwitch({required bool focused}) => Switch(
        value: switchVal,
        label: 'Sound',
        focused: focused,
        onChanged: (v) => switchVal = v,
      );

      final buffer = Buffer.blank(15, 1);
      buffer.clear();
      getSwitch(focused: false).render(buffer, const Rect(0, 0, 15, 1));
      expect(
        buffer,
        matchesAnsiGolden(
          'test/goldens/switch_unselected.ansi',
          environment: {'GENERATE_GOLDENS': 'true'},
        ),
      );

      // Click to toggle
      getSwitch(focused: true).handleMouseEvent(
        const MouseEvent(
          x: 1,
          y: 1,
          button: MouseButton.left,
          type: MouseEventType.press,
        ),
        0,
        0,
      );
      expect(switchVal, isTrue);

      buffer.clear();
      getSwitch(focused: false).render(buffer, const Rect(0, 0, 15, 1));
      expect(
        buffer,
        matchesAnsiGolden(
          'test/goldens/switch_selected.ansi',
          environment: {'GENERATE_GOLDENS': 'true'},
        ),
      );
    });

    test('Button trigger key/mouse', () {
      bool pressed = false;
      final btn = Button(
        text: 'Click',
        focused: true,
        onPressed: () => pressed = true,
      );

      btn.handleKeyEvent(const KeyEvent(' ', KeyType.character));
      expect(pressed, isTrue);

      pressed = false;
      btn.handleMouseEvent(
        const MouseEvent(
          x: 1,
          y: 1,
          button: MouseButton.left,
          type: MouseEventType.press,
        ),
        0,
        0,
      );
      expect(pressed, isTrue);
    });
  });

  group('ScrollBar Interaction Tests', () {
    test('ScrollBar updates controller on click/drag', () {
      final controller = DiscreteScrollController();
      controller.totalExtent = 100;
      controller.viewportExtent = 10; // max scroll offset = 90

      final scrollBar = ScrollBar(
        controller: controller,
        direction: LayoutDirection.vertical,
      );

      final buffer = Buffer.blank(1, 10);
      scrollBar.render(buffer, const Rect(0, 0, 1, 10));

      // Click at the exact middle of the 10-line scrollbar (y = 5)
      // clickRatio = 5 / 10 = 0.5.
      // newOffset = clickRatio * total = 0.5 * 100 = 50.
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

      expect(controller.scrollOffset, equals(50));
    });
  });
}
