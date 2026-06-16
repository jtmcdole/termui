import 'dart:async';
import 'dart:math';
import 'package:file/file.dart';
import 'package:fake_async/fake_async.dart';
import 'package:test_api/hooks.dart';
import 'package:termui/termui.dart';
import 'package:termui/perf/fs_locator.dart';
import 'package:termui_recorder/termui_recorder.dart';
import 'mock_backend.dart';
import 'finders.dart';
import 'utils.dart' as utils;

/// Representation of standard terminal keys for simulation.
class LogicalKey {
  /// The raw escape sequence string.
  final String escapeSequence;

  /// Human-readable debug name.
  final String debugName;

  /// Creates a [LogicalKey] with the given escape sequence and debug name.
  const LogicalKey(this.escapeSequence, this.debugName);

  /// Arrow Up key.
  static const LogicalKey arrowUp = LogicalKey('\x1b[A', 'arrowUp');

  /// Arrow Down key.
  static const LogicalKey arrowDown = LogicalKey('\x1b[B', 'arrowDown');

  /// Arrow Right key.
  static const LogicalKey arrowRight = LogicalKey('\x1b[C', 'arrowRight');

  /// Arrow Left key.
  static const LogicalKey arrowLeft = LogicalKey('\x1b[D', 'arrowLeft');

  /// Enter / Carriage Return.
  static const LogicalKey enter = LogicalKey('\r', 'enter');

  /// Escape key.
  static const LogicalKey escape = LogicalKey('\x1b', 'escape');

  /// Tab key.
  static const LogicalKey tab = LogicalKey('\t', 'tab');

  /// Backspace key.
  static const LogicalKey backspace = LogicalKey('\x7f', 'backspace');

  /// Delete key.
  static const LogicalKey delete = LogicalKey('\x1b[3~', 'delete');

  /// Home key.
  static const LogicalKey home = LogicalKey('\x1b[H', 'home');

  /// End key.
  static const LogicalKey end = LogicalKey('\x1b[F', 'end');

  /// Page Up key.
  static const LogicalKey pageUp = LogicalKey('\x1b[5~', 'pageUp');

  /// Page Down key.
  static const LogicalKey pageDown = LogicalKey('\x1b[6~', 'pageDown');

  /// F1 key.
  static const LogicalKey f1 = LogicalKey('\x1bOP', 'f1');

  /// F2 key.
  static const LogicalKey f2 = LogicalKey('\x1bOQ', 'f2');

  /// F3 key.
  static const LogicalKey f3 = LogicalKey('\x1bOR', 'f3');

  /// F4 key.
  static const LogicalKey f4 = LogicalKey('\x1bOS', 'f4');

  /// F5 key.
  static const LogicalKey f5 = LogicalKey('\x1b[15~', 'f5');

  /// F6 key.
  static const LogicalKey f6 = LogicalKey('\x1b[17~', 'f6');

  /// F7 key.
  static const LogicalKey f7 = LogicalKey('\x1b[18~', 'f7');

  /// F8 key.
  static const LogicalKey f8 = LogicalKey('\x1b[19~', 'f8');

  /// F9 key.
  static const LogicalKey f9 = LogicalKey('\x1b[20~', 'f9');

  /// F10 key.
  static const LogicalKey f10 = LogicalKey('\x1b[21~', 'f10');

  /// F11 key.
  static const LogicalKey f11 = LogicalKey('\x1b[23~', 'f11');

  /// F12 key.
  static const LogicalKey f12 = LogicalKey('\x1b[24~', 'f12');

  /// Ctrl+C.
  static const LogicalKey controlC = LogicalKey('\x03', 'controlC');

  /// Ctrl+D.
  static const LogicalKey controlD = LogicalKey('\x04', 'controlD');

  /// Returns a custom key wrapping a character value.
  static LogicalKey character(String char) {
    return LogicalKey(char, char);
  }
}

/// The integration testing binding and execution wrapper.
class TerminalTester {
  final bool _isWindows;
  final Point<int>? _size;

  /// Whether to record asciicast trace recordings.
  final bool recordTraces;

  final List<String> _actionLog = [];

  /// The log of simulated actions executed by this tester.
  List<String> get actionLog => List.unmodifiable(_actionLog);

  MockTerminalBackend? _backend;
  Terminal? _terminal;

  AsciicastRecorder? _recorder;
  int _lastRecordedActionIndex = 0;

  /// The mock terminal backend providing buffered standard I/O.
  MockTerminalBackend get backend =>
      _backend ??
      (throw StateError(
        'TerminalTester must be run using tester.run(...) before accessing backend',
      ));

  /// The active [Terminal] bound to [backend].
  Terminal get terminal =>
      _terminal ??
      (throw StateError(
        'TerminalTester must be run using tester.run(...) before accessing terminal',
      ));

  PromptRunner? _runner;
  FakeAsync? _fakeAsync;
  Element? _rootElement;
  Buffer? _testBuffer;

  /// Current buffer or null.
  Buffer? get buffer => _testBuffer;

  /// The currently active tester instance in this execution context.
  static TerminalTester? get active => _active;
  static TerminalTester? _active;

  /// Creates a [TerminalTester] wrapper.
  TerminalTester({
    bool isWindows = false,
    Point<int>? size,
    bool recordTraces = false,
  }) : _isWindows = isWindows,
       _size = size,
       recordTraces =
           recordTraces &&
           const bool.fromEnvironment('ASCIICAST_TESTS', defaultValue: true);

  /// The root element of the active widget tree being tested.
  Element? get rootElement => _runner?.rootElement ?? _rootElement;

  /// Executes the test callback within a controlled [FakeAsync] time environment.
  void run(Future<void> Function() callback) {
    _active = this;
    _actionLog.clear();
    _lastRecordedActionIndex = 0;
    if (recordTraces) {
      final fs = getDefaultFileSystem();
      var filename = 'trace';
      final currentTestName = TestHandle.current.name;
      filename = sanitizeTestName(currentTestName);
      Directory parentDir = fs.currentDirectory;
      try {
        final dummyFile = fs.file('.write_test');
        dummyFile.writeAsStringSync('');
        dummyFile.deleteSync();
      } catch (_) {
        parentDir = fs.systemTempDirectory;
      }
      final file = parentDir.childFile('$filename.cast');
      final w = _size?.x ?? 80;
      final h = _size?.y ?? 24;
      _recorder = AsciicastRecorder(
        FileAsciicastWriter(file),
        width: w,
        height: h,
      );
    }
    try {
      fakeAsync((async) {
        _fakeAsync = async;
        _backend = MockTerminalBackend(isWindows: _isWindows, size: _size);
        _terminal = Terminal(_backend!);

        final oldOnPromptStarted = PromptRunner.onPromptStarted;
        final oldOnPromptEnded = PromptRunner.onPromptEnded;
        PromptRunner.onPromptStarted = (runner) {
          if (runner.terminal == _terminal) {
            _runner = runner;
          }
        };
        PromptRunner.onPromptEnded = (runner) {
          if (_runner == runner) {
            _runner = null;
          }
        };

        final future = callback();
        var completed = false;
        var hasError = false;
        Object? error;
        StackTrace? stackTrace;

        future
            .then((_) {
              completed = true;
            })
            .catchError((Object e, StackTrace st) {
              completed = true;
              hasError = true;
              error = e;
              stackTrace = st;
            });

        try {
          while (!completed) {
            async.elapse(const Duration(milliseconds: 1));
          }
        } finally {
          PromptRunner.onPromptStarted = oldOnPromptStarted;
          PromptRunner.onPromptEnded = oldOnPromptEnded;
          _backend?.dispose();
          _active = null;
        }

        if (hasError) {
          Error.throwWithStackTrace(error!, stackTrace!);
        }
      });
    } finally {
      _recorder?.close();
      _recorder = null;
    }
  }

  /// Runs an interactive [PromptRunner] within the tester context.
  Future<T?> runPrompt<T>(
    PromptRunner<T> runner,
    Future<void> Function() callback,
  ) async {
    _runner = runner;
    final Future<T?> runnerFuture = runner.run();
    await callback();
    return runnerFuture;
  }

  /// Mounts a static widget for unit testing without a full prompt run loop.
  Future<void> pumpWidget(
    Widget widget, {
    Size size = const Size(80, 24),
  }) async {
    _rootElement?.unmount();
    _testBuffer = Buffer.blank(size.width.toInt(), size.height.toInt());
    _rootElement = widget.createElement()..mount(null);
    await pump();
  }

  /// Advances time, flushes pending microtasks, and forces a layout/paint pass.
  Future<void> pump([Duration? duration]) async {
    if (duration != null && duration > Duration.zero) {
      _fakeAsync?.elapse(duration);
    } else {
      _fakeAsync?.flushMicrotasks();
    }

    if (_runner != null) {
      _runner!.pump();
    } else if (_rootElement != null && _testBuffer != null) {
      _rootElement!.rebuild();
      _rootElement!.layout(
        BoxConstraints.tight(Size(_testBuffer!.width, _testBuffer!.height)),
      );
      _rootElement!.paint(_testBuffer!, Offset.zero);
    }

    _fakeAsync?.flushMicrotasks();

    if (recordTraces) {
      final poppedActions = _actionLog.sublist(_lastRecordedActionIndex);
      _lastRecordedActionIndex = _actionLog.length;
      final activeBuffer = _testBuffer ?? backend.buffer;
      if (activeBuffer != null) {
        _recorder?.recordFrame(activeBuffer, poppedActions);
      }
    }
  }

  /// Continuously advances time until there are no pending microtasks or timers.
  Future<int> pumpAndSettle({
    Duration duration = const Duration(milliseconds: 10),
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final watch = Stopwatch()..start();
    var count = 0;

    await pump();
    count++;

    while (_fakeAsync != null &&
        (_fakeAsync!.pendingTimers.isNotEmpty ||
            _fakeAsync!.microtaskCount > 0)) {
      if (watch.elapsed > timeout) {
        throw TimeoutException('pumpAndSettle timed out');
      }
      await pump(duration);
      count++;
    }
    return count;
  }

  /// Helper function to simulate typing a string
  void typeText(String text) {
    for (final char in text.split('')) {
      sendKey(LogicalKey.character(char));
    }
  }

  /// Simulates typing a key string.
  void sendString(String value) {
    _actionLog.add('Type: $value');
    _sendStringRaw(value);
  }

  void _sendStringRaw(String value) {
    // Write to the terminal's actual backend (which is terminal.backend)
    // Wait, the tester is initialized with terminal, which has its own backend.
    // So we should write to terminal.backend!
    final b = terminal.backend;
    if (b is MockTerminalBackend) {
      b.pushString(value);
    }
    _fakeAsync?.flushMicrotasks();
  }

  /// Simulates pressing a key.
  /// Simulates pressing a key with optional modifiers.
  void sendKey(
    LogicalKey key, {
    bool control = false,
    bool shift = false,
    bool alt = false,
  }) {
    _actionLog.add('Key: ${key.debugName}');
    // Explicitly trap Enter
    if (key == LogicalKey.enter) {
      _sendStringRaw('\n');
      return;
    }

    // Explicitly trap Shift+Tab (Back Tab)
    if (key == LogicalKey.tab && shift && !control && !alt) {
      sendString('\x1b[Z');
      return;
    }

    // Explicitly trap Control+Backspace
    if (key == LogicalKey.backspace && control && !alt && !shift) {
      // \x1b[ = CSI, 127 = Backspace, 5 = Control modifier, u = Kitty protocol
      _sendStringRaw('\x1b[127;5u');
      return;
    }

    final baseSeq = key.escapeSequence;

    // 1. Calculate the standard xterm modifier code
    // Base is 1. Add 1 for Shift, 2 for Alt, 4 for Control.
    final modifierValue =
        1 + (shift ? 1 : 0) + (alt ? 2 : 0) + (control ? 4 : 0);

    // If no modifiers are pressed, send the raw sequence
    if (modifierValue == 1) {
      _sendStringRaw(baseSeq);
      return;
    }

    // 2. Handle ASCII Control Characters (e.g., Ctrl+Z, Ctrl+W)
    // If the base sequence is a single character and Control is held
    if (baseSeq.length == 1 && control && !alt) {
      final charCode = baseSeq.toUpperCase().codeUnitAt(0);
      // Letters A-Z fall between 65 and 90 on the ASCII table.
      // Control maps them down to 1-26.
      if (charCode >= 64 && charCode <= 95) {
        final ctrlChar = String.fromCharCode(charCode - 64);
        _sendStringRaw(ctrlChar);
        return;
      }
    }

    // 3. Handle Special VT100 Escape Sequences (e.g., Ctrl+Left, Shift+Home)
    if (baseSeq.startsWith('\x1b[')) {
      final content = baseSeq.substring(2); // Strip the '\x1b[' prefix

      if (content.length == 1) {
        // Arrow keys / Home / End: \x1b[D becomes \x1b[1;5D
        _sendStringRaw('\x1b[1;$modifierValue$content');
      } else if (content.endsWith('~')) {
        // Extended keys like Delete: \x1b[3~ becomes \x1b[3;5~
        final numberPart = content.substring(0, content.length - 1);
        _sendStringRaw('\x1b[$numberPart;$modifierValue~');
      } else {
        // Fallback for unknown multi-char sequences
        _sendStringRaw(baseSeq);
      }
      return;
    }

    // Fallback if we don't know how to modify the key safely
    _sendStringRaw(baseSeq);
  }

  int _getButtonCode(MouseButton button) => switch (button) {
    MouseButton.left => 0,
    MouseButton.middle => 1,
    MouseButton.right => 2,
    MouseButton.none => 3,
    MouseButton.wheelUp => 64,
    MouseButton.wheelDown => 65,
  };

  /// Simulates pressing a mouse button down at the given coordinate.
  void mouseDown(int x, int y, {MouseButton button = MouseButton.left}) {
    final btnVal = _getButtonCode(button);
    _sendStringRaw('\x1b[<$btnVal;$x;${y}M');
  }

  /// Simulates releasing a mouse button at the given coordinate.
  void mouseUp(int x, int y, {MouseButton button = MouseButton.left}) {
    final btnVal = _getButtonCode(button);
    _sendStringRaw('\x1b[<$btnVal;$x;${y}m');
  }

  /// Simulates moving the mouse to the given coordinate.
  /// If [drag] is true (default), simulates dragging with the specified [button] pressed.
  /// If [drag] is false, simulates a hover movement (no button pressed).
  void mouseMove(
    int x,
    int y, {
    bool drag = true,
    MouseButton button = MouseButton.left,
  }) {
    if (drag) {
      final btnVal = _getButtonCode(button) | 32;
      _sendStringRaw('\x1b[<$btnVal;$x;${y}M');
    } else {
      _sendStringRaw('\x1b[<35;$x;${y}M');
    }
  }

  /// Resolves the center coordinate of the widget matched by [finder] and simulates a mouse click.
  void tap(Finder finder, {MouseButton button = MouseButton.left}) {
    _actionLog.add('Tap: $finder');
    final root = rootElement;
    if (root == null) {
      throw StateError(
        'No active rootElement. Did you call runPrompt or pumpWidget?',
      );
    }
    final elements = finder.apply(collectAllElements(root));
    if (elements.isEmpty) {
      throw StateError('tap failed: no widgets found matching $finder');
    }
    if (elements.length > 1) {
      throw StateError('tap failed: multiple widgets found matching $finder');
    }
    final element = elements.first;

    // Calculate absolute position
    final absoluteOffset = _getAbsoluteElementOffset(element);
    final size = element.size;

    // Center coordinates (1-indexed terminal columns/rows)
    final int x = (absoluteOffset.dx + 1 + (size.width ~/ 2));
    final int y = (absoluteOffset.dy + 1 + (size.height ~/ 2));

    // Mouse Down
    mouseDown(x, y, button: button);
    // Mouse Up
    mouseUp(x, y, button: button);
  }

  /// Simulates a terminal resize event.
  ///
  /// Updates the mock backend size, notifies size watchers, resizes the internal
  /// test buffer if in [pumpWidget] mode, and triggers a layout/paint pass.
  Future<void> simulateResize(Size newSize) async {
    _actionLog.add('Resize: $newSize');
    final b = terminal.backend;
    if (b is MockTerminalBackend) {
      b.size = Point<int>(newSize.width, newSize.height);
    }
    if (_rootElement != null && _testBuffer != null) {
      _testBuffer = Buffer.blank(newSize.width, newSize.height);
    }
    await pump();
  }

  Offset _getAbsoluteElementOffset(Element element) {
    Offset offset = Offset.zero;
    Element? current = element;
    while (current != null) {
      offset += current.relativeOffset;
      current = current.parent;
    }
    return offset;
  }

  /// Prints a tree from the root element.
  void debugDumpTree([int depth = 0]) {
    utils.debugDumpTree(rootElement, depth);
  }
}

/// Sanitizes a test name into a valid, safe filename.
String sanitizeTestName(String name) {
  final sanitized = name
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9_-]'), '_')
      .replaceAll(RegExp(r'_{2,}'), '_')
      .replaceAll(RegExp(r'^_+|_+$'), '');
  return sanitized.isEmpty ? 'trace' : sanitized;
}
