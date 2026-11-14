import 'dart:async';
import 'dart:math';

import 'package:termui/termui.dart';

import '../cast_workspace_view_model.dart';
import '../models.dart';
import 'dialog_theme.dart';

/// Pure-Dart `termui` "Stats for Nerds" modal dialog rendering live braille
/// [Sparkline] graphs for inbound RX throughput (bytes/s) and frame rate
/// (frames/s) alongside session synchronization and frame counters.
final class StatsForNerdsDialog extends StatefulWidget {
  /// Backing workspace view model supplying [CastNetworkStats] and session
  /// state.
  final CastWorkspaceViewModel viewModel;

  /// Periodic refresh cadence while the dialog is mounted.
  final Duration refreshInterval;

  /// Creates a live network telemetry modal dialog widget.
  const StatsForNerdsDialog({
    super.key,
    required this.viewModel,
    this.refreshInterval = const Duration(milliseconds: 250),
  });

  /// Displays a centered [StatsForNerdsDialog] on [sceneManager] and completes
  /// when dismissed via `Enter`, `Escape`, `q`, `s`, `i`, button press, or
  /// clicking the backdrop barrier.
  static Future<void> show(
    SceneManager sceneManager, {
    required CastWorkspaceViewModel viewModel,
    bool barrierDismissible = true,
  }) async {
    final size = clampDialogSize(
      sceneManager.terminal.backend.size,
      preferredWidth: 68,
      minWidth: 24,
      preferredHeight: 16,
    );
    await showThemedDialog<void>(
      sceneManager,
      width: size.x,
      height: size.y,
      terminalTheme: viewModel.activeTerminalTheme,
      barrierDismissible: barrierDismissible,
      builder: (_) => StatsForNerdsDialog(viewModel: viewModel),
    );
  }

  @override
  State<StatsForNerdsDialog> createState() => _StatsForNerdsDialogState();
}

final class _StatsForNerdsDialogState extends State<StatsForNerdsDialog> {
  static const Style _defaultSectionStyle = Style(
    foreground: Color(130, 218, 255),
    modifiers: Modifier.bold,
  );
  static const Style _defaultRxSparklineStyle = Style(
    foreground: Color(98, 209, 150),
    background: Color(26, 32, 44),
  );
  static const Style _defaultFpsSparklineStyle = Style(
    foreground: Color(110, 200, 255),
    background: Color(26, 32, 44),
  );

  late final void Function() _removeVisualListener;
  Timer? _refreshTimer;

  @override
  void initState() {
    super.initState();
    _removeVisualListener = widget.viewModel.addVisualListener(
      _onTelemetryTick,
    );
    if (widget.refreshInterval > Duration.zero) {
      _refreshTimer = Timer.periodic(
        widget.refreshInterval,
        (_) => _onTelemetryTick(),
      );
    }
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    _refreshTimer = null;
    _removeVisualListener();
    super.dispose();
  }

  void _onTelemetryTick() {
    if (mounted) {
      setState(() {});
    }
  }

  static void _dismiss(BuildContext context) {
    PromptScope.of(context)?.done();
  }

  static ({Style section, Style rxSparkline, Style fpsSparkline})
  _resolveTelemetryStyles(WorkspaceChromeTheme chrome) {
    if (chrome == WorkspaceChromeTheme.defaultDark) {
      return (
        section: _defaultSectionStyle,
        rxSparkline: _defaultRxSparklineStyle,
        fpsSparkline: _defaultFpsSparklineStyle,
      );
    }
    final panelBg =
        chrome.panelDecoration.backgroundColor ?? const Color(20, 24, 32);
    final isLight = TerminalContrast.relativeLuminance(panelBg) >= 0.5;
    final trackBg = WorkspaceChromeTheme.shiftRgb(panelBg, isLight ? -12 : 8);
    final sectionFg = TerminalContrast.enforceMinimumContrast(
      chrome.actionButtonStyle.foreground ?? const Color(9, 105, 218),
      panelBg,
      minRatio: 4.5,
    );
    final rxFg = TerminalContrast.enforceMinimumContrast(
      chrome.buttonStyle.foreground ?? const Color(26, 127, 55),
      trackBg,
      minRatio: 3.5,
    );
    final fpsFg = TerminalContrast.enforceMinimumContrast(
      chrome.actionButtonStyle.foreground ?? const Color(9, 105, 218),
      trackBg,
      minRatio: 3.5,
    );
    return (
      section: Style(foreground: sectionFg, modifiers: Modifier.bold),
      rxSparkline: Style(foreground: rxFg, background: trackBg),
      fpsSparkline: Style(foreground: fpsFg, background: trackBg),
    );
  }

  @override
  Widget build(BuildContext context) {
    final vm = widget.viewModel;
    final stats = vm.networkStats;
    final scopeChrome = WorkspaceChromeScope.of(context);
    final chrome = scopeChrome == WorkspaceChromeTheme.defaultDark
        ? WorkspaceChromeTheme.fromTerminalTheme(vm.activeTerminalTheme)
        : scopeChrome;

    return DecoratedBox(
      decoration: chrome.panelDecoration,
      child: Padding(
        padding: const .symmetric(horizontal: 2, vertical: 1),
        child: FocusScope(
          autofocus: true,
          onKeyEvent: (event) {
            if (_isDismissKey(event)) {
              _dismiss(context);
              return true;
            }
            return false;
          },
          child: Column([
            Text(
              'Stats for Nerds - Network & Session Telemetry',
              style: chrome.titleStyle,
              wrap: false,
            ),
            Expanded(
              child: LayoutBuilder(
                builder: (_, constraints) => _buildBody(
                  vm: vm,
                  stats: stats,
                  chrome: chrome,
                  maxRows: max(0, constraints.maxHeight),
                ),
              ),
            ),
            Button(
              text: 'Close (Enter)',
              focused: true,
              onPressed: () => _dismiss(context),
              style: chrome.buttonStyle,
              focusedStyle: chrome.focusedButtonStyle,
            ),
          ], crossAxisAlignment: .stretch),
        ),
      ),
    );
  }

  static Widget _buildBody({
    required CastWorkspaceViewModel vm,
    required CastNetworkStats stats,
    required WorkspaceChromeTheme chrome,
    required int maxRows,
  }) {
    final sessionLabel = vm.activeSessionId?.value ?? 'none';
    final syncLabel = vm.activeSessionSyncState.name;
    final seq = vm.activeSessionSeq;
    final grid = '${vm.viewportCols}x${vm.viewportRows}';
    final rxRate = _formatBytes(stats.currentRxBytesPerSec.round());
    final rxPeak = _formatBytes(stats.peakRxBytesPerSec.round());
    final fpsNow = stats.currentFramesPerSec.toStringAsFixed(1);
    final fpsPeak = stats.peakFramesPerSec.toStringAsFixed(1);
    final sparklineH = maxRows >= 10 ? 2 : 1;
    final styles = _resolveTelemetryStyles(chrome);

    final entries = <({int rows, Widget widget})>[
      (
        rows: 1,
        widget: Text(
          'Endpoint: ${vm.serverUri} (${vm.connectionState.name})',
          style: chrome.rowStyle,
          wrap: false,
        ),
      ),
      (
        rows: 1,
        widget: Text(
          'Session:  $sessionLabel | Sync: $syncLabel | Seq: $seq | Grid: $grid',
          style: chrome.rowStyle,
          wrap: false,
        ),
      ),
      (
        rows: 1,
        widget: Text(
          'Traffic:  RX ${_formatBytes(stats.totalRxBytes)} | TX ${_formatBytes(stats.totalTxBytes)} | Snap: ${stats.snapshotCount} | Delta: ${stats.deltaCount}',
          style: chrome.rowStyle,
          wrap: false,
        ),
      ),
      (
        rows: 1,
        widget: Text(
          'RX Rate:  $rxRate/s (peak $rxPeak/s)',
          style: styles.section,
          wrap: false,
        ),
      ),
      (
        rows: sparklineH,
        widget: SizedBox(
          height: sparklineH,
          child: Sparkline(
            stats.rxBytesPerSecHistory,
            max: max(stats.peakRxBytesPerSec, 256.0),
            direction: .bottomToTop,
            barType: .braille,
            style: styles.rxSparkline,
          ),
        ),
      ),
      (
        rows: 1,
        widget: Text(
          'Frames/s: $fpsNow fps (peak $fpsPeak fps)',
          style: styles.section,
          wrap: false,
        ),
      ),
      (
        rows: sparklineH,
        widget: SizedBox(
          height: sparklineH,
          child: Sparkline(
            stats.framesPerSecHistory,
            max: max(stats.peakFramesPerSec, 4.0),
            direction: .bottomToTop,
            barType: .braille,
            style: styles.fpsSparkline,
          ),
        ),
      ),
      (
        rows: 1,
        widget: Text(
          'Enter / Esc / q / s / i: close',
          style: chrome.hintStyle,
          wrap: false,
        ),
      ),
    ];

    final children = <Widget>[];
    var usedRows = 0;
    for (final entry in entries) {
      if (usedRows + entry.rows > maxRows) break;
      children.add(entry.widget);
      usedRows += entry.rows;
    }
    return Column(children, crossAxisAlignment: .stretch);
  }

  static bool _isDismissKey(KeyEvent event) {
    if (event.type == .enter) return true;
    if (event.type != .character) return false;
    final key = event.key.toLowerCase();
    return key == 'q' || key == 's' || key == 'i';
  }

  static String _formatBytes(int bytes) => formatDialogByteCount(bytes);
}
