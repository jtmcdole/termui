import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:termui/ui/buffer.dart';
import 'package:termui/ui/terminal_palette.dart';
import 'package:termui/ui/widgets/interactive/selection_controller.dart';

import 'backend.dart';
import 'rendering/atlas.dart';
import 'rendering/atlas_controller.dart';
import 'service/terminal_service.dart';
import 'terminal_ime_client.dart';
import 'terminal_surface.dart';

/// A widget that embeds a `termui` TUI application within Flutter.
///
/// It initializes a [FlutterTerminal], triggers the event loop using the
/// [onRun] callback, and sets up a [PrivateTuiView] backed by [TerminalSurface]
/// and [GlyphAtlasController] to handle painting, focus, and input routing.
///
/// ### Example Usage
///
/// ```dart
/// Terminal(
///   fontSize: 14.0,
///   fontFamily: 'Cascadia Code',
///   backgroundColor: const Color(0xFF000000),
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

  /// Default foreground color substituted when cells use `fg == 0`.
  final Color foregroundColor;

  /// Opacity multiplier in `(0.0, 1.0]` applied to `Modifier.dim` cells.
  final double faintOpacity;

  /// Palette used to resolve indexed ANSI cell colors.
  final TerminalColorTheme palette;

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

  /// Enables `DeltaTextInputClient` IME and dead-key input routing. Defaults to `false` for backward compatibility.
  final bool enableIme;

  /// Optional widget rendered while the initial glyph atlas is loading.
  final Widget? loadingWidget;

  /// Creates a [Terminal] view bounding the TUI app hierarchy.
  const Terminal({
    super.key,
    this.terminal,
    required this.onRun,
    this.fontSize = 13.0,
    this.fontFamily = 'Cascadia Mono',
    this.fontFamilyFallback,
    this.backgroundColor = const Color(0xFF000000),
    this.foregroundColor = const Color(0xFFFFFFFF),
    this.faintOpacity = 140 / 255,
    this.palette = TerminalColorTheme.termuiDark,
    this.service = const DefaultTerminalService(),
    this.enableBleed = kIsWeb,
    this.enableLigatures = false,
    this.selectionController,
    this.enableBuiltinSelection = true,
    this.enableBuiltinLinkOpen = true,
    this.enableIme = false,
    this.loadingWidget,
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
      foregroundColor: widget.foregroundColor,
      faintOpacity: widget.faintOpacity,
      palette: widget.palette,
      service: widget.service,
      enableBleed: widget.enableBleed,
      enableLigatures: widget.enableLigatures,
      selectionController: widget.selectionController,
      enableBuiltinSelection:
          widget.enableBuiltinSelection && _terminal.enableBuiltinSelection,
      enableBuiltinLinkOpen:
          widget.enableBuiltinLinkOpen && _terminal.enableBuiltinLinkOpen,
      enableIme: widget.enableIme,
      loadingWidget: widget.loadingWidget,
      onInit: _startLoop,
    );
  }
}

/// The internal widget that manages drawing, keyboard focus, and mouse input.
///
/// Delegates atlas management, GPU canvas painting, and IME/key routing to
/// [GlyphAtlasController], [TerminalSurface], and [TerminalImeClient] while
/// keeping [Terminal] backward compatible.
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

  /// Default foreground color substituted when cells use `fg == 0`.
  final Color foregroundColor;

  /// Opacity multiplier in `(0.0, 1.0]` applied to `Modifier.dim` cells.
  final double faintOpacity;

  /// Palette used to resolve indexed ANSI cell colors.
  final TerminalColorTheme palette;

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

  /// Enables `DeltaTextInputClient` IME routing when `true`. Defaults to `false`.
  final bool enableIme;

  /// Optional widget rendered while the initial glyph atlas is loading.
  final Widget? loadingWidget;

  /// Internal widget constructor binding the terminal state to rendering hooks.
  const PrivateTuiView({
    super.key,
    required this.terminal,
    required this.onInit,
    required this.service,
    this.fontSize = 13,
    this.fontFamily = 'Cascadia Mono',
    this.fontFamilyFallback,
    this.backgroundColor = const Color(0xFF000000),
    this.foregroundColor = const Color(0xFFFFFFFF),
    this.faintOpacity = 140 / 255,
    this.palette = TerminalColorTheme.termuiDark,
    this.enableBleed = kIsWeb,
    this.enableLigatures = false,
    this.selectionController,
    this.enableBuiltinSelection = true,
    this.enableBuiltinLinkOpen = true,
    this.enableIme = false,
    this.loadingWidget,
  });

  @override
  State<PrivateTuiView> createState() => PrivateTuiViewState();
}

/// Internal state for [PrivateTuiView], exposed for widget tests.
class PrivateTuiViewState extends State<PrivateTuiView> {
  final GlobalKey<TerminalSurfaceState> _surfaceKey = GlobalKey();
  final FocusNode _focusNode = FocusNode();

  late GlyphAtlasController _atlasController;
  late TerminalSelectionController _selectionController;
  late TerminalImeClient _imeClient;
  StreamSubscription<double>? _fontSizeSubscription;

  Buffer? _currentBuffer;
  bool _onInitDispatched = false;

  /// The active selection controller for this terminal view.
  TerminalSelectionController get selectionController => _selectionController;

  /// Current font size rendered by the terminal view.
  double get fontSize => _atlasController.fontSize;

  /// Active fallback [TextPainter] cache keys for unit and widget tests.
  @visibleForTesting
  Set<(String, bool, bool, bool, Color)> get debugFallbackPainterKeys =>
      Set.unmodifiable(_atlasController.fallbackPainters.keys);

  /// Active [GlyphAtlas] instance for unit and widget tests.
  @visibleForTesting
  GlyphAtlas? get debugAtlas => _atlasController.atlas;

  /// Triggers the F12 screenshot pipeline and returns when saving completes.
  @visibleForTesting
  Future<void> debugTakeScreenshot() =>
      _surfaceKey.currentState?.takeScreenshot() ?? Future<void>.value();

  @override
  void initState() {
    super.initState();
    _atlasController = GlyphAtlasController(
      fontSize: widget.terminal.fontSize,
      fontFamily: widget.fontFamily,
      fontFamilyFallback: widget.fontFamilyFallback,
    );
    _selectionController =
        widget.selectionController ?? TerminalSelectionController();
    _imeClient = TerminalImeClient(routePrintableThroughIme: widget.enableIme);
    _bindFontSizeSubscription();
  }

  void _bindFontSizeSubscription() {
    _fontSizeSubscription?.cancel();
    _fontSizeSubscription = widget.terminal.watchFontSize().listen((newSize) {
      if (!mounted) return;
      unawaited(_atlasController.setFontSize(newSize));
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final dpr = MediaQuery.maybeDevicePixelRatioOf(context) ?? 1.0;
    unawaited(_atlasController.setDevicePixelRatio(dpr));
    unawaited(_ensureAtlasAndInitLoop());
  }

  Future<void> _ensureAtlasAndInitLoop() async {
    await _atlasController.ensureInitialized();
    if (!mounted || _onInitDispatched) return;
    _onInitDispatched = true;
    widget.onInit(_handleDrawFrame);
  }

  void _handleDrawFrame(Buffer buffer) {
    if (!mounted) return;
    scheduleMicrotask(() {
      if (!mounted) return;
      _surfaceKey.currentState?.prepareBuffer(buffer);
      setState(() {
        _currentBuffer = buffer;
      });
    });
  }

  @override
  void didUpdateWidget(PrivateTuiView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.terminal != widget.terminal) {
      _bindFontSizeSubscription();
      unawaited(_atlasController.setFontSize(widget.terminal.fontSize));
    } else if (oldWidget.fontSize != widget.fontSize) {
      widget.terminal.setFontSize(widget.fontSize);
    } else if (oldWidget.fontFamily != widget.fontFamily ||
        !listEquals(oldWidget.fontFamilyFallback, widget.fontFamilyFallback)) {
      unawaited(
        _atlasController.updateConfig(
          fontFamily: widget.fontFamily,
          fontFamilyFallback: widget.fontFamilyFallback,
          updateFallbackList: true,
        ),
      );
    }

    if (oldWidget.selectionController != widget.selectionController) {
      if (oldWidget.selectionController == null) {
        _selectionController.dispose();
      }
      _selectionController =
          widget.selectionController ?? TerminalSelectionController();
    }

    if (oldWidget.enableIme != widget.enableIme) {
      _imeClient.routePrintableThroughIme = widget.enableIme;
    }

    if (oldWidget.backgroundColor != widget.backgroundColor ||
        oldWidget.foregroundColor != widget.foregroundColor ||
        oldWidget.faintOpacity != widget.faintOpacity ||
        oldWidget.palette != widget.palette) {
      _atlasController.clearPainterCaches();
    }
  }

  @override
  void dispose() {
    _fontSizeSubscription?.cancel();
    _fontSizeSubscription = null;
    if (widget.selectionController == null) {
      _selectionController.dispose();
    }
    _imeClient.dispose();
    _atlasController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: widget.backgroundColor,
      child: SizedBox.expand(
        child: TerminalSurface(
          key: _surfaceKey,
          atlasController: _atlasController,
          terminal: widget.terminal,
          buffer: _currentBuffer,
          fontSize: _atlasController.fontSize,
          fontFamily: widget.fontFamily,
          fontFamilyFallback: widget.fontFamilyFallback,
          backgroundColor: widget.backgroundColor,
          foregroundColor: widget.foregroundColor,
          faintOpacity: widget.faintOpacity,
          palette: widget.palette,
          service: widget.service,
          enableBleed: widget.enableBleed,
          enableLigatures: widget.enableLigatures,
          selectionController: _selectionController,
          enableBuiltinSelection: widget.enableBuiltinSelection,
          enableBuiltinLinkOpen: widget.enableBuiltinLinkOpen,
          imeClient: _imeClient,
          enableIme: widget.enableIme,
          focusNode: _focusNode,
          autofocus: true,
          loadingWidget: widget.loadingWidget,
        ),
      ),
    );
  }
}
