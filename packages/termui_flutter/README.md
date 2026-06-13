# termui_flutter

A Flutter GUI embedder and high-performance renderer for [`termui`](../termui) applications.

`termui_flutter` allows you to host fully-interactive terminal applications (TUIs) inside Flutter mobile, desktop, and web apps. It bridges Flutter's rendering pipeline and gesture/focus systems with `termui`'s state machine, double-buffered canvas, and widget engine.

<video src="https://github.com/user-attachments/assets/a92129b8-1bbb-4d74-8983-6c8de75a1962" width="100%" autoplay loop muted controls></video>

---

## Why termui_flutter?

- **Dynamic Texture Atlas**: Uses `GlyphAtlas` to rasterize monospaced terminal fonts and box-drawing/block characters directly into GPU-backed textures on-demand. This eliminates character seams, anti-aliasing artifacts, and line gaps.
- **Procedural Box Drawing**: Automatically bypasses font rendering for thin/double lines and block element unicode codes (`┌`, `─`, `█`, etc.), rendering them mathematically on the canvas for pixel-perfect grids.
- **Gesture/Input Routing**: Maps Flutter tap, drag, hover, and mouse scroll wheel gestures into SGR mouse coordinates, and translates hardware keys into standard terminal key sequences.
- **Dynamic Scale Adjustments**: Supports runtime scale modifications (increasing/decreasing font sizes), prompting the underlying terminal to re-measure boundaries and trigger fluid layout recalculations.
- **Zero Platform Channels**: Communicates purely via memory streams, ensuring standard code compatibility across Android, iOS, macOS, Windows, Linux, and web browser platforms.

---

## Interactive Demo

See `termui_flutter` running live in a web browser! Our online demo features the entire interactive Widget Book built with this package:

  **[Live Web Demo](https://jtmcdole.github.io/termui/)**

---

## Installation

Add both `termui` and `termui_flutter` to your `pubspec.yaml`:

```yaml
dependencies:
  termui: ^0.1.0-alpha.1
  termui_flutter: ^0.1.0-alpha.1
```

---

## Simple Compilable Example

Below is a complete, clean, and compilable Flutter application hosting a interactive terminal counter:

```dart
import 'package:flutter/material.dart' hide Color;
import 'package:termui/termui.dart' as termui;
import 'package:termui_flutter/termui_flutter.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 640,
            height: 480,
            child: Terminal(
              fontFamily: 'Cascadia Mono',
              fontSize: 14.0,
              backgroundColor: Colors.black,
              onRun: (terminal, drawFrame) async {
                final termSize = await terminal.size;
                final buffer = termui.Buffer.blank(termSize.x, termSize.y);

                var counter = 0;

                void render() {
                  buffer.clear();
                  
                  // Build a simple layout
                  final layout = termui.Column([
                    termui.SizedBox(
                      height: 1,
                      child: termui.Text(
                        ' termui Flutter Embedded Counter ',
                        style: const termui.Style(
                          foreground: termui.Colors.white,
                          background: termui.Colors.blue,
                        ),
                      ),
                    ),
                    termui.Expanded(
                      child: termui.Center(
                        child: termui.Text(
                          'Counter: $counter\n\nClick with mouse or press [+] to increment.\nPress [-] to decrement.\nPress [q] to quit.',
                          style: const termui.Style(foreground: termui.Colors.green),
                          textAlign: termui.TextAlign.center,
                        ),
                      ),
                    ),
                  ]);

                  // Draw layout to buffer
                  final elementWrapper = termui.ElementWidget(layout);
                  elementWrapper.layout(termui.BoxConstraints.tight(termui.Size(termSize.x, termSize.y)));
                  elementWrapper.paint(buffer, termui.Offset.zero);
                  // Flush buffer to the Flutter painter
                  drawFrame(buffer);
                }

                // Initial render
                render();

                // Simple event loop handling key and mouse clicks
                await for (final event in terminal.events) {
                  if (event is termui.KeyEvent) {
                    if (event.key == 'q' || event.key == 'Q') {
                      break;
                    } else if (event.key == '+') {
                      counter++;
                    } else if (event.key == '-') {
                      counter--;
                    }
                  } else if (event is termui.MouseEvent) {
                    // Increment counter on left click
                    if (event.type == termui.MouseEventType.press && 
                        event.button == termui.MouseButton.left) {
                      counter++;
                    }
                  }
                  render();
                }
              },
            ),
          ),
        ),
      ),
    );
  }
}
```

---

## Core package

`termui_flutter` acts strictly as the renderer and embedder interface. For standard CLI application logic, layouts, and widgets, check out the core package:
  **[termui](../termui)**

---

## License

This project is licensed under the MIT License - see the [LICENSE](../../LICENSE) file for details.
