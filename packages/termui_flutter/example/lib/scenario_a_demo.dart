import 'dart:async';
import 'package:flutter/scheduler.dart';
import 'package:termui/terminal/terminal.dart' as term;
import 'package:termui/ui/buffer.dart';
import 'package:termui/ui/layout.dart';
import 'package:termui/ui/widget_toolkit.dart';
import 'package:termui/ui/style.dart';
import 'package:termui/ui/color.dart';
import 'package:termui_shared_examples/widget_book/scenario_a.dart';

Future<void> runScenarioADemo(
  term.Terminal terminal, {
  void Function(Buffer buffer)? onFrameRedrawn,
}) async {
  final termSize = await terminal.size;
  var width = termSize.x;
  var height = termSize.y;

  final screenBuffer = Buffer.blank(width, height);

  // Instantiate ScenarioAExample
  final example = ScenarioAExample();
  example.init();

  void drawFrame() {
    screenBuffer.clear();

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

    layout.render(screenBuffer, Rect(0, 0, width, height));

    if (onFrameRedrawn != null) {
      onFrameRedrawn(screenBuffer);
    }
  }

  // Initial frame draw
  drawFrame();

  // Resize listener
  final sizeSubscription = terminal.watchSize().listen((size) {
    width = size.x;
    height = size.y;
    screenBuffer.resize(width, height);
    drawFrame();
  });

  // Ticker to tick physics/animations in Flutter vsync
  late final Ticker ticker;
  ticker = Ticker((elapsed) {
    example.tick(const Duration(milliseconds: 16));
    drawFrame();
  });
  ticker.start();

  try {
    // Main event loop
    await for (final event in terminal.events) {
      if (event is term.KeyEvent) {
        if (event.key == 'q' ||
            event.key == 'Q' ||
            (event.key.length == 1 && event.key.codeUnits[0] == 3)) {
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
    ticker.dispose();
    sizeSubscription.cancel();
  }
}
