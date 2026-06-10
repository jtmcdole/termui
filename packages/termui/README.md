# termui

A high-performance, double-buffered **Terminal User Interface (TUI)** and **declarative layout engine** for Dart.

`termui` enables you to build complex, rich, and highly interactive terminal applications with overlapping windows, layout grids, and a widget tree structure inspired by Flutter; without the performance pitfalls, low-level ANSI complexity, or terminal flickering of naive CLI output printing.

---

## Why termui?

- **Double-Buffered Rendering**: Maintains an in-memory representation of the screen and performs delta diffing against the previous frame, emitting only the minimal ANSI escape sequences required to repaint modified cells. Say goodbye to terminal flicker!
- **Flutter-Inspired Declarative Layouts**: Design layouts using container widgets like `Column`, `Row`, and `Stack`, structured with constraints (`LengthConstraint`, `PercentageConstraint`, `FlexConstraint`).
- **Complete Focus Node Tree & Input Dispatcher**: Translates raw stdin byte sequences into mouse, keyboard, paste, and focus events, automatically routing them down a Focus tree.
- **Floating Overlapping Windows**: Native window manager supporting movable, resizable, and overlapping windows with customizable Z-indices, border decorations, and focus highlights.
- **Rich Widget Toolkit**: Exposes fully-functional components: navigable lists, single/multiline text input fields with cursors, tables, custom borders, animated progress indicators, custom spinner icons, and more.
- **Web & Flutter Embedding**: By decoupling the rendering interface from native OS streams, the exact same TUI logic can be embedded directly into a Flutter application or web canvas using the complementary [`termui_flutter`](../termui_flutter) package.
- **2D Sub-pixel Braille Graphics**: Contains a 2D sub-pixel braille drawing canvas for plotting antialiased filled polygons, charts, vector lines, and radars directly in a text grid.

---

## Interactive Demo

See what is possible with `termui` in your browser! Check out our live interactive web demo hosting the entire Widget Book:

  **[Live Web Demo](https://jtmcdole.github.io/termui/)**

---

## Installation

Add `termui` to your `pubspec.yaml`:

```yaml
dependencies:
  termui: ^0.1.0-alpha.1
```

---

## Simple Compilable Example

Below is a complete, clean, and compilable example of building a terminal application with an interactive layout and input loop:

```dart
import 'dart:async';
import 'package:termui/termui.dart';

void main() async {
  // Run inside runGuarded to restore raw mode and cursor settings on crash/exit.
  await Terminal.runGuarded((terminal) async {
    // 1. Initialize terminal screen and setup mode
    terminal.enterAlternateScreen();
    terminal.hideCursor();
    terminal.enableMouseTracking();

    final termSize = await terminal.size;
    var width = termSize.x;
    var height = termSize.y;

    // 2. Initialize the offscreen draw buffer and the delta renderer
    final buffer = Buffer.blank(width, height);
    var renderer = Renderer(width, height, mode: RenderingMode.alternateScreen);

    var counter = 0;

    // 3. Define the UI rendering method
    void drawFrame() {
      buffer.clear();
      
      // Build a declarative layout tree (Column -> Center -> Text)
      final layout = Column([
        SizedBox(
          height: 1,
          child: Text(
            ' termui Counter Demo ',
            style: const Style(
              foreground: Colors.white,
              background: Colors.blue,
              modifiers: Modifier.bold,
            ),
          ),
        ),
        Expanded(
          child: Center(
            child: Text(
              'Counter Value: $counter\n\nPress [+] to increment, [-] to decrement.\nPress [Q] or Ctrl+C to exit.',
              style: const Style(foreground: Colors.yellow),
              textAlign: TextAlign.center,
            ),
          ),
        ),
        SizedBox(
          height: 1,
          child: Text(
            ' Current Terminal size: ${width}x${height} ',
            style: const Style(foreground: Colors.black, background: Colors.orange),
          ),
        ),
      ]);

      // Render the layout elements onto the offscreen buffer
      layout.render(buffer, Rect(0, 0, width, height));

      // Compute diff and write ANSI sequences to stdout
      final sb = StringBuffer();
      renderer.render(buffer, sb);
      if (sb.isNotEmpty) {
        terminal.backend.write(sb.toString());
      }
    }

    // Initial frame draw
    drawFrame();

    // 4. Listen to terminal resizing events
    final sizeSubscription = terminal.watchSize().listen((size) {
      width = size.x;
      height = size.y;
      buffer.resize(width, height);
      renderer = Renderer(width, height, mode: RenderingMode.alternateScreen);
      drawFrame();
    });

    try {
      // 5. Main event loop listening to parsed keyboard/mouse events
      await for (final event in terminal.events) {
        if (event is KeyEvent) {
          if (event.key == 'q' || event.key == 'Q') {
            break;
          }
          if (event.key == '+') {
            counter++;
            drawFrame();
          } else if (event.key == '-') {
            counter--;
            drawFrame();
          }
        }
      }
    } finally {
      // Clean up sizing subscription
      await sizeSubscription.cancel();
      // Terminal.runGuarded automatically restores standard screen and cursor.
    }
  });
}
```

---

## Running the Examples

This repository includes several prebuilt showcase examples under the `example/` directory:

```bash
# A comprehensive interactive layout and widget explorer
dart run example/widget_book.dart

# An overlapping window manager with draggable and resizable borders
dart run example/window_manager_interactive.dart

# Sub-pixel rendering on a vector braille canvas
dart run example/braille_canvas.dart

# Basic layout constraints alignment container
dart run example/layout_demo.dart
```

---

## Flutter & Web Support

To host a `termui` TUI application in a graphical environment (e.g. within a Flutter mobile/desktop widget or a browser canvas), check out the companion package:

  **[termui_flutter](../termui_flutter)**

---

## License

This project is licensed under the MIT License - see the [LICENSE](../../LICENSE) file for details.
