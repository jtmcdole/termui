import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:checks/checks.dart';
import 'package:stream_channel/stream_channel.dart';
import 'package:termui_cast_protocol/termui_cast_protocol.dart';
import 'package:termui_caster_cli/termui_caster_cli.dart';
import 'package:test/test.dart';

final class _FakePtySession implements PtySession {
  final StreamController<Uint8List> _outputController =
      StreamController<Uint8List>.broadcast();
  final Completer<int> _exitCompleter = Completer<int>();
  bool killed = false;

  @override
  Stream<Uint8List> get output => _outputController.stream;

  @override
  Future<int> get exitCode => _exitCompleter.future;

  Future<void> finish(int code) async {
    if (!_exitCompleter.isCompleted) {
      _exitCompleter.complete(code);
    }
    if (!_outputController.isClosed) {
      await _outputController.close();
    }
  }

  @override
  void writeBytes(Uint8List data) {}

  @override
  void resize(int cols, int rows, {int pixelWidth = 0, int pixelHeight = 0}) {}

  @override
  bool kill([ProcessSignal signal = .sigterm]) {
    killed = true;
    unawaited(finish(-1));
    return true;
  }
}

final class _ThrowingOutputPtySession implements PtySession {
  final Completer<int> _exitCompleter = Completer<int>();
  bool killed = false;

  @override
  Stream<Uint8List> get output =>
      throw StateError('broken child PTY output stream');

  @override
  Future<int> get exitCode => _exitCompleter.future;

  @override
  void writeBytes(Uint8List data) {}

  @override
  void resize(int cols, int rows, {int pixelWidth = 0, int pixelHeight = 0}) {}

  @override
  bool kill([ProcessSignal signal = .sigterm]) {
    killed = true;
    if (!_exitCompleter.isCompleted) {
      _exitCompleter.complete(-1);
    }
    return true;
  }
}

final class _FakeRelayEndpoint {
  final StreamChannelController<Uint8List> controller =
      StreamChannelController<Uint8List>();
  final List<CastMessage> received = <CastMessage>[];
  final Completer<RegisterSessionFrame> registered =
      Completer<RegisterSessionFrame>();

  _FakeRelayEndpoint() {
    controller.foreign.stream.listen((raw) {
      final msg = BufferFrameCodec.decode(raw);
      received.add(msg);
      if (msg is AuthFrame) {
        controller.foreign.sink.add(
          BufferFrameCodec.encode(const AuthAcceptedFrame(role: .caster)),
        );
      } else if (msg is RegisterSessionFrame && !registered.isCompleted) {
        registered.complete(msg);
      }
    });
  }

  void sendSpawn(SessionId sessionId) {
    controller.foreign.sink.add(
      BufferFrameCodec.encode(SpawnSessionFrame(sessionId: sessionId)),
    );
  }
}

final class _FakeRelayHub {
  final List<_FakeRelayEndpoint> endpoints = <_FakeRelayEndpoint>[];
  final List<Completer<_FakeRelayEndpoint>> _waiters =
      <Completer<_FakeRelayEndpoint>>[];

  Future<StreamChannel<Uint8List>> openChannel() async {
    final endpoint = _FakeRelayEndpoint();
    endpoints.add(endpoint);
    for (final waiter in _waiters) {
      if (!waiter.isCompleted) {
        waiter.complete(endpoint);
      }
    }
    _waiters.clear();
    return endpoint.controller.local;
  }

  Future<_FakeRelayEndpoint> waitForEndpointAt(int index) async {
    while (endpoints.length <= index) {
      final waiter = Completer<_FakeRelayEndpoint>();
      _waiters.add(waiter);
      await waiter.future.timeout(const Duration(seconds: 3));
    }
    return endpoints[index];
  }
}

void main() {
  group('CasterSupervisor multi-PTY spawning', () {
    test(
      'spawns child shell, stays alive after primary exits, and lets surviving child spawn again',
      () async {
        final hub = _FakeRelayHub();
        final startedConfigs = <CasterConfig>[];
        final startedPtys = <_FakePtySession>[];
        final logs = <String>[];

        final primaryConfig = CasterConfig(
          serverUri: Uri.parse('wss://relay.example.com/term/v1/caster'),
          token: 'caster-secret',
          sessionId: const SessionId('primary-1'),
          title: 'zsh',
          initialCols: 120,
          initialRows: 40,
          maxScrollbackLines: 2500,
          colorScheme: .light,
          iapServiceAccount: 'caster@proj.iam.gserviceaccount.com',
          downloadConPty: true,
          uploadEnabled: false,
          uploadDirPath: '/tmp/uploads',
          maxUploadBytes: 4096,
          keepAliveOnHup: true,
          command: const ['/bin/zsh', '-l'],
        );

        final supervisor = CasterSupervisor(
          primaryConfig: primaryConfig,
          environment: const <String, String>{'SHELL': '/usr/bin/fish'},
          isWindows: false,
          random: Random(7),
          channelOpener: hub.openChannel,
          onLog: logs.add,
          ptyStarter: (cfg) async {
            startedConfigs.add(cfg);
            final pty = _FakePtySession();
            startedPtys.add(pty);
            return pty;
          },
        );

        check(await supervisor.start()).isTrue();
        final primaryEndpoint = await hub.waitForEndpointAt(0);
        final primaryReg = await primaryEndpoint.registered.future.timeout(
          const Duration(seconds: 3),
        );
        check(primaryReg.sessionId).equals(const SessionId('primary-1'));
        check(primaryReg.allowSpawn).isTrue();
        check(supervisor.activeSessionCount).equals(1);

        // Track supervisor.done so we verify it stays pending until the last child exits.
        var doneCompleted = false;
        int? supervisorExit;
        unawaited(
          supervisor.done.then((code) {
            doneCompleted = true;
            supervisorExit = code;
          }),
        );

        // Trigger first spawn from primary session.
        primaryEndpoint.sendSpawn(const SessionId('primary-1'));
        final child1Endpoint = await hub.waitForEndpointAt(1);
        final child1Reg = await child1Endpoint.registered.future.timeout(
          const Duration(seconds: 3),
        );

        check(startedConfigs.length).equals(2);
        final child1Cfg = startedConfigs[1];
        check(
          child1Cfg.sessionId,
        ).not((it) => it.equals(primaryConfig.sessionId));
        check(child1Cfg.title).equals('zsh #2');
        check(child1Cfg.command).deepEquals(['/usr/bin/fish']);
        check(child1Cfg.serverUri).equals(primaryConfig.serverUri);
        check(child1Cfg.token).equals(primaryConfig.token);
        check(child1Cfg.initialCols).equals(120);
        check(child1Cfg.initialRows).equals(40);
        check(child1Cfg.maxScrollbackLines).equals(2500);
        check(child1Cfg.colorScheme).equals(.light);
        check(
          child1Cfg.iapServiceAccount,
        ).equals('caster@proj.iam.gserviceaccount.com');
        check(child1Cfg.downloadConPty).isTrue();
        check(child1Cfg.uploadEnabled).isFalse();
        check(child1Cfg.uploadDirPath).equals('/tmp/uploads');
        check(child1Cfg.maxUploadBytes).equals(4096);
        check(child1Cfg.keepAliveOnHup).isTrue();
        check(child1Cfg.allowSpawn).isTrue();
        check(child1Reg.sessionId).equals(child1Cfg.sessionId);
        check(child1Reg.title).equals('zsh #2');
        check(child1Reg.allowSpawn).isTrue();
        check(supervisor.activeSessionCount).equals(2);

        // Primary PTY exits with code 42 -> supervisor must stay alive for child1!
        await startedPtys[0].finish(42);
        await Future<void>.delayed(const Duration(milliseconds: 20));
        check(doneCompleted).isFalse();
        check(supervisor.activeSessionCount).equals(1);

        // Surviving child1 spawns child2 after primary is already gone!
        child1Endpoint.sendSpawn(child1Cfg.sessionId);
        final child2Endpoint = await hub.waitForEndpointAt(2);
        final child2Reg = await child2Endpoint.registered.future.timeout(
          const Duration(seconds: 3),
        );
        check(startedConfigs.length).equals(3);
        check(child2Reg.title).equals('zsh #3');
        check(child2Reg.allowSpawn).isTrue();
        check(child2Reg.sessionId).not((it) => it.equals(child1Cfg.sessionId));
        check(supervisor.activeSessionCount).equals(2);

        // Child1 exits -> still stays alive for child2.
        await startedPtys[1].finish(0);
        await Future<void>.delayed(const Duration(milliseconds: 20));
        check(doneCompleted).isFalse();
        check(supervisor.activeSessionCount).equals(1);

        // Child2 exits -> supervisor finishes with primary's exit code (42).
        await startedPtys[2].finish(0);
        final exitCode = await supervisor.done.timeout(
          const Duration(seconds: 3),
        );
        check(doneCompleted).isTrue();
        check(exitCode).equals(42);
        check(supervisorExit).equals(42);
        check(supervisor.activeSessionCount).equals(0);
      },
    );

    test(
      'catches failed child PTY launches (exception and null) without tearing down live sessions',
      () async {
        final hub = _FakeRelayHub();
        final logs = <String>[];
        final ptys = <_FakePtySession>[];
        var attempts = 0;

        final supervisor = CasterSupervisor(
          primaryConfig: CasterConfig(
            sessionId: const SessionId('resilient-1'),
            title: 'bash',
            command: const ['bash'],
          ),
          environment: const <String, String>{},
          isWindows: true,
          channelOpener: hub.openChannel,
          onLog: logs.add,
          ptyStarter: (cfg) async {
            attempts++;
            if (attempts == 1) {
              final pty = _FakePtySession();
              ptys.add(pty);
              return pty;
            }
            if (attempts == 2) {
              check(cfg.command).deepEquals(['powershell.exe']);
              throw const ProcessException('powershell.exe', [], 'ENOENT', 2);
            }
            if (attempts == 3) {
              return null;
            }
            final pty = _FakePtySession();
            ptys.add(pty);
            return pty;
          },
        );

        check(await supervisor.start()).isTrue();
        final primaryEp = await hub.waitForEndpointAt(0);
        await primaryEp.registered.future.timeout(const Duration(seconds: 3));

        // 1. Throwing child launch is caught and logged.
        primaryEp.sendSpawn(const SessionId('resilient-1'));
        await Future<void>.delayed(const Duration(milliseconds: 30));
        check(attempts).equals(2);
        check(supervisor.activeSessionCount).equals(1);
        check(logs).any((m) => m.contains('Failed to start spawned PTY'));

        // 2. Null child launch is logged without tearing down primary.
        primaryEp.sendSpawn(const SessionId('resilient-1'));
        await Future<void>.delayed(const Duration(milliseconds: 30));
        check(attempts).equals(3);
        check(supervisor.activeSessionCount).equals(1);
        check(logs).any((m) => m.contains('Failed to spawn child PTY'));

        // 3. Subsequent spawn still succeeds cleanly.
        primaryEp.sendSpawn(const SessionId('resilient-1'));
        final childEp = await hub.waitForEndpointAt(1);
        await childEp.registered.future.timeout(const Duration(seconds: 3));
        check(attempts).equals(4);
        check(supervisor.activeSessionCount).equals(2);

        await ptys[0].finish(0);
        await ptys[1].finish(0);
        check(
          await supervisor.done.timeout(const Duration(seconds: 3)),
        ).equals(0);
      },
    );

    test(
      'cleans up child service and kills PTY if childService.start() throws so supervisor.done never hangs',
      () async {
        final hub = _FakeRelayHub();
        final logs = <String>[];
        late _FakePtySession primaryPty;
        late _ThrowingOutputPtySession failingChildPty;
        var attempts = 0;

        final supervisor = CasterSupervisor(
          primaryConfig: CasterConfig(
            sessionId: const SessionId('start-err-1'),
            title: 'zsh',
            command: const ['/bin/zsh'],
          ),
          environment: const <String, String>{'SHELL': '/bin/zsh'},
          isWindows: false,
          channelOpener: hub.openChannel,
          onLog: logs.add,
          ptyStarter: (_) async {
            attempts++;
            if (attempts == 1) {
              primaryPty = _FakePtySession();
              return primaryPty;
            }
            failingChildPty = _ThrowingOutputPtySession();
            return failingChildPty;
          },
        );

        check(await supervisor.start()).isTrue();
        final primaryEp = await hub.waitForEndpointAt(0);
        await primaryEp.registered.future.timeout(const Duration(seconds: 3));

        // Spawn child whose PTY throws inside childService.start().
        primaryEp.sendSpawn(const SessionId('start-err-1'));
        await Future<void>.delayed(const Duration(milliseconds: 40));

        check(attempts).equals(2);
        check(failingChildPty.killed).isTrue();
        check(supervisor.activeSessionCount).equals(1);
        check(logs).any((m) => m.contains('Failed to spawn child session'));

        // Primary exits -> supervisor.done must resolve cleanly without hanging!
        await primaryPty.finish(0);
        check(
          await supervisor.done.timeout(const Duration(seconds: 3)),
        ).equals(0);
        check(supervisor.activeSessionCount).equals(0);
      },
    );

    test(
      'returns false and completes done with 70 when primary PTY fails to start',
      () async {
        final logs = <String>[];
        final nullSupervisor = CasterSupervisor(
          primaryConfig: CasterConfig(
            sessionId: const SessionId('fail-null'),
            title: 'sh',
            command: const ['sh'],
          ),
          onLog: logs.add,
          ptyStarter: (_) async => null,
        );
        check(await nullSupervisor.start()).isFalse();
        check(await nullSupervisor.done).equals(70);

        final throwingSupervisor = CasterSupervisor(
          primaryConfig: CasterConfig(
            sessionId: const SessionId('fail-throw'),
            title: 'sh',
            command: const ['sh'],
          ),
          onLog: logs.add,
          ptyStarter: (_) async => throw StateError('no pty'),
        );
        check(await throwingSupervisor.start()).isFalse();
        check(await throwingSupervisor.done).equals(70);
        check(logs).any((m) => m.contains('Failed to start primary PTY'));
      },
    );

    test(
      'fans out checkIn() and stop(killPty: true) across primary and all active children',
      () async {
        final hub = _FakeRelayHub();
        final ptys = <_FakePtySession>[];

        final supervisor = CasterSupervisor(
          primaryConfig: CasterConfig(
            sessionId: const SessionId('fanout-1'),
            title: 'zsh',
            command: const ['zsh'],
          ),
          environment: const <String, String>{'SHELL': '/bin/zsh'},
          isWindows: false,
          channelOpener: hub.openChannel,
          ptyStarter: (_) async {
            final pty = _FakePtySession();
            ptys.add(pty);
            return pty;
          },
        );

        check(await supervisor.start()).isTrue();
        final ep0 = await hub.waitForEndpointAt(0);
        await ep0.registered.future.timeout(const Duration(seconds: 3));

        // Spawn two child sessions.
        ep0.sendSpawn(const SessionId('fanout-1'));
        final ep1 = await hub.waitForEndpointAt(1);
        final reg1 = await ep1.registered.future.timeout(
          const Duration(seconds: 3),
        );

        ep0.sendSpawn(const SessionId('fanout-1'));
        final ep2 = await hub.waitForEndpointAt(2);
        final reg2 = await ep2.registered.future.timeout(
          const Duration(seconds: 3),
        );
        check(supervisor.activeSessionCount).equals(3);

        // checkIn() must reconnect all 3 active sessions (opening endpoints 3, 4, 5).
        await supervisor.checkIn();
        final reconnectedRegs = <SessionId>{};
        for (var i = 3; i < 6; i++) {
          final ep = await hub.waitForEndpointAt(i);
          final reg = await ep.registered.future.timeout(
            const Duration(seconds: 3),
          );
          reconnectedRegs.add(reg.sessionId);
        }
        check(reconnectedRegs).deepEquals(<SessionId>{
          const SessionId('fanout-1'),
          reg1.sessionId,
          reg2.sessionId,
        });

        // stop(killPty: true) must kill all 3 PTYs and resolve done to -1.
        await supervisor.stop(killPty: true);
        final exitCode = await supervisor.done.timeout(
          const Duration(seconds: 3),
        );
        check(exitCode).equals(-1);
        check(supervisor.activeSessionCount).equals(0);
        for (final pty in ptys) {
          check(pty.killed).isTrue();
        }
      },
    );

    test(
      'kills in-flight spawned PTY cleanly if stop() is called before ptyStarter resolves',
      () async {
        final hub = _FakeRelayHub();
        final ptys = <_FakePtySession>[];
        final spawnStarted = Completer<void>();
        final releaseSpawn = Completer<_FakePtySession>();

        final supervisor = CasterSupervisor(
          primaryConfig: CasterConfig(
            sessionId: const SessionId('race-1'),
            title: 'zsh',
            command: const ['zsh'],
          ),
          environment: const <String, String>{'SHELL': '/bin/zsh'},
          isWindows: false,
          channelOpener: hub.openChannel,
          ptyStarter: (cfg) async {
            if (cfg.sessionId == const SessionId('race-1')) {
              final pty = _FakePtySession();
              ptys.add(pty);
              return pty;
            }
            spawnStarted.complete();
            return releaseSpawn.future;
          },
        );

        check(await supervisor.start()).isTrue();
        final ep0 = await hub.waitForEndpointAt(0);
        await ep0.registered.future.timeout(const Duration(seconds: 3));

        ep0.sendSpawn(const SessionId('race-1'));
        await spawnStarted.future.timeout(const Duration(seconds: 3));

        await supervisor.stop(killPty: true);
        check(await supervisor.done).equals(-1);
        check(ptys.single.killed).isTrue();

        final latePty = _FakePtySession();
        releaseSpawn.complete(latePty);
        await Future<void>.delayed(const Duration(milliseconds: 20));
        check(latePty.killed).isTrue();
        check(supervisor.activeSessionCount).equals(0);
      },
    );

    test(
      'ignores SpawnSessionFrame when primary allowSpawn is false',
      () async {
        final hub = _FakeRelayHub();
        final ptys = <_FakePtySession>[];
        var starterCalls = 0;

        final supervisor = CasterSupervisor(
          primaryConfig: CasterConfig(
            sessionId: const SessionId('htop-sup'),
            title: 'htop',
            command: const ['htop'],
          ),
          channelOpener: hub.openChannel,
          ptyStarter: (_) async {
            starterCalls++;
            final pty = _FakePtySession();
            ptys.add(pty);
            return pty;
          },
        );

        check(await supervisor.start()).isTrue();
        final ep0 = await hub.waitForEndpointAt(0);
        final reg0 = await ep0.registered.future.timeout(
          const Duration(seconds: 3),
        );
        check(reg0.allowSpawn).isFalse();

        ep0.sendSpawn(const SessionId('htop-sup'));
        await Future<void>.delayed(const Duration(milliseconds: 30));
        check(starterCalls).equals(1);
        check(supervisor.activeSessionCount).equals(1);

        await ptys.single.finish(0);
        check(await supervisor.done).equals(0);
      },
    );

    test(
      'buildChildTitle sanitizes control characters and clamps ASCII and multi-byte UTF-8 cleanly',
      () {
        check(CasterSupervisor.buildChildTitle('zsh', 2)).equals('zsh #2');
        check(
          CasterSupervisor.buildChildTitle('\x1b]0;shell\x07\u202E', 3),
        ).equals(']0;shell #3');
        check(CasterSupervisor.buildChildTitle('   ', 2)).equals('shell #2');

        // 512-byte ASCII base title clamped to preserve " #2" within 512 bytes.
        final clampedAscii = CasterSupervisor.buildChildTitle('a' * 512, 2);
        check(utf8.encode(clampedAscii).length).equals(maxSessionTitleBytes);
        check(clampedAscii.endsWith(' #2')).isTrue();
        BufferFrameCodec.validateTitle(clampedAscii);

        // 512-byte 4-byte emoji base title clamped on a valid UTF-8 codepoint boundary.
        final clampedEmoji = CasterSupervisor.buildChildTitle('🚀' * 128, 2);
        check(
          utf8.encode(clampedEmoji).length,
        ).isLessOrEqual(maxSessionTitleBytes);
        check(clampedEmoji.endsWith(' #2')).isTrue();
        check(clampedEmoji.contains('\uFFFD')).isFalse();
        BufferFrameCodec.validateTitle(clampedEmoji);
      },
    );

    test(
      'runCasterCli routes through CasterSupervisor with spawn, checkIn, and shutdown seams',
      () async {
        final hub = _FakeRelayHub();
        final ptys = <_FakePtySession>[];
        final checkInCtrl = StreamController<void>.broadcast();
        final shutdownCtrl = StreamController<void>.broadcast();
        addTearDown(checkInCtrl.close);
        addTearDown(shutdownCtrl.close);

        final errBuf = StringBuffer();
        final cliFuture = runCasterCli(
          ['--session-id', 'cli-sup', '--', '/bin/zsh'],
          err: errBuf,
          environment: const <String, String>{'SHELL': '/bin/zsh'},
          channelOpener: hub.openChannel,
          checkInSignal: checkInCtrl.stream,
          shutdownSignal: shutdownCtrl.stream,
          ptyStarter: (_) async {
            final pty = _FakePtySession();
            ptys.add(pty);
            return pty;
          },
        );

        final ep0 = await hub.waitForEndpointAt(0);
        final reg0 = await ep0.registered.future.timeout(
          const Duration(seconds: 3),
        );
        check(reg0.allowSpawn).isTrue();

        // Spawn a child via CLI supervisor.
        ep0.sendSpawn(const SessionId('cli-sup'));
        final ep1 = await hub.waitForEndpointAt(1);
        final reg1 = await ep1.registered.future.timeout(
          const Duration(seconds: 3),
        );
        check(reg1.title).equals('zsh #2');

        // Primary exits -> CLI stays alive while spawned child is running.
        await ptys[0].finish(0);
        await Future<void>.delayed(const Duration(milliseconds: 20));
        check(ptys[1].killed).isFalse();

        // checkInSignal reconnects surviving child.
        checkInCtrl.add(null);
        final ep2 = await hub.waitForEndpointAt(2);
        final reg2 = await ep2.registered.future.timeout(
          const Duration(seconds: 3),
        );
        check(reg2.sessionId).equals(reg1.sessionId);

        // shutdownSignal terminates surviving child and resolves runCasterCli to -1.
        shutdownCtrl.add(null);
        final exitCode = await cliFuture.timeout(const Duration(seconds: 3));
        check(exitCode).equals(-1);
        check(ptys[1].killed).isTrue();

        // Primary PTY launch failure returns 70.
        final failCode = await runCasterCli(
          ['--', '/bin/zsh'],
          err: StringBuffer(),
          environment: const <String, String>{},
          shutdownSignal: const Stream<void>.empty(),
          checkInSignal: const Stream<void>.empty(),
          ptyStarter: (_) async => null,
        );
        check(failCode).equals(70);
      },
    );
  });
}
