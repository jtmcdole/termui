import 'dart:math' as math;

import 'package:termui/termui.dart';

import 'ktty_probe_assets.dart';
import 'ktty_probe_report.dart';

/// Active view tab inside the KTTY Probe dashboard.
enum KttyProbeTab {
  /// Combined overview of capability matrix, graphics, SGR, and live telemetry.
  overview('1:Overview'),

  /// Full 17-row capability probe table with protocol tags and decoded replies.
  matrix('2:Matrix'),

  /// Kitty Graphics (`f=32`, 32-bit MSB, `f=100` PNG), occlusion, SGR & ligatures.
  graphicsAndSgr('3:Graphics&SGR'),

  /// Live Kitty Keyboard (`press`/`repeat`/`release`), `?1016` mouse, and `OSC` actions.
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

  /// Emits an `OSC 99` desktop notification sequence over the wire.
  final void Function() onSendNotification;

  /// Emits an `OSC 52` clipboard write sequence over the wire.
  final void Function() onSendClipboard;

  /// Emits an `OSC 2` window title update over the wire.
  final void Function() onCycleWindowTitle;

  /// Emits an `OSC 133` semantic prompt marker sequence over the wire.
  final void Function() onEmitPromptMarker;

  /// Exits the KTTY Probe program cleanly.
  final void Function() onQuit;

  /// Creates [KttyProbeActions].
  const KttyProbeActions({
    required this.onSelectTab,
    required this.onReprobe,
    required this.onCycleKittyKeyboard,
    required this.onToggleSgrPixels,
    required this.onToggleOcclusion,
    required this.onSendNotification,
    required this.onSendClipboard,
    required this.onCycleWindowTitle,
    required this.onEmitPromptMarker,
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

  /// Creates a [KttyProbeViewState].
  const KttyProbeViewState({
    required this.report,
    required this.activeTab,
    required this.requestedKeyboardFlags,
    required this.sgrPixelsEnabled,
    required this.showOcclusion,
    required this.keyLog,
    required this.lastActionMessage,
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

/// Stateless presentation layout for the KTTY Probe & Check TUI.
final class KttyProbeDashboard extends StatelessWidget {
  static final KittyImageData _rawTile = buildRawRgbaVisualTile(
    cols: 12,
    rows: 4,
  );
  static final KittyImageData _msbTile = buildMsb32BitVisualTile(
    cols: 12,
    rows: 4,
  );
  static final KittyImageData _pngTile = buildPngVisualTile(cols: 12, rows: 4);

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
    final total = r.entries.length;
    final ident = r.xtVersion ?? 'Probing XTVERSION...';
    final fg = r.defaultForegroundHex ?? '?';
    final bg = r.defaultBackgroundHex ?? '?';

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
              text: ' ${r.supportedCount}/$total PASS ',
              style: Style(
                foreground: r.supportedCount == total
                    ? CharmColors.julep
                    : CharmColors.butter,
                modifiers: Modifier.bold,
              ),
            ),
            TextSpan(
              text: '│ Term: $ident │ FG:$fg BG:$bg ',
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
    return _borderedPanel(
      title:
          'Capability Matrix (Run #${state.report.probeRunCount}${state.report.isComplete ? " - DA1 Complete" : " - Waiting"})',
      borderColor: CharmColors.charple,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final visible = entries.take(math.max(0, constraints.maxHeight));
          return Column([
            for (final entry in visible) _buildCapabilityRow(entry),
          ]);
        },
      ),
    );
  }

  Widget _buildCapabilityRow(KttyCapabilityEntry entry) {
    final (badge, color) = switch (entry.status) {
      .supported => ('PASS', CharmColors.julep),
      .unsupported => ('MISS', CharmColors.salmon),
      .pending => ('WAIT', CharmColors.butter),
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
              text: entry.name.padRight(23),
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
    return _borderedPanel(
      title:
          'Kitty Graphics (U+10EEEE) & Cell Occlusion [O:${state.showOcclusion ? "ON" : "OFF"}]',
      borderColor: CharmColors.malibu,
      child: Column([
        const SizedBox(
          height: 1,
          child: Text(
            ' f=32 RGBA24    32-bit MSB ID   f=100 PNG',
            style: Style(foreground: CharmColors.smoke),
          ),
        ),
        Expanded(
          child: Stack([
            Positioned(
              left: 1,
              top: 0,
              width: 42,
              height: 4,
              child: Row([
                KttyDataTileWidget(imageData: _rawTile),
                const SizedBox(width: 2, child: Text('')),
                KttyDataTileWidget(imageData: _msbTile),
                const SizedBox(width: 2, child: Text('')),
                KttyDataTileWidget(imageData: _pngTile),
              ]),
            ),
            if (state.showOcclusion)
              const Positioned(
                left: 10,
                top: 1,
                width: 22,
                height: 2,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    backgroundColor: CharmColors.pepper,
                  ),
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
              ),
          ]),
        ),
      ]),
    );
  }

  Widget _buildSgrAndLigaturesPanel() {
    return _borderedPanel(
      title: 'Extended SGR (4:1..5, 58:2, 53), Ligatures & OSC 8',
      borderColor: CharmColors.dolly,
      child: Column([
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
                    uri: 'https://sw.kovidgoyal.net/kitty/graphics-protocol/',
                  ),
                ),
              ],
            ),
          ),
        ),
      ]),
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
          final keySlots = math.max(0, avail - 4);
          final keys = state.keyLog.take(keySlots);
          final ackStyle = Style(
            foreground: state.report.hasOsc99Ack
                ? CharmColors.julep
                : CharmColors.smoke,
          );
          return Column([
            if (avail >= 1) _buildActionButtonsRow(),
            if (avail >= 2)
              SizedBox(
                height: 1,
                child: Text(
                  'Mouse: ${state.report.lastWireMousePacket}',
                  style: const Style(foreground: CharmColors.malibu),
                ),
              ),
            if (avail >= 3)
              SizedBox(
                height: 1,
                child: Text(
                  'OSC  : ${state.lastActionMessage}',
                  style: const Style(foreground: CharmColors.butter),
                ),
              ),
            if (avail >= 4)
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

  Widget _buildActionButtonsRow() {
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
        ' Keys: [1-4] Tabs │ [R] Re-Probe │ [K] Kitty Kb │ [M] ?1016 Pixels │ [O] Occlusion │ [N] OSC 99 │ [C] OSC 52 │ [T] OSC 2 │ [P] OSC 133 │ [Q] Quit',
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
