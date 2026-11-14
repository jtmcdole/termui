import 'dart:async';
import 'dart:typed_data';

import 'package:checks/checks.dart';
import 'package:clock/clock.dart';
import 'package:stream_channel/stream_channel.dart';
import 'package:termui/termui.dart';
import 'package:termui_cast_protocol/termui_cast_protocol.dart';
import 'package:termui_cast_server/termui_cast_server.dart';
import 'package:test/test.dart';

void main() {
  group('SessionRegistry + WsRelayHandler stateless guarantees', () {
    late SessionRegistry registry;
    late WsRelayHandler handler;

    setUp(() {
      registry = SessionRegistry(maxOutboundFrames: 8, maxOutboundBytes: 65536);
      handler = WsRelayHandler(
        registry: registry,
        authenticator: TokenAuthenticator(),
      );
    });

    tearDown(() async {
      await registry.close();
    });

    test(
      'retains zero buffer history and requests fresh keyframe on late subscribe',
      () async {
        const sessionId = SessionId('sess-stateless');
        final casterPipe = StreamChannelController<Uint8List>();
        handler.attachCasterChannel(casterPipe.foreign);

        final casterInbox = <CastMessage>[];
        final casterSub = casterPipe.local.stream.listen((bytes) {
          casterInbox.add(BufferFrameCodec.decode(bytes));
        });
        addTearDown(casterSub.cancel);

        casterPipe.local.sink.add(
          BufferFrameCodec.encode(const AuthFrame(role: .caster, token: '')),
        );
        casterPipe.local.sink.add(
          BufferFrameCodec.encode(
            const RegisterSessionFrame(
              sessionId: sessionId,
              title: 'zsh',
              cols: 80,
              rows: 24,
            ),
          ),
        );
        await pumpEventQueue();

        // Emit 5 snapshots and deltas BEFORE any viewer connects.
        final preBuf = Buffer.blank(80, 24)
          ..writeString(0, 0, 'OLD', Style.empty);
        for (var seq = 1; seq <= 5; seq++) {
          casterPipe.local.sink.add(
            BufferFrameCodec.encode(
              BufferSnapshotFrame(
                snapshot: BufferSnapshot.fromBuffer(
                  sessionId: sessionId,
                  seq: seq,
                  buffer: preBuf,
                  cursor: CursorState.origin,
                  modes: TerminalModes.defaults,
                ),
              ),
            ),
          );
        }
        await pumpEventQueue();

        // Late client connects and subscribes at matching size 80x24.
        final clientPipe = StreamChannelController<Uint8List>();
        handler.attachClientChannel(clientPipe.foreign);
        final clientInbox = <CastMessage>[];
        final clientSub = clientPipe.local.stream.listen((bytes) {
          clientInbox.add(BufferFrameCodec.decode(bytes));
        });
        addTearDown(clientSub.cancel);

        clientPipe.local.sink.add(
          BufferFrameCodec.encode(const AuthFrame(role: .client, token: '')),
        );
        await pumpEventQueue();

        // Client sees AuthAccepted + SessionDirectory, zero BufferSnapshotFrames.
        check(clientInbox.whereType<BufferSnapshotFrame>()).isEmpty();

        casterInbox.clear();
        clientPipe.local.sink.add(
          BufferFrameCodec.encode(
            const SubscribeSessionFrame(
              sessionId: sessionId,
              cols: 80,
              rows: 24,
            ),
          ),
        );
        await pumpEventQueue();

        // Caster is notified of 1 subscriber and asked for a fresh keyframe.
        check(casterInbox).any(
          (it) => it
              .isA<SubscriberCountFrame>()
              .has((f) => f.subscriberCount, 'count')
              .equals(1),
        );
        check(casterInbox).any((it) => it.isA<RequestKeyframeFrame>());
        // Client still received zero stale frames from before subscribing!
        check(clientInbox.whereType<BufferSnapshotFrame>()).isEmpty();

        // Caster responds with seq=6 keyframe -> forwarded live to client.
        final liveBuf = Buffer.blank(80, 24)
          ..writeString(0, 0, 'LIVE', Style.empty);
        casterPipe.local.sink.add(
          BufferFrameCodec.encode(
            BufferSnapshotFrame(
              snapshot: BufferSnapshot.fromBuffer(
                sessionId: sessionId,
                seq: 6,
                buffer: liveBuf,
                cursor: const CursorState(x: 4, y: 0),
                modes: TerminalModes.defaults,
              ),
            ),
          ),
        );
        await pumpEventQueue();

        final snapshots = [...clientInbox.whereType<BufferSnapshotFrame>()];
        check(snapshots).length.equals(1);
        check(snapshots.single.snapshot.seq).equals(6);
        check(
          snapshots.single.snapshot.toBuffer().getCharacter(0, 0),
        ).equals('L');
      },
    );

    test(
      'evicts paused slow subscriber with 1008 without stalling healthy viewer',
      () async {
        const sessionId = SessionId('sess-backpressure');
        final casterPipe = StreamChannelController<Uint8List>();
        handler.attachCasterChannel(casterPipe.foreign);
        casterPipe.local.sink.add(
          BufferFrameCodec.encode(const AuthFrame(role: .caster, token: '')),
        );
        casterPipe.local.sink.add(
          BufferFrameCodec.encode(
            const RegisterSessionFrame(
              sessionId: sessionId,
              title: 'stream',
              cols: 20,
              rows: 4,
            ),
          ),
        );

        int? slowCloseCode;
        // Direct StreamControllers propagate pause() backpressure to addStream.
        final slowIn = StreamController<Uint8List>();
        final slowOut = StreamController<Uint8List>();
        final slowLocal = StreamChannel<Uint8List>(slowOut.stream, slowIn.sink);
        final slowForeign = StreamChannel<Uint8List>(
          slowIn.stream,
          slowOut.sink,
        );
        handler.attachClientChannel(
          slowForeign,
          closeWithCode: (code, _) async {
            slowCloseCode = code;
            unawaited(slowOut.close());
          },
        );

        final fastPipe = StreamChannelController<Uint8List>();
        handler.attachClientChannel(fastPipe.foreign);

        final fastSnapshots = <int>[];
        final fastSub = fastPipe.local.stream.listen((bytes) {
          final msg = BufferFrameCodec.decode(bytes);
          if (msg is BufferSnapshotFrame) fastSnapshots.add(msg.snapshot.seq);
        });
        addTearDown(fastSub.cancel);

        final slowSub = slowLocal.stream.listen((_) {});
        addTearDown(slowSub.cancel);
        addTearDown(slowIn.close);

        for (final ch in [slowLocal, fastPipe.local]) {
          ch.sink.add(
            BufferFrameCodec.encode(const AuthFrame(role: .client, token: '')),
          );
          ch.sink.add(
            BufferFrameCodec.encode(
              const SubscribeSessionFrame(sessionId: sessionId),
            ),
          );
        }
        await pumpEventQueue();

        // Pause slow viewer's stream subscription to induce real sink backpressure!
        slowSub.pause();

        final buf = Buffer.blank(20, 4);
        for (var seq = 1; seq <= 20; seq++) {
          casterPipe.local.sink.add(
            BufferFrameCodec.encode(
              BufferSnapshotFrame(
                snapshot: BufferSnapshot.fromBuffer(
                  sessionId: sessionId,
                  seq: seq,
                  buffer: buf,
                  cursor: CursorState.origin,
                  modes: TerminalModes.defaults,
                ),
              ),
            ),
          );
          await Future<void>.delayed(Duration.zero);
        }
        await pumpEventQueue();

        check(slowCloseCode).equals(1008);
        check(fastSnapshots).length.equals(20);
        check(registry.sessions.single.subscriberCount).equals(1);
      },
    );

    test(
      'aggregates min(cols) and min(rows) across active subscribers, restores on leave/disconnect, and sends Resize + RequestKeyframe on 0 -> 1',
      () async {
        const sessionId = SessionId('sess-min-viewport');
        final casterPipe = StreamChannelController<Uint8List>();
        handler.attachCasterChannel(casterPipe.foreign);
        final casterInbox = <CastMessage>[];
        final casterSub = casterPipe.local.stream.listen((bytes) {
          casterInbox.add(BufferFrameCodec.decode(bytes));
        });
        addTearDown(casterSub.cancel);

        casterPipe.local.sink.add(
          BufferFrameCodec.encode(const AuthFrame(role: .caster, token: '')),
        );
        casterPipe.local.sink.add(
          BufferFrameCodec.encode(
            const RegisterSessionFrame(
              sessionId: sessionId,
              title: 'vim',
              cols: 80,
              rows: 24,
            ),
          ),
        );
        await pumpEventQueue();

        final viewerA = StreamChannelController<Uint8List>();
        final viewerB = StreamChannelController<Uint8List>();
        handler.attachClientChannel(viewerA.foreign);
        handler.attachClientChannel(viewerB.foreign);
        final subA = viewerA.local.stream.listen((_) {});
        final subB = viewerB.local.stream.listen((_) {});
        addTearDown(subA.cancel);
        addTearDown(subB.cancel);

        viewerA.local.sink.add(
          BufferFrameCodec.encode(const AuthFrame(role: .client, token: '')),
        );
        viewerB.local.sink.add(
          BufferFrameCodec.encode(const AuthFrame(role: .client, token: '')),
        );
        await pumpEventQueue();
        casterInbox.clear();

        // Viewer A subscribes first at 100x30 (0 -> 1) -> sends ResizeFrame(100, 30) AND RequestKeyframeFrame!
        viewerA.local.sink.add(
          BufferFrameCodec.encode(
            const SubscribeSessionFrame(
              sessionId: sessionId,
              cols: 100,
              rows: 30,
            ),
          ),
        );
        await pumpEventQueue();
        check(
          casterInbox.whereType<ResizeFrame>().single,
        ).has((r) => (r.cols, r.rows), 'dims').equals((100, 30));
        check(casterInbox.whereType<RequestKeyframeFrame>()).length.equals(1);

        // Larger Viewer B (120x40) joins and sends InputFrame -> min stays 100x30 (no ResizeFrame!).
        casterInbox.clear();
        viewerB.local.sink.add(
          BufferFrameCodec.encode(
            const SubscribeSessionFrame(
              sessionId: sessionId,
              cols: 120,
              rows: 40,
            ),
          ),
        );
        viewerB.local.sink.add(
          BufferFrameCodec.encode(
            InputFrame(sessionId: sessionId, data: Uint8List.fromList([0x69])),
          ),
        );
        await pumpEventQueue();
        check(casterInbox.whereType<ResizeFrame>()).isEmpty();
        check(casterInbox.whereType<RequestKeyframeFrame>()).length.equals(1);

        // Viewer A shrinks to 60x20 -> min clamps to 60x20.
        casterInbox.clear();
        viewerA.local.sink.add(
          BufferFrameCodec.encode(
            const ResizeFrame(sessionId: sessionId, cols: 60, rows: 20),
          ),
        );
        await pumpEventQueue();
        check(
          casterInbox.whereType<ResizeFrame>().single,
        ).has((r) => (r.cols, r.rows), 'dims').equals((60, 20));

        // Viewer A unsubscribes -> min restores to Viewer B's 120x40!
        casterInbox.clear();
        viewerA.local.sink.add(
          BufferFrameCodec.encode(
            const UnsubscribeSessionFrame(sessionId: sessionId),
          ),
        );
        await pumpEventQueue();
        check(
          casterInbox.whereType<ResizeFrame>().single,
        ).has((r) => (r.cols, r.rows), 'dims').equals((120, 40));

        // Viewer A re-subscribes at 70x25, then drops socket -> min clamps 70x25 then restores 120x40!
        casterInbox.clear();
        viewerA.local.sink.add(
          BufferFrameCodec.encode(
            const SubscribeSessionFrame(
              sessionId: sessionId,
              cols: 70,
              rows: 25,
            ),
          ),
        );
        await pumpEventQueue();
        check(
          casterInbox.whereType<ResizeFrame>().single,
        ).has((r) => (r.cols, r.rows), 'dims').equals((70, 25));

        casterInbox.clear();
        await viewerA.local.sink.close();
        await pumpEventQueue();
        check(
          casterInbox.whereType<ResizeFrame>().single,
        ).has((r) => (r.cols, r.rows), 'dims').equals((120, 40));

        // Viewer B unsubscribes (1 -> 0) and a new Viewer C joins at 120x40 (0 -> 1):
        // requestedCols/Rows cleared on 1 -> 0, so 0 -> 1 unconditionally sends Resize + RequestKeyframe!
        viewerB.local.sink.add(
          BufferFrameCodec.encode(
            const UnsubscribeSessionFrame(sessionId: sessionId),
          ),
        );
        await pumpEventQueue();
        casterInbox.clear();

        final viewerC = StreamChannelController<Uint8List>();
        handler.attachClientChannel(viewerC.foreign);
        addTearDown(viewerC.local.stream.listen((_) {}).cancel);
        viewerC.local.sink.add(
          BufferFrameCodec.encode(const AuthFrame(role: .client, token: '')),
        );
        viewerC.local.sink.add(
          BufferFrameCodec.encode(
            const SubscribeSessionFrame(
              sessionId: sessionId,
              cols: 120,
              rows: 40,
            ),
          ),
        );
        await pumpEventQueue();
        check(
          casterInbox.whereType<ResizeFrame>().single,
        ).has((r) => (r.cols, r.rows), 'dims').equals((120, 40));
        check(casterInbox.whereType<RequestKeyframeFrame>()).length.equals(1);
      },
    );

    test(
      'unicasts clean solicited keyframe only to late joiner and preserves revert resize after in-flight delta',
      () async {
        const sessionId = SessionId('sess-unicast');
        final casterPipe = StreamChannelController<Uint8List>();
        handler.attachCasterChannel(casterPipe.foreign);
        final casterInbox = <CastMessage>[];
        final casterSub = casterPipe.local.stream.listen(
          (b) => casterInbox.add(BufferFrameCodec.decode(b)),
        );
        addTearDown(casterSub.cancel);

        casterPipe.local.sink.add(
          BufferFrameCodec.encode(const AuthFrame(role: .caster, token: '')),
        );
        casterPipe.local.sink.add(
          BufferFrameCodec.encode(
            const RegisterSessionFrame(
              sessionId: sessionId,
              title: 'zsh',
              cols: 80,
              rows: 24,
            ),
          ),
        );
        await pumpEventQueue();

        // Viewer A connects and receives initial seq=1 snapshot.
        final viewerA = StreamChannelController<Uint8List>();
        handler.attachClientChannel(viewerA.foreign);
        final inboxA = <CastMessage>[];
        final subA = viewerA.local.stream.listen(
          (b) => inboxA.add(BufferFrameCodec.decode(b)),
        );
        addTearDown(subA.cancel);

        viewerA.local.sink.add(
          BufferFrameCodec.encode(const AuthFrame(role: .client, token: '')),
        );
        viewerA.local.sink.add(
          BufferFrameCodec.encode(
            const SubscribeSessionFrame(
              sessionId: sessionId,
              cols: 80,
              rows: 24,
            ),
          ),
        );
        await pumpEventQueue();

        final buf80 = Buffer.blank(80, 24)
          ..writeString(0, 0, 'V1', Style.empty);
        final snapSeq1 = BufferFrameCodec.encode(
          BufferSnapshotFrame(
            snapshot: BufferSnapshot.fromBuffer(
              sessionId: sessionId,
              seq: 1,
              buffer: buf80,
              cursor: CursorState.origin,
              modes: TerminalModes.defaults,
            ),
          ),
        );
        casterPipe.local.sink.add(snapSeq1);
        await pumpEventQueue();
        check(inboxA.whereType<BufferSnapshotFrame>()).length.equals(1);
        inboxA.clear();

        // Viewer B joins late at 80x24 -> Caster replies with clean snapshot at seq=1.
        final viewerB = StreamChannelController<Uint8List>();
        handler.attachClientChannel(viewerB.foreign);
        final inboxB = <CastMessage>[];
        final subB = viewerB.local.stream.listen(
          (b) => inboxB.add(BufferFrameCodec.decode(b)),
        );
        addTearDown(subB.cancel);

        viewerB.local.sink.add(
          BufferFrameCodec.encode(const AuthFrame(role: .client, token: '')),
        );
        viewerB.local.sink.add(
          BufferFrameCodec.encode(
            const SubscribeSessionFrame(
              sessionId: sessionId,
              cols: 80,
              rows: 24,
            ),
          ),
        );
        await pumpEventQueue();

        casterPipe.local.sink.add(snapSeq1);
        await pumpEventQueue();

        // Viewer B gets the solicited keyframe; already-synced Viewer A gets ZERO!
        check(inboxB.whereType<BufferSnapshotFrame>()).length.equals(1);
        check(inboxA.whereType<BufferSnapshotFrame>()).isEmpty();

        // Unsubscribe Viewer B, then Viewer A sends ResizeFrame(100, 30), an in-flight pre-resize 80x24 delta arrives,
        // and Viewer A reverts to ResizeFrame(80, 24) -> neither resize may be dropped!
        viewerB.local.sink.add(
          BufferFrameCodec.encode(
            const UnsubscribeSessionFrame(sessionId: sessionId),
          ),
        );
        await pumpEventQueue();
        casterInbox.clear();
        viewerA.local.sink.add(
          BufferFrameCodec.encode(
            const ResizeFrame(sessionId: sessionId, cols: 100, rows: 30),
          ),
        );
        await pumpEventQueue();
        casterPipe.local.sink.add(
          BufferFrameCodec.encode(
            BufferDeltaFrame(
              delta: BufferDelta(
                sessionId: sessionId,
                seq: 2,
                baseSeq: 1,
                cols: 80,
                rows: 24,
                cursor: CursorState.origin,
                modes: TerminalModes.defaults,
                runs: const [],
              ),
            ),
          ),
        );
        await pumpEventQueue();
        viewerA.local.sink.add(
          BufferFrameCodec.encode(
            const ResizeFrame(sessionId: sessionId, cols: 80, rows: 24),
          ),
        );
        await pumpEventQueue();

        final forwardedResizes = [
          for (final m in casterInbox.whereType<ResizeFrame>())
            (m.cols, m.rows),
        ];
        check(forwardedResizes).deepEquals([(100, 30), (80, 24)]);
      },
    );

    test(
      'syncs requestedCols/Rows on snapshot, ignores 0x0 for initialSizeAssigned, keeps cols/rows authoritative, and never strands awaitingKeyframe',
      () async {
        const sessionId = SessionId('sess-size-sync');
        final casterPipe = StreamChannelController<Uint8List>();
        handler.attachCasterChannel(casterPipe.foreign);
        final casterInbox = <CastMessage>[];
        final casterSub = casterPipe.local.stream.listen(
          (b) => casterInbox.add(BufferFrameCodec.decode(b)),
        );
        addTearDown(casterSub.cancel);

        casterPipe.local.sink.add(
          BufferFrameCodec.encode(const AuthFrame(role: .caster, token: '')),
        );
        casterPipe.local.sink.add(
          BufferFrameCodec.encode(
            const RegisterSessionFrame(
              sessionId: sessionId,
              title: 'zsh',
              cols: 80,
              rows: 24,
            ),
          ),
        );
        await pumpEventQueue();

        // Caster emits a 100x30 snapshot before any subscriber joins.
        final snap100 = BufferFrameCodec.encode(
          BufferSnapshotFrame(
            snapshot: BufferSnapshot.fromBuffer(
              sessionId: sessionId,
              seq: 1,
              buffer: Buffer.blank(100, 30),
              cursor: CursorState.origin,
              modes: TerminalModes.defaults,
            ),
          ),
        );
        casterPipe.local.sink.add(snap100);
        await pumpEventQueue();

        // 1. First viewer subscribes with 0x0 -> must NOT lock initialSizeAssigned, and must request keyframe.
        final viewerZero = StreamChannelController<Uint8List>();
        handler.attachClientChannel(viewerZero.foreign);
        final inboxZero = <CastMessage>[];
        final subZero = viewerZero.local.stream.listen(
          (b) => inboxZero.add(BufferFrameCodec.decode(b)),
        );
        addTearDown(subZero.cancel);

        viewerZero.local.sink.add(
          BufferFrameCodec.encode(const AuthFrame(role: .client, token: '')),
        );
        await pumpEventQueue();
        casterInbox.clear();

        viewerZero.local.sink.add(
          BufferFrameCodec.encode(
            const SubscribeSessionFrame(sessionId: sessionId, cols: 0, rows: 0),
          ),
        );
        await pumpEventQueue();
        check(casterInbox.whereType<RequestKeyframeFrame>()).length.equals(1);
        casterPipe.local.sink.add(snap100);
        await pumpEventQueue();
        check(inboxZero.whereType<BufferSnapshotFrame>()).length.equals(1);

        // 2. Second viewer subscribes at 100x30 (matching the caster's 100x30 snapshot):
        // initialSizeAssigned was still false, and requestedCols/Rows were synced to 100x30,
        // so server must send RequestKeyframeFrame (NOT ResizeFrame(100, 30) without keyframe!).
        final viewerMatch = StreamChannelController<Uint8List>();
        handler.attachClientChannel(viewerMatch.foreign);
        final inboxMatch = <CastMessage>[];
        final subMatch = viewerMatch.local.stream.listen(
          (b) => inboxMatch.add(BufferFrameCodec.decode(b)),
        );
        addTearDown(subMatch.cancel);

        viewerMatch.local.sink.add(
          BufferFrameCodec.encode(const AuthFrame(role: .client, token: '')),
        );
        await pumpEventQueue();
        casterInbox.clear();
        inboxZero.clear();

        viewerMatch.local.sink.add(
          BufferFrameCodec.encode(
            const SubscribeSessionFrame(
              sessionId: sessionId,
              cols: 100,
              rows: 30,
            ),
          ),
        );
        await pumpEventQueue();
        check(casterInbox.whereType<ResizeFrame>()).isEmpty();
        check(casterInbox.whereType<RequestKeyframeFrame>()).length.equals(1);

        // 3. Before caster replies with the solicited 100x30 seq=1 keyframe for viewerMatch,
        // viewerMatch sends ResizeFrame(120, 40).
        // session.cols/rows must remain authoritative (100x30) until confirmed by snapshot,
        // and the in-flight 100x30 seq=1 keyframe must still unicast ONLY to viewerMatch!
        viewerMatch.local.sink.add(
          BufferFrameCodec.encode(
            const ResizeFrame(sessionId: sessionId, cols: 120, rows: 40),
          ),
        );
        await pumpEventQueue();
        check((
          registry.sessions.single.cols,
          registry.sessions.single.rows,
        )).equals((100, 30));

        casterPipe.local.sink.add(snap100);
        await pumpEventQueue();
        check(inboxMatch.whereType<BufferSnapshotFrame>()).length.equals(1);
        check(inboxZero.whereType<BufferSnapshotFrame>()).isEmpty();

        // 4. Both viewers unsubscribe while requestedCols=120 != cols=100; a new viewer
        // subscribing at 100x30 (cols == session.cols && rows == session.rows) must still
        // trigger RequestKeyframeFrame alongside ResizeFrame(100, 30) so it never hangs.
        viewerZero.local.sink.add(
          BufferFrameCodec.encode(
            const UnsubscribeSessionFrame(sessionId: sessionId),
          ),
        );
        viewerMatch.local.sink.add(
          BufferFrameCodec.encode(
            const UnsubscribeSessionFrame(sessionId: sessionId),
          ),
        );
        await pumpEventQueue();
        casterInbox.clear();

        final viewerAfterAbort = StreamChannelController<Uint8List>();
        handler.attachClientChannel(viewerAfterAbort.foreign);
        final subAfterAbort = viewerAfterAbort.local.stream.listen((_) {});
        addTearDown(subAfterAbort.cancel);

        viewerAfterAbort.local.sink.add(
          BufferFrameCodec.encode(const AuthFrame(role: .client, token: '')),
        );
        viewerAfterAbort.local.sink.add(
          BufferFrameCodec.encode(
            const SubscribeSessionFrame(
              sessionId: sessionId,
              cols: 100,
              rows: 30,
            ),
          ),
        );
        await pumpEventQueue();
        check(casterInbox.whereType<ResizeFrame>()).length.equals(1);
        check(casterInbox.whereType<RequestKeyframeFrame>()).length.equals(1);
      },
    );

    test(
      'delivers synchronous > 64-frame burst to healthy peer without false slow-consumer eviction',
      () async {
        final burstRegistry = SessionRegistry(
          maxOutboundFrames: 64,
          maxOutboundBytes: 8 * 1024 * 1024,
        );
        addTearDown(burstRegistry.close);

        const sessionId = SessionId('sess-burst');
        final casterOut = StreamController<Uint8List>();
        addTearDown(casterOut.close);
        final casterSub = casterOut.stream.listen((_) {});
        addTearDown(casterSub.cancel);
        final caster = burstRegistry.registerCasterPeer(sink: casterOut.sink);
        burstRegistry.registerSession(
          caster,
          const RegisterSessionFrame(
            sessionId: sessionId,
            title: 'burst',
            cols: 10,
            rows: 2,
          ),
        );

        int? clientCloseCode;
        final clientOut = StreamController<Uint8List>();
        addTearDown(clientOut.close);
        final receivedSeqs = <int>[];
        final clientSub = clientOut.stream.listen((raw) {
          final msg = BufferFrameCodec.decode(raw);
          if (msg is BufferSnapshotFrame) {
            receivedSeqs.add(msg.snapshot.seq);
          } else if (msg is BufferDeltaFrame) {
            receivedSeqs.add(msg.delta.seq);
          }
        });
        addTearDown(clientSub.cancel);

        final client = burstRegistry.registerClientPeer(
          sink: clientOut.sink,
          closeWithCode: (code, _) async {
            clientCloseCode = code;
          },
        );
        burstRegistry.subscribeClient(
          client,
          const SubscribeSessionFrame(sessionId: sessionId, cols: 10, rows: 2),
        );

        final initialSnap = BufferFrameCodec.encode(
          BufferSnapshotFrame(
            snapshot: BufferSnapshot.fromBuffer(
              sessionId: sessionId,
              seq: 1,
              buffer: Buffer.blank(10, 2),
              cursor: CursorState.origin,
              modes: TerminalModes.defaults,
            ),
          ),
        );
        final preEncodedDeltas = <Uint8List>[
          for (var seq = 2; seq <= 200; seq++)
            BufferFrameCodec.encode(
              BufferDeltaFrame(
                delta: BufferDelta(
                  sessionId: sessionId,
                  seq: seq,
                  baseSeq: seq - 1,
                  cols: 10,
                  rows: 2,
                  cursor: CursorState.origin,
                  modes: TerminalModes.defaults,
                  runs: const [],
                ),
              ),
            ),
        ];

        // Enqueue 200 frames in a single synchronous loop (> maxOutboundFrames = 64).
        check(
          burstRegistry.forwardCasterBufferBytes(caster, initialSnap),
        ).isTrue();
        for (final deltaBytes in preEncodedDeltas) {
          check(
            burstRegistry.forwardCasterBufferBytes(caster, deltaBytes),
          ).isTrue();
        }
        await pumpEventQueue();

        check(clientCloseCode).isNull();
        check(burstRegistry.connectedClientCount).equals(1);
        check(receivedSeqs).length.equals(200);
        check(receivedSeqs.first).equals(1);
        check(receivedSeqs.last).equals(200);
      },
    );

    test(
      'forwards ClipboardFrame from caster to subscribed clients and rejects mismatched sessionId',
      () async {
        const sessionId = SessionId('sess-clip');
        final casterPipe = StreamChannelController<Uint8List>();
        int? casterCloseCode;
        handler.attachCasterChannel(
          casterPipe.foreign,
          closeWithCode: (code, _) async => casterCloseCode = code,
        );
        final casterSub = casterPipe.local.stream.listen((_) {});
        addTearDown(casterSub.cancel);

        casterPipe.local.sink.add(
          BufferFrameCodec.encode(const AuthFrame(role: .caster, token: '')),
        );
        casterPipe.local.sink.add(
          BufferFrameCodec.encode(
            const RegisterSessionFrame(
              sessionId: sessionId,
              title: 'tmux',
              cols: 80,
              rows: 24,
            ),
          ),
        );
        await pumpEventQueue();

        final viewerPipe = StreamChannelController<Uint8List>();
        handler.attachClientChannel(viewerPipe.foreign);
        final viewerInbox = <CastMessage>[];
        final viewerSub = viewerPipe.local.stream.listen(
          (b) => viewerInbox.add(BufferFrameCodec.decode(b)),
        );
        addTearDown(viewerSub.cancel);

        viewerPipe.local.sink.add(
          BufferFrameCodec.encode(const AuthFrame(role: .client, token: '')),
        );
        viewerPipe.local.sink.add(
          BufferFrameCodec.encode(
            const SubscribeSessionFrame(
              sessionId: sessionId,
              cols: 80,
              rows: 24,
            ),
          ),
        );
        await pumpEventQueue();

        casterPipe.local.sink.add(
          BufferFrameCodec.encode(
            const ClipboardFrame(sessionId: sessionId, text: 'yanked text'),
          ),
        );
        casterPipe.local.sink.add(
          BufferFrameCodec.encode(
            const ClipboardFrame(sessionId: sessionId, readBlocked: true),
          ),
        );
        await pumpEventQueue();

        final clipFrames = [...viewerInbox.whereType<ClipboardFrame>()];
        check(clipFrames).length.equals(2);
        check(clipFrames[0].text).equals('yanked text');
        check(clipFrames[0].readBlocked).isFalse();
        check(clipFrames[1].readBlocked).isTrue();

        // Spoofed sessionId from caster is rejected with 1008.
        casterPipe.local.sink.add(
          BufferFrameCodec.encode(
            const ClipboardFrame(
              sessionId: SessionId('other-sess'),
              text: 'spoof',
            ),
          ),
        );
        await pumpEventQueue();
        check(casterCloseCode).equals(1008);
      },
    );

    test(
      'forwardCasterClipboard forwards provided rawBytes zero-copy without re-encoding',
      () async {
        const sessionId = SessionId('sess-raw-clip');
        final casterOut = StreamController<Uint8List>();
        addTearDown(casterOut.close);
        final casterSub = casterOut.stream.listen((_) {});
        addTearDown(casterSub.cancel);
        final caster = registry.registerCasterPeer(sink: casterOut.sink);
        registry.registerSession(
          caster,
          const RegisterSessionFrame(
            sessionId: sessionId,
            title: 'nvim',
            cols: 80,
            rows: 24,
          ),
        );

        final clientOut = StreamController<Uint8List>();
        addTearDown(clientOut.close);
        final receivedRaw = <Uint8List>[];
        final clientSub = clientOut.stream.listen(receivedRaw.add);
        addTearDown(clientSub.cancel);
        final client = registry.registerClientPeer(sink: clientOut.sink);
        registry.subscribeClient(
          client,
          const SubscribeSessionFrame(sessionId: sessionId, cols: 80, rows: 24),
        );
        await pumpEventQueue();
        receivedRaw.clear();

        const frame = ClipboardFrame(
          sessionId: sessionId,
          text: 'zero-copy payload',
        );
        final rawBytes = BufferFrameCodec.encode(frame);
        check(
          registry.forwardCasterClipboard(caster, frame, rawBytes: rawBytes),
        ).isTrue();
        await pumpEventQueue();

        check(receivedRaw).length.equals(1);
        check(identical(receivedRaw.single, rawBytes)).isTrue();

        // Mismatched sessionId still returns false even when rawBytes is passed.
        const wrongFrame = ClipboardFrame(
          sessionId: SessionId('other-sess'),
          text: 'nope',
        );
        check(
          registry.forwardCasterClipboard(
            caster,
            wrongFrame,
            rawBytes: BufferFrameCodec.encode(wrongFrame),
          ),
        ).isFalse();
      },
    );

    test(
      'unicasts ScrollbackChunkFrame only to requesting client with colliding requestIds',
      () async {
        const sessionId = SessionId('sess-scrollback');
        final casterPipe = StreamChannelController<Uint8List>();
        handler.attachCasterChannel(casterPipe.foreign);
        final casterInbox = <CastMessage>[];
        final casterSub = casterPipe.local.stream.listen((bytes) {
          casterInbox.add(BufferFrameCodec.decode(bytes));
        });
        addTearDown(casterSub.cancel);

        casterPipe.local.sink.add(
          BufferFrameCodec.encode(const AuthFrame(role: .caster, token: '')),
        );
        casterPipe.local.sink.add(
          BufferFrameCodec.encode(
            const RegisterSessionFrame(
              sessionId: sessionId,
              title: 'zsh',
              cols: 80,
              rows: 24,
            ),
          ),
        );
        await pumpEventQueue();

        final clientAPipe = StreamChannelController<Uint8List>();
        final clientBPipe = StreamChannelController<Uint8List>();
        handler.attachClientChannel(clientAPipe.foreign);
        handler.attachClientChannel(clientBPipe.foreign);
        final inboxA = <CastMessage>[];
        final inboxB = <CastMessage>[];
        addTearDown(
          clientAPipe.local.stream.listen((b) {
            inboxA.add(BufferFrameCodec.decode(b));
          }).cancel,
        );
        addTearDown(
          clientBPipe.local.stream.listen((b) {
            inboxB.add(BufferFrameCodec.decode(b));
          }).cancel,
        );

        for (final pipe in [clientAPipe, clientBPipe]) {
          pipe.local.sink.add(
            BufferFrameCodec.encode(const AuthFrame(role: .client, token: '')),
          );
          pipe.local.sink.add(
            BufferFrameCodec.encode(
              const SubscribeSessionFrame(
                sessionId: sessionId,
                cols: 80,
                rows: 24,
              ),
            ),
          );
        }
        await pumpEventQueue();
        casterInbox.clear();
        inboxA.clear();
        inboxB.clear();

        // Both clients send colliding client requestId = 7.
        clientAPipe.local.sink.add(
          BufferFrameCodec.encode(
            const RequestScrollbackFrame(
              sessionId: sessionId,
              requestId: 7,
              clearSeq: 1,
              startLine: 0,
              count: 10,
            ),
          ),
        );
        clientBPipe.local.sink.add(
          BufferFrameCodec.encode(
            const RequestScrollbackFrame(
              sessionId: sessionId,
              requestId: 7,
              clearSeq: 1,
              startLine: 20,
              count: 10,
            ),
          ),
        );
        await pumpEventQueue();

        final relayed = [...casterInbox.whereType<RequestScrollbackFrame>()];
        check(relayed).length.equals(2);
        check(
          relayed[0].requestId,
        ).not((it) => it.equals(relayed[1].requestId));

        // Caster replies only to client B's request.
        casterPipe.local.sink.add(
          BufferFrameCodec.encode(
            ScrollbackChunkFrame(
              sessionId: sessionId,
              requestId: relayed[1].requestId,
              clearSeq: 1,
              startLine: 20,
              rows: [
                EncodedScrollbackRow(
                  isWrapped: false,
                  characters: const ['B'],
                  attributes: Uint32List.fromList([0, 0, 0]),
                ),
              ],
            ),
          ),
        );
        await pumpEventQueue();

        // Client B receives its chunk with restored requestId 7; Client A receives nothing.
        check(inboxA.whereType<ScrollbackChunkFrame>()).isEmpty();
        final chunksB = [...inboxB.whereType<ScrollbackChunkFrame>()];
        check(chunksB).length.equals(1);
        check(chunksB.single.requestId).equals(7);
        check(chunksB.single.startLine).equals(20);
        check(chunksB.single.rows.single.characters).deepEquals(['B']);
      },
    );

    test(
      'caps in-flight scrollback requests at 4 per client and drops late chunks after unsubscribe',
      () async {
        const sessionId = SessionId('sess-flood');
        final casterOut = StreamController<Uint8List>();
        addTearDown(casterOut.close);
        final casterMessages = <CastMessage>[];
        addTearDown(
          casterOut.stream.listen((b) {
            casterMessages.add(BufferFrameCodec.decode(b));
          }).cancel,
        );
        final caster = registry.registerCasterPeer(sink: casterOut.sink);
        registry.registerSession(
          caster,
          const RegisterSessionFrame(
            sessionId: sessionId,
            title: 'zsh',
            cols: 80,
            rows: 24,
          ),
        );

        final clientOut = StreamController<Uint8List>();
        addTearDown(clientOut.close);
        final clientMessages = <CastMessage>[];
        addTearDown(
          clientOut.stream.listen((b) {
            clientMessages.add(BufferFrameCodec.decode(b));
          }).cancel,
        );
        final client = registry.registerClientPeer(sink: clientOut.sink);
        registry.subscribeClient(
          client,
          const SubscribeSessionFrame(sessionId: sessionId, cols: 80, rows: 24),
        );
        await pumpEventQueue();
        casterMessages.clear();

        // 4 requests succeed, 5th & 6th are dropped by per-client cap.
        for (var i = 1; i <= 6; i++) {
          final accepted = registry.forwardScrollbackRequest(
            client,
            RequestScrollbackFrame(
              sessionId: sessionId,
              requestId: i,
              clearSeq: 0,
              startLine: 0,
              count: 16,
            ),
          );
          check(accepted).equals(i <= 4);
        }
        await pumpEventQueue();

        final forwarded = [
          ...casterMessages.whereType<RequestScrollbackFrame>(),
        ];
        check(forwarded).length.equals(4);

        // Unsubscribe client before caster replies; late chunk is silently dropped.
        registry.unsubscribeClient(client, sessionId);
        clientMessages.clear();
        check(
          registry.forwardCasterScrollbackChunk(
            caster,
            ScrollbackChunkFrame(
              sessionId: sessionId,
              requestId: forwarded.first.requestId,
              clearSeq: 0,
              startLine: 0,
              rows: const [],
            ),
          ),
        ).isTrue();
        await pumpEventQueue();
        check(clientMessages.whereType<ScrollbackChunkFrame>()).isEmpty();
      },
    );

    test(
      'lazily expires unanswered scrollback requests after 10s so fresh requests succeed',
      () async {
        var now = DateTime.utc(2026, 1, 1);
        final timedRegistry = SessionRegistry(
          maxOutboundFrames: 8,
          maxOutboundBytes: 65536,
          clock: Clock(() => now),
        );
        addTearDown(timedRegistry.close);

        const sessionId = SessionId('sess-expire');
        final casterOut = StreamController<Uint8List>();
        addTearDown(casterOut.close);
        final casterMessages = <CastMessage>[];
        addTearDown(
          casterOut.stream.listen((b) {
            casterMessages.add(BufferFrameCodec.decode(b));
          }).cancel,
        );
        final caster = timedRegistry.registerCasterPeer(sink: casterOut.sink);
        timedRegistry.registerSession(
          caster,
          const RegisterSessionFrame(
            sessionId: sessionId,
            title: 'zsh',
            cols: 80,
            rows: 24,
          ),
        );

        final clientOut = StreamController<Uint8List>();
        addTearDown(clientOut.close);
        final clientMessages = <CastMessage>[];
        addTearDown(
          clientOut.stream.listen((b) {
            clientMessages.add(BufferFrameCodec.decode(b));
          }).cancel,
        );
        final client = timedRegistry.registerClientPeer(sink: clientOut.sink);
        timedRegistry.subscribeClient(
          client,
          const SubscribeSessionFrame(sessionId: sessionId, cols: 80, rows: 24),
        );
        await pumpEventQueue();
        casterMessages.clear();

        // Fill all 4 in-flight slots at t = 0s; caster never answers them.
        for (var i = 1; i <= 4; i++) {
          check(
            timedRegistry.forwardScrollbackRequest(
              client,
              RequestScrollbackFrame(
                sessionId: sessionId,
                requestId: i,
                clearSeq: 0,
                startLine: i * 10,
                count: 10,
              ),
            ),
          ).isTrue();
        }
        await pumpEventQueue();
        final staleBatch = [
          ...casterMessages.whereType<RequestScrollbackFrame>(),
        ];
        check(staleBatch).length.equals(4);

        // At t = 9s (before 10s timeout), all 4 slots are still occupied.
        now = now.add(const Duration(seconds: 9));
        check(
          timedRegistry.forwardScrollbackRequest(
            client,
            const RequestScrollbackFrame(
              sessionId: sessionId,
              requestId: 99,
              clearSeq: 0,
              startLine: 0,
              count: 10,
            ),
          ),
        ).isFalse();

        // Advance to t = 10s: lazy eviction reclaims all 4 expired slots and
        // allows 4 fresh requests through.
        casterMessages.clear();
        now = now.add(const Duration(seconds: 1));
        for (var i = 101; i <= 105; i++) {
          final accepted = timedRegistry.forwardScrollbackRequest(
            client,
            RequestScrollbackFrame(
              sessionId: sessionId,
              requestId: i,
              clearSeq: 0,
              startLine: 0,
              count: 10,
            ),
          );
          check(accepted).equals(i <= 104);
        }
        await pumpEventQueue();

        final freshBatch = [
          ...casterMessages.whereType<RequestScrollbackFrame>(),
        ];
        check(freshBatch).length.equals(4);

        // A late chunk for an already-evicted relayReqId is ignored cleanly
        // without delivering stale data or corrupting the in-flight counter.
        clientMessages.clear();
        check(
          timedRegistry.forwardCasterScrollbackChunk(
            caster,
            ScrollbackChunkFrame(
              sessionId: sessionId,
              requestId: staleBatch.first.requestId,
              clearSeq: 0,
              startLine: 10,
              rows: const [],
            ),
          ),
        ).isTrue();
        await pumpEventQueue();
        check(clientMessages.whereType<ScrollbackChunkFrame>()).isEmpty();
        check(
          timedRegistry.forwardScrollbackRequest(
            client,
            const RequestScrollbackFrame(
              sessionId: sessionId,
              requestId: 200,
              clearSeq: 0,
              startLine: 0,
              count: 10,
            ),
          ),
        ).isFalse();

        // Answering one fresh request frees exactly one slot and delivers clientReqId 101.
        check(
          timedRegistry.forwardCasterScrollbackChunk(
            caster,
            ScrollbackChunkFrame(
              sessionId: sessionId,
              requestId: freshBatch.first.requestId,
              clearSeq: 0,
              startLine: 0,
              rows: const [],
            ),
          ),
        ).isTrue();
        await pumpEventQueue();
        final chunks = [...clientMessages.whereType<ScrollbackChunkFrame>()];
        check(chunks).length.equals(1);
        check(chunks.single.requestId).equals(101);
        check(
          timedRegistry.forwardScrollbackRequest(
            client,
            const RequestScrollbackFrame(
              sessionId: sessionId,
              requestId: 201,
              clearSeq: 0,
              startLine: 0,
              count: 10,
            ),
          ),
        ).isTrue();
      },
    );

    test(
      'routes FileUploadStart/Chunk/End/Ack across colliding transferIds and enforces 1 active upload per client',
      () async {
        const sessionId = SessionId('sess-upload');
        final casterPipe = StreamChannelController<Uint8List>();
        handler.attachCasterChannel(casterPipe.foreign);
        final casterInbox = <CastMessage>[];
        addTearDown(
          casterPipe.local.stream.listen((b) {
            casterInbox.add(BufferFrameCodec.decode(b));
          }).cancel,
        );

        casterPipe.local.sink.add(
          BufferFrameCodec.encode(const AuthFrame(role: .caster, token: '')),
        );
        casterPipe.local.sink.add(
          BufferFrameCodec.encode(
            const RegisterSessionFrame(
              sessionId: sessionId,
              title: 'zsh',
              cols: 80,
              rows: 24,
            ),
          ),
        );
        await pumpEventQueue();

        final clientAPipe = StreamChannelController<Uint8List>();
        final clientBPipe = StreamChannelController<Uint8List>();
        handler.attachClientChannel(clientAPipe.foreign);
        handler.attachClientChannel(clientBPipe.foreign);
        final inboxA = <CastMessage>[];
        final inboxB = <CastMessage>[];
        addTearDown(
          clientAPipe.local.stream.listen((b) {
            inboxA.add(BufferFrameCodec.decode(b));
          }).cancel,
        );
        addTearDown(
          clientBPipe.local.stream.listen((b) {
            inboxB.add(BufferFrameCodec.decode(b));
          }).cancel,
        );

        for (final pipe in [clientAPipe, clientBPipe]) {
          pipe.local.sink.add(
            BufferFrameCodec.encode(const AuthFrame(role: .client, token: '')),
          );
          pipe.local.sink.add(
            BufferFrameCodec.encode(
              const SubscribeSessionFrame(
                sessionId: sessionId,
                cols: 80,
                rows: 24,
              ),
            ),
          );
        }
        await pumpEventQueue();
        casterInbox.clear();
        inboxA.clear();
        inboxB.clear();

        // Both clients start an upload with colliding client transferId = 42.
        clientAPipe.local.sink.add(
          BufferFrameCodec.encode(
            const FileUploadStartFrame(
              sessionId: sessionId,
              transferId: 42,
              fileName: 'a.txt',
              totalBytes: 4,
            ),
          ),
        );
        clientBPipe.local.sink.add(
          BufferFrameCodec.encode(
            const FileUploadStartFrame(
              sessionId: sessionId,
              transferId: 42,
              fileName: 'b.txt',
              totalBytes: 4,
            ),
          ),
        );
        // Client A attempts a second concurrent upload while transferId=42 is active;
        // relay immediately rejects transferId=43 without forwarding to caster.
        clientAPipe.local.sink.add(
          BufferFrameCodec.encode(
            const FileUploadStartFrame(
              sessionId: sessionId,
              transferId: 43,
              fileName: 'extra.txt',
              totalBytes: 4,
            ),
          ),
        );
        await pumpEventQueue();

        final starts = [...casterInbox.whereType<FileUploadStartFrame>()];
        check(starts).length.equals(2);
        check(
          starts[0].transferId,
        ).not((it) => it.equals(starts[1].transferId));

        final rejectedA = [...inboxA.whereType<FileUploadAckFrame>()];
        check(rejectedA).length.equals(1);
        check(rejectedA.single.transferId).equals(43);
        check(rejectedA.single.status).equals(FileUploadStatus.rejected);
        inboxA.clear();

        // Caster sends ready + chunkAck + completed for client A's relay transferId.
        final relayIdA = starts[0].transferId;
        casterPipe.local.sink.add(
          BufferFrameCodec.encode(
            FileUploadAckFrame(
              sessionId: sessionId,
              transferId: relayIdA,
              status: .ready,
              nextOffset: 0,
            ),
          ),
        );
        await pumpEventQueue();
        check(inboxB.whereType<FileUploadAckFrame>()).isEmpty();
        check(
          inboxA.whereType<FileUploadAckFrame>().single.transferId,
        ).equals(42);
        inboxA.clear();
        casterInbox.clear();

        // Client A sends Chunk and End using its local transferId=42; relay rewrites to relayIdA.
        clientAPipe.local.sink.add(
          BufferFrameCodec.encode(
            FileUploadChunkFrame(
              sessionId: sessionId,
              transferId: 42,
              offset: 0,
              data: Uint8List.fromList([1, 2, 3, 4]),
            ),
          ),
        );
        clientAPipe.local.sink.add(
          BufferFrameCodec.encode(
            FileUploadEndFrame(
              sessionId: sessionId,
              transferId: 42,
              sha256: Uint8List(32),
            ),
          ),
        );
        await pumpEventQueue();

        final relayedChunk = casterInbox
            .whereType<FileUploadChunkFrame>()
            .single;
        final relayedEnd = casterInbox.whereType<FileUploadEndFrame>().single;
        check(relayedChunk.transferId).equals(relayIdA);
        check(relayedEnd.transferId).equals(relayIdA);

        // Caster completes client A's upload; slot is freed so client A can start another.
        casterPipe.local.sink.add(
          BufferFrameCodec.encode(
            FileUploadAckFrame(
              sessionId: sessionId,
              transferId: relayIdA,
              status: .completed,
              nextOffset: 4,
              message: '/tmp/a.txt',
            ),
          ),
        );
        await pumpEventQueue();
        final completedA = inboxA.whereType<FileUploadAckFrame>().single;
        check(completedA.transferId).equals(42);
        check(completedA.status).equals(FileUploadStatus.completed);
        check(completedA.message).equals('/tmp/a.txt');

        // Client B unsubscribes mid-upload; relay automatically sends FileUploadEndFrame(aborted: true) to caster.
        casterInbox.clear();
        clientBPipe.local.sink.add(
          BufferFrameCodec.encode(
            const UnsubscribeSessionFrame(sessionId: sessionId),
          ),
        );
        await pumpEventQueue();
        final abortedEnd = casterInbox.whereType<FileUploadEndFrame>().single;
        check(abortedEnd.transferId).equals(starts[1].transferId);
        check(abortedEnd.aborted).isTrue();
      },
    );

    test(
      'refreshes upload idle timeout on chunks and aborts stalled uploads after 30s idle',
      () async {
        var now = DateTime.utc(2026, 1, 1);
        final timedRegistry = SessionRegistry(
          maxOutboundFrames: 16,
          maxOutboundBytes: 65536,
          clock: Clock(() => now),
        );
        addTearDown(timedRegistry.close);

        const sessionId = SessionId('sess-upload-idle');
        final casterOut = StreamController<Uint8List>();
        addTearDown(casterOut.close);
        final casterMessages = <CastMessage>[];
        addTearDown(
          casterOut.stream.listen((b) {
            casterMessages.add(BufferFrameCodec.decode(b));
          }).cancel,
        );
        final caster = timedRegistry.registerCasterPeer(sink: casterOut.sink);
        timedRegistry.registerSession(
          caster,
          const RegisterSessionFrame(
            sessionId: sessionId,
            title: 'zsh',
            cols: 80,
            rows: 24,
          ),
        );

        final clientOut = StreamController<Uint8List>();
        addTearDown(clientOut.close);
        final clientMessages = <CastMessage>[];
        addTearDown(
          clientOut.stream.listen((b) {
            clientMessages.add(BufferFrameCodec.decode(b));
          }).cancel,
        );
        final client = timedRegistry.registerClientPeer(sink: clientOut.sink);
        timedRegistry.subscribeClient(
          client,
          const SubscribeSessionFrame(sessionId: sessionId, cols: 80, rows: 24),
        );
        await pumpEventQueue();
        casterMessages.clear();

        check(
          timedRegistry.forwardFileUploadStart(
            client,
            const FileUploadStartFrame(
              sessionId: sessionId,
              transferId: 1,
              fileName: 'big.bin',
              totalBytes: 8,
            ),
          ),
        ).isTrue();
        await pumpEventQueue();
        final relayId = casterMessages
            .whereType<FileUploadStartFrame>()
            .single
            .transferId;

        // Advance 20s and send a chunk; idle expiry refreshes to t = 50s.
        now = now.add(const Duration(seconds: 20));
        check(
          timedRegistry.forwardFileUploadChunk(
            client,
            FileUploadChunkFrame(
              sessionId: sessionId,
              transferId: 1,
              offset: 0,
              data: Uint8List.fromList([1, 2, 3, 4]),
            ),
          ),
        ).isTrue();

        // At t = 40s (20s since last chunk < 30s idle), transfer is still alive.
        now = now.add(const Duration(seconds: 20));
        check(
          timedRegistry.forwardFileUploadChunk(
            client,
            FileUploadChunkFrame(
              sessionId: sessionId,
              transferId: 1,
              offset: 4,
              data: Uint8List.fromList([5, 6, 7, 8]),
            ),
          ),
        ).isTrue();

        // Advance 30s without activity (t = 70s); next upload operation evicts
        // the stalled transfer and emits FileUploadEndFrame(aborted: true) to caster.
        casterMessages.clear();
        now = now.add(const Duration(seconds: 30));
        check(
          timedRegistry.forwardFileUploadStart(
            client,
            const FileUploadStartFrame(
              sessionId: sessionId,
              transferId: 2,
              fileName: 'fresh.bin',
              totalBytes: 4,
            ),
          ),
        ).isTrue();
        await pumpEventQueue();

        final aborted = casterMessages.whereType<FileUploadEndFrame>().single;
        check(aborted.transferId).equals(relayId);
        check(aborted.aborted).isTrue();
        check(
          casterMessages.whereType<FileUploadStartFrame>().single.fileName,
        ).equals('fresh.bin');
      },
    );

    test(
      'detachClientPeer notifies unsubscribed sessions with SubscriberCountFrame(0) when the last viewer client disconnects',
      () async {
        const activeId = SessionId('sess-active-tab');
        const idleId = SessionId('sess-background-tab');

        final activeCasterPipe = StreamChannelController<Uint8List>();
        final idleCasterPipe = StreamChannelController<Uint8List>();
        handler.attachCasterChannel(activeCasterPipe.foreign);
        handler.attachCasterChannel(idleCasterPipe.foreign);

        final activeCasterInbox = <CastMessage>[];
        final idleCasterInbox = <CastMessage>[];
        addTearDown(
          activeCasterPipe.local.stream.listen((b) {
            activeCasterInbox.add(BufferFrameCodec.decode(b));
          }).cancel,
        );
        addTearDown(
          idleCasterPipe.local.stream.listen((b) {
            idleCasterInbox.add(BufferFrameCodec.decode(b));
          }).cancel,
        );

        for (final (pipe, id) in [
          (activeCasterPipe, activeId),
          (idleCasterPipe, idleId),
        ]) {
          pipe.local.sink.add(
            BufferFrameCodec.encode(const AuthFrame(role: .caster, token: '')),
          );
          pipe.local.sink.add(
            BufferFrameCodec.encode(
              RegisterSessionFrame(
                sessionId: id,
                title: id.value,
                cols: 80,
                rows: 24,
              ),
            ),
          );
        }
        await pumpEventQueue();

        // Two viewer clients connect; only client 1 subscribes to activeId, while idleId has 0 subscribers.
        final client1 = StreamChannelController<Uint8List>();
        final client2 = StreamChannelController<Uint8List>();
        handler.attachClientChannel(client1.foreign);
        handler.attachClientChannel(client2.foreign);
        addTearDown(client1.local.stream.listen((_) {}).cancel);
        addTearDown(client2.local.stream.listen((_) {}).cancel);

        client1.local.sink.add(
          BufferFrameCodec.encode(const AuthFrame(role: .client, token: '')),
        );
        client2.local.sink.add(
          BufferFrameCodec.encode(const AuthFrame(role: .client, token: '')),
        );
        client1.local.sink.add(
          BufferFrameCodec.encode(
            const SubscribeSessionFrame(
              sessionId: activeId,
              cols: 80,
              rows: 24,
            ),
          ),
        );
        await pumpEventQueue();

        activeCasterInbox.clear();
        idleCasterInbox.clear();

        // Disconnect client 2 while client 1 is still connected -> neither caster gets SubscriberCountFrame(0).
        await client2.local.sink.close();
        await pumpEventQueue();
        check(activeCasterInbox.whereType<SubscriberCountFrame>()).isEmpty();
        check(idleCasterInbox.whereType<SubscriberCountFrame>()).isEmpty();

        // Disconnect the last viewer (client 1) -> BOTH activeId and unsubscribed idleId receive SubscriberCountFrame(0) exactly once!
        await client1.local.sink.close();
        await pumpEventQueue();

        final activeCounts = [
          ...activeCasterInbox.whereType<SubscriberCountFrame>(),
        ];
        final idleCounts = [
          ...idleCasterInbox.whereType<SubscriberCountFrame>(),
        ];
        check(activeCounts).length.equals(1);
        check(activeCounts.single.subscriberCount).equals(0);
        check(idleCounts).length.equals(1);
        check(idleCounts.single.subscriberCount).equals(0);
      },
    );

    test(
      'drops input with caster_busy and aborts upload at 75% caster outbound high-water mark without evicting client or caster',
      () async {
        final hwmRegistry = SessionRegistry(
          maxOutboundFrames: 64,
          maxOutboundBytes: 8 * 1024 * 1024,
        );
        addTearDown(hwmRegistry.close);

        const sessionId = SessionId('sess-caster-hwm');
        int? casterCloseCode;
        final casterOut = StreamController<Uint8List>();
        addTearDown(casterOut.close);
        final casterSub = casterOut.stream.listen((_) {});
        addTearDown(casterSub.cancel);
        final caster = hwmRegistry.registerCasterPeer(
          sink: casterOut.sink,
          closeWithCode: (code, _) async => casterCloseCode = code,
        );
        hwmRegistry.registerSession(
          caster,
          const RegisterSessionFrame(
            sessionId: sessionId,
            title: 'zsh',
            cols: 80,
            rows: 24,
          ),
        );

        int? noisyInputCloseCode;
        final noisyInputFrames = <CastMessage>[];
        final noisyInputOut = StreamController<Uint8List>();
        addTearDown(noisyInputOut.close);
        addTearDown(
          noisyInputOut.stream
              .listen(
                (raw) => noisyInputFrames.add(BufferFrameCodec.decode(raw)),
              )
              .cancel,
        );
        final noisyInputClient = hwmRegistry.registerClientPeer(
          sink: noisyInputOut.sink,
          closeWithCode: (code, _) async => noisyInputCloseCode = code,
        );
        hwmRegistry.subscribeClient(
          noisyInputClient,
          const SubscribeSessionFrame(sessionId: sessionId, cols: 80, rows: 24),
        );

        int? noisyUploadCloseCode;
        final noisyUploadFrames = <CastMessage>[];
        final noisyUploadOut = StreamController<Uint8List>();
        addTearDown(noisyUploadOut.close);
        addTearDown(
          noisyUploadOut.stream
              .listen(
                (raw) => noisyUploadFrames.add(BufferFrameCodec.decode(raw)),
              )
              .cancel,
        );
        final noisyUploadClient = hwmRegistry.registerClientPeer(
          sink: noisyUploadOut.sink,
          closeWithCode: (code, _) async => noisyUploadCloseCode = code,
        );
        hwmRegistry.subscribeClient(
          noisyUploadClient,
          const SubscribeSessionFrame(sessionId: sessionId, cols: 80, rows: 24),
        );
        check(
          hwmRegistry.forwardFileUploadStart(
            noisyUploadClient,
            const FileUploadStartFrame(
              sessionId: sessionId,
              transferId: 1,
              fileName: 'big.bin',
              totalBytes: 1024,
            ),
          ),
        ).isTrue();
        await pumpEventQueue();
        noisyInputFrames.clear();
        noisyUploadFrames.clear();

        // Pause the caster's outbound stream and send 48 InputFrames to reach the 75% high-water mark (48/64).
        casterSub.pause();
        for (var i = 0; i < 48; i++) {
          hwmRegistry.forwardClientInput(
            noisyInputClient,
            InputFrame(sessionId: sessionId, data: Uint8List.fromList([0x61])),
          );
        }
        check(caster.queuedFrames).equals(48);
        check(casterCloseCode).isNull();
        check(noisyInputCloseCode).isNull();

        // 49th InputFrame hits the 75% high-water mark, drops input, and sends ErrorFrame('caster_busy') without evicting noisyInputClient!
        hwmRegistry.forwardClientInput(
          noisyInputClient,
          InputFrame(sessionId: sessionId, data: Uint8List.fromList([0x62])),
        );
        await pumpEventQueue();
        check(noisyInputCloseCode).isNull();
        check(casterCloseCode).isNull();
        check(caster.queuedFrames).equals(48);
        check(noisyInputFrames).length.equals(1);
        final busyError = noisyInputFrames.single as ErrorFrame;
        check(busyError.code).equals('caster_busy');

        // FileUploadChunkFrame while caster is still >= 48 queued frames aborts upload and sends FileUploadAckFrame(status: .rejected) without evicting noisyUploadClient!
        check(
          hwmRegistry.forwardFileUploadChunk(
            noisyUploadClient,
            FileUploadChunkFrame(
              sessionId: sessionId,
              transferId: 1,
              offset: 0,
              data: Uint8List.fromList([1, 2, 3, 4]),
            ),
          ),
        ).isFalse();
        await pumpEventQueue();
        check(noisyUploadCloseCode).isNull();
        check(casterCloseCode).isNull();
        check(noisyUploadFrames).length.equals(1);
        final uploadReject = noisyUploadFrames.single as FileUploadAckFrame;
        check(uploadReject.status).equals(FileUploadStatus.rejected);
        check(uploadReject.transferId).equals(1);
        check(hwmRegistry.connectedClientCount).equals(2);
        check(hwmRegistry.sessions).length.equals(1);
      },
    );

    _registerDroppableFanOutTest(() => handler);
    _registerUnsubscribedTitleBurstTest(() => handler);
  });
}

void _registerDroppableFanOutTest(WsRelayHandler Function() getHandler) {
  test(
    'fans out BellFrame, AudioFrame, and ShellTitleFrame and drops droppable/directory frames under outbound pressure without 1008 eviction',
    () async {
      final handler = getHandler();
      const sessionId = SessionId('sess-audio-pressure');
      final casterPipe = StreamChannelController<Uint8List>();
      handler.attachCasterChannel(casterPipe.foreign);
      final casterInbox = <CastMessage>[];
      final casterSub = casterPipe.local.stream.listen(
        (b) => casterInbox.add(BufferFrameCodec.decode(b)),
      );
      addTearDown(casterSub.cancel);

      casterPipe.local.sink.add(
        BufferFrameCodec.encode(const AuthFrame(role: .caster, token: '')),
      );
      casterPipe.local.sink.add(
        BufferFrameCodec.encode(
          const RegisterSessionFrame(
            sessionId: sessionId,
            title: 'audio',
            cols: 20,
            rows: 4,
          ),
        ),
      );

      int? slowCloseCode;
      final slowIn = StreamController<Uint8List>();
      final slowOut = StreamController<Uint8List>();
      final slowLocal = StreamChannel<Uint8List>(slowOut.stream, slowIn.sink);
      final slowForeign = StreamChannel<Uint8List>(slowIn.stream, slowOut.sink);
      handler.attachClientChannel(
        slowForeign,
        closeWithCode: (code, _) async {
          slowCloseCode = code;
          unawaited(slowOut.close());
        },
      );
      final slowInbox = <CastMessage>[];
      final slowSub = slowLocal.stream.listen(
        (b) => slowInbox.add(BufferFrameCodec.decode(b)),
      );
      addTearDown(slowSub.cancel);
      addTearDown(slowIn.close);

      final fastPipe = StreamChannelController<Uint8List>();
      handler.attachClientChannel(fastPipe.foreign);
      final fastInbox = <CastMessage>[];
      addTearDown(
        fastPipe.local.stream
            .listen((b) => fastInbox.add(BufferFrameCodec.decode(b)))
            .cancel,
      );

      for (final ch in [slowLocal, fastPipe.local]) {
        ch.sink.add(
          BufferFrameCodec.encode(const AuthFrame(role: .client, token: '')),
        );
        ch.sink.add(
          BufferFrameCodec.encode(
            const SubscribeSessionFrame(sessionId: sessionId),
          ),
        );
      }
      await pumpEventQueue();
      slowInbox.clear();
      fastInbox.clear();

      // Normal BellFrame delivery works for both unpressured viewers.
      casterPipe.local.sink.add(
        BufferFrameCodec.encode(const BellFrame(sessionId: sessionId)),
      );
      await pumpEventQueue();
      check(slowInbox.whereType<BellFrame>()).length.equals(1);
      check(fastInbox.whereType<BellFrame>()).length.equals(1);
      slowInbox.clear();
      fastInbox.clear();

      // Pause slow viewer and enqueue 6 snapshots to reach 75% of maxOutboundFrames (6/8) without evicting!
      slowSub.pause();
      final buf = Buffer.blank(20, 4);
      for (var seq = 1; seq <= 6; seq++) {
        casterPipe.local.sink.add(
          BufferFrameCodec.encode(
            BufferSnapshotFrame(
              snapshot: BufferSnapshot.fromBuffer(
                sessionId: sessionId,
                seq: seq,
                buffer: buf,
                cursor: CursorState.origin,
                modes: TerminalModes.defaults,
              ),
            ),
          ),
        );
      }
      await pumpEventQueue();

      // Burst 20 BellFrames + 20 AudioFrames + 20 ShellTitleFrames; slow viewer drops all cleanly without 1008 eviction while fast viewer gets all!
      for (var i = 0; i < 20; i++) {
        casterPipe.local.sink.add(
          BufferFrameCodec.encode(const BellFrame(sessionId: sessionId)),
        );
        casterPipe.local.sink.add(
          BufferFrameCodec.encode(
            AudioFrame(
              sessionId: sessionId,
              payload: CastToneAudioPayload(
                waveform: 'sine',
                frequencyHz: 440.0 + i,
                duration: const Duration(milliseconds: 25),
              ),
            ),
          ),
        );
        casterPipe.local.sink.add(
          BufferFrameCodec.encode(
            ShellTitleFrame(sessionId: sessionId, title: 'spin-$i'),
          ),
        );
      }
      await pumpEventQueue();

      check(slowCloseCode).isNull();
      check(fastInbox.whereType<BellFrame>()).length.equals(20);
      check(fastInbox.whereType<AudioFrame>()).length.equals(20);
      check(fastInbox.whereType<ShellTitleFrame>()).length.equals(20);

      slowSub.resume();
      await pumpEventQueue();
      check(slowCloseCode).isNull();
      check(slowInbox.whereType<BellFrame>()).isEmpty();
      check(slowInbox.whereType<AudioFrame>()).isEmpty();
      check(slowInbox.whereType<ShellTitleFrame>()).isEmpty();

      // Forward subscribed client AudioWaveformReplyFrame to caster, ignore unsubscribed, and drop under caster outbound pressure.
      final samples = Float32List.fromList(
        List<double>.generate(256, (i) => i / 256.0),
      );

      // Unsubscribed client frame is dropped.
      final unsubPipe = StreamChannelController<Uint8List>();
      handler.attachClientChannel(unsubPipe.foreign);
      addTearDown(unsubPipe.local.stream.listen((_) {}).cancel);
      unsubPipe.local.sink.add(
        BufferFrameCodec.encode(const AuthFrame(role: .client, token: '')),
      );
      await pumpEventQueue();
      casterInbox.clear();
      unsubPipe.local.sink.add(
        BufferFrameCodec.encode(
          AudioWaveformReplyFrame(
            sessionId: sessionId,
            requestId: 10,
            samples: samples,
          ),
        ),
      );
      await pumpEventQueue();
      check(casterInbox.whereType<AudioWaveformReplyFrame>()).isEmpty();

      // Subscribed client frame forwards cleanly to caster.
      fastPipe.local.sink.add(
        BufferFrameCodec.encode(
          AudioWaveformReplyFrame(
            sessionId: sessionId,
            requestId: 11,
            samples: samples,
          ),
        ),
      );
      await pumpEventQueue();
      final forwarded = casterInbox.whereType<AudioWaveformReplyFrame>().single;
      check(forwarded.requestId).equals(11);
      check(forwarded.samples[128]).isCloseTo(0.5, 1e-6);

      // Pressured caster drops AudioWaveformReplyFrame cleanly without evicting caster.
      final pReg = SessionRegistry(
        maxOutboundFrames: 8,
        maxOutboundBytes: 65536,
      );
      addTearDown(pReg.close);
      int? pCasterClose;
      final pCasterOut = StreamController<Uint8List>();
      addTearDown(pCasterOut.close);
      final pCasterInbox = <CastMessage>[];
      final pCasterSub = pCasterOut.stream.listen(
        (raw) => pCasterInbox.add(BufferFrameCodec.decode(raw)),
      );
      addTearDown(pCasterSub.cancel);
      final pCaster = pReg.registerCasterPeer(
        sink: pCasterOut.sink,
        closeWithCode: (code, _) async => pCasterClose = code,
      );
      pReg.registerSession(
        pCaster,
        const RegisterSessionFrame(
          sessionId: sessionId,
          title: 'wave-pressure',
          cols: 20,
          rows: 4,
        ),
      );
      final pClientOut = StreamController<Uint8List>();
      addTearDown(pClientOut.close);
      addTearDown(pClientOut.stream.listen((_) {}).cancel);
      final pClient = pReg.registerClientPeer(sink: pClientOut.sink);
      pReg.subscribeClient(
        pClient,
        const SubscribeSessionFrame(sessionId: sessionId),
      );
      await pumpEventQueue();
      pCasterInbox.clear();

      pCasterSub.pause();
      for (var i = 0; i < 6; i++) {
        pReg.forwardClientInput(
          pClient,
          InputFrame(sessionId: sessionId, data: Uint8List.fromList([65 + i])),
        );
      }
      check(pCaster.queuedFrames).equals(6);
      check(
        pReg.forwardClientWaveformReply(
          pClient,
          AudioWaveformReplyFrame(
            sessionId: sessionId,
            requestId: 12,
            samples: samples,
          ),
        ),
      ).isFalse();
      check(pCasterClose).isNull();
      pCasterSub.resume();
      await pumpEventQueue();
      check(pCasterInbox.whereType<AudioWaveformReplyFrame>()).isEmpty();
    },
  );
}

void _registerUnsubscribedTitleBurstTest(WsRelayHandler Function() getHandler) {
  test(
    'unsubscribed session title updates directory shellTitle and 200 title bursts do not 1008-evict paused viewers on another session',
    () async {
      final handler = getHandler();
      const noisyId = SessionId('sess-noisy-spinner');
      const quietId = SessionId('sess-quiet-session');
      final noisyCaster = StreamChannelController<Uint8List>();
      final quietCaster = StreamChannelController<Uint8List>();
      handler.attachCasterChannel(noisyCaster.foreign);
      handler.attachCasterChannel(quietCaster.foreign);
      addTearDown(noisyCaster.local.stream.listen((_) {}).cancel);
      addTearDown(quietCaster.local.stream.listen((_) {}).cancel);

      noisyCaster.local.sink.add(
        BufferFrameCodec.encode(const AuthFrame(role: .caster, token: '')),
      );
      noisyCaster.local.sink.add(
        BufferFrameCodec.encode(
          const RegisterSessionFrame(
            sessionId: noisyId,
            title: 'initial',
            cols: 20,
            rows: 4,
          ),
        ),
      );
      quietCaster.local.sink.add(
        BufferFrameCodec.encode(const AuthFrame(role: .caster, token: '')),
      );
      quietCaster.local.sink.add(
        BufferFrameCodec.encode(
          const RegisterSessionFrame(
            sessionId: quietId,
            title: 'quiet',
            cols: 20,
            rows: 4,
          ),
        ),
      );

      // Paused viewer subscribed ONLY to quietId (not noisyId).
      int? pausedCloseCode;
      final pausedIn = StreamController<Uint8List>();
      final pausedOut = StreamController<Uint8List>();
      final pausedLocal = StreamChannel<Uint8List>(
        pausedOut.stream,
        pausedIn.sink,
      );
      final pausedForeign = StreamChannel<Uint8List>(
        pausedIn.stream,
        pausedOut.sink,
      );
      handler.attachClientChannel(
        pausedForeign,
        closeWithCode: (code, _) async {
          pausedCloseCode = code;
          unawaited(pausedOut.close());
        },
      );
      final pausedInbox = <CastMessage>[];
      final pausedSub = pausedLocal.stream.listen(
        (b) => pausedInbox.add(BufferFrameCodec.decode(b)),
      );
      addTearDown(pausedSub.cancel);
      addTearDown(pausedIn.close);

      // Fast directory observer.
      final dirPipe = StreamChannelController<Uint8List>();
      handler.attachClientChannel(dirPipe.foreign);
      final dirInbox = <CastMessage>[];
      addTearDown(
        dirPipe.local.stream
            .listen((b) => dirInbox.add(BufferFrameCodec.decode(b)))
            .cancel,
      );

      for (final ch in [pausedLocal, dirPipe.local]) {
        ch.sink.add(
          BufferFrameCodec.encode(const AuthFrame(role: .client, token: '')),
        );
      }
      pausedLocal.sink.add(
        BufferFrameCodec.encode(
          const SubscribeSessionFrame(sessionId: quietId),
        ),
      );
      await pumpEventQueue();
      dirInbox.clear();
      pausedInbox.clear();

      // Pause viewer of quietId and pre-fill 6 frames (75% HWM) on its outbound pump.
      pausedSub.pause();
      final buf = Buffer.blank(20, 4);
      for (var seq = 1; seq <= 6; seq++) {
        quietCaster.local.sink.add(
          BufferFrameCodec.encode(
            BufferSnapshotFrame(
              snapshot: BufferSnapshot.fromBuffer(
                sessionId: quietId,
                seq: seq,
                buffer: buf,
                cursor: CursorState.origin,
                modes: TerminalModes.defaults,
              ),
            ),
          ),
        );
      }
      await pumpEventQueue();

      // Unsubscribed noisyId emits 200 rapid ShellTitleFrames.
      for (var i = 0; i < 200; i++) {
        noisyCaster.local.sink.add(
          BufferFrameCodec.encode(
            ShellTitleFrame(sessionId: noisyId, title: 'title-$i'),
          ),
        );
      }
      await pumpEventQueue();

      check(pausedCloseCode).isNull();
      final latestDir = dirInbox
          .whereType<SessionDirectoryFrame>()
          .last
          .sessions
          .firstWhere((s) => s.id == noisyId);
      check(latestDir.title).equals('title-199');

      pausedSub.resume();
      await pumpEventQueue();
      check(pausedCloseCode).isNull();
    },
  );
}
