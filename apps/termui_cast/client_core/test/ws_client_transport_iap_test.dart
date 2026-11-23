@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:checks/checks.dart';
import 'package:stream_channel/stream_channel.dart';
import 'package:termui_cast_client_core/src/transport/ws_channel_adapter.dart';
import 'package:termui_cast_client_core/termui_cast_client_core.dart';
import 'package:termui_cast_protocol/termui_cast_protocol.dart';
import 'package:termui_cast_protocol/termui_cast_protocol_io.dart';
import 'package:test/test.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

const String _loopbackCertPem = '''
-----BEGIN CERTIFICATE-----
MIIBXjCCAQSgAwIBAgIULU3zm1zY44xP1dipeoCjSC/8K70wCgYIKoZIzj0EAwIw
FDESMBAGA1UEAwwJMTI3LjAuMC4xMCAXDTI2MTAzMTA0MDU0M1oYDzIxMjYxMDA3
MDQwNTQzWjAUMRIwEAYDVQQDDAkxMjcuMC4wLjEwWTATBgcqhkjOPQIBBggqhkjO
PQMBBwNCAAT6yG8zLGFj+MjDuYRd1ADtqLt5rTI8w4exRE3P94LpwktT6JM3sijt
RxSUJM5sfrP/nuLlt0ybG+f2ZAfvG8sOozIwMDAdBgNVHQ4EFgQUKyz+9Glq20Rm
nJ0YWXDYbbbE1d4wDwYDVR0TAQH/BAUwAwEB/zAKBggqhkjOPQQDAgNIADBFAiEA
uYj8rkQ0YjvzlQEAK+n0RKl/u3RajZVX6AegRkn32rQCIHjGmHCbsMIbqGi+tuMy
Kd7O/JigQBUF35okHmv7/y+N
-----END CERTIFICATE-----
''';

const String _loopbackKeyPem = '''
-----BEGIN PRIVATE KEY-----
MIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQgcnEPuDznhktG/80D
VI1RW5oy4n+z93IGlv9cLtYJuBOhRANCAAT6yG8zLGFj+MjDuYRd1ADtqLt5rTI8
w4exRE3P94LpwktT6JM3sijtRxSUJM5sfrP/nuLlt0ybG+f2ZAfvG8sO
-----END PRIVATE KEY-----
''';

final class _TrustLoopbackCertHttpOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) =>
      super.createHttpClient(context)
        ..badCertificateCallback = (_, host, _) => host == '127.0.0.1';
}

void main() {
  group('WsClientTransport Cloud Run IAP bearer integration', () {
    test('rejects non-wss URIs when iapTokenProvider is configured', () {
      check(
        () => WsClientTransport(
          serverUri: Uri.parse('ws://127.0.0.1:8420/v1/client'),
          iapTokenProvider: () async => 'iap-jwt',
        ),
      ).throws<FormatException>();
    });

    test(
      'preserves iapTokenProvider across canonical wss:// endpoints and clears on endpoint mismatch',
      () {
        Future<String> provider() async => 'iap-jwt';
        final initial = WsClientTransport(
          serverUri: Uri.parse('wss://relay.run.app/v1/client'),
          token: 'bad-token',
          iapTokenProvider: provider,
        );

        final explicit443 = initial.copyWithEndpoint((
          serverUri: Uri.parse('wss://Relay.Run.App:443/v1/client'),
          token: 'good-token',
        ));
        check(identical(explicit443.iapTokenProvider, provider)).isTrue();
        check(explicit443.token).equals('good-token');

        for (final otherRaw in const [
          'wss://other-relay.run.app/v1/client',
          'wss://relay.run.app:8443/v1/client',
          'wss://relay.run.app/v2/client',
          'ws://relay.run.app/v1/client',
        ]) {
          final cleared = initial.copyWithEndpoint((
            serverUri: Uri.parse(otherRaw),
            token: 'good-token',
          ));
          check(cleared.iapTokenProvider).isNull();
        }
      },
    );

    test(
      'copyWithEndpoint replaces or clears iapTokenProvider when replaceIapTokenProvider is true and rejects ws://',
      () {
        Future<String> providerA() async => 'iap-a';
        Future<String> providerB() async => 'iap-b';
        final noIap = WsClientTransport(
          serverUri: Uri.parse('ws://127.0.0.1:8420/v1/client'),
          token: 't1',
        );

        final installed = noIap.copyWithEndpoint(
          (serverUri: Uri.parse('wss://relay.run.app/v1/client'), token: 't2'),
          iapTokenProvider: providerA,
          replaceIapTokenProvider: true,
        );
        check(identical(installed.iapTokenProvider, providerA)).isTrue();

        final swapped = installed.copyWithEndpoint(
          (serverUri: Uri.parse('wss://relay.run.app/v1/client'), token: 't3'),
          iapTokenProvider: providerB,
          replaceIapTokenProvider: true,
        );
        check(identical(swapped.iapTokenProvider, providerB)).isTrue();

        final cleared = swapped.copyWithEndpoint(
          (serverUri: Uri.parse('wss://relay.run.app/v1/client'), token: 't4'),
          iapTokenProvider: null,
          replaceIapTokenProvider: true,
        );
        check(cleared.iapTokenProvider).isNull();

        check(
          () => installed.copyWithEndpoint(
            (
              serverUri: Uri.parse('ws://127.0.0.1:8420/v1/client'),
              token: 't5',
            ),
            iapTokenProvider: providerA,
            replaceIapTokenProvider: true,
          ),
        ).throws<FormatException>();
      },
    );

    test(
      'repository.reconnect installs, swaps, and clears iapTokenProvider dynamically over wss://',
      () => HttpOverrides.runWithHttpOverrides(() async {
        final seenHeaders = <String?>[];
        final server = await _bindMockIapTlsRelay(
          expectedViewerToken: 'viewer-secret',
          onUpgradeRequest: seenHeaders.add,
          onAuthFrameToken: (_) {},
        );
        addTearDown(() => server.close(force: true));

        final uri = Uri.parse('wss://127.0.0.1:${server.port}/v1/client');
        final repository = CastClientRepository(
          transport: WsClientTransport(
            serverUri: Uri.parse('ws://127.0.0.1:1/v1/client'),
          ),
          enableReconnect: false,
        );
        addTearDown(repository.dispose);

        final received = <CastMessage>[];
        clientMessageReceivedEvent.addListener(repository.bus, received.add);

        // 1. Install IAP provider on a transport originally created without one.
        await repository.reconnect(
          (serverUri: uri, token: 'viewer-secret'),
          retryOnFailure: false,
          iapTokenProvider: () async => 'iap-first',
          replaceIapTokenProvider: true,
        );
        await _waitFor(() => received.any((m) => m is AuthAcceptedFrame));
        check(seenHeaders).deepEquals(['Bearer iap-first']);

        // 2. Reject ws:// with non-null iapTokenProvider without tearing down active transport.
        await check(
          repository.reconnect(
            (
              serverUri: Uri.parse('ws://127.0.0.1:8420/v1/client'),
              token: 'viewer-secret',
            ),
            retryOnFailure: false,
            iapTokenProvider: () async => 'iap-bad',
            replaceIapTokenProvider: true,
          ),
        ).throws<FormatException>();
        check(repository.transport.isConnected).isTrue();

        // 3. Swap IAP provider to a fresh provider and verify updated Authorization header.
        received.clear();
        await repository.reconnect(
          (serverUri: uri, token: 'viewer-secret'),
          retryOnFailure: false,
          iapTokenProvider: () async => 'iap-second',
          replaceIapTokenProvider: true,
        );
        await _waitFor(() => received.any((m) => m is AuthAcceptedFrame));
        check(
          seenHeaders,
        ).deepEquals(['Bearer iap-first', 'Bearer iap-second']);

        // 4. Clear IAP provider -> server rejects missing Authorization header (401).
        await check(
          repository.reconnect(
            (serverUri: uri, token: 'viewer-secret'),
            retryOnFailure: false,
            iapTokenProvider: null,
            replaceIapTokenProvider: true,
          ),
        ).throws<Object>();
        check(repository.transport.iapTokenProvider).isNull();
        check(seenHeaders.last).isNull();
      }, _TrustLoopbackCertHttpOverrides()),
    );

    test(
      'attaches refreshed Authorization: Bearer headers over wss:// and recovers viewer token via reconnect',
      () => HttpOverrides.runWithHttpOverrides(() async {
        final seenAuthHeaders = <String?>[];
        final seenViewerTokens = <String>[];
        final server = await _bindMockIapTlsRelay(
          expectedViewerToken: 'viewer-secret',
          onUpgradeRequest: seenAuthHeaders.add,
          onAuthFrameToken: seenViewerTokens.add,
        );
        addTearDown(() => server.close(force: true));

        var mintCount = 0;
        final uri = Uri.parse('wss://127.0.0.1:${server.port}/v1/client');
        final transport = WsClientTransport(
          serverUri: uri,
          token: 'wrong-viewer-token',
          iapTokenProvider: () async => 'iap-jwt-${++mintCount}',
        );
        final repository = CastClientRepository(
          transport: transport,
          baseReconnectDelay: const Duration(milliseconds: 20),
          maxReconnectDelay: const Duration(milliseconds: 50),
        );
        addTearDown(repository.dispose);

        final received = <CastMessage>[];
        clientMessageReceivedEvent.addListener(repository.bus, received.add);

        // 1. First connect passes IAP header ('iap-jwt-1') but fails inner AuthFrame ('wrong-viewer-token').
        await repository.connect(retryOnFailure: true);
        await _waitFor(() => received.any((m) => m is ErrorFrame));
        check(seenAuthHeaders).deepEquals(['Bearer iap-jwt-1']);
        check(seenViewerTokens).deepEquals(['wrong-viewer-token']);
        check(repository.willAutoReconnect).isFalse();

        // 2. Interactive reconnect to same wss:// endpoint updates viewer token and mints fresh IAP JWT ('iap-jwt-2').
        received.clear();
        await repository.reconnect((serverUri: uri, token: 'viewer-secret'));
        await _waitFor(() => received.any((m) => m is AuthAcceptedFrame));
        check(
          seenAuthHeaders,
        ).deepEquals(['Bearer iap-jwt-1', 'Bearer iap-jwt-2']);
        check(
          seenViewerTokens,
        ).deepEquals(['wrong-viewer-token', 'viewer-secret']);
      }, _TrustLoopbackCertHttpOverrides()),
    );

    test(
      'rejects blank IAP tokens and retries transient provider failures via repository backoff',
      () => HttpOverrides.runWithHttpOverrides(() async {
        final seenHeaders = <String?>[];
        final server = await _bindMockIapTlsRelay(
          expectedViewerToken: 'ok',
          onUpgradeRequest: seenHeaders.add,
          onAuthFrameToken: (_) {},
        );
        addTearDown(() => server.close(force: true));
        final uri = Uri.parse('wss://127.0.0.1:${server.port}/v1/client');

        final blankTransport = WsClientTransport(
          serverUri: uri,
          token: 'ok',
          iapTokenProvider: () async => '   ',
        );
        addTearDown(blankTransport.close);
        await check(blankTransport.connect()).throws<StateError>();

        var attempt = 0;
        final transientTransport = WsClientTransport(
          serverUri: uri,
          token: 'ok',
          iapTokenProvider: () async {
            attempt++;
            if (attempt == 1) {
              throw const SocketException('metadata endpoint unreachable');
            }
            return 'iap-recovered';
          },
        );
        final repository = CastClientRepository(
          transport: transientTransport,
          baseReconnectDelay: const Duration(milliseconds: 20),
          maxReconnectDelay: const Duration(milliseconds: 40),
        );
        addTearDown(repository.dispose);

        final received = <CastMessage>[];
        clientMessageReceivedEvent.addListener(repository.bus, received.add);
        await repository.connect(retryOnFailure: true);
        await _waitFor(() => received.any((m) => m is AuthAcceptedFrame));
        check(attempt).equals(2);
        check(seenHeaders).deepEquals(['Bearer iap-recovered']);
      }, _TrustLoopbackCertHttpOverrides()),
    );
  });

  group('adaptBinaryWebSocketChannel synchronous delivery & lifecycle', () {
    test(
      'forwards Uint8List zero-copy, converts List<int>, rejects non-bytes, forwards errors, and closes cleanly',
      () async {
        final incoming = StreamController<Object?>(sync: true);
        final sent = <Object?>[];
        final sinkErrors = <Object>[];
        var sinkClosed = false;
        final fakeChannel = _SyncFakeWsChannel(
          stream: incoming.stream,
          onAdd: sent.add,
          onAddError: (err, _) => sinkErrors.add(err),
          onClose: () => sinkClosed = true,
        );

        final adapted = adaptBinaryWebSocketChannel(fakeChannel);
        final received = <Uint8List>[];
        final errors = <Object>[];
        var streamDone = false;
        final sub = adapted.stream.listen(
          received.add,
          onError: errors.add,
          onDone: () => streamDone = true,
        );

        // Synchronous Uint8List delivery preserves the exact buffer instance.
        final direct = Uint8List.fromList([10, 20, 30]);
        incoming.add(direct);
        check(received).length.equals(1);
        check(identical(received.single, direct)).isTrue();

        // Synchronous List<int> conversion to Uint8List.
        incoming.add(<int>[40, 50]);
        check(received).length.equals(2);
        check(received[1]).deepEquals([40, 50]);

        // Non-byte frames emit ProtocolFormatException synchronously.
        incoming.add('text-frame');
        check(errors).length.equals(1);
        check(errors.single).isA<ProtocolFormatException>();

        // Upstream errors propagate synchronously.
        incoming.addError(StateError('upstream-err'));
        check(errors).length.equals(2);
        check(errors[1]).isA<StateError>();

        // Outbound sink delivers synchronously without extra microtask hops.
        final outbound = Uint8List.fromList([99, 100]);
        adapted.sink.add(outbound);
        check(sent).length.equals(1);
        check(identical(sent.single, outbound)).isTrue();

        final outboundErr = ArgumentError('bad-outbound');
        adapted.sink.addError(outboundErr);
        check(sinkErrors).deepEquals([outboundErr]);

        await incoming.close();
        check(streamDone).isTrue();
        await sub.cancel();

        await adapted.sink.close();
        check(sinkClosed).isTrue();
      },
    );

    test('rejects serverUri containing embedded userInfo credentials', () {
      check(
        () => WsClientTransport(
          serverUri: Uri.parse('wss://alice:secret@relay.example.com/ws'),
        ),
      ).throws<FormatException>();
    });
  });
}

Future<HttpServer> _bindMockIapTlsRelay({
  required String expectedViewerToken,
  required void Function(String? authHeader) onUpgradeRequest,
  required void Function(String viewerToken) onAuthFrameToken,
}) async {
  final ctx = SecurityContext()
    ..useCertificateChainBytes(_loopbackCertPem.codeUnits)
    ..usePrivateKeyBytes(_loopbackKeyPem.codeUnits);
  final server = await HttpServer.bindSecure(
    InternetAddress.loopbackIPv4,
    0,
    ctx,
  );
  server.listen((req) async {
    final authHeader = req.headers.value(HttpHeaders.authorizationHeader);
    onUpgradeRequest(authHeader);
    if (authHeader == null || !authHeader.startsWith('Bearer iap-')) {
      req.response.statusCode = HttpStatus.unauthorized;
      await req.response.close();
      return;
    }
    final (:channel, :closeWithCode) = await upgradeCastWebSocket(req);
    late final StreamSubscription<Uint8List> sub;
    sub = channel.stream.listen((raw) async {
      final msg = BufferFrameCodec.decode(raw);
      if (msg is AuthFrame) {
        onAuthFrameToken(msg.token);
        if (msg.token != expectedViewerToken) {
          channel.sink.add(
            BufferFrameCodec.encode(
              const ErrorFrame(
                code: 'auth_failed',
                message: 'Invalid viewer token',
              ),
            ),
          );
          await sub.cancel();
          await closeWithCode(4003, 'auth_failed');
          return;
        }
        channel.sink.add(
          BufferFrameCodec.encode(const AuthAcceptedFrame(role: .client)),
        );
      }
    });
  });
  return server;
}

Future<void> _waitFor(
  bool Function() predicate, {
  Duration timeout = const Duration(seconds: 4),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!predicate()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('Condition not met within $timeout');
    }
    await Future<void>.delayed(const Duration(milliseconds: 15));
  }
}

final class _SyncFakeWsChannel extends StreamChannelMixin<Object?>
    implements WebSocketChannel {
  @override
  final Stream<Object?> stream;

  @override
  final WebSocketSink sink;

  _SyncFakeWsChannel({
    required this.stream,
    required void Function(Object? data) onAdd,
    required void Function(Object error, StackTrace? stackTrace) onAddError,
    required void Function() onClose,
  }) : sink = _SyncFakeWsSink(onAdd, onAddError, onClose);

  @override
  int? get closeCode => null;

  @override
  String? get closeReason => null;

  @override
  String? get protocol => null;

  @override
  Future<void> get ready => Future<void>.value();
}

final class _SyncFakeWsSink implements WebSocketSink {
  final void Function(Object? data) _onAdd;
  final void Function(Object error, StackTrace? stackTrace) _onAddError;
  final void Function() _onClose;

  _SyncFakeWsSink(this._onAdd, this._onAddError, this._onClose);

  @override
  final Future<void> done = Future<void>.value();

  @override
  void add(Object? data) => _onAdd(data);

  @override
  void addError(Object error, [StackTrace? stackTrace]) =>
      _onAddError(error, stackTrace);

  @override
  Future<void> addStream(Stream<Object?> stream) => stream.forEach(_onAdd);

  @override
  Future<void> close([int? closeCode, String? closeReason]) async {
    _onClose();
  }
}
