// ignore_for_file: file_names

import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'package:termui/terminal/terminal.dart' as term;
import 'package:termui/termui.dart';

// ============================================================================
// Custom Colors
// ============================================================================
const Color cyanColor = Color(0, 255, 255);
const Color greyColor = Color(128, 128, 128);

// ============================================================================
// Dummy BuildContext
// ============================================================================
class DummyBuildContext implements BuildContext {
  @override
  Widget get widget => throw UnimplementedError();

  @override
  T? dependOnInheritedWidgetOfExactType<T extends InheritedWidget>() => null;
}

// ============================================================================
// Drop Ripple Animation
// ============================================================================
class DropRipple {
  final Point<int> position;
  final int startTime;

  DropRipple(this.position, this.startTime);
}

// ============================================================================
// Drag & Drop State Machine and Widgets
// ============================================================================

/// Represents an active drag session.
class DragSession {
  final Object data;
  final Element draggableElement;
  final Point<int> startMousePosition;
  Point<int> currentMousePosition;

  DragSession({
    required this.data,
    required this.draggableElement,
    required this.startMousePosition,
    required this.currentMousePosition,
  });
}

/// Global coordinator for drag and drop interactions.
class DragDropManager {
  static DragSession? _activeSession;
  static DragTargetElement? _lastHoveredTarget;
  static DragDropDemoState? demoState;

  static DragSession? get activeSession => _activeSession;

  static void startDrag(DragSession session) {
    _activeSession = session;
    demoState?.logEvent(
      'START_DRAG: data=${session.data} at (${session.startMousePosition.x}, ${session.startMousePosition.y})',
    );
  }

  static void cancelDrag() {
    if (_lastHoveredTarget != null) {
      _lastHoveredTarget!.handleDragLeave();
      _lastHoveredTarget = null;
    }
    _activeSession = null;
  }

  static void updateDrag(Point<int> mousePosition) {
    final session = _activeSession;
    if (session == null) return;

    session.currentMousePosition = mousePosition;
    demoState?.logEvent(
      'DRAG_MOVE: at (${mousePosition.x}, ${mousePosition.y})',
    );

    // Find the topmost DragTargetElement under the mouse cursor
    final root = _findRoot(session.draggableElement);
    if (root == null) return;

    final hitElements = _hitTest(root, mousePosition);
    DragTargetElement? hoveredTarget;
    for (final element in hitElements) {
      if (element is DragTargetElement) {
        hoveredTarget = element;
        break;
      }
    }

    if (hoveredTarget != _lastHoveredTarget) {
      _lastHoveredTarget?.handleDragLeave();
      hoveredTarget?.handleDragEnter(session);
      _lastHoveredTarget = hoveredTarget;
    }

    hoveredTarget?.handleDragOver(session);
  }

  static void drop() {
    final session = _activeSession;
    final target = _lastHoveredTarget;
    if (session != null && target != null) {
      target.handleDrop(session);
      demoState?.addRipple(session.currentMousePosition);
    } else {
      demoState?.logEvent('CANCEL_DRAG');
    }
    cancelDrag();
  }

  static Element? _findRoot(Element element) {
    var current = element;
    while (current.parent != null) {
      current = current.parent!;
    }
    return current;
  }

  static List<Element> _hitTest(
    Element element,
    Point<int> point, [
    Offset parentOffset = Offset.zero,
  ]) {
    final absOffset = parentOffset + element.relativeOffset;
    final sx = point.x - 1;
    final sy = point.y - 1;
    final inside =
        sx >= absOffset.dx &&
        sx < absOffset.dx + element.size.width &&
        sy >= absOffset.dy &&
        sy < absOffset.dy + element.size.height;
    if (!inside) return [];

    final results = <Element>[];
    element.visitChildren((child) {
      results.addAll(_hitTest(child, point, absOffset));
    });
    results.add(element);
    return results;
  }
}

/// A wrapper widget that makes a child draggable.
class Draggable<T> extends Widget {
  final T data;
  final Widget child;

  const Draggable({required this.data, required this.child, super.key});

  @override
  Element createElement() => DraggableElement(this);

  @override
  int getIntrinsicHeight(int width) => child.getIntrinsicHeight(width);

  @override
  int getIntrinsicWidth(int height) => child.getIntrinsicWidth(height);
}

class DraggableElement extends SingleChildElement implements MouseEventHandler {
  DraggableElement(Draggable super.widget);

  @override
  Widget? get childWidget => (widget as Draggable).child;

  @override
  Size performLayout(BoxConstraints constraints) {
    if (childElement != null) {
      return childElement!.layout(constraints);
    } else {
      return Size(constraints.minWidth, constraints.minHeight);
    }
  }

  @override
  void handleMouseEvent(MouseEvent event, int localX, int localY) {
    if (event.type == MouseEventType.press) {
      final session = DragSession(
        data: (widget as Draggable).data as Object,
        draggableElement: this,
        startMousePosition: Point<int>(event.x, event.y),
        currentMousePosition: Point<int>(event.x, event.y),
      );
      DragDropManager.startDrag(session);
    } else if (event.type == MouseEventType.drag) {
      DragDropManager.updateDrag(Point<int>(event.x, event.y));
    } else if (event.type == MouseEventType.release) {
      DragDropManager.drop();
    }
  }
}

/// A wrapper widget that accepts dropped data from a Draggable.
class DragTarget<T> extends Widget {
  final Widget Function(
    BuildContext context,
    List<T> candidateData,
    List<dynamic> rejectedData,
  )
  builder;
  final bool Function(T data)? onWillAccept;
  final void Function(T data)? onAccept;
  final void Function(T? data)? onLeave;

  const DragTarget({
    required this.builder,
    this.onWillAccept,
    this.onAccept,
    this.onLeave,
    super.key,
  });

  @override
  Element createElement() => DragTargetElement<T>(this);

  @override
  int getIntrinsicHeight(int width) {
    final child = builder(DummyBuildContext(), const [], const []);
    return child.getIntrinsicHeight(width);
  }

  @override
  int getIntrinsicWidth(int height) {
    final child = builder(DummyBuildContext(), const [], const []);
    return child.getIntrinsicWidth(height);
  }
}

class DragTargetElement<T> extends SingleChildElement {
  final List<T> _candidateData = [];
  final List<dynamic> _rejectedData = [];

  DragTargetElement(DragTarget<T> super.widget);

  @override
  Widget? get childWidget =>
      (widget as DragTarget<T>).builder(this, _candidateData, _rejectedData);

  @override
  Size performLayout(BoxConstraints constraints) {
    rebuild();
    if (childElement != null) {
      return childElement!.layout(constraints);
    } else {
      return Size(constraints.minWidth, constraints.minHeight);
    }
  }

  void handleDragEnter(DragSession session) {
    final dragTarget = widget as DragTarget<T>;
    final data = session.data;
    if (data is T) {
      final castedData = data as T;
      if (dragTarget.onWillAccept == null ||
          dragTarget.onWillAccept!(castedData)) {
        _candidateData.add(castedData);
        markNeedsBuild();
      } else {
        _rejectedData.add(castedData);
      }
    } else {
      _rejectedData.add(data);
    }
    DragDropManager.demoState?.logEvent(
      'DRAG_ENTER: target dropzone, data=$data',
    );
  }

  void handleDragLeave() {
    final dragTarget = widget as DragTarget<T>;
    _candidateData.clear();
    _rejectedData.clear();
    markNeedsBuild();
    if (dragTarget.onLeave != null) {
      dragTarget.onLeave!(null);
    }
    DragDropManager.demoState?.logEvent('DRAG_LEAVE: left dropzone');
  }

  void handleDragOver(DragSession session) {
    DragDropManager.demoState?.logEvent(
      'DRAG_OVER: target dropzone at (${session.currentMousePosition.x}, ${session.currentMousePosition.y})',
    );
  }

  void handleDrop(DragSession session) {
    final dragTarget = widget as DragTarget<T>;
    final data = session.data;
    if (data is T) {
      final castedData = data as T;
      if (dragTarget.onAccept != null) {
        dragTarget.onAccept!(castedData);
      }
    }
    _candidateData.clear();
    _rejectedData.clear();
    markNeedsBuild();
    DragDropManager.demoState?.logEvent('DROP: data=$data onto dropzone');
  }
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
  final List<String> receivedItems = [];
  final List<String> logs = [];
  final TextEditingController pasteInputCtrl = TextEditingController(text: '');
  final List<DropRipple> activeRipples = [];
  Timer? animationTimer;

  @override
  void initState() {
    super.initState();
    DragDropManager.demoState = this;
    try {
      final file = File('drag_drop_log.txt');
      if (file.existsSync()) {
        file.deleteSync();
      }
      file.writeAsStringSync('=== DRAG AND DROP TEST LOG ===\n');
    } catch (_) {}
  }

  void logEvent(String msg) {
    setState(() {
      logs.add('[${DateTime.now().toIso8601String().substring(11, 19)}] $msg');
      if (logs.length > 5) {
        logs.removeAt(0);
      }
    });
    try {
      final file = File('drag_drop_log.txt');
      file.writeAsStringSync('$msg\n', mode: FileMode.append);
    } catch (_) {}
  }

  void addRipple(Point<int> pos) {
    setState(() {
      activeRipples.add(DropRipple(pos, DateTime.now().millisecondsSinceEpoch));
    });
    _startAnimationTimer();
  }

  void _startAnimationTimer() {
    if (animationTimer != null) return;
    animationTimer = Timer.periodic(const Duration(milliseconds: 30), (timer) {
      final now = DateTime.now().millisecondsSinceEpoch;
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
      onAccept: (item) {
        setState(() {
          receivedItems.add(item);
        });
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
            'EVENT JOURNAL (drag_drop_log.txt)',
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

    final demo = const DragDropDemo();
    late final PromptRunner runner;
    runner = PromptRunner(
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
          DragDropManager.demoState?.addRipple(pos);

          final root = runner.rootElement;
          if (root != null) {
            final hitElements = DragDropManager._hitTest(root, pos);
            DragTargetElement? hoveredTarget;
            for (final element in hitElements) {
              if (element is DragTargetElement) {
                hoveredTarget = element;
                break;
              }
            }
            if (hoveredTarget != null) {
              // File dropped directly over the drop target!
              DragDropManager.demoState?.logEvent(
                'FILE_DROP: "${event.text}" at mouse $posStr directly over dropzone',
              );
              final session = DragSession(
                data: event.text,
                draggableElement: hoveredTarget,
                startMousePosition: pos,
                currentMousePosition: pos,
              );
              hoveredTarget.handleDrop(session);
              return;
            }
          }
        }

        // Default log if not over dropzone
        DragDropManager.demoState?.logEvent(
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
        final state = DragDropManager.demoState;
        if (state != null && state.activeRipples.isNotEmpty) {
          final canvas = Canvas(buffer.width, buffer.height);
          final now = DateTime.now().millisecondsSinceEpoch;
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
