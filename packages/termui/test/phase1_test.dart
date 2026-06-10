import 'package:test/test.dart';
import 'package:termui/ui/color.dart';
import 'package:termui/ui/style.dart';
import 'package:termui/ui/buffer.dart';
import 'package:termui/ui/renderer.dart';

void main() {
  group('Style Tests', () {
    test('Style merging works correctly', () {
      const s1 = Style(foreground: Color(255, 0, 0), modifiers: Modifier.bold);
      const s2 = Style(
        background: Color(0, 0, 255),
        modifiers: Modifier.italic,
      );

      final merged = s1.merge(s2);
      expect(merged.foreground, const Color(255, 0, 0));
      expect(merged.background, const Color(0, 0, 255));
      expect(Modifier.has(merged.modifiers, Modifier.bold), isTrue);
      expect(Modifier.has(merged.modifiers, Modifier.italic), isTrue);
    });

    test('Style equality works', () {
      const s1 = Style(foreground: Color(1, 2, 3), modifiers: Modifier.bold);
      const s2 = Style(foreground: Color(1, 2, 3), modifiers: Modifier.bold);
      const s3 = Style(foreground: Color(1, 2, 4), modifiers: Modifier.bold);
      expect(s1, equals(s2));
      expect(s1, isNot(equals(s3)));
    });
  });

  group('Buffer Tests', () {
    test('Buffer creation and initialization', () {
      final buffer = Buffer(10, 5);
      expect(buffer.width, 10);
      expect(buffer.height, 5);
      expect(buffer.getCell(0, 0)!.isTransparent, isTrue);
      expect(buffer.getCell(0, 0)!.char, ' ');
    });

    test('Buffer solid blank creation', () {
      final buffer = Buffer.blank(5, 5);
      expect(buffer.getCell(0, 0)!.isTransparent, isFalse);
    });

    test('Buffer writeString with clipping and wrapping', () {
      final buffer = Buffer(5, 3);
      buffer.writeString(0, 0, 'ABC\nDE', Style.empty);

      expect(buffer.getCell(0, 0)!.char, 'A');
      expect(buffer.getCell(1, 0)!.char, 'B');
      expect(buffer.getCell(2, 0)!.char, 'C');
      expect(buffer.getCell(3, 0)!.char, ' '); // Transparent space

      expect(buffer.getCell(0, 1)!.char, 'D');
      expect(buffer.getCell(1, 1)!.char, 'E');

      // Writing out of bounds clips safely
      buffer.writeString(3, 2, 'HELLO', Style.empty);
      expect(buffer.getCell(3, 2)!.char, 'H');
      expect(buffer.getCell(4, 2)!.char, 'E');
    });

    test('Buffer resizing', () {
      final buffer = Buffer(3, 3);
      buffer.writeString(0, 0, '123\n456\n789', Style.empty);

      buffer.resize(2, 2);
      expect(buffer.width, 2);
      expect(buffer.height, 2);
      expect(buffer.getCell(0, 0)!.char, '1');
      expect(buffer.getCell(1, 0)!.char, '2');
      expect(buffer.getCell(0, 1)!.char, '4');
      expect(buffer.getCell(1, 1)!.char, '5');
      expect(buffer.getCell(0, 2), isNull); // out of bounds
    });
  });

  group('Compositor Tests', () {
    test('Z-Index and Transparency compositing', () {
      final target = Buffer.blank(4, 4);
      final layer1 = Buffer(3, 3);
      final layer2 = Buffer(3, 3);

      // Layer 1 has '1's at 0,0 and 1,0 and is otherwise transparent
      layer1.setCell(0, 0, Cell('1', Style.empty));
      layer1.setCell(1, 0, Cell('1', Style.empty));

      // Layer 2 has '2's at 1,0 and 2,0 and is otherwise transparent
      layer2.setCell(1, 0, Cell('2', Style.empty));
      layer2.setCell(2, 0, Cell('2', Style.empty));

      final comp = Compositor();

      // Case 1: layer2 has higher z-index, should overwrite layer1
      comp.composite(
        target: target,
        layers: [
          LayeredBuffer(buffer: layer1, x: 0, y: 0, zIndex: 1),
          LayeredBuffer(buffer: layer2, x: 0, y: 0, zIndex: 2),
        ],
      );

      expect(target.getCell(0, 0)!.char, '1');
      expect(target.getCell(1, 0)!.char, '2');
      expect(target.getCell(2, 0)!.char, '2');
      expect(target.getCell(3, 0)!.char, ' ');

      // Reset target
      target.fill(Cell.blank());

      // Case 2: layer1 has higher z-index, should overwrite layer2
      comp.composite(
        target: target,
        layers: [
          LayeredBuffer(buffer: layer1, x: 0, y: 0, zIndex: 2),
          LayeredBuffer(buffer: layer2, x: 0, y: 0, zIndex: 1),
        ],
      );

      expect(target.getCell(0, 0)!.char, '1');
      expect(target.getCell(1, 0)!.char, '1');
      expect(target.getCell(2, 0)!.char, '2');
      expect(target.getCell(3, 0)!.char, ' ');
    });
  });

  group('Renderer & Payload minimization Tests', () {
    test('Only renders changes', () {
      final renderer = Renderer(5, 1);
      final back = Buffer.blank(5, 1);

      back.writeString(0, 0, 'ABCDE', Style.empty);

      final sb1 = StringBuffer();
      renderer.render(back, sb1);
      expect(sb1.toString(), contains('ABCDE'));

      // Draw same buffer again: output should be completely empty (no changes)
      final sb2 = StringBuffer();
      renderer.render(back, sb2);
      expect(sb2.toString(), isEmpty);

      // Change only middle character: output should only reposition and draw 'X'
      back.writeString(2, 0, 'X', Style.empty);
      final sb3 = StringBuffer();
      renderer.render(back, sb3);
      expect(sb3.toString(), equals('\x1b[1;3HX'));
    });

    test('Optimizes SGR grouping (emits colors once for run)', () {
      final renderer = Renderer(5, 1);
      final back = Buffer.blank(5, 1);
      const styled = Style(foreground: Color(255, 0, 0));

      back.writeString(0, 0, 'XYZ', styled);

      final sb = StringBuffer();
      renderer.render(back, sb);
      final out = sb.toString();

      // Must contain red color code once, not three times
      expect(out, contains('\x1b[38;2;255;0;0m'));
      expect('\x1b[38;2;255;0;0m'.allMatches(out).length, equals(1));
    });

    test('Resets style when modifier or color is cleared', () {
      final renderer = Renderer(5, 1);
      final back = Buffer.blank(5, 1);

      const styled = Style(
        foreground: Color(255, 0, 0),
        modifiers: Modifier.bold,
      );
      back.setCell(0, 0, Cell('X', styled));
      back.setCell(
        1,
        0,
        Cell('Y', Style.empty),
      ); // Style.empty clears colors and bold modifier

      final sb = StringBuffer();
      renderer.render(back, sb);
      final out = sb.toString();

      // Must contain style reset \x1b[0m before printing 'Y'
      expect(out, contains('\x1b[0m'));
    });
  });

  group('Renderer Inline Mode Tests', () {
    test('Inline mode uses relative movements and vertical reset', () {
      final renderer = Renderer(5, 2, mode: RenderingMode.inline);
      final back = Buffer.blank(5, 2);

      // Frame 1: Write 'A' at (1, 0) and 'B' at (3, 1)
      back.setCell(1, 0, Cell('A', Style.empty));
      back.setCell(3, 1, Cell('B', Style.empty));

      final sb1 = StringBuffer();
      renderer.render(back, sb1);
      final out1 = sb1.toString();

      // Verify that out1 moves relatively:
      // Starts at (0,0), moves right by 1 -> \x1b[1C, writes A.
      // Moves down 1 and left/carriage-return to 0, then right by 3 -> \n\r\x1b[3C, writes B.
      // Ends at bottom: from (4,1) to (0,2) -> \n\r.
      expect(out1, contains('A'));
      expect(out1, contains('B'));
      expect(out1.endsWith('\n\r'), isTrue);

      // Frame 2: change 'B' at (3, 1) to 'C'
      back.setCell(3, 1, Cell('C', Style.empty));

      final sb2 = StringBuffer();
      renderer.render(back, sb2);
      final out2 = sb2.toString();

      // Should move up 2 lines first -> \x1b[2F
      // Then only render change for C
      expect(out2.startsWith('\x1b[2F'), isTrue);
      expect(out2, contains('C'));
    });
  });
}
