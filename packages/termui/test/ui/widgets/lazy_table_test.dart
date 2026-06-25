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
  });
}
