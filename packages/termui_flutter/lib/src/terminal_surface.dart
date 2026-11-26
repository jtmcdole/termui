import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:clock/clock.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:termui/terminal/terminal.dart' as term;
import 'package:termui/ui/buffer.dart';
import 'package:termui/ui/glyph_cell_list.dart';
import 'package:termui/ui/shader_region.dart';
import 'package:termui/ui/style.dart';
import 'package:termui/ui/terminal_palette.dart';
import 'package:termui/ui/widgets/display/kitty_image.dart';
import 'package:termui/ui/widgets/interactive/selection_controller.dart';

import 'backend.dart';
import 'rendering/atlas.dart';
import 'rendering/atlas_controller.dart';
import 'rendering/cell_transform_painter.dart';
import 'rendering/gpu_atlas_batch.dart';
import 'rendering/gpu_frame_watchdog.dart';
import 'rendering/painter.dart';
import 'rendering/perf_trace.dart';
import 'rendering/search_highlight.dart';
import 'rendering/shader_backend.dart';
import 'rendering/shader_controller.dart';
import 'rendering/shader_host.dart';
import 'rendering/shader_region_painter.dart';
import 'rendering/shader_spec.dart';
import 'rendering/staging_cache.dart';
import 'selection_gesture_machine.dart';
import 'service/terminal_service.dart';
import 'terminal_ime_client.dart';
import 'util/url_launcher.dart';

/// Optional [Listenable] contract implemented by external terminal buffer
/// compositors (such as `FtermPaneController`) to distinguish full cell-content
/// mutations from overlay-only updates (`ShaderRegion` / `CellTransform`).
///
/// When [cellContentRevision] has not changed between notifications,
/// [TerminalSurface] skips static glyph-atlas fallback scans and preserves its
/// cached static direct-GPU quad batch and region masks.
abstract interface class TerminalBufferChangeSignal implements Listenable {
  /// Monotonic counter incremented whenever cell characters, attributes,
  /// scrollback rows, or cursor cells change.
  int get cellContentRevision;
}

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
  final HostShortcutResult Function(
    KeyEvent event,
    Set<term.Modifier> modifiers,
  )?
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

  /// Policy for unhandled `Meta`/`Cmd` combinations after host/built-in shortcuts.
  final TerminalMetaKeyPolicy metaKeyPolicy;

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

  /// Enables per-row sprite staging cache in [TuiAtlasPainter]. Defaults to `true`.
  ///
  /// Set to `false` as a runtime rollback switch to restage every row on each paint.
  final bool enableRowCache;

  /// Optional external text selection controller.
  final TerminalSelectionController? selectionController;

  /// Monotonic virtual row index corresponding to viewport row `0`.
  final int topVirtualRow;

  /// Optional live getter overriding [topVirtualRow] as scrollback moves.
  final int Function()? topVirtualRowProvider;

  /// Optional live epoch token (e.g. `(clearSeq, altScreen)`) whose change resets active selection state.
  final Object? Function()? selectionEpochProvider;

  /// Optional virtual row lookup used to extract multi-screenful selections across scrollback and live rows.
  final VirtualLineLookup? virtualLineLookup;

  /// Optional scrollback callback invoked when a selection drag crosses the top (`+`) or bottom (`-`) edge.
  final void Function(int deltaLines)? onSelectionAutoScroll;

  /// Enables built-in viewport mouse selection and auto-copy.
  final bool enableBuiltinSelection;

  /// Enables built-in `OSC 8` and plain-text (`http`/`https`/`mailto`) link
  /// hover cursor feedback and `Ctrl/Cmd+Click` (including macOS `Ctrl+RightClick`)
  /// launch.
  final bool enableBuiltinLinkOpen;

  /// Optional virtual row lookup used by link resolution to span soft-wrapped
  /// rows across scrollback and viewport lines; defaults to slicing [buffer].
  final VirtualLineLookup? linkLineLookup;

  /// Optional client-supplied per-cell style override for hovered hyperlinks.
  ///
  /// When omitted, hovered links are underlined by default.
  final HoveredLinkStyler? hoveredLinkStyler;

  /// Optional repaint interval used to animate [hoveredLinkStyler] while a
  /// link is actively hovered; ignored when [hoveredLinkStyler] is `null` or
  /// the duration is non-positive.
  final Duration? hoveredLinkAnimationInterval;

  /// Enables built-in host shortcuts (`F12` screenshot, `Shift+F12` rebuild, copy/paste).
  final bool enableHostShortcuts;

  /// Alignment of the cell-quantized terminal grid inside loose or bounded margins.
  final AlignmentGeometry alignment;

  /// Optional controller managing compiled custom fragment shaders and
  /// wallpaper textures across panes.
  final TerminalShaderController? shaderController;

  /// Optional declarative shader pass chains, animation mode, and wallpaper
  /// configuration wrapped inside the screenshot `RepaintBoundary`.
  final TerminalShaderConfig? shaderConfig;

  /// Opacity multiplier (`0.0..1.0`) applied to default background cells and
  /// canvas container fill so wallpapers and background shaders show through.
  final double backgroundOpacity;

  /// Active Ghostty cursor style constant (`0..3`, e.g.
  /// [TerminalShaderUniforms.cursorStyleBlock]) forwarded to custom shaders.
  final int cursorStyle;

  /// Whether the terminal cursor is visible when [cursorVisibleProvider] is
  /// omitted (forwarded to custom shaders as `iCursorVisible`).
  final bool cursorVisible;

  /// Optional live getter returning whether the terminal cursor is visible.
  final bool Function()? cursorVisibleProvider;

  /// Optional external [CliShaderRegistry] for managing CLI custom GLSL slots
  /// and built-in region presets on this pane.
  final CliShaderRegistry? cliShaderRegistry;

  /// Optional external [GpuFrameWatchdog] monitoring custom CLI shaders on this
  /// pane.
  final GpuFrameWatchdog? gpuFrameWatchdog;

  /// Optional callback invoked whenever a custom CLI shader ID is quarantined
  /// by the per-pane [GpuFrameWatchdog].
  final ShaderQuarantinedCallback? onCliShaderQuarantined;

  /// Optional monotonic animation clock driving per-cell [CellTween] evaluation.
  ///
  /// Defaults to [SchedulerBinding.currentFrameTimeStamp] so animations lock
  /// cleanly to frame vsync timestamps and remain deterministic in tests.
  final Duration Function()? tweenClock;

  /// Optional maximum ambient shader tick rate in frames per second forwarded
  /// to [TerminalShaderHost.maxAmbientFps] (`null` = uncapped display vsync).
  final double? maxAmbientFps;

  /// Optional live getter returning active search match highlights to overlay
  /// above the terminal surface.
  final TerminalSearchHighlightsProvider? searchHighlightsProvider;

  /// Optional [Listenable] notifying when [searchHighlightsProvider] changes.
  final Listenable? searchHighlightsListenable;

  /// Optional base color used for inactive search highlight spans.
  final Color? searchMatchColor;

  /// Optional base color used for the active search highlight span and border.
  final Color? activeSearchMatchColor;

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
    this.metaKeyPolicy = .claimAll,
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
    this.enableRowCache = true,
    this.selectionController,
    this.topVirtualRow = 0,
    this.topVirtualRowProvider,
    this.selectionEpochProvider,
    this.virtualLineLookup,
    this.onSelectionAutoScroll,
    this.enableBuiltinSelection = true,
    this.enableBuiltinLinkOpen = true,
    this.linkLineLookup,
    this.hoveredLinkStyler,
    this.hoveredLinkAnimationInterval,
    this.enableHostShortcuts = true,
    this.alignment = Alignment.center,
    this.shaderController,
    this.shaderConfig,
    this.backgroundOpacity = 1.0,
    this.cursorStyle = TerminalShaderUniforms.cursorStyleBlock,
    this.cursorVisible = true,
    this.cursorVisibleProvider,
    this.cliShaderRegistry,
    this.gpuFrameWatchdog,
    this.onCliShaderQuarantined,
    this.tweenClock,
    this.maxAmbientFps = TerminalShaderHost.defaultMaxAmbientFps,
    this.searchHighlightsProvider,
    this.searchHighlightsListenable,
    this.searchMatchColor,
    this.activeSearchMatchColor,
  });

  @override
  State<TerminalSurface> createState() => TerminalSurfaceState();
}

/// State backing [TerminalSurface], exposed for diagnostics and widget tests.
final class TerminalSurfaceState extends State<TerminalSurface>
    with WidgetsBindingObserver, TickerProviderStateMixin {
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
  final TuiAtlasStagingCache _stagingCache = TuiAtlasStagingCache();
  final GpuAtlasBatchBuilder _gpuBatchBuilder = GpuAtlasBatchBuilder();
  final CellTransformAnimator _cellTransformAnimator = CellTransformAnimator();
  final CellOverrideMaskBuilder _overrideMaskBuilder =
      CellOverrideMaskBuilder();
  final CellTransformGpuStager _cellTransformGpuStager =
      CellTransformGpuStager();
  final CellTransformPainter _cellTransformPainter = CellTransformPainter();
  final ShaderRegionGpuStager _regionGpuStager = ShaderRegionGpuStager();
  final ShaderRegionCanvasStager _regionCanvasStager =
      ShaderRegionCanvasStager();
  late CliShaderRegistry _cliShaderRegistry;
  late bool _ownsCliShaderRegistry;
  late GpuFrameWatchdog _gpuWatchdog;
  late bool _ownsGpuWatchdog;
  bool _attachedFrameTimingsToWatchdog = false;
  Uint8List? _cellOverrideMask;
  Ticker? _tweenTicker;
  Duration _lastTweenStamp = Duration.zero;
  Duration? _lastSyncedTweenStamp;
  Buffer? _lastSyncedTransformBuf;
  int _lastSyncedTransformRev = -1;
  int _lastSyncedRegionRev = -1;
  int _lastExternalCellContentRevision = -1;
  int _directPaintVersion = 0;
  int _directBatchInvalidationEpoch = 0;
  int _overrideMaskHash = 0;
  GpuAtlasQuadBatch? _cachedStaticBatch;
  GpuAtlasQuadBatch? _cachedDirectBatch;
  StagedRegionMasksResult? _cachedRegionMasks;
  List<ComputedShaderRegionLayout>? _cachedRegionLayouts;
  Buffer? _cachedDirectBuf;
  GlyphAtlas? _cachedDirectAtlas;
  Size _cachedDirectSize = Size.zero;
  double _cachedDirectDpr = 0.0;
  int _cachedDirectPaintVersion = -1;
  int _cachedDirectNotifyVersion = -1;
  int _cachedDirectTransformTickVersion = -1;
  int _cachedDirectEpoch = -1;
  int _cachedDirectOverrideHash = -1;
  ({int col, int row})? _cachedDirectCursor;
  (int, int)? _cachedDirectPtySize;
  int _cachedDirectRegionRev = -1;
  int _cachedDirectTransformRev = -1;
  bool _cachedDirectHasTransforms = false;
  final _SurfaceRepaintNotifier _paintNotifier = _SurfaceRepaintNotifier();
  final _ShaderMouseNotifier _shaderMouseNotifier = _ShaderMouseNotifier();
  bool _hasSearchHighlights = false;
  Listenable? _searchOverlayRepaint;
  bool _shaderHasPointerClick = false;
  bool _shaderPrimaryButtonDown = false;
  double _shaderClickLogicalX = 0.0;
  double _shaderClickLogicalY = 0.0;

  TextPainter? _composingPainter;
  String _composingPainterText = '';
  String _composingPainterFontFamily = '';
  List<String>? _composingPainterFontFallback;
  double _composingPainterFontSize = 0.0;
  int _composingPainterColorArgb = 0;

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

  static final Set<LogicalKeyboardKey> _latchedClearedModifiers = {};

  MouseCursor _currentCursor = SystemMouseCursors.basic;
  ResolvedTerminalLinkDetail? _hoveredLinkDetail;
  ResolvedTerminalLink? get _hoveredLink => _hoveredLinkDetail?.link;
  ({int col, int row})? _lastHoverCell;
  bool _hoverLinkResolved = false;
  bool _isLinkModifierActive = false;
  Timer? _linkHoverTimer;
  late SelectionGestureMachine _gestureMachine;
  int _lastTopVirtualRow = 0;
  Object? _lastSelectionEpoch;
  term.MouseButton _lastPressedButton = term.MouseButton.left;
  term.MouseEvent? _lastInjectedPointerEvent;

  double _scrollRemainderDy = 0.0;
  DateTime? _lastScrollAt;

  bool _hasReportedLayout = false;
  Size? _lastLayoutSize;
  int _lastReportedCols = 0;
  int _lastReportedRows = 0;
  double _lastReportedCellW = 0.0;
  double _lastReportedCellH = 0.0;
  bool _geometrySyncScheduled = false;
  int? _imeViewId;
  TerminalColorTheme? _cachedPaletteTheme;
  Uint32List? _cachedPalette256Argb;

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
      widget.mouseTrackingProvider?.call() ??
      widget.terminal?.mouseTracking ??
      widget.mouseTracking;

  bool get _effectiveCopyOnSelect =>
      widget.copyOnSelectProvider?.call() ?? widget.copyOnSelect;

  int get _effectiveTopVirtualRow =>
      widget.topVirtualRowProvider?.call() ?? widget.topVirtualRow;

  int _readEffectiveTopVirtualRow() => _effectiveTopVirtualRow;

  bool get _hasScrollbackBinding =>
      widget.virtualLineLookup != null ||
      widget.topVirtualRowProvider != null ||
      widget.topVirtualRow != 0;

  /// Active [GlyphAtlasController] used by this surface.
  GlyphAtlasController get atlasController => _atlasController;

  /// Active [TerminalImeClient] handling keyboard/IME arbitration.
  TerminalImeClient get imeClient => _imeClient;

  /// Active [TerminalSelectionController] used by this surface.
  TerminalSelectionController get selectionController => _selectionController;

  /// Per-pane [CliShaderRegistry] managing compiled region presets and CLI
  /// custom GLSL shaders.
  CliShaderRegistry get cliShaderRegistry => _cliShaderRegistry;

  /// Per-pane [GpuFrameWatchdog] monitoring custom CLI shaders.
  GpuFrameWatchdog get gpuFrameWatchdog => _gpuWatchdog;

  /// Most recent logical layout size computed for the terminal grid, or `null`
  /// before the first layout pass.
  Size? get lastLogicalLayoutSize => _lastLayoutSize;

  /// Injects a normalized `[0.0, 1.0]` pointer position into shader `iMouse`
  /// uniforms without moving the OS cursor or forwarding PTY mouse events.
  ///
  /// Clamps [x] and [y] to `[0.0, 1.0]` and maps them to logical pixels using
  /// [_lastLayoutSize] (falling back to the mounted [RenderBox] size when laid
  /// out). Preserves the initial press origin while [pressed] remains `true`.
  void injectShaderPointerNormalized({
    required double x,
    required double y,
    bool pressed = false,
  }) {
    if (!mounted || x.isNaN || y.isNaN) return;
    final layoutSize = _resolveLogicalLayoutSize();
    if (layoutSize == null) return;
    final lx = x.clamp(0.0, 1.0) * layoutSize.width;
    final ly = y.clamp(0.0, 1.0) * layoutSize.height;
    if (pressed && !_shaderPrimaryButtonDown) {
      _shaderHasPointerClick = true;
      _shaderClickLogicalX = math.max(lx, 1e-3);
      _shaderClickLogicalY = math.max(ly, 1e-3);
    }
    _shaderPrimaryButtonDown = pressed;
    _publishShaderPointer(lx, ly);
  }

  /// Resets injected shader pointer state and zeroes `iMouse` uniforms.
  void clearInjectedShaderPointer() {
    if (!mounted) return;
    _shaderHasPointerClick = false;
    _shaderPrimaryButtonDown = false;
    _shaderClickLogicalX = 0.0;
    _shaderClickLogicalY = 0.0;
    _shaderMouseNotifier.update(0.0, 0.0, 0.0, 0.0, notify: _hasShaderBinding);
  }

  /// Compiles and registers a custom CLI GLSL shader [source] under [id] with
  /// a bounded [timeout] (defaults to `4s`).
  Future<CompiledShaderHandle?> registerCliShader({
    required String id,
    required String source,
    bool usesPrevFrame = false,
    Duration timeout = CliShaderRegistry.cliCompileTimeout,
  }) => _cliShaderRegistry.registerCliShader(
    id: id,
    source: source,
    usesPrevFrame: usesPrevFrame,
    timeout: timeout,
  );

  /// Removes a compiled CLI shader slot [id] from this pane.
  void removeCliShader(String id) {
    _cliShaderRegistry.removeCliShader(id);
    _paintNotifier.notify();
  }

  /// Quarantines custom CLI shader [id] on this pane while preserving built-in
  /// presets and per-cell transforms.
  void quarantineCliShader(String id, String reason) {
    _cliShaderRegistry.quarantineShader(id, reason);
    _paintNotifier.notify();
  }

  /// Whether the on-demand 120 Hz `CellTween` ticker is currently running.
  @visibleForTesting
  bool get debugIsTweenTickerActive => _tweenTicker?.isActive ?? false;

  /// Active per-cell transform animator (for diagnostics and tests).
  @visibleForTesting
  CellTransformAnimator get debugCellTransformAnimator =>
      _cellTransformAnimator;

  /// Active leaf state of the selection gesture HSM (for diagnostics and tests).
  @visibleForTesting
  SelectionGestureState get debugGestureState => _gestureMachine.state;

  /// Active row-staging cache owned by this surface (for diagnostics and tests).
  @visibleForTesting
  TuiAtlasStagingCache get debugStagingCache => _stagingCache;

  /// Cached IME pre-edit [TextPainter], if currently composing (for tests).
  @visibleForTesting
  TextPainter? get debugComposingPainter => _composingPainter;

  MouseCursor get _effectiveCursor =>
      (_builtinLinkOpenEnabled &&
          _hoveredLink != null &&
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
    WidgetsBinding.instance.addObserver(this);
    _latchedClearedModifiers.retainAll(
      HardwareKeyboard.instance.logicalKeysPressed,
    );
    _lastTweenStamp = _readCurrentTweenStamp();
    _initCliShaderAndWatchdog();
    _initAtlasController();
    _initFocusAndSelection();
    _initImeClient();
    _kittyCache = _KittyGpuImageCache(onDecoded: _onKittyImageDecoded);
    _initModeFlags();
    _bindTerminalStreams();
    HardwareKeyboard.instance.addHandler(_onHardwareKeyEvent);
    final listenable = widget.bufferListenable;
    listenable?.addListener(_onExternalBufferChanged);
    if (listenable is TerminalBufferChangeSignal) {
      _lastExternalCellContentRevision = listenable.cellContentRevision;
    }
    _hasSearchHighlights = _readHasSearchHighlights();
    _rebuildSearchOverlayRepaint();
    widget.searchHighlightsListenable?.addListener(_onSearchHighlightsChanged);
    _hadActiveBuffer = _activeBuffer != null;
    _lastTopVirtualRow = _effectiveTopVirtualRow;
    _lastSelectionEpoch = widget.selectionEpochProvider?.call();
    _lastCursorPosition =
        widget.cursorPositionProvider?.call() ?? widget.cursorPosition;
    _prepareActiveBufferResources();
    _syncCellTransformsAndRegions(_activeBuffer);
  }

  void _initCliShaderAndWatchdog() {
    _ownsGpuWatchdog = widget.gpuFrameWatchdog == null;
    _gpuWatchdog =
        widget.gpuFrameWatchdog ??
        GpuFrameWatchdog(
          warmupFrameCount: GpuFrameWatchdog.recommendedWarmupFrameCount,
          isBuiltinPreset: ShaderRegionPresets.isPreset,
          onShaderQuarantined: _onWatchdogShaderQuarantined,
        );
    _syncWatchdogFrameTimings();
    _ownsCliShaderRegistry = widget.cliShaderRegistry == null;
    _cliShaderRegistry =
        widget.cliShaderRegistry ??
        CliShaderRegistry(
          backend: widget.shaderController?.backend,
          watchdog: _gpuWatchdog,
        );
    _cliShaderRegistry.attachWatchdog(_gpuWatchdog);
    if (widget.shaderController != null) {
      _cliShaderRegistry.attachBackend(widget.shaderController!.backend);
      widget.shaderController!.addListener(_onShaderControllerChanged);
    }
  }

  void _syncWatchdogFrameTimings() {
    final shouldAttach =
        widget.shaderController?.backendKind == ShaderBackendKind.flutterGpu;
    if (shouldAttach) {
      if (!_gpuWatchdog.isFrameTimingsAttached) {
        _gpuWatchdog.attachFrameTimingsCallback();
        _attachedFrameTimingsToWatchdog = true;
      }
      return;
    }
    if (_attachedFrameTimingsToWatchdog) {
      _gpuWatchdog.detachFrameTimingsCallback();
      _attachedFrameTimingsToWatchdog = false;
    }
  }

  void _invalidateDirectBatchCache() {
    _directBatchInvalidationEpoch++;
    _cachedStaticBatch = null;
    _cachedDirectBatch = null;
    _cachedRegionMasks = null;
    _cachedRegionLayouts = null;
  }

  void _onShaderControllerChanged() {
    if (!mounted) return;
    _invalidateDirectBatchCache();
    final ctrl = widget.shaderController;
    _cliShaderRegistry.attachBackend(ctrl?.backend);
    _syncWatchdogFrameTimings();
    _ensureRegionShadersCompiled(_activeBuffer);
  }

  void _onWatchdogShaderQuarantined(String shaderId, String reason) {
    if (!mounted) return;
    _cliShaderRegistry.quarantineShader(shaderId, reason);
    widget.onCliShaderQuarantined?.call(shaderId, reason);
    _paintNotifier.notify();
  }

  Duration _readCurrentTweenStamp() {
    final customClock = widget.tweenClock;
    final raw = customClock != null
        ? customClock()
        : SchedulerBinding.instance.currentSystemFrameTimeStamp;
    if (raw >= _lastTweenStamp) {
      _lastTweenStamp = raw;
    }
    return _lastTweenStamp;
  }

  double _nowTweenSec(Duration stamp) => stamp.inMicroseconds / 1e6;

  void _syncCellTransformsAndRegions(Buffer? buf, {bool force = false}) {
    if (buf == null) {
      _lastSyncedTransformBuf = null;
      _lastSyncedTweenStamp = null;
      _lastSyncedTransformRev = -1;
      _lastSyncedRegionRev = -1;
      _cellTransformAnimator.reset();
      _cellOverrideMask = null;
      _overrideMaskHash = 0;
      _gpuWatchdog.setActiveBuiltinPresets(false);
      _syncTweenTicker();
      return;
    }
    final frameStamp = _readCurrentTweenStamp();
    if (!force &&
        identical(buf, _lastSyncedTransformBuf) &&
        frameStamp == _lastSyncedTweenStamp &&
        buf.transformRevision == _lastSyncedTransformRev &&
        buf.regionRevision == _lastSyncedRegionRev) {
      return;
    }
    _lastSyncedTransformBuf = buf;
    _lastSyncedTweenStamp = frameStamp;
    _lastSyncedTransformRev = buf.transformRevision;
    _lastSyncedRegionRev = buf.regionRevision;

    _cellTransformAnimator.evaluate(
      table: buf.cellTransforms,
      cols: buf.width,
      rows: buf.height,
      nowSec: _nowTweenSec(frameStamp),
    );
    final replaceRegions = _collectActiveReplaceRegions(buf);
    _cellOverrideMask = _overrideMaskBuilder.build(
      cols: buf.width,
      rows: buf.height,
      activeTransforms: _cellTransformAnimator.activePoses,
      replaceRegions: replaceRegions,
    );
    _overrideMaskHash = _overrideMaskBuilder.lastMaskHash;
    _gpuWatchdog.setActiveBuiltinPresets(_hasActiveBuiltinPresetRegions(buf));
    _syncTweenTicker();
    _ensureRegionShadersCompiled(buf);
  }

  bool _hasActiveBuiltinPresetRegions(Buffer buf) {
    if (!buf.hasShaderRegions) return false;
    for (final region in buf.shaderRegions) {
      if (ShaderRegionPresets.isPreset(region.shaderId)) return true;
    }
    return false;
  }

  List<ShaderRegion> _collectActiveReplaceRegions(Buffer buf) {
    if (!buf.hasShaderRegions) return const <ShaderRegion>[];
    List<ShaderRegion>? list;
    for (final region in buf.shaderRegions) {
      if (region.stage == ShaderRegionStage.replaceGlyphs &&
          !_cliShaderRegistry.isQuarantined(region.shaderId)) {
        (list ??= <ShaderRegion>[]).add(region);
      }
    }
    return list ?? const <ShaderRegion>[];
  }

  void _ensureRegionShadersCompiled(Buffer? buf) {
    if (buf == null || !buf.hasShaderRegions) return;
    final ctrl = widget.shaderController;
    if (ctrl == null || !ctrl.supportsCustomGlsl) return;
    for (final region in buf.shaderRegions) {
      if (_cliShaderRegistry.handleForShader(region.shaderId) != null) continue;
      if (_cliShaderRegistry.isQuarantined(region.shaderId)) continue;
      unawaited(
        _cliShaderRegistry
            .ensureRegionShaderCompiled(region)
            .catchError((Object _) => null),
      );
    }
  }

  void _syncTweenTicker() {
    if (_cellTransformAnimator.hasActiveTweens) {
      final ticker = _tweenTicker ??= createTicker(_onTweenTick);
      if (!ticker.isActive) {
        ticker.start();
      }
      return;
    }
    if (_tweenTicker != null && _tweenTicker!.isActive) {
      _tweenTicker!.stop();
    }
  }

  void _notifyDirectSurfaceVisualChange() {
    _invalidateDirectBatchCache();
    _paintNotifier.notify();
  }

  void _onTweenTick(Duration _) {
    if (!mounted) {
      _tweenTicker?.stop();
      return;
    }
    _syncCellTransformsAndRegions(_activeBuffer);
    _paintNotifier.notifyTransformTick();
  }

  Uint8List? _readCellOverrideMask() => _cellOverrideMask;

  List<EvaluatedCellEntry> _readTransformedCells() =>
      _cellTransformAnimator.sortedEntries;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) {
      _latchedClearedModifiers.addAll(
        HardwareKeyboard.instance.logicalKeysPressed,
      );
      _syncLinkModifierState();
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
    _gestureMachine = _createGestureMachine();
  }

  SelectionGestureMachine _createGestureMachine() => SelectionGestureMachine(
    controller: _selectionController,
    onCopySelection: _copySelectedBufferText,
    onOpenUrl: (uri) => unawaited(widget.service.openUrl(uri)),
    onEdgeAutoScroll: widget.onSelectionAutoScroll != null
        ? _handleEdgeAutoScroll
        : null,
  );

  void _initImeClient() {
    _ownsImeClient = widget.imeClient == null;
    _imeClient =
        widget.imeClient ??
        TerminalImeClient(
          macosOptionAsAlt: widget.macosOptionAsAlt,
          metaKeyPolicy: widget.metaKeyPolicy,
          routePrintableThroughIme: widget.enableIme,
        );
    _bindImeClient();
  }

  void _bindImeClient() {
    _imeClient
      ..macosOptionAsAlt = widget.macosOptionAsAlt
      ..metaKeyPolicy = widget.metaKeyPolicy
      ..routePrintableThroughIme = widget.enableIme
      ..bindSurfaceHandlers(
        kittyKeyboardFlags: () => _effectiveKittyFlags,
        reportKeyReleaseEvents: () => _effectiveReportKeyRelease,
        onKeyEvent: _injectInputEvent,
        onTextInput: widget.onTextInput,
        onHostShortcut: _handleHostShortcut,
        onModifiersChanged: _syncLinkModifierState,
        modifiersProvider: _collectEffectiveModifiers,
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
      _notifyDirectSurfaceVisualChange();
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
      final dprChanged =
          dpr.isFinite && dpr > 0.0 && _atlasController.devicePixelRatio != dpr;
      final configChanged =
          _atlasController.fontSize != widget.fontSize ||
          _atlasController.fontFamily != widget.fontFamily ||
          !listEquals(
            _atlasController.fontFamilyFallback,
            widget.fontFamilyFallback,
          ) ||
          dprChanged;
      if (_atlasController.atlas == null || configChanged) {
        unawaited(
          _atlasController.updateConfig(
            fontSize: widget.fontSize,
            fontFamily: widget.fontFamily,
            fontFamilyFallback: widget.fontFamilyFallback,
            updateFallbackList: true,
            devicePixelRatio: dpr,
          ),
        );
      }
    } else if (media != null &&
        dpr.isFinite &&
        dpr > 0.0 &&
        _atlasController.devicePixelRatio != dpr) {
      unawaited(_atlasController.setDevicePixelRatio(dpr));
    }
    if (_atlasController.atlas == null) {
      unawaited(_atlasController.ensureInitialized());
    }
    _syncTerminalCellMetrics();
    final nextViewId =
        View.maybeOf(context)?.viewId ??
        WidgetsBinding.instance.platformDispatcher.implicitView?.viewId;
    final viewIdChanged = _imeViewId != nextViewId;
    _imeViewId = nextViewId;
    if (widget.enableIme &&
        _focusNode.hasFocus &&
        (!_imeClient.isAttached || viewIdChanged)) {
      _attachIme();
      _scheduleGeometrySync();
    }
  }

  @override
  void didUpdateWidget(TerminalSurface oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_didDirectBatchPropsChange(oldWidget)) {
      _invalidateDirectBatchCache();
    }
    _syncAtlasControllerBinding(oldWidget);
    _syncFocusAndImeBindings(oldWidget);
    _syncTerminalAndBufferBindings(oldWidget);
    _syncThemeAndModeBindings(oldWidget);
    _syncCliShaderAndWatchdogBindings(oldWidget);
    _syncSearchHighlightsBinding(oldWidget);
  }

  bool _didDirectBatchPropsChange(TerminalSurface oldWidget) =>
      _didDirectBatchSourcePropsChange(oldWidget) ||
      _didDirectBatchStylePropsChange(oldWidget);

  bool _didDirectBatchSourcePropsChange(TerminalSurface oldWidget) =>
      !identical(oldWidget.buffer, widget.buffer) ||
      !identical(oldWidget.terminal, widget.terminal) ||
      !identical(oldWidget.atlasController, widget.atlasController) ||
      !identical(oldWidget.selectionController, widget.selectionController) ||
      !identical(oldWidget.shaderController, widget.shaderController) ||
      !identical(oldWidget.cliShaderRegistry, widget.cliShaderRegistry) ||
      oldWidget.activePtySize != widget.activePtySize ||
      oldWidget.cursorPosition != widget.cursorPosition ||
      oldWidget.cursorStyle != widget.cursorStyle ||
      oldWidget.cursorVisible != widget.cursorVisible ||
      oldWidget.enableLigatures != widget.enableLigatures ||
      oldWidget.enableBuiltinSelection != widget.enableBuiltinSelection ||
      oldWidget.topVirtualRow != widget.topVirtualRow ||
      !identical(
        oldWidget.topVirtualRowProvider,
        widget.topVirtualRowProvider,
      ) ||
      !identical(
        oldWidget.selectionEpochProvider,
        widget.selectionEpochProvider,
      );

  bool _didDirectBatchStylePropsChange(TerminalSurface oldWidget) =>
      oldWidget.fontSize != widget.fontSize ||
      oldWidget.fontFamily != widget.fontFamily ||
      !listEquals(oldWidget.fontFamilyFallback, widget.fontFamilyFallback) ||
      oldWidget.backgroundColor != widget.backgroundColor ||
      oldWidget.foregroundColor != widget.foregroundColor ||
      oldWidget.backgroundOpacity != widget.backgroundOpacity ||
      oldWidget.faintOpacity != widget.faintOpacity ||
      oldWidget.palette != widget.palette ||
      oldWidget.outOfBoundsDimColor != widget.outOfBoundsDimColor ||
      oldWidget.shaderConfig != widget.shaderConfig ||
      oldWidget.hoveredLinkStyler != widget.hoveredLinkStyler;

  void _syncCliShaderAndWatchdogBindings(TerminalSurface oldWidget) {
    if (!identical(oldWidget.shaderController, widget.shaderController)) {
      oldWidget.shaderController?.removeListener(_onShaderControllerChanged);
      widget.shaderController?.addListener(_onShaderControllerChanged);
    }
    if (!identical(oldWidget.gpuFrameWatchdog, widget.gpuFrameWatchdog)) {
      if (_attachedFrameTimingsToWatchdog) {
        _gpuWatchdog.detachFrameTimingsCallback();
        _attachedFrameTimingsToWatchdog = false;
      }
      if (_ownsGpuWatchdog) {
        _gpuWatchdog.dispose();
      }
      _ownsGpuWatchdog = widget.gpuFrameWatchdog == null;
      _gpuWatchdog =
          widget.gpuFrameWatchdog ??
          GpuFrameWatchdog(
            warmupFrameCount: GpuFrameWatchdog.recommendedWarmupFrameCount,
            isBuiltinPreset: ShaderRegionPresets.isPreset,
            onShaderQuarantined: _onWatchdogShaderQuarantined,
          );
    }
    _syncWatchdogFrameTimings();
    if (!identical(oldWidget.cliShaderRegistry, widget.cliShaderRegistry)) {
      if (_ownsCliShaderRegistry) {
        _cliShaderRegistry.dispose();
      }
      _ownsCliShaderRegistry = widget.cliShaderRegistry == null;
      _cliShaderRegistry =
          widget.cliShaderRegistry ??
          CliShaderRegistry(
            backend: widget.shaderController?.backend,
            watchdog: _gpuWatchdog,
          );
    }
    _cliShaderRegistry.attachWatchdog(_gpuWatchdog);
    _cliShaderRegistry.attachBackend(widget.shaderController?.backend);
    _syncCellTransformsAndRegions(_activeBuffer);
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
      final dpr = media?.devicePixelRatio ?? 1.0;
      if (media != null &&
          dpr.isFinite &&
          dpr > 0.0 &&
          _atlasController.devicePixelRatio != dpr) {
        unawaited(_atlasController.setDevicePixelRatio(dpr));
      }
      if (_atlasController.atlas == null) {
        unawaited(_atlasController.ensureInitialized());
      }
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
      _attachIme();
      _scheduleGeometrySync();
    }

    if (oldWidget.selectionController != widget.selectionController) {
      _gestureMachine.dispose();
      _selectionController.removeListener(_onSelectionChanged);
      if (_ownsSelectionController) {
        _selectionController.dispose();
      }
      _ownsSelectionController = widget.selectionController == null;
      _selectionController =
          widget.selectionController ?? TerminalSelectionController();
      _selectionController.addListener(_onSelectionChanged);
      _gestureMachine = _createGestureMachine();
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
      final next = widget.bufferListenable;
      next?.addListener(_onExternalBufferChanged);
      _lastExternalCellContentRevision = next is TerminalBufferChangeSignal
          ? next.cellContentRevision
          : -1;
    }

    _syncBufferResourcesOnUpdate(oldWidget);
  }

  void _syncBufferResourcesOnUpdate(TerminalSurface oldWidget) {
    _syncVirtualScrollSelection();
    final activeBuf = _activeBuffer;
    final alreadyPrepared = identical(activeBuf, _externallyPreparedBuffer);
    _externallyPreparedBuffer = null;
    final bindingsChanged =
        oldWidget.buffer != widget.buffer ||
        oldWidget.bufferProvider != widget.bufferProvider ||
        oldWidget.cursorPosition != widget.cursorPosition;
    if (bindingsChanged ||
        oldWidget.linkLineLookup != widget.linkLineLookup ||
        oldWidget.enableBuiltinLinkOpen != widget.enableBuiltinLinkOpen ||
        widget.bufferListenable == null) {
      if (_refreshHoverLinkForBufferChange()) {
        _syncLinkHoverTicker();
      }
    }
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
    if (oldWidget.enableRowCache != widget.enableRowCache) {
      _stagingCache.invalidateAllRows();
    }
    _syncComposingPainter();
    _gestureMachine.onEdgeAutoScroll = widget.onSelectionAutoScroll != null
        ? _handleEdgeAutoScroll
        : null;
    if (oldWidget.enableBuiltinSelection && !widget.enableBuiltinSelection) {
      _gestureMachine.dispatch(.reset);
    }
    if (oldWidget.enableBuiltinLinkOpen && !widget.enableBuiltinLinkOpen) {
      _hoveredLinkDetail = null;
      _lastHoverCell = null;
      _hoverLinkResolved = false;
      _isLinkModifierActive = false;
      _gestureMachine.disarmLinks();
      _stopLinkHoverTicker();
    } else if (oldWidget.hoveredLinkStyler != widget.hoveredLinkStyler ||
        oldWidget.hoveredLinkAnimationInterval !=
            widget.hoveredLinkAnimationInterval ||
        oldWidget.enableBuiltinLinkOpen != widget.enableBuiltinLinkOpen) {
      _stopLinkHoverTicker();
      _syncLinkHoverTicker();
    }
  }

  @override
  void dispose() {
    _stopLinkHoverTicker();
    _disposeCliShaderAndWatchdog();
    WidgetsBinding.instance.removeObserver(this);
    HardwareKeyboard.instance.removeHandler(_onHardwareKeyEvent);
    widget.bufferListenable?.removeListener(_onExternalBufferChanged);
    widget.searchHighlightsListenable?.removeListener(
      _onSearchHighlightsChanged,
    );
    _searchOverlayRepaint = null;
    _cancelTerminalStreams();
    _disposeOwnedControllers();
    _disposeComposingPainter();
    _kittyCache.dispose();
    _paintNotifier.dispose();
    _shaderMouseNotifier.dispose();
    super.dispose();
  }

  void _disposeCliShaderAndWatchdog() {
    _tweenTicker?.dispose();
    _tweenTicker = null;
    widget.shaderController?.removeListener(_onShaderControllerChanged);
    if (_ownsCliShaderRegistry) {
      _cliShaderRegistry.dispose();
    }
    if (_attachedFrameTimingsToWatchdog) {
      _gpuWatchdog.detachFrameTimingsCallback();
      _attachedFrameTimingsToWatchdog = false;
    }
    if (_ownsGpuWatchdog) {
      _gpuWatchdog.dispose();
    }
  }

  void _disposeOwnedControllers() {
    _focusNode.removeListener(_onFocusChanged);
    if (_ownsFocusNode) {
      _focusNode.dispose();
    }
    _unbindImeClient(_imeClient);
    if (_ownsImeClient) {
      _imeClient.dispose();
    }
    _gestureMachine.dispose();
    _selectionController.removeListener(_onSelectionChanged);
    if (_ownsSelectionController) {
      _selectionController.dispose();
    }
    _atlasController.removeListener(_onAtlasChanged);
    if (_ownsAtlasController) {
      _atlasController.dispose();
    }
  }

  void _disposeComposingPainter() {
    _composingPainter?.dispose();
    _composingPainter = null;
    _composingPainterText = '';
    _composingPainterFontFamily = '';
    _composingPainterFontFallback = null;
    _composingPainterFontSize = 0.0;
    _composingPainterColorArgb = 0;
  }

  void _syncComposingPainter() {
    final text = widget.enableIme ? _imeClient.composingText : '';
    final atlas = _atlasController.atlas;
    if (text.isEmpty || atlas == null) {
      if (_composingPainter != null) _disposeComposingPainter();
      return;
    }
    final fontFamily = _atlasController.fontFamily;
    final fontFallback = _atlasController.fontFamilyFallback;
    final fontSize = atlas.fontSize;
    final colorArgb = widget.foregroundColor.toARGB32();
    if (_composingPainter != null &&
        _composingPainterText == text &&
        _composingPainterFontFamily == fontFamily &&
        listEquals(_composingPainterFontFallback, fontFallback) &&
        _composingPainterFontSize == fontSize &&
        _composingPainterColorArgb == colorArgb) {
      return;
    }
    _composingPainter?.dispose();
    _composingPainter = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          fontFamily: fontFamily,
          fontFamilyFallback: fontFallback,
          fontSize: fontSize,
          color: widget.foregroundColor,
          height: 1.0,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    _composingPainterText = text;
    _composingPainterFontFamily = fontFamily;
    _composingPainterFontFallback = fontFallback == null
        ? null
        : List<String>.unmodifiable(fontFallback);
    _composingPainterFontSize = fontSize;
    _composingPainterColorArgb = colorArgb;
  }

  void _onAtlasChanged() {
    if (!mounted) return;
    _invalidateDirectBatchCache();
    _syncTerminalCellMetrics();
    _syncComposingPainter();
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
    _syncVirtualScrollSelection();
    final buf = _activeBuffer;
    final hasBuf = buf != null;
    final activePty =
        widget.activePtySizeProvider?.call() ?? widget.activePtySize;
    final cursor =
        widget.cursorPositionProvider?.call() ?? widget.cursorPosition;
    final cursorMoved = cursor != _lastCursorPosition;
    _lastCursorPosition = cursor;

    final listenable = widget.bufferListenable;
    var overlayOnly = false;
    if (listenable is TerminalBufferChangeSignal) {
      final cellRev = listenable.cellContentRevision;
      overlayOnly =
          cellRev == _lastExternalCellContentRevision &&
          hasBuf &&
          _hadActiveBuffer &&
          identical(buf, _lastPaintedBuffer) &&
          activePty == _lastPaintedActivePtySize &&
          !cursorMoved;
      _lastExternalCellContentRevision = cellRev;
    }
    if (overlayOnly) {
      _syncCellTransformsAndRegions(buf, force: true);
      _paintNotifier.notifyTransformTick();
      return;
    }

    _bufferResourcesDirty = true;
    _syncCellTransformsAndRegions(buf, force: true);
    if (cursorMoved) {
      _scheduleGeometrySync();
    }

    final linkChanged = _refreshHoverLinkForBufferChange();
    if (linkChanged) {
      _syncLinkHoverTicker();
    }
    final needsWidgetRebuild =
        linkChanged ||
        !hasBuf ||
        !_hadActiveBuffer ||
        !identical(buf, _lastPaintedBuffer) ||
        activePty != _lastPaintedActivePtySize ||
        (_imeClient.composingText.isNotEmpty && cursorMoved);

    if (needsWidgetRebuild) {
      _directPaintVersion++;
      setState(() {});
      return;
    }
    _paintNotifier.notify();
  }

  void _onImeComposingChanged() {
    if (!mounted) return;
    _invalidateDirectBatchCache();
    _syncComposingPainter();
    setState(() {});
    _scheduleGeometrySync();
  }

  bool _readHasSearchHighlights() =>
      widget.searchHighlightsProvider?.call().isNotEmpty ?? false;

  void _rebuildSearchOverlayRepaint() {
    final listenable = widget.searchHighlightsListenable;
    _searchOverlayRepaint = listenable == null
        ? _paintNotifier
        : Listenable.merge(<Listenable>[_paintNotifier, listenable]);
  }

  void _syncSearchHighlightsBinding(TerminalSurface oldWidget) {
    if (!identical(
      oldWidget.searchHighlightsListenable,
      widget.searchHighlightsListenable,
    )) {
      oldWidget.searchHighlightsListenable?.removeListener(
        _onSearchHighlightsChanged,
      );
      widget.searchHighlightsListenable?.addListener(
        _onSearchHighlightsChanged,
      );
      _rebuildSearchOverlayRepaint();
    }
    _hasSearchHighlights = _readHasSearchHighlights();
    if (_hasSearchHighlights &&
        oldWidget.topVirtualRow != widget.topVirtualRow) {
      _paintNotifier.notify();
    }
  }

  void _onSearchHighlightsChanged() {
    if (!mounted) return;
    final next = _readHasSearchHighlights();
    if (next != _hasSearchHighlights) {
      setState(() {
        _hasSearchHighlights = next;
      });
    }
  }

  void _onFocusChanged() {
    final hasFocus = _focusNode.hasFocus;
    if (widget.enableIme) {
      if (hasFocus) {
        _attachIme();
        _scheduleGeometrySync();
      } else {
        _imeClient.detach();
      }
    }
    widget.onFocusChanged?.call(hasFocus);
    if (mounted && _hasShaderBinding) {
      setState(() {});
    }
  }

  bool get _hasShaderBinding =>
      widget.shaderConfig != null || widget.shaderController != null;

  double get _effectiveBackgroundOpacity {
    final surfaceOpacity = widget.backgroundOpacity.isFinite
        ? widget.backgroundOpacity.clamp(0.0, 1.0)
        : 1.0;
    final configOpacity = widget.shaderConfig?.backgroundOpacity;
    if (configOpacity == null || !configOpacity.isFinite) {
      return surfaceOpacity;
    }
    return math.min(surfaceOpacity, configOpacity.clamp(0.0, 1.0));
  }

  Color get _effectiveBackgroundColor {
    final opacity = _effectiveBackgroundOpacity;
    if (opacity >= 1.0) return widget.backgroundColor;
    return widget.backgroundColor.withValues(
      alpha: widget.backgroundColor.a * opacity,
    );
  }

  Uint32List _resolvePalette256Argb() {
    final existing = _cachedPalette256Argb;
    if (existing != null && identical(_cachedPaletteTheme, widget.palette)) {
      return existing;
    }
    final table = Uint32List(TerminalShaderUniforms.paletteLength);
    for (var i = 0; i < table.length; i++) {
      table[i] = widget.palette.resolveAnsi256(i).argb;
    }
    _cachedPaletteTheme = widget.palette;
    _cachedPalette256Argb = table;
    return table;
  }

  Rect? _readCursorRectLogical() {
    final atlas = _atlasController.atlas;
    if (atlas == null) return null;
    final cursor =
        widget.cursorPositionProvider?.call() ?? widget.cursorPosition;
    if (cursor == null || atlas.cellWidth <= 0 || atlas.cellHeight <= 0) {
      return null;
    }
    return Rect.fromLTWH(
      cursor.col * atlas.cellWidth,
      cursor.row * atlas.cellHeight,
      atlas.cellWidth,
      atlas.cellHeight,
    );
  }

  TextInputConfiguration _resolveImeConfiguration() {
    final viewId =
        _imeViewId ??
        WidgetsBinding.instance.platformDispatcher.implicitView?.viewId;
    return TerminalImeClient.defaultInputConfiguration.copyWith(viewId: viewId);
  }

  void _attachIme() {
    _imeClient.attach(_resolveImeConfiguration());
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
      _gestureMachine.dispatch(.reset);
    }
    _notifyDirectSurfaceVisualChange();
    setState(() {
      _terminalBuiltinSelection = enabled;
    });
  }

  void _onTerminalBuiltinLinkOpenChanged(bool enabled) {
    if (!mounted) return;
    if (!enabled) {
      _hoveredLinkDetail = null;
      _lastHoverCell = null;
      _hoverLinkResolved = false;
      _isLinkModifierActive = false;
      _gestureMachine.disarmLinks();
      _stopLinkHoverTicker();
    }
    setState(() {
      _terminalBuiltinLinkOpen = enabled;
      if (enabled) {
        _refreshHoverLinkForBufferChange();
        _syncLinkHoverTicker();
      }
    });
  }

  void _flushDirtyBufferResources() {
    if (!mounted) return;
    _syncCellTransformsAndRegions(_activeBuffer);
    if (!_bufferResourcesDirty) return;
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

  HostShortcutResult _handleHostShortcut(
    KeyEvent event,
    Set<term.Modifier> mods,
  ) {
    final hostResult = widget.onHostShortcut?.call(event, mods) ?? .unhandled;
    if (hostResult != .unhandled) {
      return hostResult;
    }
    if (!widget.enableHostShortcuts) {
      return .unhandled;
    }
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.f12) {
      if (_isShiftPressed) {
        unawaited(_atlasController.recreateAtlas());
      } else {
        unawaited(_performTakeScreenshot());
      }
      return .handled;
    }
    if (_builtinSelectionEnabled &&
        _selectionController.hasSelection &&
        isTerminalCopyShortcut(key, mods)) {
      if (event is KeyDownEvent) {
        _gestureMachine.dispatch(.copyShortcut);
      }
      return .handled;
    }
    if (isTerminalPasteShortcut(key, mods)) {
      unawaited(_pasteFromClipboard());
      return .handled;
    }
    return .unhandled;
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

  bool _isKeyPressed(LogicalKeyboardKey key) =>
      !_latchedClearedModifiers.contains(key) &&
      HardwareKeyboard.instance.isLogicalKeyPressed(key);

  bool get _isControlPressed =>
      _isKeyPressed(.controlLeft) || _isKeyPressed(.controlRight);

  bool get _isShiftPressed =>
      _isKeyPressed(.shiftLeft) || _isKeyPressed(.shiftRight);

  bool get _isAltPressed => _isKeyPressed(.altLeft) || _isKeyPressed(.altRight);

  bool get _isMetaPressed =>
      _isKeyPressed(.metaLeft) || _isKeyPressed(.metaRight);

  Set<term.Modifier> _collectEffectiveModifiers() => {
    if (_isShiftPressed) term.Modifier.shift,
    if (_isAltPressed) term.Modifier.alt,
    if (_isControlPressed) term.Modifier.control,
    if (_isMetaPressed) term.Modifier.meta,
  };

  bool _isLinkOpenModifierPressed() =>
      // Exclude Shift/Alt so Ctrl+Shift (forced selection) and Alt+Click (block
      // selection) remain unaffected.
      (_isControlPressed || _isMetaPressed) &&
      !_isShiftPressed &&
      !_isAltPressed;

  bool get _isMacCtrlRightClick =>
      defaultTargetPlatform == TargetPlatform.macOS &&
      _isControlPressed &&
      !_isShiftPressed &&
      !_isAltPressed &&
      !_isMetaPressed;

  bool _onHardwareKeyEvent(KeyEvent event) {
    _latchedClearedModifiers.remove(event.logicalKey);
    // Sync modifier state even when this pane does not yet hold keyboard focus
    // so stationary Ctrl/Cmd hover feedback updates across unfocused panes.
    _syncLinkModifierState();
    return false;
  }

  bool get _isLinkHovered =>
      _builtinLinkOpenEnabled && _hoveredLink != null && _isLinkModifierActive;

  bool get _shouldRunHoverTicker {
    final interval = widget.hoveredLinkAnimationInterval;
    return _isLinkHovered &&
        widget.hoveredLinkStyler != null &&
        interval != null &&
        interval > Duration.zero;
  }

  void _syncLinkHoverTicker() {
    if (!_shouldRunHoverTicker || !mounted) {
      _stopLinkHoverTicker();
      return;
    }
    if (_linkHoverTimer != null) return;
    _linkHoverTimer = Timer.periodic(widget.hoveredLinkAnimationInterval!, (_) {
      if (!mounted || !_shouldRunHoverTicker) {
        _stopLinkHoverTicker();
        return;
      }
      _notifyDirectSurfaceVisualChange();
    });
  }

  void _stopLinkHoverTicker() {
    _linkHoverTimer?.cancel();
    _linkHoverTimer = null;
  }

  static bool _linkDetailsEqual(
    ResolvedTerminalLinkDetail? a,
    ResolvedTerminalLinkDetail? b,
  ) => a?.link == b?.link && listEquals(a?.rowSpans, b?.rowSpans);

  bool _refreshHoverLinkForBufferChange() {
    _hoverLinkResolved = false;
    final prevDetail = _hoveredLinkDetail;
    final prevMod = _isLinkModifierActive;
    final hoverCell = _lastHoverCell;
    final linkMod = _isLinkOpenModifierPressed();
    if (!_builtinLinkOpenEnabled ||
        _gestureMachine.isSelectingGesture ||
        hoverCell == null ||
        !linkMod) {
      _hoveredLinkDetail = null;
      _isLinkModifierActive = _builtinLinkOpenEnabled && linkMod;
      return !_linkDetailsEqual(_hoveredLinkDetail, prevDetail) ||
          _isLinkModifierActive != prevMod;
    }
    _hoveredLinkDetail = _resolveLinkDetailAt(
      _activeBuffer,
      hoverCell.col,
      hoverCell.row,
    );
    _hoverLinkResolved = true;
    _isLinkModifierActive = true;
    return !_linkDetailsEqual(_hoveredLinkDetail, prevDetail) || !prevMod;
  }

  void _syncLinkModifierState() {
    if (!_builtinLinkOpenEnabled) return;
    final pressed = _isLinkOpenModifierPressed();
    if (pressed == _isLinkModifierActive) return;
    final prevDetail = _hoveredLinkDetail;
    _isLinkModifierActive = pressed;
    if (!pressed) {
      _hoveredLinkDetail = null;
      _hoverLinkResolved = false;
    } else if (_lastHoverCell case final cell?
        when !_gestureMachine.isSelectingGesture && !_hoverLinkResolved) {
      _hoveredLinkDetail = _resolveLinkDetailAt(
        _activeBuffer,
        cell.col,
        cell.row,
      );
      _hoverLinkResolved = true;
    }
    _syncLinkHoverTicker();
    if (mounted &&
        (!_linkDetailsEqual(_hoveredLinkDetail, prevDetail) ||
            _hoveredLinkDetail != null)) {
      _notifyDirectSurfaceVisualChange();
      setState(() {});
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
    _hoverLinkResolved = false;

    final (col, row, _) = _clampCellToActiveGrid(
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
    final mods = _collectEffectiveModifiers();

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
    _syncVirtualScrollSelection();
  }

  (int, int, int) _clampCellToActiveGrid(
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
    return (
      rawCol.clamp(0, effCols - 1),
      rawRow.clamp(0, effRows - 1),
      effRows,
    );
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

  ({int col, int row, int rawRow, int effRows, int pixelX, int pixelY})?
  _resolvePointerCoords(PointerEvent event, Size layoutSize) {
    final atlas = _atlasController.atlas;
    if (atlas == null) return null;
    final maxCol = (layoutSize.width / atlas.cellWidth).floor();
    final maxRow = (layoutSize.height / atlas.cellHeight).floor();
    if (maxCol <= 0 || maxRow <= 0) return null;

    final rawCol = (event.localPosition.dx / atlas.cellWidth).floor();
    final rawRow = (event.localPosition.dy / atlas.cellHeight).floor();
    final (clampedCol, clampedRow, effRows) = _clampCellToActiveGrid(
      rawCol,
      rawRow,
      maxCol,
      maxRow,
    );
    return (
      col: clampedCol,
      row: clampedRow,
      rawRow: rawRow,
      effRows: effRows,
      pixelX: event.localPosition.dx.floor().clamp(0, 100000) + 1,
      pixelY: event.localPosition.dy.floor().clamp(0, 100000) + 1,
    );
  }

  Size? _resolveLogicalLayoutSize() {
    final cached = _lastLayoutSize;
    if (cached != null && !cached.isEmpty) return cached;
    final renderObject = context.findRenderObject();
    if (renderObject is RenderBox &&
        renderObject.hasSize &&
        !renderObject.size.isEmpty) {
      return renderObject.size;
    }
    return null;
  }

  void _publishShaderPointer(double lx, double ly) {
    final sign = _shaderPrimaryButtonDown ? 1.0 : -1.0;
    final clickZ = _shaderHasPointerClick ? sign * _shaderClickLogicalX : 0.0;
    final clickW = _shaderHasPointerClick ? sign * _shaderClickLogicalY : 0.0;
    _shaderMouseNotifier.update(
      lx,
      ly,
      clickZ,
      clickW,
      notify: _hasShaderBinding,
    );
  }

  void _updateShaderPointerState(PointerEvent event) {
    final lx = event.localPosition.dx;
    final ly = event.localPosition.dy;
    _syncShaderPointerButtons(event, lx, ly);
    _publishShaderPointer(lx, ly);
  }

  void _syncShaderPointerButtons(PointerEvent event, double lx, double ly) {
    if (event is PointerDownEvent) {
      if ((event.buttons & kPrimaryMouseButton) != 0) {
        _shaderHasPointerClick = true;
        _shaderPrimaryButtonDown = true;
        _shaderClickLogicalX = math.max(lx, 1e-3);
        _shaderClickLogicalY = math.max(ly, 1e-3);
      }
      return;
    }
    if (event is PointerMoveEvent) {
      if ((event.buttons & kPrimaryMouseButton) == 0) {
        _shaderPrimaryButtonDown = false;
      }
      return;
    }
    _shaderPrimaryButtonDown = false;
  }

  void _handlePointerEvent(PointerEvent event, Size layoutSize) {
    _updateShaderPointerState(event);
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
    _updateSelectionAndUri(coords, termuiButton, termuiType);

    final suppressLeftPtyMouse =
        termuiButton == term.MouseButton.left &&
        _gestureMachine.consumeLeftPtySuppression(termuiType);
    final suppressRightLinkMouse = _gestureMachine.consumeRightLinkSuppression(
      termuiButton,
      termuiType,
    );
    if (suppressLeftPtyMouse || suppressRightLinkMouse) return;

    final termEvent = term.MouseEvent(
      x: coords.col + 1,
      y: coords.row + 1,
      pixelX: coords.pixelX,
      pixelY: coords.pixelY,
      button: termuiButton,
      type: termuiType,
      modifiers: _collectEffectiveModifiers(),
    );

    if (_isDuplicatePointerMotion(termEvent)) return;
    _lastInjectedPointerEvent = termEvent;
    _injectInputEvent(termEvent);
  }

  void _handlePointerCancel(PointerCancelEvent event, Size layoutSize) {
    _updateShaderPointerState(event);
    _resetScrollAccumulator();
    _lastPressedButton = term.MouseButton.left;
    _gestureMachine.dispatch(.pointerCancel);
    if (!_gestureMachine.consumeCancelPtyRelease()) return;

    final coords = _resolvePointerCoords(event, layoutSize);
    if (coords == null) return;
    final termEvent = term.MouseEvent(
      x: coords.col + 1,
      y: coords.row + 1,
      pixelX: coords.pixelX,
      pixelY: coords.pixelY,
      button: term.MouseButton.left,
      type: term.MouseEventType.release,
      modifiers: _collectEffectiveModifiers(),
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
    ({int col, int row, int rawRow, int effRows, int pixelX, int pixelY})
    coords,
    term.MouseButton button,
    term.MouseEventType type,
  ) {
    final (nextLink, uriChanged) = _updateHoveredLinkCell(
      coords.col,
      coords.row,
    );
    if (button == term.MouseButton.left) {
      _dispatchLeftPointerToHsm(coords, type, nextLink?.uri);
    } else if (button == term.MouseButton.right) {
      _dispatchRightPointerToHsm(coords, type, nextLink?.uri);
    }
    if (uriChanged && mounted) {
      _notifyDirectSurfaceVisualChange();
      setState(() {});
    }
  }

  void _dispatchLeftPointerToHsm(
    ({int col, int row, int rawRow, int effRows, int pixelX, int pixelY})
    coords,
    term.MouseEventType type,
    String? hoveredUri,
  ) {
    switch (type) {
      case .press:
        _gestureMachine.dispatch(
          .leftDown,
          _buildPointerDownPayload(coords.col, coords.row, hoveredUri),
        );
      case .drag:
        _gestureMachine.dispatch(
          .pointerDrag,
          _buildPointerDragPayload(coords),
        );
      case .release:
        _gestureMachine.dispatch(
          .leftUp,
          _buildPointerUpPayload(coords.col, coords.row, hoveredUri),
        );
      case .move:
        break;
    }
  }

  void _dispatchRightPointerToHsm(
    ({int col, int row, int rawRow, int effRows, int pixelX, int pixelY})
    coords,
    term.MouseEventType type,
    String? hoveredUri,
  ) {
    if (defaultTargetPlatform != TargetPlatform.macOS) return;
    switch (type) {
      case .press:
        _gestureMachine.dispatch(
          .rightDown,
          _buildPointerDownPayload(coords.col, coords.row, hoveredUri),
        );
      case .drag:
        if (_gestureMachine.state == .linkClicking) {
          _gestureMachine.dispatch(
            .pointerDrag,
            _buildPointerDragPayload(coords),
          );
        }
      case .release:
        _gestureMachine.dispatch(
          .rightUp,
          _buildPointerUpPayload(coords.col, coords.row, hoveredUri),
        );
      case .move:
        break;
    }
  }

  SelectionPointerDown _buildPointerDownPayload(
    int col,
    int row,
    String? hoveredUri,
  ) => (
    col: col,
    row: row,
    topVirtualRow: _effectiveTopVirtualRow,
    buffer: _activeBuffer,
    hoveredUri: hoveredUri,
    builtinSelectionEnabled: _builtinSelectionEnabled,
    builtinLinkOpenEnabled: _builtinLinkOpenEnabled,
    mouseTracking: _effectiveMouseTracking,
    openVerticalScrollback: _hasScrollbackBinding,
    isShift: _isShiftPressed,
    isAlt: _isAltPressed,
    isLinkModifier: _isLinkOpenModifierPressed(),
    isMacCtrlRightClick: _isMacCtrlRightClick,
    now: clock.now(),
  );

  SelectionPointerDrag _buildPointerDragPayload(
    ({int col, int row, int rawRow, int effRows, int pixelX, int pixelY})
    coords,
  ) => (
    col: coords.col,
    row: coords.row,
    rawRow: coords.rawRow,
    effRows: coords.effRows,
    topVirtualRow: _effectiveTopVirtualRow,
    buffer: _activeBuffer,
    builtinSelectionEnabled: _builtinSelectionEnabled,
    isAlt: _isAltPressed,
  );

  SelectionPointerUp _buildPointerUpPayload(
    int col,
    int row,
    String? hoveredUri,
  ) => (
    col: col,
    row: row,
    hoveredUri: hoveredUri,
    builtinSelectionEnabled: _builtinSelectionEnabled,
    builtinLinkOpenEnabled: _builtinLinkOpenEnabled,
    copyOnSelect: _effectiveCopyOnSelect,
    isLinkModifier: _isLinkOpenModifierPressed(),
  );

  void _syncVirtualScrollSelection() {
    if (widget.selectionEpochProvider case final epochProvider?) {
      final nextEpoch = epochProvider();
      if (nextEpoch != _lastSelectionEpoch) {
        _lastSelectionEpoch = nextEpoch;
        _lastTopVirtualRow = _effectiveTopVirtualRow;
        _gestureMachine.dispatch(.reset);
        return;
      }
    }
    final nextTopVirtual = _effectiveTopVirtualRow;
    if (nextTopVirtual == _lastTopVirtualRow) return;
    _lastTopVirtualRow = nextTopVirtual;
    if (_gestureMachine.isDraggingSelection) {
      _extendSelectionAfterScroll(nextTopVirtual);
    }
  }

  void _extendSelectionAfterScroll(int topVirtualRow) {
    final cell = _gestureMachine.lastDragScreenCell;
    if (cell == null) return;
    final buf = _activeBuffer;
    if (buf == null || buf.width <= 0 || buf.height <= 0) return;
    final (clampedCol, clampedRow, effRows) = _clampCellToActiveGrid(
      cell.col,
      cell.row,
      buf.width,
      buf.height,
    );
    _gestureMachine.dispatch(.pointerDrag, (
      col: clampedCol,
      row: clampedRow,
      rawRow: cell.rawRow,
      effRows: effRows,
      topVirtualRow: topVirtualRow,
      buffer: buf,
      builtinSelectionEnabled: _builtinSelectionEnabled,
      isAlt: _isAltPressed,
    ));
  }

  void _handleEdgeAutoScroll(int rowDelta) {
    final scroll = widget.onSelectionAutoScroll;
    if (!mounted ||
        scroll == null ||
        rowDelta == 0 ||
        !_gestureMachine.isDraggingSelection) {
      return;
    }
    final deltaLines = rowDelta < 0
        ? (-rowDelta).clamp(1, 6)
        : -rowDelta.clamp(1, 6);
    scroll(deltaLines);
    _syncVirtualScrollSelection();
  }

  (ResolvedTerminalLink?, bool) _updateHoveredLinkCell(int col, int row) {
    if (!_builtinLinkOpenEnabled) return (null, false);
    final cell = (col: col, row: row);
    if (_lastHoverCell != cell) {
      _lastHoverCell = cell;
      _hoverLinkResolved = false;
    }
    final linkMod = _isLinkOpenModifierPressed();
    if (!linkMod || _gestureMachine.isSelectingGesture) {
      final changed = _hoveredLink != null || linkMod != _isLinkModifierActive;
      _hoveredLinkDetail = null;
      _hoverLinkResolved = false;
      _isLinkModifierActive = linkMod;
      return (null, changed);
    }
    if (_hoverLinkResolved) {
      final changed = linkMod != _isLinkModifierActive;
      _isLinkModifierActive = linkMod;
      return (_hoveredLink, changed);
    }
    final nextDetail = _resolveLinkDetailAt(_activeBuffer, col, row);
    final nextLink = nextDetail?.link;
    final changed =
        !_linkDetailsEqual(nextDetail, _hoveredLinkDetail) ||
        linkMod != _isLinkModifierActive;
    _hoveredLinkDetail = nextDetail;
    _hoverLinkResolved = true;
    _isLinkModifierActive = linkMod;
    if (changed) {
      _syncLinkHoverTicker();
    }
    return (nextLink, changed);
  }

  ResolvedTerminalLinkDetail? _resolveLinkDetailAt(
    Buffer? buf,
    int col,
    int row,
  ) {
    if (buf == null ||
        col < 0 ||
        col >= buf.width ||
        row < 0 ||
        row >= buf.height) {
      return null;
    }
    final lookup =
        widget.linkLineLookup ?? (int vRow) => _bufferLineSlice(buf, vRow);
    final resolved = TerminalSelectionController.resolveLinkSpanDetailAt(
      lookup: lookup,
      col: col,
      virtualRow: row,
    );
    if (resolved == null) return null;
    final parsed = parseAllowedExternalUri(resolved.link.uri);
    if (parsed == null) return null;
    final link = resolved.link;
    return (
      link: (
        uri: '$parsed',
        startCol: link.startCol,
        startRow: link.startRow,
        endCol: link.endCol,
        endRow: link.endRow,
      ),
      rowSpans: resolved.rowSpans,
    );
  }

  static VirtualLineSlice? _bufferLineSlice(Buffer buf, int row) {
    if (row < 0 || row >= buf.height) return null;
    final start = row * buf.width;
    final end = start + buf.width;
    return (
      isWrapped: false,
      characters: buf.characters.sublist(start, end),
      uris: buf.sliceUris(start, end),
    );
  }

  void _handlePointerExit(PointerExitEvent event) {
    final hadHoveredLink = _hoveredLink != null;
    _hoveredLinkDetail = null;
    _lastHoverCell = null;
    _hoverLinkResolved = false;
    _stopLinkHoverTicker();
    if (hadHoveredLink && mounted) {
      _notifyDirectSurfaceVisualChange();
      setState(() {});
    }
    widget.onPointerExit?.call(event);
  }

  void _copySelectedBufferText() {
    final buf = _activeBuffer;
    final String selectedText;
    if (buf == null) {
      selectedText = '';
    } else if (widget.virtualLineLookup case final lookup?) {
      selectedText = _selectionController.extractVirtualText(
        lookup,
        cols: buf.width,
      );
    } else {
      selectedText = _selectionController.extractText(
        buf,
        includeHidden: true,
        topVirtualRow: _effectiveTopVirtualRow,
      );
    }
    _selectionController.clearSelection();
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
    _lastLayoutSize = layoutSize;
    return Focus(
      focusNode: _focusNode,
      autofocus: widget.autofocus,
      onKeyEvent: (_, event) => _imeClient.handleKeyEvent(event),
      child: ColoredBox(
        color: _effectiveBackgroundColor,
        child: Align(
          alignment: widget.alignment,
          child: RepaintBoundary(
            key: _boundaryKey,
            child: MouseRegion(
              cursor: _effectiveCursor,
              onExit: _handlePointerExit,
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

  TuiAtlasPainter _createAtlasPainter(
    Buffer buf, {
    required String composingText,
    required ({int col, int row})? cursor,
    required (int, int)? activePty,
    required Color effectiveBgColor,
  }) => TuiAtlasPainter(
    repaint: _paintNotifier,
    buffer: buf,
    atlas: _atlasController.atlas!,
    stagingCache: widget.enableRowCache ? _stagingCache : null,
    cellOverrideMaskProvider: _readCellOverrideMask,
    transformedCellsProvider: _readTransformedCells,
    cellTransformPainter: _cellTransformPainter,
    composingPainter: _composingPainter,
    fontFamily: _atlasController.fontFamily,
    fontFamilyFallback: _atlasController.fontFamilyFallback,
    fallbackPainters: _atlasController.fallbackPainters,
    onMissingGlyphs: null,
    onMissingStyledGlyphs: _atlasController.requestMissingStyledGlyphs,
    onBeforePaint: _flushDirtyBufferResources,
    enableBleed: widget.enableBleed,
    enableLigatures: _enableLigatures,
    ligaturePainters: _atlasController.ligaturePainters,
    selectionController: _builtinSelectionEnabled ? _selectionController : null,
    topVirtualRow: _effectiveTopVirtualRow,
    topVirtualRowProvider: _readEffectiveTopVirtualRow,
    hoveredLink: _isLinkHovered ? _hoveredLink : null,
    hoveredLinkRowSpans: _isLinkHovered ? _hoveredLinkDetail?.rowSpans : null,
    hoveredLinkStyler: widget.hoveredLinkStyler,
    kittyImages: _kittyCache.images,
    kittyImagesById: _kittyCache.imagesById,
    defaultForegroundArgb: widget.foregroundColor.toARGB32(),
    defaultBackgroundArgb: effectiveBgColor.toARGB32(),
    faintOpacity: widget.faintOpacity,
    palette: widget.palette,
    activePtyCols: activePty?.$1,
    activePtyRows: activePty?.$2,
    outOfBoundsDimColor: widget.outOfBoundsDimColor,
    composingText: composingText,
    cursorCol: cursor?.col ?? 0,
    cursorRow: cursor?.row ?? 0,
  );

  bool _canReuseStaticBatchCache({
    required Buffer buf,
    required GlyphAtlas atlas,
    required Size logicalSize,
    required double devicePixelRatio,
    required ({int col, int row})? cursor,
    required (int, int)? activePty,
  }) =>
      _cachedStaticBatch != null &&
      !_bufferResourcesDirty &&
      identical(buf, _cachedDirectBuf) &&
      identical(atlas, _cachedDirectAtlas) &&
      logicalSize == _cachedDirectSize &&
      devicePixelRatio == _cachedDirectDpr &&
      _directPaintVersion == _cachedDirectPaintVersion &&
      _paintNotifier.version == _cachedDirectNotifyVersion &&
      _directBatchInvalidationEpoch == _cachedDirectEpoch &&
      _overrideMaskHash == _cachedDirectOverrideHash &&
      cursor == _cachedDirectCursor &&
      activePty == _cachedDirectPtySize &&
      buf.regionRevision == _cachedDirectRegionRev &&
      buf.hasCellTransforms == _cachedDirectHasTransforms;

  bool _canReuseDirectBatchCache({
    required Buffer buf,
    required GlyphAtlas atlas,
    required Size logicalSize,
    required double devicePixelRatio,
    required ({int col, int row})? cursor,
    required (int, int)? activePty,
  }) =>
      _cachedDirectBatch != null &&
      !_cellTransformAnimator.hasActiveTweens &&
      _paintNotifier.transformTickVersion ==
          _cachedDirectTransformTickVersion &&
      buf.transformRevision == _cachedDirectTransformRev &&
      _canReuseStaticBatchCache(
        buf: buf,
        atlas: atlas,
        logicalSize: logicalSize,
        devicePixelRatio: devicePixelRatio,
        cursor: cursor,
        activePty: activePty,
      );

  bool _anyRegionOverlapsActiveTransforms(Buffer buf) {
    final poses = _cellTransformAnimator.activePoses;
    if (poses.isEmpty || !buf.hasShaderRegions || buf.width <= 0) return false;
    final cols = buf.width;
    for (final region in buf.shaderRegions) {
      for (final rect in region.sourceRects) {
        for (final cellIdx in poses.keys) {
          final x = cellIdx % cols;
          final y = cellIdx ~/ cols;
          if (x >= rect.x &&
              x < rect.x + rect.width &&
              y >= rect.y &&
              y < rect.y + rect.height) {
            return true;
          }
        }
      }
    }
    return false;
  }

  void _storeDirectBatchCache({
    required GpuAtlasQuadBatch staticBatch,
    required GpuAtlasQuadBatch batch,
    required StagedRegionMasksResult? regionMasks,
    required List<ComputedShaderRegionLayout> layouts,
    required Buffer buf,
    required GlyphAtlas atlas,
    required Size logicalSize,
    required double devicePixelRatio,
    required ({int col, int row})? cursor,
    required (int, int)? activePty,
  }) {
    _cachedStaticBatch = staticBatch;
    _cachedDirectBatch = batch;
    _cachedRegionMasks = regionMasks;
    _cachedRegionLayouts = layouts;
    _cachedDirectBuf = buf;
    _cachedDirectAtlas = atlas;
    _cachedDirectSize = logicalSize;
    _cachedDirectDpr = devicePixelRatio;
    _cachedDirectPaintVersion = _directPaintVersion;
    _cachedDirectNotifyVersion = _paintNotifier.version;
    _cachedDirectTransformTickVersion = _paintNotifier.transformTickVersion;
    _cachedDirectEpoch = _directBatchInvalidationEpoch;
    _cachedDirectOverrideHash = _overrideMaskHash;
    _cachedDirectCursor = cursor;
    _cachedDirectPtySize = activePty;
    _cachedDirectRegionRev = buf.regionRevision;
    _cachedDirectTransformRev = buf.transformRevision;
    _cachedDirectHasTransforms = buf.hasCellTransforms;
  }

  GpuAtlasQuadBatch? _stageDirectTerminalBatch(
    Size logicalSize,
    double devicePixelRatio,
  ) {
    final tracing = ShaderPerfTrace.isEnabled;
    final spanStart = tracing
        ? ShaderPerfTrace.beginSpan('TerminalSurface.stageDirectBatch')
        : 0;
    try {
      return _stageDirectTerminalBatchImpl(logicalSize, devicePixelRatio);
    } finally {
      if (tracing) {
        ShaderPerfTrace.endSpan('TerminalSurface.stageDirectBatch', spanStart);
      }
    }
  }

  GpuAtlasQuadBatch? _stageDirectTerminalBatchImpl(
    Size logicalSize,
    double devicePixelRatio,
  ) {
    final buf = _activeBuffer;
    final atlas = _atlasController.atlas;
    if (buf == null || atlas == null) return null;
    final activePty =
        widget.activePtySizeProvider?.call() ?? widget.activePtySize;
    final cursor =
        widget.cursorPositionProvider?.call() ?? widget.cursorPosition;
    if (_canReuseDirectBatchCache(
      buf: buf,
      atlas: atlas,
      logicalSize: logicalSize,
      devicePixelRatio: devicePixelRatio,
      cursor: cursor,
      activePty: activePty,
    )) {
      if (ShaderPerfTrace.isEnabled) {
        ShaderPerfTrace.incrementCounter('TerminalSurface.staticHit');
      }
      return _cachedDirectBatch;
    }

    _syncCellTransformsAndRegions(buf);
    final effectiveBgColor = _effectiveBackgroundColor;
    final canReuseStatic = _canReuseStaticBatchCache(
      buf: buf,
      atlas: atlas,
      logicalSize: logicalSize,
      devicePixelRatio: devicePixelRatio,
      cursor: cursor,
      activePty: activePty,
    );
    final GpuAtlasQuadBatch staticBatch;
    if (canReuseStatic) {
      if (ShaderPerfTrace.isEnabled) {
        ShaderPerfTrace.incrementCounter('TerminalSurface.staticHit');
      }
      staticBatch = _cachedStaticBatch!;
    } else {
      if (ShaderPerfTrace.isEnabled) {
        ShaderPerfTrace.incrementCounter('TerminalSurface.staticMiss');
      }
      _hadActiveBuffer = true;
      _lastPaintedBuffer = buf;
      _lastPaintedActivePtySize = activePty;
      final painter = _createAtlasPainter(
        buf,
        composingText: '',
        cursor: cursor,
        activePty: activePty,
        effectiveBgColor: effectiveBgColor,
      );
      staticBatch = painter.stageForGpu(
        logicalSize,
        devicePixelRatio,
        _gpuBatchBuilder,
      );
    }

    if (_cellTransformAnimator.activeCount <= 0 && !buf.hasShaderRegions) {
      _storeDirectBatchCache(
        staticBatch: staticBatch,
        batch: staticBatch,
        regionMasks: null,
        layouts: const <ComputedShaderRegionLayout>[],
        buf: buf,
        atlas: atlas,
        logicalSize: logicalSize,
        devicePixelRatio: devicePixelRatio,
        cursor: cursor,
        activePty: activePty,
      );
      return staticBatch;
    }

    return _stageDynamicDirectSlices(
      staticBatch: staticBatch,
      canReuseStatic: canReuseStatic,
      effectiveBgColor: effectiveBgColor,
      buf: buf,
      atlas: atlas,
      logicalSize: logicalSize,
      devicePixelRatio: devicePixelRatio,
      cursor: cursor,
      activePty: activePty,
    );
  }

  GpuAtlasQuadBatch _stageDynamicDirectSlices({
    required GpuAtlasQuadBatch staticBatch,
    required bool canReuseStatic,
    required Color effectiveBgColor,
    required Buffer buf,
    required GlyphAtlas atlas,
    required Size logicalSize,
    required double devicePixelRatio,
    required ({int col, int row})? cursor,
    required (int, int)? activePty,
  }) {
    final defaultFg = widget.foregroundColor.toARGB32();
    final defaultBg = effectiveBgColor.toARGB32();
    final xformSlice = _cellTransformGpuStager.stageTransformedCells(
      buffer: buf,
      atlas: atlas,
      entries: _cellTransformAnimator.sortedEntries,
      devicePixelRatio: devicePixelRatio,
      defaultForegroundArgb: defaultFg,
      defaultBackgroundArgb: defaultBg,
      faintOpacity: widget.faintOpacity,
      palette: widget.palette,
    );
    final canReuseMasks =
        canReuseStatic &&
        _cachedRegionMasks != null &&
        !_anyRegionOverlapsActiveTransforms(buf);
    final regionMasks = canReuseMasks
        ? _cachedRegionMasks!
        : _regionGpuStager.stageRegionMasks(
            buffer: buf,
            atlas: atlas,
            regions: buf.shaderRegions,
            paneLogicalSize: logicalSize,
            devicePixelRatio: devicePixelRatio,
            defaultForegroundArgb: defaultFg,
            defaultBackgroundArgb: defaultBg,
            faintOpacity: widget.faintOpacity,
            palette: widget.palette,
            activeTransforms: _cellTransformAnimator.activePoses,
            isShaderQuarantined: _cliShaderRegistry.isQuarantined,
          );
    final result = staticBatch.withDynamicSlices(
      transformedInstanceData: xformSlice.data,
      transformedInstanceCount: xformSlice.count,
      transformedUnderGlyphCount: xformSlice.underGlyphCount,
      transformedGeneration: xformSlice.generation,
      regionMaskInstanceData: regionMasks.data,
      regionMaskInstanceCount: regionMasks.count,
      regionMaskGeneration: regionMasks.generation,
      regionMaskSlices: regionMasks.slices,
      hasCanvasOnlyContent:
          staticBatch.hasCanvasOnlyContent ||
          xformSlice.hasCanvasOnlyFallback ||
          regionMasks.hasCanvasOnlyFallback,
    );
    _storeDirectBatchCache(
      staticBatch: staticBatch,
      batch: result,
      regionMasks: regionMasks,
      layouts: regionMasks.layouts,
      buf: buf,
      atlas: atlas,
      logicalSize: logicalSize,
      devicePixelRatio: devicePixelRatio,
      cursor: cursor,
      activePty: activePty,
    );
    return result;
  }

  List<ComputedShaderRegionLayout> _provideRegionLayouts(
    Size logicalSize,
    double devicePixelRatio,
  ) {
    final buf = _activeBuffer;
    final atlas = _atlasController.atlas;
    if (buf == null || atlas == null || !buf.hasShaderRegions) {
      return const <ComputedShaderRegionLayout>[];
    }
    final activePty =
        widget.activePtySizeProvider?.call() ?? widget.activePtySize;
    final cursor =
        widget.cursorPositionProvider?.call() ?? widget.cursorPosition;
    final cachedLayouts = _cachedRegionLayouts;
    if (cachedLayouts != null &&
        _canReuseStaticBatchCache(
          buf: buf,
          atlas: atlas,
          logicalSize: logicalSize,
          devicePixelRatio: devicePixelRatio,
          cursor: cursor,
          activePty: activePty,
        )) {
      return cachedLayouts;
    }
    final active = <ShaderRegion>[
      for (final r in buf.shaderRegions)
        if (!_cliShaderRegistry.isQuarantined(r.shaderId)) r,
    ]..sort((a, b) => a.zIndex.compareTo(b.zIndex));
    final limit = math.min(active.length, ShaderRegion.maxRegionsPerPane);
    final layouts = <ComputedShaderRegionLayout>[];
    for (var i = 0; i < limit; i++) {
      if (layouts.length >= ShaderRegion.maxRegionsPerPane) break;
      final regionLayouts = ComputedShaderRegionLayout.computeAll(
        region: active[i],
        gridCols: buf.width,
        gridRows: buf.height,
        cellWidth: atlas.cellWidth,
        cellHeight: atlas.cellHeight,
        paneLogicalSize: logicalSize,
        devicePixelRatio: devicePixelRatio,
        activeTransforms: _cellTransformAnimator.activePoses,
      );
      for (final layout in regionLayouts) {
        if (layouts.length >= ShaderRegion.maxRegionsPerPane) break;
        layouts.add(layout);
      }
    }
    return ComputedShaderRegionLayout.applyPanePixelBudget(layouts);
  }

  Future<List<RenderedShaderRegionImage>> _renderRegionsFallbackAsync(
    TerminalShaderBackend backend,
    List<ShaderRegionPassInvocation> passes,
    List<ComputedShaderRegionLayout> layouts,
    double devicePixelRatio,
    ui.Image? wallpaperImage,
  ) {
    final buf = _activeBuffer;
    final atlas = _atlasController.atlas;
    if (buf == null || atlas == null) {
      return Future<List<RenderedShaderRegionImage>>.value(
        const <RenderedShaderRegionImage>[],
      );
    }
    return _regionCanvasStager.renderRegionsFallbackAsync(
      backend: backend,
      buffer: buf,
      atlas: atlas,
      layouts: layouts,
      passes: passes,
      devicePixelRatio: devicePixelRatio,
      defaultForegroundArgb: widget.foregroundColor.toARGB32(),
      defaultBackgroundArgb: _effectiveBackgroundColor.toARGB32(),
      faintOpacity: widget.faintOpacity,
      palette: widget.palette,
      fontFamily: _atlasController.fontFamily,
      fontFamilyFallback: _atlasController.fontFamilyFallback,
      fallbackPainters: _atlasController.fallbackPainters,
      activeTransforms: _cellTransformAnimator.activePoses,
      wallpaperImage: wallpaperImage,
      watchdog: _gpuWatchdog,
    );
  }

  Widget _buildCanvasContainer(Size layoutSize) {
    final buf = _activeBuffer;
    final activePty =
        widget.activePtySizeProvider?.call() ?? widget.activePtySize;
    final cursor =
        widget.cursorPositionProvider?.call() ?? widget.cursorPosition;
    _hadActiveBuffer = buf != null;
    _lastPaintedBuffer = buf;
    _lastPaintedActivePtySize = activePty;
    _syncComposingPainter();
    final effectiveOpacity = _effectiveBackgroundOpacity;
    final effectiveBgColor = _effectiveBackgroundColor;
    final activeComposingText = widget.enableIme
        ? _imeClient.composingText
        : '';
    final inlineComposingText = _hasShaderBinding ? '' : activeComposingText;
    final canvasBox = Container(
      width: layoutSize.width,
      height: layoutSize.height,
      color: buf == null || effectiveOpacity >= 1.0
          ? effectiveBgColor
          : const ui.Color(0x00000000),
      child: buf == null
          ? const SizedBox()
          : CustomPaint(
              size: layoutSize,
              painter: _createAtlasPainter(
                buf,
                composingText: inlineComposingText,
                cursor: cursor,
                activePty: activePty,
                effectiveBgColor: effectiveBgColor,
              ),
            ),
    );
    final atlas = _atlasController.atlas;
    final Widget baseSurface = _hasShaderBinding
        ? _buildShaderHost(
            layoutSize: layoutSize,
            atlas: atlas!,
            buf: buf,
            canvasBox: canvasBox,
          )
        : canvasBox;
    final showSearchOverlay =
        _hasSearchHighlights &&
        widget.searchHighlightsProvider != null &&
        buf != null &&
        atlas != null;
    final showComposingOverlay =
        _hasShaderBinding && activeComposingText.isNotEmpty && atlas != null;
    if (!showSearchOverlay && !showComposingOverlay) {
      return baseSurface;
    }
    return Stack(
      fit: StackFit.passthrough,
      children: <Widget>[
        baseSurface,
        if (showSearchOverlay)
          _buildSearchHighlightOverlay(
            layoutSize: layoutSize,
            atlas: atlas,
            buf: buf,
          ),
        if (showComposingOverlay)
          _buildComposingOverlay(
            layoutSize: layoutSize,
            atlas: atlas,
            cursor: cursor,
            activeComposingText: activeComposingText,
            effectiveBgColor: effectiveBgColor,
          ),
      ],
    );
  }

  Widget _buildShaderHost({
    required Size layoutSize,
    required GlyphAtlas atlas,
    required Buffer? buf,
    required Widget canvasBox,
  }) => TerminalShaderHost(
    controller: widget.shaderController,
    config: widget.shaderConfig ?? TerminalShaderConfig.empty,
    paneKey: widget.key?.toString(),
    cursorRectLogicalProvider: _readCursorRectLogical,
    cursorColorArgb: widget.palette.cursorColor.argb,
    cursorStyle: widget.cursorStyle,
    cursorVisible: widget.cursorVisibleProvider?.call() ?? widget.cursorVisible,
    cursorVisibleProvider: widget.cursorVisibleProvider,
    isFocused: _focusNode.hasFocus,
    foregroundArgb: widget.foregroundColor.toARGB32(),
    backgroundArgb: widget.backgroundColor.toARGB32(),
    palette256Argb: _resolvePalette256Argb(),
    cellSizeLogical: Size(atlas.cellWidth, atlas.cellHeight),
    activityListenable: _paintNotifier,
    activitySignal: _directPaintVersion,
    directTerminalBatchProvider: buf == null ? null : _stageDirectTerminalBatch,
    atlasImage: atlas.image,
    atlasDevicePixelRatio: atlas.devicePixelRatio,
    directLogicalSize: layoutSize,
    cliShaderRegistry: _cliShaderRegistry,
    watchdog: _gpuWatchdog,
    regionLayoutsProvider: buf == null ? null : _provideRegionLayouts,
    regionFallbackRenderer: buf == null ? null : _renderRegionsFallbackAsync,
    mouseLogicalListenable: _shaderMouseNotifier,
    maxAmbientFps: widget.maxAmbientFps,
    child: canvasBox,
  );

  Widget _buildSearchHighlightOverlay({
    required Size layoutSize,
    required GlyphAtlas atlas,
    required Buffer buf,
  }) => Positioned.fill(
    child: IgnorePointer(
      child: CustomPaint(
        size: layoutSize,
        painter: TerminalSearchHighlightPainter(
          repaint: _searchOverlayRepaint,
          highlightsProvider: widget.searchHighlightsProvider!,
          topVirtualRowProvider: _readEffectiveTopVirtualRow,
          cellWidth: atlas.cellWidth,
          cellHeight: atlas.cellHeight,
          cols: buf.width,
          rows: buf.height,
          matchColor:
              widget.searchMatchColor ??
              Color(widget.palette.resolveAnsi256(4).argb),
          activeMatchColor:
              widget.activeSearchMatchColor ??
              Color(widget.palette.resolveAnsi256(3).argb),
        ),
      ),
    ),
  );

  Widget _buildComposingOverlay({
    required Size layoutSize,
    required GlyphAtlas atlas,
    required ({int col, int row})? cursor,
    required String activeComposingText,
    required Color effectiveBgColor,
  }) => Positioned.fill(
    child: IgnorePointer(
      child: CustomPaint(
        size: layoutSize,
        painter: _TerminalComposingOverlayPainter(
          cellWidth: atlas.cellWidth,
          cellHeight: atlas.cellHeight,
          cursorCol: cursor?.col ?? 0,
          cursorRow: cursor?.row ?? 0,
          composingText: activeComposingText,
          composingPainter: _composingPainter,
          fontFamily: _atlasController.fontFamily,
          fontFamilyFallback: _atlasController.fontFamilyFallback,
          fontSize: atlas.fontSize,
          defaultForegroundArgb: widget.foregroundColor.toARGB32(),
          defaultBackgroundArgb: effectiveBgColor.toARGB32(),
        ),
      ),
    ),
  );
}

final class _TerminalComposingOverlayPainter extends CustomPainter {
  final double cellWidth;
  final double cellHeight;
  final int cursorCol;
  final int cursorRow;
  final String composingText;
  final TextPainter? composingPainter;
  final String fontFamily;
  final List<String>? fontFamilyFallback;
  final double fontSize;
  final int defaultForegroundArgb;
  final int defaultBackgroundArgb;

  const _TerminalComposingOverlayPainter({
    required this.cellWidth,
    required this.cellHeight,
    required this.cursorCol,
    required this.cursorRow,
    required this.composingText,
    required this.composingPainter,
    required this.fontFamily,
    required this.fontFamilyFallback,
    required this.fontSize,
    required this.defaultForegroundArgb,
    required this.defaultBackgroundArgb,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (composingText.isEmpty || size.isEmpty) return;
    TuiAtlasPainter.paintComposingOverlay(
      canvas: canvas,
      size: size,
      cellWidth: cellWidth,
      cellHeight: cellHeight,
      cursorCol: cursorCol,
      cursorRow: cursorRow,
      composingText: composingText,
      composingPainter: composingPainter,
      fontFamily: fontFamily,
      fontFamilyFallback: fontFamilyFallback,
      fontSize: fontSize,
      defaultForegroundArgb: defaultForegroundArgb,
      defaultBackgroundArgb: defaultBackgroundArgb,
    );
  }

  @override
  bool shouldRepaint(covariant _TerminalComposingOverlayPainter oldDelegate) =>
      oldDelegate.composingText != composingText ||
      oldDelegate.cursorCol != cursorCol ||
      oldDelegate.cursorRow != cursorRow ||
      oldDelegate.composingPainter != composingPainter ||
      oldDelegate.cellWidth != cellWidth ||
      oldDelegate.cellHeight != cellHeight ||
      oldDelegate.defaultForegroundArgb != defaultForegroundArgb ||
      oldDelegate.defaultBackgroundArgb != defaultBackgroundArgb;
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
    final codes = buffer.glyphCodes;
    final glyphCells = buffer.glyphCellList;
    final attrs = buffer.attributes;
    KittyImageData? lastKittyData;
    for (var i = 0; i < total; i++) {
      final code = codes[i];
      if (code == GlyphCellList.wideContinuationCode ||
          code == GlyphCellList.spaceCode) {
        continue;
      }
      final hasKittyMod = Modifier.has(
        attrs[i * 3 + 2],
        Modifier.kittyPlaceholder,
      );
      if (!hasKittyMod &&
          code != kittyPlaceholderCodePoint &&
          (code & GlyphCellList.clusterFlag) == 0) {
        continue;
      }
      final char = glyphCells.decodeCode(code);
      if (!hasKittyMod &&
          (char.length < 2 || !char.startsWith(kittyPlaceholderChar))) {
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
    if (data.format == KittyImageData.formatPng) {
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
  int version = 0;
  int transformTickVersion = 0;

  void notify() {
    version++;
    notifyListeners();
  }

  void notifyTransformTick() {
    transformTickVersion++;
    notifyListeners();
  }
}

final class _ShaderMouseNotifier extends ChangeNotifier
    implements ValueListenable<Float32List> {
  final Float32List _value = Float32List.fromList(<double>[
    double.nan,
    double.nan,
    0.0,
    0.0,
  ]);

  @override
  Float32List get value => _value;

  void update(
    double x,
    double y,
    double clickZ,
    double clickW, {
    required bool notify,
  }) {
    if (_value[0] == x &&
        _value[1] == y &&
        _value[2] == clickZ &&
        _value[3] == clickW) {
      return;
    }
    _value[0] = x;
    _value[1] = y;
    _value[2] = clickZ;
    _value[3] = clickW;
    if (notify) {
      notifyListeners();
    }
  }
}
