import 'package:termui/termui.dart';
import 'package:termui_test/termui_test.dart';
import 'package:test/test.dart';

String _readLine(Buffer buffer, int y) =>
    [for (var x = 0; x < buffer.width; x++) buffer.getCharacter(x, y)].join();

void main() {
  group('ListView Tests', () {
    test('ListView.fromStrings renders items into buffer', () async {
      final listView = ListView.fromStrings(const ['Alpha', 'Beta', 'Gamma']);

      final element = listView.createElement();
      element.mount(null);
      element.layout(BoxConstraints.tight(const Size(10, 5)));
      final buffer = Buffer.blank(10, 5);
      element.paint(buffer, Offset.zero);

      expect(_readLine(buffer, 0), contains('Alpha'));
      expect(_readLine(buffer, 1), contains('Beta'));
      expect(_readLine(buffer, 2), contains('Gamma'));
    });

    test('ListView.raw renders correctly', () async {
      final rawList = ListView.raw(
        lines: const ['Item 1', 'Item 2', 'Item 3'],
        showScrollbar: true,
      );

      final tester = TerminalTester();
      await tester.pumpWidget(rawList);

      expect(tester.buffer!.getCharacter(0, 0), 'I');
      expect(tester.buffer!.getCharacter(5, 0), '1');

      await tester.pumpWidget(ListView.raw(lines: const ['Item A', 'Item B']));
      expect(tester.buffer!.getCharacter(0, 1), 'I'); // Item B selected
    });

    test('ListView handles scroll bounds', () async {
      final listView = ListView(
        children: List.generate(30, (i) => Text('Line $i')),
        selectedIndex: 28,
      );

      final tester = TerminalTester();
      await tester.pumpWidget(listView);

      final allRows = [
        for (var y = 0; y < tester.buffer!.height; y++)
          _readLine(tester.buffer!, y),
      ].join('\n');
      expect(allRows, contains('Line 28'));
      expect(allRows, isNot(contains('Line 0 ')));
    });
  });
}
