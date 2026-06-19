import 'package:test/test.dart';
import 'package:termui/termui.dart';

void main() {
  group('StatefulBuilder', () {
    test('passes state to builder and updates correctly on setState', () {
      final buffer = Buffer.blank(20, 10);
      int rebuildCount = 0;
      void Function(void Function())? storedSetState;

      final widget = StatefulBuilder(
        builder: (context, setState) {
          rebuildCount++;
          storedSetState = setState;
          return Text('Rebuilds: $rebuildCount');
        },
      );

      final element = widget.createElement();
      element.mount(null);
      element.layout(BoxConstraints.tight(const Size(20, 1)));
      element.paint(buffer, Offset.zero);

      expect(rebuildCount, 1);
      expect(storedSetState, isNotNull);

      // Verify initial paint
      expect(buffer.getCell(0, 0)?.char, 'R');
      expect(buffer.getCell(10, 0)?.char, '1'); // 'Rebuilds: 1'

      // Call setState
      storedSetState!(() {});

      // Verify that element is marked dirty and rebuilds
      element.rebuild();
      element.layout(BoxConstraints.tight(const Size(20, 1)));
      buffer.clear();
      element.paint(buffer, Offset.zero);

      expect(rebuildCount, greaterThan(1));
      expect(buffer.getCell(10, 0)?.char, isNot('1'));
    });
  });
}
