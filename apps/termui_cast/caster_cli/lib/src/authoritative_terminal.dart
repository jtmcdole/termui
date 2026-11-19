import 'dart:collection';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:termui/termui.dart';
import 'package:termui_cast_protocol/termui_cast_protocol.dart';
import 'package:termui_pty/termui_pty.dart';

final int _traceTakeNextFrameId = Tracer.registerString(
  'AuthoritativeTerminal.takeNextFrame',
);

const int _maxUncompressedTailBudget = BufferFrameCodec.maxFrameBytes - 256;
const int _emptyDeltaBaseTailBytes = 9;
const int _maxInlineImageBytes =
    _maxUncompressedTailBudget - _emptyDeltaBaseTailBytes;
const int _maxKittyEntriesPerFrame = 1024;
const int _maxKittyDimension = 4096;
const int _maxKittyTotalPixels = 4_194_304;
const int _maxKittyGridSpan = 512;
const int _maxKittyChunkCount = 256;
const int _minPngBytes = 24;

typedef _PreparedKittyWire = ({
  KittyImageData data,
  KittyChunkEncoding encoding,
  Uint8List wireBytes,
  int totalDecodedBytes,
});

final class _PendingKittyChunkTransfer {
  final int imageId;
  final KittyImageData data;
  final KittyChunkEncoding encoding;
  final Uint8List wireBytes;
  final int totalDecodedBytes;
  int? chunkStep;
  int nextChunkIndex = 0;

  _PendingKittyChunkTransfer({
    required this.imageId,
    required this.data,
    required this.encoding,
    required this.wireBytes,
    required this.totalDecodedBytes,
  });
}

typedef _DeltaKittySync = ({
  bool clearAll,
  List<int>? removals,
  List<KittyImagePayload>? upserts,
  bool hasChanges,
});

const _DeltaKittySync _emptyDeltaKittySync = (
  clearAll: false,
  removals: null,
  upserts: null,
  hasChanges: false,
);

/// Wraps [VirtualTerminal] with an event-driven dirty flag and 1D shadow arrays.
final class AuthoritativeTerminal {
  /// Session identifier stamped onto emitted snapshots and deltas.
  final SessionId sessionId;

  /// Optional callback invoked when an `OSC 52` clipboard write or blocked read occurs.
  void Function(ClipboardFrame frame)? onClipboardFrame;

  /// Optional callback invoked when the terminal generates a query response
  /// (`DSR`, `CPR`, `DA1`, `DA2`, `DECRQM`, `XTWINOPS`, or `APC G`) to write back to the PTY.
  void Function(String reply)? onTerminalReply;

  /// Optional diagnostic log callback for skipped oversized Kitty textures.
  void Function(String message)? onLog;

  late final VirtualTerminal _terminal;
  final bool _ownsTerminal;
  final bool _wireTerminalHooks;
  final LinkedHashSet<void Function(String title)> _titleListeners =
      LinkedHashSet();
  final LinkedHashSet<void Function()> _bellListeners = LinkedHashSet();
  final LinkedHashSet<void Function(TerminalAudioEvent event)> _audioListeners =
      LinkedHashSet();
  final LinkedHashSet<void Function(ClipboardFrame frame)> _clipboardListeners =
      LinkedHashSet();

  void Function(String title)? _prevOnTitleChanged;
  void Function()? _prevOnBell;
  void Function(TerminalAudioEvent event)? _prevOnAudioEvent;
  void Function(String selection, String text)? _prevOnClipboardWrite;
  void Function(String selection)? _prevOnClipboardReadBlocked;

  late int _shadowCols;
  late int _shadowRows;
  late List<String> _shadowChars;
  late Uint32List _shadowAttrs;
  late Uint32List _shadowUnderlineColors;
  late List<String?> _shadowUris;
  late Uint8List _shadowWrappedRows;
  final Map<int, KittyImageData> _syncedKittyData = <int, KittyImageData>{};
  final Map<int, KittyImageData> _skippedOversizedData =
      <int, KittyImageData>{};
  final Map<int, _PreparedKittyWire> _preparedChunkWire =
      <int, _PreparedKittyWire>{};
  final LinkedHashMap<int, _PendingKittyChunkTransfer> _pendingKittyChunks =
      LinkedHashMap<int, _PendingKittyChunkTransfer>();
  int _lastImageRegistryRevision = 0;
  bool _hasDeferredKittySync = false;
  CursorState _shadowCursor = CursorState.origin;
  TerminalModes _shadowModes = TerminalModes.defaults;
  ScrollbackWindow _shadowScrollback = ScrollbackWindow.empty;
  int _seq = 0;
  bool _dirty = true;
  bool _forceKeyframe = true;

  /// Creates an authoritative terminal model of [initialCols] by [initialRows].
  AuthoritativeTerminal({
    required this.sessionId,
    int initialCols = 80,
    int initialRows = 24,
    int maxScrollbackLines = 5000,
    TerminalColorTheme initialTheme = TerminalColorTheme.termuiDark,
    this.onLog,
  }) : _ownsTerminal = true,
       _wireTerminalHooks = true {
    final safeCols = max(1, initialCols);
    final safeRows = max(1, initialRows);
    _terminal = VirtualTerminal(
      width: safeCols,
      height: safeRows,
      maxScrollbackLines: maxScrollbackLines,
      syncSafetyTimeout: null,
      emitIndexedColors: true,
      theme: initialTheme,
    )..onReply = (reply) => onTerminalReply?.call(reply);
    _initShadowState(safeCols, safeRows);
    _terminal.addListener(_markDirty);
    _attachTerminalHooks(chainPrevious: false);
  }

  /// Wraps an external [terminal] (such as `PtyRouterSession.terminal`) without
  /// taking ownership of disposal or replacing its `onReply` handler.
  AuthoritativeTerminal.wrapping(
    VirtualTerminal terminal, {
    required this.sessionId,
    bool wireTerminalHooks = true,
    this.onLog,
  }) : _terminal = terminal,
       _ownsTerminal = false,
       _wireTerminalHooks = wireTerminalHooks {
    _initShadowState(_terminal.width, _terminal.height);
    _terminal.addListener(_markDirty);
    if (_wireTerminalHooks) {
      _attachTerminalHooks(chainPrevious: true);
    }
  }

  void _initShadowState(int cols, int rows) {
    final safeCols = clampCols(cols);
    final safeRows = clampRows(rows);
    final totalCells = safeCols * safeRows;
    _shadowCols = safeCols;
    _shadowRows = safeRows;
    _shadowChars = List<String>.filled(totalCells, ' ');
    _shadowAttrs = Uint32List(totalCells * 3);
    _shadowUnderlineColors = Uint32List(totalCells);
    _shadowUris = List<String?>.filled(totalCells, null);
    _shadowWrappedRows = Uint8List(wrappedRowsByteLength(safeRows));
    _lastImageRegistryRevision = _terminal.imageRegistryRevision;
  }

  void _attachTerminalHooks({required bool chainPrevious}) {
    if (chainPrevious) {
      _prevOnTitleChanged = _terminal.onTitleChanged;
      _prevOnBell = _terminal.onBell;
      _prevOnAudioEvent = _terminal.onAudioEvent;
      _prevOnClipboardWrite = _terminal.onClipboardWrite;
      _prevOnClipboardReadBlocked = _terminal.onClipboardReadBlocked;
    }
    _terminal
      ..onTitleChanged = _handleTerminalTitleChanged
      ..onBell = _handleTerminalBell
      ..onAudioEvent = _handleTerminalAudioEvent
      ..onClipboardWrite = _handleTerminalClipboardWrite
      ..onClipboardReadBlocked = _handleTerminalClipboardReadBlocked;
  }

  void _handleTerminalTitleChanged(String title) {
    _prevOnTitleChanged?.call(title);
    for (final listener in List.of(_titleListeners)) {
      listener(title);
    }
  }

  void _handleTerminalBell() {
    _prevOnBell?.call();
    for (final listener in List.of(_bellListeners)) {
      listener();
    }
  }

  void _handleTerminalAudioEvent(TerminalAudioEvent event) {
    _prevOnAudioEvent?.call(event);
    for (final listener in List.of(_audioListeners)) {
      listener(event);
    }
  }

  void _handleTerminalClipboardWrite(String selection, String text) {
    _prevOnClipboardWrite?.call(selection, text);
    if (text.isEmpty) return;
    if (!selection.contains('c') && !selection.contains('p')) return;
    _emitClipboardFrame(ClipboardFrame(sessionId: sessionId, text: text));
  }

  void _handleTerminalClipboardReadBlocked(String selection) {
    _prevOnClipboardReadBlocked?.call(selection);
    _emitClipboardFrame(
      ClipboardFrame(sessionId: sessionId, readBlocked: true),
    );
  }

  void _emitClipboardFrame(ClipboardFrame frame) {
    onClipboardFrame?.call(frame);
    for (final listener in List.of(_clipboardListeners)) {
      listener(frame);
    }
  }

  /// Registers a multi-listener callback for window title (`OSC 0`/`OSC 2`) updates.
  void addTitleListener(void Function(String title) listener) =>
      _titleListeners.add(listener);

  /// Unregisters a window title callback.
  void removeTitleListener(void Function(String title) listener) =>
      _titleListeners.remove(listener);

  /// Registers a multi-listener callback for terminal bell (`BEL`) events.
  void addBellListener(void Function() listener) =>
      _bellListeners.add(listener);

  /// Unregisters a terminal bell callback.
  void removeBellListener(void Function() listener) =>
      _bellListeners.remove(listener);

  /// Registers a multi-listener callback for `ESC _ A` audio events.
  void addAudioListener(void Function(TerminalAudioEvent event) listener) =>
      _audioListeners.add(listener);

  /// Unregisters an audio event callback.
  void removeAudioListener(void Function(TerminalAudioEvent event) listener) =>
      _audioListeners.remove(listener);

  /// Registers a multi-listener callback for `OSC 52` clipboard frames.
  void addClipboardListener(void Function(ClipboardFrame frame) listener) =>
      _clipboardListeners.add(listener);

  /// Unregisters an `OSC 52` clipboard frame callback.
  void removeClipboardListener(void Function(ClipboardFrame frame) listener) =>
      _clipboardListeners.remove(listener);

  /// Current window title reported by the wrapped [VirtualTerminal].
  String get windowTitle => _terminal.windowTitle;

  String? _lastRawUri;
  String? _lastClampedUri;

  void _markDirty() {
    _dirty = true;
  }

  /// Clamps column count into the wire protocol's supported `[1..400]` range.
  static int clampCols(int value) =>
      value.clamp(1, BufferFrameCodec.maxGridCols);

  /// Clamps row count into the wire protocol's supported `[1..200]` range.
  static int clampRows(int value) =>
      value.clamp(1, BufferFrameCodec.maxGridRows);

  bool get _dimsOutOfSync => _shadowCols != cols || _shadowRows != rows;

  /// Current wire-clamped terminal width in columns.
  int get cols => clampCols(_terminal.width);

  /// Current wire-clamped terminal height in rows.
  int get rows => clampRows(_terminal.height);

  /// Cell width in pixels (`>= 1`) reported on `XTWINOPS` (`14t` / `16t`).
  int get cellPixelWidth => _terminal.cellPixelWidth;

  /// Cell height in pixels (`>= 1`) reported on `XTWINOPS` (`14t` / `16t`).
  int get cellPixelHeight => _terminal.cellPixelHeight;

  /// Latest emitted frame sequence number.
  int get seq => _seq;

  /// Whether unshipped mutations, Kitty texture syncs, or a post-resize keyframe are pending.
  bool get isDirty =>
      _dirty ||
      _forceKeyframe ||
      _hasDeferredKittySync ||
      _dimsOutOfSync ||
      _terminal.imageRegistryRevision != _lastImageRegistryRevision;

  /// Whether the next frame must be a full [BufferSnapshot] keyframe.
  bool get needsKeyframe => _seq == 0 || _forceKeyframe || _dimsOutOfSync;

  /// Whether `DECSET 2026` synchronized output mode (`?2026h` / `?2026l`) is active.
  bool get synchronizedOutput => _terminal.synchronizedOutput;

  /// Clears `DECSET 2026` synchronized output mode (e.g. when a safety timeout expires).
  void resetSynchronizedOutput() {
    _terminal.synchronizedOutput = false;
  }

  /// Whether at least one chunked Kitty image transfer still has unsent chunks.
  bool get hasPendingKittyChunks {
    _pruneStaleHeadChunkTransfer();
    return _pendingKittyChunks.isNotEmpty;
  }

  /// Marks a full [BufferSnapshot] keyframe pending for the next [takeNextFrame].
  void forceKeyframe() {
    _forceKeyframe = true;
    _pendingKittyChunks.clear();
  }

  /// Underlying parsed `termui` [Buffer].
  Buffer get buffer => _terminal.buffer;

  /// Current cursor coordinates (clamped into wire bounds), visibility, and shape.
  CursorState get cursor => CursorState(
    x: _terminal.cursorX.clamp(0, cols - 1),
    y: _terminal.cursorY.clamp(0, rows - 1),
    visible: _terminal.cursorVisible,
    shape: _mapCursorShape(_terminal.cursorShape),
  );

  static CursorShape _mapCursorShape(TerminalCursorShape shape) =>
      switch (shape) {
        .defaultShape => .defaultShape,
        .blinkingBlock => .blinkingBlock,
        .steadyBlock => .steadyBlock,
        .blinkingUnderline => .blinkingUnderline,
        .steadyUnderline => .steadyUnderline,
        .blinkingBar => .blinkingBar,
        .steadyBar => .steadyBar,
      };

  /// Current terminal mouse, screen, and input reporting modes.
  TerminalModes get modes => TerminalModes(
    mouseTracking: _terminal.mouseTrackingEnabled,
    sgrMouse: _terminal.sgrMouseMode,
    sgrPixelsMouse: _terminal.sgrPixelsMouseMode,
    bracketedPaste: _terminal.bracketedPasteMode,
    altScreen: _terminal.isUsingAlternateScreen,
    appCursorKeys: _terminal.applicationCursorKeys,
    alternateScroll: _terminal.alternateScrollMode,
    focusReporting: _terminal.focusReportingEnabled,
    kittyKeyboardFlags: _terminal.kittyKeyboardFlags,
  );

  /// Current primary-screen scrollback ring buffer window metadata.
  ScrollbackWindow get scrollbackWindow {
    final sb = _terminal.scrollback;
    return ScrollbackWindow(
      clearSeq: sb.clearSeq,
      oldestLine: sb.oldestLine,
      totalLines: sb.totalLines,
    );
  }

  /// Feeds raw UTF-8/ANSI PTY [bytes] into [VirtualTerminal].
  void writeOutput(List<int> bytes) {
    if (bytes.isEmpty) return;
    _terminal.write(bytes);
    if (_terminal.synchronizedOutput) {
      _dirty = true;
    }
  }

  /// Feeds decoded UTF-16/UTF-8 PTY [chunk] text directly into [VirtualTerminal].
  void writeString(String chunk) {
    if (chunk.isEmpty) return;
    _terminal.writeString(chunk);
    if (_terminal.synchronizedOutput) {
      _dirty = true;
    }
  }

  /// Resizes the terminal grid and marks a full keyframe pending.
  bool resize(int newCols, int newRows) {
    final safeCols = clampCols(newCols);
    final safeRows = clampRows(newRows);
    final vtTargetCols = _ownsTerminal ? safeCols : max(1, newCols);
    final vtTargetRows = _ownsTerminal ? safeRows : max(1, newRows);
    final vtChanged =
        vtTargetCols != _terminal.width || vtTargetRows != _terminal.height;
    final shadowChanged = safeCols != _shadowCols || safeRows != _shadowRows;
    if (!vtChanged && !shadowChanged) {
      return false;
    }
    if (vtChanged) {
      _terminal.resize(vtTargetCols, vtTargetRows);
    }
    _reallocateShadow(clampCols(_terminal.width), clampRows(_terminal.height));
    return true;
  }

  void _reallocateShadow(int safeCols, int safeRows) {
    final totalCells = safeCols * safeRows;
    _shadowCols = safeCols;
    _shadowRows = safeRows;
    _shadowChars = List<String>.filled(totalCells, ' ');
    _shadowAttrs = Uint32List(totalCells * 3);
    _shadowUnderlineColors = Uint32List(totalCells);
    _shadowUris = List<String?>.filled(totalCells, null);
    _shadowWrappedRows = Uint8List(wrappedRowsByteLength(safeRows));
    _dirty = true;
    _forceKeyframe = true;
  }

  /// Captures a full [BufferSnapshot] keyframe, advancing [seq] and syncing shadow state.
  BufferSnapshot takeSnapshot() {
    if (_dimsOutOfSync) {
      _reallocateShadow(cols, rows);
    }
    _seq++;
    final buf = _terminal.buffer;
    if (buf.width == _shadowCols && buf.height == _shadowRows) {
      _shadowChars.setRange(0, _shadowChars.length, buf.characters);
      _shadowAttrs.setRange(0, _shadowAttrs.length, buf.attributes);
      _syncAllShadowAux(buf);
    } else {
      _syncProjectedShadow(buf, _shadowCols, _shadowRows);
    }
    _shadowCursor = cursor;
    _shadowModes = modes;
    _shadowScrollback = scrollbackWindow;
    _shadowWrappedRows = packWrappedRows(rows, _terminal.isRowWrapped);
    _dirty = false;
    _forceKeyframe = false;
    return _buildSnapshot(buf, syncKittyTracking: true);
  }

  void _syncProjectedShadow(Buffer buf, int dstCols, int dstRows) {
    final srcCols = buf.width;
    final copyCols = min(srcCols, dstCols);
    final copyRows = min(buf.height, dstRows);
    final srcChars = buf.characters;
    final srcAttrs = buf.attributes;
    for (var r = 0; r < copyRows; r++) {
      final srcRowStart = r * srcCols;
      final dstRowStart = r * dstCols;
      _shadowChars.setRange(
        dstRowStart,
        dstRowStart + copyCols,
        srcChars,
        srcRowStart,
      );
      _shadowAttrs.setRange(
        dstRowStart * 3,
        (dstRowStart + copyCols) * 3,
        srcAttrs,
        srcRowStart * 3,
      );
      final healSplitWide =
          srcCols > copyCols && srcChars[srcRowStart + copyCols].isEmpty;
      if (healSplitWide) {
        _shadowChars[dstRowStart + copyCols - 1] = ' ';
      }
      final auxLimit = healSplitWide ? copyCols - 1 : copyCols;
      for (var c = 0; c < auxLimit; c++) {
        final srcIdx = srcRowStart + c;
        final dstIdx = dstRowStart + c;
        _shadowUnderlineColors[dstIdx] = buf.hasUnderlineColors
            ? buf.getUnderlineColorAt(srcIdx)
            : 0;
        _shadowUris[dstIdx] = buf.hasUris
            ? _normalizedCellUri(buf, srcIdx)
            : null;
      }
      if (healSplitWide) {
        final lastIdx = dstRowStart + copyCols - 1;
        _shadowUnderlineColors[lastIdx] = 0;
        _shadowUris[lastIdx] = null;
      }
    }
  }

  /// Captures a [BufferSnapshot] at the current [seq] without advancing [seq]
  /// when shadow state is already synced; otherwise delegates to [takeSnapshot].
  BufferSnapshot snapshotCurrent() {
    if (_seq == 0 || isDirty) {
      return takeSnapshot();
    }
    return _buildSnapshot(_terminal.buffer, syncKittyTracking: false);
  }

  BufferSnapshot _buildSnapshot(Buffer buf, {required bool syncKittyTracking}) {
    final isProjected = buf.width != _shadowCols || buf.height != _shadowRows;
    final snapChars = isProjected ? [..._shadowChars] : [...buf.characters];
    final snapAttrs = isProjected
        ? Uint32List.fromList(_shadowAttrs)
        : Uint32List.fromList(buf.attributes);
    final totalCells = _shadowCols * _shadowRows;
    final underlineColors = isProjected
        ? extractSliceUnderlineColors(_shadowUnderlineColors, totalCells)
        : extractBufferUnderlineColors(buf, 0, totalCells);
    final uriRuns = isProjected
        ? extractSliceUriRuns(_shadowUris, totalCells)
        : extractBufferUriRuns(buf, 0, totalCells);
    final spanBytes = _estimateSpanWireBytes(
      snapChars,
      underlineColors,
      uriRuns,
    );
    final kittyImages = _collectSnapshotKittyPayloads(
      cellSpanBytes: spanBytes,
      syncTracking: syncKittyTracking,
    );
    return BufferSnapshot(
      sessionId: sessionId,
      seq: _seq,
      cols: _shadowCols,
      rows: _shadowRows,
      cursor: _shadowCursor,
      modes: _shadowModes,
      scrollback: _shadowScrollback,
      wrappedRows: Uint8List.fromList(_shadowWrappedRows),
      characters: snapChars,
      attributes: snapAttrs,
      underlineColors: underlineColors,
      uriRuns: uriRuns,
      kittyImages: kittyImages,
    );
  }

  /// Slices up to [ScrollbackChunkFrame.maxChunkRows] rows from the local
  /// scrollback ring buffer for [request].
  ScrollbackChunkFrame sliceScrollback(RequestScrollbackFrame request) {
    final sb = _terminal.scrollback;
    if (request.clearSeq != sb.clearSeq) {
      return ScrollbackChunkFrame(
        sessionId: sessionId,
        requestId: request.requestId,
        clearSeq: sb.clearSeq,
        startLine: sb.totalLines,
        rows: const [],
      );
    }
    final oldestLine = sb.oldestLine;
    final totalLines = sb.totalLines;
    final requestedCount = request.count.clamp(
      0,
      ScrollbackChunkFrame.maxChunkRows,
    );
    final actualStart = request.startLine.clamp(oldestLine, totalLines);
    final clampedCount = min(requestedCount, totalLines - actualStart);
    final rows = clampedCount > 0
        ? [
            for (final line in sb.slice(actualStart, clampedCount))
              _encodeScrollbackLine(line),
          ]
        : const <EncodedScrollbackRow>[];
    return ScrollbackChunkFrame(
      sessionId: sessionId,
      requestId: request.requestId,
      clearSeq: sb.clearSeq,
      startLine: actualStart,
      rows: rows,
    );
  }

  static EncodedScrollbackRow _encodeScrollbackLine(ScrollbackLine line) {
    const maxCols = BufferFrameCodec.maxGridCols;
    if (line.characters.length <= maxCols) {
      final len = line.characters.length;
      return EncodedScrollbackRow(
        isWrapped: line.isWrapped,
        characters: line.characters,
        attributes: line.attributes,
        underlineColors: extractSliceUnderlineColors(line.underlineColors, len),
        uriRuns: extractSliceUriRuns(line.uris, len),
      );
    }
    final clampedChars = line.characters.sublist(0, maxCols);
    final healedSplitWide = line.characters[maxCols].isEmpty;
    if (healedSplitWide) {
      clampedChars[maxCols - 1] = ' ';
    }
    final auxLimit = healedSplitWide ? maxCols - 1 : maxCols;
    return EncodedScrollbackRow(
      isWrapped: line.isWrapped,
      characters: clampedChars,
      attributes: Uint32List.sublistView(line.attributes, 0, maxCols * 3),
      underlineColors: extractSliceUnderlineColors(
        line.underlineColors,
        auxLimit,
      ),
      uriRuns: extractSliceUriRuns(line.uris, auxLimit),
    );
  }

  /// Emits either a required post-resize [BufferSnapshotFrame], a minimal
  /// [BufferDeltaFrame], or `null` when nothing changed since [seq].
  CastMessage? takeNextFrame() {
    if (!Tracer.isEnabled) return _takeNextFrameImpl();
    Tracer.record(_traceTakeNextFrameId, Phase.begin, .compositor);
    try {
      return _takeNextFrameImpl();
    } finally {
      Tracer.record(_traceTakeNextFrameId, Phase.end, .compositor);
    }
  }

  CastMessage? _takeNextFrameImpl() {
    if (_forceKeyframe || _dimsOutOfSync) {
      return BufferSnapshotFrame(snapshot: takeSnapshot());
    }
    if (!isDirty) return null;

    final runs = _dirty ? _diffAndSyncCells() : const <CellRun>[];
    final nextCursor = cursor;
    final nextModes = modes;
    final nextScrollback = scrollbackWindow;
    final nextWrappedRows = packWrappedRows(rows, _terminal.isRowWrapped);
    _dirty = false;
    final kittySync = _syncDeltaKittyIfNeeded(runs);

    if (runs.isEmpty &&
        !kittySync.hasChanges &&
        nextCursor == _shadowCursor &&
        nextModes == _shadowModes &&
        nextScrollback == _shadowScrollback &&
        _bytesEqual(nextWrappedRows, _shadowWrappedRows)) {
      return null;
    }

    final baseSeq = _seq;
    _seq++;
    _shadowCursor = nextCursor;
    _shadowModes = nextModes;
    _shadowScrollback = nextScrollback;
    _shadowWrappedRows = nextWrappedRows;
    return BufferDeltaFrame(
      delta: BufferDelta(
        sessionId: sessionId,
        seq: _seq,
        baseSeq: baseSeq,
        cols: cols,
        rows: rows,
        cursor: nextCursor,
        modes: nextModes,
        scrollback: nextScrollback,
        wrappedRows: Uint8List.fromList(nextWrappedRows),
        runs: runs,
        clearKittyImages: kittySync.clearAll,
        kittyRemovals: kittySync.removals,
        kittyUpserts: kittySync.upserts,
      ),
    );
  }

  static bool _bytesEqual(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  List<CellRun> _diffAndSyncCells() {
    final buf = _terminal.buffer;
    if (buf.width != _shadowCols || buf.height != _shadowRows) {
      return _diffAndSyncProjectedCells(buf);
    }
    final chars = buf.characters;
    final attrs = buf.attributes;
    final total = chars.length;
    final runs = <CellRun>[];
    var i = 0;
    while (i < total) {
      if (!_cellDiffers(buf, chars, attrs, i)) {
        i++;
        continue;
      }
      final start = i;
      i++;
      while (i < total && _cellDiffers(buf, chars, attrs, i)) {
        i++;
      }
      runs.add(_extractAndSyncRun(buf, chars, attrs, start, i));
    }
    return runs;
  }

  List<CellRun> _diffAndSyncProjectedCells(Buffer buf) {
    final total = _shadowCols * _shadowRows;
    final proj = _projectBufferToShadowGrid(buf, total);
    return _collectProjectedRuns(proj, total);
  }

  ({List<String> chars, Uint32List attrs, Uint32List ul, List<String?> uris})
  _projectBufferToShadowGrid(Buffer buf, int total) {
    final dstCols = _shadowCols;
    final projChars = List<String>.filled(total, ' ');
    final projAttrs = Uint32List(total * 3);
    final projUl = Uint32List(total);
    final projUris = List<String?>.filled(total, null);
    final srcCols = buf.width;
    final copyCols = min(srcCols, dstCols);
    final copyRows = min(buf.height, _shadowRows);
    final srcChars = buf.characters;
    final srcAttrs = buf.attributes;
    for (var r = 0; r < copyRows; r++) {
      final srcRowStart = r * srcCols;
      final dstRowStart = r * dstCols;
      projChars.setRange(
        dstRowStart,
        dstRowStart + copyCols,
        srcChars,
        srcRowStart,
      );
      projAttrs.setRange(
        dstRowStart * 3,
        (dstRowStart + copyCols) * 3,
        srcAttrs,
        srcRowStart * 3,
      );
      final healSplitWide =
          srcCols > copyCols && srcChars[srcRowStart + copyCols].isEmpty;
      if (healSplitWide) {
        projChars[dstRowStart + copyCols - 1] = ' ';
      }
      _copyRowAuxData(
        buf,
        srcRowStart,
        dstRowStart,
        healSplitWide ? copyCols - 1 : copyCols,
        projUl,
        projUris,
      );
    }
    return (chars: projChars, attrs: projAttrs, ul: projUl, uris: projUris);
  }

  void _copyRowAuxData(
    Buffer buf,
    int srcRowStart,
    int dstRowStart,
    int auxLimit,
    Uint32List projUl,
    List<String?> projUris,
  ) {
    final hasUl = buf.hasUnderlineColors;
    final hasUris = buf.hasUris;
    if (!hasUl && !hasUris) return;
    for (var c = 0; c < auxLimit; c++) {
      final srcIdx = srcRowStart + c;
      final dstIdx = dstRowStart + c;
      if (hasUl) projUl[dstIdx] = buf.getUnderlineColorAt(srcIdx);
      if (hasUris) projUris[dstIdx] = _normalizedCellUri(buf, srcIdx);
    }
  }

  List<CellRun> _collectProjectedRuns(
    ({List<String> chars, Uint32List attrs, Uint32List ul, List<String?> uris})
    proj,
    int total,
  ) {
    bool differs(int idx) {
      final ao = idx * 3;
      return proj.chars[idx] != _shadowChars[idx] ||
          proj.attrs[ao] != _shadowAttrs[ao] ||
          proj.attrs[ao + 1] != _shadowAttrs[ao + 1] ||
          proj.attrs[ao + 2] != _shadowAttrs[ao + 2] ||
          proj.ul[idx] != _shadowUnderlineColors[idx] ||
          proj.uris[idx] != _shadowUris[idx];
    }

    final runs = <CellRun>[];
    var i = 0;
    while (i < total) {
      if (!differs(i)) {
        i++;
        continue;
      }
      final start = i++;
      while (i < total && differs(i)) {
        i++;
      }
      runs.add(_commitProjectedRun(proj, start, i));
    }
    return runs;
  }

  CellRun _commitProjectedRun(
    ({List<String> chars, Uint32List attrs, Uint32List ul, List<String?> uris})
    proj,
    int start,
    int end,
  ) {
    final len = end - start;
    _shadowChars.setRange(start, end, proj.chars, start);
    _shadowAttrs.setRange(start * 3, end * 3, proj.attrs, start * 3);
    _shadowUnderlineColors.setRange(start, end, proj.ul, start);
    _shadowUris.setRange(start, end, proj.uris, start);
    return CellRun(
      startIndex: start,
      characters: proj.chars.sublist(start, end),
      attributes: Uint32List.fromList(proj.attrs.sublist(start * 3, end * 3)),
      underlineColors: extractSliceUnderlineColors(
        Uint32List.sublistView(proj.ul, start, end),
        len,
      ),
      uriRuns: extractSliceUriRuns(proj.uris.sublist(start, end), len),
    );
  }

  bool _cellDiffers(
    Buffer buf,
    List<String> chars,
    Uint32List attrs,
    int index,
  ) {
    final attrOffset = index * 3;
    if (chars[index] != _shadowChars[index] ||
        attrs[attrOffset] != _shadowAttrs[attrOffset] ||
        attrs[attrOffset + 1] != _shadowAttrs[attrOffset + 1] ||
        attrs[attrOffset + 2] != _shadowAttrs[attrOffset + 2]) {
      return true;
    }
    final ul = buf.hasUnderlineColors ? buf.getUnderlineColorAt(index) : 0;
    if (ul != _shadowUnderlineColors[index]) return true;
    final uri = buf.hasUris ? _normalizedCellUri(buf, index) : null;
    return uri != _shadowUris[index];
  }

  CellRun _extractAndSyncRun(
    Buffer buf,
    List<String> chars,
    Uint32List attrs,
    int start,
    int end,
  ) {
    final len = end - start;
    final attrStart = start * 3;
    final attrEnd = end * 3;
    _shadowChars.setRange(start, end, chars, start);
    _shadowAttrs.setRange(attrStart, attrEnd, attrs, attrStart);
    _syncRunShadowAux(buf, start, end);
    final runChars = List<String>.filled(len, ' ')
      ..setRange(0, len, chars, start);
    final runAttrs = Uint32List(len * 3)
      ..setRange(0, len * 3, attrs, attrStart);
    return CellRun(
      startIndex: start,
      characters: runChars,
      attributes: runAttrs,
      underlineColors: extractBufferUnderlineColors(buf, start, len),
      uriRuns: extractBufferUriRuns(buf, start, len),
    );
  }

  void _syncAllShadowAux(Buffer buf) {
    final total = _shadowUnderlineColors.length;
    if (buf.hasUnderlineColors) {
      for (var i = 0; i < total; i++) {
        _shadowUnderlineColors[i] = buf.getUnderlineColorAt(i);
      }
    } else {
      _shadowUnderlineColors.fillRange(0, total, 0);
    }
    if (buf.hasUris) {
      for (var i = 0; i < total; i++) {
        _shadowUris[i] = _normalizedCellUri(buf, i);
      }
    } else {
      _shadowUris.fillRange(0, total, null);
    }
  }

  void _syncRunShadowAux(Buffer buf, int start, int end) {
    if (buf.hasUnderlineColors) {
      for (var i = start; i < end; i++) {
        _shadowUnderlineColors[i] = buf.getUnderlineColorAt(i);
      }
    } else {
      _shadowUnderlineColors.fillRange(start, end, 0);
    }
    if (buf.hasUris) {
      for (var i = start; i < end; i++) {
        _shadowUris[i] = _normalizedCellUri(buf, i);
      }
    } else {
      _shadowUris.fillRange(start, end, null);
    }
  }

  String? _normalizedCellUri(Buffer buf, int index) {
    final raw = buf.getUriAt(index);
    if (raw == null || raw.isEmpty) return null;
    if (identical(raw, _lastRawUri) || raw == _lastRawUri) {
      return _lastClampedUri;
    }
    final clamped = clampOsc8Uri(raw);
    final normalized = clamped.isEmpty ? null : clamped;
    _lastRawUri = raw;
    _lastClampedUri = normalized;
    return normalized;
  }

  /// Pops and builds the next [KittyImageChunkFrame] for any staged large texture,
  /// or returns `null` when no pending chunk transfers remain.
  KittyImageChunkFrame? takeNextKittyChunkFrame({
    int maxChunkBytes = BufferFrameCodec.maxKittyChunkBytes,
  }) {
    RangeError.checkValueInInterval(
      maxChunkBytes,
      1,
      BufferFrameCodec.maxKittyChunkBytes,
      'maxChunkBytes',
    );
    _pruneStaleHeadChunkTransfer();
    if (_pendingKittyChunks.isEmpty) return null;
    final transfer = _pendingKittyChunks.values.first;
    final totalWire = transfer.wireBytes.length;
    final minStepForCap =
        (totalWire + _maxKittyChunkCount - 1) ~/ _maxKittyChunkCount;
    final chunkStep = transfer.chunkStep ??= max(maxChunkBytes, minStepForCap);
    final chunkCount = (totalWire + chunkStep - 1) ~/ chunkStep;
    final index = transfer.nextChunkIndex;
    final start = index * chunkStep;
    final end = min(totalWire, start + chunkStep);
    final slice = Uint8List.sublistView(transfer.wireBytes, start, end);
    transfer.nextChunkIndex = index + 1;
    if (transfer.nextChunkIndex >= chunkCount) {
      _pendingKittyChunks.remove(transfer.imageId);
    }
    return KittyImageChunkFrame(
      sessionId: sessionId,
      imageId: transfer.imageId,
      version: transfer.data.version,
      pixelWidth: transfer.data.pixelWidth,
      pixelHeight: transfer.data.pixelHeight,
      gridCols: transfer.data.gridCols,
      gridRows: transfer.data.gridRows,
      format: transfer.data.format,
      encoding: transfer.encoding,
      totalDecodedBytes: transfer.totalDecodedBytes,
      totalWireBytes: totalWire,
      chunkIndex: index,
      chunkCount: chunkCount,
      data: slice,
    );
  }

  void _pruneStaleHeadChunkTransfer() {
    final registry = _terminal.imageRegistry;
    while (_pendingKittyChunks.isNotEmpty) {
      final transfer = _pendingKittyChunks.values.first;
      if (identical(registry.lookupImage(transfer.imageId), transfer.data)) {
        return;
      }
      _pendingKittyChunks.remove(transfer.imageId);
      _preparedChunkWire.remove(transfer.imageId);
    }
  }

  void _stageKittyChunk(int id, KittyImageData data) {
    final prepared = _prepareKittyChunkWire(id, data);
    _pendingKittyChunks[id] = _PendingKittyChunkTransfer(
      imageId: id,
      data: data,
      encoding: prepared.encoding,
      wireBytes: prepared.wireBytes,
      totalDecodedBytes: prepared.totalDecodedBytes,
    );
  }

  void _cancelKittyChunk(int id) {
    _pendingKittyChunks.remove(id);
    _preparedChunkWire.remove(id);
  }

  _PreparedKittyWire _prepareKittyChunkWire(int id, KittyImageData data) {
    final cached = _preparedChunkWire[id];
    if (cached != null && identical(cached.data, data)) {
      return cached;
    }
    final raw = data.rgbaPixels;
    var encoding = KittyChunkEncoding.raw;
    var wireBytes = raw;
    if (data.format == 32) {
      final compressed = BufferFrameCodec.compressKittyBytes(raw);
      if (compressed.length < raw.length) {
        encoding = KittyChunkEncoding.deflateRaw;
        wireBytes = compressed;
      }
    }
    final prepared = (
      data: data,
      encoding: encoding,
      wireBytes: wireBytes,
      totalDecodedBytes: raw.length,
    );
    _preparedChunkWire[id] = prepared;
    return prepared;
  }

  List<KittyImagePayload>? _collectSnapshotKittyPayloads({
    required int cellSpanBytes,
    required bool syncTracking,
  }) {
    final registry = _terminal.imageRegistry;
    _pruneStaleKittyState(registry);
    if (syncTracking) {
      _syncedKittyData.clear();
      _lastImageRegistryRevision = _terminal.imageRegistryRevision;
    }
    final ids = [...registry.registeredImageIds];
    if (ids.isEmpty) {
      _pendingKittyChunks.clear();
      _preparedChunkWire.clear();
      if (syncTracking) _hasDeferredKittySync = false;
      return null;
    }
    return _packSnapshotKittyPayloads(
      registry,
      ids,
      remainingBudget: _maxUncompressedTailBudget - cellSpanBytes - 2,
      syncTracking: syncTracking,
    );
  }

  List<KittyImagePayload>? _packSnapshotKittyPayloads(
    KittyImageRegistry registry,
    List<int> ids, {
    required int remainingBudget,
    required bool syncTracking,
  }) {
    var budget = remainingBudget;
    final payloads = <KittyImagePayload>[];
    var deferred = false;
    for (final id in ids) {
      final data = registry.lookupImage(id);
      if (data == null || !_acceptOrSkipKittyData(id, data)) continue;
      final consumed = _stageOrPackSnapshotKitty(
        id,
        data,
        payloads: payloads,
        remainingBudget: budget,
        syncTracking: syncTracking,
      );
      if (consumed < 0) {
        deferred = true;
        continue;
      }
      budget -= consumed;
    }
    if (syncTracking || deferred) {
      _hasDeferredKittySync = deferred;
    }
    return payloads.isEmpty ? null : payloads;
  }

  /// Stages oversized snapshot Kitty images for chunked transfer or packs
  /// inline payloads within budget. Returns bytes consumed, `0` when staged
  /// as chunks, or `-1` when inline packing was deferred due to budget/limits.
  int _stageOrPackSnapshotKitty(
    int id,
    KittyImageData data, {
    required List<KittyImagePayload> payloads,
    required int remainingBudget,
    required bool syncTracking,
  }) {
    final wireBytes = KittyImagePayload.estimateWireBytes(data);
    if (wireBytes > _maxInlineImageBytes) {
      _stageKittyChunk(id, data);
      if (syncTracking) _syncedKittyData[id] = data;
      return 0;
    }
    _cancelKittyChunk(id);
    if (payloads.length >= _maxKittyEntriesPerFrame ||
        wireBytes > remainingBudget) {
      _syncedKittyData.remove(id);
      return -1;
    }
    payloads.add(KittyImagePayload.fromImageData(data));
    if (syncTracking) _syncedKittyData[id] = data;
    return wireBytes;
  }

  _DeltaKittySync _syncDeltaKittyIfNeeded(List<CellRun> runs) {
    if (!_hasDeferredKittySync &&
        _terminal.imageRegistryRevision == _lastImageRegistryRevision) {
      return _emptyDeltaKittySync;
    }
    final registry = _terminal.imageRegistry;
    _pruneStaleKittyState(registry);
    _lastImageRegistryRevision = _terminal.imageRegistryRevision;
    final activeIds = [...registry.registeredImageIds];
    if (activeIds.isEmpty) {
      final hadSynced = _syncedKittyData.isNotEmpty;
      _syncedKittyData.clear();
      _pendingKittyChunks.clear();
      _preparedChunkWire.clear();
      _hasDeferredKittySync = false;
      return (
        clearAll: hadSynced,
        removals: null,
        upserts: null,
        hasChanges: hadSynced,
      );
    }
    final (removals, deferredRemovals) = _collectKittyRemovals(registry);
    final baseTailBytes = _estimateDeltaBaseTailBytes(runs, removals.length);
    final remainingBudget = _maxUncompressedTailBudget - baseTailBytes;
    final (upserts, deferredUpserts) = _collectKittyUpserts(
      registry,
      activeIds,
      removals,
      remainingBudget,
    );
    _hasDeferredKittySync = deferredRemovals || deferredUpserts;
    final hasRemovals = removals.isNotEmpty;
    final hasUpserts = upserts.isNotEmpty;
    return (
      clearAll: false,
      removals: hasRemovals ? removals : null,
      upserts: hasUpserts ? upserts : null,
      hasChanges: hasRemovals || hasUpserts,
    );
  }

  (List<int>, bool) _collectKittyRemovals(KittyImageRegistry registry) {
    final removals = <int>[];
    var deferred = false;
    for (final id in [..._syncedKittyData.keys]) {
      if (registry.lookupImage(id) != null) continue;
      if (removals.length >= _maxKittyEntriesPerFrame) {
        deferred = true;
        continue;
      }
      removals.add(id);
      _syncedKittyData.remove(id);
      _cancelKittyChunk(id);
    }
    return (removals, deferred);
  }

  static bool _needsChunkAbaRemoval(
    KittyImageData? prev,
    KittyImageData next,
  ) =>
      prev != null &&
      !identical(prev, next) &&
      prev.version == next.version &&
      prev.pixelWidth == next.pixelWidth &&
      prev.pixelHeight == next.pixelHeight &&
      prev.gridCols == next.gridCols &&
      prev.gridRows == next.gridRows &&
      prev.format == next.format;

  int _stageChunkUpsert(
    int id,
    KittyImageData data, {
    required List<int> removals,
    required int remainingBudget,
  }) {
    var consumed = 0;
    if (_needsChunkAbaRemoval(_syncedKittyData[id], data)) {
      if (removals.length >= _maxKittyEntriesPerFrame || remainingBudget < 4) {
        return -1;
      }
      removals.add(id);
      consumed = 4;
    }
    _stageKittyChunk(id, data);
    _syncedKittyData[id] = data;
    return consumed;
  }

  (List<KittyImagePayload>, bool) _collectKittyUpserts(
    KittyImageRegistry registry,
    List<int> activeIds,
    List<int> removals,
    int initialBudget,
  ) {
    final upserts = <KittyImagePayload>[];
    var remainingBudget = initialBudget;
    var deferred = false;
    for (final id in activeIds) {
      final data = registry.lookupImage(id);
      if (data == null || identical(_syncedKittyData[id], data)) continue;
      if (!_acceptOrSkipKittyData(id, data)) continue;
      final wireBytes = KittyImagePayload.estimateWireBytes(data);
      if (wireBytes > _maxInlineImageBytes) {
        final consumed = _stageChunkUpsert(
          id,
          data,
          removals: removals,
          remainingBudget: remainingBudget,
        );
        if (consumed < 0) {
          deferred = true;
          continue;
        }
        remainingBudget -= consumed;
        continue;
      }
      _cancelKittyChunk(id);
      if (upserts.length >= _maxKittyEntriesPerFrame ||
          wireBytes > remainingBudget) {
        deferred = true;
        continue;
      }
      upserts.add(KittyImagePayload.fromImageData(data));
      remainingBudget -= wireBytes;
      _syncedKittyData[id] = data;
    }
    return (upserts, deferred);
  }

  void _pruneStaleKittyState(KittyImageRegistry registry) {
    _pruneMapByIdentity(registry, _skippedOversizedData);
    _pruneMapByIdentity(registry, _preparedChunkWire, (entry) => entry.data);
    _pruneMapByIdentity(registry, _pendingKittyChunks, (entry) => entry.data);
  }

  static void _pruneMapByIdentity<V>(
    KittyImageRegistry registry,
    Map<int, V> map, [
    KittyImageData Function(V value)? extractData,
  ]) {
    if (map.isEmpty) return;
    for (final entry in [...map.entries]) {
      final expected = extractData != null
          ? extractData(entry.value)
          : entry.value;
      if (!identical(registry.lookupImage(entry.key), expected)) {
        map.remove(entry.key);
      }
    }
  }

  bool _acceptOrSkipKittyData(int id, KittyImageData data) {
    if (identical(_skippedOversizedData[id], data)) return false;
    if (_canEncodeKittyImage(id, data)) return true;
    _skippedOversizedData[id] = data;
    _cancelKittyChunk(id);
    final wireBytes = KittyImagePayload.estimateWireBytes(data);
    onLog?.call(
      'Skipping Kitty image id=$id ($wireBytes wire bytes): exceeds 16 MiB limit or invalid payload',
    );
    return false;
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

  static bool _canEncodeKittyImage(int id, KittyImageData data) {
    if (id <= 0 || id > 0xFFFFFFFF) return false;
    final w = data.pixelWidth;
    final h = data.pixelHeight;
    if (w <= 0 ||
        w > _maxKittyDimension ||
        h <= 0 ||
        h > _maxKittyDimension ||
        w * h > _maxKittyTotalPixels) {
      return false;
    }
    if (data.gridCols <= 0 ||
        data.gridCols > _maxKittyGridSpan ||
        data.gridRows <= 0 ||
        data.gridRows > _maxKittyGridSpan) {
      return false;
    }
    final byteLen = data.rgbaPixels.length;
    if (byteLen <= 0 || byteLen > BufferFrameCodec.maxKittyImageBytes) {
      return false;
    }
    return switch (data.format) {
      32 => byteLen == w * h * 4,
      100 => _hasValidPngHeader(data.rgbaPixels, w, h),
      _ => false,
    };
  }

  static bool _hasValidPngHeader(Uint8List bytes, int width, int height) {
    if (bytes.length < _minPngBytes) return false;
    for (var i = 0; i < _pngMagic.length; i++) {
      if (bytes[i] != _pngMagic[i]) return false;
    }
    if (bytes[12] != 0x49 ||
        bytes[13] != 0x48 ||
        bytes[14] != 0x44 ||
        bytes[15] != 0x52) {
      return false;
    }
    final view = ByteData.sublistView(bytes, 0, 24);
    return view.getUint32(8) == 13 &&
        view.getUint32(16) == width &&
        view.getUint32(20) == height;
  }

  static int _estimateDeltaBaseTailBytes(List<CellRun> runs, int removalCount) {
    var total = 4 + 5 + removalCount * 4;
    for (final run in runs) {
      total +=
          8 +
          _estimateSpanWireBytes(
            run.characters,
            run.underlineColors,
            run.uriRuns,
          );
    }
    return total;
  }

  static int _estimateSpanWireBytes(
    List<String> characters,
    Map<int, int>? underlineColors,
    List<UriRun>? uriRuns,
  ) {
    var bytes = characters.length * 12 + 1;
    for (final grapheme in characters) {
      bytes += _estimateGraphemeWireBytes(grapheme);
    }
    if (underlineColors != null && underlineColors.isNotEmpty) {
      bytes += 4 + underlineColors.length * 8;
    }
    if (uriRuns != null && uriRuns.isNotEmpty) {
      bytes += _estimateUriRunsWireBytes(uriRuns);
    }
    return bytes;
  }

  static int _estimateUriRunsWireBytes(List<UriRun> uriRuns) {
    final seen = <String>{};
    var tableBytes = 4;
    for (final run in uriRuns) {
      if (seen.add(run.uri)) {
        tableBytes += 2 + utf8.encode(run.uri).length;
      }
    }
    return tableBytes + 4 + uriRuns.length * 12;
  }

  static int _estimateGraphemeWireBytes(String grapheme) {
    if (grapheme.isEmpty) return 1;
    if (grapheme.length == 1 && grapheme.codeUnitAt(0) < 0x80) return 2;
    final utf8Len = utf8.encode(grapheme).length;
    return utf8Len < 0xFF ? 1 + utf8Len : 3 + utf8Len;
  }

  /// Releases owned [VirtualTerminal] resources or restores external hooks.
  void dispose() {
    _terminal.removeListener(_markDirty);
    _titleListeners.clear();
    _bellListeners.clear();
    _audioListeners.clear();
    _clipboardListeners.clear();
    _pendingKittyChunks.clear();
    _preparedChunkWire.clear();
    if (_ownsTerminal) {
      _terminal.dispose();
      return;
    }
    if (_wireTerminalHooks) {
      _terminal
        ..onTitleChanged = _prevOnTitleChanged
        ..onBell = _prevOnBell
        ..onAudioEvent = _prevOnAudioEvent
        ..onClipboardWrite = _prevOnClipboardWrite
        ..onClipboardReadBlocked = _prevOnClipboardReadBlocked;
    }
  }
}
