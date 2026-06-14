import 'dart:math';
import 'package:termui/ui/buffer.dart';
import 'package:termui/ui/style.dart';
import 'package:termui/ui/color.dart';
import 'package:termui/ui/layout.dart';
import 'package:termui/ui/window.dart';
import 'package:termui/ui/event.dart' as ui;
import '../window_manager_demo/scenario_a_widgets.dart';
import 'example_base.dart';

/// A custom widget wrapping WindowManager rendering inside the widget tree.
class WindowManagerWidget extends Widget {
  /// The window manager instance to be rendered.
  final WindowManager windowManager;

  /// Creates a new [WindowManagerWidget] with the given [windowManager].
  WindowManagerWidget(this.windowManager);

  @override
  Element createElement() => _WindowManagerElement(this);
}

class _WindowManagerElement extends Element {
  _WindowManagerElement(super.widget);

  @override
  Size performLayout(BoxConstraints constraints) {
    return Size(constraints.maxWidth, constraints.maxHeight);
  }

  @override
  void paint(Buffer buffer, Offset offset) {
    final w = widget as WindowManagerWidget;
    final localBuffer = Viewport(
      buffer,
      Rect(offset.dx, offset.dy, size.width, size.height),
    );
    // Fill background with a dark mesh pattern
    localBuffer.fill(Cell('░', const Style(foreground: Color(45, 45, 45))));

    // Sort windows by Z-Index to render bottom-to-top
    final sortedWins = List<Window>.from(w.windowManager.windows)
      ..sort((a, b) => a.zIndex.compareTo(b.zIndex));

    for (final win in sortedWins) {
      final winEl = win.createElement()..mount(null);
      winEl.layout(
        BoxConstraints.tight(Size(localBuffer.width, localBuffer.height)),
      );
      winEl.paint(localBuffer, Offset.zero);
      winEl.unmount();
    }
  }
}

/// Scenario A Example: The Overlapping Multi-Window Dashboard.
class ScenarioAExample extends WidgetBookExample {
  /// The window manager instance.
  late final WindowManager windowManager;

  /// The diagnostics display child widget.
  late final SystemDiagnosticsWidget diagnosticsWidget;

  /// The scanning radar child widget.
  late final RadarWidget radarWidget;

  /// The rotating 3D cube child widget.
  late final SpinningCubeWidget cubeWidget;

  /// The diagnostics window.
  late final Window winDiag;

  /// The scanning radar window.
  late final Window winRadar;

  /// The 3D cube projection window.
  late final Window winCube;

  @override
  bool get capturesMouse => windowManager.isDraggingOrResizing;

  @override
  void init() {
    windowManager = WindowManager();
    diagnosticsWidget = SystemDiagnosticsWidget();
    radarWidget = RadarWidget(style: const Style(background: Colors.black));
    cubeWidget = SpinningCubeWidget(
      style: const Style(background: Colors.black),
    );

    // 1. System Diagnostics Window (Double Border)
    winDiag = Window(
      title: 'System Diagnostics',
      bounds: const Rect(2, 1, 35, 12),
      zIndex: 1,
      borderChars: ['╔', '═', '╗', '║', ' ', '║', '╚', '═', '╝'],
      borderStyle: const Style(
        foreground: Colors.orange,
        background: Colors.black,
      ),
      titleStyle: const Style(
        foreground: Colors.white,
        background: Colors.black,
        modifiers: Modifier.bold,
      ),
      backgroundStyle: const Style(background: Colors.black),
      child: diagnosticsWidget,
    );

    // 2. Network Radar Window (Single Border)
    winRadar = Window(
      title: 'Network Radar',
      bounds: const Rect(30, 2, 30, 11),
      zIndex: 2,
      borderStyle: const Style(
        foreground: Colors.green,
        background: Colors.black,
      ),
      titleStyle: const Style(
        foreground: Colors.white,
        background: Colors.black,
        modifiers: Modifier.bold,
      ),
      backgroundStyle: const Style(background: Colors.black),
      child: radarWidget,
    );

    // 3. 3D Cube Projection Window (Single Border, Quadrants Mode Canvas)
    winCube = Window(
      title: '3D Cube Projection',
      bounds: const Rect(10, 8, 28, 10),
      zIndex: 3,
      borderStyle: const Style(
        foreground: Color(255, 0, 255),
        background: Colors.black,
      ),
      titleStyle: const Style(
        foreground: Colors.white,
        background: Colors.black,
        modifiers: Modifier.bold,
      ),
      backgroundStyle: const Style(background: Colors.black),
      child: winCubeChild(),
    );

    windowManager.addWindow(winDiag);
    windowManager.addWindow(winRadar);
    windowManager.addWindow(winCube);

    winCube.focusNode.requestFocus();
  }

  /// Returns the widget tree for the cube window child.
  Widget winCubeChild() => cubeWidget;

  @override
  bool get requiresTick => true;

  @override
  bool tick(Duration duration) {
    diagnosticsWidget.update();
    radarWidget.frame++;
    cubeWidget.update();
    return true;
  }

  @override
  Widget build({
    required bool focusDemoPane,
    required int width,
    required int height,
  }) {
    // Dynamically constrain window bounds to prevent them going completely offscreen on resize
    for (final win in windowManager.windows) {
      final b = win.bounds;
      final maxX = max(2, width - 10);
      final maxY = max(2, height - 5);
      final newX = b.x.clamp(0, maxX);
      final newY = b.y.clamp(0, maxY);
      win.bounds = Rect(
        newX,
        newY,
        b.width.clamp(10, width),
        b.height.clamp(4, height),
      );
    }

    return WindowManagerWidget(windowManager);
  }

  @override
  bool handleKeyEvent(ui.KeyEvent event) {
    return windowManager.handleKeyEvent(event);
  }

  @override
  void handleMouseEvent(
    ui.MouseEvent event,
    int localX,
    int localY,
    int width,
    int height,
  ) {
    // Map relative mouse coordinates back to SGR absolute (1-indexed) format
    final absoluteEvent = ui.MouseEvent(
      x: localX + 1,
      y: localY + 1,
      type: event.type,
      button: event.button,
      modifiers: event.modifiers,
    );
    windowManager.handleMouseEvent(absoluteEvent);
  }

  @override
  Map<String, String> get helpBindings => {
    'Mouse Click': 'Focus / Bring to Front',
    'Title Drag': 'Move Window',
    'Bottom Corners': 'Resize Window',
  };
}
