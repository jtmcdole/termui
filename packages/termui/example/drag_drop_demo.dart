// ignore_for_file: file_names

import 'dart:async';
import 'dart:math';
import 'package:clock/clock.dart';
import 'package:termui/terminal/terminal.dart' as term;
import 'package:termui/termui.dart';

// ============================================================================
// Custom Colors
// ============================================================================
const Color cyanColor = Color(0, 255, 255);
const Color greyColor = Color(128, 128, 128);

// ============================================================================
// Drop Ripple Animation
// ============================================================================
class DropRipple {
  final Point<int> position;
  final int startTime;

  DropRipple(this.position, this.startTime);
}

// ============================================================================
// Drag & Drop Interactive Demo App
// ============================================================================

class DragDropDemo extends StatefulWidget {
  const DragDropDemo({super.key});

  @override
  State<DragDropDemo> createState() => DragDropDemoState();
}

class DragDropDemoState extends State<DragDropDemo> {
  static DragDropDemoState? instance;

  final List<String> receivedItems = [];
  final List<String> logs = [];
  final TextEditingController pasteInputCtrl = TextEditingController(text: '');
  final List<DropRipple> activeRipples = [];
  Timer? animationTimer;
  bool _wasDragging = false;

  @override
  void initState() {
    super.initState();
    instance = this;
    DragDropManager.onDragSessionChanged = _handleDragSessionChanged;
  }

  void _handleDragSessionChanged(DragSession? session) {
    if (session != null) {
      if (!_wasDragging) {
        _wasDragging = true;
        logEvent(
          'START_DRAG: data=${session.data} at (${session.startMousePosition.x}, ${session.startMousePosition.y})',
        );
      } else {
        logEvent(
          'DRAG_MOVE: at (${session.currentMousePosition.x}, ${session.currentMousePosition.y})',
        );
      }
    } else if (_wasDragging) {
      _wasDragging = false;
    }
  }

  void logEvent(String msg) {
    setState(() {
      logs.add('[${clock.now().toIso8601String().substring(11, 19)}] $msg');
      if (logs.length > 5) {
        logs.removeAt(0);
      }
    });
  }

  void addRipple(Point<int> pos) {
    setState(() {
      activeRipples.add(DropRipple(pos, clock.now().millisecondsSinceEpoch));
    });
    _startAnimationTimer();
  }

  void _startAnimationTimer() {
    if (animationTimer != null) return;
    animationTimer = Timer.periodic(const Duration(milliseconds: 30), (timer) {
      final now = clock.now().millisecondsSinceEpoch;
      setState(() {
        activeRipples.removeWhere((ripple) => now - ripple.startTime > 500);
      });
      if (activeRipples.isEmpty) {
        animationTimer?.cancel();
        animationTimer = null;
      }
    });
  }

  @override
  void dispose() {
    if (identical(
      DragDropManager.onDragSessionChanged,
      _handleDragSessionChanged,
    )) {
      DragDropManager.onDragSessionChanged = null;
    }
    if (identical(instance, this)) {
      instance = null;
    }
    animationTimer?.cancel();
    super.dispose();
  }

  String getDisplayValue(String item) {
    if (item == '🍎' || item == '🍌') return item;
    // Extract filename from file paths
    final separator = item.contains('\\') ? '\\' : '/';
    final parts = item.split(separator);
    final filename = parts.isEmpty ? item : parts.last;
    return '📁 $filename';
  }

  @override
  Widget build(BuildContext context) {
    final titleBox = DecoratedBox(
      decoration: const BoxDecoration(
        border: Border.doubleLine,
        borderStartColor: CharmColors.tang,
        borderEndColor: CharmColors.cherry,
      ),
      child: const Padding(
        padding: EdgeInsets.symmetric(horizontal: 2, vertical: 1),
        child: Align(
          alignment: .center,
          child: Text(
            'DRAG & DROP TUI PROTOTYPE DEMO',
            style: Style(modifiers: Modifier.bold, foreground: Colors.white),
          ),
        ),
      ),
    );

    final dragSource1 = Draggable<String>(
      data: '🍎',
      child: SizedBox(
        width: 13,
        height: 4,
        child: DecoratedBox(
          decoration: const BoxDecoration(
            border: Border.rounded,
            borderStartColor: CharmColors.paprika,
            borderEndColor: CharmColors.paprika,
          ),
          child: const Padding(
            padding: EdgeInsets.symmetric(horizontal: 2, vertical: 0),
            child: Column([
              Text('Drag Me', style: Style(modifiers: Modifier.bold)),
              Text('  🍎  ', style: Style(foreground: Colors.red)),
            ]),
          ),
        ),
      ),
    );

    final dragSource2 = Draggable<String>(
      data: '🍌',
      child: SizedBox(
        width: 13,
        height: 4,
        child: DecoratedBox(
          decoration: const BoxDecoration(
            border: Border.rounded,
            borderStartColor: CharmColors.yam,
            borderEndColor: CharmColors.yam,
          ),
          child: const Padding(
            padding: EdgeInsets.symmetric(horizontal: 2, vertical: 0),
            child: Column([
              Text('Drag Me', style: Style(modifiers: Modifier.bold)),
              Text('  🍌  ', style: Style(foreground: Colors.yellow)),
            ]),
          ),
        ),
      ),
    );

    final targetArea = DragTarget<String>(
      onWillAccept: (item) {
        logEvent('DRAG_ENTER: target dropzone, data=$item');
        return true;
      },
      onLeave: (_) {
        logEvent('DRAG_LEAVE: left dropzone');
      },
      onAccept: (item) {
        setState(() {
          receivedItems.add(item);
        });
        logEvent('DROP: data=$item onto dropzone');
        final session = DragDropManager.activeSession;
        if (session != null) {
          addRipple(session.currentMousePosition);
        }
      },
      builder: (context, candidateData, rejectedData) {
        final isHovering = candidateData.isNotEmpty;
        final borderTheme = isHovering ? Border.doubleLine : Border.rounded;
        final borderColor = isHovering ? Colors.green : cyanColor;

        final receivedText = receivedItems.isEmpty
            ? 'None yet'
            : receivedItems.map(getDisplayValue).join(' ');

        return SizedBox(
          width: 32,
          height: 5,
          child: DecoratedBox(
            decoration: BoxDecoration(
              border: borderTheme,
              borderStartColor: borderColor,
              borderEndColor: borderColor,
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 0),
              child: Column([
                const Text(
                  'DROP TARGET',
                  style: Style(modifiers: Modifier.bold),
                ),
                Text(
                  'Candidates: ${candidateData.length}',
                  style: Style(
                    foreground: isHovering ? Colors.green : greyColor,
                  ),
                ),
                Text(
                  'Received: $receivedText',
                  style: const Style(foreground: Colors.white),
                ),
              ]),
            ),
          ),
        );
      },
    );

    final sourceRow = Row([
      dragSource1,
      const SizedBox(width: 4),
      dragSource2,
      const SizedBox(width: 8),
      targetArea,
    ]);

    final pasteInputField = SizedBox(
      width: 50,
      height: 3,
      child: DecoratedBox(
        decoration: const BoxDecoration(
          border: Border.single,
          borderStartColor: Colors.yellow,
          borderEndColor: Colors.yellow,
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 0),
          child: TextField(
            controller: pasteInputCtrl,
            placeholder: 'Drag file here (simulates bracketed paste)...',
            style: const Style(foreground: Colors.white),
            focused: true,
          ),
        ),
      ),
    );

    final logLines = logs.isEmpty
        ? [
            const Text(
              'No events yet. Begin dragging to log.',
              style: Style(foreground: Colors.black),
            ),
          ]
        : [
            for (final log in logs)
              Text(log, style: const Style(foreground: Colors.black)),
          ];

    final logPanel = DecoratedBox(
      decoration: const BoxDecoration(
        border: Border.single,
        borderStartColor: greyColor,
        borderEndColor: greyColor,
        backgroundColor: Colors.white,
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 1),
        child: Column([
          const Text(
            'EVENT JOURNAL',
            style: Style(modifiers: Modifier.bold, foreground: Colors.black),
          ),
          const SizedBox(height: 1),
          ...logLines,
        ]),
      ),
    );

    final mainColumn = Column([
      titleBox,
      const SizedBox(height: 1),
      sourceRow,
      const SizedBox(height: 1),
      pasteInputField,
      const SizedBox(height: 1),
      logPanel,
      const SizedBox(height: 1),
      const Text(
        'Instructions: Drag 🍎 or 🍌 to DROP TARGET, or drop a file into the window.',
        style: Style(foreground: greyColor),
      ),
      const Text(
        'Press \'q\' or \'Ctrl+C\' to exit.',
        style: Style(foreground: greyColor),
      ),
    ]);

    return mainColumn;
  }
}

void main() async {
  await term.Terminal.runGuarded((terminal) async {
    terminal.disableMouseTracking();
    terminal.hideCursor();
    terminal.enableMouseTracking();
    terminal.enableBracketedPaste();

    const demo = DragDropDemo();
    late final PromptRunner<void> runner;
    runner = PromptRunner<void>(
      terminal: terminal,
      widget: demo,
      alternateScreen: true,
      exitConditions: const {
        PromptExitTrigger.controlC: PromptExitAction.complete,
      },
      onKeyEvent: (event) {
        if (event.key == 'q' || event.key == 'Q') {
          return true;
        }
        return false;
      },
      onPasteEvent: (event) {
        final pos = runner.lastMousePosition;
        final posStr = pos != null ? '(${pos.x}, ${pos.y})' : 'unknown';

        if (pos != null) {
          // Trigger visual drop ripple effect
          DragDropDemoState.instance?.addRipple(pos);

          final root = runner.rootElement;
          if (root != null) {
            final hitElements = root.hitTest(pos);
            DragTargetElement<Object?>? hoveredTarget;
            for (final element in hitElements) {
              if (element is DragTargetElement<Object?>) {
                hoveredTarget = element;
                break;
              }
            }
            if (hoveredTarget != null) {
              // File dropped directly over the drop target!
              DragDropDemoState.instance?.logEvent(
                'FILE_DROP: "${event.text}" at mouse $posStr directly over dropzone',
              );
              final session = DragSession(
                data: event.text,
                sourceElement: hoveredTarget,
                startMousePosition: pos,
                currentMousePosition: pos,
              );
              hoveredTarget.handleDrop(session);
              return;
            }
          }
        }

        // Default log if not over dropzone
        DragDropDemoState.instance?.logEvent(
          'PASTE: "${event.text}" at mouse $posStr (not over dropzone)',
        );
      },
      onFramePainted: (Buffer buffer) {
        final session = DragDropManager.activeSession;
        if (session != null) {
          final sx = session.currentMousePosition.x - 1;
          final sy = session.currentMousePosition.y - 1;
          if (sx >= 0 && sx < buffer.width && sy >= 0 && sy < buffer.height) {
            buffer.writeString(
              sx,
              sy,
              '${session.data}',
              Style(
                foreground: Colors.yellow,
                modifiers: buffer.getModifiers(sx, sy) | Modifier.bold,
              ),
            );
          }
        }

        // Draw active ripples
        final state = DragDropDemoState.instance;
        if (state != null && state.activeRipples.isNotEmpty) {
          final canvas = Canvas(buffer.width, buffer.height);
          final now = clock.now().millisecondsSinceEpoch;
          var hasPainted = false;

          for (final ripple in state.activeRipples) {
            final elapsed = now - ripple.startTime;
            if (elapsed > 500) continue;

            final progress = elapsed / 500.0;
            final radius = (progress * 16).round();

            final colorValue = (255 * (1.0 - progress)).round().clamp(0, 255);
            // Fading yellow ring
            final color = Color(colorValue, colorValue, 0);
            final style = Style(foreground: color);

            if (radius > 0) {
              canvas.drawCircle(
                (ripple.position.x - 1) * 2 + 1,
                (ripple.position.y - 1) * 4 + 2,
                radius,
                cellStyle: style,
              );
              hasPainted = true;
            }
          }

          if (hasPainted) {
            final el = canvas.createElement();
            el.layout(BoxConstraints.tight(Size(buffer.width, buffer.height)));
            el.paint(buffer, Offset.zero);
            el.unmount();
          }
        }
      },
    );

    await runner.run();

    terminal.disableBracketedPaste();
    terminal.disableMouseTracking();
    terminal.showCursor();
  });

  print('Exited cleanly.');
}
