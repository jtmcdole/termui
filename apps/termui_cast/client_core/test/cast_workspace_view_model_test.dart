import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:checks/checks.dart';
import 'package:fake_async/fake_async.dart';
import 'package:stream_channel/stream_channel.dart';
import 'package:termui/terminal/event.dart' as ev;
import 'package:termui/termui.dart';
import 'package:termui_cast_client_core/src/transport/ws_channel_adapter.dart';
import 'package:termui_cast_client_core/src/transport/ws_connector_stub.dart'
    as browser_stub;
import 'package:termui_cast_client_core/termui_cast_client_core.dart';
import 'package:termui_cast_protocol/termui_cast_protocol.dart';
import 'package:termui_cast_server/termui_cast_server.dart';
import 'package:termui_test/termui_test.dart';
import 'package:test/test.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

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

const String _testPinSha256 =
    '5e6b75f8fd8e0d30efe0c22865759e235ccc2bf2d86d6855fa72c513fd8cdfbb';

BufferSnapshot _makeSnapshot(
  SessionId id, {
  required int seq,
  required int cols,
  required int rows,
  String text = '',
  CursorState cursor = CursorState.origin,
  TerminalModes modes = TerminalModes.defaults,
  bool transparentCells = false,
}) {
  final buf = transparentCells ? Buffer(cols, rows) : Buffer.blank(cols, rows);
  if (text.isNotEmpty) {
    buf.writeString(0, 0, text, const Style());
  }
  return BufferSnapshot.fromBuffer(
    sessionId: id,
    seq: seq,
    buffer: buf,
    cursor: cursor,
    modes: modes,
  );
}

void main() {
  const sessA = SessionId('sess-a');
  const sessB = SessionId('sess-b');

  group('CastWorkspaceViewModel HSM gating and recovery', () {
    test(
      'drops pre-snapshot deltas while AwaitingKeyframe and recovers on baseSeq gap',
      () async {
        final pipe = StreamChannelController<Uint8List>();
        final sentByClient = <CastMessage>[];
        pipe.foreign.stream.listen((raw) {
          sentByClient.add(BufferFrameCodec.decode(raw));
        });

        final transport = WsClientTransport(
          token: 'v-tok',
          channelFactory: () async => pipe.local,
        );
        final repo = CastClientRepository(transport: transport);
        final vm = CastWorkspaceViewModel(
          repository: repo,
          initialViewportCols: 20,
          initialViewportRows: 5,
        );
        addTearDown(() async {
          await vm.dispose();
          await repo.dispose();
        });

        var notifications = 0;
        final unsub = vm.addVisualListener(() => notifications++);
        addTearDown(unsub);

        await repo.connect();
        await pumpEventQueue();
        check(sentByClient.single).isA<AuthFrame>();
        sentByClient.clear();

        // Announce sessA -> auto-subscribes and enters awaitingKeyframe.
        pipe.foreign.sink.add(
          BufferFrameCodec.encode(
            const SessionDirectoryFrame(
              sessions: [
                SessionSummary(id: sessA, title: 'zsh', cols: 20, rows: 5),
              ],
            ),
          ),
        );
        await pumpEventQueue();

        check(vm.activeSessionId).equals(sessA);
        check(
          vm.sessionStateOf(sessA),
        ).equals(ClientSessionSyncState.awaitingKeyframe);
        check(sentByClient.single).isA<SubscribeSessionFrame>();
        sentByClient.clear();

        // Send a delta BEFORE snapshot arrives -> strictly dropped!
        pipe.foreign.sink.add(
          BufferFrameCodec.encode(
            BufferDeltaFrame(
              delta: BufferDelta(
                sessionId: sessA,
                seq: 10,
                baseSeq: 9,
                cols: 20,
                rows: 5,
                cursor: const CursorState(x: 3, y: 0),
                modes: TerminalModes.defaults,
                runs: [
                  CellRun(
                    startIndex: 0,
                    characters: const ['X'],
                    attributes: Uint32List(3),
                  ),
                ],
              ),
            ),
          ),
        );
        await pumpEventQueue();
        check(
          vm.sessionStateOf(sessA),
        ).equals(ClientSessionSyncState.awaitingKeyframe);
        check(
          vm.composeActiveBufferWithCursor().getCharacter(0, 0),
        ).equals(' ');

        // Deliver authoritative snapshot seq=11 -> enters synchronized!
        pipe.foreign.sink.add(
          BufferFrameCodec.encode(
            BufferSnapshotFrame(
              snapshot: _makeSnapshot(
                sessA,
                seq: 11,
                cols: 20,
                rows: 5,
                text: 'HELLO',
                cursor: const CursorState(x: 5, y: 0),
                transparentCells: true,
              ),
            ),
          ),
        );
        await pumpEventQueue();
        check(
          vm.sessionStateOf(sessA),
        ).equals(ClientSessionSyncState.synchronized);
        check(notifications).isGreaterThan(0);

        // Verify cursor cell clears Modifier.transparent and sets Modifier.reverse
        // without mutating the underlying hydrated buffer!
        final composed = vm.composeActiveBufferWithCursor();
        check(composed.getCharacter(0, 0)).equals('H');
        final cursorMods = composed.getModifiers(5, 0);
        check(cursorMods & Modifier.transparent).equals(0);
        check(cursorMods & Modifier.reverse).not((it) => it.equals(0));

        // Subsequent valid delta seq=12 (baseSeq=11) applies cleanly!
        pipe.foreign.sink.add(
          BufferFrameCodec.encode(
            BufferDeltaFrame(
              delta: BufferDelta(
                sessionId: sessA,
                seq: 12,
                baseSeq: 11,
                cols: 20,
                rows: 5,
                cursor: const CursorState(x: 6, y: 0),
                modes: TerminalModes.defaults,
                runs: [
                  CellRun(
                    startIndex: 5,
                    characters: const ['!'],
                    attributes: Uint32List(3),
                  ),
                ],
              ),
            ),
          ),
        );
        // Duplicate seq=12 is ignored cleanly.
        pipe.foreign.sink.add(
          BufferFrameCodec.encode(
            BufferDeltaFrame(
              delta: BufferDelta(
                sessionId: sessA,
                seq: 12,
                baseSeq: 11,
                cols: 20,
                rows: 5,
                cursor: const CursorState(x: 6, y: 0),
                modes: TerminalModes.defaults,
                runs: const [],
              ),
            ),
          ),
        );
        await pumpEventQueue();
        check(
          vm.composeActiveBufferWithCursor().getCharacter(5, 0),
        ).equals('!');

        // Deliver delta with baseSeq gap (seq=15, baseSeq=14 != 12) -> transitions
        // back to awaitingKeyframe and sends RequestKeyframeFrame without corrupting buffer!
        pipe.foreign.sink.add(
          BufferFrameCodec.encode(
            BufferDeltaFrame(
              delta: BufferDelta(
                sessionId: sessA,
                seq: 15,
                baseSeq: 14,
                cols: 20,
                rows: 5,
                cursor: CursorState.origin,
                modes: TerminalModes.defaults,
                runs: const [],
              ),
            ),
          ),
        );
        await pumpEventQueue();
        check(
          vm.sessionStateOf(sessA),
        ).equals(ClientSessionSyncState.awaitingKeyframe);
        check(sentByClient.single).isA<RequestKeyframeFrame>();
      },
    );

    test(
      'auto-reconnects transport on drop and re-subscribes active session on caster restart with reset seq',
      () {
        fakeAsync((async) {
          final pipes = <StreamChannelController<Uint8List>>[];
          final sentPerPipe = <List<CastMessage>>[];
          var failFirstConnect = true;

          final transport = WsClientTransport(
            token: 'v-tok',
            channelFactory: () async {
              if (failFirstConnect) {
                failFirstConnect = false;
                throw const SocketException('Relay starting up');
              }
              final ctrl = StreamChannelController<Uint8List>();
              final sent = <CastMessage>[];
              ctrl.foreign.stream.listen(
                (raw) => sent.add(BufferFrameCodec.decode(raw)),
              );
              pipes.add(ctrl);
              sentPerPipe.add(sent);
              return ctrl.local;
            },
          );
          final repo = CastClientRepository(transport: transport);
          final vm = CastWorkspaceViewModel(
            repository: repo,
            initialViewportCols: 80,
            initialViewportRows: 23,
          );

          var disconnects = 0;
          clientDisconnectedEvent.addListener(repo.bus, (_) => disconnects++);

          // Initial connect with retryOnFailure: true backs off and connects on attempt 2!
          unawaited(repo.connect(retryOnFailure: true));
          async.flushMicrotasks();
          check(pipes).isEmpty();
          async.elapse(const Duration(milliseconds: 500));
          check(pipes.length).equals(1);

          // Initial session at seq=10.
          pipes[0].foreign.sink.add(
            BufferFrameCodec.encode(
              const SessionDirectoryFrame(
                sessions: [
                  SessionSummary(id: sessA, title: 'zsh', cols: 80, rows: 23),
                ],
              ),
            ),
          );
          pipes[0].foreign.sink.add(
            BufferFrameCodec.encode(
              BufferSnapshotFrame(
                snapshot: _makeSnapshot(
                  sessA,
                  seq: 10,
                  cols: 80,
                  rows: 23,
                  text: 'GEN1',
                ),
              ),
            ),
          );
          async.flushMicrotasks();
          check(
            vm.sessionStateOf(sessA),
          ).equals(ClientSessionSyncState.synchronized);

          // 1. Caster restarts with same SessionId -> seq resets to 1!
          pipes[0].foreign.sink.add(
            BufferFrameCodec.encode(
              const SessionClosedFrame(sessionId: sessA, exitCode: -1),
            ),
          );
          pipes[0].foreign.sink.add(
            BufferFrameCodec.encode(const SessionDirectoryFrame(sessions: [])),
          );
          async.flushMicrotasks();
          check(vm.exitCodeOf(sessA)).equals(-1);
          // Input while unsubscribed is ignored cleanly.
          check(vm.sendRawInputBytes(const [0x61])).isFalse();
          sentPerPipe[0].clear();

          // Caster reconnects with same SessionId and emits seq=1 snapshot!
          pipes[0].foreign.sink.add(
            BufferFrameCodec.encode(
              const SessionDirectoryFrame(
                sessions: [
                  SessionSummary(id: sessA, title: 'zsh', cols: 80, rows: 23),
                ],
              ),
            ),
          );
          async.flushMicrotasks();
          check(sentPerPipe[0]).any((it) => it.isA<SubscribeSessionFrame>());
          check(vm.exitCodeOf(sessA)).isNull();

          pipes[0].foreign.sink.add(
            BufferFrameCodec.encode(
              BufferSnapshotFrame(
                snapshot: _makeSnapshot(
                  sessA,
                  seq: 1,
                  cols: 80,
                  rows: 23,
                  text: 'GEN2',
                ),
              ),
            ),
          );
          async.flushMicrotasks();
          check(
            vm.composeActiveBufferWithCursor().getCharacter(3, 0),
          ).equals('2');

          // 2. Client WebSocket drops -> fires clientDisconnectedEvent, reconnects on pipes[1], and re-subscribes!
          unawaited(pipes[0].foreign.sink.close());
          async.flushMicrotasks();
          check(disconnects).equals(1);
          check(
            vm.sessionStateOf(sessA),
          ).equals(ClientSessionSyncState.unsubscribed);

          async.elapse(const Duration(milliseconds: 500));
          check(pipes.length).equals(2);
          check(sentPerPipe[1].first).isA<AuthFrame>();

          pipes[1].foreign.sink.add(
            BufferFrameCodec.encode(
              const SessionDirectoryFrame(
                sessions: [
                  SessionSummary(id: sessA, title: 'zsh', cols: 80, rows: 23),
                ],
              ),
            ),
          );
          async.flushMicrotasks();
          check(sentPerPipe[1]).any((it) => it.isA<SubscribeSessionFrame>());

          // 3. Fatal auth_failed error stops reconnect loop on subsequent close.
          pipes[1].foreign.sink.add(
            BufferFrameCodec.encode(
              const ErrorFrame(code: 'auth_failed', message: 'Bad token'),
            ),
          );
          unawaited(pipes[1].foreign.sink.close());
          async.elapse(const Duration(seconds: 5));
          check(pipes.length).equals(2);

          unawaited(vm.dispose());
          unawaited(repo.dispose());
          async.flushMicrotasks();
        });
      },
    );

    test(
      'preserves selected tab (e.g. Tab 3) across transient session disconnect instead of jumping to Tab 1',
      () async {
        const sessC = SessionId('sess-c');
        final pipe = StreamChannelController<Uint8List>();
        final sentByClient = <CastMessage>[];
        pipe.foreign.stream.listen((raw) {
          sentByClient.add(BufferFrameCodec.decode(raw));
        });

        final transport = WsClientTransport(
          token: 'v-tok',
          channelFactory: () async => pipe.local,
        );
        final repo = CastClientRepository(transport: transport);
        final vm = CastWorkspaceViewModel(
          repository: repo,
          initialViewportCols: 80,
          initialViewportRows: 23,
        );
        addTearDown(() async {
          await vm.dispose();
          await repo.dispose();
        });

        await repo.connect();
        await pumpEventQueue();
        sentByClient.clear();

        // Announce 3 sessions [sessA, sessB, sessC].
        pipe.foreign.sink.add(
          BufferFrameCodec.encode(
            const SessionDirectoryFrame(
              sessions: [
                SessionSummary(id: sessA, title: 'tab1', cols: 80, rows: 23),
                SessionSummary(id: sessB, title: 'tab2', cols: 80, rows: 23),
                SessionSummary(id: sessC, title: 'tab3', cols: 80, rows: 23),
              ],
            ),
          ),
        );
        await pumpEventQueue();

        // Select Tab 3 (sessC) and hydrate it.
        await vm.selectSession(sessC);
        pipe.foreign.sink.add(
          BufferFrameCodec.encode(
            BufferSnapshotFrame(
              snapshot: _makeSnapshot(
                sessC,
                seq: 1,
                cols: 80,
                rows: 23,
                text: 'TAB3',
              ),
            ),
          ),
        );
        await pumpEventQueue();
        check(vm.activeSessionId).equals(sessC);
        sentByClient.clear();

        // Tab 3 disconnects while Tab 1 and Tab 2 remain live in the directory.
        pipe.foreign.sink.add(
          BufferFrameCodec.encode(
            const SessionClosedFrame(sessionId: sessC, exitCode: -1),
          ),
        );
        pipe.foreign.sink.add(
          BufferFrameCodec.encode(
            const SessionDirectoryFrame(
              sessions: [
                SessionSummary(id: sessA, title: 'tab1', cols: 80, rows: 23),
                SessionSummary(id: sessB, title: 'tab2', cols: 80, rows: 23),
              ],
            ),
          ),
        );
        await pumpEventQueue();

        // Active tab stays on Tab 3 (sessC) at index 2 with exitCode -1!
        check(vm.activeSessionId).equals(sessC);
        check(vm.exitCodeOf(sessC)).equals(-1);
        check(
          vm.sessions.map((s) => s.id).toList(),
        ).deepEquals([sessA, sessB, sessC]);
        check(sentByClient).isEmpty();

        // Tab 3 reconnects -> automatically re-subscribes Tab 3 without switching tabs.
        pipe.foreign.sink.add(
          BufferFrameCodec.encode(
            const SessionDirectoryFrame(
              sessions: [
                SessionSummary(id: sessA, title: 'tab1', cols: 80, rows: 23),
                SessionSummary(id: sessB, title: 'tab2', cols: 80, rows: 23),
                SessionSummary(id: sessC, title: 'tab3', cols: 80, rows: 23),
              ],
            ),
          ),
        );
        await pumpEventQueue();

        check(vm.activeSessionId).equals(sessC);
        check(vm.exitCodeOf(sessC)).isNull();
        check(sentByClient.single)
            .isA<SubscribeSessionFrame>()
            .has((f) => f.sessionId, 'sessionId')
            .equals(sessC);

        // If Tab 3 exits and the user manually selects Tab 1, Tab 3 stays retained until dismissed.
        pipe.foreign.sink.add(
          BufferFrameCodec.encode(
            const SessionClosedFrame(sessionId: sessC, exitCode: 0),
          ),
        );
        pipe.foreign.sink.add(
          BufferFrameCodec.encode(
            const SessionDirectoryFrame(
              sessions: [
                SessionSummary(id: sessA, title: 'tab1', cols: 80, rows: 23),
                SessionSummary(id: sessB, title: 'tab2', cols: 80, rows: 23),
              ],
            ),
          ),
        );
        await pumpEventQueue();
        check(vm.activeSessionId).equals(sessC);

        await vm.selectSession(sessA);
        check(vm.activeSessionId).equals(sessA);
        check(vm.exitCodeOf(sessC)).equals(0);
        check(
          vm.sessions.map((s) => s.id).toList(),
        ).deepEquals([sessA, sessB, sessC]);

        check(await vm.dismissSession(sessC)).isTrue();
        check(vm.exitCodeOf(sessC)).isNull();
        check(vm.sessions.map((s) => s.id).toList()).deepEquals([sessA, sessB]);
      },
    );
  });

  group('Resize debounce, tab-switch resize, and input normalization', () {
    test('debounces rapid resizes and emits ResizeFrame on tab switch', () {
      fakeAsync((async) {
        final pipe = StreamChannelController<Uint8List>();
        final sentByClient = <CastMessage>[];
        pipe.foreign.stream.listen((raw) {
          sentByClient.add(BufferFrameCodec.decode(raw));
        });

        final transport = WsClientTransport(
          channelFactory: () async => pipe.local,
        );
        final repo = CastClientRepository(transport: transport);
        final vm = CastWorkspaceViewModel(
          repository: repo,
          initialViewportCols: 80,
          initialViewportRows: 23,
        );

        unawaited(repo.connect());
        async.flushMicrotasks();
        sentByClient.clear();

        pipe.foreign.sink.add(
          BufferFrameCodec.encode(
            const SessionDirectoryFrame(
              sessions: [
                SessionSummary(id: sessA, title: 'one', cols: 80, rows: 23),
                SessionSummary(id: sessB, title: 'two', cols: 80, rows: 24),
              ],
            ),
          ),
        );
        pipe.foreign.sink.add(
          BufferFrameCodec.encode(
            BufferSnapshotFrame(
              snapshot: _makeSnapshot(sessA, seq: 1, cols: 80, rows: 23),
            ),
          ),
        );
        async.flushMicrotasks();
        sentByClient.clear();

        // Rapid resizes coalesce within 32ms into a single ResizeFrame(100, 29).
        vm.resizeActiveViewport(90, 26);
        async.elapse(const Duration(milliseconds: 16));
        vm.resizeActiveViewport(100, 29);
        check(sentByClient).isEmpty();
        async.elapse(const Duration(milliseconds: 32));
        check(sentByClient.single).equalsOrSameResize(sessA, 100, 29);
        sentByClient.clear();

        // Hydrate sessA at 100x29.
        pipe.foreign.sink.add(
          BufferFrameCodec.encode(
            BufferSnapshotFrame(
              snapshot: _makeSnapshot(sessA, seq: 2, cols: 100, rows: 29),
            ),
          ),
        );
        async.flushMicrotasks();

        // Switch to sessB (announced as 80x24) -> SubscribeSessionFrame carries 100x29 directly without duplicate ResizeFrame!
        unawaited(vm.cycleSession(1));
        async.flushMicrotasks();
        check(vm.activeSessionId).equals(sessB);
        check(sentByClient.length).equals(1);
        check(sentByClient.single)
            .isA<SubscribeSessionFrame>()
            .has((f) => (f.cols, f.rows), 'dims')
            .equals((100, 29));
        sentByClient.clear();

        // Hydrate sessB at 100x29, then resize viewport to 120x35, then switch back to sessA!
        pipe.foreign.sink.add(
          BufferFrameCodec.encode(
            BufferSnapshotFrame(
              snapshot: _makeSnapshot(sessB, seq: 1, cols: 100, rows: 29),
            ),
          ),
        );
        async.flushMicrotasks();
        vm.resizeActiveViewport(120, 35);
        async.elapse(const Duration(milliseconds: 32));
        sentByClient.clear();

        unawaited(vm.selectSession(sessA));
        async.flushMicrotasks();
        check(sentByClient.single).equalsOrSameResize(sessA, 120, 35);
        sentByClient.clear();

        // Dock cycling and automatic 10s inactive-tab unsubscription.
        vm.cycleDockPosition();
        check(vm.dockPosition).equals(DockPosition.left);
        vm.setDockPosition(.hidden);
        check(vm.dockPosition).equals(DockPosition.hidden);

        async.elapse(const Duration(seconds: 10));
        check(
          vm.sessionStateOf(sessB),
        ).equals(ClientSessionSyncState.unsubscribed);
        check(sentByClient.single).isA<UnsubscribeSessionFrame>();

        pipe.foreign.sink.add(
          BufferFrameCodec.encode(
            const SessionClosedFrame(sessionId: sessA, exitCode: 42),
          ),
        );
        async.flushMicrotasks();
        check(vm.exitCodeOf(sessA)).equals(42);

        unawaited(vm.dispose());
        unawaited(repo.dispose());
        async.flushMicrotasks();
      });
    });

    test(
      'normalizes backtab, C0 punctuation, Ctrl+C, and SGR mouse bounds',
      () async {
        final pipe = StreamChannelController<Uint8List>();
        final inputPayloads = <Uint8List>[];
        pipe.foreign.stream.listen((raw) {
          final msg = BufferFrameCodec.decode(raw);
          if (msg is InputFrame) {
            inputPayloads.add(msg.data);
          }
        });

        final transport = WsClientTransport(
          channelFactory: () async => pipe.local,
        );
        final repo = CastClientRepository(transport: transport);
        final vm = CastWorkspaceViewModel(repository: repo);
        addTearDown(() async {
          await vm.dispose();
          await repo.dispose();
        });

        await repo.connect();
        pipe.foreign.sink.add(
          BufferFrameCodec.encode(
            const SessionDirectoryFrame(
              sessions: [
                SessionSummary(id: sessA, title: 'sh', cols: 80, rows: 24),
              ],
            ),
          ),
        );
        pipe.foreign.sink.add(
          BufferFrameCodec.encode(
            BufferSnapshotFrame(
              snapshot: _makeSnapshot(sessA, seq: 1, cols: 80, rows: 24),
            ),
          ),
        );
        await pumpEventQueue();

        // 1. Shift+Tab / backtab -> \x1b[Z
        check(
          vm.encodeAndSendKey(
            const ev.KeyEvent(
              'backtab',
              ev.KeyType.tab,
              modifiers: {ev.Modifier.shift},
            ),
          ),
        ).isTrue();
        // 2. Ctrl+C -> 0x03
        check(
          vm.encodeAndSendKey(
            const ev.KeyEvent(
              'c',
              ev.KeyType.character,
              modifiers: {ev.Modifier.control},
            ),
          ),
        ).isTrue();
        // 3. Ctrl+\ -> 0x1c, Ctrl+] -> 0x1d, Ctrl+_ -> 0x1f, Ctrl+Space -> 0x00
        check(
          vm.encodeAndSendKey(
            const ev.KeyEvent(
              r'\',
              ev.KeyType.character,
              modifiers: {ev.Modifier.control},
            ),
          ),
        ).isTrue();
        check(
          vm.encodeAndSendKey(
            const ev.KeyEvent(
              ']',
              ev.KeyType.character,
              modifiers: {ev.Modifier.control},
            ),
          ),
        ).isTrue();
        check(
          vm.encodeAndSendKey(
            const ev.KeyEvent(
              '_',
              ev.KeyType.character,
              modifiers: {ev.Modifier.control},
            ),
          ),
        ).isTrue();
        check(
          vm.encodeAndSendKey(
            const ev.KeyEvent(
              ' ',
              ev.KeyType.character,
              modifiers: {ev.Modifier.control},
            ),
          ),
        ).isTrue();
        check(vm.sendRawInputBytes([0x1c])).isTrue();

        // 4. Mouse ignored when mouseTracking is false, and uses X10 fallback when sgrMouse is false!
        check(
          vm.encodeAndSendMouse(
            const ev.MouseEvent(
              x: 4,
              y: 2,
              button: ev.MouseButton.left,
              type: ev.MouseEventType.press,
            ),
          ),
        ).isFalse();

        pipe.foreign.sink.add(
          BufferFrameCodec.encode(
            BufferSnapshotFrame(
              snapshot: _makeSnapshot(
                sessA,
                seq: 2,
                cols: 80,
                rows: 24,
                modes: const TerminalModes(
                  mouseTracking: true,
                  sgrMouse: false,
                ),
              ),
            ),
          ),
        );
        await pumpEventQueue();
        // Coordinates > 223 are dropped in X10 mode, while 1..223 emit X10 ESC[M bytes.
        check(
          vm.encodeAndSendMouse(
            const ev.MouseEvent(
              x: 224,
              y: 2,
              button: ev.MouseButton.left,
              type: ev.MouseEventType.press,
            ),
          ),
        ).isFalse();
        check(
          vm.encodeAndSendMouse(
            const ev.MouseEvent(
              x: 100,
              y: 2,
              button: ev.MouseButton.wheelUp,
              type: ev.MouseEventType.press,
            ),
          ),
        ).isTrue();

        // Enable both mouseTracking and sgrMouse on sessA -> valid click forwards,
        // while (-1, -1) and in-bounds hover (move + MouseButton.none) drop!
        pipe.foreign.sink.add(
          BufferFrameCodec.encode(
            BufferSnapshotFrame(
              snapshot: _makeSnapshot(
                sessA,
                seq: 3,
                cols: 80,
                rows: 24,
                modes: const TerminalModes(mouseTracking: true, sgrMouse: true),
              ),
            ),
          ),
        );
        await pumpEventQueue();

        check(
          vm.encodeAndSendMouse(
            const ev.MouseEvent(
              x: -1,
              y: -1,
              button: ev.MouseButton.none,
              type: ev.MouseEventType.move,
            ),
          ),
        ).isFalse();
        check(
          vm.encodeAndSendMouse(
            const ev.MouseEvent(
              x: -1,
              y: -1,
              button: ev.MouseButton.left,
              type: ev.MouseEventType.release,
            ),
          ),
        ).isFalse();
        check(
          vm.encodeAndSendMouse(
            const ev.MouseEvent(
              x: 4,
              y: 2,
              button: ev.MouseButton.none,
              type: ev.MouseEventType.move,
            ),
          ),
        ).isFalse();
        check(
          vm.encodeAndSendMouse(
            const ev.MouseEvent(
              x: 4,
              y: 2,
              button: ev.MouseButton.left,
              type: ev.MouseEventType.press,
            ),
          ),
        ).isTrue();

        await pumpEventQueue();
        check(inputPayloads).deepEquals([
          utf8.encode('\x1b[Z'),
          Uint8List.fromList([0x03]),
          Uint8List.fromList([0x1c]),
          Uint8List.fromList([0x1d]),
          Uint8List.fromList([0x1f]),
          Uint8List.fromList([0x00]),
          Uint8List.fromList([0x1c]),
          Uint8List.fromList([0x1b, 0x5b, 0x4d, 32 + 64, 32 + 100, 32 + 2]),
          utf8.encode('\x1b[<0;4;2M'),
        ]);
      },
    );

    test(
      'encodes DECCKM application cursor keys and Alternate Scroll (?1007h) on altScreen',
      () async {
        final pipe = StreamChannelController<Uint8List>();
        final inputPayloads = <Uint8List>[];
        pipe.foreign.stream.listen((raw) {
          final msg = BufferFrameCodec.decode(raw);
          if (msg is InputFrame) {
            inputPayloads.add(msg.data);
          }
        });

        final transport = WsClientTransport(
          channelFactory: () async => pipe.local,
        );
        final repo = CastClientRepository(transport: transport);
        final vm = CastWorkspaceViewModel(repository: repo);
        addTearDown(() async {
          await vm.dispose();
          await repo.dispose();
        });

        await repo.connect();
        pipe.foreign.sink.add(
          BufferFrameCodec.encode(
            const SessionDirectoryFrame(
              sessions: [
                SessionSummary(id: sessA, title: 'less', cols: 80, rows: 24),
              ],
            ),
          ),
        );

        // Primary screen (altScreen: false): wheelUp consumes locally without emitting alternate scroll.
        pipe.foreign.sink.add(
          BufferFrameCodec.encode(
            BufferSnapshotFrame(
              snapshot: _makeSnapshot(sessA, seq: 1, cols: 80, rows: 24),
            ),
          ),
        );
        await pumpEventQueue();
        check(
          vm.handlePtyMouseEvent(
            const ev.MouseEvent(
              x: 1,
              y: 1,
              button: ev.MouseButton.wheelUp,
              type: ev.MouseEventType.press,
            ),
          ),
        ).isTrue();
        check(inputPayloads).isEmpty();

        // Alt screen + normal cursor keys -> CSI A / CSI B.
        pipe.foreign.sink.add(
          BufferFrameCodec.encode(
            BufferSnapshotFrame(
              snapshot: _makeSnapshot(
                sessA,
                seq: 2,
                cols: 80,
                rows: 24,
                modes: const TerminalModes(
                  altScreen: true,
                  appCursorKeys: false,
                  alternateScroll: true,
                ),
              ),
            ),
          ),
        );
        await pumpEventQueue();
        check(
          vm.handlePtyMouseEvent(
            const ev.MouseEvent(
              x: 1,
              y: 1,
              button: ev.MouseButton.wheelUp,
              type: ev.MouseEventType.press,
            ),
          ),
        ).isTrue();
        check(
          vm.handlePtyMouseEvent(
            const ev.MouseEvent(
              x: 1,
              y: 1,
              button: ev.MouseButton.wheelDown,
              type: ev.MouseEventType.press,
            ),
          ),
        ).isTrue();

        // Alt screen + DECCKM appCursorKeys -> SS3 OA / SS3 OB for wheel and arrow keys.
        pipe.foreign.sink.add(
          BufferFrameCodec.encode(
            BufferSnapshotFrame(
              snapshot: _makeSnapshot(
                sessA,
                seq: 3,
                cols: 80,
                rows: 24,
                modes: const TerminalModes(
                  altScreen: true,
                  appCursorKeys: true,
                  alternateScroll: true,
                ),
              ),
            ),
          ),
        );
        await pumpEventQueue();
        check(
          vm.handlePtyMouseEvent(
            const ev.MouseEvent(
              x: 1,
              y: 1,
              button: ev.MouseButton.wheelUp,
              type: ev.MouseEventType.press,
            ),
          ),
        ).isTrue();
        check(
          vm.encodeAndSendKey(const ev.KeyEvent('up', ev.KeyType.up)),
        ).isTrue();

        // Alt screen with alternateScroll: false -> drops wheel events.
        pipe.foreign.sink.add(
          BufferFrameCodec.encode(
            BufferSnapshotFrame(
              snapshot: _makeSnapshot(
                sessA,
                seq: 4,
                cols: 80,
                rows: 24,
                modes: const TerminalModes(
                  altScreen: true,
                  appCursorKeys: true,
                  alternateScroll: false,
                ),
              ),
            ),
          ),
        );
        await pumpEventQueue();
        check(
          vm.handlePtyMouseEvent(
            const ev.MouseEvent(
              x: 1,
              y: 1,
              button: ev.MouseButton.wheelUp,
              type: ev.MouseEventType.press,
            ),
          ),
        ).isFalse();

        await pumpEventQueue();
        check(inputPayloads).deepEquals([
          utf8.encode('\x1b[A'),
          utf8.encode('\x1b[B'),
          utf8.encode('\x1bOA'),
          utf8.encode('\x1bOA'),
        ]);
      },
    );

    test(
      'clamps oversized 480x120 and 520x260 viewports to protocol maxGridCols/maxGridRows and prunes closed slots on replacement',
      () async {
        final pipe = StreamChannelController<Uint8List>();
        final sentByClient = <CastMessage>[];
        pipe.foreign.stream.listen((raw) {
          sentByClient.add(BufferFrameCodec.decode(raw));
        });

        final transport = WsClientTransport(
          channelFactory: () async => pipe.local,
        );
        final repo = CastClientRepository(transport: transport);
        final vm = CastWorkspaceViewModel(
          repository: repo,
          initialViewportCols: 480,
          initialViewportRows: 120,
          resizeDebounce: Duration.zero,
        );
        addTearDown(() async {
          await vm.dispose();
          await repo.dispose();
        });

        check(vm.viewportCols).equals(BufferFrameCodec.maxGridCols);
        check(vm.viewportRows).equals(120);

        await repo.connect();
        await pumpEventQueue();
        sentByClient.clear();

        pipe.foreign.sink.add(
          BufferFrameCodec.encode(
            const SessionDirectoryFrame(
              sessions: [
                SessionSummary(id: sessA, title: 'wide', cols: 80, rows: 24),
              ],
            ),
          ),
        );
        await pumpEventQueue();

        check(transport.isConnected).isTrue();
        check(sentByClient.single)
            .isA<SubscribeSessionFrame>()
            .has((f) => (f.cols, f.rows), 'dims')
            .equals((BufferFrameCodec.maxGridCols, 120));
        sentByClient.clear();

        pipe.foreign.sink.add(
          BufferFrameCodec.encode(
            BufferSnapshotFrame(
              snapshot: _makeSnapshot(sessA, seq: 1, cols: 400, rows: 120),
            ),
          ),
        );
        await pumpEventQueue();

        vm.resizeActiveViewport(520, 260);
        await pumpEventQueue();
        check(vm.viewportCols).equals(BufferFrameCodec.maxGridCols);
        check(vm.viewportRows).equals(BufferFrameCodec.maxGridRows);
        check(sentByClient.single).equalsOrSameResize(
          sessA,
          BufferFrameCodec.maxGridCols,
          BufferFrameCodec.maxGridRows,
        );
        sentByClient.clear();

        // Direct repository calls also clamp dimensions safely.
        repo.subscribe(sessB, cols: 999, rows: 999);
        repo.sendResize(sessB, 999, 999);
        await pumpEventQueue();
        check(transport.isConnected).isTrue();
        check(sentByClient[0])
            .isA<SubscribeSessionFrame>()
            .has((f) => (f.cols, f.rows), 'dims')
            .equals((
              BufferFrameCodec.maxGridCols,
              BufferFrameCodec.maxGridRows,
            ));
        check(sentByClient[1]).equalsOrSameResize(
          sessB,
          BufferFrameCodec.maxGridCols,
          BufferFrameCodec.maxGridRows,
        );

        // Close last active session sessA -> exitCode stays visible until sessB replaces it.
        pipe.foreign.sink.add(
          BufferFrameCodec.encode(
            const SessionClosedFrame(sessionId: sessA, exitCode: 9),
          ),
        );
        pipe.foreign.sink.add(
          BufferFrameCodec.encode(const SessionDirectoryFrame(sessions: [])),
        );
        await pumpEventQueue();
        check(vm.activeSessionId).equals(sessA);
        check(vm.exitCodeOf(sessA)).equals(9);

        // Replacement session sessB arrives -> sessA stays retained until dismissed, then switches to sessB.
        pipe.foreign.sink.add(
          BufferFrameCodec.encode(
            const SessionDirectoryFrame(
              sessions: [
                SessionSummary(id: sessB, title: 'next', cols: 80, rows: 24),
              ],
            ),
          ),
        );
        await pumpEventQueue();
        check(vm.activeSessionId).equals(sessA);
        check(vm.exitCodeOf(sessA)).equals(9);
        check(vm.sessions.map((s) => s.id).toList()).deepEquals([sessA, sessB]);

        check(await vm.dismissSession(sessA)).isTrue();
        check(vm.activeSessionId).equals(sessB);
        check(vm.exitCodeOf(sessA)).isNull();
      },
    );

    test(
      'emits DECSET 1004 focus-in (CSI I) and focus-out (CSI O) on setWorkspaceVisible and selectSession when focusReporting is enabled',
      () async {
        final pipe = StreamChannelController<Uint8List>();
        final sentInputs = <(SessionId, String)>[];
        pipe.foreign.stream.listen((raw) {
          final msg = BufferFrameCodec.decode(raw);
          if (msg is InputFrame) {
            sentInputs.add((msg.sessionId, utf8.decode(msg.data)));
          }
        });

        final transport = WsClientTransport(
          channelFactory: () async => pipe.local,
        );
        final repo = CastClientRepository(transport: transport);
        final vm = CastWorkspaceViewModel(
          repository: repo,
          inactiveSessionGrace: const Duration(seconds: 30),
        );
        addTearDown(() async {
          await vm.dispose();
          await repo.dispose();
        });

        await repo.connect();
        pipe.foreign.sink.add(
          BufferFrameCodec.encode(
            const SessionDirectoryFrame(
              sessions: [
                SessionSummary(id: sessA, title: 'vim', cols: 80, rows: 24),
                SessionSummary(id: sessB, title: 'zsh', cols: 80, rows: 24),
              ],
            ),
          ),
        );
        await pumpEventQueue();

        // Hydrate sessA with focusReporting: false initially -> visibility toggle sends nothing.
        pipe.foreign.sink.add(
          BufferFrameCodec.encode(
            BufferSnapshotFrame(
              snapshot: _makeSnapshot(
                sessA,
                seq: 1,
                cols: 80,
                rows: 24,
                modes: const TerminalModes(focusReporting: false),
              ),
            ),
          ),
        );
        await pumpEventQueue();

        vm.setWorkspaceVisible(false);
        vm.setWorkspaceVisible(true);
        await pumpEventQueue();
        check(sentInputs).isEmpty();

        // Enable focusReporting on sessA -> hiding emits CSI O, showing emits CSI I.
        pipe.foreign.sink.add(
          BufferFrameCodec.encode(
            BufferSnapshotFrame(
              snapshot: _makeSnapshot(
                sessA,
                seq: 2,
                cols: 80,
                rows: 24,
                modes: const TerminalModes(focusReporting: true),
              ),
            ),
          ),
        );
        await pumpEventQueue();

        vm.setWorkspaceVisible(false);
        await pumpEventQueue();
        check(sentInputs).deepEquals([(sessA, '\x1b[O')]);
        sentInputs.clear();

        vm.setWorkspaceVisible(true);
        await pumpEventQueue();
        check(sentInputs).deepEquals([(sessA, '\x1b[I')]);
        sentInputs.clear();

        // Switch to sessB (unhydrated initially) -> sessA receives focus-out (\x1b[O),
        // and sessB receives focus-in (\x1b[I) once its BufferSnapshotFrame arrives!
        await vm.selectSession(sessB);
        await pumpEventQueue();
        check(sentInputs).deepEquals([(sessA, '\x1b[O')]);
        sentInputs.clear();

        pipe.foreign.sink.add(
          BufferFrameCodec.encode(
            BufferSnapshotFrame(
              snapshot: _makeSnapshot(
                sessB,
                seq: 1,
                cols: 80,
                rows: 24,
                modes: const TerminalModes(focusReporting: true),
              ),
            ),
          ),
        );
        await pumpEventQueue();
        check(sentInputs).deepEquals([(sessB, '\x1b[I')]);
        sentInputs.clear();

        // Switch back to already-synchronized sessA -> sessB gets \x1b[O and sessA gets \x1b[I immediately.
        await vm.selectSession(sessA);
        await pumpEventQueue();
        check(sentInputs).deepEquals([(sessB, '\x1b[O'), (sessA, '\x1b[I')]);
        sentInputs.clear();

        // Hide workspace -> sessA gets \x1b[O once; switching tabs while hidden does NOT emit duplicate \x1b[O.
        vm.setWorkspaceVisible(false);
        await pumpEventQueue();
        check(sentInputs).deepEquals([(sessA, '\x1b[O')]);
        sentInputs.clear();

        await vm.selectSession(sessB);
        await pumpEventQueue();
        check(sentInputs).isEmpty();

        // Show workspace again -> active sessB receives \x1b[I.
        vm.setWorkspaceVisible(true);
        await pumpEventQueue();
        check(sentInputs).deepEquals([(sessB, '\x1b[I')]);
      },
    );

    test(
      'emits DECSET 1004 focus-in (CSI I) after post-grace hidden suspend and resume re-hydration',
      () {
        fakeAsync((async) {
          final pipe = StreamChannelController<Uint8List>();
          final sentInputs = <(SessionId, String)>[];
          pipe.foreign.stream.listen((raw) {
            final msg = BufferFrameCodec.decode(raw);
            if (msg is InputFrame) {
              sentInputs.add((msg.sessionId, utf8.decode(msg.data)));
            }
          });

          final transport = WsClientTransport(
            channelFactory: () async => pipe.local,
          );
          final repo = CastClientRepository(transport: transport);
          final vm = CastWorkspaceViewModel(
            repository: repo,
            inactiveSessionGrace: const Duration(seconds: 10),
          );

          unawaited(repo.connect());
          async.flushMicrotasks();
          pipe.foreign.sink.add(
            BufferFrameCodec.encode(
              const SessionDirectoryFrame(
                sessions: [
                  SessionSummary(id: sessA, title: 'vim', cols: 80, rows: 24),
                ],
              ),
            ),
          );
          pipe.foreign.sink.add(
            BufferFrameCodec.encode(
              BufferSnapshotFrame(
                snapshot: _makeSnapshot(
                  sessA,
                  seq: 1,
                  cols: 80,
                  rows: 24,
                  modes: const TerminalModes(focusReporting: true),
                ),
              ),
            ),
          );
          async.flushMicrotasks();
          sentInputs.clear();

          // Hide for > 10s so sessA is suspended (unsubscribed).
          vm.setWorkspaceVisible(false);
          async.flushMicrotasks();
          check(sentInputs).deepEquals([(sessA, '\x1b[O')]);
          sentInputs.clear();

          async.elapse(const Duration(seconds: 10));
          async.flushMicrotasks();

          // Resume visibility -> re-subscribes sessA and emits \x1b[I when snapshot arrives.
          vm.setWorkspaceVisible(true);
          async.flushMicrotasks();
          check(sentInputs).isEmpty();

          pipe.foreign.sink.add(
            BufferFrameCodec.encode(
              BufferSnapshotFrame(
                snapshot: _makeSnapshot(
                  sessA,
                  seq: 2,
                  cols: 80,
                  rows: 24,
                  modes: const TerminalModes(focusReporting: true),
                ),
              ),
            ),
          );
          async.flushMicrotasks();
          check(sentInputs).deepEquals([(sessA, '\x1b[I')]);

          unawaited(vm.dispose());
          unawaited(repo.dispose());
          async.flushMicrotasks();
        });
      },
    );
  });

  group('adaptBinaryWebSocketChannel and WsClientTransport guards', () {
    test(
      'adapts binary frames, emits ProtocolFormatException on text frames, and ignores sink.done errors',
      () async {
        final incoming = StreamController<Object?>();
        final outgoingSent = <Object?>[];
        final sinkDone = Completer<void>();
        final fakeWs = _FakeWebSocketChannel(
          incoming: incoming.stream,
          onAdd: outgoingSent.add,
          doneFuture: sinkDone.future,
        );

        final adapted = adaptBinaryWebSocketChannel(fakeWs);
        // Rejecting sink.done must not produce an unhandled async error.
        sinkDone.completeError(StateError('socket closed early'));
        await pumpEventQueue();

        final events = <Uint8List>[];
        Object? capturedError;
        adapted.stream.listen(
          events.add,
          onError: (Object e) => capturedError = e,
        );

        incoming.add(Uint8List.fromList([1, 2, 3]));
        incoming.add(<int>[4, 5]);
        await pumpEventQueue();
        check(events).deepEquals([
          Uint8List.fromList([1, 2, 3]),
          Uint8List.fromList([4, 5]),
        ]);
        check(capturedError).isNull();

        adapted.sink.add(Uint8List.fromList([9, 8]));
        await pumpEventQueue();
        check(outgoingSent.single).isA<Uint8List>().deepEquals([9, 8]);

        // Text WebSocket event triggers ProtocolFormatException instead of silent drop.
        incoming.add('unexpected-text-frame');
        await pumpEventQueue();
        check(capturedError).isA<ProtocolFormatException>();

        await incoming.close();
        await adapted.sink.close();
      },
    );

    test(
      'guards concurrent WsClientTransport.connect() calls and validates serverUri without re-parsing',
      () async {
        check(
          '${WsClientTransport.defaultServerUri}',
        ).equals(defaultClientServerUrl);
        check(
          () => WsClientTransport(
            serverUri: Uri.parse('http://127.0.0.1:8420/v1/client'),
          ),
        ).throws<FormatException>();
        check(
          () => WsClientTransport(serverUri: Uri.parse('ws://')),
        ).throws<FormatException>();

        var factoryCalls = 0;
        final dialGate = Completer<StreamChannel<Uint8List>>();
        final pipe = StreamChannelController<Uint8List>();
        final sentFrames = <CastMessage>[];
        pipe.foreign.stream.listen((raw) {
          sentFrames.add(BufferFrameCodec.decode(raw));
        });

        final transport = WsClientTransport(
          token: 'once',
          channelFactory: () {
            factoryCalls++;
            return dialGate.future;
          },
        );
        addTearDown(transport.close);

        final first = transport.connect();
        final second = transport.connect();
        check(factoryCalls).equals(1);

        dialGate.complete(pipe.local);
        await [first, second].wait;
        await pumpEventQueue();

        check(factoryCalls).equals(1);
        check(sentFrames.length).equals(1);
        check(sentFrames.single).isA<AuthFrame>();
      },
    );
  });

  group('Platform WebSocket connectors (io + web stub)', () {
    test(
      'connects over wss:// with SHA-256 cert pinning on io and throws on web stub',
      () async {
        await check(
          browser_stub.openPlatformClientWebSocket(
            Uri.parse('wss://127.0.0.1:8420/v1/client'),
            tlsPinBytes: Uint8List(32),
          ),
        ).throws<UnsupportedError>();

        final tempDir = await Directory.systemTemp.createTemp('client_pin_');
        addTearDown(() => tempDir.delete(recursive: true));
        final certPath = '${tempDir.path}/cert.pem';
        final keyPath = '${tempDir.path}/key.pem';
        await File(certPath).writeAsString(_testCertPem);
        await File(keyPath).writeAsString(_testKeyPem);

        final server = await CastServer.bind(
          ServerConfig(
            port: 0,
            casterToken: 'c-tok',
            clientToken: 'v-tok',
            tlsCertPath: certPath,
            tlsKeyPath: keyPath,
          ),
        );
        addTearDown(server.close);

        final transport = WsClientTransport(
          serverUri: server.clientUri,
          token: 'v-tok',
          tlsPinSha256: _testPinSha256,
        );
        addTearDown(transport.close);

        final accepted = transport.messages.firstWhere(
          (m) => m is AuthAcceptedFrame,
        );
        await transport.connect();
        check(transport.isConnected).isTrue();
        await accepted.timeout(const Duration(seconds: 3));
      },
    );
  });

  group('copyWithEndpoint, reconnectTo, and auth banner state machine', () {
    test(
      'copyWithEndpoint preserves TLS pin only on matching wss:// host and keeps custom factory',
      () async {
        final pipe = StreamChannelController<Uint8List>();
        var customCalls = 0;
        final pinned = WsClientTransport(
          serverUri: Uri.parse('wss://cast.example.com:8420/v1/client'),
          token: 'old-tok',
          tlsPinSha256: _testPinSha256,
          channelFactory: () async {
            customCalls++;
            return pipe.local;
          },
        );
        addTearDown(pinned.close);

        final sameHostWss = pinned.copyWithEndpoint((
          serverUri: Uri.parse('wss://cast.example.com:9443/v1/client'),
          token: 'new-tok',
        ));
        addTearDown(sameHostWss.close);
        check(sameHostWss.tlsPinBytes).isNotNull();
        check(sameHostWss.token).equals('new-tok');

        final otherHostWss = pinned.copyWithEndpoint((
          serverUri: Uri.parse('wss://other.example.com:8420/v1/client'),
          token: 'new-tok',
        ));
        addTearDown(otherHostWss.close);
        check(otherHostWss.tlsPinBytes).isNull();

        final downgradedWs = pinned.copyWithEndpoint((
          serverUri: Uri.parse('ws://cast.example.com:8420/v1/client'),
          token: 'new-tok',
        ));
        addTearDown(downgradedWs.close);
        check(downgradedWs.tlsPinBytes).isNull();

        await sameHostWss.connect();
        check(customCalls).equals(1);
      },
    );

    test(
      'sanitizes fatal auth errors, halts auto-reconnect, and recovers via reconnectTo',
      () async {
        final pipe1 = StreamChannelController<Uint8List>();
        final pipe2 = StreamChannelController<Uint8List>();
        var nextChannel = 0;

        final initialTransport = WsClientTransport(
          serverUri: Uri.parse('ws://127.0.0.1:8420/v1/client'),
          token: 'bad-token',
          channelFactory: () async => pipe1.local,
        );
        final repo = CastClientRepository(
          transport: initialTransport,
          baseReconnectDelay: const Duration(milliseconds: 20),
          transportFactory: (endpoint) {
            nextChannel++;
            if (nextChannel == 1) {
              return WsClientTransport(
                serverUri: endpoint.serverUri,
                token: endpoint.token,
                channelFactory: () =>
                    Future<StreamChannel<Uint8List>>.error(StateError('down')),
              );
            }
            return WsClientTransport(
              serverUri: endpoint.serverUri,
              token: endpoint.token,
              channelFactory: () async => pipe2.local,
            );
          },
        );
        final vm = CastWorkspaceViewModel(repository: repo);
        addTearDown(() async {
          await vm.dispose();
          await repo.dispose();
        });

        check(vm.connectionState).equals(ClientConnectionState.unconnected);
        check(vm.hasAttentionBanner).isTrue();
        check(vm.statusBanner).isNotNull().contains('Not connected');

        await repo.connect();
        check(vm.connectionState).equals(ClientConnectionState.connecting);
        check(vm.statusBanner).isNotNull().contains('Connecting to');

        // Inject fatal auth error containing ANSI control characters and >64 chars.
        final noisyError = '\x1b[31mInvalid bearer token: ${'X' * 80}\x07\r\n';
        pipe1.foreign.sink.add(
          BufferFrameCodec.encode(
            ErrorFrame(code: 'auth_failed', message: noisyError),
          ),
        );
        await pipe1.foreign.sink.close();
        await pumpEventQueue();

        check(repo.willAutoReconnect).isFalse();
        check(vm.connectionState).equals(ClientConnectionState.authFailed);
        check(vm.hasAttentionBanner).isTrue();
        check(
          vm.authErrorMessage,
        ).isNotNull().has((m) => m.length, 'length').equals(64);
        check(vm.authErrorMessage!).not((it) => it.contains('\x1b'));
        check(vm.statusBanner).isNotNull().contains('Auth failed:');

        // First reconnectTo hits dial failure with retryOnFailure: true -> reconnecting banner.
        final CastEndpoint targetEndpoint = (
          serverUri: Uri.parse('ws://127.0.0.1:8421/v1/client'),
          token: 'good-token',
        );
        await vm.reconnectTo(targetEndpoint);
        check(vm.connectionState).equals(ClientConnectionState.reconnecting);
        check(vm.hasAttentionBanner).isTrue();
        check(vm.statusBanner).isNotNull().contains('Reconnecting to');

        // Second reconnectTo succeeds and receives AuthAcceptedFrame -> authenticated, no banner.
        await vm.reconnectTo(targetEndpoint, retryOnFailure: false);
        check(vm.serverUri).equals(targetEndpoint.serverUri);
        check(vm.currentToken).equals('good-token');
        pipe2.foreign.sink.add(
          BufferFrameCodec.encode(const AuthAcceptedFrame(role: .client)),
        );
        await pumpEventQueue();

        check(vm.connectionState).equals(ClientConnectionState.authenticated);
        check(vm.hasAttentionBanner).isFalse();
        check(vm.authErrorMessage).isNull();
        check(vm.statusBanner).isNull();
      },
    );

    test(
      'ignores stale in-flight dial failures after overlapping reconnectTo and truncates astral emoji auth errors by grapheme',
      () async {
        final slowDial = Completer<StreamChannel<Uint8List>>();
        final fastPipe = StreamChannelController<Uint8List>();

        final initialTransport = WsClientTransport(
          serverUri: Uri.parse('ws://127.0.0.1:8420/v1/client'),
          token: 'initial',
          channelFactory: () => slowDial.future,
        );
        final repo = CastClientRepository(
          transport: initialTransport,
          transportFactory: (endpoint) => WsClientTransport(
            serverUri: endpoint.serverUri,
            token: endpoint.token,
            channelFactory: () async => fastPipe.local,
          ),
        );
        final vm = CastWorkspaceViewModel(repository: repo);
        addTearDown(() async {
          await vm.dispose();
          await repo.dispose();
        });

        // Start a slow initial dial, then supersede it with reconnectTo before it settles.
        final pendingInitial = repo.connect(retryOnFailure: true);
        await pumpEventQueue();
        await vm.reconnectTo((
          serverUri: Uri.parse('ws://127.0.0.1:8421/v1/client'),
          token: 'fresh-token',
        ));
        fastPipe.foreign.sink.add(
          BufferFrameCodec.encode(const AuthAcceptedFrame(role: .client)),
        );
        await pumpEventQueue();
        check(vm.connectionState).equals(ClientConnectionState.authenticated);

        // Stale dial now fails; epoch guard must suppress demotion to reconnecting.
        slowDial.completeError(const SocketException('stale timeout'));
        await pendingInitial;
        await pumpEventQueue();
        check(vm.connectionState).equals(ClientConnectionState.authenticated);

        // Astral emoji at grapheme index 64 must remain intact without splitting surrogates.
        fastPipe.foreign.sink.add(
          BufferFrameCodec.encode(
            ErrorFrame(code: 'auth_failed', message: '${'a' * 63}🚀extra-tail'),
          ),
        );
        await pumpEventQueue();
        check(vm.authErrorMessage).equals('${'a' * 63}🚀');
      },
    );

    test(
      'supports normal and box selection, copyOnSelect, OSC 52 ClipboardFrame, and bracketed paste',
      () async {
        final pipe = StreamChannelController<Uint8List>();
        final sentByClient = <CastMessage>[];
        pipe.foreign.stream.listen((raw) {
          sentByClient.add(BufferFrameCodec.decode(raw));
        });

        final transport = WsClientTransport(
          serverUri: Uri.parse('ws://127.0.0.1:8420/v1/client'),
          token: 'secret',
          channelFactory: () async => pipe.local,
        );
        final repo = CastClientRepository(transport: transport);
        final clipboardWrites = <String>[];
        final vm = CastWorkspaceViewModel(
          repository: repo,
          resizeDebounce: Duration.zero,
          clipboardNoticeDuration: Duration.zero,
          onClipboardWrite: clipboardWrites.add,
        );
        addTearDown(() async {
          await vm.dispose();
          await repo.dispose();
        });

        await repo.connect(retryOnFailure: false);
        const sessA = SessionId('sess-a');
        pipe.foreign.sink.add(
          BufferFrameCodec.encode(
            SessionDirectoryFrame(
              sessions: [
                SessionSummary(id: sessA, title: 'vim', cols: 20, rows: 5),
              ],
            ),
          ),
        );
        await pumpEventQueue();

        final buf = Buffer.blank(20, 5)
          ..writeString(0, 0, 'alpha   100', const Style())
          ..writeString(0, 1, 'bravo   200', const Style())
          ..writeString(0, 2, 'charlie 300', const Style());
        pipe.foreign.sink.add(
          BufferFrameCodec.encode(
            BufferSnapshotFrame(
              snapshot: BufferSnapshot.fromBuffer(
                sessionId: sessA,
                seq: 1,
                buffer: buf,
                cursor: const CursorState(x: 0, y: 0, visible: true),
                modes: const TerminalModes(
                  mouseTracking: false,
                  sgrMouse: false,
                  bracketedPaste: true,
                ),
              ),
            ),
          ),
        );
        await pumpEventQueue();

        // 1. Default copyOnSelect is true; dragging (1,1)->(5,2) in 1-based coords selects
        //    'alpha\nbravo' and automatically copies on release.
        check(vm.copyOnSelect).isTrue();
        check(
          vm.handlePtyMouseEvent(
            const ev.MouseEvent(
              x: 1,
              y: 1,
              button: ev.MouseButton.left,
              type: ev.MouseEventType.press,
            ),
          ),
        ).isTrue();
        check(
          vm.handlePtyMouseEvent(
            const ev.MouseEvent(
              x: 5,
              y: 2,
              button: ev.MouseButton.left,
              type: ev.MouseEventType.drag,
            ),
          ),
        ).isTrue();

        final composedNormal = vm.composeActiveBufferWithCursor();
        check(composedNormal.getBackground(2, 0)).equals(0xFF264F78);
        check(composedNormal.getBackground(4, 1)).equals(0xFF264F78);

        check(
          vm.handlePtyMouseEvent(
            const ev.MouseEvent(
              x: 5,
              y: 2,
              button: ev.MouseButton.left,
              type: ev.MouseEventType.release,
            ),
          ),
        ).isTrue();
        check(vm.lastCopiedText).equals('alpha   100\nbravo');
        check(clipboardWrites).deepEquals(['alpha   100\nbravo']);

        // 2. Disable copyOnSelect, perform Alt+Drag box selection over columns 9..11 rows 1..3
        //    ('100\n200\n300'); release does not auto-copy until copySelectionToClipboard() is called.
        vm.setCopyOnSelect(false);
        check(vm.copyOnSelect).isFalse();
        clipboardWrites.clear();

        check(
          vm.handlePtyMouseEvent(
            const ev.MouseEvent(
              x: 9,
              y: 1,
              button: ev.MouseButton.left,
              type: ev.MouseEventType.press,
              modifiers: {ev.Modifier.alt},
            ),
          ),
        ).isTrue();
        check(
          vm.handlePtyMouseEvent(
            const ev.MouseEvent(
              x: 11,
              y: 3,
              button: ev.MouseButton.left,
              type: ev.MouseEventType.drag,
              modifiers: {ev.Modifier.alt},
            ),
          ),
        ).isTrue();
        check(vm.activeSelection?.mode).equals(SelectionMode.box);
        final composedBox = vm.composeActiveBufferWithCursor();
        check(composedBox.getBackground(8, 1)).equals(0xFF3E2C5E);
        check(composedBox.getBackground(0, 1)).equals(0);

        check(
          vm.handlePtyMouseEvent(
            const ev.MouseEvent(
              x: 11,
              y: 3,
              button: ev.MouseButton.left,
              type: ev.MouseEventType.release,
            ),
          ),
        ).isTrue();
        check(clipboardWrites).isEmpty();
        check(vm.copySelectionToClipboard()).isTrue();
        check(clipboardWrites).deepEquals(['100\n200\n300']);

        // 3. When mouseTracking + sgrMouse are enabled, plain Left-Click forwards SGR mouse to PTY,
        //    whereas Shift+Left-Drag overrides remote mouse tracking and selects locally.
        pipe.foreign.sink.add(
          BufferFrameCodec.encode(
            BufferDeltaFrame(
              delta: BufferDelta(
                sessionId: sessA,
                baseSeq: 1,
                seq: 2,
                cols: 20,
                rows: 5,
                cursor: CursorState.origin,
                modes: const TerminalModes(
                  mouseTracking: true,
                  sgrMouse: true,
                  bracketedPaste: true,
                ),
                runs: const [],
              ),
            ),
          ),
        );
        await pumpEventQueue();
        sentByClient.clear();

        check(
          vm.handlePtyMouseEvent(
            const ev.MouseEvent(
              x: 2,
              y: 1,
              button: ev.MouseButton.left,
              type: ev.MouseEventType.press,
            ),
          ),
        ).isTrue();
        await pumpEventQueue();
        check(sentByClient.whereType<InputFrame>().length).equals(1);
        check(vm.activeSelection).isNull();

        sentByClient.clear();
        check(
          vm.handlePtyMouseEvent(
            const ev.MouseEvent(
              x: 1,
              y: 1,
              button: ev.MouseButton.left,
              type: ev.MouseEventType.press,
              modifiers: {ev.Modifier.shift},
            ),
          ),
        ).isTrue();
        check(
          vm.handlePtyMouseEvent(
            const ev.MouseEvent(
              x: 5,
              y: 1,
              button: ev.MouseButton.left,
              type: ev.MouseEventType.drag,
              modifiers: {ev.Modifier.shift},
            ),
          ),
        ).isTrue();
        check(
          vm.handlePtyMouseEvent(
            const ev.MouseEvent(
              x: 5,
              y: 1,
              button: ev.MouseButton.left,
              type: ev.MouseEventType.release,
              modifiers: {ev.Modifier.shift},
            ),
          ),
        ).isTrue();
        await pumpEventQueue();
        check(sentByClient.whereType<InputFrame>()).isEmpty();
        check(vm.copySelectionToClipboard()).isTrue();
        check(clipboardWrites.last).equals('alpha');

        // 4. encodeAndSendPaste normalizes newlines and wraps in DECSET 2004 brackets when active.
        sentByClient.clear();
        check(
          vm.encodeAndSendPaste(
            const ev.PasteEvent('line1\r\nline2\n\x1b[201~safe'),
          ),
        ).isTrue();
        await pumpEventQueue();
        final pastedBytes = sentByClient.whereType<InputFrame>().single.data;
        check(
          utf8.decode(pastedBytes),
        ).equals('\x1b[200~line1\rline2\rsafe\x1b[201~');

        // 5. Inbound ClipboardFrame writes to clipboard or triggers blocked-read notice.
        clipboardWrites.clear();
        pipe.foreign.sink.add(
          BufferFrameCodec.encode(
            const ClipboardFrame(sessionId: sessA, text: 'from remote tmux'),
          ),
        );
        await pumpEventQueue();
        check(clipboardWrites).deepEquals(['from remote tmux']);
        check(vm.lastCopiedText).equals('from remote tmux');

        pipe.foreign.sink.add(
          BufferFrameCodec.encode(
            const ClipboardFrame(sessionId: sessA, readBlocked: true),
          ),
        );
        await pumpEventQueue();
        check(vm.clipboardNotice).isNotNull();
        check(vm.clipboardNotice!).contains('Blocked remote clipboard read');

        // When dock is hidden, notice renders on row 0 of composed buffer without resizing PTY.
        vm.setDockPosition(.hidden);
        final hiddenComposed = vm.composeActiveBufferWithCursor();
        final row0 = [
          for (var x = 0; x < hiddenComposed.width; x++)
            hiddenComposed.getCharacter(x, 0),
        ].join();
        check(row0).contains('! Blocked remote');
        vm.dismissClipboardNotice();
        check(vm.clipboardNotice).isNull();
      },
    );

    test(
      'auto-dismisses clipboardNotice after clipboardNoticeDuration elapses in fakeAsync',
      () {
        fakeAsync((async) {
          final pipe = StreamChannelController<Uint8List>();
          final transport = WsClientTransport(
            channelFactory: () async => pipe.local,
          );
          final repo = CastClientRepository(transport: transport);
          final vm = CastWorkspaceViewModel(
            repository: repo,
            clipboardNoticeDuration: const Duration(seconds: 4),
          );

          var notifications = 0;
          final removeListener = vm.addVisualListener(() => notifications++);

          vm.toggleCopyOnSelect();
          check(vm.clipboardNotice).isNotNull();
          final afterShow = notifications;

          async.elapse(const Duration(milliseconds: 3999));
          check(vm.clipboardNotice).isNotNull();

          async.elapse(const Duration(milliseconds: 1));
          check(vm.clipboardNotice).isNull();
          check(notifications).equals(afterShow + 1);

          removeListener();
          unawaited(vm.dispose());
          unawaited(repo.dispose());
          async.flushMicrotasks();
        });
      },
    );

    test(
      'clears selection on resizeActiveViewport and dimension-changing BufferSnapshot, intersects out-of-bounds spans, and snaps wide graphemes',
      () async {
        // 1. Out-of-bounds row/col intersection and negative containsCell checks.
        final smallBuf = Buffer.blank(10, 4)
          ..writeString(0, 0, 'row-zero', const Style())
          ..writeString(0, 3, 'bottom!!', const Style());

        const belowSelection = TerminalSelection(
          anchor: Point<int>(0, 6),
          focus: Point<int>(5, 8),
        );
        check(belowSelection.rowSpans(smallBuf)).isEmpty();
        check(belowSelection.extractText(smallBuf)).equals('');

        const aboveSelection = TerminalSelection(
          anchor: Point<int>(0, -4),
          focus: Point<int>(5, -1),
        );
        check(aboveSelection.rowSpans(smallBuf)).isEmpty();
        check(aboveSelection.extractText(smallBuf)).equals('');

        const rightBoxSelection = TerminalSelection(
          anchor: Point<int>(12, 0),
          focus: Point<int>(16, 3),
          mode: .box,
        );
        check(rightBoxSelection.rowSpans(smallBuf)).isEmpty();
        check(rightBoxSelection.extractText(smallBuf)).equals('');

        const rightNormalSelection = TerminalSelection(
          anchor: Point<int>(12, 1),
          focus: Point<int>(16, 1),
        );
        check(rightNormalSelection.rowSpans(smallBuf)).isEmpty();
        check(rightNormalSelection.extractText(smallBuf)).equals('');

        const partialBottomSelection = TerminalSelection(
          anchor: Point<int>(2, 3),
          focus: Point<int>(15, 7),
        );
        check(
          partialBottomSelection.rowSpans(smallBuf),
        ).deepEquals([(3, 2, 9)]);
        check(partialBottomSelection.extractText(smallBuf)).equals('ttom!!');

        const streamSelection = TerminalSelection(
          anchor: Point<int>(2, 0),
          focus: Point<int>(5, 2),
        );
        check(streamSelection.containsCell(-1, 1)).isFalse();
        check(streamSelection.containsCell(-3, 2)).isFalse();
        check(streamSelection.containsCell(0, -1)).isFalse();
        check(streamSelection.containsCell(0, 1)).isTrue();

        // 2. Selection clears on resizeActiveViewport and active dimension-changing BufferSnapshot,
        //    reverts box -> normal when Alt is released mid-drag, avoids plain-click rebuilds,
        //    and snaps wide emoji continuation cells in both extractText and highlight.
        final pipe = StreamChannelController<Uint8List>();
        final transport = WsClientTransport(
          channelFactory: () async => pipe.local,
        );
        final repo = CastClientRepository(transport: transport);
        final clipboardWrites = <String>[];
        final vm = CastWorkspaceViewModel(
          repository: repo,
          initialViewportCols: 10,
          initialViewportRows: 4,
          resizeDebounce: Duration.zero,
          clipboardNoticeDuration: Duration.zero,
          onClipboardWrite: clipboardWrites.add,
        );
        addTearDown(() async {
          await vm.dispose();
          await repo.dispose();
        });

        await repo.connect(retryOnFailure: false);
        pipe.foreign.sink.add(
          BufferFrameCodec.encode(
            const SessionDirectoryFrame(
              sessions: [
                SessionSummary(id: sessA, title: 'emoji', cols: 10, rows: 4),
                SessionSummary(id: sessB, title: 'other', cols: 10, rows: 4),
              ],
            ),
          ),
        );
        await pumpEventQueue();

        final wideBuf = Buffer.blank(10, 4)
          ..writeString(0, 0, 'A🔥B', const Style())
          ..writeString(0, 1, 'second', const Style());
        pipe.foreign.sink.add(
          BufferFrameCodec.encode(
            BufferSnapshotFrame(
              snapshot: BufferSnapshot.fromBuffer(
                sessionId: sessA,
                seq: 1,
                buffer: wideBuf,
                cursor: CursorState.origin,
                modes: TerminalModes.defaults,
              ),
            ),
          ),
        );
        await pumpEventQueue();

        // Plain click with no prior selection triggers 0 visual rebuilds (N2).
        var rebuilds = 0;
        final removeListener = vm.addVisualListener(() => rebuilds++);
        addTearDown(removeListener);
        vm.handlePtyMouseEvent(
          const ev.MouseEvent(
            x: 2,
            y: 2,
            button: ev.MouseButton.left,
            type: ev.MouseEventType.press,
          ),
        );
        vm.handlePtyMouseEvent(
          const ev.MouseEvent(
            x: 2,
            y: 2,
            button: ev.MouseButton.left,
            type: ev.MouseEventType.release,
          ),
        );
        check(rebuilds).equals(0);
        check(vm.activeSelection).isNull();

        // Partial right-half selection of wide emoji 'A🔥B' (1-based x: 3..4 -> 0-based 2..3)
        // snaps left to include col 1 so both highlight and clipboard agree on '🔥B'.
        clipboardWrites.clear();
        vm.handlePtyMouseEvent(
          const ev.MouseEvent(
            x: 3,
            y: 1,
            button: ev.MouseButton.left,
            type: ev.MouseEventType.press,
          ),
        );
        vm.handlePtyMouseEvent(
          const ev.MouseEvent(
            x: 4,
            y: 1,
            button: ev.MouseButton.left,
            type: ev.MouseEventType.drag,
          ),
        );
        vm.handlePtyMouseEvent(
          const ev.MouseEvent(
            x: 4,
            y: 1,
            button: ev.MouseButton.left,
            type: ev.MouseEventType.release,
          ),
        );
        check(clipboardWrites).deepEquals(['🔥B']);
        final rightSnapped = vm.composeActiveBufferWithCursor();
        check(rightSnapped.getBackground(0, 0)).equals(0);
        check(rightSnapped.getBackground(1, 0)).equals(0xFF264F78);
        check(rightSnapped.getBackground(2, 0)).equals(0xFF264F78);
        check(rightSnapped.getBackground(3, 0)).equals(0xFF264F78);

        // Partial left-half selection of 'A🔥B' (1-based x: 1..2 -> 0-based 0..1)
        // snaps right to include col 2 so both highlight and clipboard agree on 'A🔥'.
        clipboardWrites.clear();
        vm.handlePtyMouseEvent(
          const ev.MouseEvent(
            x: 1,
            y: 1,
            button: ev.MouseButton.left,
            type: ev.MouseEventType.press,
          ),
        );
        vm.handlePtyMouseEvent(
          const ev.MouseEvent(
            x: 2,
            y: 1,
            button: ev.MouseButton.left,
            type: ev.MouseEventType.drag,
          ),
        );
        vm.handlePtyMouseEvent(
          const ev.MouseEvent(
            x: 2,
            y: 1,
            button: ev.MouseButton.left,
            type: ev.MouseEventType.release,
          ),
        );
        check(clipboardWrites).deepEquals(['A🔥']);
        final leftSnapped = vm.composeActiveBufferWithCursor();
        check(leftSnapped.getBackground(0, 0)).equals(0xFF264F78);
        check(leftSnapped.getBackground(1, 0)).equals(0xFF264F78);
        check(leftSnapped.getBackground(2, 0)).equals(0xFF264F78);
        check(leftSnapped.getBackground(3, 0)).equals(0);

        // resizeActiveViewport clears active selection when dimensions change.
        check(vm.activeSelection).isNotNull();
        vm.resizeActiveViewport(12, 5);
        check(vm.activeSelection).isNull();

        // Alt+Drag starts in box mode, and releasing Alt mid-drag reverts to normal (J13).
        vm.handlePtyMouseEvent(
          const ev.MouseEvent(
            x: 1,
            y: 1,
            button: ev.MouseButton.left,
            type: ev.MouseEventType.press,
            modifiers: {ev.Modifier.alt},
          ),
        );
        vm.handlePtyMouseEvent(
          const ev.MouseEvent(
            x: 3,
            y: 2,
            button: ev.MouseButton.left,
            type: ev.MouseEventType.drag,
            modifiers: {ev.Modifier.alt},
          ),
        );
        check(vm.activeSelection?.mode).equals(SelectionMode.box);
        vm.handlePtyMouseEvent(
          const ev.MouseEvent(
            x: 4,
            y: 2,
            button: ev.MouseButton.left,
            type: ev.MouseEventType.drag,
          ),
        );
        check(vm.activeSelection?.mode).equals(SelectionMode.normal);
        vm.handlePtyMouseEvent(
          const ev.MouseEvent(
            x: 4,
            y: 2,
            button: ev.MouseButton.left,
            type: ev.MouseEventType.release,
          ),
        );
        check(vm.activeSelection).isNotNull();

        // Same-dimension BufferSnapshot (or background session resize) preserves selection,
        // whereas a dimension-changing BufferSnapshot for the active session clears selection.
        await vm.selectSession(sessB);
        await vm.selectSession(sessA);
        vm.handlePtyMouseEvent(
          const ev.MouseEvent(
            x: 1,
            y: 1,
            button: ev.MouseButton.left,
            type: ev.MouseEventType.press,
          ),
        );
        vm.handlePtyMouseEvent(
          const ev.MouseEvent(
            x: 4,
            y: 2,
            button: ev.MouseButton.left,
            type: ev.MouseEventType.drag,
          ),
        );
        vm.handlePtyMouseEvent(
          const ev.MouseEvent(
            x: 4,
            y: 2,
            button: ev.MouseButton.left,
            type: ev.MouseEventType.release,
          ),
        );
        check(vm.activeSelection).isNotNull();

        pipe.foreign.sink.add(
          BufferFrameCodec.encode(
            BufferSnapshotFrame(
              snapshot: _makeSnapshot(sessB, seq: 1, cols: 6, rows: 2),
            ),
          ),
        );
        pipe.foreign.sink.add(
          BufferFrameCodec.encode(
            BufferSnapshotFrame(
              snapshot: _makeSnapshot(sessB, seq: 2, cols: 14, rows: 6),
            ),
          ),
        );
        pipe.foreign.sink.add(
          BufferFrameCodec.encode(
            BufferSnapshotFrame(
              snapshot: _makeSnapshot(sessA, seq: 2, cols: 10, rows: 4),
            ),
          ),
        );
        await pumpEventQueue();
        check(vm.activeSelection).isNotNull();

        // Clicking once on a non-collapsed selection triggers exactly 1 visual rebuild to clear it (N2).
        rebuilds = 0;
        vm.handlePtyMouseEvent(
          const ev.MouseEvent(
            x: 2,
            y: 2,
            button: ev.MouseButton.left,
            type: ev.MouseEventType.press,
          ),
        );
        vm.handlePtyMouseEvent(
          const ev.MouseEvent(
            x: 2,
            y: 2,
            button: ev.MouseButton.left,
            type: ev.MouseEventType.release,
          ),
        );
        check(rebuilds).equals(1);
        check(vm.activeSelection).isNull();

        // Re-select and verify dimension-changing active BufferSnapshot clears selection.
        vm.handlePtyMouseEvent(
          const ev.MouseEvent(
            x: 1,
            y: 1,
            button: ev.MouseButton.left,
            type: ev.MouseEventType.press,
          ),
        );
        vm.handlePtyMouseEvent(
          const ev.MouseEvent(
            x: 4,
            y: 2,
            button: ev.MouseButton.left,
            type: ev.MouseEventType.drag,
          ),
        );
        vm.handlePtyMouseEvent(
          const ev.MouseEvent(
            x: 4,
            y: 2,
            button: ev.MouseButton.left,
            type: ev.MouseEventType.release,
          ),
        );
        check(vm.activeSelection).isNotNull();

        pipe.foreign.sink.add(
          BufferFrameCodec.encode(
            BufferSnapshotFrame(
              snapshot: _makeSnapshot(sessA, seq: 3, cols: 8, rows: 3),
            ),
          ),
        );
        await pumpEventQueue();
        check(vm.activeSelection).isNull();
        final clearedComposed = vm.composeActiveBufferWithCursor();
        for (var y = 0; y < clearedComposed.height; y++) {
          for (var x = 0; x < clearedComposed.width; x++) {
            check(clearedComposed.getBackground(x, y)).equals(0);
          }
        }
      },
    );

    test(
      'rejects > 1 MiB pastes without disconnecting, chunks > 64 KiB UTF-8 pastes safely, and gates ClipboardFrame by subscription',
      () async {
        final pipe = StreamChannelController<Uint8List>();
        final sentByClient = <CastMessage>[];
        pipe.foreign.stream.listen((raw) {
          sentByClient.add(BufferFrameCodec.decode(raw));
        });

        final transport = WsClientTransport(
          channelFactory: () async => pipe.local,
        );
        final repo = CastClientRepository(transport: transport);
        final clipboardWrites = <String>[];
        final vm = CastWorkspaceViewModel(
          repository: repo,
          resizeDebounce: Duration.zero,
          clipboardNoticeDuration: Duration.zero,
          onClipboardWrite: clipboardWrites.add,
        );
        addTearDown(() async {
          await vm.dispose();
          await repo.dispose();
        });

        await repo.connect(retryOnFailure: false);
        await pumpEventQueue();

        // 1. Before subscribing to any session (activeSessionId == null), ClipboardFrames are ignored.
        pipe.foreign.sink.add(
          BufferFrameCodec.encode(
            const ClipboardFrame(sessionId: sessA, text: 'unsub-write'),
          ),
        );
        pipe.foreign.sink.add(
          BufferFrameCodec.encode(
            const ClipboardFrame(sessionId: sessA, readBlocked: true),
          ),
        );
        await pumpEventQueue();
        check(clipboardWrites).isEmpty();
        check(vm.clipboardNotice).isNull();

        // 2. Announce sessA (active) and sessB (unsubscribed initially).
        pipe.foreign.sink.add(
          BufferFrameCodec.encode(
            const SessionDirectoryFrame(
              sessions: [
                SessionSummary(id: sessA, title: 'vim', cols: 20, rows: 5),
                SessionSummary(id: sessB, title: 'logs', cols: 20, rows: 5),
              ],
            ),
          ),
        );
        await pumpEventQueue();
        pipe.foreign.sink.add(
          BufferFrameCodec.encode(
            BufferSnapshotFrame(
              snapshot: _makeSnapshot(
                sessA,
                seq: 1,
                cols: 20,
                rows: 5,
                text: 'hello',
                modes: const TerminalModes(bracketedPaste: true),
              ),
            ),
          ),
        );
        await pumpEventQueue();

        // Unsubscribed sessB frames are ignored completely.
        pipe.foreign.sink.add(
          BufferFrameCodec.encode(
            const ClipboardFrame(sessionId: sessB, readBlocked: true),
          ),
        );
        await pumpEventQueue();
        check(vm.clipboardNotice).isNull();

        // Subscribe sessB, then switch back to sessA so sessB is background-subscribed.
        await vm.selectSession(sessB);
        await vm.selectSession(sessA);
        await pumpEventQueue();

        // Background-subscribed sessB clipboard write is ignored, but readBlocked surfaces notice with session title.
        pipe.foreign.sink.add(
          BufferFrameCodec.encode(
            const ClipboardFrame(sessionId: sessB, text: 'bg-secret'),
          ),
        );
        await pumpEventQueue();
        check(clipboardWrites).isEmpty();

        pipe.foreign.sink.add(
          BufferFrameCodec.encode(
            const ClipboardFrame(sessionId: sessB, readBlocked: true),
          ),
        );
        await pumpEventQueue();
        check(vm.clipboardNotice).equals(' ! Blocked clipboard read (logs) ');
        vm.dismissClipboardNotice();

        // 3. Oversized (> 1 MiB) paste returns false, shows notice, sends 0 frames, keeps selection & connection.
        vm.handlePtyMouseEvent(
          const ev.MouseEvent(
            x: 1,
            y: 1,
            button: ev.MouseButton.left,
            type: ev.MouseEventType.press,
          ),
        );
        vm.handlePtyMouseEvent(
          const ev.MouseEvent(
            x: 4,
            y: 1,
            button: ev.MouseButton.left,
            type: ev.MouseEventType.drag,
          ),
        );
        vm.handlePtyMouseEvent(
          const ev.MouseEvent(
            x: 4,
            y: 1,
            button: ev.MouseButton.left,
            type: ev.MouseEventType.release,
          ),
        );
        check(vm.activeSelection).isNotNull();
        sentByClient.clear();

        final oversized = 'x' * (CastWorkspaceViewModel.maxPasteBytes + 1);
        check(vm.encodeAndSendPaste(ev.PasteEvent(oversized))).isFalse();
        await pumpEventQueue();
        check(vm.clipboardNotice).equals(' ! Paste exceeds 1 MiB limit ');
        check(sentByClient.whereType<InputFrame>()).isEmpty();
        check(transport.isConnected).isTrue();
        check(vm.activeSelection).isNotNull();
        vm.dismissClipboardNotice();

        // 4. Multi-byte > 64 KiB paste (~180 KiB with 4-byte emoji + 3-byte CJK) is chunked into <= 64 KiB valid UTF-8 frames.
        final unit = '🔥日本語abc\n';
        final largeMultiByte = unit * 12000;
        check(vm.encodeAndSendPaste(ev.PasteEvent(largeMultiByte))).isTrue();
        await pumpEventQueue();
        check(vm.activeSelection).isNull();

        final inputFrames = sentByClient.whereType<InputFrame>().toList();
        check(inputFrames.length).isGreaterOrEqual(3);
        final reassembled = StringBuffer();
        for (final frame in inputFrames) {
          check(frame.data.length).isLessOrEqual(65536);
          reassembled.write(utf8.decode(frame.data));
        }
        final expectedBody = largeMultiByte.replaceAll('\n', '\r');
        check('$reassembled').equals('\x1b[200~$expectedBody\x1b[201~');

        // 5. Exact 1 MiB payload succeeds even when bracketedPaste adds 12 marker bytes.
        sentByClient.clear();
        final exactOneMiB = 'x' * CastWorkspaceViewModel.maxPasteBytes;
        check(vm.encodeAndSendPaste(ev.PasteEvent(exactOneMiB))).isTrue();
        await pumpEventQueue();
        final oneMiBBytes = sentByClient.whereType<InputFrame>().fold<int>(
          0,
          (sum, f) => sum + f.data.length,
        );
        check(oneMiBBytes).equals(CastWorkspaceViewModel.maxPasteBytes + 12);
      },
    );

    test(
      'prefetches 128 tail rows on subscribe snapshot, sends 0 scrollback requests across 50 live-tail deltas, pins across reconnect, and purges ghost rows on caster restart',
      () async {
        var activePipe = StreamChannelController<Uint8List>();
        final sentByClient = <CastMessage>[];
        void attachRecorder(StreamChannelController<Uint8List> pipe) {
          pipe.foreign.stream.listen((raw) {
            sentByClient.add(BufferFrameCodec.decode(raw));
          });
        }

        attachRecorder(activePipe);
        final transport = WsClientTransport(
          token: 'secret',
          channelFactory: () async => activePipe.local,
        );
        final repo = CastClientRepository(
          transport: transport,
          baseReconnectDelay: const Duration(milliseconds: 5),
        );
        final vm = CastWorkspaceViewModel(
          repository: repo,
          initialViewportCols: 20,
          initialViewportRows: 4,
          resizeDebounce: Duration.zero,
        );
        addTearDown(() async {
          await vm.dispose();
          await repo.dispose();
        });

        await repo.connect();
        activePipe.foreign.sink.add(
          BufferFrameCodec.encode(
            const SessionDirectoryFrame(
              sessions: [
                SessionSummary(id: sessA, title: 'zsh', cols: 20, rows: 4),
              ],
            ),
          ),
        );
        await pumpEventQueue();
        sentByClient.clear();

        // 1. Initial subscribe snapshot (totalLines=200) sets state=.synchronized BEFORE
        //    prefetching exactly 1 tail page (72..200) and notifying listeners.
        ClientSessionSyncState? stateDuringVisualNotify;
        final removeSpy = vm.addVisualListener(() {
          stateDuringVisualNotify = vm.activeSessionSyncState;
        });
        activePipe.foreign.sink.add(
          BufferFrameCodec.encode(
            BufferSnapshotFrame(
              snapshot: BufferSnapshot.fromBuffer(
                sessionId: sessA,
                seq: 1,
                buffer: Buffer.blank(20, 4)
                  ..writeString(0, 0, 'live', const Style()),
                cursor: CursorState.origin,
                modes: TerminalModes.defaults,
                scrollback: const ScrollbackWindow(
                  clearSeq: 0,
                  oldestLine: 0,
                  totalLines: 200,
                ),
              ),
            ),
          ),
        );
        await pumpEventQueue();
        removeSpy();

        check(
          stateDuringVisualNotify,
        ).equals(ClientSessionSyncState.synchronized);
        final initialPrefetch = [
          ...sentByClient.whereType<RequestScrollbackFrame>(),
        ];
        check(initialPrefetch).length.equals(1);
        check(initialPrefetch.single.startLine).equals(72);
        check(initialPrefetch.single.count).equals(128);

        // Answer the initial prefetch chunk.
        activePipe.foreign.sink.add(
          BufferFrameCodec.encode(
            ScrollbackChunkFrame(
              sessionId: sessA,
              requestId: initialPrefetch.single.requestId,
              clearSeq: 0,
              startLine: 72,
              rows: [
                for (var i = 72; i < 200; i++)
                  EncodedScrollbackRow(
                    isWrapped: false,
                    characters: 'H$i'.split(''),
                    attributes: Uint32List('H$i'.length * 3),
                  ),
              ],
            ),
          ),
        );
        await pumpEventQueue();
        sentByClient.clear();

        // 2. 50 live BufferDeltaFrames while at scrollOffsetLines == 0 must emit 0 RequestScrollbackFrames!
        for (var i = 1; i <= 50; i++) {
          activePipe.foreign.sink.add(
            BufferFrameCodec.encode(
              BufferDeltaFrame(
                delta: BufferDelta(
                  sessionId: sessA,
                  baseSeq: i,
                  seq: i + 1,
                  cols: 20,
                  rows: 4,
                  cursor: CursorState.origin,
                  modes: TerminalModes.defaults,
                  scrollback: ScrollbackWindow(
                    clearSeq: 0,
                    oldestLine: 0,
                    totalLines: 200 + i,
                  ),
                  runs: const [],
                ),
              ),
            ),
          );
        }
        await pumpEventQueue();
        check([...sentByClient.whereType<RequestScrollbackFrame>()]).isEmpty();

        // 3. Scroll up to virtual row 180 (totalLines=250 -> offset=70).
        check(vm.scrollActiveBy(70)).isTrue();
        check(vm.activeScrollOffsetLines).equals(70);
        await pumpEventQueue();
        // Answer any lookahead request before testing WS reconnect.
        for (final req in [
          ...sentByClient.whereType<RequestScrollbackFrame>(),
        ]) {
          activePipe.foreign.sink.add(
            BufferFrameCodec.encode(
              ScrollbackChunkFrame(
                sessionId: sessA,
                requestId: req.requestId,
                clearSeq: req.clearSeq,
                startLine: req.startLine,
                rows: [
                  for (var i = 0; i < req.count; i++)
                    EncodedScrollbackRow(
                      isWrapped: false,
                      characters: 'H${req.startLine + i}'.split(''),
                      attributes: Uint32List(
                        'H${req.startLine + i}'.length * 3,
                      ),
                    ),
                ],
              ),
            ),
          );
        }
        await pumpEventQueue();
        sentByClient.clear();

        // Drop WS and reconnect while caster advances totalLines 250 -> 280.
        // Pinned virtual row 180 must stay pinned (offset 70 -> 100) AND uncached visible gap must be fetched!
        final reconnectedPipe = StreamChannelController<Uint8List>();
        attachRecorder(reconnectedPipe);
        final prevPipe = activePipe;
        activePipe = reconnectedPipe;
        await prevPipe.foreign.sink.close();
        await Future<void>.delayed(const Duration(milliseconds: 30));

        reconnectedPipe.foreign.sink.add(
          BufferFrameCodec.encode(
            const SessionDirectoryFrame(
              sessions: [
                SessionSummary(id: sessA, title: 'zsh', cols: 20, rows: 4),
              ],
            ),
          ),
        );
        await pumpEventQueue();
        sentByClient.clear();

        // Scroll to virtual row 248 (offset=2 on old 250) -> on reconnect at 280, offset becomes 32 (virtual row 248..251, where 250..251 is uncached!).
        check(vm.activeScrollOffsetLines).equals(70);
        reconnectedPipe.foreign.sink.add(
          BufferFrameCodec.encode(
            BufferSnapshotFrame(
              snapshot: BufferSnapshot.fromBuffer(
                sessionId: sessA,
                seq: 100,
                buffer: Buffer.blank(20, 4),
                cursor: CursorState.origin,
                modes: TerminalModes.defaults,
                scrollback: const ScrollbackWindow(
                  clearSeq: 0,
                  oldestLine: 0,
                  totalLines: 280,
                ),
              ),
            ),
          ),
        );
        await pumpEventQueue();
        check(vm.activeScrollOffsetLines).equals(100);
        final composedPinned = vm.composeActiveBufferWithCursor();
        final topLine = [
          for (var x = 0; x < 4; x++) composedPinned.getCharacter(x, 0),
        ].join();
        check(topLine).equals('H180');

        // Scroll down to virtual row 249 (offset = 280 - 249 = 31) where 200..279 was uncached -> triggers gap request!
        sentByClient.clear();
        check(vm.scrollActiveBy(-69)).isTrue();
        await pumpEventQueue();
        final gapFetch = [...sentByClient.whereType<RequestScrollbackFrame>()];
        check(gapFetch).isNotEmpty();
        check(gapFetch.first.startLine).equals(249);
        for (final req in gapFetch) {
          reconnectedPipe.foreign.sink.add(
            BufferFrameCodec.encode(
              ScrollbackChunkFrame(
                sessionId: sessA,
                requestId: req.requestId,
                clearSeq: 0,
                startLine: req.startLine,
                rows: [
                  for (var i = 0; i < req.count; i++)
                    EncodedScrollbackRow(
                      isWrapped: false,
                      characters: 'G${req.startLine + i}'.split(''),
                      attributes: Uint32List(
                        'G${req.startLine + i}'.length * 3,
                      ),
                    ),
                ],
              ),
            ),
          );
        }
        await pumpEventQueue();

        // 4. Non-empty clamped ScrollbackChunkFrame clamps scrollOffsetLines without spin-refetching.
        sentByClient.clear();
        check(vm.scrollActiveToTop()).isTrue();
        await pumpEventQueue();
        final topReq = sentByClient.whereType<RequestScrollbackFrame>().first;
        sentByClient.clear();
        reconnectedPipe.foreign.sink.add(
          BufferFrameCodec.encode(
            ScrollbackChunkFrame(
              sessionId: sessA,
              requestId: topReq.requestId,
              clearSeq: 0,
              startLine: 40,
              rows: [
                for (var i = 40; i < 168; i++)
                  EncodedScrollbackRow(
                    isWrapped: false,
                    characters: 'C$i'.split(''),
                    attributes: Uint32List('C$i'.length * 3),
                  ),
              ],
            ),
          ),
        );
        await pumpEventQueue();
        check(vm.activeRetainedScrollbackLines).equals(240);
        check(vm.activeScrollOffsetLines).equals(240);
        check([...sentByClient.whereType<RequestScrollbackFrame>()]).isEmpty();

        // 5. SessionClosedFrame preserves scrollback while ended, and caster restart with same sessionId at clearSeq=0 purges ghost cached rows!
        reconnectedPipe.foreign.sink.add(
          BufferFrameCodec.encode(
            const SessionClosedFrame(sessionId: sessA, exitCode: 0),
          ),
        );
        await pumpEventQueue();
        check(vm.activeScrollOffsetLines).equals(240);
        check(vm.activeRetainedScrollbackLines).equals(240);

        reconnectedPipe.foreign.sink.add(
          BufferFrameCodec.encode(
            const SessionDirectoryFrame(
              sessions: [
                SessionSummary(id: sessA, title: 'zsh', cols: 20, rows: 4),
              ],
            ),
          ),
        );
        await pumpEventQueue();
        check(vm.activeScrollOffsetLines).equals(0);
        check(vm.activeRetainedScrollbackLines).equals(0);
        sentByClient.clear();

        reconnectedPipe.foreign.sink.add(
          BufferFrameCodec.encode(
            BufferSnapshotFrame(
              snapshot: BufferSnapshot.fromBuffer(
                sessionId: sessA,
                seq: 1,
                buffer: Buffer.blank(20, 4)
                  ..writeString(0, 0, 'fresh', const Style()),
                cursor: CursorState.origin,
                modes: TerminalModes.defaults,
                scrollback: const ScrollbackWindow(
                  clearSeq: 0,
                  oldestLine: 0,
                  totalLines: 80,
                ),
              ),
            ),
          ),
        );
        await pumpEventQueue();
        // Because ghost cache was wiped, the restarted session requests lines 0..80 instead of serving stale H72..!
        final restartFetch = [
          ...sentByClient.whereType<RequestScrollbackFrame>(),
        ];
        check(restartFetch).length.equals(1);
        check(restartFetch.single.startLine).equals(0);
        check(restartFetch.single.count).equals(80);
      },
    );

    test(
      'retries relay-dropped RequestScrollbackFrame after 2s idle timeout, blocks scroll on altScreen, notifies on keystroke snap, and heals wide pan edges',
      () {
        fakeAsync((async) {
          final pipe = StreamChannelController<Uint8List>();
          final sentByClient = <CastMessage>[];
          pipe.foreign.stream.listen((raw) {
            sentByClient.add(BufferFrameCodec.decode(raw));
          });

          final transport = WsClientTransport(
            token: 'secret',
            channelFactory: () async => pipe.local,
          );
          final repo = CastClientRepository(transport: transport);
          final vm = CastWorkspaceViewModel(
            repository: repo,
            initialViewportCols: 10,
            initialViewportRows: 4,
            resizeDebounce: Duration.zero,
          );

          unawaited(repo.connect(retryOnFailure: false));
          async.flushMicrotasks();

          pipe.foreign.sink.add(
            BufferFrameCodec.encode(
              const SessionDirectoryFrame(
                sessions: [
                  SessionSummary(id: sessA, title: 'zsh', cols: 10, rows: 4),
                ],
              ),
            ),
          );
          async.flushMicrotasks();

          pipe.foreign.sink.add(
            BufferFrameCodec.encode(
              BufferSnapshotFrame(
                snapshot: BufferSnapshot.fromBuffer(
                  sessionId: sessA,
                  seq: 1,
                  buffer: Buffer.blank(10, 4)
                    ..writeString(0, 0, 'prompt', const Style()),
                  cursor: CursorState.origin,
                  modes: TerminalModes.defaults,
                  scrollback: const ScrollbackWindow(
                    clearSeq: 0,
                    oldestLine: 0,
                    totalLines: 20,
                  ),
                ),
              ),
            ),
          );
          async.flushMicrotasks();

          // Scroll up 5 lines; relay drops the initial RequestScrollbackFrame(s).
          check(vm.scrollActiveBy(5)).isTrue();
          async.flushMicrotasks();
          check([
            ...sentByClient.whereType<RequestScrollbackFrame>(),
          ]).isNotEmpty();
          sentByClient.clear();

          // Idle for 1.9s -> no retry yet.
          async.elapse(const Duration(milliseconds: 1900));
          check([
            ...sentByClient.whereType<RequestScrollbackFrame>(),
          ]).isEmpty();

          // Reach 2.0s idle timeout -> automatic retry RequestScrollbackFrame fires!
          async.elapse(const Duration(milliseconds: 100));
          final retried = [...sentByClient.whereType<RequestScrollbackFrame>()];
          check(retried).isNotEmpty();

          // Answer the retry with wide historical lines containing 2-cell emojis ('A🔥B🔥C🔥D🔥E🔥F').
          final wideBuf = Buffer.blank(16, 1)
            ..writeString(
              0,
              0,
              'A🔥B🔥C🔥D🔥E🔥F',
              const Style(modifiers: Modifier.underline),
            );
          pipe.foreign.sink.add(
            BufferFrameCodec.encode(
              ScrollbackChunkFrame(
                sessionId: sessA,
                requestId: retried.first.requestId,
                clearSeq: 0,
                startLine: retried.first.startLine,
                rows: [
                  for (var i = 0; i < retried.first.count; i++)
                    EncodedScrollbackRow(
                      isWrapped: false,
                      characters: [...wideBuf.characters],
                      attributes: Uint32List.fromList(wideBuf.attributes),
                    ),
                ],
              ),
            ),
          );
          async.flushMicrotasks();

          // Verify historical row rendered & thumb '▐' at (x=9, y=2) sets Modifier.none (clearing underline)!
          final composedAt0 = vm.composeActiveBufferWithCursor();
          check(composedAt0.getCharacter(0, 0)).equals('A');
          check(composedAt0.getCharacter(9, 2)).equals('▐');
          check(
            composedAt0.attributes[(2 * 10 + 9) * 3 + 2],
          ).equals(Modifier.none);

          // Pan right by 1 column -> srcX=10 ('🔥' lead at x=9) clips at right edge and heals to ' '!
          check(vm.panActiveHorizontalBy(1)).isTrue();
          final composedAt1 = vm.composeActiveBufferWithCursor();
          check(composedAt1.getCharacter(8, 0)).equals('D');
          check(composedAt1.getCharacter(9, 0)).equals(' ');

          // Pan right 1 more column (offsetCols=2):
          // - Left edge x=0 lands on continuation cell (srcX=2) -> heals to ' '!
          // - Right edge (x=8, x=9) lands on '🔥' (srcX=10..11): intact on row 0, healed to ' ' + '▐' on thumb row 2!
          check(vm.panActiveHorizontalBy(1)).isTrue();
          check(vm.activeScrollOffsetCols).equals(2);
          final composedAt2 = vm.composeActiveBufferWithCursor();
          check(composedAt2.getCharacter(0, 0)).equals(' ');
          check(composedAt2.getCharacter(1, 0)).equals('B');
          check(composedAt2.getCharacter(8, 0)).equals('🔥');
          check(composedAt2.getCharacter(8, 2)).equals(' ');
          check(composedAt2.getCharacter(9, 2)).equals('▐');

          // M10: encodeAndSendKey immediately fires visual listeners when snapping to bottom!
          var visualNotifies = 0;
          final removeVisual = vm.addVisualListener(() => visualNotifies++);
          check(
            vm.encodeAndSendKey(const ev.KeyEvent('a', ev.KeyType.character)),
          ).isTrue();
          check(vm.activeScrollOffsetLines).equals(0);
          check(vm.activeScrollOffsetCols).equals(0);
          check(visualNotifies).isGreaterOrEqual(1);
          removeVisual();

          // Select text on primary screen, then transition to altScreen (?1049h) -> clears selection (m7)
          // and blocks Shift+Wheel & scrollActiveBy (M9)!
          vm.handlePtyMouseEvent(
            const ev.MouseEvent(
              x: 1,
              y: 1,
              button: ev.MouseButton.left,
              type: ev.MouseEventType.press,
            ),
          );
          vm.handlePtyMouseEvent(
            const ev.MouseEvent(
              x: 4,
              y: 1,
              button: ev.MouseButton.left,
              type: ev.MouseEventType.drag,
            ),
          );
          vm.handlePtyMouseEvent(
            const ev.MouseEvent(
              x: 4,
              y: 1,
              button: ev.MouseButton.left,
              type: ev.MouseEventType.release,
            ),
          );
          check(vm.activeSelection).isNotNull();

          pipe.foreign.sink.add(
            BufferFrameCodec.encode(
              BufferDeltaFrame(
                delta: BufferDelta(
                  sessionId: sessA,
                  baseSeq: 1,
                  seq: 2,
                  cols: 10,
                  rows: 4,
                  cursor: CursorState.origin,
                  modes: const TerminalModes(altScreen: true),
                  scrollback: const ScrollbackWindow(
                    clearSeq: 0,
                    oldestLine: 0,
                    totalLines: 20,
                  ),
                  runs: const [],
                ),
              ),
            ),
          );
          async.flushMicrotasks();
          check(vm.activeSelection).isNull();
          check(vm.canScrollActiveSession()).isFalse();
          check(vm.scrollActiveBy(3)).isFalse();

          sentByClient.clear();
          vm.handlePtyMouseEvent(
            const ev.MouseEvent(
              x: 2,
              y: 2,
              button: ev.MouseButton.wheelUp,
              type: ev.MouseEventType.press,
              modifiers: {ev.Modifier.shift},
            ),
          );
          async.flushMicrotasks();
          check(vm.activeScrollOffsetLines).equals(0);
          // Shift+Wheel on altScreen without mouseTracking falls through to alternateScroll (\x1b[A)!
          check([...sentByClient.whereType<InputFrame>()]).length.equals(1);

          unawaited(vm.dispose());
          unawaited(repo.dispose());
          async.flushMicrotasks();
        });
      },
    );

    test(
      'opens http and https URLs on Ctrl+Click and Cmd+Click across soft-wrapped rows, balanced parens, and box-drawing borders',
      () async {
        final pipe = StreamChannelController<Uint8List>();
        final sentByClient = <CastMessage>[];
        pipe.foreign.stream.listen((raw) {
          sentByClient.add(BufferFrameCodec.decode(raw));
        });

        final transport = WsClientTransport(
          serverUri: Uri.parse('ws://127.0.0.1:8420/v1/client'),
          token: 'secret',
          channelFactory: () async => pipe.local,
        );
        final repo = CastClientRepository(transport: transport);
        final openedUrls = <Uri>[];
        final vm = CastWorkspaceViewModel(
          repository: repo,
          resizeDebounce: Duration.zero,
          onOpenUrl: openedUrls.add,
        );
        addTearDown(() async {
          await vm.dispose();
          await repo.dispose();
        });

        await repo.connect(retryOnFailure: false);
        const sessId = SessionId('sess-url');
        pipe.foreign.sink.add(
          BufferFrameCodec.encode(
            SessionDirectoryFrame(
              sessions: [
                SessionSummary(id: sessId, title: 'zsh', cols: 40, rows: 5),
              ],
            ),
          ),
        );
        await pumpEventQueue();

        // Row 0..1: soft-wrapped URL across two 40-col rows (row 1 isWrapped: true).
        // Row 2: Wikipedia URL with balanced parens inside outer parens + period.
        // Row 3: URL framed by box-drawing characters.
        final buf = Buffer.blank(40, 5)
          ..writeString(
            0,
            0,
            'Visit https://example.com/very/long/wrap',
            const Style(),
          )
          ..writeString(0, 1, 'ped/path?q=1&b=2#sec! now', const Style())
          ..writeString(
            0,
            2,
            '(see https://en.wikipedia.org/w/A_(b)).',
            const Style(),
          )
          ..writeString(
            0,
            3,
            '│http://[::1]:8420/status│ plain',
            const Style(),
          );

        pipe.foreign.sink.add(
          BufferFrameCodec.encode(
            BufferSnapshotFrame(
              snapshot: BufferSnapshot.fromBuffer(
                sessionId: sessId,
                seq: 1,
                buffer: buf,
                cursor: CursorState.origin,
                modes: const TerminalModes(mouseTracking: true, sgrMouse: true),
                wrappedRows: Uint8List.fromList([0x02]),
              ),
            ),
          ),
        );
        await pumpEventQueue();
        sentByClient.clear();

        // 1. Plain click on URL does NOT open URL; forwards to remote mouse tracking.
        check(
          vm.handlePtyMouseEvent(
            const ev.MouseEvent(
              x: 10,
              y: 1,
              button: ev.MouseButton.left,
              type: ev.MouseEventType.press,
            ),
          ),
        ).isTrue();
        await pumpEventQueue();
        check(openedUrls).isEmpty();
        check([...sentByClient.whereType<InputFrame>()]).length.equals(1);
        sentByClient.clear();

        // 1b. Hovering over a soft-wrapped URL with Ctrl (or Cmd) held underlines
        //     and highlights every cell of the URL across both wrapped rows with a
        //     Rainbow Road traveling color wave, and clears when Ctrl is released
        //     or the pointer moves off the URL.
        vm.handlePtyMouseEvent(
          const ev.MouseEvent(
            x: 10,
            y: 1,
            button: ev.MouseButton.none,
            type: ev.MouseEventType.move,
            modifiers: {ev.Modifier.control},
          ),
        );
        check(vm.hoveredUrl).equals(
          Uri.parse('https://example.com/very/long/wrapped/path?q=1&b=2#sec'),
        );
        check(vm.hoveredUrlRange).isNotNull();
        final hoveredComposed = vm.composeActiveBufferWithCursor();
        for (var x = 0; x < 6; x++) {
          check(
            hoveredComposed.getModifiers(x, 0) & Modifier.underline,
          ).equals(0);
          check(hoveredComposed.getBackground(x, 0)).equals(0);
        }
        final rainbowFgColors = <int>{};
        for (var x = 6; x < 40; x++) {
          check(
            hoveredComposed.getModifiers(x, 0) & Modifier.underline,
          ).equals(Modifier.underline);
          check(hoveredComposed.getBackground(x, 0)).not((it) => it.equals(0));
          rainbowFgColors.add(hoveredComposed.getForeground(x, 0));
        }
        check(rainbowFgColors.length).isGreaterThan(5);
        for (var x = 0; x < 20; x++) {
          check(
            hoveredComposed.getModifiers(x, 1) & Modifier.underline,
          ).equals(Modifier.underline);
          check(hoveredComposed.getBackground(x, 1)).not((it) => it.equals(0));
        }
        for (var x = 20; x < 25; x++) {
          check(
            hoveredComposed.getModifiers(x, 1) & Modifier.underline,
          ).equals(0);
          check(hoveredComposed.getBackground(x, 1)).equals(0);
        }

        // Stationary pointer modifier release/press via updateHoverModifiers updates hover state,
        // and clearMouseHover clears the hover cell when the pointer exits the terminal viewport.
        vm.updateHoverModifiers(const {});
        check(vm.hoveredUrl).isNull();
        check(vm.hoveredUrlRange).isNull();
        vm.updateHoverModifiers(const {ev.Modifier.meta});
        check(vm.hoveredUrl).equals(
          Uri.parse('https://example.com/very/long/wrapped/path?q=1&b=2#sec'),
        );
        vm.clearMouseHover();
        check(vm.hoveredUrl).isNull();
        vm.updateHoverModifiers(const {ev.Modifier.control});
        check(vm.hoveredUrl).isNull();

        // Ctrl+Drag in a mouse-tracking session does NOT trigger URL hover mid-drag (M1),
        // and when onOpenUrl is null, hovering with Ctrl does not mark links as clickable (L4).
        vm.handlePtyMouseEvent(
          const ev.MouseEvent(
            x: 10,
            y: 1,
            button: ev.MouseButton.left,
            type: ev.MouseEventType.drag,
            modifiers: {ev.Modifier.control},
          ),
        );
        check(vm.hoveredUrl).isNull();
        vm.onOpenUrl = null;
        vm.handlePtyMouseEvent(
          const ev.MouseEvent(
            x: 10,
            y: 1,
            button: ev.MouseButton.none,
            type: ev.MouseEventType.move,
            modifiers: {ev.Modifier.control},
          ),
        );
        check(vm.hoveredUrl).isNull();
        vm.onOpenUrl = openedUrls.add;
        vm.handlePtyMouseEvent(
          const ev.MouseEvent(
            x: 10,
            y: 1,
            button: ev.MouseButton.none,
            type: ev.MouseEventType.move,
            modifiers: {ev.Modifier.control},
          ),
        );
        check(vm.hoveredUrl).isNotNull();

        vm.handlePtyMouseEvent(
          const ev.MouseEvent(
            x: 10,
            y: 1,
            button: ev.MouseButton.none,
            type: ev.MouseEventType.move,
          ),
        );
        final unhoveredComposed = vm.composeActiveBufferWithCursor();
        check(
          unhoveredComposed.getModifiers(10, 0) & Modifier.underline,
        ).equals(0);
        check(unhoveredComposed.getBackground(10, 0)).equals(0);

        // 2. Ctrl+LeftClick on first row of soft-wrapped URL opens full joined URL
        //    and suppresses the matching drag + release from reaching remote PTY,
        //    even if a scroll-wheel tick or keystroke occurs while the button is held.
        check(
          vm.handlePtyMouseEvent(
            const ev.MouseEvent(
              x: 10,
              y: 1,
              button: ev.MouseButton.left,
              type: ev.MouseEventType.press,
              modifiers: {ev.Modifier.control},
            ),
          ),
        ).isTrue();
        check(openedUrls).deepEquals([
          Uri.parse('https://example.com/very/long/wrapped/path?q=1&b=2#sec'),
        ]);
        check(
          vm.handlePtyMouseEvent(
            const ev.MouseEvent(
              x: 10,
              y: 1,
              button: ev.MouseButton.wheelUp,
              type: ev.MouseEventType.press,
            ),
          ),
        ).isTrue();
        check(
          vm.encodeAndSendKey(const ev.KeyEvent('a', ev.KeyType.character)),
        ).isTrue();
        await pumpEventQueue();
        sentByClient.clear();
        check(
          vm.handlePtyMouseEvent(
            const ev.MouseEvent(
              x: 11,
              y: 1,
              button: ev.MouseButton.left,
              type: ev.MouseEventType.drag,
              modifiers: {ev.Modifier.control},
            ),
          ),
        ).isTrue();
        check(
          vm.handlePtyMouseEvent(
            const ev.MouseEvent(
              x: 11,
              y: 1,
              button: ev.MouseButton.left,
              type: ev.MouseEventType.release,
            ),
          ),
        ).isTrue();
        await pumpEventQueue();
        check(vm.activeSelection).isNull();
        check(sentByClient.whereType<InputFrame>()).isEmpty();

        // 3. macOS Ctrl+Click (MouseButton.right + Modifier.control) on second row
        //    of the soft-wrapped URL also resolves the full joined URL.
        openedUrls.clear();
        check(
          vm.handlePtyMouseEvent(
            const ev.MouseEvent(
              x: 5,
              y: 2,
              button: ev.MouseButton.right,
              type: ev.MouseEventType.press,
              modifiers: {ev.Modifier.control},
            ),
          ),
        ).isTrue();
        check(
          vm.handlePtyMouseEvent(
            const ev.MouseEvent(
              x: 5,
              y: 2,
              button: ev.MouseButton.left,
              type: ev.MouseEventType.release,
            ),
          ),
        ).isTrue();
        check(openedUrls).deepEquals([
          Uri.parse('https://example.com/very/long/wrapped/path?q=1&b=2#sec'),
        ]);

        // 4. Cmd+Click (Modifier.meta) on Wikipedia URL preserves balanced `(b)`
        //    while stripping outer closing `)` and trailing `.`.
        openedUrls.clear();
        check(
          vm.handlePtyMouseEvent(
            const ev.MouseEvent(
              x: 12,
              y: 3,
              button: ev.MouseButton.left,
              type: ev.MouseEventType.press,
              modifiers: {ev.Modifier.meta},
            ),
          ),
        ).isTrue();
        check(
          vm.handlePtyMouseEvent(
            const ev.MouseEvent(
              x: 12,
              y: 3,
              button: ev.MouseButton.left,
              type: ev.MouseEventType.release,
            ),
          ),
        ).isTrue();
        check(
          openedUrls,
        ).deepEquals([Uri.parse('https://en.wikipedia.org/w/A_(b)')]);

        // 5. Box-drawing border `│` stops URL extraction while IPv6 brackets `[::1]` are preserved.
        openedUrls.clear();
        check(
          vm.extractUrlAtCell(5, 3),
        ).equals(Uri.parse('http://[::1]:8420/status'));

        // 6. Ctrl+Click on non-URL text falls through to remote mouse tracking.
        openedUrls.clear();
        check(
          vm.handlePtyMouseEvent(
            const ev.MouseEvent(
              x: 30,
              y: 4,
              button: ev.MouseButton.left,
              type: ev.MouseEventType.press,
              modifiers: {ev.Modifier.control},
            ),
          ),
        ).isTrue();
        await pumpEventQueue();
        check(openedUrls).isEmpty();
        check([...sentByClient.whereType<InputFrame>()]).length.equals(1);

        // 7. TerminalSelection.extractUrlAt handles:
        //    - narrower scrollback rows after widening viewport (`cols: 80`),
        //    - wide CJK graphemes soft-wrapping at `width - 1` (with wrap-pad `' '`)
        //      and clicking continuation cell (`virtualX: 1`),
        //    - Markdown `[https://...](https://...)` without fusing across `](`,
        //    - smart quotes and horizontal ellipsis.
        final narrowScrollback = <VirtualLineSlice>[
          (isWrapped: false, characters: 'http://exa'.split(''), uris: null),
          (isWrapped: true, characters: 'mple.com/x'.split(''), uris: null),
        ];
        for (final (row, col) in [(0, 2), (1, 3)]) {
          check(
            TerminalSelection.extractUrlAt(
              (y) => y >= 0 && y < narrowScrollback.length
                  ? narrowScrollback[y]
                  : null,
              virtualX: col,
              virtualY: row,
              cols: 80,
            ),
          ).equals(Uri.parse('http://example.com/x'));
        }

        final wideWrapped = <VirtualLineSlice>[
          (
            isWrapped: false,
            characters: [...'https://ex.co/wiki/'.split(''), ' '],
            uris: null,
          ),
          (
            isWrapped: true,
            characters: const ['日', '', '本', '', '語', ''],
            uris: null,
          ),
        ];
        check(
          TerminalSelection.extractUrlAt(
            (y) => y >= 0 && y < wideWrapped.length ? wideWrapped[y] : null,
            virtualX: 5,
            virtualY: 0,
            cols: 20,
          ),
        ).equals(Uri.parse('https://ex.co/wiki/%E6%97%A5%E6%9C%AC%E8%AA%9E'));
        final wideMatch = TerminalSelection.matchUrlAt(
          (y) => y >= 0 && y < wideWrapped.length ? wideWrapped[y] : null,
          virtualX: 1,
          virtualY: 1,
          cols: 20,
        );
        check(wideMatch).isNotNull();
        check(
          wideMatch!.url,
        ).equals(Uri.parse('https://ex.co/wiki/%E6%97%A5%E6%9C%AC%E8%AA%9E'));
        check(wideMatch.range.containsCell(5, 1)).isTrue();

        final markdownAndQuotes = <VirtualLineSlice>[
          (
            isWrapped: false,
            characters: '[https://example.com/a](https://example.com/b)'.split(
              '',
            ),
            uris: null,
          ),
          (
            isWrapped: false,
            characters: '“https://example.com/q” https://example.com/e…'.split(
              '',
            ),
            uris: null,
          ),
        ];
        VirtualLineSlice? lookupMarkdown(int y) =>
            y >= 0 && y < markdownAndQuotes.length
            ? markdownAndQuotes[y]
            : null;
        check(
          TerminalSelection.extractUrlAt(
            lookupMarkdown,
            virtualX: 5,
            virtualY: 0,
            cols: 80,
          ),
        ).equals(Uri.parse('https://example.com/a'));
        check(
          TerminalSelection.extractUrlAt(
            lookupMarkdown,
            virtualX: 30,
            virtualY: 0,
            cols: 80,
          ),
        ).equals(Uri.parse('https://example.com/b'));
        check(
          TerminalSelection.extractUrlAt(
            lookupMarkdown,
            virtualX: 5,
            virtualY: 1,
            cols: 80,
          ),
        ).equals(Uri.parse('https://example.com/q'));
        check(
          TerminalSelection.extractUrlAt(
            lookupMarkdown,
            virtualX: 30,
            virtualY: 1,
            cols: 80,
          ),
        ).equals(Uri.parse('https://example.com/e'));

        // 8. TerminalSelection.paint supports uniform background, modifiers, and per-cell foregroundAt.
        final paintBuf = Buffer.blank(10, 2);
        const span = TerminalSelection(
          anchor: Point<int>(2, 0),
          focus: Point<int>(5, 0),
        );
        span.paint(
          paintBuf,
          background: 0xFF445566,
          modifiers: Modifier.underline,
          foregroundAt: (idx, total) => 0xFF000000 | (idx * 10 + total),
        );
        check(paintBuf.getForeground(2, 0)).equals(0xFF000004);
        check(paintBuf.getBackground(2, 0)).equals(0xFF445566);
        check(paintBuf.getForeground(5, 0)).equals(0xFF000022);
        check(paintBuf.getBackground(5, 0)).equals(0xFF445566);
        check(
          paintBuf.getModifiers(3, 0) & Modifier.underline,
        ).equals(Modifier.underline);
      },
    );

    _defineWave2Tests(sessA, sessB);
  });
}

void _defineWave2Tests(SessionId sessA, SessionId sessB) {
  _defineCorruptFrameAndSnapshotTests(sessA, sessB);
  _defineHibernationAndUploadEpochTests(sessA, sessB);
  _defineRound3PolishTests(sessA);
}

void _defineCorruptFrameAndSnapshotTests(SessionId sessA, SessionId sessB) {
  test(
    'recovers from CorruptSessionFrameException via RequestKeyframeFrame without disconnecting, treats auth_timeout as transient, and gates background visualListeners and snapshot dedupe',
    () async {
      check(
        CastClientRepository.isFatalAuthErrorCode('auth_timeout'),
      ).isFalse();
      check(CastClientRepository.isFatalAuthErrorCode('auth_busy')).isFalse();
      check(CastClientRepository.isFatalAuthErrorCode('auth_failed')).isTrue();

      // Carbon-A4: adaptBinaryWebSocketChannel swallows late sink throws.
      final throwingWs = _FakeWebSocketChannel(
        incoming: const Stream<Object?>.empty(),
        onAdd: (_) => throw StateError('closed'),
        onAddError: (_, _) => throw StateError('closed error'),
        doneFuture: Future<void>.value(),
      );
      final adapted = adaptBinaryWebSocketChannel(throwingWs);
      adapted.sink.add(Uint8List.fromList([1]));
      adapted.sink.addError(StateError('boom'));

      final pipe = StreamChannelController<Uint8List>();
      final sentByClient = <CastMessage>[];
      pipe.foreign.stream.listen((raw) {
        sentByClient.add(BufferFrameCodec.decode(raw));
      });
      final transport = WsClientTransport(
        channelFactory: () async => pipe.local,
      );
      final repo = CastClientRepository(transport: transport);
      final vm = CastWorkspaceViewModel(
        repository: repo,
        resizeDebounce: Duration.zero,
      );
      addTearDown(() async {
        await vm.dispose();
        await repo.dispose();
      });

      // Carbon-A3: selectSession before auth updates activeSessionId without sending SubscribeSessionFrame.
      await vm.selectSession(sessB);
      check(vm.activeSessionId).equals(sessB);
      check(sentByClient).isEmpty();

      await repo.connect();
      pipe.foreign.sink.add(
        BufferFrameCodec.encode(
          SessionDirectoryFrame(
            sessions: [
              SessionSummary(id: sessA, title: 'a', cols: 80, rows: 24),
              SessionSummary(id: sessB, title: 'b', cols: 80, rows: 24),
            ],
          ),
        ),
      );
      pipe.foreign.sink.add(
        BufferFrameCodec.encode(
          BufferSnapshotFrame(
            snapshot: _makeSnapshot(
              sessB,
              seq: 5,
              cols: 80,
              rows: 24,
              text: 'five',
            ),
          ),
        ),
      );
      await pumpEventQueue();
      check(vm.sessionStateOf(sessB)).equals(.synchronized);

      // Carbon-A5: lower-seq snapshot (caster restart seq: 1) and dimension-change snapshot (seq: 1, cols: 90) both apply!
      pipe.foreign.sink.add(
        BufferFrameCodec.encode(
          BufferSnapshotFrame(
            snapshot: _makeSnapshot(
              sessB,
              seq: 1,
              cols: 80,
              rows: 24,
              text: 'restart',
            ),
          ),
        ),
      );
      await pumpEventQueue();
      check(vm.composeActiveBufferWithCursor().getCharacter(0, 0)).equals('r');

      pipe.foreign.sink.add(
        BufferFrameCodec.encode(
          BufferSnapshotFrame(
            snapshot: _makeSnapshot(
              sessB,
              seq: 1,
              cols: 90,
              rows: 24,
              text: 'wide',
            ),
          ),
        ),
      );
      await pumpEventQueue();
      check(vm.composeActiveBufferWithCursor().width).equals(90);

      // Carbon-A1: background delta on sessB while sessA is active does not fire visualListeners.
      await vm.selectSession(sessA);
      pipe.foreign.sink.add(
        BufferFrameCodec.encode(
          BufferSnapshotFrame(
            snapshot: _makeSnapshot(sessA, seq: 1, cols: 80, rows: 24),
          ),
        ),
      );
      await pumpEventQueue();
      var visualFires = 0;
      final removeVisual = vm.addVisualListener(() => visualFires++);
      pipe.foreign.sink.add(
        BufferFrameCodec.encode(
          BufferDeltaFrame(
            delta: BufferDelta(
              sessionId: sessB,
              baseSeq: 1,
              seq: 2,
              cols: 90,
              rows: 24,
              cursor: CursorState.origin,
              modes: TerminalModes.defaults,
              scrollback: ScrollbackWindow.empty,
              runs: const [],
            ),
          ),
        ),
      );
      await pumpEventQueue();
      check(visualFires).equals(0);
      removeVisual();

      // C1 Gap 1: Corrupt compressed BufferSnapshotFrame tail for sessA triggers RequestKeyframeFrame without disconnecting.
      sentByClient.clear();
      final validSnapshotBytes = BufferFrameCodec.encode(
        BufferSnapshotFrame(
          snapshot: _makeSnapshot(
            sessA,
            seq: 2,
            cols: 80,
            rows: 24,
            text: 'compressed-tail',
          ),
        ),
      );
      final corruptFrame = Uint8List.fromList(validSnapshotBytes);
      for (var i = corruptFrame.length - 8; i < corruptFrame.length; i++) {
        corruptFrame[i] ^= 0xFF;
      }
      pipe.foreign.sink.add(corruptFrame);
      await pumpEventQueue();
      check(transport.isConnected).isTrue();
      check(vm.sessionStateOf(sessA)).equals(.awaitingKeyframe);
      check(sentByClient.single)
          .isA<RequestKeyframeFrame>()
          .has((f) => f.sessionId, 'sessionId')
          .equals(sessA);
    },
  );
}

void _defineHibernationAndUploadEpochTests(SessionId sessA, SessionId sessB) {
  test(
    'defers 10s inactive/hidden unsubscription during active upload, ignores directory echo while hidden, guards upload cancel epoch, and records Tracer spans',
    () {
      FakeAsync().run((async) {
        final pipe = StreamChannelController<Uint8List>();
        final sentByClient = <CastMessage>[];
        pipe.foreign.stream.listen((raw) {
          sentByClient.add(BufferFrameCodec.decode(raw));
        });
        final transport = WsClientTransport(
          channelFactory: () async => pipe.local,
        );
        final repo = CastClientRepository(transport: transport);
        final vm = CastWorkspaceViewModel(
          repository: repo,
          resizeDebounce: Duration.zero,
        );

        unawaited(repo.connect());
        async.flushMicrotasks();
        pipe.foreign.sink.add(
          BufferFrameCodec.encode(
            SessionDirectoryFrame(
              sessions: [
                SessionSummary(id: sessA, title: 'a', cols: 80, rows: 24),
                SessionSummary(id: sessB, title: 'b', cols: 80, rows: 24),
              ],
            ),
          ),
        );
        pipe.foreign.sink.add(
          BufferFrameCodec.encode(
            BufferSnapshotFrame(
              snapshot: _makeSnapshot(
                sessA,
                seq: 1,
                cols: 80,
                rows: 24,
                text: 'keep',
              ),
            ),
          ),
        );
        async.flushMicrotasks();
        sentByClient.clear();

        // Start an upload on sessA, then switch to sessB and elapse 10s -> Upload Guard defers unsubscription of sessA!
        final fileA = MemoryDroppedFileSource(
          name: 'a.txt',
          bytes: Uint8List.fromList([1, 2, 3]),
        );
        unawaited(vm.uploadDroppedFiles([fileA]));
        async.flushMicrotasks();
        final startFrame1 = sentByClient
            .whereType<FileUploadStartFrame>()
            .single;

        unawaited(vm.selectSession(sessB));
        async.flushMicrotasks();
        pipe.foreign.sink.add(
          BufferFrameCodec.encode(
            BufferSnapshotFrame(
              snapshot: _makeSnapshot(sessB, seq: 1, cols: 80, rows: 24),
            ),
          ),
        );
        async.flushMicrotasks();
        sentByClient.clear();
        async.elapse(const Duration(seconds: 10));
        check(sentByClient.whereType<UnsubscribeSessionFrame>()).isEmpty();

        // Carbon-A2: cancel upload 1 and immediately start upload 2 -> upload 1's finally must NOT reset isUploadingFiles!
        vm.cancelActiveFileUpload();
        final fileB = MemoryDroppedFileSource(
          name: 'b.txt',
          bytes: Uint8List.fromList([4]),
        );
        unawaited(vm.uploadDroppedFiles([fileB]));
        async.flushMicrotasks();
        check(vm.isUploadingFiles).isTrue();
        // Late ack for cancelled startFrame1 is ignored.
        pipe.foreign.sink.add(
          BufferFrameCodec.encode(
            FileUploadAckFrame(
              sessionId: sessA,
              transferId: startFrame1.transferId,
              status: .ready,
              nextOffset: 0,
            ),
          ),
        );
        async.flushMicrotasks();
        check(vm.isUploadingFiles).isTrue();
        vm.cancelActiveFileUpload();
        async.flushMicrotasks();

        // Next 10s tick unsubscribes sessA while preserving its cached Buffer in memory.
        sentByClient.clear();
        async.elapse(const Duration(seconds: 10));
        check(sentByClient.single)
            .isA<UnsubscribeSessionFrame>()
            .has((f) => f.sessionId, 'sessionId')
            .equals(sessA);

        // C2: setWorkspaceVisible(false) for 10s suspends sessB and ignores SessionDirectoryFrame echo while hidden.
        sentByClient.clear();
        vm.setWorkspaceVisible(false);
        async.elapse(const Duration(seconds: 10));
        check(sentByClient.single)
            .isA<UnsubscribeSessionFrame>()
            .has((f) => f.sessionId, 'sessionId')
            .equals(sessB);

        sentByClient.clear();
        pipe.foreign.sink.add(
          BufferFrameCodec.encode(
            SessionDirectoryFrame(
              sessions: [
                SessionSummary(id: sessA, title: 'a', cols: 80, rows: 24),
                SessionSummary(id: sessB, title: 'b', cols: 80, rows: 24),
              ],
            ),
          ),
        );
        async.flushMicrotasks();
        check(sentByClient).isEmpty();

        // Resuming visibility re-subscribes active session sessB.
        vm.setWorkspaceVisible(true);
        async.flushMicrotasks();
        check(sentByClient.single)
            .isA<SubscribeSessionFrame>()
            .has((f) => f.sessionId, 'sessionId')
            .equals(sessB);

        // C3: Tracer records WorkspaceBufferCompositor.compose span when enabled.
        Tracer.isEnabled = true;
        vm.composeActiveBufferWithCursor();
        Tracer.isEnabled = false;
        check(
          Tracer.registerString('WorkspaceBufferCompositor.compose'),
        ).isGreaterThan(0);

        unawaited(vm.dispose());
        unawaited(repo.dispose());
        async.flushMicrotasks();
      });
    },
  );
}

void _defineRound3PolishTests(SessionId sessA) {
  test(
    'activates first session discovered while hidden on setWorkspaceVisible(true), throttles repeated corrupt-frame keyframe retries with 250ms..5s backoff, and coalesces caster_busy notice',
    () {
      FakeAsync().run((async) {
        final pipe = StreamChannelController<Uint8List>();
        final sentByClient = <CastMessage>[];
        pipe.foreign.stream.listen((raw) {
          sentByClient.add(BufferFrameCodec.decode(raw));
        });
        final transport = WsClientTransport(
          channelFactory: () async => pipe.local,
        );
        final repo = CastClientRepository(transport: transport);
        final vm = CastWorkspaceViewModel(
          repository: repo,
          resizeDebounce: Duration.zero,
        );

        unawaited(repo.connect());
        async.flushMicrotasks();
        pipe.foreign.sink.add(
          BufferFrameCodec.encode(const SessionDirectoryFrame(sessions: [])),
        );
        async.flushMicrotasks();
        sentByClient.clear();

        // Carbon-R2-M1 / Opus-L1: Hide empty workspace for 10s, announce sessA while hidden, then resume -> selects and subscribes sessA!
        vm.setWorkspaceVisible(false);
        async.elapse(const Duration(seconds: 10));
        pipe.foreign.sink.add(
          BufferFrameCodec.encode(
            SessionDirectoryFrame(
              sessions: [
                SessionSummary(id: sessA, title: 'first', cols: 80, rows: 24),
              ],
            ),
          ),
        );
        async.flushMicrotasks();
        check(sentByClient).isEmpty();

        vm.setWorkspaceVisible(true);
        async.flushMicrotasks();
        check(vm.activeSessionId).equals(sessA);
        check(sentByClient.single)
            .isA<SubscribeSessionFrame>()
            .has((f) => f.sessionId, 'sessionId')
            .equals(sessA);
        sentByClient.clear();

        // Opus-L3: Corrupt frames back off 0ms -> 250ms -> 500ms and reset on valid snapshot.
        final validSnapshotBytes = BufferFrameCodec.encode(
          BufferSnapshotFrame(
            snapshot: _makeSnapshot(
              sessA,
              seq: 1,
              cols: 80,
              rows: 24,
              text: 'compressed-tail',
            ),
          ),
        );
        final corruptFrame = Uint8List.fromList(validSnapshotBytes);
        for (var i = corruptFrame.length - 8; i < corruptFrame.length; i++) {
          corruptFrame[i] ^= 0xFF;
        }

        // 1st corrupt frame: immediate RequestKeyframeFrame (0ms).
        pipe.foreign.sink.add(corruptFrame);
        async.flushMicrotasks();
        check(sentByClient.whereType<RequestKeyframeFrame>().length).equals(1);
        sentByClient.clear();

        // 2nd & 3rd corrupt frames within 250ms: coalesced until 250ms elapses.
        pipe.foreign.sink.add(corruptFrame);
        pipe.foreign.sink.add(corruptFrame);
        async.flushMicrotasks();
        check(sentByClient).isEmpty();
        async.elapse(const Duration(milliseconds: 249));
        check(sentByClient).isEmpty();
        async.elapse(const Duration(milliseconds: 1));
        check(sentByClient.whereType<RequestKeyframeFrame>().length).equals(1);
        sentByClient.clear();

        // Valid snapshot resets backoff -> next corrupt frame requests keyframe immediately (0ms) again!
        pipe.foreign.sink.add(validSnapshotBytes);
        async.flushMicrotasks();
        sentByClient.clear();
        pipe.foreign.sink.add(corruptFrame);
        async.flushMicrotasks();
        check(sentByClient.whereType<RequestKeyframeFrame>().length).equals(1);

        // Opus-L5: caster_busy ErrorFrame surfaces coalesced notice.
        pipe.foreign.sink.add(
          BufferFrameCodec.encode(
            const ErrorFrame(code: 'caster_busy', message: 'queue full'),
          ),
        );
        async.flushMicrotasks();
        check(
          vm.clipboardNotice,
        ).equals(' ! Caster input queue busy; input dropped ');

        unawaited(vm.dispose());
        unawaited(repo.dispose());
        async.flushMicrotasks();
      });
    },
  );

  _defineKttyAndOsc8ViewModelTests();
}

void _defineKttyAndOsc8ViewModelTests() {
  test(
    'supports kittyKeyboardFlags release forwarding (preserving Alt+Drag box selection & scrollback), 8x16 ?1016h mouse pixels under docks, mailto:, file:// clipboard copy, and shortcut release suppression',
    () async {
      final pipe = StreamChannelController<Uint8List>();
      final sentByClient = <CastMessage>[];
      const sessId = SessionId('ktty-vm');
      pipe.foreign.stream.listen((raw) {
        final msg = BufferFrameCodec.decode(raw);
        sentByClient.add(msg);
        if (msg is AuthFrame) {
          pipe.foreign.sink.add(
            BufferFrameCodec.encode(const AuthAcceptedFrame(role: .client)),
          );
          pipe.foreign.sink.add(
            BufferFrameCodec.encode(
              const SessionDirectoryFrame(
                sessions: [
                  SessionSummary(
                    id: sessId,
                    title: 'ktty',
                    cols: 40,
                    rows: 6,
                    subscriberCount: 1,
                  ),
                  SessionSummary(
                    id: SessionId('ktty-2'),
                    title: 'other',
                    cols: 40,
                    rows: 6,
                    subscriberCount: 0,
                  ),
                ],
              ),
            ),
          );
        } else if (msg is SubscribeSessionFrame) {
          final buf = Buffer.blank(40, 6)
            ..writeString(0, 0, 'Mail mailto:dev@dart.dev now', const Style())
            ..writeString(0, 1, 'Open main.dart', const Style())
            ..writeString(0, 2, 'Box0123456789', const Style())
            ..writeString(0, 3, 'BoxABCDEFGHIJ', const Style())
            ..writeString(0, 4, 'Open c++#1@main.cc', const Style());
          for (var x = 5; x < 14; x++) {
            buf.setUri(
              x,
              1,
              'file://macbook.local/Users/codefu/my%20file.dart',
            );
          }
          for (var x = 5; x < 18; x++) {
            buf.setUri(
              x,
              4,
              'file://macbook.local/Users/codefu/c%2B%2B%231%40main.cc',
            );
          }
          pipe.foreign.sink.add(
            BufferFrameCodec.encode(
              BufferSnapshotFrame(
                snapshot: BufferSnapshot.fromBuffer(
                  sessionId: msg.sessionId,
                  seq: 1,
                  buffer: buf,
                  cursor: CursorState.origin,
                  modes: const TerminalModes(
                    mouseTracking: true,
                    sgrMouse: true,
                    sgrPixelsMouse: true,
                    kittyKeyboardFlags: 3,
                  ),
                  scrollback: const ScrollbackWindow(
                    clearSeq: 0,
                    oldestLine: 0,
                    totalLines: 5,
                  ),
                ),
              ),
            ),
          );
        }
      });

      final openedUrls = <Uri>[];
      final clipboardWrites = <String>[];
      final repo = CastClientRepository(
        transport: WsClientTransport(
          serverUri: Uri.parse('ws://127.0.0.1:8420/v1/client'),
          channelFactory: () async => pipe.local,
        ),
        enableReconnect: false,
      );
      final vm = CastWorkspaceViewModel(
        repository: repo,
        initialDockPosition: .left,
        initialViewportCols: 40,
        initialViewportRows: 6,
        resizeDebounce: Duration.zero,
        onOpenUrl: openedUrls.add,
        onClipboardWrite: clipboardWrites.add,
      );
      final terminal = MockTerminal(
        MockTerminalBackend(size: const Point(62, 6)),
      );
      final controller = CastSceneController(terminal: terminal, viewModel: vm);
      vm.onClipboardWrite = clipboardWrites.add;
      addTearDown(() async {
        controller.dispose();
        terminal.dispose();
        await vm.dispose();
        await repo.dispose();
      });

      await repo.connect();
      await pumpEventQueue();

      check(controller.wantsKeyReleaseEvents).isTrue();
      check(controller.wantsPixelMouseEvents).isTrue();
      controller.setCellPixelSize(14.5, 29.0);
      check(controller.cellPixelSize).equals((14.5, 29.0));

      // 1. Clicking col 0 of PTY under a 22-col left dock (globalX=23, x=1) at zoomed
      //    14.5x29.0 font size normalizes into 8x16 PTY cell-pixel space (>= 1).
      sentByClient.clear();
      controller.sceneManager.handleMouseEvent(
        const ev.MouseEvent(
          x: 23,
          y: 1,
          pixelX: 320, // 22 * 14.5 = 319 -> +0px inside col 0 -> ptyPxX = 1
          pixelY: 16, // 15 / 29.0 * 16 -> floor(8.27) + 1 = 9
          button: .left,
          type: .press,
        ),
      );
      await pumpEventQueue();
      final mouseInputs = [...sentByClient.whereType<InputFrame>()];
      check(mouseInputs.length).equals(1);
      check(utf8.decode(mouseInputs.single.data)).equals('\x1b[<0;1;9M');

      // 1b. Cross-dock out-of-bounds ?1016h drag/release (x <= 0 with positive global pixelX)
      //     is dropped rather than leaking raw global viewer pixels!
      sentByClient.clear();
      check(
        vm.encodeAndSendMouse(
          const ev.MouseEvent(
            x: 0,
            y: 1,
            globalX: 5,
            globalY: 1,
            pixelX: 72,
            pixelY: 16,
            button: .left,
            type: .drag,
          ),
        ),
      ).isFalse();
      await pumpEventQueue();
      check(sentByClient.whereType<InputFrame>()).isEmpty();

      // 2. Shift+Alt+Drag box selection while scrolled up, followed by KeyEventType.release,
      //    forwards the Kitty release sequence WITHOUT clearing activeSelection or scrollback!
      check(vm.scrollActiveBy(2)).isTrue();
      check(vm.activeScrollOffsetLines).equals(2);
      vm.setCopyOnSelect(false);
      check(
        vm.handlePtyMouseEvent(
          const ev.MouseEvent(
            x: 4,
            y: 5,
            button: .left,
            type: .press,
            modifiers: {ev.Modifier.shift, ev.Modifier.alt},
          ),
        ),
      ).isTrue();
      check(
        vm.handlePtyMouseEvent(
          const ev.MouseEvent(
            x: 6,
            y: 6,
            button: .left,
            type: .drag,
            modifiers: {ev.Modifier.shift, ev.Modifier.alt},
          ),
        ),
      ).isTrue();
      check(
        vm.handlePtyMouseEvent(
          const ev.MouseEvent(
            x: 6,
            y: 6,
            button: .left,
            type: .release,
            modifiers: {ev.Modifier.alt},
          ),
        ),
      ).isTrue();
      check(vm.activeSelection?.mode).equals(SelectionMode.box);

      sentByClient.clear();
      check(
        vm.encodeAndSendKey(
          const ev.KeyEvent(
            '\u{E063}',
            ev.KeyType.character,
            eventType: ev.KeyEventType.release,
          ),
        ),
      ).isTrue();
      await pumpEventQueue();
      check(
        utf8.decode(sentByClient.whereType<InputFrame>().single.data),
      ).equals('\x1b[57443;1:3u');
      // Selection AND scrollback offset MUST remain intact after key release!
      check(vm.activeSelection).isNotNull();
      check(vm.activeSelection?.mode).equals(SelectionMode.box);
      check(vm.activeScrollOffsetLines).equals(2);

      // 3. Shortcut key-down consumed by CastSceneController (Ctrl+\ o, Cmd+C)
      //    suppresses its matching KeyEventType.release from reaching the PTY!
      sentByClient.clear();
      terminal.injectTestEvent(
        const ev.KeyEvent(
          r'\',
          ev.KeyType.character,
          modifiers: {ev.Modifier.control},
        ),
      );
      terminal.injectTestEvent(
        const ev.KeyEvent(
          r'\',
          ev.KeyType.character,
          eventType: ev.KeyEventType.release,
        ),
      );
      terminal.injectTestEvent(const ev.KeyEvent('o', ev.KeyType.character));
      terminal.injectTestEvent(
        const ev.KeyEvent(
          'o',
          ev.KeyType.character,
          eventType: ev.KeyEventType.release,
        ),
      );
      terminal.injectTestEvent(
        const ev.KeyEvent(
          'c',
          ev.KeyType.character,
          modifiers: {ev.Modifier.meta},
        ),
      );
      terminal.injectTestEvent(
        const ev.KeyEvent(
          'c',
          ev.KeyType.character,
          eventType: ev.KeyEventType.release,
        ),
      );
      await pumpEventQueue();
      check(sentByClient.whereType<InputFrame>()).isEmpty();
      check(vm.copyOnSelect).isTrue();
      check(clipboardWrites).deepEquals(['012\nABC']);

      // 4. mailto: opens via onOpenUrl on Ctrl+Click, while file:// OSC 8 copies
      //    decoded local path to clipboard with a status toast and does NOT call onOpenUrl!
      vm.scrollActiveToBottom();
      openedUrls.clear();
      clipboardWrites.clear();

      check(
        vm.handlePtyMouseEvent(
          const ev.MouseEvent(
            x: 10,
            y: 1,
            button: .left,
            type: .press,
            modifiers: {ev.Modifier.control},
          ),
        ),
      ).isTrue();
      check(
        vm.handlePtyMouseEvent(
          const ev.MouseEvent(x: 10, y: 1, button: .left, type: .release),
        ),
      ).isTrue();
      check(openedUrls).deepEquals([Uri.parse('mailto:dev@dart.dev')]);

      openedUrls.clear();
      check(
        vm.handlePtyMouseEvent(
          const ev.MouseEvent(
            x: 8,
            y: 2,
            button: .left,
            type: .press,
            modifiers: {ev.Modifier.control},
          ),
        ),
      ).isTrue();
      check(
        vm.handlePtyMouseEvent(
          const ev.MouseEvent(x: 8, y: 2, button: .left, type: .release),
        ),
      ).isTrue();
      check(openedUrls).isEmpty();
      check(clipboardWrites).deepEquals(['/Users/codefu/my file.dart']);
      check(
        vm.clipboardNotice,
      ).equals(' Copied path: /Users/codefu/my file.dart ');

      // 5. file:// percent-encoded reserved chars (%2B, %23, %40) decode via Uri.decodeComponent!
      clipboardWrites.clear();
      check(
        vm.handlePtyMouseEvent(
          const ev.MouseEvent(
            x: 8,
            y: 5,
            button: .left,
            type: .press,
            modifiers: {ev.Modifier.control},
          ),
        ),
      ).isTrue();
      check(
        vm.handlePtyMouseEvent(
          const ev.MouseEvent(x: 8, y: 5, button: .left, type: .release),
        ),
      ).isTrue();
      check(clipboardWrites).deepEquals(['/Users/codefu/c++#1@main.cc']);

      // 6. Shifted US chord (Ctrl+\ ! with '1' release) + modal Ctrl+\ ? + Escape close
      //    suppress orphan releases while forwarding subsequent real Enter press + release!
      sentByClient.clear();
      terminal.injectTestEvent(
        const ev.KeyEvent(
          r'\',
          ev.KeyType.character,
          modifiers: {ev.Modifier.control},
        ),
      );
      terminal.injectTestEvent(
        const ev.KeyEvent(
          '!',
          ev.KeyType.character,
          modifiers: {ev.Modifier.shift},
        ),
      );
      terminal.injectTestEvent(
        const ev.KeyEvent(
          '1',
          ev.KeyType.character,
          eventType: ev.KeyEventType.release,
        ),
      );
      await pumpEventQueue();
      check(sentByClient.whereType<InputFrame>()).isEmpty();

      terminal.injectTestEvent(
        const ev.KeyEvent(
          r'\',
          ev.KeyType.character,
          modifiers: {ev.Modifier.control},
        ),
      );
      terminal.injectTestEvent(
        const ev.KeyEvent(
          '?',
          ev.KeyType.character,
          modifiers: {ev.Modifier.shift},
        ),
      );
      await pumpEventQueue();
      check(controller.isChordsHelpOpen).isTrue();
      terminal.injectTestEvent(
        const ev.KeyEvent(
          '/',
          ev.KeyType.character,
          eventType: ev.KeyEventType.release,
        ),
      );
      terminal.injectTestEvent(const ev.KeyEvent('escape', ev.KeyType.escape));
      await pumpEventQueue();
      check(controller.isChordsHelpOpen).isFalse();
      terminal.injectTestEvent(
        const ev.KeyEvent(
          'escape',
          ev.KeyType.escape,
          eventType: ev.KeyEventType.release,
        ),
      );
      await pumpEventQueue();
      check(sentByClient.whereType<InputFrame>()).isEmpty();

      // Real Enter press + release afterward forwards BOTH press and release!
      terminal.injectTestEvent(const ev.KeyEvent('\n', ev.KeyType.enter));
      terminal.injectTestEvent(
        const ev.KeyEvent(
          '\n',
          ev.KeyType.enter,
          eventType: ev.KeyEventType.release,
        ),
      );
      await pumpEventQueue();
      final enterPayloads = [
        for (final f in sentByClient.whereType<InputFrame>())
          utf8.decode(f.data),
      ];
      check(enterPayloads).deepEquals(['\r', '\x1b[13;1:3u']);

      // 7. Ctrl-hovering a link and switching tabs synchronously clears hoveredUrl!
      vm.handlePtyMouseEvent(
        const ev.MouseEvent(
          x: 10,
          y: 1,
          button: .none,
          type: .move,
          modifiers: {ev.Modifier.control},
        ),
      );
      check(vm.hoveredUrl).equals(Uri.parse('mailto:dev@dart.dev'));
      final switchFuture = vm.selectSession(const SessionId('ktty-2'));
      check(vm.hoveredUrl).isNull();
      await switchFuture;
      await pumpEventQueue();
    },
  );
}

extension on Subject<CastMessage> {
  void equalsOrSameResize(SessionId id, int cols, int rows) {
    this.isA<ResizeFrame>()
      ..has((r) => r.sessionId, 'sessionId').equals(id)
      ..has((r) => r.cols, 'cols').equals(cols)
      ..has((r) => r.rows, 'rows').equals(rows);
  }
}

final class _FakeWebSocketChannel extends StreamChannelMixin<Object?>
    implements WebSocketChannel {
  @override
  final Stream<Object?> stream;

  @override
  final WebSocketSink sink;

  _FakeWebSocketChannel({
    required Stream<Object?> incoming,
    required void Function(Object? data) onAdd,
    void Function(Object error, StackTrace? stackTrace)? onAddError,
    required Future<void> doneFuture,
  }) : stream = incoming,
       sink = _FakeWebSocketSink(
         onAdd: onAdd,
         onAddError: onAddError,
         done: doneFuture,
       );

  @override
  int? get closeCode => null;

  @override
  String? get closeReason => null;

  @override
  String? get protocol => null;

  @override
  Future<void> get ready => Future<void>.value();
}

final class _FakeWebSocketSink implements WebSocketSink {
  final void Function(Object? data) _onAdd;
  final void Function(Object error, StackTrace? stackTrace)? _onAddError;

  @override
  final Future<void> done;

  _FakeWebSocketSink({
    required void Function(Object? data) onAdd,
    void Function(Object error, StackTrace? stackTrace)? onAddError,
    required this.done,
  }) : _onAdd = onAdd,
       _onAddError = onAddError;

  @override
  void add(Object? data) => _onAdd(data);

  @override
  void addError(Object error, [StackTrace? stackTrace]) =>
      _onAddError?.call(error, stackTrace);

  @override
  Future<void> addStream(Stream<Object?> stream) => stream.forEach(_onAdd);

  @override
  Future<void> close([int? closeCode, String? closeReason]) async {}
}
