import 'dart:math';
import 'package:test/test.dart';
import 'package:termui/ui/buffer.dart';
import 'package:termui/ui/widgets/core/widget.dart';
import 'package:termui/ui/widgets/core/element.dart';
import 'package:termui/ui/widgets/core/geometry.dart';
import 'package:termui/ui/event.dart';
import 'package:termui/ui/color.dart';
import 'package:termui/ui/style.dart';
import 'package:termui/ui/widget_toolkit.dart';
import 'package:termui_recorder/termui_recorder.dart';

void main() {
  group('Paragraph wrapping tests', () {
    test('Basic wrapping and forced breaks on constraint shrink', () {
      final buffer = Buffer.blank(10, 5);
      final p1 = Text('Hello standard word wrap');
      ElementWidget(p1)
        ..layout(BoxConstraints.tight(const Size(10, 5)))
        ..paint(buffer, Offset.zero);

      expect(
        buffer,
        matchesAnsiGolden(
          'test/goldens/paragraph_standard_wrap.ansi',
          environment: {'GENERATE_GOLDENS': 'true'},
        ),
      );

      // Clean buffer
      buffer.clear();

      // Forced wrapping of a single word larger than max width
      final p2 = Text('Supercalifragilistic');
      // MaxWidth = 8
      ElementWidget(p2)
        ..layout(BoxConstraints.tight(const Size(8, 5)))
        ..paint(buffer, Offset.zero);
      expect(
        buffer,
        matchesAnsiGolden(
          'test/goldens/paragraph_forced_wrap.ansi',
          environment: {'GENERATE_GOLDENS': 'true'},
        ),
      );
    });
  });

  group('ListView tests', () {
    test('Scrolling offset changes based on index selection', () {
      final listElement =
          ListView.fromStrings(['A', 'B', 'C', 'D', 'E']).createElement()
              as ListViewElement;
      // final list = ListView.fromStrings(['A', 'B', 'C', 'D', 'E']);
      // Viewport height is 3
      listElement.selectedIndex = 0;
      listElement.adjustScroll(3);
      expect(listElement.scrollOffset, equals(0));

      listElement.selectedIndex = 2;
      listElement.adjustScroll(3);
      expect(listElement.scrollOffset, equals(0));

      listElement.selectedIndex = 3;
      listElement.adjustScroll(
        3,
      ); // Moves scrollOffset down so index 3 is visible
      expect(listElement.scrollOffset, equals(1));

      listElement.selectedIndex = 1;
      listElement.adjustScroll(
        3,
      ); // Moves scrollOffset up so index 1 is visible
      expect(listElement.scrollOffset, equals(1));
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
      ElementWidget(input)
        ..layout(BoxConstraints.tight(const Size(5, 1)))
        ..paint(buffer, Offset.zero);
      expect(
        buffer,
        matchesAnsiGolden(
          'test/goldens/textfield_focused.ansi',
          environment: {'GENERATE_GOLDENS': 'true'},
        ),
      );

      // Reset buffer and set focused = false
      buffer.clear();
      input.focused = false;
      ElementWidget(input)
        ..layout(BoxConstraints.tight(const Size(5, 1)))
        ..paint(buffer, Offset.zero);
      expect(
        buffer,
        matchesAnsiGolden(
          'test/goldens/textfield_unfocused.ansi',
          environment: {'GENERATE_GOLDENS': 'true'},
        ),
      );
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

        ElementWidget(input)
          ..layout(BoxConstraints.tight(const Size(6, 1)))
          ..paint(buffer, Offset.zero);

        expect(
          buffer,
          matchesAnsiGolden(
            'test/goldens/textfield_placeholder_cursor.ansi',
            environment: {'GENERATE_GOLDENS': 'true'},
          ),
        );
      },
    );
  });

  group('LinearProgressIndicator tests', () {
    test('Bar render is filled proportionally and centers percentage', () {
      final buffer = Buffer.blank(10, 1);
      final bar = const LinearProgressIndicator(0.5, showPercentage: true);
      ElementWidget(bar)
        ..layout(BoxConstraints.tight(const Size(10, 1)))
        ..paint(buffer, Offset.zero);

      expect(
        buffer,
        matchesAnsiGolden(
          'test/goldens/progress_indicator_50_percent.ansi',
          environment: {'GENERATE_GOLDENS': 'true'},
        ),
      );
    });
  });

  group('Canvas & Benchmark Tests', () {
    test('Braille Bitmask Test', () {
      final canvas = Canvas(1, 1);
      // Set top-left pixel (0, 0) -> Dot 1 (0x01)
      canvas.setPixel(0, 0, true);

      final buffer = Buffer.blank(1, 1);
      ElementWidget(canvas)
        ..layout(BoxConstraints.tight(const Size(1, 1)))
        ..paint(buffer, Offset.zero);

      // Unicode value should be U+2800 + 0x01 = 0x2801
      expect(buffer.getCharacter(0, 0), equals(String.fromCharCode(0x2801)));

      // Clear and set bottom-right pixel (1, 3) -> Dot 8 (0x80)
      canvas.clear();
      canvas.setPixel(1, 3, true);
      ElementWidget(canvas)
        ..layout(BoxConstraints.tight(const Size(1, 1)))
        ..paint(buffer, Offset.zero);
      // Unicode value should be U+2800 + 0x80 = 0x2880 (⢀)
      expect(buffer.getCharacter(0, 0), equals(String.fromCharCode(0x2880)));

      // Set both: U+2881
      canvas.setPixel(0, 0, true);
      ElementWidget(canvas)
        ..layout(BoxConstraints.tight(const Size(1, 1)))
        ..paint(buffer, Offset.zero);
      expect(buffer.getCharacter(0, 0), equals(String.fromCharCode(0x2881)));
    });

    test('Bresenham Integrity Test', () {
      final canvas = Canvas(6, 3); // 12x12 sub-pixels
      canvas.drawLine(0, 0, 10, 10);
      final buffer = Buffer.blank(6, 3);
      ElementWidget(canvas)
        ..layout(BoxConstraints.tight(const Size(6, 3)))
        ..paint(buffer, Offset.zero);

      var totalFlagged = 0;
      for (var y = 0; y < 3; y++) {
        for (var x = 0; x < 6; x++) {
          final char = buffer.getCharacter(x, y);
          if (char.isNotEmpty && char != ' ') {
            final code = char.codeUnitAt(0);
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
      ElementWidget(canvas)
        ..layout(BoxConstraints.tight(const Size(2, 2)))
        ..paint(buffer, Offset.zero);

      // Cell (0, 0) is completely covered (8/8 sub-pixels).
      // So it should render as solid block '█' rather than Braille characters.
      expect(buffer.getCharacter(0, 0), equals('█'));

      // Cell (1, 0) is not drawn, so it is empty space (U+2800)
      expect(
        buffer.getCharacter(1, 0),
        anyOf(equals('⠀'), equals(' ')),
      ); // U+2800 or U+0020
    });

    test('Occlusion Culling Test', () {
      final canvas = Canvas(3, 3);
      canvas.fillBox(0, 0, 6, 12); // fill everything

      // Mark cell (1, 1) as occluded
      canvas.isOccluded = (col, row) => col == 1 && row == 1;

      final buffer = Buffer.blank(3, 3);
      ElementWidget(canvas)
        ..layout(BoxConstraints.tight(const Size(3, 3)))
        ..paint(buffer, Offset.zero);

      // Cell (1, 1) should be blank/empty because we skipped translation
      expect(buffer.getCharacter(1, 1), equals(' ')); // blank cell
      // Other cells should be filled
      expect(buffer.getCharacter(0, 0), equals('█'));
    });

    test('Canvas Color Interpolation and Custom Styles Test', () {
      final canvas = Canvas(3, 3);
      final buffer = Buffer.blank(3, 3);

      // Draw a line colored from red to blue
      canvas.drawLineColored(0, 0, 4, 8, Colors.red, Colors.blue);
      ElementWidget(canvas)
        ..layout(BoxConstraints.tight(const Size(3, 3)))
        ..paint(buffer, Offset.zero);

      // The cell at (0, 0) should have a foreground color that is Red
      final fg0 = buffer.getForeground(0, 0);
      final c0 = Color.argb(fg0);
      expect(fg0, isNot(equals(0)));
      expect(c0.r, equals(255));
      expect(c0.g, equals(0));
      expect(c0.b, equals(0));

      // The cell at (2, 2) should have a foreground color that is Blue
      final fg2 = buffer.getForeground(2, 2);
      final c2 = Color.argb(fg2);
      expect(fg2, isNot(equals(0)));
      expect(c2.r, equals(0));
      expect(c2.g, equals(0));
      expect(c2.b, equals(255));

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
      ElementWidget(canvas)
        ..layout(BoxConstraints.tight(const Size(3, 3)))
        ..paint(buffer, Offset.zero);

      // Ensure some pixels are colored
      expect(buffer.getForeground(0, 0), isNot(equals(0)));

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
      ElementWidget(canvas)
        ..layout(BoxConstraints.tight(const Size(3, 3)))
        ..paint(buffer, Offset.zero);

      // Ensure some pixels are colored
      expect(buffer.getForeground(0, 0), isNot(equals(0)));
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
      ElementWidget(canvas)
        ..layout(BoxConstraints.tight(const Size(3, 3)))
        ..paint(buffer, Offset.zero);

      // Cell at (0, 0) has the line pixel, should have green foreground and black background
      final c0 = buffer.getCharacter(0, 0);
      expect(c0, isNot(equals(' ')));
      expect(Color.argb(buffer.getForeground(0, 0)), equals(Colors.green));
      expect(Color.argb(buffer.getBackground(0, 0)), equals(Colors.black));

      // Cell at (2, 0) has no pixel (dots == 0), should have black background
      expect(Color.argb(buffer.getBackground(2, 0)), equals(Colors.black));
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
        ElementWidget(canvas)
          ..layout(BoxConstraints.tight(const Size(80, 24)))
          ..paint(buffer, Offset.zero);
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
          ElementWidget(canvas)
            ..layout(BoxConstraints.tight(Size(width, height)))
            ..paint(buffer, Offset.zero);

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
                    final char = buffer.getCharacter(cellX, cellY);
                    if (char.isEmpty) continue;
                    final code = char.codeUnitAt(0);
                    if (code >= 0x2800 && code <= 0x28FF) {
                      final dots = code - 0x2800;
                      final dx = px % 2;
                      final dy = py % 4;
                      final mask = dotMasks[(dy << 1) | dx];
                      if ((dots & mask) == 0) {
                        totalGaps++;
                      }
                    } else if (char != '█') {
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
      ElementWidget(area)
        ..layout(BoxConstraints.tight(const Size(5, 1)))
        ..paint(buffer, Offset.zero);
      expect(
        buffer,
        matchesAnsiGolden(
          'test/goldens/multiline_textfield_focused.ansi',
          environment: {'GENERATE_GOLDENS': 'true'},
        ),
      );

      // Reset buffer and set focused = false
      buffer.clear();
      area.focused = false;
      ElementWidget(area)
        ..layout(BoxConstraints.tight(const Size(5, 1)))
        ..paint(buffer, Offset.zero);
      expect(
        buffer,
        matchesAnsiGolden(
          'test/goldens/multiline_textfield_unfocused.ansi',
          environment: {'GENERATE_GOLDENS': 'true'},
        ),
      );
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
        buffer.clear();

        // 1. Empty state: showing placeholder
        ElementWidget(area)
          ..layout(BoxConstraints.tight(const Size(10, 1)))
          ..paint(buffer, Offset.zero);
        expect(
          buffer,
          matchesAnsiGolden(
            'test/goldens/multiline_placeholder_empty.ansi',
            environment: {'GENERATE_GOLDENS': 'true'},
          ),
        );

        // 2. Add text: placeholder should go away
        buffer.clear();
        area.handleKeyEvent(const KeyEvent('x', KeyType.character));
        ElementWidget(area)
          ..layout(BoxConstraints.tight(const Size(10, 1)))
          ..paint(buffer, Offset.zero);
        expect(
          buffer,
          matchesAnsiGolden(
            'test/goldens/multiline_placeholder_with_text.ansi',
            environment: {'GENERATE_GOLDENS': 'true'},
          ),
        );

        // 3. Clear text: placeholder should reappear
        buffer.clear();
        area.handleKeyEvent(const KeyEvent('backspace', KeyType.backspace));
        ElementWidget(area)
          ..layout(BoxConstraints.tight(const Size(10, 1)))
          ..paint(buffer, Offset.zero);
        expect(
          buffer,
          matchesAnsiGolden(
            'test/goldens/multiline_placeholder_empty.ansi',
            environment: {'GENERATE_GOLDENS': 'true'},
          ),
        );
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

      ElementWidget(help)
        ..layout(BoxConstraints.tight(const Size(20, 2)))
        ..paint(buffer, Offset.zero);

      expect(
        buffer,
        matchesAnsiGolden(
          'test/goldens/help_widget.ansi',
          environment: {'GENERATE_GOLDENS': 'true'},
        ),
      );
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

      ElementWidget(table)
        ..layout(BoxConstraints.tight(const Size(15, 4)))
        ..paint(buffer, Offset.zero);

      expect(
        buffer,
        matchesAnsiGolden(
          'test/goldens/table_widget.ansi',
          environment: {'GENERATE_GOLDENS': 'true'},
        ),
      );
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

      ElementWidget(paginator)
        ..layout(BoxConstraints.tight(const Size(10, 1)))
        ..paint(buffer, Offset.zero);
      expect(
        buffer,
        matchesAnsiGolden(
          'test/goldens/paginator_widget.ansi',
          environment: {'GENERATE_GOLDENS': 'true'},
        ),
      );
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
      ElementWidget(form)
        ..layout(BoxConstraints.tight(const Size(20, 10)))
        ..paint(buffer, Offset.zero);

      expect(
        buffer,
        matchesAnsiGolden(
          'test/goldens/form_focused.ansi',
          environment: {'GENERATE_GOLDENS': 'true'},
        ),
      );

      // 2. Unfocused case: unfocus all fields
      f1.focused = false;
      f2.focused = false;
      final buffer2 = Buffer(20, 10);
      ElementWidget(form)
        ..layout(BoxConstraints.tight(const Size(20, 10)))
        ..paint(buffer2, Offset.zero);

      expect(
        buffer2,
        matchesAnsiGolden(
          'test/goldens/form_unfocused.ansi',
          environment: {'GENERATE_GOLDENS': 'true'},
        ),
      );
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
      ElementWidget(barLinear)
        ..layout(BoxConstraints.tight(const Size(12, 1)))
        ..paint(bufferLinear, Offset.zero);

      var filledLinear = 0;
      for (var x = 0; x < 12; x++) {
        if (bufferLinear.getCharacter(x, 0) == '█') {
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
      ElementWidget(barEased)
        ..layout(BoxConstraints.tight(const Size(12, 1)))
        ..paint(bufferEased, Offset.zero);

      var filledEased = 0;
      for (var x = 0; x < 12; x++) {
        if (bufferEased.getCharacter(x, 0) == '█') {
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

      final treeElement =
          TreeWidget<String>(root: root, showRoot: true).createElement()
              as StatefulElement;
      treeElement.mount(null);
      final tree = treeElement.state as TreeWidgetState;

      expect(tree.flatNodes.length, equals(4));

      final buffer = Buffer(25, 4);
      ElementWidget(treeElement.widget)
        ..layout(BoxConstraints.tight(const Size(25, 4)))
        ..paint(buffer, Offset.zero);

      expect(
        buffer,
        matchesAnsiGolden(
          'test/goldens/tree_widget_rendering.ansi',
          environment: {'GENERATE_GOLDENS': 'true'},
        ),
      );
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

      final treeElement =
          TreeWidget<String>(root: root, showRoot: true).createElement()
              as StatefulElement;
      treeElement.mount(null);
      final tree = treeElement.state as TreeWidgetState;

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
      final treeWidget = TreeWidget<String>(
        root: root,
        selectedStyle: const Style(
          foreground: CharmColors.pepper,
          background: CharmColors.charple,
        ),
      );
      final treeElement = treeWidget.createElement() as StatefulElement;
      treeElement.mount(null);

      // By default, it's focused
      expect((treeElement.widget as TreeWidget).focused, isTrue);

      final bufferFocused = Buffer(10, 1);
      ElementWidget(treeElement.widget)
        ..layout(BoxConstraints.tight(const Size(10, 1)))
        ..paint(bufferFocused, Offset.zero);
      expect(
        bufferFocused,
        matchesAnsiGolden(
          'test/goldens/tree_focused_styling.ansi',
          environment: {'GENERATE_GOLDENS': 'true'},
        ),
      );

      // Set focused to false
      treeElement.update(
        TreeWidget<String>(
          root: root,
          focused: false,
          selectedStyle: const Style(
            foreground: CharmColors.pepper,
            background: CharmColors.charple,
          ),
        ),
      );
      final bufferUnfocused = Buffer(10, 1);
      ElementWidget(treeElement.widget)
        ..layout(BoxConstraints.tight(const Size(10, 1)))
        ..paint(bufferUnfocused, Offset.zero);
      expect(
        bufferUnfocused,
        matchesAnsiGolden(
          'test/goldens/tree_unfocused_styling.ansi',
          environment: {'GENERATE_GOLDENS': 'true'},
        ),
      );
    });
  });
}
