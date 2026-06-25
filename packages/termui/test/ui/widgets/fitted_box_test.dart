import 'package:test/test.dart';
import 'package:termui/termui.dart';
import 'package:termui_recorder/termui_recorder.dart';

void main() {
  group('FittedBox', () {
    test('BoxFit.none allows child to size naturally without constraints', () {
      final widget = FittedBox(
        fit: BoxFit.none,
        child: const SizedBox(width: 50, height: 20),
      );

      final element = widget.createElement();
      element.mount(null);
      final size = element.layout(
        const BoxConstraints(
          minWidth: 0,
          maxWidth: 10,
          minHeight: 0,
          maxHeight: 5,
        ),
      );

      // Parent constraint maxes out at 10x5, FittedBox enforces it on itself
      expect(size.width, 10);
      expect(size.height, 5);

      // Child should have layout size of 50x20
      var visited = false;
      element.visitChildren((child) {
        visited = true;
        expect(child.size.width, 50);
        expect(child.size.height, 20);
        // Default alignment is center, so offset should be (10 - 50)/2 = -20, (5 - 20)/2 = -7
        // Let's verify dx and dy (-20, -7)
        expect(child.relativeOffset.dx, -20);
        expect(
          child.relativeOffset.dy,
          -8,
        ); // (5 - 20) = -15, /2 = -7.5, rounded = -8
      });
      expect(visited, true);
    });

    test(
      'BoxFit.contain passes bounded constraints but does NOT force smaller child to expand',
      () {
        final widget = FittedBox(
          fit: BoxFit.contain,
          child: const SizedBox(width: 5, height: 2),
        );

        final element = widget.createElement();
        element.mount(null);
        final size = element.layout(
          const BoxConstraints(
            minWidth: 0,
            maxWidth: 10,
            minHeight: 0,
            maxHeight: 5,
          ),
        );

        expect(size.width, 10);
        expect(size.height, 5);

        element.visitChildren((child) {
          expect(child.size.width, 5);
          expect(child.size.height, 2);
          // Default center alignment offset (10 - 5)/2 = 2.5 (rounded to 3), (5 - 2)/2 = 1.5 (rounded to 2)
          expect(child.relativeOffset.dx, 3);
          expect(child.relativeOffset.dy, 2);
        });
      },
    );

    test('BoxFit.cover forces child to be at least parent max bounds', () {
      final widget = FittedBox(
        fit: BoxFit.cover,
        child: const SizedBox(width: 5, height: 2),
      );

      final element = widget.createElement();
      element.mount(null);
      final size = element.layout(
        const BoxConstraints(
          minWidth: 0,
          maxWidth: 10,
          minHeight: 0,
          maxHeight: 5,
        ),
      );

      expect(size.width, 10);
      expect(size.height, 5);

      element.visitChildren((child) {
        // SizedBox maxes out at requested bounds, but constrained by minWidth/Height of cover
        expect(child.size.width, 10);
        expect(child.size.height, 5);
        expect(child.relativeOffset.dx, 0);
        expect(child.relativeOffset.dy, 0);
      });
    });

    test('Clip.hardEdge drops overflowing cells', () {
      final widget = FittedBox(
        fit: BoxFit.none,
        clipBehavior: Clip.hardEdge,
        child: const Text('123456789'), // Width 9
      );

      final element = widget.createElement();
      element.mount(null);
      element.layout(
        const BoxConstraints(
          minWidth: 0,
          maxWidth: 5,
          minHeight: 0,
          maxHeight: 1,
        ),
      );

      final buffer = Buffer(5, 1);
      element.paint(buffer, Offset.zero);

      // The child is 9 wide. Parent is 5 wide.
      // Diff = 5 - 9 = -4.
      // offset.dx = -4 / 2 * 1.0 (since alignment is center, dx = -2).
      // So '12' is cut off. '34567' is drawn.
      expect(buffer.getCharacter(0, 0), '3');
      expect(buffer.getCharacter(1, 0), '4');
      expect(buffer.getCharacter(2, 0), '5');
      expect(buffer.getCharacter(3, 0), '6');
      expect(buffer.getCharacter(4, 0), '7');
    });

    test(
      'Clip.hardEdge does not catastrophically leak memory on massive children',
      () {
        final widget = FittedBox(
          fit: BoxFit.none,
          clipBehavior: Clip.hardEdge,
          child: const SizedBox(width: 10000, height: 10000), // Massive child
        );

        final element = widget.createElement();
        element.mount(null);
        element.layout(
          const BoxConstraints(
            minWidth: 0,
            maxWidth: 10,
            minHeight: 0,
            maxHeight: 10,
          ),
        );

        final buffer = Buffer(10, 10);
        // If FittedBox naive-allocates child bounds, this will OOM or lag heavily.
        element.paint(buffer, Offset.zero);
        expect(element.size.width, 10);
      },
    );

    test('Renders golden showing different fit and clip options', () {
      final buffer = Buffer.blank(40, 20);

      // Using SplitPane or Column/Row to arrange test cases
      final widget = Column([
        Row([
          // Contain, center, hardEdge
          ConstrainedBox(
            constraints: BoxConstraints.tight(const Size(10, 5)),
            child: DecoratedBox(
              decoration: const BoxDecoration(border: Border.ascii),
              child: FittedBox(
                fit: BoxFit.contain,
                clipBehavior: Clip.hardEdge,
                child: Text('Contain\nCenter\nShort'),
              ),
            ),
          ),
          // None, TopLeft, HardEdge (Truncation)
          ConstrainedBox(
            constraints: BoxConstraints.tight(const Size(10, 5)),
            child: DecoratedBox(
              decoration: const BoxDecoration(border: Border.ascii),
              child: FittedBox(
                fit: BoxFit.none,
                alignment: Alignment.topLeft,
                clipBehavior: Clip.hardEdge,
                child: Text(
                  'TopLeftNone\nOverflows\nMassively\nDown\nHere\nMore',
                ),
              ),
            ),
          ),
          // None, Center, None (Leaks bounds)
          ConstrainedBox(
            constraints: BoxConstraints.tight(const Size(10, 5)),
            child: DecoratedBox(
              decoration: const BoxDecoration(border: Border.ascii),
              child: FittedBox(
                fit: BoxFit.none,
                alignment: Alignment.center,
                clipBehavior: Clip.none,
                child: Text('CenterNone\nLeaks\nBounds\nWay\nOut'),
              ),
            ),
          ),
        ]),
      ]);

      final element = widget.createElement();
      element.mount(null);
      element.layout(BoxConstraints.tight(const Size(40, 20)));
      element.paint(buffer, Offset(2, 2));

      expect(buffer, matchesAnsiGolden('test/goldens/fitted_box_options.ansi'));
    });
  });
}
