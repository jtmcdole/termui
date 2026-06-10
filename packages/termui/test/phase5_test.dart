import 'dart:math';
import 'package:test/test.dart';
import 'package:termui/ui/buffer.dart';
import 'package:termui/ui/layout.dart';
import 'package:termui/ui/event.dart';
import 'package:termui/ui/color.dart';
import 'package:termui/ui/style.dart';
import 'package:termui/ui/widget_toolkit.dart';

void main() {
  group('Paragraph wrapping tests', () {
    test('Basic wrapping and forced breaks on constraint shrink', () {
      final buffer = Buffer.blank(10, 5);
      final p1 = Text('Hello standard word wrap');
      p1.render(buffer, const Rect(0, 0, 10, 5));

      // 'Hello standard word wrap' -> 'Hello' (5), 'standard' (8), 'word' (4), 'wrap' (4).
      // MaxWidth = 10
      // Line 0: 'Hello'
      // Line 1: 'standard'
      // Line 2: 'word wrap' (4 + 1 + 4 = 9 <= 10)
      expect(buffer.getCell(0, 0)!.char, equals('H'));
      expect(buffer.getCell(0, 1)!.char, equals('s'));
      expect(buffer.getCell(0, 2)!.char, equals('w'));

      // Clean buffer
      buffer.clear();

      // Forced wrapping of a single word larger than max width
      final p2 = Text('Supercalifragilistic');
      // MaxWidth = 8
      p2.render(buffer, const Rect(0, 0, 8, 5));
      // Line 0: Supercal (8)
      // Line 1: ifragili (8)
      // Line 2: stic     (4)
      expect(buffer.getCell(0, 0)!.char, equals('S'));
      expect(buffer.getCell(0, 1)!.char, equals('i'));
      expect(buffer.getCell(0, 2)!.char, equals('s'));
    });
  });

  group('ListWidget tests', () {
    test('Scrolling offset changes based on index selection', () {
      final list = ListWidget(['A', 'B', 'C', 'D', 'E']);
      // Viewport height is 3
      list.selectedIndex = 0;
      list.adjustScroll(3);
      expect(list.scrollOffset, equals(0));

      list.selectedIndex = 2;
      list.adjustScroll(3);
      expect(list.scrollOffset, equals(0));

      list.selectedIndex = 3;
      list.adjustScroll(3); // Moves scrollOffset down so index 3 is visible
      expect(list.scrollOffset, equals(1));

      list.selectedIndex = 1;
      list.adjustScroll(3); // Moves scrollOffset up so index 1 is visible
      expect(list.scrollOffset, equals(1));
    });
  });

  group('TextField (single-line) tests', () {
    test('Character insertions and backspace cursor updates', () {
      final input = TextField(initialText: 'Cat')..cursorColumn = 3;

      input.handleKeyEvent(const KeyEvent('s', KeyType.character));
      expect(input.value, equals('Cats'));
      expect(input.cursorColumn, equals(4));

      // Move cursor left
      input.handleKeyEvent(const KeyEvent('left', KeyType.left));
      expect(input.cursorColumn, equals(3));

      // Backspace (removes 't')
      input.handleKeyEvent(const KeyEvent('backspace', KeyType.backspace));
      expect(input.value, equals('Cas'));
      expect(input.cursorColumn, equals(2));
    });

    test('renders cursor when focused, hides cursor when unfocused', () {
      final input = TextField(initialText: 'abc', focused: true)
        ..cursorColumn = 1;
      final buffer = Buffer.blank(5, 1);

      // When focused
      input.render(buffer, const Rect(0, 0, 5, 1));
      expect(buffer.getCell(1, 0)!.char, equals('b'));
      expect(buffer.getCell(1, 0)!.style, equals(input.cursorStyle));

      // Reset buffer and set focused = false
      buffer.clear();
      input.focused = false;
      input.render(buffer, const Rect(0, 0, 5, 1));
      expect(buffer.getCell(1, 0)!.char, equals('b'));
      expect(buffer.getCell(1, 0)!.style, equals(input.style));
    });

    test(
      'renders placeholder with custom placeholderStyle and overlays cursor on empty value',
      () {
        final input = TextField(
          initialText: '',
          placeholder: 'Hint',
          placeholderStyle: const Style(foreground: Color(100, 100, 100)),
          cursorStyle: const Style(
            foreground: Colors.black,
            background: Colors.orange,
          ),
          focused: true,
        )..cursorColumn = 0;
        final buffer = Buffer.blank(6, 1);

        input.render(buffer, const Rect(0, 0, 6, 1));

        // Cell 0: should be 'H' with cursorStyle (overlaying the first char of placeholder 'Hint')
        expect(buffer.getCell(0, 0)!.char, equals('H'));
        expect(buffer.getCell(0, 0)!.style, equals(input.cursorStyle));

        // Cells 1-3: should be 'int' with placeholderStyle
        expect(buffer.getCell(1, 0)!.char, equals('i'));
        expect(buffer.getCell(1, 0)!.style, equals(input.placeholderStyle));
        expect(buffer.getCell(3, 0)!.char, equals('t'));
        expect(buffer.getCell(3, 0)!.style, equals(input.placeholderStyle));
      },
    );
  });

  group('LinearProgressIndicator tests', () {
    test('Bar render is filled proportionally and centers percentage', () {
      final buffer = Buffer.blank(10, 1);
      final bar = const LinearProgressIndicator(0.5, showPercentage: true);
      // Width = 10. 50% = 5 cells filled, 5 cells shaded.
      // Expected string representation is roughly '███50%████' or similar depending on layout
      bar.render(buffer, const Rect(0, 0, 10, 1));

      expect(buffer.getCell(0, 0)!.char, equals('█'));
      expect(buffer.getCell(9, 0)!.char, equals('░'));

      // Check centring: '5' should be around cell 3 or 4
      final outputStr = List.generate(
        10,
        (x) => buffer.getCell(x, 0)!.char,
      ).join('');
      expect(outputStr, contains('50%'));
    });
  });

  group('Canvas & Benchmark Tests', () {
    test('Braille Bitmask Test', () {
      final canvas = Canvas(1, 1);
      // Set top-left pixel (0, 0) -> Dot 1 (0x01)
      canvas.setPixel(0, 0, true);

      final buffer = Buffer.blank(1, 1);
      canvas.render(buffer, const Rect(0, 0, 1, 1));

      // Unicode value should be U+2800 + 0x01 = 0x2801
      expect(buffer.getCell(0, 0)!.char, equals(String.fromCharCode(0x2801)));

      // Clear and set bottom-right pixel (1, 3) -> Dot 8 (0x80)
      canvas.clear();
      canvas.setPixel(1, 3, true);
      canvas.render(buffer, const Rect(0, 0, 1, 1));
      // Unicode value should be U+2800 + 0x80 = 0x2880 (⢀)
      expect(buffer.getCell(0, 0)!.char, equals(String.fromCharCode(0x2880)));

      // Set both: U+2881
      canvas.setPixel(0, 0, true);
      canvas.render(buffer, const Rect(0, 0, 1, 1));
      expect(buffer.getCell(0, 0)!.char, equals(String.fromCharCode(0x2881)));
    });

    test('Bresenham Integrity Test', () {
      final canvas = Canvas(6, 3); // 12x12 sub-pixels
      canvas.drawLine(0, 0, 10, 10);
      final buffer = Buffer.blank(6, 3);
      canvas.render(buffer, const Rect(0, 0, 6, 3));

      var totalFlagged = 0;
      for (var y = 0; y < 3; y++) {
        for (var x = 0; x < 6; x++) {
          final cell = buffer.getCell(x, y);
          if (cell != null) {
            final code = cell.char.codeUnitAt(0);
            if (code >= 0x2800 && code <= 0x28FF) {
              final dots = code - 0x2800;
              var temp = dots;
              while (temp > 0) {
                if ((temp & 1) != 0) totalFlagged++;
                temp >>= 1;
              }
            }
          }
        }
      }
      expect(totalFlagged, equals(11));
    });

    test('Clipping & Bounds Test', () {
      final canvas = Canvas(10, 10); // 20x40 sub-pixels
      expect(() => canvas.drawCircle(5, 5, 50), returnsNormally);
      expect(
        () => canvas.fillCircle(5, 5, 50, antiAliased: true),
        returnsNormally,
      );
      expect(() => canvas.drawEllipse(5, 5, 50, 50), returnsNormally);
      expect(() => canvas.drawLine(-10, -10, 100, 100), returnsNormally);
      expect(() => canvas.drawBox(-5, -5, 50, 50), returnsNormally);
      expect(
        () => canvas.fillBox(-5, -5, 50, 50, antiAliased: true),
        returnsNormally,
      );
    });

    test('Midpoint Ellipse Algorithm Test', () {
      final canvas = Canvas(10, 10);
      expect(() => canvas.drawEllipse(10, 20, 8, 5), returnsNormally);
    });

    test('Anti-Aliasing Run-time Flag Test', () {
      final canvas = Canvas(2, 2);
      // Draw with anti-aliasing on cell (0, 0) only (2x4 sub-pixels)
      canvas.fillBox(0, 0, 2, 4, antiAliased: true);
      final buffer = Buffer.blank(2, 2);
      canvas.render(buffer, const Rect(0, 0, 2, 2));

      // Cell (0, 0) is completely covered (8/8 sub-pixels).
      // So it should render as solid block '█' rather than Braille characters.
      expect(buffer.getCell(0, 0)!.char, equals('█'));

      // Cell (1, 0) is not drawn, so it is empty space (U+2800)
      expect(
        buffer.getCell(1, 0)!.char,
        anyOf(equals('⠀'), equals(' ')),
      ); // U+2800 or U+0020
    });

    test('Occlusion Culling Test', () {
      final canvas = Canvas(3, 3);
      canvas.fillBox(0, 0, 6, 12); // fill everything

      // Mark cell (1, 1) as occluded
      canvas.isOccluded = (col, row) => col == 1 && row == 1;

      final buffer = Buffer.blank(3, 3);
      canvas.render(buffer, const Rect(0, 0, 3, 3));

      // Cell (1, 1) should be blank/empty because we skipped translation
      expect(buffer.getCell(1, 1)!.char, equals(' ')); // blank cell
      // Other cells should be filled
      expect(buffer.getCell(0, 0)!.char, equals('█'));
    });

    test('Canvas Color Interpolation and Custom Styles Test', () {
      final canvas = Canvas(3, 3);
      final buffer = Buffer.blank(3, 3);

      // Draw a line colored from red to blue
      canvas.drawLineColored(0, 0, 4, 8, Colors.red, Colors.blue);
      canvas.render(buffer, const Rect(0, 0, 3, 3));

      // The cell at (0, 0) should have a foreground color that is Red
      final cell0 = buffer.getCell(0, 0);
      expect(cell0, isNotNull);
      expect(cell0!.style.foreground, isNotNull);
      expect(cell0.style.foreground!.r, equals(255));
      expect(cell0.style.foreground!.g, equals(0));
      expect(cell0.style.foreground!.b, equals(0));

      // The cell at (2, 2) should have a foreground color that is Blue
      final cell2 = buffer.getCell(2, 2);
      expect(cell2, isNotNull);
      expect(cell2!.style.foreground, isNotNull);
      expect(cell2.style.foreground!.r, equals(0));
      expect(cell2.style.foreground!.g, equals(0));
      expect(cell2.style.foreground!.b, equals(255));

      // Test fillTriangleColored
      canvas.clear();
      canvas.fillTriangleColored(
        0,
        0,
        4,
        0,
        0,
        8,
        Colors.red,
        Colors.green,
        Colors.blue,
      );
      buffer.clear();
      canvas.render(buffer, const Rect(0, 0, 3, 3));

      // Ensure some pixels are colored
      expect(buffer.getCell(0, 0)!.style.foreground, isNotNull);

      // Test fillQuadColored
      canvas.clear();
      canvas.fillQuadColored(
        0,
        0,
        4,
        0,
        4,
        8,
        0,
        8,
        Colors.red,
        Colors.orange,
        Colors.blue,
        Colors.green,
      );
      buffer.clear();
      canvas.render(buffer, const Rect(0, 0, 3, 3));

      // Ensure some pixels are colored
      expect(buffer.getCell(0, 0)!.style.foreground, isNotNull);
    });

    test('Canvas Style Propagation and Background Merging Test', () {
      final style = const Style(background: Colors.black);
      final canvas = Canvas(3, 3, style: style);
      final buffer = Buffer.blank(3, 3);

      // Draw a line with a foreground-only style (no background color)
      canvas.drawLine(
        0,
        0,
        4,
        8,
        cellStyle: const Style(foreground: Colors.green),
      );
      canvas.render(buffer, const Rect(0, 0, 3, 3));

      // Cell at (0, 0) has the line pixel, should have green foreground and black background
      final cell0 = buffer.getCell(0, 0);
      expect(cell0, isNotNull);
      expect(cell0!.char, isNot(equals(' ')));
      expect(cell0.style.foreground, equals(Colors.green));
      expect(cell0.style.background, equals(Colors.black));

      // Cell at (2, 0) has no pixel (dots == 0), should have black background
      final cell1 = buffer.getCell(2, 0);
      expect(cell1, isNotNull);
      expect(cell1!.style.background, equals(Colors.black));
    });

    test('Canvas 60fps benchmark test', () {
      final canvas = Canvas(80, 24); // Standard TUI viewport size
      final buffer = Buffer.blank(80, 24);

      final stopwatch = Stopwatch()..start();

      // Render 1000 frames (representing ~16 seconds of 60fps video feed)
      for (var f = 0; f < 1000; f++) {
        canvas.clear();
        // Set some dummy pixels
        for (var i = 0; i < 100; i++) {
          canvas.setPixel((f + i) % 160, (f * 2 + i) % 96, true);
        }
        canvas.render(buffer, const Rect(0, 0, 80, 24));
      }

      stopwatch.stop();
      final ms = stopwatch.elapsedMilliseconds;
      // We expect 1000 frame updates to take way less than 1000ms (1 second), ensuring 60fps is trivially achieved.
      expect(ms, lessThan(1000), reason: 'Took $ms ms for 1000 frames');
      print(
        'Canvas Benchmark: Rendered 1000 frames in $ms ms (${(1000000 / ms).toStringAsFixed(1)} FPS)',
      );
    });

    test('Canvas Triangle Rasterization Rotation Gap Test', () {
      // Helper function to determine if a point is inside the triangle
      double sign(
        double px,
        double py,
        double ax,
        double ay,
        double bx,
        double by,
      ) {
        return (px - bx) * (ay - by) - (ax - bx) * (py - by);
      }

      bool isPointInTriangle(
        double px,
        double py,
        double ax,
        double ay,
        double bx,
        double by,
        double cx,
        double cy,
      ) {
        final d1 = sign(px, py, ax, ay, bx, by);
        final d2 = sign(px, py, bx, by, cx, cy);
        final d3 = sign(px, py, cx, cy, ax, ay);

        final hasNeg = (d1 < 0) || (d2 < 0) || (d3 < 0);
        final hasPos = (d1 > 0) || (d2 > 0) || (d3 > 0);

        return !(hasNeg && hasPos);
      }

      const List<int> dotMasks = [
        0x01,
        0x08,
        0x02,
        0x10,
        0x04,
        0x20,
        0x40,
        0x80,
      ];

      final width = 30;
      final height = 30;
      final canvas = Canvas(
        width,
        height,
        renderMode: CanvasRenderMode.braille,
      );

      final cx = width; // 30 sub-pixels
      final cy = height * 2; // 60 sub-pixels

      var totalGaps = 0;

      // Check a few representative radii and a set of angles to ensure no rasterization gaps
      for (var rShape in [8, 12]) {
        for (var angleDeg = 0; angleDeg < 360; angleDeg += 15) {
          canvas.clear();
          final shapeAngle = angleDeg * pi / 180;
          final t2angles = [
            shapeAngle,
            shapeAngle + 2 * pi / 3,
            shapeAngle + 4 * pi / 3,
          ];
          final t2px = List.generate(
            3,
            (i) => (cx + rShape * cos(t2angles[i])).round(),
          );
          final t2py = List.generate(
            3,
            (i) => (cy + rShape * sin(t2angles[i])).round(),
          );

          // Fills the triangle using our current algorithm
          canvas.fillTriangleColored(
            t2px[0],
            t2py[0],
            t2px[1],
            t2py[1],
            t2px[2],
            t2py[2],
            Colors.red,
            Colors.green,
            Colors.blue,
          );

          final buffer = Buffer.blank(width, height);
          canvas.render(buffer, Rect(0, 0, width, height));

          // Bounding box of the triangle
          final minX = t2px.reduce(min);
          final maxX = t2px.reduce(max);
          final minY = t2py.reduce(min);
          final maxY = t2py.reduce(max);

          // Check every sub-pixel inside the bounding box
          for (var py = minY; py <= maxY; py++) {
            for (var px = minX; px <= maxX; px++) {
              final shrinkDist = 0.0;
              if (isPointInTriangle(
                px.toDouble(),
                py.toDouble(),
                t2px[0].toDouble(),
                t2py[0].toDouble(),
                t2px[1].toDouble(),
                t2py[1].toDouble(),
                t2px[2].toDouble(),
                t2py[2].toDouble(),
              )) {
                // Check distance to each of the 3 edges
                double pointToLineDist(
                  double px,
                  double py,
                  double x0,
                  double y0,
                  double x1,
                  double y1,
                ) {
                  final num =
                      ((y1 - y0) * px - (x1 - x0) * py + x1 * y0 - y1 * x0)
                          .abs();
                  final double den = sqrt(
                    (y1 - y0) * (y1 - y0) + (x1 - x0) * (x1 - x0),
                  );
                  return den == 0 ? 0.0 : num / den;
                }

                final dEdge0 = pointToLineDist(
                  px.toDouble(),
                  py.toDouble(),
                  t2px[0].toDouble(),
                  t2py[0].toDouble(),
                  t2px[1].toDouble(),
                  t2py[1].toDouble(),
                );
                final dEdge1 = pointToLineDist(
                  px.toDouble(),
                  py.toDouble(),
                  t2px[1].toDouble(),
                  t2py[1].toDouble(),
                  t2px[2].toDouble(),
                  t2py[2].toDouble(),
                );
                final dEdge2 = pointToLineDist(
                  px.toDouble(),
                  py.toDouble(),
                  t2px[2].toDouble(),
                  t2py[2].toDouble(),
                  t2px[0].toDouble(),
                  t2py[0].toDouble(),
                );

                if (dEdge0 >= shrinkDist &&
                    dEdge1 >= shrinkDist &&
                    dEdge2 >= shrinkDist) {
                  // This is strictly an "inside" sub-pixel
                  final cellX = px ~/ 2;
                  final cellY = py ~/ 4;
                  if (cellX >= 0 &&
                      cellX < width &&
                      cellY >= 0 &&
                      cellY < height) {
                    final cell = buffer.getCell(cellX, cellY);
                    if (cell == null) continue;
                    final code = cell.char.codeUnitAt(0);
                    if (code >= 0x2800 && code <= 0x28FF) {
                      final dots = code - 0x2800;
                      final dx = px % 2;
                      final dy = py % 4;
                      final mask = dotMasks[(dy << 1) | dx];
                      if ((dots & mask) == 0) {
                        totalGaps++;
                      }
                    } else if (cell.char != '█') {
                      totalGaps++;
                    }
                  }
                }
              }
            }
          }
        }
      }

      expect(
        totalGaps,
        equals(0),
        reason:
            'Triangle rotation should not have internal rasterization gaps.',
      );
    });
  });

  group('TextField (multiline) tests', () {
    test('Character insertions, newlines, and backspace line merges', () {
      final area = TextField(initialText: 'Line1', multiline: true);
      expect(area.value, equals('Line1'));

      // Insert character
      area.cursorLine = 0;
      area.cursorColumn = 5;
      area.handleKeyEvent(const KeyEvent('!', KeyType.character));
      expect(area.value, equals('Line1!'));

      // Enter key splits line
      area.handleKeyEvent(const KeyEvent('\n', KeyType.enter));
      expect(area.value, equals('Line1!\n'));
      expect(area.cursorLine, equals(1));
      expect(area.cursorColumn, equals(0));

      // Type in new line
      area.handleKeyEvent(const KeyEvent('A', KeyType.character));
      expect(area.value, equals('Line1!\nA'));

      // Backspace at column 0 merges lines
      area.cursorLine = 1;
      area.cursorColumn = 0;
      area.handleKeyEvent(const KeyEvent('backspace', KeyType.backspace));
      expect(area.value, equals('Line1!A'));
      expect(area.cursorLine, equals(0));
      expect(area.cursorColumn, equals(6));
    });

    test('Scroll offset updates as cursor moves', () {
      final area = TextField(initialText: '1\n2\n3\n4\n5', multiline: true);
      area.cursorLine = 4;
      area.adjustScroll(3); // viewport height = 3
      expect(area.scrollOffset, equals(2)); // rows 2, 3, 4 visible
    });

    test('renders cursor when focused, hides cursor when unfocused', () {
      final area = TextField(
        initialText: 'abc',
        multiline: true,
        focused: true,
      );
      area.cursorLine = 0;
      area.cursorColumn = 1;
      final buffer = Buffer.blank(5, 1);

      // When focused
      area.render(buffer, const Rect(0, 0, 5, 1));
      expect(buffer.getCell(1, 0)!.char, equals('b'));
      expect(buffer.getCell(1, 0)!.style, equals(area.cursorStyle));

      // Reset buffer and set focused = false
      buffer.clear();
      area.focused = false;
      area.render(buffer, const Rect(0, 0, 5, 1));
      expect(buffer.getCell(1, 0)!.char, equals('b'));
      expect(buffer.getCell(1, 0)!.style, equals(area.style));
    });

    test(
      'renders placeholder with custom placeholderStyle, hides when text entered, and shows again when cleared',
      () {
        final area = TextField(
          initialText: '',
          multiline: true,
          placeholder: 'HintText',
          placeholderStyle: const Style(foreground: Color(100, 100, 100)),
          cursorStyle: const Style(
            foreground: Colors.black,
            background: Colors.orange,
          ),
          focused: true,
        );
        final buffer = Buffer.blank(10, 1);

        // 1. Empty state: showing placeholder
        area.render(buffer, const Rect(0, 0, 10, 1));
        // Cell 0 should be 'H' (from 'HintText') with cursorStyle
        expect(buffer.getCell(0, 0)!.char, equals('H'));
        expect(buffer.getCell(0, 0)!.style, equals(area.cursorStyle));
        // Cell 1 should be 'i' with placeholderStyle
        expect(buffer.getCell(1, 0)!.char, equals('i'));
        expect(buffer.getCell(1, 0)!.style, equals(area.placeholderStyle));

        // 2. Add text: placeholder should go away
        buffer.clear();
        area.handleKeyEvent(const KeyEvent('x', KeyType.character));
        area.render(buffer, const Rect(0, 0, 10, 1));
        // Cell 0 should be 'x' with style/cursor (cursor moves to 1)
        expect(buffer.getCell(0, 0)!.char, equals('x'));
        expect(buffer.getCell(0, 0)!.style, equals(area.style));
        // Cell 1 should be space (cursor is here)
        expect(buffer.getCell(1, 0)!.char, equals(' '));
        expect(buffer.getCell(1, 0)!.style, equals(area.cursorStyle));
        // No more placeholder text 'i', 'n', 't'
        expect(buffer.getCell(2, 0)!.char, equals(' '));

        // 3. Clear text: placeholder should reappear
        buffer.clear();
        area.handleKeyEvent(const KeyEvent('backspace', KeyType.backspace));
        area.render(buffer, const Rect(0, 0, 10, 1));
        // Cell 0 should be 'H' with cursorStyle
        expect(buffer.getCell(0, 0)!.char, equals('H'));
        expect(buffer.getCell(0, 0)!.style, equals(area.cursorStyle));
        // Cell 1 should be 'i' with placeholderStyle
        expect(buffer.getCell(1, 0)!.char, equals('i'));
        expect(buffer.getCell(1, 0)!.style, equals(area.placeholderStyle));
      },
    );
  });

  group('Help widget tests', () {
    test('Formats bindings with separator and fits to width', () {
      final buffer = Buffer.blank(20, 2);
      const help = Help(
        bindings: {'q': 'quit', 'esc': 'back'},
        separator: ' | ',
      );

      help.render(buffer, const Rect(0, 0, 20, 2));

      final output = List.generate(
        20,
        (x) => buffer.getCell(x, 0)!.char,
      ).join('');
      // Expected to render 'q quit | esc back'
      expect(output, contains('q quit'));
      expect(output, contains('|'));
      expect(output, contains('esc back'));
    });
  });

  group('Spinner tests', () {
    test('Spinner frames advance on tick', () {
      final spinner = Spinner.line();
      expect(spinner.currentFrame, equals('|'));
      spinner.tick();
      expect(spinner.currentFrame, equals('/'));
      spinner.tick();
      expect(spinner.currentFrame, equals('-'));
      spinner.tick();
      expect(spinner.currentFrame, equals('\\'));
      spinner.tick();
      expect(spinner.currentFrame, equals('|'));
    });
  });

  group('Table tests', () {
    test('Renders headers, separator, and rows correctly', () {
      final buffer = Buffer.blank(15, 4);
      final table = Table(
        headers: ['ID', 'Name'],
        rows: [
          ['1', 'Alice'],
          ['2', 'Bob'],
        ],
        columnWidths: [3, 6],
        selectedRowIndex: 1,
      );

      table.render(buffer, const Rect(0, 0, 15, 4));

      // Row 0: Headers -> 'ID  Name'
      final row0 = List.generate(
        15,
        (x) => buffer.getCell(x, 0)!.char,
      ).join('');
      expect(row0, startsWith('ID  Name'));

      // Row 1: Divider line -> '───────────────'
      final row1 = List.generate(
        15,
        (x) => buffer.getCell(x, 1)!.char,
      ).join('');
      expect(row1, contains('─'));

      // Row 2: First row data -> '1   Alice'
      final row2 = List.generate(
        15,
        (x) => buffer.getCell(x, 2)!.char,
      ).join('');
      expect(row2, startsWith('1   Alice'));

      // Row 3: Second row data -> '2   Bob' (selected)
      final row3 = List.generate(
        15,
        (x) => buffer.getCell(x, 3)!.char,
      ).join('');
      expect(row3, startsWith('2   Bob'));
    });
  });

  group('Paginator tests', () {
    test('Renders current and inactive dots', () {
      final buffer = Buffer.blank(10, 1);
      const paginator = Paginator(
        totalPages: 3,
        currentPage: 1,
        activeDot: 'X',
        inactiveDot: 'o',
        separator: '-',
      );

      paginator.render(buffer, const Rect(0, 0, 10, 1));
      final output = List.generate(
        10,
        (x) => buffer.getCell(x, 0)!.char,
      ).join('');
      // Expected: o-X-o
      expect(output, startsWith('o-X-o'));
    });
  });

  group('Form and FormField tests', () {
    test('Form validation and error state updates', () {
      final nameField = TextFormField(
        label: 'Name',
        initialValue: '',
        validator: (val) => (val == null || val.isEmpty) ? 'Required' : null,
      );
      final form = Form(fields: [nameField]);

      // Initially no error text
      expect(nameField.hasError, isFalse);

      // Validation fails
      final isValid = form.validate();
      expect(isValid, isFalse);
      expect(nameField.hasError, isTrue);
      expect(nameField.errorText, equals('Required'));

      // Correct value passes validation
      nameField.value = 'Alice';
      final isValidAfter = form.validate();
      expect(isValidAfter, isTrue);
      expect(nameField.hasError, isFalse);
      expect(nameField.errorText, isNull);
    });

    test('Form focus traversal with Tab/Shift-Tab', () {
      final f1 = TextFormField(label: 'F1');
      final f2 = TextFormField(label: 'F2');
      final form = Form(fields: [f1, f2]);

      expect(f1.focused, isTrue);
      expect(f2.focused, isFalse);

      // Press Tab moves to F2
      form.handleKeyEvent(const KeyEvent('tab', KeyType.character));
      expect(f1.focused, isFalse);
      expect(f2.focused, isTrue);

      // Press Shift-Tab/backtab moves back to F1
      form.handleKeyEvent(const KeyEvent('backtab', KeyType.character));
      expect(f1.focused, isTrue);
      expect(f2.focused, isFalse);
    });

    test('ConfirmFormField toggles correctly on Left/Right/Space', () {
      final confirm = ConfirmFormField(label: 'Agree', initialValue: false);

      // Toggles to true on space key
      confirm.handleKeyEvent(const KeyEvent(' ', KeyType.character));
      expect(confirm.value, isTrue);

      // Toggles to false on right key
      confirm.handleKeyEvent(const KeyEvent('right', KeyType.right));
      expect(confirm.value, isFalse);

      // Toggles to true on left key
      confirm.handleKeyEvent(const KeyEvent('left', KeyType.left));
      expect(confirm.value, isTrue);
    });

    test('SelectFormField changes option on Up/Down', () {
      final select = SelectFormField<int>(
        label: 'Select number',
        options: const [SelectOption('One', 1), SelectOption('Two', 2)],
        initialValue: 1,
      );

      expect(select.value, equals(1));

      // Move Down
      select.handleKeyEvent(const KeyEvent('down', KeyType.down));
      expect(select.value, equals(2));

      // Move Up
      select.handleKeyEvent(const KeyEvent('up', KeyType.up));
      expect(select.value, equals(1));
    });

    test('MultiSelectFormField toggles options correctly', () {
      final multiselect = MultiSelectFormField<String>(
        label: 'Select toppings',
        options: const [
          MultiSelectOption('Lettuce', 'Lettuce'),
          MultiSelectOption('Tomatoes', 'Tomatoes'),
          MultiSelectOption('Cheese', 'Cheese'),
        ],
        initialValue: const ['Lettuce'],
        validator: (val) {
          if (val == null || val.isEmpty) {
            return 'At least one required';
          }
          if (val.length > 2) {
            return 'Too many toppings';
          }
          return null;
        },
      );

      // Verify initial value
      expect(multiselect.value, equals(['Lettuce']));

      // Toggle 'Lettuce' (index 0) off by pressing space
      multiselect.handleKeyEvent(const KeyEvent(' ', KeyType.character));
      expect(multiselect.value, isEmpty);
      expect(multiselect.validate(), isFalse);
      expect(multiselect.errorText, equals('At least one required'));

      // Move to 'Tomatoes' (index 1) and toggle it on
      multiselect.handleKeyEvent(const KeyEvent('down', KeyType.down));
      multiselect.handleKeyEvent(const KeyEvent(' ', KeyType.character));
      expect(multiselect.value, equals(['Tomatoes']));
      expect(multiselect.validate(), isTrue);

      // Move to 'Cheese' (index 2) and toggle it on using Enter key
      multiselect.handleKeyEvent(const KeyEvent('down', KeyType.down));
      multiselect.handleKeyEvent(const KeyEvent('\n', KeyType.enter));
      expect(multiselect.value, equals(['Tomatoes', 'Cheese']));
      expect(multiselect.validate(), isTrue);

      // Move back to 'Lettuce' (index 0) and toggle it on
      multiselect.handleKeyEvent(const KeyEvent('up', KeyType.up));
      multiselect.handleKeyEvent(const KeyEvent('up', KeyType.up));
      multiselect.handleKeyEvent(const KeyEvent(' ', KeyType.character));
      expect(multiselect.value, equals(['Lettuce', 'Tomatoes', 'Cheese']));
      expect(multiselect.validate(), isFalse);
      expect(multiselect.errorText, equals('Too many toppings'));
    });

    test('Form renders with breaks in LeftBorder between fields', () {
      final f1 = TextFormField(label: 'Field 1');
      final f2 = TextFormField(label: 'Field 2');
      final form = Form(fields: [f1, f2]);

      // 1. Focused case: f1 is focused by default, f2 is unfocused
      final buffer = Buffer(20, 10);
      form.render(buffer, const Rect(0, 0, 20, 10));

      // f1 height = 3 (label, input, spacer). Border is drawn for 2 lines since it is focused.
      expect(buffer.getCell(0, 0)!.char, equals('│'));
      expect(buffer.getCell(0, 1)!.char, equals('│'));
      expect(buffer.getCell(0, 2)!.char, equals(' ')); // Break/spacer

      // f2 height = 3. Starts at y = 3. Since f2 is unfocused, no border is drawn (spaces).
      expect(buffer.getCell(0, 3)!.char, equals(' '));
      expect(buffer.getCell(0, 4)!.char, equals(' '));
      expect(buffer.getCell(0, 5)!.char, equals(' ')); // Break/spacer

      // 2. Unfocused case: unfocus all fields
      f1.focused = false;
      f2.focused = false;
      final buffer2 = Buffer(20, 10);
      form.render(buffer2, const Rect(0, 0, 20, 10));

      // The border characters should be spaces ' ' when unfocused
      expect(buffer2.getCell(0, 0)!.char, equals(' '));
      expect(buffer2.getCell(0, 1)!.char, equals(' '));
      expect(buffer2.getCell(0, 3)!.char, equals(' '));
    });
  });

  group('Easing and Eased LinearProgressIndicator Tests', () {
    test('Easing mathematical boundaries', () {
      expect(Easing.linear(0.0), closeTo(0.0, 1e-9));
      expect(Easing.linear(1.0), closeTo(1.0, 1e-9));

      expect(Easing.easeOutBounce(0.0), closeTo(0.0, 1e-9));
      expect(Easing.easeOutBounce(1.0), closeTo(1.0, 1e-9));

      expect(Easing.easeInOutCubic(0.0), closeTo(0.0, 1e-9));
      expect(Easing.easeInOutCubic(1.0), closeTo(1.0, 1e-9));

      expect(Easing.easeInQuad(0.5), closeTo(0.25, 1e-9));
    });

    test('LinearProgressIndicator applies easing function during rendering', () {
      // 1. ProgressBar with linear easing at 0.5 (should fill 6 out of 12 cells)
      final barLinear = LinearProgressIndicator(
        0.5,
        showPercentage: false,
        easing: Easing.linear,
      );
      final bufferLinear = Buffer(12, 1);
      barLinear.render(bufferLinear, const Rect(0, 0, 12, 1));

      var filledLinear = 0;
      for (var x = 0; x < 12; x++) {
        if (bufferLinear.getCell(x, 0)!.char == '█') {
          filledLinear++;
        }
      }
      expect(filledLinear, equals(6));

      // 2. ProgressBar with easeInQuad at 0.5 (should fill 0.25 * 12 = 3 out of 12 cells)
      final barEased = LinearProgressIndicator(
        0.5,
        showPercentage: false,
        easing: Easing.easeInQuad,
      );
      final bufferEased = Buffer(12, 1);
      barEased.render(bufferEased, const Rect(0, 0, 12, 1));

      var filledEased = 0;
      for (var x = 0; x < 12; x++) {
        if (bufferEased.getCell(x, 0)!.char == '█') {
          filledEased++;
        }
      }
      expect(filledEased, equals(3));
    });
  });

  group('TreeWidget Tests', () {
    test('Flattening and guide line rendering math', () {
      final leafA = TreeNode<String>(label: 'leafA', value: 'a');
      final leafB = TreeNode<String>(label: 'leafB', value: 'b');
      final branch = TreeNode<String>(
        label: 'branch',
        value: 'br',
        children: [leafA, leafB],
        isExpanded: true,
      );
      final root = TreeNode<String>(
        label: 'root',
        value: 'rt',
        children: [branch],
        isExpanded: true,
      );

      final tree = TreeWidget<String>(root: root, showRoot: true);

      expect(tree.flatNodes.length, equals(4));

      final buffer = Buffer(25, 4);
      tree.render(buffer, const Rect(0, 0, 25, 4));

      final row0 = List.generate(
        10,
        (x) => buffer.getCell(x, 0)!.char,
      ).join('');
      expect(row0, startsWith('▼ root'));

      final row1 = List.generate(
        15,
        (x) => buffer.getCell(x, 1)!.char,
      ).join('');
      expect(row1, startsWith('└── ▼ branch'));

      final row2 = List.generate(
        20,
        (x) => buffer.getCell(x, 2)!.char,
      ).join('');
      expect(row2, startsWith('   ├──   leafA'));

      final row3 = List.generate(
        20,
        (x) => buffer.getCell(x, 3)!.char,
      ).join('');
      expect(row3, startsWith('   └──   leafB'));
    });

    test('Keyboard navigation (collapse/expand & selection movement)', () {
      final leafA = TreeNode<String>(label: 'A', value: 'a');
      final branch = TreeNode<String>(
        label: 'branch',
        value: 'br',
        children: [leafA],
        isExpanded: false,
      );
      final root = TreeNode<String>(
        label: 'root',
        value: 'rt',
        children: [branch],
        isExpanded: true,
      );

      final tree = TreeWidget<String>(root: root, showRoot: true);

      expect(tree.flatNodes.length, equals(2));
      expect(tree.selectedIndex, equals(0));

      tree.handleKeyEvent(const KeyEvent('down', KeyType.down));
      expect(tree.selectedIndex, equals(1));

      tree.handleKeyEvent(const KeyEvent('right', KeyType.right));
      expect(tree.flatNodes.length, equals(3));
      expect(branch.isExpanded, isTrue);
      expect(tree.selectedIndex, equals(1));

      tree.handleKeyEvent(const KeyEvent('down', KeyType.down));
      expect(tree.selectedIndex, equals(2));

      tree.handleKeyEvent(const KeyEvent('left', KeyType.left));
      expect(tree.selectedIndex, equals(1));

      tree.handleKeyEvent(const KeyEvent('left', KeyType.left));
      expect(branch.isExpanded, isFalse);
      expect(tree.flatNodes.length, equals(2));
    });

    test('Focused and unfocused selection styling', () {
      final root = TreeNode<String>(label: 'root', value: 'rt');
      final tree = TreeWidget<String>(
        root: root,
        selectedStyle: const Style(
          foreground: CharmColors.pepper,
          background: CharmColors.charple,
        ),
      );

      // By default, it's focused
      expect(tree.focused, isTrue);

      final bufferFocused = Buffer(10, 1);
      tree.render(bufferFocused, const Rect(0, 0, 10, 1));
      // First character should have CharmColors.charple as background
      expect(
        bufferFocused.getCell(0, 0)!.style.background,
        equals(CharmColors.charple),
      );

      // Set focused to false
      tree.focused = false;
      final bufferUnfocused = Buffer(10, 1);
      tree.render(bufferUnfocused, const Rect(0, 0, 10, 1));
      // First character should have CharmColors.char as background when unfocused
      expect(
        bufferUnfocused.getCell(0, 0)!.style.background,
        equals(CharmColors.char),
      );
    });
  });
}
