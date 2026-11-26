import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show visibleForTesting;

import 'automation_models.dart';

final class _BodyParseResult {
  final Map<String, Object?>? body;
  final AutomationHttpResponse? error;
  final bool closeConnection;

  const _BodyParseResult.ok(this.body) : error = null, closeConnection = false;

  const _BodyParseResult.error(this.error, {this.closeConnection = false})
    : body = null;
}

/// Constant-time UTF-8 string comparison folding length differences without
/// early returns to prevent Bearer token timing side channels.
@visibleForTesting
bool constantTimeEquals(String a, String b) {
  final aBytes = utf8.encode(a);
  final bBytes = utf8.encode(b);
  final maxLen = aBytes.length > bBytes.length ? aBytes.length : bBytes.length;
  var diff = aBytes.length ^ bBytes.length;
  for (var i = 0; i < maxLen; i++) {
    final av = i < aBytes.length ? aBytes[i] : 0;
    final bv = i < bBytes.length ? bBytes[i] : 0;
    diff |= av ^ bv;
  }
  return diff == 0;
}

/// Desktop `dart:io` loopback-only HTTP server for the `fterm` automation
/// driver.
///
/// Enforces Host header allowlisting, `OPTIONS` rejection without CORS headers,
/// constant-time Bearer token authentication, PTY scope gating, strict JSON
/// request validation with a `256 KiB` body cap, and FIFO serialization for
/// mutating `POST` requests.
final class IoAutomationHttpServer implements AutomationHttpServerBackend {
  /// Maximum permitted HTTP `POST` request body size in bytes (`256 KiB`).
  static const int maxBodyBytes = 256 * 1024;

  static const int _maxDiscardBytes = 1024 * 1024;

  HttpServer? _server;
  StreamSubscription<HttpRequest>? _subscription;
  String _password = '';
  bool _allowPty = false;
  AutomationRequestHandler? _onRequest;
  Future<void> _mutationTail = Future<void>.value();

  /// Creates an [IoAutomationHttpServer].
  IoAutomationHttpServer();

  @override
  bool get isSupported => true;

  @override
  bool get isRunning => _server != null;

  @override
  int? get boundPort => _server?.port;

  @override
  Future<void> start({
    required int port,
    required String password,
    required bool allowPty,
    required AutomationRequestHandler onRequest,
  }) async {
    if (_server != null) {
      await stop();
    }
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
    _server = server;
    _password = password;
    _allowPty = allowPty;
    _onRequest = onRequest;
    _mutationTail = Future<void>.value();
    _subscription = server.listen(
      (request) => unawaited(_handleRawRequest(request)),
    );
  }

  @override
  Future<void> stop() async {
    final subscription = _subscription;
    final server = _server;
    _subscription = null;
    _server = null;
    _onRequest = null;
    _password = '';
    _allowPty = false;
    await subscription?.cancel();
    await server?.close(force: true);
  }

  @override
  void updatePassword(String password) {
    _password = password;
  }

  @override
  void updateAllowPty(bool allowPty) {
    _allowPty = allowPty;
  }

  Future<void> _handleRawRequest(HttpRequest rawRequest) async {
    var closeConnection = false;
    AutomationHttpResponse response;
    try {
      final outcome = await _processRequest(rawRequest);
      response = outcome.response;
      closeConnection = outcome.closeConnection;
    } on Object {
      response = AutomationHttpResponse.error(
        statusCode: HttpStatus.internalServerError,
        code: 'internal_error',
        message: 'Internal server error.',
      );
    }
    await _writeResponse(
      rawRequest.response,
      response,
      closeConnection: closeConnection,
    );
  }

  Future<({AutomationHttpResponse response, bool closeConnection})>
  _processRequest(HttpRequest rawRequest) async {
    final port = boundPort;
    if (port == null || !_isAllowedHost(rawRequest, port)) {
      return (
        response: AutomationHttpResponse.error(
          statusCode: HttpStatus.forbidden,
          code: 'forbidden_host',
          message: 'Host header is not allowed.',
        ),
        closeConnection: false,
      );
    }

    final method = rawRequest.method.toUpperCase();
    if (method == 'OPTIONS') {
      return (
        response: AutomationHttpResponse.error(
          statusCode: HttpStatus.methodNotAllowed,
          code: 'method_not_allowed',
          message: 'OPTIONS requests are not supported.',
        ),
        closeConnection: false,
      );
    }

    if (!_isAuthorized(rawRequest)) {
      return (
        response: AutomationHttpResponse.error(
          statusCode: HttpStatus.unauthorized,
          code: 'unauthorized',
          message: 'Missing or invalid Bearer token.',
        ),
        closeConnection: false,
      );
    }

    if (method != 'GET' && method != 'POST') {
      return (
        response: AutomationHttpResponse.error(
          statusCode: HttpStatus.methodNotAllowed,
          code: 'method_not_allowed',
          message: 'Only GET and POST methods are supported.',
        ),
        closeConnection: false,
      );
    }

    final path = _normalizePath(rawRequest.uri);
    if (!_allowPty && _isPtyScopedPath(path)) {
      return (
        response: AutomationHttpResponse.error(
          statusCode: HttpStatus.forbidden,
          code: 'pty_scope_disabled',
          message: 'PTY automation scope is disabled.',
        ),
        closeConnection: false,
      );
    }

    return _dispatchAuthorizedRequest(rawRequest, method: method, path: path);
  }

  Future<({AutomationHttpResponse response, bool closeConnection})>
  _dispatchAuthorizedRequest(
    HttpRequest rawRequest, {
    required String method,
    required String path,
  }) async {
    Map<String, Object?>? body;
    if (method == 'POST') {
      final parsed = await _parseJsonBody(rawRequest);
      if (parsed.error case final errorResponse?) {
        return (
          response: errorResponse,
          closeConnection: parsed.closeConnection,
        );
      }
      body = parsed.body;
    }

    final handler = _onRequest;
    if (handler == null) {
      return (
        response: AutomationHttpResponse.error(
          statusCode: HttpStatus.serviceUnavailable,
          code: 'server_stopped',
          message: 'Automation server is stopped.',
        ),
        closeConnection: false,
      );
    }

    final request = AutomationHttpRequest(
      method: method,
      path: path,
      queryParameters: Map<String, String>.unmodifiable(
        rawRequest.uri.queryParameters,
      ),
      body: body,
    );
    final result = method == 'POST'
        ? await _enqueueMutation(() => handler(request))
        : await handler(request);
    return (response: result, closeConnection: false);
  }

  bool _isAllowedHost(HttpRequest request, int port) {
    final hostValues = request.headers[HttpHeaders.hostHeader];
    if (hostValues == null || hostValues.length != 1) return false;
    final host = hostValues.first.toLowerCase();
    return host == '127.0.0.1:$port' || host == 'localhost:$port';
  }

  bool _isAuthorized(HttpRequest request) {
    final expected = _password;
    if (expected.isEmpty) return false;
    final authValues = request.headers[HttpHeaders.authorizationHeader];
    if (authValues == null || authValues.length != 1) return false;
    final header = authValues.first;
    final spaceIndex = header.indexOf(' ');
    if (spaceIndex <= 0) return false;
    final scheme = header.substring(0, spaceIndex).toLowerCase();
    if (scheme != 'bearer') return false;
    final token = header.substring(spaceIndex + 1);
    return constantTimeEquals(token, expected);
  }

  String _normalizePath(Uri uri) {
    final normalized = uri.normalizePath().path;
    return normalized.isEmpty ? '/' : normalized;
  }

  bool _isPtyScopedPath(String path) {
    final trimmed = path.length > 1 && path.endsWith('/')
        ? path.substring(0, path.length - 1)
        : path;
    return trimmed == '/v1/screen' ||
        trimmed.startsWith('/v1/screen/') ||
        trimmed == '/v1/pty' ||
        trimmed.startsWith('/v1/pty/') ||
        trimmed == '/v1/tabs/spawn' ||
        trimmed.startsWith('/v1/tabs/spawn/') ||
        trimmed == '/v1/input/mouse' ||
        trimmed.startsWith('/v1/input/mouse/');
  }

  Future<_BodyParseResult> _parseJsonBody(HttpRequest request) async {
    if (!_hasJsonContentType(request)) {
      return _BodyParseResult.error(
        AutomationHttpResponse.error(
          statusCode: HttpStatus.unsupportedMediaType,
          code: 'unsupported_media_type',
          message: 'POST requests require Content-Type: application/json.',
        ),
      );
    }

    if (request.contentLength > maxBodyBytes) {
      await _discardBoundedBody(request);
      return _BodyParseResult.error(
        AutomationHttpResponse.error(
          statusCode: HttpStatus.requestEntityTooLarge,
          code: 'payload_too_large',
          message: 'Request body exceeds $maxBodyBytes bytes.',
        ),
        closeConnection: true,
      );
    }

    final bytes = await _readBoundedBody(request);
    if (bytes == null) {
      return _BodyParseResult.error(
        AutomationHttpResponse.error(
          statusCode: HttpStatus.requestEntityTooLarge,
          code: 'payload_too_large',
          message: 'Request body exceeds $maxBodyBytes bytes.',
        ),
        closeConnection: true,
      );
    }
    return _decodeJsonObject(bytes);
  }

  bool _hasJsonContentType(HttpRequest request) {
    try {
      final contentType = request.headers.contentType;
      return contentType != null &&
          contentType.mimeType.toLowerCase() == 'application/json';
    } on FormatException {
      return false;
    }
  }

  Future<void> _discardBoundedBody(HttpRequest request) async {
    var discarded = 0;
    await for (final chunk in request) {
      discarded += chunk.length;
      if (discarded > _maxDiscardBytes) break;
    }
  }

  Future<Uint8List?> _readBoundedBody(HttpRequest request) async {
    final builder = BytesBuilder(copy: false);
    var totalBytes = 0;
    var exceeded = false;
    await for (final chunk in request) {
      totalBytes += chunk.length;
      if (exceeded) {
        if (totalBytes > _maxDiscardBytes) break;
        continue;
      }
      if (totalBytes > maxBodyBytes) {
        exceeded = true;
        builder.clear();
        if (totalBytes > _maxDiscardBytes) break;
        continue;
      }
      builder.add(chunk);
    }
    return exceeded ? null : builder.takeBytes();
  }

  _BodyParseResult _decodeJsonObject(Uint8List bytes) {
    try {
      final text = utf8.decode(bytes);
      final Object? decoded = jsonDecode(text);
      if (decoded is! Map<Object?, Object?>) {
        return _BodyParseResult.error(
          AutomationHttpResponse.error(
            statusCode: HttpStatus.badRequest,
            code: 'invalid_json',
            message: 'Request body must be a JSON object.',
          ),
        );
      }
      final objectMap = <String, Object?>{
        for (final MapEntry(:key, :value) in decoded.entries)
          if (key is String) key: value,
      };
      return _BodyParseResult.ok(objectMap);
    } on FormatException catch (error) {
      return _BodyParseResult.error(
        AutomationHttpResponse.error(
          statusCode: HttpStatus.badRequest,
          code: 'invalid_json',
          message: 'Malformed UTF-8 or JSON request body: ${error.message}',
        ),
      );
    }
  }

  Future<AutomationHttpResponse> _enqueueMutation(
    Future<AutomationHttpResponse> Function() action,
  ) {
    final completer = Completer<AutomationHttpResponse>();
    final previous = _mutationTail;
    final next = previous.whenComplete(() async {
      try {
        completer.complete(await action());
      } on Object catch (error, stackTrace) {
        completer.completeError(error, stackTrace);
      }
    });
    _mutationTail = next.catchError((Object _) {});
    return completer.future;
  }

  Future<void> _writeResponse(
    HttpResponse httpResponse,
    AutomationHttpResponse response, {
    required bool closeConnection,
  }) async {
    try {
      httpResponse.statusCode = response.statusCode;
      httpResponse.headers.contentType = ContentType.json;
      httpResponse.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
      if (closeConnection) {
        httpResponse.persistentConnection = false;
      }
      httpResponse.write(response.toJsonString());
      await httpResponse.close();
    } on Object {
      // Ignore client disconnects while flushing the response.
    }
  }
}

/// Platform factory returning an [IoAutomationHttpServer] on `dart:io` targets.
AutomationHttpServerBackend createPlatformAutomationHttpServerBackend() =>
    IoAutomationHttpServer();
