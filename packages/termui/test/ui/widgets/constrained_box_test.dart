import 'package:termui/termui.dart';
import 'package:termui_test/termui_test.dart';
import 'package:test/test.dart';

void main() {
  group('ConstrainedBox Tests', () {
    test('ConstrainedBox enforces minimum constraints', () {
      final widget = ConstrainedBox(
        constraints: const BoxConstraints(minWidth: 20, minHeight: 10),
        child: const SizedBox(width: 5, height: 5),
      );

      final element = widget.createElement();
      element.mount(null);
      final size = element.layout(const BoxConstraints(maxWidth: 50, maxHeight: 50));

      expect(size.width, 20);
      expect(size.height, 10);
    });

    test('ConstrainedBox enforces maximum constraints', () {
      final widget = ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 15, maxHeight: 8),
        child: const SizedBox(width: 50, height: 50),
      );

      final element = widget.createElement();
      element.mount(null);
      final size = element.layout(const BoxConstraints(maxWidth: 100, maxHeight: 100));

      expect(size.width, 15);
      expect(size.height, 8);
    });

    test('ConstrainedBox gets intrinsic height correctly', () {
      final widget = ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 10, maxHeight: 20),
        child: const SizedBox(width: 50, height: 50),
      );

      expect(widget.getIntrinsicHeight(10), 20); // 50 clamped to max 20
    });



    test('ConstrainedBox paints child correctly', () {
      final widget = ConstrainedBox(
        constraints: BoxConstraints.tight(const Size(10, 10)),
        child: const Text('Hi'),
      );

      final element = widget.createElement();
      element.mount(null);
      element.layout(const BoxConstraints());

      final buffer = Buffer(10, 10);
      element.paint(buffer, Offset.zero);
      expect(buffer.getCell(0, 0)?.char, 'H');
      expect(buffer.getCell(1, 0)?.char, 'i');

      var visited = false;
      element.visitChildren((child) {
        visited = true;
      });
      expect(visited, true);
    });
  });
}
