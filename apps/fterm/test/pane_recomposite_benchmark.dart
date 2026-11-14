import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fterm/src/workspace/fterm_pane_controller.dart';
import 'package:stream_channel/stream_channel.dart';
import 'package:termui/termui.dart' as tui;
import 'package:termui_cast_client_core/termui_cast_client_core.dart';
import 'package:termui_cast_protocol/termui_cast_protocol.dart';

void main() {
  test(
    'FtermPaneController 200x60 full vs incremental recomposition benchmark',
    () async {
      const cols = 200;
      const rows = 60;
      const sessionId = SessionId('bench-pane');

      final toClient = StreamController<Uint8List>(sync: true);
      final fromClient = StreamController<Uint8List>(sync: true);
      final sub = fromClient.stream.listen((_) {});
      final transport = WsClientTransport(
        channelFactory: () async =>
            StreamChannel<Uint8List>(toClient.stream, fromClient.sink),
      );
      final repo = CastClientRepository(
        transport: transport,
        enableReconnect: false,
      );

      await repo.connect();
      toClient.add(
        BufferFrameCodec.encode(const AuthAcceptedFrame(role: .client)),
      );
      await Future<void>.delayed(Duration.zero);

      final port = repo.openTerminalPort(
        sessionId,
        initialCols: cols,
        initialRows: rows,
      );
      await Future<void>.delayed(Duration.zero);

      final resolver = TerminalColorResolver(
        theme: tui.TerminalColorTheme.solarizedDark,
        settings: const TerminalThemeSettings(
          minimumContrast: 4.5,
          boldIsBright: true,
        ),
      );
      final pane = FtermPaneController(
        paneId: 'bench-pane',
        port: port,
        colorResolver: resolver,
        remoteSessionId: sessionId,
      )..setFocused(true);

      final initBuf = tui.Buffer.blank(cols, rows);
      var seed = 1234567;
      for (var y = 0; y < rows; y++) {
        for (var x = 0; x < cols; x++) {
          seed = (seed * 1103515245 + 12345) & 0x7FFFFFFF;
          final ch = String.fromCharCode(0x21 + (seed % 94));
          final fg = switch (seed % 4) {
            0 => 0,
            1 => tui.Color.ansi(seed % 16).argb,
            2 => tui.Color.ansi(16 + (seed % 240)).argb,
            _ => tui.Color(
              (seed >> 8) & 0xFF,
              (seed >> 16) & 0xFF,
              seed & 0xFF,
            ).argb,
          };
          final bg = switch ((seed >> 3) % 4) {
            0 => 0,
            1 => tui.Color.ansi((seed >> 2) % 16).argb,
            2 => tui.Color.ansi(16 + ((seed >> 4) % 240)).argb,
            _ => tui.Color(
              (seed >> 4) & 0xFF,
              (seed >> 12) & 0xFF,
              (seed >> 20) & 0xFF,
            ).argb,
          };
          initBuf.setCell(x, y, ch, fg, bg, seed % 8);
        }
      }

      toClient.add(
        BufferFrameCodec.encode(
          BufferSnapshotFrame(
            snapshot: BufferSnapshot.fromBuffer(
              sessionId: sessionId,
              seq: 1,
              buffer: initBuf,
              cursor: const CursorState(x: 10, y: 10),
              modes: TerminalModes.defaults,
              scrollback: ScrollbackWindow.empty,
            ),
          ),
        ),
      );
      await Future<void>.delayed(Duration.zero);

      // 1. Measure full 200x60 recomposition via setColorResolver.
      for (var i = 0; i < 20; i++) {
        pane.setColorResolver(resolver);
      }
      const fullIters = 200;
      final swFull = Stopwatch()..start();
      for (var i = 0; i < fullIters; i++) {
        pane.setColorResolver(resolver);
      }
      swFull.stop();
      final fullUs = swFull.elapsedMicroseconds / fullIters;

      // 2. Measure 1-cell incremental delta recomposition (including delta apply + recomposite).
      final oneChar = const ['X'];
      final oneAttr = Uint32List.fromList([
        const tui.Color.ansi(2).argb,
        const tui.Color.ansi(0).argb,
        tui.Modifier.bold,
      ]);
      var seq = 1;
      void sendDelta(
        List<String> chars,
        Uint32List attrs,
        int startIndex,
        int cx,
      ) {
        final delta = BufferDelta(
          sessionId: sessionId,
          baseSeq: seq,
          seq: ++seq,
          cols: cols,
          rows: rows,
          cursor: CursorState(x: cx, y: 12),
          modes: TerminalModes.defaults,
          scrollback: ScrollbackWindow.empty,
          runs: [
            CellRun(
              startIndex: startIndex,
              characters: chars,
              attributes: attrs,
            ),
          ],
        );
        toClient.add(BufferFrameCodec.encode(BufferDeltaFrame(delta: delta)));
      }

      // Also isolate pure recomposition cost via a listener-free direct loop on port.
      for (var i = 0; i < 30; i++) {
        sendDelta(oneChar, oneAttr, 12 * cols + (i % cols), i % cols);
        await Future<void>.microtask(() {});
      }
      const oneCellIters = 500;
      final swCell = Stopwatch()..start();
      for (var i = 0; i < oneCellIters; i++) {
        sendDelta(oneChar, oneAttr, 12 * cols + (i % cols), i % cols);
        await Future<void>.microtask(() {});
      }
      swCell.stop();
      final oneCellUs = swCell.elapsedMicroseconds / oneCellIters;

      // 3. Measure 1-row (200-cell) incremental delta recomposition.
      final rowChars = List<String>.filled(cols, 'R');
      final rowAttrs = Uint32List(cols * 3);
      for (var i = 0; i < cols; i++) {
        rowAttrs[i * 3] = const tui.Color.ansi(4).argb;
        rowAttrs[i * 3 + 1] = const tui.Color.ansi(0).argb;
        rowAttrs[i * 3 + 2] = tui.Modifier.none;
      }
      for (var i = 0; i < 30; i++) {
        sendDelta(rowChars, rowAttrs, 15 * cols, i % cols);
        await Future<void>.microtask(() {});
      }
      const oneRowIters = 300;
      final swRow = Stopwatch()..start();
      for (var i = 0; i < oneRowIters; i++) {
        sendDelta(rowChars, rowAttrs, 15 * cols, i % cols);
        await Future<void>.microtask(() {});
      }
      swRow.stop();
      final oneRowUs = swRow.elapsedMicroseconds / oneRowIters;

      // Sanity assertions.
      expect(pane.displayBuffer.getCharacter(0, 15), equals('R'));
      expect(oneCellUs, lessThan(fullUs));
      expect(oneRowUs, lessThan(fullUs));

      // ignore: avoid_print
      print(
        'pane_recomposite_benchmark (200x60): '
        'full=${fullUs.toStringAsFixed(1)}us/op, '
        'oneCellIncremental=${oneCellUs.toStringAsFixed(1)}us/op, '
        'oneRowIncremental=${oneRowUs.toStringAsFixed(1)}us/op',
      );

      await pane.dispose(disposePort: false);
      await port.dispose();
      await sub.cancel();
      await toClient.close();
      await fromClient.close();
      await repo.dispose();
    },
  );
}
