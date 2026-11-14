@TestOn('vm')
library;

import 'dart:isolate';
import 'dart:math';

import 'package:checks/checks.dart';
import 'package:path/path.dart' as p;
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

void main() {
  group('Three-way fake-WS resize and tab-switch ANSI goldens', () {
    test(
      'propagates resize and tab switching across CasterService <-> WsRelayHandler <-> WsClientTransport',
      () {
        final tester = TerminalTester(size: const Point(80, 24));
        tester.run(() async {
          final harness = FakeThreeWayWsHarness();
          final primary = await harness.startCaster(
            id: 'htop',
            title: 'htop',
            banner: 'Session 1: htop',
            initialCols: 80,
            initialRows: 23,
          );
          final secondary = await harness.startCaster(
            id: 'logs',
            title: 'server-logs',
            banner: 'Session 2: server-logs',
            initialCols: 80,
            initialRows: 23,
          );

          final viewer = await harness.connectViewer(
            initialDockPosition: .top,
            initialViewportCols: 80,
            initialViewportRows: 23,
          );
          final controller = CastSceneController(
            terminal: tester.terminal,
            viewModel: viewer.viewModel,
          );

          Future<void> settleFrames() async {
            for (var i = 0; i < 4; i++) {
              await tester.pump(const Duration(milliseconds: 25));
            }
          }

          await settleFrames();
          check(primary.pty.cols).equals(80);
          check(primary.pty.rows).equals(23);
          expect(
            tester.backend.buffer,
            matchesAnsiGolden(_goldenPath('resize_80x24_top.ansi')),
          );

          // 1. Click tab 2 (" 2:server-logs ") in top dock bar and capture switched tab golden.
          tester.mouseDown(12, 1);
          tester.mouseUp(12, 1);
          await settleFrames();
          check(
            viewer.viewModel.activeSessionId,
          ).equals(const SessionId('logs'));
          check(secondary.pty.cols).equals(80);
          check(secondary.pty.rows).equals(23);
          expect(
            tester.backend.buffer,
            matchesAnsiGolden(_goldenPath('switch_tab_80x24_top.ansi')),
          );

          // Switch back to tab 1 (" 1:htop ") before running resize progression.
          tester.mouseDown(3, 1);
          tester.mouseUp(3, 1);
          await settleFrames();
          check(
            viewer.viewModel.activeSessionId,
          ).equals(const SessionId('htop'));

          // 2. Expand terminal to 100x30 with top dock -> PTY becomes 100x29.
          tester.backend.size = const Point(100, 30);
          await settleFrames();
          check(primary.pty.cols).equals(100);
          check(primary.pty.rows).equals(29);
          expect(
            tester.backend.buffer,
            matchesAnsiGolden(_goldenPath('resize_100x30_top.ansi')),
          );

          // 3. Switch dock to left sidebar (22 cols) at 100x30 -> PTY becomes 78x30.
          viewer.viewModel.setDockPosition(.left);
          await settleFrames();
          check(primary.pty.cols).equals(78);
          check(primary.pty.rows).equals(30);
          expect(
            tester.backend.buffer,
            matchesAnsiGolden(_goldenPath('resize_100x30_left.ansi')),
          );

          // 4. Hide dock and shrink terminal to 60x16 -> PTY becomes fullscreen 60x16.
          viewer.viewModel.setDockPosition(.hidden);
          tester.backend.size = const Point(60, 16);
          await settleFrames();
          check(primary.pty.cols).equals(60);
          check(primary.pty.rows).equals(16);
          check(viewer.viewModel.dockPosition).equals(DockPosition.hidden);
          expect(
            tester.backend.buffer,
            matchesAnsiGolden(_goldenPath('resize_60x16_hidden.ansi')),
          );

          controller.dispose();
          await harness.dispose();
        });
      },
    );
  });
}
