import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:clock/clock.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:termui/terminal/terminal.dart' as term;
import 'package:termui/ui/buffer.dart';
import 'package:termui/ui/style.dart';
import 'package:termui/ui/terminal_palette.dart';
import 'package:termui/ui/widgets/display/kitty_image.dart';
import 'package:termui/ui/widgets/interactive/selection_controller.dart';

import 'backend.dart';
import 'rendering/atlas.dart';
import 'rendering/atlas_controller.dart';
import 'rendering/painter.dart';
import 'service/terminal_service.dart';
import 'terminal_ime_client.dart';

enum _LeftGestureRoute { none, localSelection, ptyMouse }

/// A `Scaffold`-free terminal rendering and input surface.
///
/// Multiple [TerminalSurface] panes can share a single [GlyphAtlasController]
/// so they rasterize from one shared GPU glyph texture without mid-frame
/// disposal races. Supports either a [FlutterTerminal] controller or direct
/// [Buffer] / callback bindings (such as a `TerminalPort` adapter).
final class TerminalSurface extends StatefulWidget {
  /// Optional shared glyph atlas controller across panes.
  final GlyphAtlasController? atlasController;

  /// Optional [FlutterTerminal] backing event injection and mode streams.
  final FlutterTerminal? terminal;

  /// Current [Buffer] snapshot to render when [bufferProvider] is omitted.
  final Buffer? buffer;

  /// Optional live [Buffer] getter paired with [bufferListenable].
  final Buffer? Function()? bufferProvider;

  /// Optional [Listenable] notifying when the rendered buffer or cursor changes.
  final Listenable? bufferListenable;

  /// Clamped active PTY dimensions `(cols, rows)` for out-of-bounds dimming.
  final (int cols, int rows)? activePtySize;

  /// Optional live getter for clamped active PTY dimensions `(cols, rows)`.
  final (int cols, int rows)? Function()? activePtySizeProvider;

  /// Zero-based cursor `(col, row)` for IME placement and pre-edit overlay.
  final ({int col, int row})? cursorPosition;

  /// Optional live getter for zero-based cursor `(col, row)`.
  final ({int col, int row})? Function()? cursorPositionProvider;

  /// Active Kitty keyboard protocol progressive flags (`0..31`) when not using [terminal].
  final int kittyKeyboardFlags;

  /// Optional live getter for Kitty keyboard protocol flags.
  final int Function()? kittyKeyboardFlagsProvider;

  /// Whether hardware key releases report [term.KeyEventType.release].
  final bool reportKeyReleaseEvents;

  /// Optional live getter for key release reporting.
  final bool Function()? reportKeyReleaseEventsProvider;

  /// Whether sub-cell pixel pointer coordinates (`?1016`) should be reported.
  final bool reportPixelMouseEvents;

  /// Optional live getter for pixel mouse reporting.
  final bool Function()? reportPixelMouseEventsProvider;

  /// Whether the hosted terminal application is actively tracking mouse events.
  ///
  /// When `true`, left-button gestures are forwarded to the TUI unless `Shift`
  /// is held on press to force local text selection.
  final bool mouseTracking;

  /// Optional live getter overriding [mouseTracking] on each pointer event.
  final bool Function()? mouseTrackingProvider;

  /// Whether completed local selections are copied to the clipboard on release.
  final bool copyOnSelect;

  /// Optional live getter overriding [copyOnSelect] on selection release.
  final bool Function()? copyOnSelectProvider;

  /// Optional OSC 22 mouse cursor name when not using [terminal].
  final String? mouseCursorName;

  /// Callback invoked on initial layout or when grid/cell metrics change.
  final void Function(int cols, int rows, double cellWidth, double cellHeight)?
  onViewportSizeChanged;

  /// Callback receiving encoded [term.InputEvent]s (defaults to [FlutterTerminal.injectEvent]).
  final void Function(term.InputEvent event)? onInputEvent;

  /// Optional callback receiving committed IME/printable text directly.
  final void Function(String text)? onTextInput;

  /// Optional custom shortcut hook invoked before built-in shortcuts.
  final bool Function(KeyEvent event, Set<term.Modifier> modifiers)?
  onHostShortcut;

  /// Optional callback receiving screenshot/clipboard/status notifications.
  final void Function(String message, {bool isError})? onStatusNotice;

  /// Optional callback invoked when surface keyboard focus changes.
  final void Function(bool hasFocus)? onFocusChanged;

  /// Optional pointer exit listener forwarded to [MouseRegion.onExit].
  final PointerExitEventListener? onPointerExit;

  /// Optional loading placeholder rendered before the first atlas completes.
  final Widget? loadingWidget;

  /// Optional external [FocusNode].
  final FocusNode? focusNode;

  /// Whether this surface automatically requests keyboard focus on mount.
  final bool autofocus;

  /// Optional external [TerminalImeClient].
  final TerminalImeClient? imeClient;

  /// Enables `DeltaTextInputClient` IME and dead-key input routing. Defaults to `true`.
  final bool enableIme;

  /// Treats macOS Option+printable keys as `Alt` instead of dead-key composition.
  final bool macosOptionAsAlt;

  /// Monospace font point size used when [atlasController] is omitted.
  final double fontSize;

  /// Primary monospaced font family used when [atlasController] is omitted.
  final String fontFamily;

  /// Fallback monospaced font families used when [atlasController] is omitted.
  final List<String>? fontFamilyFallback;

  /// Background color filling the terminal canvas.
  final Color backgroundColor;

  /// Default foreground color substituted when cells use `fg == 0`.
  final Color foregroundColor;

  /// Opacity multiplier in `(0.0, 1.0]` applied to `Modifier.dim` cells.
  final double faintOpacity;

  /// Palette used to resolve indexed ANSI cell colors.
  final TerminalColorTheme palette;

  /// Optional scrim color painted outside [activePtySize].
  final Color? outOfBoundsDimColor;

  /// Service used for screenshots, clipboard access, and external URL opening.
  final TerminalService service;

  /// Enables sub-pixel bleeding in [TuiAtlasPainter]. Defaults to `kIsWeb`.
  final bool enableBleed;

  /// Enables multi-cell font ligatures. Defaults to `false`.
  final bool enableLigatures;

  /// Optional external text selection controller.
  final TerminalSelectionController? selectionController;

  /// Enables built-in viewport mouse selection and auto-copy.
  final bool enableBuiltinSelection;

  /// Enables built-in `OSC 8` link hover cursor and `Ctrl/Cmd+Click` launch.
  final bool enableBuiltinLinkOpen;

  /// Enables built-in host shortcuts (`F12` screenshot, `Shift+F12` rebuild, paste).
  final bool enableHostShortcuts;

  /// Alignment of the cell-quantized terminal grid inside loose or bounded margins.
  final AlignmentGeometry alignment;

  /// Creates a `Scaffold`-free [TerminalSurface].
  const TerminalSurface({
    super.key,
    this.atlasController,
    this.terminal,
    this.buffer,
    this.bufferProvider,
    this.bufferListenable,
    this.activePtySize,
    this.activePtySizeProvider,
    this.cursorPosition,
    this.cursorPositionProvider,
    this.kittyKeyboardFlags = 0,
    this.kittyKeyboardFlagsProvider,
    this.reportKeyReleaseEvents = false,
    this.reportKeyReleaseEventsProvider,
    this.reportPixelMouseEvents = false,
    this.reportPixelMouseEventsProvider,
    this.mouseTracking = false,
    this.mouseTrackingProvider,
    this.copyOnSelect = true,
    this.copyOnSelectProvider,
    this.mouseCursorName,
    this.onViewportSizeChanged,
    this.onInputEvent,
    this.onTextInput,
    this.onHostShortcut,
    this.onStatusNotice,
    this.onFocusChanged,
    this.onPointerExit,
    this.loadingWidget,
    this.focusNode,
    this.autofocus = true,
    this.imeClient,
    this.enableIme = true,
    this.macosOptionAsAlt = false,
    this.fontSize = 13.0,
    this.fontFamily = 'Cascadia Mono',
    this.fontFamilyFallback,
    this.backgroundColor = const ui.Color(0xFF000000),
    this.foregroundColor = const ui.Color(0xFFFFFFFF),
    this.faintOpacity = 140 / 255,
    this.palette = TerminalColorTheme.termuiDark,
    this.outOfBoundsDimColor,
    this.service = const DefaultTerminalService(),
    this.enableBleed = kIsWeb,
    this.enableLigatures = false,
    this.selectionController,
    this.enableBuiltinSelection = true,
    this.enableBuiltinLinkOpen = true,
    this.enableHostShortcuts = true,
    this.alignment = Alignment.center,
  });

  @override
  State<TerminalSurface> createState() => TerminalSurfaceState();
}

/// State backing [TerminalSurface], exposed for diagnostics and widget tests.
final class TerminalSurfaceState extends State<TerminalSurface> {
  static const int _maxWheelStepsPerEvent = 32;
  static const Duration _scrollIdleReset = Duration(milliseconds: 250);

  final GlobalKey _boundaryKey = GlobalKey();

  late GlyphAtlasController _atlasController;
  late bool _ownsAtlasController;
  late FocusNode _focusNode;
  late bool _ownsFocusNode;
  late TerminalSelectionController _selectionController;
  late bool _ownsSelectionController;
  late TerminalImeClient _imeClient;
  late bool _ownsImeClient;
  late _KittyGpuImageCache _kittyCache;
  final _SurfaceRepaintNotifier _paintNotifier = _SurfaceRepaintNotifier();

  bool _hadActiveBuffer = false;
  bool _bufferResourcesDirty = false;
  Buffer? _lastPaintedBuffer;
  Buffer? _externallyPreparedBuffer;
  (int, int)? _lastPaintedActivePtySize;
  ({int col, int row})? _lastCursorPosition;

  StreamSubscription<double>? _fontSizeSubscription;
  StreamSubscription<String?>? _mouseCursorSubscription;
  StreamSubscription<String>? _clipboardSubscription;
  StreamSubscription<void>? _pasteRequestSubscription;
  StreamSubscription<bool>? _ligaturesSubscription;
  StreamSubscription<bool>? _builtinSelectionSubscription;
  StreamSubscription<bool>? _builtinLinkOpenSubscription;

  late bool _enableLigatures;
  late bool _terminalBuiltinSelection;
  late bool _terminalBuiltinLinkOpen;

  MouseCursor _currentCursor = SystemMouseCursors.basic;
  String? _hoveredUri;
  bool _isLinkModifierActive = false;
  ({int col, int row})? _linkPressCell;
  bool _isSelecting = false;
  term.MouseButton _lastPressedButton = term.MouseButton.left;
  _LeftGestureRoute _leftGestureRoute = _LeftGestureRoute.none;
  DateTime? _lastLeftTapAt;
  ({int col, int row})? _lastLeftTapCell;
  term.MouseEvent? _lastInjectedPointerEvent;

  double _scrollRemainderDy = 0.0;
  DateTime? _lastScrollAt;

  bool _hasReportedLayout = false;
  int _lastReportedCols = 0;
  int _lastReportedRows = 0;
  double _lastReportedCellW = 0.0;
  double _lastReportedCellH = 0.0;
  bool _geometrySyncScheduled = false;

  Buffer? get _activeBuffer => widget.bufferProvider?.call() ?? widget.buffer;

  bool get _builtinSelectionEnabled =>
      widget.enableBuiltinSelection && _terminalBuiltinSelection;

  bool get _builtinLinkOpenEnabled =>
      widget.enableBuiltinLinkOpen && _terminalBuiltinLinkOpen;

  int get _effectiveKittyFlags =>
      widget.kittyKeyboardFlagsProvider?.call() ??
      widget.terminal?.kittyKeyboardFlags ??
      widget.kittyKeyboardFlags;

  bool get _effectiveReportKeyRelease =>
      widget.reportKeyReleaseEventsProvider?.call() ??
      widget.terminal?.reportKeyReleaseEvents ??
      (widget.reportKeyReleaseEvents || (_effectiveKittyFlags & 2) != 0);

  bool get _effectiveReportPixelMouse =>
      widget.reportPixelMouseEventsProvider?.call() ??
      widget.terminal?.reportPixelMouseEvents ??
      widget.reportPixelMouseEvents;

  bool get _effectiveMouseTracking =>
      widget.mouseTrackingProvider?.call() ?? widget.mouseTracking;

  bool get _effectiveCopyOnSelect =>
      widget.copyOnSelectProvider?.call() ?? widget.copyOnSelect;

  /// Active [GlyphAtlasController] used by this surface.
  GlyphAtlasController get atlasController => _atlasController;

  /// Active [TerminalImeClient] handling keyboard/IME arbitration.
  TerminalImeClient get imeClient => _imeClient;

  /// Active [TerminalSelectionController] used by this surface.
  TerminalSelectionController get selectionController => _selectionController;

  MouseCursor get _effectiveCursor =>
      (_builtinLinkOpenEnabled &&
          _hoveredUri != null &&
          _isLinkModifierActive &&
          _currentCursor == SystemMouseCursors.basic)
      ? SystemMouseCursors.click
      : _currentCursor;

  /// Triggers the F12 screenshot pipeline and returns when saving completes.
  Future<void> takeScreenshot() => _performTakeScreenshot();

  /// Triggers the F12 screenshot pipeline and returns when saving completes.
  @visibleForTesting
  Future<void> debugTakeScreenshot() => takeScreenshot();

  @override
  void initState() {
    super.initState();
    _initAtlasController();
    _initFocusAndSelection();
    _initImeClient();
    _kittyCache = _KittyGpuImageCache(onDecoded: _onKittyImageDecoded);
    _initModeFlags();
    _bindTerminalStreams();
    widget.bufferListenable?.addListener(_onExternalBufferChanged);
    _hadActiveBuffer = _activeBuffer != null;
    _lastCursorPosition =
        widget.cursorPositionProvider?.call() ?? widget.cursorPosition;
    _prepareActiveBufferResources();
    if (_focusNode.hasFocus && widget.enableIme) {
      _imeClient.attach();
      _scheduleGeometrySync();
    }
  }

  void _initAtlasController() {
    _ownsAtlasController = widget.atlasController == null;
    _atlasController =
        widget.atlasController ??
        GlyphAtlasController(
          fontSize: widget.fontSize,
          fontFamily: widget.fontFamily,
          fontFamilyFallback: widget.fontFamilyFallback,
        );
    _atlasController.addListener(_onAtlasChanged);
  }

  void _initFocusAndSelection() {
    _ownsFocusNode = widget.focusNode == null;
    _focusNode = widget.focusNode ?? FocusNode();
    _focusNode.addListener(_onFocusChanged);

    _ownsSelectionController = widget.selectionController == null;
    _selectionController =
        widget.selectionController ?? TerminalSelectionController();
    _selectionController.addListener(_onSelectionChanged);
  }

  void _initImeClient() {
    _ownsImeClient = widget.imeClient == null;
    _imeClient =
        widget.imeClient ??
        TerminalImeClient(
          macosOptionAsAlt: widget.macosOptionAsAlt,
          routePrintableThroughIme: widget.enableIme,
        );
    _bindImeClient();
  }

  void _bindImeClient() {
    _imeClient
      ..macosOptionAsAlt = widget.macosOptionAsAlt
      ..routePrintableThroughIme = widget.enableIme
      ..bindSurfaceHandlers(
        kittyKeyboardFlags: () => _effectiveKittyFlags,
        reportKeyReleaseEvents: () => _effectiveReportKeyRelease,
        onKeyEvent: _injectInputEvent,
        onTextInput: widget.onTextInput,
        onHostShortcut: _handleHostShortcut,
        onModifiersChanged: _syncLinkModifierState,
      )
      ..addListener(_onImeComposingChanged);
  }

  void _unbindImeClient(TerminalImeClient client) {
    client
      ..removeListener(_onImeComposingChanged)
      ..clearSurfaceHandlers();
  }

  void _initModeFlags() {
    _enableLigatures =
        widget.enableLigatures || (widget.terminal?.enableLigatures ?? false);
    _terminalBuiltinSelection = widget.terminal?.enableBuiltinSelection ?? true;
    _terminalBuiltinLinkOpen = widget.terminal?.enableBuiltinLinkOpen ?? true;
    if (widget.terminal == null) {
      _currentCursor = _mapOsc22ToSystemCursor(widget.mouseCursorName);
    }
  }

  void _bindTerminalStreams() {
    _cancelTerminalStreams();
    final terminal = widget.terminal;
    if (terminal == null) return;

    if (_ownsAtlasController) {
      _fontSizeSubscription = terminal.watchFontSize().listen((newSize) {
        if (!mounted) return;
        unawaited(_atlasController.setFontSize(newSize));
      });
    }
    _mouseCursorSubscription = terminal.mouseCursorChanges.listen((cursorName) {
      if (!mounted) return;
      setState(() {
        _currentCursor = _mapOsc22ToSystemCursor(cursorName);
      });
    });
    _ligaturesSubscription = terminal.watchEnableLigatures().listen((enabled) {
      if (!mounted) return;
      setState(() {
        _enableLigatures = enabled;
      });
    });
    _builtinSelectionSubscription = terminal
        .watchEnableBuiltinSelection()
        .listen(_onTerminalBuiltinSelectionChanged);
    _builtinLinkOpenSubscription = terminal.watchEnableBuiltinLinkOpen().listen(
      _onTerminalBuiltinLinkOpenChanged,
    );
    _clipboardSubscription = terminal.clipboardChanges.listen((text) {
      if (mounted) {
        unawaited(_writeToClipboard(text));
      }
    });
    _pasteRequestSubscription = terminal.pasteRequests.listen((_) {
      if (mounted) {
        unawaited(_pasteFromClipboard());
      }
    });
  }

  void _cancelTerminalStreams() {
    _fontSizeSubscription?.cancel();
    _mouseCursorSubscription?.cancel();
    _ligaturesSubscription?.cancel();
    _builtinSelectionSubscription?.cancel();
    _builtinLinkOpenSubscription?.cancel();
    _clipboardSubscription?.cancel();
    _pasteRequestSubscription?.cancel();
    _fontSizeSubscription = null;
    _mouseCursorSubscription = null;
    _ligaturesSubscription = null;
    _builtinSelectionSubscription = null;
    _builtinLinkOpenSubscription = null;
    _clipboardSubscription = null;
    _pasteRequestSubscription = null;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final media = MediaQuery.maybeOf(context);
    final dpr = media?.devicePixelRatio ?? 1.0;
    if (_ownsAtlasController) {
      unawaited(
        _atlasController.updateConfig(
          fontSize: widget.fontSize,
          fontFamily: widget.fontFamily,
          fontFamilyFallback: widget.fontFamilyFallback,
          updateFallbackList: true,
          devicePixelRatio: dpr,
        ),
      );
    } else if (media != null) {
      unawaited(_atlasController.setDevicePixelRatio(dpr));
    }
    unawaited(_atlasController.ensureInitialized());
    _syncTerminalCellMetrics();
  }

  @override
  void didUpdateWidget(TerminalSurface oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncAtlasControllerBinding(oldWidget);
    _syncFocusAndImeBindings(oldWidget);
    _syncTerminalAndBufferBindings(oldWidget);
    _syncThemeAndModeBindings(oldWidget);
  }

  void _syncAtlasControllerBinding(TerminalSurface oldWidget) {
    if (oldWidget.atlasController != widget.atlasController) {
      _atlasController.removeListener(_onAtlasChanged);
      if (_ownsAtlasController) {
        _atlasController.dispose();
      }
      _initAtlasController();
      if (!_ownsAtlasController) {
        _fontSizeSubscription?.cancel();
        _fontSizeSubscription = null;
      } else if (_fontSizeSubscription == null && widget.terminal != null) {
        _bindTerminalStreams();
      }
      final media = MediaQuery.maybeOf(context);
      if (media != null) {
        unawaited(_atlasController.setDevicePixelRatio(media.devicePixelRatio));
      }
      unawaited(_atlasController.ensureInitialized());
      _syncTerminalCellMetrics();
      return;
    }

    if (_ownsAtlasController &&
        (oldWidget.fontSize != widget.fontSize ||
            oldWidget.fontFamily != widget.fontFamily ||
            !listEquals(
              oldWidget.fontFamilyFallback,
              widget.fontFamilyFallback,
            ))) {
      unawaited(
        _atlasController.updateConfig(
          fontSize: widget.fontSize,
          fontFamily: widget.fontFamily,
          fontFamilyFallback: widget.fontFamilyFallback,
          updateFallbackList: true,
        ),
      );
    }
  }

  void _syncFocusAndImeBindings(TerminalSurface oldWidget) {
    if (oldWidget.focusNode != widget.focusNode) {
      _focusNode.removeListener(_onFocusChanged);
      if (_ownsFocusNode) {
        _focusNode.dispose();
      }
      _ownsFocusNode = widget.focusNode == null;
      _focusNode = widget.focusNode ?? FocusNode();
      _focusNode.addListener(_onFocusChanged);
    }

    if (oldWidget.imeClient != widget.imeClient) {
      _unbindImeClient(_imeClient);
      if (_ownsImeClient) {
        _imeClient.dispose();
      }
      _initImeClient();
    } else {
      _bindImeClient();
    }

    if (!widget.enableIme || !_focusNode.hasFocus) {
      _imeClient.detach();
    } else if (_focusNode.hasFocus && widget.enableIme) {
      _imeClient.attach();
      _scheduleGeometrySync();
    }

    if (oldWidget.selectionController != widget.selectionController) {
      _selectionController.removeListener(_onSelectionChanged);
      if (_ownsSelectionController) {
        _selectionController.dispose();
      }
      _ownsSelectionController = widget.selectionController == null;
      _selectionController =
          widget.selectionController ?? TerminalSelectionController();
      _selectionController.addListener(_onSelectionChanged);
    }
  }

  void _syncTerminalAndBufferBindings(TerminalSurface oldWidget) {
    if (oldWidget.terminal != widget.terminal) {
      _enableLigatures =
          widget.enableLigatures || (widget.terminal?.enableLigatures ?? false);
      _terminalBuiltinSelection =
          widget.terminal?.enableBuiltinSelection ?? true;
      _terminalBuiltinLinkOpen = widget.terminal?.enableBuiltinLinkOpen ?? true;
      _bindTerminalStreams();
      _syncTerminalCellMetrics();
    } else if (oldWidget.enableLigatures != widget.enableLigatures) {
      _enableLigatures = widget.enableLigatures;
    }

    if (oldWidget.terminal == null &&
        widget.terminal == null &&
        oldWidget.mouseCursorName != widget.mouseCursorName) {
      _currentCursor = _mapOsc22ToSystemCursor(widget.mouseCursorName);
    }

    if (oldWidget.bufferListenable != widget.bufferListenable) {
      oldWidget.bufferListenable?.removeListener(_onExternalBufferChanged);
      widget.bufferListenable?.addListener(_onExternalBufferChanged);
    }

    _syncBufferResourcesOnUpdate(oldWidget);
  }

  void _syncBufferResourcesOnUpdate(TerminalSurface oldWidget) {
    final activeBuf = _activeBuffer;
    final alreadyPrepared = identical(activeBuf, _externallyPreparedBuffer);
    _externallyPreparedBuffer = null;
    final bindingsChanged =
        oldWidget.buffer != widget.buffer ||
        oldWidget.bufferProvider != widget.bufferProvider ||
        oldWidget.cursorPosition != widget.cursorPosition;
    if (bindingsChanged) {
      _scheduleGeometrySync();
    }
    if (activeBuf == null) return;
    if (!alreadyPrepared &&
        (bindingsChanged || widget.bufferListenable == null)) {
      _prepareBufferResources(activeBuf);
    }
    if (widget.bufferListenable == null) {
      _paintNotifier.notify();
    }
  }

  void _syncThemeAndModeBindings(TerminalSurface oldWidget) {
    if (oldWidget.backgroundColor != widget.backgroundColor ||
        oldWidget.foregroundColor != widget.foregroundColor ||
        oldWidget.faintOpacity != widget.faintOpacity ||
        oldWidget.palette != widget.palette) {
      if (_ownsAtlasController) {
        _atlasController.clearPainterCaches();
      }
      _prepareActiveBufferResources();
    }
    if (oldWidget.enableBuiltinSelection && !widget.enableBuiltinSelection) {
      _isSelecting = false;
      _lastLeftTapAt = null;
      _lastLeftTapCell = null;
      _selectionController.clearSelection();
    }
    if (oldWidget.enableBuiltinLinkOpen && !widget.enableBuiltinLinkOpen) {
      _hoveredUri = null;
      _isLinkModifierActive = false;
      _linkPressCell = null;
    }
  }

  @override
  void dispose() {
    widget.bufferListenable?.removeListener(_onExternalBufferChanged);
    _cancelTerminalStreams();
    _focusNode.removeListener(_onFocusChanged);
    if (_ownsFocusNode) {
      _focusNode.dispose();
    }
    _unbindImeClient(_imeClient);
    if (_ownsImeClient) {
      _imeClient.dispose();
    }
    _selectionController.removeListener(_onSelectionChanged);
    if (_ownsSelectionController) {
      _selectionController.dispose();
    }
    _atlasController.removeListener(_onAtlasChanged);
    if (_ownsAtlasController) {
      _atlasController.dispose();
    }
    _kittyCache.dispose();
    _paintNotifier.dispose();
    super.dispose();
  }

  void _onAtlasChanged() {
    if (!mounted) return;
    _syncTerminalCellMetrics();
    _prepareActiveBufferResources();
    setState(() {});
    _scheduleGeometrySync();
  }

  void _syncTerminalCellMetrics() {
    final terminal = widget.terminal;
    final atlas = _atlasController.atlas;
    if (terminal == null || atlas == null) return;
    terminal
      ..updateExactCellPixelSize(atlas.cellWidth, atlas.cellHeight)
      ..updateCellPixelSize(atlas.cellWidth.round(), atlas.cellHeight.round());
  }

  void _onExternalBufferChanged() {
    if (!mounted) return;
    final buf = _activeBuffer;
    final hasBuf = buf != null;
    final activePty =
        widget.activePtySizeProvider?.call() ?? widget.activePtySize;
    final cursor =
        widget.cursorPositionProvider?.call() ?? widget.cursorPosition;
    final cursorMoved = cursor != _lastCursorPosition;
    _lastCursorPosition = cursor;

    _bufferResourcesDirty = true;
    if (cursorMoved) {
      _scheduleGeometrySync();
    }

    final needsWidgetRebuild =
        !hasBuf ||
        !_hadActiveBuffer ||
        !identical(buf, _lastPaintedBuffer) ||
        activePty != _lastPaintedActivePtySize ||
        (_imeClient.composingText.isNotEmpty && cursorMoved);

    if (needsWidgetRebuild) {
      setState(() {});
      return;
    }
    _paintNotifier.notify();
  }

  void _onImeComposingChanged() {
    if (!mounted) return;
    setState(() {});
    _scheduleGeometrySync();
  }

  void _onFocusChanged() {
    final hasFocus = _focusNode.hasFocus;
    if (widget.enableIme) {
      if (hasFocus) {
        _imeClient.attach();
        _scheduleGeometrySync();
      } else {
        _imeClient.detach();
      }
    }
    widget.onFocusChanged?.call(hasFocus);
  }

  void _onSelectionChanged() {
    if (mounted) {
      _paintNotifier.notify();
    }
  }

  void _onKittyImageDecoded() {
    if (mounted) {
      _paintNotifier.notify();
    }
  }

  void _onTerminalBuiltinSelectionChanged(bool enabled) {
    if (!mounted) return;
    if (!enabled) {
      _isSelecting = false;
      _lastLeftTapAt = null;
      _lastLeftTapCell = null;
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

  void _flushDirtyBufferResources() {
    if (!mounted || !_bufferResourcesDirty) return;
    _bufferResourcesDirty = false;
    _prepareActiveBufferResources();
  }

  void _prepareActiveBufferResources() {
    final buf = _activeBuffer;
    if (buf == null) return;
    _prepareBufferResources(buf);
  }

  /// Pre-populates Kitty GPU image decoding and fallback [TextPainter] caches for [buffer].
  void prepareBuffer(Buffer buffer) {
    _externallyPreparedBuffer = buffer;
    _prepareBufferResources(buffer);
  }

  void _prepareBufferResources(Buffer buffer) {
    if (identical(buffer, _activeBuffer)) {
      _bufferResourcesDirty = false;
    }
    _kittyCache.ensureForBuffer(buffer);
    _atlasController.ensureFallbackPaintersForBuffer(
      buffer,
      defaultForegroundArgb: widget.foregroundColor.toARGB32(),
      defaultBackgroundArgb: widget.backgroundColor.toARGB32(),
      faintOpacity: widget.faintOpacity,
      palette: widget.palette,
    );
  }

  void _scheduleGeometrySync() {
    if (_geometrySyncScheduled || !widget.enableIme || !_focusNode.hasFocus) {
      return;
    }
    _geometrySyncScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _geometrySyncScheduled = false;
      _syncImeGeometry();
    });
  }

  void _syncImeGeometry() {
    if (!mounted || !widget.enableIme || !_focusNode.hasFocus) return;
    final atlas = _atlasController.atlas;
    if (atlas == null) return;
    final renderBox =
        _boundaryKey.currentContext?.findRenderObject() as RenderBox?;
    if (renderBox == null || !renderBox.attached || !renderBox.hasSize) return;

    final cursor =
        widget.cursorPositionProvider?.call() ?? widget.cursorPosition;
    final col = cursor?.col ?? 0;
    final row = cursor?.row ?? 0;
    final composingCells = countGraphemeDisplayCells(_imeClient.composingText);
    final cellW = atlas.cellWidth;
    final cellH = atlas.cellHeight;
    final caretRect = Rect.fromLTWH(col * cellW, row * cellH, cellW, cellH);
    final composingRect = Rect.fromLTWH(
      col * cellW,
      row * cellH,
      math.max(1, composingCells) * cellW,
      cellH,
    );
    _imeClient.updateCursorGeometry(
      editableSize: renderBox.size,
      transform: renderBox.getTransformTo(null),
      composingRect: composingRect,
      caretRect: caretRect,
    );
  }

  void _injectInputEvent(term.InputEvent event) {
    final handler = widget.onInputEvent;
    if (handler != null) {
      handler(event);
      return;
    }
    widget.terminal?.injectEvent(event);
  }

  bool _handleHostShortcut(KeyEvent event, Set<term.Modifier> mods) {
    if (widget.onHostShortcut?.call(event, mods) ?? false) {
      return true;
    }
    if (!widget.enableHostShortcuts) {
      return false;
    }
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.f12) {
      if (HardwareKeyboard.instance.isShiftPressed) {
        unawaited(_atlasController.recreateAtlas());
      } else {
        unawaited(_performTakeScreenshot());
      }
      return true;
    }
    if (isTerminalPasteShortcut(key, mods)) {
      unawaited(_pasteFromClipboard());
      return true;
    }
    return false;
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
    _injectInputEvent(term.PasteEvent(text));
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
    final atlas = _atlasController.atlas;
    if (atlas == null) return;
    final cellW = atlas.cellWidth;
    final cellH = atlas.cellHeight;
    if (cellW <= 0 || cellH <= 0) return;

    final maxCol = (layoutSize.width / cellW).floor();
    final maxRow = (layoutSize.height / cellH).floor();
    if (maxCol <= 0 || maxRow <= 0) return;

    _accumulateScrollDy(dy);
    final rawSteps = (_scrollRemainderDy / cellH).truncate();
    if (rawSteps == 0) return;
    _scrollRemainderDy -= rawSteps * cellH;

    final (col, row) = _clampCellToActiveGrid(
      (event.localPosition.dx / cellW).floor(),
      (event.localPosition.dy / cellH).floor(),
      maxCol,
      maxRow,
    );
    final pixelX = event.localPosition.dx.floor().clamp(0, 100000) + 1;
    final pixelY = event.localPosition.dy.floor().clamp(0, 100000) + 1;
    final steps = rawSteps.abs().clamp(1, _maxWheelStepsPerEvent);
    final button = rawSteps < 0
        ? term.MouseButton.wheelUp
        : term.MouseButton.wheelDown;
    final mods = collectHardwareModifiers();

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
      _injectInputEvent(termEvent);
    }
  }

  (int, int) _clampCellToActiveGrid(
    int rawCol,
    int rawRow,
    int maxC,
    int maxR,
  ) {
    final active = widget.activePtySizeProvider?.call() ?? widget.activePtySize;
    final effCols = active != null
        ? math.max(1, math.min(maxC, active.$1))
        : maxC;
    final effRows = active != null
        ? math.max(1, math.min(maxR, active.$2))
        : maxR;
    return (rawCol.clamp(0, effCols - 1), rawRow.clamp(0, effRows - 1));
  }

  static term.MouseButton _resolveMouseButton(int buttons) {
    if ((buttons & kSecondaryMouseButton) != 0) return term.MouseButton.right;
    if ((buttons & kMiddleMouseButton) != 0) return term.MouseButton.middle;
    return term.MouseButton.left;
  }

  static (term.MouseButton, term.MouseEventType) _classifyPointerEvent(
    PointerEvent event,
    term.MouseButton releaseButton,
  ) => switch (event) {
    PointerDownEvent(:final buttons) => (
      _resolveMouseButton(buttons),
      term.MouseEventType.press,
    ),
    PointerMoveEvent(:final down, :final buttons) when down => (
      _resolveMouseButton(buttons),
      term.MouseEventType.drag,
    ),
    PointerUpEvent() => (releaseButton, term.MouseEventType.release),
    _ => (term.MouseButton.none, term.MouseEventType.move),
  };

  ({int col, int row, int pixelX, int pixelY})? _resolvePointerCoords(
    PointerEvent event,
    Size layoutSize,
  ) {
    final atlas = _atlasController.atlas;
    if (atlas == null) return null;
    final maxCol = (layoutSize.width / atlas.cellWidth).floor();
    final maxRow = (layoutSize.height / atlas.cellHeight).floor();
    if (maxCol <= 0 || maxRow <= 0) return null;

    final (clampedCol, clampedRow) = _clampCellToActiveGrid(
      (event.localPosition.dx / atlas.cellWidth).floor(),
      (event.localPosition.dy / atlas.cellHeight).floor(),
      maxCol,
      maxRow,
    );
    return (
      col: clampedCol,
      row: clampedRow,
      pixelX: event.localPosition.dx.floor().clamp(0, 100000) + 1,
      pixelY: event.localPosition.dy.floor().clamp(0, 100000) + 1,
    );
  }

  void _handlePointerEvent(PointerEvent event, Size layoutSize) {
    final coords = _resolvePointerCoords(event, layoutSize);
    if (coords == null) return;

    if (event is PointerDownEvent &&
        !_focusNode.hasFocus &&
        _focusNode.canRequestFocus) {
      _focusNode.requestFocus();
    }

    if (event is PointerDownEvent) {
      _lastPressedButton = _resolveMouseButton(event.buttons);
    }
    final (termuiButton, termuiType) = _classifyPointerEvent(
      event,
      _lastPressedButton,
    );
    if (event is PointerUpEvent) {
      _lastPressedButton = term.MouseButton.left;
    }
    _updateSelectionAndUri(coords.col, coords.row, termuiButton, termuiType);

    final isLeftButton = termuiButton == term.MouseButton.left;
    final suppressPtyMouse =
        isLeftButton &&
        _leftGestureRoute == _LeftGestureRoute.localSelection &&
        (termuiType == term.MouseEventType.press ||
            termuiType == term.MouseEventType.drag ||
            termuiType == term.MouseEventType.release);
    if (isLeftButton && termuiType == term.MouseEventType.release) {
      _leftGestureRoute = _LeftGestureRoute.none;
    }
    if (suppressPtyMouse) return;

    final termEvent = term.MouseEvent(
      x: coords.col + 1,
      y: coords.row + 1,
      pixelX: coords.pixelX,
      pixelY: coords.pixelY,
      button: termuiButton,
      type: termuiType,
      modifiers: collectHardwareModifiers(),
    );

    if (_isDuplicatePointerMotion(termEvent)) return;
    _lastInjectedPointerEvent = termEvent;
    _injectInputEvent(termEvent);
  }

  void _handlePointerCancel(PointerCancelEvent event, Size layoutSize) {
    final wasSelecting = _isSelecting;
    final route = _leftGestureRoute;
    _resetScrollAccumulator();
    _linkPressCell = null;
    _isSelecting = false;
    _lastLeftTapAt = null;
    _lastLeftTapCell = null;
    _lastPressedButton = term.MouseButton.left;
    _leftGestureRoute = _LeftGestureRoute.none;
    if (wasSelecting || route == _LeftGestureRoute.ptyMouse) {
      _selectionController.clearSelection();
    }
    if (route != _LeftGestureRoute.ptyMouse) return;

    final coords = _resolvePointerCoords(event, layoutSize);
    if (coords == null) return;
    final termEvent = term.MouseEvent(
      x: coords.col + 1,
      y: coords.row + 1,
      pixelX: coords.pixelX,
      pixelY: coords.pixelY,
      button: term.MouseButton.left,
      type: term.MouseEventType.release,
      modifiers: collectHardwareModifiers(),
    );
    _lastInjectedPointerEvent = termEvent;
    _injectInputEvent(termEvent);
  }

  bool _isDuplicatePointerMotion(term.MouseEvent event) {
    if (event.type != term.MouseEventType.move &&
        event.type != term.MouseEventType.drag) {
      return false;
    }
    final prev = _lastInjectedPointerEvent;
    if (prev == null) return false;
    if (_effectiveReportPixelMouse) return prev == event;
    return prev.x == event.x &&
        prev.y == event.y &&
        prev.button == event.button &&
        prev.type == event.type &&
        setEquals(prev.modifiers, event.modifiers);
  }

  void _updateSelectionAndUri(
    int col,
    int row,
    term.MouseButton button,
    term.MouseEventType type,
  ) {
    final (nextUri, uriChanged) = _updateHoveredLinkCell(col, row);
    if (button == term.MouseButton.left) {
      if (type == term.MouseEventType.press) {
        _handleLeftPointerPress(col, row, nextUri);
      } else if (type == term.MouseEventType.drag) {
        _handlePointerDrag(col, row);
      } else if (type == term.MouseEventType.release) {
        _finishPointerRelease(col, row, nextUri);
      }
    }
    if (uriChanged && mounted) {
      setState(() {});
    }
  }

  (String?, bool) _updateHoveredLinkCell(int col, int row) {
    if (!_builtinLinkOpenEnabled) return (null, false);
    final buf = _activeBuffer;
    final inBounds =
        buf != null &&
        col >= 0 &&
        col < buf.width &&
        row >= 0 &&
        row < buf.height;
    final nextUri = inBounds ? buf.getUri(col, row) : null;
    final linkMod = _isLinkOpenModifierPressed();
    final changed = nextUri != _hoveredUri || linkMod != _isLinkModifierActive;
    _hoveredUri = nextUri;
    _isLinkModifierActive = linkMod;
    return (nextUri, changed);
  }

  void _handleLeftPointerPress(int col, int row, String? hoveredUri) {
    final isLinkClick =
        _builtinLinkOpenEnabled &&
        _isLinkOpenModifierPressed() &&
        hoveredUri != null &&
        hoveredUri.isNotEmpty;
    if (isLinkClick) {
      _linkPressCell = (col: col, row: row);
      _leftGestureRoute = _effectiveMouseTracking
          ? _LeftGestureRoute.localSelection
          : _LeftGestureRoute.none;
      return;
    }

    if (_effectiveMouseTracking) {
      if (HardwareKeyboard.instance.isShiftPressed &&
          _builtinSelectionEnabled) {
        _linkPressCell = _builtinLinkOpenEnabled ? (col: col, row: row) : null;
        _leftGestureRoute = _LeftGestureRoute.localSelection;
        _startSelectionAt(col, row);
        return;
      }
      _linkPressCell = null;
      _leftGestureRoute = _LeftGestureRoute.ptyMouse;
      _isSelecting = false;
      _lastLeftTapAt = null;
      _lastLeftTapCell = null;
      _selectionController.clearSelection();
      return;
    }

    _leftGestureRoute = _LeftGestureRoute.none;
    _linkPressCell = _builtinLinkOpenEnabled ? (col: col, row: row) : null;
    if (_builtinSelectionEnabled) {
      _startSelectionAt(col, row);
    }
  }

  void _handlePointerDrag(int col, int row) {
    if (_linkPressCell != null && _linkPressCell != (col: col, row: row)) {
      _linkPressCell = null;
    }
    if (!_builtinSelectionEnabled || !_isSelecting) return;

    if (_selectionController.mode == SelectionMode.word) {
      final buf = _activeBuffer;
      if (buf != null) {
        _selectionController.updateWordSelection(buf, col, row);
      }
      return;
    }

    final tapCell = (
      col: _resolveTapLeadCol(_activeBuffer, col, row),
      row: row,
    );
    if (tapCell == _lastLeftTapCell && !_selectionController.hasSelection) {
      return;
    }
    _lastLeftTapAt = null;
    final mode = HardwareKeyboard.instance.isAltPressed
        ? SelectionMode.block
        : SelectionMode.stream;
    _selectionController.updateSelection(col, row, mode: mode);
  }

  static int _resolveTapLeadCol(Buffer? buf, int col, int row) {
    if (buf == null || col <= 0 || col >= buf.width) return col;
    if (row < 0 || row >= buf.height) return col;
    return buf.getCharacter(col, row).isEmpty ? col - 1 : col;
  }

  void _startSelectionAt(int col, int row) {
    final buf = _activeBuffer;
    final isAlt = HardwareKeyboard.instance.isAltPressed;
    final mode = isAlt ? SelectionMode.block : SelectionMode.stream;
    final region = buf != null
        ? TerminalSelectionController.resolveRegionForCell(
            buf,
            col,
            row,
            mode: mode,
          )
        : null;
    if (_isGraphicCanvasPress(buf, row, region)) {
      _lastLeftTapAt = null;
      _lastLeftTapCell = null;
      _selectionController.clearSelection();
      _isSelecting = false;
      return;
    }

    final leadCol = _resolveTapLeadCol(buf, col, row);
    final tapCell = (col: leadCol, row: row);
    final now = clock.now();
    final lastAt = _lastLeftTapAt;
    if (!isAlt &&
        buf != null &&
        lastAt != null &&
        _lastLeftTapCell == tapCell &&
        now.difference(lastAt) <= kDoubleTapTimeout) {
      _lastLeftTapAt = null;
      _lastLeftTapCell = null;
      _selectionController.selectWord(buf, leadCol, row, region: region);
      _isSelecting = true;
      return;
    }

    _lastLeftTapAt = now;
    _lastLeftTapCell = tapCell;
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
      final hasCompletedSelection =
          _isSelecting && _selectionController.hasSelection;
      _isSelecting = false;
      if (hasCompletedSelection) {
        if (_effectiveCopyOnSelect) {
          _copySelectedBufferText();
        }
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
    final buf = _activeBuffer;
    if (buf == null) return;
    final selectedText = _selectionController.extractText(
      buf,
      includeHidden: true,
    );
    if (selectedText.isNotEmpty) {
      unawaited(_writeToClipboard(selectedText));
    }
  }

  Future<void> _performTakeScreenshot() async {
    try {
      final timestamp = clock.now().millisecondsSinceEpoch;
      final screenshotBasename = await _saveRepaintBoundaryScreenshot(
        timestamp,
      );
      final atlas = _atlasController.atlas;
      final atlasBasename = atlas != null
          ? await _saveAtlasScreenshot(atlas, timestamp)
          : null;
      if (atlas != null) {
        await _saveAtlasTable(atlas, timestamp);
      }
      final buffer = _activeBuffer;
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
      final message = savedFiles.isNotEmpty
          ? 'Saved: ${savedFiles.join(', ')}'
          : 'No files saved.';
      _notifyStatus(message);
    } on Object catch (e) {
      _notifyStatus(
        'Error saving screenshot/atlas/coordinates: $e',
        isError: true,
      );
    }
  }

  void _notifyStatus(String message, {bool isError = false}) {
    if (!mounted) return;
    widget.onStatusNotice?.call(message, isError: isError);
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

  MouseCursor _mapOsc22ToSystemCursor(String? cursorName) =>
      switch (cursorName) {
        null || '' || 'default' => SystemMouseCursors.basic,
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

  @override
  Widget build(BuildContext context) {
    if (_atlasController.atlas == null) {
      return widget.loadingWidget ?? ColoredBox(color: widget.backgroundColor);
    }
    return LayoutBuilder(builder: _buildTerminalBody);
  }

  Widget _buildTerminalBody(BuildContext context, BoxConstraints constraints) {
    final atlas = _atlasController.atlas!;
    final (cols, rows) = _calculateGridDimensions(
      constraints,
      MediaQuery.maybeSizeOf(context),
      atlas.cellWidth,
      atlas.cellHeight,
    );
    _syncTerminalSizeAndIme(cols, rows, atlas.cellWidth, atlas.cellHeight);

    final layoutSize = Size(cols * atlas.cellWidth, rows * atlas.cellHeight);
    return Focus(
      focusNode: _focusNode,
      autofocus: widget.autofocus,
      onKeyEvent: (_, event) => _imeClient.handleKeyEvent(event),
      child: ColoredBox(
        color: widget.backgroundColor,
        child: Align(
          alignment: widget.alignment,
          child: RepaintBoundary(
            key: _boundaryKey,
            child: MouseRegion(
              cursor: _effectiveCursor,
              onExit: widget.onPointerExit,
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
    final defaultCols = widget.terminal?.backend.size.x ?? 80;
    final defaultRows = widget.terminal?.backend.size.y ?? 24;
    final availW = constraints.hasBoundedWidth
        ? constraints.maxWidth
        : (fallbackSize?.width ?? defaultCols * cellW);
    final availH = constraints.hasBoundedHeight
        ? constraints.maxHeight
        : (fallbackSize?.height ?? defaultRows * cellH);
    return ((availW / cellW).floor(), (availH / cellH).floor());
  }

  void _syncTerminalSizeAndIme(
    int cols,
    int rows,
    double cellWidth,
    double cellHeight,
  ) {
    if (cols <= 0 || rows <= 0) return;
    final changed =
        !_hasReportedLayout ||
        _lastReportedCols != cols ||
        _lastReportedRows != rows ||
        _lastReportedCellW != cellWidth ||
        _lastReportedCellH != cellHeight;
    if (!changed) return;

    _hasReportedLayout = true;
    _lastReportedCols = cols;
    _lastReportedRows = rows;
    _lastReportedCellW = cellWidth;
    _lastReportedCellH = cellHeight;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      widget.terminal?.updateSize(math.Point(cols, rows));
      widget.onViewportSizeChanged?.call(cols, rows, cellWidth, cellHeight);
      _syncImeGeometry();
    });
  }

  Widget _buildPointerListener(Size layoutSize) => Listener(
    onPointerDown: (e) => _handlePointerEvent(e, layoutSize),
    onPointerMove: (e) => _handlePointerEvent(e, layoutSize),
    onPointerHover: (e) => _handlePointerEvent(e, layoutSize),
    onPointerUp: (e) => _handlePointerEvent(e, layoutSize),
    onPointerCancel: (e) => _handlePointerCancel(e, layoutSize),
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
    final buf = _activeBuffer;
    final activePty =
        widget.activePtySizeProvider?.call() ?? widget.activePtySize;
    final cursor =
        widget.cursorPositionProvider?.call() ?? widget.cursorPosition;
    _hadActiveBuffer = buf != null;
    _lastPaintedBuffer = buf;
    _lastPaintedActivePtySize = activePty;
    return Container(
      width: layoutSize.width,
      height: layoutSize.height,
      color: widget.backgroundColor,
      child: buf == null
          ? const SizedBox()
          : CustomPaint(
              size: layoutSize,
              painter: TuiAtlasPainter(
                repaint: _paintNotifier,
                buffer: buf,
                atlas: _atlasController.atlas!,
                fontFamily: _atlasController.fontFamily,
                fontFamilyFallback: _atlasController.fontFamilyFallback,
                fallbackPainters: _atlasController.fallbackPainters,
                onMissingGlyphs: null,
                onMissingStyledGlyphs:
                    _atlasController.requestMissingStyledGlyphs,
                onBeforePaint: _flushDirtyBufferResources,
                enableBleed: widget.enableBleed,
                enableLigatures: _enableLigatures,
                ligaturePainters: _atlasController.ligaturePainters,
                selectionController: _builtinSelectionEnabled
                    ? _selectionController
                    : null,
                kittyImages: _kittyCache.images,
                kittyImagesById: _kittyCache.imagesById,
                defaultForegroundArgb: widget.foregroundColor.toARGB32(),
                defaultBackgroundArgb: widget.backgroundColor.toARGB32(),
                faintOpacity: widget.faintOpacity,
                palette: widget.palette,
                activePtyCols: activePty?.$1,
                activePtyRows: activePty?.$2,
                outOfBoundsDimColor: widget.outOfBoundsDimColor,
                composingText: widget.enableIme ? _imeClient.composingText : '',
                cursorCol: cursor?.col ?? 0,
                cursorRow: cursor?.row ?? 0,
              ),
            ),
    );
  }
}

final class _KittyGpuImageCache {
  static const int _maxKittyGpuImages = 64;
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

  final VoidCallback onDecoded;
  final Map<KittyImageData, ui.Image> images = {};
  final Map<(KittyImageRegistry, int), ui.Image> imagesById = {};
  final Set<KittyImageData> _decoding = Set.identity();
  bool _disposed = false;

  _KittyGpuImageCache({required this.onDecoded});

  void ensureForBuffer(Buffer buffer) {
    if (!buffer.hasKittyImages) return;
    final width = buffer.width;
    final total = width * buffer.height;
    final chars = buffer.characters;
    final attrs = buffer.attributes;
    KittyImageData? lastKittyData;
    for (var i = 0; i < total; i++) {
      final mods = attrs[i * 3 + 2];
      final hasKittyMod = Modifier.has(mods, Modifier.kittyPlaceholder);
      final char = chars[i];
      if (!hasKittyMod) {
        if (char.length < 2 || !char.startsWith(kittyPlaceholderChar)) {
          continue;
        }
      } else if (char.isEmpty || char == ' ') {
        continue;
      }
      lastKittyData = _resolveAndEnsure(
        buffer,
        i % width,
        i ~/ width,
        char,
        lastKittyData,
      );
    }
  }

  KittyImageData? _resolveAndEnsure(
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
      _ensureImage(registry, data);
      return data;
    }
    return lastKittyData;
  }

  void _ensureImage(KittyImageRegistry registry, KittyImageData data) {
    final existing = images.remove(data);
    if (existing != null) {
      images[data] = existing;
      imagesById[(registry, data.imageId)] = existing;
      return;
    }
    if (data.rgbaPixels.isEmpty) return;
    if (data.format == 100) {
      if (!_decoding.add(data)) return;
      unawaited(_decodePngImage(registry, data));
      return;
    }
    if (data.pixelWidth <= 0 || data.pixelHeight <= 0) return;
    if (!_decoding.add(data)) return;
    ui.decodeImageFromPixels(
      data.rgbaPixels,
      data.pixelWidth,
      data.pixelHeight,
      ui.PixelFormat.rgba8888,
      (decoded) => _onImageDecoded(registry, data, decoded),
    );
  }

  static bool _isValidPngPayload(KittyImageData data) {
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

  Future<void> _decodePngImage(
    KittyImageRegistry registry,
    KittyImageData data,
  ) async {
    if (!_isValidPngPayload(data)) {
      _decoding.remove(data);
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
      _onImageDecoded(registry, data, frame.image);
    } on Object catch (_) {
      _decoding.remove(data);
    } finally {
      codec?.dispose();
    }
  }

  void _evictOldest() {
    final oldestKey = images.keys.first;
    final evicted = images.remove(oldestKey);
    if (evicted == null) return;
    imagesById.removeWhere((_, img) => identical(img, evicted));
    evicted.dispose();
  }

  void _onImageDecoded(
    KittyImageRegistry registry,
    KittyImageData data,
    ui.Image decoded,
  ) {
    _decoding.remove(data);
    if (_disposed) {
      decoded.dispose();
      return;
    }
    while (images.length >= _maxKittyGpuImages && !images.containsKey(data)) {
      _evictOldest();
    }
    final old = images[data];
    images[data] = decoded;
    imagesById[(registry, data.imageId)] = decoded;
    if (old != null && !identical(old, decoded)) {
      old.dispose();
    }
    onDecoded();
  }

  void dispose() {
    _disposed = true;
    imagesById.clear();
    for (final image in images.values) {
      image.dispose();
    }
    images.clear();
    _decoding.clear();
  }
}

final class _SurfaceRepaintNotifier extends ChangeNotifier {
  void notify() => notifyListeners();
}
