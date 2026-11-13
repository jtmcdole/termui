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
final class FlutterTerminalBackend implements TerminalBackend {
  Point<int> _size = const Point(80, 24);
  final _sizeController = StreamController<Point<int>>.broadcast();
  final _mouseCursorController = StreamController<String?>.broadcast();
  final _clipboardController = StreamController<String>.broadcast(sync: true);
  final _pasteRequestController = StreamController<void>.broadcast(sync: true);
  int _kittyKeyboardFlags = 0;
  final List<int> _kittyKeyboardStack = [];
  bool _sgrPixelsMouseMode = false;
  int _mouseTrackingMask = 0;

  static const Map<String, int> _mouseTrackingBitByMode = {
    '9': 1,
    '1000': 2,
    '1002': 4,
    '1003': 8,
  };

  static const _esc = '\x1b';
  static const _bel = '\x07';
  static const int _maxKittyKeyboardStackDepth = 16;

  /// Matches OSC 22 sequences. Capture Group 1 extracts the cursor shape name.
  static final RegExp _osc22Regex = RegExp(
    '$_esc\\]22;([^$_esc$_bel]*)(?:$_esc\\\\|$_bel)',
  );

  /// Matches Kitty keyboard protocol push (`>`), pop (`<`), and set (`=`) CSI u sequences.
  static final RegExp _kittyKeyboardRegex = RegExp(
    '$_esc\\[(?:>(\\d*)|<(\\d*)|=(\\d+)(?:;(\\d+))?)u',
  );

  /// Matches DEC private mode set (`h`) and reset (`l`) CSI sequences.
  static final RegExp _decPrivateModeRegex = RegExp(
    '$_esc\\[\\?([0-9;]+)([hl])',
  );

  /// Active Kitty keyboard protocol progressive enhancement flags.
  int get kittyKeyboardFlags => _kittyKeyboardFlags;

  /// Whether DEC private mode `1016` (SGR-Pixels mouse reporting) is active.
  bool get sgrPixelsMouseMode => _sgrPixelsMouseMode;

  /// Whether any DECSET mouse tracking mode (`?9`, `?1000`, `?1002`, `?1003`)
  /// is active.
  bool get mouseTrackingMode => _mouseTrackingMask != 0;

  @override
  bool get isWindows => false;

  @override
  Stream<List<int>> get rawInput => const Stream.empty();

  @override
  void write(String data) {
    _parseOsc22(data);
    _parseKittyKeyboard(data);
    _parseDecPrivateModes(data);
  }

  void _parseDecPrivateModes(String data) {
    if (data.contains('${_esc}c') || data.contains('$_esc[!p')) {
      _sgrPixelsMouseMode = false;
      _mouseTrackingMask = 0;
    }
    if (!data.contains('$_esc[?')) return;
    for (final match in _decPrivateModeRegex.allMatches(data)) {
      _applyDecPrivateModeMatch(match.group(1)!, match.group(2) == 'h');
    }
  }

  void _applyDecPrivateModeMatch(String params, bool enable) {
    for (final part in params.split(';')) {
      if (part == '1016') {
        _sgrPixelsMouseMode = enable;
        continue;
      }
      final bit = _mouseTrackingBitByMode[part];
      if (bit != null) {
        _mouseTrackingMask = enable
            ? (_mouseTrackingMask | bit)
            : (_mouseTrackingMask & ~bit);
      }
    }
  }

  void _parseOsc22(String data) {
    if (!data.contains('$_esc]22;')) return;
    final matches = _osc22Regex.allMatches(data);
    if (matches.lastOrNull case final lastMatch?) {
      final cursorName = lastMatch.group(1);
      _mouseCursorController.add(cursorName == '' ? null : cursorName);
    }
  }

  void _parseKittyKeyboard(String data) {
    if (data.contains('${_esc}c') || data.contains('$_esc[!p')) {
      _kittyKeyboardFlags = 0;
      _kittyKeyboardStack.clear();
    }
    if (!data.contains('$_esc[')) return;
    for (final match in _kittyKeyboardRegex.allMatches(data)) {
      _applyKittyKeyboardMatch(match);
    }
  }

  void _applyKittyKeyboardMatch(RegExpMatch match) {
    if (match.group(1) case final pushGroup?) {
      _pushKittyKeyboardFlags(int.tryParse(pushGroup) ?? 0);
      return;
    }
    if (match.group(2) case final popGroup?) {
      _popKittyKeyboardFlags(
        popGroup.isEmpty ? 1 : (int.tryParse(popGroup) ?? 1),
      );
      return;
    }
    if (match.group(3) case final setGroup?) {
      final flags = int.tryParse(setGroup) ?? 0;
      final mode = int.tryParse(match.group(4) ?? '') ?? 1;
      _setKittyKeyboardFlags(flags, mode);
    }
  }

  void _pushKittyKeyboardFlags(int flags) {
    if (_kittyKeyboardStack.length >= _maxKittyKeyboardStackDepth) {
      _kittyKeyboardStack.removeAt(0);
    }
    _kittyKeyboardStack.add(_kittyKeyboardFlags);
    _kittyKeyboardFlags = flags & 0x1F;
  }

  void _popKittyKeyboardFlags(int rawCount) {
    final count = rawCount <= 0 ? 1 : rawCount;
    if (count > _kittyKeyboardStack.length) {
      _kittyKeyboardStack.clear();
      _kittyKeyboardFlags = 0;
      return;
    }
    for (var i = 0; i < count; i++) {
      _kittyKeyboardFlags = _kittyKeyboardStack.removeLast();
    }
  }

  void _setKittyKeyboardFlags(int flags, int mode) {
    final masked = flags & 0x1F;
    switch (mode) {
      case 1:
        _kittyKeyboardFlags = masked;
      case 2:
        _kittyKeyboardFlags = (_kittyKeyboardFlags | masked) & 0x1F;
      case 3:
        _kittyKeyboardFlags = (_kittyKeyboardFlags & ~masked) & 0x1F;
    }
  }

  /// Emits [text] directly to [clipboardChanges] listeners when open.
  void emitClipboardWrite(String text) {
    if (!_clipboardController.isClosed) {
      _clipboardController.add(text);
    }
  }

  /// Emits a paste request directly to [pasteRequests] listeners when open.
  void emitPasteRequest() {
    if (!_pasteRequestController.isClosed) {
      _pasteRequestController.add(null);
    }
  }

  @override
  Point<int> get size => _size;

  @override
  Stream<Point<int>> watchSize() => _sizeController.stream;

  /// Stream emitting the active OSC 22 mouse cursor name requested by the TUI.
  Stream<String?> get mouseCursorChanges => _mouseCursorController.stream;

  /// Stream emitting clipboard write text requested via [FlutterTerminal.setClipboard].
  Stream<String> get clipboardChanges => _clipboardController.stream;

  /// Stream emitting events when the TUI requests a clipboard paste via [FlutterTerminal.requestPaste].
  Stream<void> get pasteRequests => _pasteRequestController.stream;

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
    _clipboardController.close();
    _pasteRequestController.close();
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
final class FlutterTerminal extends core.Terminal {
  // NOTE: This MUST be sync: true!
  // Browsers enforce a strict security model blocking `input.click()` (used by file_selector_web)
  // unless executed synchronously within a user-gesture (mouse click / key press) stack.
  // Using an asynchronous stream defers execution to a microtask, causing the browser to silently block the file picker.
  final _eventsController = StreamController<core_event.InputEvent>.broadcast(
    sync: true,
  );
  final _initialSizeCompleter = Completer<Point<int>>();
  final _fontSizeController = StreamController<double>.broadcast();
  final _enableLigaturesController = StreamController<bool>.broadcast();
  final _enableBuiltinSelectionController = StreamController<bool>.broadcast();
  final _enableBuiltinLinkOpenController = StreamController<bool>.broadcast();
  final _cellPixelSizeController = StreamController<(int, int)>.broadcast();
  final _exactCellPixelSizeController =
      StreamController<(double, double)>.broadcast();
  double _fontSize;
  bool _enableLigatures;
  bool _enableBuiltinSelection;
  bool _enableBuiltinLinkOpen;
  (int, int) _cellPixelSize = (9, 18);
  (double, double) _exactCellPixelSize = (9.0, 18.0);
  bool _explicitReportKeyRelease = false;
  bool _explicitReportPixelMouse = false;

  /// Stream emitting changes to the TUI's requested mouse cursor.
  Stream<String?> get mouseCursorChanges => _flutterBackend.mouseCursorChanges;

  /// Stream emitting clipboard text written synchronously via [setClipboard].
  Stream<String> get clipboardChanges => _flutterBackend.clipboardChanges;

  /// Stream emitting events when a paste is requested synchronously via [requestPaste].
  Stream<void> get pasteRequests => _flutterBackend.pasteRequests;

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
  /// | `enableLigatures` | [bool] | Whether multi-cell ligatures are enabled. Defaults to `false`. |
  /// | `enableBuiltinSelection` | [bool] | Whether built-in viewport selection is enabled. Defaults to `true`. |
  /// | `enableBuiltinLinkOpen` | [bool] | Whether built-in `OSC 8` link opening is enabled. Defaults to `true`. |
  FlutterTerminal({
    double initialFontSize = 13.0,
    bool enableLigatures = false,
    bool enableBuiltinSelection = true,
    bool enableBuiltinLinkOpen = true,
  }) : _fontSize = initialFontSize,
       _enableLigatures = enableLigatures,
       _enableBuiltinSelection = enableBuiltinSelection,
       _enableBuiltinLinkOpen = enableBuiltinLinkOpen,
       super(FlutterTerminalBackend());

  FlutterTerminalBackend get _flutterBackend =>
      backend as FlutterTerminalBackend;

  /// Returns the current font size used to render the terminal.
  double get fontSize => _fontSize;

  /// Whether multi-cell ligatures are currently enabled for rendering.
  bool get enableLigatures => _enableLigatures;

  /// Whether built-in viewport text selection and auto-copy are enabled.
  bool get enableBuiltinSelection => _enableBuiltinSelection;

  /// Stream emitting updates when [enableBuiltinSelection] changes.
  Stream<bool> watchEnableBuiltinSelection() =>
      _enableBuiltinSelectionController.stream;

  /// Updates whether built-in viewport text selection and auto-copy are enabled.
  void setEnableBuiltinSelection(bool enabled) {
    if (_enableBuiltinSelection == enabled) return;
    _enableBuiltinSelection = enabled;
    if (!_enableBuiltinSelectionController.isClosed) {
      _enableBuiltinSelectionController.add(enabled);
    }
  }

  /// Whether built-in `OSC 8` link hover cursor and click launch are enabled.
  bool get enableBuiltinLinkOpen => _enableBuiltinLinkOpen;

  /// Stream emitting updates when [enableBuiltinLinkOpen] changes.
  Stream<bool> watchEnableBuiltinLinkOpen() =>
      _enableBuiltinLinkOpenController.stream;

  /// Updates whether built-in `OSC 8` link hover cursor and click launch are enabled.
  void setEnableBuiltinLinkOpen(bool enabled) {
    if (_enableBuiltinLinkOpen == enabled) return;
    _enableBuiltinLinkOpen = enabled;
    if (!_enableBuiltinLinkOpenController.isClosed) {
      _enableBuiltinLinkOpenController.add(enabled);
    }
  }

  /// Active Kitty keyboard protocol progressive enhancement flags (`0..31`).
  int get kittyKeyboardFlags => _flutterBackend.kittyKeyboardFlags;

  /// Whether `KeyUpEvent` transitions should be reported as [core_event.KeyEventType.release].
  ///
  /// Enabled when Kitty keyboard protocol bit `2` (`CSI > 2 u` / `CSI = 2 u`) is active
  /// or when explicitly requested via [setReportKeyReleaseEvents].
  bool get reportKeyReleaseEvents =>
      (_flutterBackend.kittyKeyboardFlags & 2) != 0 ||
      _explicitReportKeyRelease;

  /// Explicitly enables or disables reporting key release events regardless of Kitty flags.
  void setReportKeyReleaseEvents(bool enabled) {
    _explicitReportKeyRelease = enabled;
  }

  /// Whether sub-cell pointer moves should be reported with pixel precision (`?1016` SGR-Pixels).
  ///
  /// Enabled when DEC private mode `1016` (`\x1b[?1016h`) is active or when explicitly
  /// requested via [setReportPixelMouseEvents].
  bool get reportPixelMouseEvents =>
      _flutterBackend.sgrPixelsMouseMode || _explicitReportPixelMouse;

  /// Whether any DECSET mouse tracking mode (`?9`, `?1000`, `?1002`, `?1003`)
  /// is active.
  bool get mouseTracking => _flutterBackend.mouseTrackingMode;

  /// Explicitly enables or disables reporting sub-cell pixel pointer motion regardless of `?1016`.
  void setReportPixelMouseEvents(bool enabled) {
    _explicitReportPixelMouse = enabled;
  }

  /// A stream that emits the font size whenever it changes.
  Stream<double> watchFontSize() => _fontSizeController.stream;

  /// A stream that emits whether ligatures are enabled whenever changed.
  Stream<bool> watchEnableLigatures() => _enableLigaturesController.stream;

  /// Current rounded logical pixel dimensions `(width, height)` of a single terminal cell (`CSI 16 t`).
  (int, int) get cellPixelSize => _cellPixelSize;

  /// A stream that emits rounded `(width, height)` cell pixel dimensions whenever the font atlas changes.
  Stream<(int, int)> watchCellPixelSize() => _cellPixelSizeController.stream;

  /// Current exact unrounded logical pixel dimensions `(width, height)` of a single terminal cell.
  (double, double) get exactCellPixelSize => _exactCellPixelSize;

  /// A stream that emits exact unrounded `(width, height)` cell pixel dimensions whenever the font atlas changes.
  Stream<(double, double)> watchExactCellPixelSize() =>
      _exactCellPixelSizeController.stream;

  /// Updates the rounded logical pixel dimensions of a single terminal cell (`>= 1`).
  void updateCellPixelSize(int width, int height) {
    final next = (max(1, width), max(1, height));
    if (_cellPixelSize != next) {
      _cellPixelSize = next;
      if (!_cellPixelSizeController.isClosed) {
        _cellPixelSizeController.add(next);
      }
    }
  }

  /// Updates the exact unrounded logical pixel dimensions of a single terminal cell (`>= 1.0`).
  void updateExactCellPixelSize(double width, double height) {
    final safeW = width.isFinite && width > 1.0 ? width : 1.0;
    final safeH = height.isFinite && height > 1.0 ? height : 1.0;
    final next = (safeW, safeH);
    if (_exactCellPixelSize != next) {
      _exactCellPixelSize = next;
      if (!_exactCellPixelSizeController.isClosed) {
        _exactCellPixelSizeController.add(next);
      }
    }
  }

  /// Enables or disables multi-cell font ligatures.
  void setEnableLigatures(bool enabled) {
    if (_enableLigatures != enabled) {
      _enableLigatures = enabled;
      _enableLigaturesController.add(enabled);
    }
  }

  /// Toggles multi-cell font ligatures between enabled and disabled.
  void toggleLigatures() => setEnableLigatures(!_enableLigatures);

  /// Sets the rendering font size, clamped between `4.0` and `72.0`.
  ///
  /// | Parameter | Type | Description |
  /// | :--- | :--- | :--- |
  /// | `size` | [double] | The target font size. |
  void setFontSize(double size) {
    Tracer.record(_traceSetFontSizeId, Phase.instant, TraceCategory.layout);
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
    Tracer.record(
      _traceIncreaseFontSizeId,
      Phase.instant,
      TraceCategory.layout,
    );
    setFontSize(_fontSize + delta);
  }

  /// Decreases the current font size by [delta].
  ///
  /// | Parameter | Type | Description |
  /// | :--- | :--- | :--- |
  /// | `delta` | [double] | The amount to decrease by. Defaults to `1.0`. |
  void decreaseFontSize([double delta = 1.0]) {
    Tracer.record(
      _traceDecreaseFontSizeId,
      Phase.instant,
      TraceCategory.layout,
    );
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
  void setClipboard(String text) {
    _flutterBackend.emitClipboardWrite(text);
  }

  @override
  void requestPaste() {
    _flutterBackend.emitPasteRequest();
  }

  @override
  void dispose() {
    _eventsController.close();
    _fontSizeController.close();
    _enableLigaturesController.close();
    _enableBuiltinSelectionController.close();
    _enableBuiltinLinkOpenController.close();
    _cellPixelSizeController.close();
    _exactCellPixelSizeController.close();
    _flutterBackend.dispose();
    super.dispose();
  }
}
