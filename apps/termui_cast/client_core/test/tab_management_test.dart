import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:checks/checks.dart';
import 'package:clock/clock.dart';
import 'package:stream_channel/stream_channel.dart';
import 'package:termui/termui.dart';
import 'package:termui_cast_client_core/src/scrollback_page_cache.dart';
import 'package:termui_cast_client_core/termui_cast_client_core.dart';
import 'package:termui_cast_protocol/termui_cast_protocol.dart';
import 'package:termui_test/termui_test.dart';
import 'package:test/test.dart';

import 'support/fake_three_way_ws_harness.dart';

final class _MutableClock {
  DateTime now;

  _MutableClock([DateTime? initial])
    : now = initial ?? DateTime.utc(2026, 11, 5, 12);

  Clock get clock => Clock(() => now);

  void advance(Duration delta) {
    now = now.add(delta);
  }
}

String _rowText(Buffer buffer, int row) {
  final sb = StringBuffer();
  for (var x = 0; x < buffer.width; x++) {
    final ch = buffer.getCharacter(x, row);
    if (ch.isNotEmpty) sb.write(ch);
  }
  return '$sb';
}

String _screenText(Buffer buffer) => [
  for (var y = 0; y < buffer.height; y++) _rowText(buffer, y).trimRight(),
].join('\n');

Future<void> _settle(TerminalTester tester, [int ticks = 4]) async {
  for (var i = 0; i < ticks; i++) {
    await tester.pump(const Duration(milliseconds: 20));
  }
}

void _clearTextField(TerminalTester tester, int count) {
  for (var i = 0; i < count; i++) {
    tester.sendKey(LogicalKey.backspace);
  }
}

void main() {
  tearDown(() {
    DragDropManager.cancelDrag();
    DragDropManager.onDragSessionChanged = null;
  });

  _defineTabStripTests();
  _defineDialogAndGestureTests();
  _defineRenameAndReorderIntegrationTests();
  _defineLifecycleAndOverflowIntegrationTests();
  _defineAdversarialRegressionTests();
  _defineDragAndNoticeRegressionTests();
}

void _defineTabStripTests() {
  group('SessionTabStrip and SessionTabStatus unit behavior', () {
    test(
      'formats fixed 5-column status chips and transitions ⏳ / ⏻ -> 💀 at 30s',
      () {
        final t0 = DateTime.utc(2026, 11, 5, 12);
        expect(SessionTabStatus.live.statusChip, isEmpty);

        final discStart = SessionTabStatus.compute(
          closeReason: .disconnected,
          endedAt: t0,
          exitCode: -1,
          now: t0,
        );
        check(discStart.phase).equals(TabVisualPhase.disconnectedCountdown);
        check(discStart.statusChip).equals('⏳30s');
        check(DockTabLayout.displayWidth(discStart.statusChip)).equals(5);

        final discSingleDigit = SessionTabStatus.compute(
          closeReason: .disconnected,
          endedAt: t0,
          exitCode: -1,
          now: t0.add(const Duration(seconds: 21, milliseconds: 500)),
        );
        check(discSingleDigit.statusChip).equals('⏳ 9s');
        check(DockTabLayout.displayWidth(discSingleDigit.statusChip)).equals(5);

        final exitStart = SessionTabStatus.compute(
          closeReason: .exited,
          endedAt: t0,
          exitCode: 0,
          now: t0.add(const Duration(milliseconds: 100)),
        );
        check(exitStart.phase).equals(TabVisualPhase.exitedCountdown);
        check(exitStart.statusChip).equals('⏻ 30s');
        check(DockTabLayout.displayWidth(exitStart.statusChip)).equals(5);

        final deadAfter30s = SessionTabStatus.compute(
          closeReason: .exited,
          endedAt: t0,
          exitCode: 0,
          now: t0.add(const Duration(seconds: 30)),
        );
        check(deadAfter30s.phase).equals(TabVisualPhase.dead);
        check(deadAfter30s.statusChip).equals('💀   ');
        check(DockTabLayout.displayWidth(deadAfter30s.statusChip)).equals(5);
        check(discStart).equals(
          const SessionTabStatus(
            phase: .disconnectedCountdown,
            remainingSeconds: 30,
            exitCode: -1,
          ),
        );
        check(discStart.hashCode).equals(
          const SessionTabStatus(
            phase: .disconnectedCountdown,
            remainingSeconds: 30,
            exitCode: -1,
          ).hashCode,
        );
      },
    );

    test(
      'preserves drag order across directory updates, reclaims slots in place, and LRU-evicts oldest non-active 💀 tabs',
      () {
        final clock = _MutableClock();
        final strip = SessionTabStrip(maxRetainedEndedTabs: 2);
        const s1 = SessionId('s1');
        const s2 = SessionId('s2');
        const s3 = SessionId('s3');
        const s4 = SessionId('s4');

        strip.reconcileDirectory(
          const [
            SessionSummary(id: s1, title: 'one', cols: 80, rows: 24),
            SessionSummary(id: s2, title: 'two', cols: 80, rows: 24),
            SessionSummary(id: s3, title: 'three', cols: 80, rows: 24),
            SessionSummary(id: s4, title: 'four', cols: 80, rows: 24),
          ],
          now: clock.now,
          activeSessionId: s1,
        );

        // User drags s4 to index 1: [s1, s4, s2, s3].
        check(strip.moveTab(s4, 1)).isTrue();
        check([
          for (final s in strip.sessions) s.id,
        ]).deepEquals([s1, s4, s2, s3]);
        // Live tabs cannot be dismissed via [x].
        check(strip.dismiss(s1)).isFalse();

        // Clean exit on s4 cannot be overwritten by a subsequent socket disconnect.
        strip.markEnded(
          s4,
          reason: .exited,
          exitCode: 0,
          now: clock.now,
          activeSessionId: s1,
        );
        strip.markEnded(
          s4,
          reason: .disconnected,
          exitCode: -1,
          now: clock.now.add(const Duration(seconds: 1)),
          activeSessionId: s1,
        );
        check(
          strip.statusOf(s4, clock.now).phase,
        ).equals(TabVisualPhase.exitedCountdown);

        // Advance 31s so s4 becomes 💀, then mark s2 ended at t+31s and s3 ended at t+32s.
        clock.advance(const Duration(seconds: 31));
        strip.markEnded(
          s2,
          reason: .disconnected,
          exitCode: -1,
          now: clock.now,
          activeSessionId: s1,
        );
        clock.advance(const Duration(seconds: 1));
        final evicted = strip.markEnded(
          s3,
          reason: .disconnected,
          exitCode: -1,
          now: clock.now,
          activeSessionId: s1,
        );

        // s4 (the oldest 💀 tab) is evicted while counting-down s2 and s3 survive!
        check(evicted).deepEquals([s4]);
        check([for (final s in strip.sessions) s.id]).deepEquals([s1, s2, s3]);

        // s2 reconnects in SessionDirectoryFrame -> reclaims index 1 in place!
        strip.reconcileDirectory(
          const [
            SessionSummary(id: s1, title: 'one', cols: 80, rows: 24),
            SessionSummary(id: s2, title: 'two-revived', cols: 80, rows: 24),
          ],
          now: clock.now,
          activeSessionId: s1,
        );
        check(strip.isLive(s2)).isTrue();
        check(strip.summaryOf(s2)?.title).equals('two-revived');
        check([for (final s in strip.sessions) s.id]).deepEquals([s1, s2, s3]);
      },
    );
  });
}

void _defineDialogAndGestureTests() {
  group('RenameTabDialog validation and DockGestureTracker boundaries', () {
    test(
      'validates trimmed non-empty titles, 64-grapheme and 512-byte caps, and rejects C0/C1/bidi controls',
      () {
        check(RenameTabDialog.validateTitle('   ').title).isNull();
        check(
          RenameTabDialog.validateTitle('  build-prod  ').title,
        ).equals('build-prod');
        check(RenameTabDialog.validateTitle('bad\ntitle').title).isNull();
        check(RenameTabDialog.validateTitle('bad\x9btitle').title).isNull();
        check(RenameTabDialog.validateTitle('spoof\u202Etxt').title).isNull();
        check(RenameTabDialog.validateTitle('iso\u2066txt').title).isNull();

        final ok64 = 'a' * 64;
        final tooLong65 = 'a' * 65;
        check(RenameTabDialog.validateTitle(ok64).title).equals(ok64);
        check(RenameTabDialog.validateTitle(tooLong65).title).isNull();

        // Family ZWJ emoji is 1 grapheme (25 UTF-8 bytes): 21 graphemes = 525 bytes > 512!
        const familyEmoji = '👨‍👩‍👧‍👦';
        check(
          RenameTabDialog.validateTitle(familyEmoji * 20).title,
        ).isNotNull();
        check(RenameTabDialog.validateTitle(familyEmoji * 21).title).isNull();
      },
    );

    test(
      'heals split wide graphemes in sliceColumns and disambiguates double-click, drag drift, and [x] cancel',
      () {
        // '漢' occupies cols 0..2; skipping 1 col heals left half with space.
        final sliced = DockTabLayout.sliceColumns('漢A', 1, 2);
        check(sliced).equals(' A');

        final clock = _MutableClock();
        final tracker = DockGestureTracker(clock: clock.clock);
        const s1 = SessionId('s1');
        const s2 = SessionId('s2');
        final layout = DockTabLayout.computeTop(
          specs: const [
            DockTabItemSpec(
              id: s1,
              index: 0,
              title: 'one',
              isActive: true,
              status: SessionTabStatus(
                phase: .disconnectedCountdown,
                remainingSeconds: 29,
                exitCode: -1,
              ),
            ),
            DockTabItemSpec(
              id: s2,
              index: 1,
              title: 'two',
              isActive: false,
              status: SessionTabStatus.live,
            ),
          ],
          maxTabX: 60,
          scrollOffsetCols: 0,
        );

        // Press on [x] of s1, then release OUTSIDE [x] -> cancels dismiss!
        final closeSpan = layout.visibleTabs.first.dismissColSpan!;
        tracker.handleMouseEvent(
          event: MouseEvent(
            x: closeSpan.$1 + 1,
            y: 1,
            button: .left,
            type: .press,
          ),
          width: 80,
          height: 1,
          dock: .top,
          layout: layout,
          chromeHitRegions: const [],
        );
        final cancelledClose = tracker.handleMouseEvent(
          event: const MouseEvent(x: 2, y: 1, button: .left, type: .release),
          width: 80,
          height: 1,
          dock: .top,
          layout: layout,
          chromeHitRegions: const [],
        );
        check(cancelledClose).isA<DockGestureConsumed>();

        // Press + release inside [x] -> emits DockGestureDismiss(s1)!
        tracker.handleMouseEvent(
          event: MouseEvent(
            x: closeSpan.$1 + 1,
            y: 1,
            button: .left,
            type: .press,
          ),
          width: 80,
          height: 1,
          dock: .top,
          layout: layout,
          chromeHitRegions: const [],
        );
        final confirmedClose = tracker.handleMouseEvent(
          event: MouseEvent(
            x: closeSpan.$1 + 2,
            y: 1,
            button: .left,
            type: .release,
          ),
          width: 80,
          height: 1,
          dock: .top,
          layout: layout,
          chromeHitRegions: const [],
        );
        check(confirmedClose)
            .isA<DockGestureDismiss>()
            .has((r) => r.sessionId, 'sessionId')
            .equals(s1);

        // Dragging Tab 1 from (3, 1) to (6, 1) (past topDragThresholdCols = 2, before Tab 2 midpoint)
        // emits DockGestureReorder with targetIndex: null so DragDropManager tracks every cell!
        tracker.handleMouseEvent(
          event: const MouseEvent(x: 3, y: 1, button: .left, type: .press),
          width: 80,
          height: 1,
          dock: .top,
          layout: layout,
          chromeHitRegions: const [],
        );
        final intermediateDrag = tracker.handleMouseEvent(
          event: const MouseEvent(x: 6, y: 1, button: .left, type: .drag),
          width: 80,
          height: 1,
          dock: .top,
          layout: layout,
          chromeHitRegions: const [],
        );
        check(intermediateDrag)
            .isA<DockGestureReorder>()
            .has((r) => r.targetIndex, 'targetIndex')
            .isNull();
      },
    );
  });
}

void _defineRenameAndReorderIntegrationTests() {
  group('Three-way CastSceneController rename and reorder integration', () {
    test(
      r'renames live tabs via double-click and Ctrl+\ r, syncs to caster across reconnects, and blocks non-live tabs',
      () {
        final tester = TerminalTester(size: const Point(90, 24));
        tester.run(() async {
          final fakeClock = _MutableClock();
          final harness = FakeThreeWayWsHarness();
          final casterA = await harness.startCaster(
            id: 'sess-1',
            title: 'alpha',
            initialBackoff: const Duration(milliseconds: 15),
          );
          final casterB = await harness.startCaster(
            id: 'sess-2',
            title: 'beta',
          );
          final viewer1 = await harness.connectViewer(clock: fakeClock.clock);
          final viewer2 = await harness.connectViewer(clock: fakeClock.clock);
          final controller = CastSceneController(
            terminal: tester.terminal,
            viewModel: viewer1.viewModel,
            clock: fakeClock.clock,
          );
          await _settle(tester);

          // 1. Double-click Tab 2 (" 2:beta ") at col 12, row 1 -> opens RenameTabDialog for sess-2!
          tester.mouseDown(12, 1);
          tester.mouseUp(12, 1);
          fakeClock.advance(const Duration(milliseconds: 120));
          tester.mouseDown(12, 1);
          tester.mouseUp(12, 1);
          await _settle(tester);
          check(controller.isRenameDialogOpen).isTrue();

          // Clear 'beta' with Backspace, validate empty rejection, then submit 'logs-prod'.
          _clearTextField(tester, 'beta'.length);
          tester.sendKey(LogicalKey.enter);
          await _settle(tester, 2);
          check(controller.isRenameDialogOpen).isTrue();
          check(
            _screenText(tester.backend.buffer!),
          ).contains('Tab name cannot be empty.');

          tester.sendString('logs-prod');
          tester.sendKey(LogicalKey.enter);
          await _settle(tester);
          check(controller.isRenameDialogOpen).isFalse();
          check(
            controller.sceneManager.focusedLayer,
          ).identicalTo(controller.ptyLayer);
          check(casterB.service.currentTitle).equals('logs-prod');
          check(
            viewer1.viewModel.titleOf(const SessionId('sess-2')),
          ).equals('logs-prod');
          check(
            viewer2.viewModel.titleOf(const SessionId('sess-2')),
          ).equals('logs-prod');

          // 2. Select Tab 1 and rename via Ctrl+\ r -> 'api-srv', then drop & reconnect casterA!
          await viewer1.viewModel.selectSession(const SessionId('sess-1'));
          await _settle(tester, 2);
          tester.sendString('\x1cr');
          await _settle(tester, 2);
          check(controller.isRenameDialogOpen).isTrue();
          _clearTextField(tester, 'alpha'.length);
          tester.sendString('api-srv');
          tester.sendKey(LogicalKey.enter);
          await _settle(tester);
          check(casterA.service.currentTitle).equals('api-srv');

          casterA.dropConnection();
          for (var i = 0; i < 10; i++) {
            await tester.pump(const Duration(milliseconds: 20));
          }
          check(
            viewer1.viewModel.isSessionLive(const SessionId('sess-1')),
          ).isTrue();
          check(
            viewer1.viewModel.titleOf(const SessionId('sess-1')),
          ).equals('api-srv');

          // 3. Cleanly exit sess-2 (⏻) -> neither Ctrl+\ r nor double-click opens RenameTabDialog!
          await casterB.pty.finish(0);
          await _settle(tester);
          await viewer1.viewModel.selectSession(const SessionId('sess-2'));
          await _settle(tester, 2);
          check(
            viewer1.viewModel.canRenameSession(const SessionId('sess-2')),
          ).isFalse();
          tester.sendString('\x1cr');
          await _settle(tester, 2);
          check(controller.isRenameDialogOpen).isFalse();

          fakeClock.advance(const Duration(seconds: 31));
          _dockDoubleClickAt(tester, fakeClock, 16, 1);
          await _settle(tester, 2);
          check(controller.isRenameDialogOpen).isFalse();

          controller.dispose();
          await harness.dispose();
        });
      },
    );

    test(
      'reorders tabs via click-and-drag across vertical/horizontal drift, supports Escape rollback, and preserves order across reconnects',
      () {
        final tester = TerminalTester(size: const Point(90, 24));
        tester.run(() async {
          final harness = FakeThreeWayWsHarness();
          final c1 = await harness.startCaster(id: 's1', title: 'one');
          await harness.startCaster(id: 's2', title: 'two');
          await harness.startCaster(id: 's3', title: 'three');
          final viewer = await harness.connectViewer();
          final controller = CastSceneController(
            terminal: tester.terminal,
            viewModel: viewer.viewModel,
          );
          await _settle(tester);

          // 1. Top bar drag: press Tab 1 (" 1:one ") at (3, 1):
          //    - Dragging to (6, 1) (before Tab 2's midpoint) starts DragDropManager,
          //      renders '░' drop-slot cavity in Tab 1's slot, and floats ' 1:one ' at col 3!
          tester.mouseDown(3, 1);
          tester.mouseMove(6, 1);
          await _settle(tester, 1);
          check(DragDropManager.activeSession).isNotNull();
          check(_rowText(tester.backend.buffer!, 0)).startsWith('░░░ 1:one ');

          //    - Drifting down into PTY row 8 at (24, 8) moves s1 to index 2,
          //      renders '░' cavity in s1's target slot on row 0, and floats ' 3:one ' on row 7!
          tester.mouseMove(24, 8);
          await _settle(tester, 1);
          check(
            DragDropManager.activeSession!.currentMousePosition,
          ).equals(const Point<int>(24, 8));
          check(_rowText(tester.backend.buffer!, 0)).contains('░░░░░░░');
          check(_rowText(tester.backend.buffer!, 7)).contains(' 3:one ');

          tester.mouseUp(24, 8);
          await _settle(tester, 2);
          check(DragDropManager.activeSession).isNull();
          check(
            _rowText(tester.backend.buffer!, 7),
          ).not((it) => it.contains('3:one'));
          check([for (final s in viewer.viewModel.sessions) s.id]).deepEquals(
            const [SessionId('s2'), SessionId('s3'), SessionId('s1')],
          );
          check(
            controller.sceneManager.focusedLayer,
          ).identicalTo(controller.ptyLayer);

          // Typing immediately after drag release goes straight to active PTY (s1)!
          tester.sendString('z');
          await _settle(tester, 2);
          check(utf8.decode(c1.pty.writtenInputs.single)).equals('z');

          // 2. Start dragging s2 from (3, 1) to (24, 5), then press Escape -> rolls back to [s2, s3, s1] and clears DragDropManager!
          tester.mouseDown(3, 1);
          tester.mouseMove(24, 5);
          await _settle(tester, 1);
          check(DragDropManager.activeSession).isNotNull();
          check([for (final s in viewer.viewModel.sessions) s.id]).deepEquals(
            const [SessionId('s3'), SessionId('s1'), SessionId('s2')],
          );
          tester.sendKey(LogicalKey.escape);
          await _settle(tester, 2);
          check(DragDropManager.activeSession).isNull();
          check([for (final s in viewer.viewModel.sessions) s.id]).deepEquals(
            const [SessionId('s2'), SessionId('s3'), SessionId('s1')],
          );
          check(
            controller.sceneManager.focusedLayer,
          ).identicalTo(controller.ptyLayer);

          // 3. Switch to left sidebar:
          //    - Press row 3 (s2, 1-based y=3) at x=9 (localX=8) and drag straight down to (9, 4):
          //      grabOffsetCols=8 keeps the floating pill aligned at col 0; pressing Ctrl+\ d mid-drag
          //      aborts the drag and rolls back to [s2, s3, s1]!
          viewer.viewModel.setDockPosition(.left);
          await _settle(tester, 2);
          tester.mouseDown(9, 3);
          tester.mouseMove(9, 4);
          await _settle(tester, 1);
          check(DragDropManager.activeSession).isNotNull();
          check(
            (DragDropManager.activeSession!.data as DockTabDragData)
                .grabOffsetCols,
          ).equals(8);
          tester.sendString('\x1cd');
          await _settle(tester, 2);
          check(DragDropManager.activeSession).isNull();
          check([for (final s in viewer.viewModel.sessions) s.id]).deepEquals(
            const [SessionId('s2'), SessionId('s3'), SessionId('s1')],
          );

          //    - Switch back to left sidebar and drag row 3 (s2, y=3) down to y=5 while drifting right to x=45!
          viewer.viewModel.setDockPosition(.left);
          await _settle(tester, 2);
          tester.mouseDown(5, 3);
          tester.mouseMove(45, 5);
          tester.mouseUp(45, 5);
          await _settle(tester, 2);
          check([for (final s in viewer.viewModel.sessions) s.id]).deepEquals(
            const [SessionId('s3'), SessionId('s1'), SessionId('s2')],
          );

          // 4. Same-URI reconnectTo preserves custom order [s3, s1, s2], while new-URI clears!
          await viewer.viewModel.reconnectTo((
            serverUri: viewer.viewModel.serverUri,
            token: harness.token,
          ));
          await _settle(tester);
          check([for (final s in viewer.viewModel.sessions) s.id]).deepEquals(
            const [SessionId('s3'), SessionId('s1'), SessionId('s2')],
          );

          controller.dispose();
          await harness.dispose();
        });
      },
    );
  });
}

void _defineLifecycleAndOverflowIntegrationTests() {
  group('Three-way CastSceneController lifecycle and overflow integration', () {
    test(
      r'renders ⏳ and ⏻ 30s countdowns into 💀, dismisses via [x] and Ctrl+\ x, and preserves offline scrollback without network fetches',
      () {
        final tester = TerminalTester(size: const Point(80, 10));
        tester.run(() async {
          final fakeClock = _MutableClock();
          final clock = fakeClock.clock;
          final pipe = StreamChannelController<Uint8List>();
          final sentByClient = <CastMessage>[];
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
                        id: SessionId('s1'),
                        title: 'build',
                        cols: 20,
                        rows: 4,
                      ),
                      SessionSummary(
                        id: SessionId('s2'),
                        title: 'logs',
                        cols: 20,
                        rows: 4,
                      ),
                    ],
                  ),
                ),
              );
            }
          });

          final transport = WsClientTransport(
            token: 'tok',
            channelFactory: () async => pipe.local,
          );
          final repo = CastClientRepository(transport: transport);
          final vm = CastWorkspaceViewModel(
            repository: repo,
            clock: clock,
            initialViewportCols: 20,
            initialViewportRows: 4,
          );
          final controller = CastSceneController(
            terminal: tester.terminal,
            viewModel: vm,
            clock: clock,
          );

          await repo.connect();
          await _settle(tester, 2);

          // Hydrate s1 with 10 lines of scrollback + cached chunk lines 0..9!
          const s1 = SessionId('s1');
          const s2 = SessionId('s2');
          final liveBuf = Buffer.blank(20, 4)
            ..writeString(0, 0, 'LIVE-BOTTOM', const Style());
          pipe.foreign.sink.add(
            BufferFrameCodec.encode(
              BufferSnapshotFrame(
                snapshot: BufferSnapshot.fromBuffer(
                  sessionId: s1,
                  seq: 1,
                  buffer: liveBuf,
                  cursor: CursorState.origin,
                  modes: TerminalModes.defaults,
                  scrollback: const ScrollbackWindow(
                    clearSeq: 0,
                    oldestLine: 0,
                    totalLines: 10,
                  ),
                ),
              ),
            ),
          );
          await _settle(tester, 1);
          final cachedRows = [
            for (var i = 0; i < 10; i++)
              EncodedScrollbackRow(
                isWrapped: false,
                characters: [
                  for (final ch in 'HIST-$i'.padRight(20).split('')) ch,
                ],
                attributes: Uint32List(60),
              ),
          ];
          pipe.foreign.sink.add(
            BufferFrameCodec.encode(
              ScrollbackChunkFrame(
                sessionId: s1,
                requestId: 1,
                clearSeq: 0,
                startLine: 0,
                rows: cachedRows,
              ),
            ),
          );
          await _settle(tester, 1);

          // s1 disconnects unexpectedly (⏳) and unsubscribed s2 exits cleanly (⏻)!
          pipe.foreign.sink.add(
            BufferFrameCodec.encode(
              const SessionClosedFrame(
                sessionId: s1,
                exitCode: -1,
                reason: .disconnected,
              ),
            ),
          );
          pipe.foreign.sink.add(
            BufferFrameCodec.encode(
              const SessionClosedFrame(
                sessionId: s2,
                exitCode: 0,
                reason: .exited,
              ),
            ),
          );
          await tester.pump(const Duration(milliseconds: 50));

          final barAtStart = _rowText(tester.backend.buffer!, 0);
          check(barAtStart).contains('▸1:build ⏳30s [x]');
          check(barAtStart).contains(' 2:logs ⏻ 30s [x]');

          // Advance 1s -> shared 1 Hz timer ticks both chips to 29s; advance to 30s -> both become 💀!
          fakeClock.advance(const Duration(seconds: 1));
          await tester.pump(const Duration(seconds: 1));
          check(_rowText(tester.backend.buffer!, 0)).contains('⏳29s');
          check(_rowText(tester.backend.buffer!, 0)).contains('⏻ 29s');

          fakeClock.advance(const Duration(seconds: 29));
          await tester.pump(const Duration(seconds: 29));
          final barAtDead = _rowText(tester.backend.buffer!, 0);
          check(barAtDead).contains('▸1:build 💀    [x]');
          check(barAtDead).contains(' 2:logs 💀    [x]');

          // Scroll retained scrollback on dead s1 without emitting any network RequestScrollbackFrame!
          sentByClient.clear();
          check(vm.canScrollActiveSession()).isTrue();
          check(vm.scrollActiveBy(6)).isTrue();
          check(
            vm.composeActiveBufferWithCursor().getCharacter(0, 0),
          ).equals('H');
          check(sentByClient).isEmpty();

          // Dismiss s2 by clicking its [x] button, then dismiss active s1 via Ctrl+\ x!
          final s2Tab = controller.dockRenderer.tabLayout.visibleTabs[1];
          final s2CloseX = s2Tab.dismissColSpan!.$1 + 1;
          tester.mouseDown(s2CloseX, 1);
          tester.mouseUp(s2CloseX, 1);
          await _settle(tester, 1);
          check([for (final s in vm.sessions) s.id]).deepEquals([s1]);

          tester.sendString('\x1cx');
          await _settle(tester, 1);
          check(vm.sessions).isEmpty();
          check(vm.activeSessionId).isNull();

          controller.dispose();
          await vm.dispose();
          await repo.dispose();
        });
      },
    );

    test(
      'scrolls overflowing tabs in DockPosition.top (◀/▶ + wheel) and DockPosition.left (▲/▼ + wheel)',
      () {
        final tester = TerminalTester(size: const Point(64, 10));
        tester.run(() async {
          final harness = FakeThreeWayWsHarness();
          for (var i = 1; i <= 10; i++) {
            await harness.startCaster(id: 's$i', title: 'service-$i');
          }
          final viewer = await harness.connectViewer();
          final controller = CastSceneController(
            terminal: tester.terminal,
            viewModel: viewer.viewModel,
          );
          await _settle(tester);

          // 1. Top bar overflows: renders ◀ ▶ and scrolls right on wheelDown!
          check(controller.dockRenderer.tabLayout.hasOverflow).isTrue();
          check(_rowText(tester.backend.buffer!, 0)).contains('◀ ▶');
          check(controller.dockRenderer.topScrollOffsetCols).equals(0);

          controller.sceneManager.handleMouseEvent(
            const MouseEvent(x: 10, y: 1, button: .wheelDown, type: .press),
          );
          await _settle(tester, 1);
          final scrolledCols = controller.dockRenderer.topScrollOffsetCols;
          check(scrolledCols).isGreaterThan(0);

          // Selecting s10 auto-scrolls s10 into view!
          await viewer.viewModel.selectSession(const SessionId('s10'));
          await _settle(tester, 2);
          check(_rowText(tester.backend.buffer!, 0)).contains('10:service-10');

          // 2. Left sidebar overflows on 10-row terminal (8 tab rows < 10 tabs): renders ▲ and ▼ indicators and scrolls on wheel!
          viewer.viewModel.setDockPosition(.left);
          await _settle(tester, 2);
          check(controller.dockRenderer.tabLayout.hasOverflow).isTrue();
          final sidebar = _screenText(tester.backend.buffer!);
          check(sidebar).contains('▲');
          check(sidebar).contains('▼');

          // Active tab is s10 (bottom) -> wheelUp over sidebar scrolls up toward s1!
          final beforeRow = controller.dockRenderer.leftScrollOffsetRows;
          controller.sceneManager.handleMouseEvent(
            const MouseEvent(x: 4, y: 5, button: .wheelUp, type: .press),
          );
          await _settle(tester, 1);
          check(
            controller.dockRenderer.leftScrollOffsetRows,
          ).isLessThan(beforeRow);

          controller.dispose();
          await harness.dispose();
        });
      },
    );
  });
}

void _attachPipeDirectoryResponder(
  StreamChannelController<Uint8List> pipe,
  List<SessionSummary> directory,
) {
  pipe.foreign.stream.listen((raw) {
    final msg = BufferFrameCodec.decode(raw);
    if (msg is AuthFrame) {
      pipe.foreign.sink
        ..add(BufferFrameCodec.encode(const AuthAcceptedFrame(role: .client)))
        ..add(
          BufferFrameCodec.encode(SessionDirectoryFrame(sessions: directory)),
        );
    }
  });
}

void _defineAdversarialRegressionTests() {
  group('Adversarial edge-case regressions', () {
    test(
      'never evicts ⏳ counting-down tabs during 30s grace even when > maxRetainedEndedTabs disconnect simultaneously',
      () {
        final fakeClock = _MutableClock();
        final strip = SessionTabStrip(maxRetainedEndedTabs: 8);
        strip.reconcileDirectory(
          [
            for (var i = 1; i <= 10; i++)
              SessionSummary(
                id: SessionId('t$i'),
                title: 'tab-$i',
                cols: 80,
                rows: 24,
              ),
          ],
          now: fakeClock.now,
          activeSessionId: const SessionId('t1'),
        );
        for (var i = 2; i <= 10; i++) {
          final evictedDuringGrace = strip.markEnded(
            SessionId('t$i'),
            reason: .disconnected,
            exitCode: -1,
            now: fakeClock.now,
            activeSessionId: const SessionId('t1'),
          );
          check(evictedDuringGrace).isEmpty();
        }
        check(strip.length).equals(10);
        fakeClock.advance(const Duration(seconds: 31));
        final prunedDead = strip.pruneOverflowAt(
          fakeClock.now,
          activeSessionId: const SessionId('t1'),
        );
        check(prunedDead).deepEquals([const SessionId('t2')]);
        check(strip.length).equals(9);
      },
    );

    test(
      'preserves 10-tab custom order and retained buffers across viewer WebSocket disconnect and reconnect',
      () {
        final tester = TerminalTester(size: const Point(90, 12));
        tester.run(() async {
          final fakeClock = _MutableClock();
          final directory = [
            for (var i = 1; i <= 10; i++)
              SessionSummary(
                id: SessionId('s$i'),
                title: 'svc-$i',
                cols: 20,
                rows: 4,
              ),
          ];
          StreamChannelController<Uint8List>? activePipe;
          final transport = WsClientTransport(
            token: 'tok',
            channelFactory: () async {
              final pipe = StreamChannelController<Uint8List>();
              activePipe = pipe;
              _attachPipeDirectoryResponder(pipe, directory);
              return pipe.local;
            },
          );
          final repo = CastClientRepository(
            transport: transport,
            baseReconnectDelay: const Duration(milliseconds: 15),
          );
          final vm = CastWorkspaceViewModel(
            repository: repo,
            clock: fakeClock.clock,
            initialViewportCols: 20,
            initialViewportRows: 4,
          );
          await repo.connect();
          await _settle(tester, 2);

          final s1Buf = Buffer.blank(20, 4)
            ..writeString(0, 0, 'RETAINED-S1', const Style());
          activePipe!.foreign.sink.add(
            BufferFrameCodec.encode(
              BufferSnapshotFrame(
                snapshot: BufferSnapshot.fromBuffer(
                  sessionId: const SessionId('s1'),
                  seq: 1,
                  buffer: s1Buf,
                  cursor: CursorState.origin,
                  modes: TerminalModes.defaults,
                ),
              ),
            ),
          );
          await _settle(tester, 1);
          check(vm.moveSession(const SessionId('s10'), 1)).isTrue();
          final expectedOrder = [
            const SessionId('s1'),
            const SessionId('s10'),
            for (var i = 2; i <= 9; i++) SessionId('s$i'),
          ];
          check([for (final s in vm.sessions) s.id]).deepEquals(expectedOrder);

          // Drop viewer WebSocket -> all 10 become ⏳ -> reconnect -> order & s1 buffer intact!
          unawaited(activePipe!.foreign.sink.close());
          await tester.pump(const Duration(milliseconds: 5));
          check(vm.isSessionLive(const SessionId('s1'))).isFalse();
          check(
            vm.composeActiveBufferWithCursor().getCharacter(0, 0),
          ).equals('R');

          for (var i = 0; i < 6; i++) {
            await tester.pump(const Duration(milliseconds: 20));
          }
          check(vm.isSessionLive(const SessionId('s1'))).isTrue();
          check([for (final s in vm.sessions) s.id]).deepEquals(expectedOrder);
          check(
            vm.composeActiveBufferWithCursor().getCharacter(0, 0),
          ).equals('R');

          await vm.dispose();
          await repo.dispose();
        });
      },
    );
  });
}

void _defineDragAndNoticeRegressionTests() {
  group('Adversarial drag, scrollback, and notice regressions', () {
    test(
      'supports overflow right and left edge-scroll drag without index-0 teleportation and rolls back on synthetic (-1,-1) release',
      () {
        final tester = TerminalTester(size: const Point(56, 10));
        tester.run(() async {
          final harness = FakeThreeWayWsHarness();
          for (var i = 1; i <= 8; i++) {
            await harness.startCaster(id: 's$i', title: 'svc-$i');
          }
          final viewer = await harness.connectViewer();
          final controller = CastSceneController(
            terminal: tester.terminal,
            viewModel: viewer.viewModel,
          );
          await _settle(tester);

          // 1. Drag s1 right to the overflow edge twice -> scrolls right and NEVER teleports to index 0!
          final edgeX = controller.dockRenderer.tabLayout.viewportEnd;
          tester.mouseDown(3, 1);
          tester.mouseMove(edgeX, 1);
          tester.mouseMove(edgeX + 1, 1);
          tester.mouseUp(edgeX + 1, 1);
          await _settle(tester, 2);
          check(controller.dockRenderer.topScrollOffsetCols).isGreaterThan(0);
          final movedIdx = [
            for (final s in viewer.viewModel.sessions) s.id,
          ].indexOf(const SessionId('s1'));
          check(movedIdx).isGreaterThan(2);

          // 2. Drag the rightmost visible tab left to x=1 (localX=0) -> scrolls left (edgeDir == -1)!
          final scrollBeforeLeft = controller.dockRenderer.topScrollOffsetCols;
          final rightTab = controller.dockRenderer.tabLayout.visibleTabs.last;
          final grabX = rightTab.x + 2;
          tester.mouseDown(grabX, 1);
          tester.mouseMove(1, 1);
          tester.mouseUp(1, 1);
          await _settle(tester, 2);
          check(
            controller.dockRenderer.topScrollOffsetCols,
          ).isLessThan(scrollBeforeLeft);

          // 3. Synthetic cancel release (-1, -1) during active drag rolls back to initialIndex!
          final orderBeforeCancel = [
            for (final s in viewer.viewModel.sessions) s.id,
          ];
          final fullVis = controller.dockRenderer.tabLayout.visibleTabs
              .firstWhere((t) => t.visibleCols >= 6);
          tester.mouseDown(fullVis.x + 2, 1);
          tester.mouseMove(fullVis.x + 22, 1);
          await _settle(tester, 1);
          check(DragDropManager.activeSession).isNotNull();
          check([
            for (final s in viewer.viewModel.sessions) s.id,
          ]).not((it) => it.deepEquals(orderBeforeCancel));
          controller.dockRenderer.handleMouseEvent(
            const MouseEvent(x: -1, y: -1, button: .left, type: .release),
          );
          await _settle(tester, 1);
          check(DragDropManager.activeSession).isNull();
          check([
            for (final s in viewer.viewModel.sessions) s.id,
          ]).deepEquals(orderBeforeCancel);

          controller.dispose();
          await harness.dispose();
        });
      },
    );

    test(
      'stops offlineScrollableLines at page gaps, shows rename error notices, and preserves background uploads on other session close',
      () {
        final tester = TerminalTester(size: const Point(80, 10));
        tester.run(() async {
          // 1. Non-contiguous scrollback pages: lines 0..9 cached and 256..299 cached (10..255 missing) -> 44!
          final cache = ScrollbackPageCache()
            ..updateWindow(
              const ScrollbackWindow(
                clearSeq: 0,
                oldestLine: 0,
                totalLines: 300,
              ),
            )
            ..ingestChunk(
              ScrollbackChunkFrame(
                sessionId: const SessionId('s1'),
                requestId: 1,
                clearSeq: 0,
                startLine: 0,
                rows: [
                  for (var i = 0; i < 10; i++)
                    EncodedScrollbackRow(
                      isWrapped: false,
                      characters: const ['a'],
                      attributes: Uint32List(3),
                    ),
                ],
              ),
            )
            ..ingestChunk(
              ScrollbackChunkFrame(
                sessionId: const SessionId('s1'),
                requestId: 2,
                clearSeq: 0,
                startLine: 256,
                rows: [
                  for (var i = 256; i < 300; i++)
                    EncodedScrollbackRow(
                      isWrapped: false,
                      characters: const ['z'],
                      attributes: Uint32List(3),
                    ),
                ],
              ),
            );
          check(cache.offlineScrollableLines).equals(44);

          // 2. rename_rejected ErrorFrame notice + ended-session rename notice + background upload survival!
          final pipe = StreamChannelController<Uint8List>();
          pipe.foreign.stream.listen((raw) {
            final msg = BufferFrameCodec.decode(raw);
            if (msg is AuthFrame) {
              pipe.foreign.sink
                ..add(
                  BufferFrameCodec.encode(
                    const AuthAcceptedFrame(role: .client),
                  ),
                )
                ..add(
                  BufferFrameCodec.encode(
                    const SessionDirectoryFrame(
                      sessions: [
                        SessionSummary(
                          id: SessionId('s1'),
                          title: 'alpha',
                          cols: 20,
                          rows: 4,
                        ),
                        SessionSummary(
                          id: SessionId('s2'),
                          title: 'beta',
                          cols: 20,
                          rows: 4,
                        ),
                      ],
                    ),
                  ),
                );
            }
          });
          final repo = CastClientRepository(
            transport: WsClientTransport(
              token: 'tok',
              channelFactory: () async => pipe.local,
            ),
          );
          final vm = CastWorkspaceViewModel(
            repository: repo,
            initialViewportCols: 20,
            initialViewportRows: 4,
          );
          await repo.connect();
          await _settle(tester, 2);

          // Hydrate s1 and start an upload on s1 (awaiting FileUploadAckFrame).
          pipe.foreign.sink.add(
            BufferFrameCodec.encode(
              BufferSnapshotFrame(
                snapshot: BufferSnapshot.fromBuffer(
                  sessionId: const SessionId('s1'),
                  seq: 1,
                  buffer: Buffer.blank(20, 4),
                  cursor: CursorState.origin,
                  modes: TerminalModes.defaults,
                ),
              ),
            ),
          );
          await _settle(tester, 1);
          unawaited(
            vm.uploadDroppedFiles([
              MemoryDroppedFileSource(name: 'payload.bin', bytes: Uint8List(4)),
            ]),
          );
          await _settle(tester, 1);
          check(vm.isUploadingFiles).isTrue();

          // Switch active view to s2 and close s2 -> s1's upload stays alive!
          await vm.selectSession(const SessionId('s2'));
          pipe.foreign.sink.add(
            BufferFrameCodec.encode(
              const SessionClosedFrame(
                sessionId: SessionId('s2'),
                exitCode: 0,
                reason: .exited,
              ),
            ),
          );
          await _settle(tester, 1);
          check(vm.isUploadingFiles).isTrue();

          // Renaming ended s2 shows transient notice; server rename_rejected shows notice!
          check(vm.renameSession(const SessionId('s2'), 'nope')).isFalse();
          check(
            vm.clipboardNotice,
          ).equals(' ! Cannot rename an ended session ');

          pipe.foreign.sink.add(
            BufferFrameCodec.encode(
              const ErrorFrame(
                code: 'rename_rejected',
                message: 'Session rename rate limit exceeded',
              ),
            ),
          );
          await _settle(tester, 1);
          check(vm.clipboardNotice!).contains('Rename rejected:');

          await vm.dispose();
          await repo.dispose();
        });
      },
    );
  });
}

void _dockDoubleClickAt(
  TerminalTester tester,
  _MutableClock clock,
  int x,
  int y,
) {
  tester.mouseDown(x, y);
  tester.mouseUp(x, y);
  clock.advance(const Duration(milliseconds: 100));
  tester.mouseDown(x, y);
  tester.mouseUp(x, y);
}
