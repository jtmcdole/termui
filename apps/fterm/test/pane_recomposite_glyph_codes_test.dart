import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fterm/src/workspace/fterm_pane_controller.dart';
import 'package:stream_channel/stream_channel.dart';
import 'package:termui/termui.dart' as tui;
import 'package:termui_cast_client_core/termui_cast_client_core.dart';
import 'package:termui_cast_protocol/termui_cast_protocol.dart';
import 'package:termui_pty/termui_pty.dart';

void main() {
  group('FtermPaneController GlyphCellList recomposition', () {
    test('incremental dirtySpans recomposition copies glyphCodes and resolves default, truecolor, and indexed cells', () async {
      final backend = _FakePtyBackend();
      final router = PtyRouter();
      final session = router.createSession(
        backend: backend,
        initialCols: 16,
        initialRows: 4,
        emitIndexedColors: true,
      );
      final port = session.openPort(initialCols: 16, initialRows: 4);
      final resolver = TerminalColorResolver(
        theme: tui.TerminalColorTheme.solarizedDark,
        settings: const TerminalThemeSettings(
          minimumContrast: 4.5,
          boldIsBright: true,
        ),
      );
      final pane = FtermPaneController(
        paneId: 'inc-pane',
        port: port,
        colorResolver: resolver,
      );

      // Write default ASCII, 24-bit RGB truecolor, and indexed ANSI cells.
      backend.emitUtf8(
        'plain\r\n'
        '\x1b[38;2;12;34;56;48;2;78;90;12mRGB\r\n'
        '\x1b[1;31;44mIDX\x1b[0m',
      );
      await Future<void>.delayed(Duration.zero);

      final buf = pane.displayBuffer;
      expect(buf.glyphCodes[0], equals('p'.codeUnitAt(0)));
      expect(buf.getCharacter(4, 0), equals('n'));

      // Truecolor row (row 1): RGB passes through untouched.
      final rgbCell = 1 * 16;
      expect(buf.glyphCodes[rgbCell], equals('R'.codeUnitAt(0)));
      expect(buf.attributes[rgbCell * 3], equals(0xFF0C2238));
      expect(buf.attributes[rgbCell * 3 + 1], equals(0xFF4E5A0C));

      // Indexed ANSI row (row 2): resolved via theme/contrast.
      final idxCell = 2 * 16;
      expect(buf.glyphCodes[idxCell], equals('I'.codeUnitAt(0)));
      expect(buf.attributes[idxCell * 3].isAnsiIndexed, isFalse);
      expect(buf.attributes[idxCell * 3 + 1].isAnsiIndexed, isFalse);

      // Incremental single-cell update on row 0 via dirtySpans.
      backend.emitUtf8('\x1b[1;3H\x1b[32mZ\x1b[0m');
      await Future<void>.delayed(Duration.zero);

      expect(buf.glyphCodes[2], equals('Z'.codeUnitAt(0)));
      expect(buf.glyphCodes[0], equals('p'.codeUnitAt(0)));
      expect(buf.attributes[2 * 3].isAnsiIndexed, isFalse);
      expect(buf.attributes[2 * 3], isNot(equals(0)));

      // lookupVirtualLine uses zero-copy rowCharactersView on live rows.
      final liveSlice = pane.lookupVirtualLine(0);
      expect(liveSlice, isNotNull);
      expect(liveSlice!.characters.take(5).join(), equals('plZin'));

      await pane.dispose(disposePort: false);
      await port.dispose();
      await router.dispose();
    });

    test('incremental cursor movement restores previous cursor cell glyph and attributes cleanly', () async {
      final backend = _FakePtyBackend();
      final router = PtyRouter();
      final session = router.createSession(
        backend: backend,
        initialCols: 12,
        initialRows: 3,
        emitIndexedColors: true,
      );
      final port = session.openPort(initialCols: 12, initialRows: 3);
      final resolver = TerminalColorResolver(
        theme: tui.TerminalColorTheme.termuiDark,
        settings: const TerminalThemeSettings(),
      );
      final pane = FtermPaneController(
        paneId: 'cursor-pane',
        port: port,
        colorResolver: resolver,
      )..setFocused(true);

      // Put a ZWJ emoji at col 0 and ASCII 'A' at col 2, cursor at (0, 0).
      backend.emitUtf8('👨‍👩‍👧‍👦A\x1b[1;1H');
      await Future<void>.delayed(Duration.zero);

      final buf = pane.displayBuffer;
      expect(buf.getCharacter(0, 0), equals('👨‍👩‍👧‍👦'));
      expect(
        buf.glyphCodes[0] & tui.GlyphCellList.clusterFlag,
        isNot(equals(0)),
      );
      expect(tui.Modifier.has(buf.attributes[2], tui.Modifier.reverse), isTrue);

      // Move cursor to (2, 0): col 0 must be restored with reverse cleared
      // and ZWJ grapheme intact, while col 2 receives reverse cursor.
      backend.emitUtf8('\x1b[1;3H');
      await Future<void>.delayed(Duration.zero);

      expect(buf.getCharacter(0, 0), equals('👨‍👩‍👧‍👦'));
      expect(
        tui.Modifier.has(buf.attributes[2], tui.Modifier.reverse),
        isFalse,
      );
      expect(buf.getCharacter(2, 0), equals('A'));
      expect(
        tui.Modifier.has(buf.attributes[2 * 3 + 2], tui.Modifier.reverse),
        isTrue,
      );

      await pane.dispose(disposePort: false);
      await port.dispose();
      await router.dispose();
    });

    test('scrollback row blending copies ZWJ, CJK, underline colors, OSC 8 URIs, blank tails, cleared rows, and scrollbar thumb', () async {
      final backend = _FakePtyBackend();
      final router = PtyRouter();
      final session = router.createSession(
        backend: backend,
        initialCols: 16,
        initialRows: 4,
        emitIndexedColors: true,
      );
      final port = session.openPort(initialCols: 16, initialRows: 4);
      final resolver = TerminalColorResolver(
        theme: tui.TerminalColorTheme.solarizedDark,
        settings: const TerminalThemeSettings(),
      );
      final pane = FtermPaneController(
        paneId: 'sb-pane',
        port: port,
        colorResolver: resolver,
      );

      // Emit 7 lines into a 4-row terminal so 3 lines enter scrollback:
      // line 0: short ASCII + OSC 8 link + SGR 58 underline color
      // line 1: ZWJ emoji + wide CJK
      // line 2: empty blank line
      // lines 3..6: live rows
      backend.emitUtf8(
        '\x1b[58;2;255;128;0m\x1b]8;;https://dart.dev\x1b\\Hi\x1b]8;;\x1b\\\x1b[0m\r\n'
        '👩‍🚀漢\r\n'
        '\r\n'
        'LIVE3\r\n'
        'LIVE4\r\n'
        'LIVE5\r\n'
        'LIVE6',
      );
      await Future<void>.delayed(Duration.zero);

      pane.scrollLines(3);
      final buf = pane.displayBuffer;

      // Row 0: scrollback line 0 with link, underline color, and blank tail.
      expect(buf.getCharacter(0, 0), equals('H'));
      expect(buf.getCharacter(1, 0), equals('i'));
      expect(buf.getUri(0, 0), equals('https://dart.dev'));
      expect(buf.getUnderlineColor(0, 0), equals(0xFFFF8000));
      expect(buf.glyphCodes[2], equals(tui.GlyphCellList.spaceCode));

      // Row 1: scrollback line 1 with ZWJ cluster and wide CJK continuation.
      expect(buf.getCharacter(0, 1), equals('👩‍🚀'));
      expect(buf.glyphCodes[1 * 16 + 1], equals(0));
      expect(buf.getCharacter(2, 1), equals('漢'));
      expect(buf.glyphCodes[1 * 16 + 3], equals(0));

      // Row 2: empty scrollback line filled with spaceCode.
      expect(buf.glyphCodes[2 * 16], equals(tui.GlyphCellList.spaceCode));

      // Row 3: live row 0 ('LIVE3') blended below scrollback.
      expect(buf.getCharacter(0, 3), equals('L'));
      expect(buf.getCharacter(4, 3), equals('3'));

      // Rightmost column has scrollbar thumb (U+2590 '▐').
      var foundThumb = false;
      for (var y = 0; y < buf.height; y++) {
        if (buf.glyphCodes[y * buf.width + (buf.width - 1)] == 0x2590) {
          foundThumb = true;
        }
      }
      expect(foundThumb, isTrue);

      // Jump back to live bottom.
      pane.jumpToBottom();
      expect(pane.scrollOffsetLines, equals(0));
      expect(pane.displayBuffer.getCharacter(0, 0), equals('L'));
      expect(pane.displayBuffer.getCharacter(4, 0), equals('3'));

      await pane.dispose(disposePort: false);
      await port.dispose();
      await router.dispose();
    });

    test('remaps multi-codepoint ZWJ clusters safely across remote source and display buffers with differing cluster tables', () async {
      const cols = 12;
      const rows = 3;
      const sessionId = SessionId('zwj-remap');

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
        theme: tui.TerminalColorTheme.termuiDark,
        settings: const TerminalThemeSettings(),
      );
      final pane = FtermPaneController(
        paneId: 'zwj-pane',
        port: port,
        colorResolver: resolver,
        remoteSessionId: sessionId,
      );

      // Seed displayBuffer with a different cluster ordering first.
      pane.displayBuffer.glyphCellList[0] = '🇺🇸';
      pane.displayBuffer.glyphCellList[2] = '👨‍💻';

      // Snapshot with a distinct cluster table in the source buffer.
      final snapBuf = tui.Buffer.blank(cols, rows);
      snapBuf.setCell(0, 0, '👨‍👩‍👧‍👦', 0, 0, 0);
      snapBuf.setCell(1, 0, '', 0, 0, 0);
      snapBuf.setCell(2, 0, '🏳️‍🌈', 0, 0, 0);
      snapBuf.setCell(3, 0, '', 0, 0, 0);
      snapBuf.setCell(0, 1, '👩‍🚀', const tui.Color.ansi(3).argb, 0, 0);
      snapBuf.setCell(1, 1, '', 0, 0, 0);

      toClient.add(
        BufferFrameCodec.encode(
          BufferSnapshotFrame(
            snapshot: BufferSnapshot.fromBuffer(
              sessionId: sessionId,
              seq: 1,
              buffer: snapBuf,
              cursor: const CursorState(x: 0, y: 0, visible: false),
              modes: TerminalModes.defaults,
              scrollback: const ScrollbackWindow(
                clearSeq: 0,
                oldestLine: 0,
                totalLines: 2,
              ),
            ),
          ),
        ),
      );
      await Future<void>.delayed(Duration.zero);

      expect(pane.displayBuffer.getCharacter(0, 0), equals('👨‍👩‍👧‍👦'));
      expect(pane.displayBuffer.getCharacter(2, 0), equals('🏳️‍🌈'));
      expect(pane.displayBuffer.getCharacter(0, 1), equals('👩‍🚀'));

      // Incremental delta introducing another ZWJ cluster on row 2.
      final deltaAttrs = Uint32List(2 * 3);
      toClient.add(
        BufferFrameCodec.encode(
          BufferDeltaFrame(
            delta: BufferDelta(
              sessionId: sessionId,
              baseSeq: 1,
              seq: 2,
              cols: cols,
              rows: rows,
              cursor: const CursorState(x: 0, y: 2, visible: false),
              modes: TerminalModes.defaults,
              scrollback: const ScrollbackWindow(
                clearSeq: 0,
                oldestLine: 0,
                totalLines: 2,
              ),
              runs: [
                CellRun(
                  startIndex: 2 * cols,
                  characters: const ['🧑‍🔬', ''],
                  attributes: deltaAttrs,
                ),
              ],
            ),
          ),
        ),
      );
      await Future<void>.delayed(Duration.zero);

      expect(pane.displayBuffer.getCharacter(0, 2), equals('🧑‍🔬'));
      expect(pane.displayBuffer.glyphCodes[2 * cols + 1], equals(0));
      expect(pane.displayBuffer.getCharacter(0, 0), equals('👨‍👩‍👧‍👦'));

      // Scrolling into unhydrated remote scrollback invokes _clearScreenRow.
      pane.scrollLines(2);
      expect(
        pane.displayBuffer.glyphCodes[0],
        equals(tui.GlyphCellList.spaceCode),
      );
      expect(
        pane.displayBuffer.glyphCodes[cols],
        equals(tui.GlyphCellList.spaceCode),
      );

      await pane.dispose(disposePort: false);
      await port.dispose();
      await sub.cancel();
      await toClient.close();
      await fromClient.close();
      await repo.dispose();
    });

    test('WorkspaceBufferCompositor.rowCharactersView exposes zero-copy read-only row slice', () {
      final buf = tui.Buffer.blank(6, 2)
        ..writeString(0, 0, 'https:', const tui.Style())
        ..setCell(0, 1, '👨‍👩‍👧‍👦', 0, 0, 0)
        ..setCell(1, 1, '', 0, 0, 0)
        ..setCell(2, 1, 'X', 0, 0, 0);

      final row0 = WorkspaceBufferCompositor.rowCharactersView(buf, 0);
      final row1 = WorkspaceBufferCompositor.rowCharactersView(buf, 1);

      expect(row0.length, equals(6));
      expect(row0.join(), equals('https:'));
      expect(row1[0], equals('👨‍👩‍👧‍👦'));
      expect(row1[1], equals(''));
      expect(row1[2], equals('X'));
      expect(() => row0[0] = '!', throwsUnsupportedError);
      expect(() => row0.length = 1, throwsUnsupportedError);
      expect(() => row0[6], throwsRangeError);
      expect(
        () => WorkspaceBufferCompositor.rowCharactersView(buf, 2),
        throwsRangeError,
      );
    });
  });
}

final class _FakePtyBackend implements RoutedPtyBackend {
  final StreamController<Uint8List> _output =
      StreamController<Uint8List>.broadcast();
  final Completer<int> _exitCode = Completer<int>();

  void emitUtf8(String text) {
    if (!_output.isClosed) {
      _output.add(Uint8List.fromList(utf8.encode(text)));
    }
  }

  @override
  Stream<Uint8List> get output => _output.stream;

  @override
  Future<int> get exitCode => _exitCode.future;

  @override
  void write(Uint8List bytes) {}

  @override
  void resize(int cols, int rows, {int pixelWidth = 0, int pixelHeight = 0}) {}

  @override
  void kill() {
    if (!_exitCode.isCompleted) _exitCode.complete(0);
  }

  @override
  Future<void> dispose() async {
    if (!_output.isClosed) await _output.close();
    if (!_exitCode.isCompleted) _exitCode.complete(0);
  }
}
