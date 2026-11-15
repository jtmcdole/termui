import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:meta/meta.dart';
import 'package:termui/termui.dart';
import 'package:termui_cast_protocol/termui_cast_protocol.dart';
import 'package:termui_pty/termui_pty.dart';

import 'cast_client_repository.dart';
import 'models.dart';
import 'scrollback_page_cache.dart';
import 'session_slot.dart';

/// Converts a wire [CastAudioPayload] into a [termui_pty] [TerminalAudioEvent].
TerminalAudioEvent toTerminalAudioEvent(CastAudioPayload payload) =>
    switch (payload) {
      CastToneAudioPayload(
        :final waveform,
        :final frequencyHz,
        :final duration,
        :final volume,
        :final pan,
        :final busId,
      ) =>
        TerminalToneAudioEvent(
          waveform: waveform,
          frequencyHz: frequencyHz,
          duration: duration,
          volume: volume,
          pan: pan,
          busId: busId,
        ),
      CastClipAudioPayload(
        :final clipId,
        :final format,
        :final bytes,
        :final volume,
        :final pan,
        :final loop,
        :final startOffset,
        :final busId,
        :final streamId,
      ) =>
        TerminalClipAudioEvent(
          clipId: clipId,
          format: format,
          bytes: bytes,
          volume: volume,
          pan: pan,
          loop: loop,
          startOffset: startOffset,
          busId: busId,
          streamId: streamId,
        ),
      CastStreamAudioPayload(
        :final op,
        :final streamId,
        :final seq,
        :final maxBufferSize,
        :final releaseConsumed,
        :final bufferingTimeNeeds,
        :final sampleRate,
        :final channels,
        :final chunkBytes,
      ) =>
        TerminalStreamAudioEvent(
          op: op,
          streamId: streamId,
          seq: seq,
          maxBufferSize: maxBufferSize,
          releaseConsumed: releaseConsumed,
          bufferingTimeNeeds: bufferingTimeNeeds,
          sampleRate: sampleRate,
          channels: channels,
          chunkBytes: chunkBytes,
        ),
      CastStopAudioPayload(:final clipId) => TerminalStopAudioEvent(
        clipId: clipId,
      ),
      CastBusAudioPayload(
        :final op,
        :final busId,
        :final filterId,
        :final paramId,
        :final value,
        :final duration,
      ) =>
        TerminalBusAudioEvent(
          op: op,
          busId: busId,
          filterId: filterId,
          paramId: paramId,
          value: value,
          duration: duration,
        ),
      CastUpdateAudioPayload(
        :final clipId,
        :final volume,
        :final pan,
        :final seekPosition,
        :final paused,
        :final speed,
        :final preservePitch,
        :final fadeVolumeTarget,
        :final fadeVolumeDuration,
        :final fadeSpeedTarget,
        :final fadeSpeedDuration,
        :final scheduleStopDuration,
      ) =>
        TerminalUpdateAudioEvent(
          clipId: clipId,
          volume: volume,
          pan: pan,
          seekPosition: seekPosition,
          paused: paused,
          speed: speed,
          preservePitch: preservePitch,
          fadeVolumeTarget: fadeVolumeTarget,
          fadeVolumeDuration: fadeVolumeDuration,
          fadeSpeedTarget: fadeSpeedTarget,
          fadeSpeedDuration: fadeSpeedDuration,
          scheduleStopDuration: scheduleStopDuration,
        ),
      CastWaveformQueryAudioPayload(:final requestId) =>
        TerminalWaveformQueryAudioEvent(requestId: requestId),
    };

/// Remote [TerminalPort] attached to a [SessionId] through a [CastClientRepository].
///
/// Multiple split panes or widgets viewing the same [SessionId] share one
/// [SessionSlot] and [ScrollbackPageCache] per repository while advertising each
/// pane's local viewport size; the repository forwards the minimum local
/// `(cols, rows)` across all attached panes and only sends
/// `UnsubscribeSessionFrame` when the last port for [sessionId] is disposed.
final class RemoteTerminalPort implements TerminalPort {
  /// Backing repository owning transport and session synchronization state.
  final CastClientRepository repository;

  /// Remote session identifier bound to this port.
  final SessionId sessionId;

  @override
  final String id;

  final SessionSlot _slot;
  final Future<int> _exitCode;
  final void Function(RemoteTerminalPort port, int cols, int rows)
  _onViewportChanged;
  final Future<void> Function(RemoteTerminalPort port) _onDispose;

  final Set<void Function()> _changeListeners = <void Function()>{};
  final Set<void Function(String title)> _titleListeners =
      <void Function(String title)>{};
  final Set<void Function()> _bellListeners = <void Function()>{};
  final Set<void Function(TerminalAudioEvent event)> _audioListeners =
      <void Function(TerminalAudioEvent event)>{};
  final Set<void Function(String selection, String text)> _clipboardListeners =
      <void Function(String selection, String text)>{};

  Buffer? _fallbackBuffer;
  ({int cols, int rows})? _localViewportSize;
  final Map<int, ScrollbackLine> _decodedScrollbackCache =
      <int, ScrollbackLine>{};
  int _decodedCacheClearSeq = -1;
  int _decodedCacheWidth = -1;

  /// Policy governing inbound remote `OSC 52` clipboard writes on this port.
  Osc52ClipboardPolicy clipboardPolicy = .allowFocused;

  /// Whether this port currently holds active user focus for `allowFocused`
  /// `OSC 52` clipboard writes.
  bool isClipboardFocused = true;

  /// Maximum decoded UTF-8 byte length allowed for `OSC 52` clipboard writes.
  int maxOsc52ClipboardBytes =
      CastWorkspaceSettings.defaultMaxOsc52ClipboardBytes;

  bool _disposed = false;

  /// Opens or shares a reference-counted [RemoteTerminalPort] on [repository].
  factory RemoteTerminalPort({
    required CastClientRepository repository,
    required SessionId sessionId,
    String? portId,
    int? initialCols,
    int? initialRows,
  }) => repository.openTerminalPort(
    sessionId,
    portId: portId,
    initialCols: initialCols,
    initialRows: initialRows,
  );

  /// Internal factory constructor used by [CastClientRepository].
  @internal
  RemoteTerminalPort.attached({
    required this.repository,
    required this.sessionId,
    required this.id,
    required SessionSlot slot,
    required Future<int> exitCode,
    required void Function(RemoteTerminalPort port, int cols, int rows)
    onViewportChanged,
    required Future<void> Function(RemoteTerminalPort port) onDispose,
    ({int cols, int rows})? initialViewportSize,
  }) : _slot = slot,
       _exitCode = exitCode,
       _onViewportChanged = onViewportChanged,
       _onDispose = onDispose,
       _localViewportSize = initialViewportSize;

  /// Whether [dispose] has already detached this port.
  bool get isDisposed => _disposed;

  /// Shared session synchronization slot backing all attached ports for [sessionId].
  SessionSlot get slot => _slot;

  /// Shared primary-screen scrollback cache for [sessionId].
  ScrollbackPageCache get scrollbackCache => _slot.scrollbackCache;

  /// Latest sanitized shell title (`OSC 0`/`OSC 2`) received for [sessionId].
  String get shellTitle => _slot.shellTitle;

  /// User-pinned custom tab title, or `null` when tracking shell/default title.
  String? get pinnedTitle => _slot.pinnedTitle;

  /// Whether a user-pinned title currently overrides [shellTitle].
  bool get isUserPinned => _slot.isUserPinned;

  /// Resolved display title (`pinnedTitle ?? shellTitle ?? directoryTitle`).
  String get displayTitle => _slot.effectiveTitle;

  /// Number of unread terminal bell (`BEL`) events recorded on [sessionId].
  int get bellCount => _slot.bellCount;

  @override
  int get renderRevision => _slot.renderRevision;

  @override
  int get fullSyncRevision => _slot.fullSyncRevision;

  @override
  List<DirtyCellSpan> get dirtySpans => _slot.dirtySpans;

  /// Most recently reported local viewport dimensions for this pane, if set.
  ({int cols, int rows})? get localViewportSize => _localViewportSize;

  /// Clears unread [bellCount] on the shared [SessionSlot].
  void clearBellCount() => _slot.clearBellCount();

  /// Sends a [RenameSessionFrame] for [sessionId], optionally clearing any user pin.
  void rename(String title, {bool clearPin = false}) =>
      repository.renameSession(sessionId, title, clearPin: clearPin);

  @override
  Buffer get buffer {
    final live = _slot.buffer;
    if (live != null) {
      _fallbackBuffer = null;
      return live;
    }
    final targetCols = max(1, _slot.currentCols);
    final targetRows = max(1, _slot.currentRows);
    final existing = _fallbackBuffer;
    if (existing != null &&
        existing.width == targetCols &&
        existing.height == targetRows) {
      return existing;
    }
    final blank = Buffer.blank(targetCols, targetRows)
      ..registerKittyRegistry(
        Rect(0, 0, targetCols, targetRows),
        _slot.kittyRegistry,
      );
    _fallbackBuffer = blank;
    return blank;
  }

  @override
  int get cols => _slot.currentCols;

  @override
  int get rows => _slot.currentRows;

  @override
  (int cols, int rows) get activePtySize =>
      (_slot.activePtyCols, _slot.activePtyRows);

  @override
  CursorStateData get cursor {
    final state = _slot.cursor;
    final maxCols = max(1, cols);
    final maxRows = max(1, rows);
    return CursorStateData(
      x: state.x.clamp(0, maxCols - 1),
      y: state.y.clamp(0, maxRows - 1),
      visible: state.visible,
      shape: _mapCursorShape(state.shape),
    );
  }

  @override
  TerminalPortModes get modes {
    final state = _slot.modes;
    return TerminalPortModes(
      mouseTracking: state.mouseTracking,
      sgrMouse: state.sgrMouse,
      sgrPixelsMouse: state.sgrPixelsMouse,
      bracketedPaste: state.bracketedPaste,
      altScreen: state.altScreen,
      appCursorKeys: state.appCursorKeys,
      alternateScroll: state.alternateScroll,
      focusReporting: state.focusReporting,
      kittyKeyboardFlags: state.kittyKeyboardFlags,
    );
  }

  @override
  ScrollbackWindowData get scrollbackWindow => (
    clearSeq: _slot.scrollbackCache.clearSeq,
    oldestLine: _slot.scrollbackCache.oldestLine,
    totalLines: _slot.scrollbackCache.totalLines,
  );

  @override
  String get windowTitle => _slot.effectiveTitle;

  @override
  String? get workingDirectory => null;

  @override
  Future<int> get exitCode => _exitCode;

  @override
  void addListener(void Function() listener) {
    if (_disposed) return;
    _changeListeners.add(listener);
  }

  @override
  void removeListener(void Function() listener) {
    _changeListeners.remove(listener);
  }

  @override
  void addTitleListener(void Function(String title) listener) {
    if (_disposed) return;
    _titleListeners.add(listener);
  }

  @override
  void removeTitleListener(void Function(String title) listener) {
    _titleListeners.remove(listener);
  }

  @override
  void addBellListener(void Function() listener) {
    if (_disposed) return;
    _bellListeners.add(listener);
  }

  @override
  void removeBellListener(void Function() listener) {
    _bellListeners.remove(listener);
  }

  @override
  void addAudioListener(void Function(TerminalAudioEvent event) listener) {
    if (_disposed) return;
    _audioListeners.add(listener);
  }

  @override
  void removeAudioListener(void Function(TerminalAudioEvent event) listener) {
    _audioListeners.remove(listener);
  }

  @override
  void addClipboardListener(
    void Function(String selection, String text) listener,
  ) {
    if (_disposed) return;
    _clipboardListeners.add(listener);
  }

  @override
  void removeClipboardListener(
    void Function(String selection, String text) listener,
  ) {
    _clipboardListeners.remove(listener);
  }

  @override
  void sendInput(Uint8List utf8Bytes) {
    if (_disposed || utf8Bytes.isEmpty) return;
    repository.sendInput(sessionId, utf8Bytes);
  }

  /// Sends a 256-sample `Float32` waveform reply for [requestId] back to the caster.
  void sendWaveformReply(int requestId, Float32List samples) {
    if (_disposed) return;
    repository.sendWaveformReply(sessionId, requestId, samples);
  }

  @override
  void setViewportSize(
    int cols,
    int rows, {
    int cellPixelWidth = 0,
    int cellPixelHeight = 0,
  }) {
    if (_disposed || cols <= 0 || rows <= 0) return;
    final safeCols = cols.clamp(1, BufferFrameCodec.maxGridCols);
    final safeRows = rows.clamp(1, BufferFrameCodec.maxGridRows);
    final next = (cols: safeCols, rows: safeRows);
    if (_localViewportSize == next) return;
    _localViewportSize = next;
    _onViewportChanged(this, safeCols, safeRows);
  }

  @override
  List<ScrollbackLine?> readScrollbackSlice(int startLine, int count) {
    if (count <= 0) return const <ScrollbackLine?>[];
    if (!_disposed && _slot.state == .synchronized) {
      _slot.prefetchScrollbackForRange(startLine, startLine + count);
    }
    final fallbackWidth = max(1, cols);
    final clearSeq = _slot.scrollbackCache.clearSeq;
    if (_decodedCacheClearSeq != clearSeq ||
        _decodedCacheWidth != fallbackWidth) {
      _decodedScrollbackCache.clear();
      _decodedCacheClearSeq = clearSeq;
      _decodedCacheWidth = fallbackWidth;
    } else if (_decodedScrollbackCache.length >
        ScrollbackPageCache.maxCachedRows) {
      _decodedScrollbackCache.clear();
    }
    final result = List<ScrollbackLine?>.filled(count, null, growable: false);
    for (var i = 0; i < count; i++) {
      final lineIdx = startLine + i;
      final cached = _decodedScrollbackCache[lineIdx];
      if (cached != null) {
        result[i] = cached;
        continue;
      }
      final encoded = _slot.scrollbackCache.rowAt(lineIdx);
      if (encoded != null) {
        final decoded = _decodeScrollbackRow(encoded, fallbackWidth);
        _decodedScrollbackCache[lineIdx] = decoded;
        result[i] = decoded;
      }
    }
    return result;
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _changeListeners.clear();
    _titleListeners.clear();
    _bellListeners.clear();
    _audioListeners.clear();
    _clipboardListeners.clear();
    _decodedScrollbackCache.clear();
    _fallbackBuffer = null;
    await _onDispose(this);
  }

  /// Dispatches a visual change event to listeners registered on this port.
  @internal
  void dispatchVisualChange() => _invokeVoidListeners(_changeListeners);

  /// Dispatches a title change event to listeners registered on this port.
  @internal
  void dispatchTitleChange(String nextTitle) =>
      _invokeListeners(_titleListeners, nextTitle);

  /// Dispatches a terminal bell event to listeners registered on this port.
  @internal
  void dispatchBell() => _invokeVoidListeners(_bellListeners);

  /// Dispatches a terminal audio event to listeners registered on this port.
  @internal
  void dispatchAudio(TerminalAudioEvent event) =>
      _invokeListeners(_audioListeners, event);

  /// Dispatches a clipboard write event to listeners registered on this port.
  @internal
  void dispatchClipboard(String selection, String text) {
    if (_disposed || _clipboardListeners.isEmpty) return;
    if (clipboardPolicy == .deny || !isClipboardFocused) return;
    if (utf8.encode(text).length > maxOsc52ClipboardBytes) return;
    for (final listener in List<void Function(String, String)>.of(
      _clipboardListeners,
    )) {
      try {
        listener(selection, text);
      } on Object catch (_) {}
    }
  }

  void _invokeVoidListeners(Set<void Function()> listeners) {
    if (_disposed || listeners.isEmpty) return;
    for (final listener in List<void Function()>.of(listeners)) {
      try {
        listener();
      } on Object catch (_) {}
    }
  }

  void _invokeListeners<T>(Set<void Function(T)> listeners, T arg) {
    if (_disposed || listeners.isEmpty) return;
    for (final listener in List<void Function(T)>.of(listeners)) {
      try {
        listener(arg);
      } on Object catch (_) {}
    }
  }

  static TerminalCursorShape _mapCursorShape(CursorShape shape) =>
      switch (shape) {
        CursorShape.defaultShape => .defaultShape,
        CursorShape.blinkingBlock => .blinkingBlock,
        CursorShape.steadyBlock => .steadyBlock,
        CursorShape.blinkingUnderline => .blinkingUnderline,
        CursorShape.steadyUnderline => .steadyUnderline,
        CursorShape.blinkingBar => .blinkingBar,
        CursorShape.steadyBar => .steadyBar,
      };

  static ScrollbackLine _decodeScrollbackRow(
    EncodedScrollbackRow row,
    int fallbackWidth,
  ) {
    final len = row.characters.length;
    return ScrollbackLine(
      width: max(fallbackWidth, len),
      characters: row.characters,
      attributes: row.attributes,
      underlineColors: _decodeUnderlineColors(row.underlineColors, len),
      uris: _decodeUriRuns(row.uriRuns, len),
      isWrapped: row.isWrapped,
    );
  }

  static Uint32List? _decodeUnderlineColors(
    Map<int, int>? sparseUnderlines,
    int len,
  ) {
    if (sparseUnderlines == null || sparseUnderlines.isEmpty || len <= 0) {
      return null;
    }
    final decoded = Uint32List(len);
    for (final entry in sparseUnderlines.entries) {
      if (entry.key >= 0 && entry.key < len) {
        decoded[entry.key] = entry.value;
      }
    }
    return decoded;
  }

  static List<String?>? _decodeUriRuns(List<UriRun>? uriRuns, int len) {
    if (uriRuns == null || uriRuns.isEmpty || len <= 0) return null;
    final decoded = List<String?>.filled(len, null);
    for (final run in uriRuns) {
      final end = min(len, run.start + run.length);
      for (var col = max(0, run.start); col < end; col++) {
        decoded[col] = run.uri;
      }
    }
    return decoded;
  }
}
