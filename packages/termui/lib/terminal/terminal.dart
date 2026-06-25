import 'dart:async';
import 'dart:math';

import 'package:termui/direction.dart';
import 'event.dart';
export 'event.dart';
import 'input_parser.dart';
import 'package:termui/terminal/backend/terminal_backend.dart';
export 'package:termui/terminal/backend/terminal_backend.dart';
import 'package:termui/terminal/backend/stub_backend.dart'
    if (dart.library.io) 'package:termui/terminal/backend/io_backend.dart'
    if (dart.library.js_interop) 'package:termui/terminal/backend/web_backend.dart';

/// Represents a parsed ANSI control sequence from the terminal input.
class ControlSequence {
  /// The parameter values associated with this sequence.
  final List<int> values;

  /// The command character code.
  final int command;

  /// Creates a new control sequence with the given [command] and [values].
  ControlSequence(this.command, this.values);
}

/// The main entry point for interacting with the terminal backend.
///
/// Handles input parsing, cursor manipulation, and querying terminal dimensions.
class Terminal {
  /// The underlying platform-specific terminal implementation.
  final TerminalBackend backend;

  /// Retrieves the current dimensions (width and height) of the terminal.
  Future<Point<int>> get size async {
    final termPoint = backend.size;
    if (termPoint != const Point(-1, -1)) {
      return termPoint;
    }

    try {
      var startPos = await cursorPosition();
      backend.write('\x1b[900;900H');
      final bottomRight = await cursorPosition();
      backend.write('\x1b[${startPos.y};${startPos.x}H');
      return bottomRight;
    } catch (_) {
      return const Point(80, 24);
    }
  }

  /// Returns a stream that emits new dimensions whenever the terminal is resized.
  Stream<Point<int>> watchSize() {
    return backend.watchSize();
  }

  final _events = StreamController<InputEvent>.broadcast();

  /// Reads a single input event from the terminal asynchronously.
  Future<InputEvent> readInput() => _events.stream.first;

  /// A stream of all incoming input events from the terminal.
  Stream<InputEvent> get events => _events.stream;

  StreamSubscription<List<int>>? _stdinSubscription;

  /// Runs a function with a raw terminal, ensuring raw mode is disabled and the
  /// terminal is restored if the program encounters an uncaught exception.
  static Future<T> runGuarded<T>(
    FutureOr<T> Function(Terminal terminal) body, {
    TerminalBackend? backend,
  }) async {
    final terminal = Terminal(backend);
    final completer = Completer<T>();

    runZonedGuarded(
      () async {
        try {
          final result = await body(terminal);
          if (!completer.isCompleted) {
            completer.complete(result);
          }
        } catch (e, st) {
          if (!completer.isCompleted) {
            completer.completeError(e, st);
          }
        }
      },
      (error, stackTrace) {
        terminal.dispose();
        terminal.showCursor(); // Re-enable cursor
        if (!completer.isCompleted) {
          completer.completeError(error, stackTrace);
        }
      },
    );

    try {
      return await completer.future;
    } finally {
      terminal.dispose();
      terminal.showCursor(); // Re-enable cursor
    }
  }

  /// Creates a new terminal using the specified [backend].
  ///
  /// If no backend is provided, uses the platform-specific default backend.
  Terminal([TerminalBackend? backend])
    : backend = backend ?? getPlatformBackend() {
    _parser = InputParser(isWindows: this.backend.isWindows);
    this.backend.enableRawMode();
    _stdinSubscription = this.backend.rawInput.listen(
      (List<int> chunk) {
        final parsed = _parser.parse(chunk);
        for (final event in parsed) {
          if (event is CursorPositionReportEvent) {
            if (_cursorCallback != null && !_cursorCallback!.isCompleted) {
              _cursorCallback!.complete(Point<int>(event.x, event.y));
            }
            _cursorCallback = null;
          } else {
            _events.add(event);
          }
        }
      },
      onDone: () {
        _events.close();
      },
    );
  }

  /// Disposes of the terminal resources and disables raw mode.
  void dispose() {
    _stdinSubscription?.cancel();
    _events.close();
    backend.disableRawMode();
    backend.dispose();
  }

  Completer<Point<int>>? _cursorCallback;

  late final InputParser _parser;

  /// Requests the current coordinates of the cursor asynchronously.
  Future<Point<int>> cursorPosition() async {
    if (_cursorCallback != null) {
      try {
        await _cursorCallback!.future;
      } catch (_) {}
      return await cursorPosition();
    }
    final completer = Completer<Point<int>>();
    _cursorCallback = completer;

    backend.write('\x1b[6n');
    try {
      final pos = await completer.future.timeout(
        const Duration(milliseconds: 200),
      );
      return pos;
    } catch (_) {
      if (_cursorCallback == completer) {
        _cursorCallback = null;
      }
      rethrow;
    }
  }

  /// Clears the entire terminal screen.
  void clear() {
    backend.write('\x1b[2J');
  }

  /// Moves the cursor to the top-left corner (home) of the terminal.
  void home() {
    backend.write('\x1b[H');
  }

  /// Moves the cursor to the specified 1-based [x] and [y] coordinates.
  void goto({required int x, required int y}) {
    assert(x > 0 && y > 0);
    backend.write('\x1b[$y;${x}H');
  }

  /// Moves the cursor a relative number of [places] in the given [dir] direction.
  void relative({Direction dir = Direction.down, required int places}) {
    backend.write('\x1b[$places${dir.character}');
  }

  /// Sequence to hide the terminal cursor.
  static const String hideCursorSequence = '\x1b[?25l';

  /// Sequence to show the terminal cursor.
  static const String showCursorSequence = '\x1b[?25h';

  /// Sequence to enter the alternate screen buffer.
  static const String enterAlternateScreenSequence = '\x1b[?1049h';

  /// Sequence to exit the alternate screen buffer.
  static const String exitAlternateScreenSequence = '\x1b[?1049l';

  /// Sequence to enable mouse click and drag tracking.
  static const String enableMouseTrackingSequence = '\x1b[?1003h\x1b[?1006h';

  /// Sequence to disable mouse click and drag tracking.
  static const String disableMouseTrackingSequence = '\x1b[?1003l\x1b[?1006l';

  /// Sequence to reset all text styling to defaults.
  static const String resetStyleSequence = '\x1b[0m';

  /// Sends the sequence to hide the terminal cursor.
  void hideCursor() => backend.write(hideCursorSequence);

  /// Sends the sequence to show the terminal cursor.
  void showCursor() => backend.write(showCursorSequence);

  /// Sends the sequence to enter the alternate screen buffer.
  void enterAlternateScreen() => backend.write(enterAlternateScreenSequence);

  /// Sends the sequence to exit the alternate screen buffer.
  void exitAlternateScreen() => backend.write(exitAlternateScreenSequence);

  /// Sends the sequence to enable mouse tracking.
  void enableMouseTracking() => backend.write(enableMouseTrackingSequence);

  /// Sends the sequence to disable mouse tracking.
  void disableMouseTracking() => backend.write(disableMouseTrackingSequence);

  /// Sends the sequence to reset all cell styling back to default.
  void resetStyle() => backend.write(resetStyleSequence);

  /// Sets the mouse pointer shape to the specified [pointer] type.
  ///
  /// Note: This uses the `OSC 22` escape sequence, which is supported by some
  /// modern terminal emulators (such as Kitty or xterm), but is ignored
  /// by others (such as iTerm2 or Windows Terminal).
  void setMousePointer(MousePointer pointer) {
    backend.write('\x1b]22;${pointer.value}\x1b\\');
  }

  /// Resets the mouse pointer shape back to the terminal's default pointer.
  void resetMousePointer() {
    const terminator = '\x1b\\';
    backend.write('\x1b]22;$terminator');
  }
}

/// Represents the mouse pointer shapes supported by compatible terminals via OSC 22.
enum MousePointer {
  /// The platform default cursor (usually an arrow).
  defaultCursor('default'),

  /// Text selection cursor (I-beam).
  text('text'),

  /// Hand/pointing cursor (indicates a link or clickable element).
  pointer('pointer'),

  /// Crosshair cursor (precision selection).
  crosshair('crosshair'),

  /// Help cursor (arrow with question mark).
  help('help'),

  /// Busy cursor with background activity indicator.
  progress('progress'),

  /// Busy/loading cursor (hourglass or spinner).
  wait('wait'),

  /// Move/drag cursor (four-directional arrows).
  move('move'),

  /// Prohibited action cursor (circle with slash).
  notAllowed('not-allowed'),

  /// Open hand cursor (before grabbing).
  grab('grab'),

  /// Closed hand cursor (while dragging).
  grabbing('grabbing'),

  /// Invisible cursor.
  none('none'),

  /// Alias/shortcut cursor (arrow with link badge).
  alias('alias'),

  /// Copy cursor (arrow with a plus sign).
  copy('copy'),

  /// Cell selection cursor (thick crosshair).
  cell('cell'),

  /// Item not allowed to be dropped here (circle with a diagonal slash).
  noDrop('no-drop'),

  /// Zoom-in cursor (magnifying glass with plus).
  zoomIn('zoom-in'),

  /// Zoom-out cursor (magnifying glass with minus).
  zoomOut('zoom-out'),

  /// Vertical resize cursor (two-headed vertical arrow).
  resizeUpDown('ns-resize'),

  /// Horizontal resize cursor (two-headed horizontal arrow).
  resizeLeftRight('ew-resize'),

  /// All-scroll cursor (four-way arrow indicator).
  allScroll('all-scroll');

  /// The parameter value for the OSC 22 sequence.
  final String value;

  const MousePointer(this.value);
}
