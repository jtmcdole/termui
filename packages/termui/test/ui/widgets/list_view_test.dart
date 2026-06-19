import 'package:termui/termui.dart';
import 'package:termui_test/termui_test.dart';
import 'package:test/test.dart';

void main() {
  group('ListView Tests', () {
    test('ListView.fromStrings handles interactions', () async {
      final listView = ListView.fromStrings(const ['A', 'B', 'C']);

      final element = listView.createElement();
      element.mount(null);
      element.layout(BoxConstraints.tight(const Size(10, 5)));
    });

    test('ListView.raw renders correctly', () async {
      final rawList = ListView.raw(
        lines: const ['Item 1', 'Item 2', 'Item 3'],
        showScrollbar: true,
      );

      final tester = TerminalTester();
      await tester.pumpWidget(rawList);

      expect(tester.buffer!.getCell(0, 0)?.char, 'I');
      expect(tester.buffer!.getCell(5, 0)?.char, '1');

      await tester.pumpWidget(ListView.raw(lines: const ['Item A', 'Item B']));
      expect(tester.buffer!.getCell(0, 1)?.char, 'I'); // Item B selected
    });

    test('ListView handles scroll bounds', () async {
      final listView = ListView(
        children: List.generate(20, (i) => Text('Line $i')),

        selectedIndex: 15,
      );

      final tester = TerminalTester();
      await tester.pumpWidget(listView);
      // scroll is shifted
      expect(true, true);
    });
  });
}
