import 'package:test/test.dart';
import 'package:termui/termui.dart';
import 'phase1_layout_state_test.dart';

void main() {
  group('Stack Positioned right & bottom alignment tests', () {
    test('Positioned right alignment without explicit width', () {
      final buffer = Buffer.blank(10, 5);
      final stack = Stack([
        const SizedBox(width: 10, height: 5, child: TestWidget('.')),
        const Positioned(
          top: 1,
          right: 1,
          child: SizedBox(width: 3, height: 1, child: TestWidget('X')),
        ),
      ]);

      final element = stack.createElement();
      element.mount(null);
      element.layout(BoxConstraints.tight(const Size(10, 5)));
      element.paint(buffer, Offset.zero);

      // Stack width = 10, child width = 3, right = 1 => child X = 10 - 1 - 3 = 6.
      // Top = 1 => child Y = 1.
      // Expected: X at (6, 1), (7, 1), (8, 1). (0, 1) should be '.'.
      expect(buffer.getCharacter(0, 1), '.');
      expect(buffer.getCharacter(6, 1), 'X');
      expect(buffer.getCharacter(7, 1), 'X');
      expect(buffer.getCharacter(8, 1), 'X');
      expect(buffer.getCharacter(9, 1), '.');
    });

    test('Positioned bottom alignment without explicit height', () {
      final buffer = Buffer.blank(5, 10);
      final stack = Stack([
        const SizedBox(width: 5, height: 10, child: TestWidget('.')),
        const Positioned(
          left: 1,
          bottom: 2,
          child: SizedBox(width: 1, height: 3, child: TestWidget('Y')),
        ),
      ]);

      final element = stack.createElement();
      element.mount(null);
      element.layout(BoxConstraints.tight(const Size(5, 10)));
      element.paint(buffer, Offset.zero);

      // Stack height = 10, child height = 3, bottom = 2 => child Y = 10 - 2 - 3 = 5.
      // Left = 1 => child X = 1.
      // Expected: Y at (1, 5), (1, 6), (1, 7). (1, 0) should be '.'.
      expect(buffer.getCharacter(1, 0), '.');
      expect(buffer.getCharacter(1, 5), 'Y');
      expect(buffer.getCharacter(1, 6), 'Y');
      expect(buffer.getCharacter(1, 7), 'Y');
      expect(buffer.getCharacter(1, 8), '.');
    });

    test(
      'Button anchored at Positioned(top: 1, right: 0) without explicit width',
      () {
        final buffer = Buffer.blank(10, 5);
        final stack = Stack([
          const SizedBox(width: 10, height: 5, child: TestWidget('.')),
          Positioned(
            top: 1,
            right: 0,
            child: Button(text: '<', onPressed: () {}),
          ),
        ]);

        final element = stack.createElement();
        element.mount(null);
        element.layout(BoxConstraints.tight(const Size(10, 5)));
        element.paint(buffer, Offset.zero);

        // Stack width = 10, Button text = '<' -> unfocused label = '  <  ' (length 5).
        // top = 1, right = 0 => X = 10 - 0 - 5 = 5, Y = 1.
        // Expected: '  <  ' rendered at columns 5..9 on line 1. Column 0..4 on line 1 should be '.'.
        expect(buffer.getCharacter(0, 1), '.');
        expect(buffer.getCharacter(4, 1), '.');
        expect(buffer.getCharacter(5, 1), ' ');
        expect(buffer.getCharacter(7, 1), '<');
        expect(buffer.getCharacter(9, 1), ' ');
      },
    );

    test('Positioned with both left and right set stretches child', () {
      final buffer = Buffer.blank(10, 5);
      final stack = Stack([
        const SizedBox(width: 10, height: 5, child: TestWidget('.')),
        const Positioned(
          left: 2,
          right: 3,
          top: 0,
          child: SizedBox(height: 1, child: TestWidget('Z')),
        ),
      ]);

      final element = stack.createElement();
      element.mount(null);
      element.layout(BoxConstraints.tight(const Size(10, 5)));
      element.paint(buffer, Offset.zero);

      // Stack width = 10, left = 2, right = 3 => child width = 10 - 2 - 3 = 5.
      // child X = 2. Expected Z at cols 2, 3, 4, 5, 6.
      expect(buffer.getCharacter(1, 0), '.');
      expect(buffer.getCharacter(2, 0), 'Z');
      expect(buffer.getCharacter(6, 0), 'Z');
      expect(buffer.getCharacter(7, 0), '.');
    });

    test('Positioned.center positions child at center', () {
      final buffer = Buffer.blank(10, 5);
      final stack = Stack([
        const SizedBox(width: 10, height: 5, child: TestWidget('.')),
        const Positioned.center(
          child: SizedBox(width: 4, height: 1, child: TestWidget('C')),
        ),
      ]);

      final element = stack.createElement();
      element.mount(null);
      element.layout(BoxConstraints.tight(const Size(10, 5)));
      element.paint(buffer, Offset.zero);

      // Stack width = 10, height = 5, child width = 4, height = 1.
      // X = (10 - 4) ~/ 2 = 3. Y = (5 - 1) ~/ 2 = 2.
      expect(buffer.getCharacter(2, 2), '.');
      expect(buffer.getCharacter(3, 2), 'C');
      expect(buffer.getCharacter(6, 2), 'C');
      expect(buffer.getCharacter(7, 2), '.');
    });
  });
}
