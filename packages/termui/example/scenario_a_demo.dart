import 'dart:async';
import 'dart:io';
import 'package:termui/terminal/terminal.dart' as term;
import 'package:termui/ui/buffer.dart';
import 'package:termui/ui/layout.dart';
import 'package:termui/ui/renderer.dart';
import 'package:termui/ui/widget_toolkit.dart';
import 'package:termui/ui/style.dart';
import 'package:termui/ui/color.dart';
import 'package:termui_shared_examples/widget_book/scenario_a.dart';

void main() async {
  // Run inside runGuarded to restore raw mode and cursor settings on crash/exit.
  await term.Terminal.runGuarded((terminal) async {
    terminal.enterAlternateScreen();
    terminal.hideCursor();
    terminal.enableMouseTracking();

    final termSize = await terminal.size;
    var width = termSize.x;
    var height = termSize.y;

    final buffer = Buffer.blank(width, height);
    var renderer = Renderer(width, height, mode: RenderingMode.alternateScreen);

    // Instantiate ScenarioAExample
    final example = ScenarioAExample();
    example.init();

    void drawFrame() {
      buffer.clear();

      // Build a simple overall container containing header, content, and footer
      final layout = Column([
        SizedBox(
          height: 1,
          child: Text(
            ' 🌐 termui Dashboard & Window Manager Demo ',
            style: const Style(
              foreground: Colors.white,
              background: Colors.blue,
              modifiers: Modifier.bold,
            ),
          ),
        ),
        Expanded(
          child: example.build(
            focusDemoPane: true,
            width: width,
            height: height - 2,
          ),
        ),
        SizedBox(
          height: 1,
          child: Text(
            ' [Ctrl+C] Exit  [Mouse Click] Focus  [Drag Title] Move Window  [Drag Corner] Resize ',
            style: const Style(
              foreground: Colors.black,
              background: Colors.white,
            ),
          ),
        ),
      ]);

      final elementWrapper = ElementWidget(layout);
      elementWrapper.layout(BoxConstraints.tight(Size(width, height)));
      elementWrapper.paint(buffer, Offset.zero);

      final sb = StringBuffer();
      renderer.render(buffer, sb);
      if (sb.isNotEmpty) {
        terminal.backend.write(sb.toString());
      }
    }

    // Initial frame draw
    drawFrame();

    // Resize listener
    final sizeSubscription = terminal.watchSize().listen((size) {
      width = size.x;
      height = size.y;
      buffer.resize(width, height);
      renderer = Renderer(width, height, mode: RenderingMode.alternateScreen);
      drawFrame();
    });

    // 60FPS tick timer
    final tickTimer = Timer.periodic(const Duration(milliseconds: 16), (timer) {
      example.tick(const Duration(milliseconds: 16));
      drawFrame();
    });

    try {
      // Main event loop
      await for (final event in terminal.events) {
        if (event is term.KeyEvent) {
          if (event.key == 'q' || event.key == 'Q') {
            break;
          }
          example.handleKeyEvent(event);
        } else if (event is term.MouseEvent) {
          // Map mouse event (which is 1-indexed) into viewport coordinate offset
          example.handleMouseEvent(
            event,
            event.x - 1,
            event.y - 2,
            width,
            height - 2,
          );
        }
      }
    } finally {
      tickTimer.cancel();
      sizeSubscription.cancel();
    }
  });

  print('Scenario A Demo exited.');
  exit(0);
}
