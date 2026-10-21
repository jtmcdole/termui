import 'dart:io';
import 'package:image/image.dart' as img;
import 'package:termui_tinpot/termui_tinpot.dart';

Future<void> main() async {
  final bytes = await File('test/assets/omega_Gate.png').readAsBytes();
  final image = img.decodeImage(bytes)!;
  final engine = TermuiTinpot();

  // Warmup
  engine.convertBuffer(image, 85, 35, useDin99d: true);

  final stopwatch = Stopwatch()..start();
  const iterations = 100;

  for (int i = 0; i < iterations; i++) {
    engine.convertBuffer(image, 85, 35, useDin99d: true);
  }

  stopwatch.stop();
  final elapsed = stopwatch.elapsedMilliseconds;
  final fps = iterations / (elapsed / 1000);

  print('Completed $iterations iterations in ${elapsed}ms');
  print('Average: ${elapsed / iterations}ms per frame');
  print('FPS: ${fps.toStringAsFixed(2)}');
}
