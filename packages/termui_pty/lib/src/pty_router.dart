import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:termui/termui.dart';

import 'audio_apc_handler.dart';
import 'scrollback_buffer.dart';
import 'terminal_port.dart';
import 'virtual_terminal.dart';

/// Abstract byte-oriented PTY backend driven by [PtyRouterSession].
abstract interface class RoutedPtyBackend {
  /// Raw UTF-8 / ANSI output byte chunks emitted by the child process.
  Stream<Uint8List> get output;

  /// Future completing with the child process exit code upon termination.
  Future<int> get exitCode;

  /// Writes encoded input or terminal query reply bytes to the PTY.
  void write(Uint8List bytes);

  /// Resizes the PTY window to [cols] by [rows] and optional pixel dimensions.
  void resize(int cols, int rows, {int pixelWidth = 0, int pixelHeight = 0});

  /// Sends a termination signal to the child process.
  void kill();

  /// Releases backend resources.
  Future<void> dispose();
}

final class _ViewportEndpoint {
  final int cols;
  final int rows;
  final int cellPixelWidth;
  final int cellPixelHeight;
  final bool isPrimary;

  const _ViewportEndpoint({
    required this.cols,
    required this.rows,
    required this.cellPixelWidth,
    required this.cellPixelHeight,
    required this.isPrimary,
  });
}

final class _RouterRawBytePipeEntry {
  final StreamController<Uint8List> toCaller;
  final StreamController<Uint8List> fromCaller;
  final StreamSubscription<Uint8List> inputSub;
  final RouterBytePipe callerPipe;

  _RouterRawBytePipeEntry({
    required this.toCaller,
    required this.fromCaller,
    required this.inputSub,
    required this.callerPipe,
  });

  static Future<void> _closeControllerSafely(
    StreamController<Uint8List> controller,
  ) {
    if (controller.isClosed) return Future<void>.value();
    final future = controller.close();
    return (controller.hasListener && !controller.isPaused)
        ? future
        : Future<void>.value();
  }

  Future<void> close() async {
    await inputSub.cancel();
    await _closeControllerSafely(fromCaller);
    await _closeControllerSafely(toCaller);
  }
}

/// Pure-Dart Web-safe multi-observer PTY router owning [PtyRouterSession]s.
final class PtyRouter {
  final Map<String, PtyRouterSession> _sessions = {};
  int _nextSessionNumber = 1;
  bool _disposed = false;

  /// Active routed sessions keyed by session ID.
  Map<String, PtyRouterSession> get sessions => Map.unmodifiable(_sessions);

  /// Looks up an active session by [sessionId], or returns `null`.
  PtyRouterSession? operator [](String sessionId) => _sessions[sessionId];

  /// Creates and starts a [PtyRouterSession] owning one authoritative [VirtualTerminal].
  PtyRouterSession createSession({
    String? id,
    required RoutedPtyBackend backend,
    int initialCols = 80,
    int initialRows = 24,
    int maxScrollbackLines = 5000,
    int cellPixelWidth = 8,
    int cellPixelHeight = 16,
    bool transparentBackground = false,
    Color? defaultForeground,
    Color? defaultBackground,
    bool emitIndexedColors = false,
    TerminalColorTheme? theme,
    Color? defaultCursorColor,
    TerminalBrightness? colorScheme,
  }) {
    if (_disposed) {
      throw StateError('PtyRouter has been disposed.');
    }
    final sessionId = id ?? 'tpr-${_nextSessionNumber++}';
    if (sessionId.isEmpty) {
      throw ArgumentError.value(
        sessionId,
        'id',
        'Session ID must be non-empty',
      );
    }
    if (_sessions.containsKey(sessionId)) {
      throw ArgumentError.value(
        sessionId,
        'id',
        'Duplicate PtyRouterSession ID',
      );
    }

    late final PtyRouterSession session;
    session = PtyRouterSession._(
      id: sessionId,
      backend: backend,
      initialCols: initialCols,
      initialRows: initialRows,
      maxScrollbackLines: maxScrollbackLines,
      cellPixelWidth: cellPixelWidth,
      cellPixelHeight: cellPixelHeight,
      transparentBackground: transparentBackground,
      defaultForeground: defaultForeground,
      defaultBackground: defaultBackground,
      emitIndexedColors: emitIndexedColors,
      theme: theme,
      defaultCursorColor: defaultCursorColor,
      colorScheme: colorScheme,
      onDispose: () => _sessions.remove(sessionId),
    );
    _sessions[sessionId] = session;
    return session;
  }

  /// Closes and disposes the session identified by [sessionId], if present.
  Future<void> closeSession(String sessionId) async {
    final session = _sessions.remove(sessionId);
    if (session != null) {
      await session.dispose();
    }
  }

  /// Disposes all active sessions owned by this router.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    final active = List.of(_sessions.values);
    _sessions.clear();
    for (final session in active) {
      await session.dispose();
    }
  }
}

/// Authoritative terminal session fanning one [RoutedPtyBackend] and one
/// [VirtualTerminal] across multiple local [TerminalPort]s and remote sinks.
final class PtyRouterSession {
  /// Unique identifier for this routed session.
  final String id;

  /// Underlying PTY transport bound to this session.
  final RoutedPtyBackend backend;

  /// Authoritative [VirtualTerminal] parsing PTY output once per chunk.
  final VirtualTerminal terminal;

  final void Function() _onDispose;
  final LinkedHashSet<void Function()> _changeListeners = LinkedHashSet();
  final LinkedHashSet<void Function(String title)> _titleListeners =
      LinkedHashSet();
  final LinkedHashSet<void Function()> _bellListeners = LinkedHashSet();
  final LinkedHashSet<void Function(TerminalAudioEvent event)> _audioListeners =
      LinkedHashSet();
  final LinkedHashSet<void Function(String selection, String text)>
  _clipboardListeners = LinkedHashSet();
  final LinkedHashSet<void Function(String selection)>
  _clipboardBlockedListeners = LinkedHashSet();
  final Map<String, _ViewportEndpoint> _endpoints = {};
  final Map<String, _RouterTerminalPort> _ports = {};
  final Set<_RouterRawBytePipeEntry> _rawBytePipes = {};
  final Set<StreamSink<Uint8List>> _outputSinks = {};

  StreamSubscription<Uint8List>? _outputSub;
  int _nextPortNumber = 1;
  int _lastPixelWidth = 0;
  int _lastPixelHeight = 0;
  bool _disposed = false;

  PtyRouterSession._({
    required this.id,
    required this.backend,
    required int initialCols,
    required int initialRows,
    required int maxScrollbackLines,
    required int cellPixelWidth,
    required int cellPixelHeight,
    required bool transparentBackground,
    required Color? defaultForeground,
    required Color? defaultBackground,
    required bool emitIndexedColors,
    required TerminalColorTheme? theme,
    required Color? defaultCursorColor,
    required TerminalBrightness? colorScheme,
    required void Function() onDispose,
  }) : _onDispose = onDispose,
       terminal = VirtualTerminal(
         width: initialCols,
         height: initialRows,
         cellPixelWidth: cellPixelWidth,
         cellPixelHeight: cellPixelHeight,
         maxScrollbackLines: maxScrollbackLines,
         transparentBackground: transparentBackground,
         defaultForeground: defaultForeground,
         defaultBackground: defaultBackground,
         emitIndexedColors: emitIndexedColors,
         theme: theme,
         defaultCursorColor: defaultCursorColor,
         colorScheme: colorScheme,
       ) {
    terminal
      ..onReply = _handleTerminalReply
      ..addListener(_dispatchChange)
      ..onTitleChanged = _dispatchTitle
      ..onBell = _dispatchBell
      ..onAudioEvent = _dispatchAudio
      ..onClipboardWrite = _dispatchClipboard
      ..onClipboardReadBlocked = _dispatchClipboardBlocked;
    _outputSub = backend.output.listen(
      _onBackendOutput,
      onError: (_, _) {},
      onDone: () {},
    );
  }

  /// Current authoritative terminal width in columns.
  int get cols => terminal.width;

  /// Current authoritative terminal height in rows.
  int get rows => terminal.height;

  /// Current authoritative PTY grid dimensions `(cols, rows)`.
  (int cols, int rows) get activePtySize => (terminal.width, terminal.height);

  /// Latest pixel dimensions forwarded to `TIOCSWINSZ`.
  (int width, int height) get activePixelSize =>
      (_lastPixelWidth, _lastPixelHeight);

  /// Future completing with the child process exit code.
  Future<int> get exitCode => backend.exitCode;

  /// Whether [dispose] has been called on this session.
  bool get isDisposed => _disposed;

  void _handleTerminalReply(String reply) {
    if (_disposed || reply.isEmpty) return;
    backend.write(Uint8List.fromList(utf8.encode(reply)));
  }

  void _onBackendOutput(Uint8List bytes) {
    if (_disposed || bytes.isEmpty) return;
    terminal.write(bytes);
    for (final pipe in List.of(_rawBytePipes)) {
      if (!pipe.toCaller.isClosed &&
          pipe.toCaller.hasListener &&
          !pipe.toCaller.isPaused) {
        _invokeIsolated(() => pipe.toCaller.add(Uint8List.fromList(bytes)));
      }
    }
    for (final sink in List.of(_outputSinks)) {
      _invokeIsolated(() => sink.add(Uint8List.fromList(bytes)));
    }
  }

  static void _invokeIsolated(void Function() fn) {
    try {
      fn();
    } catch (_) {}
  }

  void _dispatchChange() {
    for (final listener in List.of(_changeListeners)) {
      _invokeIsolated(listener);
    }
    for (final port in List.of(_ports.values)) {
      port._dispatchChange();
    }
  }

  void _dispatchTitle(String title) {
    for (final listener in List.of(_titleListeners)) {
      _invokeIsolated(() => listener(title));
    }
    for (final port in List.of(_ports.values)) {
      port._dispatchTitle(title);
    }
  }

  void _dispatchBell() {
    for (final listener in List.of(_bellListeners)) {
      _invokeIsolated(listener);
    }
    for (final port in List.of(_ports.values)) {
      port._dispatchBell();
    }
  }

  void _dispatchAudio(TerminalAudioEvent event) {
    for (final listener in List.of(_audioListeners)) {
      _invokeIsolated(() => listener(event));
    }
    for (final port in List.of(_ports.values)) {
      port._dispatchAudio(event);
    }
  }

  void _dispatchClipboard(String selection, String text) {
    for (final listener in List.of(_clipboardListeners)) {
      _invokeIsolated(() => listener(selection, text));
    }
    for (final port in List.of(_ports.values)) {
      port._dispatchClipboard(selection, text);
    }
  }

  void _dispatchClipboardBlocked(String selection) {
    for (final listener in List.of(_clipboardBlockedListeners)) {
      _invokeIsolated(() => listener(selection));
    }
  }

  /// Registers a visual buffer/state change listener.
  void addListener(void Function() listener) => _changeListeners.add(listener);

  /// Unregisters a visual buffer/state change listener.
  void removeListener(void Function() listener) =>
      _changeListeners.remove(listener);

  /// Registers a window title change listener.
  void addTitleListener(void Function(String title) listener) =>
      _titleListeners.add(listener);

  /// Unregisters a window title change listener.
  void removeTitleListener(void Function(String title) listener) =>
      _titleListeners.remove(listener);

  /// Registers a terminal bell listener.
  void addBellListener(void Function() listener) =>
      _bellListeners.add(listener);

  /// Unregisters a terminal bell listener.
  void removeBellListener(void Function() listener) =>
      _bellListeners.remove(listener);

  /// Registers a decoded audio APC event listener.
  void addAudioListener(void Function(TerminalAudioEvent event) listener) =>
      _audioListeners.add(listener);

  /// Unregisters a decoded audio APC event listener.
  void removeAudioListener(void Function(TerminalAudioEvent event) listener) =>
      _audioListeners.remove(listener);

  /// Registers an `OSC 52` clipboard write listener.
  void addClipboardListener(
    void Function(String selection, String text) listener,
  ) => _clipboardListeners.add(listener);

  /// Unregisters an `OSC 52` clipboard write listener.
  void removeClipboardListener(
    void Function(String selection, String text) listener,
  ) => _clipboardListeners.remove(listener);

  /// Registers an `OSC 52` blocked-read listener.
  void addClipboardBlockedListener(void Function(String selection) listener) =>
      _clipboardBlockedListeners.add(listener);

  /// Unregisters an `OSC 52` blocked-read listener.
  void removeClipboardBlockedListener(
    void Function(String selection) listener,
  ) => _clipboardBlockedListeners.remove(listener);

  /// Writes encoded UTF-8 or escape input bytes to the backend PTY.
  void writeInput(Uint8List utf8Bytes) {
    if (_disposed || utf8Bytes.isEmpty) return;
    backend.write(Uint8List.fromList(utf8Bytes));
  }

  /// Attaches a raw [StreamSink<Uint8List>] to receive subsequent live PTY output bytes.
  void attachOutputSink(StreamSink<Uint8List> sink) {
    if (_disposed) return;
    _outputSinks.add(sink);
  }

  /// Detaches a previously attached raw PTY output [sink].
  void detachOutputSink(StreamSink<Uint8List> sink) {
    _outputSinks.remove(sink);
  }

  /// Opens a bidirectional [RouterBytePipe] delivering live PTY output on `stream`
  /// and forwarding bytes written to `sink` directly into [backend].
  RouterBytePipe openBytePipe({bool sync = false}) {
    if (_disposed) {
      throw StateError('PtyRouterSession($id) has been disposed.');
    }
    late final _RouterRawBytePipeEntry entry;
    final toCaller = StreamController<Uint8List>(
      sync: sync,
      onCancel: () {
        _rawBytePipes.remove(entry);
        unawaited(entry.close());
      },
    );
    final fromCaller = StreamController<Uint8List>(sync: sync);
    final inputSub = fromCaller.stream.listen(
      writeInput,
      onDone: () {
        _rawBytePipes.remove(entry);
        unawaited(entry.close());
      },
    );
    final callerPipe = RouterBytePipe.fromStreamAndSink(
      stream: toCaller.stream,
      sink: fromCaller.sink,
      onClose: () async {
        _rawBytePipes.remove(entry);
        await entry.close();
      },
    );
    entry = _RouterRawBytePipeEntry(
      toCaller: toCaller,
      fromCaller: fromCaller,
      inputSub: inputSub,
      callerPipe: callerPipe,
    );
    _rawBytePipes.add(entry);
    return callerPipe;
  }

  String _allocatePortId(String? portId) {
    if (portId == null) {
      while (_ports.containsKey('port-$_nextPortNumber')) {
        _nextPortNumber++;
      }
      return 'port-${_nextPortNumber++}';
    }
    if (portId.isEmpty) {
      throw ArgumentError.value(portId, 'portId', 'Port ID must be non-empty');
    }
    if (_ports.containsKey(portId)) {
      throw ArgumentError.value(portId, 'portId', 'Duplicate active portId');
    }
    return portId;
  }

  void _removePort(String portId, _RouterTerminalPort port) {
    if (identical(_ports[portId], port)) {
      _ports.remove(portId);
    }
  }

  /// Opens a local [TerminalPort] attached to this session with input framed over
  /// an internal [RouterBytePipe].
  TerminalPort openPort({
    String? portId,
    int? initialCols,
    int? initialRows,
    int cellPixelWidth = 0,
    int cellPixelHeight = 0,
    bool isPrimary = true,
  }) {
    if (_disposed) {
      throw StateError('PtyRouterSession($id) has been disposed.');
    }
    final assignedId = _allocatePortId(portId);
    final (portPipe, routerPipe) = RouterBytePipe.duplex(sync: true);
    final inputSub = routerPipe.stream.listen(writeInput);
    final port = _RouterTerminalPort(
      session: this,
      portId: assignedId,
      isPrimary: isPrimary,
      inputPipe: portPipe,
      routerInputPipe: routerPipe,
      routerInputSub: inputSub,
    );
    _ports[assignedId] = port;
    if (initialCols != null && initialRows != null) {
      port.setViewportSize(
        initialCols,
        initialRows,
        cellPixelWidth: cellPixelWidth,
        cellPixelHeight: cellPixelHeight,
      );
    }
    return port;
  }

  /// Registers or updates a viewport size constraint for [endpointId] and
  /// recomputes the smallest active `(minCols, minRows)` across all endpoints.
  ///
  /// Non-positive [cols] or [rows] values are ignored.
  void setEndpointViewport(
    String endpointId,
    int cols,
    int rows, {
    int cellPixelWidth = 0,
    int cellPixelHeight = 0,
    bool isPrimary = false,
  }) {
    if (_disposed || cols <= 0 || rows <= 0) return;
    _endpoints[endpointId] = _ViewportEndpoint(
      cols: cols,
      rows: rows,
      cellPixelWidth: math.max(0, cellPixelWidth),
      cellPixelHeight: math.max(0, cellPixelHeight),
      isPrimary: isPrimary,
    );
    _recomputeViewportSize();
  }

  /// Removes [endpointId]'s viewport constraint and restores larger dimensions
  /// when smaller observers detach.
  void removeEndpointViewport(String endpointId) {
    if (_endpoints.remove(endpointId) != null) {
      _recomputeViewportSize();
    }
  }

  (int cellW, int cellH) _resolvePrimaryCellPixelSize() {
    var fallbackW = 0;
    var fallbackH = 0;
    for (final ep in _endpoints.values) {
      if (ep.cellPixelWidth <= 0 || ep.cellPixelHeight <= 0) continue;
      if (ep.isPrimary) {
        return (ep.cellPixelWidth, ep.cellPixelHeight);
      }
      if (fallbackW == 0) {
        fallbackW = ep.cellPixelWidth;
        fallbackH = ep.cellPixelHeight;
      }
    }
    return (fallbackW, fallbackH);
  }

  (int minCols, int minRows) _resolveMinGridSize() {
    var minCols = _endpoints.values.first.cols;
    var minRows = _endpoints.values.first.rows;
    for (final ep in _endpoints.values) {
      minCols = math.min(minCols, ep.cols);
      minRows = math.min(minRows, ep.rows);
    }
    return (minCols, minRows);
  }

  void _recomputeViewportSize() {
    if (_disposed || _endpoints.isEmpty) return;
    final (minCols, minRows) = _resolveMinGridSize();
    final (cellW, cellH) = _resolvePrimaryCellPixelSize();
    final pixelWidth = (minCols * cellW).clamp(0, 65535);
    final pixelHeight = (minRows * cellH).clamp(0, 65535);
    final gridChanged = minCols != terminal.width || minRows != terminal.height;
    final cellChanged =
        cellW > 0 &&
        cellH > 0 &&
        (cellW != terminal.cellPixelWidth || cellH != terminal.cellPixelHeight);
    final pixelChanged =
        pixelWidth != _lastPixelWidth || pixelHeight != _lastPixelHeight;
    if (!gridChanged && !cellChanged && !pixelChanged) return;

    if (gridChanged) terminal.resize(minCols, minRows);
    if (cellChanged) terminal.setCellPixelSize(cellW, cellH);
    _lastPixelWidth = pixelWidth;
    _lastPixelHeight = pixelHeight;
    backend.resize(
      minCols,
      minRows,
      pixelWidth: pixelWidth,
      pixelHeight: pixelHeight,
    );
    if (gridChanged && !cellChanged) _dispatchChange();
  }

  /// Reads up to [count] primary-screen scrollback lines starting at [startLine].
  List<ScrollbackLine?> readScrollbackSlice(int startLine, int count) {
    final sb = terminal.scrollback;
    if (count <= 0 || startLine < 0 || startLine >= sb.totalLines) {
      return const [];
    }
    final end = math.min(startLine + count, sb.totalLines);
    return [for (var line = startLine; line < end; line++) sb[line]];
  }

  /// Disposes this session, its [VirtualTerminal], open byte pipes, and [backend].
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _onDispose();
    await _outputSub?.cancel();
    _outputSub = null;
    for (final port in List.of(_ports.values)) {
      await port.dispose();
    }
    _ports.clear();
    for (final entry in List.of(_rawBytePipes)) {
      await entry.close();
    }
    _rawBytePipes.clear();
    _outputSinks.clear();
    _endpoints.clear();
    _changeListeners.clear();
    _titleListeners.clear();
    _bellListeners.clear();
    _audioListeners.clear();
    _clipboardListeners.clear();
    _clipboardBlockedListeners.clear();
    terminal.dispose();
    await backend.dispose();
  }
}

final class _RouterTerminalPort implements TerminalPort {
  final PtyRouterSession _session;
  final String _portId;
  final bool _isPrimary;
  final RouterBytePipe _inputPipe;
  final RouterBytePipe _routerInputPipe;
  final StreamSubscription<Uint8List> _routerInputSub;

  final LinkedHashSet<void Function()> _changeListeners = LinkedHashSet();
  final LinkedHashSet<void Function(String title)> _titleListeners =
      LinkedHashSet();
  final LinkedHashSet<void Function()> _bellListeners = LinkedHashSet();
  final LinkedHashSet<void Function(TerminalAudioEvent event)> _audioListeners =
      LinkedHashSet();
  final LinkedHashSet<void Function(String selection, String text)>
  _clipboardListeners = LinkedHashSet();

  bool _disposed = false;

  String get _endpointKey => 'port:$_portId';

  _RouterTerminalPort({
    required PtyRouterSession session,
    required String portId,
    required bool isPrimary,
    required RouterBytePipe inputPipe,
    required RouterBytePipe routerInputPipe,
    required StreamSubscription<Uint8List> routerInputSub,
  }) : _session = session,
       _portId = portId,
       _isPrimary = isPrimary,
       _inputPipe = inputPipe,
       _routerInputPipe = routerInputPipe,
       _routerInputSub = routerInputSub;

  @override
  String get id => '${_session.id}:$_portId';

  @override
  Buffer get buffer => _session.terminal.buffer;

  @override
  int get cols => _session.cols;

  @override
  int get rows => _session.rows;

  @override
  (int cols, int rows) get activePtySize => _session.activePtySize;

  @override
  CursorStateData get cursor {
    final vt = _session.terminal;
    return CursorStateData(
      x: vt.cursorX.clamp(0, vt.width - 1),
      y: vt.cursorY.clamp(0, vt.height - 1),
      visible: vt.cursorVisible,
      shape: vt.cursorShape,
    );
  }

  @override
  TerminalPortModes get modes {
    final vt = _session.terminal;
    return TerminalPortModes(
      mouseTracking: vt.mouseTrackingEnabled,
      sgrMouse: vt.sgrMouseMode,
      sgrPixelsMouse: vt.sgrPixelsMouseMode,
      bracketedPaste: vt.bracketedPasteMode,
      altScreen: vt.isUsingAlternateScreen,
      appCursorKeys: vt.applicationCursorKeys,
      alternateScroll: vt.alternateScrollMode,
      focusReporting: vt.focusReportingEnabled,
      kittyKeyboardFlags: vt.kittyKeyboardFlags,
    );
  }

  @override
  ScrollbackWindowData get scrollbackWindow {
    final sb = _session.terminal.scrollback;
    return (
      clearSeq: sb.clearSeq,
      oldestLine: sb.oldestLine,
      totalLines: sb.totalLines,
    );
  }

  @override
  String get windowTitle => _session.terminal.windowTitle;

  @override
  String? get workingDirectory => _session.terminal.workingDirectory;

  @override
  Future<int> get exitCode => _session.exitCode;

  void _dispatchChange() {
    if (_disposed) return;
    for (final listener in List.of(_changeListeners)) {
      PtyRouterSession._invokeIsolated(listener);
    }
  }

  void _dispatchTitle(String title) {
    if (_disposed) return;
    for (final listener in List.of(_titleListeners)) {
      PtyRouterSession._invokeIsolated(() => listener(title));
    }
  }

  void _dispatchBell() {
    if (_disposed) return;
    for (final listener in List.of(_bellListeners)) {
      PtyRouterSession._invokeIsolated(listener);
    }
  }

  void _dispatchAudio(TerminalAudioEvent event) {
    if (_disposed) return;
    for (final listener in List.of(_audioListeners)) {
      PtyRouterSession._invokeIsolated(() => listener(event));
    }
  }

  void _dispatchClipboard(String selection, String text) {
    if (_disposed) return;
    for (final listener in List.of(_clipboardListeners)) {
      PtyRouterSession._invokeIsolated(() => listener(selection, text));
    }
  }

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
    if (_disposed || _session.isDisposed || utf8Bytes.isEmpty) return;
    _inputPipe.sink.add(Uint8List.fromList(utf8Bytes));
  }

  @override
  void setViewportSize(
    int cols,
    int rows, {
    int cellPixelWidth = 0,
    int cellPixelHeight = 0,
  }) {
    if (_disposed) return;
    _session.setEndpointViewport(
      _endpointKey,
      cols,
      rows,
      cellPixelWidth: cellPixelWidth,
      cellPixelHeight: cellPixelHeight,
      isPrimary: _isPrimary,
    );
  }

  @override
  List<ScrollbackLine?> readScrollbackSlice(int startLine, int count) =>
      _session.readScrollbackSlice(startLine, count);

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _session._removePort(_portId, this);
    _changeListeners.clear();
    _titleListeners.clear();
    _bellListeners.clear();
    _audioListeners.clear();
    _clipboardListeners.clear();
    _session.removeEndpointViewport(_endpointKey);
    await _routerInputSub.cancel();
    await _inputPipe.close();
    await _routerInputPipe.close();
  }
}
