import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart'
    show
        ChangeNotifier,
        Listenable,
        ValueListenable,
        VoidCallback,
        visibleForTesting;
import 'package:termui/terminal/event.dart' as ev;
import 'package:termui/termui.dart' as tui;
import 'package:termui_cast_client_core/termui_cast_client_core.dart';
import 'package:termui_cast_protocol/termui_cast_protocol.dart' show SessionId;
import 'package:termui_flutter/termui_flutter.dart'
    show
        CliShaderRegistry,
        GpuFrameWatchdog,
        ShaderBackendKind,
        TerminalBufferChangeSignal,
        TerminalShaderBackend,
        TerminalShaderConfig;
import 'package:termui_pty/termui_pty.dart';

import '../settings_storage.dart';
import 'cli_shader_state.dart';
import 'local_host_driver.dart';

/// Callback notified when a terminal pane receives `BEL`.
typedef PaneBellCallback = void Function(String paneId);

/// Callback notified when a terminal pane decodes an `ESC _ A` audio event.
typedef PaneAudioCallback = void Function(
  String paneId,
  TerminalAudioEvent event,
);

/// Callback notified when a pane's shell title updates via `OSC 0`/`OSC 2`.
typedef PaneTitleCallback = void Function(String paneId, String title);

/// Callback notified when a pane receives an `OSC 52` clipboard write.
typedef PaneClipboardCallback = void Function(
  String paneId,
  String selection,
  String text,
);

/// Callback notified when a pane's backing shell or remote session exits.
typedef PaneExitedCallback = void Function(String paneId, int exitCode);

final class _PaneChangeNotifier extends ChangeNotifier
    implements TerminalBufferChangeSignal {
  int _listenerCount = 0;
  int _cellContentRevision = 0;

  @override
  int get cellContentRevision => _cellContentRevision;

  void bumpCellContentRevision() {
    _cellContentRevision += 1;
  }

  @override
  void addListener(VoidCallback listener) {
    super.addListener(listener);
    _listenerCount += 1;
  }

  @override
  void removeListener(VoidCallback listener) {
    super.removeListener(listener);
    if (_listenerCount > 0) {
      _listenerCount -= 1;
    }
  }

  void emitChange() => notifyListeners();
}

/// Manages live buffer compositing, scrollback offset, cursor rendering,
/// debounced viewport resizing, and encoded input for a single split pane.
final class FtermPaneController {
  static const int _maxInputChunkBytes = 4096;
  static const int _wheelScrollLines = 3;
  static const int _scrollbarThumbCode = 0x2590;

  /// Stable unique pane identifier within the workspace.
  final String paneId;

  /// Backing terminal port (local [PtyRouter] port or [RemoteTerminalPort]).
  final TerminalPort port;

  /// Local shell host handle when this pane owns a local desktop PTY.
  final LocalPaneHost? localHost;

  /// Relay session identifier when this pane views a remote caster session.
  final SessionId? remoteSessionId;

  final Duration _resizeDebounce;
  final _PaneChangeNotifier _visualNotifier = _PaneChangeNotifier();
  final _PaneChangeNotifier _pillNotifier = _PaneChangeNotifier();
  final void Function(tui.Buffer buffer)? _onFrameRedrawn;

  PaneBellCallback? _onBell;
  PaneAudioCallback? _onAudio;
  PaneTitleCallback? _onTitleChanged;
  PaneClipboardCallback? _onClipboard;
  PaneExitedCallback? _onExited;
  void Function()? _onShareChanged;
  void Function(String paneId)? _onCliShaderUiChanged;
  PaneCliShaderQuarantinedCallback? _onCliShaderQuarantined;

  late final PaneCliShaderState _cliShaderState;
  TerminalColorResolver _colorResolver;
  tui.Buffer? _composedBuffer;
  Timer? _resizeTimer;
  StreamSubscription<LocalShareSnapshot>? _shareSub;

  int? _pendingCols;
  int? _pendingRows;
  int _pendingCellW = 0;
  int _pendingCellH = 0;
  int _scrollOffsetLines = 0;
  int _lastScrollbackClearSeq = 0;
  int _lastComposedRevision = -1;
  int _lastCursorCellIndex = -1;
  int _lastComposedWidth = 0;
  int _lastComposedHeight = 0;
  int _lastComposedScrollOffset = 0;
  int _lastPillScrollOffset = 0;
  int _bellCount = 0;
  bool _focused = false;
  bool _hasExited = false;
  int? _exitStatus;
  String _shellTitle = '';
  bool _deferPortShaderRecomposite = false;
  bool _pendingDeferredShaderRecomposite = false;
  bool _disposed = false;

  /// Attaches a pane controller to [port].
  FtermPaneController({
    required this.paneId,
    required this.port,
    required this._colorResolver,
    this.localHost,
    this.remoteSessionId,
    this._resizeDebounce = const Duration(milliseconds: 32),
    this._onBell,
    this._onAudio,
    this._onTitleChanged,
    this._onClipboard,
    this._onExited,
    this._onShareChanged,
    this._onFrameRedrawn,
    CliShaderPolicy? cliShaderPolicy,
    CliFullPaneShaderMode cliFullPaneShaderMode =
        CliFullPaneShaderMode.cliBeforeUser,
    Set<String> trustedCliShaderHashes = const <String>{},
    TerminalShaderBackend? shaderBackend,
    GpuFrameWatchdog? gpuFrameWatchdog,
    this._onCliShaderUiChanged,
    this._onCliShaderQuarantined,
  }) {
    _shellTitle = _resolveInitialTitle();
    _lastScrollbackClearSeq = port.scrollbackWindow.clearSeq;
    _cliShaderState = PaneCliShaderState(
      paneId: paneId,
      isLocal: localHost != null,
      initialPolicy:
          cliShaderPolicy ??
          (localHost != null
              ? CliShaderPolicy.promptCustomGlsl
              : CliShaderPolicy.disabled),
      initialFullPaneMode: cliFullPaneShaderMode,
      trustedHashes: trustedCliShaderHashes,
      readPaneLabel: _resolvePaneLabel,
      onVisualStateChanged: _handleCliShaderVisualChanged,
      onPolicyUiChanged: _handleCliShaderUiChanged,
      onQuarantined: _handleCliShaderQuarantined,
      backend: shaderBackend,
      watchdog: gpuFrameWatchdog,
    );
    port.setShaderCapabilities(
      _cliShaderState.resolveCapabilities(
        shaderBackend?.kind ?? ShaderBackendKind.disabled,
      ),
    );
    _attachPortListeners();
    _recomposite(notify: false);
  }

  String _resolvePaneLabel() {
    if (_shellTitle.isNotEmpty) return _shellTitle;
    if (remoteSessionId case final id?) return id.value;
    return paneId;
  }

  /// Per-pane CLI `ESC _ S` trust policy, SHA-256 prompt queue, and state.
  PaneCliShaderState get cliShaderState => _cliShaderState;

  /// Per-pane compiled CLI shader registry (`4s` timeout, `32 KiB` cap).
  CliShaderRegistry get cliShaderRegistry => _cliShaderState.registry;

  /// Per-pane best-effort GPU watchdog isolating offending custom CLI shaders.
  GpuFrameWatchdog get gpuFrameWatchdog => _cliShaderState.watchdog;

  /// Resolves the effective [TerminalShaderConfig] for this pane by combining
  /// active CLI full-pane passes with [userConfig].
  TerminalShaderConfig resolveShaderConfig(TerminalShaderConfig userConfig) =>
      _cliShaderState.resolveFullPaneConfig(userConfig);

  /// Updates the active CLI shader policy, stacking mode, and trusted hashes.
  void syncCliShaderPolicy({
    required CliShaderPolicy policy,
    required CliFullPaneShaderMode fullPaneMode,
    required Set<String> trustedHashes,
    required bool userHasFullPaneShaders,
    required ShaderBackendKind backendKind,
  }) {
    if (_disposed) return;
    _cliShaderState.updatePolicy(
      policy: policy,
      fullPaneMode: fullPaneMode,
      trustedHashes: trustedHashes,
      userHasFullPaneShaders: userHasFullPaneShaders,
    );
    port.setShaderCapabilities(
      _cliShaderState.resolveCapabilities(backendKind),
    );
  }

  /// Attaches or switches the backing GPU/WebGL2 shader [backend].
  void attachShaderBackend(TerminalShaderBackend? backend) {
    if (_disposed) return;
    _cliShaderState.attachBackend(backend);
    port.setShaderCapabilities(
      _cliShaderState.resolveCapabilities(
        backend?.kind ?? ShaderBackendKind.disabled,
      ),
    );
  }

  /// Whether this pane hosts a local desktop shell.
  bool get isLocal => localHost != null;

  /// Listenable notified whenever [displayBuffer] or cursor state changes.
  ValueListenable<tui.Buffer> get bufferListenable => _bufferListenable ??=
      _PaneBufferListenable(_visualNotifier, readDisplayBuffer);

  _PaneBufferListenable? _bufferListenable;

  /// Backing notifier triggered on visual redraws.
  ChangeNotifier get visualNotifier => _visualNotifier;

  /// Scoped listenable triggered only when pane corner pill state changes
  /// (scrollback offset transitions, share status updates, or process exit).
  Listenable get pillNotifier => _pillNotifier;

  /// Active listener count registered on [visualNotifier] (for regression tests).
  @visibleForTesting
  int get debugVisualListenerCount => _visualNotifier._listenerCount;

  /// Most recently composited screen buffer ready for `TerminalSurface`.
  tui.Buffer get displayBuffer {
    final existing = _composedBuffer;
    if (existing != null) return existing;
    _recomposite(notify: false);
    return _composedBuffer!;
  }

  /// Stable tear-off reading [displayBuffer] for `TerminalSurface.bufferProvider`.
  tui.Buffer readDisplayBuffer() => displayBuffer;

  /// Monotonic virtual row index corresponding to viewport row `0` (`0` when
  /// `altScreen` is active, or `max(oldestLine, totalLines - scrollOffsetLines)`
  /// on the primary screen).
  int get topVirtualRow {
    if (port.modes.altScreen) return 0;
    final sbWin = port.scrollbackWindow;
    return math.max(sbWin.oldestLine, sbWin.totalLines - _scrollOffsetLines);
  }

  /// Stable tear-off reading [topVirtualRow] for `TerminalSurface`.
  int readTopVirtualRow() => topVirtualRow;

  /// Epoch token combining scrollback `clearSeq` and `altScreen` state so
  /// selections reset cleanly on screen switches or history clears.
  Object get selectionEpoch =>
      Object.hash(port.scrollbackWindow.clearSeq, port.modes.altScreen);

  /// Stable tear-off reading [selectionEpoch] for `TerminalSurface`.
  Object readSelectionEpoch() => selectionEpoch;

  /// Resolves the un-overlaid [tui.VirtualLineSlice] for monotonic [virtualRow]
  /// (`[oldestLine .. totalLines + liveHeight)` on primary screen, or
  /// `[0 .. liveHeight)` when `altScreen` is active).
  tui.VirtualLineSlice? lookupVirtualLine(int virtualRow) {
    if (_disposed || virtualRow < 0) return null;
    if (port.modes.altScreen) {
      return _sliceLiveBufferRow(virtualRow);
    }
    final sbWin = port.scrollbackWindow;
    if (virtualRow < sbWin.oldestLine) return null;

    final remote = remotePort;
    if (remote != null) {
      final slot = remote.slot;
      final liveBuffer = slot.buffer;
      if (liveBuffer == null) return null;
      return WorkspaceBufferCompositor.lookupVirtualLine(
        slot,
        liveBuffer,
        virtualRow,
      );
    }

    final total = sbWin.totalLines;
    if (virtualRow < total) {
      final slice = port.readScrollbackSlice(virtualRow, 1);
      final line = slice.isNotEmpty ? slice.first : null;
      if (line == null) return null;
      return (
        isWrapped: line.isWrapped,
        characters: line.characters,
        uris: line.uris,
      );
    }
    return _sliceLiveBufferRow(virtualRow - total);
  }

  tui.VirtualLineSlice? _sliceLiveBufferRow(int liveY) {
    final remote = remotePort;
    final liveBuffer = remote != null ? remote.slot.buffer : port.buffer;
    if (liveBuffer == null || liveY < 0 || liveY >= liveBuffer.height) {
      return null;
    }
    final start = liveY * liveBuffer.width;
    final end = start + liveBuffer.width;
    final isWrapped = remote != null
        ? remote.slot.isLiveRowWrapped(liveY)
        : (localHost?.isLiveRowWrapped(liveY) ?? false);
    return (
      isWrapped: isWrapped,
      characters: WorkspaceBufferCompositor.rowCharactersView(
        liveBuffer,
        liveY,
      ),
      uris: liveBuffer.sliceUris(start, end),
    );
  }

  /// Resolves the un-overlaid [tui.VirtualLineSlice] for [viewportRow] relative
  /// to [topVirtualRow] (including negative offsets into scrollback when links
  /// wrap across the top viewport edge).
  tui.VirtualLineSlice? lookupLinkLine(int viewportRow) {
    if (_disposed) return null;
    final virtualRow = topVirtualRow + viewportRow;
    if (virtualRow < 0) return null;
    return lookupVirtualLine(virtualRow);
  }

  /// Active PTY dimensions `(cols, rows)` used for out-of-bounds dimming.
  (int cols, int rows) get activePtySize => port.activePtySize;

  /// Stable tear-off reading [activePtySize] for `TerminalSurface`.
  (int cols, int rows) readActivePtySize() => activePtySize;

  /// Current zero-based cursor coordinate for IME pre-edit placement.
  ({int col, int row}) get cursorPosition =>
      (col: port.cursor.x, row: port.cursor.y);

  /// Stable tear-off reading [cursorPosition] for `TerminalSurface`.
  ({int col, int row}) readCursorPosition() => cursorPosition;

  /// Whether the terminal cursor is currently visible at the live bottom row.
  bool get cursorVisible => port.cursor.visible && _scrollOffsetLines == 0;

  /// Stable tear-off reading [cursorVisible] for `TerminalSurface`.
  bool readCursorVisible() => cursorVisible;

  /// Active Kitty keyboard progressive enhancement flags (`0..31`).
  int get kittyKeyboardFlags => port.modes.kittyKeyboardFlags;

  /// Stable tear-off reading [kittyKeyboardFlags] for `TerminalSurface`.
  int readKittyKeyboardFlags() => kittyKeyboardFlags;

  /// Whether Kitty flag bit 2 (report key repeat/release) is active.
  bool get reportKeyReleaseEvents => (port.modes.kittyKeyboardFlags & 2) != 0;

  /// Stable tear-off reading [reportKeyReleaseEvents] for `TerminalSurface`.
  bool readReportKeyReleaseEvents() => reportKeyReleaseEvents;

  /// Whether DECSET 1016 pixel mouse reporting is active.
  bool get reportPixelMouseEvents => port.modes.sgrPixelsMouse;

  /// Stable tear-off reading [reportPixelMouseEvents] for `TerminalSurface`.
  bool readReportPixelMouseEvents() => reportPixelMouseEvents;

  /// Whether DECSET mouse tracking is active at the live bottom row.
  bool get mouseTracking => _scrollOffsetLines == 0 && port.modes.mouseTracking;

  /// Stable tear-off reading [mouseTracking] for `TerminalSurface`.
  bool readMouseTracking() => mouseTracking;

  /// Current primary-screen scrollback offset (`0` = live bottom).
  int get scrollOffsetLines => _scrollOffsetLines;

  /// Current local relay share status snapshot (`unshared` for remote panes).
  LocalShareSnapshot get shareSnapshot =>
      localHost?.shareSnapshot ?? LocalShareSnapshot.unshared;

  /// Latest sanitized title emitted by the shell (`OSC 0`/`OSC 2`).
  String get shellTitle => _shellTitle;

  /// Current unread bell count accumulated by this pane.
  int get bellCount => _bellCount;

  /// Whether this pane currently owns keyboard focus in its split tree.
  bool get isFocused => _focused;

  /// Whether the underlying process or remote session has exited.
  bool get hasExited => _hasExited;

  /// Process exit status code when [hasExited] is true.
  int? get exitStatus => _exitStatus;

  /// Remote port handle when backing a remote relay session.
  RemoteTerminalPort? get remotePort =>
      port is RemoteTerminalPort ? port as RemoteTerminalPort : null;

  String _resolveInitialTitle() {
    final raw = switch (port) {
      final RemoteTerminalPort remote => remote.displayTitle,
      _ => port.windowTitle,
    };
    return raw.trim();
  }

  void _attachPortListeners() {
    port.addListener(_handlePortChange);
    port.addBellListener(_handleBell);
    port.addAudioListener(_handleAudio);
    port.addShaderListener(_handleShaderEvent);
    port.addTitleListener(_handleTitle);
    port.addClipboardListener(_handleClipboard);

    final host = localHost;
    if (host != null) {
      _shareSub = host.shareUpdates.listen((_) {
        if (!_disposed) {
          _onShareChanged?.call();
          if (!_disposed) {
            _pillNotifier.emitChange();
          }
        }
      });
    }

    unawaited(
      port.exitCode.then(_handleExited, onError: (_, _) => _handleExited(-1)),
    );
  }

  void _handlePortChange() {
    if (_disposed) return;
    _pendingDeferredShaderRecomposite = false;
    _recomposite(notify: true);
  }

  void _handleBell() {
    if (_disposed) return;
    _bellCount += 1;
    _onBell?.call(paneId);
  }

  void _handleAudio(TerminalAudioEvent event) {
    if (_disposed) return;
    _onAudio?.call(paneId, event);
  }

  void _handleShaderEvent(TerminalShaderApcEvent event) {
    if (_disposed) return;
    // Local PTY ports emit onShaderEvent synchronously during VirtualTerminal
    // parsing and follow immediately with _handlePortChange. Deferring visual
    // recomposition avoids double-recompositing every 25 Hz shader keyframe,
    // with a microtask fallback for synthetic ports that omit onChange.
    final deferVisual =
        localHost != null && event is! TerminalShaderDefineEvent;
    _deferPortShaderRecomposite = deferVisual;
    try {
      _cliShaderState.handleShaderEvent(
        event,
        onAltScreen: port.modes.altScreen,
      );
    } finally {
      _deferPortShaderRecomposite = false;
    }
  }

  void _handleCliShaderVisualChanged() {
    if (_disposed) return;
    if (_deferPortShaderRecomposite) {
      if (!_pendingDeferredShaderRecomposite) {
        _pendingDeferredShaderRecomposite = true;
        scheduleMicrotask(_flushDeferredShaderRecomposite);
      }
      return;
    }
    _recomposite(notify: true);
  }

  void _flushDeferredShaderRecomposite() {
    if (_disposed || !_pendingDeferredShaderRecomposite) return;
    _pendingDeferredShaderRecomposite = false;
    _recomposite(notify: true);
  }

  void _handleCliShaderUiChanged() {
    if (_disposed) return;
    _onCliShaderUiChanged?.call(paneId);
  }

  void _handleCliShaderQuarantined(String id, String shaderId, String reason) {
    if (_disposed) return;
    _onCliShaderQuarantined?.call(id, shaderId, reason);
  }

  void _handleTitle(String title) {
    if (_disposed) return;
    final trimmed = title.trim();
    if (trimmed == _shellTitle) return;
    _shellTitle = trimmed;
    _onTitleChanged?.call(paneId, _shellTitle);
  }

  void _handleClipboard(String selection, String text) {
    if (_disposed) return;
    _onClipboard?.call(paneId, selection, text);
  }

  void _handleExited(int code) {
    if (_disposed || _hasExited) return;
    _hasExited = true;
    _exitStatus = code;
    _cliShaderState.resetAll(notify: true);
    _onExited?.call(paneId, code);
    if (!_disposed) {
      _pillNotifier.emitChange();
    }
  }

  /// Clears unread bell counts on this pane and any attached remote slot.
  void clearBellCount() {
    _bellCount = 0;
    remotePort?.clearBellCount();
  }

  /// Updates the color resolver when theme or contrast settings change.
  void setColorResolver(TerminalColorResolver nextResolver) {
    if (_disposed) return;
    _colorResolver = nextResolver;
    localHost?.setColorScheme(nextResolver.theme.brightness);
    _recomposite(notify: true, forceFull: true);
  }

  /// Updates keyboard focus status and forwards DECSET 1004 focus sequences.
  void setFocused(bool focused) {
    if (_disposed || _focused == focused) return;
    _focused = focused;
    if (focused) {
      clearBellCount();
    }
    if (port.modes.focusReporting && !_hasExited) {
      final seq = focused ? '\x1b[I' : '\x1b[O';
      port.sendInput(Uint8List.fromList(utf8.encode(seq)));
    }
    _recomposite(notify: true, forceFull: true);
  }

  /// Schedules a PTY viewport size update for this pane's grid & cell metrics.
  void updateViewportSize(
    int cols,
    int rows,
    double cellWidth,
    double cellHeight,
  ) {
    if (_disposed || cols <= 0 || rows <= 0) return;
    final cw = cellWidth.round().clamp(1, 512);
    final ch = cellHeight.round().clamp(1, 512);
    _pendingCols = cols;
    _pendingRows = rows;
    _pendingCellW = cw;
    _pendingCellH = ch;

    if (_resizeDebounce == Duration.zero) {
      _flushPendingResize();
      return;
    }
    _resizeTimer?.cancel();
    _resizeTimer = Timer(_resizeDebounce, _flushPendingResize);
  }

  void _flushPendingResize() {
    _resizeTimer?.cancel();
    _resizeTimer = null;
    if (_disposed) return;
    final cols = _pendingCols;
    final rows = _pendingRows;
    if (cols == null || rows == null) return;
    port.setViewportSize(
      cols,
      rows,
      cellPixelWidth: _pendingCellW,
      cellPixelHeight: _pendingCellH,
    );
  }

  static int _retainedScrollbackLines(ScrollbackWindowData sbWin) =>
      math.max(0, sbWin.totalLines - sbWin.oldestLine);

  /// Scrolls primary-screen history by [deltaLines] (`+` = up, `-` = down).
  void scrollLines(int deltaLines) {
    if (_disposed || deltaLines == 0 || port.modes.altScreen) return;
    final retained = _retainedScrollbackLines(port.scrollbackWindow);
    final next = (_scrollOffsetLines + deltaLines).clamp(0, retained);
    if (next == _scrollOffsetLines) return;
    _scrollOffsetLines = next;
    _recomposite(notify: true);
  }

  /// Resets scrollback offset back to live bottom (`0`).
  void jumpToBottom() {
    if (_disposed || _scrollOffsetLines == 0) return;
    _scrollOffsetLines = 0;
    _recomposite(notify: true);
  }

  /// Encodes and routes a high-level `termui` [event] to the PTY or local
  /// scrollback engine.
  void sendInputEvent(ev.InputEvent event) {
    if (_disposed || _hasExited) return;
    switch (event) {
      case ev.MouseEvent():
        _handleMouseEvent(event);
      case ev.KeyEvent():
        if (_scrollOffsetLines > 0) {
          jumpToBottom();
        }
        _sendEncodedEvent(event);
      case ev.PasteEvent():
        if (_scrollOffsetLines > 0) {
          jumpToBottom();
        }
        _sendEncodedEvent(event);
      case ev.FocusInEvent():
        if (port.modes.focusReporting) {
          port.sendInput(Uint8List.fromList(utf8.encode('\x1b[I')));
        }
      case ev.FocusOutEvent():
        if (port.modes.focusReporting) {
          port.sendInput(Uint8List.fromList(utf8.encode('\x1b[O')));
        }
      case ev.CursorPositionReportEvent() ||
          ev.KittyGraphicsEvent() ||
          ev.KittyKeyboardEvent() ||
          ev.AudioApcReplyEvent() ||
          ev.ShaderCapabilitiesEvent():
        break;
    }
  }

  /// Sends committed IME or printable UTF-8 text to the backing PTY.
  void sendCommittedText(String text) {
    if (_disposed || _hasExited || text.isEmpty) return;
    if (_scrollOffsetLines > 0) {
      jumpToBottom();
    }
    _sendUtf8Chunked(text);
  }

  void _handleMouseEvent(ev.MouseEvent event) {
    final modes = port.modes;
    final isWheel =
        event.button == ev.MouseButton.wheelUp ||
        event.button == ev.MouseButton.wheelDown;
    if (isWheel) {
      _handleWheelMouseEvent(event, modes);
      return;
    }
    if (mouseTracking) {
      _sendEncodedEvent(event);
    }
  }

  void _handleWheelMouseEvent(ev.MouseEvent event, TerminalPortModes modes) {
    if (mouseTracking && !event.modifiers.contains(ev.Modifier.shift)) {
      _sendEncodedEvent(event);
      return;
    }
    final up = event.button == ev.MouseButton.wheelUp;
    if (modes.altScreen && modes.alternateScroll) {
      final seq = modes.appCursorKeys
          ? (up ? '\x1bOA' : '\x1bOB')
          : (up ? '\x1b[A' : '\x1b[B');
      port.sendInput(Uint8List.fromList(utf8.encode(seq)));
      return;
    }
    if (!modes.altScreen) {
      scrollLines(up ? _wheelScrollLines : -_wheelScrollLines);
    }
  }

  void _sendEncodedEvent(ev.InputEvent event) {
    final modes = port.modes;
    final (pixelX, pixelY) = event is ev.MouseEvent
        ? (event.pixelX, event.pixelY)
        : (null, null);
    final encoded = InputEncoder.encode(
      event,
      bracketedPaste: modes.bracketedPaste,
      applicationCursorKeys: modes.appCursorKeys,
      sgrMouse: modes.sgrMouse || modes.sgrPixelsMouse,
      sgrPixels: modes.sgrPixelsMouse,
      kittyKeyboardFlags: modes.kittyKeyboardFlags,
      pixelX: pixelX,
      pixelY: pixelY,
    );
    if (encoded.isEmpty) return;
    _sendUtf8Chunked(encoded);
  }

  void _sendUtf8Chunked(String payload) {
    final bytes = utf8.encode(payload);
    if (bytes.length <= _maxInputChunkBytes) {
      port.sendInput(bytes);
      return;
    }
    for (var offset = 0; offset < bytes.length; offset += _maxInputChunkBytes) {
      final end = math.min(bytes.length, offset + _maxInputChunkBytes);
      port.sendInput(Uint8List.sublistView(bytes, offset, end));
    }
  }

  void _recomposite({required bool notify, bool forceFull = false}) {
    final src = port.buffer;
    final width = math.max(1, src.width);
    final height = math.max(1, src.height);

    final sbWin = port.scrollbackWindow;
    if (sbWin.clearSeq != _lastScrollbackClearSeq) {
      _lastScrollbackClearSeq = sbWin.clearSeq;
      _scrollOffsetLines = 0;
    }
    if (port.modes.altScreen) {
      _scrollOffsetLines = 0;
    } else {
      final retained = _retainedScrollbackLines(sbWin);
      _scrollOffsetLines = _scrollOffsetLines.clamp(0, retained);
    }

    var out = _composedBuffer;
    if (out == null || out.width != width || out.height != height) {
      out = tui.Buffer.blank(width, height);
      _composedBuffer = out;
      _recompositeFull(out, src, sbWin);
    } else if (forceFull || !_tryIncrementalRecomposite(out, src)) {
      out.clearMetadata();
      _recompositeFull(out, src, sbWin);
    }

    _onFrameRedrawn?.call(out);
    if (notify) {
      _visualNotifier.emitChange();
      if (_scrollOffsetLines != _lastPillScrollOffset) {
        _lastPillScrollOffset = _scrollOffsetLines;
        _pillNotifier.emitChange();
      }
    }
  }

  void _recompositeFull(
    tui.Buffer out,
    tui.Buffer src,
    ScrollbackWindowData sbWin,
  ) {
    _populateRows(out, src, sbWin);
    if (_scrollOffsetLines == 0) {
      out.propagateMetadataFrom(src);
      _cliShaderState.applyOverlaysToBuffer(out, src);
      _lastCursorCellIndex = _paintCursorIfVisible(out);
    } else {
      _lastCursorCellIndex = -1;
      out.clearShaderRegions();
      out.clearCellTransforms();
      _propagateScrolledKittyMetadata(out, src);
      _paintScrollbarThumb(out, _retainedScrollbackLines(sbWin));
    }
    _lastComposedWidth = out.width;
    _lastComposedHeight = out.height;
    _lastComposedScrollOffset = _scrollOffsetLines;
    _lastComposedRevision = _scrollOffsetLines == 0 ? port.renderRevision : -1;
    _visualNotifier.bumpCellContentRevision();
  }

  bool _tryIncrementalRecomposite(tui.Buffer out, tui.Buffer src) {
    if (_scrollOffsetLines != 0 ||
        _lastComposedScrollOffset != 0 ||
        _lastComposedWidth != src.width ||
        _lastComposedHeight != src.height ||
        out.effects.isNotEmpty ||
        out.selectableRegions.isNotEmpty ||
        src.effects.isNotEmpty ||
        src.selectableRegions.isNotEmpty ||
        _lastComposedRevision < port.fullSyncRevision) {
      return false;
    }

    final totalCells = out.width * out.height;
    final prevCursorIdx = _lastCursorCellIndex;
    final targetCursorIdx = _targetCursorCellIndex(out);
    final sinceRev = _lastComposedRevision;
    final hasDirtySpans = _hasDirtySpansSince(port.dirtySpans, sinceRev);
    final cellsChanged = hasDirtySpans || targetCursorIdx != prevCursorIdx;

    if (cellsChanged) {
      if (prevCursorIdx >= 0 && prevCursorIdx < totalCells) {
        _copyResolvedSpan(out, src, prevCursorIdx, 1);
      }
      _applyDirtySpans(out, src, sinceRev, totalCells);
      _lastCursorCellIndex = _paintCursorIfVisible(out);
      _visualNotifier.bumpCellContentRevision();
    }

    _cliShaderState.applyOverlaysToBuffer(out, src);
    _lastComposedRevision = port.renderRevision;
    return true;
  }

  bool _hasDirtySpansSince(List<DirtyCellSpan> spans, int sinceRev) {
    for (final span in spans) {
      if (span.revision > sinceRev) return true;
    }
    return false;
  }

  void _applyDirtySpans(
    tui.Buffer out,
    tui.Buffer src,
    int sinceRev,
    int totalCells,
  ) {
    for (final span in port.dirtySpans) {
      if (span.revision <= sinceRev) continue;
      final start = span.start.clamp(0, totalCells);
      final end = (span.start + span.length).clamp(start, totalCells);
      final len = end - start;
      if (len > 0) {
        _copyResolvedSpan(out, src, start, len);
      }
    }
  }

  int _targetCursorCellIndex(tui.Buffer out) {
    final cursor = port.cursor;
    if (!cursor.visible || !_focused || out.width <= 0 || out.height <= 0) {
      return -1;
    }
    final cx = cursor.x.clamp(0, out.width - 1);
    final cy = cursor.y.clamp(0, out.height - 1);
    return cy * out.width + cx;
  }

  void _copyResolvedSpan(tui.Buffer out, tui.Buffer src, int start, int len) {
    _copyResolvedCells(
      out: out,
      dstOffset: start,
      copyCols: len,
      srcChars: src.glyphCellList,
      srcAttrs: src.attributes,
      srcStartCell: start,
    );
    out.copyCellAuxRangeFrom(src, start, start, len);
  }

  void _populateRows(
    tui.Buffer out,
    tui.Buffer src,
    ScrollbackWindowData sbWin,
  ) {
    final total = sbWin.totalLines;
    final topVirtual = math.max(sbWin.oldestLine, total - _scrollOffsetLines);
    final sbCount = math.max(0, math.min(out.height, total - topVirtual));
    final sbRows = sbCount > 0
        ? port.readScrollbackSlice(topVirtual, sbCount)
        : const <ScrollbackLine?>[];

    for (var screenY = 0; screenY < out.height; screenY++) {
      _populateSingleRow(
        out: out,
        src: src,
        screenY: screenY,
        topVirtual: topVirtual,
        total: total,
        sbCount: sbCount,
        sbRows: sbRows,
      );
    }
  }

  void _populateSingleRow({
    required tui.Buffer out,
    required tui.Buffer src,
    required int screenY,
    required int topVirtual,
    required int total,
    required int sbCount,
    required List<ScrollbackLine?> sbRows,
  }) {
    if (screenY < sbCount) {
      final line = screenY < sbRows.length ? sbRows[screenY] : null;
      if (line != null) {
        _copyScrollbackRow(out, screenY, line);
      } else {
        _clearScreenRow(out, screenY);
      }
      return;
    }
    final liveY = topVirtual + screenY - total;
    if (liveY >= 0 && liveY < src.height) {
      _copyLiveRow(out, screenY, src, liveY);
    } else {
      _clearScreenRow(out, screenY);
    }
  }

  void _clearScreenRow(tui.Buffer out, int screenY) {
    final start = screenY * out.width;
    final end = start + out.width;
    out.glyphCellList.fillCodeRange(start, end, tui.GlyphCellList.spaceCode);
    out.attributes.fillRange(start * 3, end * 3, 0);
    out.clearCellAuxRange(start, end);
  }

  void _copyLiveRow(tui.Buffer out, int screenY, tui.Buffer src, int liveY) {
    final copyCols = math.min(out.width, src.width);
    final dstOffset = screenY * out.width;
    final srcOffset = liveY * src.width;
    _copyResolvedCells(
      out: out,
      dstOffset: dstOffset,
      copyCols: copyCols,
      srcChars: src.glyphCellList,
      srcAttrs: src.attributes,
      srcStartCell: srcOffset,
    );
    out.clearCellAuxRange(dstOffset, dstOffset + out.width);
    if (copyCols > 0) {
      out.copyCellAuxRangeFrom(src, dstOffset, srcOffset, copyCols);
    }
    _fillRowTailBlank(out, dstOffset, copyCols);
  }

  void _copyScrollbackRow(tui.Buffer out, int screenY, ScrollbackLine line) {
    final copyCols = math.min(out.width, line.characters.length);
    final dstOffset = screenY * out.width;
    _copyResolvedCells(
      out: out,
      dstOffset: dstOffset,
      copyCols: copyCols,
      srcChars: line.characters,
      srcAttrs: line.attributes,
      srcStartCell: 0,
    );
    out.clearCellAuxRange(dstOffset, dstOffset + out.width);
    for (var col = 0; col < copyCols; col++) {
      final ul = line.underlineColors?[col] ?? 0;
      if (ul != 0) out.setUnderlineColorAt(dstOffset + col, ul);
      final uri = line.uris?[col];
      if (uri != null && uri.isNotEmpty) {
        out.setUriAt(dstOffset + col, uri);
      }
    }
    _fillRowTailBlank(out, dstOffset, copyCols);
  }

  void _fillRowTailBlank(tui.Buffer out, int dstOffset, int copyCols) {
    if (copyCols >= out.width) return;
    final tailStart = dstOffset + copyCols;
    final tailEnd = dstOffset + out.width;
    out.glyphCellList.fillCodeRange(
      tailStart,
      tailEnd,
      tui.GlyphCellList.spaceCode,
    );
    out.attributes.fillRange(tailStart * 3, tailEnd * 3, 0);
  }

  void _copyResolvedCells({
    required tui.Buffer out,
    required int dstOffset,
    required int copyCols,
    required List<String> srcChars,
    required Uint32List srcAttrs,
    required int srcStartCell,
  }) {
    if (copyCols <= 0) return;
    final outGlyphs = out.glyphCellList;
    if (srcChars is tui.GlyphCellList) {
      outGlyphs.copyCellsFrom(srcChars, dstOffset, srcStartCell, copyCols);
    } else {
      outGlyphs.setRange(
        dstOffset,
        dstOffset + copyCols,
        srcChars,
        srcStartCell,
      );
    }
    final outAttrs = out.attributes;
    for (var col = 0; col < copyCols; col++) {
      final srcIdx = srcStartCell + col;
      final dstIdx = dstOffset + col;
      final sBase = srcIdx * 3;
      final dBase = dstIdx * 3;
      final rawFg = srcAttrs[sBase];
      final rawBg = srcAttrs[sBase + 1];
      final mods = srcAttrs[sBase + 2] & ~tui.Modifier.transparent;
      if (!rawFg.isAnsiIndexed && !rawBg.isAnsiIndexed) {
        outAttrs[dBase] = rawFg;
        outAttrs[dBase + 1] = rawBg;
        outAttrs[dBase + 2] = mods;
        continue;
      }
      _colorResolver.resolveCellInto(
        rawFg: rawFg,
        rawBg: rawBg,
        modifiers: mods,
        grapheme: outGlyphs[dstIdx],
        outAttributes: outAttrs,
        attrOffset: dBase,
      );
    }
  }

  int _paintCursorIfVisible(tui.Buffer out) {
    final cursor = port.cursor;
    if (!cursor.visible || !_focused || out.width <= 0 || out.height <= 0) {
      return -1;
    }
    final cx = cursor.x.clamp(0, out.width - 1);
    final cy = cursor.y.clamp(0, out.height - 1);
    final cellIdx = cy * out.width + cx;
    final base = cellIdx * 3;
    final mods = out.attributes[base + 2];
    final isKitty = tui.Modifier.has(mods, tui.Modifier.kittyPlaceholder);
    final useInverse =
        !isKitty &&
        _colorResolver.theme.id == 'termui_dark' &&
        _colorResolver.settings.customOverrides.cursorColor == null;
    if (useInverse) {
      out.attributes[base + 2] = mods ^ tui.Modifier.reverse;
      return cellIdx;
    }
    final (cursorColor, cursorTextColor) = _colorResolver.resolveCursorColors(
      cellFg: isKitty ? 0 : out.attributes[base],
      cellBg: out.attributes[base + 1],
    );
    // Preserve fgArgb on Kitty placeholder cells since it carries the imageId.
    if (!isKitty) {
      out.attributes[base] = cursorTextColor;
    }
    out.attributes[base + 1] = cursorColor;
    out.attributes[base + 2] = mods & ~tui.Modifier.reverse;
    return cellIdx;
  }

  void _propagateScrolledKittyMetadata(tui.Buffer out, tui.Buffer src) {
    final paneRegistry =
        remotePort?.slot.kittyRegistry ??
        (src.width > 0 && src.height > 0
            ? src.lookupKittyRegistry(0, 0)
            : null);
    if (paneRegistry != null &&
        !identical(paneRegistry, tui.KittyImageRegistry.global)) {
      out.registerKittyRegistry(
        tui.Rect(0, 0, out.width, out.height),
        paneRegistry,
      );
    }
  }

  void _paintScrollbarThumb(tui.Buffer out, int totalLines) {
    if (out.width < 2 || out.height < 1 || totalLines <= 0) return;
    final h = out.height;
    final thumbH = math.max(1, (h * h / (totalLines + h)).round()).clamp(1, h);
    final maxTop = math.max(0, h - thumbH);
    final top =
        ((totalLines - _scrollOffsetLines) * maxTop / math.max(1, totalLines))
            .round()
            .clamp(0, maxTop);
    final x = out.width - 1;
    for (var y = top; y < top + thumbH; y++) {
      final idx = y * out.width + x;
      out.glyphCellList.setCodeAt(idx, _scrollbarThumbCode);
      out.attributes[idx * 3] = 0xFF7B8FA6;
      out.attributes[idx * 3 + 2] = tui.Modifier.none;
      out.clearCellAuxRange(idx, idx + 1);
    }
  }

  /// Detaches listeners and cancels pending resize timers without necessarily
  /// disposing [localHost] (caller owns pane teardown order).
  Future<void> dispose({bool disposePort = true}) async {
    if (_disposed) return;
    _disposed = true;
    _onBell = null;
    _onAudio = null;
    _onTitleChanged = null;
    _onClipboard = null;
    _onExited = null;
    _onShareChanged = null;
    _onCliShaderUiChanged = null;
    _onCliShaderQuarantined = null;
    _resizeTimer?.cancel();
    _resizeTimer = null;
    await _shareSub?.cancel();
    _shareSub = null;
    port.removeListener(_handlePortChange);
    port.removeBellListener(_handleBell);
    port.removeAudioListener(_handleAudio);
    port.removeShaderListener(_handleShaderEvent);
    port.removeTitleListener(_handleTitle);
    port.removeClipboardListener(_handleClipboard);
    _cliShaderState.dispose();
    _bufferListenable?.dispose();
    _visualNotifier.dispose();
    _pillNotifier.dispose();
    if (disposePort) {
      if (localHost != null) {
        await localHost!.dispose();
      } else {
        await port.dispose();
      }
    }
  }
}

final class _PaneBufferListenable extends ChangeNotifier
    implements ValueListenable<tui.Buffer>, TerminalBufferChangeSignal {
  final _PaneChangeNotifier _source;
  final tui.Buffer Function() _read;

  _PaneBufferListenable(this._source, this._read) {
    _source.addListener(notifyListeners);
  }

  @override
  tui.Buffer get value => _read();

  @override
  int get cellContentRevision => _source.cellContentRevision;

  @override
  void dispose() {
    _source.removeListener(notifyListeners);
    super.dispose();
  }
}
