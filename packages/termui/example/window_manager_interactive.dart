import 'dart:async';
import 'dart:io';
import 'package:termui/terminal/terminal.dart' as term;
import 'package:termui/ui/buffer.dart';
import 'package:termui/ui/style.dart';
import 'package:termui/ui/color.dart';
import 'package:termui/ui/layout.dart';
import 'package:termui/ui/renderer.dart';
import 'package:termui/ui/window.dart';
import 'package:termui/ui/widget_toolkit.dart';
import 'package:termui/ui/event.dart' as ui;
import 'package:termui_shared_examples/window_manager_demo/window_manager_demo_widgets.dart';

void main() async {
  // Enter Raw Mode and initialize terminal size
  final terminal = term.Terminal();
  final termSize = await terminal.size;
  final width = termSize.x;
  final height = termSize.y;

  final screenBuffer = Buffer.blank(width, height);
  final renderer = Renderer(width, height);
  final windowManager = WindowManager();

  int currentDelayMs = 30;

  // FPS tracking variables
  int frameCount = 0;
  double fps = 0.0;
  var lastFpsTime = DateTime.now();

  // Hide cursor, enable mouse capture
  terminal.hideCursor();
  terminal.enableMouseTracking();

  // Create widgets
  final infoWidget = InfoWidget();
  final mouseTrackerWidget = MouseTrackerWidget();

  final listWidget = ListView.fromStrings(
    ['Option A', 'Option B', 'Option C', 'Option D', 'Option E'],
    selectedStyle: const Style(
      foreground: Colors.white,
      background: Colors.blue,
      modifiers: Modifier.bold,
    ),
  );

  final textInput = TextField(
    placeholder: 'Type something...',
    style: const Style(foreground: Colors.white),
    cursorStyle: const Style(
      foreground: Colors.black,
      background: Colors.white,
    ),
    multiline: false,
  );

  // Setup Windows
  final win1 = Window(
    title: 'Info Window',
    bounds: const Rect(2, 2, 35, 10),
    zIndex: 1,
    borderStyle: const Style(foreground: Colors.orange),
    titleStyle: const Style(modifiers: Modifier.bold),
    child: infoWidget,
    onKeyEvent: (event) {
      infoWidget.keys.add(event.key);
      if (infoWidget.keys.length > 5) {
        infoWidget.keys.removeAt(0);
      }
    },
  );

  final win2 = Window(
    title: 'Interactive Window',
    bounds: const Rect(32, 4, 42, 14),
    zIndex: 2,
    borderStyle: const Style(foreground: Colors.green),
    titleStyle: const Style(modifiers: Modifier.bold),
    child: Column([
      SizedBox(
        height: 1,
        child: Text(
          'Select option (Arrow keys):',
          style: const Style(modifiers: Modifier.bold),
        ),
      ),
      Expanded(child: listWidget),
      SizedBox(
        height: 1,
        child: Text(
          'Input Field:',
          style: const Style(modifiers: Modifier.bold),
        ),
      ),
      SizedBox(height: 1, child: textInput),
    ]),
    onKeyEvent: (event) {
      textInput.handleKeyEvent(event);
      if (event.type == ui.KeyType.up) {
        listWidget.selectedIndex--;
      } else if (event.type == ui.KeyType.down) {
        listWidget.selectedIndex++;
      }
    },
  );

  final win3 = Window(
    title: 'Mouse Tracker',
    bounds: const Rect(2, 13, 29, 9),
    zIndex: 3,
    borderStyle: const Style(foreground: Color(0, 255, 255)),
    titleStyle: const Style(modifiers: Modifier.bold),
    child: mouseTrackerWidget,
  );

  late final Window win4;
  final sizeWidget = SizeWidget(() => win4);
  win4 = Window(
    title: 'Resizable Window',
    bounds: const Rect(35, 15, 36, 8),
    zIndex: 4,
    borderChars: ['┌', '─', '┐', '│', ' ', '│', '╚', '─', '╝'],
    borderStyle: const Style(foreground: Colors.red),
    titleStyle: const Style(modifiers: Modifier.bold),
    child: sizeWidget,
  );

  final brailleWidget = BrailleCanvasWidget();
  final win5 = Window(
    title: 'Braille Canvas',
    bounds: const Rect(15, 8, 40, 12),
    zIndex: 5,
    borderChars: ['┌', '─', '┐', '│', ' ', '│', '╚', '─', '╝'],
    borderStyle: const Style(foreground: Color(255, 0, 255)),
    titleStyle: const Style(modifiers: Modifier.bold),
    child: brailleWidget,
  );

  late final Window win6;
  late final void Function() startTimer;

  final speedSelector = NumberSelector(
    label: 'Delay',
    value: currentDelayMs,
    min: 5,
    max: 200,
    onChanged: (newVal) {
      currentDelayMs = newVal;
      startTimer();
    },
  );

  win6 = Window(
    title: 'Delay Control',
    bounds: Rect(2, height - 4, 29, 3),
    zIndex: 6,
    borderStyle: const Style(foreground: Colors.blue),
    titleStyle: const Style(modifiers: Modifier.bold),
    child: speedSelector,
    onMouseEvent: (event, localX, localY) {
      speedSelector.handleMouseEvent(event, localX - 1, localY - 1);
    },
  );

  windowManager.addWindow(win1);
  windowManager.addWindow(win2);
  windowManager.addWindow(win3);
  windowManager.addWindow(win4);
  windowManager.addWindow(win5);
  windowManager.addWindow(win6);

  // Initial focus
  win2.focusNode.requestFocus();

  String previousHover = 'Background';

  void drawFrame() {
    frameCount++;
    final now = DateTime.now();
    final elapsed = now.difference(lastFpsTime).inMilliseconds;
    if (elapsed >= 1000) {
      fps = (frameCount * 1000) / elapsed;
      frameCount = 0;
      lastFpsTime = now;
    }

    screenBuffer.clear();
    // Fill background with a checkered pattern
    screenBuffer.fill(Cell('░', const Style(foreground: Color(100, 100, 100))));

    // Render all windows in order of Z-index
    final sortedWins = List<Window>.from(windowManager.windows)
      ..sort((a, b) => a.zIndex.compareTo(b.zIndex));

    for (final win in sortedWins) {
      final winElement = win.createElement()..mount(null);
      winElement.layout(BoxConstraints.tight(Size(width, height)));
      winElement.paint(screenBuffer, Offset.zero);
    }

    // Top status bar
    screenBuffer.writeString(
      0,
      0,
      ' Overlapping Windows TUI Manager | Click to Focus | Press Q to Exit '
          .padRight(width),
      const Style(
        foreground: Colors.black,
        background: Colors.white,
        modifiers: Modifier.bold,
      ),
    );

    // Bottom status bar
    final fpsStr = 'FPS: ${fps.toStringAsFixed(1)}';
    final delayStr = 'Delay: ${currentDelayMs}ms';
    final bottomText =
        ' Click Delay Control < / > to change speed | $fpsStr | $delayStr ';
    screenBuffer.writeString(
      0,
      height - 1,
      bottomText.padRight(width).substring(0, width),
      const Style(
        foreground: Colors.black,
        background: Colors.white,
        modifiers: Modifier.bold,
      ),
    );

    final sb = StringBuffer();
    renderer.render(screenBuffer, sb);
    stdout.write(sb.toString());
  }

  // Draw initial frame
  drawFrame();

  // Listen to terminal inputs in a try-finally block to guarantee raw mode is disabled on exit
  Timer? animationTimer;

  startTimer = () {
    animationTimer?.cancel();
    animationTimer = Timer.periodic(Duration(milliseconds: currentDelayMs), (
      timer,
    ) {
      brailleWidget.frame++;
      drawFrame();
    });
  };

  try {
    startTimer();

    await for (final event in terminal.events) {
      // Check exit: Q or Ctrl+C (char code 3). Q only exits if Win2 is not focused.
      final isWin2Focused = win2.focusNode.isFocused;
      if (((event.key == 'q' || event.key == 'Q') && !isWin2Focused) ||
          (event.key.length == 1 && event.key.codeUnits[0] == 3)) {
        break;
      }

      // Route event
      if (event is ui.MouseEvent) {
        final win = windowManager.findWindowAt(event.x - 1, event.y - 1);
        final currentHover = win?.title ?? 'Background';
        if (currentHover != previousHover) {
          mouseTrackerWidget.lastTransition =
              'Exit $previousHover -> Enter $currentHover';
          previousHover = currentHover;
        }
        mouseTrackerWidget.mouseX = event.x;
        mouseTrackerWidget.mouseY = event.y;
        mouseTrackerWidget.hoverWindow = currentHover;
        mouseTrackerWidget.lastEvent =
            'Button:${event.button} (${event.pressed ? "Down" : "Up"})';

        windowManager.handleMouseEvent(event);
      } else if (event is ui.KeyEvent) {
        windowManager.handleKeyEvent(event);
      }

      infoWidget.focusedWindow =
          windowManager.rootFocusNode.findFocusedLeaf()?.id ?? 'None';
    }
  } finally {
    animationTimer?.cancel();
    // Restore terminal state before exit
    terminal.showCursor();
    terminal.disableMouseTracking();
    terminal.resetStyle();
    terminal.dispose();
    terminal.clear();
    terminal.home();
    print('Exited cleanly.');
    exit(0);
  }
}
