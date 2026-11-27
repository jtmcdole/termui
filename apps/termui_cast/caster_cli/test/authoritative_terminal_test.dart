import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:checks/checks.dart';
import 'package:termui/termui.dart';
import 'package:termui_cast_protocol/termui_cast_protocol.dart';
import 'package:termui_caster_cli/termui_caster_cli.dart';
import 'package:termui_pty/termui_pty.dart';
import 'package:test/test.dart';

void main() {
  const sessionId = SessionId('sess-vt');

  group('AuthoritativeTerminal', () {
    test(
      'emits initial snapshot keyframe then minimal CellRun deltas matching Buffer',
      () {
        final auth = AuthoritativeTerminal(
          sessionId: sessionId,
          initialCols: 20,
          initialRows: 6,
        );
        addTearDown(auth.dispose);

        check(auth.cols).equals(20);
        check(auth.rows).equals(6);
        check(auth.seq).equals(0);
        check(auth.isDirty).isTrue();
        check(auth.cursor).equals(CursorState.origin);
        check(auth.modes).equals(TerminalModes.defaults);

        final first = auth.takeNextFrame();
        check(first).isA<BufferSnapshotFrame>();
        final snap = (first as BufferSnapshotFrame).snapshot;
        check(snap.seq).equals(1);
        check(snap.cols).equals(20);
        check(snap.rows).equals(6);
        check(auth.isDirty).isFalse();
        check(auth.takeNextFrame()).isNull();
        check(auth.seq).equals(1);

        final clientBuffer = snap.toBuffer();

        // Feed 24-bit foreground + bold, wide emoji, cursor jump, and SGR mouse mode.
        auth.writeOutput(
          utf8.encode(
            '\x1b[1;38;2;255;128;0mHi🚀\x1b[0m\x1b[3;5H\x1b[?1000;1006h',
          ),
        );
        check(auth.isDirty).isTrue();

        final second = auth.takeNextFrame();
        check(second).isA<BufferDeltaFrame>();
        final delta = (second as BufferDeltaFrame).delta;
        check(delta.seq).equals(2);
        check(delta.baseSeq).equals(1);
        check(delta.cursor).equals(const CursorState(x: 4, y: 2));
        check(
          delta.modes,
        ).equals(const TerminalModes(mouseTracking: true, sgrMouse: true));
        check(delta.runs.length).equals(1);
        check(delta.runs.single.startIndex).equals(0);
        check(delta.runs.single.characters).deepEquals(['H', 'i', '🚀', '']);

        final applied = BufferFrameCodec.applyDelta(
          buffer: clientBuffer,
          currentSeq: snap.seq,
          delta: delta,
        );
        check(applied).isTrue();
        check(clientBuffer.characters).deepEquals(auth.buffer.characters);
        check(clientBuffer.attributes).deepEquals(auth.buffer.attributes);
        check(
          clientBuffer.getModifiers(0, 0) & Modifier.bold,
        ).not((it) => it.equals(0));
      },
    );

    test('emits empty-run delta on cursor-only move and skips no-op writes', () {
      final auth = AuthoritativeTerminal(
        sessionId: sessionId,
        initialCols: 16,
        initialRows: 4,
      );
      addTearDown(auth.dispose);

      final initialSnap = auth.takeSnapshot();
      check(initialSnap.seq).equals(1);
      check(auth.isDirty).isFalse();

      // Move cursor to 1-indexed row 2, col 6 -> 0-indexed (5, 1).
      auth.writeOutput(utf8.encode('\x1b[2;6H'));
      final cursorDeltaMsg = auth.takeNextFrame();
      check(cursorDeltaMsg).isA<BufferDeltaFrame>();
      final cursorDelta = (cursorDeltaMsg as BufferDeltaFrame).delta;
      check(cursorDelta.seq).equals(2);
      check(cursorDelta.baseSeq).equals(1);
      check(cursorDelta.runs).isEmpty();
      check(cursorDelta.cursor).equals(const CursorState(x: 5, y: 1));

      // Repeat exact same cursor position: VirtualTerminal notifies, diff finds no change.
      auth.writeOutput(utf8.encode('\x1b[2;6H'));
      check(auth.takeNextFrame()).isNull();
      check(auth.seq).equals(2);
      check(auth.isDirty).isFalse();
    });

    test(
      'resize forces a full BufferSnapshotFrame keyframe before resuming deltas',
      () {
        final auth = AuthoritativeTerminal(
          sessionId: sessionId,
          initialCols: 12,
          initialRows: 4,
        );
        addTearDown(auth.dispose);

        auth.writeOutput(utf8.encode('Prompt> '));
        final first = auth.takeNextFrame() as BufferSnapshotFrame;
        check(first.snapshot.seq).equals(1);

        // Same dimensions are a no-op.
        check(auth.resize(12, 4)).isFalse();
        check(auth.isDirty).isFalse();

        // Resize to 24x8 forces a snapshot keyframe on next takeNextFrame().
        check(auth.resize(24, 8)).isTrue();
        check(auth.cols).equals(24);
        check(auth.rows).equals(8);
        check(auth.isDirty).isTrue();

        final resizedMsg = auth.takeNextFrame();
        check(resizedMsg).isA<BufferSnapshotFrame>();
        final resizedSnap = (resizedMsg as BufferSnapshotFrame).snapshot;
        check(resizedSnap.seq).equals(2);
        check(resizedSnap.cols).equals(24);
        check(resizedSnap.rows).equals(8);

        final clientBuffer = resizedSnap.toBuffer();

        // Next write produces an incremental delta against seq 2.
        auth.writeOutput(utf8.encode('ls'));
        final postResizeMsg = auth.takeNextFrame();
        check(postResizeMsg).isA<BufferDeltaFrame>();
        final postResizeDelta = (postResizeMsg as BufferDeltaFrame).delta;
        check(postResizeDelta.seq).equals(3);
        check(postResizeDelta.baseSeq).equals(2);
        check(
          BufferFrameCodec.applyDelta(
            buffer: clientBuffer,
            currentSeq: resizedSnap.seq,
            delta: postResizeDelta,
          ),
        ).isTrue();
        check(clientBuffer.characters).deepEquals(auth.buffer.characters);

        // Solicited snapshotCurrent() on a clean grid returns seq=3 without bumping seq.
        final solicited = auth.snapshotCurrent();
        check(solicited.seq).equals(3);
        check(auth.seq).equals(3);
        check(auth.isDirty).isFalse();
      },
    );

    test(
      'Utf8ChunkDecoder reassembles multi-byte UTF-8 graphemes split across frames',
      () {
        final decoded = <String>[];
        final decoder = Utf8ChunkDecoder(decoded.add);
        final rocketBytes = utf8.encode('🚀'); // 4 bytes: F0 9F 9A 80
        decoder.add(rocketBytes.sublist(0, 2));
        check(decoded).isEmpty();
        decoder.add(rocketBytes.sublist(2));
        decoder.close();
        check(decoded.join()).equals('🚀');
      },
    );

    test(
      'clears Oh My Zsh status-line backgrounds on SGR 39/49, clear (CSI 2J/3J), and reset (ESC c) for deltas and fresh snapshots',
      () {
        final auth = AuthoritativeTerminal(
          sessionId: sessionId,
          initialCols: 24,
          initialRows: 4,
        );
        addTearDown(auth.dispose);

        final clientBuffer = auth.takeSnapshot().toBuffer();
        var clientSeq = auth.seq;

        // 1. Simulate zsh PROMPT_SP + Oh My Zsh multi-segment colored status line + SGR 39/49 reset + CHA (\x1b[1G).
        auth.writeOutput(
          utf8.encode(
            '\x1b[48;5;24;37m ~/src \x1b[44;33m git:main \x1b[49;39m  \x1b[K\r\n'
            '\x1b[41mERR\x1b[0m\x1b[1G\$ ',
          ),
        );
        final omzFrame = auth.takeNextFrame() as BufferDeltaFrame;
        check(
          BufferFrameCodec.applyDelta(
            buffer: clientBuffer,
            currentSeq: clientSeq,
            delta: omzFrame.delta,
          ),
        ).isTrue();
        clientSeq = omzFrame.delta.seq;

        // SGR 49;39 trailing spaces at cols 17..18 and CSI K at 19..23 must have bg == 0, fg == 0.
        check(clientBuffer.getBackground(17, 0)).equals(0);
        check(clientBuffer.getForeground(17, 0)).equals(0);
        check(clientBuffer.getBackground(20, 0)).equals(0);
        // CHA (\x1b[1G) rewound row 1 to col 0 and overwrote 'ER' with '$ ' (unstyled bg == 0).
        check(clientBuffer.getCharacter(0, 1)).equals(r'$');
        check(clientBuffer.getCharacter(1, 1)).equals(' ');
        check(clientBuffer.getBackground(0, 1)).equals(0);
        check(clientBuffer.getBackground(1, 1)).equals(0);

        // 2. Run `clear` (\x1b[H\x1b[2J\x1b[3J): every cell on row 0 and row 1 must clear bg/fg/modifiers to 0.
        auth.writeOutput(utf8.encode('\x1b[H\x1b[2J\x1b[3J'));
        final clearFrame = auth.takeNextFrame() as BufferDeltaFrame;
        check(
          BufferFrameCodec.applyDelta(
            buffer: clientBuffer,
            currentSeq: clientSeq,
            delta: clearFrame.delta,
          ),
        ).isTrue();
        clientSeq = clearFrame.delta.seq;

        for (var y = 0; y < auth.rows; y++) {
          for (var x = 0; x < auth.cols; x++) {
            check(clientBuffer.getCharacter(x, y)).equals(' ');
            check(clientBuffer.getForeground(x, y)).equals(0);
            check(clientBuffer.getBackground(x, y)).equals(0);
            check(clientBuffer.getModifiers(x, y)).equals(0);
          }
        }

        // Brand-new client connecting after `clear` receives snapshotCurrent() with zero stale backgrounds.
        final reconnectAfterClear = auth.snapshotCurrent().toBuffer();
        for (var y = 0; y < auth.rows; y++) {
          for (var x = 0; x < auth.cols; x++) {
            check(reconnectAfterClear.getBackground(x, y)).equals(0);
            check(reconnectAfterClear.getModifiers(x, y)).equals(0);
          }
        }

        // 3. Paint colored status bar, enable mouse + hide cursor (?25l), then run `reset` (\x1bc\x1b[!p).
        auth.writeOutput(
          utf8.encode('\x1b[45;32mSTATUS_BAR\x1b[?1000;1006h\x1b[?25l'),
        );
        final statusDelta = (auth.takeNextFrame() as BufferDeltaFrame).delta;
        check(statusDelta.cursor.visible).isFalse();
        check(statusDelta.modes.mouseTracking).isTrue();
        check(
          BufferFrameCodec.applyDelta(
            buffer: clientBuffer,
            currentSeq: clientSeq,
            delta: statusDelta,
          ),
        ).isTrue();
        clientSeq = statusDelta.seq;

        auth.writeOutput(utf8.encode('\x1bc\x1b[!p\x1b[?3;4l\x1b[4l\x1b>'));
        final resetDelta = (auth.takeNextFrame() as BufferDeltaFrame).delta;
        check(resetDelta.cursor).equals(CursorState.origin);
        check(resetDelta.modes).equals(TerminalModes.defaults);
        check(
          BufferFrameCodec.applyDelta(
            buffer: clientBuffer,
            currentSeq: clientSeq,
            delta: resetDelta,
          ),
        ).isTrue();
        clientSeq = resetDelta.seq;

        for (var x = 0; x < 10; x++) {
          check(clientBuffer.getCharacter(x, 0)).equals(' ');
          check(clientBuffer.getBackground(x, 0)).equals(0);
          check(clientBuffer.getForeground(x, 0)).equals(0);
        }

        // 4. Scrolling and resizing keep new cells opaque (no Modifier.transparent leak).
        auth.writeOutput(utf8.encode('r0\r\nr1\r\nr2\r\nr3\r\nr4'));
        auth.takeNextFrame();
        check(auth.buffer.getModifiers(0, 3) & Modifier.transparent).equals(0);
        auth.resize(30, 6);
        check(auth.buffer.getModifiers(28, 5) & Modifier.transparent).equals(0);
      },
    );

    test(
      'handles BCE erases, wide-grapheme healing, alt screen (?1049), DECSTBM margins, ICH/DCH, and SGR palettes',
      () {
        final auth = AuthoritativeTerminal(
          sessionId: sessionId,
          initialCols: 10,
          initialRows: 5,
        );
        addTearDown(auth.dispose);
        auth.takeSnapshot();

        // 1. Wide grapheme wrap at rightmost col (col 9) + split healing on overwrite & erase.
        auth.writeOutput(utf8.encode('\x1b[1;10H🚀'));
        check(auth.buffer.getCharacter(9, 0)).equals(' ');
        check(auth.buffer.getCharacter(0, 1)).equals('🚀');
        check(auth.buffer.getCharacter(1, 1)).equals('');

        // Overwriting trailing half (col 1, row 1) heals leading half (col 0, row 1) to ' '.
        auth.writeOutput(utf8.encode('\x1b[2;2HX'));
        check(auth.buffer.getCharacter(0, 1)).equals(' ');
        check(auth.buffer.getCharacter(1, 1)).equals('X');

        // Overwriting leading half heals trailing half, and shrink-resize heals clipped wide char.
        auth.writeOutput(utf8.encode('\x1b[2;3H🚀\x1b[2;3HY\x1b[2;5H🚀'));
        check(auth.buffer.getCharacter(2, 1)).equals('Y');
        check(auth.buffer.getCharacter(3, 1)).equals(' ');
        check(auth.buffer.getCharacter(4, 1)).equals('🚀');
        auth.resize(
          5,
          5,
        ); // col 4 is rightmost; trailing half clipped -> healed to ' '.
        check(auth.buffer.getCharacter(4, 1)).equals(' ');
        auth.resize(10, 5);

        // 1-col terminal safely replaces wide grapheme with space.
        final narrow = AuthoritativeTerminal(
          sessionId: sessionId,
          initialCols: 1,
          initialRows: 2,
        );
        addTearDown(narrow.dispose);
        narrow.writeOutput(utf8.encode('🚀'));
        check(narrow.buffer.getCharacter(0, 0)).equals(' ');

        // 2. BCE on CSI K (0, 1, 2), CSI J (0, 1), and CSI X (ECH).
        final greenBg = const Color.ansi(2).argb;
        auth.writeOutput(utf8.encode('\x1b[42m\x1b[1;5H\x1b[1K'));
        check(auth.buffer.getBackground(0, 0)).equals(greenBg);
        check(auth.buffer.getBackground(4, 0)).equals(greenBg);
        auth.writeOutput(utf8.encode('\x1b[2;1H\x1b[2K\x1b[3;2H\x1b[3X'));
        check(auth.buffer.getBackground(9, 1)).equals(greenBg);
        check(auth.buffer.getBackground(3, 2)).equals(greenBg);
        auth.writeOutput(
          utf8.encode('\x1b[0m\x1b[2;2H\x1b[1J\x1b[4;2H\x1b[0J'),
        );
        check(auth.buffer.getBackground(0, 0)).equals(0);
        check(auth.buffer.getBackground(5, 4)).equals(0);

        // 3. ICH (@), DCH (P), DECSTBM (r), IL (L), DL (M), SU (S), SD (T), RI (ESC M), IND/NEL, DECSC/DECRC.
        auth.writeOutput(utf8.encode('\x1b[1;1HABCDEF\x1b[1;3H\x1b[2@12'));
        check(auth.buffer.getCharacter(2, 0)).equals('1');
        check(auth.buffer.getCharacter(3, 0)).equals('2');
        check(auth.buffer.getCharacter(4, 0)).equals('C');
        auth.writeOutput(utf8.encode('\x1b[1;3H\x1b[2P'));
        check(auth.buffer.getCharacter(2, 0)).equals('C');

        auth.writeOutput(
          utf8.encode(
            '\x1b[2;4r\x1b[2;1HR2\x1b[3;1HR3\x1b[4;1HR4'
            '\x1b[2;1H\x1bM\x1b[2;1H\x1b[L\x1b[M\x1b[S\x1b[T'
            '\x1b7\x1bD\x1bE\x1b8\x1b[1;1r',
          ),
        );
        check(auth.cursor.y).isGreaterOrEqual(0);

        // 4. Alternate screen (?1049h / ?1049l) preserves primary screen and cursor.
        auth.writeOutput(utf8.encode('\x1bcPRIMARY\x1b[?1049hALT_VIEW'));
        check(auth.buffer.getCharacter(0, 0)).equals('A');
        auth.writeOutput(utf8.encode('\x1b[?1049l'));
        check(auth.buffer.getCharacter(0, 0)).equals('P');
        check(auth.cursor.x).equals(7);

        // 5. Extended SGR modifiers (2..9, 22..29), bright/cube/grayscale colors, C0 controls, CNL/CPL/VPA/SCOSC.
        auth.writeOutput(
          utf8.encode(
            '\x1b[2;3;4;7;8;9;91;104mM\x1b[22;23;24;27;28;29;38;5;240;48;2;10;20;30mN'
            '\t\b\x1b[1E\x1b[1F\x1b[3d\x1b[s\x1b[2B\x1b[2D\x1b[2C\x1b[1A\x1b[u'
            '\x1b[?7lZZZZZZZZZZZZ\x1b[?7h\x1b]0;title\x07',
          ),
        );
        check(auth.cursor.y).equals(2);
      },
    );

    test(
      'tracks DECSET 2004 bracketedPaste mode and emits ClipboardFrame on OSC 52 writes and blocked reads',
      () {
        final auth = AuthoritativeTerminal(
          sessionId: sessionId,
          initialCols: 20,
          initialRows: 4,
        );
        addTearDown(auth.dispose);
        final clipboardFrames = <ClipboardFrame>[];
        auth.onClipboardFrame = clipboardFrames.add;

        auth.takeSnapshot();
        auth.writeOutput(utf8.encode('\x1b[?2004h'));
        final deltaMsg = auth.takeNextFrame() as BufferDeltaFrame;
        check(deltaMsg.delta.modes.bracketedPaste).isTrue();

        final encoded = base64.encode(utf8.encode('copied from nvim'));
        auth.writeOutput(utf8.encode('\x1b]52;c;$encoded\x07\x1b]52;c;?\x07'));
        check(clipboardFrames).length.equals(2);
        check(clipboardFrames[0].text).equals('copied from nvim');
        check(clipboardFrames[0].readBlocked).isFalse();
        check(clipboardFrames[1].readBlocked).isTrue();
      },
    );

    test(
      'ignores empty OSC 52 writes and non-clipboard targets while forwarding c, p, pc, and empty target',
      () {
        final auth = AuthoritativeTerminal(
          sessionId: sessionId,
          initialCols: 20,
          initialRows: 4,
        );
        addTearDown(auth.dispose);
        final clipboardFrames = <ClipboardFrame>[];
        auth.onClipboardFrame = clipboardFrames.add;

        String b64(String value) => base64.encode(utf8.encode(value));

        // Empty reset and cut-buffer / secondary targets ('0', 's') must be ignored.
        auth.writeOutput(
          utf8.encode(
            '\x1b]52;c;\x07'
            '\x1b]52;;\x07'
            '\x1b]52;0;${b64('cut0')}\x07'
            '\x1b]52;s;${b64('secondary')}\x07',
          ),
        );
        check(clipboardFrames).isEmpty();

        // Targets 'c', 'p', 'pc', and '' (normalized to 'c') must emit ClipboardFrame.
        auth.writeOutput(
          utf8.encode(
            '\x1b]52;c;${b64('clip-c')}\x07'
            '\x1b]52;p;${b64('clip-p')}\x07'
            '\x1b]52;pc;${b64('clip-pc')}\x07'
            '\x1b]52;;${b64('clip-default')}\x07',
          ),
        );
        check([
          for (final f in clipboardFrames) f.text,
        ]).deepEquals(['clip-c', 'clip-p', 'clip-pc', 'clip-default']);
      },
    );

    test(
      'tracks primary scrollback window, clearSeq deltas, modes, and sliceScrollback clamping',
      () {
        final auth = AuthoritativeTerminal(
          sessionId: sessionId,
          initialCols: 10,
          initialRows: 3,
          maxScrollbackLines: 4,
        );
        addTearDown(auth.dispose);
        auth.takeSnapshot();

        // Empty scrollback slice clamps to 0 with empty rows.
        final emptyChunk = auth.sliceScrollback(
          const RequestScrollbackFrame(
            sessionId: sessionId,
            requestId: 9,
            clearSeq: 0,
            startLine: 0,
            count: 10,
          ),
        );
        check(emptyChunk.requestId).equals(9);
        check(emptyChunk.clearSeq).equals(0);
        check(emptyChunk.startLine).equals(0);
        check(emptyChunk.rows).isEmpty();

        // Emit 7 lines on a 3-row terminal -> 4 evicted, 4 retained (lines 0..3? Wait: 7 lines = L0..L6; L0..L3 scrolled off).
        for (var i = 0; i < 6; i++) {
          auth.writeOutput(utf8.encode('L$i\r\n'));
        }
        final deltaMsg = auth.takeNextFrame() as BufferDeltaFrame;
        check(deltaMsg.delta.scrollback).equals(
          const ScrollbackWindow(clearSeq: 0, oldestLine: 0, totalLines: 4),
        );

        // Scroll 2 more lines -> ring evicts L0, L1; oldestLine = 2, totalLines = 6.
        auth.writeOutput(utf8.encode('L6\r\nL7\r\n'));
        final delta2 = auth.takeNextFrame() as BufferDeltaFrame;
        check(delta2.delta.scrollback).equals(
          const ScrollbackWindow(clearSeq: 0, oldestLine: 2, totalLines: 6),
        );

        // Request starting before oldestLine (startLine: 0) clamps to oldestLine (2).
        final chunk = auth.sliceScrollback(
          const RequestScrollbackFrame(
            sessionId: sessionId,
            requestId: 42,
            clearSeq: 0,
            startLine: 0,
            count: 2,
          ),
        );
        check(chunk.requestId).equals(42);
        check(chunk.startLine).equals(2);
        check(chunk.rows.length).equals(2);
        check(chunk.rows[0].characters).deepEquals(['L', '2']);
        check(chunk.rows[1].characters).deepEquals(['L', '3']);

        // Clear visible screen + cursor first so subsequent CSI 3 J changes ONLY scrollback clearSeq.
        auth.writeOutput(utf8.encode('\x1b[2J\x1b[H'));
        auth.takeNextFrame();

        auth.writeOutput(utf8.encode('\x1b[3J'));
        final clearDelta = auth.takeNextFrame() as BufferDeltaFrame;
        check(clearDelta.delta.runs).isEmpty();
        check(clearDelta.delta.scrollback).equals(
          const ScrollbackWindow(clearSeq: 1, oldestLine: 0, totalLines: 0),
        );

        // Toggle altScreen, appCursorKeys, and disable alternateScroll.
        auth.writeOutput(utf8.encode('\x1b[?1049h\x1b[?1h\x1b[?1007l'));
        final modeDelta = auth.takeNextFrame() as BufferDeltaFrame;
        check(modeDelta.delta.modes.altScreen).isTrue();
        check(modeDelta.delta.modes.appCursorKeys).isTrue();
        check(modeDelta.delta.modes.alternateScroll).isFalse();
      },
    );

    test(
      'preserves 120-col scrollback rows across 120->80 width shrink, rejects stale clearSeq, and clamps >400-col rows',
      () {
        final auth = AuthoritativeTerminal(
          sessionId: sessionId,
          initialCols: 120,
          initialRows: 3,
          maxScrollbackLines: 32,
        );
        addTearDown(auth.dispose);
        auth.takeSnapshot();

        final wideLine = List<String>.generate(
          120,
          (i) => String.fromCharCode(0x41 + (i % 26)),
        ).join();
        // Scroll the 120-char line (row 0) and a blank line (row 1) into scrollback.
        auth.writeOutput(
          utf8.encode('$wideLine\r\n\r\nlive0\r\nlive1\r\nlive2'),
        );
        auth.takeNextFrame();

        // Shrink terminal width from 120 -> 80.
        check(auth.resize(80, 3)).isTrue();
        final postShrinkSnap =
            (auth.takeNextFrame() as BufferSnapshotFrame).snapshot;
        check(postShrinkSnap.cols).equals(80);
        check(postShrinkSnap.scrollback.totalLines).equals(2);

        final chunk = auth.sliceScrollback(
          const RequestScrollbackFrame(
            sessionId: sessionId,
            requestId: 77,
            clearSeq: 0,
            startLine: 0,
            count: 4,
          ),
        );
        final roundTripped =
            BufferFrameCodec.decode(BufferFrameCodec.encode(chunk))
                as ScrollbackChunkFrame;
        check(roundTripped.requestId).equals(77);
        check(roundTripped.clearSeq).equals(0);
        check(roundTripped.startLine).equals(0);
        check(roundTripped.rows.length).equals(2);
        check(roundTripped.rows[0].characters.join()).equals(wideLine);
        check(roundTripped.rows[0].characters.length).equals(120);
        check(roundTripped.rows[1].characters).isEmpty();

        // Stale request.clearSeq immediately returns empty rows with current clearSeq & totalLines.
        final staleReply = auth.sliceScrollback(
          const RequestScrollbackFrame(
            sessionId: sessionId,
            requestId: 78,
            clearSeq: 99,
            startLine: 0,
            count: 4,
          ),
        );
        check(staleReply.requestId).equals(78);
        check(staleReply.clearSeq).equals(0);
        check(staleReply.startLine).equals(2);
        check(staleReply.rows).isEmpty();

        // >400-col scrollback row (including a wide emoji straddling col 399..400)
        // is clamped cleanly to 400 cells and round-trips through BufferFrameCodec.
        final ultraWide = AuthoritativeTerminal(
          sessionId: sessionId,
          initialCols: 410,
          initialRows: 2,
          maxScrollbackLines: 8,
        );
        addTearDown(ultraWide.dispose);
        final prefix399 = 'X' * 399;
        ultraWide.writeOutput(utf8.encode('$prefix399🚀TAIL\r\nnext\r\nlive'));
        final clampedChunk = ultraWide.sliceScrollback(
          const RequestScrollbackFrame(
            sessionId: sessionId,
            requestId: 79,
            clearSeq: 0,
            startLine: 0,
            count: 2,
          ),
        );
        final decodedClamped =
            BufferFrameCodec.decode(BufferFrameCodec.encode(clampedChunk))
                as ScrollbackChunkFrame;
        check(decodedClamped.rows.first.characters.length).equals(400);
        check(decodedClamped.rows.first.attributes.length).equals(1200);
        // Split wide emoji at col 399..400 is healed to ' ' at col 399.
        check(decodedClamped.rows.first.characters[398]).equals('X');
        check(decodedClamped.rows.first.characters[399]).equals(' ');
      },
    );

    test(
      'populates wrappedRows on snapshots and deltas and emits delta when CSI K clears wrap flag alone',
      () {
        final auth = AuthoritativeTerminal(
          sessionId: sessionId,
          initialCols: 10,
          initialRows: 4,
        );
        addTearDown(auth.dispose);

        final initial = auth.takeSnapshot();
        for (var r = 0; r < 4; r++) {
          check(initial.isRowWrapped(r)).isFalse();
        }

        // Soft-wrap 12 visible chars across row 0 -> row 1 (row 1 began via auto-wrap).
        auth.writeOutput(utf8.encode('0123456789AB'));
        final wrapDelta = (auth.takeNextFrame() as BufferDeltaFrame).delta;
        check(wrapDelta.isRowWrapped(0)).isFalse();
        check(wrapDelta.isRowWrapped(1)).isTrue();
        check(wrapDelta.isRowWrapped(2)).isFalse();

        // Solicited snapshotCurrent() also preserves wrappedRows.
        final solicited = auth.snapshotCurrent();
        check(solicited.isRowWrapped(0)).isFalse();
        check(solicited.isRowWrapped(1)).isTrue();

        // CSI K on row 0 clears both trailing cells and row 1's continuation wrap flag.
        auth.writeOutput(utf8.encode('\x1b[1;5H\x1b[K'));
        final clearWrapDelta = (auth.takeNextFrame() as BufferDeltaFrame).delta;
        check(clearWrapDelta.isRowWrapped(1)).isFalse();

        // Now test wrap-only mutation: reset, soft-wrap 11 spaces so all cells stay ' '
        // with default attributes while row 1 gets marked wrapped, return cursor to (0, 0),
        // takeSnapshot(), then issue CSI K so ONLY wrappedRows changes (runs.isEmpty).
        auth.writeOutput(utf8.encode('\x1bc           \x1b[1;1H'));
        final spaceWrappedSnap = auth.takeSnapshot();
        check(spaceWrappedSnap.isRowWrapped(1)).isTrue();
        check(spaceWrappedSnap.cursor).equals(CursorState.origin);

        auth.writeOutput(utf8.encode('\x1b[K'));
        final wrapOnlyMsg = auth.takeNextFrame();
        check(wrapOnlyMsg).isA<BufferDeltaFrame>();
        final wrapOnlyDelta = (wrapOnlyMsg as BufferDeltaFrame).delta;
        check(wrapOnlyDelta.runs).isEmpty();
        check(wrapOnlyDelta.cursor).equals(CursorState.origin);
        check(wrapOnlyDelta.isRowWrapped(1)).isFalse();
      },
    );

    test(
      'preserves truecolor gradient across SGR 58 underline colors and colon subparameters',
      () {
        const banner = "Love Jetski CLI? We're hiring SWEs!";
        final auth = AuthoritativeTerminal(
          sessionId: sessionId,
          initialCols: 40,
          initialRows: 2,
        );
        addTearDown(auth.dispose);

        final initialSnap = auth.takeSnapshot();
        final clientBuffer = initialSnap.toBuffer();

        final payload = StringBuffer();
        final expectedFg = <int>[];
        for (var i = 0; i < banner.length; i++) {
          final r = (66 + (242 - 66) * i / (banner.length - 1)).round();
          final g = (133 + (82 - 133) * i / (banner.length - 1)).round();
          final b = (244 + (90 - 244) * i / (banner.length - 1)).round();
          expectedFg.add(Color(r, g, b).argb);
          payload.write('\x1b[4;38;2;$r;$g;$b;58;2;$r;$g;${b}m${banner[i]}');
        }
        payload.write('\x1b[0m');
        auth.writeOutput(utf8.encode('$payload'));

        final wire = BufferFrameCodec.encode(auth.takeNextFrame()!);
        final decoded = BufferFrameCodec.decode(wire) as BufferDeltaFrame;
        check(
          BufferFrameCodec.applyDelta(
            buffer: clientBuffer,
            currentSeq: initialSnap.seq,
            delta: decoded.delta,
          ),
        ).isTrue();

        for (var i = 0; i < banner.length; i++) {
          check(clientBuffer.getForeground(i, 0)).equals(expectedFg[i]);
          check(clientBuffer.getUnderlineColor(i, 0)).equals(expectedFg[i]);
          check(clientBuffer.getBackground(i, 0)).equals(0);
        }
        for (var i = 0; i < banner.length; i++) {
          check(
            clientBuffer.getModifiers(i, 0),
          ).equals(Modifier.underlineSingle);
        }
      },
    );

    test(
      'preserves prompt-box alignment across CBT (CSI Z), CHT (CSI I), and REP (CSI b) selection diffs',
      () {
        final auth = AuthoritativeTerminal(
          sessionId: sessionId,
          initialCols: 191,
          initialRows: 3,
        );
        addTearDown(auth.dispose);

        const promptLine =
            '> /tmp/termui_cast_uploads_AMSNOH/cast-1793982141855523/assign-rfc-number.yml ';
        final border = '─' * 191;

        auth.writeOutput(
          utf8.encode(
            '\x1b[1;1H$border'
            '\x1b[2;1H$promptLine'
            '\x1b[3;1H$border'
            '\x1b[1;73H\x1b[48;2;138;180;248m${'─' * 119}\x1b[0m'
            '\x1b[2;79H',
          ),
        );
        final snap = auth.takeSnapshot();
        final clientBuffer = snap.toBuffer();

        // Apply ultraviolet selection diff using RI + CBT (\x1bM\x1b[Z), \r\n, and CBT (\x1b[Z).
        auth.writeOutput(
          utf8.encode(
            '\x1bM\x1b[Z${'─' * 119}'
            '\r\n$promptLine'
            '\x1b[Z\x1b[48;2;138;180;248mr.ym\x1b[0ml\b\b\b\b\b',
          ),
        );
        final wire = BufferFrameCodec.encode(auth.takeNextFrame()!);
        final decoded = BufferFrameCodec.decode(wire) as BufferDeltaFrame;
        check(
          BufferFrameCodec.applyDelta(
            buffer: clientBuffer,
            currentSeq: snap.seq,
            delta: decoded.delta,
          ),
        ).isTrue();

        for (var x = 72; x < 78; x++) {
          check(clientBuffer.getCharacter(x, 0)).equals('─');
          check(clientBuffer.getBackground(x, 0)).equals(0);
        }
        check(
          [for (var x = 0; x < 5; x++) clientBuffer.getCharacter(x, 1)].join(),
        ).equals('> /tm');
        check(
          [
            for (var x = 72; x < 77; x++) clientBuffer.getCharacter(x, 1),
          ].join(),
        ).equals('r.yml');
        for (var x = 78; x <= 82; x++) {
          check(clientBuffer.getCharacter(x, 1)).equals(' ');
        }
        check(decoded.delta.cursor.x).equals(72);
        check(decoded.delta.cursor.y).equals(1);
        check(
          [for (var x = 0; x < 10; x++) clientBuffer.getCharacter(x, 2)].join(),
        ).equals('─' * 10);
      },
    );

    test(
      'forwards onTerminalReply for CPR and DECRQM queries and exposes synchronizedOutput (?2026)',
      () {
        final auth = AuthoritativeTerminal(
          sessionId: sessionId,
          initialCols: 40,
          initialRows: 10,
        );
        addTearDown(auth.dispose);
        final replies = <String>[];
        auth.onTerminalReply = replies.add;

        check(auth.synchronizedOutput).isFalse();
        auth.writeOutput(
          utf8.encode('\x1b[4;7H\x1b[6n\x1b[?2026\$p\x1b[?2026h\x1b[?2026\$p'),
        );
        check(auth.synchronizedOutput).isTrue();
        check(
          replies,
        ).deepEquals(['\x1b[4;7R', '\x1b[?2026;2\$y', '\x1b[?2026;1\$y']);

        auth.writeOutput(utf8.encode('\x1b[?2026l'));
        check(auth.synchronizedOutput).isFalse();

        auth.writeOutput(utf8.encode('\x1b[?2026h'));
        check(auth.synchronizedOutput).isTrue();
        auth.resetSynchronizedOutput();
        check(auth.synchronizedOutput).isFalse();
      },
    );

    test(
      'tracks DECSCUSR cursor shape (CSI Ps SP q) and DECSET 1004 focusReporting mode across deltas and resets',
      () {
        final auth = AuthoritativeTerminal(
          sessionId: sessionId,
          initialCols: 20,
          initialRows: 4,
        );
        addTearDown(auth.dispose);

        final initial = auth.takeSnapshot();
        check(initial.cursor.shape).equals(CursorShape.defaultShape);
        check(initial.modes.focusReporting).isFalse();

        final shapeCases = <(String, CursorShape)>[
          ('\x1b[1 q', CursorShape.blinkingBlock),
          ('\x1b[2 q', CursorShape.steadyBlock),
          ('\x1b[3 q', CursorShape.blinkingUnderline),
          ('\x1b[4 q', CursorShape.steadyUnderline),
          ('\x1b[5 q', CursorShape.blinkingBar),
          ('\x1b[6 q', CursorShape.steadyBar),
          ('\x1b[0 q', CursorShape.defaultShape),
        ];

        for (final (seq, expectedShape) in shapeCases) {
          auth.writeOutput(utf8.encode(seq));
          final frame = auth.takeNextFrame();
          check(frame).isA<BufferDeltaFrame>();
          final delta = (frame! as BufferDeltaFrame).delta;
          check(delta.cursor.shape).equals(expectedShape);
        }

        // Enable DECSET 1004 focus reporting + steady bar cursor.
        auth.writeOutput(utf8.encode('\x1b[?1004h\x1b[6 q'));
        final enabledDelta = (auth.takeNextFrame()! as BufferDeltaFrame).delta;
        check(enabledDelta.modes.focusReporting).isTrue();
        check(enabledDelta.cursor.shape).equals(CursorShape.steadyBar);

        // Disable DECSET 1004 focus reporting.
        auth.writeOutput(utf8.encode('\x1b[?1004l'));
        final disabledDelta = (auth.takeNextFrame()! as BufferDeltaFrame).delta;
        check(disabledDelta.modes.focusReporting).isFalse();
        check(disabledDelta.cursor.shape).equals(CursorShape.steadyBar);
      },
    );

    _defineV5ProtocolAndKittyTests(sessionId);
  });

  _defineAuthoritativeTracerTests();
}

Uint8List _encodeTestRgbaPng(int width, int height, Uint8List rgba) {
  final table = Uint32List(256);
  for (var i = 0; i < 256; i++) {
    var c = i;
    for (var k = 0; k < 8; k++) {
      c = (c & 1) != 0 ? (0xEDB88320 ^ (c >>> 1)) : (c >>> 1);
    }
    table[i] = c;
  }
  int crc32(List<int> typeBytes, Uint8List data) {
    var crc = 0xFFFFFFFF;
    for (final b in typeBytes) {
      crc = table[(crc ^ b) & 0xFF] ^ (crc >>> 8);
    }
    for (final b in data) {
      crc = table[(crc ^ b) & 0xFF] ^ (crc >>> 8);
    }
    return (crc ^ 0xFFFFFFFF) & 0xFFFFFFFF;
  }

  final stride = width * 4;
  final scanlines = Uint8List((stride + 1) * height);
  for (var y = 0; y < height; y++) {
    scanlines.setRange(
      y * (stride + 1) + 1,
      (y + 1) * (stride + 1),
      rgba,
      y * stride,
    );
  }
  final len = scanlines.length;
  final nlen = (~len) & 0xFFFF;
  var s1 = 1;
  var s2 = 0;
  for (final b in scanlines) {
    s1 = (s1 + b) % 65521;
    s2 = (s2 + s1) % 65521;
  }
  final adler = ((s2 << 16) | s1) & 0xFFFFFFFF;
  final idat = BytesBuilder(copy: false)
    ..add([0x78, 0x01, 0x01, len & 0xFF, (len >>> 8) & 0xFF])
    ..add([nlen & 0xFF, (nlen >>> 8) & 0xFF])
    ..add(scanlines)
    ..add([
      (adler >>> 24) & 0xFF,
      (adler >>> 16) & 0xFF,
      (adler >>> 8) & 0xFF,
      adler & 0xFF,
    ]);
  final ihdr = Uint8List(13);
  ByteData.sublistView(ihdr)
    ..setUint32(0, width)
    ..setUint32(4, height)
    ..setUint8(8, 8)
    ..setUint8(9, 6);

  final out = BytesBuilder(copy: false)
    ..add(const [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);
  for (final (type, chunkData) in [
    ('IHDR', ihdr),
    ('IDAT', idat.takeBytes()),
    ('IEND', Uint8List(0)),
  ]) {
    final typeBytes = ascii.encode(type);
    final header = ByteData(4)..setUint32(0, chunkData.length);
    final footer = ByteData(4)..setUint32(0, crc32(typeBytes, chunkData));
    out
      ..add(header.buffer.asUint8List())
      ..add(typeBytes)
      ..add(chunkData)
      ..add(footer.buffer.asUint8List());
  }
  return out.takeBytes();
}

void _defineV5ProtocolAndKittyTests(SessionId sessionId) {
  test(
    'diffs OSC 8 URIs, SGR 4:3 + SGR 58 underlines, KTTY modes, and >400-col scrollback aux channels',
    () {
      final auth = AuthoritativeTerminal(
        sessionId: sessionId,
        initialCols: 24,
        initialRows: 4,
      );
      addTearDown(auth.dispose);

      final clientBuffer = auth.takeSnapshot().toBuffer();
      var seq = auth.seq;

      // Enable SGR-Pixels mouse (?1016h) and Kitty keyboard flags (CSI > 3 u),
      // and write an OSC 8 hyperlink with SGR 4:3 curly underline + SGR 58 color.
      auth.writeOutput(
        utf8.encode(
          '\x1b[?1000;1016h\x1b[>3u'
          '\x1b]8;;https://dart.dev\x1b\\'
          '\x1b[4:3;58:2::10:200:90mDart\x1b[0m'
          '\x1b]8;;\x1b\\',
        ),
      );
      final delta1 =
          (BufferFrameCodec.decode(
                    BufferFrameCodec.encode(auth.takeNextFrame()!),
                  )
                  as BufferDeltaFrame)
              .delta;
      check(delta1.modes.sgrPixelsMouse).isTrue();
      check(delta1.modes.kittyKeyboardFlags).equals(3);
      check(
        BufferFrameCodec.applyDelta(
          buffer: clientBuffer,
          currentSeq: seq,
          delta: delta1,
        ),
      ).isTrue();
      seq = delta1.seq;

      final expectedUl = const Color(10, 200, 90).argb;
      for (var x = 0; x < 4; x++) {
        check(clientBuffer.getUri(x, 0)).equals('https://dart.dev');
        check(clientBuffer.getUnderlineColor(x, 0)).equals(expectedUl);
        check(
          clientBuffer.getModifiers(x, 0) & Modifier.underlineStyleMask,
        ).equals(Modifier.underlineCurly & Modifier.underlineStyleMask);
      }

      // Overwriting the same text 'Dart' with a DIFFERENT OSC 8 URI and no SGR 58
      // emits a CellRun even though characters match.
      auth.writeOutput(
        utf8.encode(
          '\x1b[1;1H\x1b]8;;https://flutter.dev\x1b\\Dart\x1b]8;;\x1b\\',
        ),
      );
      final delta2 = (auth.takeNextFrame()! as BufferDeltaFrame).delta;
      check(delta2.runs).isNotEmpty();
      check(
        BufferFrameCodec.applyDelta(
          buffer: clientBuffer,
          currentSeq: seq,
          delta: delta2,
        ),
      ).isTrue();
      seq = delta2.seq;
      check(clientBuffer.getUri(0, 0)).equals('https://flutter.dev');
      check(clientBuffer.getUnderlineColor(0, 0)).equals(0);

      // Erasing with CHA + EL (\x1b[1G\x1b[K) clears stale URI metadata on the client.
      auth.writeOutput(utf8.encode('\x1b[1G\x1b[K\x1b[<u\x1b[?1016l'));
      final delta3 = (auth.takeNextFrame()! as BufferDeltaFrame).delta;
      check(delta3.modes.kittyKeyboardFlags).equals(0);
      check(delta3.modes.sgrPixelsMouse).isFalse();
      check(
        BufferFrameCodec.applyDelta(
          buffer: clientBuffer,
          currentSeq: seq,
          delta: delta3,
        ),
      ).isTrue();
      check(clientBuffer.getUri(0, 0)).isNull();

      // >400-col scrollback row clamps OSC 8 URI runs and SGR 58 underline colors cleanly.
      final ultraWide = AuthoritativeTerminal(
        sessionId: sessionId,
        initialCols: 410,
        initialRows: 2,
        maxScrollbackLines: 8,
      );
      addTearDown(ultraWide.dispose);
      ultraWide.writeOutput(
        utf8.encode(
          '\x1b]8;;https://dart.dev/wide\x1b\\'
          '\x1b[4;58;2;200;100;50m${'W' * 399}🚀TAIL\x1b[0m'
          '\x1b]8;;\x1b\\\r\nnext\r\nlive',
        ),
      );
      final chunk = ultraWide.sliceScrollback(
        RequestScrollbackFrame(
          sessionId: sessionId,
          requestId: 101,
          clearSeq: 0,
          startLine: 0,
          count: 2,
        ),
      );
      final decodedChunk =
          BufferFrameCodec.decode(BufferFrameCodec.encode(chunk))
              as ScrollbackChunkFrame;
      final firstRow = decodedChunk.rows.first;
      check(firstRow.characters.length).equals(400);
      check(firstRow.uriRuns).isNotNull();
      check(
        firstRow.uriRuns!.single,
      ).equals((start: 0, length: 399, uri: 'https://dart.dev/wide'));
      check(firstRow.underlineColors).isNotNull();
      check(firstRow.underlineColors!.containsKey(398)).isTrue();
      check(firstRow.underlineColors!.containsKey(399)).isFalse();
    },
  );

  test(
    'syncs APC G Kitty images across deltas, snapshotCurrent(), >4 MiB batch deferral, and oversized skip',
    () {
      final logs = <String>[];
      final auth = AuthoritativeTerminal(
        sessionId: sessionId,
        initialCols: 20,
        initialRows: 4,
        onLog: logs.add,
      );
      addTearDown(auth.dispose);

      auth.takeSnapshot();

      final rgba2x2 = Uint8List.fromList(List<int>.filled(16, 0xCC));
      final png2x2 = _encodeTestRgbaPng(2, 2, rgba2x2);
      auth.writeOutput(
        utf8.encode(
          '\x1b_Gi=10,s=2,v=2,a=t,t=d,f=32,q=2;${base64Encode(rgba2x2)}\x1b\\'
          '\x1b_Gi=11,a=t,t=d,f=100,q=2;${base64Encode(png2x2)}\x1b\\',
        ),
      );

      final upsertWire = BufferFrameCodec.encode(auth.takeNextFrame()!);
      final upsertDelta =
          (BufferFrameCodec.decode(upsertWire) as BufferDeltaFrame).delta;
      check(upsertDelta.kittyUpserts).isNotNull();
      check([
        for (final p in upsertDelta.kittyUpserts!) p.imageId,
      ]).deepEquals([10, 11]);
      check(auth.isDirty).isFalse();

      // Late-joining subscriber calling snapshotCurrent() receives active Kitty images without bumping seq.
      final seqBefore = auth.seq;
      final lateSnapWire = BufferFrameCodec.encode(
        BufferSnapshotFrame(snapshot: auth.snapshotCurrent()),
      );
      final lateSnap =
          (BufferFrameCodec.decode(lateSnapWire) as BufferSnapshotFrame)
              .snapshot;
      check(lateSnap.seq).equals(seqBefore);
      check(auth.isDirty).isFalse();
      check(lateSnap.kittyImages).isNotNull();
      check([
        for (final p in lateSnap.kittyImages!) p.imageId,
      ]).deepEquals([10, 11]);

      // Delete image 10 -> emits kittyRemovals: [10].
      auth.writeOutput(utf8.encode('\x1b_Ga=d,d=I,i=10,q=2\x1b\\'));
      final removeDelta = (auth.takeNextFrame()! as BufferDeltaFrame).delta;
      check(removeDelta.kittyRemovals).isNotNull();
      check(removeDelta.kittyRemovals!).deepEquals([10]);

      // Delete all images (d=A) -> emits clearKittyImages: true.
      auth.writeOutput(utf8.encode('\x1b_Ga=d,d=A,q=2\x1b\\'));
      final clearDelta = (auth.takeNextFrame()! as BufferDeltaFrame).delta;
      check(clearDelta.clearKittyImages).isTrue();

      // Multi-image batch exceeding 4 MiB uncompressed tail defers second texture to next delta.
      final bytes2p5MiB = Uint8List(800 * 800 * 4); // 2,560,000 bytes each
      final b64ZlibBig = base64Encode(zlib.encode(bytes2p5MiB));
      auth.writeOutput(
        utf8.encode(
          '\x1b_Gi=21,s=800,v=800,a=t,t=d,f=32,o=z,q=2;$b64ZlibBig\x1b\\'
          '\x1b_Gi=22,s=800,v=800,a=t,t=d,f=32,o=z,q=2;$b64ZlibBig\x1b\\',
        ),
      );
      final batch1Msg = auth.takeNextFrame()!;
      check(
        BufferFrameCodec.encode(batch1Msg).length,
      ).isLessOrEqual(BufferFrameCodec.maxFrameBytes);
      final batch1 = (batch1Msg as BufferDeltaFrame).delta;
      check([for (final p in batch1.kittyUpserts!) p.imageId]).deepEquals([21]);
      check(auth.isDirty).isTrue();

      final batch2Msg = auth.takeNextFrame()!;
      check(
        BufferFrameCodec.encode(batch2Msg).length,
      ).isLessOrEqual(BufferFrameCodec.maxFrameBytes);
      final batch2 = (batch2Msg as BufferDeltaFrame).delta;
      check([for (final p in batch2.kittyUpserts!) p.imageId]).deepEquals([22]);
      check(auth.isDirty).isFalse();

      // Calling snapshotCurrent() when clean while >4 MiB of active textures exist
      // marks omitted textures deferred so the next takeNextFrame() delivers id=22!
      final lateJoinSnap = auth.snapshotCurrent();
      check([
        for (final p in lateJoinSnap.kittyImages!) p.imageId,
      ]).deepEquals([21]);
      check(auth.isDirty).isTrue();
      final lateJoinFollowUp =
          (auth.takeNextFrame()! as BufferDeltaFrame).delta;
      check([
        for (final p in lateJoinFollowUp.kittyUpserts!) p.imageId,
      ]).deepEquals([22]);
      check(auth.isDirty).isFalse();

      // ABA regression: deleting i=21 (version 0) via a=d and re-uploading new pixels
      // at i=21 (also version 0) in a single coalesce window emits an upsert!
      final pxCyan = base64Encode(Uint8List.fromList([0, 255, 255, 255]));
      auth.writeOutput(
        utf8.encode(
          '\x1b_Ga=d,d=I,i=21,q=2\x1b\\'
          '\x1b_Gi=21,s=1,v=1,a=t,t=d,f=32,q=2;$pxCyan\x1b\\',
        ),
      );
      final abaDelta = (auth.takeNextFrame()! as BufferDeltaFrame).delta;
      check(abaDelta.kittyUpserts).isNotNull().length.equals(1);
      check(abaDelta.kittyUpserts!.single.imageId).equals(21);
      check(abaDelta.kittyUpserts!.single.bytes).deepEquals([0, 255, 255, 255]);

      // Large valid texture exceeding 4 MiB (1025x1024 RGBA) stages via KittyImageChunkFrame
      // instead of skipping, supports snapshotCurrent() replay without advancing seq, and cancels on a=d!
      final largeRgba = Uint8List(1025 * 1024 * 4); // 4,198,400 bytes
      for (var i = 0; i < largeRgba.length; i += 4) {
        largeRgba[i] = 0x42;
      }
      final b64ZlibLarge = base64Encode(zlib.encode(largeRgba));
      auth.writeOutput(
        utf8.encode(
          '\x1b_Gi=99,s=1025,v=1024,a=t,t=d,f=32,o=z,q=2;$b64ZlibLarge\x1b\\',
        ),
      );
      check(auth.takeNextFrame()).isNull();
      check(auth.isDirty).isFalse();
      check(auth.hasPendingKittyChunks).isTrue();
      check(
        logs.any((line) => line.contains('Skipping Kitty image id=99')),
      ).isFalse();

      final chunkFrames = <KittyImageChunkFrame>[];
      var callIdx = 0;
      while (auth.hasPendingKittyChunks) {
        final limit = callIdx.isEven ? 4096 : 8192;
        chunkFrames.add(auth.takeNextKittyChunkFrame(maxChunkBytes: limit)!);
        callIdx++;
      }
      check(chunkFrames).isNotEmpty();
      check(chunkFrames.first.imageId).equals(99);
      check(chunkFrames.first.encoding).equals(KittyChunkEncoding.deflateRaw);
      final expectedCount = chunkFrames.first.chunkCount;
      check(chunkFrames.length).equals(expectedCount);
      final assembled = BytesBuilder(copy: false);
      for (var i = 0; i < chunkFrames.length; i++) {
        check(chunkFrames[i].chunkIndex).equals(i);
        check(chunkFrames[i].chunkCount).equals(expectedCount);
        assembled.add(chunkFrames[i].data);
      }
      check(
        BufferFrameCodec.inflateKittyBytes(
          assembled.takeBytes(),
          expectedBytes: chunkFrames.first.totalDecodedBytes,
        ),
      ).deepEquals(largeRgba);

      // ABA delete + re-upload of >4 MiB image with same dims/version=0 in one coalesce window
      // emits id=99 in kittyRemovals AND re-stages chunks for the replacement payload.
      final largeRgbaB = Uint8List.fromList(largeRgba)..[0] = 0x99;
      final b64ZlibLargeB = base64Encode(zlib.encode(largeRgbaB));
      auth.writeOutput(
        utf8.encode(
          '\x1b_Ga=d,d=I,i=99,q=2\x1b\\'
          '\x1b_Gi=99,s=1025,v=1024,a=t,t=d,f=32,o=z,q=2;$b64ZlibLargeB\x1b\\',
        ),
      );
      final abaChunkDelta = (auth.takeNextFrame()! as BufferDeltaFrame).delta;
      check(abaChunkDelta.kittyRemovals).isNotNull().deepEquals([99]);
      check(auth.hasPendingKittyChunks).isTrue();
      final replacementWire = BytesBuilder(copy: false);
      while (auth.hasPendingKittyChunks) {
        replacementWire.add(
          auth.takeNextKittyChunkFrame(maxChunkBytes: 4096)!.data,
        );
      }
      check(
        BufferFrameCodec.inflateKittyBytes(
          replacementWire.takeBytes(),
          expectedBytes: largeRgbaB.length,
        ),
      ).deepEquals(largeRgbaB);

      // snapshotCurrent() re-stages large active image from chunk 0 without bumping seq.
      final snapSeqBefore = auth.seq;
      final snapWithLarge = auth.snapshotCurrent();
      check(snapWithLarge.seq).equals(snapSeqBefore);
      check(
        snapWithLarge.kittyImages?.map((p) => p.imageId),
      ).isNotNull().not((it) => it.contains(99));
      check(auth.hasPendingKittyChunks).isTrue();
      final replayedFirst = auth.takeNextKittyChunkFrame()!;
      check(replayedFirst.chunkIndex).equals(0);
      check(replayedFirst.imageId).equals(99);

      // Deleting id=99 via a=d cancels any remaining pending chunks and emits removal.
      auth.writeOutput(utf8.encode('\x1b_Ga=d,d=I,i=99,q=2\x1b\\'));
      final removeLarge = (auth.takeNextFrame()! as BufferDeltaFrame).delta;
      check(removeLarge.kittyRemovals).isNotNull().deepEquals([99]);
      check(auth.hasPendingKittyChunks).isFalse();
      check(auth.takeNextKittyChunkFrame()).isNull();

      // forceKeyframe() clears staged chunk transfers until takeSnapshot() re-stages active textures.
      auth.writeOutput(
        utf8.encode(
          '\x1b_Gi=98,s=1025,v=1024,a=t,t=d,f=32,o=z,q=2;$b64ZlibLarge\x1b\\',
        ),
      );
      auth.takeNextFrame();
      check(auth.hasPendingKittyChunks).isTrue();
      auth.forceKeyframe();
      check(auth.hasPendingKittyChunks).isFalse();
      auth.takeSnapshot();
      check(auth.hasPendingKittyChunks).isTrue();
      auth.writeOutput(utf8.encode('\x1b_Ga=d,d=I,i=98,q=2\x1b\\'));
      auth.takeNextFrame();

      // Truly invalid / >16 MiB textures registered directly log once, skip cleanly, and recover.
      final rawVt = VirtualTerminal(width: 10, height: 4);
      final rawLogs = <String>[];
      final wrapped = AuthoritativeTerminal.wrapping(
        rawVt,
        sessionId: const SessionId('wrap-skip'),
        onLog: rawLogs.add,
      );
      addTearDown(() {
        wrapped.dispose();
        rawVt.dispose();
      });
      wrapped.takeSnapshot();
      rawVt.imageRegistry.registerImage(
        KittyImageData(
          imageId: 99,
          pixelWidth: 2049,
          pixelHeight: 2048,
          rgbaPixels: Uint8List(16),
          gridCols: 1,
          gridRows: 1,
        ),
      );
      rawVt.writeString('x');
      wrapped.takeNextFrame();
      check(rawLogs).any((line) => line.contains('Skipping Kitty image id=99'));
      check(wrapped.hasPendingKittyChunks).isFalse();

      rawVt.imageRegistry.registerImage(
        KittyImageData(
          imageId: 99,
          pixelWidth: 1,
          pixelHeight: 1,
          rgbaPixels: Uint8List.fromList([0, 255, 255, 255]),
          gridCols: 1,
          gridRows: 1,
        ),
      );
      rawVt.writeString('y');
      final recovered99 = (wrapped.takeNextFrame()! as BufferDeltaFrame).delta;
      check(recovered99.kittyUpserts).isNotNull().length.equals(1);
      check(recovered99.kittyUpserts!.single.imageId).equals(99);
    },
  );
}

void _defineAuthoritativeTracerTests() {
  test(
    'AuthoritativeTerminal.takeNextFrame records Tracer begin and end events when enabled',
    () async {
      await Tracer.initialize();
      final auth = AuthoritativeTerminal(
        sessionId: const SessionId('trace-term'),
        initialCols: 20,
        initialRows: 4,
      );
      addTearDown(() {
        Tracer.isEnabled = false;
        auth.dispose();
      });

      auth.takeSnapshot();
      auth.writeOutput(utf8.encode('trace-me'));

      Tracer.isEnabled = true;
      final frame = auth.takeNextFrame();
      Tracer.isEnabled = false;

      check(frame).isA<BufferDeltaFrame>();
      check(
        Tracer.registerString('AuthoritativeTerminal.takeNextFrame'),
      ).isGreaterThan(0);
    },
  );

  test(
    'AuthoritativeTerminal.wrapping preserves external VirtualTerminal lifecycle, onReply, multi-listener hooks, and external resizes',
    () {
      final replies = <String>[];
      final existingTitles = <String>[];
      var existingBells = 0;
      final existingAudio = <TerminalAudioEvent>[];
      final vt = VirtualTerminal(
        width: 20,
        height: 5,
        onReply: replies.add,
        onBell: () => existingBells++,
        onAudioEvent: existingAudio.add,
      )..onTitleChanged = existingTitles.add;
      addTearDown(vt.dispose);

      final wrapped = AuthoritativeTerminal.wrapping(
        vt,
        sessionId: const SessionId('wrapped-vt'),
      );
      final wrappedTitles = <String>[];
      var wrappedBells = 0;
      final wrappedAudio = <TerminalAudioEvent>[];
      wrapped
        ..addTitleListener(wrappedTitles.add)
        ..addBellListener(() => wrappedBells++)
        ..addAudioListener(wrappedAudio.add);

      // Queries still route exclusively through external VirtualTerminal.onReply.
      vt.write(
        utf8.encode(
          '\x1b[c\x07\x1b]2;wrapped-sh\x07\x1b_Aa=tone,w=sine,f=440,d=50;\x1b\\',
        ),
      );
      check(replies).deepEquals(['\x1b[?62;22c']);
      check(existingBells).equals(1);
      check(wrappedBells).equals(1);
      check(existingTitles).deepEquals(['wrapped-sh']);
      check(wrappedTitles).deepEquals(['wrapped-sh']);
      check(existingAudio).length.equals(1);
      check(wrappedAudio).length.equals(1);

      // Initial snapshot captures existing contents; external vt.resize triggers keyframe resync!
      final snap1 = wrapped.takeSnapshot();
      check((snap1.cols, snap1.rows)).equals((20, 5));
      vt.resize(12, 4);
      check(wrapped.needsKeyframe).isTrue();
      final nextFrame = wrapped.takeNextFrame();
      check(nextFrame).isA<BufferSnapshotFrame>();
      final snap2 = (nextFrame! as BufferSnapshotFrame).snapshot;
      check((snap2.cols, snap2.rows)).equals((12, 4));

      // Disposing wrapped restores prior hooks and does NOT dispose external vt or clear onReply.
      wrapped.dispose();
      vt.write(utf8.encode('\x1b[c\x07\x1b]2;after-dispose\x07'));
      check(replies).length.equals(2);
      check(existingBells).equals(2);
      check(existingTitles).deepEquals(['wrapped-sh', 'after-dispose']);
      check(wrappedBells).equals(1);
      check(wrappedTitles).deepEquals(['wrapped-sh']);
    },
  );

  test(
    'standalone AuthoritativeTerminal advertises cast shader capabilities by default, updates via setShaderCapabilities, and wrapping preserves host capabilities',
    () {
      final replies = <String>[];
      final auth = AuthoritativeTerminal(
        sessionId: const SessionId('standalone-caps'),
        initialCols: 40,
        initialRows: 12,
      )..onTerminalReply = replies.add;
      addTearDown(auth.dispose);

      // Default standalone caster responds to a=query with cast capabilities.
      auth.writeOutput(utf8.encode(ShaderApcEncoder.encodeQuery()));
      check(replies).length.equals(1);
      check(replies.single).contains(
        'backend=cast,glsl=1,xform=1,region=1,max_slots=16,max_regions=8',
      );

      // Disabling capabilities (e.g. relay without shaderFrames support) replies disabled.
      auth.setShaderCapabilities(
        AuthoritativeTerminal.disabledShaderCapabilities,
      );
      auth.writeOutput(utf8.encode(ShaderApcEncoder.encodeQuery()));
      check(replies).length.equals(2);
      check(replies.last).contains(
        'backend=disabled,glsl=0,xform=0,region=0,max_slots=0,max_regions=0',
      );

      // AuthoritativeTerminal.wrapping leaves external VirtualTerminal capabilities untouched.
      final hostReplies = <String>[];
      final hostVt = VirtualTerminal(
        width: 40,
        height: 12,
        onReply: hostReplies.add,
        shaderCapabilitiesProvider: () => (
          backend: 'flutter_gpu',
          glsl: true,
          xform: true,
          region: true,
          maxSlots: 16,
          maxRegions: 8,
        ),
      );
      addTearDown(hostVt.dispose);

      final wrapped = AuthoritativeTerminal.wrapping(
        hostVt,
        sessionId: const SessionId('wrapped-caps'),
      );
      addTearDown(wrapped.dispose);

      wrapped.setShaderCapabilities(defaultDisabledShaderCapabilities);
      hostVt.write(utf8.encode(ShaderApcEncoder.encodeQuery()));
      check(hostReplies).length.equals(1);
      check(hostReplies.single).contains('backend=flutter_gpu,glsl=1');
    },
  );

  test(
    'H4a: exiting alt-screen preserves primary shaders/regions in replay and restores them in pending frames',
    () {
      final auth = AuthoritativeTerminal(
        sessionId: const SessionId('h4-alt-screen'),
        initialCols: 40,
        initialRows: 12,
      );
      addTearDown(auth.dispose);

      // Define a primary-screen GLSL shader and region, then drain pending frames.
      auth.writeOutput(
        utf8.encode(
          ShaderApcEncoder.encodeDefine(
            id: 'glow',
            glslSource: 'void mainImage(out vec4 o, in vec2 c) {}',
          ).join(),
        ),
      );
      auth.writeOutput(
        utf8.encode(
          ShaderApcEncoder.encodeRegion(
            ShaderRegion(
              id: 'primary_r',
              shaderId: 'glow',
              sourceRects: const [Rect(1, 2, 10, 3)],
            ),
          ),
        ),
      );
      auth.takePendingShaderFrames();

      // Enter alt-screen, define an alt-screen region, and drain.
      auth.writeOutput(utf8.encode('\x1b[?1049h'));
      auth.writeOutput(
        utf8.encode(
          ShaderApcEncoder.encodeRegion(
            ShaderRegion(
              id: 'alt_r',
              shaderId: 'glow',
              sourceRects: const [Rect(0, 0, 5, 2)],
            ),
          ),
        ),
      );
      auth.takePendingShaderFrames();

      // Exit alt-screen: VirtualTerminal restores primary buffer's shader regions
      // and emits TerminalResetShaderEvent(target: .all, altScreenExit: true).
      auth.writeOutput(utf8.encode('\x1b[?1049l'));

      final pendingAfterExit = auth.takePendingShaderFrames();
      check(
        pendingAfterExit.any((f) => f.payload is CastResetShaderPayload),
      ).isTrue();
      check(
        pendingAfterExit.any(
          (f) =>
              f.payload is CastDefineShaderPayload &&
              (f.payload as CastDefineShaderPayload).id == 'glow',
        ),
      ).isTrue();
      check(
        pendingAfterExit.any(
          (f) =>
              f.payload is CastRegionShaderPayload &&
              (f.payload as CastRegionShaderPayload).id == 'primary_r' &&
              !(f.payload as CastRegionShaderPayload).remove,
        ),
      ).isTrue();

      final replay = auth.buildShaderReplayFrames();
      check(
        replay.any(
          (f) =>
              f.payload is CastDefineShaderPayload &&
              (f.payload as CastDefineShaderPayload).id == 'glow',
        ),
      ).isTrue();
      check(
        replay.any(
          (f) =>
              f.payload is CastRegionShaderPayload &&
              (f.payload as CastRegionShaderPayload).id == 'primary_r' &&
              !(f.payload as CastRegionShaderPayload).remove,
        ),
      ).isTrue();
      check(
        replay.any(
          (f) =>
              f.payload is CastRegionShaderPayload &&
              (f.payload as CastRegionShaderPayload).id == 'alt_r',
        ),
      ).isFalse();
    },
  );

  test(
    'H4b: scrolling shifts region and cell transform coordinates in buildShaderReplayFrames to match VirtualTerminal.buffer',
    () {
      final auth = AuthoritativeTerminal(
        sessionId: const SessionId('h4-scroll'),
        initialCols: 20,
        initialRows: 10,
      );
      addTearDown(auth.dispose);

      // Attach region at row 5 and cell transform at (2, 5).
      auth.writeOutput(
        utf8.encode(
          ShaderApcEncoder.encodeRegion(
            ShaderRegion(
              id: 'banner',
              shaderId: 'pulse',
              sourceRects: const [Rect(1, 5, 8, 2)],
            ),
          ),
        ),
      );
      auth.writeOutput(
        utf8.encode(
          ShaderApcEncoder.encodeTransform(
            col: 2,
            row: 5,
            transform: const CellTransform(dx: 0.25, dy: -0.5),
          ),
        ),
      );
      auth.takePendingShaderFrames();

      // Scroll terminal up 2 rows (CSI 2 S) -> VirtualTerminal shifts row 5 -> row 3.
      auth.writeOutput(utf8.encode('\x1b[2S'));
      check(auth.buffer.shaderRegions.single.sourceRects.single.y).equals(3);
      check(auth.buffer.getCellTransform(2, 3)).isNotNull();
      check(auth.buffer.getCellTransform(2, 5)).isNull();

      // Replay frames must report shifted row 3, NOT stale row 5.
      final replay = auth.buildShaderReplayFrames();
      final regionPayload = replay
          .map((f) => f.payload)
          .whereType<CastRegionShaderPayload>()
          .single;
      check(regionPayload.region!.sourceRects.single.y).equals(3);

      final xformPayload = replay
          .map((f) => f.payload)
          .whereType<CastTransformsShaderPayload>()
          .single;
      check(xformPayload.entries.single.col).equals(2);
      check(xformPayload.entries.single.row).equals(3);
    },
  );
}
