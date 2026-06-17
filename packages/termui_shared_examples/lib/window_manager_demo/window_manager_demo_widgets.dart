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
  Element createElement() => _InfoElement(this);
}

class _InfoElement extends Element {
  _InfoElement(super.widget);

  @override
  Size performLayout(BoxConstraints constraints) {
    return Size(constraints.maxWidth, constraints.maxHeight);
  }

  @override
  void paint(Buffer buffer, Offset offset) {
    final w = widget as InfoWidget;
    buffer.writeString(
      offset.dx,
      offset.dy,
      'Click windows to focus.\nWin 1 onKeyEvent logs keys below.\nPress Q on other windows to quit.',
      const Style(foreground: Colors.white),
    );
    buffer.writeString(
      offset.dx,
      offset.dy + 4,
      'Focused Win: ${w.focusedWindow}',
      const Style(foreground: Colors.orange, modifiers: Modifier.bold),
    );
    buffer.writeString(
      offset.dx,
      offset.dy + 6,
      'Win 1 Keys: ${w.keys.map((k) => k == '\r' || k == '\n' ? 'Enter' : k).join(" ")}',
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
  Element createElement() => _MouseTrackerElement(this);
}

class _MouseTrackerElement extends Element {
  _MouseTrackerElement(super.widget);

  @override
  Size performLayout(BoxConstraints constraints) {
    return Size(constraints.maxWidth, constraints.maxHeight);
  }

  @override
  void paint(Buffer buffer, Offset offset) {
    final w = widget as MouseTrackerWidget;
    buffer.writeString(
      offset.dx,
      offset.dy,
      'Cursor Coords: (${w.mouseX}, ${w.mouseY})',
      const Style(foreground: Color(0, 255, 255), modifiers: Modifier.bold),
    );
    buffer.writeString(
      offset.dx,
      offset.dy + 2,
      'Hover Window: ${w.hoverWindow}',
      const Style(foreground: Colors.white),
    );
    buffer.writeString(
      offset.dx,
      offset.dy + 4,
      'Event: ${w.lastEvent}',
      const Style(foreground: Colors.white),
    );
    buffer.writeString(
      offset.dx,
      offset.dy + 6,
      'Log: ${w.lastTransition}',
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
  Element createElement() => _SizeElement(this);
}

class _SizeElement extends Element {
  _SizeElement(super.widget);

  @override
  Size performLayout(BoxConstraints constraints) {
    return Size(constraints.maxWidth, constraints.maxHeight);
  }

  @override
  void paint(Buffer buffer, Offset offset) {
    final wWidget = widget as SizeWidget;
    final win = wWidget.windowFn();
    final w = win.width;
    final h = win.height;
    buffer.writeString(
      offset.dx,
      offset.dy,
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
  Element createElement() => _BrailleCanvasElement(this);
}

class _BrailleCanvasElement extends Element {
  _BrailleCanvasElement(super.widget);

  @override
  Size performLayout(BoxConstraints constraints) {
    return Size(constraints.maxWidth, constraints.maxHeight);
  }

  @override
  void paint(Buffer buffer, Offset offset) {
    final w = size.width;
    final h = size.height;
    if (w <= 0 || h <= 0) return;
    final target = widget as BrailleCanvasWidget;
    final frame = target.frame;

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

    final canvasEl = canvas.createElement()..mount(null);
    canvasEl.layout(BoxConstraints.tight(Size(w, h)));
    canvasEl.paint(buffer, offset);
    canvasEl.unmount();
  }
}
