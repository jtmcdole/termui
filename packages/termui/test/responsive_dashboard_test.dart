import 'package:test/test.dart';
import 'package:termui/ui/buffer.dart';
import 'package:termui/ui/widgets/core/geometry.dart';
import '../example/03_responsive_dashboard.dart';

void main() {
  test('Responsive Dashboard layout tests - normal size', () {
    const app = DashboardApp();
    final element = app.createElement()..mount(null);

    final buffer = Buffer.blank(80, 20);
    expect(() {
      element.layout(BoxConstraints.tight(const Size(80, 20)));
      element.paint(buffer, Offset.zero);
    }, returnsNormally);

    element.unmount(); // Clean up timers
  });

  test('Responsive Dashboard layout tests - small size fallback', () {
    const app = DashboardApp();
    final element = app.createElement()..mount(null);

    final buffer = Buffer.blank(30, 8);
    expect(() {
      element.layout(BoxConstraints.tight(const Size(30, 8)));
      element.paint(buffer, Offset.zero);
    }, returnsNormally);

    // Verify it renders the fallback message: "Screen too small!"
    var foundFallbackText = false;
    for (var y = 0; y < buffer.height; y++) {
      final sb = StringBuffer();
      for (var x = 0; x < buffer.width; x++) {
        sb.write(buffer.getCell(x, y)?.char ?? ' ');
      }
      if (sb.toString().contains('Screen too small!')) {
        foundFallbackText = true;
        break;
      }
    }
    expect(foundFallbackText, isTrue);

    element.unmount(); // Clean up timers
  });

  test('Responsive Dashboard layout tests - resize dynamic redistribution', () {
    const app = DashboardApp();
    final element = app.createElement()..mount(null);

    // Initial render
    final buffer1 = Buffer.blank(80, 20);
    expect(() {
      element.layout(BoxConstraints.tight(const Size(80, 20)));
      element.paint(buffer1, Offset.zero);
    }, returnsNormally);

    // Simulate resize by rendering with a different bounding box
    final buffer2 = Buffer.blank(100, 30);
    expect(() {
      element.layout(BoxConstraints.tight(const Size(100, 30)));
      element.paint(buffer2, Offset.zero);
    }, returnsNormally);

    element.unmount(); // Clean up timers
  });
}
