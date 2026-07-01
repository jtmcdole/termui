import 'package:termui/termui.dart';
import 'package:test/test.dart';

void main() {
  group('LazyList Tests', () {
    test('LazyList builds only visible items', () {
      int buildCount = 0;
      final lazy = LazyList(
        itemCount: 100,
        itemBuilder: (i) {
          buildCount++;
          return Text('Item \$i');
        },
      );

      final element = lazy.createElement();
      element.mount(null);
      element.layout(const BoxConstraints.tightFor(width: 20, height: 5));

      // Should build only 5 items initially
      expect(buildCount, 5);

      final buffer = Buffer(20, 5);
      element.paint(buffer, Offset.zero);
      expect(buffer.getCharacter(0, 0), 'I');

      // Update widget with new offset
      final lazy2 = LazyList(
        itemCount: 100,
        scrollOffset: 10,
        itemBuilder: (i) {
          return Text('Item \$i');
        },
      );
      element.update(lazy2);
      element.layout(const BoxConstraints.tightFor(width: 20, height: 5));
      element.paint(buffer, Offset.zero);
    });

    test('LazyList respects changing height', () {
      final lazy = LazyList(
        itemCount: 10,
        itemBuilder: (i) => Text('Item \$i'),
      );

      final element = lazy.createElement();
      element.mount(null);
      element.layout(const BoxConstraints.tightFor(width: 20, height: 2));

      expect((element as LazyListElement).childElements.length, 2);

      element.layout(const BoxConstraints.tightFor(width: 20, height: 4));
      expect((element).childElements.length, 4);
    });
  });

  group('LazyTable Tests', () {
    test('LazyTable renders headers and visible rows', () {
      final table = LazyTable(
        headers: const ['ID', 'Name'],
        columnWidths: const [5, 10],
        itemCount: 50,
        itemBuilder: (i) => ['\$i', 'Name \$i'],
      );

      final element = table.createElement();
      element.mount(null);
      element.layout(const BoxConstraints.tightFor(width: 20, height: 5));

      final buffer = Buffer(20, 5);
      element.paint(buffer, Offset.zero);

      expect(buffer.getCharacter(0, 0), 'I'); // Header 'ID'
    });

    test('LazyTable scrolling and dynamic data', () {
      final table = LazyTable(
        headers: const ['A', 'B'],
        columnWidths: const [10, 10],
        itemCount: 10,
        scrollOffset: 2,
        itemBuilder: (i) => ['A\$i', 'B\$i'],
      );

      final element = table.createElement();
      element.mount(null);
      element.layout(const BoxConstraints.tightFor(width: 20, height: 5));
    });

    test('LazyTable handles wide characters and CJK without layout shifting', () {
      final table = LazyTable(
        headers: const ['Col1', 'Col2'],
        columnWidths: const [10, 5],
        itemCount: 2,
        itemBuilder: (i) =>
            i == 0 ? ['📁 folder', 'next'] : ['📁 folder exceeds width', 'val'],
      );

      final element = table.createElement();
      element.mount(null);
      element.layout(const BoxConstraints.tightFor(width: 20, height: 4));

      final buffer = Buffer(20, 4);
      element.paint(buffer, Offset.zero);

      // Row 1 (first item, i == 0):
      // Col 1 has width 10, followed by a 1-space separator.
      // So 'next' in Col 2 should start exactly at x = 11.
      expect(buffer.getCharacter(0, 2), equals('📁'));
      expect(buffer.getCharacter(1, 2), equals('')); // Wide character marker
      expect(buffer.getCharacter(2, 2), equals(' '));
      expect(buffer.getCharacter(3, 2), equals('f'));
      expect(buffer.getCharacter(11, 2), equals('n'));
      expect(buffer.getCharacter(12, 2), equals('e'));

      // Row 2 (second item, i == 1):
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
