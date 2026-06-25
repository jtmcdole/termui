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
      expect((buffer.getModifiers(0, 0) & Modifier.transparent) != 0, isTrue);
      expect(buffer.getCharacter(0, 0), ' ');
    });

    test('Buffer solid blank creation', () {
      final buffer = Buffer.blank(5, 5);
      expect((buffer.getModifiers(0, 0) & Modifier.transparent) != 0, isFalse);
    });

    test('Buffer writeString with clipping and wrapping', () {
      final buffer = Buffer(5, 3);
      buffer.writeString(0, 0, 'ABC\nDE', Style.empty);

      expect(buffer.getCharacter(0, 0), 'A');
      expect(buffer.getCharacter(1, 0), 'B');
      expect(buffer.getCharacter(2, 0), 'C');
      expect(buffer.getCharacter(3, 0), ' '); // Transparent space

      expect(buffer.getCharacter(0, 1), 'D');
      expect(buffer.getCharacter(1, 1), 'E');

      // Writing out of bounds clips safely
      buffer.writeString(3, 2, 'HELLO', Style.empty);
      expect(buffer.getCharacter(3, 2), 'H');
      expect(buffer.getCharacter(4, 2), 'E');
    });

    test('Buffer resizing', () {
      final buffer = Buffer(3, 3);
      buffer.writeString(0, 0, '123\n456\n789', Style.empty);

      buffer.resize(2, 2);
      expect(buffer.width, 2);
      expect(buffer.height, 2);
      expect(buffer.getCharacter(0, 0), '1');
      expect(buffer.getCharacter(1, 0), '2');
      expect(buffer.getCharacter(0, 1), '4');
      expect(buffer.getCharacter(1, 1), '5');
      expect(buffer.getCharacter(0, 2), ' '); // out of bounds
    });
  });

  group('Compositor Tests', () {
    test('Z-Index and Transparency compositing', () {
      final target = Buffer.blank(4, 4);
      final layer1 = Buffer(3, 3);
      final layer2 = Buffer(3, 3);

      // Layer 1 has '1's at 0,0 and 1,0 and is otherwise transparent
      layer1.setAttributes(0, 0, char: '1', modifiers: 0);
      layer1.setAttributes(1, 0, char: '1', modifiers: 0);

      // Layer 2 has '2's at 1,0 and 2,0 and is otherwise transparent
      layer2.setAttributes(1, 0, char: '2', modifiers: 0);
      layer2.setAttributes(2, 0, char: '2', modifiers: 0);

      final comp = Compositor();

      // Case 1: layer2 has higher z-index, should overwrite layer1
      comp.composite(
        target: target,
        layers: [
          LayeredBuffer(buffer: layer1, x: 0, y: 0, zIndex: 1),
          LayeredBuffer(buffer: layer2, x: 0, y: 0, zIndex: 2),
        ],
      );

      expect(target.getCharacter(0, 0), '1');
      expect(target.getCharacter(1, 0), '2');
      expect(target.getCharacter(2, 0), '2');
      expect(target.getCharacter(3, 0), ' ');

      // Reset target
      target.fillAttributes(char: ' ', modifiers: Modifier.transparent);

      // Case 2: layer1 has higher z-index, should overwrite layer2
      comp.composite(
        target: target,
        layers: [
          LayeredBuffer(buffer: layer1, x: 0, y: 0, zIndex: 2),
          LayeredBuffer(buffer: layer2, x: 0, y: 0, zIndex: 1),
        ],
      );

      expect(target.getCharacter(0, 0), '1');
      expect(target.getCharacter(1, 0), '1');
      expect(target.getCharacter(2, 0), '2');
      expect(target.getCharacter(3, 0), ' ');
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
      back.setAttributes(
        0,
        0,
        char: 'X',
        fg: styled.foreground?.argb,
        bg: styled.background?.argb,
        modifiers: styled.modifiers,
      );
      back.setAttributes(
        1,
        0,
        char: 'Y',
        modifiers: 0,
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
      back.setAttributes(1, 0, char: 'A', modifiers: 0);
      back.setAttributes(3, 1, char: 'B', modifiers: 0);

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
      back.setAttributes(3, 1, char: 'C', modifiers: 0);

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
