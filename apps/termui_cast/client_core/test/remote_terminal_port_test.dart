import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:checks/checks.dart';
import 'package:stream_channel/stream_channel.dart';
import 'package:termui/termui.dart';
import 'package:termui_cast_client_core/src/session_slot.dart';
import 'package:termui_cast_client_core/termui_cast_client_core.dart';
import 'package:termui_cast_protocol/termui_cast_protocol.dart';
import 'package:termui_pty/termui_pty.dart';
import 'package:test/test.dart';

Uint8List _corruptAudioWireFrame(SessionId sessionId) {
  final valid = BufferFrameCodec.encode(
    AudioFrame(
      sessionId: sessionId,
      payload: const CastToneAudioPayload(
        waveform: 'sine',
        frequencyHz: 440,
        duration: Duration(milliseconds: 50),
      ),
    ),
  );
  // Corrupt every byte in the raw-deflate tail past frame type + session header.
  final corrupted = Uint8List.fromList(valid);
  for (var i = corrupted.length - 4; i < corrupted.length; i++) {
    corrupted[i] ^= 0xFF;
  }
  return corrupted;
}

BufferSnapshot _makeSnapshot({
  required SessionId sessionId,
  required int seq,
  required int cols,
  required int rows,
  String firstLine = 'HELLO',
  ScrollbackWindow scrollback = ScrollbackWindow.empty,
}) {
  final buffer = Buffer.blank(cols, rows);
  for (var i = 0; i < firstLine.length && i < cols; i++) {
    buffer.setCell(i, 0, firstLine[i], 0xFFFFFFFF, 0, 0);
  }
  return BufferSnapshot.fromBuffer(
    sessionId: sessionId,
    seq: seq,
    buffer: buffer,
    cursor: const CursorState(x: 2, y: 0, shape: .blinkingBar),
    modes: const TerminalModes(bracketedPaste: true, kittyKeyboardFlags: 1),
    scrollback: scrollback,
  );
}

final class _FakeServerTransportHarness {
  final StreamController<Uint8List> toClient = StreamController<Uint8List>();
  final StreamController<Uint8List> fromClient = StreamController<Uint8List>();
  final List<CastMessage> received = <CastMessage>[];
  late final StreamSubscription<Uint8List> _sub;

  _FakeServerTransportHarness() {
    _sub = fromClient.stream.listen((raw) {
      received.add(BufferFrameCodec.decode(raw));
    });
  }

  Future<StreamChannel<Uint8List>> openChannel() async =>
      StreamChannel<Uint8List>(toClient.stream, fromClient.sink);

  void send(CastMessage message) {
    toClient.add(BufferFrameCodec.encode(message));
  }

  Future<void> close() async {
    await _sub.cancel();
    await toClient.close();
    await fromClient.close();
  }
}

void main() {
  group('WsClientTransport AudioFrame error isolation', () {
    test(
      'drops corrupt 0x19 AudioFrame without closing transport or resetting SessionSlot',
      () async {
        const sessionId = SessionId('audio-err');
        final server = _FakeServerTransportHarness();
        final transport = WsClientTransport(channelFactory: server.openChannel);
        final repo = CastClientRepository(
          transport: transport,
          enableReconnect: false,
        );
        final corruptEvents = <SessionId>[];
        final corruptSub = transport.corruptSessionFrames.listen(
          corruptEvents.add,
        );
        var disconnected = false;
        final disconnectSub = transport.disconnects.listen(
          (_) => disconnected = true,
        );

        await repo.connect();
        server.send(const AuthAcceptedFrame(role: .client));
        await Future<void>.delayed(Duration.zero);

        final port = repo.openTerminalPort(
          sessionId,
          initialCols: 80,
          initialRows: 24,
        );
        await Future<void>.delayed(Duration.zero);

        server.send(
          BufferSnapshotFrame(
            snapshot: _makeSnapshot(
              sessionId: sessionId,
              seq: 1,
              cols: 80,
              rows: 24,
              firstLine: 'SYNCED',
            ),
          ),
        );
        await Future<void>.delayed(Duration.zero);
        check(port.slot.state).equals(ClientSessionSyncState.synchronized);

        final rxBeforeCorrupt = transport.rxBytes;
        final corruptFrame = _corruptAudioWireFrame(sessionId);
        server.toClient.add(corruptFrame);
        await Future<void>.delayed(Duration.zero);

        check(transport.isConnected).isTrue();
        check(disconnected).isFalse();
        check(corruptEvents).isEmpty();
        check(transport.rxBytes).equals(rxBeforeCorrupt + corruptFrame.length);
        check(port.slot.state).equals(ClientSessionSyncState.synchronized);
        check(port.slot.seq).equals(1);
        check(port.buffer.getCharacter(0, 0)).equals('S');

        // Transport remains healthy for subsequent valid AudioFrame + BellFrame.
        final bells = <int>[];
        final audios = <TerminalAudioEvent>[];
        port.addBellListener(() => bells.add(1));
        port.addAudioListener(audios.add);
        server.send(const BellFrame(sessionId: sessionId));
        server.send(
          const AudioFrame(
            sessionId: sessionId,
            payload: CastStopAudioPayload(clipId: 7),
          ),
        );
        server.send(
          const AudioFrame(
            sessionId: sessionId,
            payload: CastUpdateAudioPayload(
              clipId: 7,
              volume: 0.5,
              pan: 0.25,
              seekPosition: Duration(milliseconds: 300),
              paused: true,
              speed: 1.5,
              preservePitch: true,
              fadeVolumeTarget: 0.1,
              fadeVolumeDuration: Duration(milliseconds: 200),
              fadeSpeedTarget: 0.8,
              fadeSpeedDuration: Duration(milliseconds: 400),
              scheduleStopDuration: Duration(milliseconds: 900),
            ),
          ),
        );
        await Future<void>.delayed(Duration.zero);
        check(bells.length).equals(1);
        check(port.bellCount).equals(1);
        check(audios).deepEquals([
          const TerminalStopAudioEvent(clipId: 7),
          const TerminalUpdateAudioEvent(
            clipId: 7,
            volume: 0.5,
            pan: 0.25,
            seekPosition: Duration(milliseconds: 300),
            paused: true,
            speed: 1.5,
            preservePitch: true,
            fadeVolumeTarget: 0.1,
            fadeVolumeDuration: Duration(milliseconds: 200),
            fadeSpeedTarget: 0.8,
            fadeSpeedDuration: Duration(milliseconds: 400),
            scheduleStopDuration: Duration(milliseconds: 900),
          ),
        ]);

        await corruptSub.cancel();
        await disconnectSub.cancel();
        await port.dispose();
        await repo.dispose();
        await server.close();
      },
    );
  });

  group('RemoteTerminalPort ref-counting and TerminalPort contract', () {
    test(
      'ref-counts split panes, tracks local min(cols, rows), restores size on close, and only unsubscribes on last pane dispose',
      () async {
        const sessionId = SessionId('split-1');
        final server = _FakeServerTransportHarness();
        final transport = WsClientTransport(channelFactory: server.openChannel);
        final repo = CastClientRepository(
          transport: transport,
          enableReconnect: false,
        );
        await repo.connect();
        server.send(const AuthAcceptedFrame(role: .client));
        await Future<void>.delayed(Duration.zero);
        server.received.clear();

        // Pane 1 opens at 100x30 -> SubscribeSessionFrame(100, 30).
        final port1 = RemoteTerminalPort(
          repository: repo,
          sessionId: sessionId,
          portId: 'pane-1',
          initialCols: 100,
          initialRows: 30,
        );
        await Future<void>.delayed(Duration.zero);
        check(repo.attachedPortCount(sessionId)).equals(1);
        check(
          repo.localMinViewportSize(sessionId),
        ).equals((cols: 100, rows: 30));
        check(server.received.length).equals(1);
        check(server.received.single).isA<SubscribeSessionFrame>()
          ..has((f) => f.cols, 'cols').equals(100)
          ..has((f) => f.rows, 'rows').equals(30);
        server.received.clear();

        // Pane 2 attaches at 70x25 -> shares subscription, sends ResizeFrame(70, 25).
        final port2 = repo.openTerminalPort(
          sessionId,
          portId: 'pane-2',
          initialCols: 70,
          initialRows: 25,
        );
        await Future<void>.delayed(Duration.zero);
        check(repo.attachedPortCount(sessionId)).equals(2);
        check(
          repo.localMinViewportSize(sessionId),
        ).equals((cols: 70, rows: 25));
        check(server.received.length).equals(1);
        check(server.received.single).isA<ResizeFrame>()
          ..has((f) => f.cols, 'cols').equals(70)
          ..has((f) => f.rows, 'rows').equals(25);
        server.received.clear();

        // Snapshot at 60x20 updates activePtySize even while local panes are larger.
        server.send(
          BufferSnapshotFrame(
            snapshot: _makeSnapshot(
              sessionId: sessionId,
              seq: 1,
              cols: 60,
              rows: 20,
              scrollback: const ScrollbackWindow(
                clearSeq: 1,
                oldestLine: 0,
                totalLines: 2,
              ),
            ),
          ),
        );
        await Future<void>.delayed(Duration.zero);
        check(port1.cols).equals(60);
        check(port1.rows).equals(20);
        check(port1.activePtySize).equals((60, 20));
        check(port1.localViewportSize).equals((cols: 100, rows: 30));
        check(port2.localViewportSize).equals((cols: 70, rows: 25));
        check(port1.cursor.shape).equals(TerminalCursorShape.blinkingBar);
        check(port1.modes.bracketedPaste).isTrue();
        check(port1.modes.kittyKeyboardFlags).equals(1);

        // Close smaller pane 2 (ref-count 2 -> 1): no UnsubscribeSessionFrame,
        // sends ResizeFrame(100, 30) restoring pane 1's dimensions.
        await port2.dispose();
        await Future<void>.delayed(Duration.zero);
        check(port2.isDisposed).isTrue();
        check(repo.attachedPortCount(sessionId)).equals(1);
        check(server.received.whereType<UnsubscribeSessionFrame>()).isEmpty();
        final restores = [...server.received.whereType<ResizeFrame>()];
        check(restores.length).equals(1);
        check(restores.single.cols).equals(100);
        check(restores.single.rows).equals(30);
        server.received.clear();

        // Close last pane 1 (ref-count 1 -> 0): sends UnsubscribeSessionFrame.
        await port1.dispose();
        await Future<void>.delayed(Duration.zero);
        check(repo.attachedPortCount(sessionId)).equals(0);
        check(server.received.length).equals(1);
        check(server.received.single)
            .isA<UnsubscribeSessionFrame>()
            .has((f) => f.sessionId, 'sessionId')
            .equals(sessionId);

        await repo.dispose();
        await server.close();
      },
    );

    test(
      'routes scrollback slice fetches, pinned vs shell title, audio clips, clipboard, and reconnect resubscribe',
      () async {
        const sessionId = SessionId('meta-1');
        var server = _FakeServerTransportHarness();
        final transport = WsClientTransport(channelFactory: server.openChannel);
        final repo = CastClientRepository(
          transport: transport,
          transportFactory: (_) =>
              WsClientTransport(channelFactory: server.openChannel),
          enableReconnect: false,
        );

        // Open port BEFORE connect() / AuthAcceptedFrame.
        final port = repo.openTerminalPort(
          sessionId,
          initialCols: 80,
          initialRows: 24,
        );
        final titles = <String>[];
        final audioEvents = <TerminalAudioEvent>[];
        final clipboards = <(String, String)>[];
        port.addTitleListener(titles.add);
        port.addAudioListener(audioEvents.add);
        port.addClipboardListener((sel, text) => clipboards.add((sel, text)));

        await repo.connect();
        server.send(const AuthAcceptedFrame(role: .client));
        await Future<void>.delayed(Duration.zero);
        check(
          server.received.whereType<SubscribeSessionFrame>().length,
        ).equals(1);

        server.send(
          const SessionDirectoryFrame(
            sessions: [
              SessionSummary(id: sessionId, title: 'zsh', cols: 80, rows: 24),
            ],
          ),
        );
        server.send(const ShellTitleFrame(sessionId: sessionId, title: 'vim'));
        await Future<void>.delayed(Duration.zero);
        check(port.windowTitle).equals('vim');
        check(port.isUserPinned).isFalse();
        check(titles.contains('vim')).isTrue();

        // User pin overrides shellTitle until directory clears pin.
        server.send(
          const SessionDirectoryFrame(
            sessions: [
              SessionSummary(
                id: sessionId,
                title: 'Pinned Pane',
                cols: 80,
                rows: 24,
                isUserPinned: true,
              ),
            ],
          ),
        );
        server.send(
          const ShellTitleFrame(sessionId: sessionId, title: 'cargo'),
        );
        await Future<void>.delayed(Duration.zero);
        check(port.isUserPinned).isTrue();
        check(port.pinnedTitle).equals('Pinned Pane');
        check(port.shellTitle).equals('cargo');
        check(port.displayTitle).equals('Pinned Pane');

        // Clearing pin restores latest shellTitle via SessionDirectoryFrame + rename(clearPin: true).
        server.received.clear();
        port.rename('', clearPin: true);
        await Future<void>.delayed(Duration.zero);
        check(server.received.whereType<RenameSessionFrame>().single)
          ..has((r) => r.title, 'title').equals('')
          ..has((r) => r.clearPin, 'clearPin').isTrue();

        server.send(
          const SessionDirectoryFrame(
            sessions: [
              SessionSummary(id: sessionId, title: 'cargo', cols: 80, rows: 24),
            ],
          ),
        );
        await Future<void>.delayed(Duration.zero);
        check(port.isUserPinned).isFalse();
        check(port.displayTitle).equals('cargo');

        // Audio clip + clipboard + scrollback hydration.
        server.send(
          BufferSnapshotFrame(
            snapshot: _makeSnapshot(
              sessionId: sessionId,
              seq: 1,
              cols: 80,
              rows: 24,
              scrollback: const ScrollbackWindow(
                clearSeq: 2,
                oldestLine: 0,
                totalLines: 300,
              ),
            ),
          ),
        );
        server.send(
          AudioFrame(
            sessionId: sessionId,
            payload: CastClipAudioPayload(
              clipId: 9,
              format: 'wav',
              bytes: Uint8List.fromList([1, 2, 3, 4]),
              loop: true,
              pan: -0.5,
              startOffset: const Duration(milliseconds: 250),
              busId: 3,
            ),
          ),
        );
        server.send(
          const AudioFrame(
            sessionId: sessionId,
            payload: CastBusAudioPayload(
              op: 'param',
              busId: 3,
              filterId: 7,
              paramId: 2,
              value: 0.75,
            ),
          ),
        );
        server.send(
          AudioFrame(
            sessionId: sessionId,
            payload: CastStreamAudioPayload(
              op: 'chunk',
              streamId: 4,
              seq: 0,
              chunkBytes: Uint8List.fromList([7, 8, 9]),
            ),
          ),
        );
        server.send(
          AudioFrame(
            sessionId: sessionId,
            payload: CastClipAudioPayload(
              clipId: 10,
              format: 'wav',
              bytes: Uint8List(0),
              streamId: 4,
            ),
          ),
        );
        server.send(
          const ClipboardFrame(sessionId: sessionId, text: 'copied-text'),
        );
        await Future<void>.delayed(Duration.zero);
        check(audioEvents).length.equals(4);
        check(audioEvents.first).isA<TerminalClipAudioEvent>()
          ..has((e) => e.clipId, 'clipId').equals(9)
          ..has((e) => e.format, 'format').equals('wav')
          ..has((e) => e.loop, 'loop').isTrue()
          ..has((e) => e.pan, 'pan').equals(-0.5)
          ..has((e) => e.busId, 'busId').equals(3)
          ..has(
            (e) => e.startOffset,
            'startOffset',
          ).equals(const Duration(milliseconds: 250));
        check(audioEvents[1]).equals(
          const TerminalBusAudioEvent(
            op: 'param',
            busId: 3,
            filterId: 7,
            paramId: 2,
            value: 0.75,
          ),
        );
        check(audioEvents[2]).equals(
          TerminalStreamAudioEvent(
            op: 'chunk',
            streamId: 4,
            seq: 0,
            chunkBytes: Uint8List.fromList([7, 8, 9]),
          ),
        );
        check(audioEvents.last).isA<TerminalClipAudioEvent>()
          ..has((e) => e.clipId, 'clipId').equals(10)
          ..has((e) => e.streamId, 'streamId').equals(4)
          ..has((e) => e.bytes, 'bytes').isEmpty();
        check(clipboards).deepEquals([('c', 'copied-text')]);

        server.received.clear();
        final missSlice = port.readScrollbackSlice(0, 1);
        check(missSlice).deepEquals([null]);
        await Future<void>.delayed(Duration.zero);
        final sbReq = server.received
            .whereType<RequestScrollbackFrame>()
            .single;
        check(sbReq.startLine).equals(0);
        check(sbReq.count).equals(1);

        server.send(
          ScrollbackChunkFrame(
            sessionId: sessionId,
            requestId: sbReq.requestId,
            clearSeq: 2,
            startLine: 0,
            rows: [
              EncodedScrollbackRow(
                isWrapped: true,
                characters: ['a', 'b'],
                attributes: Uint32List.fromList([1, 0, 0, 2, 0, 0]),
                underlineColors: const {1: 0xFF112233},
                uriRuns: const [(start: 0, length: 2, uri: 'https://dart.dev')],
              ),
            ],
          ),
        );
        await Future<void>.delayed(Duration.zero);
        final hitSlice = port.readScrollbackSlice(0, 1);
        final line = hitSlice.single!;
        check(line.isWrapped).isTrue();
        check(line.characters).deepEquals(['a', 'b']);
        check(line.underlineColors).isNotNull();
        check(line.underlineColors![1]).equals(0xFF112233);
        check(
          line.uris,
        ).isNotNull().deepEquals(['https://dart.dev', 'https://dart.dev']);

        // Reconnect auto-resubscribes open RemoteTerminalPort.
        await server.close();
        server = _FakeServerTransportHarness();
        await repo.reconnect((
          serverUri: WsClientTransport.defaultServerUri,
          token: 'new-tok',
        ));
        server.send(const AuthAcceptedFrame(role: .client));
        await Future<void>.delayed(Duration.zero);
        check(
          server.received.whereType<SubscribeSessionFrame>().length,
        ).equals(1);

        // Session exit completes exitCode.
        server.send(
          const SessionClosedFrame(
            sessionId: sessionId,
            exitCode: 42,
            reason: .exited,
          ),
        );
        check(await port.exitCode).equals(42);
        port.sendInput(Uint8List.fromList(utf8.encode('ignored')));

        await port.dispose();
        await repo.dispose();
        await server.close();
      },
    );

    test(
      're-subscribes port opened before sessionId appears in SessionDirectoryFrame',
      () async {
        const sessionId = SessionId('late-session');
        final server = _FakeServerTransportHarness();
        final transport = WsClientTransport(channelFactory: server.openChannel);
        final repo = CastClientRepository(
          transport: transport,
          enableReconnect: false,
        );
        await repo.connect();
        server.send(const AuthAcceptedFrame(role: .client));
        server.send(const SessionDirectoryFrame(sessions: []));
        await Future<void>.delayed(Duration.zero);
        server.received.clear();

        // Opened while session is unknown on relay -> initial SubscribeSessionFrame rejected.
        final port = repo.openTerminalPort(
          sessionId,
          initialCols: 80,
          initialRows: 24,
        );
        await Future<void>.delayed(Duration.zero);
        check(
          server.received.whereType<SubscribeSessionFrame>().length,
        ).equals(1);
        server.received.clear();
        server.send(
          const ErrorFrame(code: 'unknown_session', message: 'Not registered'),
        );
        await Future<void>.delayed(Duration.zero);

        // Once caster registers sessionId and relay broadcasts SessionDirectoryFrame,
        // repository re-subscribes cleanly and synchronizes the port.
        server.send(
          const SessionDirectoryFrame(
            sessions: [
              SessionSummary(
                id: sessionId,
                title: 'late-shell',
                cols: 80,
                rows: 24,
              ),
            ],
          ),
        );
        await Future<void>.delayed(Duration.zero);
        final resubscribes = [
          ...server.received.whereType<SubscribeSessionFrame>(),
        ];
        check(resubscribes.length).equals(1);
        check(resubscribes.single.cols).equals(80);
        check(resubscribes.single.rows).equals(24);

        server.send(
          BufferSnapshotFrame(
            snapshot: _makeSnapshot(
              sessionId: sessionId,
              seq: 1,
              cols: 80,
              rows: 24,
              firstLine: 'LATE_OK',
            ),
          ),
        );
        await Future<void>.delayed(Duration.zero);
        check(port.slot.state).equals(ClientSessionSyncState.synchronized);
        check(port.buffer.getCharacter(0, 0)).equals('L');

        await port.dispose();
        await repo.dispose();
        await server.close();
      },
    );

    test(
      'RemoteTerminalPort isolates throwing listeners from sibling listeners and sibling ports on the same SessionId',
      () async {
        const sessionId = SessionId('shared-fanout');
        final server = _FakeServerTransportHarness();
        final transport = WsClientTransport(channelFactory: server.openChannel);
        final repo = CastClientRepository(
          transport: transport,
          enableReconnect: false,
        );
        await repo.connect();
        server.send(const AuthAcceptedFrame(role: .client));
        await Future<void>.delayed(Duration.zero);

        final port1 = repo.openTerminalPort(
          sessionId,
          initialCols: 80,
          initialRows: 24,
        );
        final port2 = repo.openTerminalPort(
          sessionId,
          initialCols: 80,
          initialRows: 24,
        );
        await Future<void>.delayed(Duration.zero);

        var p1Changes = 0;
        var p2Changes = 0;
        final p1Titles = <String>[];
        final p2Titles = <String>[];
        var p1Bells = 0;
        var p2Bells = 0;
        final p1Audios = <TerminalAudioEvent>[];
        final p2Audios = <TerminalAudioEvent>[];
        final p1Clips = <(String, String)>[];
        final p2Clips = <(String, String)>[];

        port1
          ..addListener(() => throw StateError('boom change'))
          ..addListener(() => p1Changes += 1)
          ..addTitleListener((_) => throw StateError('boom title'))
          ..addTitleListener(p1Titles.add)
          ..addBellListener(() => throw StateError('boom bell'))
          ..addBellListener(() => p1Bells += 1)
          ..addAudioListener((_) => throw StateError('boom audio'))
          ..addAudioListener(p1Audios.add)
          ..addClipboardListener((_, _) => throw StateError('boom clip'))
          ..addClipboardListener((s, t) => p1Clips.add((s, t)));

        port2
          ..addListener(() => p2Changes += 1)
          ..addTitleListener(p2Titles.add)
          ..addBellListener(() => p2Bells += 1)
          ..addAudioListener(p2Audios.add)
          ..addClipboardListener((s, t) => p2Clips.add((s, t)));

        server.send(
          BufferSnapshotFrame(
            snapshot: _makeSnapshot(
              sessionId: sessionId,
              seq: 1,
              cols: 80,
              rows: 24,
              firstLine: 'OK',
            ),
          ),
        );
        server.send(const ShellTitleFrame(sessionId: sessionId, title: 'zsh'));
        server.send(const BellFrame(sessionId: sessionId));
        server.send(
          const AudioFrame(
            sessionId: sessionId,
            payload: CastStopAudioPayload(clipId: 3),
          ),
        );
        server.send(const ClipboardFrame(sessionId: sessionId, text: 'copied'));
        await Future<void>.delayed(Duration.zero);

        check(p1Changes).isGreaterOrEqual(1);
        check(p2Changes).isGreaterOrEqual(1);
        check(p1Titles).deepEquals(['zsh']);
        check(p2Titles).deepEquals(['zsh']);
        check(p1Bells).equals(1);
        check(p2Bells).equals(1);
        check(p1Audios).deepEquals([const TerminalStopAudioEvent(clipId: 3)]);
        check(p2Audios).deepEquals([const TerminalStopAudioEvent(clipId: 3)]);
        check(p1Clips).deepEquals([('c', 'copied')]);
        check(p2Clips).deepEquals([('c', 'copied')]);

        await port1.dispose();
        await port2.dispose();
        await repo.dispose();
        await server.close();
      },
    );

    test(
      'tracks renderRevision, fullSyncRevision, and bounded dirtySpans across snapshots, single-run/cursor-only/Kitty deltas, alt-screen flips, and >64-span overflow',
      () async {
        const sessionId = SessionId('dirty-span-1');
        final server = _FakeServerTransportHarness();
        final transport = WsClientTransport(channelFactory: server.openChannel);
        final repo = CastClientRepository(
          transport: transport,
          enableReconnect: false,
        );
        await repo.connect();
        server.send(const AuthAcceptedFrame(role: .client));
        await Future<void>.delayed(Duration.zero);

        final port = repo.openTerminalPort(
          sessionId,
          initialCols: 20,
          initialRows: 4,
        );
        await Future<void>.delayed(Duration.zero);
        check(port.renderRevision).equals(0);
        check(port.fullSyncRevision).equals(0);
        check(port.dirtySpans).isEmpty();

        // 1. Snapshot initializes fullSyncRevision == renderRevision == 1.
        server.send(
          BufferSnapshotFrame(
            snapshot: _makeSnapshot(
              sessionId: sessionId,
              seq: 1,
              cols: 20,
              rows: 4,
              firstLine: 'INIT',
            ),
          ),
        );
        await Future<void>.delayed(Duration.zero);
        check(port.renderRevision).equals(1);
        check(port.fullSyncRevision).equals(1);
        check(port.dirtySpans).isEmpty();

        // 2. Single-run delta appends one dirty span at revision 2.
        server.send(
          BufferDeltaFrame(
            delta: BufferDelta(
              sessionId: sessionId,
              baseSeq: 1,
              seq: 2,
              cols: 20,
              rows: 4,
              cursor: const CursorState(x: 5, y: 0),
              modes: TerminalModes.defaults,
              scrollback: ScrollbackWindow.empty,
              runs: [
                CellRun(
                  startIndex: 4,
                  characters: const ['!'],
                  attributes: Uint32List.fromList([0xFFFFFFFF, 0, 0]),
                ),
              ],
            ),
          ),
        );
        await Future<void>.delayed(Duration.zero);
        check(port.renderRevision).equals(2);
        check(port.fullSyncRevision).equals(1);
        check(port.dirtySpans).deepEquals([(revision: 2, start: 4, length: 1)]);

        // 3. Cursor-only delta advances renderRevision without altering fullSyncRevision or dirtySpans.
        server.send(
          BufferDeltaFrame(
            delta: BufferDelta(
              sessionId: sessionId,
              baseSeq: 2,
              seq: 3,
              cols: 20,
              rows: 4,
              cursor: const CursorState(x: 6, y: 1),
              modes: TerminalModes.defaults,
              scrollback: ScrollbackWindow.empty,
              runs: const [],
            ),
          ),
        );
        await Future<void>.delayed(Duration.zero);
        check(port.renderRevision).equals(3);
        check(port.fullSyncRevision).equals(1);
        check(port.dirtySpans).deepEquals([(revision: 2, start: 4, length: 1)]);

        // 4. Kitty mutation promotes fullSyncRevision and clears dirtySpans.
        server.send(
          BufferDeltaFrame(
            delta: BufferDelta(
              sessionId: sessionId,
              baseSeq: 3,
              seq: 4,
              cols: 20,
              rows: 4,
              cursor: const CursorState(x: 6, y: 1),
              modes: TerminalModes.defaults,
              scrollback: ScrollbackWindow.empty,
              clearKittyImages: true,
              runs: [
                CellRun(
                  startIndex: 0,
                  characters: const ['K'],
                  attributes: Uint32List.fromList([0xFFFFFFFF, 0, 0]),
                ),
              ],
            ),
          ),
        );
        await Future<void>.delayed(Duration.zero);
        check(port.renderRevision).equals(4);
        check(port.fullSyncRevision).equals(4);
        check(port.dirtySpans).isEmpty();

        // 5. Alt-screen flip promotes fullSyncRevision and clears dirtySpans.
        server.send(
          BufferDeltaFrame(
            delta: BufferDelta(
              sessionId: sessionId,
              baseSeq: 4,
              seq: 5,
              cols: 20,
              rows: 4,
              cursor: const CursorState(x: 0, y: 0),
              modes: const TerminalModes(altScreen: true),
              scrollback: ScrollbackWindow.empty,
              runs: [
                CellRun(
                  startIndex: 0,
                  characters: const ['A'],
                  attributes: Uint32List.fromList([0xFFFFFFFF, 0, 0]),
                ),
              ],
            ),
          ),
        );
        await Future<void>.delayed(Duration.zero);
        check(port.renderRevision).equals(5);
        check(port.fullSyncRevision).equals(5);
        check(port.dirtySpans).isEmpty();

        // 6. >64 queued dirty spans promotes fullSyncRevision and clears dirtySpans.
        var seq = 5;
        for (var i = 0; i < SessionSlot.maxDirtySpans; i++) {
          server.send(
            BufferDeltaFrame(
              delta: BufferDelta(
                sessionId: sessionId,
                baseSeq: seq,
                seq: ++seq,
                cols: 20,
                rows: 4,
                cursor: const CursorState(x: 0, y: 0),
                modes: const TerminalModes(altScreen: true),
                scrollback: ScrollbackWindow.empty,
                runs: [
                  CellRun(
                    startIndex: i % 80,
                    characters: const ['x'],
                    attributes: Uint32List.fromList([0xFFFFFFFF, 0, 0]),
                  ),
                ],
              ),
            ),
          );
        }
        await Future<void>.delayed(Duration.zero);
        check(port.dirtySpans.length).equals(SessionSlot.maxDirtySpans);
        check(port.fullSyncRevision).equals(5);

        // 65th span pushes total over 64 -> promotes fullSyncRevision == renderRevision.
        server.send(
          BufferDeltaFrame(
            delta: BufferDelta(
              sessionId: sessionId,
              baseSeq: seq,
              seq: ++seq,
              cols: 20,
              rows: 4,
              cursor: const CursorState(x: 0, y: 0),
              modes: const TerminalModes(altScreen: true),
              scrollback: ScrollbackWindow.empty,
              runs: [
                CellRun(
                  startIndex: 0,
                  characters: const ['z'],
                  attributes: Uint32List.fromList([0xFFFFFFFF, 0, 0]),
                ),
              ],
            ),
          ),
        );
        await Future<void>.delayed(Duration.zero);
        check(port.renderRevision).equals(port.fullSyncRevision);
        check(port.dirtySpans).isEmpty();

        await port.dispose();
        await repo.dispose();
        await server.close();
      },
    );

    test(
      'registers session-scoped KittyImageRegistry on RemoteTerminalPort.buffer across fallback, snapshots, and deltas without touching global registry',
      () async {
        const sessionId = SessionId('kitty-scoped-1');
        const id24 = 0x004B01;
        const id32 = 0x42004B02;
        const idDelta = 0x004B03;
        final server = _FakeServerTransportHarness();
        final transport = WsClientTransport(channelFactory: server.openChannel);
        final repo = CastClientRepository(
          transport: transport,
          enableReconnect: false,
        );
        await repo.connect();
        server.send(const AuthAcceptedFrame(role: .client));
        await Future<void>.delayed(Duration.zero);

        final port = repo.openTerminalPort(
          sessionId,
          initialCols: 16,
          initialRows: 4,
        );
        await Future<void>.delayed(Duration.zero);

        // Fallback buffer before first snapshot already carries the slot's scoped registry.
        check(
          identical(
            port.buffer.lookupKittyRegistry(0, 0),
            port.slot.kittyRegistry,
          ),
        ).isTrue();

        final snapshotBuf = Buffer.blank(16, 4)
          ..setAttributes(
            0,
            0,
            char: kittyPlaceholderCell(0, 0),
            fg: 0xFF000000 | id24,
            bg: 0,
            modifiers: Modifier.kittyPlaceholder,
            blend: false,
          )
          ..setAttributes(
            2,
            0,
            char: kittyPlaceholderCell(0, 0, imageIdMsb: 0x42),
            fg: 0xFF000000 | (id32 & 0xFFFFFF),
            bg: 0,
            modifiers: Modifier.kittyPlaceholder,
            blend: false,
          );
        final pixels24 = Uint8List.fromList(const [10, 200, 250, 255]);
        final pixels32 = Uint8List.fromList(const [20, 240, 90, 255]);

        server.send(
          BufferSnapshotFrame(
            snapshot: BufferSnapshot.fromBuffer(
              sessionId: sessionId,
              seq: 1,
              buffer: snapshotBuf,
              cursor: CursorState.origin,
              modes: TerminalModes.defaults,
              kittyImages: [
                KittyImagePayload(
                  imageId: id24,
                  pixelWidth: 1,
                  pixelHeight: 1,
                  gridCols: 1,
                  gridRows: 1,
                  bytes: pixels24,
                ),
                KittyImagePayload(
                  imageId: id32,
                  pixelWidth: 1,
                  pixelHeight: 1,
                  gridCols: 1,
                  gridRows: 1,
                  bytes: pixels32,
                ),
              ],
            ),
          ),
        );
        await Future<void>.delayed(Duration.zero);

        check(KittyImageRegistry.global.lookupImage(id24)).isNull();
        check(KittyImageRegistry.global.lookupImage(id32)).isNull();
        check(
          port.buffer.lookupKittyImage(0, 0, id24)?.rgbaPixels,
        ).isNotNull().deepEquals(pixels24);
        check(
          port.buffer.lookupKittyImage(2, 0, id32)?.rgbaPixels,
        ).isNotNull().deepEquals(pixels32);

        final pixelsDelta = Uint8List.fromList(const [255, 80, 40, 255]);
        server.send(
          BufferDeltaFrame(
            delta: BufferDelta(
              sessionId: sessionId,
              baseSeq: 1,
              seq: 2,
              cols: 16,
              rows: 4,
              cursor: CursorState.origin,
              modes: TerminalModes.defaults,
              runs: [
                CellRun(
                  startIndex: 4,
                  characters: [kittyPlaceholderCell(0, 0)],
                  attributes: Uint32List.fromList([
                    0xFF000000 | idDelta,
                    0,
                    Modifier.kittyPlaceholder,
                  ]),
                ),
              ],
              kittyRemovals: const [id24],
              kittyUpserts: [
                KittyImagePayload(
                  imageId: idDelta,
                  pixelWidth: 1,
                  pixelHeight: 1,
                  gridCols: 1,
                  gridRows: 1,
                  bytes: pixelsDelta,
                ),
              ],
            ),
          ),
        );
        await Future<void>.delayed(Duration.zero);

        check(port.buffer.lookupKittyImage(0, 0, id24)).isNull();
        check(
          port.buffer.lookupKittyImage(2, 0, id32)?.rgbaPixels,
        ).isNotNull().deepEquals(pixels32);
        check(
          port.buffer.lookupKittyImage(4, 0, idDelta)?.rgbaPixels,
        ).isNotNull().deepEquals(pixelsDelta);

        await port.dispose();
        await repo.dispose();
        await server.close();
      },
    );

    test(
      'maps CastWaveformQueryAudioPayload to TerminalWaveformQueryAudioEvent and sends AudioWaveformReplyFrame',
      () async {
        const sessionId = SessionId('wave-port-1');
        final server = _FakeServerTransportHarness();
        final transport = WsClientTransport(channelFactory: server.openChannel);
        final repo = CastClientRepository(
          transport: transport,
          enableReconnect: false,
        );
        await repo.connect();
        server.send(const AuthAcceptedFrame(role: .client));
        await Future<void>.delayed(Duration.zero);

        final port = repo.openTerminalPort(sessionId);
        final events = <TerminalAudioEvent>[];
        port.addAudioListener(events.add);

        server.send(
          const AudioFrame(
            sessionId: sessionId,
            payload: CastWaveformQueryAudioPayload(requestId: 55),
          ),
        );
        await Future<void>.delayed(Duration.zero);
        check(
          events,
        ).deepEquals([const TerminalWaveformQueryAudioEvent(requestId: 55)]);

        final samples = Float32List(256)..[10] = -0.5;
        port.sendWaveformReply(55, samples);
        await Future<void>.delayed(Duration.zero);

        final reply = server.received
            .whereType<AudioWaveformReplyFrame>()
            .single;
        check(reply.sessionId).equals(sessionId);
        check(reply.requestId).equals(55);
        check(reply.samples[10]).isCloseTo(-0.5, 1e-6);

        await port.dispose();
        await repo.dispose();
        await server.close();
      },
    );
  });

  group('Wave 1 client_core hardening', () {
    test(
      'Osc52ClipboardPolicy enforces allowFocused, deny, focus, and byte cap',
      () async {
        const settings = CastWorkspaceSettings(osc52Policy: .deny);
        final roundtrip = CastWorkspaceSettings.fromJsonString(
          settings.toJsonString(),
        );
        check(roundtrip.osc52Policy).equals(Osc52ClipboardPolicy.deny);
        check(
          roundtrip.copyWith(osc52Policy: .allowFocused).osc52Policy,
        ).equals(Osc52ClipboardPolicy.allowFocused);

        const sessionId = SessionId('osc52-policy');
        final server = _FakeServerTransportHarness();
        final transport = WsClientTransport(channelFactory: server.openChannel);
        final repo = CastClientRepository(
          transport: transport,
          enableReconnect: false,
        );
        await repo.connect();
        server.send(const AuthAcceptedFrame(role: .client));
        await Future<void>.delayed(Duration.zero);

        final port = repo.openTerminalPort(sessionId);
        final received = <(String, String)>[];
        port.addClipboardListener((sel, text) => received.add((sel, text)));

        // Focused + default allowFocused delivers small payload.
        port.maxOsc52ClipboardBytes = 4;
        server.send(const ClipboardFrame(sessionId: sessionId, text: 'abcd'));
        await Future<void>.delayed(Duration.zero);
        check(received).deepEquals(const [('c', 'abcd')]);

        // Exceeding maxOsc52ClipboardBytes drops payload.
        server.send(const ClipboardFrame(sessionId: sessionId, text: 'abcde'));
        await Future<void>.delayed(Duration.zero);
        check(received).length.equals(1);

        // Unfocused drops payload under allowFocused.
        port.isClipboardFocused = false;
        server.send(const ClipboardFrame(sessionId: sessionId, text: 'ok'));
        await Future<void>.delayed(Duration.zero);
        check(received).length.equals(1);

        // Focused + deny drops payload.
        port.isClipboardFocused = true;
        port.clipboardPolicy = .deny;
        server.send(const ClipboardFrame(sessionId: sessionId, text: 'ok'));
        await Future<void>.delayed(Duration.zero);
        check(received).length.equals(1);

        await port.dispose();
        await repo.dispose();
        await server.close();
      },
    );

    test(
      'readScrollbackSlice caches decoded ScrollbackLine per (clearSeq, width) and counts wide columns in maxHorizontalPanCols',
      () async {
        const sessionId = SessionId('sb-cache-wide');
        final server = _FakeServerTransportHarness();
        final transport = WsClientTransport(channelFactory: server.openChannel);
        final repo = CastClientRepository(
          transport: transport,
          enableReconnect: false,
        );
        await repo.connect();
        server.send(const AuthAcceptedFrame(role: .client));
        await Future<void>.delayed(Duration.zero);

        final port = repo.openTerminalPort(
          sessionId,
          initialCols: 4,
          initialRows: 2,
        );
        server.send(
          BufferSnapshotFrame(
            snapshot: _makeSnapshot(
              sessionId: sessionId,
              seq: 1,
              cols: 4,
              rows: 2,
              scrollback: const ScrollbackWindow(
                clearSeq: 1,
                oldestLine: 0,
                totalLines: 2,
              ),
            ),
          ),
        );
        final wideChars = <String>[
          '\u4e2d',
          '\u6587',
          '\u5b57',
          'a',
        ]; // 7 display cols
        server.send(
          ScrollbackChunkFrame(
            sessionId: sessionId,
            requestId: 1,
            clearSeq: 1,
            startLine: 0,
            rows: [
              EncodedScrollbackRow(
                isWrapped: false,
                characters: wideChars,
                attributes: Uint32List(wideChars.length * 3),
              ),
              EncodedScrollbackRow(
                isWrapped: false,
                characters: const [
                  '\u4e2d',
                  '',
                  '\u6587',
                  '',
                  'x',
                ], // 5 display cols
                attributes: Uint32List(5 * 3),
              ),
            ],
          ),
        );
        await Future<void>.delayed(Duration.zero);

        port.slot.scrollBy(2, viewportCols: 4, viewportRows: 2);
        check(port.slot.maxHorizontalPanCols(4, 2)).equals(3); // 7 - 4 = 3

        final firstRead = port.readScrollbackSlice(0, 2);
        final secondRead = port.readScrollbackSlice(0, 2);
        check(identical(firstRead[0], secondRead[0])).isTrue();
        check(identical(firstRead[1], secondRead[1])).isTrue();

        // clearSeq bump invalidates decoded ScrollbackLine cache.
        server.send(
          BufferSnapshotFrame(
            snapshot: _makeSnapshot(
              sessionId: sessionId,
              seq: 2,
              cols: 4,
              rows: 2,
              scrollback: const ScrollbackWindow(
                clearSeq: 2,
                oldestLine: 0,
                totalLines: 1,
              ),
            ),
          ),
        );
        server.send(
          ScrollbackChunkFrame(
            sessionId: sessionId,
            requestId: 2,
            clearSeq: 2,
            startLine: 0,
            rows: [
              EncodedScrollbackRow(
                isWrapped: false,
                characters: const ['z'],
                attributes: Uint32List(3),
              ),
            ],
          ),
        );
        await Future<void>.delayed(Duration.zero);

        final afterClear = port.readScrollbackSlice(0, 1);
        check(identical(firstRead[0], afterClear[0])).isFalse();

        await port.dispose();
        await repo.dispose();
        await server.close();
      },
    );

    test(
      'assembles multi-chunk raw/deflateRaw KittyImageChunkFrame textures via CastClientRepository, deduplicates, clears on delta/snapshot, evicts stale pending, and recovers on corrupt chunks',
      () async {
        const sessionId = SessionId('kitty-chunks-client');
        final server = _FakeServerTransportHarness();
        final transport = WsClientTransport(channelFactory: server.openChannel);
        final repo = CastClientRepository(
          transport: transport,
          enableReconnect: false,
        );
        await repo.connect();
        server.send(const AuthAcceptedFrame(role: .client));
        await Future<void>.delayed(Duration.zero);

        final port = repo.openTerminalPort(sessionId);
        var visualChanges = 0;
        port.addListener(() => visualChanges += 1);

        // Chunks received while awaitingKeyframe are ignored safely.
        server.send(
          KittyImageChunkFrame(
            sessionId: sessionId,
            imageId: 700,
            pixelWidth: 2,
            pixelHeight: 2,
            gridCols: 1,
            gridRows: 1,
            totalDecodedBytes: 16,
            totalWireBytes: 16,
            chunkIndex: 0,
            chunkCount: 1,
            data: Uint8List(16),
          ),
        );
        await Future<void>.delayed(Duration.zero);
        check(port.slot.kittyRegistry.lookupImage(700)).isNull();

        server.send(
          BufferSnapshotFrame(
            snapshot: _makeSnapshot(
              sessionId: sessionId,
              seq: 1,
              cols: 4,
              rows: 2,
            ),
          ),
        );
        await Future<void>.delayed(Duration.zero);

        // 1. Multi-chunk deflateRaw reassembly + visual notification + O(1) dedup fast path.
        final rgba = Uint8List.fromList(
          List<int>.generate(64, (i) => (i * 7) & 0xFF),
        );
        final deflated = BufferFrameCodec.compressKittyBytes(rgba);
        final half = deflated.length ~/ 2;
        final part0 = Uint8List.sublistView(deflated, 0, half);
        final part1 = Uint8List.sublistView(deflated, half);
        final revBefore = port.fullSyncRevision;
        final changesBefore = visualChanges;
        server.send(
          KittyImageChunkFrame(
            sessionId: sessionId,
            imageId: 701,
            version: 5,
            pixelWidth: 4,
            pixelHeight: 4,
            gridCols: 2,
            gridRows: 2,
            format: 32,
            encoding: .deflateRaw,
            totalDecodedBytes: 64,
            totalWireBytes: deflated.length,
            chunkIndex: 0,
            chunkCount: 2,
            data: part0,
          ),
        );
        server.send(
          KittyImageChunkFrame(
            sessionId: sessionId,
            imageId: 701,
            version: 5,
            pixelWidth: 4,
            pixelHeight: 4,
            gridCols: 2,
            gridRows: 2,
            format: 32,
            encoding: .deflateRaw,
            totalDecodedBytes: 64,
            totalWireBytes: deflated.length,
            chunkIndex: 1,
            chunkCount: 2,
            data: part1,
          ),
        );
        await Future<void>.delayed(Duration.zero);
        final assembled701 = port.slot.kittyRegistry.lookupImage(701);
        check(assembled701).isNotNull();
        check(assembled701!.rgbaPixels).deepEquals(rgba);
        check(port.fullSyncRevision).isGreaterThan(revBefore);
        check(visualChanges).isGreaterThan(changesBefore);

        // Duplicate chunk 0 with matching metadata+version is O(1) no-op.
        final revAfter701 = port.fullSyncRevision;
        server.send(
          KittyImageChunkFrame(
            sessionId: sessionId,
            imageId: 701,
            version: 5,
            pixelWidth: 4,
            pixelHeight: 4,
            gridCols: 2,
            gridRows: 2,
            format: 32,
            encoding: .deflateRaw,
            totalDecodedBytes: 64,
            totalWireBytes: deflated.length,
            chunkIndex: 0,
            chunkCount: 2,
            data: part0,
          ),
        );
        await Future<void>.delayed(Duration.zero);
        check(port.fullSyncRevision).equals(revAfter701);

        // 2. Single-chunk PNG assembly.
        final pngBytes =
            (BytesBuilder()
                  ..add(const [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
                  ..add(const [0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52])
                  ..add(const [0x00, 0x00, 0x00, 0x03, 0x00, 0x00, 0x00, 0x03])
                  ..add(const [0x08, 0x06, 0x00, 0x00, 0x00]))
                .takeBytes();
        server.send(
          KittyImageChunkFrame(
            sessionId: sessionId,
            imageId: 702,
            pixelWidth: 3,
            pixelHeight: 3,
            gridCols: 1,
            gridRows: 1,
            format: 100,
            encoding: .raw,
            totalDecodedBytes: pngBytes.length,
            totalWireBytes: pngBytes.length,
            chunkIndex: 0,
            chunkCount: 1,
            data: pngBytes,
          ),
        );
        await Future<void>.delayed(Duration.zero);
        check(
          port.slot.kittyRegistry.lookupImage(702)?.rgbaPixels,
        ).isNotNull().deepEquals(pngBytes);

        // 3. Partial assembly eviction when > maxPendingKittyAssemblies (16) and cleanup on delta removal.
        for (var i = 0; i < 18; i++) {
          server.send(
            KittyImageChunkFrame(
              sessionId: sessionId,
              imageId: 800 + i,
              pixelWidth: 2,
              pixelHeight: 2,
              gridCols: 1,
              gridRows: 1,
              totalDecodedBytes: 16,
              totalWireBytes: 16,
              chunkIndex: 0,
              chunkCount: 2,
              data: Uint8List(8),
            ),
          );
        }
        await Future<void>.delayed(Duration.zero);

        // Completing the evicted oldest assembly (800) triggers corruptFrame keyframe recovery!
        server.received.clear();
        server.send(
          KittyImageChunkFrame(
            sessionId: sessionId,
            imageId: 800,
            pixelWidth: 2,
            pixelHeight: 2,
            gridCols: 1,
            gridRows: 1,
            totalDecodedBytes: 16,
            totalWireBytes: 16,
            chunkIndex: 1,
            chunkCount: 2,
            data: Uint8List(8),
          ),
        );
        await Future<void>.delayed(Duration.zero);
        check(server.received.whereType<RequestKeyframeFrame>()).isNotEmpty();

        // Re-sync and test corrupt deflate triggers .corruptFrame + delta removals clear partial state.
        server.send(
          BufferSnapshotFrame(
            snapshot: _makeSnapshot(
              sessionId: sessionId,
              seq: 2,
              cols: 4,
              rows: 2,
            ),
          ),
        );
        await Future<void>.delayed(Duration.zero);
        server.received.clear();
        server.send(
          KittyImageChunkFrame(
            sessionId: sessionId,
            imageId: 901,
            pixelWidth: 4,
            pixelHeight: 4,
            gridCols: 1,
            gridRows: 1,
            format: 32,
            encoding: .deflateRaw,
            totalDecodedBytes: 64,
            totalWireBytes: 4,
            chunkIndex: 0,
            chunkCount: 1,
            data: Uint8List.fromList([0xFF, 0xFF, 0xFF, 0xFF]),
          ),
        );
        await Future<void>.delayed(Duration.zero);
        check(server.received.whereType<RequestKeyframeFrame>()).isNotEmpty();

        server.send(
          BufferSnapshotFrame(
            snapshot: _makeSnapshot(
              sessionId: sessionId,
              seq: 3,
              cols: 4,
              rows: 2,
            ),
          ),
        );
        await Future<void>.delayed(Duration.zero);
        server.send(
          KittyImageChunkFrame(
            sessionId: sessionId,
            imageId: 902,
            pixelWidth: 2,
            pixelHeight: 2,
            gridCols: 1,
            gridRows: 1,
            totalDecodedBytes: 16,
            totalWireBytes: 16,
            chunkIndex: 0,
            chunkCount: 2,
            data: Uint8List(8),
          ),
        );
        server.send(
          BufferDeltaFrame(
            delta: BufferDelta(
              sessionId: sessionId,
              seq: 4,
              baseSeq: 3,
              cols: 4,
              rows: 2,
              cursor: CursorState.origin,
              modes: TerminalModes.defaults,
              runs: const [],
              kittyRemovals: const [902],
            ),
          ),
        );
        await Future<void>.delayed(Duration.zero);
        // After delta removal discarded partial 902, chunk 1 alone fails safely with keyframe request.
        server.received.clear();
        server.send(
          KittyImageChunkFrame(
            sessionId: sessionId,
            imageId: 902,
            pixelWidth: 2,
            pixelHeight: 2,
            gridCols: 1,
            gridRows: 1,
            totalDecodedBytes: 16,
            totalWireBytes: 16,
            chunkIndex: 1,
            chunkCount: 2,
            data: Uint8List(8),
          ),
        );
        await Future<void>.delayed(Duration.zero);
        check(server.received.whereType<RequestKeyframeFrame>()).isNotEmpty();

        // 4. Exact 16 concurrent 2-chunk assemblies complete cleanly without evicting entry 0.
        server.send(
          BufferSnapshotFrame(
            snapshot: _makeSnapshot(
              sessionId: sessionId,
              seq: 5,
              cols: 4,
              rows: 2,
            ),
          ),
        );
        await Future<void>.delayed(Duration.zero);
        server.received.clear();
        for (var i = 0; i < 16; i++) {
          server.send(
            KittyImageChunkFrame(
              sessionId: sessionId,
              imageId: 1000 + i,
              pixelWidth: 2,
              pixelHeight: 2,
              gridCols: 1,
              gridRows: 1,
              totalDecodedBytes: 16,
              totalWireBytes: 16,
              chunkIndex: 0,
              chunkCount: 2,
              data: Uint8List(8)..[0] = i,
            ),
          );
        }
        for (var i = 0; i < 16; i++) {
          server.send(
            KittyImageChunkFrame(
              sessionId: sessionId,
              imageId: 1000 + i,
              pixelWidth: 2,
              pixelHeight: 2,
              gridCols: 1,
              gridRows: 1,
              totalDecodedBytes: 16,
              totalWireBytes: 16,
              chunkIndex: 1,
              chunkCount: 2,
              data: Uint8List(8)..[0] = i + 100,
            ),
          );
        }
        await Future<void>.delayed(Duration.zero);
        check(server.received.whereType<RequestKeyframeFrame>()).isEmpty();
        for (var i = 0; i < 16; i++) {
          final img = port.slot.kittyRegistry.lookupImage(1000 + i);
          check(img).isNotNull();
          check(img!.rgbaPixels[0]).equals(i);
          check(img.rgbaPixels[8]).equals(i + 100);
        }

        // 5. >32 MiB cumulative wire bytes evicts oldest assembly (1100) while preserving active (1102).
        final chunk500K = Uint8List(500 * 1000);
        for (final id in [1100, 1101]) {
          for (var c = 0; c < 31; c++) {
            server.send(
              KittyImageChunkFrame(
                sessionId: sessionId,
                imageId: id,
                pixelWidth: 2000,
                pixelHeight: 2000,
                gridCols: 4,
                gridRows: 2,
                totalDecodedBytes: 16 * 1000 * 1000,
                totalWireBytes: 16 * 1000 * 1000,
                chunkIndex: c,
                chunkCount: 32,
                data: chunk500K,
              ),
            );
          }
        }
        for (var c = 0; c < 7; c++) {
          server.send(
            KittyImageChunkFrame(
              sessionId: sessionId,
              imageId: 1102,
              pixelWidth: 1000,
              pixelHeight: 1000,
              gridCols: 2,
              gridRows: 1,
              totalDecodedBytes: 4 * 1000 * 1000,
              totalWireBytes: 4 * 1000 * 1000,
              chunkIndex: c,
              chunkCount: 8,
              data: chunk500K,
            ),
          );
        }
        server.send(
          KittyImageChunkFrame(
            sessionId: sessionId,
            imageId: 1102,
            pixelWidth: 1000,
            pixelHeight: 1000,
            gridCols: 2,
            gridRows: 1,
            totalDecodedBytes: 4 * 1000 * 1000,
            totalWireBytes: 4 * 1000 * 1000,
            chunkIndex: 7,
            chunkCount: 8,
            data: chunk500K,
          ),
        );
        await Future<void>.delayed(Duration.zero);
        check(port.slot.kittyRegistry.lookupImage(1102)).isNotNull();
        // Oldest assembly (1100) was evicted when 1102 crossed the 32 MiB cap.
        server.received.clear();
        server.send(
          KittyImageChunkFrame(
            sessionId: sessionId,
            imageId: 1100,
            pixelWidth: 2000,
            pixelHeight: 2000,
            gridCols: 4,
            gridRows: 2,
            totalDecodedBytes: 16 * 1000 * 1000,
            totalWireBytes: 16 * 1000 * 1000,
            chunkIndex: 31,
            chunkCount: 32,
            data: chunk500K,
          ),
        );
        await Future<void>.delayed(Duration.zero);
        check(server.received.whereType<RequestKeyframeFrame>()).isNotEmpty();

        // 6. Header mismatch, out-of-order chunkIndex, and invalid PNG IHDR trigger corruptFrame recovery,
        // and _enterAwaitingKeyframe discards unrelated pending assemblies.
        for (final badCase in ['header_mismatch', 'out_of_order', 'bad_png']) {
          server.send(
            BufferSnapshotFrame(
              snapshot: _makeSnapshot(
                sessionId: sessionId,
                seq: 6,
                cols: 4,
                rows: 2,
              ),
            ),
          );
          await Future<void>.delayed(Duration.zero);
          // Start an unrelated pending assembly to confirm _enterAwaitingKeyframe discards it.
          server.send(
            KittyImageChunkFrame(
              sessionId: sessionId,
              imageId: 1299,
              pixelWidth: 2,
              pixelHeight: 2,
              gridCols: 1,
              gridRows: 1,
              totalDecodedBytes: 16,
              totalWireBytes: 16,
              chunkIndex: 0,
              chunkCount: 2,
              data: Uint8List(8),
            ),
          );
          server.received.clear();
          if (badCase == 'bad_png') {
            final bogusPngDeflated = BufferFrameCodec.compressKittyBytes(
              Uint8List.fromList(List<int>.filled(32, 0x7A)),
            );
            server.send(
              KittyImageChunkFrame(
                sessionId: sessionId,
                imageId: 1200,
                pixelWidth: 2,
                pixelHeight: 2,
                gridCols: 1,
                gridRows: 1,
                format: 100,
                encoding: .deflateRaw,
                totalDecodedBytes: 32,
                totalWireBytes: bogusPngDeflated.length,
                chunkIndex: 0,
                chunkCount: 1,
                data: bogusPngDeflated,
              ),
            );
          } else {
            server.send(
              KittyImageChunkFrame(
                sessionId: sessionId,
                imageId: 1200,
                pixelWidth: 2,
                pixelHeight: 2,
                gridCols: 1,
                gridRows: 1,
                totalDecodedBytes: 16,
                totalWireBytes: 16,
                chunkIndex: 0,
                chunkCount: 3,
                data: Uint8List(6),
              ),
            );
            server.send(
              KittyImageChunkFrame(
                sessionId: sessionId,
                imageId: 1200,
                pixelWidth: badCase == 'header_mismatch' ? 4 : 2,
                pixelHeight: badCase == 'header_mismatch' ? 1 : 2,
                gridCols: 1,
                gridRows: 1,
                totalDecodedBytes: 16,
                totalWireBytes: 16,
                chunkIndex: badCase == 'out_of_order' ? 2 : 1,
                chunkCount: 3,
                data: Uint8List(6),
              ),
            );
          }
          await Future<void>.delayed(Duration.zero);
          check(server.received.whereType<RequestKeyframeFrame>()).isNotEmpty();
          check(
            port.slot.state,
          ).equals(ClientSessionSyncState.awaitingKeyframe);
        }

        await port.dispose();
        await repo.dispose();
        await server.close();
      },
    );
  });
}
