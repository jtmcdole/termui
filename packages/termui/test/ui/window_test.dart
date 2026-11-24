import 'package:termui/termui.dart';
import 'package:test/test.dart';

String _rowText(Buffer buffer, int y) =>
    [for (var x = 0; x < buffer.width; x++) buffer.getCharacter(x, y)].join();

void main() {
  setUp(() {
    FocusManager.instance.setPrimaryFocus(null);
  });

  group('WindowElement drag, resize, and chrome', () {
    test('title press, drag (4, 3), release, then drag fires onPan once', () {
      final panEvents = <(int, int)>[];
      final win = Window(
        title: 'Demo',
        width: 20,
        height: 8,
        onPan: (dx, dy) => panEvents.add((dx, dy)),
        child: const SizedBox.shrink(),
      );
      final el = win.createElement() as WindowElement..mount(null);
      el.layout(BoxConstraints.tight(const Size(20, 8)));

      // Title ' Demo ' is centered at x = (20 - 6) ~/ 2 = 7..12 on y = 0.
      expect(win.isPositionOnTitle(8, 0), isTrue);

      el.handleMouseEvent(
        const MouseEvent(x: 8, y: 0, button: .left, type: .press),
        8,
        0,
      );
      el.handleMouseEvent(
        const MouseEvent(x: 12, y: 3, button: .left, type: .drag),
        12,
        3,
      );
      el.handleMouseEvent(
        const MouseEvent(x: 12, y: 3, button: .left, type: .release),
        12,
        3,
      );
      el.handleMouseEvent(
        const MouseEvent(x: 16, y: 6, button: .left, type: .drag),
        16,
        6,
      );

      expect(panEvents, [(4, 3)]);
    });

    test('bottom-right corner drag clamps onResize to (10, 5)', () {
      final resizeEvents = <(int, int)>[];
      final win = Window(
        title: 'Resize',
        width: 12,
        height: 6,
        onResize: (w, h) => resizeEvents.add((w, h)),
        child: const SizedBox.shrink(),
      );
      final el = win.createElement() as WindowElement..mount(null);
      el.layout(BoxConstraints.tight(const Size(12, 6)));

      // Press at bottom-right corner (11, 5), drag inward by (-5, -3).
      el.handleMouseEvent(
        const MouseEvent(x: 11, y: 5, button: .left, type: .press),
        11,
        5,
      );
      el.handleMouseEvent(
        const MouseEvent(x: 6, y: 2, button: .left, type: .drag),
        6,
        2,
      );

      expect(resizeEvents, [(10, 5)]);
    });

    test(
      'bottom-left corner drag clamps onResize to (10, 5) and fires onPan(actualDx, 0)',
      () {
        final panEvents = <(int, int)>[];
        final resizeEvents = <(int, int)>[];
        final win = Window(
          title: 'Resize',
          width: 12,
          height: 6,
          onPan: (dx, dy) => panEvents.add((dx, dy)),
          onResize: (w, h) => resizeEvents.add((w, h)),
          child: const SizedBox.shrink(),
        );
        final el = win.createElement() as WindowElement..mount(null);
        el.layout(BoxConstraints.tight(const Size(12, 6)));

        // Press at bottom-left corner (0, 5), drag right+up by (+5, -3).
        // newWidth = max(10, 12 - 5) = 10, actualDx = 12 - 10 = 2.
        el.handleMouseEvent(
          const MouseEvent(x: 0, y: 5, button: .left, type: .press),
          0,
          5,
        );
        el.handleMouseEvent(
          const MouseEvent(x: 5, y: 2, button: .left, type: .drag),
          5,
          2,
        );

        expect(panEvents, [(2, 0)]);
        expect(resizeEvents, [(10, 5)]);
      },
    );

    test('showCloseButton paints [x] at offset.dx + w - 4', () {
      final buffer = Buffer.blank(25, 10);
      final win = Window(
        title: 'App',
        width: 16,
        height: 6,
        showCloseButton: true,
        child: const SizedBox.shrink(),
      );
      final el = win.createElement()..mount(null);
      el.layout(BoxConstraints.tight(const Size(16, 6)));
      el.paint(buffer, const Offset(3, 2));

      final topRow = _rowText(buffer, 2);
      // offset.dx (3) + w (16) - 4 = 15.
      expect(topRow.substring(15, 18), '[x]');
    });

    test(
      'isPositionOnTitle handles empty, truncated, and suppressed titles',
      () {
        final emptyTitle = Window(
          title: '',
          width: 12,
          height: 5,
          child: const SizedBox.shrink(),
        );
        expect(emptyTitle.isPositionOnTitle(5, 0), isFalse);

        final suppressed = Window(
          title: 'Very Long Title',
          width: 7,
          height: 5,
          child: const SizedBox.shrink(),
        );
        expect(suppressed.isPositionOnTitle(3, 0), isFalse);

        final truncated = Window(
          title: 'Very Long Title',
          width: 12,
          height: 5,
          child: const SizedBox.shrink(),
        );
        // Displayed title: ' Very ... ' (length 10), centered at titleX = 1..10.
        expect(truncated.isPositionOnTitle(1, 0), isTrue);
        expect(truncated.isPositionOnTitle(10, 0), isTrue);
        expect(truncated.isPositionOnTitle(0, 0), isFalse);
        expect(truncated.isPositionOnTitle(1, 1), isFalse);
      },
    );
  });
}
