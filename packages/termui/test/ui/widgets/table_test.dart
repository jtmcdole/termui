import 'package:termui/termui.dart';
import 'package:test/test.dart';

void main() {
  group('Table Tests', () {
    test('Table handles wide characters and CJK without layout shifting', () {
      final table = Table(
        headers: const ['Col1', 'Col2'],
        columnWidths: const [10, 5],
        rows: const [
          ['📁 folder', 'next'],
          ['📁 folder exceeds width', 'val'],
        ],
      );

      final element = table.createElement();
      element.mount(null);
      element.layout(const BoxConstraints.tightFor(width: 20, height: 4));

      final buffer = Buffer(20, 4);
      element.paint(buffer, Offset.zero);

      // Row 1 (first item, y == 2):
      // Col 1 has width 10, followed by a 1-space separator.
      // So 'next' in Col 2 should start exactly at x = 11.
      expect(buffer.getCharacter(0, 2), equals('📁'));
      expect(buffer.getCharacter(1, 2), equals('')); // Wide character marker
      expect(buffer.getCharacter(2, 2), equals(' '));
      expect(buffer.getCharacter(3, 2), equals('f'));
      expect(buffer.getCharacter(11, 2), equals('n'));
      expect(buffer.getCharacter(12, 2), equals('e'));

      // Row 2 (second item, y == 3):
      // Col 1 has width 10. The cell text is '📁 folder exceeds width'.
      // With visual truncation:
      // '📁' (2) + ' ' (1) + 'f' (1) + 'o' (1) + 'l' (1) + 'd' (1) + 'e' (1) + 'r' (1) + ' ' (1) = 10 visual width.
      // So it should truncate to '📁 folder ' (excluding 'exceeds width').
      // Let's verify buffer characters for Col 1 in row 2 (y == 3):
      expect(buffer.getCharacter(0, 3), equals('📁'));
      expect(buffer.getCharacter(1, 3), equals(''));
      expect(buffer.getCharacter(2, 3), equals(' '));
      expect(buffer.getCharacter(3, 3), equals('f'));
      expect(buffer.getCharacter(4, 3), equals('o'));
      expect(buffer.getCharacter(5, 3), equals('l'));
      expect(buffer.getCharacter(6, 3), equals('d'));
      expect(buffer.getCharacter(7, 3), equals('e'));
      expect(buffer.getCharacter(8, 3), equals('r'));
      expect(buffer.getCharacter(9, 3), equals(' '));
      expect(buffer.getCharacter(10, 3), equals(' ')); // Separator space
      expect(buffer.getCharacter(11, 3), equals('v')); // Start of Col 2
    });
  });
}
