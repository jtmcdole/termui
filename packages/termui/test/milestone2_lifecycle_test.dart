import 'package:test/test.dart';
import 'package:termui/ui/buffer.dart';
import 'package:termui/ui/style.dart';
import 'package:termui/ui/layout.dart';

class SimpleLeafWidget extends Widget {
  final String content;
  const SimpleLeafWidget(this.content);

  @override
  Element createElement() => SimpleLeafElement(this);
}

class SimpleLeafElement extends Element {
  SimpleLeafElement(SimpleLeafWidget super.widget);

  @override
  Size performLayout(BoxConstraints constraints) {
    final w = constraints.maxWidth == BoxConstraints.infinity
        ? 0
        : constraints.maxWidth;
    return constraints.constrain(Size(w, 1));
  }

  @override
  void performPaint(Buffer buffer, Offset offset) {
    final w = widget as SimpleLeafWidget;
    buffer.writeString(offset.dx, offset.dy, w.content, Style.empty);
  }
}

class SimpleStatelessWidget extends StatelessWidget {
  final Widget child;
  const SimpleStatelessWidget({required this.child});

  @override
  Widget build(BuildContext context) {
    return child;
  }
}

class SimpleStatefulWidget extends StatefulWidget {
  final Widget child;
  const SimpleStatefulWidget({required this.child});

  @override
  State createState() => _SimpleStatefulWidgetState();
}

class _SimpleStatefulWidgetState extends State<SimpleStatefulWidget> {
  @override
  Widget build(BuildContext context) {
    return widget.child;
  }
}

class SimpleInheritedWidget extends InheritedWidget {
  const SimpleInheritedWidget({required super.child});

  @override
  bool updateShouldNotify(SimpleInheritedWidget oldWidget) => false;
}

void main() {
  group('Milestone 2 - Base Lifecycle Separation', () {
    test('LeafElement layout and paint works correctly', () {
      final widget = SimpleLeafWidget('Hello');
      final element = widget.createElement();
      element.mount(null);

      final size = element.layout(
        const BoxConstraints(
          minWidth: 5,
          maxWidth: 10,
          minHeight: 1,
          maxHeight: 1,
        ),
      );
      expect(size.width, 10);
      expect(size.height, 1);
      expect(element.size, size);
      expect(element.constraints?.minWidth, 5);

      final buffer = Buffer.blank(10, 1);
      element.paint(buffer, Offset.zero);

      final cell = buffer.getCell(0, 0);
      expect(cell?.char, 'H');

      element.unmount();
    });

    test('StatelessElement layout and paint propagates correctly', () {
      final leaf = SimpleLeafWidget('World');
      final widget = SimpleStatelessWidget(child: leaf);
      final element = StatelessElement(widget);
      element.mount(null);

      final size = element.layout(
        const BoxConstraints(
          minWidth: 5,
          maxWidth: 10,
          minHeight: 1,
          maxHeight: 1,
        ),
      );
      expect(size.width, 10);
      expect(size.height, 1);
      expect(element.size, size);

      final buffer = Buffer.blank(10, 1);
      element.paint(buffer, Offset.zero);

      final cell = buffer.getCell(0, 0);
      expect(cell?.char, 'W');

      element.unmount();
    });

    test('StatefulElement layout and paint propagates correctly', () {
      final leaf = SimpleLeafWidget('State');
      final widget = SimpleStatefulWidget(child: leaf);
      final element = StatefulElement(widget);
      element.mount(null);

      final size = element.layout(
        const BoxConstraints(
          minWidth: 5,
          maxWidth: 10,
          minHeight: 1,
          maxHeight: 1,
        ),
      );
      expect(size.width, 10);
      expect(size.height, 1);
      expect(element.size, size);

      final buffer = Buffer.blank(10, 1);
      element.paint(buffer, Offset.zero);

      final cell = buffer.getCell(0, 0);
      expect(cell?.char, 'S');

      element.unmount();
    });

    test('InheritedElement layout and paint propagates correctly', () {
      final leaf = SimpleLeafWidget('Inherit');
      final widget = SimpleInheritedWidget(child: leaf);
      final element = InheritedElement(widget);
      element.mount(null);

      final size = element.layout(
        const BoxConstraints(
          minWidth: 5,
          maxWidth: 10,
          minHeight: 1,
          maxHeight: 1,
        ),
      );
      expect(size.width, 10);
      expect(size.height, 1);
      expect(element.size, size);

      final buffer = Buffer.blank(10, 1);
      element.paint(buffer, Offset.zero);

      final cell = buffer.getCell(0, 0);
      expect(cell?.char, 'I');

      element.unmount();
    });

    test('ElementWidget layout and paint exposes cached element', () {
      final leaf = SimpleLeafWidget('Bridge');
      final widget = ElementWidget(leaf);

      widget.layout(
        const BoxConstraints(
          minWidth: 6,
          maxWidth: 10,
          minHeight: 1,
          maxHeight: 1,
        ),
      );
      expect(widget.element, isNotNull);
      expect(widget.element!.size.width, 10);

      final buffer = Buffer.blank(10, 1);
      widget.paint(buffer, Offset.zero);

      final cell = buffer.getCell(0, 0);
      expect(cell?.char, 'B');
    });

    test('Element layout and paint performs layout and paint', () {
      final leaf = SimpleLeafWidget('Fallback');
      final element = leaf.createElement();
      element.mount(null);

      final buffer = Buffer.blank(10, 1);
      element.layout(BoxConstraints.tight(const Size(10, 1)));
      element.paint(buffer, Offset.zero);

      expect(element.size.width, 10);
      final cell = buffer.getCell(0, 0);
      expect(cell?.char, 'F');

      element.unmount();
    });
  });
}
