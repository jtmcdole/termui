import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:termui/termui.dart';

import 'terminal_theme_settings.dart';

export 'package:termui/termui.dart'
    show
        ResolvedTerminalLink,
        SelectionMode,
        SelectionRegion,
        VirtualLineLookup,
        VirtualLineSlice;

/// Default local relay server `/v1/client` WebSocket URL string.
const String defaultClientServerUrl = 'ws://127.0.0.1:8420/v1/client';

/// Matched hyperlink [Uri] (`http`, `https`, `mailto`, or `file`) and its
/// inclusive virtual-buffer [TerminalSelection] range.
typedef MatchedTerminalUrl = ({Uri url, TerminalSelection range});

/// Immutable client-side selection range in 0-indexed virtual buffer coordinates.
final class TerminalSelection {
  /// 0-indexed `(col, row)` cell where the selection gesture started.
  final Point<int> anchor;

  /// 0-indexed `(col, row)` cell where the selection gesture currently ends.
  final Point<int> focus;

  /// Selection geometry mode (`normal` stream or rectangular `box`).
  final SelectionMode mode;

  /// Optional pane region bounds confining stream selection inside split panes.
  final SelectionRegion? region;

  /// Whether a single-cell span (`anchor == focus`, e.g. a 1-char `OSC 8` link)
  /// is treated as non-collapsed.
  final bool allowSingleCell;

  /// Creates an immutable terminal selection range.
  const TerminalSelection({
    required this.anchor,
    required this.focus,
    this.mode = .normal,
    this.region,
    this.allowSingleCell = false,
  });

  /// Whether [anchor] and [focus] refer to the exact same cell when single-cell
  /// spans are disallowed.
  bool get isCollapsed => !allowSingleCell && anchor == focus;

  /// Returns `(start, end)` ordered top-to-bottom, left-to-right for [mode].
  (Point<int> start, Point<int> end) get normalized {
    if (mode == .box) {
      return (
        Point<int>(min(anchor.x, focus.x), min(anchor.y, focus.y)),
        Point<int>(max(anchor.x, focus.x), max(anchor.y, focus.y)),
      );
    }
    if (anchor.y < focus.y || (anchor.y == focus.y && anchor.x <= focus.x)) {
      return (anchor, focus);
    }
    return (focus, anchor);
  }

  TerminalSelectionController _toController() => TerminalSelectionController()
    ..startSelection(anchor.x, anchor.y, mode: mode, region: region)
    ..updateSelection(focus.x, focus.y, mode: mode);

  /// Whether the 0-indexed cell `([x], [y])` lies inside this non-collapsed selection.
  bool containsCell(int x, int y) {
    if (isCollapsed || x < 0 || y < 0) return false;
    return _toController().containsCell(x, y);
  }

  /// Intersects this selection with [buffer]'s `0..width-1` by `0..height-1`
  /// viewport (starting at [topVirtualRow] and horizontal [leftVirtualCol]) and
  /// snaps wide-grapheme continuation cells so highlight and extraction match.
  List<(int y, int colStart, int colEnd)> visibleRowSpans(
    Buffer buffer, {
    int topVirtualRow = 0,
    int leftVirtualCol = 0,
  }) {
    if (isCollapsed || buffer.width <= 0 || buffer.height <= 0) return const [];
    return _toController().visibleRowSpans(
      buffer,
      topVirtualRow: topVirtualRow,
      leftVirtualCol: leftVirtualCol,
    );
  }

  /// Intersects this selection with [buffer] at virtual offset `0`.
  List<(int y, int colStart, int colEnd)> rowSpans(Buffer buffer) =>
      visibleRowSpans(buffer);

  /// Paints this selection's visible spans onto [buffer] with [background],
  /// OR-ed [modifiers], and a per-cell foreground from [foregroundAt].
  ///
  /// `cellIndex` counts painted cells in row-major order after viewport
  /// clipping, and `totalCells` is their count.
  void paint(
    Buffer buffer, {
    int topVirtualRow = 0,
    int leftVirtualCol = 0,
    int? background,
    int modifiers = Modifier.none,
    int Function(int cellIndex, int totalCells)? foregroundAt,
  }) {
    final spans = visibleRowSpans(
      buffer,
      topVirtualRow: topVirtualRow,
      leftVirtualCol: leftVirtualCol,
    );
    final totalCells = _countSpanCells(spans);
    if (totalCells <= 0) return;

    var cellIndex = 0;
    for (final (y, colStart, colEnd) in spans) {
      final rowOffset = y * buffer.width;
      for (var x = colStart; x <= colEnd; x++) {
        final idx = cellIndex++;
        _paintCell(
          buffer.attributes,
          (rowOffset + x) * 3,
          fg: foregroundAt?.call(idx, totalCells),
          bg: background,
          modifiers: modifiers,
        );
      }
    }
  }

  static int _countSpanCells(List<(int y, int colStart, int colEnd)> spans) {
    var total = 0;
    for (final (_, colStart, colEnd) in spans) {
      total += colEnd - colStart + 1;
    }
    return total;
  }

  static void _paintCell(
    Uint32List attrs,
    int cellBase, {
    required int? fg,
    required int? bg,
    required int modifiers,
  }) {
    if (fg != null) attrs[cellBase] = fg;
    if (bg != null) attrs[cellBase + 1] = bg;
    attrs[cellBase + 2] =
        (attrs[cellBase + 2] & ~Modifier.transparent) | modifiers;
  }

  /// Extracts selected characters across [lineAt], joining soft-wrapped rows
  /// (`isWrapped == true`) without `\n` when [mode] is [SelectionMode.normal].
  String extractVirtualText(VirtualLineLookup lineAt, {required int cols}) {
    if (isCollapsed || cols <= 0) return '';
    return _toController().extractVirtualText(lineAt, cols: cols);
  }

  /// Extracts selected characters from [buffer], stripping trailing row padding
  /// and joining rows with `\n`.
  String extractText(Buffer buffer) {
    if (isCollapsed) return '';
    return _toController().extractSelectedText(buffer);
  }

  /// Matches an `OSC 8` (`http`, `https`, `mailto`, `file`) or plain-text
  /// (`http`, `https`, `mailto`) [Uri] and its [TerminalSelection] range
  /// spanning the 0-indexed virtual cell `([virtualX], [virtualY])` across
  /// soft-wrapped rows in [lineAt].
  static MatchedTerminalUrl? matchUrlAt(
    VirtualLineLookup lineAt, {
    required int virtualX,
    required int virtualY,
    required int cols,
  }) {
    if (virtualX < 0 || virtualY < 0 || cols <= 0) return null;
    final resolved = TerminalSelectionController.resolveLinkSpanAt(
      lookup: lineAt,
      col: virtualX,
      virtualRow: virtualY,
    );
    if (resolved == null) return null;
    final uri = _parseSupportedMatchedUri(resolved.uri);
    if (uri == null) return null;
    return (
      url: uri,
      range: TerminalSelection(
        anchor: Point<int>(resolved.startCol, resolved.startRow),
        focus: Point<int>(resolved.endCol, resolved.endRow),
        allowSingleCell: true,
      ),
    );
  }

  static Uri? _parseSupportedMatchedUri(String raw) {
    final uri = Uri.tryParse(raw);
    if (uri == null) return null;
    return switch (uri.scheme.toLowerCase()) {
      'http' || 'https' when uri.hasAuthority && uri.host.isNotEmpty => uri,
      'mailto' when !uri.hasAuthority && uri.path.isNotEmpty => uri,
      'file' when uri.path.isNotEmpty => uri,
      _ => null,
    };
  }

  /// Extracts a hyperlink [Uri] spanning the 0-indexed virtual cell
  /// `([virtualX], [virtualY])` across soft-wrapped rows in [lineAt].
  static Uri? extractUrlAt(
    VirtualLineLookup lineAt, {
    required int virtualX,
    required int virtualY,
    required int cols,
  }) => matchUrlAt(
    lineAt,
    virtualX: virtualX,
    virtualY: virtualY,
    cols: cols,
  )?.url;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TerminalSelection &&
          other.anchor == anchor &&
          other.focus == focus &&
          other.mode == mode &&
          other.region == region &&
          other.allowSingleCell == allowSingleCell;

  @override
  int get hashCode => Object.hash(anchor, focus, mode, region, allowSingleCell);
}

/// Client-side placement of the multi-session tab/dock bar.
enum DockPosition {
  /// Single-row horizontal tab bar docked at row `0`.
  top,

  /// Vertical session sidebar docked at column `0`.
  left,

  /// Chrome hidden; PTY occupies 100% of the viewport unless an attention banner is active.
  hidden;

  /// Cycles to the next dock position (`top -> left -> hidden -> top`).
  DockPosition get next => switch (this) {
    .top => .left,
    .left => .hidden,
    .hidden => .top,
  };
}

/// Policy governing inbound remote `OSC 52` clipboard writes on viewer clients.
enum Osc52ClipboardPolicy {
  /// Allow `OSC 52` writes only when the target session/pane has active focus
  /// and the payload is within the configured size bound.
  allowFocused,

  /// Ignore all inbound remote `OSC 52` clipboard writes.
  deny,
}

/// Immutable user preferences for a workspace, serializable to and from JSON
/// for browser `localStorage` persistence.
final class CastWorkspaceSettings {
  /// Maximum decoded UTF-8 byte size accepted from an inbound `OSC 52` write (`1 MiB`).
  static const int defaultMaxOsc52ClipboardBytes = 1024 * 1024;

  /// Default workspace settings (`dockPosition: top`, `copyOnSelect: true`,
  /// `debugOverlayEnabled: false`, `f12ShortcutsEnabled: false`,
  /// `osc52Policy: allowFocused`).
  static const CastWorkspaceSettings defaults = CastWorkspaceSettings();

  /// Placement of the multi-session tab/dock bar.
  final DockPosition dockPosition;

  /// Whether releasing a non-empty mouse selection automatically copies it.
  final bool copyOnSelect;

  /// Whether `termui` debug overlay rendering is enabled.
  final bool debugOverlayEnabled;

  /// Whether `F12` (screenshot) and `Shift+F12` (atlas reload) shortcuts are enabled.
  final bool f12ShortcutsEnabled;

  /// Terminal palette and theme configuration.
  final TerminalThemeSettings themeSettings;

  /// Inbound remote `OSC 52` clipboard security policy.
  final Osc52ClipboardPolicy osc52Policy;

  /// Creates an immutable workspace settings snapshot.
  const CastWorkspaceSettings({
    this.dockPosition = .top,
    this.copyOnSelect = true,
    this.debugOverlayEnabled = false,
    this.f12ShortcutsEnabled = false,
    this.themeSettings = const TerminalThemeSettings(),
    this.osc52Policy = .allowFocused,
  });

  /// Returns a copy of these settings with specified fields replaced.
  CastWorkspaceSettings copyWith({
    DockPosition? dockPosition,
    bool? copyOnSelect,
    bool? debugOverlayEnabled,
    bool? f12ShortcutsEnabled,
    TerminalThemeSettings? themeSettings,
    Osc52ClipboardPolicy? osc52Policy,
  }) => CastWorkspaceSettings(
    dockPosition: dockPosition ?? this.dockPosition,
    copyOnSelect: copyOnSelect ?? this.copyOnSelect,
    debugOverlayEnabled: debugOverlayEnabled ?? this.debugOverlayEnabled,
    f12ShortcutsEnabled: f12ShortcutsEnabled ?? this.f12ShortcutsEnabled,
    themeSettings: themeSettings ?? this.themeSettings,
    osc52Policy: osc52Policy ?? this.osc52Policy,
  );

  /// Encodes this settings snapshot to a JSON map.
  Map<String, Object?> toJson() => {
    'dockPosition': dockPosition.name,
    'copyOnSelect': copyOnSelect,
    'debugOverlayEnabled': debugOverlayEnabled,
    'f12ShortcutsEnabled': f12ShortcutsEnabled,
    'themeSettings': themeSettings.toJson(),
    'osc52Policy': osc52Policy.name,
  };

  /// Encodes this settings snapshot to a JSON string.
  String toJsonString() => jsonEncode(toJson());

  /// Parses a JSON string into [CastWorkspaceSettings], falling back to
  /// [defaultDockPosition] and safe boolean defaults when [raw] is `null`,
  /// malformed, or missing fields.
  static CastWorkspaceSettings fromJsonString(
    String? raw, {
    DockPosition defaultDockPosition = .top,
  }) {
    if (raw == null || raw.isEmpty) {
      return CastWorkspaceSettings(dockPosition: defaultDockPosition);
    }
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<Object?, Object?>) {
        return CastWorkspaceSettings(dockPosition: defaultDockPosition);
      }
      return CastWorkspaceSettings(
        dockPosition: _parseDockPosition(
          decoded['dockPosition'],
          defaultDockPosition,
        ),
        copyOnSelect: _parseBool(decoded['copyOnSelect'], fallback: true),
        debugOverlayEnabled: _parseBool(
          decoded['debugOverlayEnabled'],
          fallback: false,
        ),
        f12ShortcutsEnabled: _parseBool(
          decoded['f12ShortcutsEnabled'],
          fallback: false,
        ),
        themeSettings: TerminalThemeSettings.fromJson(decoded['themeSettings']),
        osc52Policy: _parseOsc52Policy(decoded['osc52Policy']),
      );
    } on FormatException {
      return CastWorkspaceSettings(dockPosition: defaultDockPosition);
    }
  }

  static DockPosition _parseDockPosition(Object? raw, DockPosition fallback) =>
      switch (raw) {
        'top' => .top,
        'left' => .left,
        'hidden' => .hidden,
        _ => fallback,
      };

  static Osc52ClipboardPolicy _parseOsc52Policy(Object? raw) => switch (raw) {
    'deny' => .deny,
    'allowFocused' => .allowFocused,
    _ => .allowFocused,
  };

  static bool _parseBool(Object? raw, {required bool fallback}) =>
      raw is bool ? raw : fallback;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CastWorkspaceSettings &&
          other.dockPosition == dockPosition &&
          other.copyOnSelect == copyOnSelect &&
          other.debugOverlayEnabled == debugOverlayEnabled &&
          other.f12ShortcutsEnabled == f12ShortcutsEnabled &&
          other.themeSettings == themeSettings &&
          other.osc52Policy == osc52Policy;

  @override
  int get hashCode => Object.hash(
    dockPosition,
    copyOnSelect,
    debugOverlayEnabled,
    f12ShortcutsEnabled,
    themeSettings,
    osc52Policy,
  );
}

/// Connection and authentication lifecycle states of a viewer workspace.
enum ClientConnectionState {
  /// Not yet connected (for example, awaiting initial dialog submission).
  unconnected,

  /// Dialing the WebSocket endpoint or awaiting authentication confirmation.
  connecting,

  /// Authenticated and synchronized with the relay server.
  authenticated,

  /// Transport dropped or dial failed; retrying with backoff.
  reconnecting,

  /// Relay rejected authentication (`auth_failed`, `auth_role`, `bad_auth`, `auth_timeout`).
  authFailed,
}

/// Validated connection parameters returned by the interactive connection dialog.
typedef CastEndpoint = ({Uri serverUri, String token});

/// Immutable snapshot of client network throughput, frame counts, and rolling
/// Sparkline history.
final class CastNetworkStats {
  /// Total inbound wire bytes decoded across the client lifecycle.
  final int totalRxBytes;

  /// Total outbound wire bytes encoded across the client lifecycle.
  final int totalTxBytes;

  /// Total inbound protocol frames decoded.
  final int totalRxFrames;

  /// Total full-buffer keyframes received.
  final int snapshotCount;

  /// Total incremental cell-run delta frames received.
  final int deltaCount;

  /// Inbound throughput in bytes per second for the active sampling bucket.
  final double currentRxBytesPerSec;

  /// Peak inbound throughput in bytes per second across the rolling window.
  final double peakRxBytesPerSec;

  /// Inbound frame rate in frames per second for the active sampling bucket.
  final double currentFramesPerSec;

  /// Peak inbound frame rate in frames per second across the rolling window.
  final double peakFramesPerSec;

  /// Rolling time-series history of inbound throughput (bytes/s), oldest to
  /// newest.
  final List<double> rxBytesPerSecHistory;

  /// Rolling time-series history of inbound frame rate (frames/s), oldest to
  /// newest.
  final List<double> framesPerSecHistory;

  /// Creates an immutable network telemetry snapshot.
  const CastNetworkStats({
    required this.totalRxBytes,
    required this.totalTxBytes,
    required this.totalRxFrames,
    required this.snapshotCount,
    required this.deltaCount,
    required this.currentRxBytesPerSec,
    required this.peakRxBytesPerSec,
    required this.currentFramesPerSec,
    required this.peakFramesPerSec,
    required this.rxBytesPerSecHistory,
    required this.framesPerSecHistory,
  });
}

/// Platform-neutral handle for a dropped browser or desktop file.
abstract interface class DroppedFileSource {
  /// Base file name reported by the drop source.
  String get name;

  /// Total file size in bytes.
  int get size;

  /// Whether the dropped entry is a directory (skipped in v0.1 flat-file mode).
  bool get isDirectory;

  /// Reads the half-open byte slice `[start, end)` from the underlying blob or file.
  Future<Uint8List> readSlice(int start, int end);
}

/// In-memory [DroppedFileSource] used by tests and pure-Dart callers.
final class MemoryDroppedFileSource implements DroppedFileSource {
  @override
  final String name;

  @override
  final bool isDirectory;

  final Uint8List _bytes;

  /// Creates an in-memory dropped file source.
  MemoryDroppedFileSource({
    required this.name,
    required Uint8List bytes,
    this.isDirectory = false,
  }) : _bytes = bytes;

  @override
  int get size => _bytes.length;

  @override
  Future<Uint8List> readSlice(int start, int end) async {
    final safeStart = start.clamp(0, _bytes.length);
    final safeEnd = end.clamp(safeStart, _bytes.length);
    return Uint8List.fromList(_bytes.sublist(safeStart, safeEnd));
  }
}

/// Immutable progress snapshot of an active multi-file upload batch.
final class FileUploadProgress {
  /// 1-indexed file number currently being uploaded (`1 .. fileCount`).
  final int fileIndex;

  /// Total number of valid files in the upload batch.
  final int fileCount;

  /// Sanitized display name of the file currently being uploaded.
  final String currentFileName;

  /// Confirmed bytes written across all files in the batch so far.
  final int overallSentBytes;

  /// Total bytes across all files in the batch.
  final int overallTotalBytes;

  /// Creates an immutable upload progress snapshot.
  const FileUploadProgress({
    required this.fileIndex,
    required this.fileCount,
    required this.currentFileName,
    required this.overallSentBytes,
    required this.overallTotalBytes,
  });

  /// Overall completion fraction in `0.0 .. 1.0`.
  double get fraction {
    if (overallTotalBytes <= 0) {
      return fileCount <= 0
          ? 1.0
          : ((fileIndex - 1) / fileCount).clamp(0.0, 1.0);
    }
    return (overallSentBytes / overallTotalBytes).clamp(0.0, 1.0);
  }
}
