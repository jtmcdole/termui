import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:checks/checks.dart';
import 'package:clock/clock.dart';
import 'package:crypto/crypto.dart';
import 'package:fake_async/fake_async.dart';
import 'package:pty2/pty2.dart';
import 'package:stream_channel/stream_channel.dart';
import 'package:termui_cast_protocol/termui_cast_protocol.dart';
import 'package:termui_cast_protocol/termui_cast_protocol_io.dart';
import 'package:termui_cast_server/termui_cast_server.dart';
import 'package:termui_caster_cli/termui_caster_cli.dart';
import 'package:termui_pty/termui_pty.dart';
import 'package:test/test.dart';

import 'support/backpressure_probe.dart' show probeJsonPrefix;

const String _testCertPem = '''
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

const String _testKeyPem = '''
-----BEGIN PRIVATE KEY-----
MIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQgcnEPuDznhktG/80D
VI1RW5oy4n+z93IGlv9cLtYJuBOhRANCAAT6yG8zLGFj+MjDuYRd1ADtqLt5rTI8
w4exRE3P94LpwktT6JM3sijtRxSUJM5sfrP/nuLlt0ybG+f2ZAfvG8sO
-----END PRIVATE KEY-----
''';

const String _testRsaPrivateKeyPem = '''
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

final class _TrustLoopbackCertHttpOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) =>
      super.createHttpClient(context)
        ..badCertificateCallback = (_, host, _) => host == '127.0.0.1';
}

final class _ThrowingStreamSink implements StreamSink<Uint8List> {
  int sentCount = 0;

  @override
  void add(Uint8List event) {
    sentCount++;
    throw StateError('sink broken');
  }

  @override
  void addError(Object error, [StackTrace? stackTrace]) {}

  @override
  Future<void> addStream(Stream<Uint8List> stream) {
    final completer = Completer<void>();
    late final StreamSubscription<Uint8List> sub;
    sub = stream.listen(
      (event) {
        try {
          add(event);
        } on Object catch (e, st) {
          unawaited(sub.cancel());
          if (!completer.isCompleted) completer.completeError(e, st);
        }
      },
      onError: (Object e, StackTrace st) {
        if (!completer.isCompleted) completer.completeError(e, st);
      },
      onDone: () {
        if (!completer.isCompleted) completer.complete();
      },
    );
    return completer.future;
  }

  @override
  Future<void> close() async {}

  @override
  Future<void> get done async {}
}

final class _FakePtySession implements PtySession {
  final StreamController<Uint8List> _outputController =
      StreamController<Uint8List>.broadcast();
  final Completer<int> _exitCompleter = Completer<int>();
  final List<Uint8List> writtenInputs = [];
  final List<(int cols, int rows)> resizes = [];
  final List<ProcessSignal> killSignals = [];
  bool ignoreSigterm = false;
  bool killed = false;

  @override
  Stream<Uint8List> get output => _outputController.stream;

  @override
  Future<int> get exitCode => _exitCompleter.future;

  void emitText(String text) {
    _outputController.add(utf8.encode(text));
  }

  Future<void> finish(int code) async {
    if (!_exitCompleter.isCompleted) {
      _exitCompleter.complete(code);
    }
    await _outputController.close();
  }

  @override
  void writeBytes(Uint8List data) {
    writtenInputs.add(Uint8List.fromList(data));
  }

  @override
  void resize(int cols, int rows, {int pixelWidth = 0, int pixelHeight = 0}) {
    resizes.add((cols, rows));
  }

  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    killed = true;
    killSignals.add(signal);
    if (ignoreSigterm && signal == ProcessSignal.sigterm) {
      return true;
    }
    unawaited(finish(-1));
    return true;
  }
}

void main() {
  group('CasterConfig and CasterConnectionMachine', () {
    test('parses valid CLI flags and rejects malformed arguments', () {
      final config = CasterConfig.fromArgs([
        '--server',
        'wss://example.com:8420/v1/caster',
        '--token',
        'secret',
        '--session-id',
        'my-sess',
        '--cols',
        '100',
        '--rows',
        '30',
        '--',
        '/bin/zsh',
        '-l',
      ])!;
      check('${config.serverUri}').equals('wss://example.com:8420/v1/caster');
      check(config.token).equals('secret');
      check(config.sessionId).equals(const SessionId('my-sess'));
      check(config.title).equals('zsh');
      check(config.initialCols).equals(100);
      check(config.initialRows).equals(30);
      check(config.command).deepEquals(['/bin/zsh', '-l']);

      final boundary = CasterConfig(
        sessionId: const SessionId('exact-bounds'),
        title: 'a' * 512,
        token: 't' * 4096,
        command: const ['sh'],
      );
      check(boundary.title.length).equals(512);
      check(boundary.token.length).equals(4096);

      final generated = CasterConfig.fromArgs([
        '--',
        'zsh',
      ], clock: Clock.fixed(DateTime.fromMicrosecondsSinceEpoch(42000)))!;
      check(generated.sessionId).equals(const SessionId('cast-42000'));

      check(CasterConfig.fromArgs(['--help'])).isNull();
      check(() => CasterConfig.fromArgs([])).throws<FormatException>();
      check(
        () => CasterConfig.fromArgs(['--cols', '0', '--', 'sh']),
      ).throws<FormatException>();
      check(
        () => CasterConfig.fromArgs([
          '--server',
          'http://127.0.0.1:8420/v1/caster',
          '--',
          'sh',
        ]),
      ).throws<FormatException>();
      check(
        () => CasterConfig(
          serverUri: Uri.parse('http://127.0.0.1:8420/v1/caster'),
          sessionId: const SessionId('bad-scheme'),
          title: 'sh',
          command: const ['sh'],
        ),
      ).throws<FormatException>();
      check(
        () => CasterConfig.fromArgs(['--server', 'ws:///no-host', '--', 'sh']),
      ).throws<FormatException>();
      check(
        () => CasterConfig(
          serverUri: Uri.parse('ws:///no-host'),
          sessionId: const SessionId('bad-host'),
          title: 'sh',
          command: const ['sh'],
        ),
      ).throws<FormatException>();
      check(
        () => CasterConfig(
          sessionId: const SessionId('over-title'),
          title: '🚀' * 129,
          command: const ['sh'],
        ),
      ).throws<FormatException>();
      check(
        () => CasterConfig(
          sessionId: const SessionId('over-token'),
          title: 'ok',
          token: 't' * 4097,
          command: const ['sh'],
        ),
      ).throws<FormatException>();

      final winCfg = CasterConfig.fromArgs([
        r'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe',
        '-NoLogo',
      ])!;
      check(winCfg.title).equals('powershell.exe');
      check(winCfg.downloadConPty).isFalse();
      check(winCfg.command).deepEquals([
        r'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe',
        '-NoLogo',
      ]);

      final downloadFlagCfg = CasterConfig.fromArgs([
        '--download-conpty',
        '--',
        'powershell.exe',
      ])!;
      check(downloadFlagCfg.downloadConPty).isTrue();

      final downloadEnvCfg = CasterConfig.fromArgs(
        ['--', 'powershell.exe'],
        environment: const {'TERMUI_CAST_DOWNLOAD_CONPTY': 'true'},
      )!;
      check(downloadEnvCfg.downloadConPty).isTrue();

      final negatedFlagCfg = CasterConfig.fromArgs(
        ['--no-download-conpty', '--', 'powershell.exe'],
        environment: const {'TERMUI_CAST_DOWNLOAD_CONPTY': 'true'},
      )!;
      check(negatedFlagCfg.downloadConPty).isFalse();

      for (final falseVal in ['0', 'false', 'no', '']) {
        final cfg = CasterConfig.fromArgs(
          ['--', 'powershell.exe'],
          environment: {'TERMUI_CAST_DOWNLOAD_CONPTY': falseVal},
        )!;
        check(cfg.downloadConPty).isFalse();
      }

      check(
        () => CasterConfig.fromArgs(
          ['--', 'powershell.exe'],
          environment: const {'TERMUI_CAST_DOWNLOAD_CONPTY': 'tru'},
        ),
      ).throws<FormatException>();
    });

    test(
      'transitions through reconnect backoff and resets attempt counter',
      () async {
        final machine = CasterConnectionMachine(
          random: Random(7),
          baseDelay: const Duration(milliseconds: 100),
          maxDelay: const Duration(milliseconds: 500),
        );
        addTearDown(machine.dispose);

        check(machine.state).equals(CasterLifecycleState.idle);
        await machine.dispatch(.start);
        check(machine.state).equals(CasterLifecycleState.connecting);

        await machine.dispatch(.connectionFailed);
        check(machine.state).equals(CasterLifecycleState.reconnectBackoff);
        check(machine.reconnectAttempt).equals(1);
        final d1 = machine.nextBackoffDelay();
        check(d1.inMilliseconds).isGreaterOrEqual(50);

        await machine.dispatch(.retryTimerFired);
        check(machine.state).equals(CasterLifecycleState.connecting);

        await machine.dispatch(.connected);
        check(machine.state).equals(CasterLifecycleState.streaming);
        check(machine.reconnectAttempt).equals(1);

        await machine.dispatch(.registered);
        check(machine.state).equals(CasterLifecycleState.streaming);
        check(machine.reconnectAttempt).equals(0);

        await machine.dispatch(.disconnected);
        check(machine.state).equals(CasterLifecycleState.reconnectBackoff);
        check(machine.reconnectAttempt).equals(1);

        await machine.dispatch(.stop);
        check(machine.state).equals(CasterLifecycleState.terminated);
      },
    );
  });

  group('CasterService FakeAsync coalescing, resize, input, and reconnect', () {
    test(
      'coalesces dirty frames only when subscriberCount > 0, handles solicited keyframes, and reconnects on drop',
      () {
        fakeAsync((async) {
          final pty = _FakePtySession();
          final serverSides = <StreamChannel<Uint8List>>[];

          final service = CasterService(
            config: CasterConfig(
              sessionId: const SessionId('cast-1'),
              title: 'shell',
              token: 'c-tok',
              initialCols: 20,
              initialRows: 5,
              command: const ['sh'],
            ),
            pty: pty,
            random: Random(1),
            frameCoalesceInterval: const Duration(milliseconds: 16),
            baseReconnectDelay: const Duration(milliseconds: 100),
            channelOpener: () async {
              final c2s = StreamController<Uint8List>();
              final s2c = StreamController<Uint8List>();
              serverSides.add(StreamChannel<Uint8List>(c2s.stream, s2c.sink));
              return StreamChannel<Uint8List>(s2c.stream, c2s.sink);
            },
          );

          unawaited(service.start());
          async.flushMicrotasks();
          check(serverSides.length).equals(1);

          final server1Frames = <CastMessage>[];
          serverSides[0].stream.listen((raw) {
            server1Frames.add(BufferFrameCodec.decode(raw));
          });
          async.flushMicrotasks();

          // 1. Caster sends AuthFrame immediately.
          check(server1Frames.single).isA<AuthFrame>();
          server1Frames.clear();

          // 2. Server replies AuthAcceptedFrame -> Caster sends RegisterSessionFrame.
          serverSides[0].sink.add(
            BufferFrameCodec.encode(const AuthAcceptedFrame(role: .caster)),
          );
          async.flushMicrotasks();
          check(server1Frames.single).isA<RegisterSessionFrame>();
          check(
            service.stateMachine.state,
          ).equals(CasterLifecycleState.streaming);
          server1Frames.clear();

          // 3. Emit PTY output while subscriberCount == 0: zero frames sent or timers armed!
          pty.emitText('booting...');
          async.flushMicrotasks();
          check(async.periodicTimerCount).equals(0);
          check(async.nonPeriodicTimerCount).equals(0);
          check(server1Frames).isEmpty();

          // 4. Viewer subscribes -> SubscriberCount(1) + RequestKeyframe.
          serverSides[0].sink.add(
            BufferFrameCodec.encode(
              const SubscriberCountFrame(
                sessionId: SessionId('cast-1'),
                subscriberCount: 1,
              ),
            ),
          );
          serverSides[0].sink.add(
            BufferFrameCodec.encode(
              const RequestKeyframeFrame(sessionId: SessionId('cast-1')),
            ),
          );
          async.flushMicrotasks();
          check(service.subscriberCount).equals(1);
          check(server1Frames.single).isA<BufferSnapshotFrame>();
          check(
            (server1Frames.single as BufferSnapshotFrame).snapshot.seq,
          ).equals(1);
          server1Frames.clear();

          // 5. Multiple rapid PTY chunks within 16ms coalesce into a single BufferDeltaFrame.
          pty.emitText('A');
          pty.emitText('B');
          async.flushMicrotasks();
          check(server1Frames).isEmpty();
          async.elapse(const Duration(milliseconds: 16));
          check(server1Frames.single).isA<BufferDeltaFrame>();
          check((server1Frames.single as BufferDeltaFrame).delta.seq).equals(2);
          server1Frames.clear();

          // 5b. Late viewer joins while clean -> RequestKeyframe emits snapshot at seq=2 without bumping seq!
          serverSides[0].sink.add(
            BufferFrameCodec.encode(
              const RequestKeyframeFrame(sessionId: SessionId('cast-1')),
            ),
          );
          async.flushMicrotasks();
          check(server1Frames.single).isA<BufferSnapshotFrame>();
          check(
            (server1Frames.single as BufferSnapshotFrame).snapshot.seq,
          ).equals(2);
          server1Frames.clear();

          // 6. InputFrame and ResizeFrame route to PtySession; Resize coalesces SIGWINCH redraw into a single snapshot.
          serverSides[0].sink.add(
            BufferFrameCodec.encode(
              InputFrame(
                sessionId: const SessionId('cast-1'),
                data: Uint8List.fromList([0x03]),
              ),
            ),
          );
          serverSides[0].sink.add(
            BufferFrameCodec.encode(
              const ResizeFrame(
                sessionId: SessionId('cast-1'),
                cols: 32,
                rows: 10,
              ),
            ),
          );
          async.flushMicrotasks();
          // Simulate child process reacting to SIGWINCH 4ms later within coalesce window.
          async.elapse(const Duration(milliseconds: 4));
          pty.emitText('RESIZED-32x10');
          async.elapse(const Duration(milliseconds: 16));
          check(pty.writtenInputs.single).deepEquals([0x03]);
          check(pty.resizes.single).equals((32, 10));
          // Must coalesce into ONE BufferSnapshotFrame (not snapshot + delta!).
          check(server1Frames.length).equals(1);
          check(server1Frames.single).isA<BufferSnapshotFrame>();
          check(
            (server1Frames.single as BufferSnapshotFrame).snapshot.cols,
          ).equals(32);
          server1Frames.clear();

          // 6b. ResizeFrame matching current 32x10 dimensions while seq > 0 still emits a snapshot (clean and dirty) so awaiting subscribers never hang.
          serverSides[0].sink.add(
            BufferFrameCodec.encode(
              const ResizeFrame(
                sessionId: SessionId('cast-1'),
                cols: 32,
                rows: 10,
              ),
            ),
          );
          async.flushMicrotasks();
          check(server1Frames.length).equals(1);
          final cleanSameDimSeq =
              (server1Frames.single as BufferSnapshotFrame).snapshot.seq;
          server1Frames.clear();

          pty.emitText('DIRTY-SAME-DIM');
          async.flushMicrotasks();
          serverSides[0].sink.add(
            BufferFrameCodec.encode(
              const ResizeFrame(
                sessionId: SessionId('cast-1'),
                cols: 32,
                rows: 10,
              ),
            ),
          );
          async.flushMicrotasks();
          check(server1Frames.length).equals(1);
          check(
            (server1Frames.single as BufferSnapshotFrame).snapshot.seq,
          ).equals(cleanSameDimSeq + 1);
          server1Frames.clear();

          // 6c. Dirty terminal with subscriberCount == 1 emits a single snapshot on RequestKeyframe without a wasted delta first.
          pty.emitText('DIRTY-ONE');
          async.flushMicrotasks();
          serverSides[0].sink.add(
            BufferFrameCodec.encode(
              const RequestKeyframeFrame(sessionId: SessionId('cast-1')),
            ),
          );
          async.flushMicrotasks();
          check(server1Frames.length).equals(1);
          check(server1Frames.single).isA<BufferSnapshotFrame>();
          server1Frames.clear();

          // 6d. Dirty terminal with subscriberCount == 2 emits delta for synced viewer + snapshot for joining viewer.
          serverSides[0].sink.add(
            BufferFrameCodec.encode(
              const SubscriberCountFrame(
                sessionId: SessionId('cast-1'),
                subscriberCount: 2,
              ),
            ),
          );
          pty.emitText('DIRTY-TWO');
          async.flushMicrotasks();
          serverSides[0].sink.add(
            BufferFrameCodec.encode(
              const RequestKeyframeFrame(sessionId: SessionId('cast-1')),
            ),
          );
          async.flushMicrotasks();
          check(server1Frames.length).equals(2);
          check(server1Frames[0]).isA<BufferDeltaFrame>();
          check(server1Frames[1]).isA<BufferSnapshotFrame>();
          server1Frames.clear();

          // 7. Server drops channel -> Caster backs off and reconnects on serverSides[1].
          unawaited(serverSides[0].sink.close());
          async.flushMicrotasks();
          check(
            service.stateMachine.state,
          ).equals(CasterLifecycleState.reconnectBackoff);
          check(service.subscriberCount).equals(0);

          async.elapse(const Duration(milliseconds: 250));
          check(serverSides.length).equals(2);
          final server2Frames = <CastMessage>[];
          serverSides[1].stream.listen((raw) {
            server2Frames.add(BufferFrameCodec.decode(raw));
          });
          async.flushMicrotasks();
          check(server2Frames.single).isA<AuthFrame>();
          server2Frames.clear();

          serverSides[1].sink.add(
            BufferFrameCodec.encode(const AuthAcceptedFrame(role: .caster)),
          );
          async.flushMicrotasks();
          final reg2 = server2Frames.single as RegisterSessionFrame;
          check(reg2.cols).equals(32);
          check(reg2.rows).equals(10);
          server2Frames.clear();

          // 8. Child exits -> SessionClosedFrame sent and service.done completes.
          int? observedExit;
          service.done.then((code) => observedExit = code);
          unawaited(pty.finish(0));
          async.flushMicrotasks();
          check(server2Frames.single).isA<SessionClosedFrame>();
          check(observedExit).equals(0);
          check(
            service.stateMachine.state,
          ).equals(CasterLifecycleState.terminated);
        });
      },
    );

    test(
      'stops immediately without reconnect loop on fatal auth_failed ErrorFrame',
      () {
        fakeAsync((async) {
          final pty = _FakePtySession();
          late StreamChannelController<Uint8List> ctrl;
          final logs = <String>[];
          int? exitCode;
          final service = CasterService(
            config: CasterConfig(
              sessionId: const SessionId('dup-1'),
              title: 'dup',
              command: const ['sh'],
            ),
            pty: pty,
            onLog: logs.add,
            channelOpener: () async {
              ctrl = StreamChannelController<Uint8List>();
              return ctrl.local;
            },
          );
          service.done.then((code) => exitCode = code);

          unawaited(service.start());
          async.flushMicrotasks();
          ctrl.foreign.stream.listen((_) {});
          ctrl.foreign.sink.add(
            BufferFrameCodec.encode(
              const ErrorFrame(
                code: 'auth_failed',
                message: 'Invalid bearer token',
              ),
            ),
          );
          async.flushMicrotasks();
          check(
            service.stateMachine.state,
          ).equals(CasterLifecycleState.terminated);
          check(pty.killed).isTrue();
          check(exitCode).equals(78);
          check(logs).any((it) => it.contains('auth_failed'));
        });
      },
    );

    test(
      'enters jittered reconnect backoff without killing PTY on duplicate_session ErrorFrame',
      () {
        fakeAsync((async) {
          final pty = _FakePtySession();
          final serverSides = <StreamChannel<Uint8List>>[];
          final logs = <String>[];
          final service = CasterService(
            config: CasterConfig(
              sessionId: const SessionId('dup-live'),
              title: 'shell',
              command: const ['sh'],
            ),
            pty: pty,
            random: Random(3),
            baseReconnectDelay: const Duration(milliseconds: 100),
            onLog: logs.add,
            channelOpener: () async {
              final c2s = StreamController<Uint8List>();
              final s2c = StreamController<Uint8List>();
              serverSides.add(StreamChannel<Uint8List>(c2s.stream, s2c.sink));
              return StreamChannel<Uint8List>(s2c.stream, c2s.sink);
            },
          );

          unawaited(service.start());
          async.flushMicrotasks();
          serverSides[0].stream.listen((_) {});
          serverSides[0].sink.add(
            BufferFrameCodec.encode(const AuthAcceptedFrame(role: .caster)),
          );
          async.flushMicrotasks();

          serverSides[0].sink.add(
            BufferFrameCodec.encode(
              const ErrorFrame(
                code: 'duplicate_session',
                message: 'Session "dup-live" already active',
              ),
            ),
          );
          async.flushMicrotasks();

          check(pty.killed).isFalse();
          check(
            service.stateMachine.state,
          ).equals(CasterLifecycleState.reconnectBackoff);
          check(logs).any((it) => it.contains('duplicate_session'));

          // Elapse backoff -> reconnects on serverSides[1] and re-registers.
          async.elapse(const Duration(milliseconds: 250));
          check(serverSides.length).equals(2);
          final server2Frames = <CastMessage>[];
          serverSides[1].stream.listen((raw) {
            server2Frames.add(BufferFrameCodec.decode(raw));
          });
          async.flushMicrotasks();
          check(server2Frames.single).isA<AuthFrame>();
          server2Frames.clear();

          serverSides[1].sink.add(
            BufferFrameCodec.encode(const AuthAcceptedFrame(role: .caster)),
          );
          async.flushMicrotasks();
          check(server2Frames.single).isA<RegisterSessionFrame>();

          unawaited(pty.finish(0));
          async.flushMicrotasks();
        });
      },
    );

    test(
      'logs _sendFrame sink errors and guards _onAuthAccepted across channel replacement',
      () {
        fakeAsync((async) {
          final pty = _FakePtySession();
          final logs = <String>[];
          final incoming = StreamController<Uint8List>(sync: true);
          final throwingSink = _ThrowingStreamSink();
          var attempt = 0;

          final service = CasterService(
            config: CasterConfig(
              sessionId: const SessionId('guard-1'),
              title: 'guard',
              command: const ['sh'],
            ),
            pty: pty,
            onLog: logs.add,
            baseReconnectDelay: const Duration(milliseconds: 100),
            channelOpener: () async {
              attempt++;
              if (attempt == 1) {
                return StreamChannel<Uint8List>(incoming.stream, throwingSink);
              }
              final ctrl = StreamChannelController<Uint8List>();
              ctrl.foreign.stream.listen((_) {});
              return ctrl.local;
            },
          );

          unawaited(service.start());
          async.flushMicrotasks();
          // Initial AuthFrame hit _ThrowingStreamSink -> must be logged via onLog.
          check(logs).any((it) => it.contains('Failed to send'));

          // Deliver AuthAcceptedFrame then immediately close incoming in the same turn
          // while stateMachine.dispatch(.connected) is awaiting microtask settlement.
          throwingSink.sentCount = 0;
          incoming.add(
            BufferFrameCodec.encode(const AuthAcceptedFrame(role: .caster)),
          );
          unawaited(incoming.close());
          async.flushMicrotasks();
          check(throwingSink.sentCount).equals(0);

          unawaited(pty.finish(0));
          async.flushMicrotasks();
        });
      },
    );

    test(
      'emits lifecycle logs on start, registration, viewer count changes, and child exit',
      () {
        fakeAsync((async) {
          final pty = _FakePtySession();
          final serverSides = <StreamChannel<Uint8List>>[];
          final logs = <String>[];
          final service = CasterService(
            config: CasterConfig(
              serverUri: Uri.parse('ws://127.0.0.1:8420/v1/caster'),
              sessionId: const SessionId('life-1'),
              title: 'shell',
              initialCols: 80,
              initialRows: 24,
              command: const ['sh'],
            ),
            pty: pty,
            onLog: logs.add,
            channelOpener: () async {
              final c2s = StreamController<Uint8List>();
              final s2c = StreamController<Uint8List>();
              serverSides.add(StreamChannel<Uint8List>(c2s.stream, s2c.sink));
              return StreamChannel<Uint8List>(s2c.stream, c2s.sink);
            },
          );

          unawaited(service.start());
          async.flushMicrotasks();
          check(
            logs,
          ).contains('Started "sh" (session: life-1, title: "shell", 80x24)');

          serverSides[0].stream.listen((_) {});
          serverSides[0].sink.add(
            BufferFrameCodec.encode(const AuthAcceptedFrame(role: .caster)),
          );
          async.flushMicrotasks();
          check(logs).contains(
            'Registered session "life-1" on ws://127.0.0.1:8420/v1/caster',
          );

          serverSides[0].sink.add(
            BufferFrameCodec.encode(
              const SubscriberCountFrame(
                sessionId: SessionId('life-1'),
                subscriberCount: 1,
              ),
            ),
          );
          async.flushMicrotasks();
          check(logs).contains('Active viewers: 1');

          serverSides[0].sink.add(
            BufferFrameCodec.encode(
              const SubscriberCountFrame(
                sessionId: SessionId('life-1'),
                subscriberCount: 0,
              ),
            ),
          );
          async.flushMicrotasks();
          check(logs).contains('Active viewers: 0');

          unawaited(pty.finish(0));
          async.flushMicrotasks();
          check(logs).contains('Child process exited with code 0');
        });
      },
    );

    test(
      'coalesces 70 rapid OSC 52 writes into 1 ClipboardFrame per 16ms tick without overflowing a 64-frame relay queue',
      () {
        fakeAsync((async) {
          final pty = _FakePtySession();
          final registry = SessionRegistry(
            maxOutboundFrames: 64,
            maxOutboundBytes: 8 * 1024 * 1024,
          );
          final relay = WsRelayHandler(
            registry: registry,
            authenticator: TokenAuthenticator(),
          );

          final service = CasterService(
            config: CasterConfig(
              sessionId: const SessionId('osc-burst'),
              title: 'tmux',
              initialCols: 20,
              initialRows: 4,
              command: const ['sh'],
            ),
            pty: pty,
            frameCoalesceInterval: const Duration(milliseconds: 16),
            channelOpener: () async {
              final ctrl = StreamChannelController<Uint8List>();
              relay.attachCasterChannel(ctrl.foreign);
              return ctrl.local;
            },
          );

          unawaited(service.start());
          async.flushMicrotasks();

          int? viewerCloseCode;
          final viewerIn = StreamController<Uint8List>();
          final viewerOut = StreamController<Uint8List>();
          final viewerLocal = StreamChannel<Uint8List>(
            viewerOut.stream,
            viewerIn.sink,
          );
          relay.attachClientChannel(
            StreamChannel<Uint8List>(viewerIn.stream, viewerOut.sink),
            closeWithCode: (code, _) async {
              viewerCloseCode = code;
            },
          );

          final viewerFrames = <CastMessage>[];
          final viewerSub = viewerLocal.stream.listen((raw) {
            viewerFrames.add(BufferFrameCodec.decode(raw));
          });

          viewerLocal.sink.add(
            BufferFrameCodec.encode(const AuthFrame(role: .client, token: '')),
          );
          viewerLocal.sink.add(
            BufferFrameCodec.encode(
              const SubscribeSessionFrame(
                sessionId: SessionId('osc-burst'),
                cols: 20,
                rows: 4,
              ),
            ),
          );
          async.flushMicrotasks();
          check(service.subscriberCount).equals(1);
          viewerFrames.clear();

          // Pause viewer subscription so >64 uncoalesced frames would overflow SessionRegistry!
          viewerSub.pause();

          final burst = StringBuffer();
          for (var i = 0; i < 70; i++) {
            final payload = base64.encode(utf8.encode('yank-$i'));
            burst.write('\x1b]52;c;$payload\x07');
          }
          burst.write('\x1b]52;c;?\x07');
          pty.emitText(burst.toString());
          async.flushMicrotasks();

          // Nothing sent synchronously before the 16ms coalesce window elapses.
          async.elapse(const Duration(milliseconds: 15));
          check(viewerCloseCode).isNull();

          // At 16ms, at most 1 readBlocked ClipboardFrame + 1 latest-write ClipboardFrame flush.
          async.elapse(const Duration(milliseconds: 1));
          viewerSub.resume();
          async.flushMicrotasks();

          check(viewerCloseCode).isNull();
          check(registry.connectedClientCount).equals(1);
          final clips = [...viewerFrames.whereType<ClipboardFrame>()];
          check(clips).length.equals(2);
          check(clips[0].readBlocked).isTrue();
          check(clips[0].text).equals('');
          check(clips[1].readBlocked).isFalse();
          check(clips[1].text).equals('yank-69');

          // Unsubscribing clears any pending clipboard state before timer fires.
          viewerFrames.clear();
          final stalePayload = base64.encode(utf8.encode('stale-yank'));
          pty.emitText('\x1b]52;c;$stalePayload\x07');
          async.flushMicrotasks();
          viewerLocal.sink.add(
            BufferFrameCodec.encode(
              const UnsubscribeSessionFrame(sessionId: SessionId('osc-burst')),
            ),
          );
          async.flushMicrotasks();
          async.elapse(const Duration(milliseconds: 20));

          viewerLocal.sink.add(
            BufferFrameCodec.encode(
              const SubscribeSessionFrame(
                sessionId: SessionId('osc-burst'),
                cols: 20,
                rows: 4,
              ),
            ),
          );
          async.flushMicrotasks();
          async.elapse(const Duration(milliseconds: 20));
          check(viewerFrames.whereType<ClipboardFrame>()).isEmpty();

          unawaited(pty.finish(0));
          unawaited(viewerSub.cancel());
          unawaited(viewerIn.close());
          unawaited(viewerOut.close());
          unawaited(registry.close());
          async.flushMicrotasks();
        });
      },
    );
  });

  group('Live pty2 CLI execution', () {
    test(
      'runCasterCli casts a real pty2 child process and returns exit code 0',
      () async {
        final helpOut = StringBuffer();
        check(
          await runCasterCli(
            ['--help'],
            out: helpOut,
            environment: const <String, String>{},
          ),
        ).equals(0);
        check(helpOut.toString()).contains('--server');

        final badErr = StringBuffer();
        check(
          await runCasterCli(
            [],
            err: badErr,
            environment: const <String, String>{},
          ),
        ).equals(64);
        check(
          await runCasterCli(
            [
              '--server',
              'wss://cast.example.com/v1/caster',
              '--iap-key-file',
              '/nonexistent/sa-key.json',
              '--',
              'sh',
            ],
            err: badErr,
            environment: const <String, String>{},
          ),
        ).equals(64);

        final capturedSnapshots = <BufferSnapshot>[];
        final cliErr = StringBuffer();
        final exitCode = await runCasterCli(
          [
            '--session-id',
            'live-pty2',
            '--title',
            'echo-test',
            '--cols',
            '40',
            '--rows',
            '8',
            '--',
            '/bin/sh',
            '-c',
            r'printf "\033[32mLIVE_PTY2_OK\033[0m\n"',
          ],
          err: cliErr,
          environment: const <String, String>{},
          channelOpener: () async {
            final ctrl = StreamChannelController<Uint8List>();
            ctrl.foreign.stream.listen((raw) {
              switch (BufferFrameCodec.decode(raw)) {
                case AuthFrame():
                  ctrl.foreign.sink.add(
                    BufferFrameCodec.encode(
                      const AuthAcceptedFrame(role: .caster),
                    ),
                  );
                case RegisterSessionFrame(:final sessionId):
                  ctrl.foreign.sink.add(
                    BufferFrameCodec.encode(
                      SubscriberCountFrame(
                        sessionId: sessionId,
                        subscriberCount: 1,
                      ),
                    ),
                  );
                  ctrl.foreign.sink.add(
                    BufferFrameCodec.encode(
                      RequestKeyframeFrame(sessionId: sessionId),
                    ),
                  );
                case BufferSnapshotFrame(:final snapshot):
                  capturedSnapshots.add(snapshot);
                case BufferDeltaFrame(:final delta):
                  if (capturedSnapshots.isNotEmpty) {
                    final prev = capturedSnapshots.last;
                    final buf = prev.toBuffer();
                    if (BufferFrameCodec.applyDelta(
                      buffer: buf,
                      currentSeq: prev.seq,
                      delta: delta,
                    )) {
                      capturedSnapshots.add(
                        BufferSnapshot.fromBuffer(
                          sessionId: delta.sessionId,
                          seq: delta.seq,
                          buffer: buf,
                          cursor: delta.cursor,
                          modes: delta.modes,
                        ),
                      );
                    }
                  }
                default:
                  break;
              }
            });
            return ctrl.local;
          },
        );

        // In pty2 0.5.7 (unix.dart:L457-L462), fast-exiting children reaped
        // before Isolate.run(_waitForExitCode) calls waitpid return -1 (ECHILD).
        check(const [0, -1]).contains(exitCode);
        check(capturedSnapshots).isNotEmpty();
        final finalRow = capturedSnapshots.last.characters
            .sublist(0, 12)
            .join();
        check(finalRow).equals('LIVE_PTY2_OK');
      },
      skip: Platform.isWindows ? 'Requires POSIX /bin/sh' : null,
    );

    Future<Map<String, Object?>> runBackpressureProbe({
      required bool synthetic,
    }) async {
      final packageConfig = await Isolate.packageConfig;
      check(packageConfig).isNotNull();
      final libUri = await Isolate.resolvePackageUri(
        Uri.parse('package:termui_caster_cli/termui_caster_cli.dart'),
      );
      check(libUri).isNotNull();
      final probePath = libUri!
          .resolve('../test/support/backpressure_probe.dart')
          .toFilePath();

      final result = await Process.run(Platform.resolvedExecutable, [
        '--old_gen_heap_size=64',
        '--new_gen_semi_max_size=4',
        '--enable-vm-service=0',
        '--disable-service-auth-codes',
        '--packages=${packageConfig!.toFilePath()}',
        probePath,
        if (synthetic) '--synthetic',
      ]).timeout(const Duration(seconds: 30));

      check(
        result.exitCode,
        because: 'stdout=${result.stdout}\nstderr=${result.stderr}',
      ).equals(0);
      final jsonLine = LineSplitter.split(
        result.stdout as String,
      ).lastWhere((line) => line.startsWith(probeJsonPrefix));
      return jsonDecode(jsonLine.substring(probeJsonPrefix.length))
          as Map<String, Object?>;
    }

    test(
      'high-throughput pty2 child applies backpressure so timers keep firing and memory stays bounded',
      () async {
        // Measure post-GC main-isolate `heapUsage` via the Dart VM service in
        // a subprocess so concurrent sibling suites, the in-process CFE
        // `kernel-service` isolate, and OS `MADV_FREE` page caching cannot
        // cause false-positive memory spikes.
        final metrics = await runBackpressureProbe(synthetic: false);
        check(metrics['timerTicks'] as int).isGreaterOrEqual(3);
        check(metrics['emittedFrames'] as int).isGreaterOrEqual(2);
        check(metrics['heapDeltaBytes'] as int).isLessThan(16 * 1024 * 1024);
      },
      timeout: const Timeout(Duration(seconds: 60)),
      skip: Platform.isWindows ? 'Requires POSIX /bin/sh and yes' : null,
    );

    test(
      'backpressure heap probe measures bounded post-GC isolate heap under flood',
      () async {
        final metrics = await runBackpressureProbe(synthetic: true);
        check(metrics['timerTicks'] as int).isGreaterOrEqual(3);
        check(metrics['emittedFrames'] as int).isGreaterOrEqual(2);
        check(metrics['heapDeltaBytes'] as int).isLessThan(16 * 1024 * 1024);
      },
      timeout: const Timeout(Duration(seconds: 60)),
    );

    test(
      'runCasterCli stops service and kills PTY cleanly when shutdownSignal fires',
      () async {
        final shutdownController = StreamController<void>();
        addTearDown(shutdownController.close);
        final registered = Completer<void>();
        final closedFrames = <SessionClosedFrame>[];

        final cliErr = StringBuffer();
        final cliFuture = runCasterCli(
          ['--session-id', 'sig-pty', '--', '/bin/sh', '-c', 'sleep 30'],
          err: cliErr,
          environment: const <String, String>{},
          shutdownSignal: shutdownController.stream,
          channelOpener: () async {
            final ctrl = StreamChannelController<Uint8List>();
            ctrl.foreign.stream.listen((raw) {
              switch (BufferFrameCodec.decode(raw)) {
                case AuthFrame():
                  ctrl.foreign.sink.add(
                    BufferFrameCodec.encode(
                      const AuthAcceptedFrame(role: .caster),
                    ),
                  );
                case RegisterSessionFrame():
                  if (!registered.isCompleted) registered.complete();
                case final SessionClosedFrame frame:
                  closedFrames.add(frame);
                default:
                  break;
              }
            });
            return ctrl.local;
          },
        );

        await registered.future.timeout(const Duration(seconds: 3));
        shutdownController.add(null);

        final exitCode = await cliFuture.timeout(const Duration(seconds: 3));
        check(exitCode).equals(-1);
        check(closedFrames.length).equals(1);
        check(closedFrames.single.sessionId).equals(const SessionId('sig-pty'));
      },
    );

    test(
      'Pty2Session defers ack while paused, forwards writeBytes and resize, and cleans up unsubscribed kill',
      () async {
        final unsubscribed = Pty2Session.start(
          '/bin/sh',
          const ['-c', 'sleep 5'],
          initialCols: 40,
          initialRows: 10,
        );
        check(unsubscribed.kill()).isTrue();
        await unsubscribed.exitCode.timeout(const Duration(seconds: 3));

        final pty = Pty2Session.start(
          '/bin/sh',
          const [
            '-c',
            'printf "FIRST\\n"; read line; printf "ECHO:%s\\n" "\$line"',
          ],
          initialCols: 40,
          initialRows: 10,
        );
        final received = StringBuffer();
        final echoed = Completer<void>();
        late final StreamSubscription<Uint8List> sub;
        var pausedOnce = false;
        sub = pty.output.listen((chunk) {
          received.write(utf8.decode(chunk, allowMalformed: true));
          if (!pausedOnce) {
            pausedOnce = true;
            sub.pause();
          }
          if (received.toString().contains('ECHO:HI') && !echoed.isCompleted) {
            echoed.complete();
          }
        });

        await Future<void>.delayed(const Duration(milliseconds: 50));
        pty
          ..resize(60, 15)
          ..writeBytes(utf8.encode('HI\n'));
        sub.resume();

        await echoed.future.timeout(const Duration(seconds: 3));
        await sub.cancel();
        pty.kill();
        await pty.exitCode.timeout(const Duration(seconds: 3));
        check(received.toString()).contains('FIRST');
        check(received.toString()).contains('ECHO:HI');
      },
      skip: Platform.isWindows ? 'Requires POSIX /bin/sh' : null,
    );

    test(
      'termui_cast child process logs lifecycle and terminates in < 2000ms after child exit without pingInterval hang',
      () async {
        final server = await CastServer.bind(
          ServerConfig(port: 0, casterToken: 'test-tok'),
        );
        addTearDown(server.close);

        final tempDir = await Directory.systemTemp.createTemp('fast_exit_cli_');
        addTearDown(() => tempDir.delete(recursive: true));
        final exitTriggerPath = '${tempDir.path}/exit_now';

        final packageConfig = await Isolate.packageConfig;
        check(packageConfig).isNotNull();

        final candidates = [
          Platform.script.resolve('../bin/termui_cast.dart').toFilePath(),
          '${Directory.current.path}/bin/termui_cast.dart',
          '${Directory.current.path}/apps/termui_cast/caster_cli/bin/termui_cast.dart',
        ];
        final binPath = candidates.firstWhere(
          (p) => File(p).existsSync(),
          orElse: () => candidates.first,
        );

        final stderrLines = <String>[];
        final registeredLogged = Completer<void>();
        final childExitedLogged = Completer<Stopwatch>();

        final proc = await Process.start(
          Platform.resolvedExecutable,
          [
            '--packages=${packageConfig!.toFilePath()}',
            binPath,
            '--server',
            '${server.casterUri}',
            '--token',
            'test-tok',
            '--session-id',
            'fast-exit-test',
            '--',
            '/bin/sh',
            '-c',
            'while [ ! -f "\$1" ]; do sleep 0.05; done; exit 0',
            'sh',
            exitTriggerPath,
          ],
          environment: const <String, String>{
            'TERMUI_CAST_SERVER_URL': '',
            'TERMUI_CAST_CASTER_TOKEN': '',
            'TERMUI_CAST_IAP_SERVICE_ACCOUNT': '',
            'TERMUI_CAST_IAP_KEY_FILE': '',
          },
        );
        addTearDown(proc.kill);

        proc.stderr
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .listen((line) {
              stderrLines.add(line);
              if (line.contains('Registered session "fast-exit-test"') &&
                  !registeredLogged.isCompleted) {
                registeredLogged.complete();
              }
              if (line.contains('Child process exited with code ') &&
                  !childExitedLogged.isCompleted) {
                final sw = Stopwatch()..start();
                childExitedLogged.complete(sw);
              }
            });

        unawaited(
          proc.exitCode.then((code) {
            final err = StateError(
              'termui_cast exited early ($code): ${stderrLines.join(' | ')}',
            );
            if (!registeredLogged.isCompleted) {
              registeredLogged.completeError(err);
            }
            if (!childExitedLogged.isCompleted) {
              childExitedLogged.completeError(err);
            }
          }),
        );

        unawaited(proc.stdout.drain<void>());

        await registeredLogged.future.timeout(const Duration(seconds: 30));
        await File(exitTriggerPath).writeAsString('go', flush: true);

        final stopwatch = await childExitedLogged.future.timeout(
          const Duration(seconds: 10),
        );
        final code = await proc.exitCode.timeout(const Duration(seconds: 5));
        stopwatch.stop();

        check(code, because: 'stderr=$stderrLines').equals(0);
        check(
          stderrLines,
        ).any((l) => l.contains('Started "/bin/sh -c while [ ! -f'));
        check(
          stderrLines,
        ).any((l) => l.contains('Registered session "fast-exit-test"'));
        check(
          stderrLines,
        ).any((l) => l.contains('Child process exited with code 0'));
        check(stopwatch.elapsedMilliseconds).isLessThan(2000);
      },
      timeout: const Timeout(Duration(seconds: 60)),
      skip: Platform.isWindows ? 'Requires POSIX /bin/sh' : null,
    );

    test(
      'CasterConfig and IapJwtSigner validate, cache, refresh, and attach IAP bearer JWTs over wss://',
      () async {
        // 1. Environment fallbacks and CLI overrides.
        final fromEnv = CasterConfig.fromArgs(
          const ['--', 'zsh'],
          environment: const <String, String>{
            'TERMUI_CAST_SERVER_URL': 'wss://cast.example.com/v1/caster',
            'TERMUI_CAST_CASTER_TOKEN': 'env-token',
            'TERMUI_CAST_IAP_SERVICE_ACCOUNT':
                'caster-host@my-proj.iam.gserviceaccount.com',
          },
        )!;
        check(
          '${fromEnv.serverUri}',
        ).equals('wss://cast.example.com/v1/caster');
        check(fromEnv.token).equals('env-token');
        check(
          fromEnv.iapServiceAccount,
        ).equals('caster-host@my-proj.iam.gserviceaccount.com');

        // Rejects --iap-service-account on ws:// or malformed email.
        check(
          () => CasterConfig.fromArgs([
            '--server',
            'ws://127.0.0.1:8420/v1/caster',
            '--iap-service-account',
            'caster@proj.iam.gserviceaccount.com',
            '--',
            'sh',
          ]),
        ).throws<FormatException>();
        check(
          () => CasterConfig.fromArgs([
            '--server',
            'wss://127.0.0.1:8420/v1/caster',
            '--iap-service-account',
            'not-an-email',
            '--',
            'sh',
          ]),
        ).throws<FormatException>();
        check(
          () => TokenAuthenticator.iapAudienceForWebSocketUri(
            Uri.parse('ws://127.0.0.1:8420/v1/caster'),
          ),
        ).throws<FormatException>();
        check(
          TokenAuthenticator.iapAudienceForWebSocketUri(
            Uri.parse('wss://cast.example.com:8443/v1/caster'),
          ),
        ).equals('https://cast.example.com:8443/v1/caster');

        // 2. IapJwtSigner caches token until refreshMargin, then re-signs and cleans up temp dir.
        var currentSeconds = 1700000000;
        var signCalls = 0;
        final recordedClaims = <Map<String, Object?>>[];
        final signer = IapJwtSigner(
          serviceAccount: 'caster-mac2@proj.iam.gserviceaccount.com',
          targetAudienceUrl: 'https://cast.example.com/v1/caster',
          ttl: const Duration(minutes: 55),
          refreshMargin: const Duration(minutes: 5),
          clock: Clock(
            () => DateTime.fromMillisecondsSinceEpoch(currentSeconds * 1000),
          ),
          processRunner: (executable, arguments) async {
            signCalls++;
            check(executable).equals('gcloud');
            final claimPath = arguments[arguments.length - 2];
            final jwtPath = arguments.last;
            final decoded =
                jsonDecode(await File(claimPath).readAsString())
                    as Map<String, Object?>;
            recordedClaims.add(decoded);
            await File(jwtPath).writeAsString('signed-jwt-$signCalls\n');
            return ProcessResult(1, 0, '', '');
          },
        );

        final tok1 = await signer.getBearerToken();
        check(tok1).equals('signed-jwt-1');
        check(signCalls).equals(1);
        check(
          recordedClaims.single['iss'],
        ).equals('caster-mac2@proj.iam.gserviceaccount.com');
        check(
          recordedClaims.single['aud'],
        ).equals('https://cast.example.com/v1/caster');
        check(recordedClaims.single['iat']).equals(1700000000);
        check(recordedClaims.single['exp']).equals(1700000000 + 3300);

        // Within validity window (49 minutes later) -> returns cached token.
        currentSeconds += 49 * 60;
        final tok2 = await signer.getBearerToken();
        check(tok2).equals('signed-jwt-1');
        check(signCalls).equals(1);

        // Inside 5-minute refreshMargin (51 minutes after initial) -> mints fresh token.
        currentSeconds += 2 * 60;
        final tok3 = await signer.getBearerToken();
        check(tok3).equals('signed-jwt-2');
        check(signCalls).equals(2);

        // Concurrent calls at refresh boundary share a single in-flight signing operation.
        currentSeconds += 51 * 60;
        final concurrentResults = await [
          signer.getBearerToken(),
          signer.getBearerToken(),
          signer.getBearerToken(),
        ].wait;
        check(
          concurrentResults,
        ).deepEquals(const ['signed-jwt-3', 'signed-jwt-3', 'signed-jwt-3']);
        check(signCalls).equals(3);

        // Non-zero exit code surfaces ProcessException.
        final failingSigner = IapJwtSigner(
          serviceAccount: 'caster-mac2@proj.iam.gserviceaccount.com',
          targetAudienceUrl: 'https://cast.example.com/v1/caster',
          processRunner: (_, _) async =>
              ProcessResult(1, 1, '', 'permission denied'),
        );
        await check(failingSigner.getBearerToken()).throws<ProcessException>();

        // 3. End-to-end CasterService over wss:// attaches Authorization: Bearer header.
        final tempDir = await Directory.systemTemp.createTemp('cast_sa_key_');
        addTearDown(() => tempDir.delete(recursive: true));
        final keyFile = File('${tempDir.path}/sa-key.json');
        await keyFile.writeAsString(
          jsonEncode(<String, Object>{
            'type': 'service_account',
            'client_email': 'caster-ext@external-proj.iam.gserviceaccount.com',
            'private_key_id': 'kid-12345',
            'private_key': _testRsaPrivateKeyPem,
          }),
        );

        final ctx = SecurityContext()
          ..useCertificateChainBytes(utf8.encode(_testCertPem))
          ..usePrivateKeyBytes(utf8.encode(_testKeyPem));
        final httpsServer = await HttpServer.bindSecure(
          InternetAddress.loopbackIPv4,
          0,
          ctx,
        );
        addTearDown(() => httpsServer.close(force: true));

        final authHeaders = <String?>[];
        final registered = Completer<RegisterSessionFrame>();
        httpsServer.listen((req) async {
          if (!WebSocketTransformer.isUpgradeRequest(req)) {
            req.response.statusCode = HttpStatus.ok;
            await req.response.close();
            return;
          }
          authHeaders.add(req.headers.value(HttpHeaders.authorizationHeader));
          final (:channel, closeWithCode: _) = await upgradeCastWebSocket(req);
          channel.stream.listen((bytes) {
            final frame = BufferFrameCodec.decode(bytes);
            if (frame is AuthFrame) {
              channel.sink.add(
                BufferFrameCodec.encode(const AuthAcceptedFrame(role: .caster)),
              );
            } else if (frame is RegisterSessionFrame &&
                !registered.isCompleted) {
              registered.complete(frame);
            }
          });
        });

        final pty = _FakePtySession();
        final service = CasterService(
          config: CasterConfig(
            serverUri: Uri.parse(
              'wss://127.0.0.1:${httpsServer.port}/v1/caster',
            ),
            token: 'app-tok',
            sessionId: const SessionId('iap-sess'),
            title: 'iap',
            iapKeyFilePath: keyFile.path,
            command: const ['sh'],
          ),
          pty: pty,
        );
        await HttpOverrides.runWithHttpOverrides(() async {
          await service.start();
          final reg = await registered.future.timeout(
            const Duration(seconds: 3),
          );
          check(reg.sessionId).equals(const SessionId('iap-sess'));
          check(authHeaders.length).equals(1);
          check(authHeaders.single).isNotNull();
          check(authHeaders.single!).startsWith('Bearer eyJ');
          await pty.finish(0);
          check(await service.done).equals(0);
        }, _TrustLoopbackCertHttpOverrides());

        // 4. Pure-Dart RS256 signing via --iap-key-file / TERMUI_CAST_IAP_KEY_FILE without gcloud,
        //    plus CLI-over-env precedence and mutual exclusion.
        check(
          () => CasterConfig.fromArgs([
            '--server',
            'ws://127.0.0.1:8420/v1/caster',
            '--iap-key-file',
            keyFile.path,
            '--',
            'sh',
          ]),
        ).throws<FormatException>();
        check(
          () => CasterConfig.fromArgs([
            '--server',
            'wss://cast.example.com/v1/caster',
            '--iap-service-account',
            'caster@proj.iam.gserviceaccount.com',
            '--iap-key-file',
            keyFile.path,
            '--',
            'sh',
          ]),
        ).throws<FormatException>();

        // Explicit --server ws:// ignores TERMUI_CAST_IAP_* in environment; explicit --iap-service-account ignores TERMUI_CAST_IAP_KEY_FILE.
        final localOverride = CasterConfig.fromArgs(
          const ['--server', 'ws://127.0.0.1:8420/v1/caster', '--', 'zsh'],
          environment: <String, String>{
            'TERMUI_CAST_IAP_SERVICE_ACCOUNT':
                'caster@proj.iam.gserviceaccount.com',
            'TERMUI_CAST_IAP_KEY_FILE': keyFile.path,
          },
        )!;
        check(localOverride.iapServiceAccount).isNull();
        check(localOverride.iapServiceAccountKey).isNull();

        final saOverride = CasterConfig.fromArgs(
          const [
            '--server',
            'wss://cast.example.com/v1/caster',
            '--iap-service-account',
            'override@proj.iam.gserviceaccount.com',
            '--',
            'zsh',
          ],
          environment: <String, String>{
            'TERMUI_CAST_IAP_KEY_FILE': keyFile.path,
          },
        )!;
        check(
          saOverride.iapServiceAccount,
        ).equals('override@proj.iam.gserviceaccount.com');
        check(saOverride.iapServiceAccountKey).isNull();

        final keyConfig = CasterConfig.fromArgs(
          const ['--', 'zsh'],
          environment: <String, String>{
            'TERMUI_CAST_SERVER_URL': 'wss://cast.example.com/v1/caster',
            'TERMUI_CAST_IAP_KEY_FILE': keyFile.path,
          },
        )!;
        check(keyConfig.iapKeyFilePath).equals(keyFile.path);
        check(keyConfig.iapServiceAccountKey).isNotNull();

        // Rejects non-RSA PKCS#8 keys (e.g. EC _testKeyPem), non-PEM, and invalid RSA parameters.
        check(
          () => RsaPrivateKey.fromPem(_testKeyPem),
        ).throws<FormatException>();
        check(
          () => RsaPrivateKey.fromPem(_testCertPem),
        ).throws<FormatException>();
        check(
          () => RsaPrivateKey(
            modulus: BigInt.one << 512,
            publicExponent: BigInt.from(65537),
            privateExponent: BigInt.from(3),
          ),
        ).throws<FormatException>();
        check(
          () => IapJwtSigner(
            targetAudienceUrl: 'https://cast.example.com/v1/caster',
          ),
        ).throws<ArgumentError>();

        final keySigner = IapJwtSigner(
          serviceAccountKey: keyConfig.iapServiceAccountKey,
          targetAudienceUrl: 'https://cast.example.com/v1/caster',
          clock: Clock.fixed(
            DateTime.fromMillisecondsSinceEpoch(1700000000 * 1000),
          ),
          processRunner: (_, _) => throw StateError(
            'gcloud must not be called with serviceAccountKey',
          ),
        );
        final rs256Jwt = await keySigner.getBearerToken();
        final parts = rs256Jwt.split('.');
        check(parts.length).equals(3);
        final headerJson =
            jsonDecode(
                  utf8.decode(base64Url.decode(base64Url.normalize(parts[0]))),
                )
                as Map<String, Object?>;
        final payloadJson =
            jsonDecode(
                  utf8.decode(base64Url.decode(base64Url.normalize(parts[1]))),
                )
                as Map<String, Object?>;
        check(headerJson['alg']).equals('RS256');
        check(headerJson['kid']).equals('kid-12345');
        check(
          payloadJson['iss'],
        ).equals('caster-ext@external-proj.iam.gserviceaccount.com');
        check(payloadJson['aud']).equals('https://cast.example.com/v1/caster');

        // Verify RS256 signature via public key exponentiation (s^e mod n) and SHA-256 DigestInfo comparison.
        final sigBytes = base64Url.decode(base64Url.normalize(parts[2]));
        final rsaKey = RsaPrivateKey.fromPem(_testRsaPrivateKeyPem);
        check(sigBytes.length).equals(rsaKey.byteLength);
        var sigInt = BigInt.zero;
        for (final b in sigBytes) {
          sigInt = (sigInt << 8) | BigInt.from(b);
        }
        final verifiedEm = sigInt.modPow(rsaKey.publicExponent, rsaKey.modulus);
        final emBytes = Uint8List(rsaKey.byteLength);
        var tmp = verifiedEm;
        for (var i = emBytes.length - 1; i >= 0; i--) {
          emBytes[i] = (tmp & BigInt.from(0xff)).toInt();
          tmp = tmp >> 8;
        }
        final expectedDigest = sha256
            .convert(utf8.encode('${parts[0]}.${parts[1]}'))
            .bytes;
        check(emBytes[0]).equals(0x00);
        check(emBytes[1]).equals(0x01);
        check(
          emBytes.sublist(emBytes.length - expectedDigest.length),
        ).deepEquals(expectedDigest);
      },
    );

    test(
      'CasterConfig parses --scrollback-lines / TERMUI_CAST_SCROLLBACK_LINES and validates bounds',
      () {
        final defaultCfg = CasterConfig.fromArgs(['--', 'zsh'])!;
        check(
          defaultCfg.maxScrollbackLines,
        ).equals(CasterConfig.defaultScrollbackLines);

        final cliCfg = CasterConfig.fromArgs([
          '--scrollback-lines=12000',
          '--',
          'zsh',
        ])!;
        check(cliCfg.maxScrollbackLines).equals(12000);

        final envCfg = CasterConfig.fromArgs(
          ['--', 'zsh'],
          environment: const {'TERMUI_CAST_SCROLLBACK_LINES': '2500'},
        )!;
        check(envCfg.maxScrollbackLines).equals(2500);

        check(
          () => CasterConfig.fromArgs(['--scrollback-lines=-1', '--', 'zsh']),
        ).throws<FormatException>();
        check(
          () =>
              CasterConfig.fromArgs(['--scrollback-lines=100001', '--', 'zsh']),
        ).throws<FormatException>();
        check(
          () => CasterConfig.fromArgs(['--scrollback-lines=abc', '--', 'zsh']),
        ).throws<FormatException>();
      },
    );

    test(
      'CasterService serves RequestScrollbackFrame with ScrollbackChunkFrame from ring buffer',
      () async {
        const sessionId = SessionId('sess-sb-serve');
        final registry = SessionRegistry();
        addTearDown(registry.close);
        final handler = WsRelayHandler(
          registry: registry,
          authenticator: TokenAuthenticator(),
        );
        final pty = _FakePtySession();

        final caster = CasterService(
          config: CasterConfig(
            sessionId: sessionId,
            title: 'zsh',
            initialCols: 10,
            initialRows: 3,
            maxScrollbackLines: 100,
            command: const ['zsh'],
          ),
          pty: pty,
          frameCoalesceInterval: Duration.zero,
          channelOpener: () async {
            final pipe = StreamChannelController<Uint8List>();
            handler.attachCasterChannel(pipe.foreign);
            return pipe.local;
          },
        );
        addTearDown(caster.stop);
        await caster.start();
        await pumpEventQueue(times: 20);

        final clientPipe = StreamChannelController<Uint8List>();
        handler.attachClientChannel(clientPipe.foreign);
        final clientInbox = <CastMessage>[];
        addTearDown(
          clientPipe.local.stream.listen((b) {
            clientInbox.add(BufferFrameCodec.decode(b));
          }).cancel,
        );

        clientPipe.local.sink.add(
          BufferFrameCodec.encode(const AuthFrame(role: .client, token: '')),
        );
        clientPipe.local.sink.add(
          BufferFrameCodec.encode(
            const SubscribeSessionFrame(
              sessionId: sessionId,
              cols: 10,
              rows: 3,
            ),
          ),
        );
        await pumpEventQueue(times: 50);

        pty.emitText('row0\r\nrow1\r\nrow2\r\nrow3\r\nrow4\r\n');
        await pumpEventQueue(times: 50);

        clientInbox.clear();
        clientPipe.local.sink.add(
          BufferFrameCodec.encode(
            const RequestScrollbackFrame(
              sessionId: sessionId,
              requestId: 55,
              clearSeq: 0,
              startLine: 0,
              count: 3,
            ),
          ),
        );
        await pumpEventQueue(times: 50);

        final chunks = [...clientInbox.whereType<ScrollbackChunkFrame>()];
        check(chunks).length.equals(1);
        check(chunks.single.requestId).equals(55);
        check(chunks.single.startLine).equals(0);
        check(chunks.single.rows.length).equals(3);
        check(
          chunks.single.rows[0].characters,
        ).deepEquals(['r', 'o', 'w', '0']);
        check(
          chunks.single.rows[1].characters,
        ).deepEquals(['r', 'o', 'w', '1']);
        check(
          chunks.single.rows[2].characters,
        ).deepEquals(['r', 'o', 'w', '2']);
      },
    );

    test(
      'CasterService serves 120-col scrollback rows cleanly after 120->80 resize shrink',
      () async {
        const sessionId = SessionId('sess-sb-shrink');
        final registry = SessionRegistry();
        addTearDown(registry.close);
        final handler = WsRelayHandler(
          registry: registry,
          authenticator: TokenAuthenticator(),
        );
        final pty = _FakePtySession();

        final caster = CasterService(
          config: CasterConfig(
            sessionId: sessionId,
            title: 'zsh',
            initialCols: 120,
            initialRows: 3,
            maxScrollbackLines: 100,
            command: const ['zsh'],
          ),
          pty: pty,
          frameCoalesceInterval: Duration.zero,
          channelOpener: () async {
            final pipe = StreamChannelController<Uint8List>();
            handler.attachCasterChannel(pipe.foreign);
            return pipe.local;
          },
        );
        addTearDown(caster.stop);
        await caster.start();
        await pumpEventQueue(times: 20);

        final clientPipe = StreamChannelController<Uint8List>();
        handler.attachClientChannel(clientPipe.foreign);
        final clientInbox = <CastMessage>[];
        addTearDown(
          clientPipe.local.stream.listen((b) {
            clientInbox.add(BufferFrameCodec.decode(b));
          }).cancel,
        );

        clientPipe.local.sink.add(
          BufferFrameCodec.encode(const AuthFrame(role: .client, token: '')),
        );
        clientPipe.local.sink.add(
          BufferFrameCodec.encode(
            const SubscribeSessionFrame(
              sessionId: sessionId,
              cols: 120,
              rows: 3,
            ),
          ),
        );
        await pumpEventQueue(times: 50);

        final wide120 = 'W' * 120;
        pty.emitText('$wide120\r\n\r\nlive0\r\nlive1\r\nlive2');
        await pumpEventQueue(times: 50);

        // Shrink terminal to 80x3 and request historical scrollback.
        clientPipe.local.sink.add(
          BufferFrameCodec.encode(
            const ResizeFrame(sessionId: sessionId, cols: 80, rows: 3),
          ),
        );
        await pumpEventQueue(times: 50);

        clientInbox.clear();
        clientPipe.local.sink.add(
          BufferFrameCodec.encode(
            const RequestScrollbackFrame(
              sessionId: sessionId,
              requestId: 88,
              clearSeq: 0,
              startLine: 0,
              count: 4,
            ),
          ),
        );
        await pumpEventQueue(times: 50);

        final chunks = [...clientInbox.whereType<ScrollbackChunkFrame>()];
        check(chunks).length.equals(1);
        check(chunks.single.requestId).equals(88);
        check(chunks.single.rows.length).equals(2);
        check(chunks.single.rows[0].characters.join()).equals(wide120);
        check(chunks.single.rows[1].characters).isEmpty();
      },
    );

    test(
      'Caster WebSocket drop and auto-reconnect preserves scrollback ring and serves pre-drop + offline rows',
      () {
        FakeAsync().run((async) {
          const sessionId = SessionId('sess-sb-reconnect');
          final registry = SessionRegistry();
          final handler = WsRelayHandler(
            registry: registry,
            authenticator: TokenAuthenticator(),
          );
          final pty = _FakePtySession();
          var casterConnections = 0;
          late void Function() dropCurrentWire;

          final caster = CasterService(
            config: CasterConfig(
              sessionId: sessionId,
              title: 'zsh',
              initialCols: 20,
              initialRows: 3,
              maxScrollbackLines: 100,
              command: const ['zsh'],
            ),
            pty: pty,
            random: Random(0),
            frameCoalesceInterval: Duration.zero,
            channelOpener: () async {
              final casterEnd = StreamChannelController<Uint8List>();
              final serverEnd = StreamChannelController<Uint8List>();
              final c2s = casterEnd.foreign.stream.listen(
                serverEnd.local.sink.add,
              );
              final s2c = serverEnd.local.stream.listen(
                casterEnd.foreign.sink.add,
              );
              dropCurrentWire = () {
                unawaited(c2s.cancel());
                unawaited(s2c.cancel());
                unawaited(casterEnd.foreign.sink.close());
                unawaited(serverEnd.local.sink.close());
              };
              casterConnections++;
              handler.attachCasterChannel(serverEnd.foreign);
              return casterEnd.local;
            },
          );

          unawaited(caster.start());
          async.flushMicrotasks();
          check(casterConnections).equals(1);

          // Emit pre-drop rows so pre0 and pre1 enter scrollback (3-row viewport holds pre2, pre3, '').
          pty.emitText('pre0\r\npre1\r\npre2\r\npre3\r\n');
          async.flushMicrotasks();
          check(caster.terminal.scrollbackWindow.totalLines).equals(2);

          // Drop the caster WebSocket transport -> both ends see EOF and caster enters reconnectBackoff.
          dropCurrentWire();
          async.flushMicrotasks();
          check(
            caster.stateMachine.state,
          ).equals(CasterLifecycleState.reconnectBackoff);

          // While caster is offline, PTY continues emitting output -> pre2, pre3, off0, off1 scroll into ring!
          pty.emitText('off0\r\noff1\r\noff2\r\noff3\r\n');
          async.flushMicrotasks();
          check(caster.terminal.scrollbackWindow.totalLines).equals(6);

          // Elapse backoff so caster auto-reconnects and re-registers on the relay.
          async.elapse(const Duration(milliseconds: 500));
          async.flushMicrotasks();
          check(casterConnections).equals(2);
          check(
            caster.stateMachine.state,
          ).equals(CasterLifecycleState.streaming);

          // Subscribe a viewer after reconnect and fetch all 6 scrollback lines (pre-drop + offline).
          final clientPipe = StreamChannelController<Uint8List>();
          handler.attachClientChannel(clientPipe.foreign);
          final clientInbox = <CastMessage>[];
          clientPipe.local.stream.listen((b) {
            clientInbox.add(BufferFrameCodec.decode(b));
          });
          clientPipe.local.sink.add(
            BufferFrameCodec.encode(const AuthFrame(role: .client, token: '')),
          );
          clientPipe.local.sink.add(
            BufferFrameCodec.encode(
              const SubscribeSessionFrame(
                sessionId: sessionId,
                cols: 20,
                rows: 3,
              ),
            ),
          );
          async.flushMicrotasks();

          final snapshots = [...clientInbox.whereType<BufferSnapshotFrame>()];
          check(snapshots).isNotEmpty();
          check(snapshots.last.snapshot.scrollback.totalLines).equals(6);

          clientInbox.clear();
          clientPipe.local.sink.add(
            BufferFrameCodec.encode(
              const RequestScrollbackFrame(
                sessionId: sessionId,
                requestId: 301,
                clearSeq: 0,
                startLine: 0,
                count: 10,
              ),
            ),
          );
          async.flushMicrotasks();

          final chunks = [...clientInbox.whereType<ScrollbackChunkFrame>()];
          check(chunks).length.equals(1);
          check(chunks.single.requestId).equals(301);
          check([
            for (final row in chunks.single.rows) row.characters.join(),
          ]).deepEquals(['pre0', 'pre1', 'pre2', 'pre3', 'off0', 'off1']);

          unawaited(caster.stop());
          unawaited(registry.close());
          async.flushMicrotasks();
        });
      },
    );

    test(
      'Pty2Session.buildChildEnvironment strips inherited tmux, terminal, and TERMUI_CAST_* variables unless explicitly overridden',
      () {
        final sanitized = Pty2Session.buildChildEnvironment(
          baseEnvironment: const {
            'PATH': '/usr/bin',
            'TERM': 'tmux-256color',
            'TMUX': '/tmp/tmux-501/default,1234,0',
            'TMUX_PANE': '%1',
            'TERM_PROGRAM': 'tmux',
            'TERM_PROGRAM_VERSION': '3.5a',
            'TERMUI_CAST_CASTER_TOKEN': 'secret-caster-token',
            'TERMUI_CAST_IAP_KEY_FILE': '/etc/keys/sa.json',
          },
        );
        check(sanitized).deepEquals({
          'PATH': '/usr/bin',
          'TERM': 'xterm-256color',
          'TERMUI_AUDIO_APC': '1',
        });

        final overridden = Pty2Session.buildChildEnvironment(
          baseEnvironment: const {
            'TMUX': '/tmp/outer',
            'TERM_PROGRAM': 'tmux',
            'TERMUI_CAST_CASTER_TOKEN': 'stripped',
          },
          overrides: const {
            'TMUX': '/tmp/explicit',
            'TERM_PROGRAM': 'custom',
            'TERMUI_CAST_CUSTOM': 'kept',
          },
        );
        check(overridden).deepEquals({
          'TERM': 'xterm-256color',
          'TERMUI_AUDIO_APC': '1',
          'TMUX': '/tmp/explicit',
          'TERM_PROGRAM': 'custom',
          'TERMUI_CAST_CUSTOM': 'kept',
        });

        final baseOptOut = Pty2Session.buildChildEnvironment(
          baseEnvironment: const {'TERMUI_AUDIO_APC': '0'},
        );
        check(baseOptOut['TERMUI_AUDIO_APC']).equals('0');

        final overrideOptOut = Pty2Session.buildChildEnvironment(
          baseEnvironment: const {},
          overrides: const {'TERMUI_AUDIO_APC': '0'},
        );
        check(overrideOptOut['TERMUI_AUDIO_APC']).equals('0');
      },
    );

    test(
      'CasterService probes server revision on connect, SubscriberCountFrame(0), and periodic timer, reconnecting when revision changes',
      () {
        FakeAsync().run((async) {
          const sessionId = SessionId('sess-rev-probe');
          final pty = _FakePtySession();
          var activeRevision = 'rev-a';
          var probeCalls = 0;
          var channelOpenCalls = 0;
          late StreamChannelController<Uint8List> currentRelayCtrl;
          final logs = <String>[];

          final caster = CasterService(
            config: CasterConfig(
              sessionId: sessionId,
              title: 'zsh',
              command: const ['zsh'],
            ),
            pty: pty,
            random: Random(0),
            revisionPollInterval: const Duration(seconds: 30),
            onLog: logs.add,
            revisionProber: () async {
              probeCalls++;
              return activeRevision;
            },
            channelOpener: () async {
              channelOpenCalls++;
              final ctrl = StreamChannelController<Uint8List>();
              currentRelayCtrl = ctrl;
              ctrl.foreign.stream.listen((raw) {
                if (BufferFrameCodec.decode(raw) is AuthFrame) {
                  ctrl.foreign.sink.add(
                    BufferFrameCodec.encode(
                      const AuthAcceptedFrame(role: .caster),
                    ),
                  );
                }
              });
              return ctrl.local;
            },
          );

          unawaited(caster.start());
          async.flushMicrotasks();
          check(channelOpenCalls).equals(1);
          check(probeCalls).equals(1);

          // 1. SubscriberCountFrame(0) when subscriberCount was already 0 (unclicked background tab)
          //    triggers an immediate probe and reconnects when revision changed to rev-b!
          activeRevision = 'rev-b';
          currentRelayCtrl.foreign.sink.add(
            BufferFrameCodec.encode(
              const SubscriberCountFrame(
                sessionId: sessionId,
                subscriberCount: 0,
              ),
            ),
          );
          async.flushMicrotasks();
          check(probeCalls).equals(2);
          check(
            logs,
          ).any((l) => l.contains('Server revision changed (rev-a -> rev-b)'));

          async.elapse(const Duration(milliseconds: 500));
          async.flushMicrotasks();
          check(channelOpenCalls).equals(2);
          check(
            probeCalls,
          ).equals(3); // baseline probe on channel 2 records rev-b

          // 2. While viewer is subscribed (subscriberCount == 1), periodic timer detects rev-c and reconnects!
          currentRelayCtrl.foreign.sink.add(
            BufferFrameCodec.encode(
              const SubscriberCountFrame(
                sessionId: sessionId,
                subscriberCount: 1,
              ),
            ),
          );
          async.flushMicrotasks();
          check(caster.subscriberCount).equals(1);

          activeRevision = 'rev-c';
          async.elapse(const Duration(seconds: 30));
          async.flushMicrotasks();
          check(
            logs,
          ).any((l) => l.contains('Server revision changed (rev-b -> rev-c)'));

          async.elapse(const Duration(milliseconds: 500));
          async.flushMicrotasks();
          check(channelOpenCalls).equals(3);

          unawaited(caster.stop());
          async.flushMicrotasks();
        });
      },
    );

    test(
      'CasterService handles failed initial baseline probe, transient probe errors, queued follow-up probes, and cross-connection isolation',
      () {
        FakeAsync().run((async) {
          const sessionId = SessionId('sess-rev-edge');
          final pty = _FakePtySession();
          var channelOpenCalls = 0;
          late StreamChannelController<Uint8List> currentRelayCtrl;
          final probeQueue = <Future<String?> Function()>[];
          var probeCalls = 0;

          final caster = CasterService(
            config: CasterConfig(
              sessionId: sessionId,
              title: 'zsh',
              command: const ['zsh'],
            ),
            pty: pty,
            random: Random(0),
            revisionPollInterval: const Duration(seconds: 60),
            revisionProber: () {
              probeCalls++;
              if (probeQueue.isNotEmpty) {
                return probeQueue.removeAt(0)();
              }
              return Future<String?>.value(null);
            },
            channelOpener: () async {
              channelOpenCalls++;
              final ctrl = StreamChannelController<Uint8List>();
              currentRelayCtrl = ctrl;
              ctrl.foreign.stream.listen((raw) {
                if (BufferFrameCodec.decode(raw) is AuthFrame) {
                  ctrl.foreign.sink.add(
                    BufferFrameCodec.encode(
                      const AuthAcceptedFrame(role: .caster),
                    ),
                  );
                }
              });
              return ctrl.local;
            },
          );

          // 1. Slow initial baseline probe is in flight when SubscriberCountFrame(0) arrives:
          //    initial baseline probe fails (returns null), and the queued follow-up probe
          //    immediately runs and sees 'rev-b', triggering a reconnect instead of adopting 'rev-b' as baseline!
          final baselineCompleter = Completer<String?>();
          probeQueue.add(() => baselineCompleter.future);
          probeQueue.add(() async => 'rev-b');

          unawaited(caster.start());
          async.flushMicrotasks();
          check(channelOpenCalls).equals(1);
          check(probeCalls).equals(1);

          // Trigger SubscriberCountFrame(0) while baselineCompleter is still in flight.
          currentRelayCtrl.foreign.sink.add(
            BufferFrameCodec.encode(
              const SubscriberCountFrame(
                sessionId: sessionId,
                subscriberCount: 0,
              ),
            ),
          );
          async.flushMicrotasks();
          check(probeCalls).equals(1); // queued via _revisionProbePending

          // Complete initial probe with null -> queued follow-up probe runs immediately and sees 'rev-b' -> reconnects!
          baselineCompleter.complete(null);
          async.flushMicrotasks();
          check(probeCalls).equals(2);
          check(
            caster.stateMachine.state,
          ).equals(CasterLifecycleState.reconnectBackoff);

          // 2. Reconnect to channel 2 where baseline is 'rev-b'; throwing or null probes do NOT disconnect.
          probeQueue.add(() async => 'rev-b');
          probeQueue.add(
            () => Future<String?>.error(StateError('network blip')),
          );
          probeQueue.add(() async => null);

          async.elapse(const Duration(milliseconds: 500));
          async.flushMicrotasks();
          check(channelOpenCalls).equals(2);
          check(
            caster.stateMachine.state,
          ).equals(CasterLifecycleState.streaming);

          async.elapse(const Duration(seconds: 120));
          async.flushMicrotasks();
          check(channelOpenCalls).equals(2);
          check(
            caster.stateMachine.state,
          ).equals(CasterLifecycleState.streaming);

          unawaited(caster.stop());
          async.flushMicrotasks();
        });
      },
    );

    test(
      'CasterService defers revision reconnect while a file upload is active, handles rollback, and aborts stalled uploads after idle timeout',
      () async {
        const sessionId = SessionId('sess-rev-upload-defer');
        final tempUploadDir = Directory.systemTemp.createTempSync(
          'cast_rev_upload_',
        );
        addTearDown(() => tempUploadDir.deleteSync(recursive: true));

        final pty = _FakePtySession();
        var activeRevision = 'rev-a';
        var channelOpenCalls = 0;
        late StreamChannelController<Uint8List> currentRelayCtrl;
        final logs = <String>[];
        final casterInbox = <CastMessage>[];
        var nextProbeGate = Completer<void>();

        final caster = CasterService(
          config: CasterConfig(
            sessionId: sessionId,
            title: 'zsh',
            uploadDirPath: tempUploadDir.path,
            command: const ['zsh'],
          ),
          pty: pty,
          random: Random(0),
          baseReconnectDelay: const Duration(milliseconds: 20),
          revisionPollInterval: const Duration(milliseconds: 40),
          uploadIdleTimeout: const Duration(milliseconds: 400),
          onLog: logs.add,
          revisionProber: () async {
            if (!nextProbeGate.isCompleted) nextProbeGate.complete();
            return activeRevision;
          },
          channelOpener: () async {
            channelOpenCalls++;
            final ctrl = StreamChannelController<Uint8List>();
            currentRelayCtrl = ctrl;
            ctrl.foreign.stream.listen((raw) {
              final decoded = BufferFrameCodec.decode(raw);
              casterInbox.add(decoded);
              if (decoded is AuthFrame) {
                ctrl.foreign.sink.add(
                  BufferFrameCodec.encode(
                    const AuthAcceptedFrame(role: .caster),
                  ),
                );
              }
            });
            return ctrl.local;
          },
        );
        addTearDown(caster.stop);

        Future<void> waitForAck(
          FileUploadStatus status,
          int expectedCount,
        ) async {
          final deadline = DateTime.now().add(const Duration(seconds: 3));
          while (casterInbox
                  .whereType<FileUploadAckFrame>()
                  .where((a) => a.status == status)
                  .length <
              expectedCount) {
            if (DateTime.now().isAfter(deadline)) {
              fail('Timed out waiting for $expectedCount $status ACKs');
            }
            await Future<void>.delayed(const Duration(milliseconds: 5));
          }
        }

        Future<void> waitForProbes(int count) async {
          for (var i = 0; i < count; i++) {
            nextProbeGate = Completer<void>();
            await nextProbeGate.future.timeout(const Duration(seconds: 3));
          }
          await pumpEventQueue();
        }

        await caster.start();
        await waitForProbes(1);
        check(channelOpenCalls).equals(1);

        // 1. Start upload 1; revision rolls to rev-b then rolls back to rev-a before upload finishes.
        final payload = Uint8List.fromList(utf8.encode('hello world'));
        final digest = Uint8List.fromList(sha256.convert(payload).bytes);
        currentRelayCtrl.foreign.sink.add(
          BufferFrameCodec.encode(
            FileUploadStartFrame(
              sessionId: sessionId,
              transferId: 6,
              fileName: 'rollback.txt',
              totalBytes: payload.length,
            ),
          ),
        );
        await waitForAck(.ready, 1);

        activeRevision = 'rev-b';
        await waitForProbes(2);
        check(
          logs.where((l) => l.contains('deferring reconnect')).length,
        ).equals(1);

        // Roll back to rev-a and finish upload 1 -> no spurious reconnect!
        activeRevision = 'rev-a';
        await waitForProbes(1);
        currentRelayCtrl.foreign.sink.add(
          BufferFrameCodec.encode(
            FileUploadChunkFrame(
              sessionId: sessionId,
              transferId: 6,
              offset: 0,
              data: payload,
            ),
          ),
        );
        currentRelayCtrl.foreign.sink.add(
          BufferFrameCodec.encode(
            FileUploadEndFrame(
              sessionId: sessionId,
              transferId: 6,
              sha256: digest,
            ),
          ),
        );
        await waitForAck(.completed, 1);
        await waitForProbes(1);
        check(channelOpenCalls).equals(1);
        check(caster.stateMachine.state).equals(CasterLifecycleState.streaming);
        pty.writtenInputs.clear();

        // 2. Start upload 2; revision changes to rev-b while upload is in progress -> deferred, then reconnects on completion.
        currentRelayCtrl.foreign.sink.add(
          BufferFrameCodec.encode(
            FileUploadStartFrame(
              sessionId: sessionId,
              transferId: 7,
              fileName: 'notes.txt',
              totalBytes: payload.length,
            ),
          ),
        );
        await waitForAck(.ready, 2);

        activeRevision = 'rev-b';
        await waitForProbes(1);
        check(channelOpenCalls).equals(1);
        check(caster.stateMachine.state).equals(CasterLifecycleState.streaming);

        // Send chunk and end frame -> upload finalizes, path is written to PTY, and deferred reconnect fires!
        currentRelayCtrl.foreign.sink.add(
          BufferFrameCodec.encode(
            FileUploadChunkFrame(
              sessionId: sessionId,
              transferId: 7,
              offset: 0,
              data: payload,
            ),
          ),
        );
        currentRelayCtrl.foreign.sink.add(
          BufferFrameCodec.encode(
            FileUploadEndFrame(
              sessionId: sessionId,
              transferId: 7,
              sha256: digest,
            ),
          ),
        );
        await waitForAck(.completed, 2);
        final deadline2 = DateTime.now().add(const Duration(seconds: 3));
        while (channelOpenCalls < 2) {
          if (DateTime.now().isAfter(deadline2)) {
            fail('Timed out waiting for channelOpenCalls == 2');
          }
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
        check(utf8.decode(pty.writtenInputs.single)).contains('notes.txt');
        await waitForProbes(1);

        // 3. Start upload 3 and stall forever -> after uploadIdleTimeout (400ms), stalled upload is aborted and deferred reconnect fires!
        currentRelayCtrl.foreign.sink.add(
          BufferFrameCodec.encode(
            FileUploadStartFrame(
              sessionId: sessionId,
              transferId: 8,
              fileName: 'stalled.txt',
              totalBytes: 1024,
            ),
          ),
        );
        await waitForAck(.ready, 3);

        activeRevision = 'rev-c';
        await waitForProbes(1);
        check(channelOpenCalls).equals(2);

        final deadline3 = DateTime.now().add(const Duration(seconds: 3));
        while (channelOpenCalls < 3) {
          if (DateTime.now().isAfter(deadline3)) {
            fail('Timed out waiting for channelOpenCalls == 3');
          }
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        check(logs).contains('Aborted stalled file upload after idle timeout');
        check(channelOpenCalls).equals(3);
      },
    );

    test(
      'IapJwtSigner signTimeout bounds hung gcloud subprocesses and clears _inFlightJwt for subsequent calls',
      () async {
        var calls = 0;
        final signer = IapJwtSigner(
          serviceAccount: 'caster@proj.iam.gserviceaccount.com',
          targetAudienceUrl: 'https://cast.example.com/v1/caster',
          signTimeout: const Duration(milliseconds: 50),
          processRunner: (executable, arguments) {
            calls++;
            if (calls == 1) {
              return Completer<ProcessResult>().future; // Hung forever
            }
            final jwtPath = arguments.last;
            File(jwtPath).writeAsStringSync('signed-jwt-after-timeout');
            return Future<ProcessResult>.value(ProcessResult(1, 0, '', ''));
          },
        );

        Object? firstError;
        Object? secondError;
        final f1 = signer.getBearerToken().then<void>(
          (_) {},
          onError: (Object e) => firstError = e,
        );
        final f2 = signer.getBearerToken().then<void>(
          (_) {},
          onError: (Object e) => secondError = e,
        );
        await [f1, f2].wait;
        check(calls).equals(1); // Single-flight deduplicated
        check(firstError).isA<TimeoutException>();
        check(secondError).isA<TimeoutException>();

        // Next call after timeout is not wedged and mints a fresh JWT cleanly.
        final recoveredJwt = await signer.getBearerToken();
        check(calls).equals(2);
        check(recoveredJwt).equals('signed-jwt-after-timeout');
      },
    );

    test(
      'default HTTP HEAD /v1/caster revision prober over wss:// with IAP JWT detects server revision rollout',
      () => HttpOverrides.runWithHttpOverrides(() async {
        final ctx = SecurityContext()
          ..useCertificateChainBytes(utf8.encode(_testCertPem))
          ..usePrivateKeyBytes(utf8.encode(_testKeyPem));
        final httpsServer = await HttpServer.bindSecure(
          InternetAddress.loopbackIPv4,
          0,
          ctx,
        );
        addTearDown(() => httpsServer.close(force: true));

        var servedRevision = 'rev-1';
        var wsUpgrades = 0;
        final headAuthHeaders = <String?>[];
        final firstBaselineProbed = Completer<void>();
        final secondUpgradeDone = Completer<void>();

        httpsServer.listen((req) async {
          if (req.uri.path == '/v1/caster' &&
              req.method == 'HEAD' &&
              !WebSocketTransformer.isUpgradeRequest(req)) {
            headAuthHeaders.add(
              req.headers.value(HttpHeaders.authorizationHeader),
            );
            req.response
              ..statusCode = HttpStatus.ok
              ..headers.set(HttpHeaders.cacheControlHeader, 'no-store')
              ..headers.set(castRevisionHeader, servedRevision)
              ..headers.contentLength = 0;
            await req.response.close();
            if (!firstBaselineProbed.isCompleted) {
              firstBaselineProbed.complete();
            }
            return;
          }
          wsUpgrades++;
          final (:channel, closeWithCode: _) = await upgradeCastWebSocket(req);
          channel.stream.listen((bytes) {
            final frame = BufferFrameCodec.decode(bytes);
            if (frame is AuthFrame) {
              channel.sink.add(
                BufferFrameCodec.encode(const AuthAcceptedFrame(role: .caster)),
              );
            } else if (frame is RegisterSessionFrame &&
                wsUpgrades >= 2 &&
                !secondUpgradeDone.isCompleted) {
              secondUpgradeDone.complete();
            }
          });
        });

        final pty = _FakePtySession();
        var iapCalls = 0;
        final service = CasterService(
          config: CasterConfig(
            serverUri: Uri.parse(
              'wss://127.0.0.1:${httpsServer.port}/v1/caster',
            ),
            token: 'tok',
            sessionId: const SessionId('live-rev-wss'),
            title: 'zsh',
            command: const ['zsh'],
          ),
          pty: pty,
          iapTokenProvider: () async {
            iapCalls++;
            return 'iap-jwt-$iapCalls';
          },
          revisionPollInterval: const Duration(milliseconds: 80),
          baseReconnectDelay: const Duration(milliseconds: 20),
        );
        addTearDown(service.stop);

        await service.start();
        await firstBaselineProbed.future.timeout(const Duration(seconds: 3));
        check(wsUpgrades).equals(1);
        check(headAuthHeaders).isNotEmpty();
        check(headAuthHeaders.first).equals('Bearer iap-jwt-2');

        // Roll server revision to rev-2 -> default HEAD /v1/caster prober detects it and reconnects!
        servedRevision = 'rev-2';
        await secondUpgradeDone.future.timeout(const Duration(seconds: 3));
        check(wsUpgrades).equals(2);
      }, _TrustLoopbackCertHttpOverrides()),
    );

    test(
      'suppresses dirty flushes while outbound channel sink is paused, coalesces in-place on resume, and reconnects on outbound queue overflow',
      () {
        fakeAsync((async) {
          const sessionId = SessionId('uplink-bp');
          final pty = _FakePtySession();
          final serverSides = <StreamChannel<Uint8List>>[];
          final logs = <String>[];

          final service = CasterService(
            config: CasterConfig(
              sessionId: sessionId,
              title: 'shell',
              initialCols: 20,
              initialRows: 4,
              maxScrollbackLines: 50,
              command: const ['sh'],
            ),
            pty: pty,
            maxOutboundFrames: 4,
            frameCoalesceInterval: const Duration(milliseconds: 16),
            baseReconnectDelay: const Duration(milliseconds: 100),
            onLog: logs.add,
            channelOpener: () async {
              final c2s = StreamController<Uint8List>();
              final s2c = StreamController<Uint8List>();
              serverSides.add(StreamChannel<Uint8List>(c2s.stream, s2c.sink));
              return StreamChannel<Uint8List>(s2c.stream, c2s.sink);
            },
          );

          unawaited(service.start());
          async.flushMicrotasks();
          check(serverSides.length).equals(1);

          final server1Frames = <CastMessage>[];
          final sub1 = serverSides[0].stream.listen((raw) {
            server1Frames.add(BufferFrameCodec.decode(raw));
          });
          async.flushMicrotasks();
          check(server1Frames.single).isA<AuthFrame>();
          server1Frames.clear();

          serverSides[0].sink.add(
            BufferFrameCodec.encode(const AuthAcceptedFrame(role: .caster)),
          );
          serverSides[0].sink.add(
            BufferFrameCodec.encode(
              const SubscriberCountFrame(
                sessionId: sessionId,
                subscriberCount: 1,
              ),
            ),
          );
          serverSides[0].sink.add(
            BufferFrameCodec.encode(
              const RequestKeyframeFrame(sessionId: sessionId),
            ),
          );
          async.flushMicrotasks();
          final initialSnap =
              (server1Frames.whereType<BufferSnapshotFrame>().single).snapshot;
          check(initialSnap.seq).equals(1);
          server1Frames.clear();

          // Pause the server subscription to simulate uplink TCP backpressure.
          sub1.pause();

          // Emit 20 PTY screen mutations across 200ms while uplink is paused.
          for (var i = 0; i < 20; i++) {
            pty.emitText('\rFRAME-$i');
            async.elapse(const Duration(milliseconds: 20));
          }
          // AuthoritativeTerminal stays dirty and does not advance seq while paused!
          check(service.terminal.isDirty).isTrue();
          check(service.terminal.seq).equals(1);
          check(server1Frames).isEmpty();

          // Resume the uplink -> _onOutboundResume schedules a single coalesced delta flush!
          sub1.resume();
          async.flushMicrotasks();
          async.elapse(const Duration(milliseconds: 16));
          check(server1Frames.length).equals(1);
          final coalescedDelta =
              (server1Frames.single as BufferDeltaFrame).delta;
          check(coalescedDelta.baseSeq).equals(1);
          check(coalescedDelta.seq).equals(2);
          server1Frames.clear();

          // Pause again and flood > maxOutboundFrames (4) control/scrollback replies -> triggers reconnect!
          sub1.pause();
          for (var i = 0; i < 6; i++) {
            serverSides[0].sink.add(
              BufferFrameCodec.encode(
                RequestScrollbackFrame(
                  sessionId: sessionId,
                  requestId: i + 1,
                  clearSeq: 0,
                  startLine: 0,
                  count: 2,
                ),
              ),
            );
            async.flushMicrotasks();
          }
          check(logs).any((l) => l.contains('Outbound frame queue overflow'));
          check(
            service.stateMachine.state,
          ).equals(CasterLifecycleState.reconnectBackoff);

          async.elapse(const Duration(milliseconds: 250));
          check(serverSides.length).equals(2);

          unawaited(sub1.cancel());
          unawaited(pty.finish(0));
          async.flushMicrotasks();
        });
      },
    );

    test(
      'IapJwtSigner default runner kills timed-out subprocess when signTimeout is short, and runCasterCli prewarms JWT',
      () async {
        // 1. runCasterCli pre-warms iapSigner.getBearerToken() before starting Pty2Session.
        final eventOrder = <String>[];
        final prewarmSigner = IapJwtSigner(
          serviceAccount: 'caster@proj.iam.gserviceaccount.com',
          targetAudienceUrl: 'https://cast.example.com/v1/caster',
          processRunner: (exe, args, {environment}) async {
            eventOrder.add('iap_sign');
            return ProcessResult(1, 0, 'prewarmed-jwt\n', '');
          },
        );
        final exitCode = await runCasterCli(
          [
            '--session-id',
            'prewarm-demo',
            '--server',
            'wss://cast.example.com/v1/caster',
            '--',
            '/bin/sh',
            '-c',
            'exit 0',
          ],
          out: StringBuffer(),
          err: StringBuffer(),
          environment: const <String, String>{},
          iapSigner: prewarmSigner,
          channelOpener: () async {
            eventOrder.add('channel_open');
            final ctrl = StreamChannelController<Uint8List>();
            ctrl.foreign.stream.listen((_) {});
            return ctrl.local;
          },
        );
        check(const [0, -1]).contains(exitCode);
        check(eventOrder).deepEquals(['iap_sign', 'channel_open']);

        // 2. Real subprocess via default runner is killed when signTimeout expires (< 10s).
        final tempDir = await Directory.systemTemp.createTemp(
          'iap_timeout_kill_',
        );
        addTearDown(() => tempDir.delete(recursive: true));
        final pidFile = File('${tempDir.path}/child.pid');
        final fakeGcloud = File('${tempDir.path}/fake_gcloud.sh')
          ..writeAsStringSync(
            '#!/bin/sh\necho \$\$ > "${pidFile.path}"\nexec sleep 30\n',
          );
        Process.runSync('chmod', ['+x', fakeGcloud.path]);

        final signer = IapJwtSigner(
          serviceAccount: 'caster@proj.iam.gserviceaccount.com',
          targetAudienceUrl: 'https://cast.example.com/v1/caster',
          signTimeout: const Duration(milliseconds: 150),
          gcloudExecutable: fakeGcloud.path,
        );
        await check(signer.getBearerToken()).throws<TimeoutException>();
        // Wait briefly for OS process termination and verify the child PID is gone.
        if (pidFile.existsSync()) {
          final pid = int.parse(pidFile.readAsStringSync().trim());
          await Future<void>.delayed(const Duration(milliseconds: 100));
          final alive = Process.killPid(pid, ProcessSignal.sigcont);
          check(alive).isFalse();
        }
      },
      skip: Platform.isWindows ? 'Requires POSIX /bin/sh and chmod' : null,
    );

    test(
      'stop(killPty: true) escalates to SIGKILL after ptyKillTimeout when child ignores SIGTERM',
      () {
        fakeAsync((async) {
          final stubbornPty = _FakePtySession()..ignoreSigterm = true;
          final service = CasterService(
            config: CasterConfig(
              sessionId: const SessionId('sigkill-stop'),
              title: 'sh',
              command: const ['sh'],
            ),
            pty: stubbornPty,
            ptyKillTimeout: const Duration(seconds: 2),
            channelOpener: () async {
              final ctrl = StreamChannelController<Uint8List>();
              ctrl.foreign.stream.listen((_) {});
              return ctrl.local;
            },
          );

          unawaited(service.start());
          async.flushMicrotasks();

          var stopCompleted = false;
          unawaited(
            service.stop(killPty: true).then((_) {
              stopCompleted = true;
            }),
          );
          async.flushMicrotasks();
          check(stubbornPty.killSignals).deepEquals([ProcessSignal.sigterm]);
          check(stopCompleted).isFalse();

          // Elapse 2s escalation timeout -> sends SIGKILL and completes stop().
          async.elapse(const Duration(seconds: 2));
          async.flushMicrotasks();
          check(
            stubbornPty.killSignals,
          ).deepEquals([ProcessSignal.sigterm, ProcessSignal.sigkill]);
          check(stopCompleted).isTrue();
        });
      },
    );

    test(
      'CasterService writes terminal query replies back to PTY and holds coalesced frames during DECSET 2026 synchronized output up to 150ms safety timeout',
      () {
        fakeAsync((async) {
          const sessionId = SessionId('sync-and-replies');
          final pty = _FakePtySession();
          final serverFrames = <CastMessage>[];
          late StreamChannel<Uint8List> serverSide;

          final service = CasterService(
            config: CasterConfig(
              sessionId: sessionId,
              title: 'shell',
              initialCols: 20,
              initialRows: 4,
              command: const ['sh'],
            ),
            pty: pty,
            frameCoalesceInterval: const Duration(milliseconds: 16),
            channelOpener: () async {
              final c2s = StreamController<Uint8List>();
              final s2c = StreamController<Uint8List>();
              serverSide = StreamChannel<Uint8List>(c2s.stream, s2c.sink);
              return StreamChannel<Uint8List>(s2c.stream, c2s.sink);
            },
          );

          unawaited(service.start());
          async.flushMicrotasks();

          final sub = serverSide.stream.listen((raw) {
            serverFrames.add(BufferFrameCodec.decode(raw));
          });
          async.flushMicrotasks();
          serverFrames.clear();

          serverSide.sink.add(
            BufferFrameCodec.encode(const AuthAcceptedFrame(role: .caster)),
          );
          serverSide.sink.add(
            BufferFrameCodec.encode(
              const SubscriberCountFrame(
                sessionId: sessionId,
                subscriberCount: 1,
              ),
            ),
          );
          serverSide.sink.add(
            BufferFrameCodec.encode(
              const RequestKeyframeFrame(sessionId: sessionId),
            ),
          );
          async.flushMicrotasks();
          check(serverFrames.whereType<BufferSnapshotFrame>().length).equals(1);
          serverFrames.clear();

          // 1. Terminal queries (CPR, DA1, DECRQM) are batched per chunk and capped at <= 1024 chars per chunk to prevent ptm write() deadlocks.
          pty.emitText('\x1b[2;5H\x1b[6n\x1b[c\x1b[?2026\$p');
          async.flushMicrotasks();
          check([
            for (final bytes in pty.writtenInputs) utf8.decode(bytes),
          ]).deepEquals(['\x1b[2;5R\x1b[?62;22c\x1b[?2026;2\$y']);
          pty.writtenInputs.clear();
          pty.emitText('\x1b[c' * 500);
          async.flushMicrotasks();
          check(pty.writtenInputs.length).equals(1);
          final cappedReply = utf8.decode(pty.writtenInputs.single);
          check(cappedReply.length).isLessOrEqual(1024);
          check(cappedReply.length % 9).equals(0);
          async.elapse(const Duration(milliseconds: 16));
          serverFrames.clear();

          // 2. Sub-16ms multi-chunk ?2026h ... ?2026l coalesces within the 16ms frame window.
          pty.emitText('\x1b[?2026h\x1b[1;1HSUB1');
          async.flushMicrotasks();
          async.elapse(const Duration(milliseconds: 4));
          pty.emitText('SUB2\x1b[?2026l');
          async.flushMicrotasks();
          check(serverFrames).isEmpty();
          async.elapse(const Duration(milliseconds: 4));
          pty.emitText('\x1b[?2026h\x1b[1;1HSUB3\x1b[?2026l');
          async.flushMicrotasks();
          check(serverFrames).isEmpty();
          async.elapse(const Duration(milliseconds: 8));
          check(serverFrames.length).equals(1);
          check(
            (serverFrames.single as BufferDeltaFrame)
                .delta
                .runs
                .single
                .characters
                .join(),
          ).equals('SUB3SUB2');
          serverFrames.clear();

          // 3. > 16ms DECSET 2026 (?2026h) holds frame across 16ms tick and flushes immediately on ?2026l (even with same-size ResizeFrame mid-batch).
          pty.emitText('\x1b[?2026h\x1b[1;1HHALF1');
          async.flushMicrotasks();
          async.elapse(const Duration(milliseconds: 25));
          serverSide.sink.add(
            BufferFrameCodec.encode(
              const ResizeFrame(sessionId: sessionId, cols: 20, rows: 4),
            ),
          );
          async.flushMicrotasks();
          async.elapse(const Duration(milliseconds: 25));
          check(serverFrames).isEmpty();

          pty.emitText('HALF2\x1b[?2026l');
          async.flushMicrotasks();
          check(serverFrames.length).equals(1);
          final syncedSnap =
              (serverFrames.single as BufferSnapshotFrame).snapshot;
          check(syncedSnap.characters.take(10).join()).equals('HALF1HALF2');
          serverFrames.clear();

          // 4. Stalled ?2026h without ?2026l force-flushes after 150ms (even across resizes) and resets synchronizedOutput.
          pty.emitText('\x1b[?2026h\x1b[2;1HSTALLED');
          async.flushMicrotasks();
          async.elapse(const Duration(milliseconds: 50));
          serverSide.sink.add(
            BufferFrameCodec.encode(
              const ResizeFrame(sessionId: sessionId, cols: 22, rows: 5),
            ),
          );
          async.flushMicrotasks();
          async.elapse(const Duration(milliseconds: 50));
          serverSide.sink.add(
            BufferFrameCodec.encode(
              const ResizeFrame(sessionId: sessionId, cols: 20, rows: 5),
            ),
          );
          async.flushMicrotasks();
          async.elapse(const Duration(milliseconds: 49));
          check(serverFrames).isEmpty();
          async.elapse(const Duration(milliseconds: 1));
          check(serverFrames.length).equals(1);
          check(service.terminal.synchronizedOutput).isFalse();
          serverFrames.clear();

          // Subsequent output flushes at the normal 16ms coalesce interval.
          pty.emitText('\x1b[3;1HAFTER');
          async.flushMicrotasks();
          async.elapse(const Duration(milliseconds: 16));
          check(serverFrames.length).equals(1);

          // Stopping while ?2026h is active cancels _syncOutputTimeoutTimer and leaves no pending timers.
          pty.emitText('\x1b[?2026h\x1b[3;1HSTOPPING');
          async.flushMicrotasks();
          check(async.pendingTimers).isNotEmpty();
          unawaited(service.stop());
          async.flushMicrotasks();
          unawaited(sub.cancel());
          async.flushMicrotasks();
          check(async.pendingTimers).isEmpty();
        });
      },
    );

    test(
      'answers all 17 ktty_probe capability queries and streams uploaded KittyImagePayload frames',
      () {
        fakeAsync((async) {
          const sessionId = SessionId('ktty-probe-17');
          final pty = _FakePtySession();
          late StreamChannel<Uint8List> serverSide;
          final serverFrames = <CastMessage>[];
          final service = CasterService(
            config: CasterConfig(
              sessionId: sessionId,
              title: 'ktty_probe',
              initialCols: 100,
              initialRows: 30,
              command: const ['ktty_probe'],
            ),
            pty: pty,
            channelOpener: () async {
              final ctrl = StreamChannelController<Uint8List>();
              serverSide = ctrl.foreign;
              return ctrl.local;
            },
          );

          unawaited(service.start());
          async.flushMicrotasks();
          final sub = serverSide.stream.listen((raw) {
            serverFrames.add(BufferFrameCodec.decode(raw));
          });
          serverSide.sink.add(
            BufferFrameCodec.encode(const AuthAcceptedFrame(role: .caster)),
          );
          async.flushMicrotasks();
          serverSide.sink.add(
            BufferFrameCodec.encode(
              const SubscriberCountFrame(
                sessionId: sessionId,
                subscriberCount: 1,
              ),
            ),
          );
          serverSide.sink.add(
            BufferFrameCodec.encode(
              const RequestKeyframeFrame(sessionId: sessionId),
            ),
          );
          async.flushMicrotasks();
          serverFrames.clear();
          pty.writtenInputs.clear();

          final sampleRgba = Uint8List.fromList(const [
            40, 210, 255, 255, 255, 110, 190, 255, //
            110, 255, 170, 255, 255, 220, 90, 255,
          ]);
          final rawB64 = base64Encode(sampleRgba);
          final zlibB64 = base64Encode(_zlibCompressForTest(sampleRgba));
          final pngB64 = base64Encode(_pngEncode2x2ForTest(sampleRgba));

          // Emit all 17 ktty_probe queries (+ CSI 16 t cell pixel size) in one batch.
          final probeBatch = StringBuffer()
            ..write('\x1b_Gi=901,s=1,v=1,a=q,t=d,f=24;AAAA\x1b\\')
            ..write('\x1b_Gi=902,s=2,v=2,a=t,t=d,f=32,q=0;$rawB64\x1b\\')
            ..write('\x1b_Gi=903,s=2,v=2,a=t,t=d,f=32,o=z,q=0;$zlibB64\x1b\\')
            ..write('\x1b_Gi=904,a=t,t=d,f=100,q=0;$pngB64\x1b\\')
            ..write('\x1b[?u')
            ..write('\x1b[>0q')
            ..write('\x1b]10;?\x1b\\')
            ..write('\x1b]11;?\x1b\\')
            ..write('\x1b[?2026\$p')
            ..write('\x1b[?1016\$p')
            ..write('\x1b[?2027\$p')
            ..write('\x1b[?2004\$p')
            ..write('\x1b[?1004\$p')
            ..write('\x1b[?1006\$p')
            ..write('\x1b[16t')
            ..write('\x1b[18t')
            ..write('\x1b[>c')
            ..write('\x1b[c');
          pty.emitText('$probeBatch');
          async.flushMicrotasks();

          final replyStream = [
            for (final bytes in pty.writtenInputs) utf8.decode(bytes),
          ].join();

          // Assert all 17 ktty_probe replies + CSI 16 t cell-pixel reply arrived!
          final expectedTokens = <String>[
            '\x1b_Gi=901;OK\x1b\\',
            '\x1b_Gi=902;OK\x1b\\',
            '\x1b_Gi=903;OK\x1b\\',
            '\x1b_Gi=904;OK\x1b\\',
            '\x1b[?0u',
            '\x1bP>|termui',
            '\x1b]10;rgb:',
            '\x1b]11;rgb:',
            '\x1b[?2026;2\$y',
            '\x1b[?1016;2\$y',
            '\x1b[?2027;2\$y',
            '\x1b[?2004;2\$y',
            '\x1b[?1004;2\$y',
            '\x1b[?1006;2\$y',
            '\x1b[6;16;8t',
            '\x1b[8;30;100t',
            '\x1b[>',
            '\x1b[?62;22c',
          ];
          for (final token in expectedTokens) {
            check(replyStream).contains(token);
          }

          async.elapse(const Duration(milliseconds: 16));
          final deltaFrames = [...serverFrames.whereType<BufferDeltaFrame>()];
          check(deltaFrames.length).equals(1);
          final upserts = deltaFrames.single.delta.kittyUpserts;
          check(upserts).isNotNull();
          check([
            for (final p in upserts!) p.imageId,
          ]).deepEquals([902, 903, 904]);

          // Late-joining subscriber requesting keyframe gets all 3 images via snapshotCurrent().
          serverFrames.clear();
          serverSide.sink.add(
            BufferFrameCodec.encode(
              const RequestKeyframeFrame(sessionId: sessionId),
            ),
          );
          async.flushMicrotasks();
          final snapFrames = [...serverFrames.whereType<BufferSnapshotFrame>()];
          check(snapFrames.length).equals(1);
          check([
            for (final p in snapFrames.single.snapshot.kittyImages!) p.imageId,
          ]).deepEquals([902, 903, 904]);

          unawaited(service.stop());
          unawaited(sub.cancel());
          async.flushMicrotasks();
        });
      },
    );

    test(
      'CasterService.fromRouterSession handles seq == 0 no-op resize snapshot flush, endpoint clamping/release, title, bell, and audio backpressure drop',
      () {
        fakeAsync((async) {
          const sessionId = SessionId('router-cast');
          final backend = _FakeRoutedPtyBackend();
          final router = PtyRouter();
          final routerSession = router.createSession(
            id: 'local-1',
            backend: backend,
            initialCols: 60,
            initialRows: 20,
          );
          final localPort = routerSession.openPort(
            initialCols: 60,
            initialRows: 20,
          );

          late StreamChannel<Uint8List> serverSide;
          final serverFrames = <CastMessage>[];
          final service = CasterService.fromRouterSession(
            config: CasterConfig(
              sessionId: sessionId,
              title: 'local-zsh',
              initialCols: 60,
              initialRows: 20,
              command: const ['zsh'],
            ),
            session: routerSession,
            maxOutboundFrames: 64,
            maxOutboundBytes: 4096,
            channelOpener: () async {
              final ctrl = StreamChannelController<Uint8List>();
              serverSide = ctrl.foreign;
              return ctrl.local;
            },
          );

          unawaited(service.start());
          async.flushMicrotasks();
          final sub = serverSide.stream.listen((raw) {
            serverFrames.add(BufferFrameCodec.decode(raw));
          });
          async.flushMicrotasks();

          serverSide.sink.add(
            BufferFrameCodec.encode(const AuthAcceptedFrame(role: .caster)),
          );
          async.flushMicrotasks();
          serverFrames.clear();

          // 1. seq == 0 + larger remote viewer (120x40) than local tpr (60x20):
          // terminal.resize returns false, yet CasterService immediately flushes BufferSnapshotFrame at 60x20!
          serverSide.sink.add(
            BufferFrameCodec.encode(
              const SubscriberCountFrame(
                sessionId: sessionId,
                subscriberCount: 1,
              ),
            ),
          );
          serverSide.sink.add(
            BufferFrameCodec.encode(
              const ResizeFrame(sessionId: sessionId, cols: 120, rows: 40),
            ),
          );
          async.flushMicrotasks();

          final initialSnap = serverFrames
              .whereType<BufferSnapshotFrame>()
              .single;
          check((
            initialSnap.snapshot.cols,
            initialSnap.snapshot.rows,
          )).equals((60, 20));
          check(routerSession.cols).equals(60);
          check(routerSession.rows).equals(20);
          serverFrames.clear();

          // 2. Queries from PTY go through PtyRouter's single onReply once (zero double reply!).
          backend.emitText('\x1b[c');
          async.flushMicrotasks();
          check(backend.writtenStrings).deepEquals(['\x1b[?62;22c']);
          async.elapse(const Duration(milliseconds: 16));
          serverFrames.clear();

          // 3. Smaller remote viewer (40x12) clamps local tpr while subscriberCount > 0,
          // and subscriberCount -> 0 releases remote endpoint and restores 60x20!
          serverSide.sink.add(
            BufferFrameCodec.encode(
              const ResizeFrame(sessionId: sessionId, cols: 40, rows: 12),
            ),
          );
          async.flushMicrotasks();
          check((routerSession.cols, routerSession.rows)).equals((40, 12));
          check(localPort.activePtySize).equals((40, 12));
          async.elapse(const Duration(milliseconds: 16));
          serverFrames.clear();

          // 4. Live ShellTitleFrame, BellFrame, and AudioFrame emission.
          backend.emitText(
            '\x1b]2;router-nvim\x07\x07'
            '\x1b_Aa=tone,w=sine,f=520,d=40;\x1b\\'
            '\x1b_Aa=update,i=1,v=0.6,p=-0.25;\x1b\\',
          );
          async.flushMicrotasks();
          check(
            serverFrames.whereType<ShellTitleFrame>().single.title,
          ).equals('router-nvim');
          check(serverFrames.whereType<BellFrame>()).length.equals(1);
          final liveAudioFrames = [...serverFrames.whereType<AudioFrame>()];
          check(liveAudioFrames).length.equals(2);
          check(liveAudioFrames[1].payload).equals(
            const CastUpdateAudioPayload(clipId: 1, volume: 0.6, pan: -0.25),
          );
          serverFrames.clear();

          // 5. Outbound bytes >= (maxOutboundBytes * 3) ~/ 4 drops AudioFrame cleanly without reconnect!
          final pausedC2s = StreamController<Uint8List>();
          final pausedS2c = StreamController<Uint8List>();
          final receivedPaused = <CastMessage>[];
          final remoteSub = pausedC2s.stream.listen(
            (raw) => receivedPaused.add(BufferFrameCodec.decode(raw)),
          );
          final pausedService = CasterService.fromRouterSession(
            config: CasterConfig(
              sessionId: const SessionId('audio-bp'),
              title: 'bp',
              initialCols: 40,
              initialRows: 12,
              command: const ['zsh'],
            ),
            session: routerSession,
            maxOutboundFrames: 64,
            maxOutboundBytes: 512,
            channelOpener: () async =>
                StreamChannel<Uint8List>(pausedS2c.stream, pausedC2s.sink),
          );
          unawaited(pausedService.start());
          async.flushMicrotasks();
          pausedS2c.sink.add(
            BufferFrameCodec.encode(const AuthAcceptedFrame(role: .caster)),
          );
          pausedS2c.sink.add(
            BufferFrameCodec.encode(
              const SubscriberCountFrame(
                sessionId: SessionId('audio-bp'),
                subscriberCount: 1,
              ),
            ),
          );
          async.flushMicrotasks();
          receivedPaused.clear();

          // Pause the uplink, flush microtasks so controller.isPaused propagates,
          // queue a 350-byte clip (> 75% of 512 = 384), then emit 5 tones and a bus vol that must all drop,
          // followed by control bus create/attach/destroy + stop frames that stay reliable within maxOutboundBytes!
          remoteSub.pause();
          async.flushMicrotasks();
          final clipBytes = Uint8List.fromList(
            List<int>.generate(350, (i) => (i * 137 + 19) & 0xFF),
          );
          final clipB64 = base64Encode(clipBytes);
          backend.emitText('\x1b_Aa=clip,i=1,f=wav,s=150,b=2;$clipB64\x1b\\');
          async.flushMicrotasks();
          backend.emitText('\x1b_Aa=tone,w=sine,f=880,d=20,b=2;\x1b\\' * 5);
          backend.emitText('\x1b_Aa=bus,op=create,b=2;\x1b\\');
          backend.emitText('\x1b_Aa=bus,op=attach,b=2,ft=7;\x1b\\');
          backend.emitText('\x1b_Aa=bus,op=vol,b=2,v=0.5;\x1b\\');
          backend.emitText('\x1b_Aa=bus,op=destroy,b=2;\x1b\\');
          backend.emitText('\x1b_Aa=stop,i=1;\x1b\\');
          async.flushMicrotasks();

          check(
            pausedService.stateMachine.state,
          ).equals(CasterLifecycleState.streaming);
          remoteSub.resume();
          async.flushMicrotasks();
          final receivedAudio = [...receivedPaused.whereType<AudioFrame>()];
          check(receivedAudio).length.equals(5);
          check(receivedAudio.first.payload)
              .isA<CastClipAudioPayload>()
              .has((p) => p.startOffset, 'startOffset')
              .equals(const Duration(milliseconds: 150));
          check(
            (receivedAudio.first.payload as CastClipAudioPayload).busId,
          ).equals(2);
          check(
            receivedAudio[1].payload,
          ).equals(const CastBusAudioPayload(op: 'create', busId: 2));
          check(receivedAudio[2].payload).equals(
            const CastBusAudioPayload(op: 'attach', busId: 2, filterId: 7),
          );
          check(
            receivedAudio[3].payload,
          ).equals(const CastBusAudioPayload(op: 'destroy', busId: 2));
          check(
            receivedAudio.last.payload,
          ).equals(const CastStopAudioPayload(clipId: 1));

          // Verify stream open/end and streamId clip play stay reliable while stream chunks drop under pressure.
          receivedPaused.clear();
          remoteSub.pause();
          async.flushMicrotasks();
          backend.emitText('\x1b_Aa=clip,i=2,f=wav;$clipB64\x1b\\');
          async.flushMicrotasks();
          backend.emitText(
            '\x1b_Aa=stream,op=open,s=4,max=4194304,rel=0,buf=200,sr=48000,ch=2;\x1b\\',
          );
          backend.emitText(
            '\x1b_Aa=stream,op=chunk,s=4,seq=0;${base64Encode([1, 2, 3])}\x1b\\',
          );
          backend.emitText('\x1b_Aa=stream,op=end,s=4,seq=1;\x1b\\');
          async.flushMicrotasks();
          remoteSub.resume();
          async.flushMicrotasks();
          final streamAudio1 = [...receivedPaused.whereType<AudioFrame>()];
          check(streamAudio1).length.equals(3);
          check(streamAudio1[1].payload).equals(
            const CastStreamAudioPayload(
              op: 'open',
              streamId: 4,
              maxBufferSize: 4194304,
              releaseConsumed: false,
              bufferingTimeNeeds: Duration(milliseconds: 200),
              sampleRate: 48000,
              channels: 2,
            ),
          );
          check(streamAudio1[2].payload).equals(
            const CastStreamAudioPayload(op: 'end', streamId: 4, seq: 1),
          );

          receivedPaused.clear();
          remoteSub.pause();
          async.flushMicrotasks();
          backend.emitText('\x1b_Aa=clip,i=3,f=wav;$clipB64\x1b\\');
          async.flushMicrotasks();
          backend.emitText(
            '\x1b_Aa=stream,op=chunk,s=4,seq=2;${base64Encode([4, 5, 6])}\x1b\\',
          );
          backend.emitText('\x1b_Aa=clip,i=8,st=4,v=0.7,p=-0.1,l=1;\x1b\\');
          async.flushMicrotasks();
          remoteSub.resume();
          async.flushMicrotasks();
          final streamAudio2 = [...receivedPaused.whereType<AudioFrame>()];
          check(streamAudio2).length.equals(2);
          check(streamAudio2.last.payload)
              .isA<CastClipAudioPayload>()
              .has((p) => p.streamId, 'streamId')
              .equals(4);

          unawaited(pausedService.stop());
          unawaited(remoteSub.cancel());
          unawaited(pausedC2s.close());
          unawaited(pausedS2c.close());
          async.flushMicrotasks();

          // 5b. Outbound frame count >= (maxOutboundFrames * 3) ~/ 4 drops droppable audio & waveform queries
          // while preserving control frames (stop / stream end) in the remaining 25% of slots!
          final slotC2s = StreamController<Uint8List>();
          final slotS2c = StreamController<Uint8List>();
          final receivedSlot = <CastMessage>[];
          final slotSub = slotC2s.stream.listen(
            (raw) => receivedSlot.add(BufferFrameCodec.decode(raw)),
          );
          final slotService = CasterService.fromRouterSession(
            config: CasterConfig(
              sessionId: const SessionId('audio-slots'),
              title: 'slots',
              initialCols: 40,
              initialRows: 12,
              command: const ['zsh'],
            ),
            session: routerSession,
            maxOutboundFrames: 8,
            maxOutboundBytes: 64 * 1024,
            channelOpener: () async =>
                StreamChannel<Uint8List>(slotS2c.stream, slotC2s.sink),
          );
          unawaited(slotService.start());
          async.flushMicrotasks();
          slotS2c.sink.add(
            BufferFrameCodec.encode(const AuthAcceptedFrame(role: .caster)),
          );
          slotS2c.sink.add(
            BufferFrameCodec.encode(
              const SubscriberCountFrame(
                sessionId: SessionId('audio-slots'),
                subscriberCount: 1,
              ),
            ),
          );
          async.flushMicrotasks();
          receivedSlot.clear();

          slotSub.pause();
          async.flushMicrotasks();
          // Emit 8 small droppable pan updates (6 fit before highWaterFrames=6; 7th & 8th drop),
          // plus a waveform query (dropped at >=6) and two reliable control frames (slots 7 & 8).
          for (var k = 0; k < 8; k++) {
            backend.emitText('\x1b_Aa=update,i=1,p=0.$k;\x1b\\');
          }
          backend.emitText('\x1b_Aa=wave,q=7;\x1b\\');
          backend.emitText('\x1b_Aa=stop,i=1;\x1b\\');
          backend.emitText('\x1b_Aa=stream,op=end,s=4,seq=2;\x1b\\');
          async.flushMicrotasks();

          check(
            slotService.stateMachine.state,
          ).equals(CasterLifecycleState.streaming);
          slotSub.resume();
          async.flushMicrotasks();

          final slotAudio = [...receivedSlot.whereType<AudioFrame>()];
          check(slotAudio).length.equals(8);
          check(
            slotAudio.where((f) => f.payload is CastUpdateAudioPayload),
          ).length.equals(6);
          check(
            slotAudio.where((f) => f.payload is CastWaveformQueryAudioPayload),
          ).isEmpty();
          check(
            slotAudio[6].payload,
          ).equals(const CastStopAudioPayload(clipId: 1));
          check(slotAudio[7].payload).equals(
            const CastStreamAudioPayload(op: 'end', streamId: 4, seq: 2),
          );

          unawaited(slotService.stop());
          unawaited(slotSub.cancel());
          unawaited(slotC2s.close());
          unawaited(slotS2c.close());
          async.flushMicrotasks();

          // 6. subscriberCount -> 0 releases remote endpoint and clears stale
          // viewport so a subsequent 0 -> 1 join does NOT snap back to 40x12!
          serverSide.sink.add(
            BufferFrameCodec.encode(
              const SubscriberCountFrame(
                sessionId: sessionId,
                subscriberCount: 0,
              ),
            ),
          );
          async.flushMicrotasks();
          check((routerSession.cols, routerSession.rows)).equals((60, 20));
          check(localPort.activePtySize).equals((60, 20));

          serverSide.sink.add(
            BufferFrameCodec.encode(
              const SubscriberCountFrame(
                sessionId: sessionId,
                subscriberCount: 1,
              ),
            ),
          );
          async.flushMicrotasks();
          check((routerSession.cols, routerSession.rows)).equals((60, 20));
          check(localPort.activePtySize).equals((60, 20));

          // 7. Stopping CasterService does NOT dispose PtyRouterSession or kill local shell!
          unawaited(service.stop());
          unawaited(sub.cancel());
          async.flushMicrotasks();
          check(routerSession.isDisposed).isFalse();
          check(backend.killed).isFalse();

          unawaited(localPort.dispose());
          unawaited(router.dispose());
          unawaited(backend.dispose());
          async.flushMicrotasks();
        });
      },
    );

    _registerRouterAuthFailTest();
    _registerTitleBellBurstTest();
    _registerPty2AckTest();
    _registerWaveformQueryReplyTest();
  });
}

void _registerRouterAuthFailTest() {
  test(
    'CasterService.fromRouterSession fatal ErrorFrame exits with 78 without killing backend or disposing routerSession',
    () {
      fakeAsync((async) {
        const sessionId = SessionId('router-auth-fail');
        final backend = _FakeRoutedPtyBackend();
        final router = PtyRouter();
        final routerSession = router.createSession(
          id: 'local-auth-fail',
          backend: backend,
          initialCols: 80,
          initialRows: 24,
        );

        late StreamChannel<Uint8List> serverSide;
        final service = CasterService.fromRouterSession(
          config: CasterConfig(
            sessionId: sessionId,
            title: 'local-zsh',
            initialCols: 80,
            initialRows: 24,
            command: const ['zsh'],
          ),
          session: routerSession,
          channelOpener: () async {
            final ctrl = StreamChannelController<Uint8List>();
            serverSide = ctrl.foreign;
            return ctrl.local;
          },
        );

        int? exitedCode;
        unawaited(service.done.then((code) => exitedCode = code));
        unawaited(service.start());
        async.flushMicrotasks();
        final sub = serverSide.stream.listen((_) {});
        async.flushMicrotasks();

        serverSide.sink.add(
          BufferFrameCodec.encode(
            const ErrorFrame(code: 'auth_failed', message: 'bad token'),
          ),
        );
        async.flushMicrotasks();

        check(exitedCode).equals(78);
        check(backend.killed).isFalse();
        check(routerSession.isDisposed).isFalse();

        unawaited(sub.cancel());
        unawaited(router.dispose());
        unawaited(backend.dispose());
        async.flushMicrotasks();
      });
    },
  );
}

void _registerTitleBellBurstTest() {
  test(
    'CasterService coalesces 200 rapid OSC 2 titles (even when unsubscribed), syncs pinned shellTitle on reconnect, and rate-limits 200 BEL bursts without reconnecting',
    () {
      fakeAsync((async) {
        const sessionId = SessionId('title-bell-burst');
        final pty = _FakePtySession();
        final channels = <StreamChannel<Uint8List>>[];
        final sentFrames = <CastMessage>[];
        final subRefs = <StreamSubscription<Uint8List>>[];

        final service = CasterService(
          config: CasterConfig(
            sessionId: sessionId,
            title: 'initial',
            initialCols: 40,
            initialRows: 12,
            command: const ['zsh'],
          ),
          pty: pty,
          maxOutboundFrames: 8,
          maxOutboundBytes: 4096,
          baseReconnectDelay: const Duration(milliseconds: 50),
          channelOpener: () async {
            final ctrl = StreamChannelController<Uint8List>();
            channels.add(ctrl.foreign);
            subRefs.add(
              ctrl.foreign.stream.listen(
                (raw) => sentFrames.add(BufferFrameCodec.decode(raw)),
              ),
            );
            return ctrl.local;
          },
        );

        unawaited(service.start());
        async.flushMicrotasks();
        check(channels).length.equals(1);
        channels.first.sink.add(
          BufferFrameCodec.encode(const AuthAcceptedFrame(role: .caster)),
        );
        async.flushMicrotasks();
        sentFrames.clear();

        // 1. Even with subscriberCount == 0, 200 rapid OSC 2 updates emit leading + trailing (150ms) ShellTitleFrames without reconnecting!
        for (var i = 0; i < 200; i++) {
          pty.emitText('\x1b]2;spin-$i\x07');
        }
        async.flushMicrotasks();
        check(
          sentFrames.whereType<ShellTitleFrame>().map((f) => f.title),
        ).deepEquals(['spin-0']);
        async.elapse(const Duration(milliseconds: 150));
        async.flushMicrotasks();
        check(
          sentFrames.whereType<ShellTitleFrame>().map((f) => f.title),
        ).deepEquals(['spin-0', 'spin-199']);
        async.elapse(const Duration(milliseconds: 150));
        async.flushMicrotasks();
        check(sentFrames.whereType<ShellTitleFrame>()).length.equals(2);
        check(channels).length.equals(1);

        // 2. Reconnect while pinned preserves custom title in RegisterSessionFrame AND sends ShellTitleFrame for live shellTitle!
        channels.first.sink.add(
          BufferFrameCodec.encode(
            const RenameSessionFrame(
              sessionId: sessionId,
              title: 'Pinned Custom',
            ),
          ),
        );
        async.flushMicrotasks();
        sentFrames.clear();
        unawaited(service.checkIn());
        async.flushMicrotasks();
        check(channels).length.equals(2);
        channels[1].sink.add(
          BufferFrameCodec.encode(const AuthAcceptedFrame(role: .caster)),
        );
        async.flushMicrotasks();
        final reg = sentFrames.whereType<RegisterSessionFrame>().single;
        check(reg.title).equals('Pinned Custom');
        final syncedTitle = sentFrames.whereType<ShellTitleFrame>().single;
        check(syncedTitle.title).equals('spin-199');

        // 3. Subscribe 1 viewer and burst 200 BELs within 50ms -> at most 1 BellFrame per 75ms, and droppable queue overflow never reconnects!
        channels[1].sink.add(
          BufferFrameCodec.encode(
            const SubscriberCountFrame(
              sessionId: sessionId,
              subscriberCount: 1,
            ),
          ),
        );
        async.flushMicrotasks();
        sentFrames.clear();

        pty.emitText('\x07' * 200);
        async.flushMicrotasks();
        check(sentFrames.whereType<BellFrame>()).length.equals(1);

        async.elapse(const Duration(milliseconds: 50));
        pty.emitText('\x07' * 50);
        async.flushMicrotasks();
        check(sentFrames.whereType<BellFrame>()).length.equals(1);

        async.elapse(const Duration(milliseconds: 25));
        pty.emitText('\x07' * 50);
        async.flushMicrotasks();
        check(sentFrames.whereType<BellFrame>()).length.equals(2);

        // Pause channel and burst 200 more BELs across 75ms windows -> droppable never triggers reconnect!
        subRefs[1].pause();
        async.flushMicrotasks();
        for (var w = 0; w < 20; w++) {
          async.elapse(const Duration(milliseconds: 80));
          pty.emitText('\x07' * 10);
          async.flushMicrotasks();
        }
        check(
          service.stateMachine.state,
        ).equals(CasterLifecycleState.streaming);
        check(channels).length.equals(2);

        unawaited(service.stop());
        for (final s in subRefs) {
          unawaited(s.cancel());
        }
        async.flushMicrotasks();
        check(async.pendingTimers).isEmpty();
      });
    },
  );
}

void _registerPty2AckTest() {
  test(
    'Pty2Session schedules ack even when a synchronous output listener throws',
    () async {
      final fakePty = _FakeAckPseudoTerminal();
      final session = Pty2Session.wrap(fakePty);
      addTearDown(() async {
        session.kill();
        await fakePty.close();
      });

      final errors = <Object>[];
      final received = <String>[];
      final secondReceived = Completer<void>();

      await runZonedGuarded(() async {
        final sub = session.output.listen((bytes) {
          final text = utf8.decode(bytes);
          if (text == 'first') {
            throw StateError('sync listener error');
          }
          received.add(text);
          if (text == 'second' && !secondReceived.isCompleted) {
            secondReceived.complete();
          }
        });
        addTearDown(sub.cancel);

        fakePty.ackCompleter = Completer<void>();
        fakePty.emitChunk('first');
        await fakePty.ackCompleter!.future.timeout(const Duration(seconds: 2));
        check(fakePty.ackCount).equals(1);

        fakePty.ackCompleter = Completer<void>();
        fakePty.emitChunk('second');
        await secondReceived.future.timeout(const Duration(seconds: 2));
        await fakePty.ackCompleter!.future.timeout(const Duration(seconds: 2));
      }, (error, _) => errors.add(error));

      check(errors).length.equals(1);
      check(received).deepEquals(['second']);
      check(fakePty.ackCount).equals(2);
    },
  );
}

void _registerWaveformQueryReplyTest() {
  test(
    'CasterService handles a=wave queries (0-subscriber empty reply, single-winner _pendingWaveformReqId, and post-exit guard)',
    () {
      fakeAsync((async) {
        const sessionId = SessionId('wave-sess');
        final pty = _FakePtySession();
        final sentFrames = <CastMessage>[];
        late StreamChannelController<Uint8List> channelCtrl;
        final service = CasterService(
          config: CasterConfig(
            sessionId: sessionId,
            title: 'wave',
            initialCols: 40,
            initialRows: 12,
            command: const ['zsh'],
          ),
          pty: pty,
          channelOpener: () async {
            channelCtrl = StreamChannelController<Uint8List>();
            channelCtrl.local.stream.listen(
              (b) => sentFrames.add(BufferFrameCodec.decode(b)),
            );
            return channelCtrl.foreign;
          },
        );

        unawaited(service.start());
        async.flushMicrotasks();
        channelCtrl.local.sink.add(
          BufferFrameCodec.encode(const AuthAcceptedFrame(role: .caster)),
        );
        async.flushMicrotasks();
        sentFrames.clear();

        // 1. With 0 subscribers and live PTY, a=wave writes empty a=waver immediately.
        pty.emitText('\x1b_Aa=wave,q=1;\x1b\\');
        async.flushMicrotasks();
        check(
          pty.writtenInputs.map(utf8.decode),
        ).deepEquals(['\x1b_Aa=waver,q=1;\x1b\\']);
        check(sentFrames.whereType<AudioFrame>()).isEmpty();
        pty.writtenInputs.clear();

        // 2. With subscribers > 0, forwards CastWaveformQueryAudioPayload and accepts ONLY first matching reply.
        channelCtrl.local.sink.add(
          BufferFrameCodec.encode(
            const SubscriberCountFrame(
              sessionId: sessionId,
              subscriberCount: 2,
            ),
          ),
        );
        async.flushMicrotasks();
        pty.emitText('\x1b_Aa=wave,q=2;\x1b\\');
        async.flushMicrotasks();
        final queryPayload =
            sentFrames.whereType<AudioFrame>().single.payload
                as CastWaveformQueryAudioPayload;
        check(
          queryPayload,
        ).equals(const CastWaveformQueryAudioPayload(requestId: 2));

        // Stale requestId=1 is dropped.
        final s1 = Float32List(256)..[0] = 0.25;
        final s2 = Float32List(256)..[0] = 0.75;
        channelCtrl.local.sink.add(
          BufferFrameCodec.encode(
            AudioWaveformReplyFrame(
              sessionId: sessionId,
              requestId: 1,
              samples: s1,
            ),
          ),
        );
        async.flushMicrotasks();
        check(pty.writtenInputs).isEmpty();

        // First matching viewer reply (q=2) writes a=waver; second viewer reply (q=2) is dropped!
        channelCtrl.local.sink.add(
          BufferFrameCodec.encode(
            AudioWaveformReplyFrame(
              sessionId: sessionId,
              requestId: 2,
              samples: s1,
            ),
          ),
        );
        channelCtrl.local.sink.add(
          BufferFrameCodec.encode(
            AudioWaveformReplyFrame(
              sessionId: sessionId,
              requestId: 2,
              samples: s2,
            ),
          ),
        );
        async.flushMicrotasks();
        check(pty.writtenInputs).length.equals(1);
        check(
          utf8.decode(pty.writtenInputs.single),
        ).equals(AudioApcHandler.encodeWaveformReply(2, s1));
        pty.writtenInputs.clear();

        // 3. After child PTY finishes, late AudioWaveformReplyFrame is ignored.
        pty.emitText('\x1b_Aa=wave,q=3;\x1b\\');
        async.flushMicrotasks();
        unawaited(pty.finish(0));
        async.flushMicrotasks();
        channelCtrl.local.sink.add(
          BufferFrameCodec.encode(
            AudioWaveformReplyFrame(
              sessionId: sessionId,
              requestId: 3,
              samples: s2,
            ),
          ),
        );
        async.flushMicrotasks();
        check(pty.writtenInputs).isEmpty();

        unawaited(service.stop());
        unawaited(channelCtrl.local.sink.close());
        async.flushMicrotasks();
      });
    },
  );

  group(
    'Wave 1 hardening: config, clamping, backoff, pending title, drain & statusStream',
    () {
      test(
        'CasterConfig warns on --token, reads --token-file / env, validates mutual exclusion, and rejects userInfo',
        () {
          final tempDir = Directory.systemTemp.createTempSync('caster_tok_');
          addTearDown(() => tempDir.deleteSync(recursive: true));
          final tokenFile = File('${tempDir.path}/token.txt')
            ..writeAsStringSync('file-secret-tok\n');

          final cliTokCfg = CasterConfig.fromArgs([
            '--token',
            'argv-secret',
            '--keep-alive-on-hup',
            '--',
            'sh',
          ]);
          check(cliTokCfg).isNotNull();
          check(cliTokCfg!.token).equals('argv-secret');
          check(cliTokCfg.keepAliveOnHup).isTrue();
          check(cliTokCfg.warnings).length.equals(1);
          check(cliTokCfg.warnings.single).contains('--token');

          final fileCfg = CasterConfig.fromArgs([
            '--token-file',
            tokenFile.path,
            '--',
            'sh',
          ]);
          check(fileCfg!.token).equals('file-secret-tok');
          check(fileCfg.warnings).isEmpty();
          check(fileCfg.keepAliveOnHup).isFalse();

          final envFileCfg = CasterConfig.fromArgs(
            ['--', 'sh'],
            environment: {'TERMUI_CAST_CASTER_TOKEN_FILE': tokenFile.path},
          );
          check(envFileCfg!.token).equals('file-secret-tok');

          check(
            () => CasterConfig.fromArgs([
              '--token',
              'a',
              '--token-file',
              tokenFile.path,
              '--',
              'sh',
            ]),
          ).throws<FormatException>();
          check(
            () => CasterConfig.fromArgs([
              '--server',
              'ws://user:pass@127.0.0.1:8420/v1/caster',
              '--',
              'sh',
            ]),
          ).throws<FormatException>();
        },
      );

      test(
        'fromRouterSession clamps >400x200 router dimensions on RegisterSessionFrame & BufferSnapshotFrame',
        () {
          fakeAsync((async) {
            final backend = _FakeRoutedPtyBackend();
            final router = PtyRouter();
            final session = router.createSession(
              id: 'wide-router',
              backend: backend,
              initialCols: 450,
              initialRows: 230,
            );
            addTearDown(session.dispose);

            final sentFrames = <CastMessage>[];
            late StreamChannel<Uint8List> serverSide;
            final service = CasterService.fromRouterSession(
              config: CasterConfig(
                sessionId: const SessionId('wide-router'),
                title: 'wide',
                command: const ['sh'],
              ),
              session: session,
              channelOpener: () async {
                final c2s = StreamController<Uint8List>();
                final s2c = StreamController<Uint8List>();
                serverSide = StreamChannel<Uint8List>(c2s.stream, s2c.sink);
                return StreamChannel<Uint8List>(s2c.stream, c2s.sink);
              },
            );

            unawaited(service.start());
            async.flushMicrotasks();
            serverSide.stream.listen((raw) {
              sentFrames.add(BufferFrameCodec.decode(raw));
            });
            serverSide.sink.add(
              BufferFrameCodec.encode(const AuthAcceptedFrame(role: .caster)),
            );
            serverSide.sink.add(
              BufferFrameCodec.encode(
                const SubscriberCountFrame(
                  sessionId: SessionId('wide-router'),
                  subscriberCount: 1,
                ),
              ),
            );
            serverSide.sink.add(
              BufferFrameCodec.encode(
                const RequestKeyframeFrame(sessionId: SessionId('wide-router')),
              ),
            );
            async.flushMicrotasks();

            final reg = sentFrames.whereType<RegisterSessionFrame>().single;
            check(reg.cols).equals(BufferFrameCodec.maxGridCols);
            check(reg.rows).equals(BufferFrameCodec.maxGridRows);
            final snap = sentFrames.whereType<BufferSnapshotFrame>().single;
            check(snap.snapshot.cols).equals(BufferFrameCodec.maxGridCols);
            check(snap.snapshot.rows).equals(BufferFrameCodec.maxGridRows);

            unawaited(service.stop());
            async.flushMicrotasks();
          });
        },
      );

      test(
        'resets backoff only after SubscriberCountFrame, escalates duplicate_session backoff, preserves pending title on pause, and emits statusStream',
        () {
          fakeAsync((async) {
            final pty = _FakePtySession();
            final serverSides = <StreamChannel<Uint8List>>[];
            final statuses = <CasterStatusSnapshot>[];
            final service = CasterService(
              config: CasterConfig(
                sessionId: const SessionId('backoff-reg'),
                title: 'shell',
                command: const ['sh'],
              ),
              pty: pty,
              random: Random(1),
              baseReconnectDelay: const Duration(milliseconds: 100),
              channelOpener: () async {
                final ctrl = StreamChannelController<Uint8List>();
                serverSides.add(ctrl.foreign);
                return ctrl.local;
              },
            );
            final statusSub = service.statusStream.listen(statuses.add);
            addTearDown(statusSub.cancel);

            unawaited(service.start());
            async.flushMicrotasks();

            for (var attempt = 0; attempt < 2; attempt++) {
              final frames = <CastMessage>[];
              serverSides[attempt].stream.listen((raw) {
                frames.add(BufferFrameCodec.decode(raw));
              });
              serverSides[attempt].sink.add(
                BufferFrameCodec.encode(const AuthAcceptedFrame(role: .caster)),
              );
              async.flushMicrotasks();
              serverSides[attempt].sink.add(
                BufferFrameCodec.encode(
                  const ErrorFrame(
                    code: 'duplicate_session',
                    message: 'still active',
                  ),
                ),
              );
              async.flushMicrotasks();
              check(service.stateMachine.reconnectAttempt).equals(attempt + 1);
              // Must escalate past 100ms base delay (attempt 2 >= 100ms, never reset by AuthAccepted).
              async.elapse(const Duration(milliseconds: 250));
            }
            check(serverSides.length).equals(3);

            final s3Frames = <CastMessage>[];
            final s3PauseCtrl = StreamController<Uint8List>();
            serverSides[2].stream.listen((raw) {
              s3Frames.add(BufferFrameCodec.decode(raw));
            });
            serverSides[2].sink.add(
              BufferFrameCodec.encode(const AuthAcceptedFrame(role: .caster)),
            );
            async.flushMicrotasks();
            check(service.stateMachine.reconnectAttempt).equals(2);

            serverSides[2].sink.add(
              BufferFrameCodec.encode(
                const SubscriberCountFrame(
                  sessionId: SessionId('backoff-reg'),
                  subscriberCount: 1,
                ),
              ),
            );
            async.flushMicrotasks();
            check(service.stateMachine.reconnectAttempt).equals(0);
            check(service.currentStatus.subscriberCount).equals(1);
            check(statuses.any((s) => s.subscriberCount == 1)).isTrue();

            // Shell title during cooldown survives _cancelFrameTimers on resize.
            s3Frames.clear();
            pty.emitText('\x1b]2;title-first\x07');
            async.flushMicrotasks();
            pty.emitText('\x1b]2;title-pending\x07');
            async.flushMicrotasks();
            serverSides[2].sink.add(
              BufferFrameCodec.encode(
                const ResizeFrame(
                  sessionId: SessionId('backoff-reg'),
                  cols: 30,
                  rows: 10,
                ),
              ),
            );
            async.flushMicrotasks();
            async.elapse(const Duration(milliseconds: 150));
            check(
              s3Frames.whereType<ShellTitleFrame>().map((f) => f.title),
            ).contains('title-pending');

            unawaited(s3PauseCtrl.close());
            unawaited(pty.finish(0));
            async.flushMicrotasks();
            async.elapse(const Duration(milliseconds: 500));
          });
        },
      );

      test(
        'bounds _awaitPtyExit drain at 500ms if PTY output stays open and drains SessionClosedFrame on exit',
        () {
          fakeAsync((async) {
            final outputCtrl = StreamController<Uint8List>();
            final exitCompleter = Completer<int>();
            final pty = _OpenOutputFakePty(
              outputCtrl.stream,
              exitCompleter.future,
            );
            final serverFrames = <CastMessage>[];
            late StreamChannel<Uint8List> serverSide;
            final service = CasterService(
              config: CasterConfig(
                sessionId: const SessionId('drain-bound'),
                title: 'sh',
                command: const ['sh'],
              ),
              pty: pty,
              channelOpener: () async {
                final ctrl = StreamChannelController<Uint8List>();
                serverSide = ctrl.foreign;
                serverSide.stream.listen((raw) {
                  serverFrames.add(BufferFrameCodec.decode(raw));
                });
                return ctrl.local;
              },
            );

            unawaited(service.start());
            async.flushMicrotasks();
            serverSide.sink.add(
              BufferFrameCodec.encode(const AuthAcceptedFrame(role: .caster)),
            );
            async.flushMicrotasks();

            var completed = false;
            unawaited(service.done.then((_) => completed = true));
            exitCompleter.complete(0);
            async.flushMicrotasks();
            check(completed).isFalse();

            async.elapse(const Duration(milliseconds: 500));
            async.flushMicrotasks();
            check(completed).isTrue();
            check(
              serverFrames.whereType<SessionClosedFrame>().single.reason,
            ).equals(SessionCloseReason.exited);

            unawaited(outputCtrl.close());
            async.flushMicrotasks();
          });
        },
      );
    },
  );
}

final class _OpenOutputFakePty implements PtySession {
  @override
  final Stream<Uint8List> output;
  @override
  final Future<int> exitCode;

  _OpenOutputFakePty(this.output, this.exitCode);

  @override
  void writeBytes(Uint8List data) {}

  @override
  void resize(int cols, int rows, {int pixelWidth = 0, int pixelHeight = 0}) {}

  @override
  bool kill([ProcessSignal signal = .sigterm]) => true;
}

final class _FakeAckPseudoTerminal implements PseudoTerminal {
  final StreamController<String> _out = StreamController<String>.broadcast();
  final Completer<int> _exitCode = Completer<int>();
  int ackCount = 0;
  Completer<void>? ackCompleter;

  void emitChunk(String text) => _out.add(text);

  @override
  Stream<String> get out => _out.stream;

  @override
  Future<int> get exitCode => _exitCode.future;

  @override
  void ackProcessed() {
    ackCount += 1;
    final completer = ackCompleter;
    if (completer != null && !completer.isCompleted) {
      completer.complete();
    }
  }

  @override
  void init() {}

  @override
  void write(String input) {}

  @override
  void resize(
    int width,
    int height, {
    int pixelWidth = 0,
    int pixelHeight = 0,
  }) {}

  @override
  bool kill([ProcessSignal signal = .sigterm]) => true;

  Future<void> close() async {
    if (!_out.isClosed) await _out.close();
    if (!_exitCode.isCompleted) _exitCode.complete(0);
  }
}

final class _FakeRoutedPtyBackend implements RoutedPtyBackend {
  final StreamController<Uint8List> _output =
      StreamController<Uint8List>.broadcast();
  final Completer<int> _exitCode = Completer<int>();
  final List<String> writtenStrings = [];
  bool killed = false;

  @override
  Stream<Uint8List> get output => _output.stream;

  @override
  Future<int> get exitCode => _exitCode.future;

  void emitText(String text) {
    _output.add(Uint8List.fromList(utf8.encode(text)));
  }

  @override
  void write(Uint8List bytes) {
    writtenStrings.add(utf8.decode(bytes));
  }

  @override
  void resize(int cols, int rows, {int pixelWidth = 0, int pixelHeight = 0}) {}

  @override
  void kill() {
    killed = true;
    if (!_exitCode.isCompleted) _exitCode.complete(0);
  }

  @override
  Future<void> dispose() async {
    if (!_output.isClosed) await _output.close();
    if (!_exitCode.isCompleted) _exitCode.complete(0);
  }
}

Uint8List _zlibCompressForTest(Uint8List raw) =>
    Uint8List.fromList(zlib.encode(raw));

Uint8List _pngEncode2x2ForTest(Uint8List rgba) {
  final table = Uint32List(256);
  for (var i = 0; i < 256; i++) {
    var c = i;
    for (var k = 0; k < 8; k++) {
      c = (c & 1) != 0 ? (0xEDB88320 ^ (c >>> 1)) : (c >>> 1);
    }
    table[i] = c;
  }
  int crc32(List<int> typeBytes, Uint8List data) {
    var crc = 0xFFFFFFFF;
    for (final b in typeBytes) {
      crc = table[(crc ^ b) & 0xFF] ^ (crc >>> 8);
    }
    for (final b in data) {
      crc = table[(crc ^ b) & 0xFF] ^ (crc >>> 8);
    }
    return (crc ^ 0xFFFFFFFF) & 0xFFFFFFFF;
  }

  final scanlines = Uint8List(18);
  scanlines.setRange(1, 9, rgba, 0);
  scanlines.setRange(10, 18, rgba, 8);
  final ihdr = Uint8List(13);
  ByteData.sublistView(ihdr)
    ..setUint32(0, 2)
    ..setUint32(4, 2)
    ..setUint8(8, 8)
    ..setUint8(9, 6);
  final out = BytesBuilder(copy: false)
    ..add(const [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);
  for (final (type, chunkData) in [
    ('IHDR', ihdr),
    ('IDAT', _zlibCompressForTest(scanlines)),
    ('IEND', Uint8List(0)),
  ]) {
    final typeBytes = ascii.encode(type);
    final header = ByteData(4)..setUint32(0, chunkData.length);
    final footer = ByteData(4)..setUint32(0, crc32(typeBytes, chunkData));
    out
      ..add(header.buffer.asUint8List())
      ..add(typeBytes)
      ..add(chunkData)
      ..add(footer.buffer.asUint8List());
  }
  return out.takeBytes();
}
