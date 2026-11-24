import 'package:termui/src/window_title.dart';
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

    test('compact 1x3 window skips wide continuation cells', () {
      final buffer = Buffer.blank(5, 5);
      // Wide char at (1, 1) places a '' continuation cell at (2, 1).
      buffer.writeString(1, 1, '漢', Style.empty);
      expect(buffer.getCharacter(2, 1), '');

      const borderFg = Color(255, 0, 0);
      final win = Window(
        title: 'X',
        width: 1,
        height: 3,
        borderStyle: const Style(foreground: borderFg),
        child: const SizedBox.shrink(),
      );
      final el = win.createElement()..mount(null);
      el.layout(BoxConstraints.tight(const Size(1, 3)));
      el.paint(buffer, const Offset(2, 0));

      expect(buffer.getCharacter(2, 0), ' ');
      expect(buffer.getForeground(2, 0), borderFg.argb);
      expect(buffer.getCharacter(2, 1), '');
      expect(buffer.getForeground(2, 1), isNot(borderFg.argb));
      expect(buffer.getCharacter(2, 2), ' ');
      expect(buffer.getForeground(2, 2), borderFg.argb);
    });

    test(
      'onMouseEvent forwards all events, body clicks isolate drag, and globalX/globalY drive pan',
      () {
        final forwarded = <(MouseEventType, int, int)>[];
        final panEvents = <(int, int)>[];
        final resizeEvents = <(int, int)>[];
        final win = Window(
          title: 'Demo',
          width: 20,
          height: 8,
          onMouseEvent: (e, lx, ly) => forwarded.add((e.type, lx, ly)),
          onPan: (dx, dy) => panEvents.add((dx, dy)),
          onResize: (w, h) => resizeEvents.add((w, h)),
          child: const SizedBox.shrink(),
        );
        final el = win.createElement() as WindowElement..mount(null);
        el.layout(BoxConstraints.tight(const Size(20, 8)));

        // Body click + drag should not trigger pan or resize, but still forward.
        el.handleMouseEvent(
          const MouseEvent(x: 5, y: 3, button: .left, type: .press),
          5,
          3,
        );
        el.handleMouseEvent(
          const MouseEvent(x: 10, y: 5, button: .left, type: .drag),
          10,
          5,
        );
        el.handleMouseEvent(
          const MouseEvent(x: 10, y: 5, button: .none, type: .move),
          10,
          5,
        );
        expect(panEvents, isEmpty);
        expect(resizeEvents, isEmpty);

        // Title drag using globalX/globalY while local x/y stay fixed.
        el.handleMouseEvent(
          const MouseEvent(
            x: 8,
            y: 0,
            globalX: 100,
            globalY: 50,
            button: .left,
            type: .press,
          ),
          8,
          0,
        );
        el.handleMouseEvent(
          const MouseEvent(
            x: 8,
            y: 0,
            globalX: 107,
            globalY: 54,
            button: .left,
            type: .drag,
          ),
          8,
          0,
        );
        el.handleMouseEvent(
          const MouseEvent(
            x: 8,
            y: 0,
            globalX: 107,
            globalY: 54,
            button: .left,
            type: .release,
          ),
          8,
          0,
        );

        expect(panEvents, [(7, 4)]);
        expect(resizeEvents, isEmpty);
        expect(forwarded, [
          (MouseEventType.press, 5, 3),
          (MouseEventType.drag, 10, 5),
          (MouseEventType.move, 10, 5),
          (MouseEventType.press, 8, 0),
          (MouseEventType.drag, 8, 0),
          (MouseEventType.release, 8, 0),
        ]);
      },
    );

    test('formatWindowTitle boundary cases', () {
      expect(formatWindowTitle('Demo', 8), ' Demo ');
      expect(formatWindowTitle('ABCDE', 8), ' A... ');
    });
  });
}
