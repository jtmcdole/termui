import 'package:test/test.dart';
import 'package:termui/ui/buffer.dart';
import 'package:termui/ui/style.dart';
import 'package:termui/ui/layout.dart';
import 'package:termui/ui/widget_toolkit.dart';

class TestLeafWidget extends Widget {
  final String content;
  const TestLeafWidget(this.content);

  @override
  Element createElement() => _TestLeafElement(this);

  @override
  int getIntrinsicHeight(int width) {
    return 1;
  }
}

class _TestLeafElement extends Element {
  _TestLeafElement(super.widget);

  @override
  void paint(Buffer buffer, Offset offset) {
    buffer.writeString(
      offset.dx,
      offset.dy,
      (widget as TestLeafWidget).content,
      Style.empty,
    );
  }
}

class TrackingWidget extends Widget {
  final String label;
  final void Function()? onMount;
  final void Function()? onUnmount;
  final void Function(Widget)? onUpdate;

  const TrackingWidget({
    required this.label,
    this.onMount,
    this.onUnmount,
    this.onUpdate,
  });

  @override
  Element createElement() => TrackingElement(this);
}

class TrackingElement extends Element {
  TrackingElement(TrackingWidget super.widget);

  @override
  void mount(Element? parent) {
    super.mount(parent);
    (widget as TrackingWidget).onMount?.call();
  }

  @override
  void unmount() {
    (widget as TrackingWidget).onUnmount?.call();
    super.unmount();
  }

  @override
  void update(Widget newWidget) {
    super.update(newWidget);
    (widget as TrackingWidget).onUpdate?.call(newWidget);
  }

  @override
  Size performLayout(BoxConstraints constraints) {
    final width = constraints.maxWidth == BoxConstraints.infinity
        ? 0
        : constraints.maxWidth;
    return constraints.constrain(Size(width, 1));
  }

  @override
  void paint(Buffer buffer, Offset offset) {
    final trackWidget = widget as TrackingWidget;
    buffer.writeString(offset.dx, offset.dy, trackWidget.label, Style.empty);
  }
}

void main() {
  group('LayoutBuilder Tests', () {
    test(
      'builder function is called with correct BuildContext and BoxConstraints',
      () {
        late BuildContext capturedContext;
        late BoxConstraints capturedConstraints;
        var builderCalled = false;

        final widget = LayoutBuilder(
          builder: (context, constraints) {
            capturedContext = context;
            capturedConstraints = constraints;
            builderCalled = true;
            return const TestLeafWidget('Hello');
          },
        );

        final element = widget.createElement();
        element.mount(null);

        const testConstraints = BoxConstraints(
          minWidth: 5,
          maxWidth: 10,
          minHeight: 1,
          maxHeight: 1,
        );
        final size = element.layout(testConstraints);

        expect(builderCalled, isTrue);
        expect(capturedContext, same(element));
        expect(capturedConstraints.minWidth, 5);
        expect(capturedConstraints.maxWidth, 10);
        expect(capturedConstraints.minHeight, 1);
        expect(capturedConstraints.maxHeight, 1);
        expect(size.width, 10);
        expect(size.height, 1);

        element.unmount();
      },
    );

    test(
      'changing constraints dynamically updates built child widget and size',
      () {
        final widget = LayoutBuilder(
          builder: (context, constraints) {
            if (constraints.maxWidth > 5) {
              return const TestLeafWidget('Wide');
            } else {
              return const TestLeafWidget('Narrow');
            }
          },
        );

        final element = widget.createElement();
        element.mount(null);

        // Wide constraints
        final size1 = element.layout(
          const BoxConstraints(
            minWidth: 8,
            maxWidth: 8,
            minHeight: 1,
            maxHeight: 1,
          ),
        );
        expect(size1.width, 8);

        final buffer1 = Buffer.blank(8, 1);
        element.paint(buffer1, Offset.zero);
        expect(buffer1.getCell(0, 0)?.char, 'W'); // Starts with 'W' from "Wide"

        // Narrow constraints
        final size2 = element.layout(
          const BoxConstraints(
            minWidth: 4,
            maxWidth: 4,
            minHeight: 1,
            maxHeight: 1,
          ),
        );
        expect(size2.width, 4);

        final buffer2 = Buffer.blank(4, 1);
        element.paint(buffer2, Offset.zero);
        expect(
          buffer2.getCell(0, 0)?.char,
          'N',
        ); // Starts with 'N' from "Narrow"

        element.unmount();
      },
    );

    test(
      'rebuilding, mounting, updating, and unmounting subtrees inside LayoutBuilder',
      () {
        var mountCount = 0;
        var unmountCount = 0;
        var updateCount = 0;
        var label = 'A';

        final widget = LayoutBuilder(
          builder: (context, constraints) {
            return TrackingWidget(
              label: label,
              onMount: () => mountCount++,
              onUnmount: () => unmountCount++,
              onUpdate: (newWidget) => updateCount++,
            );
          },
        );

        final element = widget.createElement();
        element.mount(null);

        // 1. Initial Layout & Mount
        final size = element.layout(
          const BoxConstraints(
            minWidth: 5,
            maxWidth: 5,
            minHeight: 1,
            maxHeight: 1,
          ),
        );
        expect(size.width, 5);
        expect(mountCount, 1);
        expect(unmountCount, 0);

        final buffer1 = Buffer.blank(5, 1);
        element.paint(buffer1, Offset.zero);
        expect(buffer1.getCell(0, 0)?.char, 'A');

        // 2. Rebuild with same widget type (updates child)
        label = 'B';
        element.rebuild();

        expect(mountCount, 1); // No new mount since type matches
        expect(updateCount, 1); // Child updated
        expect(unmountCount, 0);

        final buffer2 = Buffer.blank(5, 1);
        element.paint(buffer2, Offset.zero);
        expect(buffer2.getCell(0, 0)?.char, 'B');

        // 3. Update the LayoutBuilder widget itself with a new builder
        var newBuilderCount = 0;
        final newLayoutBuilder = LayoutBuilder(
          builder: (context, constraints) {
            newBuilderCount++;
            return TrackingWidget(
              label: 'C',
              onMount: () => mountCount++,
              onUnmount: () => unmountCount++,
              onUpdate: (newWidget) => updateCount++,
            );
          },
        );

        element.update(newLayoutBuilder); // calls rebuild internally

        expect(newBuilderCount, 1);
        expect(
          mountCount,
          1,
        ); // Old element was type-compatible, so it was updated
        expect(updateCount, 2);
        expect(unmountCount, 0);

        final buffer3 = Buffer.blank(5, 1);
        element.paint(buffer3, Offset.zero);
        expect(buffer3.getCell(0, 0)?.char, 'C');

        // 4. Force builder to return different widget type (should unmount old and mount new)
        var differentBuilderCount = 0;
        final differentLayoutBuilder = LayoutBuilder(
          builder: (context, constraints) {
            differentBuilderCount++;
            return const TestLeafWidget('Leaf');
          },
        );

        element.update(differentLayoutBuilder);

        expect(differentBuilderCount, 1);
        expect(
          unmountCount,
          1,
        ); // Old TrackingWidget element unmounted because of type mismatch

        final buffer4 = Buffer.blank(5, 1);
        element.paint(buffer4, Offset.zero);
        expect(buffer4.getCell(0, 0)?.char, 'L'); // "Leaf"

        // 5. Unmount LayoutBuilder element (unmounts active child subtree)
        expect(element.parent, isNull);
        element.unmount();
      },
    );
  });
}
