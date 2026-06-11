import 'dart:async';
import 'dart:math';
import 'package:termui/terminal/terminal.dart' as term;
import 'package:termui/ui/buffer.dart';
import 'package:termui/ui/style.dart';
import 'package:termui/ui/color.dart';
import 'package:termui/ui/layout.dart';
import 'package:termui/ui/renderer.dart';
import 'package:termui/ui/widget_toolkit.dart';
import 'package:termui/ui/event.dart' as ui;
import 'package:flutter/scheduler.dart';
import 'package:termui/perf/tracer.dart';
import 'package:termui/perf/fs_locator.dart';
import 'package:termui_shared_examples/widget_book/widget_book_examples.dart';
import 'package:termui_flutter/termui_flutter.dart';
import 'dart:io';
import 'package:termui_recorder/termui_recorder.dart';

final int _traceFrameTotalId = Tracer.registerString('Frame:total');
final int _traceFrameBuildId = Tracer.registerString('Frame:buildLayout');
final int _traceFrameRenderId = Tracer.registerString('Frame:renderLayout');
final int _traceFrameOutputId = Tracer.registerString('Frame:outputDelta');

// Pre-define pages for the widget book
enum DemoPage {
  textInputs('Text Inputs'),
  dataDisplays('Data Displays'),
  indicators('Indicators'),
  richTextTimer('Rich Text & Timer'),
  layoutPadding('Layout & Padding'),
  layoutState('Layout & State'),
  charmColors('Charm Colors'),
  forms('Forms & Validation'),
  burgerOrder('Burger Order Form'),
  fileTree('File Tree'),
  splitPane('Split Pane'),
  lazyScrolling('Virtual Scrolling'),
  modalDialog('Modal & Scrollbar'),
  vectorGraphics('Clock & Radar'),
  decoratedWidgets('Decorated Box & Selectors'),
  animations('Animations & Effects'),
  scenarioA('Scenario A: Overlapping Windows'),
  mouseCursors('Mouse Cursors (OSC 22)');

  final String title;
  const DemoPage(this.title);
}

Future<void> runWidgetBook(
  term.Terminal terminal, {
  bool isInline = false,
  void Function(Buffer buffer)? onFrameRedrawn,
}) async {
  await Tracer.initialize();
  final mode = isInline ? RenderingMode.inline : RenderingMode.alternateScreen;

  final termSize = await terminal.size;
  var width = termSize.x;
  var height = isInline
      ? 16
      : termSize.y; // Inline mode uses a fixed height viewport

  final buffer = Buffer.blank(width, height);
  final renderer = Renderer(width, height, mode: mode);

  // Track active page and focus state
  var selectedPage = DemoPage.textInputs;
  var focusDemoPane = false; // true if demo pane is active, false if sidebar
  var showHelpDialog = false;

  AsciicastRecorder? castRecorder;
  StringBuffer? castOutput;
  var isRecordingCast = false;
  var statusMessage = '';
  Timer? statusClearTimer;

  void setStatus(String msg) {
    statusMessage = msg;
    statusClearTimer?.cancel();
    statusClearTimer = Timer(const Duration(seconds: 4), () {
      statusMessage = '';
    });
  }

  // Setup sidebar list widget
  final sidebarList = ListWidget(
    DemoPage.values.map((p) => p.title).toList(),
    selectedIndex: 0,
    selectedStyle: const Style(
      foreground: CharmColors.pepper,
      background: CharmColors.charple,
      modifiers: Modifier.bold,
    ),
  );

  // Setup page examples
  final examples = <DemoPage, WidgetBookExample>{
    DemoPage.textInputs: TextInputsExample(),
    DemoPage.dataDisplays: DataDisplaysExample(),
    DemoPage.indicators: IndicatorsExample(),
    DemoPage.richTextTimer: RichTextTimerExample(),
    DemoPage.layoutPadding: LayoutPaddingExample(),
    DemoPage.layoutState: LayoutStateExample(),
    DemoPage.charmColors: CharmColorsExample(),
    DemoPage.forms: FormsExample(),
    DemoPage.burgerOrder: BurgerOrderExample(),
    DemoPage.fileTree: FileTreeExample(),
    DemoPage.splitPane: SplitPaneExample(),
    DemoPage.lazyScrolling: LazyScrollingExample(),
    DemoPage.modalDialog: ModalDialogExample(),
    DemoPage.vectorGraphics: VectorGraphicsExample(),
    DemoPage.decoratedWidgets: DecoratedWidgetsExample(),
    DemoPage.animations: AnimationsExample(),
    DemoPage.scenarioA: ScenarioAExample(),
    DemoPage.mouseCursors: MouseCursorsExample(),
  };

  for (final example in examples.values) {
    example.attachTerminal(terminal);
    example.init();
  }

  // Hide cursor, enable mouse tracking & switch to alternate screen buffer
  if (!isInline) {
    terminal.enterAlternateScreen();
    terminal.hideCursor();
    terminal.enableMouseTracking();
  }

  // Ticker to drive animations at vsync
  var lastFpsMs = 0;
  var fpsFrameCount = 0;
  var currentFps = 0.0;
  late final Ticker ticker;
  ticker = Ticker((elapsed) {
    Tracer.record(_traceFrameTotalId, Phase.begin);
    try {
      for (final example in examples.values) {
        example.tick(const Duration(milliseconds: 16));
      }

      fpsFrameCount++;
      final currentMs = DateTime.now().millisecondsSinceEpoch;
      if (lastFpsMs == 0) {
        lastFpsMs = currentMs;
      } else if (currentMs - lastFpsMs >= 500) {
        currentFps = fpsFrameCount * 1000 / (currentMs - lastFpsMs);
        fpsFrameCount = 0;
        lastFpsMs = currentMs;
      }

      _drawFrame(
        terminal: terminal,
        buffer: buffer,
        renderer: renderer,
        width: width,
        height: height,
        isInline: isInline,
        selectedPage: selectedPage,
        focusDemoPane: focusDemoPane,
        showHelpDialog: showHelpDialog,
        sidebarList: sidebarList,
        examples: examples,
        currentFps: currentFps,
        onFrameRedrawn: onFrameRedrawn,
        isRecordingCast: isRecordingCast,
        statusMessage: statusMessage,
      );

      if (isRecordingCast && castRecorder != null) {
        castRecorder.recordFrame(buffer);
      }
    } finally {
      Tracer.record(_traceFrameTotalId, Phase.end);
    }
  });
  ticker.start();

  // Listen to sizing changes
  final sizeSubscription = terminal.watchSize().listen((size) {
    width = size.x;
    height = isInline ? 16 : size.y;
    buffer.resize(width, height);
  });

  try {
    // Main event loop
    await for (final event in terminal.events) {
      if (event is ui.KeyEvent &&
          event.modifiers.contains(ui.Modifier.control)) {
        if (terminal is FlutterTerminal) {
          if (event.key == '=' || event.key == '+') {
            terminal.increaseFontSize();
            continue;
          } else if (event.key == '-') {
            terminal.decreaseFontSize();
            continue;
          }
        }
      }

      if (showHelpDialog) {
        showHelpDialog = false;
        continue;
      }

      final activeExample = examples[selectedPage]!;

      // 1. Handle Modal/Overlay events if active
      if (activeExample.hasActiveOverlay) {
        if (event is ui.MouseEvent) {
          activeExample.handleOverlayMouseEvent(
            event,
            event.x - 1,
            event.y - 1,
            width,
            height,
          );
          continue;
        }

        if (event is ui.KeyEvent) {
          activeExample.handleOverlayKeyEvent(event);
        }
        continue;
      }

      // 2. Handle global mouse events
      if (event is ui.MouseEvent) {
        if (event.type == ui.MouseEventType.press && event.y - 1 == 0) {
          final clickX = event.x - 1;
          final headerText = _getHeaderText(
            isInline: isInline,
            width: width,
            height: height,
            currentFps: currentFps,
            isRecordingCast: isRecordingCast,
            statusMessage: statusMessage,
          );

          final castIndex = headerText.indexOf('[Record Cast]');
          final stopCastIndex = headerText.indexOf('[Stop Cast]');

          if (castIndex != -1 &&
              clickX >= castIndex &&
              clickX < castIndex + 13) {
            castOutput = StringBuffer();
            castRecorder = AsciicastRecorder(
              castOutput,
              width: width,
              height: height,
            );
            isRecordingCast = true;
            setStatus('Recording Cast...');
          } else if (stopCastIndex != -1 &&
              clickX >= stopCastIndex &&
              clickX < stopCastIndex + 11) {
            isRecordingCast = false;
            if (castOutput != null) {
              final timestamp = DateTime.now().millisecondsSinceEpoch;
              final filename = 'recording_$timestamp.cast';
              File(filename).writeAsStringSync(castOutput.toString());
              setStatus('Saved to $filename');
            } else {
              setStatus('Recording failed');
            }
            castRecorder = null;
            castOutput = null;
          }
          continue;
        }

        final sidebarWidth = (width * 0.25).round();
        final demoX = sidebarWidth + 2;
        final demoY = 3;
        final demoWidth = width - sidebarWidth - 3;
        final demoHeight = height - 5;
        final localX = event.x - 1 - demoX;
        final localY = event.y - 1 - demoY;

        final isInsideDemo =
            localX >= 0 &&
            localX < demoWidth &&
            localY >= 0 &&
            localY < demoHeight;

        // Handle sidebar click
        final localSidebarX = event.x - 1;
        final localSidebarY = event.y - 1 - 2;
        final isInsideSidebar =
            localSidebarX >= 0 &&
            localSidebarX < sidebarWidth &&
            event.y - 1 >= 2 &&
            event.y - 1 < height - 1;

        if (isInsideSidebar && event.type == ui.MouseEventType.press) {
          focusDemoPane = false;
          final clickedIdx = localSidebarY + sidebarList.scrollOffset;
          if (clickedIdx >= 0 && clickedIdx < DemoPage.values.length) {
            sidebarList.selectedIndex = clickedIdx;
            selectedPage = DemoPage.values[clickedIdx];
            terminal.resetMousePointer(); // Reset cursor shape on page switch
          }
        }

        if (isInsideDemo || activeExample.capturesMouse) {
          activeExample.handleMouseEvent(
            event,
            localX,
            localY,
            demoWidth,
            demoHeight,
          );
        } else {
          terminal
              .resetMousePointer(); // Reset cursor when mouse leaves demo pane
        }
        continue;
      }

      // 3. Handle key events
      final isEditing =
          focusDemoPane &&
          (selectedPage == DemoPage.textInputs ||
              selectedPage == DemoPage.forms ||
              (selectedPage == DemoPage.burgerOrder &&
                  (activeExample as BurgerOrderExample).burgerStage >= 1 &&
                  activeExample.burgerStage <= 3));

      if (!isEditing && (event.key == 'q' || event.key == 'Q')) {
        break;
      }
      if (event.key.length == 1 && event.key.codeUnits[0] == 3) {
        break; // Ctrl+C
      }

      if (!isEditing && (event.key == 't' || event.key == 'T')) {
        if (Tracer.isEnabled) {
          await Tracer.stop();
        } else {
          final fs = getDefaultFileSystem();
          final timestamp = DateTime.now().millisecondsSinceEpoch;
          final tracePath = fs.path.join(
            fs.currentDirectory.path,
            'trace_$timestamp.json',
          );
          await Tracer.start(tracePath, fs: fs);
        }
        continue;
      }

      if (!isEditing &&
          (event.key == 'h' || event.key == 'H' || event.key == '?')) {
        showHelpDialog = true;
        continue;
      }

      if (event is ui.KeyEvent) {
        // Route event depending on focus
        var consumed = false;
        if (focusDemoPane) {
          if (event.type == ui.KeyType.escape) {
            focusDemoPane = false;
            consumed = true;
          } else {
            consumed = activeExample.handleKeyEvent(event);
          }
        }

        if (!consumed) {
          if (event.key == '\t' || event.key == 'backtab') {
            focusDemoPane = !focusDemoPane;
            continue;
          }
          if (event.key == 'escape') {
            focusDemoPane = false;
            continue;
          }

          if (!focusDemoPane) {
            // Sidebar is focused: Up/Down selects pages
            if (event.type == ui.KeyType.up) {
              sidebarList.selectedIndex = (sidebarList.selectedIndex - 1).clamp(
                0,
                DemoPage.values.length - 1,
              );
            } else if (event.type == ui.KeyType.down) {
              sidebarList.selectedIndex = (sidebarList.selectedIndex + 1).clamp(
                0,
                DemoPage.values.length - 1,
              );
            }
            final newPage = DemoPage.values[sidebarList.selectedIndex];
            if (newPage != selectedPage) {
              selectedPage = newPage;
              terminal.resetMousePointer(); // Reset cursor shape on page switch
            }
          }
        }
      }
    }
  } finally {
    ticker.dispose();
    sizeSubscription.cancel();
    statusClearTimer?.cancel();

    if (isRecordingCast && castOutput != null) {
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      File(
        'recording_$timestamp.cast',
      ).writeAsStringSync(castOutput.toString());
    }

    if (!isInline) {
      terminal.showCursor();
      terminal.disableMouseTracking();
      terminal.exitAlternateScreen();
      terminal.resetStyle();
    }
  }
}

// Draw frame layout structure
void _drawFrame({
  required term.Terminal terminal,
  required Buffer buffer,
  required Renderer renderer,
  required int width,
  required int height,
  required bool isInline,
  required DemoPage selectedPage,
  required bool focusDemoPane,
  required bool showHelpDialog,
  required ListWidget sidebarList,
  required Map<DemoPage, WidgetBookExample> examples,
  double currentFps = 0.0,
  void Function(Buffer buffer)? onFrameRedrawn,
  bool isRecordingCast = false,
  String statusMessage = '',
}) {
  buffer.clear();

  final activeExample = examples[selectedPage]!;
  final showModalDemo = activeExample.hasActiveOverlay;

  Tracer.record(_traceFrameBuildId, Phase.begin);
  // Create layout tree
  final appLayout = Column([
    // Header
    SizedBox(
      height: 1,
      child: Text(
        _getHeaderText(
          isInline: isInline,
          width: width,
          height: height,
          currentFps: currentFps,
          isRecordingCast: isRecordingCast,
          statusMessage: statusMessage,
        ),
        style: const Style(
          foreground: CharmColors.pepper,
          background: CharmColors.soda,
          modifiers: Modifier.bold,
        ),
      ),
    ),
    // Middle panel: Sidebar | Content pane
    Expanded(
      child: Row([
        // Sidebar (Width: 25%)
        Flexible(
          flex: 25,
          child: Column([
            SizedBox(
              height: 1,
              child: Text(
                ' COMPONENTS ',
                style: Style(
                  foreground: CharmColors.soda,
                  modifiers: focusDemoPane ? Modifier.dim : Modifier.bold,
                ),
              ),
            ),
            Expanded(child: sidebarList),
          ]),
        ),
        // Separator vertical border line
        SizedBox(
          width: 1,
          child: Grid(
            List.generate(
              max(0, height - 3),
              (_) => [Cell('│', const Style(modifiers: Modifier.dim))],
            ),
          ),
        ),
        // Content Pane (Flex: 1)
        Expanded(
          flex: 74,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 1),
            child: Column([
              // Active Page Title
              SizedBox(
                height: 1,
                child: Text(
                  '${selectedPage.title} Preview ${focusDemoPane ? "[ACTIVE]" : ""} ${Tracer.isEnabled ? "🔴 [TRACING]" : ""}',
                  style: const Style(
                    foreground: CharmColors.charple,
                    modifiers: Modifier.bold,
                  ),
                ),
              ),
              const SizedBox(height: 1, child: Text('')), // spacer
              // Dynamic Demo Component
              Expanded(
                child: activeExample.build(
                  focusDemoPane: focusDemoPane,
                  width: width - (width * 0.25).round() - 3,
                  height: height - 5,
                ),
              ),
            ]),
          ),
        ),
      ]),
    ),
    // Footer Help Bar
    SizedBox(
      height: 1,
      child: Help(
        bindings: focusDemoPane
            ? {
                ...activeExample.helpBindings,
                if (!activeExample.helpBindings.containsKey('Tab'))
                  'Tab': 'Sidebar',
                'Esc': 'Defocus',
                'T': Tracer.isEnabled ? 'Stop Tracing' : 'Start Tracing',
                if (selectedPage != DemoPage.textInputs)
                  'H/?': 'Shortcuts Help',
                'Q': 'Quit',
              }
            : {
                'Tab': 'Focus Preview',
                'Up/Down': 'Navigate',
                'T': Tracer.isEnabled ? 'Stop Tracing' : 'Start Tracing',
                'H/?': 'Shortcuts Help',
                'Q': 'Quit',
              },
        keyStyle: const Style(
          foreground: CharmColors.julep,
          modifiers: Modifier.bold,
        ),
      ),
    ),
  ]);
  Tracer.record(_traceFrameBuildId, Phase.end);

  Tracer.record(_traceFrameRenderId, Phase.begin);
  // Render layout and output delta sequence
  appLayout.render(buffer, Rect(0, 0, width, height));

  if (showModalDemo) {
    activeExample.renderOverlay(buffer, width, height);
  }

  if (showHelpDialog) {
    final dialogWidth = 62;
    final dialogHeight = 16;
    final startX = (width - dialogWidth) ~/ 2;
    final startY = (height - dialogHeight) ~/ 2;

    final borderStyle = const Style(
      foreground: CharmColors.julep,
      background: CharmColors.bbq,
    );
    final titleStyle = const Style(
      foreground: CharmColors.soda,
      background: CharmColors.charple,
      modifiers: Modifier.bold,
    );
    final keyStyle = const Style(
      foreground: CharmColors.tang,
      background: CharmColors.bbq,
      modifiers: Modifier.bold,
    );
    final descStyle = const Style(
      foreground: CharmColors.soda,
      background: CharmColors.bbq,
    );
    final hintStyle = const Style(
      foreground: CharmColors.squid,
      background: CharmColors.bbq,
      modifiers: Modifier.italic,
    );

    // Draw top border
    buffer.writeString(
      startX,
      startY,
      '┌${'─' * (dialogWidth - 2)}┐',
      borderStyle,
    );

    // Draw title
    final titleText = ' ADVANCED EDITING SHORTCUTS ';
    final titleX = startX + (dialogWidth - titleText.length) ~/ 2;
    buffer.writeString(titleX, startY, titleText, titleStyle);

    final lines = [
      ('Ctrl + Left Arrow', 'Move back one word'),
      ('Ctrl + Right Arrow', 'Move forward one word'),
      ('Home / Ctrl+Shift+Left', 'Move to start of line'),
      ('End / Ctrl+Shift+Right', 'Move to end of line'),
      ('Ctrl + W', 'Delete word backward'),
      ('Ctrl + Delete / Ctrl + D', 'Delete word forward'),
      ('Ctrl + K', 'Delete cursor to end of line'),
      ('Ctrl + Backspace', 'Delete cursor to start of line'),
      ('Ctrl + Z / Alt + Z', 'Undo last operation'),
      ('Ctrl + Y / Alt + Y', 'Redo last operation'),
    ];

    for (var i = 0; i < dialogHeight - 2; i++) {
      final y = startY + 1 + i;
      buffer.writeString(
        startX,
        y,
        '│${' ' * (dialogWidth - 2)}│',
        borderStyle,
      );

      if (i > 0 && i - 1 < lines.length) {
        final item = lines[i - 1];
        buffer.writeString(startX + 3, y, item.$1, keyStyle);
        buffer.writeString(startX + 28, y, ': ${item.$2}', descStyle);
      } else if (i == dialogHeight - 3) {
        final closeText = ' Press any key to close ';
        final closeX = startX + (dialogWidth - closeText.length) ~/ 2;
        buffer.writeString(closeX, y, closeText, hintStyle);
      }
    }

    // Draw bottom border
    buffer.writeString(
      startX,
      startY + dialogHeight - 1,
      '└${'─' * (dialogWidth - 2)}┘',
      borderStyle,
    );
  }
  Tracer.record(_traceFrameRenderId, Phase.end);

  Tracer.record(_traceFrameOutputId, Phase.begin);
  if (onFrameRedrawn != null) {
    onFrameRedrawn(buffer);
  } else {
    final sb = StringBuffer();
    renderer.render(buffer, sb);
    if (sb.isNotEmpty) {
      terminal.backend.write(sb.toString());
    }
  }
  Tracer.record(_traceFrameOutputId, Phase.end);
}

String _getHeaderText({
  required bool isInline,
  required int width,
  required int height,
  required double currentFps,
  required bool isRecordingCast,
  required String statusMessage,
}) {
  final prefix = isInline
      ? ' 📖 Widget Book Demo (Inline) [Size: ${width}x$height] [FPS: ${currentFps.toStringAsFixed(1)}]'
      : ' 📖 Widget Book Demo (Alt) [Size: ${width}x$height] [FPS: ${currentFps.toStringAsFixed(1)}]';

  final castBtnText = isRecordingCast ? '🔴 [Stop Cast]' : '⏺ [Record Cast]';
  final status = statusMessage.isNotEmpty ? '  [$statusMessage]' : '';

  return '$prefix  $castBtnText$status';
}
