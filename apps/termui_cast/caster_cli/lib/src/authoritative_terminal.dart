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
const int _maxKittyEntriesPerFrame = 1024;
const int _maxKittyDimension = 4096;
const int _maxKittyTotalPixels = 4_194_304;
const int _maxKittyGridSpan = 512;
const int _minPngBytes = 24;

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
    final safeCols = max(1, cols);
    final safeRows = max(1, rows);
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

  void _markDirty() {
    _dirty = true;
  }

  bool get _dimsOutOfSync =>
      _shadowCols != _terminal.width || _shadowRows != _terminal.height;

  /// Current terminal width in columns.
  int get cols => _terminal.width;

  /// Current terminal height in rows.
  int get rows => _terminal.height;

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

  /// Marks a full [BufferSnapshot] keyframe pending for the next [takeNextFrame].
  void forceKeyframe() {
    _forceKeyframe = true;
  }

  /// Underlying parsed `termui` [Buffer].
  Buffer get buffer => _terminal.buffer;

  /// Current cursor coordinates, visibility, and shape.
  CursorState get cursor => CursorState(
    x: _terminal.cursorX.clamp(0, _terminal.width - 1),
    y: _terminal.cursorY.clamp(0, _terminal.height - 1),
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

  /// Resizes the terminal grid and marks a full keyframe pending.
  bool resize(int newCols, int newRows) {
    final safeCols = max(1, newCols);
    final safeRows = max(1, newRows);
    final vtChanged =
        safeCols != _terminal.width || safeRows != _terminal.height;
    final shadowChanged = safeCols != _shadowCols || safeRows != _shadowRows;
    if (!vtChanged && !shadowChanged) {
      return false;
    }
    if (vtChanged) {
      _terminal.resize(safeCols, safeRows);
    }
    _reallocateShadow(safeCols, safeRows);
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
      _reallocateShadow(_terminal.width, _terminal.height);
    }
    _seq++;
    final buf = _terminal.buffer;
    _shadowChars.setRange(0, _shadowChars.length, buf.characters);
    _shadowAttrs.setRange(0, _shadowAttrs.length, buf.attributes);
    _syncAllShadowAux(buf);
    _shadowCursor = cursor;
    _shadowModes = modes;
    _shadowScrollback = scrollbackWindow;
    _shadowWrappedRows = packWrappedRows(rows, _terminal.isRowWrapped);
    _dirty = false;
    _forceKeyframe = false;
    return _buildSnapshot(buf, syncKittyTracking: true);
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
    final totalCells = buf.width * buf.height;
    final underlineColors = extractBufferUnderlineColors(buf, 0, totalCells);
    final uriRuns = extractBufferUriRuns(buf, 0, totalCells);
    final spanBytes = _estimateSpanWireBytes(
      buf.characters,
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
      cols: buf.width,
      rows: buf.height,
      cursor: _shadowCursor,
      modes: _shadowModes,
      scrollback: _shadowScrollback,
      wrappedRows: Uint8List.fromList(_shadowWrappedRows),
      characters: [...buf.characters],
      attributes: Uint32List.fromList(buf.attributes),
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

  static String? _normalizedCellUri(Buffer buf, int index) {
    final raw = buf.getUriAt(index);
    if (raw == null || raw.isEmpty) return null;
    final clamped = clampOsc8Uri(raw);
    return clamped.isEmpty ? null : clamped;
  }

  List<KittyImagePayload>? _collectSnapshotKittyPayloads({
    required int cellSpanBytes,
    required bool syncTracking,
  }) {
    final registry = _terminal.imageRegistry;
    _pruneSkippedOversized(registry);
    if (syncTracking) {
      _syncedKittyData.clear();
      _lastImageRegistryRevision = _terminal.imageRegistryRevision;
    }
    final ids = [...registry.registeredImageIds];
    if (ids.isEmpty) {
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
      final wireBytes = KittyImagePayload.estimateWireBytes(data);
      if (payloads.length >= _maxKittyEntriesPerFrame || wireBytes > budget) {
        deferred = true;
        _syncedKittyData.remove(id);
        continue;
      }
      payloads.add(KittyImagePayload.fromImageData(data));
      budget -= wireBytes;
      if (syncTracking) _syncedKittyData[id] = data;
    }
    if (syncTracking || deferred) {
      _hasDeferredKittySync = deferred;
    }
    return payloads.isEmpty ? null : payloads;
  }

  _DeltaKittySync _syncDeltaKittyIfNeeded(List<CellRun> runs) {
    if (!_hasDeferredKittySync &&
        _terminal.imageRegistryRevision == _lastImageRegistryRevision) {
      return _emptyDeltaKittySync;
    }
    final registry = _terminal.imageRegistry;
    _pruneSkippedOversized(registry);
    _lastImageRegistryRevision = _terminal.imageRegistryRevision;
    final activeIds = [...registry.registeredImageIds];
    if (activeIds.isEmpty) {
      final hadSynced = _syncedKittyData.isNotEmpty;
      _syncedKittyData.clear();
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
    }
    return (removals, deferred);
  }

  (List<KittyImagePayload>, bool) _collectKittyUpserts(
    KittyImageRegistry registry,
    List<int> activeIds,
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

  void _pruneSkippedOversized(KittyImageRegistry registry) {
    if (_skippedOversizedData.isEmpty) return;
    for (final entry in [..._skippedOversizedData.entries]) {
      if (!identical(registry.lookupImage(entry.key), entry.value)) {
        _skippedOversizedData.remove(entry.key);
      }
    }
  }

  bool _acceptOrSkipKittyData(int id, KittyImageData data) {
    if (identical(_skippedOversizedData[id], data)) return false;
    const maxSingleImageBytes =
        _maxUncompressedTailBudget - _emptyDeltaBaseTailBytes;
    if (_canEncodeKittyImage(id, data, maxSingleImageBytes)) return true;
    _skippedOversizedData[id] = data;
    final wireBytes = KittyImagePayload.estimateWireBytes(data);
    onLog?.call(
      'Skipping Kitty image id=$id ($wireBytes wire bytes): exceeds single-frame limit',
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

  static bool _canEncodeKittyImage(
    int id,
    KittyImageData data,
    int maxWireBytes,
  ) {
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
    if (KittyImagePayload.estimateWireBytes(data) > maxWireBytes) return false;
    final byteLen = data.rgbaPixels.length;
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
