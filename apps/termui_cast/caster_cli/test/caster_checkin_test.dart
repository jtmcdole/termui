import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:checks/checks.dart';
import 'package:fake_async/fake_async.dart';
import 'package:stream_channel/stream_channel.dart';
import 'package:termui_cast_protocol/termui_cast_protocol.dart';
import 'package:termui_cast_server/termui_cast_server.dart';
import 'package:termui_caster_cli/termui_caster_cli.dart';
import 'package:test/test.dart';

final class _FakePtySession implements PtySession {
  final StreamController<Uint8List> _outputController =
      StreamController<Uint8List>.broadcast();
  final Completer<int> _exitCompleter = Completer<int>();

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
  void writeBytes(Uint8List data) {}

  @override
  void resize(int cols, int rows, {int pixelWidth = 0, int pixelHeight = 0}) {}

  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    unawaited(finish(-1));
    return true;
  }
}

final class _HangingCloseSink implements StreamSink<Uint8List> {
  final StreamSink<Uint8List> _inner;
  final Completer<void> _closeCompleter = Completer<void>();
  int closeCalls = 0;

  _HangingCloseSink(this._inner);

  @override
  void add(Uint8List event) => _inner.add(event);

  @override
  void addError(Object error, [StackTrace? stackTrace]) =>
      _inner.addError(error, stackTrace);

  @override
  Future<void> addStream(Stream<Uint8List> stream) => _inner.addStream(stream);

  @override
  Future<void> close() {
    closeCalls++;
    return _closeCompleter.future;
  }

  @override
  Future<void> get done => _closeCompleter.future;
}

final class _TrackedSinkChannel extends StreamChannelMixin<Uint8List> {
  final StreamChannel<Uint8List> _inner;
  final StreamSink<Uint8List> _customSink;

  _TrackedSinkChannel(this._inner, this._customSink);

  @override
  Stream<Uint8List> get stream => _inner.stream;

  @override
  StreamSink<Uint8List> get sink => _customSink;
}

final class _CountingCloseSink implements StreamSink<Uint8List> {
  final StreamSink<Uint8List> _inner;
  int closeCalls = 0;

  _CountingCloseSink(this._inner);

  @override
  void add(Uint8List event) => _inner.add(event);

  @override
  void addError(Object error, [StackTrace? stackTrace]) =>
      _inner.addError(error, stackTrace);

  @override
  Future<void> addStream(Stream<Uint8List> stream) => _inner.addStream(stream);

  @override
  Future<void> close() {
    closeCalls++;
    return _inner.close();
  }

  @override
  Future<void> get done => _inner.done;
}

CasterConfig _testConfig({
  String sessionId = 'checkin-test',
  String title = 'zsh',
  int cols = 20,
  int rows = 4,
}) => CasterConfig(
  sessionId: SessionId(sessionId),
  title: title,
  token: 'c-tok',
  initialCols: cols,
  initialRows: rows,
  maxScrollbackLines: 100,
  command: const ['zsh'],
);

({
  StreamChannel<Uint8List> clientChannel,
  StreamChannelController<Uint8List> relayCtrl,
  List<CastMessage> receivedFrames,
})
_openAutoAuthChannel({bool hangSinkClose = false}) {
  final ctrl = StreamChannelController<Uint8List>();
  final frames = <CastMessage>[];
  ctrl.foreign.stream.listen((raw) {
    final msg = BufferFrameCodec.decode(raw);
    frames.add(msg);
    if (msg is AuthFrame) {
      ctrl.foreign.sink.add(
        BufferFrameCodec.encode(const AuthAcceptedFrame(role: .caster)),
      );
    }
  });
  final clientChannel = hangSinkClose
      ? _TrackedSinkChannel(ctrl.local, _HangingCloseSink(ctrl.local.sink))
      : ctrl.local;
  return (
    clientChannel: clientChannel,
    relayCtrl: ctrl,
    receivedFrames: frames,
  );
}

void main() {
  group('CasterConnectionMachine checkIn transitions', () {
    test(
      'handles .checkIn in active states and ignores .idle and .terminated',
      () async {
        final machine = CasterConnectionMachine(random: Random(0));
        addTearDown(machine.dispose);

        // Ignored in .idle.
        check(machine.state).equals(CasterLifecycleState.idle);
        check(await machine.dispatch(.checkIn)).isFalse();
        check(machine.state).equals(CasterLifecycleState.idle);

        // .connecting -> .connecting resets reconnectAttempt.
        check(await machine.dispatch(.start)).isTrue();
        check(machine.state).equals(CasterLifecycleState.connecting);
        check(await machine.dispatch(.connectionFailed)).isTrue();
        check(machine.reconnectAttempt).equals(1);
        check(await machine.dispatch(.retryTimerFired)).isTrue();
        check(machine.state).equals(CasterLifecycleState.connecting);
        check(machine.reconnectAttempt).equals(1);
        check(await machine.dispatch(.checkIn)).isTrue();
        check(machine.state).equals(CasterLifecycleState.connecting);
        check(machine.reconnectAttempt).equals(0);

        // .streaming -> .connecting resets reconnectAttempt.
        check(await machine.dispatch(.connected)).isTrue();
        check(machine.state).equals(CasterLifecycleState.streaming);
        check(await machine.dispatch(.checkIn)).isTrue();
        check(machine.state).equals(CasterLifecycleState.connecting);
        check(machine.reconnectAttempt).equals(0);

        // .reconnectBackoff -> .connecting resets reconnectAttempt.
        check(await machine.dispatch(.connectionFailed)).isTrue();
        check(await machine.dispatch(.retryTimerFired)).isTrue();
        check(await machine.dispatch(.connectionFailed)).isTrue();
        check(machine.state).equals(CasterLifecycleState.reconnectBackoff);
        check(machine.reconnectAttempt).equals(2);
        check(await machine.dispatch(.checkIn)).isTrue();
        check(machine.state).equals(CasterLifecycleState.connecting);
        check(machine.reconnectAttempt).equals(0);

        // Ignored in .terminated.
        check(await machine.dispatch(.stop)).isTrue();
        check(machine.state).equals(CasterLifecycleState.terminated);
        check(await machine.dispatch(.checkIn)).isFalse();
        check(machine.state).equals(CasterLifecycleState.terminated);
      },
    );
  });

  group('CasterService.checkIn FakeAsync behavior', () {
    test(
      'is a safe no-op before start and after stop, and supersedes same-turn start without duplicate connections',
      () {
        fakeAsync((async) {
          final pty = _FakePtySession();
          var openCalls = 0;
          final service = CasterService(
            config: _testConfig(),
            pty: pty,
            random: Random(0),
            channelOpener: () async {
              openCalls++;
              return _openAutoAuthChannel().clientChannel;
            },
          );

          // 1. Before start().
          unawaited(service.checkIn());
          async.flushMicrotasks();
          check(openCalls).equals(0);
          check(service.stateMachine.state).equals(CasterLifecycleState.idle);

          // 2. Same-turn checkIn() supersedes start()'s initial .connecting
          // epoch without opening a duplicate connection.
          unawaited(service.start());
          unawaited(service.checkIn());
          async.flushMicrotasks();
          check(openCalls).equals(1);
          check(
            service.stateMachine.state,
          ).equals(CasterLifecycleState.streaming);

          // 3. After stop().
          unawaited(service.stop());
          async.flushMicrotasks();
          check(
            service.stateMachine.state,
          ).equals(CasterLifecycleState.terminated);
          unawaited(service.checkIn());
          async.flushMicrotasks();
          check(openCalls).equals(1);
          check(
            service.stateMachine.state,
          ).equals(CasterLifecycleState.terminated);
        });
      },
    );

    test(
      'during reconnectBackoff cancels backoff timer, resets attempts, and re-registers with preserved resumeToken and title',
      () {
        fakeAsync((async) {
          final pty = _FakePtySession();
          final logs = <String>[];
          var openCalls = 0;
          var failAttempts = false;
          final channels =
              <
                ({
                  StreamChannelController<Uint8List> relayCtrl,
                  List<CastMessage> frames,
                })
              >[];

          final service = CasterService(
            config: _testConfig(sessionId: 'backoff-checkin', title: 'initial'),
            pty: pty,
            random: Random(1),
            baseReconnectDelay: const Duration(seconds: 5),
            onLog: logs.add,
            channelOpener: () async {
              openCalls++;
              if (failAttempts) {
                throw const SocketException('offline');
              }
              final opened = _openAutoAuthChannel();
              channels.add((
                relayCtrl: opened.relayCtrl,
                frames: opened.receivedFrames,
              ));
              return opened.clientChannel;
            },
          );

          unawaited(service.start());
          async.flushMicrotasks();
          check(openCalls).equals(1);
          check(
            service.stateMachine.state,
          ).equals(CasterLifecycleState.streaming);

          // Rename session while connected.
          channels[0].relayCtrl.foreign.sink.add(
            BufferFrameCodec.encode(
              const RenameSessionFrame(
                sessionId: SessionId('backoff-checkin'),
                title: 'custom-renamed',
              ),
            ),
          );
          async.flushMicrotasks();
          check(service.currentTitle).equals('custom-renamed');

          // Force disconnect and fail two reconnect attempts so attempt count >= 2.
          failAttempts = true;
          unawaited(channels[0].relayCtrl.foreign.sink.close());
          async.flushMicrotasks();
          check(
            service.stateMachine.state,
          ).equals(CasterLifecycleState.reconnectBackoff);
          check(service.stateMachine.reconnectAttempt).equals(1);

          async.elapse(const Duration(seconds: 10));
          async.flushMicrotasks();
          check(openCalls).equals(2);
          check(service.stateMachine.reconnectAttempt).equals(2);
          check(
            service.stateMachine.state,
          ).equals(CasterLifecycleState.reconnectBackoff);

          // Server recovers; checkIn() must bypass the pending backoff timer immediately.
          failAttempts = false;
          unawaited(service.checkIn());
          async.flushMicrotasks();

          check(openCalls).equals(3);
          check(service.stateMachine.reconnectAttempt).equals(0);
          check(
            service.stateMachine.state,
          ).equals(CasterLifecycleState.streaming);
          check(logs).any(
            (l) => l.contains(
              'Check-in requested; reconnecting session "backoff-checkin"',
            ),
          );

          final regs = [
            ...channels.last.frames.whereType<RegisterSessionFrame>(),
          ];
          check(regs.length).equals(1);
          check(regs.single.title).equals('custom-renamed');
          check(regs.single.resumeToken).deepEquals(service.resumeToken);

          // Old canceled backoff timer must not trigger another connection later.
          async.elapse(const Duration(seconds: 30));
          async.flushMicrotasks();
          check(openCalls).equals(3);

          unawaited(service.stop());
          async.flushMicrotasks();
        });
      },
    );

    test(
      'checkIn while retryTimerFired is settling supersedes timer attempt without duplicate connections',
      () {
        fakeAsync((async) {
          final pty = _FakePtySession();
          final logs = <String>[];
          var openCalls = 0;
          var interceptMicrotask = false;
          late StreamChannelController<Uint8List> currentRelay;
          Completer<StreamChannel<Uint8List>>? secondOpener;
          late final CasterService service;

          runZoned(
            () {
              service = CasterService(
                config: _testConfig(sessionId: 'settling-timer'),
                pty: pty,
                random: Random(3),
                baseReconnectDelay: const Duration(milliseconds: 200),
                onLog: logs.add,
                channelOpener: () {
                  openCalls++;
                  if (openCalls == 2) {
                    secondOpener = Completer<StreamChannel<Uint8List>>();
                    return secondOpener!.future;
                  }
                  final opened = _openAutoAuthChannel();
                  currentRelay = opened.relayCtrl;
                  return Future<StreamChannel<Uint8List>>.value(
                    opened.clientChannel,
                  );
                },
              );

              unawaited(service.start());
              async.flushMicrotasks();
              check(openCalls).equals(1);

              unawaited(currentRelay.foreign.sink.close());
              async.flushMicrotasks();
              check(
                service.stateMachine.state,
              ).equals(CasterLifecycleState.reconnectBackoff);
              check(service.stateMachine.reconnectAttempt).equals(1);

              // Intercept the microtask posted when retryTimerFired settles and
              // fire checkIn() right in that window.
              interceptMicrotask = true;
              async.elapse(const Duration(seconds: 1));
              async.flushMicrotasks();

              // Must have opened only ONE new attempt (by checkIn) and reset
              // attempts to 0 even before AuthAcceptedFrame arrives.
              check(openCalls).equals(2);
              check(service.stateMachine.reconnectAttempt).equals(0);
              check(
                service.stateMachine.state,
              ).equals(CasterLifecycleState.connecting);
              check(
                logs,
              ).any((l) => l.contains('Check-in requested; reconnecting'));

              final secondOpened = _openAutoAuthChannel();
              secondOpener!.complete(secondOpened.clientChannel);
              async.flushMicrotasks();
              check(
                service.stateMachine.state,
              ).equals(CasterLifecycleState.streaming);

              unawaited(service.stop());
              async.flushMicrotasks();
            },
            zoneSpecification: ZoneSpecification(
              scheduleMicrotask: (self, parent, zone, f) {
                if (interceptMicrotask) {
                  interceptMicrotask = false;
                  parent.scheduleMicrotask(
                    zone,
                    () => unawaited(service.checkIn()),
                  );
                }
                parent.scheduleMicrotask(zone, f);
              },
            ),
          );
        });
      },
    );

    test(
      'during streaming detaches hanging sink close, preserves scrollback, and forces one BufferSnapshotFrame with >= 2 subscribers',
      () {
        fakeAsync((async) {
          final pty = _FakePtySession();
          const sessionId = SessionId('stream-checkin');
          final registry = SessionRegistry();
          final handler = WsRelayHandler(
            registry: registry,
            authenticator: TokenAuthenticator(),
          );
          final channelFrames = <List<CastMessage>>[];
          var openCalls = 0;

          final service = CasterService(
            config: _testConfig(sessionId: sessionId.value, cols: 20, rows: 3),
            pty: pty,
            random: Random(0),
            frameCoalesceInterval: const Duration(milliseconds: 16),
            channelOpener: () async {
              openCalls++;
              final casterEnd = StreamChannelController<Uint8List>();
              final serverEnd = StreamChannelController<Uint8List>();
              final sentFrames = <CastMessage>[];
              channelFrames.add(sentFrames);

              casterEnd.foreign.stream.listen((raw) {
                sentFrames.add(BufferFrameCodec.decode(raw));
                serverEnd.local.sink.add(raw);
              });
              serverEnd.local.stream.listen(casterEnd.foreign.sink.add);
              handler.attachCasterChannel(serverEnd.foreign);
              if (openCalls == 1) {
                return _TrackedSinkChannel(
                  casterEnd.local,
                  _HangingCloseSink(casterEnd.local.sink),
                );
              }
              return casterEnd.local;
            },
          );

          unawaited(service.start());
          async.flushMicrotasks();
          check(openCalls).equals(1);

          // Emit lines into scrollback and connect 2 viewers.
          pty.emitText('line0\r\nline1\r\nline2\r\nline3\r\n');
          async.flushMicrotasks();
          check(service.terminal.scrollbackWindow.totalLines).equals(2);

          final client1 = StreamChannelController<Uint8List>();
          final client2 = StreamChannelController<Uint8List>();
          for (final client in [client1, client2]) {
            handler.attachClientChannel(client.foreign);
            client.local.sink.add(
              BufferFrameCodec.encode(
                const AuthFrame(role: .client, token: ''),
              ),
            );
            client.local.sink.add(
              BufferFrameCodec.encode(
                const SubscribeSessionFrame(
                  sessionId: sessionId,
                  cols: 20,
                  rows: 3,
                ),
              ),
            );
          }
          async.flushMicrotasks();
          check(service.subscriberCount).equals(2);

          // Make terminal dirty before the 16ms coalesce timer fires, then trigger checkIn().
          pty.emitText('pre-hup');
          async.flushMicrotasks();
          check(service.terminal.isDirty).isTrue();

          unawaited(service.checkIn());
          // Zero-delay reconnect even though channel 1's sink.close() never completes!
          async.flushMicrotasks();

          check(openCalls).equals(2);
          check(
            service.stateMachine.state,
          ).equals(CasterLifecycleState.streaming);
          check(service.terminal.scrollbackWindow.totalLines).equals(2);

          // Channel 2 must emit RegisterSessionFrame and BufferSnapshotFrames
          // (no wasted BufferDeltaFrame first) with subscriberCount >= 2.
          final regs = [...channelFrames[1].whereType<RegisterSessionFrame>()];
          check(regs.length).equals(1);
          check(regs.single.resumeToken).deepEquals(service.resumeToken);
          final postCheckInFrames = [
            for (final msg in channelFrames[1])
              if (msg is BufferSnapshotFrame || msg is BufferDeltaFrame) msg,
          ];
          check(postCheckInFrames).isNotEmpty();
          check(
            postCheckInFrames.every((msg) => msg is BufferSnapshotFrame),
          ).isTrue();
          final snap =
              (postCheckInFrames.first as BufferSnapshotFrame).snapshot;
          check(snap.characters.join()).contains('pre-hup');

          unawaited(service.stop());
          unawaited(registry.close());
          async.flushMicrotasks();
        });
      },
    );

    test(
      'during hanging channelOpener and rapid bursts discards late throw or late open without clobbering',
      () {
        fakeAsync((async) {
          final pty = _FakePtySession();
          final logs = <String>[];
          final pendingOpeners = <Completer<StreamChannel<Uint8List>>>[];

          final service = CasterService(
            config: _testConfig(sessionId: 'hang-opener'),
            pty: pty,
            random: Random(0),
            onLog: logs.add,
            channelOpener: () {
              final c = Completer<StreamChannel<Uint8List>>();
              pendingOpeners.add(c);
              return c.future;
            },
          );

          // Attempt 1 hangs in channelOpener.
          unawaited(service.start());
          async.flushMicrotasks();
          check(pendingOpeners.length).equals(1);
          check(
            service.stateMachine.state,
          ).equals(CasterLifecycleState.connecting);

          // Rapid burst of 3 checkIn() calls must start only ONE new opener (attempt 2).
          unawaited(service.checkIn());
          unawaited(service.checkIn());
          unawaited(service.checkIn());
          async.flushMicrotasks();
          check(pendingOpeners.length).equals(2);

          // Attempt 2 opens and streams.
          final activeOpened = _openAutoAuthChannel();
          pendingOpeners[1].complete(activeOpened.clientChannel);
          async.flushMicrotasks();
          check(
            service.stateMachine.state,
          ).equals(CasterLifecycleState.streaming);

          // Case A: Stale attempt 1 fails late -> ignored cleanly.
          pendingOpeners[0].completeError(
            const SocketException('late failure'),
          );
          async.flushMicrotasks();
          check(
            service.stateMachine.state,
          ).equals(CasterLifecycleState.streaming);
          check(pendingOpeners.length).equals(2);
          check(
            logs.where((l) => l.contains('Connection attempt failed')),
          ).isEmpty();

          // Now test Case B: attempt 3 hangs, attempt 4 succeeds, then attempt 3 opens late.
          unawaited(service.checkIn());
          async.flushMicrotasks();
          check(pendingOpeners.length).equals(3);

          unawaited(service.checkIn());
          async.flushMicrotasks();
          check(pendingOpeners.length).equals(4);

          final winningOpened = _openAutoAuthChannel();
          pendingOpeners[3].complete(winningOpened.clientChannel);
          async.flushMicrotasks();
          check(
            service.stateMachine.state,
          ).equals(CasterLifecycleState.streaming);

          final staleCtrl = StreamChannelController<Uint8List>();
          final countingSink = _CountingCloseSink(staleCtrl.local.sink);
          final staleChannel = _TrackedSinkChannel(
            staleCtrl.local,
            countingSink,
          );
          pendingOpeners[2].complete(staleChannel);
          async.flushMicrotasks();

          check(countingSink.closeCalls).equals(1);
          check(
            service.stateMachine.state,
          ).equals(CasterLifecycleState.streaming);
          check(pendingOpeners.length).equals(4);

          // Auth timeout triggers reconnect when relay never answers AuthAcceptedFrame.
          unawaited(service.checkIn());
          async.flushMicrotasks();
          check(pendingOpeners.length).equals(5);
          final silentRelay = StreamChannelController<Uint8List>();
          silentRelay.foreign.stream.listen((_) {});
          pendingOpeners[4].complete(silentRelay.local);
          async.flushMicrotasks();
          async.elapse(service.authTimeout);
          async.flushMicrotasks();
          check(logs).any((l) => l.contains('Relay authentication timed out'));
          check(
            service.stateMachine.state,
          ).equals(CasterLifecycleState.reconnectBackoff);

          unawaited(service.stop());
          async.flushMicrotasks();
        });
      },
    );

    test(
      'performs make-before-break takeover on healthy channel without dropping viewers and ignores duplicate AuthAcceptedFrame',
      _verifyHealthyMakeBeforeBreakTakeover,
    );
    test(
      '0-viewer session resets backoff via SubscriberCountFrame(0), upload preserves queued overflow replies, and reconnect sends offline pending shellTitle',
      _verifyZeroViewerBackoffOverflowRepliesAndPendingTitle,
    );
  });
}

void _verifyHealthyMakeBeforeBreakTakeover() {
  fakeAsync((async) {
    final pty = _FakePtySession();
    const sessionId = SessionId('healthy-takeover');
    final registry = SessionRegistry();
    final handler = WsRelayHandler(
      registry: registry,
      authenticator: TokenAuthenticator(),
    );
    final countingSinks = <_CountingCloseSink>[];
    final sentFramesPerAttempt = <List<CastMessage>>[];
    var failNextConnect = false;
    var openCalls = 0;

    final service = CasterService(
      config: _testConfig(sessionId: sessionId.value, cols: 20, rows: 3),
      pty: pty,
      random: Random(0),
      channelOpener: () async {
        openCalls++;
        if (failNextConnect) {
          throw const SocketException('connect failed');
        }
        final casterEnd = StreamChannelController<Uint8List>();
        final serverEnd = StreamChannelController<Uint8List>();
        final sent = <CastMessage>[];
        sentFramesPerAttempt.add(sent);
        final injectDuplicateAuth = openCalls == 2;
        casterEnd.foreign.stream.listen((raw) {
          sent.add(BufferFrameCodec.decode(raw));
          serverEnd.local.sink.add(raw);
        }, onDone: () => unawaited(serverEnd.local.sink.close()));
        serverEnd.local.stream.listen((raw) {
          casterEnd.foreign.sink.add(raw);
          if (injectDuplicateAuth &&
              BufferFrameCodec.decode(raw) is AuthAcceptedFrame) {
            casterEnd.foreign.sink.add(raw);
          }
        }, onDone: () => unawaited(casterEnd.foreign.sink.close()));
        handler.attachCasterChannel(serverEnd.foreign);
        final counting = _CountingCloseSink(casterEnd.local.sink);
        countingSinks.add(counting);
        return _TrackedSinkChannel(casterEnd.local, counting);
      },
    );

    unawaited(service.start());
    async.flushMicrotasks();
    check(openCalls).equals(1);

    final viewer = StreamChannelController<Uint8List>();
    final viewerFrames = <CastMessage>[];
    viewer.local.stream.listen((raw) {
      viewerFrames.add(BufferFrameCodec.decode(raw));
    });
    handler.attachClientChannel(viewer.foreign);
    viewer.local.sink.add(
      BufferFrameCodec.encode(const AuthFrame(role: .client, token: '')),
    );
    viewer.local.sink.add(
      BufferFrameCodec.encode(
        const SubscribeSessionFrame(sessionId: sessionId, cols: 20, rows: 3),
      ),
    );
    async.flushMicrotasks();
    check(service.subscriberCount).equals(1);

    pty.emitText('takeover-ok');
    async.flushMicrotasks();

    // Healthy-channel checkIn() must take over in place without sending
    // SessionClosedFrame(.disconnected) to the subscribed viewer.
    unawaited(service.checkIn());
    async.flushMicrotasks();

    check(openCalls).equals(2);
    check(service.stateMachine.state).equals(CasterLifecycleState.streaming);
    check(service.subscriberCount).equals(1);
    check(viewerFrames.whereType<SessionClosedFrame>()).isEmpty();
    check(countingSinks[0].closeCalls).equals(1);

    // Duplicate AuthAcceptedFrame on attempt 2 must not emit a 2nd RegisterSessionFrame.
    check(
      sentFramesPerAttempt[1].whereType<RegisterSessionFrame>().length,
    ).equals(1);
    final viewerSnaps = [...viewerFrames.whereType<BufferSnapshotFrame>()];
    check(viewerSnaps.last.snapshot.characters.join()).contains('takeover-ok');

    // Failed checkIn() connect attempt must immediately close the retired channel.
    failNextConnect = true;
    unawaited(service.checkIn());
    async.flushMicrotasks();
    check(countingSinks[1].closeCalls).equals(1);
    check(
      service.stateMachine.state,
    ).equals(CasterLifecycleState.reconnectBackoff);

    unawaited(service.stop());
    unawaited(registry.close());
    async.flushMicrotasks();
  });
}

void _verifyZeroViewerBackoffOverflowRepliesAndPendingTitle() {
  fakeAsync((async) {
    final pty = _FakePtySession();
    const sessionId = SessionId('docket-d01-d07');
    final registry = SessionRegistry();
    final handler = WsRelayHandler(
      registry: registry,
      authenticator: TokenAuthenticator(),
    );
    final sentPerAttempt = <List<CastMessage>>[];
    var failFirst = true;
    var openCalls = 0;

    final service = CasterService(
      config: _testConfig(sessionId: sessionId.value, cols: 20, rows: 3),
      pty: pty,
      random: Random(0),
      baseReconnectDelay: const Duration(seconds: 2),
      uploadIdleTimeout: Duration.zero,
      channelOpener: () async {
        openCalls++;
        if (failFirst) {
          failFirst = false;
          throw const SocketException('transient failure');
        }
        final casterEnd = StreamChannelController<Uint8List>();
        final serverEnd = StreamChannelController<Uint8List>();
        final sent = <CastMessage>[];
        sentPerAttempt.add(sent);
        casterEnd.foreign.stream.listen((raw) {
          sent.add(BufferFrameCodec.decode(raw));
          serverEnd.local.sink.add(raw);
        }, onDone: () => unawaited(serverEnd.local.sink.close()));
        serverEnd.local.stream.listen(
          casterEnd.foreign.sink.add,
          onDone: () => unawaited(casterEnd.foreign.sink.close()),
        );
        handler.attachCasterChannel(serverEnd.foreign);
        return casterEnd.local;
      },
    );

    unawaited(service.start());
    async.flushMicrotasks();
    // Attempt 1 failed -> waiting in reconnectBackoff with nextBackoff >= 2s.
    check(openCalls).equals(1);
    check(
      service.stateMachine.state,
    ).equals(CasterLifecycleState.reconnectBackoff);

    // Offline OSC 2 title update while disconnected.
    pty.emitText('\x1b]2;offline-shell-title\x07');
    async.flushMicrotasks();

    // Advance backoff so attempt 2 connects with 0 viewers -> relay emits SubscriberCountFrame(0),
    // caster transitions through .registered -> streaming (resetting backoff) and sends ShellTitleFrame.
    async.elapse(const Duration(seconds: 5));
    async.flushMicrotasks();
    check(openCalls).equals(2);
    check(service.stateMachine.state).equals(CasterLifecycleState.streaming);
    check(
      sentPerAttempt[0].whereType<ShellTitleFrame>().any(
        (f) => f.title == 'offline-shell-title',
      ),
    ).isTrue();

    // Queue overflow terminal query replies (total > 8192 bytes per drain tick so remainder sits in _overflowReplies)
    // and emit an upload frame; upload idle sync must NOT clear queued _overflowReplies (D-01).
    final ptyWrites = <String>[];
    final recordingPty = _RecordingPtySession(ptyWrites);
    final svc2 = CasterService(
      config: _testConfig(sessionId: 'd01-upload', cols: 20, rows: 3),
      pty: recordingPty,
      random: Random(0),
      channelOpener: () async {
        final casterEnd = StreamChannelController<Uint8List>();
        final serverEnd = StreamChannelController<Uint8List>();
        casterEnd.foreign.stream.listen(
          serverEnd.local.sink.add,
          onDone: () => unawaited(serverEnd.local.sink.close()),
        );
        serverEnd.local.stream.listen(
          casterEnd.foreign.sink.add,
          onDone: () => unawaited(casterEnd.foreign.sink.close()),
        );
        handler.attachCasterChannel(serverEnd.foreign);
        return casterEnd.local;
      },
    );
    unawaited(svc2.start());
    async.flushMicrotasks();

    // Attach a viewer and trigger a DA1/DSR burst exceeding 8 KiB + file upload start mid-drain.
    final viewer = StreamChannelController<Uint8List>();
    final viewerInbox = <CastMessage>[];
    viewer.local.stream.listen((raw) {
      viewerInbox.add(BufferFrameCodec.decode(raw));
    });
    handler.attachClientChannel(viewer.foreign);
    viewer.local.sink.add(
      BufferFrameCodec.encode(const AuthFrame(role: .client, token: '')),
    );
    viewer.local.sink.add(
      BufferFrameCodec.encode(
        const SubscribeSessionFrame(sessionId: SessionId('d01-upload')),
      ),
    );
    async.flushMicrotasks();

    // Emit 300 DA1 queries (~7.5 KiB-10 KiB of replies) so _overflowReplies buffers tail chunks.
    recordingPty.emitText('\x1b[c' * 1200);
    // Start & abort an upload while overflow replies are pending drain.
    viewer.local.sink.add(
      BufferFrameCodec.encode(
        const FileUploadStartFrame(
          sessionId: SessionId('d01-upload'),
          transferId: 1,
          fileName: 'note.txt',
          totalBytes: 4,
        ),
      ),
    );
    viewer.local.sink.add(
      BufferFrameCodec.encode(
        FileUploadEndFrame(
          sessionId: const SessionId('d01-upload'),
          transferId: 1,
          sha256: Uint8List(0),
          aborted: true,
        ),
      ),
    );
    async.elapse(const Duration(milliseconds: 50));
    async.flushMicrotasks();

    final totalWritten = ptyWrites.fold<int>(0, (sum, s) => sum + s.length);
    check(totalWritten).isGreaterThan(8192);

    unawaited(svc2.stop());
    unawaited(service.stop());
    unawaited(registry.close());
    async.flushMicrotasks();
  });
}

final class _RecordingPtySession extends _FakePtySession {
  final List<String> writes;
  _RecordingPtySession(this.writes);

  @override
  void writeBytes(Uint8List data) {
    writes.add(utf8.decode(data, allowMalformed: true));
  }
}
