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

class DashboardApp extends StatefulWidget {
  final int width;
  final int height;

  const DashboardApp({required this.width, required this.height});

  @override
  State<DashboardApp> createState() => _DashboardAppState();
}

class _DashboardAppState extends State<DashboardApp> {
  // Task state
  late List<double> progressValues;
  late List<String> taskStatuses;
  late List<String> dropdownValues;

  int selectedRow = 0;
  bool isActionFocused = false;
  String lastActionMessage =
      'Use [Up/Down] to select rows. Press [Tab] or [Right] to focus actions.';

  @override
  void initState() {
    super.initState();
    progressValues = [0.70, 0.40, 1.0, 0.12];
    taskStatuses = ['Syncing', 'Building', 'Passed', 'Running'];
    dropdownValues = ['active', 'restart', 'rerun', 'run'];
  }

  void updateProgress() {
    setState(() {
      for (var i = 0; i < progressValues.length; i++) {
        if (i == 0 && dropdownValues[0] == 'paused') continue;
        if (i == 3 && dropdownValues[3] == 'skip') continue;

        if (progressValues[i] < 1.0) {
          progressValues[i] = min(1.0, progressValues[i] + 0.005);
          if (progressValues[i] >= 1.0) {
            taskStatuses[i] = 'Passed';
          }
        }
      }
    });
  }

  void handleKeyEvent(ui.KeyEvent event) {
    if (!isActionFocused) {
      if (event.key == 'down') {
        setState(() {
          selectedRow = (selectedRow + 1) % 4;
        });
      } else if (event.key == 'up') {
        setState(() {
          selectedRow = (selectedRow - 1 + 4) % 4;
        });
      } else if (event.key == '\t' || event.key == 'right') {
        setState(() {
          isActionFocused = true;
          lastActionMessage =
              'Action focused. Press [Space] or [Enter] to open, [Esc] or [Left] to cancel.';
        });
      }
    } else {
      if (event.key == 'left' || event.key == 'escape') {
        setState(() {
          isActionFocused = false;
          lastActionMessage = 'Row selection mode. Use [Up/Down] to navigate.';
        });
      } else if (event.key == '\t') {
        setState(() {
          isActionFocused = false;
          selectedRow = (selectedRow + 1) % 4;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = ThemeData.dark;
    final textStyle = theme.textStyle;

    // Headers & widths mapping to 80 cols
    final headers = [
      'ID',
      'Task Name',
      'Progress',
      'Status',
      'Spin',
      'Actions',
    ];
    final widths = [4, 16, 18, 10, 6, 18];

    final rows = [
      [
        '01',
        const Text('Database Sync'),
        LinearProgressIndicator(progressValues[0], showPercentage: true),
        Text(
          taskStatuses[0],
          style: Style(
            foreground: progressValues[0] >= 1.0
                ? Colors.green
                : const Color(255, 255, 0),
          ),
        ),
        progressValues[0] >= 1.0
            ? const Text(
                '✔',
                style: Style(
                  foreground: Colors.green,
                  modifiers: Modifier.bold,
                ),
              )
            : Spinner.dots(
                style: const Style(foreground: Colors.green),
                paused: taskStatuses[0] == 'Paused',
              ),
        DropdownButton<String>(
          items: const [
            DropdownMenuItem(value: 'active', child: Text('Active')),
            DropdownMenuItem(value: 'paused', child: Text('Paused')),
            DropdownMenuItem(value: 'rerun', child: Text('Rerun')),
          ],
          value: dropdownValues[0],
          focused: isActionFocused && selectedRow == 0,
          onChanged: (val) {
            setState(() {
              if (val == 'rerun') {
                progressValues[0] = 0.0;
                taskStatuses[0] = 'Syncing';
                dropdownValues[0] = 'active';
                lastActionMessage = 'Database Sync: RERUN requested!';
              } else {
                dropdownValues[0] = val ?? 'active';
                taskStatuses[0] = val == 'paused' ? 'Paused' : 'Syncing';
                lastActionMessage =
                    'Database Sync set to: ${val?.toUpperCase()}';
              }
            });
          },
        ),
      ],
      [
        '02',
        const Text('Build Assets'),
        LinearProgressIndicator(progressValues[1], showPercentage: true),
        Text(
          taskStatuses[1],
          style: Style(
            foreground: progressValues[1] >= 1.0 ? Colors.green : Colors.orange,
          ),
        ),
        progressValues[1] >= 1.0
            ? const Text(
                '✔',
                style: Style(
                  foreground: Colors.green,
                  modifiers: Modifier.bold,
                ),
              )
            : Spinner.line(
                style: const Style(foreground: Colors.orange),
                paused: taskStatuses[1] == 'Paused',
              ),
        PopupMenuButton<String>(
          items: const [
            PopupMenuItem(value: 'restart', child: Text('Restart')),
            PopupMenuItem(value: 'abort', child: Text('Abort')),
          ],
          focused: isActionFocused && selectedRow == 1,
          onSelected: (val) {
            setState(() {
              if (val == 'restart') {
                progressValues[1] = 0.0;
                taskStatuses[1] = 'Building';
              }
              lastActionMessage = 'Build Assets action: ${val.toUpperCase()}';
            });
          },
          child: const Text('Options'),
        ),
      ],
      [
        '03',
        const Text('Static Analysis'),
        LinearProgressIndicator(progressValues[2], showPercentage: true),
        Text(
          taskStatuses[2],
          style: Style(
            foreground: progressValues[2] >= 1.0
                ? Colors.green
                : const Color(255, 255, 0),
          ),
        ),
        progressValues[2] >= 1.0
            ? const Text(
                '✔',
                style: Style(
                  foreground: Colors.green,
                  modifiers: Modifier.bold,
                ),
              )
            : Spinner.pulse(
                style: const Style(foreground: Colors.blue),
                paused: taskStatuses[2] == 'Paused',
              ),
        PopupMenuButton<String>(
          items: const [PopupMenuItem(value: 'rerun', child: Text('Rerun'))],
          focused: isActionFocused && selectedRow == 2,
          onSelected: (val) {
            setState(() {
              if (val == 'rerun') {
                progressValues[2] = 0.0;
                taskStatuses[2] = 'Analyzing';
              }
              lastActionMessage =
                  'Static Analysis action: ${val.toUpperCase()}';
            });
          },
          child: const Text('Options'),
        ),
      ],
      [
        '04',
        const Text('Unit Tests'),
        LinearProgressIndicator(progressValues[3], showPercentage: true),
        Text(
          taskStatuses[3],
          style: Style(
            foreground: progressValues[3] >= 1.0 ? Colors.green : Colors.blue,
          ),
        ),
        progressValues[3] >= 1.0
            ? const Text(
                '✔',
                style: Style(
                  foreground: Colors.green,
                  modifiers: Modifier.bold,
                ),
              )
            : Spinner.dots(
                style: const Style(foreground: Colors.blue),
                speed: const Duration(milliseconds: 60),
                paused:
                    taskStatuses[3] == 'Skipped' || taskStatuses[3] == 'Paused',
              ),
        DropdownButton<String>(
          items: const [
            DropdownMenuItem(value: 'run', child: Text('Run')),
            DropdownMenuItem(value: 'skip', child: Text('Skip')),
            DropdownMenuItem(value: 'rerun', child: Text('Rerun')),
          ],
          value: dropdownValues[3],
          focused: isActionFocused && selectedRow == 3,
          onChanged: (val) {
            setState(() {
              if (val == 'rerun') {
                progressValues[3] = 0.0;
                taskStatuses[3] = 'Running';
                dropdownValues[3] = 'run';
                lastActionMessage = 'Unit Tests: RERUN requested!';
              } else {
                dropdownValues[3] = val ?? 'run';
                taskStatuses[3] = val == 'skip' ? 'Skipped' : 'Running';
                lastActionMessage = 'Unit Tests set to: ${val?.toUpperCase()}';
              }
            });
          },
        ),
      ],
    ];

    final table = Table(
      headers: headers,
      rows: rows,
      columnWidths: widths,
      selectedRowIndex: selectedRow,
      selectedRowStyle: isActionFocused
          ? const Style(
              background: Color(66, 66, 66),
            ) // Dim selection if button has focus
          : const Style(modifiers: Modifier.reverse),
    );

    return DecoratedBox(
      decoration: BoxDecoration(backgroundStyle: theme.backgroundStyle),
      child: Column([
        // Title Bar
        SizedBox(
          height: 1,
          child: DecoratedBox(
            decoration: BoxDecoration(backgroundStyle: theme.primaryStyle),
            child: Center(
              child: Text(
                ' 🖥️  TERMUI DATA DASHBOARD & OVERLAYS SHOWCASE  🖥️ ',
                style: theme.primaryStyle.merge(
                  const Style(modifiers: Modifier.bold),
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: 1),
        // Top Info Panel
        SizedBox(
          height: 1,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 2),
            child: Row([
              Expanded(
                child: Text(
                  'Active Mode: ${isActionFocused ? "ACTION [Focused]" : "NAVIGATION [Row Selected]"}',
                  style: isActionFocused
                      ? const Style(
                          foreground: Colors.orange,
                          modifiers: Modifier.bold,
                        )
                      : const Style(
                          foreground: Colors.green,
                          modifiers: Modifier.bold,
                        ),
                ),
              ),
              SizedBox(
                width: 15,
                child: Text(
                  'Time: ${DateTime.now().toIso8601String().substring(11, 19)}',
                  style: textStyle,
                ),
              ),
            ]),
          ),
        ),
        const SizedBox(height: 1),
        // The Data Table
        Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 1),
            child: table,
          ),
        ),
        // Interactive Message Log
        SizedBox(
          height: 3,
          child: DecoratedBox(
            decoration: const BoxDecoration(
              border: Border(
                topChar: '─',
                style: Style(modifiers: Modifier.dim),
                bottomChar: '',
                leftChar: '',
                rightChar: '',
                topLeftChar: '',
                topRightChar: '',
                bottomLeftChar: '',
                bottomRightChar: '',
              ),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 1),
              child: Column([
                SizedBox(
                  height: 1,
                  child: Text(
                    'STATUS LOG:',
                    style: textStyle.merge(
                      const Style(
                        foreground: Color(0, 255, 255),
                        modifiers: Modifier.bold,
                      ),
                    ),
                  ),
                ),
                SizedBox(
                  height: 1,
                  child: Text(lastActionMessage, style: textStyle),
                ),
              ]),
            ),
          ),
        ),
        // Footer Help
        SizedBox(
          height: 1,
          child: Help(
            bindings: const {
              'Up/Down': 'Navigate Rows',
              'Tab/Right': 'Focus Action',
              'Left/Esc': 'Exit Action',
              'Space/Enter': 'Activate',
              'Q': 'Quit',
            },
            keyStyle: const Style(foreground: Color(255, 255, 0)),
            descStyle: const Style(foreground: Colors.white),
          ),
        ),
      ]),
    );
  }
}

void main() async {
  await term.Terminal.runGuarded((terminal) async {
    final termSize = await terminal.size;
    var width = termSize.x;
    var height = termSize.y;

    if (width < 80 || height < 15) {
      stderr.writeln('Terminal must be at least 80x15 to run this demo.');
      exit(1);
    }

    terminal.enterAlternateScreen();
    terminal.hideCursor();
    terminal.enableMouseTracking();

    final buffer = Buffer.blank(width, height);
    var renderer = Renderer(width, height, mode: RenderingMode.alternateScreen);

    // Instantiate and mount the dashboard app widget
    // We wrap it in Overlay so that DropdownButton/PopupMenuButton can locate the OverlayState
    final elementWrapper = ElementWidget(
      Overlay(
        child: DashboardApp(width: width, height: height),
      ),
    );

    late final BuildOwner buildOwner;

    void drawFrame() {
      buildOwner.buildScope();
      buffer.clear();
      // Pre-fill background
      elementWrapper.layout(
        BoxConstraints.tight(Size(width, height)),
        buildOwner,
      );
      elementWrapper.paint(buffer, Offset.zero);

      final sb = StringBuffer();
      renderer.render(buffer, sb);
      if (sb.isNotEmpty) {
        stdout.write(sb.toString());
      }
    }

    buildOwner = BuildOwner(onNeedVisualUpdate: drawFrame);

    // Timer to drive animations at ~30 FPS
    final animationTimer = Timer.periodic(const Duration(milliseconds: 33), (
      timer,
    ) {
      final state = elementWrapper.findState<_DashboardAppState>();
      state?.updateProgress();
      drawFrame();
    });

    final sizeSubscription = terminal.watchSize().listen((size) {
      width = size.x;
      height = size.y;
      buffer.resize(width, height);
      renderer = Renderer(width, height, mode: RenderingMode.alternateScreen);
      drawFrame();
    });

    // Handle mouse event helper
    void handleGlobalMouseEvent(Element rootEl, ui.MouseEvent event) {
      final sx = event.x - 1;
      final sy = event.y - 1;
      bool handled = false;

      void traverse(Element el) {
        if (handled) return;

        if (el is StatefulElement) {
          final state = el.state;
          final widgetType = state.widget.runtimeType.toString();
          if (widgetType.startsWith('DropdownButton')) {
            final dState = state as dynamic;
            final bounds = dState.buttonBounds as Rect;

            if (sx >= bounds.x &&
                sx < bounds.x + bounds.width &&
                sy >= bounds.y &&
                sy < bounds.y + bounds.height) {
              if (event.type == ui.MouseEventType.press) {
                dState.toggleDropdown();
                drawFrame();
              }
              handled = true;
              return;
            }

            if (dState.isOpen && dState.overlayEntry != null) {
              final itemX = bounds.x;
              final itemYStart = bounds.y + bounds.height;
              final itemYEnd = itemYStart + dState.widget.items.length;
              if (sx >= itemX &&
                  sx < itemX + bounds.width &&
                  sy >= itemYStart &&
                  sy < itemYEnd) {
                if (event.type == ui.MouseEventType.press) {
                  final clickedItemIdx = sy - itemYStart;
                  dState.selectItem(clickedItemIdx);
                  drawFrame();
                }
                handled = true;
                return;
              }
            }
          } else if (widgetType.startsWith('PopupMenuButton')) {
            final pState = state as dynamic;
            final bounds = pState.buttonBounds as Rect;

            if (sx >= bounds.x &&
                sx < bounds.x + bounds.width &&
                sy >= bounds.y &&
                sy < bounds.y + bounds.height) {
              if (event.type == ui.MouseEventType.press) {
                pState.toggleMenu();
                drawFrame();
              }
              handled = true;
              return;
            }

            if (pState.isOpen && pState.overlayEntry != null) {
              final menuWidth = max(12, bounds.width);
              final itemX = bounds.x;
              final itemYStart = bounds.y + bounds.height;
              final itemYEnd = itemYStart + pState.widget.items.length;
              if (sx >= itemX &&
                  sx < itemX + menuWidth &&
                  sy >= itemYStart &&
                  sy < itemYEnd) {
                if (event.type == ui.MouseEventType.press) {
                  final clickedItemIdx = sy - itemYStart;
                  pState.selectItem(clickedItemIdx);
                  drawFrame();
                }
                handled = true;
                return;
              }
            }
          }
        }
        el.visitChildren(traverse);
      }

      traverse(rootEl);
    }

    try {
      await for (final event in terminal.events) {
        if (event.key == 'q' || event.key == 'Q') {
          break;
        }
        if (event.key.length == 1 && event.key.codeUnits[0] == 3) {
          break; // Ctrl+C
        }

        if (event is ui.MouseEvent) {
          // Route mouse events using the tree helper
          if (elementWrapper.element != null) {
            handleGlobalMouseEvent(elementWrapper.element!, event);
          }
        } else if (event is ui.KeyEvent) {
          // Route keyboard events
          final state = elementWrapper.findState<_DashboardAppState>();
          if (state != null) {
            // Check if action overlay is open and intercept key events
            bool overlayOpen = false;
            dynamic openOverlayState;

            void traverseForOpenOverlay(Element el) {
              if (overlayOpen) return;
              if (el is StatefulElement) {
                final s = el.state;
                final widgetType = s.widget.runtimeType.toString();
                if (widgetType.startsWith('DropdownButton') &&
                    (s as dynamic).isOpen) {
                  overlayOpen = true;
                  openOverlayState = s;
                } else if (widgetType.startsWith('PopupMenuButton') &&
                    (s as dynamic).isOpen) {
                  overlayOpen = true;
                  openOverlayState = s;
                }
              }
              el.visitChildren(traverseForOpenOverlay);
            }

            if (elementWrapper.element != null) {
              traverseForOpenOverlay(elementWrapper.element!);
            }

            if (overlayOpen && openOverlayState != null) {
              openOverlayState.handleKeyEvent(event);
              drawFrame();
            } else {
              // Direct key events to either form/selection state or to the focused action button
              if (state.isActionFocused) {
                void traverseForFocusedAction(Element el) {
                  if (el is StatefulElement) {
                    final s = el.state;
                    final w = el.widget;
                    final widgetType = w.runtimeType.toString();
                    if (widgetType.startsWith('DropdownButton') &&
                        (w as dynamic).focused) {
                      (s as dynamic).handleKeyEvent(event);
                    } else if (widgetType.startsWith('PopupMenuButton') &&
                        (w as dynamic).focused) {
                      (s as dynamic).handleKeyEvent(event);
                    }
                  }
                  el.visitChildren(traverseForFocusedAction);
                }

                if (elementWrapper.element != null) {
                  traverseForFocusedAction(elementWrapper.element!);
                }
              }
              // Send event to top-level app logic
              state.handleKeyEvent(event);
              drawFrame();
            }
          }
        }
      }
    } finally {
      animationTimer.cancel();
      sizeSubscription.cancel();
      terminal.showCursor();
      terminal.disableMouseTracking();
      terminal.exitAlternateScreen();
      terminal.resetStyle();
    }
  });
  print('Dashboard demo exited cleanly.');
  exit(0);
}
