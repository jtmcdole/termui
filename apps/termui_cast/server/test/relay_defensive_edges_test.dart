import 'dart:async';
import 'dart:typed_data';

import 'package:checks/checks.dart';
import 'package:stream_channel/stream_channel.dart';
import 'package:termui/termui.dart';
import 'package:termui_cast_protocol/termui_cast_protocol.dart';
import 'package:termui_cast_server/termui_cast_server.dart';
import 'package:test/test.dart';

void main() {
  group('WsRelayHandler and SessionRegistry defensive edges', () {
    late SessionRegistry registry;
    late WsRelayHandler handler;
    late List<String> logs;

    setUp(() {
      logs = <String>[];
      registry = SessionRegistry(
        maxOutboundFrames: 16,
        maxOutboundBytes: 65536,
      );
      handler = WsRelayHandler(
        registry: registry,
        authenticator: TokenAuthenticator(),
        onLog: logs.add,
      );
    });

    tearDown(() async {
      await registry.close();
    });

    test(
      'rejects wrong-role and malformed initial auth frames and post-auth corrupt frames',
      () async {
        // 1. Role mismatch on caster channel -> auth_role ErrorFrame + sink close.
        final wrongRole = StreamChannelController<Uint8List>();
        handler.attachCasterChannel(wrongRole.foreign);
        final wrongInbox = <CastMessage>[];
        wrongRole.local.stream.listen(
          (b) => wrongInbox.add(BufferFrameCodec.decode(b)),
        );
        wrongRole.local.sink.add(
          BufferFrameCodec.encode(const AuthFrame(role: .client, token: '')),
        );
        await pumpEventQueue();
        check(wrongInbox).any(
          (it) => it
              .isA<ErrorFrame>()
              .has((e) => e.code, 'code')
              .equals('auth_role'),
        );

        // 2. Malformed initial bytes -> bad_auth ErrorFrame + closeWithCode 1008.
        int? badAuthCode;
        final badBytes = StreamChannelController<Uint8List>();
        handler.attachClientChannel(
          badBytes.foreign,
          closeWithCode: (code, _) async {
            badAuthCode = code;
          },
        );
        final badInbox = <CastMessage>[];
        badBytes.local.stream.listen(
          (b) => badInbox.add(BufferFrameCodec.decode(b)),
        );
        badBytes.local.sink.add(Uint8List.fromList([0xFF, 0x00]));
        await pumpEventQueue();
        check(badAuthCode).equals(1008);
        check(badInbox).any(
          (it) => it
              .isA<ErrorFrame>()
              .has((e) => e.code, 'code')
              .equals('bad_auth'),
        );

        // 3. Post-auth corrupt frame evicts peer with 1008 and logs error.
        int? policyCode;
        final authed = StreamChannelController<Uint8List>();
        handler.attachClientChannel(
          authed.foreign,
          closeWithCode: (code, _) async {
            policyCode = code;
          },
        );
        final authedSub = authed.local.stream.listen((_) {});
        addTearDown(authedSub.cancel);
        authed.local.sink.add(
          BufferFrameCodec.encode(const AuthFrame(role: .client, token: '')),
        );
        await pumpEventQueue();
        check(registry.connectedClientCount).equals(1);

        authed.local.sink.add(Uint8List.fromList([0x01, 0xFE, 0xAA]));
        await pumpEventQueue();
        check(policyCode).equals(1008);
        check(registry.connectedClientCount).equals(0);
        check(logs).isNotEmpty();
      },
    );

    test(
      'handles duplicate register, unknown subscribe, keyframe requests, resize updates, unsubscribe, and SessionClosedFrame',
      () async {
        const sessionId = SessionId('sess-edges');
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
        const regFrame = RegisterSessionFrame(
          sessionId: sessionId,
          title: 'edge-sh',
          cols: 40,
          rows: 10,
        );
        casterPipe.local.sink.add(BufferFrameCodec.encode(regFrame));
        // Duplicate registration from same caster returns duplicate_session ErrorFrame.
        casterPipe.local.sink.add(BufferFrameCodec.encode(regFrame));
        await pumpEventQueue();

        check(casterInbox).any(
          (it) => it
              .isA<ErrorFrame>()
              .has((e) => e.code, 'code')
              .equals('duplicate_session'),
        );

        // Connect two clients with pause/resume exercise on clientA.
        final clientIn = StreamController<Uint8List>();
        final clientOut = StreamController<Uint8List>();
        handler.attachClientChannel(
          StreamChannel<Uint8List>(clientIn.stream, clientOut.sink),
        );
        final clientAInbox = <CastMessage>[];
        final subA = clientOut.stream.listen(
          (b) => clientAInbox.add(BufferFrameCodec.decode(b)),
        );
        addTearDown(subA.cancel);
        addTearDown(clientIn.close);

        final clientB = StreamChannelController<Uint8List>();
        handler.attachClientChannel(clientB.foreign);
        final subB = clientB.local.stream.listen((_) {});
        addTearDown(subB.cancel);

        clientIn.sink.add(
          BufferFrameCodec.encode(const AuthFrame(role: .client, token: '')),
        );
        clientB.local.sink.add(
          BufferFrameCodec.encode(const AuthFrame(role: .client, token: '')),
        );
        await pumpEventQueue();

        // Pause and resume clientA's outbound stream while subscribing to an unknown session.
        subA.pause(Future<void>.delayed(const Duration(milliseconds: 10)));
        clientIn.sink.add(
          BufferFrameCodec.encode(
            const SubscribeSessionFrame(sessionId: SessionId('missing')),
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 25));
        await pumpEventQueue();
        check(clientAInbox).any(
          (it) => it
              .isA<ErrorFrame>()
              .has((e) => e.code, 'code')
              .equals('unknown_session'),
        );

        // Subscribe both clients to sess-edges, deliver initial snapshot, request keyframe (coalescing duplicate), then unsubscribe clientA.
        clientIn.sink.add(
          BufferFrameCodec.encode(
            const SubscribeSessionFrame(sessionId: sessionId),
          ),
        );
        clientB.local.sink.add(
          BufferFrameCodec.encode(
            const SubscribeSessionFrame(sessionId: sessionId),
          ),
        );
        await pumpEventQueue();
        casterPipe.local.sink.add(
          BufferFrameCodec.encode(
            BufferSnapshotFrame(
              snapshot: BufferSnapshot.fromBuffer(
                sessionId: sessionId,
                seq: 1,
                buffer: Buffer.blank(40, 10),
                cursor: CursorState.origin,
                modes: TerminalModes.defaults,
              ),
            ),
          ),
        );
        await pumpEventQueue();
        casterInbox.clear();

        clientIn.sink.add(
          BufferFrameCodec.encode(
            const RequestKeyframeFrame(sessionId: sessionId),
          ),
        );
        clientB.local.sink.add(
          BufferFrameCodec.encode(
            const RequestKeyframeFrame(sessionId: sessionId),
          ),
        );
        await pumpEventQueue();
        check(casterInbox.whereType<RequestKeyframeFrame>()).length.equals(1);

        // Unsubscribe clientA -> smallest-viewport aggregation across remaining clientB!
        clientIn.sink.add(
          BufferFrameCodec.encode(
            const UnsubscribeSessionFrame(sessionId: sessionId),
          ),
        );
        clientB.local.sink.add(
          BufferFrameCodec.encode(
            const ResizeFrame(sessionId: sessionId, cols: 50, rows: 15),
          ),
        );
        await pumpEventQueue();
        check(casterInbox).any(
          (it) => it
              .isA<ResizeFrame>()
              .has((r) => (r.cols, r.rows), 'dims')
              .equals((50, 15)),
        );

        // Caster emits snapshot at 60x20 -> updates directory dimensions!
        casterPipe.local.sink.add(
          BufferFrameCodec.encode(
            BufferSnapshotFrame(
              snapshot: BufferSnapshot.fromBuffer(
                sessionId: sessionId,
                seq: 1,
                buffer: Buffer.blank(60, 20),
                cursor: CursorState.origin,
                modes: TerminalModes.defaults,
              ),
            ),
          ),
        );
        await pumpEventQueue();
        check((
          registry.sessions.single.cols,
          registry.sessions.single.rows,
        )).equals((60, 20));

        // Explicit SessionClosedFrame removes session and notifies subscribers.
        casterPipe.local.sink.add(
          BufferFrameCodec.encode(
            const SessionClosedFrame(sessionId: sessionId, exitCode: 42),
          ),
        );
        await pumpEventQueue();
        check(registry.sessions).isEmpty();
      },
    );

    test(
      'pipelined frames after auth failure cannot authenticate across async close or leak zombie peers',
      () async {
        final tokenHandler = WsRelayHandler(
          registry: registry,
          authenticator: TokenAuthenticator(
            casterToken: 'secret-c',
            clientToken: 'secret-v',
          ),
          onLog: logs.add,
        );

        // Client sends [wrongToken, validToken] back-to-back while closeWithCode suspends asynchronously.
        final closeBlocker = Completer<void>();
        addTearDown(() {
          if (!closeBlocker.isCompleted) closeBlocker.complete();
        });
        final clientPipe = StreamChannelController<Uint8List>();
        tokenHandler.attachClientChannel(
          clientPipe.foreign,
          closeWithCode: (_, _) async {
            await closeBlocker.future;
          },
        );
        final clientInbox = <CastMessage>[];
        final clientSub = clientPipe.local.stream.listen(
          (b) => clientInbox.add(BufferFrameCodec.decode(b)),
        );
        addTearDown(clientSub.cancel);

        clientPipe.local.sink.add(
          BufferFrameCodec.encode(
            const AuthFrame(role: .client, token: 'wrong'),
          ),
        );
        clientPipe.local.sink.add(
          BufferFrameCodec.encode(
            const AuthFrame(role: .client, token: 'secret-v'),
          ),
        );
        await pumpEventQueue();

        check(registry.connectedClientCount).equals(0);
        check(clientInbox.whereType<AuthAcceptedFrame>()).isEmpty();

        closeBlocker.complete();
        await clientPipe.local.sink.close();
        await pumpEventQueue();
        check(registry.connectedClientCount).equals(0);

        // Caster sends [malformedBytes, validAuth, RegisterSession] back-to-back across async close.
        final casterCloseBlocker = Completer<void>();
        addTearDown(() {
          if (!casterCloseBlocker.isCompleted) casterCloseBlocker.complete();
        });
        final casterPipe = StreamChannelController<Uint8List>();
        tokenHandler.attachCasterChannel(
          casterPipe.foreign,
          closeWithCode: (_, _) async {
            await casterCloseBlocker.future;
          },
        );
        final casterSub = casterPipe.local.stream.listen((_) {});
        addTearDown(casterSub.cancel);

        casterPipe.local.sink.add(Uint8List.fromList([0xFF, 0x00]));
        casterPipe.local.sink.add(
          BufferFrameCodec.encode(
            const AuthFrame(role: .caster, token: 'secret-c'),
          ),
        );
        casterPipe.local.sink.add(
          BufferFrameCodec.encode(
            const RegisterSessionFrame(
              sessionId: SessionId('zombie-sess'),
              title: 'zombie',
              cols: 80,
              rows: 24,
            ),
          ),
        );
        await pumpEventQueue();
        check(registry.sessions).isEmpty();

        casterCloseBlocker.complete();
        await casterPipe.local.sink.close();
        await pumpEventQueue();
        check(registry.sessions).isEmpty();
      },
    );

    test(
      'forwards v6 snapshots, deltas, scrollback chunks, title, bell, and audio while evicting hostile 0x17/0x18/0x19/tail frames',
      () async {
        const sessionId = SessionId('sess-v6-relay');
        int? casterCloseCode;
        final casterPipe = StreamChannelController<Uint8List>();
        handler.attachCasterChannel(
          casterPipe.foreign,
          closeWithCode: (code, _) async {
            casterCloseCode = code;
          },
        );
        final casterSub = casterPipe.local.stream.listen((_) {});
        addTearDown(casterSub.cancel);

        final clientPipe = StreamChannelController<Uint8List>();
        handler.attachClientChannel(clientPipe.foreign);
        final clientInbox = <CastMessage>[];
        final clientSub = clientPipe.local.stream.listen(
          (b) => clientInbox.add(BufferFrameCodec.decode(b)),
        );
        addTearDown(clientSub.cancel);

        casterPipe.local.sink.add(
          BufferFrameCodec.encode(const AuthFrame(role: .caster, token: '')),
        );
        casterPipe.local.sink.add(
          BufferFrameCodec.encode(
            const RegisterSessionFrame(
              sessionId: sessionId,
              title: 'ktty-sh',
              cols: 6,
              rows: 2,
            ),
          ),
        );
        clientPipe.local.sink.add(
          BufferFrameCodec.encode(const AuthFrame(role: .client, token: '')),
        );
        await pumpEventQueue();

        clientPipe.local.sink.add(
          BufferFrameCodec.encode(
            const SubscribeSessionFrame(sessionId: sessionId),
          ),
        );
        await pumpEventQueue();

        final buf = Buffer.blank(6, 2)
          ..writeString(
            0,
            0,
            'KTTY',
            Style(
              underlineColor: const Color(0x11, 0xAA, 0xFF),
              uri: 'https://dart.dev',
            ),
          );
        final kittyPayload = KittyImagePayload(
          imageId: 42,
          pixelWidth: 2,
          pixelHeight: 2,
          gridCols: 1,
          gridRows: 1,
          bytes: Uint8List(16),
        );
        final snapWire = BufferFrameCodec.encode(
          BufferSnapshotFrame(
            snapshot: BufferSnapshot.fromBuffer(
              sessionId: sessionId,
              seq: 1,
              buffer: buf,
              cursor: CursorState.origin,
              modes: const TerminalModes(
                sgrPixelsMouse: true,
                kittyKeyboardFlags: 3,
              ),
              kittyImages: [kittyPayload],
            ),
          ),
        );
        casterPipe.local.sink.add(snapWire);

        // Request and reply with a v5 ScrollbackChunkFrame carrying OSC 8 uriRuns.
        clientPipe.local.sink.add(
          BufferFrameCodec.encode(
            const RequestScrollbackFrame(
              sessionId: sessionId,
              requestId: 55,
              clearSeq: 0,
              startLine: 0,
              count: 1,
            ),
          ),
        );
        await pumpEventQueue();

        casterPipe.local.sink.add(
          BufferFrameCodec.encode(
            ScrollbackChunkFrame(
              sessionId: sessionId,
              requestId: 1,
              clearSeq: 0,
              startLine: 0,
              rows: [
                EncodedScrollbackRow(
                  isWrapped: false,
                  characters: 'Docs'.split(''),
                  attributes: Uint32List(12),
                  uriRuns: const [
                    (start: 0, length: 4, uri: 'https://dart.dev'),
                  ],
                ),
              ],
            ),
          ),
        );
        await pumpEventQueue();

        final rxSnap = clientInbox.whereType<BufferSnapshotFrame>().single;
        check(rxSnap.snapshot.modes.sgrPixelsMouse).isTrue();
        check(rxSnap.snapshot.modes.kittyKeyboardFlags).equals(3);
        check(rxSnap.snapshot.kittyImages).isNotNull().length.equals(1);
        check(
          rxSnap.snapshot.toBuffer().getUri(0, 0),
        ).equals('https://dart.dev');

        final rxChunk = clientInbox.whereType<ScrollbackChunkFrame>().single;
        check(rxChunk.requestId).equals(55);
        check(rxChunk.rows.single.uriRuns).isNotNull().length.equals(1);

        // Valid 0x17, 0x18, and 0x19 forward cleanly to subscriber.
        casterPipe.local.sink.add(
          BufferFrameCodec.encode(
            const ShellTitleFrame(sessionId: sessionId, title: 'ktty-shell'),
          ),
        );
        casterPipe.local.sink.add(
          BufferFrameCodec.encode(const BellFrame(sessionId: sessionId)),
        );
        casterPipe.local.sink.add(
          BufferFrameCodec.encode(
            const AudioFrame(
              sessionId: sessionId,
              payload: CastToneAudioPayload(
                waveform: 'sine',
                frequencyHz: 440,
                duration: Duration(milliseconds: 50),
              ),
            ),
          ),
        );
        await pumpEventQueue();
        check(
          clientInbox.whereType<ShellTitleFrame>().single.title,
        ).equals('ktty-shell');
        check(clientInbox.whereType<BellFrame>()).length.equals(1);
        check(clientInbox.whereType<AudioFrame>()).length.equals(1);

        // Hostile 0x17 (raw control byte), 0x18 (trailing byte), and 0x19 (oversized uncompressedLen)
        // each evict a caster with 1008 without tearing down healthy peers.
        for (final badFrame in [
          (BytesBuilder()
                ..addByte(BufferFrameCodec.protocolVersion)
                ..addByte(0x17)
                ..add([0, 3, ...'bad'.codeUnits])
                ..add([0, 3])
                ..add('a\x1bc'.codeUnits))
              .takeBytes(),
          (BytesBuilder()
                ..addByte(BufferFrameCodec.protocolVersion)
                ..addByte(0x18)
                ..add([0, 3, ...'bad'.codeUnits])
                ..addByte(0x00))
              .takeBytes(),
          (BytesBuilder()
                ..addByte(BufferFrameCodec.protocolVersion)
                ..addByte(0x19)
                ..add([0, 3, ...'bad'.codeUnits])
                ..addByte(0x01)
                ..add([0x00, 0x40, 0x00, 0x00])
                ..add([0x78, 0x9C, 0x03, 0x00, 0x00, 0x00, 0x00, 0x01]))
              .takeBytes(),
        ]) {
          int? rogueCloseCode;
          final rogueCaster = StreamChannelController<Uint8List>();
          handler.attachCasterChannel(
            rogueCaster.foreign,
            closeWithCode: (code, _) async => rogueCloseCode = code,
          );
          addTearDown(rogueCaster.local.stream.listen((_) {}).cancel);
          rogueCaster.local.sink.add(
            BufferFrameCodec.encode(const AuthFrame(role: .caster, token: '')),
          );
          rogueCaster.local.sink.add(
            BufferFrameCodec.encode(
              const RegisterSessionFrame(
                sessionId: SessionId('bad'),
                title: 'bad',
                cols: 10,
                rows: 4,
              ),
            ),
          );
          await pumpEventQueue();
          rogueCaster.local.sink.add(badFrame);
          await pumpEventQueue();
          check(rogueCloseCode).equals(1008);
        }

        // Tampered raw PNG Kitty IHDR bomb (header 2x2, IHDR 20000x20000) or truncated delta tail evicts caster with 1008.
        final pngHeaderBytes =
            (BytesBuilder()
                  ..add(const [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
                  ..add(const [0x00, 0x00, 0x00, 0x0D])
                  ..add(const [0x49, 0x48, 0x44, 0x52])
                  ..add(const [0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00, 0x02])
                  ..add(const [
                    0x08,
                    0x06,
                    0x00,
                    0x00,
                    0x00,
                    0x00,
                    0x00,
                    0x00,
                    0x00,
                  ]))
                .toBytes();
        final validPngDelta = BufferFrameCodec.encode(
          BufferDeltaFrame(
            delta: BufferDelta(
              sessionId: sessionId,
              seq: 2,
              baseSeq: 1,
              cols: 6,
              rows: 2,
              cursor: CursorState.origin,
              modes: TerminalModes.defaults,
              runs: const [],
              kittyUpserts: [
                KittyImagePayload(
                  imageId: 9,
                  pixelWidth: 2,
                  pixelHeight: 2,
                  gridCols: 1,
                  gridRows: 1,
                  format: 100,
                  bytes: pngHeaderBytes,
                ),
              ],
            ),
          ),
        );
        final tamperedRelayPng = Uint8List.fromList(validPngDelta);
        final pngOffset = tamperedRelayPng.length - pngHeaderBytes.length;
        ByteData.sublistView(
          tamperedRelayPng,
          pngOffset + 16,
          pngOffset + 24,
        ).setUint32(0, 20000);
        casterPipe.local.sink.add(tamperedRelayPng);
        await pumpEventQueue();
        check(casterCloseCode).equals(1008);
      },
    );

    test(
      'routes 0x1B KittyImageChunkFrame to synchronized subscribers, respects awaitingKeyframe & outbound pressure, and evicts tampered 0x1B casters',
      () async {
        const sessionId = SessionId('kitty-chunk-relay');
        final registry = SessionRegistry(
          maxOutboundFrames: 4,
          maxOutboundBytes: 128 * 1024,
        );
        addTearDown(registry.close);
        final handler = WsRelayHandler(
          registry: registry,
          authenticator: TokenAuthenticator(
            casterToken: 'c-tok',
            clientToken: 'v-tok',
          ),
        );
        addTearDown(handler.close);

        final casterPipe = StreamChannelController<Uint8List>();
        int? casterCloseCode;
        handler.attachCasterChannel(
          casterPipe.foreign,
          closeWithCode: (code, _) async => casterCloseCode = code,
        );
        final casterInbox = <CastMessage>[];
        addTearDown(
          casterPipe.local.stream
              .listen((raw) => casterInbox.add(BufferFrameCodec.decode(raw)))
              .cancel,
        );

        casterPipe.local.sink.add(
          BufferFrameCodec.encode(
            const AuthFrame(role: .caster, token: 'c-tok'),
          ),
        );
        casterPipe.local.sink.add(
          BufferFrameCodec.encode(
            const RegisterSessionFrame(
              sessionId: sessionId,
              title: 'chunk-relay',
              cols: 8,
              rows: 4,
            ),
          ),
        );
        await pumpEventQueue();

        // Attach synced client (with direct StreamController backpressure).
        final syncedIn = StreamController<Uint8List>();
        final syncedOut = StreamController<Uint8List>();
        final syncedLocal = StreamChannel<Uint8List>(
          syncedOut.stream,
          syncedIn.sink,
        );
        final syncedForeign = StreamChannel<Uint8List>(
          syncedIn.stream,
          syncedOut.sink,
        );
        handler.attachClientChannel(
          syncedForeign,
          closeWithCode: (_, _) async => unawaited(syncedOut.close()),
        );
        final syncedMsgs = <CastMessage>[];
        final syncedSub = syncedLocal.stream.listen(
          (raw) => syncedMsgs.add(BufferFrameCodec.decode(raw)),
        );
        addTearDown(syncedSub.cancel);
        addTearDown(syncedIn.close);

        syncedLocal.sink.add(
          BufferFrameCodec.encode(
            const AuthFrame(role: .client, token: 'v-tok'),
          ),
        );
        syncedLocal.sink.add(
          BufferFrameCodec.encode(
            const SubscribeSessionFrame(sessionId: sessionId),
          ),
        );
        await pumpEventQueue();

        // Bring only syncedPipe out of awaitingKeyframe by delivering snapshot,
        // then add late2 after snapshot so late2 remains in awaitingKeyframe.
        casterPipe.local.sink.add(
          BufferFrameCodec.encode(
            BufferSnapshotFrame(
              snapshot: BufferSnapshot(
                sessionId: sessionId,
                seq: 1,
                cols: 8,
                rows: 4,
                cursor: CursorState.origin,
                modes: TerminalModes.defaults,
                wrappedRows: Uint8List(1),
                characters: List<String>.filled(32, ' '),
                attributes: Uint32List(32 * 3),
              ),
            ),
          ),
        );
        await pumpEventQueue();
        syncedMsgs.clear();

        final late2Pipe = StreamChannelController<Uint8List>();
        handler.attachClientChannel(late2Pipe.foreign);
        final late2Msgs = <CastMessage>[];
        addTearDown(
          late2Pipe.local.stream
              .listen((raw) => late2Msgs.add(BufferFrameCodec.decode(raw)))
              .cancel,
        );
        late2Pipe.local.sink.add(
          BufferFrameCodec.encode(
            const AuthFrame(role: .client, token: 'v-tok'),
          ),
        );
        late2Pipe.local.sink.add(
          BufferFrameCodec.encode(
            const SubscribeSessionFrame(sessionId: sessionId),
          ),
        );
        await pumpEventQueue();
        late2Msgs.clear();
        casterInbox.clear();

        // Forward 0x1B chunk: syncedPipe receives it; awaitingKeyframe late2 does not.
        final validChunk = KittyImageChunkFrame(
          sessionId: sessionId,
          imageId: 55,
          pixelWidth: 2,
          pixelHeight: 2,
          gridCols: 1,
          gridRows: 1,
          format: 32,
          encoding: .raw,
          totalDecodedBytes: 16,
          totalWireBytes: 16,
          chunkIndex: 0,
          chunkCount: 1,
          data: Uint8List(16),
        );
        casterPipe.local.sink.add(BufferFrameCodec.encode(validChunk));
        await pumpEventQueue();
        check(
          syncedMsgs.whereType<KittyImageChunkFrame>().single.imageId,
        ).equals(55);
        check(late2Msgs.whereType<KittyImageChunkFrame>()).isEmpty();

        // Synchronize late2 with snapshot seq=2 so awaitingKeyframe empties,
        // then pause syncedPipe and send >maxOutboundFrames chunks ->
        // downgraded to awaitingKeyframe + RequestKeyframe.
        casterPipe.local.sink.add(
          BufferFrameCodec.encode(
            BufferSnapshotFrame(
              snapshot: BufferSnapshot(
                sessionId: sessionId,
                seq: 2,
                cols: 8,
                rows: 4,
                cursor: CursorState.origin,
                modes: TerminalModes.defaults,
                wrappedRows: Uint8List(1),
                characters: List<String>.filled(32, ' '),
                attributes: Uint32List(32 * 3),
              ),
            ),
          ),
        );
        await pumpEventQueue();
        casterInbox.clear();

        syncedSub.pause();
        await pumpEventQueue();
        for (var i = 0; i < 8; i++) {
          casterPipe.local.sink.add(BufferFrameCodec.encode(validChunk));
        }
        await pumpEventQueue();
        syncedSub.resume();
        await pumpEventQueue();
        check(casterInbox.whereType<RequestKeyframeFrame>()).isNotEmpty();
        syncedMsgs.clear();
        casterPipe.local.sink.add(BufferFrameCodec.encode(validChunk));
        await pumpEventQueue();
        check(syncedMsgs.whereType<KittyImageChunkFrame>()).isEmpty();

        // Tampered trailing-byte 0x1B chunk evicts caster with 1008.
        final badChunkWire = Uint8List.fromList([
          ...BufferFrameCodec.encode(validChunk),
          0xFF,
        ]);
        casterPipe.local.sink.add(badChunkWire);
        await pumpEventQueue();
        check(casterCloseCode).equals(1008);
      },
    );
  });
}
