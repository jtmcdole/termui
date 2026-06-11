import 'package:termui/terminal/terminal.dart' as core;
import 'package:termui/terminal/backend/terminal_backend.dart';
import 'package:termui/ui/event.dart' as core_event;
import 'package:termui/perf/tracer.dart';
import 'dart:async';
import 'dart:math';

/// An in-memory, mock terminal backend implementation.
///
/// This backend implements [TerminalBackend] without binding to a native
/// OS terminal or standard streams (`stdin`/`stdout`). It is designed for
/// testing, graphics-based embedding, and hosting TUI apps in GUI environments.
///
/// It maintains terminal size in memory and provides a broadcast stream to
/// notify listeners of dimension updates.
///
/// ### Example Usage
///
/// ```dart
/// final backend = FlutterTerminalBackend();
/// print('Size: ${backend.size}'); // Defaults to 80x24
///
/// backend.watchSize().listen((newSize) {
///   print('Term resized to: $newSize');
/// });
///
/// backend.updateSize(const Point(120, 40));
/// ```
class FlutterTerminalBackend implements TerminalBackend {
  Point<int> _size = const Point(80, 24);
  final _sizeController = StreamController<Point<int>>.broadcast();
  final _mouseCursorController = StreamController<String?>.broadcast();

  static const _esc = '\x1b';
  static const _bel = '\x07';

  /// Matches OSC 22 sequences. Capture Group 1 extracts the cursor shape name.
  static final RegExp _osc22Regex = RegExp(
    '$_esc\\]22;([^$_esc$_bel]*)(?:$_esc\\\\|$_bel)',
  );

  @override
  bool get isWindows => false;

  @override
  Stream<List<int>> get rawInput => const Stream.empty();

  @override
  void write(String data) {
    final matches = _osc22Regex.allMatches(data);
    if (matches.isNotEmpty) {
      final lastMatch = matches.last;
      final cursorName = lastMatch.group(1);
      _mouseCursorController.add(cursorName == '' ? null : cursorName);
    }
  }

  @override
  Point<int> get size => _size;

  @override
  Stream<Point<int>> watchSize() => _sizeController.stream;

  /// Stream emitting the active OSC 22 mouse cursor name requested by the TUI.
  Stream<String?> get mouseCursorChanges => _mouseCursorController.stream;

  /// Updates the terminal size and notifies listeners via [watchSize].
  ///
  /// | Parameter | Type | Description |
  /// | :--- | :--- | :--- |
  /// | `newSize` | [Point]<[int]> | The new terminal dimensions in columns and rows. |
  void updateSize(Point<int> newSize) {
    if (_size != newSize) {
      _size = newSize;
      _sizeController.add(newSize);
    }
  }

  @override
  void enableRawMode() {}

  @override
  void disableRawMode() {}

  @override
  void dispose() {
    _sizeController.close();
    _mouseCursorController.close();
  }
}

/// A custom terminal implementation managed by the Flutter frontend.
///
/// It acts as the bridge between Flutter's lifecycle and layout engine, and the
/// termui package. It manages the active terminal size, listens for GUI-based
/// events (keyboard, mouse), and manages font sizing/scaling.
///
/// It provides utility methods to dynamically change the scale (font size)
/// of the rendered terminal and lets the renderer adapt layout properties.
///
/// ### Example Usage
///
/// ```dart
/// final terminal = FlutterTerminal(initialFontSize: 14.0);
///
/// terminal.watchFontSize().listen((newSize) {
///   print('Font size adjusted to: $newSize');
/// });
///
/// terminal.increaseFontSize(2.0);
/// ```
class FlutterTerminal extends core.Terminal {
  final _eventsController = StreamController<core_event.InputEvent>.broadcast();
  final _initialSizeCompleter = Completer<Point<int>>();
  final _fontSizeController = StreamController<double>.broadcast();
  double _fontSize;

  /// Stream emitting changes to the TUI's requested mouse cursor.
  Stream<String?> get mouseCursorChanges => _flutterBackend.mouseCursorChanges;

  static final int _traceSetFontSizeId = Tracer.registerString(
    'FlutterTerminal:setFontSize',
  );
  static final int _traceIncreaseFontSizeId = Tracer.registerString(
    'FlutterTerminal:increaseFontSize',
  );
  static final int _traceDecreaseFontSizeId = Tracer.registerString(
    'FlutterTerminal:decreaseFontSize',
  );

  /// Creates a new [FlutterTerminal] instance.
  ///
  /// | Parameter | Type | Description |
  /// | :--- | :--- | :--- |
  /// | `initialFontSize` | [double] | The starting font size. Defaults to `13.0`. |
  FlutterTerminal({double initialFontSize = 13.0})
    : _fontSize = initialFontSize,
      super(FlutterTerminalBackend());

  FlutterTerminalBackend get _flutterBackend =>
      backend as FlutterTerminalBackend;

  /// Returns the current font size used to render the terminal.
  double get fontSize => _fontSize;

  /// A stream that emits the font size whenever it changes.
  Stream<double> watchFontSize() => _fontSizeController.stream;

  /// Sets the rendering font size, clamped between `4.0` and `72.0`.
  ///
  /// | Parameter | Type | Description |
  /// | :--- | :--- | :--- |
  /// | `size` | [double] | The target font size. |
  void setFontSize(double size) {
    Tracer.record(_traceSetFontSizeId, Phase.instant);
    final clamped = size.clamp(4.0, 72.0);
    if (_fontSize != clamped) {
      _fontSize = clamped;
      _fontSizeController.add(clamped);
    }
  }

  /// Increases the current font size by [delta].
  ///
  /// | Parameter | Type | Description |
  /// | :--- | :--- | :--- |
  /// | `delta` | [double] | The amount to increase by. Defaults to `1.0`. |
  void increaseFontSize([double delta = 1.0]) {
    Tracer.record(_traceIncreaseFontSizeId, Phase.instant);
    setFontSize(_fontSize + delta);
  }

  /// Decreases the current font size by [delta].
  ///
  /// | Parameter | Type | Description |
  /// | :--- | :--- | :--- |
  /// | `delta` | [double] | The amount to decrease by. Defaults to `1.0`. |
  void decreaseFontSize([double delta = 1.0]) {
    Tracer.record(_traceDecreaseFontSizeId, Phase.instant);
    setFontSize(_fontSize - delta);
  }

  @override
  Future<Point<int>> get size async {
    if (_flutterBackend.size != const Point(80, 24) ||
        _initialSizeCompleter.isCompleted) {
      return _flutterBackend.size;
    }
    return _initialSizeCompleter.future;
  }

  @override
  Stream<Point<int>> watchSize() => _flutterBackend.watchSize();

  @override
  Stream<core_event.InputEvent> get events => _eventsController.stream;

  /// Updates the underlying terminal size and resolves the size future.
  ///
  /// | Parameter | Type | Description |
  /// | :--- | :--- | :--- |
  /// | `newSize` | [Point]<[int]> | The new dimensions of the terminal grid. |
  void updateSize(Point<int> newSize) {
    _flutterBackend.updateSize(newSize);
    if (!_initialSizeCompleter.isCompleted) {
      _initialSizeCompleter.complete(newSize);
    }
  }

  /// Injects a [core_event.InputEvent] into the event loop stream.
  ///
  /// | Parameter | Type | Description |
  /// | :--- | :--- | :--- |
  /// | `event` | [core_event.InputEvent] | The keyboard/mouse/paste/focus event to inject. |
  void injectEvent(core_event.InputEvent event) {
    if (!_eventsController.isClosed) {
      _eventsController.add(event);
    }
  }

  @override
  void dispose() {
    _eventsController.close();
    _fontSizeController.close();
    _flutterBackend.dispose();
    super.dispose();
  }
}
