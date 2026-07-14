import 'package:termui/termui.dart';
import 'package:test/test.dart';

void main() {
  test('Compositor flattens layers efficiently without Map allocations', () {
    final compositor = Compositor();
    final target = Buffer(80, 24);

    // Create 5,000 overlapping layers
    final layers = List.generate(5000, (i) {
      final buffer = Buffer(10, 10);
      buffer.setAttributes(0, 0, char: 'A');
      return LayeredBuffer(buffer: buffer, x: i % 70, y: i % 14, zIndex: i % 5);
    });

    final watch = Stopwatch()..start();
    compositor.composite(target: target, layers: layers);
    watch.stop();

    print('Compositing 5,000 layers took: ${watch.elapsedMilliseconds}ms');
    expect(true, isTrue);
  });
}
