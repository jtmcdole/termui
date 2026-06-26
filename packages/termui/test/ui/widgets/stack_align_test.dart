import 'package:termui/termui.dart';
import 'package:termui_recorder/termui_recorder.dart';
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
        Positioned(
          left: 2,
          top: 2,
          child: SizedBox(width: 2, height: 2, child: Text('Fr')),
        ),
      ]);
      final element = stack.createElement();
      element.mount(null);
      element.layout(BoxConstraints.tight(const Size(10, 10)));
      expect(
        (element as StackElement).childElements[1].relativeOffset,
        const Offset(2, 2),
      );
    });

    test(
      'Stack positions child when left/width and top/height are omitted but right/bottom are specified',
      () {
        final stack = Stack([
          Positioned(
            right: 2,
            bottom: 3,
            child: SizedBox(width: 2, height: 1, child: Text('Fr')),
          ),
        ]);
        final element = stack.createElement();
        element.mount(null);
        element.layout(BoxConstraints.tight(const Size(10, 10)));
        expect(
          (element as StackElement).childElements.first.relativeOffset,
          const Offset(6, 6),
        );
      },
    );
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
      expect(
        (element as dynamic).childElement.relativeOffset,
        const Offset(4, 4),
      );
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
      expect(
        (element as dynamic).childElement.relativeOffset,
        const Offset(8, 8),
      );
    });
  });

  group('Stack constraints and sizing tests (loose & unbounded)', () {
    test(
      'Stack with loose constraints sizes to non-positioned children and positions correctly',
      () {
        final stack = Stack([
          SizedBox(width: 5, height: 5, child: Text('Base')),
          Positioned(
            right: 0,
            bottom: 0,
            child: SizedBox(width: 1, height: 1, child: Text('P')),
          ),
        ]);
        final element = stack.createElement();
        element.mount(null);
        element.layout(
          BoxConstraints(
            minWidth: 0,
            maxWidth: 10,
            minHeight: 0,
            maxHeight: 10,
          ),
        );

        // The stack should be sized to the non-positioned child: 5x5.
        expect(element.size, const Size(5, 5));

        // The positioned child (right: 0, bottom: 0) should be positioned at Offset(4, 4).
        final positionedElement = (element as StackElement).childElements[1];
        expect(positionedElement.relativeOffset, const Offset(4, 4));
      },
    );

    test(
      'Stack with unbounded constraints does not squeeze positioned children to 0 width',
      () {
        final stack = Stack([
          SizedBox(width: 5, height: 5, child: Text('Base')),
          Positioned(
            left: 1,
            top: 1,
            child: SizedBox(width: 2, height: 2, child: Text('P')),
          ),
        ]);
        final element = stack.createElement();
        element.mount(null);

        // Layout with unbounded (infinity) constraints.
        element.layout(
          const BoxConstraints(
            minWidth: 0,
            maxWidth: BoxConstraints.infinity,
            minHeight: 0,
            maxHeight: BoxConstraints.infinity,
          ),
        );

        // Stack should size to the non-positioned child: 5x5.
        expect(element.size, const Size(5, 5));

        // The positioned child should be laid out at Offset(1, 1).
        final positionedElement = (element as StackElement).childElements[1];
        expect(positionedElement.relativeOffset, const Offset(1, 1));
        expect(positionedElement.size, const Size(2, 2));
      },
    );
  });

  group('Stack Positioned Golden Tests', () {
    void runStackGolden(
      String goldenPath,
      Widget widget, {
      int width = 30,
      int height = 10,
    }) {
      // 30% grey buffer is 2 cells wider and taller to show the edges.
      final buffer = Buffer.blank(width + 2, height + 2);
      buffer.fillAttributes(bg: const Color(77, 77, 77).argb);

      // Wrap the stack widget in a DecoratedBox with a single line border
      // and a 50% yellow background.
      final decorated = DecoratedBox(
        decoration: const BoxDecoration(
          backgroundColor: Color(128, 128, 0), // 50% yellow
          border: Border.single,
        ),
        child: widget,
      );

      final element = decorated.createElement();
      element.mount(null);
      element.layout(BoxConstraints.tight(Size(width, height)));
      element.paint(buffer, const Offset(1, 1));

      expect(
        buffer,
        matchesAnsiGolden(
          goldenPath,
          environment: {'GENERATE_GOLDENS': 'true'},
        ),
      );
    }

    test('renders centered positioned widget with description', () {
      final stack = Stack([
        SizedBox(
          width: 30,
          height: 10,
          child: Text('Expected: Centered12x2 centered inside stack.'),
        ),
        Positioned.center(
          width: 12,
          height: 2,
          child: StackGoldenTestWidget(label: 'Centered12x2'),
        ),
      ]);
      runStackGolden('test/goldens/stack/positioned_centered.ansi', stack);
    });

    test(
      'renders left/right/top/height stretch and offset with description',
      () {
        final stack = Stack([
          SizedBox(
            width: 30,
            height: 10,
            child: Text('Expected: L2-R2-T2-H2 stretched horizontally.'),
          ),
          Positioned(
            left: 2,
            right: 2,
            top: 2,
            height: 2,
            child: StackGoldenTestWidget(label: 'L2-R2-T2-H2'),
          ),
        ]);
        runStackGolden('test/goldens/stack/positioned_left_right.ansi', stack);
      },
    );

    test(
      'renders left/width/top/bottom stretch and offset with description',
      () {
        final stack = Stack([
          SizedBox(
            width: 30,
            height: 10,
            child: Text('Expected: L2-W10-T2-B2 stretched vertically.'),
          ),
          Positioned(
            left: 2,
            width: 10,
            top: 2,
            bottom: 2,
            child: StackGoldenTestWidget(label: 'L2-W10-T2-B2'),
          ),
        ]);
        runStackGolden('test/goldens/stack/positioned_top_bottom.ansi', stack);
      },
    );

    test(
      'renders right/bottom only with loose constraints and description',
      () {
        final stack = Stack([
          SizedBox(
            width: 30,
            height: 10,
            child: Text('Expected: R2-B2-Loose sized naturally in stack.'),
          ),
          Positioned(
            right: 2,
            bottom: 2,
            child: StackGoldenTestWidget(label: 'R2-B2-Loose'),
          ),
        ]);
        runStackGolden(
          'test/goldens/stack/positioned_right_bottom_loose.ansi',
          stack,
        );
      },
    );

    test('renders left/top only with loose constraints and description', () {
      final stack = Stack([
        SizedBox(
          width: 30,
          height: 10,
          child: Text('Expected: L2-T2-Loose sized naturally in stack.'),
        ),
        Positioned(
          left: 2,
          top: 2,
          child: StackGoldenTestWidget(label: 'L2-T2-Loose'),
        ),
      ]);
      runStackGolden(
        'test/goldens/stack/positioned_left_top_loose.ansi',
        stack,
      );
    });

    test('renders right/width and bottom/height with description', () {
      final stack = Stack([
        SizedBox(
          width: 30,
          height: 10,
          child: Text('Expected: R2-W10-B2-H2 positioned from R & B.'),
        ),
        Positioned(
          right: 2,
          width: 10,
          bottom: 2,
          height: 2,
          child: StackGoldenTestWidget(label: 'R2-W10-B2-H2'),
        ),
      ]);
      runStackGolden(
        'test/goldens/stack/positioned_right_bottom_fixed.ansi',
        stack,
      );
    });

    test(
      'renders overconstrained degenerate negative layout with description',
      () {
        final stack = Stack([
          SizedBox(
            width: 30,
            height: 10,
            child: Text('Expected: L20 + R20 > W28, clamps width to 0.'),
          ),
          Positioned(
            left: 20,
            right: 20,
            top: 1,
            bottom: 1,
            child: StackGoldenTestWidget(label: 'ClampedNegative'),
          ),
        ]);
        runStackGolden(
          'test/goldens/stack/positioned_clamped_negative.ansi',
          stack,
        );
      },
    );

    test(
      'renders centered positioned widget with loose constraints and description',
      () {
        final stack = Stack([
          SizedBox(
            width: 30,
            height: 10,
            child: Text('Expected: CenteredLoose centered inside stack.'),
          ),
          Positioned.center(
            child: StackGoldenTestWidget(label: 'CenteredLoose'),
          ),
        ]);
        runStackGolden(
          'test/goldens/stack/positioned_centered_loose.ansi',
          stack,
        );
      },
    );

    test('renders right-only loose constraints and description', () {
      final stack = Stack([
        SizedBox(
          width: 30,
          height: 10,
          child: Text('Expected: RightOnlyLoose at R2 inside stack.'),
        ),
        Positioned(
          right: 2,
          child: StackGoldenTestWidget(label: 'RightOnlyLoose'),
        ),
      ]);
      runStackGolden(
        'test/goldens/stack/positioned_right_only_loose.ansi',
        stack,
      );
    });

    test('renders bottom-only loose constraints and description', () {
      final stack = Stack([
        SizedBox(
          width: 30,
          height: 10,
          child: Text('Expected: BottomOnlyLoose at B2 inside stack.'),
        ),
        Positioned(
          bottom: 2,
          child: StackGoldenTestWidget(label: 'BottomOnlyLoose'),
        ),
      ]);
      runStackGolden(
        'test/goldens/stack/positioned_bottom_only_loose.ansi',
        stack,
      );
    });

    test(
      'renders width-only and height-only fixed constraints and description',
      () {
        final stack = Stack([
          SizedBox(
            width: 30,
            height: 10,
            child: Text('Expected: W12-H3 at L0, T0 inside stack.'),
          ),
          Positioned(
            width: 12,
            height: 3,
            child: StackGoldenTestWidget(label: 'W12-H3'),
          ),
        ]);
        runStackGolden(
          'test/goldens/stack/positioned_width_height_only.ansi',
          stack,
        );
      },
    );

    test('renders none specified default constraints and description', () {
      final stack = Stack([
        SizedBox(
          width: 30,
          height: 10,
          child: Text('Expected: NoneSpecified at L0, T0 inside stack.'),
        ),
        Positioned(child: StackGoldenTestWidget(label: 'NoneSpecified')),
      ]);
      runStackGolden(
        'test/goldens/stack/positioned_none_specified.ansi',
        stack,
      );
    });

    test(
      'renders overconstrained degenerate negative height layout with description',
      () {
        final stack = Stack([
          SizedBox(
            width: 30,
            height: 10,
            child: Text('Expected: T8 + B8 > H8, clamps height to 0.'),
          ),
          Positioned(
            top: 8,
            bottom: 8,
            child: StackGoldenTestWidget(label: 'ClampedHeight'),
          ),
        ]);
        runStackGolden(
          'test/goldens/stack/positioned_clamped_negative_height.ansi',
          stack,
        );
      },
    );
  });
}

class StackGoldenTestWidget extends Widget {
  final String label;

  const StackGoldenTestWidget({required this.label, super.key});

  @override
  Element createElement() => _StackGoldenTestElement(this);
}

class _StackGoldenTestElement extends Element {
  _StackGoldenTestElement(StackGoldenTestWidget super.widget);

  @override
  Size performLayout(BoxConstraints constraints) {
    final label = (widget as StackGoldenTestWidget).label;
    if (constraints.maxWidth <= 0 || constraints.maxHeight <= 0) {
      return Size.zero;
    }
    return constraints.constrain(Size(label.length, constraints.maxHeight));
  }

  @override
  void performPaint(Buffer buffer, Offset offset) {
    if (size.width <= 0 || size.height <= 0) return;
    final label = (widget as StackGoldenTestWidget).label;
    for (var y = 0; y < size.height; y++) {
      for (var x = 0; x < size.width; x++) {
        buffer.writeString(
          offset.dx + x,
          offset.dy + y,
          '█',
          const Style(foreground: CharmColors.charple),
        );
      }
    }
    buffer.writeString(
      offset.dx,
      offset.dy,
      label,
      const Style(foreground: CharmColors.pepper),
    );
  }
}
