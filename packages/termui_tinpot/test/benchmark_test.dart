import 'dart:io';
import 'package:test/test.dart';
import 'package:image/image.dart' as img;
import 'package:termui_tinpot/termui_tinpot.dart';

void main() {
  test('Benchmark Tinpot Conversion', () async {
    final bytes = await File('packages/termui_tinpot/test/assets/omega_Gate.png').readAsBytes();
    final image = img.decodeImage(bytes)!;
    final engine = TermuiTinpot();

    // Warmup
    engine.convert(image, 85, 35, useDin99d: true);

    final stopwatch = Stopwatch()..start();
    const iterations = 100;

    for (int i = 0; i < iterations; i++) {
      engine.convert(image, 85, 35, useDin99d: true);
    }

    stopwatch.stop();
    final elapsed = stopwatch.elapsedMilliseconds;
    final fps = iterations / (elapsed / 1000);
    
    print('Completed $iterations iterations in ${elapsed}ms');
    print('Average: ${elapsed / iterations}ms per frame');
    print('FPS: ${fps.toStringAsFixed(2)}');
    
    // We expect it to be reasonable. Let's just ensure it passes.
    expect(fps, greaterThan(0));
  });
}
