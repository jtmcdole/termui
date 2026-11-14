import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:clock/clock.dart';
import 'package:termui_cast_protocol/termui_cast_protocol.dart';
import 'package:termui_cast_protocol/termui_cast_protocol_io.dart';

import 'server_config.dart';
import 'session_registry.dart';
import 'static_web_handler.dart';
import 'ws_relay_handler.dart';

/// Running HTTP / HTTPS WebSocket relay and optional static web server instance.
final class CastServer {
  /// Active startup configuration.
  final ServerConfig config;

  /// Backing stateless session registry.
  final SessionRegistry registry;

  /// Channel relay handler attached to `/v1/caster` and `/v1/client`.
  final WsRelayHandler handler;

  final HttpServer _httpServer;
  final StaticWebHandler? _staticHandler;
  late final StreamSubscription<HttpRequest> _requestSub;

  CastServer._({
    required this.config,
    required this.registry,
    required this.handler,
    required HttpServer httpServer,
    StaticWebHandler? staticHandler,
  }) : _httpServer = httpServer,
       _staticHandler = staticHandler {
    _requestSub = _httpServer.listen(
      _handleHttpRequest,
      onError: (Object error) => handler.onLog?.call('HTTP error: $error'),
    );
  }

  /// Bound TCP port.
  int get port => _httpServer.port;

  /// WebSocket URI for caster peers (`/v1/caster`).
  Uri get casterUri => _endpointUri('/v1/caster');

  /// WebSocket URI for viewer client peers (`/v1/client`).
  Uri get clientUri => _endpointUri('/v1/client');

  /// Binds an HTTP or HTTPS server according to [config].
  static Future<CastServer> bind(
    ServerConfig config, {
    Clock clock = const Clock(),
    Duration scrollbackRequestTimeout =
        SessionRegistry.defaultScrollbackRequestTimeout,
    int maxPendingAuth = WsRelayHandler.defaultMaxPendingAuth,
    int maxTotalPeers = WsRelayHandler.defaultMaxTotalPeers,
    void Function(String message)? onLog,
  }) async {
    final staticHandler = config.webRoot == null
        ? null
        : StaticWebHandler(config.webRoot!);
    final httpServer = await _bindHttpServer(config);
    final registry = SessionRegistry(
      clock: clock,
      scrollbackRequestTimeout: scrollbackRequestTimeout,
    );
    final authenticator = TokenAuthenticator(
      casterToken: config.casterToken,
      clientToken: config.clientToken,
    );
    final handler = WsRelayHandler(
      registry: registry,
      authenticator: authenticator,
      authTimeout: config.authTimeout,
      maxPendingAuth: maxPendingAuth,
      maxTotalPeers: maxTotalPeers,
      onLog: onLog,
    );
    return CastServer._(
      config: config,
      registry: registry,
      handler: handler,
      httpServer: httpServer,
      staticHandler: staticHandler,
    );
  }

  /// Gracefully closes the HTTP listener and all active WebSocket peers.
  Future<void> close() async {
    await _requestSub.cancel();
    await [handler.close(), registry.close()].wait;
    await _httpServer.close(force: true);
  }

  Uri _endpointUri(String path) {
    final rawHost = _httpServer.address.address;
    final connectHost = switch (rawHost) {
      '0.0.0.0' => '127.0.0.1',
      '::' => '::1',
      _ => rawHost,
    };
    return Uri(scheme: 'ws', host: connectHost, port: port, path: path);
  }

  Future<void> _handleHttpRequest(HttpRequest request) async {
    try {
      final path = request.uri.path;
      if (await _handleHealthOrProbeRequest(request, path)) return;

      if (path == '/v1/caster' || path == '/v1/client') {
        await _handleWebSocketUpgrade(request, path);
        return;
      }

      final staticHandler = _staticHandler;
      if (staticHandler != null && !path.startsWith('/v1/')) {
        await staticHandler.handle(request);
        return;
      }

      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
    } on Object catch (error) {
      handler.onLog?.call('HTTP error: $error');
    }
  }

  Future<bool> _handleHealthOrProbeRequest(
    HttpRequest request,
    String path,
  ) async {
    final revision = config.revision;
    if (path == '/healthz' &&
        (request.method == 'GET' || request.method == 'HEAD')) {
      request.response
        ..statusCode = HttpStatus.ok
        ..headers.set(HttpHeaders.cacheControlHeader, 'no-store')
        ..headers.contentType = ContentType.text
        ..headers.contentLength = 3;
      if (revision != null) {
        request.response.headers.set(castRevisionHeader, revision);
      }
      if (request.method != 'HEAD') {
        request.response.add(utf8.encode('ok\n'));
      }
      await request.response.close();
      return true;
    }

    if ((path == '/v1/caster' || path == '/v1/client') &&
        request.method == 'HEAD' &&
        !WebSocketTransformer.isUpgradeRequest(request)) {
      request.response
        ..statusCode = HttpStatus.ok
        ..headers.set(HttpHeaders.cacheControlHeader, 'no-store')
        ..headers.contentLength = 0;
      if (revision != null) {
        request.response.headers.set(castRevisionHeader, revision);
      }
      await request.response.close();
      return true;
    }
    return false;
  }

  Future<void> _handleWebSocketUpgrade(HttpRequest request, String path) async {
    if (!WebSocketTransformer.isUpgradeRequest(request)) {
      request.response.statusCode = HttpStatus.badRequest;
      await request.response.close();
      return;
    }
    if (!config.isOriginAllowed(
      request.headers['origin'],
      requestHostHeader: request.headers.value(HttpHeaders.hostHeader),
      forwardedProtoHeader: request.headers.value('x-forwarded-proto'),
    )) {
      handler.onLog?.call('Rejected cross-origin WebSocket upgrade on $path');
      request.response.statusCode = HttpStatus.forbidden;
      await request.response.close();
      return;
    }
    if (!handler.canAcceptUpgrade) {
      handler.onLog?.call('Rejected WebSocket upgrade on $path: at capacity');
      request.response.statusCode = HttpStatus.serviceUnavailable;
      await request.response.close();
      return;
    }

    try {
      final revision = config.revision;
      if (revision != null) {
        request.response.headers.set(castRevisionHeader, revision);
      }
      final (:channel, :closeWithCode) = await upgradeCastWebSocket(request);
      if (path == '/v1/caster') {
        handler.attachCasterChannel(channel, closeWithCode: closeWithCode);
      } else {
        handler.attachClientChannel(channel, closeWithCode: closeWithCode);
      }
    } on Object catch (error) {
      handler.onLog?.call('WebSocket upgrade failed on $path: $error');
    }
  }

  static Future<HttpServer> _bindHttpServer(ServerConfig config) =>
      HttpServer.bind(config.host, config.port);
}
