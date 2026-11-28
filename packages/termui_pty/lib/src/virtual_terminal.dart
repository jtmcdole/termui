import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:characters/characters.dart';
import 'package:termui/termui.dart';

import 'ansi_parser.dart';
import 'audio_apc_handler.dart';
import 'kitty_apc_handler.dart';
import 'scrollback_buffer.dart';
import 'shader_apc_handler.dart';

/// Host shader and cell-transform capability profile returned for `ESC _ S a=query`.
typedef TerminalShaderCapabilities = ({
  String backend,
  bool glsl,
  bool xform,
  bool region,
  int maxSlots,
  int maxRegions,
});

/// Callback returning current host shader capabilities for `ESC _ S a=query` replies.
typedef ShaderCapabilitiesProvider = TerminalShaderCapabilities Function();

/// Default capability profile when no GPU shader backend is configured.
const TerminalShaderCapabilities defaultDisabledShaderCapabilities = (
  backend: 'disabled',
  glsl: false,
  xform: true,
  region: false,
  maxSlots: ShaderApcParser.maxSlots,
  maxRegions: ShaderRegion.maxRegionsPerPane,
);

final class _ScreenShaderState {
  final Map<String, ShaderRegion> regions = <String, ShaderRegion>{};
  final CellTransformTable transforms = CellTransformTable();
  late final ShaderApcParser parser;

  _ScreenShaderState(void Function(TerminalShaderApcEvent event) onEvent) {
    parser = ShaderApcParser(onShaderEvent: onEvent);
  }

  void reset() {
    regions.clear();
    transforms.clear();
    parser.reset();
  }
}

/// Cursor visual style selected by `DECSCUSR` (`CSI Ps SP q`).
enum TerminalCursorShape {
  /// Terminal default cursor style (`Ps = 0`).
  defaultShape,

  /// Blinking block cursor (`Ps = 1`).
  blinkingBlock,

  /// Steady block cursor (`Ps = 2`).
  steadyBlock,

  /// Blinking underline cursor (`Ps = 3`).
  blinkingUnderline,

  /// Steady underline cursor (`Ps = 4`).
  steadyUnderline,

  /// Blinking vertical bar cursor (`Ps = 5`).
  blinkingBar,

  /// Steady vertical bar cursor (`Ps = 6`).
  steadyBar,
}

/// Semantic shell prompt region reported via `OSC 133` (`A`/`B`/`C`/`D`).
enum ShellPromptZone {
  /// Outside of an active prompt/command cycle (`OSC 133;D` or initial state).
  none,

  /// Inside the shell prompt (`OSC 133;A`).
  prompt,

  /// Inside the user command input line (`OSC 133;B`).
  commandInput,

  /// Inside the executing command's output (`OSC 133;C`).
  commandOutput,
}

/// Structured Kitty `OSC 99` desktop notification payload and callback flags.
typedef Osc99Notification = ({
  String id,
  String title,
  String body,
  bool reportActivation,
  bool reportClose,
});

typedef _SavedCursor = ({
  int x,
  int y,
  Style style,
  bool pendingWrap,
  bool originMode,
  bool g0DecGraphics,
  bool g1DecGraphics,
  bool useG1,
});

final class _PendingOsc99 {
  final StringBuffer title = StringBuffer();
  final StringBuffer body = StringBuffer();
  int totalLength = 0;
  bool reportActivation = false;
  bool reportClose = false;

  void append(String content, {required bool isBody, required int maxChars}) {
    final remaining = maxChars - totalLength;
    if (remaining <= 0 || content.isEmpty) return;
    var sliceLen = math.min(content.length, remaining);
    if (sliceLen < content.length) {
      final lastUnit = content.codeUnitAt(sliceLen - 1);
      if (lastUnit >= 0xD800 && lastUnit <= 0xDBFF) {
        sliceLen--;
      }
    }
    if (sliceLen <= 0) return;
    final slice = sliceLen == content.length
        ? content
        : content.substring(0, sliceLen);
    (isBody ? body : title).write(slice);
    totalLength += slice.length;
  }
}

/// A virtual terminal that maintains primary and alternate screen buffers,
/// cursor state, scroll margins, and terminal modes in response to ANSI/VT100
/// escape sequences.
final class VirtualTerminal implements TerminalHandler {
  static const List<int> _ansi16Rgb = [
    0x000000,
    0xAA0000,
    0x00AA00,
    0xAAAA00,
    0x0000AA,
    0xAA00AA,
    0x00AAAA,
    0xAAAAAA,
    0x555555,
    0xFF5555,
    0x55FF55,
    0xFFFF55,
    0x5555FF,
    0xFF55FF,
    0x55FFFF,
    0xFFFFFF,
  ];

  static const _SavedCursor _initialSavedCursor = (
    x: 0,
    y: 0,
    style: .empty,
    pendingWrap: false,
    originMode: false,
    g0DecGraphics: false,
    g1DecGraphics: false,
    useG1: false,
  );

  static const List<String> _decSpecialGraphics = [
    ' ',
    '◆',
    '▒',
    '␉',
    '␌',
    '␍',
    '␊',
    '°',
    '±',
    '␤',
    '␋',
    '┘',
    '┐',
    '┌',
    '└',
    '┼',
    '⎺',
    '⎻',
    '─',
    '⎼',
    '⎽',
    '├',
    '┤',
    '┴',
    '┬',
    '│',
    '≤',
    '≥',
    'π',
    '≠',
    '£',
    '·',
  ];

  static final RegExp _whitespaceRegex = RegExp(r'\s+');
  static final RegExp _conEmuOsc9Regex = RegExp(r'^\d+;');
  static const int _maxOsc52PayloadLength = 1_400_000;
  static const int _maxOsc52DecodedBytes = 1_048_576;
  static const int _maxTitleStackDepth = 20;
  static const int _maxKittyKbStackDepth = 16;
  static const int _maxOsc99Chars = 16 * 1024;
  static const int _maxPendingOsc99 = 32;
  static const int _maxCellGraphemeUnits = 32;

  /// The width of the virtual terminal in columns.
  int width;

  /// The height of the virtual terminal in rows.
  int height;

  /// Scoped Kitty Graphics image registry owned by this terminal instance.
  final KittyImageRegistry imageRegistry = KittyImageRegistry();

  /// Monotonically increasing revision of [imageRegistry], incremented on
  /// `APC G` image mutations and terminal resets.
  int get imageRegistryRevision => imageRegistry.revision;

  int _shaderMetadataRevision = 0;

  /// Monotonically increasing revision incremented whenever active buffer
  /// `shaderRegions`, `cellTransforms`, or scrollback overlay visibility mutates.
  int get shaderMetadataRevision => _shaderMetadataRevision;

  final Buffer _primaryBuffer;
  final ScrollbackBuffer _scrollback;
  List<bool> _primaryWrapped;
  bool _wrappingNextIndexDown = false;
  Buffer? _altBuffer;
  bool _usingAltScreen = false;
  late final _ScreenShaderState _primaryShaderState = _ScreenShaderState(
    _handleShaderEvent,
  );
  _ScreenShaderState? _altShaderState;

  _ScreenShaderState get _activeShaderState => _usingAltScreen
      ? (_altShaderState ?? _primaryShaderState)
      : _primaryShaderState;

  /// Primary-screen scrollback ring buffer (`maxLines == 0` disables retention).
  ScrollbackBuffer get scrollback => _scrollback;

  int _viewportOffset = 0;

  /// Current scrollback viewport offset (0 = active screen; >0 = scrolled
  /// back into history by N lines, clamped to `0..scrollback.retainedLines`).
  int get viewportOffset => _viewportOffset;
  set viewportOffset(int value) {
    final clamped = value.clamp(0, _scrollback.retainedLines);
    if (_viewportOffset != clamped) {
      _viewportOffset = clamped;
      _syncPrimaryShaderOverlays();
      _notifyListeners();
    }
  }

  final List<int> _promptLineIndices = [];

  /// The absolute line positions of semantic shell prompts (`OSC 133;A`).
  List<int> get promptLineIndices => List.unmodifiable(_promptLineIndices);

  /// Scrolls the scrollback viewport by [delta] lines.
  ///
  /// Positive [delta] scrolls further back into history, while negative [delta]
  /// scrolls forward towards the active screen. Clamped to `0..scrollback.retainedLines`.
  void scrollViewport(int delta) {
    _viewportOffset = (_viewportOffset + delta).clamp(
      0,
      _scrollback.retainedLines,
    );
    _syncPrimaryShaderOverlays();
    _notifyListeners();
  }

  /// Resets the scrollback viewport to the active screen (`viewportOffset = 0`).
  void resetViewport() {
    _viewportOffset = 0;
    _syncPrimaryShaderOverlays();
    _notifyListeners();
  }

  /// Jumps to the previous (`direction < 0` or `backward: true`) or next
  /// (`direction > 0` or `backward: false`) semantic shell prompt (`OSC 133;A`),
  /// returning `true` iff [viewportOffset] changed.
  bool jumpToPrompt({int? direction, bool? backward}) {
    final dir = direction ?? (backward == null ? -1 : (backward ? -1 : 1));
    if (dir == 0 || _promptLineIndices.isEmpty) return false;
    final isBackward = dir < 0;
    final currentTopLine = _scrollback.totalLines - _viewportOffset;
    final targetLine = isBackward
        ? _findPreviousPromptLine(currentTopLine)
        : _findNextPromptLine(currentTopLine);

    final maxOffset = _scrollback.retainedLines;
    final targetOffset = targetLine != null
        ? (_scrollback.totalLines - targetLine).clamp(0, maxOffset)
        : (isBackward ? _viewportOffset : 0);

    if (targetOffset == _viewportOffset) return false;
    _viewportOffset = targetOffset;
    _syncPrimaryShaderOverlays();
    _notifyListeners();
    return true;
  }

  int? _findPreviousPromptLine(int currentTopLine) {
    var low = 0;
    var high = _promptLineIndices.length - 1;
    int? result;
    while (low <= high) {
      final mid = (low + high) >>> 1;
      final line = _promptLineIndices[mid];
      if (line < currentTopLine) {
        result = line;
        low = mid + 1;
      } else {
        high = mid - 1;
      }
    }
    return result;
  }

  int? _findNextPromptLine(int currentTopLine) {
    var low = 0;
    var high = _promptLineIndices.length - 1;
    int? result;
    while (low <= high) {
      final mid = (low + high) >>> 1;
      final line = _promptLineIndices[mid];
      if (line > currentTopLine) {
        result = line;
        high = mid - 1;
      } else {
        low = mid + 1;
      }
    }
    return result;
  }

  int _lowerBoundPrompt(int targetLine) {
    var low = 0;
    var high = _promptLineIndices.length;
    while (low < high) {
      final mid = (low + high) >>> 1;
      if (_promptLineIndices[mid] < targetLine) {
        low = mid + 1;
      } else {
        high = mid;
      }
    }
    return low;
  }

  void _recordPromptLine() {
    if (_usingAltScreen) return;
    final absLine = _scrollback.totalLines + cursorY;
    if (_promptLineIndices.isEmpty || _promptLineIndices.last < absLine) {
      _promptLineIndices.add(absLine);
      return;
    }
    if (_promptLineIndices.last == absLine) return;
    final idx = _lowerBoundPrompt(absLine);
    if (idx < _promptLineIndices.length && _promptLineIndices[idx] == absLine) {
      return;
    }
    _promptLineIndices.insert(idx, absLine);
  }

  void _pruneEvictedPromptLines() {
    final minLine = _scrollback.maxLines <= 0
        ? _scrollback.totalLines
        : _scrollback.oldestLine;
    if (minLine <= 0 || _promptLineIndices.isEmpty) return;
    if (_promptLineIndices.first >= minLine) return;
    final keepIdx = _lowerBoundPrompt(minLine);
    _promptLineIndices.removeRange(0, keepIdx);
  }

  /// Returns whether visible row [row] (`0 <= row < height`) began via
  /// right-margin auto-wrap from the preceding row (`scrollback[totalLines - 1]`
  /// when `row == 0`).
  ///
  /// Always returns `false` while [isUsingAlternateScreen] is `true` or when
  /// [row] is out of bounds.
  bool isRowWrapped(int row) {
    if (_usingAltScreen || row < 0 || row >= height) return false;
    return _primaryWrapped[row];
  }

  /// The active screen buffer (primary or alternate screen).
  ///
  /// The returned [Buffer] switches between the primary and alternate buffers
  /// across `?47`, `?1047`, and `?1049` transitions, so callers should read
  /// [buffer] on each frame rather than caching it across writes.
  Buffer get buffer =>
      _usingAltScreen ? (_altBuffer ?? _primaryBuffer) : _primaryBuffer;

  /// Renders the visible viewport (including scrollback when [viewportOffset] > 0)
  /// into [target] (or a new [Buffer]) and registers [imageRegistry].
  Buffer renderBuffer([Buffer? target]) {
    final buf =
        target ??
        _createBuffer(width, height, transparent: transparentBackground);
    final copyW = math.min(width, buf.width);
    final copyH = math.min(height, buf.height);
    final src = buffer;
    final vOffset = _usingAltScreen ? 0 : _viewportOffset;

    for (var y = 0; y < copyH; y++) {
      final dstStart = y * buf.width;
      if (vOffset > 0 && y < vOffset) {
        final sbLine = _scrollback[_scrollback.totalLines - vOffset + y];
        _copyScrollbackRowToBuffer(
          buf,
          dstStart,
          copyW,
          sbLine,
          transparent: transparentBackground,
        );
      } else {
        final srcRow = vOffset > 0 ? y - vOffset : y;
        final srcStart = srcRow * src.width;
        buf.glyphCellList.copyCellsFrom(
          src.glyphCellList,
          dstStart,
          srcStart,
          copyW,
        );
        buf.attributes.setRange(
          dstStart * 3,
          (dstStart + copyW) * 3,
          src.attributes,
          srcStart * 3,
        );
        buf.copyCellAuxRangeFrom(src, dstStart, srcStart, copyW);
      }
    }
    buf.registerKittyRegistry(Rect(0, 0, width, height), imageRegistry);
    buf.shaderRegions.clear();
    buf.clearCellTransforms();
    if (vOffset == 0) {
      _copyShaderMetadataToBuffer(buf, src, copyW, copyH);
    }
    return buf;
  }

  static void _copyShaderMetadataToBuffer(
    Buffer dst,
    Buffer src,
    int copyW,
    int copyH,
  ) {
    final clip = Rect(0, 0, copyW, copyH);
    for (final region in src.shaderRegions) {
      final clipped = region.translatedAndClipped(0, 0, clip);
      if (clipped != null) {
        dst.addShaderRegion(clipped);
      }
    }
    final table = src.cellTransforms;
    if (table == null || table.isEmpty || src.width <= 0) return;
    for (final entry in table.entries) {
      final x = entry.key % src.width;
      final y = entry.key ~/ src.width;
      if (x < copyW && y < copyH) {
        dst.setCellTransform(x, y, entry.value);
      }
    }
  }

  static void _fillBlankAttributes(
    Buffer buf,
    int startCell,
    int endCell,
    bool transparent,
  ) {
    buf.attributes.fillRange(startCell * 3, endCell * 3, 0);
    if (transparent) {
      for (var i = startCell * 3 + 2; i < endCell * 3; i += 3) {
        buf.attributes[i] = Modifier.transparent;
      }
    }
  }

  static void _copyScrollbackRowToBuffer(
    Buffer buf,
    int dstStart,
    int copyW,
    ScrollbackLine? sbLine, {
    required bool transparent,
  }) {
    if (sbLine == null) {
      buf.glyphCellList.fillCodeRange(
        dstStart,
        dstStart + copyW,
        GlyphCellList.spaceCode,
      );
      _fillBlankAttributes(buf, dstStart, dstStart + copyW, transparent);
      buf.clearCellAuxRange(dstStart, dstStart + copyW);
      return;
    }
    buf.writeCellAuxSlices(
      dstStart,
      copyW,
      underlineColors: sbLine.underlineColors,
      uris: sbLine.uris,
    );
    final sbCells = sbLine.glyphCellList;
    final n = math.min(sbCells.length, copyW);
    if (n > 0) {
      buf.glyphCellList.copyCellsFrom(sbCells, dstStart, 0, n);
      buf.attributes.setRange(
        dstStart * 3,
        (dstStart + n) * 3,
        sbLine.attributes,
        0,
      );
    }
    if (n < copyW) {
      buf.glyphCellList.fillCodeRange(
        dstStart + n,
        dstStart + copyW,
        GlyphCellList.spaceCode,
      );
      _fillBlankAttributes(buf, dstStart + n, dstStart + copyW, transparent);
    }
  }

  int _cellPixelWidth;
  int _cellPixelHeight;

  /// Width of a single character cell in pixels (reported via `CSI 16 t` and `CSI 14 t`).
  int get cellPixelWidth => _cellPixelWidth;

  /// Height of a single character cell in pixels (reported via `CSI 16 t` and `CSI 14 t`).
  int get cellPixelHeight => _cellPixelHeight;

  /// Updates the cell pixel dimensions (`>= 1`) used for `XTWINOPS` (`14t`/`16t`),
  /// Kitty graphics sizing, `DECSET 2048` in-band resize reports, and `?1016` mouse scaling.
  void setCellPixelSize(int pixelWidth, int pixelHeight) {
    final nextW = math.max(1, pixelWidth);
    final nextH = math.max(1, pixelHeight);
    if (_cellPixelWidth == nextW && _cellPixelHeight == nextH) return;
    _cellPixelWidth = nextW;
    _cellPixelHeight = nextH;
    if (_inBandWindowResize) {
      _replyWindowResize();
    }
    _notifyListeners();
  }

  /// Whether the alternate screen buffer (`?47`, `?1047`, or `?1049`) is active.
  bool get isUsingAlternateScreen => _usingAltScreen;

  /// The 0-indexed X coordinate of the cursor (`cursorX == width` indicates
  /// right-margin pending wrap when [autoWrapMode] is `true`).
  int cursorX = 0;

  /// The 0-indexed Y coordinate of the cursor.
  int cursorY = 0;

  bool _cursorVisible = true;

  /// Whether the cursor is visible (`DECTCEM` `?25h` / `?25l`).
  bool get cursorVisible => _cursorVisible;

  bool _autoWrap = true;

  /// Whether right-margin auto-wrap (`DECAWM` `?7h` / `?7l`) is enabled.
  bool get autoWrapMode => _autoWrap;

  bool _insertMode = false;

  /// Whether ANSI Insert/Replace Mode (`IRM`, `CSI 4 h` / `CSI 4 l`) is enabled.
  bool get insertMode => _insertMode;

  bool _originMode = false;

  /// Whether Origin Mode (`DECOM`, `?6h` / `?6l`) is enabled.
  bool get originMode => _originMode;

  int _scrollTop = 0;
  int _scrollBottom;
  Style _currentStyle = .empty;
  String? _lastPrintedGrapheme;
  int? _lastPrintedCellX;
  int? _lastPrintedCellY;
  bool _g0DecGraphics = false;
  bool _g1DecGraphics = false;
  bool _useG1 = false;
  final Set<int> _tabStops = {};
  _SavedCursor _savedPrimary = _initialSavedCursor;
  _SavedCursor _savedAlt = _initialSavedCursor;
  late AnsiParser _parser;
  late ByteConversionSink _utf8Sink;

  /// Whether the terminal background should be rendered as transparent.
  final bool transparentBackground;

  /// The default foreground color applied to characters when no explicit color is set.
  final Color? defaultForeground;

  int _mouseTrackingMask = 0;

  /// Whether mouse tracking is enabled (set by DECSET `9`, `1000`, `1002`, or `1003`).
  bool get mouseTrackingEnabled => _mouseTrackingMask != 0;

  set mouseTrackingEnabled(bool value) {
    _mouseTrackingMask = value
        ? (_mouseTrackingMask == 0 ? _mouseModeBit(1000) : _mouseTrackingMask)
        : 0;
  }

  /// Whether SGR mouse reporting mode is enabled (set by DECSET `1006`).
  bool sgrMouseMode = false;

  /// Whether SGR-Pixels mouse reporting mode is enabled (set by DECSET `1016`).
  bool sgrPixelsMouseMode = false;

  bool _focusReporting = false;

  /// Whether focus reporting (`DECSET 1004`, `?1004h` / `?1004l`) is enabled.
  bool get focusReportingEnabled => _focusReporting;

  TerminalCursorShape _cursorShape = .defaultShape;

  /// The active cursor visual style set via `DECSCUSR` (`CSI Ps SP q`).
  TerminalCursorShape get cursorShape => _cursorShape;

  /// Whether bracketed paste mode (`DECSET 2004`, `?2004h` / `?2004l`) is enabled.
  bool bracketedPasteMode = false;

  bool _applicationCursorKeys = false;

  /// Whether application cursor keys mode (`DECCKM`, `?1h` / `?1l`) is enabled.
  bool get applicationCursorKeys => _applicationCursorKeys;

  bool _alternateScrollMode = true;

  /// Whether alternate scroll mode (`DECSET 1007`, `?1007h` / `?1007l`) is enabled.
  bool get alternateScrollMode => _alternateScrollMode;

  static const Duration _defaultSyncSafetyTimeout = Duration(milliseconds: 100);
  static const int _maxSyncBatchCount = 100;

  final Duration? _syncSafetyTimeout;
  bool _inSyncUpdate = false;
  Timer? _syncSafetyTimer;
  int _syncBatchCount = 0;
  bool _pendingSyncNotify = false;
  bool _dirtySinceLastNotify = false;

  /// Whether synchronized output mode (`DECSET 2026`, `?2026h` / `?2026l`) is enabled.
  bool get synchronizedOutput => _inSyncUpdate;

  set synchronizedOutput(bool value) {
    if (_inSyncUpdate == value) return;
    _setSynchronizedOutput(value);
  }

  bool _graphemeClusterMode = false;

  /// Whether Unicode grapheme clustering mode (`DECSET 2027`, `?2027h` / `?2027l`) is enabled.
  bool get graphemeClusterMode => _graphemeClusterMode;

  int _primaryKittyKbFlags = 0;
  final List<int> _primaryKittyKbStack = [];
  int _altKittyKbFlags = 0;
  final List<int> _altKittyKbStack = [];

  /// Active Kitty keyboard protocol progressive enhancement flags for the active screen.
  int get kittyKeyboardFlags =>
      _usingAltScreen ? _altKittyKbFlags : _primaryKittyKbFlags;

  set kittyKeyboardFlags(int value) {
    final masked = value & 0x1F;
    if (_usingAltScreen) {
      _altKittyKbFlags = masked;
    } else {
      _primaryKittyKbFlags = masked;
    }
  }

  List<int> get _activeKittyKbStack =>
      _usingAltScreen ? _altKittyKbStack : _primaryKittyKbStack;

  /// Current window title set via `OSC 0` or `OSC 2` and restored via `CSI 23 t`.
  String windowTitle = '';

  /// Current icon / tab title set via `OSC 0` or `OSC 1` and restored via `CSI 23 t`.
  String iconTitle = '';

  final List<String> _windowTitleStack = [];
  final List<String> _iconTitleStack = [];

  /// Callback invoked when [windowTitle] changes via `OSC 0`, `OSC 2`, or `CSI 23 t`.
  void Function(String title)? onTitleChanged;

  /// Current working directory reported via `OSC 7` (`file://hostname/path`).
  String? workingDirectory;

  String? _activeUri;

  /// Active semantic shell prompt zone reported via `OSC 133`.
  ShellPromptZone promptZone = .none;

  /// Exit status reported by the most recent `OSC 133;D;<exitCode>` sequence.
  int? lastCommandExitCode;

  /// Callback invoked when [workingDirectory] is updated via `OSC 7`.
  void Function(String directory)? onWorkingDirectoryChanged;

  /// Callback invoked when an `OSC 133` semantic prompt transition occurs.
  void Function(ShellPromptZone zone, {int? exitCode})? onShellIntegration;

  /// Callback invoked when an `OSC 52` clipboard write sequence is decoded.
  ///
  /// The `selection` parameter is the target selection buffer (e.g. `'c'` for
  /// clipboard or `'p'` for primary), and `text` is the decoded UTF-8 string.
  void Function(String selection, String text)? onClipboardWrite;

  /// Callback invoked when a remote application sends an `OSC 52` clipboard
  /// read query (`\x1b]52;<selection>;?\x07`), which is blocked for security.
  void Function(String selection)? onClipboardReadBlocked;

  /// Callback invoked when the terminal generates an escape sequence reply to a
  /// terminal query (`DSR`, `CPR`, `DECXCPR`, `DA1`, `DA2`, `DECRQM`, or `XTWINOPS 18t`).
  void Function(String reply)? onReply;

  /// The default background color applied when querying background color via OSC 11.
  final Color? defaultBackground;

  /// Emits [Color.ansi] values instead of eager RGB for palette SGR codes.
  final bool emitIndexedColors;

  /// Optional theme palette used to answer `OSC 4`, `OSC 10/11/12`, and
  /// `CSI ? 996 n` queries when explicit overrides are not set.
  final TerminalColorTheme? theme;

  /// The default cursor color reported by `OSC 12 ; ?`.
  final Color? defaultCursorColor;

  final Map<int, Color> _osc4Overrides = <int, Color>{};
  Color? _osc10Override;
  Color? _osc11Override;
  Color? _osc12Override;
  TerminalBrightness _colorScheme;
  bool _colorSchemeReporting = false;
  bool _inBandWindowResize = false;

  /// Whether in-band window resize notifications (`DECSET 2048`) are enabled.
  bool get inBandWindowResize => _inBandWindowResize;

  /// Callback invoked when an `OSC 9` or `OSC 99` desktop notification is received.
  void Function(String title, String message)? onNotification;

  /// Callback invoked with full Kitty `OSC 99` metadata (`id`, `a=report`, `c=1`).
  void Function(Osc99Notification notification)? onOsc99Notification;

  /// Callback invoked when the active `OSC 22` mouse cursor shape changes.
  void Function(String? shape)? onMouseCursorChanged;

  static const int _maxPointerShapeStackDepth = 64;
  static const int _maxOsc22QueryTokens = 64;
  static const int _maxOsc99IdLength = 128;
  static final RegExp _osc22ValidShapeRegex = RegExp(r'^[a-z0-9_-]{1,64}$');
  final List<String?> _pointerShapeStack = [];

  /// Active `OSC 22` mouse cursor shape name (e.g. `'pointer'`), or `null` for default.
  String? get mouseCursorShape =>
      _pointerShapeStack.isEmpty ? null : _pointerShapeStack.last;

  /// Callback invoked when the terminal receives a `BEL` (`0x07`) control character.
  void Function()? onBell;

  /// Callback invoked when an `ESC _ A` audio APC event is decoded.
  void Function(TerminalAudioEvent event)? onAudioEvent;

  /// Callback invoked when an `ESC _ S` artistic shader or cell-transform event is decoded.
  void Function(TerminalShaderApcEvent event)? onShaderEvent;

  /// Optional provider returning current host shader capabilities for `ESC _ S a=query`.
  ShaderCapabilitiesProvider? shaderCapabilitiesProvider;

  /// Configures a static [TerminalShaderCapabilities] profile for `ESC _ S a=query` replies.
  void setShaderCapabilities(TerminalShaderCapabilities capabilities) {
    shaderCapabilitiesProvider = () => capabilities;
  }

  static final RegExp _osc99UnsafeIdChars = RegExp(r'[^a-zA-Z0-9_.\-]');

  static String _sanitizeOsc99Id(String id) {
    final cleaned = id.replaceAll(_osc99UnsafeIdChars, '');
    return cleaned.length <= _maxOsc99IdLength
        ? cleaned
        : cleaned.substring(0, _maxOsc99IdLength);
  }

  /// Emits a Kitty `OSC 99` activation event reply (`\x1b]99;i=<id>;\x1b\\`) via [onReply].
  void reportNotificationActivated(String id) {
    final safeId = _sanitizeOsc99Id(id);
    onReply?.call('\x1b]99;i=$safeId;\x1b\\');
  }

  /// Emits a Kitty `OSC 99` close event reply (`\x1b]99;i=<id>:p=close;\x1b\\`) via [onReply].
  void reportNotificationClosed(String id) {
    final safeId = _sanitizeOsc99Id(id);
    onReply?.call('\x1b]99;i=$safeId:p=close;\x1b\\');
  }

  final Map<String, _PendingOsc99> _pendingOsc99 = {};

  /// Whether local Kitty Graphics Protocol transmission media (`t=t` temp files
  /// and, unless [allowLocalKittyShm] overrides it, `t=s` POSIX shared memory)
  /// are permitted on this terminal.
  ///
  /// Defaults to `false` so untrusted or remote PTY streams cannot read or
  /// unlink local temp/shared-memory files unless explicitly opted in.
  final bool allowLocalKittyMedia;

  /// Whether POSIX shared-memory (`t=s`) transmission is permitted.
  ///
  /// Defaults to [allowLocalKittyMedia]. Pass `allowLocalKittyMedia: true` with
  /// `allowLocalKittyShm: false` to allow only `t=t` temp files.
  final bool allowLocalKittyShm;

  late final KittyApcHandler _kittyApcHandler = KittyApcHandler(
    registry: imageRegistry,
    onReply: (reply) => onReply?.call(reply),
    onPlaceVirtual: _placeVirtualImage,
    onClearPlacements: _clearKittyPlacements,
    cellPixelSize: () => (_cellPixelWidth, _cellPixelHeight),
    allowLocalMedia: allowLocalKittyMedia,
    allowLocalShm: allowLocalKittyShm,
  );

  late final AudioApcHandler _audioApcHandler = AudioApcHandler(
    onAudioEvent: (event) => onAudioEvent?.call(event),
  );

  final List<void Function()> _listeners = [];

  /// Creates a new virtual terminal with the specified dimensions and settings.
  VirtualTerminal({
    int width = 80,
    int height = 24,
    int cellPixelWidth = 8,
    int cellPixelHeight = 16,
    this.transparentBackground = false,
    this.defaultForeground,
    this.defaultBackground,
    this.emitIndexedColors = false,
    this.theme,
    this.defaultCursorColor,
    TerminalBrightness? colorScheme,
    int maxScrollbackLines = 0,
    Duration? syncSafetyTimeout = _defaultSyncSafetyTimeout,
    this.onReply,
    this.onNotification,
    this.onMouseCursorChanged,
    this.onBell,
    this.onAudioEvent,
    this.onShaderEvent,
    this.shaderCapabilitiesProvider,
    this.allowLocalKittyMedia = false,
    bool? allowLocalKittyShm,
  }) : allowLocalKittyShm = allowLocalKittyShm ?? allowLocalKittyMedia,
       width = math.max(1, width),
       _colorScheme =
           colorScheme ?? theme?.brightness ?? TerminalBrightness.dark,
       height = math.max(1, height),
       _cellPixelWidth = math.max(1, cellPixelWidth),
       _cellPixelHeight = math.max(1, cellPixelHeight),
       _scrollBottom = math.max(1, height) - 1,
       _scrollback = ScrollbackBuffer(maxLines: maxScrollbackLines),
       _syncSafetyTimeout = syncSafetyTimeout,
       _primaryWrapped = List<bool>.filled(math.max(1, height), false),
       _primaryBuffer = _createBuffer(
         math.max(1, width),
         math.max(1, height),
         transparent: transparentBackground,
       ) {
    _primaryBuffer.registerKittyRegistry(
      Rect(0, 0, this.width, this.height),
      imageRegistry,
    );
    _resetDefaultTabStops();
    _initParser();
  }

  void _resetDefaultTabStops() {
    _tabStops
      ..clear()
      ..addAll([for (var col = 8; col < width; col += 8) col]);
  }

  void _resolvePendingWrapBeforeWrite() {
    if (cursorX >= width && _autoWrap) {
      _wrapLineDown();
    }
  }

  void _placeVirtualImage(
    int cols,
    int rows,
    int imageId,
    bool advanceCursor,
    int placementId,
  ) {
    if (advanceCursor) {
      _resolvePendingWrapBeforeWrite();
    }

    final maskedId = imageId & 0xFFFF_FFFF;
    final startX = cursorX.clamp(0, width - 1);
    final validCols = math.max(
      1,
      math.min(cols, math.min(width - startX, kittyDiacritics.length)),
    );
    final totalRows = math.max(1, math.min(rows, kittyDiacritics.length));
    final fgArgb = 0xFF00_0000 | (maskedId & 0xFF_FFFF);
    final imageIdMsb = (maskedId >>> 24) & 0xFF;
    final ulArgb = _kittyDirectPlacementTag | (placementId & 0xFF_FFFF);

    if (!advanceCursor) {
      final startY = cursorY.clamp(0, height - 1);
      final clippedRows = math.max(1, math.min(totalRows, height - startY));
      for (var r = 0; r < clippedRows; r++) {
        _writeKittyImageRow(
          startX,
          startY + r,
          r,
          validCols,
          fgArgb,
          imageIdMsb,
          ulArgb,
        );
      }
      return;
    }

    var y = cursorY.clamp(0, height - 1);
    final usesScrollRegion = y <= _scrollBottom;
    for (var r = 0; r < totalRows; r++) {
      if (r > 0) {
        if (usesScrollRegion && y >= _scrollBottom) {
          _scrollRegion(
            _scrollTop,
            _scrollBottom,
            1,
            up: true,
            evictTop: _scrollTop == 0,
          );
          y = _scrollBottom;
        } else if (y < height - 1) {
          y++;
        } else {
          break;
        }
      }
      _writeKittyImageRow(startX, y, r, validCols, fgArgb, imageIdMsb, ulArgb);
    }

    cursorY = y;
    cursorX = startX;
    _advanceCursorAfterPrint(validCols);
  }

  static const int _kittyDirectPlacementTag = 0xFE00_0000;

  static bool _matchesClearUnderline(
    int cellUnderline,
    int? placementId,
    bool directOnly,
  ) {
    final isDirect = (cellUnderline & 0xFF00_0000) == _kittyDirectPlacementTag;
    if (directOnly && !isDirect) return false;
    if (placementId == null) return true;
    final masked = placementId & 0xFF_FFFF;
    if (directOnly) return cellUnderline == (_kittyDirectPlacementTag | masked);
    return cellUnderline == (_kittyDirectPlacementTag | masked) ||
        (placementId > 0 && cellUnderline == (0xFF00_0000 | masked));
  }

  void _clearKittyPlacements(
    int? imageId, {
    int? placementId,
    bool directOnly = false,
  }) {
    final active = buffer;
    for (var y = 0; y < height; y++) {
      _clearKittyPlacementsInRow(active, y, imageId, placementId, directOnly);
    }
  }

  void _clearKittyPlacementsInRow(
    Buffer active,
    int y,
    int? imageId,
    int? placementId,
    bool directOnly,
  ) {
    var activeImageId = 0;
    var activeUnderline = 0;
    final rowBase = y * width;
    for (var x = 0; x < width; x++) {
      final cellIdx = rowBase + x;
      if (!Modifier.has(
        active.attributes[cellIdx * 3 + 2],
        Modifier.kittyPlaceholder,
      )) {
        activeImageId = 0;
        activeUnderline = 0;
        continue;
      }
      final cellChar = active.getCharacter(x, y);
      final cellFg = active.attributes[cellIdx * 3];
      final cellUnderline = active.getUnderlineColor(x, y);
      final inherits =
          activeImageId != 0 &&
          cellUnderline == activeUnderline &&
          (cellChar == kittyPlaceholderChar ||
              (cellChar.length == 3 &&
                  cellChar.startsWith(kittyPlaceholderChar))) &&
          extractKittyCellImageId(cellChar, cellFg) ==
              (activeImageId & 0xFFFFFF);
      final cellId = inherits
          ? activeImageId
          : extractKittyCellImageId(cellChar, cellFg);
      activeImageId = cellId;
      activeUnderline = cellUnderline;
      final matchesId = imageId == null || cellId == imageId;
      if (matchesId &&
          _matchesClearUnderline(cellUnderline, placementId, directOnly)) {
        _resetSplitCell(active, cellIdx);
      }
    }
  }

  void _writeKittyImageRow(
    int startX,
    int y,
    int tileRow,
    int validCols,
    int fgArgb,
    int imageIdMsb,
    int underlineColor,
  ) {
    for (var c = 0; c < validCols; c++) {
      buffer.setAttributes(
        startX + c,
        y,
        char: kittyPlaceholderCell(tileRow, c, imageIdMsb: imageIdMsb),
        fg: fgArgb,
        bg: 0,
        modifiers: Modifier.kittyPlaceholder,
        underlineColor: underlineColor,
        uri: '',
        blend: false,
      );
    }
  }

  static Buffer _createBuffer(int w, int h, {required bool transparent}) =>
      transparent
      ? Buffer(w, h, defaultBlend: false)
      : Buffer.blank(w, h, defaultBlend: false);

  Buffer _newBuffer(int w, int h) =>
      _createBuffer(w, h, transparent: transparentBackground)
        ..registerKittyRegistry(Rect(0, 0, w, h), imageRegistry);

  void _initParser() {
    _parser = AnsiParser(this);
    _utf8Sink = const Utf8Decoder(
      allowMalformed: true,
    ).startChunkedConversion(_ParserStringSink(_parser.parse));
  }

  /// Adds a listener to be notified when the terminal buffer changes.
  void addListener(void Function() listener) {
    _listeners.add(listener);
  }

  /// Removes a previously added listener.
  void removeListener(void Function() listener) {
    _listeners.remove(listener);
  }

  /// Disposes of resources.
  void dispose() {
    _syncSafetyTimer?.cancel();
    _syncSafetyTimer = null;
    _pendingOsc99.clear();
    _pointerShapeStack.clear();
    _kittyApcHandler.reset();
    _audioApcHandler.reset();
    _primaryShaderState.reset();
    _altShaderState?.reset();
    _altShaderState = null;
    _utf8Sink.close();
    _listeners.clear();
  }

  void _dispatchListeners() {
    for (final listener in _listeners) {
      listener();
    }
  }

  void _notifyListeners() {
    if (_inSyncUpdate) {
      _pendingSyncNotify = true;
      _syncBatchCount++;
      if (_syncBatchCount >= _maxSyncBatchCount) {
        _onSyncSafetyTimeout();
      }
      return;
    }
    _dirtySinceLastNotify = false;
    _dispatchListeners();
  }

  void _setSynchronizedOutput(bool enable) {
    if (enable) {
      _inSyncUpdate = true;
      _syncBatchCount = 0;
      _syncSafetyTimer?.cancel();
      final timeout = _syncSafetyTimeout;
      _syncSafetyTimer = timeout != null
          ? Timer(timeout, _onSyncSafetyTimeout)
          : null;
      return;
    }
    _syncSafetyTimer?.cancel();
    _syncSafetyTimer = null;
    _syncBatchCount = 0;
    _inSyncUpdate = false;
    if (_pendingSyncNotify || _dirtySinceLastNotify) {
      _pendingSyncNotify = false;
      _notifyListeners();
    }
  }

  void _onSyncSafetyTimeout() {
    _syncSafetyTimer?.cancel();
    _syncSafetyTimer = null;
    _syncBatchCount = 0;
    _inSyncUpdate = false;
    if (_pendingSyncNotify || _dirtySinceLastNotify) {
      _pendingSyncNotify = false;
      _notifyListeners();
    }
  }

  void _markDirty() {
    _dirtySinceLastNotify = true;
    if (_inSyncUpdate) {
      _pendingSyncNotify = true;
    }
  }

  /// Resets the terminal to its initial power-on state, exiting alternate
  /// screen, clearing the primary screen, resetting cursor/SGR/mode state, and
  /// discarding partial UTF-8 or escape sequences.
  void reset() {
    _utf8Sink.close();
    _initParser();
    _resetState(fullReset: true);
    _dirtySinceLastNotify = false;
    _dispatchListeners();
  }

  void _resetState({required bool fullReset}) {
    _currentStyle = .empty;
    _lastPrintedGrapheme = null;
    _clearLastPrintedCell();
    _g0DecGraphics = false;
    _g1DecGraphics = false;
    _useG1 = false;
    _cursorVisible = true;
    _autoWrap = true;
    _insertMode = false;
    _originMode = false;
    _mouseTrackingMask = 0;
    sgrMouseMode = false;
    sgrPixelsMouseMode = false;
    _focusReporting = false;
    _inBandWindowResize = false;
    _cursorShape = .defaultShape;
    bracketedPasteMode = false;
    _applicationCursorKeys = false;
    _alternateScrollMode = true;
    _inSyncUpdate = false;
    _pendingSyncNotify = false;
    _syncBatchCount = 0;
    _syncSafetyTimer?.cancel();
    _syncSafetyTimer = null;
    _pendingOsc99.clear();
    final previousCursorShape = mouseCursorShape;
    _pointerShapeStack.clear();
    if (previousCursorShape != null) {
      onMouseCursorChanged?.call(null);
    }
    _graphemeClusterMode = false;
    _primaryKittyKbFlags = 0;
    _primaryKittyKbStack.clear();
    _altKittyKbFlags = 0;
    _altKittyKbStack.clear();
    _scrollTop = 0;
    _scrollBottom = height - 1;
    if (fullReset) {
      _osc4Overrides.clear();
      _osc10Override = null;
      _osc11Override = null;
      _osc12Override = null;
      _colorSchemeReporting = false;
      _resetFullScreenState();
    } else {
      _resetSavedCursorOnly();
      _resetActiveShaderState();
    }
    onShaderEvent?.call(const TerminalResetShaderEvent(target: .all));
  }

  void _resetFullScreenState() {
    _kittyApcHandler.reset();
    _audioApcHandler.reset();
    _primaryShaderState.reset();
    _altShaderState?.reset();
    _altShaderState = null;
    _resetDefaultTabStops();
    _savedPrimary = _initialSavedCursor;
    _savedAlt = _initialSavedCursor;
    _usingAltScreen = false;
    _altBuffer = null;
    cursorX = 0;
    cursorY = 0;
    windowTitle = '';
    iconTitle = '';
    _windowTitleStack.clear();
    _iconTitleStack.clear();
    workingDirectory = null;
    _activeUri = null;
    promptZone = .none;
    lastCommandExitCode = null;
    _primaryWrapped.fillRange(0, height, false);
    _scrollback.clear();
    _viewportOffset = 0;
    _promptLineIndices.clear();
    _fillRowsWithEraseAttributes(_primaryBuffer, 0, height);
    _syncBufferShaderMetadata(
      _primaryBuffer,
      _primaryShaderState,
      hideOverlays: false,
    );
  }

  void _resetActiveShaderState() {
    _activeShaderState.reset();
    _syncActiveBufferShaderMetadata();
  }

  void _resetSavedCursorOnly() {
    if (_usingAltScreen) {
      _savedAlt = _initialSavedCursor;
    } else {
      _savedPrimary = _initialSavedCursor;
    }
    _clampPendingWrap();
  }

  void _clampPendingWrap() {
    if (cursorX >= width) {
      cursorX = math.max(0, width - 1);
    }
  }

  /// Resizes the virtual terminal (both primary and active alternate buffers)
  /// to [newWidth] by [newHeight], optionally updating cell pixel dimensions
  /// atomically so `DECSET 2048` emits a single resize notification.
  void resize(
    int newWidth,
    int newHeight, {
    int? cellPixelWidth,
    int? cellPixelHeight,
  }) {
    final clampedWidth = math.max(1, newWidth);
    final clampedHeight = math.max(1, newHeight);
    final nextCellW = cellPixelWidth != null
        ? math.max(1, cellPixelWidth)
        : _cellPixelWidth;
    final nextCellH = cellPixelHeight != null
        ? math.max(1, cellPixelHeight)
        : _cellPixelHeight;
    final gridChanged = clampedWidth != width || clampedHeight != height;
    final cellChanged =
        nextCellW != _cellPixelWidth || nextCellH != _cellPixelHeight;
    if (!gridChanged && !cellChanged) return;
    _cellPixelWidth = nextCellW;
    _cellPixelHeight = nextCellH;
    if (!gridChanged) {
      if (_inBandWindowResize) _replyWindowResize();
      return;
    }
    _clearLastPrintedCell();
    final oldWidth = width;
    final oldHeight = height;
    _evictOverflowBeforeShrink(clampedHeight);
    final shrunkHorizontally = clampedWidth < width;
    _primaryBuffer.resize(clampedWidth, clampedHeight);
    _primaryBuffer.registerKittyRegistry(
      Rect(0, 0, clampedWidth, clampedHeight),
      imageRegistry,
    );
    if (shrunkHorizontally) _healRightEdgeWideGraphemes(_primaryBuffer);
    final alt = _altBuffer;
    if (alt != null) {
      alt.resize(clampedWidth, clampedHeight);
      alt.registerKittyRegistry(
        Rect(0, 0, clampedWidth, clampedHeight),
        imageRegistry,
      );
      if (shrunkHorizontally) _healRightEdgeWideGraphemes(alt);
    }
    final nextWrapped = List<bool>.filled(clampedHeight, false);
    final copyWrapped = math.min(_primaryWrapped.length, clampedHeight);
    nextWrapped.setRange(0, copyWrapped, _primaryWrapped);
    _primaryWrapped = nextWrapped;
    _resizeTabStops(clampedWidth);
    width = clampedWidth;
    height = clampedHeight;
    _scrollTop = 0;
    _scrollBottom = height - 1;
    cursorX = cursorX.clamp(0, width - 1);
    cursorY = cursorY.clamp(0, height - 1);
    _viewportOffset = _viewportOffset.clamp(0, _scrollback.retainedLines);
    _resizeShaderState(_primaryShaderState, oldWidth, oldHeight, width, height);
    if (_altShaderState case final altShader?) {
      _resizeShaderState(altShader, oldWidth, oldHeight, width, height);
    }
    _syncBufferShaderMetadata(
      _primaryBuffer,
      _primaryShaderState,
      hideOverlays: !_usingAltScreen && _viewportOffset > 0,
    );
    if (alt != null && _altShaderState != null) {
      _syncBufferShaderMetadata(alt, _altShaderState!, hideOverlays: false);
    }
    if (_inBandWindowResize) {
      _replyWindowResize();
    }
  }

  void _resizeTabStops(int newWidth) {
    if (newWidth < width) {
      _tabStops.removeWhere((col) => col >= newWidth);
      return;
    }
    for (var col = ((width + 7) ~/ 8) * 8; col < newWidth; col += 8) {
      if (col > 0) _tabStops.add(col);
    }
  }

  void _evictOverflowBeforeShrink(int clampedHeight) {
    if (clampedHeight >= height) return;
    final baseCursorY = (_usingAltScreen ? _savedPrimary.y : cursorY).clamp(
      0,
      height - 1,
    );
    final targetY = _lastNonBlankPrimaryRow(baseCursorY);
    final evictCount = math.min(targetY - clampedHeight + 1, baseCursorY);
    if (evictCount <= 0) return;

    _pushPrimaryRowsToScrollback(evictCount);
    _copyCellSpan(_primaryBuffer, 0, evictCount * width, clampedHeight * width);
    _primaryWrapped.setRange(0, clampedHeight, _primaryWrapped, evictCount);
    _shiftShaderStateRows(_primaryShaderState, 0, height - 1, -evictCount);
    _savedPrimary = (
      x: _savedPrimary.x,
      y: math.max(0, _savedPrimary.y.clamp(0, height - 1) - evictCount),
      style: _savedPrimary.style,
      pendingWrap: _savedPrimary.pendingWrap,
      originMode: _savedPrimary.originMode,
      g0DecGraphics: _savedPrimary.g0DecGraphics,
      g1DecGraphics: _savedPrimary.g1DecGraphics,
      useG1: _savedPrimary.useG1,
    );
    if (!_usingAltScreen) {
      cursorY = baseCursorY - evictCount;
    }
  }

  int _lastNonBlankPrimaryRow(int minRow) {
    for (var r = height - 1; r > minRow; r--) {
      if (_primaryWrapped[r] || _rowHasVisibleContent(_primaryBuffer, r)) {
        return r;
      }
    }
    return minRow;
  }

  static bool _rowHasVisibleContent(Buffer buf, int row) {
    final rowStart = row * buf.width;
    final rowEnd = rowStart + buf.width;
    final codes = buf.glyphCodes;
    for (var cell = rowStart; cell < rowEnd; cell++) {
      if (codes[cell] != GlyphCellList.spaceCode) return true;
      final attrIdx = cell * 3;
      if (buf.attributes[attrIdx + 1] != 0 ||
          (buf.attributes[attrIdx + 2] & ~Modifier.transparent) != 0) {
        return true;
      }
    }
    return false;
  }

  static bool _isWideCellAt(Buffer buf, int cellIdx) {
    final code = buf.glyphCodes[cellIdx];
    if (code == GlyphCellList.wideContinuationCode) return false;
    if ((code & GlyphCellList.clusterFlag) == 0) return isWideCodePoint(code);
    return isWideGrapheme(buf.glyphCellList.decodeCode(code));
  }

  void _healRightEdgeWideGraphemes(Buffer buf) {
    final rightCol = buf.width - 1;
    for (var y = 0; y < buf.height; y++) {
      final cellIdx = y * buf.width + rightCol;
      if (_isWideCellAt(buf, cellIdx)) {
        _resetSplitCell(buf, cellIdx);
      }
    }
  }

  void _resetSplitCell(Buffer buf, int cellIdx) {
    buf.glyphCellList.setCodeAt(cellIdx, GlyphCellList.spaceCode);
    final attrIdx = cellIdx * 3;
    buf.attributes[attrIdx] = 0;
    buf.attributes[attrIdx + 1] = 0;
    buf.attributes[attrIdx + 2] = transparentBackground
        ? Modifier.transparent
        : Modifier.none;
    buf.clearCellAuxRange(cellIdx, cellIdx + 1);
  }

  void _clearSplitWideEdges(
    Buffer active,
    int rowOffset,
    int startX,
    int endX,
  ) {
    final codes = active.glyphCodes;
    if (startX > 0 &&
        codes[rowOffset + startX] == GlyphCellList.wideContinuationCode &&
        _isWideCellAt(active, rowOffset + startX - 1)) {
      _resetSplitCell(active, rowOffset + startX - 1);
    }
    if (endX < width &&
        codes[rowOffset + endX] == GlyphCellList.wideContinuationCode) {
      _resetSplitCell(active, rowOffset + endX);
    }
  }

  /// Feeds a chunk of UTF-8 encoded bytes into the terminal.
  void write(List<int> chunk) {
    _utf8Sink.add(chunk);
    if (_dirtySinceLastNotify) {
      _notifyListeners();
    }
  }

  /// Feeds an already-decoded Dart string directly into the terminal.
  void writeString(String text) {
    _parser.parse(text);
    if (_dirtySinceLastNotify) {
      _notifyListeners();
    }
  }

  int _resolveOscColorArg(Color? color, Color? dynamicOverride) {
    if (color == null) return dynamicOverride?.argb ?? 0;
    if (color.isAnsiIndexed) {
      return _osc4Overrides[color.ansiIndex]?.argb ??
          (emitIndexedColors
              ? color.argb
              : _legacyColorFromAnsi256(color.ansiIndex).argb);
    }
    return color.argb;
  }

  (int fg, int bg, int mod) _eraseAttributes() {
    final bgArg = _resolveOscColorArg(_currentStyle.background, _osc11Override);
    if (transparentBackground &&
        _osc11Override == null &&
        (bgArg == 0 || bgArg == 0xFF000000)) {
      return (0, 0, Modifier.transparent);
    }
    return (0, bgArg, Modifier.none);
  }

  void _eraseRowSpan(int y, int startX, int endX) {
    if (startX >= endX || y < 0 || y >= height) return;
    final active = buffer;
    final rowOffset = y * width;
    _clearSplitWideEdges(active, rowOffset, startX, endX);
    final startCell = rowOffset + startX;
    final endCell = rowOffset + endX;
    active.glyphCellList.fillCodeRange(
      startCell,
      endCell,
      GlyphCellList.spaceCode,
    );
    final (fg, bg, mod) = _eraseAttributes();
    _fillEraseAttributesRange(active, startCell, endCell, fg, bg, mod);
    active.clearCellAuxRange(startCell, endCell);
  }

  void _eraseInDisplay(int mode) {
    final active = buffer;
    switch (mode) {
      case 0: // Cursor (inclusive) to end of screen
        _clampPendingWrap();
        _eraseRowSpan(cursorY, cursorX, width);
        _clearLineWrapOnErase(clearStart: cursorX == 0, clearEnd: true);
        if (cursorY + 1 < height) {
          _fillRowsWithEraseAttributes(active, cursorY + 1, height);
          _clearWrappedRange(cursorY + 1, height);
        }
      case 1: // Start of screen to cursor (inclusive)
        _clampPendingWrap();
        if (cursorY > 0) {
          _fillRowsWithEraseAttributes(active, 0, cursorY);
        }
        _eraseRowSpan(cursorY, 0, math.min(width, cursorX + 1));
        _clearWrappedRange(0, cursorY + 1);
      case 2: // Entire screen
        _clampPendingWrap();
        _fillRowsWithEraseAttributes(active, 0, height);
        _clearWrappedRange(0, height);
      case 3: // Saved scrollback lines only
        if (!_usingAltScreen) {
          _scrollback.clear();
          _viewportOffset = 0;
          _promptLineIndices.clear();
          _syncPrimaryShaderOverlays();
        }
    }
  }

  void _eraseInLine(int mode) {
    _clampPendingWrap();
    switch (mode) {
      case 0: // Cursor (inclusive) to end of line
        _eraseRowSpan(cursorY, cursorX, width);
        _clearLineWrapOnErase(clearStart: cursorX == 0, clearEnd: true);
      case 1: // Start of line to cursor (inclusive)
        _eraseRowSpan(cursorY, 0, math.min(width, cursorX + 1));
        _clearLineWrapOnErase(clearStart: true, clearEnd: false);
      case 2: // Entire line
        _eraseRowSpan(cursorY, 0, width);
        _clearLineWrapOnErase(clearStart: true, clearEnd: true);
    }
  }

  void _clearWrappedRange(int start, int end) {
    if (_usingAltScreen || start >= end) return;
    _primaryWrapped.fillRange(start, end, false);
  }

  void _clearLineWrapOnErase({
    required bool clearStart,
    required bool clearEnd,
  }) {
    if (_usingAltScreen) return;
    if (clearStart) _primaryWrapped[cursorY] = false;
    if (clearEnd && cursorY + 1 < height) _primaryWrapped[cursorY + 1] = false;
  }

  void _indexDown() {
    final wrapped = _wrappingNextIndexDown;
    _wrappingNextIndexDown = false;
    var advanced = false;
    if (cursorY == _scrollBottom) {
      _scrollRegion(_scrollTop, _scrollBottom, 1, up: true, evictTop: true);
      advanced = true;
    } else if (cursorY < height - 1) {
      cursorY++;
      advanced = true;
    }
    if (wrapped && advanced && !_usingAltScreen) {
      _primaryWrapped[cursorY] = true;
    }
  }

  void _reverseIndex() {
    _clampPendingWrap();
    if (cursorY == _scrollTop) {
      _scrollRegion(_scrollTop, _scrollBottom, 1, up: false);
    } else if (cursorY > 0) {
      cursorY--;
    }
  }

  void _scrollRegion(
    int top,
    int bottom,
    int count, {
    required bool up,
    bool evictTop = false,
  }) {
    if (top < 0 || bottom >= height || top > bottom || count <= 0) return;
    final regionRows = bottom - top + 1;
    final shift = math.min(count, regionRows);
    _evictTopRowsToScrollback(top, shift, up: up, evictTop: evictTop);
    final keepRows = regionRows - shift;
    final active = buffer;
    if (keepRows > 0) {
      final dstRow = up ? top : top + shift;
      final srcRow = up ? top + shift : top;
      _copyCellSpan(active, dstRow * width, srcRow * width, keepRows * width);
      if (!_usingAltScreen) {
        _primaryWrapped.setRange(
          dstRow,
          dstRow + keepRows,
          _primaryWrapped,
          srcRow,
        );
      }
    }
    final fillStart = up ? bottom - shift + 1 : top;
    final fillEnd = up ? bottom + 1 : top + shift;
    _fillRowsWithEraseAttributes(active, fillStart, fillEnd);
    _clearWrappedRange(fillStart, fillEnd);
    _shiftShaderStateRows(_activeShaderState, top, bottom, up ? -shift : shift);
    _syncActiveBufferShaderMetadata();
  }

  void _evictTopRowsToScrollback(
    int top,
    int shift, {
    required bool up,
    required bool evictTop,
  }) {
    if (!evictTop || !up || _usingAltScreen || top != 0) return;
    _pushPrimaryRowsToScrollback(shift);
  }

  void _pushPrimaryRowsToScrollback(int count) {
    if (_scrollback.maxLines <= 0) {
      _scrollback.advanceDiscarded(count);
      _pruneEvictedPromptLines();
      return;
    }
    for (var r = 0; r < count; r++) {
      _scrollback.push(
        ScrollbackLine.fromBufferRow(
          _primaryBuffer,
          r,
          isWrapped: _primaryWrapped[r],
        ),
      );
    }
    if (_viewportOffset > 0) {
      _viewportOffset = (_viewportOffset + count).clamp(
        0,
        _scrollback.retainedLines,
      );
      _syncPrimaryShaderOverlays();
    }
    _pruneEvictedPromptLines();
  }

  static void _copyCellSpan(
    Buffer buf,
    int dstCell,
    int srcCell,
    int cellCount,
  ) {
    if (cellCount <= 0) return;
    buf.glyphCellList.copyCellsFrom(
      buf.glyphCellList,
      dstCell,
      srcCell,
      cellCount,
    );
    buf.attributes.setRange(
      dstCell * 3,
      (dstCell + cellCount) * 3,
      buf.attributes,
      srcCell * 3,
    );
    buf.copyCellAuxRangeFrom(buf, dstCell, srcCell, cellCount);
  }

  static void _fillEraseAttributesRange(
    Buffer buf,
    int startCell,
    int endCell,
    int fg,
    int bg,
    int mod,
  ) {
    if (fg == 0 && bg == 0 && mod == 0) {
      buf.attributes.fillRange(startCell * 3, endCell * 3, 0);
      return;
    }
    for (var i = startCell * 3; i < endCell * 3; i += 3) {
      buf.attributes[i] = fg;
      buf.attributes[i + 1] = bg;
      buf.attributes[i + 2] = mod;
    }
  }

  void _fillRowsWithEraseAttributes(
    Buffer buf,
    int startRow,
    int endRowExclusive,
  ) {
    final startCell = startRow * width;
    final endCell = endRowExclusive * width;
    if (startCell >= endCell) return;
    buf.glyphCellList.fillCodeRange(
      startCell,
      endCell,
      GlyphCellList.spaceCode,
    );
    final (fg, bg, mod) = _eraseAttributes();
    _fillEraseAttributesRange(buf, startCell, endCell, fg, bg, mod);
    buf.clearCellAuxRange(startCell, endCell);
  }

  bool get _isDecGraphicsActive => _useG1 ? _g1DecGraphics : _g0DecGraphics;

  static bool _isPrintableAscii(String text) {
    final len = text.length;
    for (var i = 0; i < len; i++) {
      final cu = text.codeUnitAt(i);
      if (cu < 0x20 || cu > 0x7E) return false;
    }
    return true;
  }

  @override
  void printText(String text) {
    if (text.isEmpty) return;
    _markDirty();
    if (!_insertMode &&
        !_isDecGraphicsActive &&
        cursorX >= 0 &&
        cursorY >= 0 &&
        cursorY < height &&
        (cursorX < width || _autoWrap) &&
        _isPrintableAscii(text)) {
      _printAsciiRun(text);
      return;
    }
    for (final char in text.characters) {
      _printGrapheme(char);
    }
  }

  void _printAsciiRun(String text) {
    final (fgArg, bgArg, baseMod, bgTransparent) = _resolvePrintAttributes('A');
    final spaceMod = bgTransparent ? (baseMod | Modifier.transparent) : baseMod;
    final ulColor = _resolveOscColorArg(_currentStyle.underlineColor, null);
    final uri = _activeUri;
    final len = text.length;
    var offset = 0;

    while (offset < len) {
      _resolvePendingWrapBeforeWrite();
      final active = buffer;
      final remaining = len - offset;
      final avail = width - cursorX;
      if (!_autoWrap && remaining > avail) {
        _writeClampedAsciiTail(
          active,
          text,
          offset,
          avail,
          fgArg,
          bgArg,
          baseMod,
          spaceMod,
          ulColor,
          uri,
        );
        return;
      }

      final count = math.min(remaining, avail);
      final startX = cursorX;
      _writeAsciiRowSegment(
        active,
        cursorY,
        startX,
        text,
        offset,
        count,
        fgArg,
        bgArg,
        baseMod,
        spaceMod,
        ulColor,
        uri,
      );
      _lastPrintedCellX = startX + count - 1;
      _lastPrintedCellY = cursorY;
      offset += count;
      _advanceCursorAfterPrint(count);
    }

    _lastPrintedGrapheme = buffer.glyphCellList.decodeCode(
      text.codeUnitAt(len - 1),
    );
  }

  void _writeClampedAsciiTail(
    Buffer active,
    String text,
    int offset,
    int avail,
    int fgArg,
    int bgArg,
    int baseMod,
    int spaceMod,
    int ulColor,
    String? uri,
  ) {
    final headCount = avail - 1;
    if (headCount > 0) {
      _writeAsciiRowSegment(
        active,
        cursorY,
        cursorX,
        text,
        offset,
        headCount,
        fgArg,
        bgArg,
        baseMod,
        spaceMod,
        ulColor,
        uri,
      );
    }
    final lastIndex = text.length - 1;
    _writeAsciiRowSegment(
      active,
      cursorY,
      width - 1,
      text,
      lastIndex,
      1,
      fgArg,
      bgArg,
      baseMod,
      spaceMod,
      ulColor,
      uri,
    );
    cursorX = width - 1;
    _lastPrintedCellX = cursorX;
    _lastPrintedCellY = cursorY;
    _lastPrintedGrapheme = active.glyphCellList.decodeCode(
      text.codeUnitAt(lastIndex),
    );
  }

  void _writeAsciiRowSegment(
    Buffer active,
    int y,
    int startX,
    String text,
    int textOffset,
    int count,
    int fgArg,
    int bgArg,
    int baseMod,
    int spaceMod,
    int ulColor,
    String? uri,
  ) {
    final rowOffset = y * width;
    _clearSplitWideEdges(active, rowOffset, startX, startX + count);
    final cells = active.glyphCellList;
    final attrs = active.attributes;
    for (var i = 0; i < count; i++) {
      final cu = text.codeUnitAt(textOffset + i);
      final idx = rowOffset + startX + i;
      cells.setCodeAt(idx, cu);
      final attrIdx = idx * 3;
      attrs[attrIdx] = fgArg;
      attrs[attrIdx + 1] = bgArg;
      attrs[attrIdx + 2] = cu == GlyphCellList.spaceCode ? spaceMod : baseMod;
      active.setUnderlineColorAt(idx, ulColor);
      active.setUriAt(idx, uri);
    }
  }

  void _wrapLineDown() {
    cursorX = 0;
    _wrappingNextIndexDown = true;
    _indexDown();
    _wrappingNextIndexDown = false;
  }

  void _clearLastPrintedCell() {
    _lastPrintedCellX = null;
    _lastPrintedCellY = null;
  }

  static bool _isZeroWidthMark(String grapheme) {
    if (grapheme.isEmpty || !isZeroWidthGrapheme(grapheme)) return false;
    final cu = grapheme.codeUnitAt(0);
    return cu != 0x00AD && (cu < 0xFFF9 || cu > 0xFFFB);
  }

  static String _capGrapheme(String grapheme) {
    if (grapheme.length <= _maxCellGraphemeUnits) return grapheme;
    var end = _maxCellGraphemeUnits;
    final last = grapheme.codeUnitAt(end - 1);
    if (last >= 0xD800 && last <= 0xDBFF) end--;
    return grapheme.substring(0, end);
  }

  void _printGrapheme(String rawChar, {bool translateCharset = true}) {
    if (rawChar.isEmpty || _containsControlCodeUnit(rawChar)) return;
    final translated = translateCharset ? _translateCharset(rawChar) : rawChar;
    if (_isZeroWidthMark(translated)) {
      _appendZeroWidthMark(translated);
      return;
    }
    final char = _capGrapheme(translated);
    _lastPrintedGrapheme = char;
    _resolvePendingWrapBeforeWrite();

    final (fgArg, bgArg, modArg, isBgTransparent) = _resolvePrintAttributes(
      char,
    );
    if (isWideGrapheme(char)) {
      _printWideGrapheme(char, fgArg, bgArg, modArg, isBgTransparent);
      return;
    }
    if (_insertMode) _insertBlankChars(1);
    final printedX = cursorX;
    final printedY = cursorY;
    buffer.setAttributes(
      printedX,
      printedY,
      char: char,
      fg: fgArg,
      bg: bgArg,
      modifiers: modArg,
      underlineColor: _resolveOscColorArg(_currentStyle.underlineColor, null),
      uri: _activeUri ?? '',
    );
    _lastPrintedCellX = printedX;
    _lastPrintedCellY = printedY;
    _advanceCursorAfterPrint(1);
  }

  void _appendZeroWidthMark(String mark) {
    final prevX = _lastPrintedCellX;
    final prevY = _lastPrintedCellY;
    if (prevX == null ||
        prevY == null ||
        prevY != cursorY ||
        prevX < 0 ||
        prevX >= width ||
        prevY < 0 ||
        prevY >= height) {
      return;
    }
    final active = buffer;
    final cellIdx = prevY * width + prevX;
    final existing = active.characters[cellIdx];
    if (existing.isEmpty ||
        existing.length + mark.length > _maxCellGraphemeUnits) {
      return;
    }
    final merged = '$existing$mark';
    _lastPrintedGrapheme = merged;
    final wasWide = isWideGrapheme(existing);
    if (wasWide || !isWideGrapheme(merged)) {
      active.characters[cellIdx] = merged;
      return;
    }
    _promoteMergedCellToWide(active, prevX, prevY, cellIdx, merged);
  }

  void _promoteMergedCellToWide(
    Buffer active,
    int prevX,
    int prevY,
    int cellIdx,
    String merged,
  ) {
    final attrBase = cellIdx * 3;
    final fg = active.attributes[attrBase];
    final bg = active.attributes[attrBase + 1];
    final mod = active.attributes[attrBase + 2];
    final ul = active.getUnderlineColor(prevX, prevY);
    final uri = active.getUri(prevX, prevY) ?? '';
    if (prevX + 1 < width) {
      if (_insertMode) _insertBlankChars(1);
      active.setAttributes(
        prevX,
        prevY,
        char: merged,
        fg: fg,
        bg: bg,
        modifiers: mod,
        underlineColor: ul,
        uri: uri,
        blend: false,
      );
      cursorX = prevX;
      _advanceCursorAfterPrint(2);
      return;
    }
    final padMod = (transparentBackground && bg == 0)
        ? (mod | Modifier.transparent)
        : mod;
    active.setAttributes(
      prevX,
      prevY,
      char: ' ',
      fg: fg,
      bg: bg,
      modifiers: padMod,
      underlineColor: 0,
      uri: '',
      blend: false,
    );
    if (width == 1 || !_autoWrap) {
      _clearLastPrintedCell();
      return;
    }
    _wrapLineDown();
    if (_insertMode) _insertBlankChars(2);
    final wrappedX = cursorX;
    final wrappedY = cursorY;
    active.setAttributes(
      wrappedX,
      wrappedY,
      char: merged,
      fg: fg,
      bg: bg,
      modifiers: mod,
      underlineColor: ul,
      uri: uri,
      blend: false,
    );
    _lastPrintedCellX = wrappedX;
    _lastPrintedCellY = wrappedY;
    _advanceCursorAfterPrint(2);
  }

  String _translateCharset(String char) {
    if (!(_useG1 ? _g1DecGraphics : _g0DecGraphics) || char.length != 1) {
      return char;
    }
    final code = char.codeUnitAt(0);
    if (code < 0x5F || code > 0x7E) return char;
    return _decSpecialGraphics[code - 0x5F];
  }

  static bool _containsControlCodeUnit(String grapheme) {
    for (var i = 0; i < grapheme.length; i++) {
      final codeUnit = grapheme.codeUnitAt(i);
      if (codeUnit <= 0x1F || (codeUnit >= 0x7F && codeUnit <= 0x9F)) {
        return true;
      }
    }
    return false;
  }

  (int fg, int bg, int mod, bool bgTransparent) _resolvePrintAttributes(
    String char,
  ) {
    final isKitty = char.startsWith(kittyPlaceholderChar);
    var fgArg = switch ((isKitty, _currentStyle.foreground)) {
      (true, null) => 0,
      (true, final fg?) when fg.isAnsiIndexed => 0xFF00_0000 | fg.ansiIndex,
      (_, final fg) => _resolveOscColorArg(fg, _osc10Override),
    };
    var bgArg = _resolveOscColorArg(_currentStyle.background, _osc11Override);
    var modArg = _currentStyle.modifiers;
    if (isKitty) {
      modArg |= Modifier.kittyPlaceholder;
    }

    final bgTransparent =
        transparentBackground &&
        _osc11Override == null &&
        (bgArg == 0 || bgArg == 0xFF000000);
    if (bgTransparent) {
      bgArg = 0;
      if (fgArg == 0 && !isKitty) fgArg = defaultForeground?.argb ?? 0xFFFFFFFF;
      if (char == ' ') modArg |= Modifier.transparent;
    } else if (fgArg == 0 && !isKitty && defaultForeground != null) {
      fgArg = defaultForeground!.argb;
    }
    return (fgArg, bgArg, modArg, bgTransparent);
  }

  void _printWideGrapheme(
    String char,
    int fgArg,
    int bgArg,
    int modArg,
    bool bgTransparent,
  ) {
    if (cursorX == width - 1) {
      buffer.setAttributes(
        cursorX,
        cursorY,
        char: ' ',
        fg: fgArg,
        bg: bgArg,
        modifiers: bgTransparent ? (modArg | Modifier.transparent) : modArg,
      );
      if (width == 1 || !_autoWrap) {
        _clearLastPrintedCell();
        cursorX = (width == 1 && _autoWrap) ? 1 : width - 1;
        return;
      }
      _wrapLineDown();
    }
    if (_insertMode) _insertBlankChars(2);
    final printedX = cursorX;
    final printedY = cursorY;
    buffer.setAttributes(
      printedX,
      printedY,
      char: char,
      fg: fgArg,
      bg: bgArg,
      modifiers: modArg,
      underlineColor: _resolveOscColorArg(_currentStyle.underlineColor, null),
      uri: _activeUri ?? '',
    );
    _lastPrintedCellX = printedX;
    _lastPrintedCellY = printedY;
    _advanceCursorAfterPrint(2);
  }

  void _advanceCursorAfterPrint(int step) {
    final nextX = cursorX + step;
    if (nextX >= width) {
      cursorX = _autoWrap ? width : width - 1;
    } else {
      cursorX = nextX;
    }
  }

  @override
  void execute(int charCode) {
    _clearLastPrintedCell();
    if (charCode == 7) {
      onBell?.call();
      return;
    }
    _markDirty();
    switch (charCode) {
      case 8: // Backspace
        _clampPendingWrap();
        if (cursorX > 0) cursorX--;
      case 9: // Horizontal tab
        _advanceTabStops(1);
      case 10 || 11 || 12: // Line feed, vertical tab, form feed
        _clampPendingWrap();
        _indexDown();
      case 13: // Carriage return
        cursorX = 0;
      case 14: // Shift Out (SO -> G1)
        _useG1 = true;
      case 15: // Shift In (SI -> G0)
        _useG1 = false;
    }
  }

  void _handleDecPrivateMode(String command, List<int> params) {
    switch (command) {
      case 'J':
        _markDirty();
        _eraseInDisplay(params.isEmpty ? 0 : params[0]);
      case 'K':
        _markDirty();
        _eraseInLine(params.isEmpty ? 0 : params[0]);
      case 'n':
        _handleDecPrivateDsr(params);
      case 'W':
        if (params.length == 1 && params[0] == 5) {
          _markDirty();
          _resetDefaultTabStops();
        }
      case 'h' || 'l':
        final enable = command == 'h';
        for (final param in params) {
          _applyDecPrivateModeParam(param, enable);
        }
    }
  }

  void _handleDecPrivateDsr(List<int> params) {
    if (params.length != 1) return;
    switch (params[0]) {
      case 6:
        _replyCursorPosition(extended: true);
      case 996:
        _replyColorScheme();
    }
  }

  void _replyColorScheme() {
    final mode = _colorScheme == .light ? 2 : 1;
    onReply?.call('\x1b[?997;${mode}n');
  }

  void _applyDecPrivateModeParam(int param, bool enable) {
    if (param == 2026) {
      synchronizedOutput = enable;
      return;
    }
    _markDirty();
    switch (param) {
      case 1: // DECCKM (Application Cursor Keys)
        _applicationCursorKeys = enable;
      case 6: // DECOM (Origin Mode)
        _originMode = enable;
        cursorX = 0;
        cursorY = enable ? _scrollTop : 0;
      case 7: // DECAWM (Auto-Wrap Mode)
        _autoWrap = enable;
        if (!enable) _clampPendingWrap();
      case 25: // DECTCEM (Text Cursor Enable Mode)
        _cursorVisible = enable;
      case 47 || 1047: // Alternate Screen Buffer
        _switchAlternateScreen(enable, saveRestoreCursor: false);
      case 1048: // Save / Restore Cursor (DECSC / DECRC)
        enable ? _saveCursor() : _restoreCursor();
      case 1049: // Save Cursor + Alternate Screen Buffer
        _switchAlternateScreen(enable, saveRestoreCursor: true);
      case 9 || 1000 || 1002 || 1003:
        final bit = _mouseModeBit(param);
        _mouseTrackingMask = enable
            ? (_mouseTrackingMask | bit)
            : (_mouseTrackingMask & ~bit);
      case 1004: // Focus Reporting
        _focusReporting = enable;
      case 1006:
        sgrMouseMode = enable;
      case 1007: // Alternate Scroll Mode
        _alternateScrollMode = enable;
      case 1016:
        sgrPixelsMouseMode = enable;
      case 2004:
        bracketedPasteMode = enable;
      case 2027:
        _graphemeClusterMode = enable;
      case 2031:
        _colorSchemeReporting = enable;
      case 2048:
        _inBandWindowResize = enable;
        if (enable) {
          _replyWindowResize();
        }
    }
  }

  void _replyWindowResize() {
    onReply?.call(
      '\x1b[48;$height;$width;${height * _cellPixelHeight};${width * _cellPixelWidth}t',
    );
  }

  void _switchAlternateScreen(bool enable, {required bool saveRestoreCursor}) {
    _clearLastPrintedCell();
    if (enable && !_usingAltScreen) {
      if (saveRestoreCursor) _saveCursor();
      _altBuffer = _newBuffer(width, height);
      _altShaderState = _ScreenShaderState(_handleShaderEvent);
      _usingAltScreen = true;
      _scrollTop = 0;
      _scrollBottom = height - 1;
      _audioApcHandler.reset();
      if (saveRestoreCursor) {
        cursorX = 0;
        cursorY = 0;
      } else {
        _clampPendingWrap();
      }
      return;
    }
    if (!enable && _usingAltScreen) {
      _usingAltScreen = false;
      _altBuffer?.shaderRegions.clear();
      _altBuffer?.clearCellTransforms();
      _altBuffer = null;
      _altShaderState?.reset();
      _altShaderState = null;
      _scrollTop = 0;
      _scrollBottom = height - 1;
      _audioApcHandler.reset();
      _syncPrimaryShaderOverlays();
      if (saveRestoreCursor) {
        _restoreCursor();
      } else {
        _clampPendingWrap();
      }
      onShaderEvent?.call(
        const TerminalResetShaderEvent(target: .all, altScreenExit: true),
      );
    }
  }

  void _saveCursor() {
    final snapshot = (
      x: cursorX.clamp(0, width - 1),
      y: cursorY.clamp(0, height - 1),
      style: _currentStyle,
      pendingWrap: cursorX >= width,
      originMode: _originMode,
      g0DecGraphics: _g0DecGraphics,
      g1DecGraphics: _g1DecGraphics,
      useG1: _useG1,
    );
    if (_usingAltScreen) {
      _savedAlt = snapshot;
    } else {
      _savedPrimary = snapshot;
    }
  }

  void _restoreCursor() {
    final saved = _usingAltScreen ? _savedAlt : _savedPrimary;
    final restoredX = saved.x.clamp(0, width - 1);
    cursorX = (saved.pendingWrap && _autoWrap && restoredX == width - 1)
        ? width
        : restoredX;
    _originMode = saved.originMode;
    cursorY = _originMode
        ? saved.y.clamp(_scrollTop, _scrollBottom)
        : saved.y.clamp(0, height - 1);
    _currentStyle = saved.style;
    _g0DecGraphics = saved.g0DecGraphics;
    _g1DecGraphics = saved.g1DecGraphics;
    _useG1 = saved.useG1;
  }

  @override
  void csi(
    String command,
    List<int> params, {
    String? intermediate,
    List<List<int>?>? subparams,
  }) {
    _clearLastPrintedCell();
    if (intermediate == null && command == 'm') {
      _markDirty();
      _applySgr(params, subparams: subparams);
      return;
    }
    if (subparams != null) return;
    if (intermediate != null) {
      _handleIntermediateCsi(intermediate, command, params);
      return;
    }
    if (_tryHandleQueryCsi(command, params)) return;
    _markDirty();

    final p1 = _clampedPositiveParam(params, 0);
    final p2 = _clampedPositiveParam(params, 1);
    if (_tryHandleCursorCsi(command, p1, p2)) return;
    _handleEditingOrModeCsi(command, params, p1);
  }

  void _handleIntermediateCsi(
    String intermediate,
    String command,
    List<int> params,
  ) {
    switch ((intermediate, command)) {
      case ('?', 'u'):
        onReply?.call('\x1b[?${kittyKeyboardFlags}u');
      case ('>', 'u'):
        _markDirty();
        _pushKittyKeyboard(params);
      case ('<', 'u'):
        _markDirty();
        _popKittyKeyboard(params);
      case ('=', 'u'):
        _markDirty();
        _setKittyKeyboard(params);
      case ('?', _):
        _handleDecPrivateMode(command, params);
      case ('!', 'p'):
        _markDirty();
        _resetState(fullReset: false);
      case ('>', 'c'):
        if (_isZeroOrEmptyParam(params)) onReply?.call('\x1b[>1;10;0c');
      case ('>', 'q'):
        if (_isZeroOrEmptyParam(params)) {
          onReply?.call('\x1bP>|termui(0.8.3)\x1b\\');
        }
      case (r'?$', 'p'):
        _replyDecrqm(params, decPrivate: true);
      case (r'$', 'p'):
        _replyDecrqm(params, decPrivate: false);
      case (' ', 'q'):
        _markDirty();
        _setCursorShape(params);
    }
  }

  void _pushKittyKeyboard(List<int> params) {
    final stack = _activeKittyKbStack;
    if (stack.length >= _maxKittyKbStackDepth) {
      stack.removeAt(0);
    }
    stack.add(kittyKeyboardFlags);
    final flags = params.isNotEmpty ? (params[0] & 0x1F) : 0;
    kittyKeyboardFlags = flags;
  }

  void _popKittyKeyboard(List<int> params) {
    final count = (params.isEmpty || params[0] <= 0) ? 1 : params[0];
    final stack = _activeKittyKbStack;
    if (count > stack.length) {
      stack.clear();
      kittyKeyboardFlags = 0;
      return;
    }
    for (var i = 0; i < count; i++) {
      kittyKeyboardFlags = stack.removeLast();
    }
  }

  void _setKittyKeyboard(List<int> params) {
    final flags = (params.isNotEmpty ? params[0] : 0) & 0x1F;
    final mode = (params.length >= 2 && params[1] > 0) ? params[1] : 1;
    if (mode == 1) {
      kittyKeyboardFlags = flags;
    } else if (mode == 2) {
      kittyKeyboardFlags = kittyKeyboardFlags | flags;
    } else if (mode == 3) {
      kittyKeyboardFlags = kittyKeyboardFlags & ~flags;
    }
  }

  static int _mouseModeBit(int mode) => switch (mode) {
    9 => 1 << 0,
    1000 => 1 << 1,
    1002 => 1 << 2,
    1003 => 1 << 3,
    _ => 0,
  };

  void _setCursorShape(List<int> params) {
    if (params.length > 1) return;
    final code = params.isEmpty ? 0 : params[0];
    final shape = switch (code) {
      0 => TerminalCursorShape.defaultShape,
      1 => TerminalCursorShape.blinkingBlock,
      2 => TerminalCursorShape.steadyBlock,
      3 => TerminalCursorShape.blinkingUnderline,
      4 => TerminalCursorShape.steadyUnderline,
      5 => TerminalCursorShape.blinkingBar,
      6 => TerminalCursorShape.steadyBar,
      _ => null,
    };
    if (shape != null) _cursorShape = shape;
  }

  static bool _isZeroOrEmptyParam(List<int> params) =>
      params.isEmpty || (params.length == 1 && params[0] == 0);

  bool _tryHandleQueryCsi(String command, List<int> params) {
    switch (command) {
      case 'c':
        if (_isZeroOrEmptyParam(params)) onReply?.call('\x1b[?62;22c');
      case 'n':
        if (params.length == 1 && params[0] == 5) {
          onReply?.call('\x1b[0n');
        } else if (params.length == 1 && params[0] == 6) {
          _replyCursorPosition(extended: false);
        }
      case 't':
        _handleWindowManipulationCsi(params);
      default:
        return false;
    }
    return true;
  }

  void _handleWindowManipulationCsi(List<int> params) {
    if (params.isEmpty) return;
    final op = params[0];
    final target = params.length > 1 ? params[1] : 0;
    if (op == 14 && params.length == 1) {
      onReply?.call(
        '\x1b[4;${height * _cellPixelHeight};${width * _cellPixelWidth}t',
      );
    } else if (op == 16 && params.length == 1) {
      onReply?.call('\x1b[6;$_cellPixelHeight;${_cellPixelWidth}t');
    } else if (op == 18 && params.length == 1) {
      onReply?.call('\x1b[8;$height;${width}t');
    } else if (op == 22) {
      _pushTitleStack(target);
    } else if (op == 23) {
      _popTitleStack(target);
    }
  }

  void _pushTitleStack(int target) {
    if (target == 0 || target == 1) {
      if (_iconTitleStack.length >= _maxTitleStackDepth) {
        _iconTitleStack.removeAt(0);
      }
      _iconTitleStack.add(iconTitle);
    }
    if (target == 0 || target == 2) {
      if (_windowTitleStack.length >= _maxTitleStackDepth) {
        _windowTitleStack.removeAt(0);
      }
      _windowTitleStack.add(windowTitle);
    }
  }

  void _popTitleStack(int target) {
    if ((target == 0 || target == 1) && _iconTitleStack.isNotEmpty) {
      iconTitle = _iconTitleStack.removeLast();
    }
    if ((target == 0 || target == 2) && _windowTitleStack.isNotEmpty) {
      windowTitle = _windowTitleStack.removeLast();
      onTitleChanged?.call(windowTitle);
    }
  }

  void _replyCursorPosition({required bool extended}) {
    final reply = onReply;
    if (reply == null) return;
    final row = _originMode
        ? cursorY.clamp(_scrollTop, _scrollBottom) - _scrollTop + 1
        : cursorY.clamp(0, height - 1) + 1;
    final col = cursorX.clamp(0, width - 1) + 1;
    reply(extended ? '\x1b[?$row;$col;1R' : '\x1b[$row;${col}R');
  }

  void _replyDecrqm(List<int> params, {required bool decPrivate}) {
    final reply = onReply;
    if (reply == null || params.length != 1) return;
    final mode = params[0];
    final pm = decPrivate
        ? _decPrivateModeStatus(mode)
        : (mode == 4 ? (_insertMode ? 1 : 2) : 0);
    final prefix = decPrivate ? '?' : '';
    reply('\x1b[$prefix$mode;$pm\$y');
  }

  int _decPrivateModeStatus(int mode) {
    final enabled = switch (mode) {
      1 => _applicationCursorKeys,
      6 => _originMode,
      7 => _autoWrap,
      25 => _cursorVisible,
      47 || 1047 || 1049 => _usingAltScreen,
      9 ||
      1000 ||
      1002 ||
      1003 => (_mouseTrackingMask & _mouseModeBit(mode)) != 0,
      1004 => _focusReporting,
      1006 => sgrMouseMode,
      1007 => _alternateScrollMode,
      1016 => sgrPixelsMouseMode,
      1048 => false,
      2004 => bracketedPasteMode,
      2026 => synchronizedOutput,
      2027 => _graphemeClusterMode,
      2031 => _colorSchemeReporting,
      2048 => _inBandWindowResize,
      _ => null,
    };
    if (enabled == null) return 0;
    return enabled ? 1 : 2;
  }

  static int _clampedPositiveParam(List<int> params, int index) {
    if (index >= params.length || params[index] <= 0) return 1;
    return math.min(params[index], 0xFFFF);
  }

  int _moveCursorUp(int rows) =>
      math.max(cursorY >= _scrollTop ? _scrollTop : 0, cursorY - rows);

  int _moveCursorDown(int rows) => math.min(
    cursorY <= _scrollBottom ? _scrollBottom : height - 1,
    cursorY + rows,
  );

  int _resolveAbsoluteRow(int oneBasedRow) => _originMode
      ? (_scrollTop + oneBasedRow - 1).clamp(_scrollTop, _scrollBottom)
      : (oneBasedRow - 1).clamp(0, height - 1);

  bool _tryHandleCursorCsi(String command, int p1, int p2) {
    switch (command) {
      case 'A': // Cursor Up (CUU)
        _clampPendingWrap();
        cursorY = _moveCursorUp(p1);
      case 'B' || 'e': // Cursor Down (CUD) / Line Position Relative (VPR)
        _clampPendingWrap();
        cursorY = _moveCursorDown(p1);
      case 'C' ||
          'a': // Cursor Forward (CUF) / Character Position Relative (HPR)
        _clampPendingWrap();
        cursorX = math.min(width - 1, cursorX + p1);
      case 'D': // Cursor Back (CUB)
        _clampPendingWrap();
        cursorX = math.max(0, cursorX - p1);
      case 'E': // Cursor Next Line (CNL)
        cursorX = 0;
        cursorY = _moveCursorDown(p1);
      case 'F': // Cursor Preceding Line (CPL)
        cursorX = 0;
        cursorY = _moveCursorUp(p1);
      case 'G' || '`': // Cursor Character Absolute (CHA / HPA)
        cursorX = (p1 - 1).clamp(0, width - 1);
      case 'I': // Cursor Horizontal Forward Tabulation (CHT)
        _advanceTabStops(p1);
      case 'Z': // Cursor Backward Tabulation (CBT)
        _retreatTabStops(p1);
      case 'd': // Line Position Absolute (VPA)
        _clampPendingWrap();
        cursorY = _resolveAbsoluteRow(p1);
      case 'H' || 'f': // Cursor Position (CUP / HVP)
        cursorX = (p2 - 1).clamp(0, width - 1);
        cursorY = _resolveAbsoluteRow(p1);
      default:
        return false;
    }
    return true;
  }

  void _handleEditingOrModeCsi(String command, List<int> params, int p1) {
    switch (command) {
      case 'J':
        _eraseInDisplay(params.isEmpty ? 0 : params[0]);
      case 'K':
        _eraseInLine(params.isEmpty ? 0 : params[0]);
      case 'X':
        _clampPendingWrap();
        _eraseRowSpan(cursorY, cursorX, math.min(width, cursorX + p1));
      case 'P':
        _deleteChars(p1);
      case '@':
        _insertBlankChars(p1);
      case 'L':
        _insertLines(p1);
      case 'M':
        _deleteLines(p1);
      case 'S':
        _scrollRegion(_scrollTop, _scrollBottom, p1, up: true, evictTop: true);
      case 'T':
        if (params.length <= 1) {
          _scrollRegion(_scrollTop, _scrollBottom, p1, up: false);
        }
      case 'r':
        _setScrollRegion(params);
      case 'b':
        _repeatLastGrapheme(p1);
      case 's':
        if (params.isEmpty) _saveCursor();
      case 'u':
        if (params.isEmpty) _restoreCursor();
      case 'h' || 'l':
        _setAnsiMode(params, command == 'h');
      case 'g':
        _clearTabStop(params.isEmpty ? 0 : params[0]);
    }
  }

  void _clearTabStop(int mode) {
    if (mode == 0) {
      _tabStops.remove(cursorX.clamp(0, width - 1));
    } else if (mode == 3) {
      _tabStops.clear();
    }
  }

  int _nextTabStopAfter(int x) {
    var best = width - 1;
    for (final stop in _tabStops) {
      if (stop > x && stop < best) best = stop;
    }
    return best;
  }

  int _prevTabStopBefore(int x) {
    var best = 0;
    for (final stop in _tabStops) {
      if (stop < x && stop > best) best = stop;
    }
    return best;
  }

  void _advanceTabStops(int count) {
    _clampPendingWrap();
    for (var i = 0; i < count && cursorX < width - 1; i++) {
      cursorX = _nextTabStopAfter(cursorX);
    }
  }

  void _retreatTabStops(int count) {
    _clampPendingWrap();
    for (var i = 0; i < count && cursorX > 0; i++) {
      cursorX = _prevTabStopBefore(cursorX);
    }
  }

  void _setAnsiMode(List<int> params, bool enable) {
    for (final param in params) {
      if (param == 4) _insertMode = enable;
    }
  }

  void _repeatLastGrapheme(int count) {
    final last = _lastPrintedGrapheme;
    if (last == null) return;
    final limit = math.min(count, width * height);
    for (var i = 0; i < limit; i++) {
      _printGrapheme(last, translateCharset: false);
    }
  }

  void _setScrollRegion(List<int> params) {
    final rawTop = _clampedPositiveParam(params, 0);
    final rawBottom = params.length > 1 && params[1] > 0
        ? math.min(params[1], 0xFFFF)
        : height;
    if (rawTop > rawBottom) return;
    final top = (rawTop - 1).clamp(0, height - 1);
    final bottom = (rawBottom - 1).clamp(0, height - 1);
    if (top < bottom || (height == 1 && rawTop == 1)) {
      _scrollTop = top;
      _scrollBottom = bottom;
      cursorX = 0;
      cursorY = _originMode ? _scrollTop : 0;
    }
  }

  void _insertLines(int count) {
    _clampPendingWrap();
    if (cursorY < _scrollTop || cursorY > _scrollBottom) return;
    cursorX = 0;
    _scrollRegion(cursorY, _scrollBottom, count, up: false);
  }

  void _deleteLines(int count) {
    _clampPendingWrap();
    if (cursorY < _scrollTop || cursorY > _scrollBottom) return;
    cursorX = 0;
    _scrollRegion(cursorY, _scrollBottom, count, up: true);
  }

  void _deleteChars(int count) {
    _clampPendingWrap();
    final active = buffer;
    final rowBase = cursorY * width;
    final codes = active.glyphCodes;
    if (cursorX > 0 &&
        codes[rowBase + cursorX] == GlyphCellList.wideContinuationCode) {
      _resetSplitCell(active, rowBase + cursorX - 1);
    }
    final remaining = width - cursorX;
    final del = math.min(count, remaining);
    final srcEnd = cursorX + del;
    if (srcEnd < width &&
        codes[rowBase + srcEnd] == GlyphCellList.wideContinuationCode) {
      _resetSplitCell(active, rowBase + srcEnd);
    }
    _copyCellSpan(active, rowBase + cursorX, rowBase + srcEnd, remaining - del);
    _eraseRowSpan(cursorY, width - del, width);
  }

  void _insertBlankChars(int count) {
    _clampPendingWrap();
    final active = buffer;
    final rowBase = cursorY * width;
    if (cursorX > 0 &&
        active.glyphCodes[rowBase + cursorX] ==
            GlyphCellList.wideContinuationCode) {
      _resetSplitCell(active, rowBase + cursorX - 1);
      _resetSplitCell(active, rowBase + cursorX);
    }
    final remaining = width - cursorX;
    final ins = math.min(count, remaining);
    final shiftCols = remaining - ins;
    if (shiftCols > 0) {
      final src = rowBase + cursorX;
      if (_isWideCellAt(active, src + shiftCols - 1)) {
        _resetSplitCell(active, src + shiftCols - 1);
      }
      _copyCellSpan(active, src + ins, src, shiftCols);
    }
    _eraseRowSpan(cursorY, cursorX, cursorX + ins);
  }

  void _applySgr(List<int> params, {List<List<int>?>? subparams}) {
    if (params.isEmpty) {
      _currentStyle = .empty;
      return;
    }
    var i = 0;
    while (i < params.length) {
      final code = params[i];
      final sub = (subparams != null && i < subparams.length)
          ? subparams[i]
          : null;
      if (sub != null) {
        _applyColonSgr(code, sub);
        i++;
        continue;
      }
      if (code == 38 || code == 48 || code == 58) {
        final (color, consumed) = _parseExtendedColor(
          params,
          i,
          subparams: subparams,
        );
        _applyExtendedSgrColor(code, color);
        i += consumed;
        continue;
      }
      _applySingleSgrCode(code);
      i++;
    }
  }

  void _applyColonSgr(int code, List<int> sub) {
    switch ((code, sub)) {
      case (4, [final variant, ...]) when variant >= 0 && variant <= 5:
        _setUnderlineStyle(UnderlineStyle.values[variant]);
      case (38 || 48 || 58, _):
        _applyExtendedSgrColor(code, _parseColonExtendedColor(sub));
    }
  }

  void _applyExtendedSgrColor(int code, Color? color) {
    if (color == null) return;
    _currentStyle = switch (code) {
      38 => _currentStyle.merge(Style(foreground: color)),
      48 => _currentStyle.merge(Style(background: color)),
      58 => _currentStyle.merge(Style(underlineColor: color)),
      _ => _currentStyle,
    };
  }

  Color? _parseColonExtendedColor(List<int> sub) => switch (sub) {
    [5, final index, ...] => _colorFromAnsi256(index),
    [2, _, final r, final g, final b, ...] || [2, final r, final g, final b] =>
      Color(r.clamp(0, 255), g.clamp(0, 255), b.clamp(0, 255)),
    _ => null,
  };

  static int _semicolonSpanEnd(
    List<int> params,
    List<List<int>?>? subparams,
    int index,
  ) {
    final limit = math.min(params.length, index + 5);
    if (subparams == null) return limit;
    var end = index + 1;
    while (end < limit && (end >= subparams.length || subparams[end] == null)) {
      end++;
    }
    return end;
  }

  (Color?, int) _parseExtendedColor(
    List<int> params,
    int index, {
    List<List<int>?>? subparams,
  }) {
    final end = _semicolonSpanEnd(params, subparams, index);
    if (index + 1 >= end) return (null, 1);
    final mode = params[index + 1];
    if (mode == 5) {
      if (index + 2 >= end) return (null, end - index);
      return (_colorFromAnsi256(params[index + 2]), 3);
    }
    if (mode == 2) {
      if (index + 4 >= end) return (null, end - index);
      final r = params[index + 2].clamp(0, 255);
      final g = params[index + 3].clamp(0, 255);
      final b = params[index + 4].clamp(0, 255);
      return (Color(r, g, b), 5);
    }
    return (null, 2);
  }

  void _applySingleSgrCode(int code) {
    switch (code) {
      case 0:
        _currentStyle = .empty;
      case 4:
        _setUnderlineStyle(UnderlineStyle.single);
      case 21:
        _setUnderlineStyle(UnderlineStyle.doubleLine);
      case 24:
        _setUnderlineStyle(UnderlineStyle.none);
      case 1 || 2 || 3 || 5 || 6 || 7 || 8 || 9 || 53:
        _setModifier(_modifierBitForSet(code), enable: true);
      case 22:
        _setModifier(Modifier.bold | Modifier.dim, enable: false);
      case 23 || 25 || 27 || 28 || 29 || 55:
        _setModifier(_modifierBitForReset(code), enable: false);
      case 39 || 49 || 59:
        _resetColorChannel(code);
      default:
        _applyBasicPaletteCode(code);
    }
  }

  void _setUnderlineStyle(UnderlineStyle style) {
    _currentStyle = Style(
      foreground: _currentStyle.foreground,
      background: _currentStyle.background,
      underlineColor: _currentStyle.underlineColor,
      modifiers: Modifier.withUnderlineStyle(_currentStyle.modifiers, style),
    );
  }

  void _resetColorChannel(int code) {
    _currentStyle = Style(
      foreground: code == 39 ? null : _currentStyle.foreground,
      background: code == 49 ? null : _currentStyle.background,
      underlineColor: code == 59 ? null : _currentStyle.underlineColor,
      modifiers: _currentStyle.modifiers,
    );
  }

  static int _modifierBitForSet(int code) => switch (code) {
    1 => Modifier.bold,
    2 => Modifier.dim,
    3 => Modifier.italic,
    5 || 6 => Modifier.blink,
    7 => Modifier.reverse,
    8 => Modifier.hidden,
    9 => Modifier.crossedOut,
    53 => Modifier.overline,
    _ => Modifier.none,
  };

  static int _modifierBitForReset(int code) => switch (code) {
    23 => Modifier.italic,
    25 => Modifier.blink,
    27 => Modifier.reverse,
    28 => Modifier.hidden,
    29 => Modifier.crossedOut,
    55 => Modifier.overline,
    _ => Modifier.none,
  };

  void _setModifier(int mask, {required bool enable}) {
    final nextModifiers = enable
        ? (_currentStyle.modifiers | mask)
        : (_currentStyle.modifiers & ~mask);
    _currentStyle = Style(
      foreground: _currentStyle.foreground,
      background: _currentStyle.background,
      underlineColor: _currentStyle.underlineColor,
      modifiers: nextModifiers,
    );
  }

  void _applyBasicPaletteCode(int code) {
    if (code >= 30 && code <= 37) {
      _currentStyle = _currentStyle.merge(
        Style(foreground: _colorFromAnsi256(code - 30)),
      );
    } else if (code >= 90 && code <= 97) {
      _currentStyle = _currentStyle.merge(
        Style(foreground: _colorFromAnsi256(code - 90 + 8)),
      );
    } else if (code >= 40 && code <= 47) {
      _currentStyle = _currentStyle.merge(
        Style(background: _colorFromAnsi256(code - 40)),
      );
    } else if (code >= 100 && code <= 107) {
      _currentStyle = _currentStyle.merge(
        Style(background: _colorFromAnsi256(code - 100 + 8)),
      );
    }
  }

  @override
  void apc(String payload) {
    _clearLastPrintedCell();
    if (payload.startsWith('A') || payload.startsWith('_A')) {
      _audioApcHandler.handleApc(payload);
      return;
    }
    if (payload.startsWith('S') || payload.startsWith('_S')) {
      _activeShaderState.parser.handleApc(payload);
      return;
    }
    _markDirty();
    _kittyApcHandler.handleApc(payload);
  }

  void _handleShaderEvent(TerminalShaderApcEvent event) {
    switch (event) {
      case TerminalShaderQueryEvent():
        _replyShaderCapabilities();
        onShaderEvent?.call(event);
      case TerminalShaderDefineEvent():
        onShaderEvent?.call(event);
      case TerminalShaderRegionEvent():
        _applyShaderRegionEvent(event);
        _markDirty();
        onShaderEvent?.call(event);
      case TerminalShaderTransformBatchEvent():
        _applyShaderTransformBatchEvent(event);
        _markDirty();
        onShaderEvent?.call(event);
      case TerminalShaderSetEvent():
        _markDirty();
        onShaderEvent?.call(event);
      case TerminalShaderUniformEvent():
        _applyShaderUniformEvent(event);
        _markDirty();
        onShaderEvent?.call(event);
      case TerminalResetShaderEvent():
        _applyShaderResetEvent(event);
        _markDirty();
        onShaderEvent?.call(event);
    }
  }

  void _replyShaderCapabilities() {
    final caps =
        shaderCapabilitiesProvider?.call() ?? defaultDisabledShaderCapabilities;
    onReply?.call(
      ShaderApcEncoder.encodeCapsReply(
        backend: caps.backend,
        glsl: caps.glsl,
        xform: caps.xform,
        region: caps.region,
        maxSlots: caps.maxSlots,
        maxRegions: caps.maxRegions,
      ),
    );
  }

  void _applyShaderRegionEvent(TerminalShaderRegionEvent event) {
    final state = _activeShaderState;
    if (event.remove || event.region == null) {
      state.regions.remove(event.id);
      _syncActiveBufferShaderMetadata();
      return;
    }
    final clipped = event.region!.translatedAndClipped(
      0,
      0,
      Rect(0, 0, width, height),
    );
    if (clipped == null) {
      state.regions.remove(event.id);
    } else if (state.regions.containsKey(event.id) ||
        state.regions.length < ShaderRegion.maxRegionsPerPane) {
      state.regions[event.id] = clipped;
    }
    _syncActiveBufferShaderMetadata();
  }

  void _applyShaderTransformBatchEvent(
    TerminalShaderTransformBatchEvent event,
  ) {
    final table = _activeShaderState.transforms;
    if (event.replace) {
      table.clear();
    }
    for (final entry in event.entries) {
      if (entry.col < 0 ||
          entry.col >= width ||
          entry.row < 0 ||
          entry.row >= height) {
        continue;
      }
      final cellIdx = entry.row * width + entry.col;
      final transform = entry.transform;
      if (transform == null || transform.isIdentity) {
        table.remove(cellIdx);
      } else {
        table.set(cellIdx, transform);
      }
    }
    _syncActiveBufferShaderMetadata();
  }

  void _applyShaderUniformEvent(TerminalShaderUniformEvent event) {
    final id = event.id;
    if (id == null) return;
    final state = _activeShaderState;
    final existing = state.regions[id];
    if (existing == null) return;
    final updated = ShaderRegion.sanitizeParams(existing.params);
    for (var i = 0; i < ShaderRegion.paramCount; i++) {
      if ((event.paramMask & (1 << i)) != 0) {
        updated[i] = event.params[i];
      }
    }
    state.regions[id] = existing.copyWith(params: updated);
    _syncActiveBufferShaderMetadata();
  }

  void _applyShaderResetEvent(TerminalResetShaderEvent event) {
    final state = _activeShaderState;
    switch (event.target) {
      case ShaderResetTarget.all:
        state.regions.clear();
        state.transforms.clear();
      case ShaderResetTarget.regions:
        state.regions.clear();
      case ShaderResetTarget.xforms:
        state.transforms.clear();
      case ShaderResetTarget.pane:
        return;
    }
    _syncActiveBufferShaderMetadata();
  }

  void _syncActiveBufferShaderMetadata() {
    _syncBufferShaderMetadata(
      buffer,
      _activeShaderState,
      hideOverlays: !_usingAltScreen && _viewportOffset > 0,
    );
  }

  void _syncPrimaryShaderOverlays() {
    _syncBufferShaderMetadata(
      _primaryBuffer,
      _primaryShaderState,
      hideOverlays: _viewportOffset > 0,
    );
  }

  void _syncBufferShaderMetadata(
    Buffer target,
    _ScreenShaderState state, {
    required bool hideOverlays,
  }) {
    _shaderMetadataRevision++;
    target.clearShaderRegions();
    target.clearCellTransforms();
    if (hideOverlays) return;
    for (final region in state.regions.values) {
      target.addShaderRegion(region);
    }
    if (state.transforms.isEmpty) return;
    for (final entry in state.transforms.entries) {
      target.setCellTransformAt(entry.key, entry.value);
    }
  }

  void _shiftShaderStateRows(
    _ScreenShaderState state,
    int top,
    int bottom,
    int deltaRows,
  ) {
    if (deltaRows == 0) return;
    _shiftTransformsInRegion(state.transforms, top, bottom, deltaRows);
    _shiftRegionsInRegion(state.regions, top, bottom, deltaRows);
  }

  void _shiftTransformsInRegion(
    CellTransformTable table,
    int top,
    int bottom,
    int deltaRows,
  ) {
    if (table.isEmpty) return;
    if (top == 0 && bottom == height - 1) {
      table.shiftRows(deltaRows, width, height);
      return;
    }
    final next = <int, CellTransform>{};
    for (final entry in table.entries) {
      final col = entry.key % width;
      final row = entry.key ~/ width;
      if (row < top || row > bottom) {
        next[entry.key] = entry.value;
        continue;
      }
      final newRow = row + deltaRows;
      if (newRow >= top && newRow <= bottom) {
        next[newRow * width + col] = entry.value;
      }
    }
    table.clear();
    for (final entry in next.entries) {
      table.set(entry.key, entry.value);
    }
  }

  void _shiftRegionsInRegion(
    Map<String, ShaderRegion> regions,
    int top,
    int bottom,
    int deltaRows,
  ) {
    if (regions.isEmpty) return;
    final clip = Rect(0, top, width, bottom - top + 1);
    final isFullScreen = top == 0 && bottom == height - 1;
    for (final id in [...regions.keys]) {
      final region = regions[id]!;
      final shifted = isFullScreen
          ? region.translatedAndClipped(0, deltaRows, clip)
          : _shiftRegionWithinBand(region, top, bottom, deltaRows, clip);
      if (shifted == null) {
        regions.remove(id);
      } else {
        regions[id] = shifted;
      }
    }
  }

  ShaderRegion? _shiftRegionWithinBand(
    ShaderRegion region,
    int top,
    int bottom,
    int deltaRows,
    Rect bandClip,
  ) {
    final nextRects = <Rect>[];
    for (final rect in region.sourceRects) {
      final rectBottom = rect.y + rect.height - 1;
      if (rectBottom < top || rect.y > bottom) {
        nextRects.add(rect);
        continue;
      }
      final moved = Rect(
        rect.x,
        rect.y + deltaRows,
        rect.width,
        rect.height,
      ).intersect(bandClip);
      if (moved.width > 0 && moved.height > 0) {
        nextRects.add(moved);
      }
    }
    return nextRects.isEmpty ? null : region.copyWith(sourceRects: nextRects);
  }

  static void _resizeShaderState(
    _ScreenShaderState state,
    int oldWidth,
    int oldHeight,
    int newWidth,
    int newHeight,
  ) {
    state.transforms.resize(oldWidth, oldHeight, newWidth, newHeight);
    if (state.regions.isEmpty) return;
    final bounds = Rect(0, 0, newWidth, newHeight);
    for (final id in [...state.regions.keys]) {
      final clipped = state.regions[id]!.translatedAndClipped(0, 0, bounds);
      if (clipped == null) {
        state.regions.remove(id);
      } else {
        state.regions[id] = clipped;
      }
    }
  }

  @override
  void osc(int command, String payload) {
    _clearLastPrintedCell();
    switch (command) {
      case 0:
        _markDirty();
        iconTitle = payload;
        windowTitle = payload;
        onTitleChanged?.call(payload);
      case 1:
        _markDirty();
        iconTitle = payload;
      case 2:
        _markDirty();
        windowTitle = payload;
        onTitleChanged?.call(payload);
      case 7:
        _markDirty();
        _handleOsc7(payload);
      case 8:
        _markDirty();
        _handleOsc8(payload);
      case 4:
        _handleOsc4(payload);
      case 9:
        _handleOsc9(payload);
      case 10 || 11 || 12:
        _handleDynamicColorOsc(command, payload);
      case 22:
        _handleOsc22(payload);
      case 52:
        _handleOsc52(payload);
      case 99:
        _handleOsc99(payload);
      case 104:
        _handleOsc104(payload);
      case 110:
        if (_osc10Override != null) {
          _osc10Override = null;
          _markDirty();
        }
      case 111:
        if (_osc11Override != null) {
          _osc11Override = null;
          _markDirty();
        }
      case 112:
        if (_osc12Override != null) {
          _osc12Override = null;
          _markDirty();
        }
      case 133:
        _markDirty();
        _handleOsc133(payload);
      default:
        _handleOscUnknown(command, payload);
    }
  }

  static String _formatX11Rgb(Color color) {
    final r = (color.r * 0x101).toRadixString(16).padLeft(4, '0');
    final g = (color.g * 0x101).toRadixString(16).padLeft(4, '0');
    final b = (color.b * 0x101).toRadixString(16).padLeft(4, '0');
    return 'rgb:$r/$g/$b';
  }

  void _handleOsc9(String payload) {
    if (_conEmuOsc9Regex.hasMatch(payload)) return;
    onNotification?.call('', payload);
  }

  /// Active terminal color scheme used for `CSI ? 996 n` and `DECSET 2031`.
  TerminalBrightness get colorScheme => _colorScheme;

  /// Updates [colorScheme] and notifies listeners (and subscribers if mode `2031` is enabled).
  void setColorScheme(TerminalBrightness scheme) {
    if (_colorScheme == scheme) return;
    _colorScheme = scheme;
    if (_colorSchemeReporting) {
      _replyColorScheme();
    }
    _notifyListeners();
  }

  Color _resolveIndexedColor(int index) {
    final override = _osc4Overrides[index];
    if (override != null) return override;
    if (theme case final t?) return t.resolveAnsi256(index);
    return _legacyColorFromAnsi256(index);
  }

  Color _effectiveDynamicColor(int oscCode) => switch (oscCode) {
    10 =>
      _osc10Override ??
          defaultForeground ??
          theme?.foreground ??
          const Color(255, 255, 255),
    11 =>
      _osc11Override ??
          defaultBackground ??
          theme?.background ??
          const Color(0, 0, 0),
    12 =>
      _osc12Override ??
          defaultCursorColor ??
          theme?.cursorColor ??
          _osc10Override ??
          defaultForeground ??
          theme?.foreground ??
          const Color(255, 255, 255),
    _ => const Color(255, 255, 255),
  };

  void _handleOsc4(String payload) {
    final parts = payload.split(';');
    for (var i = 0; i + 1 < parts.length; i += 2) {
      final index = int.tryParse(parts[i].trim());
      if (index == null || index < 0 || index > 255) continue;
      final spec = parts[i + 1].trim();
      if (spec == '?') {
        final color = _resolveIndexedColor(index);
        onReply?.call('\x1b]4;$index;${_formatX11Rgb(color)}\x1b\\');
        continue;
      }
      final parsed = _parseX11Color(spec);
      if (parsed != null) {
        _osc4Overrides[index] = parsed;
        _markDirty();
      }
    }
  }

  void _handleOsc104(String payload) {
    final trimmed = payload.trim();
    if (trimmed.isEmpty) {
      if (_osc4Overrides.isNotEmpty) {
        _osc4Overrides.clear();
        _markDirty();
      }
      return;
    }
    for (final part in trimmed.split(';')) {
      final index = int.tryParse(part.trim());
      if (index != null &&
          index >= 0 &&
          index <= 255 &&
          _osc4Overrides.remove(index) != null) {
        _markDirty();
      }
    }
  }

  void _handleDynamicColorOsc(int startCode, String payload) {
    final parts = payload.split(';');
    for (var i = 0; i < parts.length; i++) {
      final code = startCode + i;
      if (code > 12) break;
      final spec = parts[i].trim();
      if (spec == '?') {
        final color = _effectiveDynamicColor(code);
        onReply?.call('\x1b]$code;${_formatX11Rgb(color)}\x1b\\');
        continue;
      }
      final parsed = _parseX11Color(spec);
      if (parsed == null) continue;
      switch (code) {
        case 10:
          _osc10Override = parsed;
        case 11:
          _osc11Override = parsed;
        case 12:
          _osc12Override = parsed;
      }
      _markDirty();
    }
  }

  static Color? _parseX11Color(String spec) {
    final trimmed = spec.trim();
    if (trimmed.startsWith('#')) {
      final hex = trimmed.substring(1);
      final channelWidth = switch (hex.length) {
        3 => 1,
        6 => 2,
        9 => 3,
        12 => 4,
        _ => 0,
      };
      if (channelWidth == 0) return null;
      final r = _parseScaledHexChannel(hex.substring(0, channelWidth));
      final g = _parseScaledHexChannel(
        hex.substring(channelWidth, channelWidth * 2),
      );
      final b = _parseScaledHexChannel(
        hex.substring(channelWidth * 2, channelWidth * 3),
      );
      if (r == null || g == null || b == null) return null;
      return Color(r, g, b);
    }
    if (trimmed.toLowerCase().startsWith('rgb:')) {
      final channels = trimmed.substring(4).split('/');
      if (channels.length != 3) return null;
      final r = _parseScaledHexChannel(channels[0]);
      final g = _parseScaledHexChannel(channels[1]);
      final b = _parseScaledHexChannel(channels[2]);
      if (r == null || g == null || b == null) return null;
      return Color(r, g, b);
    }
    return null;
  }

  static int? _parseScaledHexChannel(String hex) {
    if (hex.isEmpty || hex.length > 4) return null;
    final value = int.tryParse(hex, radix: 16);
    if (value == null || value < 0) return null;
    return switch (hex.length) {
      1 => (value * 255) ~/ 15,
      2 => value,
      3 => value >> 4,
      4 => value >> 8,
      _ => null,
    };
  }

  void _handleOsc22(String payload) {
    if (payload.startsWith('?')) {
      _replyOsc22Query(payload.substring(1));
      return;
    }
    final before = mouseCursorShape;
    if (payload.startsWith('>')) {
      _pushOsc22Shapes(payload.substring(1));
    } else if (payload.startsWith('<')) {
      if (_pointerShapeStack.isNotEmpty) {
        _pointerShapeStack.removeLast();
      }
    } else {
      final raw = payload.startsWith('=') ? payload.substring(1) : payload;
      _setOsc22Shape(raw);
    }
    final after = mouseCursorShape;
    if (after != before) {
      _markDirty();
      onMouseCursorChanged?.call(after);
    }
  }

  void _replyOsc22Query(String queryBody) {
    if (queryBody.isEmpty) {
      onReply?.call('\x1b]22;\x1b\\');
      return;
    }
    final results = <String>[];
    final tokens = queryBody.split(',');
    final count = math.min(tokens.length, _maxOsc22QueryTokens);
    for (var i = 0; i < count; i++) {
      final token = tokens[i].trim();
      if (token == '__current__') {
        results.add(
          mouseCursorShape ?? (_pointerShapeStack.isEmpty ? '0' : 'default'),
        );
      } else {
        results.add(MousePointer.fromOsc22Name(token) != null ? '1' : '0');
      }
    }
    onReply?.call('\x1b]22;${results.join(',')}\x1b\\');
  }

  static ({bool valid, String? value}) _parseOsc22Shape(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty || trimmed == 'default') {
      return (valid: true, value: null);
    }
    if (!_osc22ValidShapeRegex.hasMatch(trimmed)) {
      return (valid: false, value: null);
    }
    return (valid: true, value: trimmed);
  }

  void _pushOsc22Shapes(String namesPart) {
    for (final raw in namesPart.split(',')) {
      final parsed = _parseOsc22Shape(raw);
      if (!parsed.valid) continue;
      if (_pointerShapeStack.length >= _maxPointerShapeStackDepth) {
        _pointerShapeStack.removeAt(0);
      }
      _pointerShapeStack.add(parsed.value);
    }
  }

  void _setOsc22Shape(String raw) {
    final parsed = _parseOsc22Shape(raw);
    if (!parsed.valid) return;
    final normalized = parsed.value;
    if (normalized == null) {
      if (_pointerShapeStack.length <= 1) {
        _pointerShapeStack.clear();
      } else {
        _pointerShapeStack[_pointerShapeStack.length - 1] = null;
      }
      return;
    }
    if (_pointerShapeStack.isEmpty) {
      _pointerShapeStack.add(normalized);
    } else {
      _pointerShapeStack[_pointerShapeStack.length - 1] = normalized;
    }
  }

  void _handleOsc99(String payload) {
    final semi = payload.indexOf(';');
    if (semi < 0) {
      if (payload.contains('=')) {
        _processKittyOsc99(payload, '');
      } else if (payload.isNotEmpty) {
        onNotification?.call('', payload);
      }
      return;
    }
    final metaPart = payload.substring(0, semi);
    final bodyPart = payload.substring(semi + 1);
    if (!metaPart.contains('=') && metaPart.isNotEmpty) {
      onNotification?.call(metaPart, bodyPart);
      return;
    }
    _processKittyOsc99(metaPart, bodyPart);
  }

  void _processKittyOsc99(String metaPart, String bodyPart) {
    final meta = _parseOsc99Meta(metaPart);
    if (meta.payloadType == '?') {
      final safeId = _sanitizeOsc99Id(meta.id);
      final idPrefix = safeId.isEmpty ? '' : 'i=$safeId:';
      onReply?.call(
        '\x1b]99;${idPrefix}p=?;a=report:c=1:p=title,body,close,?\x1b\\',
      );
      return;
    }
    if (meta.payloadType == 'close') {
      _pendingOsc99.remove(meta.id);
      return;
    }
    if (meta.payloadType != '' &&
        meta.payloadType != 'title' &&
        meta.payloadType != 'body') {
      return;
    }

    if (!_pendingOsc99.containsKey(meta.id) &&
        _pendingOsc99.length >= _maxPendingOsc99) {
      _pendingOsc99.remove(_pendingOsc99.keys.first);
    }
    final pending = _pendingOsc99.putIfAbsent(meta.id, _PendingOsc99.new);
    if (meta.reportActivation) pending.reportActivation = true;
    if (meta.reportClose) pending.reportClose = true;
    final content = _decodeOsc99Payload(bodyPart, isBase64: meta.isBase64);
    pending.append(
      content,
      isBody: meta.payloadType == 'body',
      maxChars: _maxOsc99Chars,
    );

    if (meta.done) {
      _pendingOsc99.remove(meta.id);
      final titleStr = pending.title.toString();
      final bodyStr = pending.body.toString();
      onNotification?.call(titleStr, bodyStr);
      onOsc99Notification?.call((
        id: meta.id,
        title: titleStr,
        body: bodyStr,
        reportActivation: pending.reportActivation,
        reportClose: pending.reportClose,
      ));
    }
  }

  ({
    String id,
    String payloadType,
    bool done,
    bool isBase64,
    bool reportActivation,
    bool reportClose,
  })
  _parseOsc99Meta(String metaPart) {
    var id = '';
    var payloadType = '';
    var done = true;
    var isBase64 = false;
    var reportActivation = false;
    var reportClose = false;

    for (final entry in metaPart.split(':')) {
      final eq = entry.indexOf('=');
      if (eq <= 0) continue;
      final k = entry.substring(0, eq).trim();
      final v = entry.substring(eq + 1).trim();
      switch (k) {
        case 'i':
          id = v;
        case 'p':
          payloadType = v.toLowerCase();
        case 'd':
          done = v != '0';
        case 'e':
          isBase64 = v == '1';
        case 'a':
          reportActivation = v.split(',').contains('report');
        case 'c':
          reportClose = v == '1';
      }
    }
    return (
      id: id,
      payloadType: payloadType,
      done: done,
      isBase64: isBase64,
      reportActivation: reportActivation,
      reportClose: reportClose,
    );
  }

  String _decodeOsc99Payload(String body, {required bool isBase64}) {
    if (!isBase64) return body;
    try {
      final cleaned = body.replaceAll(_whitespaceRegex, '');
      final bytes = base64.decode(base64.normalize(cleaned));
      return utf8.decode(bytes, allowMalformed: true);
    } on Exception {
      return body;
    }
  }

  void _handleOscUnknown(int command, String payload) {
    if (command == -1) {
      if (payload.startsWith('10;?')) {
        _handleDynamicColorOsc(10, '?');
      } else if (payload.startsWith('11;?')) {
        _handleDynamicColorOsc(11, '?');
      }
    }
  }

  void _handleOsc8(String payload) {
    final semi = payload.indexOf(';');
    if (semi == -1) return;
    final uri = sanitizeOsc8Uri(payload.substring(semi + 1));
    _activeUri = uri.isEmpty ? null : uri;
  }

  void _handleOsc7(String payload) {
    final trimmed = payload.trim();
    if (trimmed.isEmpty) return;
    final uri = Uri.tryParse(trimmed);
    final rawPath = (uri != null && uri.scheme == 'file') ? uri.path : trimmed;
    if (rawPath.isEmpty) return;
    String decoded;
    try {
      decoded = Uri.decodeFull(rawPath);
    } on ArgumentError {
      decoded = rawPath;
    }
    workingDirectory = decoded;
    onWorkingDirectoryChanged?.call(decoded);
  }

  void _handleOsc133(String payload) {
    if (payload.isEmpty) return;
    final marker = payload[0];
    switch (marker) {
      case 'A':
        promptZone = .prompt;
        _recordPromptLine();
        onShellIntegration?.call(.prompt);
      case 'B':
        promptZone = .commandInput;
        onShellIntegration?.call(.commandInput);
      case 'C':
        promptZone = .commandOutput;
        onShellIntegration?.call(.commandOutput);
      case 'D':
        final exitCode = _parseOsc133ExitCode(payload);
        lastCommandExitCode = exitCode;
        promptZone = .none;
        onShellIntegration?.call(.none, exitCode: exitCode);
    }
  }

  static int? _parseOsc133ExitCode(String payload) {
    if (payload.length < 3 || payload.codeUnitAt(1) != 0x3B) return null;
    final rest = payload.substring(2);
    final semi = rest.indexOf(';');
    final token = semi < 0 ? rest : rest.substring(0, semi);
    return int.tryParse(token);
  }

  void _handleOsc52(String payload) {
    if (payload.length > _maxOsc52PayloadLength) return;
    final semi = payload.indexOf(';');
    if (semi < 0) return;
    final rawSelection = payload.substring(0, semi);
    final selection = rawSelection.isEmpty ? 'c' : rawSelection;
    final body = payload.substring(semi + 1).trim();
    if (body == '?') {
      onClipboardReadBlocked?.call(selection);
      return;
    }
    final writer = onClipboardWrite;
    if (writer == null) return;
    final text = _decodeOsc52Payload(body);
    if (text != null) {
      writer(selection, text);
    }
  }

  static String? _decodeOsc52Payload(String body) {
    final cleaned = body.replaceAll(_whitespaceRegex, '');
    try {
      final decodedBytes = base64.decode(base64.normalize(cleaned));
      if (decodedBytes.length > _maxOsc52DecodedBytes) return null;
      final text = utf8.decode(decodedBytes, allowMalformed: true);
      if (utf8.encode(text).length > _maxOsc52DecodedBytes) return null;
      return text;
    } on FormatException {
      return null;
    }
  }

  @override
  void esc(String command) {
    _clearLastPrintedCell();
    _markDirty();
    switch (command) {
      case 'c': // RIS (Reset to Initial State)
        _resetState(fullReset: true);
      case '7': // DECSC (Save Cursor)
        _saveCursor();
      case '8': // DECRC (Restore Cursor)
        _restoreCursor();
      case 'D': // IND (Index)
        _clampPendingWrap();
        _indexDown();
      case 'E': // NEL (Next Line)
        cursorX = 0;
        _indexDown();
      case 'M': // RI (Reverse Index)
        _reverseIndex();
      case 'H': // HTS (Horizontal Tab Set)
        _tabStops.add(cursorX.clamp(0, width - 1));
      case '(0': // Designate G0 as DEC Special Graphics
        _g0DecGraphics = true;
      case _ when command.startsWith('('): // Designate G0 as ASCII / non-DEC
        _g0DecGraphics = false;
      case ')0': // Designate G1 as DEC Special Graphics
        _g1DecGraphics = true;
      case _ when command.startsWith(')'): // Designate G1 as ASCII / non-DEC
        _g1DecGraphics = false;
    }
  }

  Color _colorFromAnsi256(int code) {
    if (code < 0 || code > 255) return Colors.white;
    return Color.ansi(code);
  }

  Color _legacyColorFromAnsi256(int code) {
    if (code < 0 || code > 255) return Colors.white;
    if (code < 16) {
      final rgb = _ansi16Rgb[code];
      return Color((rgb >> 16) & 0xFF, (rgb >> 8) & 0xFF, rgb & 0xFF);
    }
    if (code < 232) {
      final cube = code - 16;
      final r = (cube ~/ 36) % 6;
      final g = (cube ~/ 6) % 6;
      final b = cube % 6;
      return Color(
        r == 0 ? 0 : r * 40 + 55,
        g == 0 ? 0 : g * 40 + 55,
        b == 0 ? 0 : b * 40 + 55,
      );
    }
    final gray = (code - 232) * 10 + 8;
    return Color(gray, gray, gray);
  }
}

final class _ParserStringSink extends StringConversionSinkBase {
  final void Function(String) _onChunk;

  _ParserStringSink(this._onChunk);

  @override
  void addSlice(String str, int start, int end, bool isLast) {
    if (start < end) {
      _onChunk(str.substring(start, end));
    }
  }

  @override
  void close() {}
}
