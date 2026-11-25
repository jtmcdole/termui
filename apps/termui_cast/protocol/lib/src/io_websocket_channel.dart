import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:stream_channel/stream_channel.dart';

import 'buffer_frame_codec.dart';

const String _webSocketGuid = '258EAFA5-E914-47DA-95CA-C5AB0DC85B11';

/// Maximum raw incoming socket bytes (`16 KiB`) permitted before the initial
/// WebSocket frame is decoded and delivered.
const int maxPreAuthRawBytes = 16 * 1024;

/// Maximum unconsumed raw framing overhead (`64 KiB`) permitted above
/// `maxPayloadLength` between delivered WebSocket frames.
const int maxFragmentationOverheadBytes = 64 * 1024;

/// Sink wrapping a `dart:io` [WebSocket] for binary frames while swallowing
/// async socket-reset errors on `done` and exposing an awaitable [closeWithCode].
final class IoBinaryWebSocketSink implements StreamSink<Uint8List> {
  final WebSocket _ws;
  final Future<void>? _handshakeDone;
  final void Function()? _onPrepareClose;
  final void Function()? _onCloseTimeout;
  final Future<void> _done;
  AbortableByteStream? _activeStream;
  Future<void>? _activeAddStream;
  Future<void>? _closeFuture;
  bool _closing = false;

  /// Wraps an open `dart:io` [WebSocket].
  IoBinaryWebSocketSink(
    this._ws, {
    Future<void>? handshakeDone,
    void Function()? onPrepareClose,
    void Function()? onCloseTimeout,
  }) : _handshakeDone = handshakeDone,
       _onPrepareClose = onPrepareClose,
       _onCloseTimeout = onCloseTimeout,
       _done = _ws.done.then<void>(
         (_) {},
         onError: (Object _, StackTrace _) {},
       );

  @override
  void add(Uint8List data) {
    if (!_closing && _ws.readyState == WebSocket.open) {
      _ws.add(data);
    }
  }

  @override
  void addError(Object error, [StackTrace? stackTrace]) {}

  @override
  Future<void> addStream(Stream<Uint8List> stream) {
    if (_closing || _ws.readyState != WebSocket.open) {
      return stream.listen(null).cancel();
    }
    if (_activeAddStream != null) {
      throw StateError('StreamSink is bound to a stream');
    }
    final wrapped = AbortableByteStream(stream);
    _activeStream = wrapped;
    final future = _ws
        .addStream(wrapped)
        .then<void>((_) {}, onError: (Object _, StackTrace _) {});
    _activeAddStream = future;
    return future.whenComplete(() {
      if (identical(_activeAddStream, future)) {
        _activeAddStream = null;
        _activeStream = null;
      }
    });
  }

  /// Closes the underlying [WebSocket] with [code] and [reason].
  Future<void> closeWithCode(int code, String reason) {
    if (_closing) return _closeFuture ?? Future<void>.value();
    _closing = true;
    final future = _doClose(code, reason);
    _closeFuture = future;
    return future;
  }

  Future<void> _doClose(int code, String reason) async {
    _activeStream?.abort();
    final active = _activeAddStream;
    if (active != null) {
      await active;
    }
    var timedOut = false;
    try {
      _ws.pingInterval = null;
      _onPrepareClose?.call();
      await _ws
          .close(code, reason)
          .timeout(
            const Duration(milliseconds: 500),
            onTimeout: () {
              timedOut = true;
            },
          );
      final handshake = _handshakeDone;
      if (!timedOut && handshake != null) {
        await handshake.timeout(
          const Duration(milliseconds: 500),
          onTimeout: () {
            timedOut = true;
          },
        );
      }
    } on Object catch (_) {
      timedOut = true;
    }
    if (timedOut) {
      _onCloseTimeout?.call();
    }
  }

  @override
  Future<void> close() => closeWithCode(WebSocketStatus.normalClosure, '');

  @override
  Future<void> get done => _done;
}

/// Single-subscription `Stream<Uint8List>` wrapper that can be synchronously
/// terminated via [abort] to release an active `StreamSink.addStream` call.
final class AbortableByteStream extends Stream<Uint8List> {
  final Stream<Uint8List> _source;
  StreamSubscription<Uint8List>? _sub;
  void Function()? _onDone;
  bool _aborted = false;

  /// Wraps [_source] with an explicit [abort] handle.
  AbortableByteStream(this._source);

  /// Cancels the underlying subscription and completes any active listener's
  /// `onDone` callback immediately.
  void abort() {
    if (_aborted) return;
    _aborted = true;
    final sub = _sub;
    _sub = null;
    if (sub != null) {
      unawaited(sub.cancel());
    }
    final done = _onDone;
    _onDone = null;
    done?.call();
  }

  @override
  StreamSubscription<Uint8List> listen(
    void Function(Uint8List event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    if (_aborted) {
      return const Stream<Uint8List>.empty().listen(
        onData,
        onError: onError,
        onDone: onDone,
        cancelOnError: cancelOnError,
      );
    }
    _onDone = onDone;
    final sub = _source.listen(
      (chunk) {
        if (!_aborted) onData?.call(chunk);
      },
      onError: onError,
      onDone: _handleSourceDone,
      cancelOnError: cancelOnError,
    );
    _sub = sub;
    return _AbortableByteSubscription(this, sub);
  }

  void _handleSourceDone() {
    if (_aborted) return;
    _aborted = true;
    _sub = null;
    final done = _onDone;
    _onDone = null;
    done?.call();
  }
}

final class _AbortableByteSubscription
    implements StreamSubscription<Uint8List> {
  final AbortableByteStream _owner;
  final StreamSubscription<Uint8List> _inner;

  _AbortableByteSubscription(this._owner, this._inner);

  @override
  bool get isPaused => _inner.isPaused;

  @override
  void pause([Future<void>? resumeSignal]) => _inner.pause(resumeSignal);

  @override
  void resume() => _inner.resume();

  @override
  Future<void> cancel() {
    _owner._aborted = true;
    _owner._onDone = null;
    _owner._sub = null;
    return _inner.cancel();
  }

  @override
  Future<E> asFuture<E>([E? futureValue]) => _inner.asFuture<E>(futureValue);

  @override
  void onData(void Function(Uint8List data)? handleData) {
    _inner.onData(
      handleData == null
          ? null
          : (chunk) {
              if (!_owner._aborted) handleData(chunk);
            },
    );
  }

  @override
  void onDone(void Function()? handleDone) {
    _owner._onDone = handleDone;
  }

  @override
  void onError(Function? handleError) => _inner.onError(handleError);
}

/// Adapts an open `dart:io` [WebSocket] into a binary [StreamChannel] and
/// a close-code callback, rejecting non-binary frames with [ProtocolFormatException].
({
  StreamChannel<Uint8List> channel,
  Future<void> Function(int code, String reason) closeWithCode,
})
wrapIoBinaryWebSocket(
  WebSocket ws, {
  int maxPayloadLength = BufferFrameCodec.maxFrameBytes,
  Duration pingInterval = const Duration(seconds: 20),
  void Function()? onCloseTimeout,
}) => _wrapIoBinaryWebSocketInternal(
  ws,
  maxPayloadLength: maxPayloadLength,
  pingInterval: pingInterval,
  onCloseTimeout: onCloseTimeout,
);

void _markCloseHandshakeDone(WebSocket ws, Completer<void> handshakeCompleter) {
  try {
    ws.pingInterval = null;
  } on Object catch (_) {}
  if (!handshakeCompleter.isCompleted) handshakeCompleter.complete();
}

({
  StreamChannel<Uint8List> channel,
  Future<void> Function(int code, String reason) closeWithCode,
})
_wrapIoBinaryWebSocketInternal(
  WebSocket ws, {
  required int maxPayloadLength,
  required Duration pingInterval,
  _MeteredWebSocketSocket? meteredSocket,
  void Function()? onCloseTimeout,
}) {
  ws.pingInterval = pingInterval;
  final handshakeCompleter = Completer<void>();
  final wsDone = Completer<void>();
  final destroySocket = onCloseTimeout ?? meteredSocket?.destroy;
  final doneWaitTimeout = destroySocket != null
      ? const Duration(milliseconds: 2500)
      : const Duration(milliseconds: 200);
  late final StreamSubscription<Object?> sub;
  late final IoBinaryWebSocketSink sink;
  late final StreamController<Uint8List> incoming;
  Future<void>? cancelSubFuture;
  Future<void> cancelSubAfterDone() {
    if (wsDone.isCompleted) return Future<void>.value();
    return cancelSubFuture ??= () async {
      try {
        await wsDone.future.timeout(doneWaitTimeout);
      } on TimeoutException {
        if (!wsDone.isCompleted) {
          await sub.cancel();
        }
      }
    }();
  }

  incoming = StreamController<Uint8List>(
    onPause: () => sub.pause(),
    onResume: () => sub.resume(),
    onCancel: () async {
      await Future<void>.value();
      await (sink._closeFuture ?? sink.close());
      await cancelSubAfterDone();
    },
  );
  sink = IoBinaryWebSocketSink(
    ws,
    handshakeDone: handshakeCompleter.future,
    onPrepareClose: () {
      if (sub.isPaused) sub.resume();
    },
    onCloseTimeout: () {
      if (sub.isPaused) sub.resume();
      if (!wsDone.isCompleted) {
        destroySocket?.call();
      }
      _markCloseHandshakeDone(ws, handshakeCompleter);
      unawaited(cancelSubAfterDone());
    },
  );
  meteredSocket?.onLimitExceeded = (ProtocolFormatException error) {
    if (!incoming.isClosed) {
      incoming.addError(error);
    }
    unawaited(
      sink
          .closeWithCode(
            WebSocketStatus.policyViolation,
            'Frame size limit exceeded',
          )
          .whenComplete(meteredSocket.destroy),
    );
  };
  sub = ws.listen(
    (Object? data) {
      meteredSocket?.onFrameDelivered();
      _forwardIncomingFrame(data, maxPayloadLength, incoming);
    },
    onError: incoming.addError,
    onDone: () {
      if (!wsDone.isCompleted) wsDone.complete();
      _markCloseHandshakeDone(ws, handshakeCompleter);
      unawaited(sink.close());
      if (!incoming.isClosed) {
        unawaited(incoming.close());
      }
    },
  );
  return (
    channel: StreamChannel<Uint8List>(incoming.stream, sink),
    closeWithCode: sink.closeWithCode,
  );
}

void _forwardIncomingFrame(
  Object? data,
  int maxPayloadLength,
  StreamController<Uint8List> incoming,
) {
  final Uint8List bytes;
  if (data is Uint8List) {
    bytes = data;
  } else if (data is List<int>) {
    bytes = Uint8List.fromList(data);
  } else {
    incoming.addError(
      const ProtocolFormatException('Expected binary WebSocket frame'),
    );
    return;
  }
  if (bytes.length > maxPayloadLength) {
    incoming.addError(
      ProtocolFormatException(
        'WebSocket frame exceeds $maxPayloadLength bytes: ${bytes.length}',
      ),
    );
    return;
  }
  incoming.add(bytes);
}

/// Upgrades an incoming [HttpRequest] to an uncompressed binary [WebSocket]
/// capped at [maxPayloadLength] bytes, enforcing a [preAuthMaxBytes] raw byte
/// limit before the first frame and a `maxPayloadLength + 65536` unconsumed
/// byte cap across `FIN=0` continuation frames.
Future<
  ({
    StreamChannel<Uint8List> channel,
    Future<void> Function(int code, String reason) closeWithCode,
  })
>
upgradeCastWebSocket(
  HttpRequest request, {
  int maxPayloadLength = BufferFrameCodec.maxFrameBytes,
  int preAuthMaxBytes = maxPreAuthRawBytes,
  Duration pingInterval = const Duration(seconds: 20),
}) async {
  final key = request.headers.value('sec-websocket-key');
  if (!WebSocketTransformer.isUpgradeRequest(request) || key == null) {
    throw const WebSocketException('Invalid WebSocket upgrade request');
  }
  final accept = base64.encode(
    sha1.convert(utf8.encode('$key$_webSocketGuid')).bytes,
  );
  request.response
    ..statusCode = HttpStatus.switchingProtocols
    ..headers.add(HttpHeaders.connectionHeader, 'Upgrade')
    ..headers.set(HttpHeaders.upgradeHeader, 'websocket')
    ..headers.set('Sec-WebSocket-Accept', accept)
    ..contentLength = 0;

  final rawSocket = await request.response.detachSocket();
  final meteredSocket = _MeteredWebSocketSocket(
    rawSocket,
    preAuthMaxBytes: preAuthMaxBytes,
    maxUnconsumedBytes: maxPayloadLength + maxFragmentationOverheadBytes,
  );
  final ws = WebSocket.fromUpgradedSocket(
    meteredSocket,
    serverSide: true,
    compression: CompressionOptions.compressionOff,
  );
  return _wrapIoBinaryWebSocketInternal(
    ws,
    maxPayloadLength: maxPayloadLength,
    pingInterval: pingInterval,
    meteredSocket: meteredSocket,
  );
}

final class _MeteredWebSocketSocket extends Stream<Uint8List>
    implements Socket {
  final Socket _inner;
  final int preAuthMaxBytes;
  final int maxUnconsumedBytes;
  void Function(ProtocolFormatException error)? onLimitExceeded;
  StreamSubscription<Uint8List>? _sub;
  void Function()? _innerOnDone;
  int _unconsumedBytes = 0;
  bool _firstFrameReceived = false;
  bool _aborted = false;

  _MeteredWebSocketSocket(
    this._inner, {
    required this.preAuthMaxBytes,
    required this.maxUnconsumedBytes,
  });

  void onFrameDelivered() {
    _firstFrameReceived = true;
    _unconsumedBytes = 0;
  }

  @override
  StreamSubscription<Uint8List> listen(
    void Function(Uint8List event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    _innerOnDone = onDone;
    final sub = _inner.listen(
      (chunk) => _handleChunk(chunk, onData),
      onError: onError,
      onDone: () {
        if (_aborted) return;
        final done = _innerOnDone;
        _innerOnDone = null;
        done?.call();
      },
      cancelOnError: cancelOnError,
    );
    _sub = sub;
    return sub;
  }

  void _handleChunk(Uint8List chunk, void Function(Uint8List event)? onData) {
    if (_aborted) return;
    final limit = _firstFrameReceived ? maxUnconsumedBytes : preAuthMaxBytes;
    _unconsumedBytes += chunk.length;
    if (_unconsumedBytes > limit) {
      _aborted = true;
      final sub = _sub;
      _sub = null;
      if (sub != null) {
        unawaited(sub.cancel());
      }
      onLimitExceeded?.call(
        ProtocolFormatException(
          _firstFrameReceived
              ? 'Unconsumed WebSocket bytes ($_unconsumedBytes) exceeded $limit'
              : 'Pre-auth WebSocket bytes ($_unconsumedBytes) exceeded $limit',
        ),
      );
      return;
    }
    onData?.call(chunk);
  }

  @override
  Encoding get encoding => _inner.encoding;

  @override
  set encoding(Encoding value) => _inner.encoding = value;

  @override
  void add(List<int> data) => _inner.add(data);

  @override
  void write(Object? object) => _inner.write(object);

  @override
  void writeln([Object? object = '']) => _inner.writeln(object);

  @override
  void writeAll(Iterable<Object?> objects, [String separator = '']) =>
      _inner.writeAll(objects, separator);

  @override
  void writeCharCode(int charCode) => _inner.writeCharCode(charCode);

  @override
  void addError(Object error, [StackTrace? stackTrace]) =>
      _inner.addError(error, stackTrace);

  @override
  Future<Object?> addStream(Stream<List<int>> stream) =>
      _inner.addStream(stream);

  @override
  Future<Object?> flush() => _inner.flush();

  @override
  Future<Object?> close() async {
    try {
      await _inner.close().timeout(
        const Duration(milliseconds: 200),
        onTimeout: () {},
      );
    } on Object catch (_) {}
    if (_aborted) {
      final done = _innerOnDone;
      _innerOnDone = null;
      done?.call();
      _inner.destroy();
    }
    return null;
  }

  @override
  Future<Object?> get done => _inner.done;

  @override
  void destroy() => _inner.destroy();

  @override
  bool setOption(SocketOption option, bool enabled) =>
      _inner.setOption(option, enabled);

  @override
  Uint8List getRawOption(RawSocketOption option) => _inner.getRawOption(option);

  @override
  void setRawOption(RawSocketOption option) => _inner.setRawOption(option);

  @override
  int get port => _inner.port;

  @override
  int get remotePort => _inner.remotePort;

  @override
  InternetAddress get address => _inner.address;

  @override
  InternetAddress get remoteAddress => _inner.remoteAddress;
}

/// Connects to a `ws://` or `wss://` [uri] with uncompressed frames, optional
/// HTTP upgrade [headers], and [maxPayloadLength] enforcement.
Future<StreamChannel<Uint8List>> connectCastWebSocket(
  Uri uri, {
  Map<String, Object>? headers,
  int maxPayloadLength = BufferFrameCodec.maxFrameBytes,
  Duration timeout = const Duration(seconds: 10),
  Duration pingInterval = const Duration(seconds: 20),
}) async {
  final client = HttpClient()..connectionTimeout = timeout;
  var canceled = false;
  final openFuture = _openUpgradedClientWebSocket(
    client,
    uri,
    headers,
    maxPayloadLength,
  );
  try {
    final (:ws, :rawSocket) = await openFuture.timeout(timeout);
    client.close();
    return _wrapIoBinaryWebSocketInternal(
      ws,
      maxPayloadLength: maxPayloadLength,
      pingInterval: pingInterval,
      onCloseTimeout: rawSocket.destroy,
    ).channel;
  } on Object {
    canceled = true;
    unawaited(
      openFuture.then((opened) {
        if (canceled) {
          opened.rawSocket.destroy();
          unawaited(opened.ws.close().catchError((Object _) {}));
        }
      }, onError: (Object _) {}),
    );
    client.close(force: true);
    rethrow;
  }
}

Future<({WebSocket ws, Socket rawSocket})> _openUpgradedClientWebSocket(
  HttpClient client,
  Uri uri,
  Map<String, Object>? headers,
  int maxPayloadLength,
) async {
  if (uri.scheme != 'ws' && uri.scheme != 'wss') {
    throw WebSocketException("Unsupported URL scheme '${uri.scheme}'");
  }
  if (uri.userInfo.isNotEmpty) {
    throw const FormatException(
      'WebSocket URI must not embed userInfo credentials.',
    );
  }
  final httpUri = uri.replace(scheme: uri.scheme == 'wss' ? 'https' : 'http');
  final nonce = _generateWebSocketNonce();
  final req = await client.openUrl('GET', httpUri);
  req.followRedirects = false;
  if (headers != null) {
    for (final entry in headers.entries) {
      req.headers.add(entry.key, entry.value);
    }
  }
  req.headers
    ..set(HttpHeaders.connectionHeader, 'Upgrade')
    ..set(HttpHeaders.upgradeHeader, 'websocket')
    ..set('Sec-WebSocket-Key', nonce)
    ..set('Cache-Control', 'no-cache')
    ..set('Sec-WebSocket-Version', '13');
  final response = await req.close();
  if (!_isValidWebSocketUpgradeResponse(response, nonce)) {
    unawaited(
      response.detachSocket().then((s) => s.destroy(), onError: (Object _) {}),
    );
    final safeUri = Uri(
      scheme: httpUri.scheme,
      host: httpUri.host,
      port: httpUri.hasPort ? httpUri.port : null,
      path: httpUri.path,
    );
    throw WebSocketException(
      "Connection to '$safeUri' was not upgraded to websocket",
      response.statusCode,
    );
  }
  final rawSocket = await response.detachSocket();
  final ws = WebSocket.fromUpgradedSocket(
    rawSocket,
    serverSide: false,
    compression: .compressionOff,
    maxPayloadLength: maxPayloadLength,
  );
  return (ws: ws, rawSocket: rawSocket);
}

String _generateWebSocketNonce() {
  final rng = Random.secure();
  final bytes = Uint8List(16);
  for (var i = 0; i < bytes.length; i++) {
    bytes[i] = rng.nextInt(256);
  }
  return base64Encode(bytes);
}

bool _isValidWebSocketUpgradeResponse(
  HttpClientResponse response,
  String nonce,
) {
  if (response.statusCode != HttpStatus.switchingProtocols ||
      response.headers['sec-websocket-extensions'] != null ||
      response.headers['sec-websocket-protocol'] != null) {
    return false;
  }
  final conn = response.headers[HttpHeaders.connectionHeader];
  if (conn == null || !conn.any((v) => v.trim().toLowerCase() == 'upgrade')) {
    return false;
  }
  final upgrade = response.headers[HttpHeaders.upgradeHeader];
  if (upgrade == null ||
      upgrade.length != 1 ||
      upgrade.single.trim().toLowerCase() != 'websocket') {
    return false;
  }
  final accept = response.headers['sec-websocket-accept'];
  final expected = base64.encode(
    sha1.convert(utf8.encode('$nonce$_webSocketGuid')).bytes,
  );
  return accept != null &&
      accept.length == 1 &&
      accept.single.trim() == expected;
}

/// Returns a broadcast stream of process termination signals (`SIGINT`, and
/// `SIGTERM` on non-Windows platforms) that cancels underlying watchers when
/// the returned stream has no active listeners.
Stream<ProcessSignal> watchPosixTerminationSignals() {
  final controller = StreamController<ProcessSignal>.broadcast();
  final subs = <StreamSubscription<ProcessSignal>>[
    ProcessSignal.sigint.watch().listen(controller.add),
    if (!Platform.isWindows)
      ProcessSignal.sigterm.watch().listen(controller.add),
  ];
  controller.onCancel = () async {
    await [for (final sub in subs) sub.cancel()].wait;
  };
  return controller.stream;
}

/// Returns a broadcast stream of `SIGHUP` signals on POSIX platforms (macOS and
/// Linux), or an empty stream on Windows, clearing the native signal handler
/// when the last listener cancels.
Stream<ProcessSignal> watchPosixHangupSignals() => Platform.isWindows
    ? const Stream<ProcessSignal>.empty()
    : ProcessSignal.sighup.watch();
