@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:checks/checks.dart';
import 'package:crypto/crypto.dart';
import 'package:termui_cast_protocol/termui_cast_protocol.dart';
import 'package:termui_cast_protocol/termui_cast_protocol_io.dart';
import 'package:test/test.dart';

void main() {
  group('io_websocket_channel', () {
    test(
      'enforces maxPayloadLength, rejects text frames, and swallows TCP reset errors on sink.done',
      () async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => server.close(force: true));

        final serverErrors = <Object>[];
        server.listen((req) async {
          final (:channel, :closeWithCode) = await upgradeCastWebSocket(
            req,
            maxPayloadLength: 256,
          );
          channel.stream.listen(
            channel.sink.add,
            onError: (Object err) {
              serverErrors.add(err);
              unawaited(closeWithCode(1008, 'Protocol error'));
            },
          );
        });

        final uri = Uri.parse('ws://127.0.0.1:${server.port}/ws');

        // 1. Oversized frame (> 256 bytes) is rejected before delivery.
        final hugeWs = await WebSocket.connect('$uri');
        hugeWs.add(Uint8List(1024));
        await hugeWs.drain<void>().timeout(const Duration(seconds: 3));
        check(const <int?>[1002, 1008, 1009]).contains(hugeWs.closeCode);

        // 2. Text frame triggers ProtocolFormatException and 1008 close.
        final textWs = await WebSocket.connect('$uri');
        textWs.add('not-binary');
        await textWs.drain<void>().timeout(const Duration(seconds: 3));
        check(textWs.closeCode).equals(1008);
        check(serverErrors).any((it) => it.isA<ProtocolFormatException>());

        // 3. Abrupt TCP reset both mid-handshake and mid-stream does not surface unhandled async error.
        final rstHandshake = await HttpServer.bind(
          InternetAddress.loopbackIPv4,
          0,
        );
        addTearDown(() => rstHandshake.close(force: true));
        rstHandshake.listen((req) async {
          final rawSock = await req.response.detachSocket(writeHeaders: false);
          rawSock.destroy();
        });
        await check(
          connectCastWebSocket(
            Uri.parse('ws://127.0.0.1:${rstHandshake.port}/ws'),
          ),
        ).throws<Object>();

        // Verify mid-stream TCP RST (via TCP proxy Socket.destroy) closes channel without unhandled sink.done error.
        final backend = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => backend.close(force: true));
        backend.listen((req) async {
          final (:channel, closeWithCode: _) = await upgradeCastWebSocket(req);
          channel.stream.listen((_) {}, onError: (Object _) {});
        });

        final proxy = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(proxy.close);
        final proxySockets = <Socket>[];
        proxy.listen((inbound) async {
          proxySockets.add(inbound);
          final outbound = await Socket.connect('127.0.0.1', backend.port);
          proxySockets.add(outbound);
          inbound.listen(
            outbound.add,
            onError: (Object _) {},
            onDone: outbound.destroy,
          );
          outbound.listen(
            inbound.add,
            onError: (Object _) {},
            onDone: inbound.destroy,
          );
        });

        final clientChan = await connectCastWebSocket(
          Uri.parse('ws://127.0.0.1:${proxy.port}/ws'),
        );
        final closedCompleter = Completer<void>();
        clientChan.stream.listen(
          (_) {},
          onError: (Object _) {},
          onDone: () {
            if (!closedCompleter.isCompleted) closedCompleter.complete();
          },
        );
        for (final s in proxySockets) {
          s.destroy();
        }
        await closedCompleter.future.timeout(const Duration(seconds: 3));
        await clientChan.sink.done;
      },
    );

    test(
      'propagates TCP write backpressure through addStream, closes cleanly while bound, and wires incoming pause/resume/cancel',
      () async {
        // Use a TCP proxy that stops reading from server -> client to induce real TCP write backpressure!
        final serverPaused = Completer<void>();
        late Future<void> Function(int, String) serverCloseWithCode;

        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => server.close(force: true));
        server.listen((req) async {
          final (:channel, :closeWithCode) = await upgradeCastWebSocket(req);
          serverCloseWithCode = closeWithCode;
          late final StreamController<Uint8List> source;
          Timer? pumpTimer;
          source = StreamController<Uint8List>(
            onListen: () {
              final chunk = Uint8List(32768);
              pumpTimer = Timer.periodic(const Duration(milliseconds: 1), (_) {
                if (!source.isClosed && !source.isPaused) {
                  source.add(chunk);
                }
              });
            },
            onPause: () {
              pumpTimer?.cancel();
              if (!serverPaused.isCompleted) serverPaused.complete();
            },
            onCancel: () {
              pumpTimer?.cancel();
            },
          );
          unawaited(channel.sink.addStream(source.stream));
        });

        // Proxy accepts client WebSocket handshake, then pauses forwarding server->client TCP bytes.
        final proxy = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(proxy.close);
        StreamSubscription<Uint8List>? backendToClientSub;
        final sockets = <Socket>[];
        bool upgraded = false;
        proxy.listen((clientSock) async {
          sockets.add(clientSock);
          final backendSock = await Socket.connect('127.0.0.1', server.port);
          sockets.add(backendSock);
          clientSock.listen(
            backendSock.add,
            onError: (Object _) {},
            onDone: () =>
                unawaited(backendSock.close().catchError((Object _) {})),
          );
          backendToClientSub = backendSock.listen(
            (data) {
              clientSock.add(data);
              if (!upgraded &&
                  String.fromCharCodes(data).contains('\r\n\r\n')) {
                upgraded = true;
                backendToClientSub?.pause();
              }
            },
            onError: (Object _) {},
            onDone: () =>
                unawaited(clientSock.close().catchError((Object _) {})),
          );
        });
        addTearDown(() {
          for (final s in sockets) {
            s.destroy();
          }
        });

        final clientWs = await WebSocket.connect(
          'ws://127.0.0.1:${proxy.port}/ws',
        );
        addTearDown(() => clientWs.close());

        // Server's addStream source must receive onPause when TCP send/recv buffers fill!
        await serverPaused.future.timeout(const Duration(seconds: 3));

        // Resume proxy forwarding and close server sink while addStream is still active -> must not throw StateError!
        backendToClientSub?.resume();
        await serverCloseWithCode(1008, 'backpressure-evict');
        await clientWs.drain<void>().timeout(const Duration(seconds: 3));
        check(clientWs.closeCode).equals(1008);

        // Verify wrapIoBinaryWebSocket forwards pause, resume, and cancel to underlying WebSocket.
        final pauseEvents = <String>[];
        final fakeWs = _FakePauseTrackingWebSocket(pauseEvents.add);
        final wrapped = wrapIoBinaryWebSocket(fakeWs);
        final sub = wrapped.channel.stream.listen((_) {});
        sub.pause();
        check(pauseEvents).contains('pause');
        sub.resume();
        check(pauseEvents).contains('resume');
        await sub.cancel();
        check(pauseEvents).contains('cancel');
      },
    );

    test(
      'aborts pre-auth >16 KiB floods and fragmented FIN=0 continuation floods',
      () async {
        final serverErrors = <Object>[];
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => server.close(force: true));
        server.listen((req) async {
          final (:channel, :closeWithCode) = await upgradeCastWebSocket(
            req,
            maxPayloadLength: 1024,
          );
          channel.stream.listen(
            channel.sink.add,
            onError: (Object err) {
              serverErrors.add(err);
              unawaited(closeWithCode(1008, 'Protocol error'));
            },
          );
        });

        final uri = Uri.parse('ws://127.0.0.1:${server.port}/ws');

        // 1. Pre-auth frame > 16 KiB is rejected before buffering.
        final preAuthWs = await WebSocket.connect('$uri');
        preAuthWs.add(Uint8List(maxPreAuthRawBytes + 512));
        await preAuthWs.drain<void>().timeout(const Duration(seconds: 3));
        check(const <int?>[1002, 1008, 1009]).contains(preAuthWs.closeCode);
        check(serverErrors).any((it) => it.isA<ProtocolFormatException>());

        // 2. Post-auth FIN=0 continuation flood (> maxPayloadLength + 65536) is aborted.
        serverErrors.clear();
        final rawSock = await Socket.connect('127.0.0.1', server.port);
        addTearDown(rawSock.destroy);
        rawSock.write(
          'GET /ws HTTP/1.1\r\n'
          'Host: 127.0.0.1:${server.port}\r\n'
          'Upgrade: websocket\r\n'
          'Connection: Upgrade\r\n'
          'Sec-WebSocket-Version: 13\r\n'
          'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\r\n',
        );
        await rawSock.flush();

        final sockClosed = Completer<void>();
        final responseBuf = BytesBuilder();
        final upgradedCompleter = Completer<void>();
        rawSock.listen(
          (chunk) {
            responseBuf.add(chunk);
            if (!upgradedCompleter.isCompleted &&
                String.fromCharCodes(
                  responseBuf.toBytes(),
                ).contains('\r\n\r\n')) {
              upgradedCompleter.complete();
            }
          },
          onError: (Object _) {
            if (!sockClosed.isCompleted) sockClosed.complete();
          },
          onDone: () {
            if (!sockClosed.isCompleted) sockClosed.complete();
          },
        );
        await upgradedCompleter.future.timeout(const Duration(seconds: 3));

        // Send a valid small first binary frame (FIN=1, opcode=0x02, masked, 4 bytes) to pass pre-auth.
        rawSock.add(const [
          0x82, // FIN=1, binary
          0x84, // MASK=1, len=4
          0x00, 0x00, 0x00, 0x00, // zero mask key
          0x01, 0x02, 0x03, 0x04,
        ]);
        await rawSock.flush();
        await Future<void>.delayed(const Duration(milliseconds: 20));

        // Now send a fragmented initial frame (FIN=0, opcode=0x02) followed by FIN=0 continuation
        // frames (opcode=0x00), each 512 bytes (<= maxPayloadLength=1024), until total unconsumed
        // bytes exceed 1024 + 65536.
        Uint8List buildMaskedFrame(int firstByte, int payloadLen) {
          final b = BytesBuilder()
            ..addByte(firstByte)
            ..addByte(0x80 | 126)
            ..addByte((payloadLen >> 8) & 0xFF)
            ..addByte(payloadLen & 0xFF)
            ..add(const [0, 0, 0, 0])
            ..add(Uint8List(payloadLen));
          return b.takeBytes();
        }

        rawSock.add(buildMaskedFrame(0x02, 512)); // FIN=0, opcode=binary
        final contFrame = buildMaskedFrame(0x00, 512); // FIN=0, continuation
        for (var i = 0; i < 140; i++) {
          rawSock.add(contFrame);
        }
        await rawSock.flush().catchError((Object _) {});
        await sockClosed.future.timeout(const Duration(seconds: 3));
        check(serverErrors).any((it) => it.isA<ProtocolFormatException>());
      },
    );

    test(
      'watchPosixHangupSignals delivers SIGHUP on POSIX and stays empty on Windows',
      _verifyPosixHangupSignals,
      timeout: const Timeout(Duration(seconds: 60)),
    );

    test(
      'connectCastWebSocket destroys blackholed socket on close timeout and rejects non-upgrade responses',
      _verifyBlackholedCloseAndBadUpgrade,
    );

    test(
      'rejects HTTP redirects, malformed 101 upgrade headers, and cleans up timed-out late upgrades',
      _verifyUpgradeHardeningAndTimeoutCleanup,
    );
  });
}

Future<void> _verifyPosixHangupSignals() async {
  final signals = watchPosixHangupSignals();
  if (Platform.isWindows) {
    check(await signals.toList()).isEmpty();
    return;
  }
  check(signals.isBroadcast).isTrue();

  final packageConfig = await Isolate.packageConfig;
  check(packageConfig).isNotNull();
  final tempDir = Directory.systemTemp.createTempSync('watch_sighup_');
  addTearDown(() => tempDir.deleteSync(recursive: true));
  final childScript = File('${tempDir.path}/child_sighup.dart')
    ..writeAsStringSync('''
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:termui_cast_protocol/termui_cast_protocol_io.dart';

Future<void> main() async {
  final signals = watchPosixHangupSignals();
  final stdinLines = StreamIterator(
    stdin.transform(utf8.decoder).transform(const LineSplitter()),
  );
  for (var cycle = 1; cycle <= 2; cycle++) {
    final seen = Completer<ProcessSignal>();
    final sub = signals.listen((sig) {
      if (!seen.isCompleted) seen.complete(sig);
    });
    stdout.writeln('LISTENING_\$cycle');
    final sig = await seen.future.timeout(const Duration(seconds: 5));
    if (sig != ProcessSignal.sighup) exit(2);
    await sub.cancel();
    stdout.writeln('CANCELED_\$cycle');
    if (cycle == 1) {
      if (!await stdinLines.moveNext()) exit(3);
      await stdinLines.cancel();
    }
  }
}
''');

  final child = await Process.start(Platform.resolvedExecutable, [
    '--packages=${packageConfig!.toFilePath()}',
    childScript.path,
  ]);
  addTearDown(child.kill);
  final stderrLines = <String>[];
  child.stderr
      .transform(utf8.decoder)
      .transform(const LineSplitter())
      .listen(stderrLines.add);
  final outLines = StreamIterator(
    child.stdout.transform(utf8.decoder).transform(const LineSplitter()),
  );

  check(
    await outLines.moveNext().timeout(const Duration(seconds: 30)),
    because: 'stderr=$stderrLines',
  ).isTrue();
  check(outLines.current).equals('LISTENING_1');
  check(Process.killPid(child.pid, .sighup)).isTrue();
  check(await outLines.moveNext().timeout(const Duration(seconds: 5))).isTrue();
  check(outLines.current).equals('CANCELED_1');

  child.stdin.writeln('NEXT');
  await child.stdin.close();

  check(await outLines.moveNext().timeout(const Duration(seconds: 5))).isTrue();
  check(outLines.current).equals('LISTENING_2');
  check(Process.killPid(child.pid, .sighup)).isTrue();
  check(await outLines.moveNext().timeout(const Duration(seconds: 5))).isTrue();
  check(outLines.current).equals('CANCELED_2');

  check(await child.exitCode.timeout(const Duration(seconds: 5))).equals(0);
}

Future<void> _verifyBlackholedCloseAndBadUpgrade() async {
  // 1. Non-upgrade HTTP 200 response and unsupported scheme throw cleanly.
  final plainHttp = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  addTearDown(() => plainHttp.close(force: true));
  plainHttp.listen((req) async {
    req.response.statusCode = HttpStatus.ok;
    await req.response.close();
  });
  await check(
    connectCastWebSocket(Uri.parse('ws://127.0.0.1:${plainHttp.port}/ws')),
  ).throws<WebSocketException>();
  await check(
    connectCastWebSocket(Uri.parse('http://127.0.0.1:${plainHttp.port}/ws')),
  ).throws<WebSocketException>();

  // 2. Embedded userInfo credentials in URI are rejected, and
  // unawaited(sub.cancel()) followed by sink.add + closeWithCode(1008) preserves
  // both the final frame and the 1008 close code.
  final backend = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  addTearDown(() => backend.close(force: true));
  backend.listen((req) async {
    final (:channel, :closeWithCode) = await upgradeCastWebSocket(req);
    late final StreamSubscription<Uint8List> srvSub;
    srvSub = channel.stream.listen((data) async {
      if (data.length == 1 && data[0] == 0xFE) {
        unawaited(srvSub.cancel());
        channel.sink.add(Uint8List.fromList([0xFF]));
        await closeWithCode(1008, 'rejected');
      }
    }, onError: (Object _) {});
  });
  await check(
    connectCastWebSocket(
      Uri.parse('ws://alice:secret@127.0.0.1:${backend.port}/ws'),
    ),
  ).throws<FormatException>();

  final rejectWs = await WebSocket.connect('ws://127.0.0.1:${backend.port}/ws');
  rejectWs.add(Uint8List.fromList([0xFE]));
  final rejectFrames = await rejectWs.cast<List<int>>().toList().timeout(
    const Duration(seconds: 3),
  );
  check(rejectFrames.single).deepEquals([0xFF]);
  check(rejectWs.closeCode).equals(1008);

  // 3. Blackholed socket deterministically destroys underlying TCP socket for
  // both sink.close()-first and sub.cancel()-first teardown orders.
  final proxy = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  addTearDown(proxy.close);
  final sockets = <Socket>[];
  final inboundClosedCompleters = <Completer<void>>[];
  var blackholed = false;
  proxy.listen((inbound) async {
    sockets.add(inbound);
    final closed = Completer<void>();
    inboundClosedCompleters.add(closed);
    final outbound = await Socket.connect('127.0.0.1', backend.port);
    sockets.add(outbound);
    inbound.listen(
      (d) {
        if (!blackholed) outbound.add(d);
      },
      onError: (Object _) {
        if (!closed.isCompleted) closed.complete();
      },
      onDone: () {
        if (!closed.isCompleted) closed.complete();
      },
    );
    outbound.listen((d) {
      if (!blackholed) inbound.add(d);
    }, onError: (Object _) {});
  });
  addTearDown(() {
    for (final s in sockets) {
      s.destroy();
    }
  });

  // 3a. sink.close() before sub.cancel().
  final chan1 = await connectCastWebSocket(
    Uri.parse('ws://127.0.0.1:${proxy.port}/ws'),
  );
  final sub1 = chan1.stream.listen((_) {});
  final inbound1Closed = inboundClosedCompleters.last;
  blackholed = true;
  final closeFuture1 = chan1.sink.close();
  await sub1.cancel();
  await closeFuture1.timeout(const Duration(seconds: 3));
  await chan1.sink.done.timeout(const Duration(seconds: 3));
  await inbound1Closed.future.timeout(const Duration(seconds: 3));

  // 3b. sub.cancel() before sink.close().
  blackholed = false;
  final chan2 = await connectCastWebSocket(
    Uri.parse('ws://127.0.0.1:${proxy.port}/ws'),
  );
  final sub2 = chan2.stream.listen((_) {});
  final inbound2Closed = inboundClosedCompleters.last;
  blackholed = true;
  await sub2.cancel().timeout(const Duration(seconds: 3));
  await chan2.sink.done.timeout(const Duration(seconds: 3));
  await inbound2Closed.future.timeout(const Duration(seconds: 3));
}

Future<void> _verifyUpgradeHardeningAndTimeoutCleanup() async {
  await _assertRedirectBlocked();
  await _assertFailedUpgradeStripsQueryAndFragment();
  await _assertMalformedUpgradeHeadersRejected();
  await _assertTimeoutDestroysLateUpgradedSocket();

  var closeTimedOut = false;
  final stalledSink = IoBinaryWebSocketSink(
    _FakePauseTrackingWebSocket((_) {}, hangClose: true),
    handshakeDone: Future<void>.value(),
    onCloseTimeout: () => closeTimedOut = true,
  );
  await stalledSink.close().timeout(const Duration(seconds: 2));
  check(closeTimedOut).isTrue();
}

Future<void> _assertRedirectBlocked() async {
  var redirectHits = 0;
  final trapServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  addTearDown(() => trapServer.close(force: true));
  trapServer.listen((req) async {
    redirectHits++;
    final (:channel, closeWithCode: _) = await upgradeCastWebSocket(req);
    channel.stream.listen((_) {}, onError: (Object _) {});
  });

  final redirector = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  addTearDown(() => redirector.close(force: true));
  redirector.listen((req) async {
    req.response.statusCode = HttpStatus.found;
    req.response.headers.set(
      HttpHeaders.locationHeader,
      'http://127.0.0.1:${trapServer.port}/ws',
    );
    await req.response.close();
  });

  await check(
    connectCastWebSocket(Uri.parse('ws://127.0.0.1:${redirector.port}/ws')),
  ).throws<WebSocketException>();
  check(redirectHits).equals(0);
}

Future<void> _assertFailedUpgradeStripsQueryAndFragment() async {
  final srv = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  addTearDown(() => srv.close(force: true));
  srv.listen((req) async {
    req.response.statusCode = HttpStatus.unauthorized;
    await req.response.close();
  });

  Object? caught;
  try {
    await connectCastWebSocket(
      Uri.parse(
        'ws://127.0.0.1:${srv.port}/v1/client?token=secretQuery#secretFrag',
      ),
    );
  } on WebSocketException catch (e) {
    caught = e;
  }
  check(caught).isA<WebSocketException>();
  final message = '$caught';
  check(message).contains('/v1/client');
  check(message).not((it) => it.contains('secretQuery'));
  check(message).not((it) => it.contains('secretFrag'));
}

Future<void> _assertMalformedUpgradeHeadersRejected() async {
  const wsGuid = '258EAFA5-E914-47DA-95CA-C5AB0DC85B11';
  var mode = '';
  final rawSrv = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  addTearDown(rawSrv.close);
  rawSrv.listen((sock) {
    final buf = StringBuffer();
    sock.listen((chunk) async {
      buf.write(ascii.decode(chunk, allowInvalid: true));
      final text = '$buf';
      if (!text.contains('\r\n\r\n')) return;
      final keyMatch = RegExp(
        r'sec-websocket-key:\s*([^\r\n]+)',
        caseSensitive: false,
      ).firstMatch(text);
      final key = keyMatch?.group(1)?.trim() ?? '';
      final accept = base64.encode(
        sha1.convert(utf8.encode('$key$wsGuid')).bytes,
      );
      final extra = switch (mode) {
        'ext' =>
          'Upgrade: websocket\r\nSec-WebSocket-Accept: $accept\r\n'
              'Sec-WebSocket-Extensions: permessage-deflate\r\n',
        'proto' =>
          'Upgrade: websocket\r\nSec-WebSocket-Accept: $accept\r\n'
              'Sec-WebSocket-Protocol: chat\r\n',
        'dup-accept' =>
          'Upgrade: websocket\r\nSec-WebSocket-Accept: $accept\r\n'
              'Sec-WebSocket-Accept: $accept\r\n',
        _ =>
          'Upgrade: websocket\r\nUpgrade: h2c\r\n'
              'Sec-WebSocket-Accept: $accept\r\n',
      };
      sock.write(
        'HTTP/1.1 101 Switching Protocols\r\nConnection: Upgrade\r\n$extra\r\n',
      );
      await sock.flush().catchError((Object _) {});
    }, onError: (Object _) {});
  });

  for (final testMode in ['ext', 'proto', 'dup-accept', 'dup-upgrade']) {
    mode = testMode;
    await check(
      connectCastWebSocket(Uri.parse('ws://127.0.0.1:${rawSrv.port}/ws')),
    ).throws<WebSocketException>();
  }
}

Future<void> _assertTimeoutDestroysLateUpgradedSocket() async {
  final peerClosed = Completer<void>();
  var serverUpgraded = 0;
  final wsSrv = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  addTearDown(() => wsSrv.close(force: true));
  wsSrv.listen((req) async {
    final (:channel, closeWithCode: _) = await upgradeCastWebSocket(req);
    serverUpgraded++;
    channel.stream.listen(
      (_) {},
      onError: (Object _) {},
      onDone: () {
        if (!peerClosed.isCompleted) peerClosed.complete();
      },
    );
  });

  final slowClient = HttpClient()
    ..connectionFactory = (uri, _, _) async {
      await Future<void>.delayed(const Duration(milliseconds: 80));
      return Socket.startConnect(uri.host, uri.port);
    };
  await check(
    HttpOverrides.runZoned(
      () => connectCastWebSocket(
        Uri.parse('ws://127.0.0.1:${wsSrv.port}/ws'),
        timeout: const Duration(milliseconds: 20),
      ),
      createHttpClient: (_) => slowClient,
    ),
  ).throws<TimeoutException>();

  await peerClosed.future.timeout(const Duration(seconds: 3));
  check(serverUpgraded).equals(1);
}

final class _FakePauseTrackingWebSocket extends Stream<Object?>
    implements WebSocket {
  final void Function(String event) onEvent;
  final bool hangClose;
  final Completer<void> _doneCompleter = Completer<void>();

  _FakePauseTrackingWebSocket(this.onEvent, {this.hangClose = false});

  @override
  Duration? pingInterval;

  @override
  int get readyState => WebSocket.open;

  @override
  Future<Object?> get done => _doneCompleter.future;

  @override
  StreamSubscription<Object?> listen(
    void Function(Object? event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    final controller = StreamController<Object?>(
      onPause: () => onEvent('pause'),
      onResume: () => onEvent('resume'),
      onCancel: () => onEvent('cancel'),
    );
    return controller.stream.listen(
      onData,
      onError: onError,
      onDone: onDone,
      cancelOnError: cancelOnError,
    );
  }

  @override
  Future<Object?> close([int? code, String? reason]) async {
    if (hangClose) return Completer<Object?>().future;
    if (!_doneCompleter.isCompleted) _doneCompleter.complete();
    return null;
  }

  @override
  Object? noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
