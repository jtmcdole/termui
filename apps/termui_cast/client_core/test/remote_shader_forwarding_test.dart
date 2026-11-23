import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:checks/checks.dart';
import 'package:clock/clock.dart';
import 'package:stream_channel/stream_channel.dart';
import 'package:termui/termui.dart';
import 'package:termui_cast_client_core/termui_cast_client_core.dart';
import 'package:termui_cast_protocol/termui_cast_protocol.dart';
import 'package:termui_cast_server/termui_cast_server.dart';
import 'package:termui_caster_cli/termui_caster_cli.dart';
import 'package:termui_pty/termui_pty.dart';
import 'package:test/test.dart';

final class _FakePtySession implements PtySession {
  final StreamController<Uint8List> _output = StreamController<Uint8List>(
    sync: true,
  );
  final Completer<int> _exit = Completer<int>();
  final List<Uint8List> inputs = <Uint8List>[];

  void emitString(String text) =>
      _output.add(Uint8List.fromList(utf8.encode(text)));

  @override
  Stream<Uint8List> get output => _output.stream;

  @override
  Future<int> get exitCode => _exit.future;

  @override
  void writeBytes(List<int> bytes) => inputs.add(Uint8List.fromList(bytes));

  @override
  void resize(int cols, int rows, {int pixelWidth = 0, int pixelHeight = 0}) {}

  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    if (!_exit.isCompleted) _exit.complete(0);
    if (!_output.isClosed) unawaited(_output.close());
    return true;
  }
}

final class _FakeRoutedBackend implements RoutedPtyBackend {
  final StreamController<Uint8List> _output = StreamController<Uint8List>(
    sync: true,
  );
  final Completer<int> _exit = Completer<int>();

  void emitString(String text) =>
      _output.add(Uint8List.fromList(utf8.encode(text)));

  @override
  Stream<Uint8List> get output => _output.stream;

  @override
  Future<int> get exitCode => _exit.future;

  @override
  void write(Uint8List bytes) {}

  @override
  void resize(int cols, int rows, {int pixelWidth = 0, int pixelHeight = 0}) {}

  @override
  void kill() {
    if (!_exit.isCompleted) _exit.complete(0);
  }

  @override
  Future<void> dispose() async {
    kill();
    if (!_output.isClosed) await _output.close();
  }
}

(StreamChannel<Uint8List>, StreamChannel<Uint8List>) _duplexChannels({
  void Function(Uint8List bytes)? onAToB,
  void Function(Uint8List bytes)? onBToA,
}) {
  final aToB = StreamController<Uint8List>();
  final bToA = StreamController<Uint8List>();
  final a = StreamChannel<Uint8List>(
    bToA.stream,
    _InterceptingSink(aToB.sink, onAToB),
  );
  final b = StreamChannel<Uint8List>(
    aToB.stream,
    _InterceptingSink(bToA.sink, onBToA),
  );
  return (a, b);
}

final class _InterceptingSink implements StreamSink<Uint8List> {
  final StreamSink<Uint8List> _inner;
  final void Function(Uint8List bytes)? _onAdd;

  _InterceptingSink(this._inner, this._onAdd);

  @override
  void add(Uint8List event) {
    _onAdd?.call(event);
    _inner.add(event);
  }

  @override
  void addError(Object error, [StackTrace? stackTrace]) =>
      _inner.addError(error, stackTrace);

  @override
  Future<void> addStream(Stream<Uint8List> stream) => _inner.addStream(
    stream.map((e) {
      _onAdd?.call(e);
      return e;
    }),
  );

  @override
  Future<void> close() => _inner.close();

  @override
  Future<void> get done => _inner.done;
}

Future<void> _waitUntil(
  bool Function() predicate, {
  Duration timeout = const Duration(seconds: 5),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!predicate()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('Condition not met within $timeout');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

void main() {
  const sessionId = SessionId('shader-sess');

  group('End-to-end 0x1C ShaderFrame forwarding', () {
    test(
      'forwards define, region, transforms, set, uniform, and reset from CasterService -> Relay -> RemoteTerminalPort',
      () async {
        final registry = SessionRegistry();
        final relay = WsRelayHandler(
          registry: registry,
          authenticator: TokenAuthenticator(casterToken: '', clientToken: ''),
        );
        final pty = _FakePtySession();
        final casterWireFrames = <CastMessage>[];
        final caster = CasterService(
          config: CasterConfig(
            sessionId: sessionId,
            title: 'shader-demo',
            command: const ['demo'],
          ),
          pty: pty,
          frameCoalesceInterval: const Duration(milliseconds: 16),
          channelOpener: () async {
            final (casterSide, serverSide) = _duplexChannels(
              onAToB: (raw) =>
                  casterWireFrames.add(BufferFrameCodec.decode(raw)),
            );
            relay.attachCasterChannel(serverSide);
            return casterSide;
          },
        );
        final viewerRepo = CastClientRepository(
          transport: WsClientTransport(
            serverUri: Uri.parse('ws://127.0.0.1:8420/v1/client'),
            channelFactory: () async {
              final (clientSide, serverSide) = _duplexChannels();
              relay.attachClientChannel(serverSide);
              return clientSide;
            },
          ),
        );
        final nonOptedRepo = CastClientRepository(
          enableShaderFrames: false,
          transport: WsClientTransport(
            serverUri: Uri.parse('ws://127.0.0.1:8420/v1/client'),
            channelFactory: () async {
              final (clientSide, serverSide) = _duplexChannels();
              relay.attachClientChannel(serverSide);
              return clientSide;
            },
          ),
        );

        addTearDown(() async {
          await viewerRepo.dispose();
          await nonOptedRepo.dispose();
          await caster.stop();
          await relay.close();
          await registry.close();
        });

        await caster.start();
        await _waitUntil(() => registry.sessions.length == 1);

        await viewerRepo.connect();
        await nonOptedRepo.connect();
        final optedPort = viewerRepo.openTerminalPort(
          sessionId,
          initialCols: 80,
          initialRows: 24,
        );
        final nonOptedPort = nonOptedRepo.openTerminalPort(
          sessionId,
          initialCols: 80,
          initialRows: 24,
        );
        await _waitUntil(
          () =>
              optedPort.slot.state == .synchronized &&
              nonOptedPort.slot.state == .synchronized,
        );

        final optedEvents = <TerminalShaderApcEvent>[];
        final nonOptedEvents = <TerminalShaderApcEvent>[];
        optedPort.addShaderListener(optedEvents.add);
        nonOptedPort.addShaderListener(nonOptedEvents.add);
        casterWireFrames.clear();

        // Emit text + define + region + redundant uniforms + redundant xforms + set in one 16ms tick.
        const glsl = 'void mainImage(out vec4 c, in vec2 u) { c = vec4(1.0); }';
        final region = ShaderRegion(
          id: 'flame',
          shaderId: 'fire_glsl',
          sourceRects: const [Rect(0, 0, 4, 1)],
          padding: const CellPadding(top: 2),
        );
        pty.emitString(
          'FIRE'
          '${ShaderApcEncoder.encodeDefine(id: 'fire_glsl', glslSource: glsl, persist: true).join()}'
          '${ShaderApcEncoder.encodeRegion(region)}'
          '${ShaderApcEncoder.encodeUniform(id: 'flame', params: {0: 1.0})}'
          '${ShaderApcEncoder.encodeUniform(id: 'flame', params: {0: 2.5, 1: 0.75})}'
          '${ShaderApcEncoder.encodeTransform(col: 0, row: 0, transform: const CellTransform(dy: 1.0))}'
          '${ShaderApcEncoder.encodeTransform(col: 0, row: 0, transform: const CellTransform(dy: 3.0))}'
          '${ShaderApcEncoder.encodeSet(stage: 'post', presetId: 'crt_lottes')}',
        );

        await _waitUntil(() => optedEvents.length == 5);
        await _waitUntil(() => nonOptedPort.buffer.getCharacter(0, 0) == 'F');

        // Verify BufferDeltaFrame was emitted strictly before ShaderFrames in the 16ms tick.
        final deltaIdx = casterWireFrames.indexWhere(
          (m) => m is BufferDeltaFrame,
        );
        final firstShaderIdx = casterWireFrames.indexWhere(
          (m) => m is ShaderFrame,
        );
        check(deltaIdx).isGreaterOrEqual(0);
        check(firstShaderIdx).isGreaterThan(deltaIdx);

        // Verify coalescing: define never dropped, redundant uniforms & xforms merged latest-wins!
        check(optedEvents[0]).equals(
          const TerminalShaderDefineEvent(
            id: 'fire_glsl',
            glslSource: glsl,
            persist: true,
          ),
        );
        check(optedEvents[1])
            .isA<TerminalShaderRegionEvent>()
            .has((e) => e.id, 'id')
            .equals('flame');
        final uniformEv = optedEvents[2] as TerminalShaderUniformEvent;
        check(uniformEv.paramMask).equals(0x03);
        check(uniformEv.params[0]).equals(2.5);
        check(uniformEv.params[1]).equals(0.75);
        final xformEv = optedEvents[3] as TerminalShaderTransformBatchEvent;
        check(xformEv.entries.length).equals(1);
        check(xformEv.entries.single.transform!.dy).equals(3.0);
        check(optedEvents[4])
            .isA<TerminalShaderSetEvent>()
            .has((e) => e.presetId, 'presetId')
            .equals('crt_lottes');

        // Non-opted-in viewer got the text delta but ZERO 0x1C shader events.
        check(nonOptedEvents).isEmpty();

        // Late-joining opted-in viewer triggers RequestKeyframeFrame -> full replay!
        final lateRepo = CastClientRepository(
          transport: WsClientTransport(
            serverUri: Uri.parse('ws://127.0.0.1:8420/v1/client'),
            channelFactory: () async {
              final (clientSide, serverSide) = _duplexChannels();
              relay.attachClientChannel(serverSide);
              return clientSide;
            },
          ),
        );
        addTearDown(lateRepo.dispose);
        await lateRepo.connect();
        final latePort = lateRepo.openTerminalPort(
          sessionId,
          initialCols: 80,
          initialRows: 24,
        );
        final lateEvents = <TerminalShaderApcEvent>[];
        latePort.addShaderListener(lateEvents.add);

        await _waitUntil(() => lateEvents.length >= 4);
        check(
          lateEvents.whereType<TerminalShaderDefineEvent>().length,
        ).equals(1);
        final replayedRegion = lateEvents
            .whereType<TerminalShaderRegionEvent>()
            .single
            .region!;
        check(replayedRegion.params[0]).equals(2.5);
        check(replayedRegion.params[1]).equals(0.75);
        final replayedXform = lateEvents
            .whereType<TerminalShaderTransformBatchEvent>()
            .single;
        check(replayedXform.replace).isTrue();
        check(replayedXform.entries.single.transform!.dy).equals(3.0);
        check(
          lateEvents.whereType<TerminalShaderSetEvent>().single.presetId,
        ).equals('crt_lottes');

        // Emit reset -> never dropped, clears active replay state.
        optedEvents.clear();
        pty.emitString(ShaderApcEncoder.encodeReset(target: 'all'));
        await _waitUntil(
          () => optedEvents.contains(
            const TerminalResetShaderEvent(target: .all),
          ),
        );
        check(caster.terminal.buildShaderReplayFrames()).isEmpty();

        await latePort.dispose();
        await optedPort.dispose();
        await nonOptedPort.dispose();
      },
    );

    test(
      'works in shared PtyRouterSession mode and chunks >960 transforms <= 64 KiB on keyframe replay',
      () async {
        final registry = SessionRegistry();
        final relay = WsRelayHandler(
          registry: registry,
          authenticator: TokenAuthenticator(casterToken: '', clientToken: ''),
        );
        final router = PtyRouter();
        final backend = _FakeRoutedBackend();
        final routerSession = router.createSession(
          id: 'shared-shader',
          backend: backend,
          initialCols: 80,
          initialRows: 30,
        );
        final caster = CasterService.fromRouterSession(
          config: CasterConfig(
            sessionId: sessionId,
            title: 'router-shader',
            command: const ['sh'],
          ),
          session: routerSession,
          frameCoalesceInterval: const Duration(milliseconds: 10),
          channelOpener: () async {
            final (casterSide, serverSide) = _duplexChannels();
            relay.attachCasterChannel(serverSide);
            return casterSide;
          },
        );
        final repo = CastClientRepository(
          transport: WsClientTransport(
            serverUri: Uri.parse('ws://127.0.0.1:8420/v1/client'),
            channelFactory: () async {
              final (clientSide, serverSide) = _duplexChannels();
              relay.attachClientChannel(serverSide);
              return clientSide;
            },
          ),
        );
        addTearDown(() async {
          await repo.dispose();
          await caster.stop();
          await router.dispose();
          await backend.dispose();
          await relay.close();
          await registry.close();
        });

        await caster.start();
        await _waitUntil(() => registry.sessions.length == 1);

        // Emit 1,100 transforms via shared router BEFORE any viewer subscribes.
        final batch = <CellTransformEntry>[
          for (var i = 0; i < 1100; i++)
            (
              col: i % 80,
              row: i ~/ 80,
              transform: CellTransform(dx: (i % 5) * 0.1 + 0.1),
            ),
        ];
        for (final seq in ShaderApcEncoder.encodeTransformsBatch(batch)) {
          backend.emitString(seq);
        }

        // Verify replay frames chunk into <= 64 KiB wire frames (960 + 140).
        final replayFrames = caster.terminal.buildShaderReplayFrames();
        check(replayFrames.length).equals(2);
        for (final f in replayFrames) {
          check(
            BufferFrameCodec.encode(f).length,
          ).isLessOrEqual(BufferFrameCodec.maxShaderFrameBytes);
        }

        await repo.connect();
        final port = repo.openTerminalPort(
          sessionId,
          initialCols: 80,
          initialRows: 30,
        );
        final receivedBatches = <TerminalShaderTransformBatchEvent>[];
        port.addShaderListener((ev) {
          if (ev is TerminalShaderTransformBatchEvent) {
            receivedBatches.add(ev);
          }
        });

        await _waitUntil(() => receivedBatches.length == 2);
        check(receivedBatches[0].replace).isTrue();
        check(receivedBatches[0].entries.length).equals(960);
        check(receivedBatches[1].replace).isFalse();
        check(receivedBatches[1].entries.length).equals(140);
        await port.dispose();
      },
    );

    test(
      'suppresses 0x1C emission without disconnecting when relay advertises shaderFrames: false',
      () async {
        final registry = SessionRegistry();
        final legacyRelay = WsRelayHandler(
          registry: registry,
          authenticator: TokenAuthenticator(casterToken: '', clientToken: ''),
          enableShaderFrames: false,
        );
        final pty = _FakePtySession();
        final casterWireFrames = <CastMessage>[];
        final clientWireFrames = <CastMessage>[];

        final caster = CasterService(
          config: CasterConfig(
            sessionId: sessionId,
            title: 'legacy-check',
            command: const ['sh'],
          ),
          pty: pty,
          frameCoalesceInterval: const Duration(milliseconds: 10),
          channelOpener: () async {
            final (casterSide, serverSide) = _duplexChannels(
              onAToB: (raw) =>
                  casterWireFrames.add(BufferFrameCodec.decode(raw)),
            );
            legacyRelay.attachCasterChannel(serverSide);
            return casterSide;
          },
        );
        final repo = CastClientRepository(
          transport: WsClientTransport(
            serverUri: Uri.parse('ws://127.0.0.1:8420/v1/client'),
            channelFactory: () async {
              final (clientSide, serverSide) = _duplexChannels(
                onAToB: (raw) =>
                    clientWireFrames.add(BufferFrameCodec.decode(raw)),
              );
              legacyRelay.attachClientChannel(serverSide);
              return clientSide;
            },
          ),
        );
        addTearDown(() async {
          await repo.dispose();
          await caster.stop();
          await legacyRelay.close();
          await registry.close();
        });

        await caster.start();
        await _waitUntil(() => registry.sessions.length == 1);
        await repo.connect();
        final port = repo.openTerminalPort(
          sessionId,
          initialCols: 80,
          initialRows: 24,
        );
        await _waitUntil(() => port.slot.state == .synchronized);

        // Client subscribed with shaderFrames: false against legacy relay.
        final subFrames = clientWireFrames
            .whereType<SubscribeSessionFrame>()
            .toList();
        check(subFrames).isNotEmpty();
        for (final subFrame in subFrames) {
          check(subFrame.shaderFrames).isFalse();
        }

        // Emit text + shader APC -> text arrives, ZERO 0x1C emitted, caster stays streaming!
        pty.emitString(
          'OK'
          '${ShaderApcEncoder.encodeTransform(col: 0, row: 0, transform: const CellTransform(dx: 1.0))}',
        );
        await _waitUntil(() => port.buffer.getCharacter(0, 0) == 'O');
        await Future<void>.delayed(const Duration(milliseconds: 30));

        check(casterWireFrames.whereType<ShaderFrame>()).isEmpty();
        check(caster.stateMachine.state).equals(CasterLifecycleState.streaming);
        await port.dispose();
      },
    );
  });

  group('SessionRegistry 0x1C rate caps and synchronized backpressure', () {
    test(
      'enforces per-session <= 120 frames/sec and <= 512 KiB/sec budgets cleanly without disconnect',
      () async {
        var now = DateTime.utc(2026, 1, 1, 12);
        final registry = SessionRegistry(clock: Clock(() => now));
        addTearDown(registry.close);

        final casterCtrl = StreamController<Uint8List>();
        final viewerCtrl = StreamController<Uint8List>();
        final viewerFrames = <CastMessage>[];
        viewerCtrl.stream.listen(
          (raw) => viewerFrames.add(BufferFrameCodec.decode(raw)),
        );

        final caster = registry.registerCasterPeer(sink: casterCtrl.sink);
        final viewer = registry.registerClientPeer(sink: viewerCtrl.sink);
        registry.registerSession(
          caster,
          const RegisterSessionFrame(
            sessionId: sessionId,
            title: 'rate-test',
            cols: 20,
            rows: 5,
          ),
        );
        registry.subscribeClient(
          viewer,
          const SubscribeSessionFrame(
            sessionId: sessionId,
            cols: 20,
            rows: 5,
            shaderFrames: true,
          ),
        );
        // Hydrate viewer with snapshot so it leaves awaitingKeyframe.
        final snap = BufferFrameCodec.encode(
          BufferSnapshotFrame(
            snapshot: BufferSnapshot.fromBuffer(
              sessionId: sessionId,
              seq: 1,
              buffer: Buffer.blank(20, 5),
              cursor: CursorState.origin,
              modes: TerminalModes.defaults,
            ),
          ),
        );
        check(registry.forwardCasterBufferBytes(caster, snap)).isTrue();
        await Future<void>.delayed(Duration.zero);
        viewerFrames.clear();

        // 1. Frame rate cap: 120 allowed in 1s, 121st..130th dropped cleanly.
        final smallFrame = BufferFrameCodec.encode(
          const ShaderFrame(
            sessionId: sessionId,
            payload: CastResetShaderPayload(target: 'pane'),
          ),
        );
        for (var i = 0; i < 130; i++) {
          check(registry.forwardCasterShaderBytes(caster, smallFrame)).isTrue();
        }
        await Future<void>.delayed(Duration.zero);
        check(viewerFrames.whereType<ShaderFrame>().length).equals(120);

        // Advance clock by 1 second -> budget refills.
        now = now.add(const Duration(seconds: 1));
        viewerFrames.clear();

        // 2. Byte rate cap (512 KiB/sec): 30 KiB defines -> 17 * ~30.7 KiB <= 512 KiB,
        // 18th frame exceeds 512 KiB and is dropped cleanly.
        final bigGlsl = '/*${'a' * (30 * 1024)}*/';
        final bigFrame = BufferFrameCodec.encode(
          ShaderFrame(
            sessionId: sessionId,
            payload: CastDefineShaderPayload(id: 'big', glslSource: bigGlsl),
          ),
        );
        final maxFits = (512 * 1024) ~/ bigFrame.length;
        for (var i = 0; i < maxFits + 5; i++) {
          check(registry.forwardCasterShaderBytes(caster, bigFrame)).isTrue();
        }
        await Future<void>.delayed(Duration.zero);
        check(viewerFrames.whereType<ShaderFrame>().length).equals(maxFits);
      },
    );

    test(
      'downgrades pressured opted-in subscriber to awaitingKeyframe instead of dropping 0x1C like audio',
      () async {
        final registry = SessionRegistry(maxOutboundFrames: 4);
        addTearDown(registry.close);

        final casterCtrl = StreamController<Uint8List>();
        final casterMessages = <CastMessage>[];
        casterCtrl.stream.listen(
          (raw) => casterMessages.add(BufferFrameCodec.decode(raw)),
        );

        final slowViewerCtrl = StreamController<Uint8List>();
        final slowSub = slowViewerCtrl.stream.listen((_) {});

        final caster = registry.registerCasterPeer(sink: casterCtrl.sink);
        final viewer = registry.registerClientPeer(sink: slowViewerCtrl.sink);
        registry.registerSession(
          caster,
          const RegisterSessionFrame(
            sessionId: sessionId,
            title: 'bp-test',
            cols: 20,
            rows: 5,
          ),
        );
        registry.subscribeClient(
          viewer,
          const SubscribeSessionFrame(
            sessionId: sessionId,
            cols: 20,
            rows: 5,
            shaderFrames: true,
          ),
        );
        final snap = BufferFrameCodec.encode(
          BufferSnapshotFrame(
            snapshot: BufferSnapshot.fromBuffer(
              sessionId: sessionId,
              seq: 1,
              buffer: Buffer.blank(20, 5),
              cursor: CursorState.origin,
              modes: TerminalModes.defaults,
            ),
          ),
        );
        registry.forwardCasterBufferBytes(caster, snap);
        await Future<void>.delayed(Duration.zero);
        casterMessages.clear();

        // Pause viewer sink and fill its outbound queue past high-water mark (3 of 4).
        slowSub.pause();
        final shaderBytes = BufferFrameCodec.encode(
          const ShaderFrame(
            sessionId: sessionId,
            payload: CastDefineShaderPayload(
              id: 's1',
              glslSource: 'void mainImage(out vec4 c, in vec2 u){c=vec4(1.);}',
            ),
          ),
        );
        for (var i = 0; i < 4; i++) {
          check(
            registry.forwardCasterShaderBytes(caster, shaderBytes),
          ).isTrue();
        }
        await Future<void>.delayed(Duration.zero);

        // Relay must have requested a keyframe from caster for the pressured subscriber!
        check(casterMessages.whereType<RequestKeyframeFrame>()).isNotEmpty();

        await slowSub.cancel();
      },
    );
  });
}
