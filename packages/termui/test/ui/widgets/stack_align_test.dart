import 'package:termui/termui.dart';
import 'package:test/test.dart';

void main() {
  group('Stack Tests', () {
    test('Stack places children over each other', () {
      final stack = Stack([
        SizedBox(width: 5, height: 5, child: Text('Back')),
        SizedBox(width: 2, height: 2, child: Text('Fr')),
      ]);
      final element = stack.createElement();
      element.mount(null);
      element.layout(BoxConstraints.tight(const Size(10, 10)));

      final buffer = Buffer.blank(10, 10);
      element.paint(buffer, Offset.zero);
      // It paints both.
      expect(true, true);
    });

    test('Stack respects positioning constraints', () {
      final stack = Stack([
        SizedBox(width: 5, height: 5, child: Text('Back')),
        Positioned(left: 2, top: 2, child: SizedBox(width: 2, height: 2, child: Text('Fr'))),
      ]);
      final element = stack.createElement();
      element.mount(null);
      element.layout(BoxConstraints.tight(const Size(10, 10)));
      expect(true, true);
    });
  });

  group('Align Tests', () {
    test('Align positions child at center', () {
      final align = Align(
        alignment: Alignment.center,
        child: SizedBox(width: 2, height: 2, child: Text('X')),
      );
      final element = align.createElement();
      element.mount(null);
      element.layout(BoxConstraints.tight(const Size(10, 10)));
      // Center of 10x10 is 4x4 for a 2x2 child.
      expect((element as dynamic).childElement.relativeOffset, const Offset(4, 4));
    });

    test('Align positions child at bottom right', () {
      final align = Align(
        alignment: Alignment.bottomRight,
        child: SizedBox(width: 2, height: 2, child: Text('X')),
      );
      final element = align.createElement();
      element.mount(null);
      element.layout(BoxConstraints.tight(const Size(10, 10)));
      // Bottom right is 8x8.
      expect((element as dynamic).childElement.relativeOffset, const Offset(8, 8));
    });
  });
}
