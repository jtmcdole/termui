import 'dart:math' as math;

import 'package:characters/characters.dart';
import 'package:termui/termui.dart';

import 'ktty_probe_assets.dart';
import 'ktty_probe_report.dart';

/// Ordered `OSC 22` pointer shapes showcased by [KttyOsc22CursorSwatch].
const List<String> kttyOsc22SwatchShapes = [
  'pointer',
  'text',
  'grab',
  'nesw-resize',
  'not-allowed',
];

/// Active view tab inside the KTTY Probe dashboard.
enum KttyProbeTab {
  /// Combined overview of capability matrix, graphics, SGR, and live telemetry.
  overview('1:Overview'),

  /// Full capability probe table with protocol tags and decoded replies.
  matrix('2:Matrix'),

  /// Kitty Graphics (`f=32`, 32-bit MSB, `f=100` PNG, animation), occlusion, SGR & `OSC 66`.
  graphicsAndSgr('3:Graphics&SGR'),

  /// Live Kitty Keyboard (`press`/`repeat`/`release`), `?1016` mouse, `OSC 22`, and `OSC` actions.
  inputAndOsc('4:Input&OSC');

  /// Short tab button label.
  final String label;

  const KttyProbeTab(this.label);
}

/// Callbacks connecting [KttyProbeDashboard] controls to the controller.
final class KttyProbeActions {
  /// Selects a dashboard tab.
  final void Function(KttyProbeTab tab) onSelectTab;

  /// Re-runs the non-destructive wire capability query burst.
  final void Function() onReprobe;

  /// Cycles Kitty Keyboard progressive enhancement flags (`CSI = flags ; 1 u`).
  final void Function() onCycleKittyKeyboard;

  /// Toggles `?1016` SGR-Pixels mouse mode vs `?1006` cell mouse mode.
  final void Function() onToggleSgrPixels;

  /// Toggles the cell-granularity occlusion badge over the `KittyImage` tiles.
  final void Function() onToggleOcclusion;

  /// Cycles Kitty Graphics delete modes (`a=d,d=a,q=2` vs `a=d,d=A,q=2`).
  final void Function()? onCycleDeleteMode;

  /// Emits an `OSC 99` desktop notification sequence over the wire.
  final void Function() onSendNotification;

  /// Emits an `OSC 52` clipboard write sequence over the wire.
  final void Function() onSendClipboard;

  /// Emits an `OSC 2` window title update over the wire.
  final void Function() onCycleWindowTitle;

  /// Emits an `OSC 133` semantic prompt marker sequence over the wire.
  final void Function() onEmitPromptMarker;

  /// Exports the JSON capability report via a host-supplied Web-safe callback.
  final void Function()? onExportReport;

  /// Copies the JSON capability report to the clipboard via `OSC 52`.
  final void Function()? onCopyReport;

  /// Invoked when mouse hover enters or leaves an `OSC 22` cursor swatch chip.
  final void Function(String? shape)? onHoverCursorShape;

  /// Exits the KTTY Probe program cleanly.
  final void Function() onQuit;

  /// Creates [KttyProbeActions].
  const KttyProbeActions({
    required this.onSelectTab,
    required this.onReprobe,
    required this.onCycleKittyKeyboard,
    required this.onToggleSgrPixels,
    required this.onToggleOcclusion,
    this.onCycleDeleteMode,
    required this.onSendNotification,
    required this.onSendClipboard,
    required this.onCycleWindowTitle,
    required this.onEmitPromptMarker,
    this.onExportReport,
    this.onCopyReport,
    this.onHoverCursorShape,
    required this.onQuit,
  });
}

/// Immutable UI snapshot rendered by [KttyProbeDashboard].
final class KttyProbeViewState {
  /// Capability probe report.
  final KttyProbeReport report;

  /// Currently selected dashboard tab.
  final KttyProbeTab activeTab;

  /// Active Kitty Keyboard progressive enhancement flags requested by the user.
  final int requestedKeyboardFlags;

  /// Whether `?1016` SGR-Pixels mouse mode is requested.
  final bool sgrPixelsEnabled;

  /// Whether the floating occlusion badge over the graphics tiles is visible.
  final bool showOcclusion;

  /// Recent decoded keyboard events (most recent first).
  final List<String> keyLog;

  /// Last interactive `OSC` action message.
  final String lastActionMessage;

  /// Optional label for the active Kitty Graphics delete mode (`'d=a'` or `'d=A'`).
  final String? deleteModeLabel;

  /// Currently hovered `OSC 22` cursor swatch shape, or `null` when idle.
  final String? hoveredCursorShape;

  /// Creates a [KttyProbeViewState].
  const KttyProbeViewState({
    required this.report,
    required this.activeTab,
    required this.requestedKeyboardFlags,
    required this.sgrPixelsEnabled,
    required this.showOcclusion,
    required this.keyLog,
    required this.lastActionMessage,
    this.deleteModeLabel,
    this.hoveredCursorShape,
  });
}

/// Widget that paints a [KittyImageData] (including `format: 100` PNG or 32-bit
/// MSB IDs) as `U+10EEEE` Unicode placeholder cells.
final class KttyDataTileWidget extends Widget {
  /// Descriptor containing pixels/PNG payload, 32-bit `imageId`, and grid dimensions.
  final KittyImageData imageData;

  /// Creates a [KttyDataTileWidget].
  const KttyDataTileWidget({super.key, required this.imageData});

  @override
  int getIntrinsicWidth(int height) => imageData.gridCols;

  @override
  int getIntrinsicHeight(int width) => imageData.gridRows;

  @override
  Element createElement() => _KttyDataTileElement(this);
}

final class _KttyDataTileElement extends Element {
  KittyImageData? _cachedBase;
  KittyImageData? _cachedSizedData;
  List<String>? _cachedCells;
  int _cachedCols = -1;
  int _cachedRows = -1;
  int _cachedMsb = -1;

  _KttyDataTileElement(KttyDataTileWidget super.widget);

  @override
  Size performLayout(BoxConstraints constraints) {
    final data = (widget as KttyDataTileWidget).imageData;
    return constraints.constrain(Size(data.gridCols, data.gridRows));
  }

  KittyImageData _resolveSizedData(
    KittyImageData base,
    int validId,
    int cols,
    int rows,
  ) {
    if (base.imageId == validId &&
        cols == base.gridCols &&
        rows == base.gridRows) {
      return base;
    }
    if (identical(_cachedBase, base) &&
        _cachedSizedData != null &&
        _cachedSizedData!.imageId == validId &&
        _cachedSizedData!.gridCols == cols &&
        _cachedSizedData!.gridRows == rows) {
      return _cachedSizedData!;
    }
    final sized = base.copyWith(
      imageId: validId,
      gridCols: cols,
      gridRows: rows,
    );
    _cachedBase = base;
    _cachedSizedData = sized;
    return sized;
  }

  List<String> _ensureCells(int cols, int rows, int msb) {
    if (_cachedCells != null &&
        _cachedCols == cols &&
        _cachedRows == rows &&
        _cachedMsb == msb) {
      return _cachedCells!;
    }
    final cells = List<String>.generate(
      cols * rows,
      (i) => kittyPlaceholderCell(i ~/ cols, i % cols, imageIdMsb: msb),
      growable: false,
    );
    _cachedCells = cells;
    _cachedCols = cols;
    _cachedRows = rows;
    _cachedMsb = msb;
    return cells;
  }

  @override
  void performPaint(Buffer buffer, Offset offset) {
    final base = (widget as KttyDataTileWidget).imageData;
    final cols = math.min(size.width, kittyDiacritics.length);
    final rows = math.min(size.height, kittyDiacritics.length);
    if (cols <= 0 || rows <= 0) return;

    final validId = (base.imageId & 0xFFFFFFFF) == 0
        ? 1
        : (base.imageId & 0xFFFFFFFF);
    final msb = (validId >>> 24) & 0xFF;
    KittyImageRegistry.register(_resolveSizedData(base, validId, cols, rows));
    buffer.registerKittyRegistry(
      Rect(offset.dx, offset.dy, cols, rows),
      KittyImageRegistry.global,
    );
    final cells = _ensureCells(cols, rows, msb);

    final fgArgb = 0xFF000000 | (validId & 0xFFFFFF);
    for (var ry = 0; ry < rows; ry++) {
      final by = offset.dy + ry;
      final rowBase = ry * cols;
      for (var rx = 0; rx < cols; rx++) {
        buffer.setAttributes(
          offset.dx + rx,
          by,
          char: cells[rowBase + rx],
          fg: fgArgb,
          bg: 0,
          modifiers: Modifier.kittyPlaceholder,
          blend: false,
        );
      }
    }
  }
}

/// Widget that paints a 24-bit [KittyImageData] ([kttyVisualShorthandImageId])
/// using shorthand `U+10EEEE` Unicode placeholder cells: column 0 carries a
/// single row diacritic (`U+10EEEE` + row diacritic, 3 UTF-16 code units) and
/// columns `1..cols-1` carry bare `U+10EEEE` (2 UTF-16 code units), while
/// `underlineColor` encodes placement IDs `p=1` (top half) and `p=2` (bottom half).
final class KttyShorthandTileWidget extends Widget {
  /// Descriptor containing pixels payload, 24-bit `imageId`, and grid dimensions.
  final KittyImageData imageData;

  /// Creates a [KttyShorthandTileWidget].
  const KttyShorthandTileWidget({super.key, required this.imageData});

  @override
  int getIntrinsicWidth(int height) => imageData.gridCols;

  @override
  int getIntrinsicHeight(int width) => imageData.gridRows;

  @override
  Element createElement() => _KttyShorthandTileElement(this);
}

final class _KttyShorthandTileElement extends Element {
  static final int _topPlacementColor = const Color(0, 0, 1).argb;
  static final int _bottomPlacementColor = const Color(0, 0, 2).argb;

  KittyImageData? _cachedBase;
  KittyImageData? _cachedSizedData;
  List<String>? _cachedRowHeads;

  _KttyShorthandTileElement(KttyShorthandTileWidget super.widget);

  @override
  Size performLayout(BoxConstraints constraints) {
    final data = (widget as KttyShorthandTileWidget).imageData;
    return constraints.constrain(Size(data.gridCols, data.gridRows));
  }

  KittyImageData _resolveSizedData(
    KittyImageData base,
    int validId,
    int cols,
    int rows,
  ) {
    if (base.imageId == validId &&
        cols == base.gridCols &&
        rows == base.gridRows) {
      return base;
    }
    if (identical(_cachedBase, base) &&
        _cachedSizedData != null &&
        _cachedSizedData!.imageId == validId &&
        _cachedSizedData!.gridCols == cols &&
        _cachedSizedData!.gridRows == rows) {
      return _cachedSizedData!;
    }
    final sized = base.copyWith(
      imageId: validId,
      gridCols: cols,
      gridRows: rows,
    );
    _cachedBase = base;
    _cachedSizedData = sized;
    return sized;
  }

  List<String> _ensureRowHeads(int rows) {
    final existing = _cachedRowHeads;
    if (existing != null && existing.length == rows) {
      return existing;
    }
    final heads = List<String>.generate(
      rows,
      (row) =>
          '$kittyPlaceholderChar${String.fromCharCode(kittyDiacritics[row])}',
      growable: false,
    );
    _cachedRowHeads = heads;
    return heads;
  }

  @override
  void performPaint(Buffer buffer, Offset offset) {
    final base = (widget as KttyShorthandTileWidget).imageData;
    final cols = math.min(size.width, kittyDiacritics.length);
    final rows = math.min(size.height, kittyDiacritics.length);
    if (cols <= 0 || rows <= 0) return;

    final low24 = base.imageId & 0xFFFFFF;
    final validId = low24 == 0 ? kttyVisualShorthandImageId : low24;
    KittyImageRegistry.register(_resolveSizedData(base, validId, cols, rows));
    buffer.registerKittyRegistry(
      Rect(offset.dx, offset.dy, cols, rows),
      KittyImageRegistry.global,
    );

    final rowHeads = _ensureRowHeads(rows);
    final fgArgb = 0xFF000000 | validId;
    final splitRow = rows ~/ 2;
    for (var ry = 0; ry < rows; ry++) {
      final by = offset.dy + ry;
      final ulArgb = ry < splitRow ? _topPlacementColor : _bottomPlacementColor;
      buffer.setAttributes(
        offset.dx,
        by,
        char: rowHeads[ry],
        fg: fgArgb,
        bg: 0,
        modifiers: Modifier.kittyPlaceholder,
        underlineColor: ulArgb,
        blend: false,
      );
      for (var rx = 1; rx < cols; rx++) {
        buffer.setAttributes(
          offset.dx + rx,
          by,
          char: kittyPlaceholderChar,
          fg: fgArgb,
          bg: 0,
          modifiers: Modifier.kittyPlaceholder,
          underlineColor: ulArgb,
          blend: false,
        );
      }
    }
  }
}

/// Widget that paints a 2-frame animated Kitty showcase tile as `U+10EEEE`
/// placeholder cells and registers its frames in [KittyImageRegistry.global].
final class KttyAnimatedTileWidget extends Widget {
  /// Ordered animation frames (`frames[0]` is frame 1, `frames[1]` is frame 2).
  final List<KittyImageData> frames;

  /// Frame delay in milliseconds.
  final int frameGapMs;

  /// Creates a [KttyAnimatedTileWidget].
  const KttyAnimatedTileWidget({
    super.key,
    required this.frames,
    this.frameGapMs = 450,
  });

  @override
  int getIntrinsicWidth(int height) =>
      frames.isEmpty ? 0 : frames.first.gridCols;

  @override
  int getIntrinsicHeight(int width) =>
      frames.isEmpty ? 0 : frames.first.gridRows;

  @override
  Element createElement() => _KttyAnimatedTileElement(this);
}

final class _KttyAnimatedTileElement extends Element {
  List<String>? _cachedCells;
  int _cachedCols = -1;
  int _cachedRows = -1;
  int _cachedMsb = -1;
  int? _registeredImageId;
  int _registeredCols = -1;
  int _registeredRows = -1;
  int _registeredGapMs = -1;
  List<KittyImageData>? _registeredFrames;

  _KttyAnimatedTileElement(KttyAnimatedTileWidget super.widget);

  @override
  void unmount() {
    final id = _registeredImageId;
    if (id != null) {
      KittyImageRegistry.global.unregisterImage(id);
      _registeredImageId = null;
      _registeredFrames = null;
    }
    super.unmount();
  }

  @override
  Size performLayout(BoxConstraints constraints) {
    final w = widget as KttyAnimatedTileWidget;
    if (w.frames.isEmpty) return constraints.constrain(Size.zero);
    return constraints.constrain(
      Size(w.frames.first.gridCols, w.frames.first.gridRows),
    );
  }

  List<String> _ensureCells(int cols, int rows, int msb) {
    if (_cachedCells != null &&
        _cachedCols == cols &&
        _cachedRows == rows &&
        _cachedMsb == msb) {
      return _cachedCells!;
    }
    final cells = List<String>.generate(
      cols * rows,
      (i) => kittyPlaceholderCell(i ~/ cols, i % cols, imageIdMsb: msb),
      growable: false,
    );
    _cachedCells = cells;
    _cachedCols = cols;
    _cachedRows = rows;
    _cachedMsb = msb;
    return cells;
  }

  static bool _sameFrameReferences(
    List<KittyImageData>? previous,
    List<KittyImageData> next,
  ) {
    if (previous == null || previous.length != next.length) return false;
    for (var i = 0; i < next.length; i++) {
      if (!identical(previous[i], next[i])) return false;
    }
    return true;
  }

  void _ensureAnimationRegistered(
    List<KittyImageData> frames,
    int validId,
    int cols,
    int rows,
    int gapMs,
  ) {
    final prevId = _registeredImageId;
    if (prevId != null && prevId != validId) {
      KittyImageRegistry.global.unregisterImage(prevId);
    }
    final existing = KittyImageRegistry.global.lookupAnimation(validId);
    if (prevId == validId &&
        _registeredCols == cols &&
        _registeredRows == rows &&
        _registeredGapMs == gapMs &&
        _sameFrameReferences(_registeredFrames, frames) &&
        existing != null &&
        existing.frames.length == frames.length) {
      return;
    }

    final base = frames.first;
    final sizedBase =
        base.imageId == validId &&
            base.gridCols == cols &&
            base.gridRows == rows
        ? base
        : base.copyWith(imageId: validId, gridCols: cols, gridRows: rows);
    KittyImageRegistry.global.unregisterImage(validId);
    KittyImageRegistry.register(sizedBase);

    for (var i = 0; i < frames.length; i++) {
      final f = frames[i];
      final sized =
          f.imageId == validId && f.gridCols == cols && f.gridRows == rows
          ? f
          : f.copyWith(imageId: validId, gridCols: cols, gridRows: rows);
      KittyImageRegistry.global.registerAnimationFrame(
        validId,
        KittyAnimationFrame(frameNumber: i + 1, imageData: sized, gapMs: gapMs),
      );
    }
    KittyImageRegistry.global.setAnimationPlayback(
      validId,
      playback: KittyAnimationPlayback.running,
      loopCount: 0,
    );
    _registeredImageId = validId;
    _registeredCols = cols;
    _registeredRows = rows;
    _registeredGapMs = gapMs;
    _registeredFrames = List<KittyImageData>.of(frames, growable: false);
  }

  @override
  void performPaint(Buffer buffer, Offset offset) {
    final w = widget as KttyAnimatedTileWidget;
    if (w.frames.isEmpty) return;
    final cols = math.min(size.width, kittyDiacritics.length);
    final rows = math.min(size.height, kittyDiacritics.length);
    if (cols <= 0 || rows <= 0) return;

    final rawId = w.frames.first.imageId & 0xFFFFFFFF;
    final validId = rawId == 0 ? kttyVisualAnimatedImageId : rawId;
    final msb = (validId >>> 24) & 0xFF;
    _ensureAnimationRegistered(w.frames, validId, cols, rows, w.frameGapMs);
    buffer.registerKittyRegistry(
      Rect(offset.dx, offset.dy, cols, rows),
      KittyImageRegistry.global,
    );
    final cells = _ensureCells(cols, rows, msb);
    final fgArgb = 0xFF000000 | (validId & 0xFFFFFF);
    for (var ry = 0; ry < rows; ry++) {
      final by = offset.dy + ry;
      final rowBase = ry * cols;
      for (var rx = 0; rx < cols; rx++) {
        buffer.setAttributes(
          offset.dx + rx,
          by,
          char: cells[rowBase + rx],
          fg: fgArgb,
          bg: 0,
          modifiers: Modifier.kittyPlaceholder,
          blend: false,
        );
      }
    }
  }
}

/// Widget showcasing Kitty Text Sizing (`OSC 66`) by writing packed
/// [KittyTextSizing] anchor and continuation cells into the target [Buffer].
final class KttyOsc66HeadlineWidget extends Widget {
  /// Text rendered at [scale]x cell pitch using grapheme clusters.
  final String text;

  /// Integer scale factor (`1..7`, defaults to `2`).
  final int scale;

  /// Text foreground/background/modifier style.
  final Style style;

  /// Creates a [KttyOsc66HeadlineWidget].
  const KttyOsc66HeadlineWidget({
    super.key,
    required this.text,
    this.scale = 2,
    this.style = const Style(
      foreground: CharmColors.julep,
      modifiers: Modifier.bold,
    ),
  });

  static int _scaledDisplayWidth(String text, int scale) {
    var total = 0;
    for (final grapheme in text.characters) {
      total += math.max(1, graphemeWidth(grapheme)) * scale;
    }
    return total;
  }

  @override
  int getIntrinsicWidth(int height) =>
      _scaledDisplayWidth(text, scale.clamp(1, 7));

  @override
  int getIntrinsicHeight(int width) => scale.clamp(1, 7);

  @override
  Element createElement() => _KttyOsc66HeadlineElement(this);
}

final class _KttyOsc66HeadlineElement extends Element {
  _KttyOsc66HeadlineElement(KttyOsc66HeadlineWidget super.widget);

  @override
  Size performLayout(BoxConstraints constraints) {
    final w = widget as KttyOsc66HeadlineWidget;
    final s = w.scale.clamp(1, 7);
    return constraints.constrain(
      Size(KttyOsc66HeadlineWidget._scaledDisplayWidth(w.text, s), s),
    );
  }

  void _paintScaledGrapheme(
    Buffer buffer, {
    required String grapheme,
    required int baseX,
    required int baseY,
    required int scale,
    required int explicitWidth,
    required int boxCols,
    required int boxRows,
    required int fg,
    required int bg,
    required int mods,
  }) {
    for (var dy = 0; dy < boxRows; dy++) {
      for (var dx = 0; dx < boxCols; dx++) {
        final bx = baseX + dx;
        final by = baseY + dy;
        if (dx != 0 || dy != 0) {
          buffer.setAttributes(
            bx,
            by,
            char: ' ',
            fg: fg,
            bg: bg,
            modifiers: mods,
            blend: false,
          );
        }
      }
    }
    buffer.setAttributes(
      baseX,
      baseY,
      char: grapheme,
      fg: fg,
      bg: bg,
      modifiers: mods,
      blend: false,
    );
    for (var dy = 0; dy < boxRows; dy++) {
      for (var dx = 0; dx < boxCols; dx++) {
        final bits = KittyTextSizing.pack(
          scale: scale,
          explicitWidth: explicitWidth,
          isContinuation: dx != 0 || dy != 0,
          originDx: dx,
          originDy: dy,
        ).bits;
        buffer.setTextSizing(baseX + dx, baseY + dy, bits);
      }
    }
  }

  @override
  void performPaint(Buffer buffer, Offset offset) {
    final w = widget as KttyOsc66HeadlineWidget;
    final s = w.scale.clamp(1, 7);
    final maxCols = size.width;
    final maxRows = math.min(size.height, s);
    if (maxCols <= 0 || maxRows <= 0) return;

    final fg = w.style.foreground?.argb ?? 0;
    final bg = w.style.background?.argb ?? 0;
    final mods = w.style.modifiers;
    var cursorX = 0;
    for (final grapheme in w.text.characters) {
      final gw = math.max(1, graphemeWidth(grapheme));
      final boxCols = gw * s;
      if (cursorX + boxCols > maxCols) break;
      _paintScaledGrapheme(
        buffer,
        grapheme: grapheme,
        baseX: offset.dx + cursorX,
        baseY: offset.dy,
        scale: s,
        explicitWidth: gw > 1 ? gw : 0,
        boxCols: boxCols,
        boxRows: maxRows,
        fg: fg,
        bg: bg,
        mods: mods,
      );
      cursorX += boxCols;
    }
  }
}

/// Interactive single-row swatch emitting `OSC 22` hover cursor shape updates
/// for `pointer`, `text`, `grab`, `nesw-resize`, and `not-allowed`.
final class KttyOsc22CursorSwatch extends StatefulWidget {
  /// Currently active hovered shape (externally controlled or echoed).
  final String? activeShape;

  /// Called whenever hover enters or leaves a pointer swatch chip.
  final void Function(String? shape)? onHoverShapeChanged;

  /// Creates a [KttyOsc22CursorSwatch].
  const KttyOsc22CursorSwatch({
    super.key,
    this.activeShape,
    this.onHoverShapeChanged,
  });

  @override
  State<KttyOsc22CursorSwatch> createState() => _KttyOsc22CursorSwatchState();
}

final class _KttyOsc22CursorSwatchState extends State<KttyOsc22CursorSwatch>
    implements MouseEventHandlerWithArea {
  static const String _prefix = 'OSC22:';

  String? _hoveredShape;

  @override
  void initState() {
    super.initState();
    _hoveredShape = widget.activeShape;
  }

  @override
  void didUpdateWidget(KttyOsc22CursorSwatch oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.activeShape != widget.activeShape) {
      _hoveredShape = widget.activeShape;
    }
  }

  @override
  void dispose() {
    if (_hoveredShape != null) {
      _hoveredShape = null;
      widget.onHoverShapeChanged?.call(null);
    }
    super.dispose();
  }

  static String? shapeAtLocalOffset(int localX, int localY) {
    if (localY != 0) return null;
    var cursor = _prefix.length;
    for (final shape in kttyOsc22SwatchShapes) {
      final start = cursor + 1; // leading space
      final chipLen = shape.length + 2; // '[shape]'
      final end = start + chipLen;
      if (localX >= start && localX < end) return shape;
      cursor = end;
    }
    return null;
  }

  @override
  void handleMouseEvent(MouseEvent event, int localX, int localY, Rect area) {
    if (event.type != MouseEventType.move &&
        event.type != MouseEventType.drag &&
        event.type != MouseEventType.press) {
      return;
    }
    final insideArea =
        localX >= 0 &&
        localX < area.width &&
        localY >= 0 &&
        localY < area.height;
    final next = insideArea ? shapeAtLocalOffset(localX, localY) : null;
    final current = _hoveredShape ?? widget.activeShape;
    if (next == current) return;
    _hoveredShape = next;
    widget.onHoverShapeChanged?.call(next);
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final active = _hoveredShape ?? widget.activeShape;
    return SizedBox(
      height: 1,
      child: RichText(
        wrap: false,
        text: TextSpan(
          children: [
            const TextSpan(
              text: _prefix,
              style: Style(
                foreground: CharmColors.smoke,
                modifiers: Modifier.dim,
              ),
            ),
            for (final shape in kttyOsc22SwatchShapes) ...[
              const TextSpan(text: ' '),
              TextSpan(
                text: '[$shape]',
                style: active == shape
                    ? const Style(
                        foreground: CharmColors.pepper,
                        background: CharmColors.malibu,
                        modifiers: Modifier.bold,
                      )
                    : const Style(foreground: CharmColors.malibu),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Stateless presentation layout for the KTTY Probe & Check TUI.
final class KttyProbeDashboard extends StatelessWidget {
  static const int _shorthandMinInnerWidth = 56;
  static const int _animatedMinInnerWidth = 70;

  static final KittyImageData _rawTile = buildRawRgbaVisualTile(
    cols: 12,
    rows: 4,
  );
  static final KittyImageData _msbTile = buildMsb32BitVisualTile(
    cols: 12,
    rows: 4,
  );
  static final KittyImageData _pngTile = buildPngVisualTile(cols: 12, rows: 4);
  static final KittyImageData _shorthandTile = buildShorthandVisualTile(
    cols: 12,
    rows: 4,
  );
  static final List<KittyImageData> _animatedFrames =
      buildAnimatedVisualTileFrames(cols: 12, rows: 4);

  /// Current state snapshot.
  final KttyProbeViewState state;

  /// User interaction callbacks.
  final KttyProbeActions actions;

  /// Creates a [KttyProbeDashboard].
  const KttyProbeDashboard({
    super.key,
    required this.state,
    required this.actions,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final w = constraints.maxWidth;
        final h = constraints.maxHeight;
        return Column([
          if (h >= 1) _buildHeaderBar(),
          if (h >= 2) _buildTabToolbar(),
          if (h >= 4) Expanded(child: _buildBody(w, h - 3)),
          if (h >= 3) _buildFooterBar(),
        ]);
      },
    );
  }

  Widget _buildHeaderBar() {
    final r = state.report;
    final coreTotal = r.coreTotalCount;
    final coreSupported = r.coreSupportedCount;
    final ident = r.xtVersion ?? 'Probing XTVERSION...';
    final fg = r.defaultForegroundHex ?? '?';
    final bg = r.defaultBackgroundHex ?? '?';
    final scheme = r.colorScheme ?? '?';

    return SizedBox(
      height: 1,
      child: RichText(
        wrap: false,
        text: TextSpan(
          children: [
            const TextSpan(
              text: ' KTTY PROBE ',
              style: Style(
                foreground: CharmColors.pepper,
                background: CharmColors.julep,
                modifiers: Modifier.bold,
              ),
            ),
            TextSpan(
              text: ' $coreSupported/$coreTotal PASS ',
              style: Style(
                foreground:
                    r.coreUnsupportedCount == 0 && coreSupported == coreTotal
                    ? CharmColors.julep
                    : CharmColors.butter,
                modifiers: Modifier.bold,
              ),
            ),
            TextSpan(
              text: '│ Term: $ident │ Scheme:$scheme │ FG:$fg BG:$bg ',
              style: const Style(foreground: CharmColors.salt),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTabToolbar() {
    return SizedBox(
      height: 1,
      child: Row([
        for (final tab in KttyProbeTab.values) ...[
          Button(
            text: ' [${tab.label}] ',
            onPressed: () => actions.onSelectTab(tab),
            style: state.activeTab == tab
                ? const Style(
                    foreground: CharmColors.pepper,
                    background: CharmColors.malibu,
                    modifiers: Modifier.bold,
                  )
                : const Style(foreground: CharmColors.smoke),
          ),
        ],
        const SizedBox(width: 1, child: Text('')),
        Button(
          text: ' [R:Re-Probe] ',
          onPressed: actions.onReprobe,
          style: const Style(
            foreground: CharmColors.butter,
            modifiers: Modifier.bold,
          ),
        ),
        Button(
          text: ' [Q:Quit] ',
          onPressed: actions.onQuit,
          style: const Style(foreground: CharmColors.salmon),
        ),
      ]),
    );
  }

  Widget _buildBody(int width, int height) => switch (state.activeTab) {
    .overview => _buildOverviewBody(width, height),
    .matrix => _buildMatrixPanel(),
    .graphicsAndSgr => Column([
      Expanded(flex: 55, child: _buildGraphicsShowcasePanel()),
      Expanded(flex: 45, child: _buildSgrAndLigaturesPanel()),
    ]),
    .inputAndOsc => _buildInputAndOscPanel(),
  };

  Widget _buildOverviewBody(int width, int height) {
    final rightPane = LayoutBuilder(
      builder: (context, constraints) {
        final rh = constraints.maxHeight;
        return Column([
          if (rh >= 16)
            SizedBox(height: 8, child: _buildGraphicsShowcasePanel()),
          if (rh >= 22)
            SizedBox(height: 6, child: _buildSgrAndLigaturesPanel()),
          if (rh >= 2) Expanded(child: _buildInputAndOscPanel()),
        ]);
      },
    );
    if (width < 88) {
      return Column([
        if (height >= 4) Expanded(flex: 50, child: _buildMatrixPanel()),
        if (height >= 4) Expanded(flex: 50, child: rightPane),
      ]);
    }
    return Row([
      Expanded(flex: 46, child: _buildMatrixPanel()),
      const SizedBox(width: 1, child: Text('')),
      Expanded(flex: 54, child: rightPane),
    ]);
  }

  Widget _buildMatrixPanel() {
    final entries = state.report.entries;
    final mux = state.report.multiplexerDiagnostics;
    final hasMuxWarning = mux != null && mux.hints.isNotEmpty;
    return _borderedPanel(
      title:
          'Capability Matrix (Run #${state.report.probeRunCount}${state.report.isComplete ? " - DA1 Complete" : " - Waiting"})',
      borderColor: CharmColors.charple,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final bannerRows = hasMuxWarning && constraints.maxHeight >= 1
              ? 1
              : 0;
          final visible = entries.take(
            math.max(0, constraints.maxHeight - bannerRows),
          );
          return Column([
            if (bannerRows == 1) _buildMultiplexerBanner(mux!),
            for (final entry in visible) _buildCapabilityRow(entry),
          ]);
        },
      ),
    );
  }

  Widget _buildMultiplexerBanner(KttyMultiplexerDiagnostics mux) {
    final summary = mux.hints.join(' | ');
    return SizedBox(
      height: 1,
      child: RichText(
        wrap: false,
        text: TextSpan(
          children: [
            TextSpan(
              text: '[WARN] ${mux.multiplexer}:',
              style: const Style(
                foreground: CharmColors.pepper,
                background: CharmColors.butter,
                modifiers: Modifier.bold,
              ),
            ),
            TextSpan(
              text: ' $summary',
              style: const Style(
                foreground: CharmColors.butter,
                modifiers: Modifier.bold,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCapabilityRow(KttyCapabilityEntry entry) {
    final (badge, color) = switch (entry.status) {
      .supported => ('PASS', CharmColors.julep),
      .unsupported => ('MISS', CharmColors.salmon),
      .pending => ('WAIT', CharmColors.butter),
      .optionalDisabled => ('OPT ', CharmColors.malibu),
    };
    return SizedBox(
      height: 1,
      child: RichText(
        wrap: false,
        text: TextSpan(
          children: [
            TextSpan(
              text: '[$badge] ',
              style: Style(foreground: color, modifiers: Modifier.bold),
            ),
            TextSpan(
              text: entry.name.padRight(24),
              style: const Style(foreground: CharmColors.salt),
            ),
            TextSpan(
              text: '${entry.protocol.padRight(13)} ',
              style: const Style(
                foreground: CharmColors.dolly,
                modifiers: Modifier.dim,
              ),
            ),
            TextSpan(
              text: entry.detail,
              style: Style(foreground: color),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildGraphicsShowcasePanel() {
    final occLabel = state.showOcclusion ? 'ON' : 'OFF';
    return _borderedPanel(
      title: 'Kitty Graphics (U+10EEEE) & Cell Occlusion [O:$occLabel]',
      borderColor: CharmColors.malibu,
      child: LayoutBuilder(
        builder: (context, constraints) =>
            _buildGraphicsShowcaseContent(constraints.maxWidth),
      ),
    );
  }

  Widget _buildGraphicsShowcaseContent(int maxWidth) {
    final showShorthand = maxWidth >= _shorthandMinInnerWidth;
    final showAnimated = maxWidth >= _animatedMinInnerWidth;
    final (caption, rowWidth) = _resolveGraphicsRowSpec(
      showShorthand: showShorthand,
      showAnimated: showAnimated,
    );
    return Column([
      SizedBox(
        height: 1,
        child: Text(caption, style: const Style(foreground: CharmColors.smoke)),
      ),
      Expanded(
        child: Stack([
          Positioned(
            left: 1,
            top: 0,
            width: rowWidth,
            height: 4,
            child: _buildGraphicsTileRow(
              showShorthand: showShorthand,
              showAnimated: showAnimated,
            ),
          ),
          if (state.showOcclusion) _buildOcclusionOverlay(),
        ]),
      ),
    ]);
  }

  static (String caption, int rowWidth) _resolveGraphicsRowSpec({
    required bool showShorthand,
    required bool showAnimated,
  }) {
    if (showAnimated) {
      return (
        ' f=32 RGBA24    32-bit MSB ID   f=100 PNG  Shorthand     Anim 2-Fr',
        68,
      );
    }
    if (showShorthand) {
      return (' f=32 RGBA24    32-bit MSB ID   f=100 PNG  Shorthand', 54);
    }
    return (' f=32 RGBA24    32-bit MSB ID   f=100 PNG', 40);
  }

  Widget _buildGraphicsTileRow({
    required bool showShorthand,
    required bool showAnimated,
  }) {
    return Row([
      KttyDataTileWidget(imageData: _rawTile),
      const SizedBox(width: 2, child: Text('')),
      KttyDataTileWidget(imageData: _msbTile),
      const SizedBox(width: 2, child: Text('')),
      KttyDataTileWidget(imageData: _pngTile),
      if (showShorthand) ...[
        const SizedBox(width: 2, child: Text('')),
        KttyShorthandTileWidget(imageData: _shorthandTile),
      ],
      if (showAnimated) ...[
        const SizedBox(width: 2, child: Text('')),
        KttyAnimatedTileWidget(frames: _animatedFrames),
      ],
    ]);
  }

  Widget _buildOcclusionOverlay() {
    return const Positioned(
      left: 10,
      top: 1,
      width: 22,
      height: 2,
      child: DecoratedBox(
        decoration: BoxDecoration(backgroundColor: CharmColors.pepper),
        child: Column([
          SizedBox(
            height: 1,
            child: Text(
              ' [Z-Occlusion Cell] ',
              style: Style(
                foreground: CharmColors.butter,
                background: CharmColors.pepper,
                modifiers: Modifier.bold,
              ),
            ),
          ),
          SizedBox(
            height: 1,
            child: Text(
              ' Clips U+10EEEE [O] ',
              style: Style(
                foreground: CharmColors.julep,
                background: CharmColors.pepper,
              ),
            ),
          ),
        ]),
      ),
    );
  }

  Widget _buildSgrAndLigaturesPanel() {
    return _borderedPanel(
      title: 'Extended SGR (4:1..5, 58:2, 53), Ligatures, OSC 8 & OSC 66',
      borderColor: CharmColors.dolly,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final h = constraints.maxHeight;
          return Column([
            if (h >= 1)
              SizedBox(
                height: 1,
                child: RichText(
                  wrap: false,
                  text: const TextSpan(
                    children: [
                      TextSpan(
                        text: '4:1 Single ',
                        style: Style(
                          foreground: CharmColors.salt,
                          underlineStyle: UnderlineStyle.single,
                          underlineColor: CharmColors.malibu,
                        ),
                      ),
                      TextSpan(
                        text: '4:2 Double ',
                        style: Style(
                          foreground: CharmColors.salt,
                          underlineStyle: UnderlineStyle.doubleLine,
                          underlineColor: CharmColors.julep,
                        ),
                      ),
                      TextSpan(
                        text: '4:3 Curly ',
                        style: Style(
                          foreground: CharmColors.salt,
                          underlineStyle: UnderlineStyle.curly,
                          underlineColor: CharmColors.salmon,
                        ),
                      ),
                      TextSpan(
                        text: '4:4 Dot ',
                        style: Style(
                          foreground: CharmColors.salt,
                          underlineStyle: UnderlineStyle.dotted,
                          underlineColor: CharmColors.butter,
                        ),
                      ),
                      TextSpan(
                        text: '4:5 Dash',
                        style: Style(
                          foreground: CharmColors.salt,
                          underlineStyle: UnderlineStyle.dashed,
                          underlineColor: CharmColors.dolly,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            if (h >= 2)
              SizedBox(
                height: 1,
                child: RichText(
                  wrap: false,
                  text: const TextSpan(
                    children: [
                      TextSpan(
                        text: 'Overline(53) ',
                        style: Style(
                          foreground: CharmColors.julep,
                          modifiers: Modifier.overline,
                        ),
                      ),
                      TextSpan(
                        text: 'Bold ',
                        style: Style(
                          foreground: CharmColors.salt,
                          modifiers: Modifier.bold,
                        ),
                      ),
                      TextSpan(
                        text: 'Italic ',
                        style: Style(
                          foreground: CharmColors.malibu,
                          modifiers: Modifier.italic,
                        ),
                      ),
                      TextSpan(
                        text: 'BoldItalic ',
                        style: Style(
                          foreground: CharmColors.butter,
                          modifiers: Modifier.bold | Modifier.italic,
                        ),
                      ),
                      TextSpan(
                        text: 'Strike ',
                        style: Style(
                          foreground: CharmColors.salmon,
                          modifiers: Modifier.crossedOut,
                        ),
                      ),
                      TextSpan(
                        text: 'Dim',
                        style: Style(
                          foreground: CharmColors.smoke,
                          modifiers: Modifier.dim,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            if (h >= 3)
              SizedBox(
                height: 1,
                child: RichText(
                  wrap: false,
                  text: const TextSpan(
                    children: [
                      TextSpan(
                        text: 'Ligatures: -> => !== === <= >= |>  ',
                        style: Style(foreground: CharmColors.salt),
                      ),
                      TextSpan(
                        text: '[OSC 8 Spec Link]',
                        style: Style(
                          foreground: CharmColors.malibu,
                          underlineStyle: UnderlineStyle.single,
                          underlineColor: CharmColors.malibu,
                          uri:
                              'https://sw.kovidgoyal.net/kitty/graphics-protocol/',
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            if (h >= 5)
              const SizedBox(
                height: 2,
                child: KttyOsc66HeadlineWidget(text: 'OSC66 2x'),
              ),
          ]);
        },
      ),
    );
  }

  Widget _buildInputAndOscPanel() {
    final kbHex =
        '0x${state.requestedKeyboardFlags.toRadixString(16).padLeft(2, '0')}';
    final mouseMode = state.sgrPixelsEnabled ? '?1016 Pixels' : '?1006 Cell';

    return _borderedPanel(
      title: 'Live Input & Shell Actions (Kb:$kbHex  Mouse:$mouseMode)',
      borderColor: CharmColors.julep,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final avail = constraints.maxHeight;
          final keySlots = math.max(0, avail - 5);
          final keys = state.keyLog.take(keySlots);
          final ackStyle = Style(
            foreground: state.report.hasOsc99Ack
                ? CharmColors.julep
                : CharmColors.smoke,
          );
          return Column([
            if (avail >= 1) _buildActionButtonsRow(),
            if (avail >= 2) _buildCursorAndExportRow(constraints.maxWidth),
            if (avail >= 3)
              SizedBox(
                height: 1,
                child: Text(
                  'Mouse: ${state.report.lastWireMousePacket}',
                  style: const Style(foreground: CharmColors.malibu),
                ),
              ),
            if (avail >= 4)
              SizedBox(
                height: 1,
                child: Text(
                  'OSC  : ${state.lastActionMessage}',
                  style: const Style(foreground: CharmColors.butter),
                ),
              ),
            if (avail >= 5)
              SizedBox(
                height: 1,
                child: Text(
                  'Ack99: ${state.report.lastOsc99Ack}',
                  style: ackStyle,
                ),
              ),
            for (final line in keys)
              SizedBox(
                height: 1,
                child: Text(
                  'Key  : $line',
                  style: const Style(foreground: CharmColors.salt),
                ),
              ),
          ]);
        },
      ),
    );
  }

  Widget _buildCursorAndExportRow(int maxWidth) {
    final swatch = KttyOsc22CursorSwatch(
      activeShape: state.hoveredCursorShape,
      onHoverShapeChanged: actions.onHoverCursorShape,
    );
    if (maxWidth < 83) return swatch;
    return SizedBox(
      height: 1,
      child: Row([
        SizedBox(width: 58, height: 1, child: swatch),
        const SizedBox(width: 2, child: Text('')),
        SizedBox(
          width: 12,
          height: 1,
          child: Button(
            text: '[E:Export]',
            onPressed: actions.onExportReport ?? () {},
            style: const Style(foreground: CharmColors.julep),
          ),
        ),
        const SizedBox(width: 1, child: Text('')),
        SizedBox(
          width: 10,
          height: 1,
          child: Button(
            text: '[P:Copy]',
            onPressed: actions.onCopyReport ?? () {},
            style: const Style(foreground: CharmColors.malibu),
          ),
        ),
      ]),
    );
  }

  Widget _buildActionButtonsRow() {
    final delLabel = state.deleteModeLabel;
    final delText = delLabel == null ? '[D:DelMode]' : '[D:$delLabel]';
    return SizedBox(
      height: 1,
      child: Row([
        Button(
          text: '[K:KbFlags]',
          onPressed: actions.onCycleKittyKeyboard,
          style: const Style(foreground: CharmColors.malibu),
        ),
        const SizedBox(width: 1, child: Text('')),
        Button(
          text: '[M:?1016]',
          onPressed: actions.onToggleSgrPixels,
          style: const Style(foreground: CharmColors.julep),
        ),
        const SizedBox(width: 1, child: Text('')),
        Button(
          text: '[O:Occlude]',
          onPressed: actions.onToggleOcclusion,
          style: const Style(foreground: CharmColors.butter),
        ),
        const SizedBox(width: 1, child: Text('')),
        Button(
          text: delText,
          onPressed: actions.onCycleDeleteMode ?? () {},
          style: const Style(foreground: CharmColors.salmon),
        ),
        const SizedBox(width: 1, child: Text('')),
        Button(
          text: '[N:OSC99]',
          onPressed: actions.onSendNotification,
          style: const Style(foreground: CharmColors.dolly),
        ),
        const SizedBox(width: 1, child: Text('')),
        Button(
          text: '[C:OSC52]',
          onPressed: actions.onSendClipboard,
          style: const Style(foreground: CharmColors.salt),
        ),
        const SizedBox(width: 1, child: Text('')),
        Button(
          text: '[T:Title]',
          onPressed: actions.onCycleWindowTitle,
          style: const Style(foreground: CharmColors.smoke),
        ),
      ]),
    );
  }

  Widget _buildFooterBar() {
    return const SizedBox(
      height: 1,
      child: Text(
        ' Keys: [1-4] Tabs │ [R] Re-Probe │ [K] Kb │ [M] ?1016 │ [O] Occlude │ [D] DelMode │ [N] OSC99 │ [C] OSC52 │ [T] Title │ [S] OSC133 │ [E] Export │ [P] Copy │ [Q] Quit',
        style: Style(foreground: CharmColors.smoke, modifiers: Modifier.dim),
      ),
    );
  }

  static Widget _borderedPanel({
    required String title,
    required Color borderColor,
    required Widget child,
  }) {
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border.all(Style(foreground: borderColor)),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 1),
        child: LayoutBuilder(
          builder: (context, constraints) => Column([
            if (constraints.maxHeight >= 1)
              SizedBox(
                height: 1,
                child: Text(
                  title,
                  style: Style(
                    foreground: borderColor,
                    modifiers: Modifier.bold,
                  ),
                ),
              ),
            if (constraints.maxHeight >= 2) Expanded(child: child),
          ]),
        ),
      ),
    );
  }
}
