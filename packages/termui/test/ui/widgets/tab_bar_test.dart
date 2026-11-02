import 'package:termui/termui.dart';
import 'package:termui_test/termui_test.dart';
import 'package:test/test.dart';

void main() {
  group('TabBar Tests', () {
    test('TabController manages state correctly', () {
      final controller = TabController(length: 3);
      expect(controller.index, 0);

      var notified = false;
      controller.addListener(() {
        notified = true;
      });

      controller.index = 2;
      expect(controller.index, 2);
      expect(notified, true);

      controller.index = 5; // Should clamp to length - 1
      expect(controller.index, 2);
    });

    test('TabBar paints correctly and updates active tab highlight', () async {
      final controller = TabController(length: 2);

      final bar = TabBar(
        controller: controller,
        labels: const ['Tab 1', 'Tab 2'],
      );

      final tester = TerminalTester();
      await tester.pumpWidget(bar);

      final row0 = [
        for (var x = 0; x < tester.buffer!.width; x++)
          tester.buffer!.getCharacter(x, 0),
      ].join();
      expect(row0, contains('Tab 1'));
      expect(row0, contains('Tab 2'));

      final tab1Col = row0.indexOf('Tab 1');
      final tab2Col = row0.indexOf('Tab 2');
      final initialTab1Fg = tester.buffer!.getForeground(tab1Col, 0);
      final initialTab2Fg = tester.buffer!.getForeground(tab2Col, 0);
      final initialTab1Mods = tester.buffer!.getModifiers(tab1Col, 0);
      final initialTab2Mods = tester.buffer!.getModifiers(tab2Col, 0);
      expect(
        initialTab1Fg != initialTab2Fg || initialTab1Mods != initialTab2Mods,
        isTrue,
      );

      controller.index = 1;
      await tester.pump();

      expect(tester.buffer!.getForeground(tab2Col, 0), equals(initialTab1Fg));
      expect(tester.buffer!.getModifiers(tab2Col, 0), equals(initialTab1Mods));
    });

    test('TabPanel displays correct child', () async {
      final controller = TabController(length: 2);
      final panel = TabPanel(
        tabFocusNodes: [
          FocusNode(id: 't1'),
          FocusNode(id: 't2'),
        ],
        controller: controller,
        children: const [Text('First'), Text('Second')],
      );

      final tester = TerminalTester();
      await tester.pumpWidget(panel);

      expect(tester.buffer!.getCharacter(0, 0), 'F'); // First

      controller.index = 1;
      await tester.pump();

      expect(tester.buffer!.getCharacter(0, 0), 'S'); // Second
    });
  });
}
