import 'dart:async';
import 'dart:typed_data';

import 'package:stream_channel/stream_channel.dart';
import 'package:termui_cast_protocol/termui_cast_protocol.dart';

import '../models.dart';
import 'ws_connector_stub.dart' if (dart.library.io) 'ws_connector_io.dart';

/// Factory opening a binary `StreamChannel<Uint8List>` for a client viewer.
typedef ClientChannelFactory = Future<StreamChannel<Uint8List>> Function();

/// Binary WebSocket transport authenticating as a [CastRole.client] peer.
final class WsClientTransport {
  /// Default local relay server viewer endpoint.
  static final Uri defaultServerUri = Uri.parse(defaultClientServerUrl);

  /// Target `/v1/client` WebSocket URI.
  final Uri serverUri;

  /// Bearer token sent inside the initial binary `AuthFrame`.
  final String token;

  /// Optional Cloud Run IAP bearer token provider (`dart:io` `wss://` only).
  final IapTokenProvider? iapTokenProvider;

  final ClientChannelFactory? _customChannelFactory;
  final ClientChannelFactory _channelFactory;
  final StreamController<CastMessage> _messages =
      StreamController<CastMessage>.broadcast();
  final StreamController<SessionId> _corruptSessionFrames =
      StreamController<SessionId>.broadcast();
  final StreamController<void> _disconnects =
      StreamController<void>.broadcast();

  StreamChannel<Uint8List>? _channel;
  StreamSubscription<Uint8List>? _sub;
  int _rxBytes = 0;
  int _txBytes = 0;
  bool _connecting = false;
  bool _closed = false;

  /// Creates a client WebSocket transport.
  factory WsClientTransport({
    Uri? serverUri,
    String token = '',
    IapTokenProvider? iapTokenProvider,
    ClientChannelFactory? channelFactory,
  }) {
    final resolvedUri = _validateServerUri(serverUri);
    if (iapTokenProvider != null && resolvedUri.scheme != 'wss') {
      throw const FormatException(
        'Cloud Run IAP authentication requires a wss:// server URI.',
      );
    }
    return WsClientTransport._(
      serverUri: resolvedUri,
      token: token,
      iapTokenProvider: iapTokenProvider,
      customChannelFactory: channelFactory,
      channelFactory:
          channelFactory ??
          (() => openPlatformClientWebSocket(
            resolvedUri,
            iapTokenProvider: iapTokenProvider,
          )),
    );
  }

  WsClientTransport._({
    required this.serverUri,
    required this.token,
    required this.iapTokenProvider,
    required ClientChannelFactory? customChannelFactory,
    required ClientChannelFactory channelFactory,
  }) : _customChannelFactory = customChannelFactory,
       _channelFactory = channelFactory;

  /// Creates a fresh transport targeting [endpoint], preserving any injected
  /// channel factory seam or compatible `wss://` IAP signer.
  WsClientTransport copyWithEndpoint(CastEndpoint endpoint) {
    final resolvedUri = _validateServerUri(endpoint.serverUri);
    final preservedIapProvider =
        iapTokenProvider != null &&
            resolvedUri.scheme == 'wss' &&
            serverUri.scheme == 'wss' &&
            TokenAuthenticator.iapAudienceForWebSocketUri(resolvedUri) ==
                TokenAuthenticator.iapAudienceForWebSocketUri(serverUri)
        ? iapTokenProvider
        : null;
    final customFactory = _customChannelFactory;
    return WsClientTransport._(
      serverUri: resolvedUri,
      token: endpoint.token,
      iapTokenProvider: preservedIapProvider,
      customChannelFactory: customFactory,
      channelFactory:
          customFactory ??
          (() => openPlatformClientWebSocket(
            resolvedUri,
            iapTokenProvider: preservedIapProvider,
          )),
    );
  }

  static Uri _validateServerUri(Uri? uri) {
    if (uri == null) return defaultServerUri;
    if ((uri.scheme != 'ws' && uri.scheme != 'wss') || uri.host.isEmpty) {
      throw FormatException(
        'Expected ws:// or wss:// URL with a non-empty host, got "$uri".',
      );
    }
    if (uri.userInfo.isNotEmpty) {
      throw const FormatException(
        'Relay server URI must not contain userInfo credentials.',
      );
    }
    return uri;
  }

  /// Decoded protocol messages arriving from the relay server.
  Stream<CastMessage> get messages => _messages.stream;

  /// Session IDs of inbound compressed snapshot/delta/scrollback frames whose
  /// payload failed decompression or validation after their outer header was
  /// parsed, allowing the session to recover via `RequestKeyframeFrame`
  /// without tearing down the WebSocket.
  Stream<SessionId> get corruptSessionFrames => _corruptSessionFrames.stream;

  /// Emits whenever an established channel closes unexpectedly prior to [close].
  Stream<void> get disconnects => _disconnects.stream;

  /// Whether an underlying channel is currently open.
  bool get isConnected => _channel != null && !_closed;

  /// Cumulative inbound wire bytes decoded by this transport instance.
  int get rxBytes => _rxBytes;

  /// Cumulative outbound wire bytes encoded and written by this transport instance.
  int get txBytes => _txBytes;

  /// Opens the transport channel and sends the initial `AuthFrame`.
  Future<void> connect() async {
    if (_closed || _channel != null || _connecting) return;
    _connecting = true;
    final StreamChannel<Uint8List> channel;
    try {
      channel = await _channelFactory();
    } finally {
      _connecting = false;
    }
    if (_closed) {
      unawaited(channel.sink.close().catchError((Object _) {}));
      return;
    }
    _channel = channel;
    _sub = channel.stream.listen(
      _onRawFrame,
      onError: (Object _) => _handleChannelClosed(),
      onDone: _handleChannelClosed,
    );
    send(AuthFrame(role: .client, token: token));
  }

  void _onRawFrame(Uint8List raw) {
    if (_closed) return;
    try {
      final decoded = BufferFrameCodec.decode(raw);
      _rxBytes += raw.length;
      _messages.add(decoded);
    } on CorruptAudioFrameException catch (_) {
      _rxBytes += raw.length;
    } on CorruptSessionFrameException catch (e) {
      _rxBytes += raw.length;
      _corruptSessionFrames.add(e.sessionId);
    } on FormatException catch (_) {
      _handleChannelClosed();
    }
  }

  void _handleChannelClosed() {
    final chan = _channel;
    final sub = _sub;
    _channel = null;
    _sub = null;
    if (sub != null) unawaited(sub.cancel());
    if (chan != null) {
      unawaited(chan.sink.close().catchError((Object _) {}));
      if (!_closed) {
        _disconnects.add(null);
      }
    }
  }

  /// Encodes and transmits [message] if connected.
  void send(CastMessage message) {
    final chan = _channel;
    if (_closed || chan == null) return;
    try {
      final encoded = BufferFrameCodec.encode(message);
      chan.sink.add(encoded);
      _txBytes += encoded.length;
    } on Object catch (_) {
      _handleChannelClosed();
    }
  }

  /// Closes the underlying channel and streams.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _handleChannelClosed();
    await [
      _messages.close(),
      _corruptSessionFrames.close(),
      _disconnects.close(),
    ].wait;
  }
}
