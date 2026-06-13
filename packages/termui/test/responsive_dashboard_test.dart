import 'package:test/test.dart';
import 'package:termui/ui/buffer.dart';
import 'package:termui/ui/layout.dart';
import '../example/03_responsive_dashboard.dart';

void main() {
  test('Responsive Dashboard layout tests - normal size', () {
    const app = DashboardApp();
    final element = app.createElement()..mount(null);

    final buffer = Buffer.blank(80, 20);
    expect(
      () => element.render(buffer, const Rect(0, 0, 80, 20)),
      returnsNormally,
    );

    element.unmount(); // Clean up timers
  });

  test('Responsive Dashboard layout tests - small size fallback', () {
    const app = DashboardApp();
    final element = app.createElement()..mount(null);

    final buffer = Buffer.blank(30, 8);
    expect(
      () => element.render(buffer, const Rect(0, 0, 30, 8)),
      returnsNormally,
    );

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
    expect(
      () => element.render(buffer1, const Rect(0, 0, 80, 20)),
      returnsNormally,
    );

    // Simulate resize by rendering with a different bounding box
    final buffer2 = Buffer.blank(100, 30);
    expect(
      () => element.render(buffer2, const Rect(0, 0, 100, 30)),
      returnsNormally,
    );

    element.unmount(); // Clean up timers
  });
}
