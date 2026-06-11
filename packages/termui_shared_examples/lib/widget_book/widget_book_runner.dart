import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:termui/terminal/terminal.dart' as term;
import 'package:termui/ui/buffer.dart';
import 'package:termui/ui/style.dart';
import 'package:termui/ui/color.dart';
import 'package:termui/ui/layout.dart';
import 'package:termui/ui/renderer.dart';
import 'package:termui/ui/widget_toolkit.dart';
import 'package:termui/ui/event.dart' as ui;
import 'package:termui/perf/tracer.dart';
import 'package:termui/perf/fs_locator.dart';
import 'package:termui_shared_examples/widget_book/widget_book_examples.dart';
import 'package:termui_recorder/termui_recorder.dart';

final int _traceFrameTotalId = Tracer.registerString('Frame:total');
final int _traceFrameBuildId = Tracer.registerString('Frame:buildLayout');
final int _traceFrameRenderId = Tracer.registerString('Frame:renderLayout');
final int _traceFrameOutputId = Tracer.registerString('Frame:outputDelta');

/// Pre-defined pages for the shared widget book.
enum DemoPage {
  /// Single and multi-line text input fields.
  textInputs('Text Inputs'),

  /// Labels, lists, and formatted data tables.
  dataDisplays('Data Displays'),

  /// Progress bars and loading spinners.
  indicators('Indicators'),

  /// Interactive styled text and time trackers.
  richTextTimer('Rich Text & Timer'),

  /// Layout nesting and padding constraints.
  layoutPadding('Layout & Padding'),

  /// Interactive state rendering and variables.
  layoutState('Layout & State'),

  /// Available color palette swatch blocks.
  charmColors('Charm Colors'),

  /// Form inputs with navigation and validation.
  forms('Forms & Validation'),

  /// Multi-stage burger ordering form wizard.
  burgerOrder('Burger Order Form'),

  /// Expandable/collapsible file tree browser.
  fileTree('File Tree'),

  /// Bounded vertical/horizontal split pane views.
  splitPane('Split Pane'),

  /// Viewport-clamped virtual list scrolling.
  lazyScrolling('Virtual Scrolling'),

  /// Floating overlay modal dialogues and scrollbars.
  modalDialog('Modal & Scrollbar'),

  /// Sub-pixel rendering and trigonometric shape transforms.
  vectorGraphics('Clock & Radar'),

  /// Decorated boxes and list selectors.
  decoratedWidgets('Decorated Box & Selectors'),

  /// Animated progress bar transitions.
  animations('Animations & Effects'),

  /// Overlapping draggable floating windows.
  scenarioA('Scenario A: Overlapping Windows'),

  /// Dynamic cursor styling protocol tests.
  mouseCursors('Mouse Cursors (OSC 22)');

  /// Display title of the demo page.
  final String title;

  /// Creates a [DemoPage].
  const DemoPage(this.title);
}

/// The shared entrypoint that coordinates terminal/platform events and drives frames.
Future<void> runWidgetBookShared(
  term.Terminal terminal,
  WidgetBookPlatform platform, {
  bool isInline = false,
}) async {
  await Tracer.initialize();
  final mode = isInline ? RenderingMode.inline : RenderingMode.alternateScreen;

  final termSize = await terminal.size;
  var width = termSize.x;
  var height = isInline ? 16 : termSize.y;

  final buffer = Buffer.blank(width, height);
  final renderer = Renderer(width, height, mode: mode);

  var selectedPage = DemoPage.textInputs;
  var focusDemoPane = false;
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

  // Sidebar navigation
  final sidebarList = ListWidget(
    DemoPage.values.map((p) => p.title).toList(),
    selectedIndex: 0,
    selectedStyle: const Style(
      foreground: CharmColors.pepper,
      background: CharmColors.charple,
      modifiers: Modifier.bold,
    ),
  );

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

  if (!isInline) {
    terminal.enterAlternateScreen();
    terminal.hideCursor();
    terminal.enableMouseTracking();
  }

  var lastFpsMs = 0;
  var fpsFrameCount = 0;
  var currentFps = 0.0;

  platform.startTicker((elapsed) {
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
        platform: platform,
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

  final sizeSubscription = terminal.watchSize().listen((size) {
    width = size.x;
    height = isInline ? 16 : size.y;
    buffer.resize(width, height);
  });

  try {
    await for (final event in terminal.events) {
      if (event is ui.KeyEvent && platform.handleKeyEvent(terminal, event)) {
        continue;
      }

      if (showHelpDialog) {
        showHelpDialog = false;
        continue;
      }

      final activeExample = examples[selectedPage]!;
      if (activeExample.hasActiveOverlay) {
        if (event is ui.KeyEvent) {
          activeExample.handleOverlayKeyEvent(event);
        } else if (event is ui.MouseEvent) {
          activeExample.handleOverlayMouseEvent(
            event,
            event.x,
            event.y,
            width,
            height,
          );
        }
        continue;
      }

      if (event is ui.KeyEvent) {
        if (event.type == ui.KeyType.character && event.key == 'q') {
          break;
        }

        if (event.type == ui.KeyType.character &&
            (event.key == 'h' || event.key == '?')) {
          showHelpDialog = true;
          continue;
        }

        if (event.type == ui.KeyType.character && event.key == 't') {
          if (Tracer.isEnabled) {
            await Tracer.stop();
            setStatus('Tracing stopped');
          } else {
            final fs = getDefaultFileSystem();
            final timestamp = DateTime.now().millisecondsSinceEpoch;
            final tracePath = fs.path.join(
              fs.currentDirectory.path,
              'trace_$timestamp.json',
            );
            await Tracer.start(tracePath, fs: fs);
            setStatus('Tracing started: $tracePath');
          }
          continue;
        }

        if (focusDemoPane) {
          if (event.type == ui.KeyType.escape) {
            focusDemoPane = false;
            continue;
          }

          final consumed = activeExample.handleKeyEvent(event);
          if (consumed) continue;

          if (event.type == ui.KeyType.tab &&
              !event.modifiers.contains(ui.Modifier.shift)) {
            focusDemoPane = false;
            continue;
          }
        } else {
          if (event.type == ui.KeyType.tab &&
              !event.modifiers.contains(ui.Modifier.shift)) {
            focusDemoPane = true;
            continue;
          }
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
            terminal.resetMousePointer();
          }
        }
      } else if (event is ui.MouseEvent) {
        final sidebarWidth = (width * 0.25).round();
        final contentStartX = sidebarWidth + 2;
        final contentWidth = width - contentStartX - 1;
        final contentStartY = 2;
        final contentHeight = height - 5;

        final inSidebar =
            event.x < sidebarWidth && event.y > 0 && event.y < height - 1;
        final inContent =
            event.x >= contentStartX &&
            event.x < contentStartX + contentWidth &&
            event.y >= contentStartY &&
            event.y < contentStartY + contentHeight;

        if (inSidebar) {
          focusDemoPane = false;
          final relativeY = event.y - 1;
          if (relativeY >= 0 && relativeY < sidebarList.items.length) {
            sidebarList.selectedIndex = relativeY;
            final newPage = DemoPage.values[sidebarList.selectedIndex];
            if (newPage != selectedPage) {
              selectedPage = newPage;
              terminal.resetMousePointer();
            }
          }
        } else if (inContent || activeExample.capturesMouse) {
          focusDemoPane = true;
          final localX = event.x - contentStartX;
          final localY = event.y - contentStartY;
          activeExample.handleMouseEvent(
            event,
            localX,
            localY,
            contentWidth,
            contentHeight,
          );
        }

        final castBtnX =
            _getHeaderText(
              isInline: isInline,
              width: width,
              height: height,
              currentFps: currentFps,
              isRecordingCast: isRecordingCast,
              statusMessage: statusMessage,
            ).indexOf('⏺') -
            1;

        if (event.y == 0 && event.x >= castBtnX && event.x < castBtnX + 16) {
          if (event.type == ui.MouseEventType.press) {
            if (isRecordingCast) {
              isRecordingCast = false;
              if (castRecorder != null) {
                final timestamp = DateTime.now().millisecondsSinceEpoch;
                final file = File('recording_$timestamp.cast');
                file.writeAsStringSync(castOutput!.toString());
                setStatus('Asciicast saved to ${file.path}');
                castRecorder = null;
                castOutput = null;
              }
            } else {
              isRecordingCast = true;
              castOutput = StringBuffer();
              castRecorder = AsciicastRecorder(
                castOutput,
                width: width,
                height: height,
              );
              setStatus('Recording asciicast...');
            }
          }
        }
      }
    }
  } finally {
    platform.stopTicker();
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
    platform.onExit();
  }
}

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
  required WidgetBookPlatform platform,
  bool isRecordingCast = false,
  String statusMessage = '',
}) {
  buffer.clear();

  final activeExample = examples[selectedPage]!;
  final showModalDemo = activeExample.hasActiveOverlay;

  Tracer.record(_traceFrameBuildId, Phase.begin);
  final appLayout = Column([
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
    Expanded(
      child: Row([
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
        SizedBox(
          width: 1,
          child: Grid(
            List.generate(
              max(0, height - 3),
              (_) => [Cell('│', const Style(modifiers: Modifier.dim))],
            ),
          ),
        ),
        Expanded(
          flex: 74,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 1),
            child: Column([
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
              const SizedBox(height: 1, child: Text('')),
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

    buffer.writeString(
      startX,
      startY,
      '┌${'─' * (dialogWidth - 2)}┐',
      borderStyle,
    );

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

    buffer.writeString(
      startX,
      startY + dialogHeight - 1,
      '└${'─' * (dialogWidth - 2)}┘',
      borderStyle,
    );
  }
  Tracer.record(_traceFrameRenderId, Phase.end);

  Tracer.record(_traceFrameOutputId, Phase.begin);
  platform.onFrameRedrawn(buffer);

  // Also render output delta sequence if running on CLI platform (which sets onFrameRedrawn as a no-op)
  if (platform.shouldRenderToTerminal) {
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
