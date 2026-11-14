@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:checks/checks.dart';
import 'package:clock/clock.dart';
import 'package:path/path.dart' as p;
import 'package:stream_channel/stream_channel.dart';
import 'package:termui/termui.dart';
import 'package:termui_cast_client_core/src/ui/hsv_color_wheel_picker.dart';
import 'package:termui_cast_client_core/termui_cast_client_core.dart';
import 'package:termui_cast_protocol/termui_cast_protocol.dart';
import 'package:termui_recorder/termui_recorder.dart';
import 'package:termui_test/termui_test.dart';
import 'package:test/test.dart';

import 'support/fake_three_way_ws_harness.dart';

String _goldenPath(String filename) {
  final libUri = Isolate.resolvePackageUriSync(
    Uri.parse('package:termui_cast_client_core/termui_cast_client_core.dart'),
  );
  if (libUri == null) {
    throw StateError('Unable to resolve package:termui_cast_client_core URI.');
  }
  final pkgRoot = p.dirname(p.dirname(p.fromUri(libUri)));
  return p.join(pkgRoot, 'test', 'goldens', filename);
}

String _extractScreenText(Buffer buf) {
  final sb = StringBuffer();
  for (var y = 0; y < buf.height; y++) {
    for (var x = 0; x < buf.width; x++) {
      sb.write(buf.getCharacter(x, y));
    }
    sb.writeln();
  }
  return '$sb';
}

Point<int> _findTextInBuffer(Buffer buf, String needle) {
  for (var y = 0; y < buf.height; y++) {
    final rowBuf = StringBuffer();
    for (var x = 0; x < buf.width; x++) {
      rowBuf.write(buf.getCharacter(x, y));
    }
    final col = '$rowBuf'.indexOf(needle);
    if (col >= 0) {
      return Point<int>(col, y);
    }
  }
  fail(
    'Expected buffer to contain "$needle", got:\n${_extractScreenText(buf)}',
  );
}

void _clickBufferText(
  TerminalTester tester,
  String needle, {
  int colOffset = 0,
}) {
  final pos = _findTextInBuffer(tester.backend.buffer!, needle);
  final oneBasedX = pos.x + colOffset + 1;
  final oneBasedY = pos.y + 1;
  tester.mouseDown(oneBasedX, oneBasedY);
  tester.mouseUp(oneBasedX, oneBasedY);
}

double _cellContrastAtText(Buffer buf, String needle, {int colOffset = 0}) {
  final pos = _findTextInBuffer(buf, needle);
  final x = pos.x + colOffset;
  final fg = Color.argb(buf.getForeground(x, pos.y));
  final bg = Color.argb(buf.getBackground(x, pos.y));
  return TerminalContrast.contrastRatio(fg, bg);
}

Future<void> _settleTester(TerminalTester tester) async {
  for (var i = 0; i < 4; i++) {
    await tester.pump(const Duration(milliseconds: 20));
  }
}

void _assertZeroOverflowStripes(Buffer buf) {
  final screen = _extractScreenText(buf);
  for (final stripe in const ['▜', '▙']) {
    if (screen.contains(stripe)) {
      fail('Expected zero "$stripe" overflow stripes, got:\n$screen');
    }
  }
}

bool _hasNonEmptyBrailleInRows(Buffer buf, int yStart, int yEndInclusive) {
  for (var y = yStart; y <= yEndInclusive && y < buf.height; y++) {
    for (var x = 0; x < buf.width; x++) {
      final ch = buf.getCharacter(x, y);
      if (ch.isNotEmpty) {
        final code = ch.runes.first;
        if (code >= 0x2801 && code <= 0x28FF) {
          return true;
        }
      }
    }
  }
  return false;
}

void main() {
  group('CastNetworkStats and ViewModel telemetry', () {
    test(
      'tracks RX/TX wire bytes across reconnects, rolling window peaks, and backward Clock jumps',
      () async {
        var now = DateTime.utc(2026, 11, 1, 12);
        final fakeClock = Clock(() => now);
        var activePipe = StreamChannelController<Uint8List>();
        final transport = WsClientTransport(
          token: 'stats-tok',
          channelFactory: () async => activePipe.local,
        );
        final repo = CastClientRepository(transport: transport);
        final vm = CastWorkspaceViewModel(
          repository: repo,
          clock: fakeClock,
          initialViewportCols: 20,
          initialViewportRows: 5,
          resizeDebounce: Duration.zero,
        );
        addTearDown(() async {
          await vm.dispose();
          await repo.dispose();
        });

        await repo.connect();
        await pumpEventQueue();

        // Initial AuthFrame sent by client -> totalTxBytes > 0.
        final txAfterFirstConnect = vm.networkStats.totalTxBytes;
        check(txAfterFirstConnect).isGreaterThan(0);
        check(vm.networkStats.totalRxBytes).equals(0);
        check(vm.networkStats.snapshotCount).equals(0);
        check(vm.networkStats.deltaCount).equals(0);

        const sessId = SessionId('sess-telemetry');
        final dirRaw = BufferFrameCodec.encode(
          const SessionDirectoryFrame(
            sessions: [
              SessionSummary(id: sessId, title: 'htop', cols: 20, rows: 5),
            ],
          ),
        );
        activePipe.foreign.sink.add(dirRaw);
        await pumpEventQueue();

        final snapBuf = Buffer.blank(20, 5)
          ..writeString(0, 0, 'HELLO STATS', Style.empty);
        final snapRaw = BufferFrameCodec.encode(
          BufferSnapshotFrame(
            snapshot: BufferSnapshot.fromBuffer(
              sessionId: sessId,
              seq: 1,
              buffer: snapBuf,
              cursor: CursorState.origin,
              modes: TerminalModes.defaults,
            ),
          ),
        );
        activePipe.foreign.sink.add(snapRaw);
        await pumpEventQueue();

        final statsAfterSnap = vm.networkStats;
        // Repeated getter calls within the same bucket return the cached instance.
        check(vm.networkStats).identicalTo(statsAfterSnap);
        check(
          statsAfterSnap.totalRxBytes,
        ).equals(dirRaw.length + snapRaw.length);
        check(statsAfterSnap.totalRxFrames).equals(2);
        check(statsAfterSnap.snapshotCount).equals(1);
        check(statsAfterSnap.deltaCount).equals(0);
        check(vm.activeSessionSeq).equals(1);
        check(vm.activeSessionSyncState).equals(.synchronized);
        check(statsAfterSnap.currentRxBytesPerSec).isGreaterThan(0);
        check(statsAfterSnap.currentFramesPerSec).equals(8.0);
        check(statsAfterSnap.rxBytesPerSecHistory.last).isGreaterThan(0);
        check(statsAfterSnap.framesPerSecHistory.last).equals(8.0);

        // Advance clock by 250ms (1 bucket) and send a BufferDeltaFrame.
        now = now.add(const Duration(milliseconds: 250));
        final deltaRaw = BufferFrameCodec.encode(
          BufferDeltaFrame(
            delta: BufferDelta(
              sessionId: sessId,
              seq: 2,
              baseSeq: 1,
              cols: 20,
              rows: 5,
              cursor: const CursorState(x: 1, y: 0),
              modes: TerminalModes.defaults,
              runs: [
                CellRun(
                  startIndex: 0,
                  characters: const ['!'],
                  attributes: Uint32List.fromList(const [0, 0, 0]),
                ),
              ],
            ),
          ),
        );
        activePipe.foreign.sink.add(deltaRaw);
        await pumpEventQueue();

        final statsAfterDelta = vm.networkStats;
        check(statsAfterDelta.snapshotCount).equals(1);
        check(statsAfterDelta.deltaCount).equals(1);
        check(vm.activeSessionSeq).equals(2);
        check(statsAfterDelta.framesPerSecHistory.last).equals(4.0);
        final prevIndex = statsAfterDelta.framesPerSecHistory.length - 2;
        check(statsAfterDelta.framesPerSecHistory[prevIndex]).equals(8.0);

        // Advance clock by 60 seconds (exceeding full 128-bucket window) -> rolling peak decays to 0.0!
        now = now.add(const Duration(seconds: 60));
        final idleStats = vm.networkStats;
        check(idleStats.currentRxBytesPerSec).equals(0.0);
        check(idleStats.currentFramesPerSec).equals(0.0);
        check(idleStats.peakRxBytesPerSec).equals(0.0);
        check(idleStats.peakFramesPerSec).equals(0.0);

        // Backward wall-clock jump (NTP adjustment) resets bucket baseline without freezing rotation.
        now = now.subtract(const Duration(minutes: 5));
        check(vm.networkStats.currentFramesPerSec).equals(0.0);
        now = now.add(const Duration(milliseconds: 250));

        // Reconnect to a new endpoint and verify cumulative RX/TX bytes are preserved.
        final rxBeforeReconnect = vm.networkStats.totalRxBytes;
        final txBeforeReconnect = vm.networkStats.totalTxBytes;
        activePipe = StreamChannelController<Uint8List>();
        await vm.reconnectTo((
          serverUri: Uri.parse('ws://127.0.0.1:8420/v1/client'),
          token: 'next-tok',
        ));
        await pumpEventQueue();
        activePipe.foreign.sink.add(
          BufferFrameCodec.encode(const AuthAcceptedFrame(role: .client)),
        );
        await pumpEventQueue();

        check(vm.networkStats.totalRxBytes).isGreaterThan(rxBeforeReconnect);
        check(vm.networkStats.totalTxBytes).isGreaterThan(txBeforeReconnect);
      },
    );
  });

  group('ChordsHelpDialog and StatsForNerdsDialog', () {
    test(
      r'opens ChordsHelpDialog via Ctrl+\ ?, Ctrl+\ h, and [?] dock buttons (top & left), clears armed leader, and matches golden',
      () {
        final tester = TerminalTester(size: const Point(80, 24));
        tester.run(() async {
          final harness = FakeThreeWayWsHarness();
          final caster = await harness.startCaster(id: 'sess-1', title: 'zsh');
          final viewer = await harness.connectViewer();
          final controller = CastSceneController(
            terminal: tester.terminal,
            viewModel: viewer.viewModel,
          );

          Future<void> settle() async {
            for (var i = 0; i < 4; i++) {
              await tester.pump(const Duration(milliseconds: 20));
            }
          }

          await settle();
          check(controller.isChordsHelpOpen).isFalse();

          // 1. Open via Ctrl+\ ? and verify preserved two-column alignment + ANSI golden.
          tester.sendString('\x1c?');
          await settle();
          check(controller.isChordsHelpOpen).isTrue();
          final helpText = _extractScreenText(tester.backend.buffer!);
          check(
            helpText,
          ).contains(r'  Ctrl+\ c                  Open connection dialog');
          check(
            helpText,
          ).contains(r'  Ctrl+\ n / ] / Tab        Switch to next session');
          check(
            helpText,
          ).contains(r'  Ctrl+\ r / Double-Click   Rename active live tab');
          check(
            helpText,
          ).contains(r'  Ctrl+\ x / [x]            Dismiss ended session tab');
          check(helpText).contains(
            r'  Ctrl+\ d / Space          Cycle dock (top/left/hidden)',
          );
          check(
            helpText,
          ).contains(r'  Ctrl+\ y / Cmd+C          Copy active selection');
          check(
            helpText,
          ).contains(r'  Ctrl+\ v / Cmd+V          Paste from clipboard');
          check(
            helpText,
          ).contains(r'  Ctrl+\ o                  Toggle copy-on-select');
          check(helpText).contains(
            '  Drag / Shift+Drag         Select text (Alt = box mode)',
          );
          check(
            helpText,
          ).contains('  Shift+Wheel / PgUp/Dn     Scroll/page primary history');
          check(
            helpText,
          ).contains(r'  Arrows / Esc / Ctrl+\ g   Pan/scroll or exit history');
          check(
            helpText,
          ).contains(r'  Ctrl+\ s / i              Open Stats for Nerds');
          check(
            helpText,
          ).contains(r'  Ctrl+\ ,                  Open Settings dialog');
          check(
            helpText,
          ).contains(r'  Ctrl+\ ? / h              Open Chords Help dialog');
          expect(
            tester.backend.buffer,
            matchesAnsiGolden(_goldenPath('chords_help_dialog.ansi')),
          );

          // Close via 'q'.
          tester.sendString('q');
          await settle();
          check(controller.isChordsHelpOpen).isFalse();
          check(
            controller.sceneManager.focusedLayer,
          ).identicalTo(controller.ptyLayer);

          // 2. Open via Ctrl+\ h and close via Enter.
          tester.sendString('\x1ch');
          await settle();
          check(controller.isChordsHelpOpen).isTrue();
          tester.sendKey(LogicalKey.enter);
          await settle();
          check(controller.isChordsHelpOpen).isFalse();

          // 3. Arm leader with Ctrl+\, then click [?] in top dock bar -> must disarm _leaderArmed!
          tester.sendString('\x1c');
          tester.mouseDown(72, 1);
          tester.mouseUp(72, 1);
          await settle();
          check(controller.isChordsHelpOpen).isTrue();
          tester.sendKey(LogicalKey.escape);
          await settle();
          check(controller.isChordsHelpOpen).isFalse();

          // Typing 'd' after closing modal must go to PTY, NOT cycle dockPosition!
          caster.pty.writtenInputs.clear();
          tester.sendString('d');
          await settle();
          check(viewer.viewModel.dockPosition).equals(DockPosition.top);
          check(utf8.decode(caster.pty.writtenInputs.single)).equals('d');

          // 4. Switch dock to left sidebar and click [?] button (cols 16..18 -> 1-based col 17, row 1).
          viewer.viewModel.setDockPosition(.left);
          await settle();
          tester.mouseDown(17, 1);
          tester.mouseUp(17, 1);
          await settle();
          check(controller.isChordsHelpOpen).isTrue();
          tester.sendString('?');
          await settle();
          check(controller.isChordsHelpOpen).isFalse();

          controller.dispose();
          await harness.dispose();
        });
      },
    );

    test(
      r'opens StatsForNerdsDialog via Ctrl+\ s and [Stats] dock buttons (top & left), renders both Braille Sparklines, and updates on PTY output',
      () {
        final tester = TerminalTester(size: const Point(80, 24));
        tester.run(() async {
          var now = DateTime.utc(2026, 11, 1, 12);
          final fakeClock = Clock(() => now);
          final harness = FakeThreeWayWsHarness();
          final caster = await harness.startCaster(id: 'sess-1', title: 'htop');
          final transport = WsClientTransport(
            token: harness.token,
            channelFactory: harness.openClientChannel,
          );
          final repo = CastClientRepository(transport: transport);
          final viewModel = CastWorkspaceViewModel(
            repository: repo,
            clock: fakeClock,
            resizeDebounce: Duration.zero,
          );
          await repo.connect();
          final controller = CastSceneController(
            terminal: tester.terminal,
            viewModel: viewModel,
          );

          Future<void> settle() async {
            for (var i = 0; i < 4; i++) {
              await tester.pump(const Duration(milliseconds: 20));
            }
          }

          await settle();
          check(controller.isStatsDialogOpen).isFalse();

          // 1. Open StatsForNerdsDialog via Ctrl+\ s and verify both Sparklines + ANSI golden.
          tester.sendString('\x1cs');
          await settle();
          check(controller.isStatsDialogOpen).isTrue();

          final initialBuf = tester.backend.buffer!;
          final initialText = _extractScreenText(initialBuf);
          check(initialText).contains('Stats for Nerds');
          check(initialText).contains('sess-1');
          check(initialText).contains('synchronized');
          check(initialText).contains('RX Rate:');
          check(initialText).contains('Frames/s:');
          // Verify non-empty braille cells in RX Rate rows (11..12) AND Frames/s rows (14..15) independently.
          check(_hasNonEmptyBrailleInRows(initialBuf, 11, 12)).isTrue();
          check(_hasNonEmptyBrailleInRows(initialBuf, 14, 15)).isTrue();
          expect(
            initialBuf,
            matchesAnsiGolden(_goldenPath('stats_for_nerds_dialog.ansi')),
          );

          // 2. Advance clock 35s past initial keyframe and emit small delta -> RX Rate sparkline scales to rolling peak!
          now = now.add(const Duration(seconds: 35));
          final seqBefore = viewModel.activeSessionSeq;
          caster.pty.emitRawAnsi('LIVE NETWORK BURST');
          await settle();
          check(viewModel.activeSessionSeq).isGreaterThan(seqBefore);
          final updatedBuf = tester.backend.buffer!;
          final updatedText = _extractScreenText(updatedBuf);
          check(updatedText).contains('Seq: ${viewModel.activeSessionSeq}');
          check(updatedText).contains('Delta: 1');
          check(_hasNonEmptyBrailleInRows(updatedBuf, 11, 12)).isTrue();
          check(_hasNonEmptyBrailleInRows(updatedBuf, 14, 15)).isTrue();

          // Close via 's'.
          tester.sendString('s');
          await settle();
          check(controller.isStatsDialogOpen).isFalse();
          check(
            controller.sceneManager.focusedLayer,
          ).identicalTo(controller.ptyLayer);

          // 3. Click [Stats] button in top dock bar (cols 62..68 -> 1-based col 65, row 1).
          tester.mouseDown(65, 1);
          tester.mouseUp(65, 1);
          await settle();
          check(controller.isStatsDialogOpen).isTrue();
          tester.sendKey(LogicalKey.enter);
          await settle();
          check(controller.isStatsDialogOpen).isFalse();

          // 4. Switch dock to left sidebar and click [Stats] button (cols 8..14 -> 1-based col 11, row 1).
          viewModel.setDockPosition(.left);
          await settle();
          tester.mouseDown(11, 1);
          tester.mouseUp(11, 1);
          await settle();
          check(controller.isStatsDialogOpen).isTrue();
          tester.sendString('i');
          await settle();
          check(controller.isStatsDialogOpen).isFalse();

          controller.dispose();
          await viewModel.dispose();
          await repo.dispose();
          await harness.dispose();
        });
      },
    );

    test(
      'renders ChordsHelpDialog and StatsForNerdsDialog on compact 60x14 viewport with long session ID without Column overflow',
      () {
        final tester = TerminalTester(size: const Point(60, 14));
        tester.run(() async {
          final harness = FakeThreeWayWsHarness();
          await harness.startCaster(
            id: 'cast-1793563200000000',
            title: 'long-session',
            initialCols: 60,
            initialRows: 13,
          );
          final viewer = await harness.connectViewer(
            initialViewportCols: 60,
            initialViewportRows: 13,
          );
          final controller = CastSceneController(
            terminal: tester.terminal,
            viewModel: viewer.viewModel,
          );

          Future<void> settle() async {
            for (var i = 0; i < 4; i++) {
              await tester.pump(const Duration(milliseconds: 20));
            }
          }

          await settle();

          // 1. Open ChordsHelpDialog on 60x14 -> no overflow hazard stripes ('▜' or '▙'), Close button stays visible.
          tester.sendString('\x1c?');
          await settle();
          final helpScreen = _extractScreenText(tester.backend.buffer!);
          check(helpScreen).not((it) => it.contains('▜'));
          check(helpScreen).not((it) => it.contains('▙'));
          check(helpScreen).contains('Close (Enter)');
          tester.sendKey(LogicalKey.enter);
          await settle();
          check(controller.isChordsHelpOpen).isFalse();

          // 2. Open StatsForNerdsDialog on 60x14 with 21-char session ID -> no overflow hazard stripes, Close button stays visible.
          tester.sendString('\x1cs');
          await settle();
          final statsScreen = _extractScreenText(tester.backend.buffer!);
          check(statsScreen).not((it) => it.contains('▜'));
          check(statsScreen).not((it) => it.contains('▙'));
          check(statsScreen).contains('cast-1793563200000000');
          check(statsScreen).contains('Close (Enter)');
          tester.sendKey(LogicalKey.enter);
          await settle();
          check(controller.isStatsDialogOpen).isFalse();

          // 3. Open SettingsDialog on 60x14 -> no overflow hazard stripes, Close button stays visible.
          tester.sendString('\x1c,');
          await settle();
          final settingsScreen = _extractScreenText(tester.backend.buffer!);
          check(settingsScreen).not((it) => it.contains('▜'));
          check(settingsScreen).not((it) => it.contains('▙'));
          check(settingsScreen).contains('Close (Esc)');
          tester.sendKey(LogicalKey.escape);
          await settle();
          check(controller.isSettingsDialogOpen).isFalse();

          controller.dispose();
          await harness.dispose();
        });
      },
    );

    _defineSettingsCheckboxTest();
    _defineHotReloadDockTest();
    _defineTinyViewportAndDebugToggleTest();
  });
}

void _defineSettingsCheckboxTest() {
  test(
    r'opens SettingsDialog via Ctrl+\ , and [⚙] dock buttons (top & left), toggles debug overlay and F12 shortcuts, and resets debug flags on dispose',
    () {
      final tester = TerminalTester(size: const Point(80, 24));
      tester.run(() async {
        final harness = FakeThreeWayWsHarness();
        final caster = await harness.startCaster(id: 'sess-1', title: 'zsh');
        final viewer = await harness.connectViewer();
        final persistedSettings = <CastWorkspaceSettings>[];
        viewer.viewModel.onSettingsChanged = persistedSettings.add;
        final controller = CastSceneController(
          terminal: tester.terminal,
          viewModel: viewer.viewModel,
        );

        await _settleTester(tester);
        check(controller.isSettingsDialogOpen).isFalse();
        check(viewer.viewModel.copyOnSelect).isTrue();
        check(viewer.viewModel.debugOverlayEnabled).isFalse();
        check(viewer.viewModel.f12ShortcutsEnabled).isFalse();
        check(debugPaintLayerBordersEnabled).isFalse();
        check(debugShowTouchesEnabled).isFalse();
        check(
          CastWorkspaceSettings.fromJsonString(
            null,
            defaultDockPosition: .left,
          ),
        ).equals(const CastWorkspaceSettings(dockPosition: .left));
        check(
          CastWorkspaceSettings.fromJsonString('{invalid'),
        ).equals(CastWorkspaceSettings.defaults);

        // 1. Open SettingsDialog via Ctrl+\ , and verify initial checkboxes.
        tester.sendString('\x1c,');
        await _settleTester(tester);
        check(controller.isSettingsDialogOpen).isTrue();
        final initialText = _extractScreenText(tester.backend.buffer!);
        check(initialText).contains('TermUI Caster - Settings');
        check(
          initialText,
        ).contains(r'[X] Copy selection on release (Ctrl+\ o)');
        check(
          initialText,
        ).contains('[ ] Debug overlay: layer borders, hover & touches');
        check(
          initialText,
        ).contains('[ ] Enable F12 screenshot & Shift+F12 atlas reload');

        // 2. Press Space on focused item 0 (copyOnSelect) -> toggles off.
        tester.sendString(' ');
        await _settleTester(tester);
        check(viewer.viewModel.copyOnSelect).isFalse();

        // 3. Press Tab to move to item 1 (debugOverlayEnabled) and Space to toggle on!
        tester.sendKey(LogicalKey.tab);
        await _settleTester(tester);
        tester.sendString(' ');
        await _settleTester(tester);
        check(viewer.viewModel.debugOverlayEnabled).isTrue();
        check(debugPaintLayerBordersEnabled).isTrue();
        check(debugShowTouchesEnabled).isTrue();
        check(debugPaintHoverEnabled).isTrue();
        check(debugMouseCursorEnabled).isTrue();
        check(_extractScreenText(tester.backend.buffer!)).contains('[🧐]');

        // 4. Press Down to move to item 2 (f12ShortcutsEnabled) and Enter to toggle on!
        tester.sendKey(LogicalKey.arrowDown);
        await _settleTester(tester);
        tester.sendKey(LogicalKey.enter);
        await _settleTester(tester);
        check(viewer.viewModel.f12ShortcutsEnabled).isTrue();
        check(controller.isSettingsDialogOpen).isTrue();

        // 5. Navigate to Close button (index 12) and Enter to dismiss!
        for (var i = 0; i < 10; i++) {
          tester.sendKey(LogicalKey.arrowDown);
          await _settleTester(tester);
        }
        tester.sendKey(LogicalKey.enter);
        await _settleTester(tester);
        check(controller.isSettingsDialogOpen).isFalse();
        check(
          controller.sceneManager.focusedLayer,
        ).identicalTo(controller.ptyLayer);

        // 6. Ctrl+O (0x0f) still forwards to the PTY even while debugOverlayEnabled is true!
        caster.pty.writtenInputs.clear();
        tester.sendString('\x0f');
        await _settleTester(tester);
        check(caster.pty.writtenInputs.single).deepEquals(const [0x0f]);

        // 7. Click [⚙] in top dock bar (cols 58..61 -> 1-based col 60, row 1) -> opens SettingsDialog!
        tester.mouseDown(60, 1);
        tester.mouseUp(60, 1);
        await _settleTester(tester);
        check(controller.isSettingsDialogOpen).isTrue();
        tester.sendString(',');
        await _settleTester(tester);
        check(controller.isSettingsDialogOpen).isFalse();

        // 8. Switch dock to left sidebar and click [⚙] button (cols 18..21 -> 1-based col 20, row 1).
        viewer.viewModel.setDockPosition(.left);
        await _settleTester(tester);
        tester.mouseDown(20, 1);
        tester.mouseUp(20, 1);
        await _settleTester(tester);
        check(controller.isSettingsDialogOpen).isTrue();
        tester.sendString('q');
        await _settleTester(tester);
        check(controller.isSettingsDialogOpen).isFalse();

        // 9. Verify persisted settings JSON round-trip and that dispose() resets global termui debug flags to false.
        check(persistedSettings).isNotEmpty();
        final latestSettings = persistedSettings.last;
        check(latestSettings).equals(
          const CastWorkspaceSettings(
            dockPosition: .left,
            copyOnSelect: false,
            debugOverlayEnabled: true,
            f12ShortcutsEnabled: true,
          ),
        );
        check(
          CastWorkspaceSettings.fromJsonString(latestSettings.toJsonString()),
        ).equals(latestSettings);

        controller.dispose();
        check(debugPaintLayerBordersEnabled).isFalse();
        check(debugShowTouchesEnabled).isFalse();
        check(debugPaintHoverEnabled).isFalse();
        check(debugMouseCursorEnabled).isFalse();
        await harness.dispose();
      });
    },
  );
}

void _defineHotReloadDockTest() {
  test(
    'rebinds dock callbacks on hot reload (TermuiBinding.reassembleAll), toggles top<->left on [Dock] click, and accepts slash/control/uppercase chords',
    () {
      final tester = TerminalTester(size: const Point(80, 24));
      tester.run(() async {
        final harness = FakeThreeWayWsHarness();
        await harness.startCaster(id: 'sess-1', title: 'zsh');
        final viewer = await harness.connectViewer();
        final controller = CastSceneController(
          terminal: tester.terminal,
          viewModel: viewer.viewModel,
        );

        await _settleTester(tester);

        controller.dockRenderer
          ..onRequestConnectionPrompt = null
          ..onRequestChordsHelp = null
          ..onRequestStats = null
          ..onRequestSettings = null;
        TermuiBinding.reassembleAll();
        await _settleTester(tester);

        tester.mouseDown(60, 1);
        tester.mouseUp(60, 1);
        await _settleTester(tester);
        check(controller.isSettingsDialogOpen).isTrue();
        tester.sendKey(LogicalKey.escape);
        await _settleTester(tester);
        check(controller.isSettingsDialogOpen).isFalse();

        tester.mouseDown(65, 1);
        tester.mouseUp(65, 1);
        await _settleTester(tester);
        check(controller.isStatsDialogOpen).isTrue();
        tester.sendString('S');
        await _settleTester(tester);
        check(controller.isStatsDialogOpen).isFalse();

        tester.mouseDown(72, 1);
        tester.mouseUp(72, 1);
        await _settleTester(tester);
        check(controller.isChordsHelpOpen).isTrue();
        tester.sendString('/');
        await _settleTester(tester);
        check(controller.isChordsHelpOpen).isFalse();

        check(viewer.viewModel.dockPosition).equals(DockPosition.top);
        tester.mouseDown(77, 1);
        tester.mouseUp(77, 1);
        await _settleTester(tester);
        check(viewer.viewModel.dockPosition).equals(DockPosition.left);

        tester.mouseDown(3, 1);
        tester.mouseUp(3, 1);
        await _settleTester(tester);
        check(viewer.viewModel.dockPosition).equals(DockPosition.top);

        tester.sendString('\x1c/');
        await _settleTester(tester);
        check(controller.isChordsHelpOpen).isTrue();
        tester.sendString('Q');
        await _settleTester(tester);
        check(controller.isChordsHelpOpen).isFalse();

        tester.sendString('\x1c\x1f');
        await _settleTester(tester);
        check(controller.isChordsHelpOpen).isTrue();
        tester.sendKey(LogicalKey.escape);
        await _settleTester(tester);
        check(controller.isChordsHelpOpen).isFalse();

        tester.sendString('\x1c\x13');
        await _settleTester(tester);
        check(controller.isStatsDialogOpen).isTrue();
        tester.sendKey(LogicalKey.escape);
        await _settleTester(tester);
        check(controller.isStatsDialogOpen).isFalse();

        controller.dispose();
        await harness.dispose();
      });
    },
  );
}

void _defineTinyViewportAndDebugToggleTest() {
  test(
    'clamps dialogs on compact viewports without RangeError, clamps SettingsDialog focus to visible checkboxes, records RemotePtySceneRenderer.render Tracer span, and leaves global debugToggleKey untouched',
    () {
      final tester = TerminalTester(size: const Point(32, 16));
      tester.run(() async {
        final harness = FakeThreeWayWsHarness();
        await harness.startCaster(
          id: 'tiny-1',
          title: 'zsh',
          initialCols: 32,
          initialRows: 15,
        );
        final viewer = await harness.connectViewer(
          initialViewportCols: 32,
          initialViewportRows: 15,
        );
        final priorDebugToggleKey = debugToggleKey;
        Tracer.isEnabled = true;
        final controller = CastSceneController(
          terminal: tester.terminal,
          viewModel: viewer.viewModel,
        );

        Future<void> settle() async {
          for (var i = 0; i < 4; i++) {
            await tester.pump(const Duration(milliseconds: 20));
          }
        }

        await settle();
        Tracer.isEnabled = false;
        check(
          Tracer.registerString('RemotePtySceneRenderer.render'),
        ).isGreaterThan(0);
        check(controller.sceneManager.enableDebugToggleKey).isFalse();
        check(debugToggleKey).equals(priorDebugToggleKey);

        // Carbon-A8 & Opus-L2: ConnectionPromptDialog on 40x14 and 30x10 renders Connect (Enter) without overflow!
        for (final size in const [Point(40, 14), Point(30, 10)]) {
          tester.backend.size = size;
          await settle();
          tester.sendString('\x1cc');
          await settle();
          check(controller.isConnectionPromptOpen).isTrue();
          final promptText = _extractScreenText(tester.backend.buffer!);
          check(promptText).not((it) => it.contains('▜'));
          check(promptText).not((it) => it.contains('▙'));
          check(promptText).contains('Connect (Enter)');
          tester.sendKey(LogicalKey.escape);
          await settle();
          check(controller.isConnectionPromptOpen).isFalse();
        }

        // Carbon-A7: Resize to 32x10 -> SettingsDialog clamps size and dismisses via Escape!
        tester.backend.size = const Point(32, 10);
        await settle();
        tester.sendString('\x1c,');
        await settle();
        check(controller.isSettingsDialogOpen).isTrue();
        tester.sendKey(LogicalKey.escape);
        await settle();
        check(controller.isSettingsDialogOpen).isFalse();

        // Disposing controller leaves global debugToggleKey unmodified.
        controller.dispose();
        check(debugToggleKey).equals(priorDebugToggleKey);
        await harness.dispose();
      });
    },
  );

  test(
    'SettingsDialog and PaletteEditorDialog interactive controls, compact scrolling, and leader chords',
    () {
      final tester = TerminalTester(size: const Point(80, 24));
      tester.run(() async {
        final harness = FakeThreeWayWsHarness();
        await harness.startCaster(
          id: 'settings-1',
          title: 'zsh',
          initialCols: 80,
          initialRows: 23,
        );
        final viewer = await harness.connectViewer(
          initialViewportCols: 80,
          initialViewportRows: 23,
        );
        final controller = CastSceneController(
          terminal: tester.terminal,
          viewModel: viewer.viewModel,
        );

        Future<void> settle() async {
          for (var i = 0; i < 4; i++) {
            await tester.pump(const Duration(milliseconds: 20));
          }
        }

        await settle();

        // 1. Ctrl+\ t chord cycles theme preset and shows transient notice
        final initialTheme = viewer.viewModel.activeTerminalTheme;
        tester.sendString('\x1ct');
        await settle();
        final afterChordTheme = viewer.viewModel.activeTerminalTheme;
        check(afterChordTheme.id).not((it) => it.equals(initialTheme.id));
        check(viewer.viewModel.clipboardNotice).isNotNull();
        check(viewer.viewModel.clipboardNotice!).contains('Theme:');

        // 2. Open SettingsDialog via Ctrl+\ ,
        tester.sendString('\x1c,');
        await settle();
        check(controller.isSettingsDialogOpen).isTrue();

        // Focus 0..2 are checkboxes: copyOnSelect, debugOverlayEnabled, f12ShortcutsEnabled
        // Focus 3: Appearance mode
        tester.sendKey(LogicalKey.arrowDown); // 1
        await settle();
        tester.sendKey(LogicalKey.arrowDown); // 2
        await settle();
        tester.sendKey(LogicalKey.arrowDown); // 3 (Appearance)
        await settle();
        final initialMode = viewer.viewModel.themeSettings.appearanceMode;
        tester.sendKey(LogicalKey.arrowRight);
        await settle();
        check(
          viewer.viewModel.themeSettings.appearanceMode,
        ).not((it) => it.equals(initialMode));

        // Focus 6: ANSI Contrast
        tester.sendKey(LogicalKey.arrowDown); // 4 (Dark Preset)
        await settle();
        tester.sendKey(LogicalKey.arrowDown); // 5 (Light Preset)
        await settle();
        tester.sendKey(LogicalKey.arrowDown); // 6 (ANSI Contrast)
        await settle();
        check(viewer.viewModel.themeSettings.minimumContrast).equals(1.0);
        tester.sendKey(LogicalKey.arrowRight);
        await settle();
        check(viewer.viewModel.themeSettings.minimumContrast).equals(3.0);

        // Focus 7: Bold is Bright toggle
        tester.sendKey(LogicalKey.arrowDown); // 7 (Bold is Bright)
        await settle();
        check(viewer.viewModel.themeSettings.boldIsBright).isFalse();
        tester.sendKey(LogicalKey.character(' '));
        await settle();
        check(viewer.viewModel.themeSettings.boldIsBright).isTrue();

        // Focus 8: Faint Opacity
        tester.sendKey(LogicalKey.arrowDown); // 8 (Faint Opacity)
        await settle();
        final initialFaint = viewer.viewModel.themeSettings.faintOpacity;
        tester.sendKey(LogicalKey.arrowRight);
        await settle();
        check(
          viewer.viewModel.themeSettings.faintOpacity,
        ).not((it) => it.equals(initialFaint));

        // Focus 9: Smart Cursor
        tester.sendKey(LogicalKey.arrowDown); // 9 (Smart Cursor)
        await settle();
        check(viewer.viewModel.themeSettings.smartCursorColor).isTrue();
        tester.sendKey(LogicalKey.character(' '));
        await settle();
        check(viewer.viewModel.themeSettings.smartCursorColor).isFalse();

        // Focus 10: Customize ANSI Palette... -> Opens PaletteEditorDialog directly on Enter!
        tester.sendKey(LogicalKey.arrowDown); // 10
        await settle();
        tester.sendKey(LogicalKey.enter);
        await settle();
        check(controller.isSettingsDialogOpen).isFalse();
        check(controller.isPaletteEditorOpen).isTrue();

        // Palette Editor: Slot 0 (Black), type valid hex #123456
        tester.sendKey(LogicalKey.tab); // Move focus to hex input
        await settle();
        // Type hex code
        tester.sendString('\x7f\x7f\x7f\x7f\x7f\x7f\x7f#123456');
        await settle();
        tester.sendKey(LogicalKey.enter);
        await settle();
        check(
          viewer.viewModel.themeSettings.customOverrides.ansiOverrides[0],
        ).equals(const Color(0x12, 0x34, 0x56));

        // Reset slot via Reset Slot button (hex -> R -> G -> B -> Reset Slot)
        for (var i = 0; i < 4; i++) {
          tester.sendKey(LogicalKey.tab);
          await settle();
        }
        tester.sendKey(LogicalKey.enter);
        await settle();
        check(
          viewer.viewModel.themeSettings.customOverrides.ansiOverrides[0],
        ).isNull();

        // Close PaletteEditorDialog via Escape
        tester.sendKey(LogicalKey.escape);
        await settle();
        check(controller.isPaletteEditorOpen).isFalse();

        // 3. Compact viewport scrolling test (60x14)
        tester.backend.size = const Point(60, 14);
        await settle();
        tester.sendString('\x1c,');
        await settle();
        check(controller.isSettingsDialogOpen).isTrue();

        // Traverse down through all items; should not overflow
        for (var i = 0; i < 12; i++) {
          tester.sendKey(LogicalKey.arrowDown);
          await settle();
        }
        // At item 12 (Close button)
        tester.sendKey(LogicalKey.enter);
        await settle();
        check(controller.isSettingsDialogOpen).isFalse();

        controller.dispose();
        await viewer.viewModel.dispose();
        await harness.dispose();
      });
    },
  );

  _defineSettingsMouseClickTest();
  _definePaletteMouseClickAndBlurTest();
  _definePaletteRgbWheelAndScrollTest();
  _definePaletteWheelInDialogTest();
  _definePaletteEdgeCasesTest();
  _defineCompactAndLightContrastTest();
}

void _defineSettingsMouseClickTest() {
  test(
    'SettingsDialog locates and clicks all checkboxes, < ... > selectors, Reload from Storage, Customize ANSI Palette..., and Close (Esc) via MouseEvent',
    () {
      final tester = TerminalTester(size: const Point(80, 24));
      tester.run(() async {
        final harness = FakeThreeWayWsHarness();
        await harness.startCaster(id: 'mouse-settings', title: 'zsh');
        var storedJson = const CastWorkspaceSettings(
          copyOnSelect: true,
          themeSettings: TerminalThemeSettings(
            appearanceMode: .dark,
            darkThemeId: 'solarized_dark',
            minimumContrast: 4.5,
          ),
        ).toJsonString();
        final transport = WsClientTransport(
          token: harness.token,
          channelFactory: harness.openClientChannel,
        );
        final repo = CastClientRepository(transport: transport);
        final vm = CastWorkspaceViewModel(
          repository: repo,
          resizeDebounce: Duration.zero,
          onReloadSettings: () =>
              CastWorkspaceSettings.fromJsonString(storedJson),
        );
        await repo.connect();
        final controller = CastSceneController(
          terminal: tester.terminal,
          viewModel: vm,
        );

        await _settleTester(tester);
        tester.sendString('\x1c,');
        await _settleTester(tester);
        check(controller.isSettingsDialogOpen).isTrue();

        _clickBufferText(tester, '[X] Copy selection on release');
        await _settleTester(tester);
        check(vm.copyOnSelect).isFalse();

        _clickBufferText(tester, '[ ] Debug overlay:');
        await _settleTester(tester);
        check(vm.debugOverlayEnabled).isTrue();
        _clickBufferText(tester, 'Debug overlay: layer borders', colOffset: 2);
        await tester.pump(const Duration(milliseconds: 700));
        await _settleTester(tester);
        check(vm.debugOverlayEnabled).isFalse();

        _clickBufferText(tester, 'F12 screenshot & Shift+F12');
        await _settleTester(tester);
        check(vm.f12ShortcutsEnabled).isTrue();

        _clickBufferText(tester, '< System >', colOffset: 2);
        await _settleTester(tester);
        check(vm.themeSettings.appearanceMode).equals(ThemeAppearanceMode.dark);
        _clickBufferText(tester, '< Dark >', colOffset: 2);
        await _settleTester(tester);
        check(
          vm.themeSettings.appearanceMode,
        ).equals(ThemeAppearanceMode.light);
        final titlePos = _findTextInBuffer(
          tester.backend.buffer!,
          'TermUI Caster - Settings',
        );
        final livePanelBg = Color.argb(
          tester.backend.buffer!.getBackground(titlePos.x, titlePos.y),
        );
        check(
          TerminalContrast.relativeLuminance(livePanelBg),
        ).isGreaterOrEqual(0.8);

        _clickBufferText(tester, '< TermUI Dark >', colOffset: 3);
        await _settleTester(tester);
        check(vm.themeSettings.darkThemeId).equals('high_contrast_dark');
        _clickBufferText(tester, '< High Contrast Dark >', colOffset: 0);
        await _settleTester(tester);
        check(vm.themeSettings.darkThemeId).equals('termui_dark');

        _clickBufferText(tester, '< TermUI Light >', colOffset: 3);
        await _settleTester(tester);
        check(vm.themeSettings.lightThemeId).equals('high_contrast_light');

        check(
          _extractScreenText(tester.backend.buffer!),
        ).contains('min ANSI contrast:');
        _clickBufferText(tester, '< 1.0x (Exact) >', colOffset: 3);
        await _settleTester(tester);
        check(vm.themeSettings.minimumContrast).equals(3.0);
        check(
          _extractScreenText(tester.backend.buffer!),
        ).contains('< 3.0x (UI) >');

        _clickBufferText(tester, '[ ] Bold uses Bright ANSI colors');
        await _settleTester(tester);
        check(vm.themeSettings.boldIsBright).isTrue();

        _clickBufferText(tester, '< 55% >', colOffset: 2);
        await _settleTester(tester);
        check(vm.themeSettings.faintOpacity).equals(0.75);

        _clickBufferText(tester, '[X] Smart Cursor:');
        await _settleTester(tester);
        check(vm.themeSettings.smartCursorColor).isFalse();

        storedJson = const CastWorkspaceSettings(
          copyOnSelect: true,
          themeSettings: TerminalThemeSettings(
            appearanceMode: .dark,
            darkThemeId: 'solarized_dark',
            minimumContrast: 7.0,
          ),
        ).toJsonString();
        _clickBufferText(tester, 'Reload from Storage', colOffset: 2);
        await _settleTester(tester);
        check(vm.copyOnSelect).isTrue();
        check(vm.themeSettings.darkThemeId).equals('solarized_dark');
        check(vm.themeSettings.minimumContrast).equals(7.0);
        check(vm.clipboardNotice).equals('Settings reloaded from storage');
        check(
          _extractScreenText(tester.backend.buffer!),
        ).contains('< 7.0x (AAA) >');

        _clickBufferText(tester, 'Customize ANSI Palette...', colOffset: 2);
        await _settleTester(tester);
        check(controller.isSettingsDialogOpen).isFalse();
        check(controller.isPaletteEditorOpen).isTrue();
        tester.sendKey(LogicalKey.escape);
        await _settleTester(tester);
        check(controller.isPaletteEditorOpen).isFalse();

        tester.sendString('\x1c,');
        await _settleTester(tester);
        check(controller.isSettingsDialogOpen).isTrue();
        _clickBufferText(tester, 'Close (Esc)', colOffset: 2);
        await _settleTester(tester);
        check(controller.isSettingsDialogOpen).isFalse();

        controller.dispose();
        await vm.dispose();
        await repo.dispose();
        await harness.dispose();
      });
    },
  );
}

void _definePaletteMouseClickAndBlurTest() {
  test(
    'PaletteEditorDialog renders all 20 slots, preserves empty overrides across Tab/Esc, syncs inline hex across row switches, and clicks all controls',
    () {
      final tester = TerminalTester(size: const Point(80, 24));
      tester.run(() async {
        final harness = FakeThreeWayWsHarness();
        await harness.startCaster(id: 'mouse-palette', title: 'zsh');
        final viewer = await harness.connectViewer();
        final vm = viewer.viewModel;
        vm.updateThemeSettings(
          const TerminalThemeSettings(
            appearanceMode: .light,
            lightThemeId: 'termui_light',
          ),
        );
        final controller = CastSceneController(
          terminal: tester.terminal,
          viewModel: vm,
        );

        await _settleTester(tester);
        check(vm.themeSettings.customOverrides.isEmpty).isTrue();

        // 1. M2 regression: all 20 slots visible; Up/Down + Tab through all 8 controls + Esc -> empty overrides!
        unawaited(controller.openPaletteEditor());
        await _settleTester(tester);
        check(controller.isPaletteEditorOpen).isTrue();
        final openText = _extractScreenText(tester.backend.buffer!);
        for (final label in const [
          '0  Black',
          '7  White',
          '8  Brt Black',
          '15 Brt White',
          'FG Foregrnd',
          'BG Backgrnd',
          'CR Cursor',
          'SL Selection',
        ]) {
          check(openText).contains(label);
        }
        check(
          _cellContrastAtText(tester.backend.buffer!, '1  Red'),
        ).isGreaterOrEqual(4.5);

        for (var i = 0; i < 3; i++) {
          tester.sendKey(LogicalKey.arrowUp);
          await _settleTester(tester);
        }
        check(
          _extractScreenText(tester.backend.buffer!),
        ).contains('▸ BG Backgrnd');
        for (var i = 0; i < 3; i++) {
          tester.sendKey(LogicalKey.arrowDown);
          await _settleTester(tester);
        }
        check(
          _extractScreenText(tester.backend.buffer!),
        ).contains('▸ 0  Black');

        for (var i = 0; i < 8; i++) {
          tester.sendKey(LogicalKey.tab);
          await _settleTester(tester);
        }
        tester.sendKey(LogicalKey.escape);
        await _settleTester(tester);
        check(controller.isPaletteEditorOpen).isFalse();
        check(vm.themeSettings.customOverrides.isEmpty).isTrue();

        // 2. Reopen: Enter on slotList focuses hex without closing; row & inline hex clicks commit/discard safely
        unawaited(controller.openPaletteEditor());
        await _settleTester(tester);
        check(controller.isPaletteEditorOpen).isTrue();
        check(
          _extractScreenText(tester.backend.buffer!),
        ).contains('Contrast vs bg:');

        tester.sendKey(LogicalKey.enter);
        await _settleTester(tester);
        check(controller.isPaletteEditorOpen).isTrue();
        tester.sendString('qrhl');
        await _settleTester(tester);
        check(controller.isPaletteEditorOpen).isTrue();
        tester.sendKey(LogicalKey.tab, shift: true);
        await _settleTester(tester);
        check(vm.themeSettings.customOverrides.isEmpty).isTrue();

        _clickBufferText(tester, '1  Red', colOffset: 1);
        await _settleTester(tester);
        check(_extractScreenText(tester.backend.buffer!)).contains('▸ 1  Red');
        _clickBufferText(tester, '0  Black', colOffset: 1);
        await _settleTester(tester);
        check(
          _extractScreenText(tester.backend.buffer!),
        ).contains('▸ 0  Black');

        _clickBufferText(tester, '#24292F', colOffset: 1);
        await _settleTester(tester);
        tester.sendString('\x7f\x7f\x7f\x7f\x7f\x7f\x7f\x7f#AA33CC');
        await _settleTester(tester);

        // Clicking slot 1's #CF222E commits slot 0 (#AA33CC) before switching focus to slot 1 hex!
        _clickBufferText(tester, '#CF222E', colOffset: 1);
        await _settleTester(tester);
        check(
          vm.themeSettings.customOverrides.ansiOverrides[0],
        ).equals(const Color(0xAA, 0x33, 0xCC));
        check(_extractScreenText(tester.backend.buffer!)).contains('▸ 1  Red');

        tester.sendString('\x7f\x7f\x7f\x7f\x7f\x7f\x7f\x7f#115599');
        await _settleTester(tester);
        tester.sendKey(LogicalKey.enter);
        await _settleTester(tester);
        check(
          vm.themeSettings.customOverrides.ansiOverrides[1],
        ).equals(const Color(0x11, 0x55, 0x99));

        _clickBufferText(tester, 'Reset Slot (r)', colOffset: 2);
        await _settleTester(tester);
        check(vm.themeSettings.customOverrides.ansiOverrides[1]).isNull();
        check(
          vm.themeSettings.customOverrides.ansiOverrides[0],
        ).equals(const Color(0xAA, 0x33, 0xCC));

        _clickBufferText(tester, 'Reset All *', colOffset: 2);
        await _settleTester(tester);
        check(vm.themeSettings.customOverrides.isEmpty).isTrue();

        _clickBufferText(tester, 'Close (Esc)', colOffset: 2);
        await _settleTester(tester);
        check(controller.isPaletteEditorOpen).isFalse();

        controller.dispose();
        await harness.dispose();
      });
    },
  );
}

void _definePaletteRgbWheelAndScrollTest() {
  test(
    'PaletteEditorDialog steps < R > < G > < B > live (±1/±16 & mouse), resets via r, and scrolls via wheel without overflow',
    () {
      final tester = TerminalTester(size: const Point(80, 24));
      tester.run(() async {
        final harness = FakeThreeWayWsHarness();
        await harness.startCaster(id: 'rgb-scroll-palette', title: 'zsh');
        final viewer = await harness.connectViewer();
        final vm = viewer.viewModel;
        final controller = CastSceneController(
          terminal: tester.terminal,
          viewModel: vm,
        );
        await _settleTester(tester);

        unawaited(controller.openPaletteEditor());
        await _settleTester(tester);

        // Slot 0 in termui_dark is #1E222A (30, 34, 42)
        _clickBufferText(
          tester,
          'R: <  30 (1E) >',
          colOffset: 14,
        ); // '>' (+1 -> 31)
        await _settleTester(tester);
        check(
          vm.themeSettings.customOverrides.ansiOverrides[0],
        ).equals(const Color(31, 34, 42));
        check(_extractScreenText(tester.backend.buffer!)).contains('#1F222A');

        _clickBufferText(
          tester,
          'R: <  31 (1F) >',
          colOffset: 3,
        ); // '<' (-1 -> 30)
        await _settleTester(tester);
        check(
          vm.themeSettings.customOverrides.ansiOverrides[0],
        ).equals(const Color(30, 34, 42));

        // Shift+Right (+16), Shift+Left (-16) on G, plus clamping at 255 & 0 on B
        tester.sendKey(LogicalKey.tab); // greenChannel
        await _settleTester(tester);
        tester.sendKey(LogicalKey.arrowRight, shift: true); // 34 + 16 = 50
        await _settleTester(tester);
        tester.sendKey(LogicalKey.arrowRight); // 50 + 1 = 51
        await _settleTester(tester);
        tester.sendKey(LogicalKey.arrowLeft, shift: true); // 51 - 16 = 35
        await _settleTester(tester);
        check(
          vm.themeSettings.customOverrides.ansiOverrides[0],
        ).equals(const Color(30, 35, 42));

        tester.sendKey(LogicalKey.tab); // blueChannel
        await _settleTester(tester);
        for (var i = 0; i < 15; i++) {
          tester.sendKey(LogicalKey.arrowRight, shift: true);
          await _settleTester(tester);
        }
        check(
          vm.themeSettings.customOverrides.ansiOverrides[0],
        ).equals(const Color(30, 35, 255));
        for (var i = 0; i < 17; i++) {
          tester.sendKey(LogicalKey.arrowLeft, shift: true);
          await _settleTester(tester);
        }
        check(
          vm.themeSettings.customOverrides.ansiOverrides[0],
        ).equals(const Color(30, 35, 0));

        // 'r' resets active slot
        tester.sendKey(LogicalKey.character('r'));
        await _settleTester(tester);
        check(vm.themeSettings.customOverrides.ansiOverrides[0]).isNull();

        // Compact 60x14 wheel scrolling + error rendering without overflow
        tester.sendKey(LogicalKey.escape);
        await _settleTester(tester);
        tester.backend.size = const Point(60, 14);
        await _settleTester(tester);
        unawaited(controller.openPaletteEditor());
        await _settleTester(tester);
        _assertZeroOverflowStripes(tester.backend.buffer!);
        check(_extractScreenText(tester.backend.buffer!)).contains('0  Black');

        final listPos = _findTextInBuffer(tester.backend.buffer!, '0  Black');
        tester.mouseDown(
          listPos.x + 2,
          listPos.y + 1,
          button: MouseButton.wheelDown,
        );
        await _settleTester(tester);
        check(
          _extractScreenText(tester.backend.buffer!),
        ).not((it) => it.contains('0  Black'));
        tester.mouseDown(
          listPos.x + 2,
          listPos.y + 1,
          button: MouseButton.wheelUp,
        );
        await _settleTester(tester);
        check(_extractScreenText(tester.backend.buffer!)).contains('0  Black');

        // Enter invalid hex on 60x14 and 32x10: error visible, zero overflow stripes!
        _clickBufferText(tester, '#1E222A', colOffset: 1);
        await _settleTester(tester);
        tester.sendString('\x7f\x7f\x7f\x7f\x7f\x7f\x7f#ZZZZZZ');
        await _settleTester(tester);
        tester.sendKey(LogicalKey.enter);
        await _settleTester(tester);
        _assertZeroOverflowStripes(tester.backend.buffer!);
        check(
          _extractScreenText(tester.backend.buffer!),
        ).contains('Invalid hex');

        tester.sendKey(LogicalKey.escape);
        await _settleTester(tester);
        tester.backend.size = const Point(32, 10);
        await _settleTester(tester);
        unawaited(controller.openPaletteEditor());
        await _settleTester(tester);
        _assertZeroOverflowStripes(tester.backend.buffer!);

        tester.sendKey(LogicalKey.escape);
        await _settleTester(tester);
        check(controller.isPaletteEditorOpen).isFalse();

        controller.dispose();
        await harness.dispose();
      });
    },
  );
}

void _defineCompactAndLightContrastTest() {
  test(
    'renders PaletteEditorDialog and SettingsDialog with zero overflow on 60x14 and 32x10, and renders ChordsHelpDialog and StatsForNerdsDialog with >= 4.5:1 body contrast in termui_light',
    () {
      final tester = TerminalTester(size: const Point(60, 14));
      tester.run(() async {
        final harness = FakeThreeWayWsHarness();
        await harness.startCaster(
          id: 'compact-contrast',
          title: 'zsh',
          initialCols: 60,
          initialRows: 13,
        );
        final viewer = await harness.connectViewer(
          initialViewportCols: 60,
          initialViewportRows: 13,
        );
        final vm = viewer.viewModel;
        final controller = CastSceneController(
          terminal: tester.terminal,
          viewModel: vm,
        );

        await _settleTester(tester);

        for (final size in const [Point(60, 14), Point(32, 10)]) {
          tester.backend.size = size;
          await _settleTester(tester);

          tester.sendString('\x1c,');
          await _settleTester(tester);
          check(controller.isSettingsDialogOpen).isTrue();
          _assertZeroOverflowStripes(tester.backend.buffer!);
          check(
            _extractScreenText(tester.backend.buffer!),
          ).contains('Close (Esc)');
          tester.sendKey(LogicalKey.escape);
          await _settleTester(tester);
          check(controller.isSettingsDialogOpen).isFalse();

          unawaited(controller.openPaletteEditor());
          await _settleTester(tester);
          check(controller.isPaletteEditorOpen).isTrue();
          _assertZeroOverflowStripes(tester.backend.buffer!);
          check(
            _extractScreenText(tester.backend.buffer!),
          ).contains('Close (Esc)');
          tester.sendKey(LogicalKey.escape);
          await _settleTester(tester);
          check(controller.isPaletteEditorOpen).isFalse();
        }

        tester.backend.size = const Point(80, 24);
        vm.updateThemeSettings(
          const TerminalThemeSettings(
            appearanceMode: .light,
            lightThemeId: 'termui_light',
          ),
        );
        await _settleTester(tester);

        tester.sendString('\x1c?');
        await _settleTester(tester);
        check(controller.isChordsHelpOpen).isTrue();
        final helpBuf = tester.backend.buffer!;
        check(
          _cellContrastAtText(helpBuf, 'Open connection dialog'),
        ).isGreaterOrEqual(4.5);
        check(
          _cellContrastAtText(helpBuf, 'Cycle color theme preset'),
        ).isGreaterOrEqual(4.5);
        tester.sendKey(LogicalKey.enter);
        await _settleTester(tester);
        check(controller.isChordsHelpOpen).isFalse();

        tester.sendString('\x1cs');
        await _settleTester(tester);
        check(controller.isStatsDialogOpen).isTrue();
        final statsBuf = tester.backend.buffer!;
        check(_cellContrastAtText(statsBuf, 'Endpoint:')).isGreaterOrEqual(4.5);
        check(_cellContrastAtText(statsBuf, 'Session:')).isGreaterOrEqual(4.5);
        check(_cellContrastAtText(statsBuf, 'Traffic:')).isGreaterOrEqual(4.5);
        check(_cellContrastAtText(statsBuf, 'RX Rate:')).isGreaterOrEqual(4.5);
        check(_cellContrastAtText(statsBuf, 'Frames/s:')).isGreaterOrEqual(4.5);
        tester.sendKey(LogicalKey.enter);
        await _settleTester(tester);
        check(controller.isStatsDialogOpen).isFalse();

        controller.dispose();
        await harness.dispose();
      });
    },
  );
}

({int minX, int maxX, int minY, int maxY}) _findKittyBounds(Buffer buf) {
  var minX = buf.width;
  var maxX = -1;
  var minY = buf.height;
  var maxY = -1;
  for (var y = 0; y < buf.height; y++) {
    for (var x = 0; x < buf.width; x++) {
      if (buf.getCharacter(x, y).startsWith('\u{10EEEE}')) {
        if (x < minX) minX = x;
        if (x > maxX) maxX = x;
        if (y < minY) minY = y;
        if (y > maxY) maxY = y;
      }
    }
  }
  check(maxX).isGreaterThan(minX);
  check(maxY).isGreaterThan(minY);
  return (minX: minX, maxX: maxX, minY: minY, maxY: maxY);
}

void _definePaletteWheelInDialogTest() {
  test(
    'PaletteEditorDialog integrates HsvColorWheelPicker clicks, V=0 hue retention during bar drag, and mid-drag slot switch cancellation',
    () {
      final tester = TerminalTester(size: const Point(80, 24));
      tester.run(() async {
        final harness = FakeThreeWayWsHarness();
        await harness.startCaster(id: 'wheel-dialog', title: 'zsh');
        final viewer = await harness.connectViewer();
        final vm = viewer.viewModel;
        final controller = CastSceneController(
          terminal: tester.terminal,
          viewModel: vm,
        );
        await _settleTester(tester);

        unawaited(controller.openPaletteEditor());
        await _settleTester(tester);

        // Focus hexInput with un-submitted draft, then click wheel to blur & update slot 0.
        _clickBufferText(tester, '#1E222A', colOffset: 1);
        await _settleTester(tester);
        tester.sendString('\x7f\x7f\x7f\x7f\x7f\x7f\x7f#112233');
        await _settleTester(tester);

        final bounds = _findKittyBounds(tester.backend.buffer!);
        final wheelX =
            bounds.minX + ((bounds.maxX - bounds.minX) * 0.35).round() + 1;
        final wheelY =
            bounds.minY + ((bounds.maxY - bounds.minY) * 0.25).round() + 1;
        tester.mouseDown(wheelX, wheelY);
        tester.mouseUp(wheelX, wheelY);
        await _settleTester(tester);

        final picked = vm.themeSettings.customOverrides.ansiOverrides[0]!;
        check(picked).not((it) => it.equals(const Color(0x11, 0x22, 0x33)));
        check(
          _extractScreenText(tester.backend.buffer!),
        ).contains(CustomPaletteOverrides.formatHexRgb(picked));

        // Drag brightness bar: top -> bottom (#000000) -> mid while keeping hue.
        final barX = bounds.maxX + 1;
        final topY = bounds.minY + 1;
        final botY = bounds.maxY + 1;
        final midY = ((bounds.minY + bounds.maxY) ~/ 2) + 1;
        tester.mouseDown(barX, topY);
        await _settleTester(tester);
        final topColor = vm.themeSettings.customOverrides.ansiOverrides[0]!;
        final topHue = HsvColor.fromColor(topColor).hue;

        tester.mouseMove(barX, botY, drag: true);
        await _settleTester(tester);
        check(
          vm.themeSettings.customOverrides.ansiOverrides[0],
        ).equals(const Color(0, 0, 0));
        check(_extractScreenText(tester.backend.buffer!)).contains('#000000');

        tester.mouseMove(barX, midY, drag: true);
        await _settleTester(tester);
        final midColor = vm.themeSettings.customOverrides.ansiOverrides[0]!;
        check(midColor).not((it) => it.equals(const Color(0, 0, 0)));
        final midHue = HsvColor.fromColor(midColor).hue;
        final hueDiff = ((midHue - topHue).abs()) % 360.0;
        check(hueDiff > 180 ? 360 - hueDiff : hueDiff).isLessThan(5.0);

        // Mid-drag arrowDown switches to slot 1 and cancels active drag.
        tester.sendKey(LogicalKey.arrowDown);
        await _settleTester(tester);
        tester.mouseMove(barX, topY, drag: true);
        tester.mouseUp(barX, topY);
        await _settleTester(tester);
        check(vm.themeSettings.customOverrides.ansiOverrides[1]).isNull();

        tester.sendKey(LogicalKey.escape);
        await _settleTester(tester);
        controller.dispose();
        await harness.dispose();
      });
    },
  );
}

void _definePaletteEdgeCasesTest() {
  test(
    'PaletteEditorDialog handles invalid hex discard, barrier dismiss, exact stepper hit width, compact 36x14/32x10, and 82x21 wide scroll re-center',
    () {
      final tester = TerminalTester(size: const Point(80, 24));
      tester.run(() async {
        final harness = FakeThreeWayWsHarness();
        await harness.startCaster(id: 'palette-edges', title: 'zsh');
        final viewer = await harness.connectViewer();
        final vm = viewer.viewModel;
        final controller = CastSceneController(
          terminal: tester.terminal,
          viewModel: vm,
        );
        await _settleTester(tester);

        unawaited(controller.openPaletteEditor());
        await _settleTester(tester);

        // Invalid hex on 80x24: Enter shows error; Shift+Tab clears & reverts; Enter re-opens clean.
        tester.sendKey(LogicalKey.enter);
        await _settleTester(tester);
        tester.sendString('\x7f\x7f\x7f\x7f\x7f\x7f\x7fqrhl');
        await _settleTester(tester);
        tester.sendKey(LogicalKey.enter);
        await _settleTester(tester);
        check(
          _extractScreenText(tester.backend.buffer!),
        ).contains('Invalid hex');

        tester.sendKey(LogicalKey.tab, shift: true);
        await _settleTester(tester);
        check(
          _extractScreenText(tester.backend.buffer!),
        ).not((it) => it.contains('Invalid hex'));
        tester.sendKey(LogicalKey.enter);
        await _settleTester(tester);
        check(_extractScreenText(tester.backend.buffer!)).contains('#1E222A');
        check(vm.themeSettings.customOverrides.isEmpty).isTrue();

        // Clicking blank space right of B: < ... > is a no-op.
        final bPos = _findTextInBuffer(tester.backend.buffer!, 'B: <');
        tester.mouseDown(bPos.x + 19, bPos.y + 1);
        tester.mouseUp(bPos.x + 19, bPos.y + 1);
        await _settleTester(tester);
        check(vm.themeSettings.customOverrides.isEmpty).isTrue();

        // Un-submitted #FF00AA + backdrop barrier click (0, 0 -> 1, 1) discards & closes.
        _clickBufferText(tester, '#1E222A', colOffset: 1);
        await _settleTester(tester);
        tester.sendString('\x7f\x7f\x7f\x7f\x7f\x7f\x7f#FF00AA');
        await _settleTester(tester);
        tester.mouseDown(1, 1);
        tester.mouseUp(1, 1);
        await _settleTester(tester);
        check(controller.isPaletteEditorOpen).isFalse();
        check(vm.themeSettings.customOverrides.isEmpty).isTrue();

        // Compact 32x10: bottom visible row keeps TextField mounted when Invalid hex shrinks list.
        tester.backend.size = const Point(32, 10);
        await _settleTester(tester);
        unawaited(controller.openPaletteEditor());
        await _settleTester(tester);
        tester.sendKey(LogicalKey.arrowDown);
        tester.sendKey(LogicalKey.arrowDown);
        await _settleTester(tester);
        tester.sendKey(LogicalKey.enter);
        await _settleTester(tester);
        tester.sendString('\x7f\x7f\x7f\x7f\x7f\x7f\x7fbad');
        await _settleTester(tester);
        tester.sendKey(LogicalKey.enter);
        await _settleTester(tester);
        _assertZeroOverflowStripes(tester.backend.buffer!);
        check(
          _extractScreenText(tester.backend.buffer!),
        ).contains('Invalid hex');
        tester.sendString('\x7f\x7f\x7f#224466');
        await _settleTester(tester);
        tester.sendKey(LogicalKey.enter);
        await _settleTester(tester);
        check(
          vm.themeSettings.customOverrides.ansiOverrides[2],
        ).equals(const Color(0x22, 0x44, 0x66));
        tester.sendKey(LogicalKey.escape);
        await _settleTester(tester);

        // Compact 36x14: <R> click (colOffset 2) and [#RRGGBB] click.
        tester.backend.size = const Point(36, 14);
        await _settleTester(tester);
        unawaited(controller.openPaletteEditor());
        await _settleTester(tester);
        _clickBufferText(tester, 'R:<', colOffset: 2);
        await _settleTester(tester);
        check(
          vm.themeSettings.customOverrides.ansiOverrides[0],
        ).equals(const Color(29, 34, 42));
        _clickBufferText(tester, '#1D222A', colOffset: 1);
        await _settleTester(tester);
        tester.sendString('\x7f\x7f\x7f\x7f\x7f\x7f\x7f#010203');
        await _settleTester(tester);
        tester.sendKey(LogicalKey.enter);
        await _settleTester(tester);
        check(
          vm.themeSettings.customOverrides.ansiOverrides[0],
        ).equals(const Color(1, 2, 3));
        _assertZeroOverflowStripes(tester.backend.buffer!);
        tester.sendKey(LogicalKey.escape);
        await _settleTester(tester);

        // Wide-plus-scroll 82x21 (~640x384): wheel visible, listRows < 20, Enter re-centers slot 0.
        tester.backend.size = const Point(82, 21);
        await _settleTester(tester);
        unawaited(controller.openPaletteEditor());
        await _settleTester(tester);
        _findKittyBounds(tester.backend.buffer!);
        _assertZeroOverflowStripes(tester.backend.buffer!);
        check(
          _extractScreenText(tester.backend.buffer!),
        ).not((it) => it.contains('SL Selection'));

        final slot0Pos = _findTextInBuffer(tester.backend.buffer!, '0  Black');
        for (var i = 0; i < 3; i++) {
          tester.mouseDown(
            slot0Pos.x + 2,
            slot0Pos.y + 1,
            button: MouseButton.wheelDown,
          );
        }
        await _settleTester(tester);
        check(
          _extractScreenText(tester.backend.buffer!),
        ).contains('SL Selection');
        check(
          _extractScreenText(tester.backend.buffer!),
        ).not((it) => it.contains('0  Black'));

        tester.sendKey(LogicalKey.enter);
        await _settleTester(tester);
        check(_extractScreenText(tester.backend.buffer!)).contains('0  Black');

        tester.sendKey(LogicalKey.escape);
        await _settleTester(tester);
        controller.dispose();
        await harness.dispose();
      });
    },
  );
}
