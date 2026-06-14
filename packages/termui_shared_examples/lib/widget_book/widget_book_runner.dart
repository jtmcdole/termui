import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:termui/terminal/terminal.dart' as term;
import 'package:termui/ui/buffer.dart';
import 'package:termui/ui/style.dart';
import 'package:termui/ui/color.dart';
import 'package:termui/ui/layout.dart';
import 'package:termui/ui/widget_toolkit.dart';
import 'package:termui/ui/event.dart' hide Modifier;
import 'package:termui/ui/window.dart';
import 'package:termui/perf/tracer.dart';
import 'package:termui/perf/fs_locator.dart';
import 'package:termui_shared_examples/widget_book/widget_book_examples.dart';
import 'package:termui_recorder/termui_recorder.dart';

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

  if (!isInline) {
    terminal.enterAlternateScreen();
    terminal.hideCursor();
    terminal.enableMouseTracking();
  }

  final appKey = GlobalKey<_WidgetBookAppState>();

  final runner = PromptRunner<void>(
    terminal: terminal,
    widget: WidgetBookApp(
      key: appKey,
      terminal: terminal,
      platform: platform,
      isInline: isInline,
    ),
    alternateScreen: !isInline,
    onFramePainted: (buf) {
      final state = appKey.currentState;
      if (state != null) {
        final activeExample = state.examples[state._selectedPage]!;
        if (activeExample.hasActiveOverlay) {
          activeExample.renderOverlay(buf, buf.width, buf.height);
        }
      }
      platform.onFrameRedrawn(buf);
      state?.recordFrame(buf);
    },
  );

  try {
    await runner.run();
  } on PromptAbortedException catch (e) {
    if (e.trigger != PromptExitTrigger.controlC) {
      rethrow;
    }
  } finally {
    if (!isInline) {
      terminal.showCursor();
      terminal.disableMouseTracking();
      terminal.exitAlternateScreen();
      terminal.resetStyle();
    }
    platform.onExit();
  }
}

/// The main widget for the Widget Book application.
class WidgetBookApp extends StatefulWidget {
  /// The terminal instance.
  final term.Terminal terminal;

  /// The active widget book platform controls.
  final WidgetBookPlatform platform;

  /// Whether the widget book is rendered inline.
  final bool isInline;

  /// Creates a [WidgetBookApp] widget.
  const WidgetBookApp({
    super.key,
    required this.terminal,
    required this.platform,
    required this.isInline,
  });

  @override
  State<WidgetBookApp> createState() => _WidgetBookAppState();
}

class _WidgetBookAppState extends State<WidgetBookApp> {
  late final FocusScopeNode _rootScopeNode = FocusScopeNode(id: 'root_scope');
  late final FocusNode _sidebarFocusNode = FocusNode(id: 'sidebar');
  late final FocusScopeNode _previewFocusNode = FocusScopeNode(id: 'preview');
  final _previewPaneKey = GlobalKey();
  bool _tickerRunning = false;

  DemoPage _selectedPage = DemoPage.textInputs;
  int _selectedPageIdx = 0;
  int? _hoveredPageIdx;
  bool _focusDemoPane = false;
  bool _showHelpDialog = false;
  String _statusMessage = '';

  AsciicastRecorder? castRecorder;
  StringBuffer? castOutput;
  bool _isRecordingCast = false;

  Timer? _statusClearTimer;
  double _currentFps = 0.0;
  int fpsFrameCount = 0;
  int lastFpsMs = 0;

  final Map<DemoPage, WidgetBookExample> examples = {
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

  @override
  void initState() {
    super.initState();

    for (final example in examples.values) {
      example.attachTerminal(widget.terminal);
      example.init();
    }

    _rootScopeNode.addChild(_sidebarFocusNode);
    _rootScopeNode.addChild(_previewFocusNode);

    _updateTickerState();
  }

  void _onTick(Duration elapsed) {
    if (!mounted) return;

    var needsRepaint = false;
    final activeExample = examples[_selectedPage];
    if (activeExample != null) {
      needsRepaint = activeExample.tick(const Duration(milliseconds: 16));
    }

    fpsFrameCount++;
    final currentMs = DateTime.now().millisecondsSinceEpoch;
    if (lastFpsMs == 0) {
      lastFpsMs = currentMs;
    } else if (currentMs - lastFpsMs >= 500) {
      setState(() {
        _currentFps = fpsFrameCount * 1000 / (currentMs - lastFpsMs);
      });
      fpsFrameCount = 0;
      lastFpsMs = currentMs;
    } else {
      if (needsRepaint) {
        final previewElement = _previewPaneKey.currentContext as Element?;
        if (previewElement != null) {
          BuildOwner.markNeedsBuild(previewElement);
          if (State.onNeedRepaint != null) {
            State.onNeedRepaint!();
          }
        }
      }
    }
  }

  void _updateTickerState() {
    final activeExample = examples[_selectedPage];
    final needsTick = activeExample != null && activeExample.requiresTick;

    if (needsTick && !_tickerRunning) {
      _tickerRunning = true;
      fpsFrameCount = 0;
      lastFpsMs = 0;
      widget.platform.startTicker(_onTick);
    } else if (!needsTick && _tickerRunning) {
      _tickerRunning = false;
      widget.platform.stopTicker();
    }
  }

  @override
  void dispose() {
    if (_tickerRunning) {
      widget.platform.stopTicker();
    }
    _statusClearTimer?.cancel();
    _sidebarFocusNode.dispose();
    _previewFocusNode.dispose();
    _rootScopeNode.dispose();

    if (_isRecordingCast && castOutput != null) {
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      File(
        'recording_$timestamp.cast',
      ).writeAsStringSync(castOutput!.toString());
    }

    super.dispose();
  }

  void _setStatus(String msg) {
    setState(() {
      _statusMessage = msg;
    });
    _statusClearTimer?.cancel();
    _statusClearTimer = Timer(const Duration(seconds: 4), () {
      if (mounted) {
        setState(() {
          _statusMessage = '';
        });
      }
    });
  }

  void _toggleRecording() {
    if (_isRecordingCast) {
      _isRecordingCast = false;
      if (castRecorder != null) {
        final timestamp = DateTime.now().millisecondsSinceEpoch;
        final file = File('recording_$timestamp.cast');
        file.writeAsStringSync(castOutput!.toString());
        _setStatus('Asciicast saved to ${file.path}');
        castRecorder = null;
        castOutput = null;
      }
    } else {
      _isRecordingCast = true;
      castOutput = StringBuffer();
      final element = context as Element;
      final w = element.size.width;
      final h = element.size.height;
      castRecorder = AsciicastRecorder(castOutput!, width: w, height: h);
      _setStatus('Recording asciicast...');
    }
  }

  void recordFrame(Buffer buffer) {
    if (_isRecordingCast && castRecorder != null) {
      castRecorder!.recordFrame(buffer);
    }
  }

  Future<void> _toggleTracing() async {
    if (Tracer.isEnabled) {
      await Tracer.stop();
      _setStatus('Tracing stopped');
    } else {
      final fs = getDefaultFileSystem();
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final tracePath = fs.path.join(
        fs.currentDirectory.path,
        'trace_$timestamp.json',
      );
      await Tracer.start(tracePath, fs: fs);
      _setStatus('Tracing started: $tracePath');
    }
  }

  void handleMouseEvent(term.MouseEvent event, int localX, int localY) {
    if (_hoveredPageIdx != null) {
      setState(() {
        _hoveredPageIdx = null;
      });
    }
    final activeExample = examples[_selectedPage]!;
    final element = context as Element;
    final w = element.size.width;
    final h = element.size.height;
    if (activeExample.hasActiveOverlay) {
      activeExample.handleOverlayMouseEvent(event, localX, localY, w, h);
      return;
    }

    if (localY == 0) {
      final headerText = _getHeaderText(w, h);
      final castBtnX = headerText.indexOf('⏺') - 1;
      if (localX >= castBtnX && localX < castBtnX + 16) {
        if (event.type == term.MouseEventType.press) {
          _toggleRecording();
        }
      }
    }
  }

  String _getHeaderText(int width, int height) {
    final prefix = widget.isInline
        ? ' 📖 Widget Book Demo (Inline) [Size: ${width}x$height] [FPS: ${_currentFps.toStringAsFixed(1)}]'
        : ' 📖 Widget Book Demo (Alt) [Size: ${width}x$height] [FPS: ${_currentFps.toStringAsFixed(1)}]';

    final castBtnText = _isRecordingCast ? '🔴 [Stop Cast]' : '⏺ [Record Cast]';
    final status = _statusMessage.isNotEmpty ? '  [$_statusMessage]' : '';

    return '$prefix  $castBtnText$status';
  }

  @override
  Widget build(BuildContext context) {
    final element = context as Element;
    final width = element.size.width;
    final height = element.size.height;
    final activeExample = examples[_selectedPage]!;

    final sidebarWidth = (width * 0.25).round();
    final contentWidth = width - sidebarWidth - 3;
    final contentHeight = height - 5;

    final headerText = _getHeaderText(width, height);

    final mainLayout = Column([
      SizedBox(
        height: 1,
        child: Text(
          headerText,
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
                    modifiers: _focusDemoPane ? Modifier.dim : Modifier.bold,
                  ),
                ),
              ),
              Expanded(
                child: SidebarWidget(
                  items: DemoPage.values.map((p) => p.title).toList(),
                  selectedIndex: _selectedPageIdx,
                  hoveredIndex: _hoveredPageIdx,
                  focusNode: _sidebarFocusNode,
                  onSelected: (idx) {
                    setState(() {
                      _selectedPageIdx = idx;
                      _selectedPage = DemoPage.values[idx];
                      widget.terminal.resetMousePointer();
                    });
                    _updateTickerState();
                  },
                  onHovered: (idx) {
                    setState(() {
                      _hoveredPageIdx = idx;
                    });
                  },
                ),
              ),
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
                    '${_selectedPage.title} Preview ${_focusDemoPane ? "[ACTIVE]" : ""} ${Tracer.isEnabled ? "🔴 [TRACING]" : ""}',
                    style: const Style(
                      foreground: CharmColors.charple,
                      modifiers: Modifier.bold,
                    ),
                  ),
                ),
                const SizedBox(height: 1, child: Text('')),
                Expanded(
                  child: PreviewPaneWidget(
                    key: _previewPaneKey,
                    activeExample: activeExample,
                    focusNode: _previewFocusNode,
                    onFocusChange: (hasFocus) {
                      if (mounted) {
                        setState(() {
                          _focusDemoPane = hasFocus;
                        });
                      }
                    },
                    contentWidth: contentWidth,
                    contentHeight: contentHeight,
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
          bindings: _focusDemoPane
              ? {
                  ...activeExample.helpBindings,
                  if (!activeExample.helpBindings.containsKey('Tab'))
                    'Tab': 'Sidebar',
                  'Esc': 'Defocus',
                  'T': Tracer.isEnabled ? 'Stop Tracing' : 'Start Tracing',
                  if (_selectedPage != DemoPage.textInputs)
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

    return FocusScope(
      focusNode: _rootScopeNode,
      autofocus: true,
      onKeyEvent: (event) {
        if (event.type == KeyType.tab) {
          if (event.modifiers.contains(term.Modifier.shift)) {
            _rootScopeNode.previousFocus();
          } else {
            _rootScopeNode.nextFocus();
          }
          return true;
        }

        if (event.type == KeyType.escape || event.key == 'escape') {
          if (_previewFocusNode.hasFocus) {
            _sidebarFocusNode.requestFocus();
            return true;
          }
        }

        if (event.type == KeyType.character) {
          if (event.key == 'q') {
            PromptScope.of(context)?.done();
            return true;
          }
          if (event.key == 'h' || event.key == '?') {
            setState(() {
              _showHelpDialog = true;
            });
            return true;
          }
          if (event.key == 't') {
            _toggleTracing();
            return true;
          }
        }

        return false;
      },
      child: Stack([
        Positioned(left: 0, top: 0, right: 0, bottom: 0, child: mainLayout),
        if (_showHelpDialog)
          Positioned(
            left: 0,
            top: 0,
            right: 0,
            bottom: 0,
            child: ModalDismissBarrier(
              onDismiss: () {
                setState(() {
                  _showHelpDialog = false;
                });
              },
              child: Stack([
                Positioned.center(
                  width: 62,
                  height: 16,
                  child: Focus(
                    autofocus: true,
                    onKeyEvent: (event) {
                      setState(() {
                        _showHelpDialog = false;
                      });
                      return true;
                    },
                    child: const HelpDialog(),
                  ),
                ),
              ]),
            ),
          ),
      ]),
    );
  }
}

/// A widget representing the sidebar containing all selectable example pages.
class SidebarWidget extends StatefulWidget {
  /// The list of items to display.
  final List<String> items;

  /// The currently selected item index.
  final int selectedIndex;

  /// The currently hovered item index, if any.
  final int? hoveredIndex;

  /// Callback when a sidebar item is selected.
  final void Function(int index) onSelected;

  /// Callback when hover state changes.
  final void Function(int? index) onHovered;

  /// The focus node managed by this sidebar.
  final FocusNode focusNode;

  /// Creates a new [SidebarWidget].
  const SidebarWidget({
    super.key,
    required this.items,
    required this.selectedIndex,
    this.hoveredIndex,
    required this.onSelected,
    required this.onHovered,
    required this.focusNode,
  });

  @override
  State<SidebarWidget> createState() => _SidebarWidgetState();
}

class _SidebarWidgetState extends State<SidebarWidget> {
  int scrollOffset = 0;

  void adjustScroll(int viewportHeight) {
    if (widget.items.isEmpty || viewportHeight <= 0) return;
    final selectedIdx = widget.selectedIndex.clamp(0, widget.items.length - 1);

    if (selectedIdx < scrollOffset) {
      scrollOffset = selectedIdx;
    } else if (selectedIdx >= scrollOffset + viewportHeight) {
      scrollOffset = selectedIdx - viewportHeight + 1;
    }
  }

  void handleMouseEvent(term.MouseEvent event, int localX, int localY) {
    if (event.type == term.MouseEventType.press) {
      widget.focusNode.requestFocus();
      final clickedIdx = localY + scrollOffset;
      if (clickedIdx >= 0 && clickedIdx < widget.items.length) {
        widget.onSelected(clickedIdx);
      }
    } else if (event.type == term.MouseEventType.move ||
        event.type == term.MouseEventType.drag) {
      final hoverIdx = localY + scrollOffset;
      if (hoverIdx >= 0 && hoverIdx < widget.items.length) {
        widget.onHovered(hoverIdx);
      } else {
        widget.onHovered(null);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final listWidget = ListWidget(
      widget.items,
      selectedIndex: widget.selectedIndex,
      hoveredIndex: widget.hoveredIndex,
      selectedStyle: const Style(
        foreground: CharmColors.pepper,
        background: CharmColors.charple,
        modifiers: Modifier.bold,
      ),
      hoveredStyle: const Style(
        foreground: CharmColors.pepper,
        background: CharmColors.charple,
        modifiers: Modifier.dim,
      ),
    );

    return Focus(
      focusNode: widget.focusNode,
      onFocusChange: (hasFocus) {
        setState(() {});
      },
      onKeyEvent: (event) {
        if (event.type == KeyType.up) {
          final newIdx = (widget.selectedIndex - 1).clamp(
            0,
            widget.items.length - 1,
          );
          widget.onSelected(newIdx);
          return true;
        } else if (event.type == KeyType.down) {
          final newIdx = (widget.selectedIndex + 1).clamp(
            0,
            widget.items.length - 1,
          );
          widget.onSelected(newIdx);
          return true;
        }
        return false;
      },
      child: _SidebarRenderWidget(
        listWidget: listWidget,
        onMouseEvent: handleMouseEvent,
      ),
    );
  }
}

class _SidebarRenderWidget extends Widget {
  final ListWidget listWidget;
  final void Function(term.MouseEvent event, int localX, int localY)
  onMouseEvent;

  const _SidebarRenderWidget({
    required this.listWidget,
    required this.onMouseEvent,
  });

  @override
  Element createElement() => _SidebarRenderWidgetElement(this);
}

class _SidebarRenderWidgetElement extends Element {
  Element? childElement;

  _SidebarRenderWidgetElement(_SidebarRenderWidget super.widget);

  @override
  void mount(Element? parent) {
    super.mount(parent);
    rebuild();
  }

  @override
  void unmount() {
    childElement?.unmount();
    super.unmount();
  }

  @override
  void update(Widget newWidget) {
    super.update(newWidget);
    rebuild();
  }

  @override
  void rebuild() {
    final w = widget as _SidebarRenderWidget;
    if (childElement != null &&
        childElement!.widget.runtimeType == w.listWidget.runtimeType) {
      childElement!.update(w.listWidget);
    } else {
      childElement?.unmount();
      childElement = w.listWidget.createElement();
      childElement!.mount(this);
    }
  }

  @override
  void visitChildren(void Function(Element child) visitor) {
    if (childElement != null) visitor(childElement!);
  }

  @override
  Size performLayout(BoxConstraints constraints) {
    if (childElement != null) {
      return childElement!.layout(constraints);
    }
    return constraints.constrain(Size.zero);
  }

  @override
  void paint(Buffer buffer, Offset offset) {
    if (childElement != null) {
      childElement!.paint(buffer, offset);
    }
  }

  void handleMouseEvent(term.MouseEvent event, int localX, int localY) {
    (widget as _SidebarRenderWidget).onMouseEvent(event, localX, localY);
  }
}

/// A widget rendering the preview pane of the currently selected example.
class PreviewPaneWidget extends Widget {
  /// The currently active example.
  final WidgetBookExample activeExample;

  /// The focus scope node managed by this preview pane.
  final FocusScopeNode focusNode;

  /// Optional callback executed when focus status transitions.
  final void Function(bool hasFocus)? onFocusChange;

  /// The width allocated to the preview pane.
  final int contentWidth;

  /// The height allocated to the preview pane.
  final int contentHeight;

  /// Creates a new [PreviewPaneWidget].
  const PreviewPaneWidget({
    super.key,
    required this.activeExample,
    required this.focusNode,
    this.onFocusChange,
    required this.contentWidth,
    required this.contentHeight,
  });

  @override
  Element createElement() => _PreviewPaneElement(this);
}

class _PreviewPaneElement extends Element {
  Element? childElement;

  _PreviewPaneElement(PreviewPaneWidget super.widget);

  @override
  void mount(Element? parent) {
    super.mount(parent);
    rebuild();
  }

  @override
  void unmount() {
    childElement?.unmount();
    super.unmount();
  }

  @override
  void update(Widget newWidget) {
    super.update(newWidget);
    rebuild();
  }

  @override
  void rebuild() {
    final w = widget as PreviewPaneWidget;
    final exampleWidget = w.activeExample.build(
      focusDemoPane: w.focusNode.hasFocus,
      width: w.contentWidth,
      height: w.contentHeight,
    );
    final childWidget = FocusScope(
      focusNode: w.focusNode,
      onFocusChange: w.onFocusChange,
      onKeyEvent: (event) {
        if (event.type == KeyType.escape || event.key == 'escape') {
          return false;
        }
        if (w.activeExample.handleKeyEvent(event)) {
          return true;
        }
        return false;
      },
      child: exampleWidget,
    );
    if (childElement != null &&
        childElement!.widget.runtimeType == childWidget.runtimeType) {
      childElement!.update(childWidget);
    } else {
      childElement?.unmount();
      childElement = childWidget.createElement();
      childElement!.mount(this);
    }
  }

  @override
  void visitChildren(void Function(Element child) visitor) {
    if (childElement != null) visitor(childElement!);
  }

  @override
  Size performLayout(BoxConstraints constraints) {
    if (childElement != null) {
      return childElement!.layout(constraints);
    }
    return constraints.constrain(Size.zero);
  }

  @override
  void paint(Buffer buffer, Offset offset) {
    if (childElement != null) {
      childElement!.paint(buffer, offset);
    }
  }

  void handleMouseEvent(term.MouseEvent event, int localX, int localY) {
    final w = widget as PreviewPaneWidget;
    w.focusNode.requestFocus();
    w.activeExample.handleMouseEvent(
      event,
      localX,
      localY,
      w.contentWidth,
      w.contentHeight,
    );
  }
}

/// A overlay dialog displaying advanced text-editing shortcuts.
class HelpDialog extends Widget {
  /// Creates a [HelpDialog] widget.
  const HelpDialog({super.key});

  @override
  Element createElement() => _HelpDialogElement(this);
}

class _HelpDialogElement extends Element {
  _HelpDialogElement(super.widget);

  @override
  Size performLayout(BoxConstraints constraints) {
    return constraints.constrain(const Size(62, 16));
  }

  @override
  void paint(Buffer buffer, Offset offset) {
    final startX = offset.dx.toInt();
    final startY = offset.dy.toInt();
    final dialogWidth = 62;
    final dialogHeight = 16;

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
}

/// A full-screen widget that blocks clicks to widgets beneath it and dismisses the overlay on click.
class ModalDismissBarrier extends Widget {
  /// The child widget.
  final Widget child;

  /// Callback when the barrier is clicked.
  final void Function() onDismiss;

  /// Creates a new [ModalDismissBarrier].
  const ModalDismissBarrier({
    super.key,
    required this.child,
    required this.onDismiss,
  });

  @override
  Element createElement() => _ModalDismissBarrierElement(this);
}

class _ModalDismissBarrierElement extends Element {
  Element? childElement;

  _ModalDismissBarrierElement(ModalDismissBarrier super.widget);

  @override
  void mount(Element? parent) {
    super.mount(parent);
    rebuild();
  }

  @override
  void unmount() {
    childElement?.unmount();
    super.unmount();
  }

  @override
  void update(Widget newWidget) {
    super.update(newWidget);
    rebuild();
  }

  @override
  void rebuild() {
    final w = widget as ModalDismissBarrier;
    if (childElement != null &&
        childElement!.widget.runtimeType == w.child.runtimeType) {
      childElement!.update(w.child);
    } else {
      childElement?.unmount();
      childElement = w.child.createElement();
      childElement!.mount(this);
    }
  }

  @override
  void visitChildren(void Function(Element child) visitor) {
    if (childElement != null) visitor(childElement!);
  }

  @override
  Size performLayout(BoxConstraints constraints) {
    if (childElement != null) {
      childElement!.layout(constraints);
    }
    return constraints.constrain(
      Size(constraints.maxWidth, constraints.maxHeight),
    );
  }

  @override
  void paint(Buffer buffer, Offset offset) {
    if (childElement != null) {
      childElement!.paint(buffer, offset);
    }
  }

  void handleMouseEvent(term.MouseEvent event, int localX, int localY) {
    if (event.type == term.MouseEventType.press) {
      (widget as ModalDismissBarrier).onDismiss();
    }
  }
}
