import 'package:test/test.dart';
import 'package:termui/ui/buffer.dart';
import 'package:termui/ui/style.dart';
import 'package:termui/ui/widgets/core/widget.dart';
import 'package:termui/ui/widgets/core/element.dart';
import 'package:termui/ui/widgets/core/geometry.dart';
import 'package:termui/ui/window.dart';

class SimpleWidget extends Widget {
  const SimpleWidget();

  @override
  Element createElement() => _SimpleElement(this);
}

class _SimpleElement extends Element {
  _SimpleElement(super.widget);

  @override
  Size performLayout(BoxConstraints constraints) {
    return constraints.constrain(const Size(1, 1));
  }

  @override
  void performPaint(Buffer buffer, Offset offset) {
    buffer.writeString(offset.dx, offset.dy, 'X', Style.empty);
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

  group('Visual Border Drawing Tests', () {
    test('Window borders and contents placement', () {
      final buffer = Buffer.blank(15, 10);
      final win = Window(
        title: 'A',
        width: 10,
        height: 5,
        child: const SimpleWidget(),
      );

      ElementWidget(win)
        ..layout(BoxConstraints.tight(const Size(15, 10)))
        ..paint(buffer, const Offset(1, 1));

      // Window bounds: offset (1, 1) to (10, 5) size on buffer
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
