import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:ui' as ui;
import 'package:clock/clock.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart' hide Color;
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:termui/ui/buffer.dart';
import 'package:termui/ui/style.dart';
import 'package:termui/ui/widgets/display/kitty_image.dart';
import 'package:termui/terminal/terminal.dart' as term;
import 'package:termui/perf/tracer.dart';

import 'backend.dart';
import 'rendering/atlas.dart';
import 'rendering/painter.dart';
import 'util/font_helper.dart';
import 'service/terminal_service.dart';

/// A widget that embeds a `termui` TUI application within Flutter.
///
/// It initializes a [FlutterTerminal], triggers the event loop using the
/// [onRun] callback, and sets up a [PrivateTuiView] to handle painting and focus.
///
/// ### Example Usage
///
/// ```dart
/// Terminal(
///   fontSize: 14.0,
///   fontFamily: 'Cascadia Code',
///   backgroundColor: Colors.black,
///   onRun: (terminal, drawFrame) async {
///     final app = App(backend: terminal.backend);
///     app.run((frame) {
///       frame.write(0, 0, 'Welcome to the Embedded TUI!');
///     });
///   },
/// )
/// ```
///
/// ### Properties and Configuration
///
/// | Property | Type | Description |
/// | :--- | :--- | :--- |
/// | `terminal` | [FlutterTerminal]? | Optional custom terminal instance. |
/// | `onRun` | `Future<void> Function(...)` | Callback executing the TUI event loop. |
/// | `fontSize` | [double] | The text rendering font size. Defaults to `13.0`. |
/// | `fontFamily` | [String] | Monospaced font family for rendering cells. |
/// | `backgroundColor` | [Color] | The background color of the terminal view. |
final class Terminal extends StatefulWidget {
  /// Optional custom terminal instance.
  final FlutterTerminal? terminal;

  /// Callback executing the TUI event loop, providing the terminal and draw dispatcher.
  final Future<void> Function(
    FlutterTerminal terminal,
    void Function(Buffer) drawFrame,
  )
  onRun;

  /// The text rendering font size. Defaults to `13.0`.
  final double fontSize;

  /// Monospaced font family for rendering cells.
  final String fontFamily;

  /// Fallback monospaced font families.
  final List<String>? fontFamilyFallback;

  /// The background color of the terminal view.
  final Color backgroundColor;

  /// The MVVM service used for external operations like saving screenshots.
  final TerminalService service;

  /// Enables sub-pixel bleeding to prevent gaps during fractional transformations. Defaults to kIsWeb.
  final bool enableBleed;

  /// Creates a [Terminal] view bounding the TUI app hierarchy.
  const Terminal({
    super.key,
    this.terminal,
    required this.onRun,
    this.fontSize = 13.0,
    this.fontFamily = 'Cascadia Mono',
    this.fontFamilyFallback,
    this.backgroundColor = Colors.black,
    this.service = const DefaultTerminalService(),
    this.enableBleed = kIsWeb,
  });

  @override
  State<Terminal> createState() => _TerminalState();
}

class _TerminalState extends State<Terminal> {
  late final FlutterTerminal _terminal;
  bool _isRunning = false;

  @override
  void initState() {
    super.initState();
    _terminal =
        widget.terminal ?? FlutterTerminal(initialFontSize: widget.fontSize);
  }

  @override
  void dispose() {
    if (widget.terminal == null) {
      _terminal.dispose();
    }
    super.dispose();
  }

  void _startLoop(void Function(Buffer) drawFrame) async {
    if (_isRunning) return;
    _isRunning = true;
    try {
      await widget.onRun(_terminal, drawFrame);
    } finally {
      _isRunning = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    return PrivateTuiView(
      terminal: _terminal,
      fontSize: widget.fontSize,
      fontFamily: widget.fontFamily,
      fontFamilyFallback: widget.fontFamilyFallback,
      backgroundColor: widget.backgroundColor,
      service: widget.service,
      enableBleed: widget.enableBleed,
      onInit: _startLoop,
    );
  }
}

/// The internal widget that manages drawing, keyboard focus, and mouse input.
///
/// It listens for pointer gestures (tap, drag, hover) and hardware keyboard
/// events, translating them into `termui` input events. It also holds the
/// [GlyphAtlas] texture atlas and schedules custom paints when a new [Buffer]
/// is received.
///
/// Key functions:
/// 1. Manages a [FocusNode] to direct hardware keyboard inputs.
/// 2. Performs hit-testing to map mouse positions to terminal grid cells.
/// 3. Builds a fallback dictionary of painters for characters not in the atlas.
///
/// | Property | Type | Description |
/// | :--- | :--- | :--- |
/// | `terminal` | [FlutterTerminal] | The terminal logic controller. |
/// | `onInit` | `Function(void Function(Buffer))` | Callback to hook frame rendering. |
/// | `fontSize` | [double] | Monospaced font height scaling factor. |
/// | `fontFamily` | [String] | Active typeface family. |
/// | `backgroundColor` | [Color] | Backdrop style filling the grid viewport. |
final class PrivateTuiView extends StatefulWidget {
  /// The internal terminal logic controller backing the UI events.
  final FlutterTerminal terminal;

  /// Hook to register the native frame drawing callback on initialization.
  final void Function(void Function(Buffer) onDrawFrame) onInit;

  /// The scaled monospaced font point height.
  final double fontSize;

  /// The configured monospaced text typeface label.
  final String fontFamily;

  /// Fallback monospaced font families.
  final List<String>? fontFamilyFallback;

  /// General terminal canvas background color filler.
  final Color backgroundColor;

  /// The service for saving screenshots.
  final TerminalService service;

  /// Enables sub-pixel bleeding to prevent gaps during fractional transformations. Defaults to kIsWeb.
  final bool enableBleed;

  /// Internal widget constructor binding the terminal state to rendering hooks.
  const PrivateTuiView({
    super.key,
    required this.terminal,
    required this.onInit,
    required this.service,
    this.fontSize = 13,
    this.fontFamily = 'Cascadia Mono',
    this.fontFamilyFallback,
    this.backgroundColor = Colors.black,
    this.enableBleed = kIsWeb,
  });

  @override
  State<PrivateTuiView> createState() => PrivateTuiViewState();
}

/// Internal state for [PrivateTuiView], exposed for widget tests.
class PrivateTuiViewState extends State<PrivateTuiView> {
  final FocusNode _focusNode = FocusNode();
  final GlobalKey _boundaryKey = GlobalKey();
  GlyphAtlas? _atlas;
  Buffer? _currentBuffer;
  StreamSubscription<String?>? _mouseCursorSubscription;
  StreamSubscription<String>? _clipboardSubscription;
  StreamSubscription<void>? _pasteRequestSubscription;
  MouseCursor _currentCursor = SystemMouseCursors.basic;
  String? _hoveredUri;
  bool _isLinkModifierActive = false;
  Point<int>? _selectionAnchor;
  Point<int>? _selectionFocus;
  (int, int)? _selectionColBounds;
  bool _selectionBoxMode = false;
  bool _isSelecting = false;

  MouseCursor get _effectiveCursor =>
      (_hoveredUri != null &&
          _isLinkModifierActive &&
          _currentCursor == SystemMouseCursors.basic)
      ? SystemMouseCursors.click
      : _currentCursor;

  final Map<(String, bool, bool, Color), TextPainter> _fallbackPainters = {};
  static const int _maxKittyGpuImages = 64;
  final Map<KittyImageData, ui.Image> _kittyGpuImages = {};
  final Set<KittyImageData> _decodingKittyImages = {};
  final Set<String> _pendingGlyphs = {};
  final Set<String> _processingGlyphs = {};
  bool _isUpdatingAtlas = false;
  term.MouseEvent? _lastInjectedPointerEvent;

  late double _fontSize;

  /// Current font size rendered by the terminal view.
  double get fontSize => _fontSize;
  int _atlasGenerationId = 0;
  StreamSubscription<double>? _fontSizeSubscription;
  double _devicePixelRatio = 1.0;

  static final int _traceRecreateAtlasId = Tracer.registerString(
    'TuiView:recreateAtlas',
  );
  static final int _traceFontSizeChangedId = Tracer.registerString(
    'TuiView:fontSizeChanged',
  );
  static final int _traceTriggerAtlasUpdateId = Tracer.registerString(
    'TuiView:triggerAtlasUpdate',
  );

  void _handleSystemFontsChange() {
    if (mounted) {
      _recreateAtlas();
    }
  }

  @override
  void initState() {
    super.initState();
    PaintingBinding.instance.systemFonts.addListener(_handleSystemFontsChange);
    _fontSize = widget.terminal.fontSize;
    _fontSizeSubscription = widget.terminal.watchFontSize().listen((newSize) {
      if (mounted) {
        Tracer.record(
          _traceFontSizeChangedId,
          Phase.instant,
          TraceCategory.layout,
        );
        setState(() {
          _fontSize = newSize;
        });
        _recreateAtlas();
      }
    });

    _mouseCursorSubscription = widget.terminal.mouseCursorChanges.listen((
      cursorName,
    ) {
      if (mounted) {
        setState(() {
          _currentCursor = _mapOsc22ToSystemCursor(cursorName);
        });
      }
    });
    _bindClipboardStreams();

    _initAtlasAndLoop();
  }

  void _bindClipboardStreams() {
    _clipboardSubscription?.cancel();
    _pasteRequestSubscription?.cancel();
    _clipboardSubscription = widget.terminal.clipboardChanges.listen((text) {
      if (mounted) {
        unawaited(_writeToClipboard(text));
      }
    });
    _pasteRequestSubscription = widget.terminal.pasteRequests.listen((_) {
      if (mounted) {
        unawaited(_pasteFromClipboard());
      }
    });
  }

  Future<void> _writeToClipboard(String text) async {
    try {
      await widget.service.setClipboard(text);
    } on Object catch (_) {
      // Ignore platform or browser clipboard rejections.
    }
  }

  Future<void> _pasteFromClipboard() async {
    final String? text;
    try {
      text = await widget.service.getClipboard();
    } on Object catch (_) {
      return;
    }
    if (!mounted || text == null || text.isEmpty) return;
    widget.terminal.injectEvent(term.PasteEvent(text));
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final dpr = MediaQuery.maybeDevicePixelRatioOf(context) ?? 1.0;
    if (_devicePixelRatio != dpr) {
      _devicePixelRatio = dpr;
      _recreateAtlas();
    }
  }

  void _initAtlasAndLoop() async {
    await _recreateAtlas();
    if (mounted) {
      widget.onInit((buffer) {
        if (mounted) {
          scheduleMicrotask(() {
            if (mounted) {
              _updateFallbackPainters(buffer);
              setState(() {
                _currentBuffer = buffer;
              });
            }
          });
        }
      });
    }

    await waitForFontsToLoad();
    if (mounted) {
      _recreateAtlas();
    }
  }

  Future<void> _recreateAtlas() async {
    final genId = ++_atlasGenerationId;
    Tracer.record(_traceRecreateAtlasId, Phase.begin, TraceCategory.paint);
    for (final painter in _fallbackPainters.values) {
      painter.dispose();
    }
    _fallbackPainters.clear();
    _pendingGlyphs.clear();
    _processingGlyphs.clear();
    _isUpdatingAtlas = false;

    final newAtlas = await GlyphAtlasGenerator.generate(
      fontSize: _fontSize,
      fontFamily: widget.fontFamily,
      fontFamilyFallback: widget.fontFamilyFallback,
      devicePixelRatio: _devicePixelRatio,
    );

    if (!mounted || genId != _atlasGenerationId) {
      newAtlas.image.dispose();
      Tracer.record(_traceRecreateAtlasId, Phase.end, TraceCategory.paint);
      return;
    }
    final oldAtlas = _atlas;
    setState(() {
      _atlas = newAtlas;
      if (_currentBuffer != null) {
        _updateFallbackPainters(_currentBuffer!);
      }
    });
    if (oldAtlas != null && !identical(oldAtlas.image, newAtlas.image)) {
      oldAtlas.image.dispose();
    }
    Tracer.record(_traceRecreateAtlasId, Phase.end, TraceCategory.paint);
  }

  MouseCursor _mapOsc22ToSystemCursor(String? cursorName) {
    if (cursorName == null || cursorName.isEmpty || cursorName == 'default') {
      return SystemMouseCursors.basic;
    }
    return switch (cursorName) {
      'text' => SystemMouseCursors.text,
      'pointer' => SystemMouseCursors.click,
      'crosshair' => SystemMouseCursors.precise,
      'help' => SystemMouseCursors.help,
      'progress' => SystemMouseCursors.progress,
      'wait' => SystemMouseCursors.wait,
      'move' => SystemMouseCursors.move,
      'not-allowed' => SystemMouseCursors.forbidden,
      'grab' => SystemMouseCursors.grab,
      'grabbing' => SystemMouseCursors.grabbing,
      'none' => SystemMouseCursors.none,
      'alias' => SystemMouseCursors.alias,
      'copy' => SystemMouseCursors.copy,
      'cell' => SystemMouseCursors.cell,
      'no-drop' => SystemMouseCursors.noDrop,
      'zoom-in' => SystemMouseCursors.zoomIn,
      'zoom-out' => SystemMouseCursors.zoomOut,
      'ns-resize' => SystemMouseCursors.resizeUpDown,
      'ew-resize' => SystemMouseCursors.resizeLeftRight,
      'all-scroll' => SystemMouseCursors.allScroll,
      _ => SystemMouseCursors.basic,
    };
  }

  @override
  void didUpdateWidget(PrivateTuiView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.terminal != widget.terminal) {
      _fontSizeSubscription?.cancel();
      _mouseCursorSubscription?.cancel();
      _fontSize = widget.terminal.fontSize;
      _fontSizeSubscription = widget.terminal.watchFontSize().listen((newSize) {
        if (mounted) {
          Tracer.record(
            _traceFontSizeChangedId,
            Phase.instant,
            TraceCategory.layout,
          );
          setState(() {
            _fontSize = newSize;
          });
          _recreateAtlas();
        }
      });
      _mouseCursorSubscription = widget.terminal.mouseCursorChanges.listen((
        cursorName,
      ) {
        if (mounted) {
          setState(() {
            _currentCursor = _mapOsc22ToSystemCursor(cursorName);
          });
        }
      });
      _bindClipboardStreams();
      _recreateAtlas();
    } else if (oldWidget.fontSize != widget.fontSize) {
      widget.terminal.setFontSize(widget.fontSize);
    } else if (oldWidget.fontFamily != widget.fontFamily ||
        oldWidget.fontFamilyFallback != widget.fontFamilyFallback) {
      _recreateAtlas();
    }
  }

  @override
  void dispose() {
    PaintingBinding.instance.systemFonts.removeListener(
      _handleSystemFontsChange,
    );
    _fontSizeSubscription?.cancel();
    _mouseCursorSubscription?.cancel();
    _clipboardSubscription?.cancel();
    _pasteRequestSubscription?.cancel();
    for (final painter in _fallbackPainters.values) {
      painter.dispose();
    }
    _fallbackPainters.clear();
    for (final image in _kittyGpuImages.values) {
      image.dispose();
    }
    _kittyGpuImages.clear();
    _decodingKittyImages.clear();
    _atlas?.image.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _updateFallbackPainters(Buffer buffer) {
    final atlas = _atlas;
    if (atlas == null) return;

    final total = buffer.width * buffer.height;
    final width = buffer.width;
    for (var i = 0; i < total; i++) {
      final char = buffer.characters[i];
      if (char.isEmpty || char == ' ' || atlas.charRects.containsKey(char)) {
        continue;
      }
      final x = i % width;
      final y = i ~/ width;
      final mods = buffer.getModifiers(x, y);
      if (Modifier.has(mods, Modifier.kittyPlaceholder) ||
          char.startsWith(kittyPlaceholderChar)) {
        final msb = parseKittyPlaceholderCell(char)?.imageIdMsb ?? 0;
        final imageId =
            ((msb & 0xFF) << 24) | (buffer.getForeground(x, y) & 0xFFFFFF);
        final data = buffer.lookupKittyImage(x, y, imageId);
        if (data != null) _ensureKittyGpuImage(data);
        continue;
      }
      _ensureFallbackPainterForCell(buffer, x, y, char, mods);
    }
  }

  void _ensureFallbackPainterForCell(
    Buffer buffer,
    int x,
    int y,
    String char,
    int mods,
  ) {
    final isReverse = Modifier.has(mods, Modifier.reverse);
    final fgVal = isReverse
        ? buffer.getBackground(x, y)
        : buffer.getForeground(x, y);
    final color = fgVal != 0
        ? Color(fgVal)
        : (isReverse ? Colors.black : Colors.white);
    final isBold = Modifier.has(mods, Modifier.bold);
    final isDim = Modifier.has(mods, Modifier.dim);

    final key = (char, isBold, isDim, color);
    if (_fallbackPainters.containsKey(key)) return;
    final textStyle = TextStyle(
      fontFamily: widget.fontFamily,
      fontFamilyFallback: widget.fontFamilyFallback,
      fontSize: _fontSize,
      color: color,
      fontWeight: isBold ? FontWeight.bold : FontWeight.normal,
      height: 1.0,
    );
    _fallbackPainters[key] = TextPainter(
      text: TextSpan(text: char, style: textStyle),
      textDirection: TextDirection.ltr,
    )..layout();
  }

  void _ensureKittyGpuImage(KittyImageData data) {
    final existing = _kittyGpuImages.remove(data);
    if (existing != null) {
      _kittyGpuImages[data] = existing;
      return;
    }
    if (data.rgbaPixels.isEmpty) return;
    if (data.format == 100) {
      if (!_decodingKittyImages.add(data)) return;
      unawaited(_decodeKittyPngImage(data));
      return;
    }
    if (data.pixelWidth <= 0 || data.pixelHeight <= 0) return;
    if (!_decodingKittyImages.add(data)) return;
    ui.decodeImageFromPixels(
      data.rgbaPixels,
      data.pixelWidth,
      data.pixelHeight,
      ui.PixelFormat.rgba8888,
      (decoded) => _onKittyGpuImageDecoded(data, decoded),
    );
  }

  Future<void> _decodeKittyPngImage(KittyImageData data) async {
    ui.Codec? codec;
    try {
      codec = await ui.instantiateImageCodec(data.rgbaPixels);
      final frame = await codec.getNextFrame();
      _onKittyGpuImageDecoded(data, frame.image);
    } on Object catch (_) {
      _decodingKittyImages.remove(data);
    } finally {
      codec?.dispose();
    }
  }

  void _onKittyGpuImageDecoded(KittyImageData data, ui.Image decoded) {
    _decodingKittyImages.remove(data);
    if (!mounted) {
      decoded.dispose();
      return;
    }
    while (_kittyGpuImages.length >= _maxKittyGpuImages) {
      final oldestKey = _kittyGpuImages.keys.first;
      _kittyGpuImages.remove(oldestKey)?.dispose();
    }
    final old = _kittyGpuImages[data];
    setState(() {
      _kittyGpuImages[data] = decoded;
    });
    if (old != null && !identical(old, decoded)) {
      old.dispose();
    }
  }

  void _onMissingGlyphs(List<String> glyphs) {
    if (_atlas == null) return;
    var needsUpdate = false;
    for (final glyph in glyphs) {
      if (!_pendingGlyphs.contains(glyph) &&
          !_processingGlyphs.contains(glyph) &&
          !_atlas!.charRects.containsKey(glyph)) {
        _pendingGlyphs.add(glyph);
        needsUpdate = true;
      }
    }
    if (needsUpdate) {
      _triggerAtlasUpdate();
    }
  }

  void _triggerAtlasUpdate() async {
    if (_isUpdatingAtlas || _pendingGlyphs.isEmpty || _atlas == null) return;
    _isUpdatingAtlas = true;
    final genId = _atlasGenerationId;
    Tracer.record(_traceTriggerAtlasUpdateId, Phase.begin, TraceCategory.paint);

    final batch = _pendingGlyphs.toList();
    _pendingGlyphs.removeAll(batch);
    _processingGlyphs.addAll(batch);

    try {
      await Future.microtask(() {});
      if (!mounted || genId != _atlasGenerationId) return;

      final oldAtlas = _atlas;
      final newAtlas = await oldAtlas!.addGlyphs(batch);
      if (!mounted || genId != _atlasGenerationId) {
        newAtlas.image.dispose();
        return;
      }
      setState(() {
        _atlas = newAtlas;
      });
      if (!identical(oldAtlas.image, newAtlas.image)) {
        oldAtlas.image.dispose();
      }
    } finally {
      _processingGlyphs.removeAll(batch);
      if (genId == _atlasGenerationId) {
        _isUpdatingAtlas = false;
      }
      Tracer.record(_traceTriggerAtlasUpdateId, Phase.end, TraceCategory.paint);
      if (mounted && _pendingGlyphs.isNotEmpty && genId == _atlasGenerationId) {
        _triggerAtlasUpdate();
      }
    }
  }

  static bool _isLinkOpenModifierPressed() {
    final kb = HardwareKeyboard.instance;
    return kb.isControlPressed || kb.isMetaPressed;
  }

  void _syncLinkModifierState() {
    final pressed = _isLinkOpenModifierPressed();
    if (pressed != _isLinkModifierActive) {
      _isLinkModifierActive = pressed;
      if (_hoveredUri != null && mounted) {
        setState(() {});
      }
    }
  }

  void _handleKeyEvent(KeyEvent event) {
    _syncLinkModifierState();
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return;
    final key = event.logicalKey;

    if (key == LogicalKeyboardKey.f12) {
      if (HardwareKeyboard.instance.isShiftPressed) {
        _recreateAtlas();
      } else {
        _takeScreenshot();
      }
      return;
    }

    final mods = _collectHardwareModifiers();
    if (_isPasteShortcut(key, mods)) {
      unawaited(_pasteFromClipboard());
      return;
    }

    final resolved = _resolveKeyEvent(event, mods);
    if (resolved != null) {
      widget.terminal.injectEvent(resolved);
    }
  }

  static Set<term.Modifier> _collectHardwareModifiers() {
    final kb = HardwareKeyboard.instance;
    return {
      if (kb.isShiftPressed) term.Modifier.shift,
      if (kb.isAltPressed) term.Modifier.alt,
      if (kb.isControlPressed) term.Modifier.control,
      if (kb.isMetaPressed) term.Modifier.meta,
    };
  }

  static term.KeyEvent? _resolveKeyEvent(
    KeyEvent event,
    Set<term.Modifier> mods,
  ) {
    final key = event.logicalKey;
    final (termKey, termType) = switch (key) {
      LogicalKeyboardKey.arrowUp => ('up', term.KeyType.up),
      LogicalKeyboardKey.arrowDown => ('down', term.KeyType.down),
      LogicalKeyboardKey.arrowLeft => ('left', term.KeyType.left),
      LogicalKeyboardKey.arrowRight => ('right', term.KeyType.right),
      LogicalKeyboardKey.home => ('home', term.KeyType.home),
      LogicalKeyboardKey.end => ('end', term.KeyType.end),
      LogicalKeyboardKey.delete => ('delete', term.KeyType.delete),
      LogicalKeyboardKey.insert => ('insert', term.KeyType.insert),
      LogicalKeyboardKey.backspace => ('backspace', term.KeyType.backspace),
      LogicalKeyboardKey.pageUp => ('pageUp', term.KeyType.pageUp),
      LogicalKeyboardKey.pageDown => ('pageDown', term.KeyType.pageDown),
      LogicalKeyboardKey.escape => ('escape', term.KeyType.escape),
      LogicalKeyboardKey.enter ||
      LogicalKeyboardKey.numpadEnter => ('\n', term.KeyType.enter),
      LogicalKeyboardKey.tab => (
        mods.contains(term.Modifier.shift) ? 'backtab' : '\t',
        term.KeyType.tab,
      ),
      LogicalKeyboardKey.f1 => ('f1', term.KeyType.f1),
      LogicalKeyboardKey.f2 => ('f2', term.KeyType.f2),
      LogicalKeyboardKey.f3 => ('f3', term.KeyType.f3),
      LogicalKeyboardKey.f4 => ('f4', term.KeyType.f4),
      LogicalKeyboardKey.f5 => ('f5', term.KeyType.f5),
      LogicalKeyboardKey.f6 => ('f6', term.KeyType.f6),
      LogicalKeyboardKey.f7 => ('f7', term.KeyType.f7),
      LogicalKeyboardKey.f8 => ('f8', term.KeyType.f8),
      LogicalKeyboardKey.f9 => ('f9', term.KeyType.f9),
      LogicalKeyboardKey.f10 => ('f10', term.KeyType.f10),
      LogicalKeyboardKey.f11 => ('f11', term.KeyType.f11),
      LogicalKeyboardKey.equal => ('=', term.KeyType.character),
      LogicalKeyboardKey.numpadAdd => ('+', term.KeyType.character),
      LogicalKeyboardKey.minus ||
      LogicalKeyboardKey.numpadSubtract => ('-', term.KeyType.character),
      _ when _isCtrlShiftLetter(key, mods) => (
        key.keyLabel.toLowerCase(),
        term.KeyType.character,
      ),
      _ when event.character != null && event.character!.isNotEmpty =>
        _resolveCharacterKey(event.character!),
      _ when key.keyLabel.length == 1 => (
        key.keyLabel.toLowerCase(),
        term.KeyType.character,
      ),
      _ => (null, null),
    };
    if (termKey == null || termType == null) return null;
    return term.KeyEvent(termKey, termType, modifiers: mods);
  }

  static bool _isCtrlShiftLetter(
    LogicalKeyboardKey key,
    Set<term.Modifier> mods,
  ) =>
      mods.contains(term.Modifier.control) &&
      mods.contains(term.Modifier.shift) &&
      _isAsciiLetterKey(key) &&
      key.keyLabel.length == 1;

  static (String, term.KeyType) _resolveCharacterKey(String ch) =>
      (ch == '\n' || ch == '\r' || ch == '\r\n')
      ? ('\n', term.KeyType.enter)
      : (ch, term.KeyType.character);

  static bool _isPasteShortcut(
    LogicalKeyboardKey key,
    Set<term.Modifier> mods,
  ) {
    if (key == LogicalKeyboardKey.keyV) {
      final isCmdV =
          mods.contains(term.Modifier.meta) &&
          !mods.contains(term.Modifier.control) &&
          !mods.contains(term.Modifier.alt);
      final isCtrlShiftV =
          mods.contains(term.Modifier.control) &&
          mods.contains(term.Modifier.shift) &&
          !mods.contains(term.Modifier.meta) &&
          !mods.contains(term.Modifier.alt);
      return isCmdV || isCtrlShiftV;
    }
    if (key == LogicalKeyboardKey.insert) {
      return mods.contains(term.Modifier.shift) &&
          !mods.contains(term.Modifier.control) &&
          !mods.contains(term.Modifier.alt) &&
          !mods.contains(term.Modifier.meta);
    }
    return false;
  }

  static bool _isAsciiLetterKey(LogicalKeyboardKey key) =>
      key.keyId >= LogicalKeyboardKey.keyA.keyId &&
      key.keyId <= LogicalKeyboardKey.keyZ.keyId;

  void _takeScreenshot() async {
    try {
      final timestamp = clock.now().millisecondsSinceEpoch;
      String? screenshotBasename;
      String? atlasBasename;
      String? coordinatesBasename;

      final boundary =
          _boundaryKey.currentContext?.findRenderObject()
              as RenderRepaintBoundary?;
      if (boundary != null) {
        final image = await boundary.toImage(pixelRatio: 2.0);
        final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
        if (byteData != null) {
          final pngBytes = byteData.buffer.asUint8List();
          screenshotBasename = await widget.service.saveScreenshot(
            'screenshot_$timestamp.png',
            pngBytes,
          );
        }
      }

      final atlas = _atlas;
      if (atlas != null) {
        final byteData = await atlas.image.toByteData(
          format: ui.ImageByteFormat.png,
        );
        if (byteData != null) {
          final pngBytes = byteData.buffer.asUint8List();
          atlasBasename = await widget.service.saveScreenshot(
            'atlas_$timestamp.png',
            pngBytes,
          );
        }

        final rectsMap = atlas.charRects.map((key, value) {
          return MapEntry(
            key.runes
                .map(
                  (r) =>
                      'U+${r.toRadixString(16).padLeft(4, '0').toUpperCase()}',
                )
                .join(' '),
            {
              'char': key,
              'left': value.left,
              'top': value.top,
              'right': value.right,
              'bottom': value.bottom,
              'width': value.width,
              'height': value.height,
            },
          );
        });

        final atlasJsonStr = const JsonEncoder.withIndent(
          '  ',
        ).convert(rectsMap);
        final atlasJsonBytes = utf8.encode(atlasJsonStr);
        await widget.service.saveScreenshot(
          'atlas_table_$timestamp.json',
          atlasJsonBytes,
        );
      }

      final buffer = _currentBuffer;
      if (buffer != null && atlas != null) {
        final cellsList = <Map<String, Object?>>[];
        final data = <String, Object?>{
          'timestamp': timestamp,
          'cols': buffer.width,
          'rows': buffer.height,
          'cellWidth': atlas.cellWidth,
          'cellHeight': atlas.cellHeight,
          'cells': cellsList,
        };

        for (var y = 0; y < buffer.height; y++) {
          final rowOffset = y * buffer.width;
          for (var x = 0; x < buffer.width; x++) {
            final idx = rowOffset + x;
            final char = buffer.characters[idx];
            final fg = buffer.getForeground(x, y);
            final bg = buffer.getBackground(x, y);
            final mods = buffer.getModifiers(x, y);

            final rect = atlas.charRects[char];
            final cellData = {
              'x': x,
              'y': y,
              'char': char,
              'fg': fg != 0
                  ? '0x${fg.toRadixString(16).padLeft(8, '0').toUpperCase()}'
                  : null,
              'bg': bg != 0
                  ? '0x${bg.toRadixString(16).padLeft(8, '0').toUpperCase()}'
                  : null,
              'modifiers': mods,
            };
            if (rect != null) {
              cellData['atlasRect'] = {
                'left': rect.left,
                'top': rect.top,
                'right': rect.right,
                'bottom': rect.bottom,
              };
            }
            cellsList.add(cellData);
          }
        }

        final jsonStr = const JsonEncoder.withIndent('  ').convert(data);
        final jsonBytes = utf8.encode(jsonStr);
        coordinatesBasename = await widget.service.saveScreenshot(
          'coordinates_$timestamp.json',
          jsonBytes,
        );
      }

      if (mounted) {
        final savedFiles = <String>[
          ?screenshotBasename,
          ?atlasBasename,
          if (atlasBasename != null)
            atlasBasename
                .replaceFirst('atlas_', 'atlas_table_')
                .replaceAll('.png', '.json'),
          ?coordinatesBasename,
        ];

        final String message;
        if (savedFiles.isNotEmpty) {
          message = 'Saved: ${savedFiles.join(', ')}';
        } else {
          message = 'No files saved.';
        }

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(message),
            duration: const Duration(seconds: 4),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error saving screenshot/atlas/coordinates: $e'),
          ),
        );
      }
    }
  }

  static const int _maxWheelStepsPerEvent = 32;
  static const Duration _scrollIdleReset = Duration(milliseconds: 250);

  double _scrollRemainderDy = 0.0;
  DateTime? _lastScrollAt;

  void _resetScrollAccumulator() {
    _scrollRemainderDy = 0.0;
    _lastScrollAt = null;
  }

  void _accumulateScrollDy(double dy) {
    final now = clock.now();
    final lastAt = _lastScrollAt;
    if (lastAt != null && now.difference(lastAt) > _scrollIdleReset) {
      _scrollRemainderDy = 0.0;
    } else if (_scrollRemainderDy * dy < 0) {
      _scrollRemainderDy = 0.0;
    }
    _lastScrollAt = now;
    _scrollRemainderDy += dy;
  }

  void _handleScrollDelta(PointerEvent event, double dy, Size layoutSize) {
    if (dy == 0.0 || !dy.isFinite) return;
    final cellWidth = _atlas!.cellWidth;
    final cellHeight = _atlas!.cellHeight;
    if (cellWidth <= 0 || cellHeight <= 0) return;

    final maxCol = (layoutSize.width / cellWidth).floor();
    final maxRow = (layoutSize.height / cellHeight).floor();
    if (maxCol <= 0 || maxRow <= 0) return;

    _accumulateScrollDy(dy);
    final rawSteps = (_scrollRemainderDy / cellHeight).truncate();
    if (rawSteps == 0) return;
    _scrollRemainderDy -= rawSteps * cellHeight;

    final col = (event.localPosition.dx / cellWidth).floor().clamp(
      0,
      maxCol - 1,
    );
    final row = (event.localPosition.dy / cellHeight).floor().clamp(
      0,
      maxRow - 1,
    );
    final steps = rawSteps.abs().clamp(1, _maxWheelStepsPerEvent);
    final button = rawSteps < 0
        ? term.MouseButton.wheelUp
        : term.MouseButton.wheelDown;
    final mods = _collectHardwareModifiers();

    for (var i = 0; i < steps; i++) {
      final termEvent = term.MouseEvent(
        x: col + 1,
        y: row + 1,
        button: button,
        type: term.MouseEventType.press,
        modifiers: mods,
      );
      _lastInjectedPointerEvent = termEvent;
      widget.terminal.injectEvent(termEvent);
    }
  }

  static term.MouseButton _resolveMouseButton(int buttons) {
    if ((buttons & kSecondaryMouseButton) != 0) return term.MouseButton.right;
    if ((buttons & kMiddleMouseButton) != 0) return term.MouseButton.middle;
    return term.MouseButton.left;
  }

  static (term.MouseButton, term.MouseEventType) _classifyPointerEvent(
    PointerEvent event,
  ) => switch (event) {
    PointerDownEvent(:final buttons) => (
      _resolveMouseButton(buttons),
      term.MouseEventType.press,
    ),
    PointerMoveEvent(:final down, :final buttons) when down => (
      _resolveMouseButton(buttons),
      term.MouseEventType.drag,
    ),
    PointerUpEvent() => (term.MouseButton.left, term.MouseEventType.release),
    _ => (term.MouseButton.none, term.MouseEventType.move),
  };

  void _updateSelectionAndUri(
    int col,
    int row,
    term.MouseButton button,
    term.MouseEventType type,
  ) {
    final nextUri = _currentBuffer?.getUri(col, row);
    final linkMod = _isLinkOpenModifierPressed();
    var rebuild = nextUri != _hoveredUri || linkMod != _isLinkModifierActive;
    _hoveredUri = nextUri;
    _isLinkModifierActive = linkMod;

    if (type == term.MouseEventType.press && button == term.MouseButton.left) {
      if (_selectionFocus != null) rebuild = true;
      _startSelectionAt(col, row);
    } else if (type == term.MouseEventType.drag && _isSelecting) {
      rebuild = _updateActiveDragSelection(col, row) || rebuild;
    } else if (type == term.MouseEventType.release) {
      _finishPointerRelease(col, row, nextUri);
    }

    if (rebuild && mounted) {
      setState(() {});
    }
  }

  void _startSelectionAt(int col, int row) {
    final buf = _currentBuffer;
    final colBounds = _resolveRegionColBounds(buf, col, row);
    if (_isGraphicCanvasPress(buf, row, colBounds)) {
      _selectionAnchor = null;
      _selectionFocus = null;
      _selectionColBounds = null;
      _isSelecting = false;
      return;
    }
    _selectionAnchor = Point(col, row);
    _selectionFocus = null;
    _selectionColBounds = colBounds;
    _selectionBoxMode = HardwareKeyboard.instance.isAltPressed;
    _isSelecting = true;
  }

  bool _updateActiveDragSelection(int col, int row) {
    final anchor = _selectionAnchor;
    if (anchor == null) return false;
    final boxMode = HardwareKeyboard.instance.isAltPressed;
    final bounds = _selectionColBounds;
    final clampedX = (!boxMode && bounds != null)
        ? col.clamp(bounds.$1, bounds.$2)
        : col;
    final pt = Point(clampedX, row);
    if ((pt != anchor || _selectionFocus != null) &&
        (_selectionFocus != pt || _selectionBoxMode != boxMode)) {
      _selectionFocus = pt;
      _selectionBoxMode = boxMode;
      return true;
    }
    return false;
  }

  static (int, int)? _resolveRegionColBounds(Buffer? buf, int col, int row) {
    if (buf == null || buf.width <= 0 || buf.height <= 0) return null;
    var minCol = 0;
    for (var x = col - 1; x >= 0; x--) {
      if (_isVerticalPaneDivider(buf, x, row)) {
        minCol = x + 1;
        break;
      }
    }
    var maxCol = buf.width - 1;
    for (var x = col + 1; x < buf.width; x++) {
      if (_isVerticalPaneDivider(buf, x, row)) {
        maxCol = x - 1;
        break;
      }
    }
    return minCol <= maxCol ? (minCol, maxCol) : (0, buf.width - 1);
  }

  static bool _isVerticalPaneDivider(Buffer buf, int x, int row) {
    if (!_isVerticalBoxChar(buf.getCharacter(x, row))) return false;
    final minSpan = max(3, buf.height ~/ 2);
    var span = 1;
    for (
      var y = row - 1;
      y >= 0 && _isVerticalBoxChar(buf.getCharacter(x, y));
      y--
    ) {
      span++;
    }
    for (
      var y = row + 1;
      y < buf.height && _isVerticalBoxChar(buf.getCharacter(x, y));
      y++
    ) {
      span++;
    }
    return span >= minSpan;
  }

  static bool _isVerticalBoxChar(String ch) =>
      ch == '│' || ch == '┃' || ch == '║';

  static bool _isGraphicCanvasPress(
    Buffer? buf,
    int row,
    (int, int)? colBounds,
  ) {
    if (buf == null || row < 0 || row >= buf.height) return false;
    final minCol = colBounds?.$1 ?? 0;
    final maxCol = colBounds?.$2 ?? (buf.width - 1);
    var halfBlocks = 0;
    for (var x = minCol; x <= maxCol; x++) {
      if (Modifier.has(buf.getModifiers(x, row), Modifier.kittyPlaceholder)) {
        return true;
      }
      final ch = buf.getCharacter(x, row);
      if (ch == '▀' || ch == '▄') {
        halfBlocks++;
        if (halfBlocks >= 8) return true;
      }
    }
    return false;
  }

  void _finishPointerRelease(int col, int row, String? uri) {
    final wasDragging = _isSelecting && _selectionFocus != null;
    final clickedSameCell =
        _isSelecting &&
        _selectionFocus == null &&
        _selectionAnchor == Point(col, row);
    _isSelecting = false;
    if (wasDragging) {
      final selectedText = _extractSelectedText();
      if (selectedText.isNotEmpty) {
        unawaited(_writeToClipboard(selectedText));
      }
      return;
    }
    _selectionAnchor = null;
    if (clickedSameCell &&
        uri != null &&
        uri.isNotEmpty &&
        _isLinkOpenModifierPressed()) {
      unawaited(widget.service.openUrl(uri));
    }
  }

  String _extractSelectedText() {
    final buf = _currentBuffer;
    final a = _selectionAnchor;
    final b = _selectionFocus;
    if (buf == null || a == null || b == null || buf.width <= 0) return '';
    final (start, end) = (a.y < b.y || (a.y == b.y && a.x <= b.x))
        ? (a, b)
        : (b, a);
    final minCol = _selectionColBounds?.$1 ?? 0;
    final maxCol = _selectionColBounds?.$2 ?? (buf.width - 1);
    final lines = <String>[];
    for (var y = start.y; y <= end.y; y++) {
      final (rowStart, rowEnd) = _selectedRowSpan(
        y,
        start,
        end,
        minCol,
        maxCol,
      );
      lines.add(_extractRowSlice(buf, y, rowStart, rowEnd));
    }
    return lines.join('\n');
  }

  (int, int) _selectedRowSpan(
    int y,
    Point<int> start,
    Point<int> end,
    int minCol,
    int maxCol,
  ) {
    if (_selectionBoxMode || start.y == end.y) {
      return (min(start.x, end.x), max(start.x, end.x));
    }
    if (y == start.y) return (max(minCol, start.x), maxCol);
    if (y == end.y) return (minCol, min(maxCol, end.x));
    return (minCol, maxCol);
  }

  static String _extractRowSlice(Buffer buf, int y, int x0, int x1) {
    if (y < 0 || y >= buf.height || x0 > x1) return '';
    final sb = StringBuffer();
    final rowBase = y * buf.width;
    final endX = x1.clamp(0, buf.width - 1);
    for (var x = x0.clamp(0, buf.width - 1); x <= endX; x++) {
      final idx = rowBase + x;
      final char = buf.characters[idx];
      if (char.isEmpty) continue;
      if (Modifier.has(
        buf.attributes[idx * 3 + 2],
        Modifier.kittyPlaceholder,
      )) {
        continue;
      }
      sb.write(char);
    }
    return sb.toString().replaceFirst(RegExp(r' +$'), '');
  }

  void _handlePointerEvent(PointerEvent event, Size layoutSize) {
    final cellWidth = _atlas!.cellWidth;
    final cellHeight = _atlas!.cellHeight;
    final maxCol = (layoutSize.width / cellWidth).floor();
    final maxRow = (layoutSize.height / cellHeight).floor();
    if (maxCol <= 0 || maxRow <= 0) return;

    final clampedCol = (event.localPosition.dx / cellWidth).floor().clamp(
      0,
      maxCol - 1,
    );
    final clampedRow = (event.localPosition.dy / cellHeight).floor().clamp(
      0,
      maxRow - 1,
    );

    if (event is PointerDownEvent &&
        !_focusNode.hasFocus &&
        _focusNode.canRequestFocus) {
      _focusNode.requestFocus();
    }

    final (termuiButton, termuiType) = _classifyPointerEvent(event);
    _updateSelectionAndUri(clampedCol, clampedRow, termuiButton, termuiType);

    final termEvent = term.MouseEvent(
      x: clampedCol + 1,
      y: clampedRow + 1,
      button: termuiButton,
      type: termuiType,
      modifiers: _collectHardwareModifiers(),
    );

    if ((termuiType == term.MouseEventType.move ||
            termuiType == term.MouseEventType.drag) &&
        _lastInjectedPointerEvent == termEvent) {
      return;
    }

    _lastInjectedPointerEvent = termEvent;
    widget.terminal.injectEvent(termEvent);
  }

  @override
  Widget build(BuildContext context) {
    if (_atlas == null) {
      return Scaffold(
        backgroundColor: widget.backgroundColor,
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final cellWidth = _atlas!.cellWidth;
        final cellHeight = _atlas!.cellHeight;

        final fallbackSize = MediaQuery.maybeSizeOf(context);
        final availableWidth = constraints.hasBoundedWidth
            ? constraints.maxWidth
            : (fallbackSize?.width ??
                  widget.terminal.backend.size.x * cellWidth);
        final availableHeight = constraints.hasBoundedHeight
            ? constraints.maxHeight
            : (fallbackSize?.height ??
                  widget.terminal.backend.size.y * cellHeight);

        final cols = (availableWidth / cellWidth).floor();
        final rows = (availableHeight / cellHeight).floor();

        if (cols > 0 && rows > 0) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted) return;
            widget.terminal.updateSize(Point(cols, rows));
          });
        }

        final layoutSize = Size(cols * cellWidth, rows * cellHeight);

        return Scaffold(
          backgroundColor: widget.backgroundColor,
          body: Focus(
            focusNode: _focusNode,
            autofocus: true,
            onKeyEvent: (node, event) {
              _handleKeyEvent(event);
              return KeyEventResult.handled;
            },
            child: Center(
              child: RepaintBoundary(
                key: _boundaryKey,
                child: MouseRegion(
                  cursor: _effectiveCursor,
                  child: Listener(
                    onPointerDown: (e) => _handlePointerEvent(e, layoutSize),
                    onPointerMove: (e) => _handlePointerEvent(e, layoutSize),
                    onPointerHover: (e) => _handlePointerEvent(e, layoutSize),
                    onPointerUp: (e) => _handlePointerEvent(e, layoutSize),
                    onPointerCancel: (_) => _resetScrollAccumulator(),
                    onPointerSignal: (signal) {
                      if (signal case PointerScrollEvent(:final scrollDelta)) {
                        _handleScrollDelta(signal, scrollDelta.dy, layoutSize);
                      }
                    },
                    onPointerPanZoomStart: (_) => _resetScrollAccumulator(),
                    onPointerPanZoomUpdate: (event) => _handleScrollDelta(
                      event,
                      -event.panDelta.dy,
                      layoutSize,
                    ),
                    onPointerPanZoomEnd: (_) => _resetScrollAccumulator(),
                    child: Container(
                      width: layoutSize.width,
                      height: layoutSize.height,
                      color: widget.backgroundColor,
                      child: _currentBuffer == null
                          ? const SizedBox()
                          : CustomPaint(
                              size: layoutSize,
                              painter: TuiAtlasPainter(
                                buffer: _currentBuffer!,
                                atlas: _atlas!,
                                fontFamily: widget.fontFamily,
                                fontFamilyFallback: widget.fontFamilyFallback,
                                fallbackPainters: _fallbackPainters,
                                onMissingGlyphs: _onMissingGlyphs,
                                enableBleed: widget.enableBleed,
                                selectionStart: _selectionFocus != null
                                    ? _selectionAnchor
                                    : null,
                                selectionEnd: _selectionFocus,
                                selectionColBounds: _selectionColBounds,
                                selectionBoxMode: _selectionBoxMode,
                                kittyImages: _kittyGpuImages,
                              ),
                            ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
