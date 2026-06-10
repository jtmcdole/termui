/// This is an example of rendering raw terminal with the braille Canvas.
library;

import 'dart:async';
import 'dart:math';
import 'package:termui/ui/buffer.dart';
import 'package:termui/ui/style.dart';
import 'package:termui/ui/color.dart';
import 'package:termui/ui/layout.dart';
import 'package:termui/ui/renderer.dart';
import 'package:termui/ui/widget_toolkit.dart';

void main() async {
  const width = 80;
  const height = 24;
  final buffer = Buffer.blank(width, height);
  final renderer = Renderer(width, height);
  final canvas = Canvas(
    width,
    height - 2,
    style: const Style(foreground: Colors.green),
  );

  print('\x1b[?25l'); // Hide cursor
  print('\x1b[2J'); // Clear screen

  const fps = 60;

  var frame = 0;
  Timer.periodic(const Duration(milliseconds: 1000 ~/ fps), (t) {
    canvas.clear();

    // Draw an animated morphing circle
    final cx = width;
    final cy = (height - 2) * 2;
    final r = 20 + 5 * sin(frame * 0.1);
    for (var theta = 0.0; theta < 2 * pi; theta += 0.02) {
      final x = (cx + r * cos(theta) * 2.0).round();
      final y = (cy + r * sin(theta)).round();
      canvas.setPixel(x, y, true);
    }

    // Draw some noise points moving on sine/cos waves
    for (var i = 0; i < 20; i++) {
      final px = (sin(frame * 0.05 + i) * (width - 5) + width).round();
      final py = (cos(frame * 0.05 + i) * (height - 4) * 2 + (height - 2) * 2)
          .round();
      canvas.setPixel(px, py, true);
    }

    buffer.clear();

    // Render top header
    buffer.writeString(
      0,
      0,
      '=== Braille Canvas Animation ===',
      const Style(foreground: Colors.white, modifiers: Modifier.bold),
    );

    // Render canvas inside the layout area
    final canvasArea = const Rect(0, 1, width, height - 2);
    canvas.render(buffer, canvasArea);

    buffer.writeString(
      0,
      height - 1,
      'Frame: $frame | Render target: ~$fps FPS',
      const Style(modifiers: Modifier.dim),
    );

    final buf = StringBuffer();
    renderer.render(buffer, buf);
    print(buf);
    frame++;

    if (frame >= 150) {
      t.cancel();
      print('\x1b[?25h\x1b[0m'); // Restore cursor
      print('\nAnimation Done!');
    }
  });
}
