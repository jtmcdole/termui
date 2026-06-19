import 'package:termui/termui.dart';
import 'package:termui/ui/event.dart' as ui;

/// Interface defining platform-specific behavior needed by the shared Widget Book.
abstract class WidgetBookPlatform {
  /// Invoked when a new frame is drawn to notify the host platform.
  void onFrameRedrawn(Buffer buffer);

  /// Whether the runner should render ANSI sequences directly to the terminal stdout.
  /// True on CLI/TTY platforms, false on virtual/embedded canvases like Flutter.
  bool get shouldRenderToTerminal;

  /// Starts the periodic animation ticker loop.
  void startTicker(void Function(Duration elapsed) onTick);

  /// Stops the active animation ticker loop.
  void stopTicker();

  /// Processes platform-specific key events (like Flutter's font resizing shortcuts).
  /// Returns `true` if the event was handled and consumed.
  bool handleKeyEvent(Terminal terminal, ui.KeyEvent event);

  /// Handles clean up and platform-specific exit logic.
  void onExit();
}
