import 'dart:async';
import 'dart:math';
import 'package:termui/terminal/terminal.dart';
import 'package:termui/ui/event.dart' as ui;

/// A mock implementation of [Terminal] that allows direct event injection
/// without going through ANSI byte parsing.
class MockTerminal extends Terminal {
  final _eventsController = StreamController<ui.InputEvent>.broadcast();

  /// Whether the cursor is currently visible.
  bool isCursorVisible = true;

  /// Creates a [MockTerminal] with the given backend.
  MockTerminal(super.backend);

  @override
  Stream<ui.InputEvent> get events => _eventsController.stream;

  @override
  void showCursor() {
    isCursorVisible = true;
    super.showCursor();
  }

  @override
  void hideCursor() {
    isCursorVisible = false;
    super.hideCursor();
  }

  /// Whether mouse tracking is currently enabled.
  bool mouseTrackingEnabled = false;

  @override
  void enableMouseTracking() {
    mouseTrackingEnabled = true;
    super.enableMouseTracking();
  }

  @override
  void disableMouseTracking() {
    mouseTrackingEnabled = false;
    super.disableMouseTracking();
  }

  /// Directly injects a structured [InputEvent] into the terminal event stream.
  void injectTestEvent(ui.InputEvent event) {
    _eventsController.add(event);
  }

  /// Injects a terminal resize event.
  void injectResize(Point<int> newSize) {
    try {
      (backend as dynamic).size = newSize;
    } catch (_) {}
  }

  @override
  void dispose() {
    _eventsController.close();
    super.dispose();
  }
}
