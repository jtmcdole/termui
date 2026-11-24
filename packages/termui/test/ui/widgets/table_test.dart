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

    test(
      'Table unmounts widget cells when rows shrink or headers change and truncates wide headers',
      () {
        final unmountedIds = <String>[];

        final initialTable = Table(
          headers: const ['HeaderOne', 'HeaderTwo'],
          columnWidths: const [10, 10],
          rows: [
            [
              _UnmountSpyCell(id: 'r0c0', onUnmount: unmountedIds.add),
              _UnmountSpyCell(id: 'r0c1', onUnmount: unmountedIds.add),
            ],
            [
              _UnmountSpyCell(id: 'r1c0', onUnmount: unmountedIds.add),
              _UnmountSpyCell(id: 'r1c1', onUnmount: unmountedIds.add),
            ],
          ],
        );

        final element = initialTable.createElement() as TableElement;
        element.mount(null);
        addTearDown(element.unmount);

        // Paint into a narrower width than columnsTotalWidth (10 + 10 + 1 = 21 > 12)
        // to exercise header truncation.
        element.layout(const BoxConstraints.tightFor(width: 12, height: 4));
        final buffer = Buffer(12, 4);
        element.paint(buffer, Offset.zero);

        final headerLine = [
          for (var x = 0; x < 12; x++) buffer.getCharacter(x, 0),
        ].join();
        expect(headerLine, equals('HeaderOne  H'));
        expect(unmountedIds, isEmpty);

        // Shrink rows from 2 to 1: row 1 cells must unmount.
        element.update(
          Table(
            headers: const ['HeaderOne', 'HeaderTwo'],
            columnWidths: const [10, 10],
            rows: [
              [
                _UnmountSpyCell(id: 'r0c0', onUnmount: unmountedIds.add),
                _UnmountSpyCell(id: 'r0c1', onUnmount: unmountedIds.add),
              ],
            ],
          ),
        );
        expect(unmountedIds, equals(['r1c0', 'r1c1']));

        // Change headers.length from 2 to 1: old row 0 cell elements must unmount
        // before rebuilding the resized column slot list.
        element.update(
          Table(
            headers: const ['OnlyHeader'],
            columnWidths: const [10],
            rows: [
              [_UnmountSpyCell(id: 'r0c0_new', onUnmount: unmountedIds.add)],
            ],
          ),
        );
        expect(unmountedIds, equals(['r1c0', 'r1c1', 'r0c0', 'r0c1']));
      },
    );
  });
}

class _UnmountSpyCell extends Widget {
  final String id;
  final void Function(String id) onUnmount;

  const _UnmountSpyCell({required this.id, required this.onUnmount});

  @override
  Element createElement() => _UnmountSpyCellElement(this);
}

class _UnmountSpyCellElement extends Element {
  _UnmountSpyCellElement(_UnmountSpyCell super.widget);

  @override
  void unmount() {
    (widget as _UnmountSpyCell).onUnmount((widget as _UnmountSpyCell).id);
    super.unmount();
  }

  @override
  Size performLayout(BoxConstraints constraints) =>
      constraints.constrain(const Size(1, 1));

  @override
  void performPaint(Buffer buffer, Offset offset) {
    buffer.writeString(offset.dx, offset.dy, 'x', Style.empty);
  }
}
