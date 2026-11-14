import 'dart:convert';
import 'dart:math';

import 'package:checks/checks.dart';
import 'package:termui/terminal/event.dart' as ev;
import 'package:termui_cast_client_core/termui_cast_client_core.dart';
import 'package:termui_cast_protocol/termui_cast_protocol.dart';
import 'package:termui_test/termui_test.dart';
import 'package:test/test.dart';

import 'support/fake_three_way_ws_harness.dart';

void main() {
  group('CastSceneController', () {
    test(
      'keeps ptyLayer focused on tab clicks and passes Ctrl+C, Tab, Shift+Tab, Esc, and SGR mouse to PTY',
      () {
        final tester = TerminalTester(size: const Point(80, 24));
        tester.run(() async {
          final harness = FakeThreeWayWsHarness();
          final shellA = await harness.startCaster(
            id: 'sess-1',
            title: 'build',
            enableMouseTracking: true,
          );
          final shellB = await harness.startCaster(
            id: 'sess-2',
            title: 'logs',
            enableMouseTracking: true,
          );
          final viewer = await harness.connectViewer();
          final controller = CastSceneController(
            terminal: tester.terminal,
            viewModel: viewer.viewModel,
          );

          for (var i = 0; i < 4; i++) {
            await tester.pump(const Duration(milliseconds: 20));
          }

          check(
            controller.sceneManager.focusedLayer,
          ).identicalTo(controller.ptyLayer);
          check(
            viewer.viewModel.activeSessionId,
          ).equals(const SessionId('sess-1'));

          // Click the second tab (" 2:logs ") in row 1 of the top dock bar.
          tester.mouseDown(14, 1);
          tester.mouseUp(14, 1);
          for (var i = 0; i < 3; i++) {
            await tester.pump(const Duration(milliseconds: 20));
          }

          check(
            viewer.viewModel.activeSessionId,
          ).equals(const SessionId('sess-2'));
          // Focus immediately returns to ptyLayer after clicking chromeLayer.
          check(
            controller.sceneManager.focusedLayer,
          ).identicalTo(controller.ptyLayer);

          // Send Ctrl+C, Ctrl+O (must not trigger termui's debug overlay!), Tab, Shift+Tab, and Esc; all must reach sess-2's PTY.
          tester.sendKey(LogicalKey.character('c'), control: true);
          tester.sendKey(LogicalKey.character('o'), control: true);
          tester.sendKey(LogicalKey.tab);
          tester.sendKey(LogicalKey.tab, shift: true);
          tester.sendKey(LogicalKey.escape);
          // Click inside PTY area at global (col=10, row=5) -> local PTY (10, 4).
          tester.mouseDown(10, 5);
          tester.mouseUp(10, 5);
          await tester.pump(const Duration(milliseconds: 20));

          final received = [
            for (final bytes in shellB.pty.writtenInputs) utf8.decode(bytes),
          ].join();
          check(received).contains('\x03');
          check(received).contains('\x0f');
          check(received).contains('\t');
          check(received).contains('\x1b[Z');
          check(received).contains('\x1b');
          check(received).contains('\x1b[<0;10;4M');
          check(shellA.pty.writtenInputs).isEmpty();

          controller.dispose();
          await harness.dispose();
        });
      },
    );

    test(
      r'handles Ctrl+\ leader chords on both TTY (\x1c) and Flutter KeyEvent shapes and forwards double Ctrl+\',
      () {
        final tester = TerminalTester(size: const Point(80, 24));
        tester.run(() async {
          final harness = FakeThreeWayWsHarness();
          final shellA = await harness.startCaster(id: 'alpha', title: 'alpha');
          await harness.startCaster(id: 'beta', title: 'beta');
          final viewer = await harness.connectViewer();
          final controller = CastSceneController(
            terminal: tester.terminal,
            viewModel: viewer.viewModel,
          );

          for (var i = 0; i < 4; i++) {
            await tester.pump(const Duration(milliseconds: 20));
          }

          check(viewer.viewModel.dockPosition).equals(DockPosition.top);
          check(controller.ptyLayer.height).equals(23);

          // TTY raw 0x1c + 'd' cycles dock: top -> left.
          tester.sendString('\x1cd');
          await tester.pump(const Duration(milliseconds: 20));
          check(viewer.viewModel.dockPosition).equals(DockPosition.left);
          check(controller.ptyLayer.x).equals(SessionDockBar.leftSidebarWidth);
          check(
            controller.ptyLayer.width,
          ).equals(80 - SessionDockBar.leftSidebarWidth);

          // Flutter KeyEvent shape Ctrl+\ followed by 'n' cycles to beta.
          controller.sceneManager.handleKeyEvent(
            const ev.KeyEvent(
              r'\',
              ev.KeyType.character,
              modifiers: {ev.Modifier.control},
            ),
          );
          controller.sceneManager.handleKeyEvent(
            const ev.KeyEvent('n', ev.KeyType.character),
          );
          for (var i = 0; i < 3; i++) {
            await tester.pump(const Duration(milliseconds: 20));
          }
          check(
            viewer.viewModel.activeSessionId,
          ).equals(const SessionId('beta'));

          // Switch back to alpha with leader + '1', then send double Ctrl+\ -> literal 0x1c.
          tester.sendString('\x1c1');
          await tester.pump(const Duration(milliseconds: 20));
          check(
            viewer.viewModel.activeSessionId,
          ).equals(const SessionId('alpha'));

          tester.sendString('\x1c\x1c');
          await tester.pump(const Duration(milliseconds: 20));
          check(shellA.pty.writtenInputs).isNotEmpty();
          check(shellA.pty.writtenInputs.last).deepEquals(const [0x1c]);

          controller.dispose();
          await harness.dispose();
        });
      },
    );

    test(
      'sizes renderers on initial 100x30 top and left layouts and clips wide CJK/emoji labels by display width',
      () {
        // 1. Initial 100x30 with top dock renders full 100-column bar immediately.
        final topTester = TerminalTester(size: const Point(28, 8));
        topTester.run(() async {
          final harness = FakeThreeWayWsHarness();
          await harness.startCaster(
            id: 'wide-1',
            title: '日本語🚀',
            initialCols: 28,
            initialRows: 7,
          );
          await harness.startCaster(
            id: 'wide-2',
            title: 'テスト🎉長いタイトル',
            initialCols: 28,
            initialRows: 7,
          );
          final viewer = await harness.connectViewer(
            initialDockPosition: .top,
            initialViewportCols: 28,
            initialViewportRows: 7,
          );
          final controller = CastSceneController(
            terminal: topTester.terminal,
            viewModel: viewer.viewModel,
          );

          for (var i = 0; i < 4; i++) {
            await topTester.pump(const Duration(milliseconds: 20));
          }

          check(controller.dockRenderer.currentBuffer!.width).equals(28);
          check(controller.ptyRenderer.currentBuffer!.width).equals(28);
          check(controller.ptyRenderer.currentBuffer!.height).equals(7);
          // [Dock] toggle at columns 22..27 must never be overwritten by wide graphemes.
          final topBuffer = topTester.backend.buffer!;
          check(topBuffer.getCharacter(22, 0)).equals('[');
          check(topBuffer.getCharacter(27, 0)).equals(']');

          // Tab 1 (" 1:日本語🚀 ") spans 12 display cols (0..11), gap at 12, Tab 2 starts at col 13 (1-based 14).
          topTester.mouseDown(15, 1);
          topTester.mouseUp(15, 1);
          for (var i = 0; i < 3; i++) {
            await topTester.pump(const Duration(milliseconds: 20));
          }
          check(
            viewer.viewModel.activeSessionId,
          ).equals(const SessionId('wide-2'));

          controller.dispose();
          await harness.dispose();
        });

        // 2. Initial 100x30 with DockPosition.left renders full-height sidebar and preserves '│' border.
        final leftTester = TerminalTester(size: const Point(100, 30));
        leftTester.run(() async {
          final harness = FakeThreeWayWsHarness();
          await harness.startCaster(
            id: 'left-1',
            title: '日本語🚀ビルド長い名前テスト',
            initialCols: 78,
            initialRows: 30,
          );
          await harness.startCaster(
            id: 'left-2',
            title: 'ログ🎉監視セッション',
            initialCols: 78,
            initialRows: 30,
          );
          final viewer = await harness.connectViewer(
            initialDockPosition: .left,
            initialViewportCols: 78,
            initialViewportRows: 30,
          );
          final controller = CastSceneController(
            terminal: leftTester.terminal,
            viewModel: viewer.viewModel,
          );

          for (var i = 0; i < 4; i++) {
            await leftTester.pump(const Duration(milliseconds: 20));
          }

          check(
            controller.dockRenderer.currentBuffer!.width,
          ).equals(SessionDockBar.leftSidebarWidth);
          check(controller.dockRenderer.currentBuffer!.height).equals(30);
          check(controller.ptyRenderer.currentBuffer!.width).equals(78);
          check(controller.ptyRenderer.currentBuffer!.height).equals(30);

          // Border column 21 stays intact across header, divider, and wide-grapheme tab rows.
          final leftBuffer = leftTester.backend.buffer!;
          check(leftBuffer.getCharacter(21, 0)).equals('│');
          check(leftBuffer.getCharacter(21, 1)).equals('┤');
          check(leftBuffer.getCharacter(21, 2)).equals('│');
          check(leftBuffer.getCharacter(21, 3)).equals('│');

          // Click row 4 (1-based y=4 -> 0-based row 3, second session) in initial left sidebar.
          leftTester.mouseDown(5, 4);
          leftTester.mouseUp(5, 4);
          for (var i = 0; i < 3; i++) {
            await leftTester.pump(const Duration(milliseconds: 20));
          }
          check(
            viewer.viewModel.activeSessionId,
          ).equals(const SessionId('left-2'));

          controller.dispose();
          await harness.dispose();
        });
      },
    );

    test(
      'displays auth error banner across dock modes and reconnects via Enter, banner click, or Ctrl+\\ c',
      () {
        final tester = TerminalTester(size: const Point(80, 24));
        tester.run(() async {
          final harness = FakeThreeWayWsHarness(token: 'expected-secret');
          await harness.startCaster(id: 'sess-1', title: 'zsh');

          final viewer = await harness.connectViewer(
            clientToken: 'wrong-token',
            resizeDebounce: Duration.zero,
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

          String rowText(int y) {
            final buf = tester.backend.buffer!;
            return [
              for (var x = 0; x < buf.width; x++) buf.getCharacter(x, y),
            ].join();
          }

          await settle();
          check(viewer.viewModel.connectionState).equals(.authFailed);
          check(rowText(0)).contains('Auth failed: Invalid bearer token');
          check(rowText(0)).not((it) => it.contains('No active sessions'));
          check(rowText(0)).not((it) => it.contains('wrong-token'));

          // Even when dock is hidden or left, attention banner stays visible.
          viewer.viewModel.setDockPosition(.hidden);
          await settle();
          check(rowText(0)).contains('Auth failed');

          viewer.viewModel.setDockPosition(.left);
          await settle();
          check(rowText(2)).contains('Auth failed');

          viewer.viewModel.setDockPosition(.top);
          await settle();

          // Press Enter on the auth-failed workspace -> opens ConnectionPromptDialog!
          tester.sendKey(LogicalKey.enter);
          await settle();
          check(controller.isConnectionPromptOpen).isTrue();

          // Dismiss via Escape -> returns to workspace with banner intact.
          tester.sendKey(LogicalKey.escape);
          await settle();
          check(controller.isConnectionPromptOpen).isFalse();
          check(rowText(0)).contains('Auth failed');

          // Click the banner in row 0 -> re-opens ConnectionPromptDialog!
          tester.mouseDown(10, 1);
          tester.mouseUp(10, 1);
          await settle();
          check(controller.isConnectionPromptOpen).isTrue();

          // Tab into Bearer Token field, clear wrong-token, enter expected-secret, and submit.
          tester.sendKey(LogicalKey.tab);
          await tester.pump(const Duration(milliseconds: 20));
          for (var i = 0; i < 'wrong-token'.length; i++) {
            tester.sendKey(LogicalKey.backspace);
          }
          tester.sendString('expected-secret');
          tester.sendKey(LogicalKey.enter);
          await settle();

          check(controller.isConnectionPromptOpen).isFalse();
          check(viewer.viewModel.connectionState).equals(.authenticated);
          check(
            viewer.viewModel.activeSessionId,
          ).equals(const SessionId('sess-1'));
          check(rowText(0)).contains('1:zsh');

          // Ctrl+\ + 'c' opens ConnectionPromptDialog even while a live session is active;
          // clicking the dimming barrier at (1, 1) dismisses it cleanly back to ptyLayer.
          tester.sendString('\x1cc');
          await settle();
          check(controller.isConnectionPromptOpen).isTrue();
          tester.mouseDown(1, 1);
          tester.mouseUp(1, 1);
          await settle();
          check(controller.isConnectionPromptOpen).isFalse();
          check(
            controller.sceneManager.focusedLayer,
          ).identicalTo(controller.ptyLayer);

          // Leader shortcuts cycle dock (top -> left -> hidden -> top), cycle sessions,
          // and auto-hide left sidebar when terminal narrows below 6 cols.
          tester.sendString('\x1cd');
          await settle();
          check(viewer.viewModel.dockPosition).equals(.left);
          tester.backend.size = const Point(5, 24);
          await settle();
          check(
            controller.sceneManager.layers.contains(controller.chromeLayer),
          ).isFalse();
          tester.backend.size = const Point(80, 24);
          await settle();
          check(
            controller.sceneManager.layers.contains(controller.chromeLayer),
          ).isTrue();

          tester.sendString('\x1cd');
          tester.sendString('\x1cd');
          tester.sendString('\x1cp');
          tester.sendString('\x1c');
          tester.sendKey(LogicalKey.tab);
          await settle();
          check(viewer.viewModel.dockPosition).equals(.top);

          controller.dispose();
          await harness.dispose();
        });
      },
    );

    test(
      'routes mouse selection, copy/paste chords, OSC 52 writes, and blocked-read notices end-to-end',
      () {
        final tester = TerminalTester(size: const Point(80, 24));
        return tester.run(() async {
          final harness = FakeThreeWayWsHarness();
          final caster = await harness.startCaster(id: 'sess-1', title: 'tmux');
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

          String rowText(int y) {
            final buf = tester.backend.buffer!;
            final sb = StringBuffer();
            for (var x = 0; x < buf.width; x++) {
              sb.write(buf.getCharacter(x, y));
            }
            return '$sb';
          }

          await settle();

          // 1. Remote PTY prints text and enables bracketed paste (?2004h).
          caster.pty.emitRawAnsi(
            '\x1b[?2004h\x1b[Hselect-me   col2\r\nrow-two     val2',
          );
          await settle();
          check(viewer.viewModel.activeModes.bracketedPaste).isTrue();

          // 2. Toggle copy-on-select via Ctrl+\ o -> shows notice in top bar, then toggle back on.
          tester.sendString('\x1co');
          await settle();
          check(viewer.viewModel.copyOnSelect).isFalse();
          check(rowText(0)).contains('Copy-on-select: OFF');

          tester.sendString('\x1co');
          await settle();
          check(viewer.viewModel.copyOnSelect).isTrue();
          check(rowText(0)).contains('1:tmux');
          check(rowText(0)).contains('Copy-on-select: ON');

          // Click the inline notice span (after ' 1:tmux ') in row 0 to dismiss it.
          tester.mouseDown(25, 1);
          tester.mouseUp(25, 1);
          await settle();
          check(viewer.viewModel.clipboardNotice).isNull();

          // 3. Drag on ptyLayer (row 2 in global coordinates = row 0 in PTY) from col 1 to col 9
          //    to select 'select-me'. Because copyOnSelect is true, release writes OSC 52 to terminal.
          tester.backend.writes.clear();
          tester.mouseDown(1, 2);
          controller.sceneManager.handleMouseEvent(
            const ev.MouseEvent(
              x: 9,
              y: 2,
              button: ev.MouseButton.left,
              type: ev.MouseEventType.drag,
            ),
          );
          tester.mouseUp(9, 2);
          await settle();
          check(viewer.viewModel.lastCopiedText).equals('select-me');
          final expectedOsc52 =
              '\x1b]52;c;${base64.encode(utf8.encode('select-me'))}\x1b\\';
          check(
            tester.backend.writes.any((w) => w.contains(expectedOsc52)),
          ).isTrue();

          // 4. Ctrl+\ y and Cmd+C also copy active selection.
          tester.backend.writes.clear();
          tester.sendString('\x1cy');
          await settle();
          check(
            tester.backend.writes.any((w) => w.contains(expectedOsc52)),
          ).isTrue();

          tester.backend.writes.clear();
          controller.sceneManager.handleKeyEvent(
            const ev.KeyEvent(
              'c',
              ev.KeyType.character,
              modifiers: {ev.Modifier.meta},
            ),
          );
          await settle();
          check(
            tester.backend.writes.any((w) => w.contains(expectedOsc52)),
          ).isTrue();

          // 5. Ctrl+\ v and Cmd+V emit OSC 52 paste request ('\x1b]52;c;?\x1b\\'),
          //    and PasteEvent sends bracketed paste to remote PTY.
          tester.backend.writes.clear();
          tester.sendString('\x1cv');
          await settle();
          check(
            tester.backend.writes.any((w) => w.contains('\x1b]52;c;?\x1b\\')),
          ).isTrue();

          caster.pty.writtenInputs.clear();
          controller.sceneManager.handlePasteEvent(
            const ev.PasteEvent('pasted\nline'),
          );
          await settle();
          final ptyReceived = [
            for (final chunk in caster.pty.writtenInputs) utf8.decode(chunk),
          ].join();
          check(ptyReceived).equals('\x1b[200~pasted\rline\x1b[201~');

          // 6. Remote PTY emits OSC 52 clipboard write -> forwarded to client terminal.setClipboard.
          tester.backend.writes.clear();
          final remotePayload = base64.encode(utf8.encode('tmux-yank-buffer'));
          caster.pty.emitRawAnsi('\x1b]52;c;$remotePayload\x07');
          await settle();
          check(viewer.viewModel.lastCopiedText).equals('tmux-yank-buffer');
          check(
            tester.backend.writes.any(
              (w) => w.contains('\x1b]52;c;$remotePayload\x1b\\'),
            ),
          ).isTrue();

          // 7. Remote PTY attempts OSC 52 clipboard read ('\x1b]52;c;?\x07') -> blocked at caster,
          //    and client displays security warning banner in dock bar!
          caster.pty.emitRawAnsi('\x1b]52;c;?\x07');
          await settle();
          check(rowText(0)).contains('Blocked remote clipboard read');

          // 8. Shift+Insert triggers terminal.requestPaste() without forwarding Insert to PTY.
          tester.backend.writes.clear();
          caster.pty.writtenInputs.clear();
          controller.sceneManager.handleKeyEvent(
            const ev.KeyEvent(
              'insert',
              ev.KeyType.insert,
              modifiers: {ev.Modifier.shift},
            ),
          );
          await settle();
          check(
            tester.backend.writes.any((w) => w.contains('\x1b]52;c;?\x1b\\')),
          ).isTrue();
          check(caster.pty.writtenInputs).isEmpty();

          controller.dispose();
          await harness.dispose();
        });
      },
    );

    test(
      'preserves clickable tabs/rows during top and left dock notices, dismisses hidden-dock row-0 notice on click, and consumes unsubscribed/oversized PasteEvents',
      () {
        final tester = TerminalTester(size: const Point(80, 24));
        return tester.run(() async {
          final harness = FakeThreeWayWsHarness();
          final shellBuild = await harness.startCaster(
            id: 'sess-1',
            title: 'build',
            enableMouseTracking: true,
          );
          final shellLogs = await harness.startCaster(
            id: 'sess-2',
            title: 'logs',
            enableMouseTracking: true,
          );
          final viewer = await harness.connectViewer(
            resizeDebounce: Duration.zero,
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

          String rowText(int y) {
            final buf = tester.backend.buffer!;
            final sb = StringBuffer();
            for (var x = 0; x < buf.width; x++) {
              sb.write(buf.getCharacter(x, y));
            }
            return '$sb';
          }

          await settle();

          // 1. Top dock: notice renders after tabs so both tabs stay visible and clickable.
          tester.sendString('\x1co');
          await settle();
          check(viewer.viewModel.clipboardNotice).isNotNull();
          check(rowText(0)).contains('1:build');
          check(rowText(0)).contains('2:logs');
          check(rowText(0)).contains('Copy-on-select: OFF');

          // Click Tab 2 (" 2:logs ") while notice is active -> switches session without dismissing notice.
          tester.mouseDown(14, 1);
          tester.mouseUp(14, 1);
          await settle();
          check(
            viewer.viewModel.activeSessionId,
          ).equals(const SessionId('sess-2'));
          check(viewer.viewModel.clipboardNotice).isNotNull();

          // Click inline notice span (x = 30) -> dismisses notice while staying on sess-2.
          tester.mouseDown(30, 1);
          tester.mouseUp(30, 1);
          await settle();
          check(viewer.viewModel.clipboardNotice).isNull();
          check(
            viewer.viewModel.activeSessionId,
          ).equals(const SessionId('sess-2'));

          // Narrow top dock (< 24 remaining cols): notice overlays 0..maxTabX and click dismisses notice.
          tester.backend.size = const Point(36, 24);
          await settle();
          tester.sendString('\x1co');
          await settle();
          check(viewer.viewModel.clipboardNotice).isNotNull();
          tester.mouseDown(3, 1);
          tester.mouseUp(3, 1);
          await settle();
          check(viewer.viewModel.clipboardNotice).isNull();
          check(
            viewer.viewModel.activeSessionId,
          ).equals(const SessionId('sess-2'));

          tester.backend.size = const Point(80, 24);
          await settle();

          // 2. Left sidebar: blocked OSC 52 notice wraps across rows 2..3 while keeping sessions visible below.
          viewer.viewModel.setDockPosition(.left);
          await settle();
          shellLogs.pty.emitRawAnsi('\x1b]52;c;?\x07');
          await settle();
          check(viewer.viewModel.clipboardNotice).isNotNull();
          final leftBuf = tester.backend.buffer!;
          check(leftBuf.getCharacter(21, 2)).equals('│');
          check(leftBuf.getCharacter(21, 3)).equals('│');
          check(rowText(2).substring(0, 21)).contains('Blocked');
          check(rowText(3).substring(0, 21)).contains('clipboard read');
          check(rowText(4).substring(0, 21)).contains('1:build');
          check(rowText(5).substring(0, 21)).contains('2:logs');

          // Click '1:build' at row 4 (1-based y = 5) while notice is visible -> switches to sess-1.
          tester.mouseDown(5, 5);
          tester.mouseUp(5, 5);
          await settle();
          check(
            viewer.viewModel.activeSessionId,
          ).equals(const SessionId('sess-1'));
          check(viewer.viewModel.clipboardNotice).isNotNull();

          // Click notice row 2 (1-based y = 3) -> dismisses notice.
          tester.mouseDown(5, 3);
          tester.mouseUp(5, 3);
          await settle();
          check(viewer.viewModel.clipboardNotice).isNull();

          // 3. Hidden dock: row 0 (1-based y = 1) click dismisses notice without forwarding mouse to PTY.
          viewer.viewModel.setDockPosition(.hidden);
          await settle();
          shellBuild.pty.emitRawAnsi('\x1b]52;c;?\x07');
          await settle();
          check(viewer.viewModel.clipboardNotice).isNotNull();
          check(rowText(0)).contains('Blocked remote clipboard read');

          shellBuild.pty.writtenInputs.clear();
          tester.mouseDown(6, 1);
          tester.mouseUp(6, 1);
          await settle();
          check(viewer.viewModel.clipboardNotice).isNull();
          check(viewer.viewModel.activeSelection).isNull();
          check(shellBuild.pty.writtenInputs).isEmpty();

          // 4. RemotePtySceneRenderer.handlePasteEvent always returns true (even oversized or unsubscribed)
          //    so SceneManager never synthesizes per-character KeyEvents.
          shellBuild.pty.writtenInputs.clear();
          check(
            controller.ptyRenderer.handlePasteEvent(
              ev.PasteEvent('z' * (CastWorkspaceViewModel.maxPasteBytes + 1)),
            ),
          ).isTrue();
          controller.sceneManager.handlePasteEvent(
            ev.PasteEvent('z' * (CastWorkspaceViewModel.maxPasteBytes + 1)),
          );
          await settle();
          check(shellBuild.pty.writtenInputs).isEmpty();
          check(
            viewer.viewModel.clipboardNotice,
          ).isNotNull().contains('exceeds 1 MiB');
          viewer.viewModel.dismissClipboardNotice();

          await shellBuild.pty.finish(0);
          await shellLogs.pty.finish(0);
          await settle();
          check(
            viewer.viewModel.activeSessionSyncState,
          ).equals(ClientSessionSyncState.unsubscribed);
          check(
            controller.ptyRenderer.handlePasteEvent(
              const ev.PasteEvent('\x1cd'),
            ),
          ).isTrue();
          controller.sceneManager.handlePasteEvent(
            const ev.PasteEvent('\x1cd'),
          );
          await settle();
          // Dock position must remain hidden (no fallback KeyEvent synthesized for '\x1cd').
          check(viewer.viewModel.dockPosition).equals(DockPosition.hidden);

          controller.dispose();
          await harness.dispose();
        });
      },
    );

    test(
      'scrolls primary scrollback via wheel/Shift+PageUp/Home/End, pins viewport on live PTY output, copies wrapped virtual selection, and snaps to bottom on [↑N] pill or keystroke',
      () {
        final tester = TerminalTester(size: const Point(60, 12));
        return tester.run(() async {
          final harness = FakeThreeWayWsHarness();
          // 60 cols x 11 PTY rows (row 0 is top dock bar; width >= 52 renders [↑N] pill).
          final caster = await harness.startCaster(
            id: 'sess-sb',
            title: 'zsh',
            initialCols: 60,
            initialRows: 11,
          );
          final viewer = await harness.connectViewer(
            initialViewportCols: 60,
            initialViewportRows: 11,
            resizeDebounce: Duration.zero,
          );
          final controller = CastSceneController(
            terminal: tester.terminal,
            viewModel: viewer.viewModel,
          );

          Future<void> settle() async {
            for (var i = 0; i < 6; i++) {
              await tester.pump(const Duration(milliseconds: 20));
            }
          }

          String rowText(int y) {
            final buf = tester.backend.buffer!;
            return [
              for (var x = 0; x < buf.width; x++) buf.getCharacter(x, y),
            ].join();
          }

          await settle();

          // Clear initial harness box & scrollback, then emit 25 numbered lines + a soft-wrapped 72-char line -> >15 lines in scrollback.
          caster.pty.emitRawAnsi('\x1b[3J\x1b[H\x1b[2J');
          for (var i = 0; i < 25; i++) {
            caster.pty.emitRawAnsi('LINE-${'$i'.padLeft(2, '0')}\r\n');
          }
          caster.pty.emitRawAnsi(
            'https://example.com/very-long-wrapped-url-1234567890-abcdef-ghijkl-mnop\r\n',
          );
          caster.pty.emitRawAnsi('zsh% ');
          await settle();

          check(viewer.viewModel.activeScrollOffsetLines).equals(0);
          check(
            viewer.viewModel.activeRetainedScrollbackLines,
          ).isGreaterThan(15);

          // 1. Shift+Home jumps to oldest scrollback line (LINE-00) and renders [↑N] pill + '▐' thumb!
          controller.sceneManager.handleKeyEvent(
            const ev.KeyEvent(
              'home',
              ev.KeyType.home,
              modifiers: {ev.Modifier.shift},
            ),
          );
          await settle();

          final pinnedOffset = viewer.viewModel.activeScrollOffsetLines;
          check(
            pinnedOffset,
          ).equals(viewer.viewModel.activeRetainedScrollbackLines);
          check(rowText(0)).contains('[↑$pinnedOffset]');
          check(rowText(1)).startsWith('LINE-00');
          // Rightmost column shows scrollbar thumb '▐'.
          check(tester.backend.buffer!.getCharacter(59, 1)).equals('▐');

          // 2. While pinned at top, new PTY output advances offset to keep LINE-00 pinned!
          caster.pty.emitRawAnsi('NEW-OUTPUT-LINE\r\nzsh% ');
          await settle();
          check(
            viewer.viewModel.activeScrollOffsetLines,
          ).equals(pinnedOffset + 1);
          check(rowText(1)).startsWith('LINE-00');

          // 3. Scroll down with mouse wheelDown (3 lines per notch) -> shows LINE-03 at top!
          controller.sceneManager.handleMouseEvent(
            const ev.MouseEvent(
              x: 5,
              y: 3,
              button: ev.MouseButton.wheelDown,
              type: ev.MouseEventType.press,
            ),
          );
          await settle();
          check(rowText(1)).startsWith('LINE-03');

          // 4. Drag selection across LINE-03 and LINE-04 -> copies 'LINE-03\nLINE-04'!
          tester.mouseDown(1, 2); // screen row 1 (1-based y=2) = LINE-03
          controller.sceneManager.handleMouseEvent(
            const ev.MouseEvent(
              x: 7,
              y: 3, // screen row 2 (1-based y=3) = LINE-04
              button: ev.MouseButton.left,
              type: ev.MouseEventType.drag,
            ),
          );
          tester.mouseUp(7, 3);
          await settle();
          check(viewer.viewModel.lastCopiedText).equals('LINE-03\nLINE-04');

          // 5. Typing a key snaps back to live bottom and forwards the key to PTY!
          caster.pty.writtenInputs.clear();
          tester.sendString('x');
          await settle();
          check(viewer.viewModel.activeScrollOffsetLines).equals(0);
          check(utf8.decode(caster.pty.writtenInputs.single)).equals('x');

          // 6. Scroll up again via Shift+PageUp, then click [↑N] pill in top dock to snap to bottom!
          controller.sceneManager.handleKeyEvent(
            const ev.KeyEvent(
              'pageUp',
              ev.KeyType.pageUp,
              modifiers: {ev.Modifier.shift},
            ),
          );
          await settle();
          final afterPgUpOffset = viewer.viewModel.activeScrollOffsetLines;
          check(afterPgUpOffset).isGreaterThan(0);
          final pillLabel = '[↑$afterPgUpOffset]';
          final pillCol = rowText(0).indexOf(pillLabel);
          check(pillCol).isGreaterOrEqual(0);
          tester.mouseDown(pillCol + 2, 1);
          tester.mouseUp(pillCol + 2, 1);
          await settle();
          check(viewer.viewModel.activeScrollOffsetLines).equals(0);

          // 7. CSI 3 J (clear scrollback) resets retained lines & offset to 0!
          controller.sceneManager.handleKeyEvent(
            const ev.KeyEvent(
              'pageUp',
              ev.KeyType.pageUp,
              modifiers: {ev.Modifier.shift},
            ),
          );
          await settle();
          check(viewer.viewModel.activeScrollOffsetLines).isGreaterThan(0);
          caster.pty.emitRawAnsi('\x1b[3J');
          await settle();
          check(viewer.viewModel.activeRetainedScrollbackLines).equals(0);
          check(viewer.viewModel.activeScrollOffsetLines).equals(0);

          controller.dispose();
          await harness.dispose();
        });
      },
    );

    test(
      'copies unbroken soft-wrapped URLs in scrollback, on the live screen (preserving wrap-margin space), and across the scrollback-to-live-row-0 seam',
      () {
        final tester = TerminalTester(size: const Point(60, 12));
        return tester.run(() async {
          final harness = FakeThreeWayWsHarness();
          // 60 cols x 11 PTY rows (row 0 is top dock bar).
          final caster = await harness.startCaster(
            id: 'sess-wrap',
            title: 'zsh',
            initialCols: 60,
            initialRows: 11,
          );
          final viewer = await harness.connectViewer(
            initialViewportCols: 60,
            initialViewportRows: 11,
            resizeDebounce: Duration.zero,
          );
          final controller = CastSceneController(
            terminal: tester.terminal,
            viewModel: viewer.viewModel,
          );

          Future<void> settle() async {
            for (var i = 0; i < 6; i++) {
              await tester.pump(const Duration(milliseconds: 20));
            }
          }

          String rowText(int y) {
            final buf = tester.backend.buffer!;
            return [
              for (var x = 0; x < buf.width; x++) buf.getCharacter(x, y),
            ].join();
          }

          await settle();
          caster.pty.emitRawAnsi('\x1b[3J\x1b[H\x1b[2J');

          // 1. Live screen soft-wrap with trailing space right at column 60 ('git clone ' padded to col 60 + URL).
          final prefixWithWrapSpace = '${'a' * 49} git clone ';
          check(prefixWithWrapSpace.length).equals(60);
          const liveUrl = 'https://example.com/live-soft-wrap-repo.git';
          caster.pty.emitRawAnsi('$prefixWithWrapSpace$liveUrl\r\n');
          await settle();

          // Drag from col 51 ('g' of 'git clone ') on PTY row 0 (screen y=2) to end of URL on PTY row 1 (screen y=3).
          tester.mouseDown(51, 2);
          controller.sceneManager.handleMouseEvent(
            ev.MouseEvent(
              x: liveUrl.length,
              y: 3,
              button: ev.MouseButton.left,
              type: ev.MouseEventType.drag,
            ),
          );
          tester.mouseUp(liveUrl.length, 3);
          await settle();
          check(viewer.viewModel.lastCopiedText).equals('git clone $liveUrl');

          // 2. Scrollback soft-wrapped URL + Seam soft-wrapped URL (first 60 chars in scrollback[totalLines-1], tail on live row 0!).
          caster.pty.emitRawAnsi('\x1b[3J\x1b[H\x1b[2J');
          const sbUrl =
              'https://example.com/scrollback-wrapped-url-0123456789-abcdefghijklmnop';
          caster.pty.emitRawAnsi('$sbUrl\r\n');
          // Now row 0..1 has sbUrl (2 rows). Emit 8 filler lines (rows 2..9).
          for (var i = 0; i < 8; i++) {
            caster.pty.emitRawAnsi('FILL-$i\r\n');
          }
          // Cursor is now on PTY row 10 (bottom row of 11-row PTY).
          // Emitting an 85-char URL without trailing \r\n wraps once at col 60, scrolling 1 row so:
          // - sbUrl rows + FILL-0..6 are in scrollback (with sbUrl wholly in scrollback)
          // - seamUrl[0..60) is evicted to scrollback[totalLines - 1], while seamUrl[60..85) stays on live row 9?
          // Wait: to put seamUrl[0..60) at scrollback[totalLines - 1] and seamUrl[60..85) at live row 0,
          // emit seamUrl followed by 9 newlines so live row 0 IS seamUrl[60..85)!
          const seamUrl =
              'https://example.com/seam-wrapped-url-across-scrollback-and-live-row-zero-1234567890';
          check(seamUrl.length).equals(83);
          caster.pty.emitRawAnsi('$seamUrl\r\n');
          for (var i = 0; i < 9; i++) {
            caster.pty.emitRawAnsi('TAIL-$i\r\n');
          }
          caster.pty.emitRawAnsi('zsh% ');
          await settle();

          // Live row 0 (screen y=2) must now hold the 23-char wrapped tail of seamUrl!
          check(rowText(1)).startsWith(seamUrl.substring(60));

          // Scroll up 1 line via Shift+Up? At offset=0 only Shift+PgUp/Home/Wheel enters scrollback; scroll up 3 lines via wheelUp!
          controller.sceneManager.handleMouseEvent(
            const ev.MouseEvent(
              x: 5,
              y: 3,
              button: ev.MouseButton.wheelUp,
              type: ev.MouseEventType.press,
            ),
          );
          await settle();
          check(viewer.viewModel.activeScrollOffsetLines).equals(3);
          // At offset=3: screen y=3 (1-based y=4) is scrollback[totalLines - 1] (seamUrl[0..60)),
          // and screen y=4 (1-based y=5) is live row 0 (seamUrl[60..83))!
          check(rowText(3)).startsWith(seamUrl.substring(0, 30));
          check(rowText(4)).startsWith(seamUrl.substring(60));

          tester.mouseDown(1, 4);
          controller.sceneManager.handleMouseEvent(
            const ev.MouseEvent(
              x: 40,
              y: 5,
              button: ev.MouseButton.left,
              type: ev.MouseEventType.drag,
            ),
          );
          tester.mouseUp(40, 5);
          await settle();
          check(viewer.viewModel.lastCopiedText).equals(seamUrl);

          // Now jump to oldest scrollback via Home (Option B bare Home while scrolled!) and copy sbUrl across rows 0..1!
          controller.sceneManager.handleKeyEvent(
            const ev.KeyEvent('home', ev.KeyType.home),
          );
          await settle();
          check(rowText(1)).startsWith(sbUrl.substring(0, 30));
          tester.mouseDown(1, 2);
          controller.sceneManager.handleMouseEvent(
            const ev.MouseEvent(
              x: 30,
              y: 3,
              button: ev.MouseButton.left,
              type: ev.MouseEventType.drag,
            ),
          );
          tester.mouseUp(30, 3);
          await settle();
          check(viewer.viewModel.lastCopiedText).equals(sbUrl);

          controller.dispose();
          await harness.dispose();
        });
      },
    );

    test(
      'supports Option B scroll/pan keys, [↑N →M] top & left dock pills, Esc snap without PTY leak, width-shrink 100->60 wide copy, and timer-paced drag auto-scroll',
      () {
        final tester = TerminalTester(size: const Point(100, 12));
        return tester.run(() async {
          final harness = FakeThreeWayWsHarness();
          final caster = await harness.startCaster(
            id: 'sess-pan',
            title: 'zsh',
            initialCols: 100,
            initialRows: 11,
          );
          final viewer = await harness.connectViewer(
            initialViewportCols: 100,
            initialViewportRows: 11,
            resizeDebounce: Duration.zero,
          );
          final controller = CastSceneController(
            terminal: tester.terminal,
            viewModel: viewer.viewModel,
          );

          Future<void> settle() async {
            for (var i = 0; i < 6; i++) {
              await tester.pump(const Duration(milliseconds: 20));
            }
          }

          String rowText(int y) {
            final buf = tester.backend.buffer!;
            return [
              for (var x = 0; x < buf.width; x++) buf.getCharacter(x, y),
            ].join();
          }

          await settle();
          caster.pty.emitRawAnsi('\x1b[3J\x1b[H\x1b[2J');

          // Emit a 90-col single line + a 128-col soft-wrapped URL at width=100, then push both into scrollback!
          final wideLine90 =
              'WIDE-START-${'0123456789' * 7}-END90abc'; // 90 chars
          check(wideLine90.length).equals(90);
          final wrappedAt100Url =
              'https://example.com/${'w' * 80}/tail-after-100-col-wrap-xyz';
          check(wrappedAt100Url.length).equals(128);

          caster.pty.emitRawAnsi('$wideLine90\r\n');
          caster.pty.emitRawAnsi('$wrappedAt100Url\r\n');
          for (var i = 0; i < 20; i++) {
            caster.pty.emitRawAnsi('ROW-${'$i'.padLeft(2, '0')}\r\n');
          }
          caster.pty.emitRawAnsi('zsh% ');
          await settle();

          // Shrink terminal width 100 -> 60!
          tester.backend.size = const Point(60, 12);
          await settle();
          check(viewer.viewModel.viewportCols).equals(60);

          // At offset=0, bare Up/Right/Esc go straight to PTY without scrolling!
          caster.pty.writtenInputs.clear();
          controller.sceneManager.handleKeyEvent(
            const ev.KeyEvent('escape', ev.KeyType.escape),
          );
          await settle();
          check(viewer.viewModel.activeScrollOffsetLines).equals(0);
          check(utf8.decode(caster.pty.writtenInputs.single)).equals('\x1b');
          caster.pty.writtenInputs.clear();

          // Enter scrollback via Shift+Home -> jumps to wideLine90 + wrappedAt100Url at top!
          controller.sceneManager.handleKeyEvent(
            const ev.KeyEvent(
              'home',
              ev.KeyType.home,
              modifiers: {ev.Modifier.shift},
            ),
          );
          await settle();
          final topOffset = viewer.viewModel.activeScrollOffsetLines;
          check(topOffset).isGreaterThan(10);
          check(rowText(0)).contains('[↑$topOffset]');
          check(rowText(1)).startsWith('WIDE-START-');

          // Option B: bare Right (+1) and Shift+Right (+8) pan horizontally up to 100 - 60 = 40 cols!
          controller.sceneManager.handleKeyEvent(
            const ev.KeyEvent('right', ev.KeyType.right),
          );
          controller.sceneManager.handleKeyEvent(
            const ev.KeyEvent(
              'right',
              ev.KeyType.right,
              modifiers: {ev.Modifier.shift},
            ),
          );
          await settle();
          check(viewer.viewModel.activeScrollOffsetCols).equals(9);
          check(rowText(0)).contains('[↑$topOffset →9]');
          check(rowText(1)).startsWith(wideLine90.substring(9, 30));

          // Pan all the way right via 5x Shift+Right -> clamps at 40 ('100 - 60')!
          for (var i = 0; i < 5; i++) {
            controller.sceneManager.handleKeyEvent(
              const ev.KeyEvent(
                'right',
                ev.KeyType.right,
                modifiers: {ev.Modifier.shift},
              ),
            );
          }
          await settle();
          check(viewer.viewModel.activeScrollOffsetCols).equals(40);
          check(rowText(0)).contains('[↑$topOffset →40]');
          // wideLine90[40..90] is 50 chars, followed by blank cells (and '▐' thumb at col 59).
          check(
            rowText(1).substring(0, 50),
          ).equals(wideLine90.substring(40, 90));
          check(rowText(1).substring(50, 58)).equals(' ' * 8);
          check(
            rowText(2).substring(0, 59),
          ).equals(wrappedAt100Url.substring(40, 99));

          // Bare Left (-1) and Shift+Left (-8) pan back left -> 40 - 9 = 31; then pan back to 0.
          controller.sceneManager.handleKeyEvent(
            const ev.KeyEvent('left', ev.KeyType.left),
          );
          controller.sceneManager.handleKeyEvent(
            const ev.KeyEvent(
              'left',
              ev.KeyType.left,
              modifiers: {ev.Modifier.shift},
            ),
          );
          await settle();
          check(viewer.viewModel.activeScrollOffsetCols).equals(31);
          for (var i = 0; i < 4; i++) {
            controller.sceneManager.handleKeyEvent(
              const ev.KeyEvent(
                'left',
                ev.KeyType.left,
                modifiers: {ev.Modifier.shift},
              ),
            );
          }
          await settle();
          check(viewer.viewModel.activeScrollOffsetCols).equals(0);

          // Copy wrappedAt100Url (on PTY rows 1..2 -> 1-based screen y=3..4) while narrowed at 60 cols ->
          // M12 must include all 100 chars of wrapped row 1 + 28 chars of row 2 without truncation!
          tester.mouseDown(1, 3);
          controller.sceneManager.handleMouseEvent(
            const ev.MouseEvent(
              x: 40,
              y: 4,
              button: ev.MouseButton.left,
              type: ev.MouseEventType.drag,
            ),
          );
          tester.mouseUp(40, 4);
          await settle();
          check(viewer.viewModel.lastCopiedText).equals(wrappedAt100Url);

          // Bare Down scrolls down 1 line; Bare Up scrolls up 1 line; Bare Esc snaps cleanly to bottom with 0 PTY bytes!
          controller.sceneManager.handleKeyEvent(
            const ev.KeyEvent('down', ev.KeyType.down),
          );
          await settle();
          check(viewer.viewModel.activeScrollOffsetLines).equals(topOffset - 1);
          controller.sceneManager.handleKeyEvent(
            const ev.KeyEvent('up', ev.KeyType.up),
          );
          await settle();
          check(viewer.viewModel.activeScrollOffsetLines).equals(topOffset);
          check(caster.pty.writtenInputs).isEmpty();

          controller.sceneManager.handleKeyEvent(
            const ev.KeyEvent('escape', ev.KeyType.escape),
          );
          await settle();
          check(viewer.viewModel.activeScrollOffsetLines).equals(0);
          check(viewer.viewModel.activeScrollOffsetCols).equals(0);
          check(caster.pty.writtenInputs).isEmpty();

          // Left dock bar (m6) renders clickable [↑N →M] pill and Ctrl+\ \x07 (n2) also snaps to bottom!
          controller.sceneManager.handleKeyEvent(
            const ev.KeyEvent(
              'home',
              ev.KeyType.home,
              modifiers: {ev.Modifier.shift},
            ),
          );
          controller.sceneManager.handleKeyEvent(
            const ev.KeyEvent('right', ev.KeyType.right),
          );
          viewer.viewModel.setDockPosition(.left);
          await settle();
          final leftRow2 = rowText(2);
          check(leftRow2).contains('[↑');
          check(leftRow2).contains('→1]');
          tester.mouseDown(3, 3);
          tester.mouseUp(3, 3);
          await settle();
          check(viewer.viewModel.activeScrollOffsetLines).equals(0);
          check(viewer.viewModel.activeScrollOffsetCols).equals(0);

          viewer.viewModel.setDockPosition(.top);
          controller.sceneManager.handleKeyEvent(
            const ev.KeyEvent(
              'pageUp',
              ev.KeyType.pageUp,
              modifiers: {ev.Modifier.shift},
            ),
          );
          await settle();
          check(viewer.viewModel.activeScrollOffsetLines).isGreaterThan(0);
          tester.sendString('\x1c\x07');
          await settle();
          check(viewer.viewModel.activeScrollOffsetLines).equals(0);

          // M11: Timer-paced drag-to-edge auto-scroll (~80ms periodic timer, 0 synchronous scrolls on x-drag)!
          tester.mouseDown(
            5,
            6,
          ); // anchor on interior PTY row (1-based y=6 in top dock -> PTY y=5)
          // Drag to top PTY row (screen y=2 -> PTY local y=1) and move horizontally across x=5..15 with 0 time elapsed!
          for (var x = 5; x <= 15; x++) {
            controller.sceneManager.handleMouseEvent(
              ev.MouseEvent(
                x: x,
                y: 2,
                button: ev.MouseButton.left,
                type: ev.MouseEventType.drag,
              ),
            );
          }
          check(viewer.viewModel.activeScrollOffsetLines).equals(0);

          // Elapse 250ms (~3 ticks of 80ms) -> auto-scrolls up ~3 lines smoothly!
          await tester.pump(const Duration(milliseconds: 250));
          final autoScrolledUp = viewer.viewModel.activeScrollOffsetLines;
          check(autoScrolledUp).isGreaterOrEqual(2);
          check(autoScrolledUp).isLessOrEqual(4);

          // Drag to bottom PTY row (screen y=12 -> PTY local y=11 == maxRows) -> auto-scrolls back down!
          controller.sceneManager.handleMouseEvent(
            const ev.MouseEvent(
              x: 10,
              y: 12,
              button: ev.MouseButton.left,
              type: ev.MouseEventType.drag,
            ),
          );
          await tester.pump(const Duration(milliseconds: 250));
          check(
            viewer.viewModel.activeScrollOffsetLines,
          ).isLessThan(autoScrolledUp);

          tester.mouseUp(10, 12);
          await tester.pump(const Duration(milliseconds: 250));
          final afterRelease = viewer.viewModel.activeScrollOffsetLines;
          await tester.pump(const Duration(milliseconds: 250));
          check(viewer.viewModel.activeScrollOffsetLines).equals(afterRelease);

          // Hovering a URL with Ctrl sets pointer cursor, modal opens reset it,
          // and closing modal restores it while still hovering.
          viewer.viewModel.onOpenUrl = (_) {};
          caster.pty.emitRawAnsi(
            '\x1b[2J\x1b[HVisit https://dart.dev/get-dart now\r\n',
          );
          await settle();
          tester.backend.writes.clear();
          controller.sceneManager.handleMouseEvent(
            const ev.MouseEvent(
              x: 10,
              y: 2,
              button: ev.MouseButton.none,
              type: ev.MouseEventType.move,
              modifiers: {ev.Modifier.control},
            ),
          );
          await tester.pump(const Duration(milliseconds: 60));
          check(
            viewer.viewModel.hoveredUrl,
          ).equals(Uri.parse('https://dart.dev/get-dart'));
          check(
            tester.backend.writes.any(
              (w) => w.contains('\x1b]22;pointer\x1b\\'),
            ),
          ).isTrue();

          tester.backend.writes.clear();
          controller.openChordsHelp().ignore();
          await settle();
          check(controller.isChordsHelpOpen).isTrue();
          check(
            tester.backend.writes.any((w) => w.contains('\x1b]22;\x1b\\')),
          ).isTrue();

          tester.backend.writes.clear();
          tester.sendKey(LogicalKey.escape);
          await settle();
          check(controller.isChordsHelpOpen).isFalse();
          check(
            tester.backend.writes.any(
              (w) => w.contains('\x1b]22;pointer\x1b\\'),
            ),
          ).isTrue();

          tester.backend.writes.clear();
          controller.dispose();
          check(
            tester.backend.writes.any((w) => w.contains('\x1b]22;\x1b\\')),
          ).isTrue();
          await harness.dispose();
        });
      },
    );
  });
}
