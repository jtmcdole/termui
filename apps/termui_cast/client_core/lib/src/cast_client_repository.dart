import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:clock/clock.dart' as clock_pkg;
import 'package:core_bus/core_bus.dart';
import 'package:termui_cast_protocol/termui_cast_protocol.dart';

import 'models.dart';
import 'remote_terminal_port.dart';
import 'scrollback_page_cache.dart';
import 'session_slot.dart';
import 'transport/ws_client_transport.dart';

/// Factory building a new [WsClientTransport] when reconnecting to a new [CastEndpoint].
typedef ClientTransportFactory =
    WsClientTransport Function(CastEndpoint endpoint);

/// Broadcast event carrying each decoded [CastMessage] from the relay server.
const Event<CastMessage> clientMessageReceivedEvent =
    Event<CastMessage>.broadcast(name: 'client.message');

/// Broadcast event emitted when a dial attempt begins for the target [Uri].
const Event<Uri> clientConnectingEvent = Event<Uri>.broadcast(
  name: 'client.connecting',
);

/// Broadcast event emitted when a dial attempt fails before establishing a channel.
const Event<bool> clientConnectFailedEvent = Event<bool>.broadcast(
  name: 'client.connectFailed',
);

/// Broadcast event emitted when a compressed session frame payload fails
/// decompression/validation after its outer header is parsed.
const Event<SessionId> clientCorruptSessionFrameEvent =
    Event<SessionId>.broadcast(name: 'client.corruptSessionFrame');

/// Broadcast event emitted when the client transport disconnects.
const Event<bool> clientDisconnectedEvent = Event<bool>.broadcast(
  name: 'client.disconnected',
);

/// Pure-Dart repository demuxing [WsClientTransport] frames onto an [EventBus]
/// with jittered exponential-backoff reconnect on unexpected drops.
final class CastClientRepository {
  /// Event bus receiving incoming server events.
  final EventBus bus;

  /// Whether unexpected transport drops schedule automatic reconnects.
  final bool enableReconnect;

  /// Whether subscriptions opt into capability-negotiated `0x1C` shader frames
  /// when advertised by the relay's [AuthAcceptedFrame].
  final bool enableShaderFrames;

  /// Optional observer notified when a transport connect attempt throws.
  final void Function(Object error)? onConnectError;

  final ClientTransportFactory? _transportFactory;
  final bool _ownsBus;
  final Random _random;
  final clock_pkg.Clock _clock;
  final Duration _baseReconnectDelay;
  final Duration _maxReconnectDelay;
  final Duration _scrollbackRequestTimeout;

  static final clock_pkg.Clock _zoneClock = clock_pkg.Clock(
    () => clock_pkg.clock.now(),
  );

  final StreamController<BellFrame> _bellFrames =
      StreamController<BellFrame>.broadcast();
  final StreamController<AudioFrame> _audioFrames =
      StreamController<AudioFrame>.broadcast();
  final StreamController<ShaderFrame> _shaderFrames =
      StreamController<ShaderFrame>.broadcast();
  final StreamController<ShellTitleFrame> _shellTitleFrames =
      StreamController<ShellTitleFrame>.broadcast();
  final Map<SessionId, _AttachedPortGroup> _attachedPortGroups =
      <SessionId, _AttachedPortGroup>{};
  final Map<SessionId, SessionSummary> _latestDirectorySummaries =
      <SessionId, SessionSummary>{};

  WsClientTransport _transport;
  StreamSubscription<CastMessage>? _messageSub;
  StreamSubscription<SessionId>? _corruptFrameSub;
  StreamSubscription<void>? _disconnectSub;
  Timer? _reconnectTimer;
  int _reconnectAttempt = 0;
  int _epoch = 0;
  int _priorRxBytes = 0;
  int _priorTxBytes = 0;
  int _nextPortId = 1;
  bool _authenticatedOnTransport = false;
  bool _hasReceivedDirectory = false;
  bool _relaySupportsShaderFrames = false;
  bool _fatalAuthError = false;
  bool _disposed = false;

  /// Creates a client repository backed by [transport].
  CastClientRepository({
    required WsClientTransport transport,
    ClientTransportFactory? transportFactory,
    EventBus? bus,
    this.enableReconnect = true,
    this.enableShaderFrames = true,
    this.onConnectError,
    Random? random,
    clock_pkg.Clock? clock,
    Duration baseReconnectDelay = const Duration(milliseconds: 200),
    Duration maxReconnectDelay = const Duration(seconds: 10),
    Duration scrollbackRequestTimeout = ScrollbackPageCache.requestTimeout,
  }) : _transport = transport,
       _transportFactory = transportFactory,
       _ownsBus = bus == null,
       bus = bus ?? EventBus(),
       _random = random ?? Random(),
       _clock = clock ?? _zoneClock,
       _baseReconnectDelay = baseReconnectDelay,
       _maxReconnectDelay = maxReconnectDelay,
       _scrollbackRequestTimeout = scrollbackRequestTimeout;

  /// Broadcast stream of inbound [BellFrame] events across subscribed sessions.
  Stream<BellFrame> get bellFrames => _bellFrames.stream;

  /// Broadcast stream of inbound [AudioFrame] events across subscribed sessions.
  Stream<AudioFrame> get audioFrames => _audioFrames.stream;

  /// Broadcast stream of inbound `0x1C` [ShaderFrame] events across subscribed sessions.
  Stream<ShaderFrame> get shaderFrames => _shaderFrames.stream;

  /// Broadcast stream of inbound [ShellTitleFrame] updates across sessions.
  Stream<ShellTitleFrame> get shellTitleFrames => _shellTitleFrames.stream;

  /// Underlying active binary WebSocket client transport.
  WsClientTransport get transport => _transport;

  /// Target `/v1/client` WebSocket URI of the active transport.
  Uri get serverUri => _transport.serverUri;

  /// Bearer token configured on the active transport.
  String get token => _transport.token;

  /// Cumulative inbound wire bytes decoded across all transport epochs.
  int get totalRxBytes => _priorRxBytes + _transport.rxBytes;

  /// Cumulative outbound wire bytes sent across all transport epochs.
  int get totalTxBytes => _priorTxBytes + _transport.txBytes;

  /// Whether automatic reconnect is active (enabled and not halted by an auth error).
  bool get willAutoReconnect =>
      enableReconnect && !_fatalAuthError && !_disposed;

  /// Connects [transport] and begins publishing frames onto [bus].
  ///
  /// When [retryOnFailure] is `true`, an initial dial failure enters
  /// jittered reconnect backoff instead of throwing.
  Future<void> connect({bool retryOnFailure = false}) async {
    if (_disposed) return;
    final epoch = _epoch;
    final target = _transport;
    _attachSubscriptions();
    clientConnectingEvent.post(bus, target.serverUri);
    try {
      await target.connect();
    } on Object catch (error) {
      if (_disposed || epoch != _epoch) return;
      onConnectError?.call(error);
      clientConnectFailedEvent.post(bus, true);
      if (!retryOnFailure || !enableReconnect) rethrow;
      _scheduleReconnect();
    }
  }

  /// Replaces the active transport with [endpoint], resets fatal auth state, and connects.
  Future<void> reconnect(
    CastEndpoint endpoint, {
    bool retryOnFailure = true,
  }) async {
    if (_disposed) return;
    final epoch = ++_epoch;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _detachSubscriptions();
    final previous = _transport;
    _priorRxBytes += previous.rxBytes;
    _priorTxBytes += previous.txBytes;
    _resetAttachedPortsConnectionState();
    final nextTransport =
        _transportFactory?.call(endpoint) ??
        previous.copyWithEndpoint(endpoint);
    _transport = nextTransport;
    _reconnectAttempt = 0;
    _fatalAuthError = false;
    await previous.close();
    if (_disposed || epoch != _epoch) {
      await nextTransport.close();
      return;
    }
    await connect(retryOnFailure: retryOnFailure);
  }

  void _attachSubscriptions() {
    _messageSub ??= _transport.messages.listen(_onTransportMessage);
    _corruptFrameSub ??= _transport.corruptSessionFrames.listen(
      _onCorruptSessionFrame,
    );
    _disconnectSub ??= _transport.disconnects.listen((_) => _onDisconnected());
  }

  void _detachSubscriptions() {
    final msgSub = _messageSub;
    final corruptSub = _corruptFrameSub;
    final discSub = _disconnectSub;
    _messageSub = null;
    _corruptFrameSub = null;
    _disconnectSub = null;
    if (msgSub != null) unawaited(msgSub.cancel());
    if (corruptSub != null) unawaited(corruptSub.cancel());
    if (discSub != null) unawaited(discSub.cancel());
  }

  void _onCorruptSessionFrame(SessionId sessionId) {
    if (_disposed) return;
    if (_attachedPortGroups[sessionId] case final group?) {
      unawaited(group.slot.machine.handle(.corruptFrame));
    }
    clientCorruptSessionFrameEvent.post(bus, sessionId);
  }

  void _onTransportMessage(CastMessage message) {
    if (_disposed) return;
    if (message case AuthAcceptedFrame(:final shaderFrames)) {
      _reconnectAttempt = 0;
      _fatalAuthError = false;
      _authenticatedOnTransport = true;
      _relaySupportsShaderFrames = shaderFrames;
    } else if (message case ErrorFrame(:final code)) {
      if (isFatalAuthErrorCode(code)) {
        _fatalAuthError = true;
        _authenticatedOnTransport = false;
        _relaySupportsShaderFrames = false;
        _reconnectTimer?.cancel();
        _reconnectTimer = null;
      }
    }
    _routeStreamsAndAttachedPorts(message);
    clientMessageReceivedEvent.post(bus, message);
  }

  /// Returns `true` when [code] denotes a non-retryable authentication failure.
  static bool isFatalAuthErrorCode(String code) =>
      code == 'auth_failed' || code == 'auth_role' || code == 'bad_auth';

  void _onDisconnected() {
    if (_disposed) return;
    _resetAttachedPortsConnectionState();
    clientDisconnectedEvent.post(bus, true);
    if (enableReconnect && !_fatalAuthError) {
      _scheduleReconnect();
    }
  }

  void _scheduleReconnect() {
    if (_disposed || _fatalAuthError || _reconnectTimer != null) return;
    _reconnectAttempt++;
    final shift = (_reconnectAttempt - 1).clamp(0, 10);
    final cappedMs = min(
      _maxReconnectDelay.inMilliseconds,
      _baseReconnectDelay.inMilliseconds * (1 << shift),
    );
    final jitterFactor = 0.5 + _random.nextDouble() * 0.5;
    final delayMs = max(1, (cappedMs * jitterFactor).round());

    final epoch = _epoch;
    _reconnectTimer = Timer(
      Duration(milliseconds: delayMs),
      () => unawaited(_onReconnectTimerFired(epoch)),
    );
  }

  Future<void> _onReconnectTimerFired(int epoch) async {
    _reconnectTimer = null;
    if (_disposed || _fatalAuthError || epoch != _epoch) return;
    final target = _transport;
    clientConnectingEvent.post(bus, target.serverUri);
    try {
      await target.connect();
    } on Object catch (error) {
      if (_disposed || _fatalAuthError || epoch != _epoch) return;
      onConnectError?.call(error);
      clientConnectFailedEvent.post(bus, true);
      _scheduleReconnect();
    }
  }

  /// Subscribes to live buffer updates for [sessionId].
  void subscribe(
    SessionId sessionId, {
    int cols = 0,
    int rows = 0,
    bool? shaderFrames,
  }) {
    final hasSize = cols > 0 && rows > 0;
    final safeCols = hasSize ? cols.clamp(1, BufferFrameCodec.maxGridCols) : 0;
    final safeRows = hasSize ? rows.clamp(1, BufferFrameCodec.maxGridRows) : 0;
    final optInShaders =
        shaderFrames ?? (enableShaderFrames && _relaySupportsShaderFrames);
    _transport.send(
      SubscribeSessionFrame(
        sessionId: sessionId,
        cols: safeCols,
        rows: safeRows,
        shaderFrames: optInShaders,
      ),
    );
  }

  /// Unsubscribes from buffer updates for [sessionId].
  void unsubscribe(SessionId sessionId) {
    _transport.send(UnsubscribeSessionFrame(sessionId: sessionId));
  }

  /// Requests an immediate full [BufferSnapshotFrame] for [sessionId].
  void requestKeyframe(SessionId sessionId) {
    _transport.send(RequestKeyframeFrame(sessionId: sessionId));
  }

  /// Requests a bounded slice of primary-screen scrollback rows from the caster.
  void requestScrollback(RequestScrollbackFrame frame) {
    _transport.send(frame);
  }

  /// Sends raw input [data] to [sessionId]'s remote PTY.
  void sendInput(SessionId sessionId, Uint8List data) {
    if (data.isEmpty) return;
    _transport.send(InputFrame(sessionId: sessionId, data: data));
  }

  /// Sends a 256-sample `Float32` waveform reply for [requestId] to [sessionId]'s caster.
  void sendWaveformReply(
    SessionId sessionId,
    int requestId,
    Float32List samples,
  ) {
    if (_disposed ||
        requestId <= 0 ||
        samples.length != AudioWaveformReplyFrame.sampleCount) {
      return;
    }
    _transport.send(
      AudioWaveformReplyFrame(
        sessionId: sessionId,
        requestId: requestId,
        samples: samples,
      ),
    );
  }

  /// Sends viewport resize intent `([cols], [rows])` for [sessionId].
  void sendResize(SessionId sessionId, int cols, int rows) {
    if (cols <= 0 || rows <= 0) return;
    final safeCols = cols.clamp(1, BufferFrameCodec.maxGridCols);
    final safeRows = rows.clamp(1, BufferFrameCodec.maxGridRows);
    _transport.send(
      ResizeFrame(sessionId: sessionId, cols: safeCols, rows: safeRows),
    );
  }

  /// Opens a reference-counted [RemoteTerminalPort] viewing [sessionId].
  ///
  /// Multiple ports attached to the same [sessionId] share one synchronized
  /// [SessionSlot] and advertise the minimum `(cols, rows)` across all local
  /// panes that have reported viewport dimensions; [unsubscribe] is sent only
  /// when the last open port for [sessionId] is disposed.
  RemoteTerminalPort openTerminalPort(
    SessionId sessionId, {
    String? portId,
    int? initialCols,
    int? initialRows,
  }) {
    if (_disposed) {
      throw StateError('CastClientRepository has been disposed.');
    }
    final group = _getOrCreatePortGroup(sessionId);
    final initialSize = _normalizeViewportSize(initialCols, initialRows);
    final resolvedPortId = portId ?? 'port-${_nextPortId++}';
    final port = RemoteTerminalPort.attached(
      repository: this,
      sessionId: sessionId,
      id: '${sessionId.value}:$resolvedPortId',
      slot: group.slot,
      exitCode: group.exitCompleter.future,
      initialViewportSize: initialSize,
      onViewportChanged: (target, cols, rows) =>
          _onPortViewportChanged(sessionId, group, target, cols, rows),
      onDispose: (target) => _onPortDisposed(sessionId, group, target),
    );
    group.ports.add(port);
    if (initialSize != null) {
      group.paneViewports[port] = initialSize;
    }
    _syncGroupSubscriptionAndResize(sessionId, group);
    return port;
  }

  /// Returns the number of live attached [RemoteTerminalPort]s for [sessionId].
  int attachedPortCount(SessionId sessionId) =>
      _attachedPortGroups[sessionId]?.ports.length ?? 0;

  /// Returns the minimum reported viewport `(cols, rows)` across open ports
  /// for [sessionId], or `null` if no viewport size has been reported yet.
  ({int cols, int rows})? localMinViewportSize(SessionId sessionId) =>
      _attachedPortGroups[sessionId]?.computeMinViewport();

  /// Sends a [RenameSessionFrame] updating [sessionId]'s display title.
  void renameSession(
    SessionId sessionId,
    String title, {
    bool clearPin = false,
  }) {
    _transport.send(
      RenameSessionFrame(
        sessionId: sessionId,
        title: title,
        clearPin: clearPin,
      ),
    );
  }

  /// Sends a [FileUploadStartFrame] initiating a file transfer on [frame]'s session.
  void sendFileUploadStart(FileUploadStartFrame frame) {
    _transport.send(frame);
  }

  /// Sends a [FileUploadChunkFrame] carrying a file slice for an active transfer.
  void sendFileUploadChunk(FileUploadChunkFrame frame) {
    _transport.send(frame);
  }

  /// Sends a [FileUploadEndFrame] completing or aborting an active file transfer.
  void sendFileUploadEnd(FileUploadEndFrame frame) {
    _transport.send(frame);
  }

  /// Closes the transport and cleans up timers and bus subscriptions.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _epoch++;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _detachSubscriptions();
    _disposeAttachedPortGroups();
    await _transport.close();
    await [
      _bellFrames.close(),
      _audioFrames.close(),
      _shaderFrames.close(),
      _shellTitleFrames.close(),
    ].wait;
    if (_ownsBus) {
      await bus.reset();
    }
  }

  _AttachedPortGroup _getOrCreatePortGroup(SessionId sessionId) {
    final existing = _attachedPortGroups[sessionId];
    if (existing != null) return existing;
    late final _AttachedPortGroup group;
    final slot = SessionSlot(
      id: sessionId,
      clock: _clock,
      requestTimeout: _scrollbackRequestTimeout,
      onVisualChange: () => _dispatchVisualChange(group),
      onClearSelection: () => group.slot.selectionController.clearSelection(),
      onRequestKeyframe: () => requestKeyframe(sessionId),
      onRequestScrollback: requestScrollback,
    );
    group = _AttachedPortGroup(slot: slot);
    if (_latestDirectorySummaries[sessionId] case final summary?) {
      slot.applyDirectorySummary(summary);
    }
    _attachedPortGroups[sessionId] = group;
    return group;
  }

  ({int cols, int rows})? _normalizeViewportSize(int? cols, int? rows) {
    if (cols == null || rows == null || cols <= 0 || rows <= 0) return null;
    return (
      cols: cols.clamp(1, BufferFrameCodec.maxGridCols),
      rows: rows.clamp(1, BufferFrameCodec.maxGridRows),
    );
  }

  void _syncGroupSubscriptionAndResize(
    SessionId sessionId,
    _AttachedPortGroup group,
  ) {
    final minSize = group.computeMinViewport();
    final wantShaders = enableShaderFrames && _relaySupportsShaderFrames;
    if (!group.subscribedOnTransport) {
      if (_authenticatedOnTransport && !group.slot.endedByExit) {
        group.subscribedOnTransport = true;
        group.subscribedWithShaderFrames = wantShaders;
        group.lastSentMinSize = minSize;
        if (group.slot.state == .unsubscribed) {
          unawaited(group.slot.machine.handle(.subscribe));
        }
        subscribe(
          sessionId,
          cols: minSize?.cols ?? 0,
          rows: minSize?.rows ?? 0,
          shaderFrames: wantShaders,
        );
      }
      return;
    }
    if (wantShaders && !group.subscribedWithShaderFrames) {
      group.subscribedWithShaderFrames = true;
      group.lastSentMinSize = minSize;
      subscribe(
        sessionId,
        cols: minSize?.cols ?? 0,
        rows: minSize?.rows ?? 0,
        shaderFrames: true,
      );
      return;
    }
    if (minSize != null && minSize != group.lastSentMinSize) {
      group.lastSentMinSize = minSize;
      sendResize(sessionId, minSize.cols, minSize.rows);
    }
  }

  void _onPortViewportChanged(
    SessionId sessionId,
    _AttachedPortGroup group,
    RemoteTerminalPort port,
    int cols,
    int rows,
  ) {
    if (_disposed || !group.ports.contains(port)) return;
    group.paneViewports[port] = (cols: cols, rows: rows);
    _syncGroupSubscriptionAndResize(sessionId, group);
  }

  Future<void> _onPortDisposed(
    SessionId sessionId,
    _AttachedPortGroup group,
    RemoteTerminalPort port,
  ) async {
    group.ports.remove(port);
    group.paneViewports.remove(port);
    if (_disposed) return;
    if (group.ports.isEmpty) {
      _attachedPortGroups.remove(sessionId);
      final wasSubscribed = group.subscribedOnTransport;
      group.subscribedOnTransport = false;
      if (!group.exitCompleter.isCompleted) {
        group.exitCompleter.complete(group.slot.exitCode ?? -1);
      }
      group.slot.dispose();
      if (wasSubscribed && _transport.isConnected) {
        unsubscribe(sessionId);
      }
      return;
    }
    final nextMinSize = group.computeMinViewport();
    if (nextMinSize != group.lastSentMinSize) {
      group.lastSentMinSize = nextMinSize;
      if (group.subscribedOnTransport && nextMinSize != null) {
        sendResize(sessionId, nextMinSize.cols, nextMinSize.rows);
      }
    }
  }

  void _resetAttachedPortsConnectionState() {
    _authenticatedOnTransport = false;
    _hasReceivedDirectory = false;
    _relaySupportsShaderFrames = false;
    for (final group in _attachedPortGroups.values) {
      group.subscribedOnTransport = false;
      group.subscribedWithShaderFrames = false;
      group.slot.handleSessionEnded(exited: false);
      _dispatchVisualChange(group);
    }
  }

  void _disposeAttachedPortGroups() {
    final groups = _attachedPortGroups.values.toList(growable: false);
    _attachedPortGroups.clear();
    for (final group in groups) {
      group.ports.clear();
      group.paneViewports.clear();
      if (!group.exitCompleter.isCompleted) {
        group.exitCompleter.complete(group.slot.exitCode ?? -1);
      }
      group.slot.dispose();
    }
  }

  void _resubscribeAttachedGroups() {
    for (final entry in _attachedPortGroups.entries) {
      _syncGroupSubscriptionAndResize(entry.key, entry.value);
    }
  }

  void _routeStreamsAndAttachedPorts(CastMessage message) {
    switch (message) {
      case AuthAcceptedFrame():
        _resubscribeAttachedGroups();
      case final ShellTitleFrame frame:
        _handleShellTitleFrame(frame);
      case final BellFrame frame:
        _handleBellFrame(frame);
      case final AudioFrame frame:
        _handleAudioFrame(frame);
      case final ShaderFrame frame:
        _handleShaderFrame(frame);
      case SessionDirectoryFrame(:final sessions):
        _handleDirectoryForPorts(sessions);
      case BufferSnapshotFrame(:final snapshot):
        final group = _attachedPortGroups[snapshot.sessionId];
        if (group != null) {
          unawaited(group.slot.machine.handle(.snapshot, snapshot));
        }
      case BufferDeltaFrame(:final delta):
        final group = _attachedPortGroups[delta.sessionId];
        if (group != null) {
          unawaited(group.slot.machine.handle(.delta, delta));
        }
      case final ScrollbackChunkFrame chunk:
        _attachedPortGroups[chunk.sessionId]?.slot.ingestScrollbackChunk(chunk);
      case final KittyImageChunkFrame chunk:
        _attachedPortGroups[chunk.sessionId]?.slot.ingestKittyImageChunk(chunk);
      case final ClipboardFrame frame:
        _handleClipboardForPorts(frame);
      case final SessionClosedFrame frame:
        final exited = frame.reason == .exited;
        _handleSessionEndedForPorts(
          frame.sessionId,
          exited: exited,
          exitCode: exited ? frame.exitCode : null,
        );
      default:
        break;
    }
  }

  void _handleShellTitleFrame(ShellTitleFrame frame) {
    if (!_shellTitleFrames.isClosed) {
      _shellTitleFrames.add(frame);
    }
    final group = _attachedPortGroups[frame.sessionId];
    if (group == null) return;
    final previous = group.slot.effectiveTitle;
    group.slot.applyShellTitle(frame.title);
    final next = group.slot.effectiveTitle;
    if (next != previous) {
      _dispatchTitleChange(group, next);
    }
  }

  void _handleBellFrame(BellFrame frame) {
    if (!_bellFrames.isClosed) {
      _bellFrames.add(frame);
    }
    final group = _attachedPortGroups[frame.sessionId];
    if (group == null) return;
    group.slot.recordBell();
    _dispatchBell(group);
  }

  void _handleAudioFrame(AudioFrame frame) {
    if (!_audioFrames.isClosed) {
      _audioFrames.add(frame);
    }
    final group = _attachedPortGroups[frame.sessionId];
    if (group == null) return;
    final event = toTerminalAudioEvent(frame.payload);
    for (final port in List<RemoteTerminalPort>.of(group.ports)) {
      port.dispatchAudio(event);
    }
  }

  void _handleShaderFrame(ShaderFrame frame) {
    if (!_shaderFrames.isClosed) {
      _shaderFrames.add(frame);
    }
    final group = _attachedPortGroups[frame.sessionId];
    if (group == null) return;
    final event = toTerminalShaderApcEvent(frame.payload);
    for (final port in List<RemoteTerminalPort>.of(group.ports)) {
      port.dispatchShader(event);
    }
  }

  void _handleDirectoryForPorts(List<SessionSummary> sessions) {
    _authenticatedOnTransport = true;
    final hadDirectory = _hasReceivedDirectory;
    _hasReceivedDirectory = true;
    final previousIds = _latestDirectorySummaries.keys.toSet();
    _latestDirectorySummaries.clear();
    for (final entry in sessions) {
      _latestDirectorySummaries[entry.id] = entry;
      final group = _attachedPortGroups[entry.id];
      if (group == null) continue;
      if (hadDirectory &&
          !previousIds.contains(entry.id) &&
          group.slot.state != .synchronized) {
        group.subscribedOnTransport = false;
        group.subscribedWithShaderFrames = false;
      }
      final prevTitle = group.slot.effectiveTitle;
      group.slot.applyDirectorySummary(entry);
      _dispatchVisualChange(group);
      final nextTitle = group.slot.effectiveTitle;
      if (nextTitle != prevTitle) {
        _dispatchTitleChange(group, nextTitle);
      }
    }
    _resubscribeAttachedGroups();
  }

  void _handleClipboardForPorts(ClipboardFrame frame) {
    if (frame.readBlocked || frame.text.isEmpty) return;
    final group = _attachedPortGroups[frame.sessionId];
    if (group == null) return;
    for (final port in List<RemoteTerminalPort>.of(group.ports)) {
      port.dispatchClipboard('c', frame.text);
    }
  }

  void _handleSessionEndedForPorts(
    SessionId sessionId, {
    required bool exited,
    int? exitCode,
  }) {
    final group = _attachedPortGroups[sessionId];
    if (group == null) return;
    group.subscribedOnTransport = false;
    group.subscribedWithShaderFrames = false;
    group.slot.handleSessionEnded(exited: exited, exitCode: exitCode);
    if (exited && !group.exitCompleter.isCompleted) {
      group.exitCompleter.complete(exitCode ?? 0);
    }
    _dispatchVisualChange(group);
  }

  void _dispatchVisualChange(_AttachedPortGroup group) {
    for (final port in List<RemoteTerminalPort>.of(group.ports)) {
      port.dispatchVisualChange();
    }
  }

  void _dispatchTitleChange(_AttachedPortGroup group, String title) {
    for (final port in List<RemoteTerminalPort>.of(group.ports)) {
      port.dispatchTitleChange(title);
    }
  }

  void _dispatchBell(_AttachedPortGroup group) {
    for (final port in List<RemoteTerminalPort>.of(group.ports)) {
      port.dispatchBell();
    }
  }
}

final class _AttachedPortGroup {
  final SessionSlot slot;
  final Set<RemoteTerminalPort> ports = <RemoteTerminalPort>{};
  final Map<RemoteTerminalPort, ({int cols, int rows})> paneViewports =
      <RemoteTerminalPort, ({int cols, int rows})>{};
  final Completer<int> exitCompleter = Completer<int>();

  ({int cols, int rows})? lastSentMinSize;
  bool subscribedOnTransport = false;
  bool subscribedWithShaderFrames = false;

  _AttachedPortGroup({required this.slot});

  ({int cols, int rows})? computeMinViewport() {
    if (paneViewports.isEmpty) return null;
    int? minCols;
    int? minRows;
    for (final size in paneViewports.values) {
      minCols = minCols == null ? size.cols : min(minCols, size.cols);
      minRows = minRows == null ? size.rows : min(minRows, size.rows);
    }
    if (minCols == null || minRows == null) return null;
    return (cols: minCols, rows: minRows);
  }
}
