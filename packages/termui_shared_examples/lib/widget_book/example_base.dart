import 'package:termui/ui/buffer.dart';
import 'package:termui/ui/layout.dart';
import 'package:termui/ui/event.dart' as ui;
import 'package:termui/terminal/terminal.dart' as core;

/// Base class for a single page example within the Widget Book.
abstract class WidgetBookExample {
  /// The terminal instance.
  core.Terminal? terminal;

  /// Attaches the active terminal instance to this example page.
  void attachTerminal(core.Terminal terminal) {
    this.terminal = terminal;
  }

  /// Initialize widgets and state.
  void init() {}

  /// Build the widget layout tree for this demo page.
  Widget build({
    required bool focusDemoPane,
    required int width,
    required int height,
  });

  /// Handle a key event when the demo pane is focused.
  /// Returns true if the event was consumed, false otherwise.
  bool handleKeyEvent(ui.KeyEvent event) => false;

  /// Handle a mouse event when inside the demo pane bounds.
  void handleMouseEvent(
    ui.MouseEvent event,
    int localX,
    int localY,
    int width,
    int height,
  ) {}

  /// Periodic tick for animations/timers.
  void tick(Duration duration) {}

  /// Whether this example currently has an active overlay (e.g. modal).
  bool get hasActiveOverlay => false;

  /// Whether this example currently captures the mouse (e.g. during a window drag/resize operation).
  bool get capturesMouse => false;

  /// Render overlay elements (like modal dialogs) on the full screen buffer.
  void renderOverlay(Buffer buffer, int width, int height) {}

  /// Handle key events when the overlay is active.
  void handleOverlayKeyEvent(ui.KeyEvent event) {}

  /// Handle mouse events when the overlay is active.
  void handleOverlayMouseEvent(
    ui.MouseEvent event,
    int x,
    int y,
    int width,
    int height,
  ) {}

  /// Help bindings specific to this page when focused.
  Map<String, String> get helpBindings => {};
}
