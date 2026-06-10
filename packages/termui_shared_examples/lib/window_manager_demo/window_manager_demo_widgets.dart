import 'dart:math';
import 'package:termui/ui/buffer.dart';
import 'package:termui/ui/style.dart';
import 'package:termui/ui/color.dart';
import 'package:termui/ui/layout.dart';
import 'package:termui/ui/window.dart';
import 'package:termui/ui/widget_toolkit.dart';

/// A widget that displays instructions and the currently focused window.
class InfoWidget extends Widget {
  /// The title of the currently focused window.
  String focusedWindow = 'None';

  /// A list of recorded key presses.
  final List<String> keys = [];

  @override
  void render(Buffer buffer, Rect area) {
    buffer.writeString(
      0,
      0,
      'Click windows to focus.\nWin 1 onKeyEvent logs keys below.\nPress Q on other windows to quit.',
      const Style(foreground: Colors.white),
    );
    buffer.writeString(
      0,
      4,
      'Focused Win: $focusedWindow',
      const Style(foreground: Colors.orange, modifiers: Modifier.bold),
    );
    buffer.writeString(
      0,
      6,
      'Win 1 Keys: ${keys.map((k) => k == '\r' || k == '\n' ? 'Enter' : k).join(" ")}',
      const Style(foreground: Colors.green, modifiers: Modifier.bold),
    );
  }
}

/// A widget that tracks and displays mouse events and cursor position.
class MouseTrackerWidget extends Widget {
  /// The current X coordinate of the mouse.
  int mouseX = 0;

  /// The current Y coordinate of the mouse.
  int mouseY = 0;

  /// The last recorded mouse event.
  String lastEvent = 'None';

  /// The window currently being hovered over.
  String hoverWindow = 'None';

  /// The last window transition event.
  String lastTransition = 'None';

  @override
  void render(Buffer buffer, Rect area) {
    buffer.writeString(
      0,
      0,
      'Cursor Coords: ($mouseX, $mouseY)',
      const Style(foreground: Color(0, 255, 255), modifiers: Modifier.bold),
    );
    buffer.writeString(
      0,
      2,
      'Hover Window: $hoverWindow',
      const Style(foreground: Colors.white),
    );
    buffer.writeString(
      0,
      4,
      'Event: $lastEvent',
      const Style(foreground: Colors.white),
    );
    buffer.writeString(
      0,
      6,
      'Log: $lastTransition',
      const Style(foreground: Color(255, 255, 0)),
    );
  }
}

/// A widget that displays the bounds (width and height) of a window.
class SizeWidget extends Widget {
  /// A function that returns the window to measure.
  final Window Function() windowFn;

  /// Creates a new instance of [SizeWidget].
  SizeWidget(this.windowFn);

  @override
  void render(Buffer buffer, Rect area) {
    final win = windowFn();
    final w = win.bounds.width;
    final h = win.bounds.height;
    buffer.writeString(
      0,
      0,
      'Drag bottom corners (╚/╝) to resize.\n\nWidth:  $w\nHeight: $h',
      const Style(foreground: Colors.white),
    );
  }
}

/// A widget that renders an animated graphic on a Braille canvas.
class BrailleCanvasWidget extends Widget {
  /// The current frame of the animation.
  int frame = 0;

  @override
  void render(Buffer buffer, Rect area) {
    final w = area.width;
    final h = area.height;
    if (w <= 0 || h <= 0) return;

    final canvas = Canvas(w, h, style: const Style(foreground: Colors.green));

    final pixelCx = w;
    final pixelCy = h * 2;
    final minDim = pixelCx < pixelCy ? pixelCx : pixelCy;

    final baseR = minDim * 0.45;
    final varR = minDim * 0.11;
    final r = baseR + varR * sin(frame * 0.1);

    for (var theta = 0.0; theta < 2 * pi; theta += 0.02) {
      final x = (pixelCx + r * cos(theta) * 2.0).round();
      final y = (pixelCy + r * sin(theta)).round();
      canvas.setPixel(x, y, true);
    }

    for (var i = 0; i < 20; i++) {
      final px = (sin(frame * 0.05 + i) * (pixelCx - 5) + pixelCx).round();
      final py = (cos(frame * 0.05 + i) * (pixelCy - 8) + pixelCy).round();
      canvas.setPixel(px, py, true);
    }

    canvas.render(buffer, Rect(0, 0, w, h));
  }
}
