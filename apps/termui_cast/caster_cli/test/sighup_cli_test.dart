@TestOn('posix')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:checks/checks.dart';
import 'package:stream_channel/stream_channel.dart';
import 'package:termui_cast_protocol/termui_cast_protocol.dart';
import 'package:termui_cast_protocol/termui_cast_protocol_io.dart';
import 'package:termui_cast_server/termui_cast_server.dart';
import 'package:termui_caster_cli/termui_caster_cli.dart';
import 'package:test/test.dart';

String _resolveCasterBinPath() {
  final candidates = [
    Platform.script.resolve('../bin/termui_cast.dart').toFilePath(),
    '${Directory.current.path}/bin/termui_cast.dart',
    '${Directory.current.path}/apps/termui_cast/caster_cli/bin/termui_cast.dart',
  ];
  return candidates.firstWhere(
    (p) => File(p).existsSync(),
    orElse: () => candidates.first,
  );
}

final class _ProxyLink {
  final Socket clientSock;
  final Socket serverSock;
  final StreamSubscription<Uint8List> c2sSub;
  final StreamSubscription<Uint8List> s2cSub;
  bool blackholed = false;

  _ProxyLink(this.clientSock, this.serverSock, this.c2sSub, this.s2cSub);

  void severUpstream() {
    if (blackholed) return;
    blackholed = true;
    c2sSub.onData((_) {});
    unawaited(s2cSub.cancel());
    serverSock.destroy();
  }

  Future<void> close() async {
    await c2sSub.cancel();
    await s2cSub.cancel();
    clientSock.destroy();
    serverSock.destroy();
  }
}

final class _BlackholeTcpProxy {
  final ServerSocket _listener;
  final int _targetPort;
  final List<_ProxyLink> _links = [];
  int wsConnectionCount = 0;

  _BlackholeTcpProxy._(this._listener, this._targetPort) {
    _listener.listen(_handleInbound);
  }

  int get port => _listener.port;

  static Future<_BlackholeTcpProxy> start(int targetPort) async {
    final listener = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    return _BlackholeTcpProxy._(listener, targetPort);
  }

  Future<void> _handleInbound(Socket clientSock) async {
    final serverSock = await Socket.connect('127.0.0.1', _targetPort);
    var firstChunk = true;
    late final _ProxyLink link;
    final c2s = clientSock.listen(
      (chunk) {
        if (firstChunk) {
          firstChunk = false;
          if (ascii
              .decode(chunk, allowInvalid: true)
              .toLowerCase()
              .contains('upgrade: websocket')) {
            wsConnectionCount++;
          }
        }
        if (!link.blackholed) {
          serverSock.add(chunk);
        }
      },
      onError: (Object _) {},
      onDone: () {
        if (!link.blackholed) {
          unawaited(serverSock.close().catchError((Object _) {}));
        }
      },
    );
    final s2c = serverSock.listen(
      clientSock.add,
      onError: (Object _) {},
      onDone: () => unawaited(clientSock.close().catchError((Object _) {})),
    );
    link = _ProxyLink(clientSock, serverSock, c2s, s2c);
    _links.add(link);
  }

  /// Severs all `proxy -> CastServer` sockets while keeping
  /// `termui_cast -> proxy` sockets open and blackholed until SIGHUP.
  void severUpstreamAndBlackholeClient() {
    for (final link in _links) {
      link.severUpstream();
    }
  }

  Future<void> close() async {
    for (final link in _links) {
      await link.close();
    }
    await _listener.close();
  }
}

final class _ViewerSessionTracker {
  final StreamChannel<Uint8List> viewer;
  final Completer<void> firstRegisteredDir = Completer<void>();
  final Completer<void> beforeHupOutput = Completer<void>();
  final Completer<void> droppedDir = Completer<void>();
  final Completer<void> reregisteredDir = Completer<void>();
  final Completer<BufferSnapshot> snapshotAfterHup =
      Completer<BufferSnapshot>();
  bool waitingPostHupSnapshot = false;

  _ViewerSessionTracker(this.viewer) {
    viewer.stream.listen(_onRawFrame);
  }

  void _onRawFrame(Uint8List raw) {
    switch (BufferFrameCodec.decode(raw)) {
      case SessionDirectoryFrame(:final sessions):
        _onDirectory(sessions);
      case BufferSnapshotFrame(:final snapshot):
        _onSnapshot(snapshot);
      case BufferDeltaFrame(:final delta):
        if (!beforeHupOutput.isCompleted &&
            [
              for (final run in delta.runs) run.characters.join(),
            ].join().contains('BEFORE_HUP')) {
          beforeHupOutput.complete();
        }
      default:
        break;
    }
  }

  void _onDirectory(List<SessionSummary> sessions) {
    if (!firstRegisteredDir.isCompleted && sessions.isNotEmpty) {
      firstRegisteredDir.complete();
    } else if (firstRegisteredDir.isCompleted &&
        !droppedDir.isCompleted &&
        sessions.isEmpty) {
      droppedDir.complete();
    } else if (droppedDir.isCompleted &&
        !reregisteredDir.isCompleted &&
        sessions.isNotEmpty) {
      reregisteredDir.complete();
    }
  }

  void _onSnapshot(BufferSnapshot snapshot) {
    if (waitingPostHupSnapshot && !snapshotAfterHup.isCompleted) {
      snapshotAfterHup.complete(snapshot);
    } else if (!beforeHupOutput.isCompleted &&
        snapshot.characters.join().contains('BEFORE_HUP')) {
      beforeHupOutput.complete();
    }
  }
}

Future<StreamChannel<Uint8List>> _openCliTestChannel(
  List<RegisterSessionFrame> registrations,
  Completer<void> reg1,
  Completer<void> reg2,
) async {
  final ctrl = StreamChannelController<Uint8List>();
  ctrl.foreign.stream.listen((raw) {
    switch (BufferFrameCodec.decode(raw)) {
      case AuthFrame():
        ctrl.foreign.sink.add(
          BufferFrameCodec.encode(const AuthAcceptedFrame(role: .caster)),
        );
      case final RegisterSessionFrame frame:
        registrations.add(frame);
        if (registrations.length == 1 && !reg1.isCompleted) {
          reg1.complete();
        } else if (registrations.length == 2 && !reg2.isCompleted) {
          reg2.complete();
        }
      default:
        break;
    }
  });
  return ctrl.local;
}

Future<void> _runPrewarmAndStreamingCliTest() async {
  final checkInCtrl = StreamController<void>.broadcast();
  final shutdownCtrl = StreamController<void>.broadcast();
  addTearDown(checkInCtrl.close);
  addTearDown(shutdownCtrl.close);

  final prewarmStarted = Completer<void>();
  final allowPrewarmFinish = Completer<void>();
  final signer = IapJwtSigner(
    serviceAccount: 'caster@proj.iam.gserviceaccount.com',
    targetAudienceUrl: 'https://relay.example.com/v1/caster',
    processRunner: (_, args) async {
      if (!prewarmStarted.isCompleted) prewarmStarted.complete();
      await allowPrewarmFinish.future;
      await File(args.last).writeAsString('fake-iap-jwt');
      return ProcessResult(1, 0, '', '');
    },
  );

  var openCalls = 0;
  final registrations = <RegisterSessionFrame>[];
  final reg1 = Completer<void>();
  final reg2 = Completer<void>();
  final cliErr = StringBuffer();

  final cliFuture = runCasterCli(
    [
      '--server',
      'wss://relay.example.com/v1/caster',
      '--iap-service-account',
      'caster@proj.iam.gserviceaccount.com',
      '--session-id',
      'cli-checkin-test',
      '--',
      '/bin/sh',
      '-c',
      'sleep 30',
    ],
    err: cliErr,
    environment: const <String, String>{},
    iapSigner: signer,
    checkInSignal: checkInCtrl.stream,
    shutdownSignal: shutdownCtrl.stream,
    channelOpener: () {
      openCalls++;
      return _openCliTestChannel(registrations, reg1, reg2);
    },
  );

  // Fire checkInSignal while IAP token pre-warm is still blocked.
  await prewarmStarted.future.timeout(const Duration(seconds: 3));
  checkInCtrl.add(null);
  await Future<void>.delayed(const Duration(milliseconds: 20));
  check(openCalls).equals(0);

  // Complete pre-warm and await first session registration.
  allowPrewarmFinish.complete();
  await reg1.future.timeout(const Duration(seconds: 5));
  check(openCalls).equals(1);

  // Fire checkInSignal while streaming -> immediate reconnect & re-registration.
  checkInCtrl.add(null);
  await reg2.future.timeout(const Duration(seconds: 3));
  check(openCalls).equals(2);
  check(registrations[1].resumeToken).deepEquals(registrations[0].resumeToken);

  // Shutdown and verify trailing checkInSignal after shutdown is ignored.
  shutdownCtrl.add(null);
  checkInCtrl.add(null);
  final exitCode = await cliFuture.timeout(const Duration(seconds: 5));
  check(exitCode).equals(-1);
  check(openCalls).equals(2);
}

Future<void> _runSubprocessSighupProxyTest() async {
  final server = await CastServer.bind(
    ServerConfig(
      port: 0,
      casterToken: 'sighup-caster-tok',
      clientToken: 'sighup-client-tok',
    ),
  );
  addTearDown(server.close);

  final proxy = await _BlackholeTcpProxy.start(server.port);
  addTearDown(proxy.close);

  final packageConfig = await Isolate.packageConfig;
  check(packageConfig).isNotNull();
  final proxyCasterUri = Uri(
    scheme: 'ws',
    host: '127.0.0.1',
    port: proxy.port,
    path: '/v1/caster',
  );

  final viewer = await connectCastWebSocket(server.clientUri);
  addTearDown(viewer.sink.close);
  final tracker = _ViewerSessionTracker(viewer);
  viewer.sink.add(
    BufferFrameCodec.encode(
      const AuthFrame(role: .client, token: 'sighup-client-tok'),
    ),
  );

  final stderrLines = <String>[];
  final childExitedLogged = Completer<Stopwatch>();
  final proc = await Process.start(
    Platform.resolvedExecutable,
    [
      '--packages=${packageConfig!.toFilePath()}',
      _resolveCasterBinPath(),
      '--server',
      '$proxyCasterUri',
      '--token',
      'sighup-caster-tok',
      '--keep-alive-on-hup',
      '--session-id',
      'sighup-subproc',
      '--',
      '/bin/sh',
      '-c',
      'printf "BEFORE_HUP\\n"; read line; printf "AFTER:%s\\n" "\$line"',
    ],
    environment: const <String, String>{
      'TERMUI_CAST_SERVER_URL': '',
      'TERMUI_CAST_CASTER_TOKEN': '',
      'TERMUI_CAST_IAP_SERVICE_ACCOUNT': '',
      'TERMUI_CAST_IAP_KEY_FILE': '',
    },
  );
  addTearDown(proc.kill);
  unawaited(proc.stdout.drain<void>());
  proc.stderr.transform(utf8.decoder).transform(const LineSplitter()).listen((
    line,
  ) {
    stderrLines.add(line);
    if (line.contains('Child process exited with code ') &&
        !childExitedLogged.isCompleted) {
      childExitedLogged.complete(Stopwatch()..start());
    }
  });

  // 1. Wait for registration and pre-HUP output snapshot/delta.
  await tracker.firstRegisteredDir.future.timeout(const Duration(seconds: 20));
  viewer.sink.add(
    BufferFrameCodec.encode(
      const SubscribeSessionFrame(
        sessionId: SessionId('sighup-subproc'),
        cols: 80,
        rows: 24,
      ),
    ),
  );
  await tracker.beforeHupOutput.future.timeout(const Duration(seconds: 5));

  // 2. Sever ONLY proxy -> CastServer while keeping termui_cast -> proxy open.
  proxy.severUpstreamAndBlackholeClient();
  await tracker.droppedDir.future.timeout(const Duration(seconds: 5));
  check(server.registry.sessions).isEmpty();

  // Confirm termui_cast stays wedged on the blackholed socket until SIGHUP.
  await Future<void>.delayed(const Duration(milliseconds: 150));
  check(proxy.wsConnectionCount).equals(1);
  check(server.registry.sessions).isEmpty();

  // 3. Send SIGHUP to termui_cast and verify immediate re-registration.
  check(Process.killPid(proc.pid, .sighup)).isTrue();
  await tracker.reregisteredDir.future.timeout(const Duration(seconds: 5));
  check(proxy.wsConnectionCount).equals(2);
  check(server.registry.sessions.length).equals(1);
  check(
    server.registry.sessions.single.id,
  ).equals(const SessionId('sighup-subproc'));

  // Re-subscribe viewer and verify pre-HUP output is intact.
  tracker.waitingPostHupSnapshot = true;
  viewer.sink.add(
    BufferFrameCodec.encode(
      const SubscribeSessionFrame(
        sessionId: SessionId('sighup-subproc'),
        cols: 80,
        rows: 24,
      ),
    ),
  );
  final postHupSnap = await tracker.snapshotAfterHup.future.timeout(
    const Duration(seconds: 5),
  );
  check(postHupSnap.characters.join()).contains('BEFORE_HUP');

  // 4. Send input to verify child shell is still alive, then exit cleanly < 2000ms.
  viewer.sink.add(
    BufferFrameCodec.encode(
      InputFrame(
        sessionId: const SessionId('sighup-subproc'),
        data: Uint8List.fromList(utf8.encode('ALIVE\n')),
      ),
    ),
  );

  final stopwatch = await childExitedLogged.future.timeout(
    const Duration(seconds: 5),
  );
  final exitCode = await proc.exitCode.timeout(const Duration(seconds: 5));
  stopwatch.stop();

  check(exitCode).equals(0);
  check(stopwatch.elapsedMilliseconds).isLessThan(2000);
  check(stderrLines).any(
    (l) =>
        l.contains('Check-in requested; reconnecting session "sighup-subproc"'),
  );
}

const String _testKeyPem = '''
-----BEGIN PRIVATE KEY-----
MIICdQIBADANBgkqhkiG9w0BAQEFAASCAl8wggJbAgEAAoGBAKEbjO9lhv9IyH7m
FdUnxE9DeZhlOpUv6m24yYDzGKODSXUKkP5j3ulvCjIlFkRZNtC/zxCEdCFzIy60
jCgWOzgNSi50xrprE4vbPssG5G7Nssv6UX+rY5p2DEmS+Ivy+Szn4xb4KkYlncgm
fXAsTV71MAHHcmh9OXs9T0Hsf4KzAgMBAAECgYAuUtmnTC4Q4UClHEtSyuhrUh94
bkL1+p0Rh3yJE10WRv2sJamjO9wwirkHyhoo9O4J/9zuBufNZmnLWCaksB++fWnH
AuuA9xf7TC/TMUxETYCGrFBAWB2VM+tJn2/7OSdYzLByUZPY4DW3t/74c4TaLk/H
J/tRc3cINOfmwCUgAQJBAMt3XQgEm8QmGnoC1UtUr2iVS8/NIKgF0j1ERPPHLN2E
7rUjHQC3J78CSetCFQzm1NBEELJwI7WqSbEym+raTrMCQQDKtGGi2P+yYW2gxUms
kh3sk2sEHNfA74Gquj+1LduCUX4aR5IKDycKTSJtInY0d5RfJgMgYwfFbvlOKWxZ
n/wBAkAX0lTREIEQOQnWiShh1ntm+jvTC4gsQ+o2hByykfo9wUeVa5QEtmzv3xu6
cJU4WnpGHAH8ckasCVDxbyR0HbUjAkAdGt1SBppgQID/LpSvhKNrTpd1Fbcc6sbR
fsCbASSdh5n1qAUeEKLoZb7lsKcMTYcuSkT0p4N8I70ELgpyq/gBAkB0cyb73k5w
AcUmR6oniiNfTkhtwRerwKrdqSbSjEbxlevwqqQnM1+Kl1vKC0Tyy8WM5yVuQkAJ
EwFSx/7Q3CSd
-----END PRIVATE KEY-----
''';

Future<void> _runCliHelpAndDefaultIapCleanupTest() async {
  // 1. --help with default environment returns 0 cleanly.
  final outBuf = StringBuffer();
  final helpCode = await runCasterCli(['--help'], out: outBuf);
  check(helpCode).equals(0);
  check('$outBuf').contains('Usage: termui_cast');

  // 2. Default IapJwtSigner construction (offline --iap-key-file) and signal
  // listener cleanup when shutdownSignal fires.
  final tempDir = Directory.systemTemp.createTempSync('sighup_cli_key_');
  addTearDown(() => tempDir.deleteSync(recursive: true));
  final keyFile = File('${tempDir.path}/sa.json')
    ..writeAsStringSync(
      jsonEncode(<String, String>{
        'client_email': 'caster@proj.iam.gserviceaccount.com',
        'private_key': _testKeyPem,
      }),
    );

  final errBuf = StringBuffer();
  final checkInCtrl = StreamController<void>.broadcast();
  final shutdownCtrl = StreamController<void>.broadcast();
  addTearDown(checkInCtrl.close);
  addTearDown(shutdownCtrl.close);
  var signaledShutdown = false;

  final code = await runCasterCli(
    [
      '--server',
      'wss://127.0.0.1:1/v1/caster',
      '--iap-key-file',
      keyFile.path,
      '--',
      '/bin/sh',
      '-c',
      'sleep 30',
    ],
    err: errBuf,
    environment: const <String, String>{},
    checkInSignal: checkInCtrl.stream,
    shutdownSignal: shutdownCtrl.stream,
    channelOpener: () {
      if (!signaledShutdown) {
        signaledShutdown = true;
        shutdownCtrl.add(null);
      }
      return Completer<StreamChannel<Uint8List>>().future;
    },
  );
  check(code, because: 'err=$errBuf').equals(-1);
  check(checkInCtrl.hasListener).isFalse();
  check(shutdownCtrl.hasListener).isFalse();
}

final class _EioThrowingSink implements StringSink {
  const _EioThrowingSink();

  @override
  void write(Object? object) =>
      throw const StdoutException('Input/output error');

  @override
  void writeAll(Iterable<Object?> objects, [String separator = '']) =>
      throw const StdoutException('Input/output error');

  @override
  void writeCharCode(int charCode) =>
      throw const StdoutException('Input/output error');

  @override
  void writeln([Object? object = '']) =>
      throw const StdoutException('Input/output error');
}

Future<void> _runEioRevokedTtyCliTest() async {
  const eioSink = _EioThrowingSink();
  check(await runCasterCli(['--help'], out: eioSink, err: eioSink)).equals(0);
  check(
    await runCasterCli(['--no-such-flag'], out: eioSink, err: eioSink),
  ).equals(64);

  final checkInCtrl = StreamController<void>.broadcast();
  final shutdownCtrl = StreamController<void>.broadcast();
  addTearDown(checkInCtrl.close);
  addTearDown(shutdownCtrl.close);

  var openCalls = 0;
  final registrations = <RegisterSessionFrame>[];
  final reg1 = Completer<void>();
  final reg2 = Completer<void>();

  final cliFuture = runCasterCli(
    ['--session-id', 'eio-tty-test', '--', '/bin/sh', '-c', 'sleep 30'],
    out: eioSink,
    err: eioSink,
    environment: const <String, String>{},
    checkInSignal: checkInCtrl.stream,
    shutdownSignal: shutdownCtrl.stream,
    channelOpener: () {
      openCalls++;
      return _openCliTestChannel(registrations, reg1, reg2);
    },
  );

  await reg1.future.timeout(const Duration(seconds: 5));
  check(openCalls).equals(1);

  checkInCtrl.add(null);
  await reg2.future.timeout(const Duration(seconds: 5));
  check(openCalls).equals(2);

  shutdownCtrl.add(null);
  final exitCode = await cliFuture.timeout(const Duration(seconds: 5));
  check(exitCode).equals(-1);
}

void main() {
  group('runCasterCli checkInSignal wiring', () {
    test(
      'handles --help, builds default IapJwtSigner, and cleans up checkInSignal on exit',
      _runCliHelpAndDefaultIapCleanupTest,
    );

    test(
      'survives checkInSignal during slow IAP pre-warm and reconnects on checkInSignal while streaming',
      _runPrewarmAndStreamingCliTest,
    );

    test(
      'survives EIO StdoutException on revoked controlling TTY during checkInSignal and shutdownSignal',
      _runEioRevokedTtyCliTest,
    );

    test(
      'live termui_cast subprocess survives SIGHUP over blackholed TCP proxy, re-registers, and keeps child alive',
      _runSubprocessSighupProxyTest,
    );
  });
}
