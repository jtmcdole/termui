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
import 'package:termui/perf/tracer.dart';
import 'package:termui/terminal/terminal.dart' as term;
import 'package:termui/ui/buffer.dart';
import 'package:termui/ui/style.dart';
import 'package:termui/ui/widgets/display/kitty_image.dart';
import 'package:termui/ui/widgets/interactive/selection_controller.dart';

import 'backend.dart';
import 'rendering/atlas.dart';
import 'rendering/painter.dart';
import 'service/terminal_service.dart';
import 'util/font_helper.dart';

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

  /// Enables multi-cell font ligatures. Defaults to false.
  final bool enableLigatures;

  /// Optional controller managing interactive text selection state.
  final TerminalSelectionController? selectionController;

  /// Whether built-in viewport mouse selection and auto-copy are enabled. Defaults to `true`.
  final bool enableBuiltinSelection;

  /// Whether built-in `OSC 8` link cursor and click opening are enabled. Defaults to `true`.
  final bool enableBuiltinLinkOpen;

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
    this.enableLigatures = false,
    this.selectionController,
    this.enableBuiltinSelection = true,
    this.enableBuiltinLinkOpen = true,
  });

  @override
  State<Terminal> createState() => _TerminalState();
}

class _TerminalState extends State<Terminal> {
  FlutterTerminal? _internalTerminal;
  bool _isRunning = false;

  FlutterTerminal get _terminal => widget.terminal ?? _internalTerminal!;

  @override
  void initState() {
    super.initState();
    if (widget.terminal == null) {
      _internalTerminal = FlutterTerminal(
        initialFontSize: widget.fontSize,
        enableLigatures: widget.enableLigatures,
        enableBuiltinSelection: widget.enableBuiltinSelection,
        enableBuiltinLinkOpen: widget.enableBuiltinLinkOpen,
      )..setEnableLigatures(widget.enableLigatures);
    }
  }

  @override
  void didUpdateWidget(Terminal oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.terminal != widget.terminal) {
      if (oldWidget.terminal == null) {
        _internalTerminal?.dispose();
        _internalTerminal = null;
      }
      if (widget.terminal == null) {
        _internalTerminal = FlutterTerminal(
          initialFontSize: widget.fontSize,
          enableLigatures: widget.enableLigatures,
          enableBuiltinSelection: widget.enableBuiltinSelection,
          enableBuiltinLinkOpen: widget.enableBuiltinLinkOpen,
        );
      }
    } else if (widget.terminal == null) {
      if (oldWidget.enableLigatures != widget.enableLigatures) {
        _internalTerminal?.setEnableLigatures(widget.enableLigatures);
      }
      if (oldWidget.enableBuiltinSelection != widget.enableBuiltinSelection) {
        _internalTerminal?.setEnableBuiltinSelection(
          widget.enableBuiltinSelection,
        );
      }
      if (oldWidget.enableBuiltinLinkOpen != widget.enableBuiltinLinkOpen) {
        _internalTerminal?.setEnableBuiltinLinkOpen(
          widget.enableBuiltinLinkOpen,
        );
      }
    }
  }

  @override
  void dispose() {
    _internalTerminal?.dispose();
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
      enableLigatures: widget.enableLigatures,
      selectionController: widget.selectionController,
      enableBuiltinSelection:
          widget.enableBuiltinSelection && _terminal.enableBuiltinSelection,
      enableBuiltinLinkOpen:
          widget.enableBuiltinLinkOpen && _terminal.enableBuiltinLinkOpen,
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

  /// Enables multi-cell font ligatures. Defaults to false.
  final bool enableLigatures;

  /// Optional controller managing interactive text selection state.
  final TerminalSelectionController? selectionController;

  /// Whether built-in viewport mouse selection and auto-copy are enabled. Defaults to `true`.
  final bool enableBuiltinSelection;

  /// Whether built-in `OSC 8` link cursor and click opening are enabled. Defaults to `true`.
  final bool enableBuiltinLinkOpen;

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
    this.enableLigatures = false,
    this.selectionController,
    this.enableBuiltinSelection = true,
    this.enableBuiltinLinkOpen = true,
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
  StreamSubscription<bool>? _ligaturesSubscription;
  StreamSubscription<bool>? _builtinSelectionSubscription;
  StreamSubscription<bool>? _builtinLinkOpenSubscription;
  late bool _enableLigatures;
  late bool _terminalBuiltinSelection;
  late bool _terminalBuiltinLinkOpen;
  final Set<LogicalKeyboardKey> _suppressedHostShortcutKeys = {};
  MouseCursor _currentCursor = SystemMouseCursors.basic;
  String? _hoveredUri;
  bool _isLinkModifierActive = false;
  late TerminalSelectionController _selectionController;
  ({int col, int row})? _linkPressCell;
  bool _isSelecting = false;

  bool get _builtinSelectionEnabled =>
      widget.enableBuiltinSelection && _terminalBuiltinSelection;

  bool get _builtinLinkOpenEnabled =>
      widget.enableBuiltinLinkOpen && _terminalBuiltinLinkOpen;

  /// The active selection controller for this terminal view.
  TerminalSelectionController get selectionController => _selectionController;

  MouseCursor get _effectiveCursor =>
      (_builtinLinkOpenEnabled &&
          _hoveredUri != null &&
          _isLinkModifierActive &&
          _currentCursor == SystemMouseCursors.basic)
      ? SystemMouseCursors.click
      : _currentCursor;

  final Map<(String, bool, bool, bool, Color), TextPainter> _fallbackPainters =
      {};
  final Map<(String, bool, bool, Color), TextPainter> _ligaturePainters = {};
  final Map<KittyImageData, ui.Image> _kittyGpuImages = {};
  final Map<(KittyImageRegistry, int), ui.Image> _kittyGpuImagesById = {};
  final Set<KittyImageData> _decodingKittyImages = Set.identity();
  final Set<(String, GlyphStyleVariant)> _pendingGlyphs = {};
  final Set<(String, GlyphStyleVariant)> _processingGlyphs = {};
  static const int _maxKittyGpuImages = 64;
  static const int _maxFallbackPainters = 256;
  bool _isUpdatingAtlas = false;
  term.MouseEvent? _lastInjectedPointerEvent;

  late double _fontSize;

  /// Current font size rendered by the terminal view.
  double get fontSize => _fontSize;

  /// Active fallback [TextPainter] cache keys for unit and widget tests.
  @visibleForTesting
  Set<(String, bool, bool, bool, Color)> get debugFallbackPainterKeys =>
      Set.unmodifiable(_fallbackPainters.keys);

  /// Active [GlyphAtlas] instance for unit and widget tests.
  @visibleForTesting
  GlyphAtlas? get debugAtlas => _atlas;

  /// Triggers the F12 screenshot pipeline and returns when saving completes.
  @visibleForTesting
  Future<void> debugTakeScreenshot() => _performTakeScreenshot();
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
    _enableLigatures =
        widget.enableLigatures || widget.terminal.enableLigatures;
    _terminalBuiltinSelection = widget.terminal.enableBuiltinSelection;
    _terminalBuiltinLinkOpen = widget.terminal.enableBuiltinLinkOpen;
    _bindTerminalStreams();

    _selectionController =
        widget.selectionController ?? TerminalSelectionController();
    _selectionController.addListener(_onSelectionChanged);

    _initAtlasAndLoop();
  }

  void _bindTerminalStreams() {
    _fontSizeSubscription?.cancel();
    _mouseCursorSubscription?.cancel();
    _ligaturesSubscription?.cancel();
    _builtinSelectionSubscription?.cancel();
    _builtinLinkOpenSubscription?.cancel();
    _fontSizeSubscription = widget.terminal.watchFontSize().listen((newSize) {
      if (!mounted) return;
      Tracer.record(
        _traceFontSizeChangedId,
        Phase.instant,
        TraceCategory.layout,
      );
      setState(() {
        _fontSize = newSize;
      });
      _recreateAtlas();
    });
    _mouseCursorSubscription = widget.terminal.mouseCursorChanges.listen((
      cursorName,
    ) {
      if (!mounted) return;
      setState(() {
        _currentCursor = _mapOsc22ToSystemCursor(cursorName);
      });
    });
    _ligaturesSubscription = widget.terminal.watchEnableLigatures().listen((
      enabled,
    ) {
      if (!mounted) return;
      setState(() {
        _enableLigatures = enabled;
      });
    });
    _builtinSelectionSubscription = widget.terminal
        .watchEnableBuiltinSelection()
        .listen(_onTerminalBuiltinSelectionChanged);
    _builtinLinkOpenSubscription = widget.terminal
        .watchEnableBuiltinLinkOpen()
        .listen(_onTerminalBuiltinLinkOpenChanged);
    _bindClipboardStreams();
  }

  void _onTerminalBuiltinSelectionChanged(bool enabled) {
    if (!mounted) return;
    if (!enabled) {
      _isSelecting = false;
      _selectionController.clearSelection();
    }
    setState(() {
      _terminalBuiltinSelection = enabled;
    });
  }

  void _onTerminalBuiltinLinkOpenChanged(bool enabled) {
    if (!mounted) return;
    if (!enabled) {
      _hoveredUri = null;
      _isLinkModifierActive = false;
      _linkPressCell = null;
    }
    setState(() {
      _terminalBuiltinLinkOpen = enabled;
    });
  }

  void _onSelectionChanged() {
    if (mounted) {
      setState(() {});
    }
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
    _disposePainterCaches();
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
      newAtlas.dispose();
      Tracer.record(_traceRecreateAtlasId, Phase.end, TraceCategory.paint);
      return;
    }
    final oldAtlas = _atlas;
    widget.terminal
      ..updateExactCellPixelSize(newAtlas.cellWidth, newAtlas.cellHeight)
      ..updateCellPixelSize(
        newAtlas.cellWidth.round(),
        newAtlas.cellHeight.round(),
      );
    setState(() {
      _atlas = newAtlas;
      if (_currentBuffer != null) {
        _updateFallbackPainters(_currentBuffer!);
      }
    });
    if (oldAtlas != null && !identical(oldAtlas.image, newAtlas.image)) {
      oldAtlas.dispose();
    }
    Tracer.record(_traceRecreateAtlasId, Phase.end, TraceCategory.paint);
  }

  void _disposePainterCaches() {
    for (final painter in _fallbackPainters.values) {
      painter.dispose();
    }
    _fallbackPainters.clear();
    for (final painter in _ligaturePainters.values) {
      painter.dispose();
    }
    _ligaturePainters.clear();
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
      _fontSize = widget.terminal.fontSize;
      _enableLigatures =
          widget.enableLigatures || widget.terminal.enableLigatures;
      _terminalBuiltinSelection = widget.terminal.enableBuiltinSelection;
      _terminalBuiltinLinkOpen = widget.terminal.enableBuiltinLinkOpen;
      _suppressedHostShortcutKeys.clear();
      _bindTerminalStreams();
      _recreateAtlas();
    } else {
      _syncFontConfig(oldWidget);
      if (oldWidget.enableLigatures != widget.enableLigatures) {
        _enableLigatures = widget.enableLigatures;
      }
    }
    if (oldWidget.enableBuiltinSelection && !widget.enableBuiltinSelection) {
      _isSelecting = false;
      _selectionController.clearSelection();
    }
    if (oldWidget.enableBuiltinLinkOpen && !widget.enableBuiltinLinkOpen) {
      _hoveredUri = null;
      _isLinkModifierActive = false;
      _linkPressCell = null;
    }
    _syncSelectionController(oldWidget);
  }

  void _syncFontConfig(PrivateTuiView oldWidget) {
    if (oldWidget.fontSize != widget.fontSize) {
      widget.terminal.setFontSize(widget.fontSize);
    } else if (oldWidget.fontFamily != widget.fontFamily ||
        oldWidget.fontFamilyFallback != widget.fontFamilyFallback) {
      _recreateAtlas();
    }
  }

  void _syncSelectionController(PrivateTuiView oldWidget) {
    if (oldWidget.selectionController == widget.selectionController) return;
    _selectionController.removeListener(_onSelectionChanged);
    if (oldWidget.selectionController == null) {
      _selectionController.dispose();
    }
    _selectionController =
        widget.selectionController ?? TerminalSelectionController();
    _selectionController.addListener(_onSelectionChanged);
  }

  @override
  void dispose() {
    _selectionController.removeListener(_onSelectionChanged);
    if (widget.selectionController == null) {
      _selectionController.dispose();
    }
    PaintingBinding.instance.systemFonts.removeListener(
      _handleSystemFontsChange,
    );
    _fontSizeSubscription?.cancel();
    _mouseCursorSubscription?.cancel();
    _clipboardSubscription?.cancel();
    _pasteRequestSubscription?.cancel();
    _ligaturesSubscription?.cancel();
    _builtinSelectionSubscription?.cancel();
    _builtinLinkOpenSubscription?.cancel();
    _suppressedHostShortcutKeys.clear();
    _disposePainterCaches();
    _kittyGpuImagesById.clear();
    for (final image in _kittyGpuImages.values) {
      image.dispose();
    }
    _kittyGpuImages.clear();
    _decodingKittyImages.clear();
    _atlasGenerationId++;
    _atlas?.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _updateFallbackPainters(Buffer buffer) {
    final atlas = _atlas;
    if (atlas == null) return;

    final total = buffer.width * buffer.height;
    final width = buffer.width;
    KittyImageData? lastKittyData;
    for (var i = 0; i < total; i++) {
      final char = buffer.characters[i];
      if (char.isEmpty || char == ' ') continue;
      final x = i % width;
      final y = i ~/ width;
      final mods = buffer.getModifiers(x, y);
      if (Modifier.has(mods, Modifier.kittyPlaceholder) ||
          char.startsWith(kittyPlaceholderChar)) {
        lastKittyData = _resolveAndEnsureKittyGpuImage(
          buffer,
          x,
          y,
          char,
          lastKittyData,
        );
        continue;
      }
      _ensureGlyphFallbackIfMissing(atlas, buffer, x, y, char, mods);
    }
  }

  void _ensureGlyphFallbackIfMissing(
    GlyphAtlas atlas,
    Buffer buffer,
    int x,
    int y,
    String char,
    int mods,
  ) {
    final isBold = Modifier.has(mods, Modifier.bold);
    final isItalic = Modifier.has(mods, Modifier.italic);
    if (atlas.rectFor(char, isBold: isBold, isItalic: isItalic) != null) {
      return;
    }
    _ensureFallbackPainterForCell(buffer, x, y, char, mods);
  }

  KittyImageData? _resolveAndEnsureKittyGpuImage(
    Buffer buffer,
    int x,
    int y,
    String char,
    KittyImageData? lastKittyData,
  ) {
    final imageId = extractKittyCellImageId(char, buffer.getForeground(x, y));
    if (imageId == 0) return lastKittyData;
    final registry = buffer.lookupKittyRegistry(x, y);
    final data = registry.lookupImage(imageId);
    if (data != null && !identical(data, lastKittyData)) {
      _ensureKittyGpuImage(registry, data);
      return data;
    }
    return lastKittyData;
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
    final isItalic = Modifier.has(mods, Modifier.italic);
    final isDim = Modifier.has(mods, Modifier.dim);

    final key = (char, isBold, isItalic, isDim, color);
    if (_fallbackPainters.containsKey(key)) return;
    while (_fallbackPainters.length >= _maxFallbackPainters) {
      final oldest = _fallbackPainters.keys.first;
      _fallbackPainters.remove(oldest)?.dispose();
    }
    final textStyle = TextStyle(
      fontFamily: widget.fontFamily,
      fontFamilyFallback: widget.fontFamilyFallback,
      fontSize: _fontSize,
      color: color,
      fontWeight: isBold ? FontWeight.bold : FontWeight.normal,
      fontStyle: isItalic ? FontStyle.italic : FontStyle.normal,
      height: 1.0,
    );
    _fallbackPainters[key] = TextPainter(
      text: TextSpan(text: char, style: textStyle),
      textDirection: TextDirection.ltr,
    )..layout();
  }

  void _evictBakedFallbackPainters(List<(String, GlyphStyleVariant)> baked) {
    if (_fallbackPainters.isEmpty) return;
    final bakedSet = <(String, bool, bool)>{
      for (final (char, variant) in baked)
        (
          char,
          variant == GlyphStyleVariant.bold ||
              variant == GlyphStyleVariant.boldItalic,
          variant == GlyphStyleVariant.italic ||
              variant == GlyphStyleVariant.boldItalic,
        ),
    };
    final toRemove = <(String, bool, bool, bool, Color)>[];
    for (final key in _fallbackPainters.keys) {
      if (bakedSet.contains((key.$1, key.$2, key.$3))) {
        toRemove.add(key);
      }
    }
    for (final key in toRemove) {
      _fallbackPainters.remove(key)?.dispose();
    }
  }

  void _ensureKittyGpuImage(KittyImageRegistry registry, KittyImageData data) {
    final existing = _kittyGpuImages.remove(data);
    if (existing != null) {
      _kittyGpuImages[data] = existing;
      _kittyGpuImagesById[(registry, data.imageId)] = existing;
      return;
    }
    if (data.rgbaPixels.isEmpty) return;
    if (data.format == 100) {
      if (!_decodingKittyImages.add(data)) return;
      unawaited(_decodeKittyPngImage(registry, data));
      return;
    }
    if (data.pixelWidth <= 0 || data.pixelHeight <= 0) return;
    if (!_decodingKittyImages.add(data)) return;
    ui.decodeImageFromPixels(
      data.rgbaPixels,
      data.pixelWidth,
      data.pixelHeight,
      ui.PixelFormat.rgba8888,
      (decoded) => _onKittyGpuImageDecoded(registry, data, decoded),
    );
  }

  static const List<int> _pngMagic = [
    0x89,
    0x50,
    0x4E,
    0x47,
    0x0D,
    0x0A,
    0x1A,
    0x0A,
  ];

  static bool _isValidKittyPngPayload(KittyImageData data) {
    final w = data.pixelWidth;
    final h = data.pixelHeight;
    if (w <= 0 || w > 4096 || h <= 0 || h > 4096 || w * h > 4194304) {
      return false;
    }
    final bytes = data.rgbaPixels;
    if (bytes.length < 24 || !_hasPngIhdrMagic(bytes)) return false;
    final view = ByteData.sublistView(bytes);
    return view.getUint32(8) == 13 &&
        view.getUint32(16) == w &&
        view.getUint32(20) == h;
  }

  static bool _hasPngIhdrMagic(Uint8List bytes) {
    for (var i = 0; i < _pngMagic.length; i++) {
      if (bytes[i] != _pngMagic[i]) return false;
    }
    return bytes[12] == 0x49 &&
        bytes[13] == 0x48 &&
        bytes[14] == 0x44 &&
        bytes[15] == 0x52;
  }

  Future<void> _decodeKittyPngImage(
    KittyImageRegistry registry,
    KittyImageData data,
  ) async {
    if (!_isValidKittyPngPayload(data)) {
      _decodingKittyImages.remove(data);
      return;
    }
    ui.Codec? codec;
    try {
      codec = await ui.instantiateImageCodec(
        data.rgbaPixels,
        targetWidth: data.pixelWidth,
        targetHeight: data.pixelHeight,
      );
      final frame = await codec.getNextFrame();
      _onKittyGpuImageDecoded(registry, data, frame.image);
    } on Object catch (_) {
      _decodingKittyImages.remove(data);
    } finally {
      codec?.dispose();
    }
  }

  void _evictOldestKittyGpuImage() {
    final oldestKey = _kittyGpuImages.keys.first;
    final evicted = _kittyGpuImages.remove(oldestKey);
    if (evicted == null) return;
    _kittyGpuImagesById.removeWhere((_, img) => identical(img, evicted));
    evicted.dispose();
  }

  void _onKittyGpuImageDecoded(
    KittyImageRegistry registry,
    KittyImageData data,
    ui.Image decoded,
  ) {
    _decodingKittyImages.remove(data);
    if (!mounted) {
      decoded.dispose();
      return;
    }
    while (_kittyGpuImages.length >= _maxKittyGpuImages &&
        !_kittyGpuImages.containsKey(data)) {
      _evictOldestKittyGpuImage();
    }
    final old = _kittyGpuImages[data];
    setState(() {
      _kittyGpuImages[data] = decoded;
      _kittyGpuImagesById[(registry, data.imageId)] = decoded;
    });
    if (old != null && !identical(old, decoded)) {
      old.dispose();
    }
  }

  void _onMissingStyledGlyphs(List<(String, GlyphStyleVariant)> glyphs) {
    if (_atlas == null) return;
    var needsUpdate = false;
    for (final entry in glyphs) {
      if (!_pendingGlyphs.contains(entry) &&
          !_processingGlyphs.contains(entry) &&
          !_atlas!.styledCharRects.containsKey(entry)) {
        _pendingGlyphs.add(entry);
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
      final newAtlas = await oldAtlas!.addStyledGlyphs(batch);
      if (!mounted || genId != _atlasGenerationId || newAtlas.isDisposed) {
        if (!identical(oldAtlas.image, newAtlas.image)) {
          newAtlas.dispose();
        }
        return;
      }
      setState(() {
        _atlas = newAtlas;
        _evictBakedFallbackPainters(batch);
      });
      if (!identical(oldAtlas.image, newAtlas.image)) {
        oldAtlas.dispose();
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
    if (!_builtinLinkOpenEnabled) return;
    final pressed = _isLinkOpenModifierPressed();
    if (pressed != _isLinkModifierActive) {
      _isLinkModifierActive = pressed;
      if (_hoveredUri != null && mounted) {
        setState(() {});
      }
    }
  }

  KeyEventResult _handleKeyEvent(KeyEvent event) {
    _syncLinkModifierState();
    if (event is KeyUpEvent) {
      if (!widget.terminal.reportKeyReleaseEvents) {
        _suppressedHostShortcutKeys.clear();
        return KeyEventResult.ignored;
      }
      if (_suppressedHostShortcutKeys.remove(event.logicalKey)) {
        return KeyEventResult.handled;
      }
      return _injectResolvedKeyEvent(
        event,
        eventType: term.KeyEventType.release,
      );
    }
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    if (_handleHostKeyShortcut(event.logicalKey)) {
      return KeyEventResult.handled;
    }
    final eventType = event is KeyRepeatEvent
        ? term.KeyEventType.repeat
        : term.KeyEventType.press;
    return _injectResolvedKeyEvent(event, eventType: eventType);
  }

  bool _handleHostKeyShortcut(LogicalKeyboardKey key) {
    if (key == LogicalKeyboardKey.f12) {
      if (HardwareKeyboard.instance.isShiftPressed) {
        _recreateAtlas();
      } else {
        _takeScreenshot();
      }
      return true;
    }
    final mods = _collectHardwareModifiers();
    if (_isPasteShortcut(key, mods)) {
      if (widget.terminal.reportKeyReleaseEvents) {
        _suppressedHostShortcutKeys.add(key);
      }
      unawaited(_pasteFromClipboard());
      return true;
    }
    return false;
  }

  KeyEventResult _injectResolvedKeyEvent(
    KeyEvent event, {
    required term.KeyEventType eventType,
  }) {
    final mods = _collectHardwareModifiers();
    final resolved = _resolveKeyEvent(event, mods, eventType: eventType);
    if (resolved != null) {
      widget.terminal.injectEvent(resolved);
    }
    return KeyEventResult.handled;
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
    Set<term.Modifier> mods, {
    term.KeyEventType eventType = term.KeyEventType.press,
  }) {
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
      _ when _isCtrlLetter(key, mods, event.character) => (
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
    final shiftedCodepoint = _resolveShiftedCodepoint(key, mods, termKey);
    return term.KeyEvent(
      termKey,
      termType,
      modifiers: mods,
      eventType: eventType,
      shiftedCodepoint: shiftedCodepoint,
    );
  }

  static bool _isCtrlLetter(
    LogicalKeyboardKey key,
    Set<term.Modifier> mods,
    String? character,
  ) {
    if (!mods.contains(term.Modifier.control) ||
        !_isAsciiLetterKey(key) ||
        key.keyLabel.length != 1) {
      return false;
    }
    if (character == null || character.isEmpty) return true;
    final unit = character.codeUnitAt(0);
    if (character.length == 1 && (unit <= 0x1F || unit == 0x7F)) {
      return true;
    }
    return character.toLowerCase() == key.keyLabel.toLowerCase();
  }

  static int? _resolveShiftedCodepoint(
    LogicalKeyboardKey key,
    Set<term.Modifier> mods,
    String termKey,
  ) {
    if (!mods.contains(term.Modifier.shift) ||
        !_isAsciiLetterKey(key) ||
        key.keyLabel.length != 1) {
      return null;
    }
    final lower = key.keyLabel.toLowerCase();
    return termKey == lower ? lower.toUpperCase().codeUnitAt(0) : null;
  }

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

  void _takeScreenshot() {
    unawaited(_performTakeScreenshot());
  }

  Future<void> _performTakeScreenshot() async {
    try {
      final timestamp = clock.now().millisecondsSinceEpoch;
      final screenshotBasename = await _saveRepaintBoundaryScreenshot(
        timestamp,
      );
      final atlas = _atlas;
      final atlasBasename = atlas != null
          ? await _saveAtlasScreenshot(atlas, timestamp)
          : null;
      if (atlas != null) {
        await _saveAtlasTable(atlas, timestamp);
      }
      final buffer = _currentBuffer;
      final coordinatesBasename = (buffer != null && atlas != null)
          ? await _saveCoordinatesScreenshot(buffer, atlas, timestamp)
          : null;

      final savedFiles = <String>[
        ?screenshotBasename,
        ?atlasBasename,
        if (atlasBasename != null)
          atlasBasename
              .replaceFirst('atlas_', 'atlas_table_')
              .replaceAll('.png', '.json'),
        ?coordinatesBasename,
      ];
      _showScreenshotSnackBar(savedFiles);
    } catch (e) {
      _showScreenshotErrorSnackBar(e);
    }
  }

  Future<String?> _saveRepaintBoundaryScreenshot(int timestamp) async {
    final boundary =
        _boundaryKey.currentContext?.findRenderObject()
            as RenderRepaintBoundary?;
    if (boundary == null) return null;
    final image = await boundary.toImage(pixelRatio: 2.0);
    final ByteData? byteData;
    try {
      byteData = await image.toByteData(format: ui.ImageByteFormat.png);
    } finally {
      image.dispose();
    }
    if (byteData == null) return null;
    return widget.service.saveScreenshot(
      'screenshot_$timestamp.png',
      byteData.buffer.asUint8List(),
    );
  }

  Future<String?> _saveAtlasScreenshot(GlyphAtlas atlas, int timestamp) async {
    final byteData = await atlas.image.toByteData(
      format: ui.ImageByteFormat.png,
    );
    if (byteData == null) return null;
    return widget.service.saveScreenshot(
      'atlas_$timestamp.png',
      byteData.buffer.asUint8List(),
    );
  }

  Future<String?> _saveAtlasTable(GlyphAtlas atlas, int timestamp) async {
    final rectsMap = atlas.charRects.map((key, value) {
      final codePoints = key.runes
          .map((r) => 'U+${r.toRadixString(16).padLeft(4, '0').toUpperCase()}')
          .join(' ');
      return MapEntry(codePoints, {
        'char': key,
        'left': value.left,
        'top': value.top,
        'right': value.right,
        'bottom': value.bottom,
        'width': value.width,
        'height': value.height,
      });
    });
    final jsonStr = const JsonEncoder.withIndent('  ').convert(rectsMap);
    return widget.service.saveScreenshot(
      'atlas_table_$timestamp.json',
      utf8.encode(jsonStr),
    );
  }

  Future<String?> _saveCoordinatesScreenshot(
    Buffer buffer,
    GlyphAtlas atlas,
    int timestamp,
  ) async {
    final cellsList = _serializeBufferCells(buffer, atlas);
    final data = <String, Object?>{
      'timestamp': timestamp,
      'cols': buffer.width,
      'rows': buffer.height,
      'cellWidth': atlas.cellWidth,
      'cellHeight': atlas.cellHeight,
      'cells': cellsList,
    };
    final jsonStr = const JsonEncoder.withIndent('  ').convert(data);
    return widget.service.saveScreenshot(
      'coordinates_$timestamp.json',
      utf8.encode(jsonStr),
    );
  }

  List<Map<String, Object?>> _serializeBufferCells(
    Buffer buffer,
    GlyphAtlas atlas,
  ) {
    final cellsList = <Map<String, Object?>>[];
    for (var y = 0; y < buffer.height; y++) {
      final rowOffset = y * buffer.width;
      for (var x = 0; x < buffer.width; x++) {
        cellsList.add(_serializeCell(buffer, x, y, rowOffset + x, atlas));
      }
    }
    return cellsList;
  }

  Map<String, Object?> _serializeCell(
    Buffer buffer,
    int x,
    int y,
    int idx,
    GlyphAtlas atlas,
  ) {
    final char = buffer.characters[idx];
    final fg = buffer.getForeground(x, y);
    final bg = buffer.getBackground(x, y);
    final ul = buffer.getUnderlineColor(x, y);
    final uri = buffer.getUri(x, y);
    final mods = buffer.getModifiers(x, y);
    final rect = atlas.charRects[char];

    return {
      'x': x,
      'y': y,
      'char': char,
      'fg': _formatHexColorOrNull(fg),
      'bg': _formatHexColorOrNull(bg),
      if (ul != 0) 'underlineColor': _formatHexColorOrNull(ul),
      'uri': ?uri,
      'modifiers': mods,
      if (rect != null)
        'atlasRect': {
          'left': rect.left,
          'top': rect.top,
          'right': rect.right,
          'bottom': rect.bottom,
        },
    };
  }

  static String? _formatHexColorOrNull(int argb) => argb != 0
      ? '0x${argb.toRadixString(16).padLeft(8, '0').toUpperCase()}'
      : null;

  void _showScreenshotSnackBar(List<String> files) {
    if (!mounted) return;
    final message = files.isNotEmpty
        ? 'Saved: ${files.join(', ')}'
        : 'No files saved.';
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 4)),
    );
  }

  void _showScreenshotErrorSnackBar(Object error) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Error saving screenshot/atlas/coordinates: $error'),
      ),
    );
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
    final pixelX = event.localPosition.dx.floor().clamp(0, 100000) + 1;
    final pixelY = event.localPosition.dy.floor().clamp(0, 100000) + 1;
    final steps = rawSteps.abs().clamp(1, _maxWheelStepsPerEvent);
    final button = rawSteps < 0
        ? term.MouseButton.wheelUp
        : term.MouseButton.wheelDown;
    final mods = _collectHardwareModifiers();

    for (var i = 0; i < steps; i++) {
      final termEvent = term.MouseEvent(
        x: col + 1,
        y: row + 1,
        pixelX: pixelX,
        pixelY: pixelY,
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
    final (nextUri, uriChanged) = _updateHoveredLinkCell(col, row);
    if (type == term.MouseEventType.press && button == term.MouseButton.left) {
      _handleLeftPointerPress(col, row);
    } else if (type == term.MouseEventType.drag) {
      _handlePointerDrag(col, row);
    } else if (type == term.MouseEventType.release) {
      _finishPointerRelease(col, row, nextUri);
    }

    if (uriChanged && mounted) {
      setState(() {});
    }
  }

  (String?, bool) _updateHoveredLinkCell(int col, int row) {
    if (!_builtinLinkOpenEnabled) return (null, false);
    final nextUri = _currentBuffer?.getUri(col, row);
    final linkMod = _isLinkOpenModifierPressed();
    final changed = nextUri != _hoveredUri || linkMod != _isLinkModifierActive;
    _hoveredUri = nextUri;
    _isLinkModifierActive = linkMod;
    return (nextUri, changed);
  }

  void _handleLeftPointerPress(int col, int row) {
    _linkPressCell = _builtinLinkOpenEnabled ? (col: col, row: row) : null;
    if (_builtinSelectionEnabled) {
      _startSelectionAt(col, row);
    }
  }

  void _handlePointerDrag(int col, int row) {
    if (_linkPressCell != null && _linkPressCell != (col: col, row: row)) {
      _linkPressCell = null;
    }
    if (_builtinSelectionEnabled && _isSelecting) {
      final isBlock = HardwareKeyboard.instance.isAltPressed;
      final mode = isBlock ? SelectionMode.block : SelectionMode.stream;
      _selectionController.updateSelection(col, row, mode: mode);
    }
  }

  void _startSelectionAt(int col, int row) {
    final buf = _currentBuffer;
    final isBlock = HardwareKeyboard.instance.isAltPressed;
    final mode = isBlock ? SelectionMode.block : SelectionMode.stream;
    final region = buf != null
        ? TerminalSelectionController.resolveRegionForCell(
            buf,
            col,
            row,
            mode: mode,
          )
        : null;
    if (_isGraphicCanvasPress(buf, row, region)) {
      _selectionController.clearSelection();
      _isSelecting = false;
      return;
    }
    _selectionController.startSelection(col, row, mode: mode, region: region);
    _isSelecting = true;
  }

  static bool _isGraphicCanvasPress(
    Buffer? buf,
    int row,
    SelectionRegion? region,
  ) {
    if (buf == null || row < 0 || row >= buf.height) return false;
    final minCol = region?.minCol ?? 0;
    final maxCol = region?.maxCol ?? (buf.width - 1);
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
    final clickedLinkCell = _linkPressCell == (col: col, row: row);
    _linkPressCell = null;

    if (_builtinSelectionEnabled) {
      final wasDragging = _isSelecting && _selectionController.hasSelection;
      _isSelecting = false;
      if (wasDragging) {
        _copySelectedBufferText();
        return;
      }
      _selectionController.clearSelection();
    }

    if (_builtinLinkOpenEnabled &&
        clickedLinkCell &&
        uri != null &&
        uri.isNotEmpty &&
        _isLinkOpenModifierPressed()) {
      unawaited(widget.service.openUrl(uri));
    }
  }

  void _copySelectedBufferText() {
    final buf = _currentBuffer;
    if (buf == null) return;
    final selectedText = _selectionController.extractText(
      buf,
      includeHidden: true,
    );
    if (selectedText.isNotEmpty) {
      unawaited(_writeToClipboard(selectedText));
    }
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

    final pixelX = event.localPosition.dx.floor().clamp(0, 100000) + 1;
    final pixelY = event.localPosition.dy.floor().clamp(0, 100000) + 1;
    final termEvent = term.MouseEvent(
      x: clampedCol + 1,
      y: clampedRow + 1,
      pixelX: pixelX,
      pixelY: pixelY,
      button: termuiButton,
      type: termuiType,
      modifiers: _collectHardwareModifiers(),
    );

    if (_isDuplicatePointerMotion(termEvent)) {
      return;
    }

    _lastInjectedPointerEvent = termEvent;
    widget.terminal.injectEvent(termEvent);
  }

  bool _isDuplicatePointerMotion(term.MouseEvent event) {
    if (event.type != term.MouseEventType.move &&
        event.type != term.MouseEventType.drag) {
      return false;
    }
    final prev = _lastInjectedPointerEvent;
    if (prev == null) return false;
    if (widget.terminal.reportPixelMouseEvents) {
      return prev == event;
    }
    return prev.x == event.x &&
        prev.y == event.y &&
        prev.button == event.button &&
        prev.type == event.type &&
        setEquals(prev.modifiers, event.modifiers);
  }

  @override
  Widget build(BuildContext context) {
    if (_atlas == null) {
      return _buildLoadingIndicator();
    }
    return LayoutBuilder(builder: _buildTerminalBody);
  }

  Widget _buildLoadingIndicator() => Scaffold(
    backgroundColor: widget.backgroundColor,
    body: const Center(child: CircularProgressIndicator()),
  );

  Widget _buildTerminalBody(BuildContext context, BoxConstraints constraints) {
    final atlas = _atlas!;
    final (cols, rows) = _calculateGridDimensions(
      constraints,
      MediaQuery.maybeSizeOf(context),
      atlas.cellWidth,
      atlas.cellHeight,
    );
    _syncTerminalSize(cols, rows);

    final layoutSize = Size(cols * atlas.cellWidth, rows * atlas.cellHeight);
    return Scaffold(
      backgroundColor: widget.backgroundColor,
      body: Focus(
        focusNode: _focusNode,
        autofocus: true,
        onKeyEvent: (node, event) => _handleKeyEvent(event),
        child: Center(
          child: RepaintBoundary(
            key: _boundaryKey,
            child: MouseRegion(
              cursor: _effectiveCursor,
              child: _buildPointerListener(layoutSize),
            ),
          ),
        ),
      ),
    );
  }

  (int, int) _calculateGridDimensions(
    BoxConstraints constraints,
    Size? fallbackSize,
    double cellW,
    double cellH,
  ) {
    final availW = constraints.hasBoundedWidth
        ? constraints.maxWidth
        : (fallbackSize?.width ?? widget.terminal.backend.size.x * cellW);
    final availH = constraints.hasBoundedHeight
        ? constraints.maxHeight
        : (fallbackSize?.height ?? widget.terminal.backend.size.y * cellH);
    return ((availW / cellW).floor(), (availH / cellH).floor());
  }

  void _syncTerminalSize(int cols, int rows) {
    if (cols <= 0 || rows <= 0) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        widget.terminal.updateSize(Point(cols, rows));
      }
    });
  }

  Widget _buildPointerListener(Size layoutSize) => Listener(
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
    onPointerPanZoomUpdate: (event) =>
        _handleScrollDelta(event, -event.panDelta.dy, layoutSize),
    onPointerPanZoomEnd: (_) => _resetScrollAccumulator(),
    child: _buildCanvasContainer(layoutSize),
  );

  Widget _buildCanvasContainer(Size layoutSize) {
    final buf = _currentBuffer;
    return Container(
      width: layoutSize.width,
      height: layoutSize.height,
      color: widget.backgroundColor,
      child: buf == null
          ? const SizedBox()
          : CustomPaint(
              size: layoutSize,
              painter: TuiAtlasPainter(
                buffer: buf,
                atlas: _atlas!,
                fontFamily: widget.fontFamily,
                fontFamilyFallback: widget.fontFamilyFallback,
                fallbackPainters: _fallbackPainters,
                onMissingGlyphs: null,
                onMissingStyledGlyphs: _onMissingStyledGlyphs,
                enableBleed: widget.enableBleed,
                enableLigatures: _enableLigatures,
                ligaturePainters: _ligaturePainters,
                selectionController: _builtinSelectionEnabled
                    ? _selectionController
                    : null,
                kittyImages: _kittyGpuImages,
                kittyImagesById: _kittyGpuImagesById,
              ),
            ),
    );
  }
}
