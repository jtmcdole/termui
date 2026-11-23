import 'dart:async';
import 'dart:typed_data';

import 'package:stream_channel/stream_channel.dart';
import 'package:termui_cast_protocol/termui_cast_protocol.dart';

import 'session_registry.dart';

enum _ConnPhase { awaitingAuth, authenticated, closed }

/// Attaches binary `StreamChannel<Uint8List>` peers to a [SessionRegistry].
final class WsRelayHandler {
  /// Default maximum concurrent unauthenticated WebSocket connections.
  static const int defaultMaxPendingAuth = 32;

  /// Default maximum total concurrent WebSocket peer connections.
  static const int defaultMaxTotalPeers = 256;

  /// Backing stateless session registry.
  final SessionRegistry registry;

  /// Bearer-token verifier for caster and client roles.
  final TokenAuthenticator authenticator;

  /// Deadline for receiving the initial binary `AuthFrame`.
  final Duration authTimeout;

  /// Maximum concurrent peers awaiting their initial `AuthFrame`.
  final int maxPendingAuth;

  /// Maximum total concurrent peers (pending auth + authenticated).
  final int maxTotalPeers;

  /// Whether this relay advertises and forwards capability-negotiated `0x1C` shader frames.
  final bool enableShaderFrames;

  /// Optional diagnostic log callback for defensive error reporting.
  final void Function(String message)? onLog;

  final Set<_RelayPeerSession> _sessions = {};
  int _reservedUpgrades = 0;

  /// Creates a WebSocket relay channel handler.
  WsRelayHandler({
    required this.registry,
    required this.authenticator,
    this.authTimeout = const Duration(seconds: 2),
    this.maxPendingAuth = defaultMaxPendingAuth,
    this.maxTotalPeers = defaultMaxTotalPeers,
    this.enableShaderFrames = true,
    this.onLog,
  });

  /// Number of currently attached peers awaiting authentication.
  int get pendingAuthCount {
    var count = 0;
    for (final session in _sessions) {
      if (!session.isAuthenticated) count++;
    }
    return count;
  }

  /// Total number of currently attached peers.
  int get totalPeerCount => _sessions.length;

  /// Whether the relay has capacity to accept a new WebSocket upgrade.
  bool get canAcceptUpgrade =>
      totalPeerCount + _reservedUpgrades < maxTotalPeers;

  /// Atomically reserves one pre-upgrade peer slot if below [maxTotalPeers].
  bool tryReserveUpgrade() {
    if (!canAcceptUpgrade) return false;
    _reservedUpgrades++;
    return true;
  }

  /// Releases a slot previously acquired with [tryReserveUpgrade].
  void releaseUpgradeReservation() {
    if (_reservedUpgrades > 0) _reservedUpgrades--;
  }

  /// Attaches an incoming caster binary frame channel.
  void attachCasterChannel(
    StreamChannel<Uint8List> channel, {
    Future<void> Function(int code, String reason)? closeWithCode,
  }) {
    _attachPeer(role: .caster, channel: channel, closeWithCode: closeWithCode);
  }

  /// Attaches an incoming client viewer binary frame channel.
  void attachClientChannel(
    StreamChannel<Uint8List> channel, {
    Future<void> Function(int code, String reason)? closeWithCode,
  }) {
    _attachPeer(role: .client, channel: channel, closeWithCode: closeWithCode);
  }

  /// Closes all currently attached peer sessions.
  Future<void> close() async {
    final active = [..._sessions];
    _sessions.clear();
    await [for (final session in active) session.close()].wait;
  }

  void _attachPeer({
    required CastRole role,
    required StreamChannel<Uint8List> channel,
    required Future<void> Function(int code, String reason)? closeWithCode,
  }) {
    _evictOldestPendingAuthIfNeeded();
    late final _RelayPeerSession session;
    session = _RelayPeerSession(
      role: role,
      channel: channel,
      closeWithCode: closeWithCode,
      registry: registry,
      authenticator: authenticator,
      authTimeout: authTimeout,
      enableShaderFrames: enableShaderFrames,
      onLog: onLog,
      onTerminated: () => _sessions.remove(session),
    );
    _sessions.add(session);
    session.start();
  }

  _RelayPeerSession? _firstPendingAuthSession() {
    for (final session in _sessions) {
      if (!session.isAuthenticated) return session;
    }
    return null;
  }

  void _evictOldestPendingAuthIfNeeded() {
    if (maxPendingAuth <= 0) return;
    while (pendingAuthCount >= maxPendingAuth) {
      final oldest = _firstPendingAuthSession();
      if (oldest == null) break;
      oldest.evictPendingAuth();
    }
  }
}

final class _RelayPeerSession {
  final CastRole role;
  final StreamChannel<Uint8List> channel;
  final Future<void> Function(int code, String reason)? closeWithCode;
  final SessionRegistry registry;
  final TokenAuthenticator authenticator;
  final Duration authTimeout;
  final bool enableShaderFrames;
  final void Function(String message)? onLog;
  final void Function() onTerminated;

  _ConnPhase _phase = _ConnPhase.awaitingAuth;
  StreamSubscription<Uint8List>? _sub;
  Timer? _authTimer;
  CasterPeer? _casterPeer;
  ClientPeer? _clientPeer;
  bool isAuthenticated = false;
  bool _terminated = false;

  _RelayPeerSession({
    required this.role,
    required this.channel,
    required this.closeWithCode,
    required this.registry,
    required this.authenticator,
    required this.authTimeout,
    required this.enableShaderFrames,
    required this.onLog,
    required this.onTerminated,
  });

  void start() {
    _authTimer = Timer(authTimeout, _onAuthTimeout);
    _sub = channel.stream.listen(
      _onFrame,
      onError: (Object error) {
        onLog?.call('Relay ${role.name} stream error: $error');
        unawaited(_rejectProtocolViolation());
      },
      onDone: _cleanup,
    );
  }

  void _onFrame(Uint8List bytes) {
    switch (_phase) {
      case .awaitingAuth:
        if (_verifyInitialAuth(bytes)) {
          _phase = .authenticated;
          _onAuthenticated();
        }
      case .authenticated:
        _onAuthenticatedFrame(bytes);
      case .closed:
        return;
    }
  }

  Future<void> close() async {
    _cleanup(closeSink: false);
    final closer = closeWithCode;
    if (closer != null) {
      await closer(1001, 'Server shutting down').catchError((Object _) {});
    } else {
      unawaited(channel.sink.close().catchError((Object _) {}));
    }
  }

  bool _verifyInitialAuth(Uint8List bytes) {
    if (_terminated || _phase != .awaitingAuth) return false;
    _authTimer?.cancel();
    _authTimer = null;
    try {
      final decoded = BufferFrameCodec.decode(bytes);
      if (decoded is! AuthFrame || decoded.role != role) {
        unawaited(
          _rejectAndClose('auth_role', 'Expected ${role.name} AuthFrame'),
        );
        return false;
      }
      if (!authenticator.verify(role, decoded.token)) {
        unawaited(_rejectAndClose('auth_failed', 'Invalid bearer token'));
        return false;
      }
      return true;
    } on FormatException catch (e) {
      unawaited(_rejectAndClose('bad_auth', e.message));
      return false;
    }
  }

  void _onAuthenticated() {
    if (_terminated) return;
    isAuthenticated = true;
    final accepted = AuthAcceptedFrame(
      role: role,
      shaderFrames: enableShaderFrames,
    );
    if (role == .caster) {
      _casterPeer = registry.registerCasterPeer(
        sink: channel.sink,
        closeWithCode: closeWithCode,
      )..sendMessage(accepted);
    } else {
      _clientPeer =
          registry.registerClientPeer(
              sink: channel.sink,
              closeWithCode: closeWithCode,
            )
            ..sendMessage(accepted)
            ..sendMessage(SessionDirectoryFrame(sessions: registry.sessions));
    }
  }

  void _onAuthenticatedFrame(Uint8List bytes) {
    if (_terminated || _phase != .authenticated) return;
    try {
      if (role == .caster) {
        _dispatchCasterFrame(bytes);
      } else {
        _dispatchClientFrame(bytes);
      }
    } on Object catch (error) {
      onLog?.call('Relay ${role.name} frame error: $error');
      unawaited(_rejectProtocolViolation());
    }
  }

  void _dispatchCasterFrame(Uint8List rawBytes) {
    final caster = _casterPeer;
    if (caster == null) return;
    // Fast zero-allocation path for BufferSnapshotFrame (0x09), BufferDeltaFrame (0x0A),
    // ScrollbackChunkFrame (0x11), BellFrame (0x18), AudioFrame (0x19), and KittyImageChunkFrame (0x1B).
    if (_tryForwardRawCasterFrame(caster, rawBytes)) return;
    switch (BufferFrameCodec.decode(rawBytes)) {
      case RegisterSessionFrame frame:
        registry.registerSession(caster, frame);
      case SessionClosedFrame(:final exitCode, :final reason):
        registry.closeCasterSession(caster, exitCode, reason: reason);
      case ShellTitleFrame frame:
        if (!registry.updateCasterShellTitle(caster, frame)) {
          throw const ProtocolFormatException(
            'Invalid caster shell title frame',
          );
        }
      case ClipboardFrame frame:
        if (!registry.forwardCasterClipboard(
          caster,
          frame,
          rawBytes: rawBytes,
        )) {
          throw const ProtocolFormatException('Invalid caster clipboard frame');
        }
      case FileUploadAckFrame frame:
        if (!registry.forwardCasterFileUploadAck(caster, frame)) {
          throw const ProtocolFormatException('Invalid caster file upload ack');
        }
      default:
        onLog?.call('Unexpected frame from caster');
    }
  }

  bool _tryForwardRawCasterFrame(CasterPeer caster, Uint8List rawBytes) {
    if (rawBytes.length < 2 ||
        rawBytes[0] != BufferFrameCodec.protocolVersion) {
      return false;
    }
    return switch (rawBytes[1]) {
      0x09 || 0x0A => _requireForwarded(
        registry.forwardCasterBufferBytes(caster, rawBytes),
        'Invalid caster buffer frame',
      ),
      0x11 => _requireForwarded(
        registry.forwardCasterScrollbackChunkBytes(
          caster,
          rawBytes,
          rewriteInPlace: true,
        ),
        'Invalid caster scrollback chunk',
      ),
      0x18 => _requireForwarded(
        registry.forwardCasterBellBytes(caster, rawBytes),
        'Invalid caster bell frame',
      ),
      0x19 => _requireForwarded(
        registry.forwardCasterAudioBytes(caster, rawBytes),
        'Invalid caster audio frame',
      ),
      0x1B => _requireForwarded(
        registry.forwardCasterKittyChunkBytes(caster, rawBytes),
        'Invalid caster Kitty chunk',
      ),
      0x1C => _handleCasterShaderBytes(caster, rawBytes),
      _ => false,
    };
  }

  bool _handleCasterShaderBytes(CasterPeer caster, Uint8List rawBytes) {
    if (!enableShaderFrames) {
      if (rawBytes.length > BufferFrameCodec.maxShaderFrameBytes) {
        throw const ProtocolFormatException('Oversized caster shader frame');
      }
      return true;
    }
    return _requireForwarded(
      registry.forwardCasterShaderBytes(caster, rawBytes),
      'Invalid caster shader frame',
    );
  }

  static bool _requireForwarded(bool ok, String message) {
    if (!ok) throw ProtocolFormatException(message);
    return true;
  }

  void _dispatchClientFrame(Uint8List rawBytes) {
    final client = _clientPeer;
    if (client == null) return;
    switch (BufferFrameCodec.decode(rawBytes)) {
      case SubscribeSessionFrame frame:
        registry.subscribeClient(client, frame);
      case UnsubscribeSessionFrame(:final sessionId):
        registry.unsubscribeClient(client, sessionId);
      case InputFrame frame:
        registry.forwardClientInput(client, frame);
      case ResizeFrame frame:
        registry.forwardClientResize(client, frame);
      case RequestKeyframeFrame(:final sessionId):
        registry.forwardKeyframeRequest(client, sessionId);
      case RequestScrollbackFrame frame:
        registry.forwardScrollbackRequest(client, frame);
      case FileUploadStartFrame frame:
        registry.forwardFileUploadStart(client, frame);
      case FileUploadChunkFrame frame:
        registry.forwardFileUploadChunk(client, frame);
      case FileUploadEndFrame frame:
        registry.forwardFileUploadEnd(client, frame);
      case RenameSessionFrame frame:
        registry.renameSession(client, frame);
      case SpawnSessionFrame frame:
        registry.forwardClientSpawnSession(client, frame);
      case AudioWaveformReplyFrame frame:
        registry.forwardClientWaveformReply(client, frame, rawBytes: rawBytes);
      default:
        onLog?.call('Unexpected frame from client');
    }
  }

  void _onAuthTimeout() {
    if (_phase != .awaitingAuth) return;
    unawaited(_rejectAndClose('auth_timeout', 'Authentication timed out'));
  }

  void evictPendingAuth() {
    unawaited(
      _rejectAndClose('auth_busy', 'Evicted by newer pending connection'),
    );
  }

  Future<void> _rejectAndClose(String code, String message) async {
    if (_terminated) return;
    _terminated = true;
    _phase = .closed;
    onTerminated();
    _authTimer?.cancel();
    _authTimer = null;
    final sub = _sub;
    _sub = null;
    unawaited(sub?.cancel());
    try {
      channel.sink.add(
        BufferFrameCodec.encode(ErrorFrame(code: code, message: message)),
      );
    } on Object catch (_) {}
    final closer = closeWithCode;
    if (closer != null) {
      await closer(1008, message).catchError((Object _) {});
    } else {
      await channel.sink.close().catchError((Object _) {});
    }
  }

  Future<void> _rejectProtocolViolation() async {
    _cleanup(closeSink: false);
    final closer = closeWithCode;
    if (closer != null) {
      await closer(1008, 'Protocol violation').catchError((Object _) {});
    } else {
      unawaited(channel.sink.close().catchError((Object _) {}));
    }
  }

  void _cleanup({bool closeSink = true}) {
    if (_terminated) return;
    _terminated = true;
    _phase = .closed;
    onTerminated();
    _authTimer?.cancel();
    _authTimer = null;
    final sub = _sub;
    _sub = null;
    unawaited(sub?.cancel());
    final caster = _casterPeer;
    if (caster != null) registry.detachCasterPeer(caster, closeSink: closeSink);
    final client = _clientPeer;
    if (client != null) registry.detachClientPeer(client, closeSink: closeSink);
  }
}
