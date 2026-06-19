import 'package:termui/termui.dart';
import 'package:termui/terminal/event.dart' as evt;
import 'package:termui_test/termui_test.dart';
import 'package:test/test.dart';

void main() {
  group('SingleChildScrollView Tests', () {
    test('Handles scrolling via mouse wheel', () {
      final view = SingleChildScrollView(
        childLength: 50,
        child: const SizedBox(width: 10, height: 50),
      );

      final element = view.createElement();
      element.mount(null);
      element.layout(const BoxConstraints.tightFor(width: 10, height: 10));


    });

    test('Renders child correctly', () async {
      final tester = TerminalTester();
      await tester.pumpWidget(
        SingleChildScrollView(
          childLength: 10,
          child: const Text('Hello World'),
        ),
      );

      expect(tester.buffer!.getCell(0, 0)?.char, 'H');
    });
  });

  group('SafeLayout Tests', () {
    test('SafeLayout clamps to bounds', () {
      final safe = SafeLayout(
        child: const SizedBox(width: 100, height: 100),
      );

      final element = safe.createElement();
      element.mount(null);

      final size = element.layout(const BoxConstraints(maxWidth: 50, maxHeight: 50));
      expect(size.width, 50);
      expect(size.height, 50);
    });
  });
}
