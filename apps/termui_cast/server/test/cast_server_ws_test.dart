import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:checks/checks.dart';
import 'package:termui_cast_protocol/termui_cast_protocol.dart';
import 'package:termui_cast_protocol/termui_cast_protocol_io.dart';
import 'package:termui_cast_server/termui_cast_server.dart';
import 'package:test/test.dart';

void main() {
  group('ServerConfig and CLI guardrails', () {
    test('rejects non-loopback bind without both caster and client tokens', () {
      check(
        () => ServerConfig(
          host: InternetAddress.anyIPv4,
          port: 8420,
          casterToken: 'only-caster',
        ),
      ).throws<FormatException>();

      check(
        () => ServerConfig.fromArgs(['--host', '0.0.0.0']),
      ).throws<FormatException>();

      check(() => ServerConfig(port: 70000)).throws<FormatException>();
      check(
        () => ServerConfig.fromArgs(['unexpected']),
      ).throws<FormatException>();
      check(
        () => ServerConfig.fromArgs(['--host', 'not-an-ip']),
      ).throws<FormatException>();
      check(
        () => ServerConfig.fromArgs(['--port', 'abc']),
      ).throws<FormatException>();

      final localCfg = ServerConfig.fromArgs([
        '--host',
        'localhost',
        '--port',
        '0',
      ]);
      check(localCfg).isNotNull();
      check(localCfg!.host).equals(InternetAddress.loopbackIPv4);
    });

    test(
      'returns exit code 64 on invalid CLI flags, warns on plaintext non-loopback, and exits 0 on clean shutdown',
      () async {
        final errBuf = StringBuffer();
        final badExit = await runServerCli(['--host', '0.0.0.0'], err: errBuf);
        check(badExit).equals(64);
        check(errBuf.toString()).contains('--caster-token');

        final outBuf = StringBuffer();
        final helpExit = await runServerCli(['--help'], out: outBuf);
        check(helpExit).equals(0);
        check(outBuf.toString()).contains('--port');

        final shutdown = StreamController<void>();
        final runOut = _NotifyingStringSink();
        final runErr = StringBuffer();
        final runFuture = runServerCli(
          [
            '--host',
            '0.0.0.0',
            '--port',
            '0',
            '--caster-token',
            'c-tok',
            '--client-token',
            'v-tok',
          ],
          out: runOut,
          err: runErr,
          shutdownSignal: shutdown.stream,
        );
        await runOut.ready.future.timeout(const Duration(seconds: 3));
        shutdown.add(null);
        await shutdown.close();
        check(await runFuture).equals(0);
        check(runOut.buffer.toString()).contains('ws://127.0.0.1:');
        check(runErr.toString()).contains('WARNING: Binding non-loopback');
      },
    );

    test(
      'logs bound host:port alongside clickable http:// and normalized ws:// endpoints (#425)',
      () async {
        // 1. Wildcard IPv4 bind (0.0.0.0) logs bound 0.0.0.0:<port> plus local http:// and ws:// endpoints.
        final wildcardShutdown = StreamController<void>();
        addTearDown(wildcardShutdown.close);
        final wildcardOut = _NotifyingStringSink();
        final wildcardErr = StringBuffer();
        final wildcardFuture = runServerCli(
          const [
            '--host',
            '0.0.0.0',
            '--port',
            '0',
            '--caster-token',
            'c-tok',
            '--client-token',
            'v-tok',
            '--no-web',
          ],
          out: wildcardOut,
          err: wildcardErr,
          shutdownSignal: wildcardShutdown.stream,
        );
        await wildcardOut.ready.future.timeout(const Duration(seconds: 3));
        wildcardShutdown.add(null);
        check(await wildcardFuture).equals(0);

        final wildcardText = wildcardOut.buffer.toString();
        final wildcardPortMatch = RegExp(
          r'ws://127\.0\.0\.1:(\d+)/v1/caster',
        ).firstMatch(wildcardText);
        check(wildcardPortMatch).isNotNull();
        final wildcardPort = wildcardPortMatch!.group(1)!;
        check(wildcardText).contains('Listening on 0.0.0.0:$wildcardPort');
        check(wildcardText).contains(
          'Local HTTP: http://127.0.0.1:$wildcardPort/ (static web disabled)',
        );
        check(wildcardText).contains(
          'Local WS:   ws://127.0.0.1:$wildcardPort/v1/caster '
          'and ws://127.0.0.1:$wildcardPort/v1/client',
        );
        check(
          wildcardErr.toString(),
        ).contains('WARNING: Binding non-loopback 0.0.0.0');

        // 2. Loopback bind with --base-path and --web-dir logs concrete 127.0.0.1:<port> without "(static web disabled)".
        final tempWebDir = Directory.systemTemp.createTempSync(
          'cast_server_cli_web_',
        );
        addTearDown(() => tempWebDir.deleteSync(recursive: true));
        File(
          '${tempWebDir.path}${Platform.pathSeparator}index.html',
        ).writeAsStringSync('<!doctype html><html></html>');

        final loopbackShutdown = StreamController<void>();
        addTearDown(loopbackShutdown.close);
        final loopbackOut = _NotifyingStringSink();
        final loopbackFuture = runServerCli(
          [
            '--host',
            '127.0.0.1',
            '--port',
            '0',
            '--base-path',
            '/term',
            '--insecure-no-auth',
            '--web-dir',
            tempWebDir.path,
          ],
          out: loopbackOut,
          err: StringBuffer(),
          shutdownSignal: loopbackShutdown.stream,
        );
        await loopbackOut.ready.future.timeout(const Duration(seconds: 3));
        loopbackShutdown.add(null);
        check(await loopbackFuture).equals(0);

        final loopbackText = loopbackOut.buffer.toString();
        final loopbackPortMatch = RegExp(
          r'ws://127\.0\.0\.1:(\d+)/term/v1/caster',
        ).firstMatch(loopbackText);
        check(loopbackPortMatch).isNotNull();
        final loopbackPort = loopbackPortMatch!.group(1)!;
        check(loopbackText).contains('Listening on 127.0.0.1:$loopbackPort');
        check(
          loopbackText,
        ).contains('HTTP: http://127.0.0.1:$loopbackPort/term/\n');
        check(loopbackText).contains(
          'WS:   ws://127.0.0.1:$loopbackPort/term/v1/caster '
          'and ws://127.0.0.1:$loopbackPort/term/v1/client',
        );
        check(loopbackText).not((it) => it.contains('Local HTTP:'));
        check(loopbackText).not((it) => it.contains('(static web disabled)'));

        // 3. Wildcard IPv6 bind (::) brackets [::]:<port> and normalizes local endpoints to [::1].
        final ipv6Shutdown = StreamController<void>();
        addTearDown(ipv6Shutdown.close);
        final ipv6Out = _NotifyingStringSink();
        final ipv6Future = runServerCli(
          const [
            '--host',
            '::',
            '--port',
            '0',
            '--caster-token',
            'c-tok',
            '--client-token',
            'v-tok',
            '--no-web',
          ],
          out: ipv6Out,
          err: StringBuffer(),
          shutdownSignal: ipv6Shutdown.stream,
        );
        await ipv6Out.ready.future.timeout(const Duration(seconds: 3));
        ipv6Shutdown.add(null);
        check(await ipv6Future).equals(0);

        final ipv6Text = ipv6Out.buffer.toString();
        final ipv6PortMatch = RegExp(
          r'ws://\[::1\]:(\d+)/v1/caster',
        ).firstMatch(ipv6Text);
        check(ipv6PortMatch).isNotNull();
        final ipv6Port = ipv6PortMatch!.group(1)!;
        check(ipv6Text).contains('Listening on [::]:$ipv6Port');
        check(
          ipv6Text,
        ).contains('Local HTTP: http://[::1]:$ipv6Port/ (static web disabled)');
        check(ipv6Text).contains(
          'Local WS:   ws://[::1]:$ipv6Port/v1/caster '
          'and ws://[::1]:$ipv6Port/v1/client',
        );

        // 4. Loopback IPv6 bind (::1) brackets [::1]:<port> without the "Local " prefix.
        final ipv6LoopbackShutdown = StreamController<void>();
        addTearDown(ipv6LoopbackShutdown.close);
        final ipv6LoopbackOut = _NotifyingStringSink();
        final ipv6LoopbackFuture = runServerCli(
          const [
            '--host',
            '::1',
            '--port',
            '0',
            '--insecure-no-auth',
            '--no-web',
          ],
          out: ipv6LoopbackOut,
          err: StringBuffer(),
          shutdownSignal: ipv6LoopbackShutdown.stream,
        );
        await ipv6LoopbackOut.ready.future.timeout(const Duration(seconds: 3));
        ipv6LoopbackShutdown.add(null);
        check(await ipv6LoopbackFuture).equals(0);

        final ipv6LoopbackText = ipv6LoopbackOut.buffer.toString();
        final ipv6LoopbackPortMatch = RegExp(
          r'ws://\[::1\]:(\d+)/v1/caster',
        ).firstMatch(ipv6LoopbackText);
        check(ipv6LoopbackPortMatch).isNotNull();
        final ipv6LoopbackPort = ipv6LoopbackPortMatch!.group(1)!;
        check(
          ipv6LoopbackText,
        ).contains('Listening on [::1]:$ipv6LoopbackPort');
        check(ipv6LoopbackText).contains(
          'HTTP: http://[::1]:$ipv6LoopbackPort/ (static web disabled)',
        );
        check(ipv6LoopbackText).not((it) => it.contains('Local HTTP:'));
      },
    );
  });

  group('CastServer ws:// and wss:// network integration', () {
    test(
      'upgrades /v1/caster and /v1/client, enforces frame ordering, rejects bad frames, and rebinds after close',
      () async {
        final server = await CastServer.bind(
          ServerConfig(
            port: 0,
            casterToken: 'c-tok',
            clientToken: 'v-tok',
            authTimeout: const Duration(milliseconds: 120),
          ),
        );
        final boundPort = server.port;

        // 1. Bad token on /v1/caster is rejected with close code 1008.
        final badWs = await WebSocket.connect('${server.casterUri}');
        badWs.add(
          BufferFrameCodec.encode(
            const AuthFrame(role: .caster, token: 'wrong'),
          ),
        );
        await badWs.drain<void>();
        check(badWs.closeCode).equals(1008);

        // 2. Silent connection exceeding authTimeout is closed with 1008.
        final idleWs = await WebSocket.connect('${server.clientUri}');
        await idleWs.drain<void>();
        check(idleWs.closeCode).equals(1008);

        // 3. Valid caster + valid client exchange directory updates over ws://.
        final casterChan = await connectCastWebSocket(server.casterUri);
        casterChan.sink.add(
          BufferFrameCodec.encode(
            const AuthFrame(role: .caster, token: 'c-tok'),
          ),
        );
        casterChan.sink.add(
          BufferFrameCodec.encode(
            const RegisterSessionFrame(
              sessionId: SessionId('live-ws'),
              title: 'bash',
              cols: 80,
              rows: 24,
            ),
          ),
        );

        final clientChan = await connectCastWebSocket(server.clientUri);
        final clientInbox = <CastMessage>[];
        final directoryCompleter = Completer<SessionDirectoryFrame>();
        clientChan.stream.listen((raw) {
          final msg = BufferFrameCodec.decode(raw);
          clientInbox.add(msg);
          if (msg is SessionDirectoryFrame &&
              msg.sessions.isNotEmpty &&
              !directoryCompleter.isCompleted) {
            directoryCompleter.complete(msg);
          }
        });

        clientChan.sink.add(
          BufferFrameCodec.encode(
            const AuthFrame(role: .client, token: 'v-tok'),
          ),
        );

        final dir = await directoryCompleter.future.timeout(
          const Duration(seconds: 3),
        );
        check(dir.sessions.single.id).equals(const SessionId('live-ws'));
        // AuthAcceptedFrame must precede the initial SessionDirectoryFrame.
        check(clientInbox.first).isA<AuthAcceptedFrame>();

        // 4. Malformed 0x09 buffer frame from an authenticated caster closes with 1008.
        final rogueCasterWs = await WebSocket.connect('${server.casterUri}');
        rogueCasterWs.add(
          BufferFrameCodec.encode(
            const AuthFrame(role: .caster, token: 'c-tok'),
          ),
        );
        // Send truncated 0x09 buffer header before registering any session.
        rogueCasterWs.add(
          Uint8List.fromList([BufferFrameCodec.protocolVersion, 0x09, 0, 1]),
        );
        await rogueCasterWs.drain<void>().timeout(const Duration(seconds: 3));
        check(rogueCasterWs.closeCode).equals(1008);

        // 5. Oversized (> 4 MiB) binary WebSocket frame is rejected at transport level.
        final hugeWs = await WebSocket.connect('${server.clientUri}');
        hugeWs.add(Uint8List(BufferFrameCodec.maxFrameBytes + 1024));
        await hugeWs.drain<void>().timeout(const Duration(seconds: 3));
        check(const <int?>[1002, 1008, 1009]).contains(hugeWs.closeCode);

        // 6. Unknown HTTP route returns 404; non-upgrade /v1/caster returns 400.
        final httpClient = HttpClient();
        addTearDown(httpClient.close);
        final req = await httpClient.getUrl(
          server.clientUri.replace(scheme: 'http', path: '/unknown'),
        );
        final resp = await req.close();
        await resp.drain<void>();
        check(resp.statusCode).equals(HttpStatus.notFound);

        final nonUpgradeReq = await httpClient.getUrl(
          server.casterUri.replace(scheme: 'http'),
        );
        final nonUpgradeResp = await nonUpgradeReq.close();
        await nonUpgradeResp.drain<void>();
        check(nonUpgradeResp.statusCode).equals(HttpStatus.badRequest);

        // 7. Text WebSocket frame on binary endpoint closes with 1008 without crashing server.
        final textWs = await WebSocket.connect('${server.clientUri}');
        textWs.add('non-binary-frame');
        await textWs.drain<void>().timeout(const Duration(seconds: 3));
        check(textWs.closeCode).equals(1008);
        check(server.registry.connectedClientCount).equals(1);

        // 8. Closing server closes active upgraded WebSockets and releases the port immediately.
        await server.close();
        await casterChan.stream.drain<void>().timeout(
          const Duration(seconds: 3),
        );
        final rebound = await CastServer.bind(ServerConfig(port: boundPort));
        addTearDown(rebound.close);
        check(rebound.port).equals(boundPort);
      },
    );

    _registerBackpressureAndOriginTests();
  });
}

void _registerBackpressureAndOriginTests() {
  test(
    'evicts stalled TCP viewer socket with 1008 under real socket backpressure without affecting healthy viewer',
    () async {
      final server = await CastServer.bind(ServerConfig(port: 0));
      addTearDown(server.close);

      // Proxy pauses server->slowClient TCP bytes right after HTTP 101 upgrade.
      final proxy = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(proxy.close);
      StreamSubscription<Uint8List>? backendToSlowSub;
      final proxySockets = <Socket>[];
      bool upgraded = false;
      proxy.listen((inbound) async {
        proxySockets.add(inbound);
        final outbound = await Socket.connect('127.0.0.1', server.port);
        proxySockets.add(outbound);
        inbound.listen(
          outbound.add,
          onError: (Object _) {},
          onDone: outbound.destroy,
        );
        backendToSlowSub = outbound.listen(
          (chunk) {
            inbound.add(chunk);
            if (!upgraded && String.fromCharCodes(chunk).contains('\r\n\r\n')) {
              upgraded = true;
              backendToSlowSub?.pause();
            }
          },
          onError: (Object _) {},
          onDone: () => unawaited(inbound.close().catchError((Object _) {})),
        );
      });
      addTearDown(() {
        for (final s in proxySockets) {
          s.destroy();
        }
      });

      const sessionId = SessionId('tcp-backpressure');
      final casterWs = await WebSocket.connect('${server.casterUri}');
      addTearDown(casterWs.close);
      casterWs.add(
        BufferFrameCodec.encode(const AuthFrame(role: .caster, token: '')),
      );
      casterWs.add(
        BufferFrameCodec.encode(
          const RegisterSessionFrame(
            sessionId: sessionId,
            title: 'flood',
            cols: 120,
            rows: 40,
          ),
        ),
      );

      final fastWs = await WebSocket.connect('${server.clientUri}');
      addTearDown(fastWs.close);
      int fastSnapshots = 0;
      int? expectedFastSnapshots;
      final allFastSnapshots = Completer<void>();
      final allSubscribed = Completer<void>();
      fastWs.listen((raw) {
        final msg = BufferFrameCodec.decode(
          raw is Uint8List ? raw : Uint8List.fromList(raw as List<int>),
        );
        if (msg is SessionDirectoryFrame &&
            msg.sessions.isNotEmpty &&
            msg.sessions.single.subscriberCount == 2 &&
            !allSubscribed.isCompleted) {
          allSubscribed.complete();
        }
        if (msg is BufferSnapshotFrame) {
          fastSnapshots++;
          if (expectedFastSnapshots != null &&
              fastSnapshots >= expectedFastSnapshots &&
              !allFastSnapshots.isCompleted) {
            allFastSnapshots.complete();
          }
        }
      });

      final slowWs = await WebSocket.connect(
        'ws://127.0.0.1:${proxy.port}/v1/client',
      );
      addTearDown(slowWs.close);

      for (final ws in [fastWs, slowWs]) {
        ws.add(
          BufferFrameCodec.encode(const AuthFrame(role: .client, token: '')),
        );
        ws.add(
          BufferFrameCodec.encode(
            const SubscribeSessionFrame(
              sessionId: sessionId,
              cols: 120,
              rows: 40,
            ),
          ),
        );
      }

      await allSubscribed.future.timeout(const Duration(seconds: 3));
      check(server.registry.connectedClientCount).equals(2);

      // Stream ~64 KiB high-entropy snapshots until slowWs overflows OS TCP buffers + 64-frame queue and is evicted!
      final highEntropyChars = List<String>.generate(
        120 * 40,
        (i) => String.fromCharCode(0x21 + ((i * 73 + (i >> 4)) % 90)),
      );
      final highEntropyAttrs = Uint32List(120 * 40 * 3);
      var lcg = 0x12345678;
      for (var i = 0; i < highEntropyAttrs.length; i++) {
        lcg = (lcg * 1664525 + 1013904223) & 0xFFFFFFFF;
        highEntropyAttrs[i] = lcg;
      }
      final snapBytes = BufferFrameCodec.encode(
        BufferSnapshotFrame(
          snapshot: BufferSnapshot(
            sessionId: sessionId,
            seq: 1,
            cols: 120,
            rows: 40,
            cursor: CursorState.origin,
            modes: TerminalModes.defaults,
            characters: highEntropyChars,
            attributes: highEntropyAttrs,
          ),
        ),
      );

      var sentCount = 0;
      while (server.registry.connectedClientCount == 2 && sentCount < 600) {
        sentCount++;
        final frame = BufferFrameCodec.encode(
          BufferSnapshotFrame(
            snapshot: BufferSnapshot(
              sessionId: sessionId,
              seq: sentCount,
              cols: 120,
              rows: 40,
              cursor: CursorState.origin,
              modes: TerminalModes.defaults,
              characters: highEntropyChars,
              attributes: highEntropyAttrs,
            ),
          ),
        );
        casterWs.add(frame);
        if (sentCount.isEven) {
          await Future<void>.delayed(const Duration(milliseconds: 1));
        }
      }
      check(snapBytes.length).isGreaterThan(55000);
      check(server.registry.connectedClientCount).equals(1);
      check(server.registry.sessions.single.subscriberCount).equals(1);

      // Resume proxy so the queued 1008 Close frame reaches slowWs cleanly.
      backendToSlowSub?.resume();
      await slowWs.drain<void>().timeout(const Duration(seconds: 3));
      check(slowWs.closeCode).equals(1008);
      // Wait for loopback fastWs to finish delivering the final in-flight snapshot.
      expectedFastSnapshots = sentCount;
      if (fastSnapshots < sentCount) {
        await allFastSnapshots.future.timeout(const Duration(seconds: 3));
      }
      check(fastSnapshots).equals(sentCount);
    },
  );

  test(
    'rejects cross-site Origin headers with 403 Forbidden while allowing loopback, same-host, and --allowed-origin via runServerCli',
    () async {
      // 1. Invalid --allowed-origin returns exit code 64 in runServerCli.
      final badOriginErr = StringBuffer();
      final badOriginCode = await runServerCli([
        '--allowed-origin',
        'ftp://bad.example',
      ], err: badOriginErr);
      check(badOriginCode).equals(64);
      check(badOriginErr.toString()).contains('--allowed-origin');

      // 2. Start server via runServerCli with --allowed-origin https://trusted.example.
      final shutdown = StreamController<void>();
      addTearDown(shutdown.close);
      final cliOut = _NotifyingStringSink();
      final cliErr = StringBuffer();
      final cliFuture = runServerCli(
        ['--port', '0', '--allowed-origin', 'https://trusted.example'],
        out: cliOut,
        err: cliErr,
        shutdownSignal: shutdown.stream,
      );
      await cliOut.ready.future.timeout(const Duration(seconds: 3));
      final cliText = cliOut.buffer.toString();
      final match = RegExp(
        r'ws://127\.0\.0\.1:(\d+)/v1/client',
      ).firstMatch(cliText)!;
      final clientUrl = match.group(0)!;
      final casterUrl = clientUrl.replaceAll('/v1/client', '/v1/caster');
      final boundPort = int.parse(match.group(1)!);

      // Verify loopback auto-minted tokens are echoed at startup and enforced.
      final casterTokMatch = RegExp(
        r'Auto-generated caster token \(TERMUI_CAST_CASTER_TOKEN\): (\S+)',
      ).firstMatch(cliText);
      final clientTokMatch = RegExp(
        r'Auto-generated client token \(TERMUI_CAST_CLIENT_TOKEN\): (\S+)',
      ).firstMatch(cliText);
      check(casterTokMatch).isNotNull();
      check(clientTokMatch).isNotNull();
      final echoedClientToken = clientTokMatch!.group(1)!;

      final unauthedLoopbackWs = await WebSocket.connect(clientUrl);
      unauthedLoopbackWs.add(
        BufferFrameCodec.encode(const AuthFrame(role: .client, token: '')),
      );
      await unauthedLoopbackWs.drain<void>().timeout(
        const Duration(seconds: 2),
      );
      check(unauthedLoopbackWs.closeCode).equals(1008);

      final authedLoopbackChan = await connectCastWebSocket(
        Uri.parse(clientUrl),
      );
      addTearDown(() => authedLoopbackChan.sink.close());
      final acceptedLoopback = Completer<AuthAcceptedFrame>();
      authedLoopbackChan.stream.listen((raw) {
        final msg = BufferFrameCodec.decode(raw);
        if (msg is AuthAcceptedFrame && !acceptedLoopback.isCompleted) {
          acceptedLoopback.complete(msg);
        }
      });
      authedLoopbackChan.sink.add(
        BufferFrameCodec.encode(
          AuthFrame(role: .client, token: echoedClientToken),
        ),
      );
      check(
        (await acceptedLoopback.future.timeout(
          const Duration(seconds: 2),
        )).role,
      ).equals(CastRole.client);

      // Cross-site Origin on /v1/client and /v1/caster -> 403 Forbidden!
      for (final url in [clientUrl, casterUrl]) {
        await check(
          WebSocket.connect(url, headers: {'origin': 'https://evil.example'}),
        ).throws<WebSocketException>(
          (it) => it
              .has((e) => e.httpStatusCode, 'httpStatusCode')
              .equals(HttpStatus.forbidden),
        );
      }

      // Sandboxed iframe Origin: null -> 403 Forbidden!
      await check(
        WebSocket.connect(clientUrl, headers: {'origin': 'null'}),
      ).throws<WebSocketException>(
        (it) => it
            .has((e) => e.httpStatusCode, 'httpStatusCode')
            .equals(HttpStatus.forbidden),
      );

      // Loopback Origins (localhost, 127.0.0.1, [::1]) and configured --allowed-origin succeed.
      for (final origin in [
        'http://localhost:5173',
        'http://127.0.0.1:8080',
        'http://[::1]:3000',
        'https://TRUSTED.example:443/',
      ]) {
        final ws = await WebSocket.connect(
          clientUrl,
          headers: {'origin': origin},
        );
        await ws.close();
      }

      // DNS rebinding Host header on loopback bind -> 403 Forbidden!
      final httpClient = HttpClient();
      addTearDown(httpClient.close);

      final rebindReq = await httpClient.getUrl(
        Uri.parse('http://127.0.0.1:$boundPort/v1/client'),
      );
      rebindReq.persistentConnection = false;
      rebindReq.headers
        ..set(HttpHeaders.hostHeader, 'cast.corp.example:$boundPort')
        ..set('origin', 'https://cast.corp.example:$boundPort')
        ..set(HttpHeaders.connectionHeader, 'Upgrade')
        ..set(HttpHeaders.upgradeHeader, 'websocket')
        ..set('Sec-WebSocket-Version', '13')
        ..set('Sec-WebSocket-Key', 'dGhlIHNhbXBsZSBub25jZQ==');
      final rebindResp = await rebindReq.close();
      await rebindResp.drain<void>();
      check(rebindResp.statusCode).equals(HttpStatus.forbidden);

      final multiOriginReq = await httpClient.getUrl(
        Uri.parse('http://127.0.0.1:$boundPort/v1/client'),
      );
      multiOriginReq.headers
        ..add('origin', 'http://localhost:3000')
        ..add('origin', 'https://evil.example')
        ..set(HttpHeaders.connectionHeader, 'Upgrade')
        ..set(HttpHeaders.upgradeHeader, 'websocket')
        ..set('Sec-WebSocket-Version', '13')
        ..set('Sec-WebSocket-Key', 'dGhlIHNhbXBsZSBub25jZQ==');
      final multiOriginResp = await multiOriginReq.close();
      await multiOriginResp.drain<void>();
      check(multiOriginResp.statusCode).equals(HttpStatus.forbidden);

      // Verify non-loopback ServerConfig origin rules:
      // 1. Rejects http://localhost:3000 when not in allowedOrigins.
      // 2. Rejects same-host with port mismatch (cast.corp.example:8420 vs :3000).
      // 3. Allows same-host with matching port (cast.corp.example:8420 vs :8420).
      final nonLoopbackCfg = ServerConfig(
        host: InternetAddress.anyIPv4,
        port: 8420,
        casterToken: 'c-tok',
        clientToken: 'v-tok',
      );
      check(
        nonLoopbackCfg.isOriginAllowed(const [
          'http://localhost:3000',
        ], requestHostHeader: 'cast.corp.example:8420'),
      ).isFalse();
      check(
        nonLoopbackCfg.isOriginAllowed(const [
          'https://cast.corp.example:3000',
        ], requestHostHeader: 'cast.corp.example:8420'),
      ).isFalse();
      check(
        nonLoopbackCfg.isOriginAllowed(const [
          'https://cast.corp.example:8420',
        ], requestHostHeader: 'cast.corp.example:8420'),
      ).isTrue();

      // Verify X-Forwarded-Proto: https behind TLS-terminating reverse proxy
      // rejects http:// Origin and accepts https:// Origin on same-host match.
      check(
        nonLoopbackCfg.isOriginAllowed(
          const ['http://cast.corp.example:8420'],
          requestHostHeader: 'cast.corp.example:8420',
          forwardedProtoHeader: 'https, http',
        ),
      ).isFalse();
      check(
        nonLoopbackCfg.isOriginAllowed(
          const ['https://cast.corp.example:8420'],
          requestHostHeader: 'cast.corp.example:8420',
          forwardedProtoHeader: 'https, http',
        ),
      ).isTrue();

      // Verify maxPendingAuth evicts the oldest pending-auth connection on new connect,
      // while maxTotalPeers returns 503 Service Unavailable before upgrading when at capacity.
      final cappedServer = await CastServer.bind(
        ServerConfig(port: 0),
        maxPendingAuth: 1,
        maxTotalPeers: 2,
      );
      addTearDown(cappedServer.close);
      final pendingWs1 = await WebSocket.connect('${cappedServer.clientUri}');
      addTearDown(pendingWs1.close);
      final pendingWs1Frames = <CastMessage>[];
      final pendingWs1Closed = Completer<int?>();
      pendingWs1.listen(
        (raw) => pendingWs1Frames.add(
          BufferFrameCodec.decode(
            raw is Uint8List ? raw : Uint8List.fromList(raw as List<int>),
          ),
        ),
        onDone: () => pendingWs1Closed.complete(pendingWs1.closeCode),
      );
      final pendingWs2 = await WebSocket.connect('${cappedServer.clientUri}');
      addTearDown(pendingWs2.close);
      check(
        await pendingWs1Closed.future.timeout(const Duration(seconds: 2)),
      ).equals(1008);
      check(pendingWs1Frames).length.equals(1);
      check((pendingWs1Frames.single as ErrorFrame).code).equals('auth_busy');

      // Authenticate two peers to reach maxTotalPeers = 2, then verify 503 on 3rd.
      pendingWs2.add(
        BufferFrameCodec.encode(const AuthFrame(role: .client, token: '')),
      );
      final authedWs = await WebSocket.connect('${cappedServer.casterUri}');
      addTearDown(authedWs.close);
      authedWs.add(
        BufferFrameCodec.encode(const AuthFrame(role: .caster, token: '')),
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await check(
        WebSocket.connect('${cappedServer.clientUri}'),
      ).throws<WebSocketException>(
        (it) => it
            .has((e) => e.httpStatusCode, 'httpStatusCode')
            .equals(HttpStatus.serviceUnavailable),
      );

      shutdown.add(null);
      check(await cliFuture).equals(0);
      check(cliErr.toString()).contains('Rejected cross-origin');
    },
  );

  test(
    'reserves pre-upgrade peer cap under concurrent upgrades and exits 78 on bind SocketException',
    () async {
      final server = await CastServer.bind(
        ServerConfig(host: InternetAddress.loopbackIPv4, port: 0),
        maxTotalPeers: 2,
      );
      addTearDown(server.close);

      // Simultaneous connection attempts exceeding maxTotalPeers=2 must reject overflow with 503.
      final results = await [
        for (var i = 0; i < 4; i++)
          WebSocket.connect('${server.clientUri}').then<int>(
            (ws) {
              addTearDown(ws.close);
              return HttpStatus.switchingProtocols;
            },
            onError: (Object err) =>
                err is WebSocketException ? (err.httpStatusCode ?? 0) : 0,
          ),
      ].wait;
      check(
        results.where((s) => s == HttpStatus.switchingProtocols).length,
      ).equals(2);
      check(
        results.where((s) => s == HttpStatus.serviceUnavailable).length,
      ).equals(2);

      // Binding second server on the occupied port returns exit code 78 cleanly.
      final errSink = StringBuffer();
      final exitCode = await runServerCli([
        '--host=127.0.0.1',
        '--port=${server.port}',
        '--insecure-no-auth',
      ], err: errSink);
      check(exitCode).equals(78);
      check(errSink.toString()).contains('Failed to bind');
    },
  );

  test(
    'allows loopback proxied Host headers matching --allowed-origin (#401) and routes WebSockets under --base-path (#406)',
    () async {
      final server = await CastServer.bind(
        ServerConfig(
          port: 0,
          basePath: '/term',
          allowedOrigins: const ['https://box.tail.ts.net'],
        ),
      );
      addTearDown(server.close);
      check(server.casterUri.path).equals('/term/v1/caster');
      check(server.clientUri.path).equals('/term/v1/client');

      // 1. Proxied Host: box.tail.ts.net and box.tail.ts.net:443 upgrade cleanly on loopback.
      final httpClient = HttpClient();
      addTearDown(() => httpClient.close(force: true));
      for (final hostHeader in const [
        'box.tail.ts.net',
        'box.tail.ts.net:443',
      ]) {
        final req = await httpClient.getUrl(
          Uri.parse('http://127.0.0.1:${server.port}/term/v1/client'),
        );
        req.persistentConnection = false;
        req.headers
          ..set(HttpHeaders.hostHeader, hostHeader)
          ..set('origin', 'https://box.tail.ts.net')
          ..set(HttpHeaders.connectionHeader, 'Upgrade')
          ..set(HttpHeaders.upgradeHeader, 'websocket')
          ..set('Sec-WebSocket-Version', '13')
          ..set('Sec-WebSocket-Key', 'dGhlIHNhbXBsZSBub25jZQ==');
        final resp = await req.close();
        check(resp.statusCode).equals(HttpStatus.switchingProtocols);
        final sock = await resp.detachSocket();
        sock.destroy();
      }

      // 2. Non-default port box.tail.ts.net:8443, unknown evil.example, and
      // scheme-downgraded http:// Origin on loopback (without X-Forwarded-Proto) return 403.
      for (final badHost in const ['box.tail.ts.net:8443', 'evil.example']) {
        final req = await httpClient.getUrl(
          Uri.parse('http://127.0.0.1:${server.port}/term/v1/client'),
        );
        req.persistentConnection = false;
        req.headers
          ..set(HttpHeaders.hostHeader, badHost)
          ..set(HttpHeaders.connectionHeader, 'Upgrade')
          ..set(HttpHeaders.upgradeHeader, 'websocket')
          ..set('Sec-WebSocket-Version', '13')
          ..set('Sec-WebSocket-Key', 'dGhlIHNhbXBsZSBub25jZQ==');
        final resp = await req.close();
        await resp.drain<void>();
        check(resp.statusCode).equals(HttpStatus.forbidden);
      }

      final downgradeReq = await httpClient.getUrl(
        Uri.parse('http://127.0.0.1:${server.port}/term/v1/client'),
      );
      downgradeReq.persistentConnection = false;
      downgradeReq.headers
        ..set(HttpHeaders.hostHeader, 'box.tail.ts.net')
        ..set('origin', 'http://box.tail.ts.net')
        ..set(HttpHeaders.connectionHeader, 'Upgrade')
        ..set(HttpHeaders.upgradeHeader, 'websocket')
        ..set('Sec-WebSocket-Version', '13')
        ..set('Sec-WebSocket-Key', 'dGhlIHNhbXBsZSBub25jZQ==');
      final downgradeResp = await downgradeReq.close();
      await downgradeResp.drain<void>();
      check(downgradeResp.statusCode).equals(HttpStatus.forbidden);

      // 3. Unprefixed /v1/client and lookalike /terminal/v1/client return 404.
      for (final wrongPath in const ['/v1/client', '/terminal/v1/client']) {
        await check(
          WebSocket.connect('ws://127.0.0.1:${server.port}$wrongPath'),
        ).throws<WebSocketException>(
          (it) => it
              .has((e) => e.httpStatusCode, 'httpStatusCode')
              .equals(HttpStatus.notFound),
        );
      }

      // 4. Prefixed /term/v1/caster and /term/v1/client complete binary handshake.
      final ws = await WebSocket.connect('${server.clientUri}');
      addTearDown(ws.close);
      final accepted = Completer<AuthAcceptedFrame>();
      ws.listen((raw) {
        final msg = BufferFrameCodec.decode(
          raw is Uint8List ? raw : Uint8List.fromList(raw as List<int>),
        );
        if (msg is AuthAcceptedFrame && !accepted.isCompleted) {
          accepted.complete(msg);
        }
      });
      ws.add(
        BufferFrameCodec.encode(const AuthFrame(role: .client, token: '')),
      );
      check(
        (await accepted.future.timeout(const Duration(seconds: 2))).role,
      ).equals(CastRole.client);
    },
  );

  test(
    'enforces --trust-proxy-client-auth and --require-client-auth-header while keeping /v1/caster token-gated (#407)',
    () async {
      final shutdown = StreamController<void>();
      addTearDown(shutdown.close);
      final cliOut = _NotifyingStringSink();
      final cliErr = StringBuffer();
      final cliFuture = runServerCli(
        const [
          '--port=0',
          '--caster-token=caster-only-secret',
          '--trust-proxy-client-auth',
          '--require-client-auth-header=X-Forwarded-Email',
        ],
        out: cliOut,
        err: cliErr,
        shutdownSignal: shutdown.stream,
      );
      await cliOut.ready.future.timeout(const Duration(seconds: 3));
      check(cliErr.toString()).contains('--trust-proxy-client-auth');
      check(cliErr.toString()).contains('perimeter auth');

      final clientUrl = RegExp(
        r'ws://127\.0\.0\.1:\d+/v1/client',
      ).firstMatch(cliOut.buffer.toString())!.group(0)!;
      final casterUrl = clientUrl.replaceAll('/v1/client', '/v1/caster');

      // 1. Missing or blank required header on /v1/client -> 401 Unauthorized.
      await check(WebSocket.connect(clientUrl)).throws<WebSocketException>(
        (it) => it
            .has((e) => e.httpStatusCode, 'httpStatusCode')
            .equals(HttpStatus.unauthorized),
      );
      await check(
        WebSocket.connect(
          clientUrl,
          headers: const {'X-Forwarded-Email': '   '},
        ),
      ).throws<WebSocketException>(
        (it) => it
            .has((e) => e.httpStatusCode, 'httpStatusCode')
            .equals(HttpStatus.unauthorized),
      );

      // 2. Non-empty required header allows tokenless /v1/client auth.
      final clientWs = await WebSocket.connect(
        clientUrl,
        headers: const {'X-Forwarded-Email': 'alice@example.com'},
      );
      addTearDown(clientWs.close);
      final clientAccepted = Completer<AuthAcceptedFrame>();
      clientWs.listen((raw) {
        final msg = BufferFrameCodec.decode(
          raw is Uint8List ? raw : Uint8List.fromList(raw as List<int>),
        );
        if (msg is AuthAcceptedFrame && !clientAccepted.isCompleted) {
          clientAccepted.complete(msg);
        }
      });
      clientWs.add(
        BufferFrameCodec.encode(const AuthFrame(role: .client, token: '')),
      );
      check(
        (await clientAccepted.future.timeout(const Duration(seconds: 2))).role,
      ).equals(CastRole.client);

      // 3. /v1/caster does NOT require client header, and remains gated by casterToken.
      final badCasterWs = await WebSocket.connect(casterUrl);
      badCasterWs.add(
        BufferFrameCodec.encode(const AuthFrame(role: .caster, token: '')),
      );
      await badCasterWs.drain<void>().timeout(const Duration(seconds: 2));
      check(badCasterWs.closeCode).equals(1008);

      final goodCasterWs = await WebSocket.connect(casterUrl);
      addTearDown(goodCasterWs.close);
      final casterAccepted = Completer<AuthAcceptedFrame>();
      goodCasterWs.listen((raw) {
        final msg = BufferFrameCodec.decode(
          raw is Uint8List ? raw : Uint8List.fromList(raw as List<int>),
        );
        if (msg is AuthAcceptedFrame && !casterAccepted.isCompleted) {
          casterAccepted.complete(msg);
        }
      });
      goodCasterWs.add(
        BufferFrameCodec.encode(
          const AuthFrame(role: .caster, token: 'caster-only-secret'),
        ),
      );
      check(
        (await casterAccepted.future.timeout(const Duration(seconds: 2))).role,
      ).equals(CastRole.caster);

      shutdown.add(null);
      check(await cliFuture).equals(0);
    },
  );
}

final class _NotifyingStringSink implements StringSink {
  final StringBuffer buffer = StringBuffer();
  final Completer<void> ready = Completer<void>();

  @override
  void write(Object? object) {
    buffer.write(object);
    if (!ready.isCompleted && buffer.toString().contains('Listening on ')) {
      scheduleMicrotask(() {
        if (!ready.isCompleted) ready.complete();
      });
    }
  }

  @override
  void writeAll(Iterable<Object?> objects, [String separator = '']) {
    buffer.writeAll(objects, separator);
    if (!ready.isCompleted && buffer.toString().contains('Listening on ')) {
      ready.complete();
    }
  }

  @override
  void writeCharCode(int charCode) {
    buffer.writeCharCode(charCode);
  }

  @override
  void writeln([Object? object = '']) {
    buffer.writeln(object);
    if (!ready.isCompleted && buffer.toString().contains('Listening on ')) {
      ready.complete();
    }
  }
}
