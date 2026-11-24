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
  bool _closed = false;

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

  /// Bound interface address.
  InternetAddress get address => _httpServer.address;

  /// Bound TCP port.
  int get port => _httpServer.port;

  /// Local-connectable HTTP base URI for the server (`<basePath>/`).
  ///
  /// Wildcard bind addresses (`0.0.0.0` and `::`) are normalized to loopback
  /// (`127.0.0.1` and `::1`). Serves static web assets when [ServerConfig.webRoot]
  /// is configured; `<basePath>/healthz` is always served relative to this URI.
  Uri get httpUri => _endpointUri('http', '${config.basePath}/');

  /// Local-connectable WebSocket URI for caster peers (`<basePath>/v1/caster`).
  ///
  /// Wildcard bind addresses (`0.0.0.0` and `::`) are normalized to loopback
  /// (`127.0.0.1` and `::1`).
  Uri get casterUri => _endpointUri('ws', '${config.basePath}/v1/caster');

  /// Local-connectable WebSocket URI for viewer client peers (`<basePath>/v1/client`).
  ///
  /// Wildcard bind addresses (`0.0.0.0` and `::`) are normalized to loopback
  /// (`127.0.0.1` and `::1`).
  Uri get clientUri => _endpointUri('ws', '${config.basePath}/v1/client');

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
        : StaticWebHandler(config.webRoot!, basePath: config.basePath);
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
    _closed = true;
    await _requestSub.cancel();
    await [handler.close(), registry.close()].wait;
    await _httpServer.close(force: true);
  }

  Uri _endpointUri(String scheme, String path) {
    final bound = _httpServer.address;
    final String connectHost;
    if (bound == InternetAddress.anyIPv4) {
      connectHost = InternetAddress.loopbackIPv4.address;
    } else if (bound == InternetAddress.anyIPv6) {
      connectHost = InternetAddress.loopbackIPv6.address;
    } else {
      connectHost = bound.address;
    }
    return Uri(scheme: scheme, host: connectHost, port: port, path: path);
  }

  Future<void> _handleHttpRequest(HttpRequest request) async {
    try {
      final rawPath = request.uri.path;
      final basePath = config.basePath;
      if (basePath.isNotEmpty) {
        if (await _handleBasePathRedirect(request, rawPath, basePath)) return;
        if (rawPath != basePath && !rawPath.startsWith('$basePath/')) {
          request.response.statusCode = HttpStatus.notFound;
          await request.response.close();
          return;
        }
      }

      final routePath = basePath.isEmpty
          ? rawPath
          : rawPath.substring(basePath.length);
      if (await _handleHealthOrProbeRequest(request, routePath)) return;

      if (routePath == '/v1/caster' || routePath == '/v1/client') {
        await _handleWebSocketUpgrade(request, routePath);
        return;
      }

      final staticHandler = _staticHandler;
      if (staticHandler != null && !routePath.startsWith('/v1/')) {
        await staticHandler.handle(request);
        return;
      }

      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
    } on Object catch (error) {
      handler.onLog?.call('HTTP error: $error');
    }
  }

  Future<bool> _handleBasePathRedirect(
    HttpRequest request,
    String rawPath,
    String basePath,
  ) async {
    if (rawPath != basePath) return false;
    if (request.method != 'GET' && request.method != 'HEAD') return false;
    final location = request.uri.hasQuery
        ? '$basePath/?${request.uri.query}'
        : '$basePath/';
    request.response
      ..statusCode = HttpStatus.permanentRedirect
      ..headers.set(HttpHeaders.locationHeader, location);
    await request.response.close();
    return true;
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
    if (path == '/v1/client' && !_hasRequiredClientAuthHeader(request)) {
      handler.onLog?.call(
        'Rejected WebSocket upgrade on $path: missing required header '
        '${config.requireClientAuthHeader}',
      );
      request.response.statusCode = HttpStatus.unauthorized;
      await request.response.close();
      return;
    }
    if (_closed || !handler.tryReserveUpgrade()) {
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
      if (_closed) {
        await closeWithCode(
          1001,
          'Server shutting down',
        ).catchError((Object _) {});
        return;
      }
      if (path == '/v1/caster') {
        handler.attachCasterChannel(channel, closeWithCode: closeWithCode);
      } else {
        handler.attachClientChannel(channel, closeWithCode: closeWithCode);
      }
    } on Object catch (error) {
      handler.onLog?.call('WebSocket upgrade failed on $path: $error');
    } finally {
      handler.releaseUpgradeReservation();
    }
  }

  bool _hasRequiredClientAuthHeader(HttpRequest request) {
    final headerName = config.requireClientAuthHeader;
    if (headerName == null) return true;
    final values = request.headers[headerName];
    if (values == null || values.isEmpty) return false;
    return values.any((value) => value.trim().isNotEmpty);
  }

  static Future<HttpServer> _bindHttpServer(ServerConfig config) =>
      HttpServer.bind(config.host, config.port);
}
