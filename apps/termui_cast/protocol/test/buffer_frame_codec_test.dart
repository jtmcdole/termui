import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:checks/checks.dart';
import 'package:termui/termui.dart';
import 'package:termui_cast_protocol/src/deflate_raw.dart';
import 'package:termui_cast_protocol/termui_cast_protocol.dart';
import 'package:test/test.dart';

void main() {
  group('BufferFrameCodec snapshots and deltas', () {
    test(
      'round-trips wide emoji graphemes, 24-bit ARGB colors, and modifiers',
      () {
        const sessionId = SessionId('sess-emoji');
        final original = Buffer.blank(8, 2);
        original.writeString(
          0,
          0,
          '🚀Hi',
          Style(
            foreground: const Color(0x12, 0x34, 0x56),
            background: const Color(0xAB, 0xCD, 0xEF),
            modifiers: Modifier.bold | Modifier.underline,
          ),
        );
        // Include a multi-codepoint ZWJ grapheme cluster (> 4 UTF-8 bytes).
        const familyEmoji = '👨‍👩‍👧‍👦';
        original.setAttributes(
          4,
          1,
          char: familyEmoji,
          fg: 0xFFFF8800,
          bg: 0xFF112233,
          modifiers: Modifier.italic,
        );

        final snapshot = BufferSnapshot.fromBuffer(
          sessionId: sessionId,
          seq: 7,
          buffer: original,
          cursor: const CursorState(x: 4, y: 1, visible: true),
          modes: const TerminalModes(
            mouseTracking: true,
            sgrMouse: true,
            bracketedPaste: true,
          ),
        );

        final encoded = BufferFrameCodec.encode(
          BufferSnapshotFrame(snapshot: snapshot),
        );
        final relayPeek = BufferFrameCodec.inspectRelayBufferFrame(
          encoded,
          expectedSession: sessionId,
        );
        check(
          relayPeek,
        ).isNotNull().equals((isSnapshot: true, seq: 7, cols: 8, rows: 2));

        final decoded = BufferFrameCodec.decode(encoded);
        check(decoded).isA<BufferSnapshotFrame>();
        final hydratedSnapshot = (decoded as BufferSnapshotFrame).snapshot;
        check(hydratedSnapshot.sessionId).equals(sessionId);
        check(hydratedSnapshot.seq).equals(7);
        check(hydratedSnapshot.cols).equals(8);
        check(hydratedSnapshot.rows).equals(2);
        check(
          hydratedSnapshot.cursor,
        ).equals(const CursorState(x: 4, y: 1, visible: true));
        check(hydratedSnapshot.modes).equals(
          const TerminalModes(
            mouseTracking: true,
            sgrMouse: true,
            bracketedPaste: true,
          ),
        );

        final hydrated = hydratedSnapshot.toBuffer();
        check(hydrated.characters).deepEquals(original.characters);
        check(hydrated.attributes).deepEquals(original.attributes);
        // Wide emoji continuation cell ('') is preserved intact.
        check(hydrated.getCharacter(0, 0)).equals('🚀');
        check(hydrated.getCharacter(1, 0)).equals('');
        check(hydrated.getCharacter(4, 1)).equals(familyEmoji);
      },
    );

    test(
      'round-trips all 7 CursorShape values and focusReporting mode across snapshots and deltas while keeping inspectRelayBufferFrame compatible',
      () {
        const sessionId = SessionId('sess-cursor-shape');
        final buf = Buffer.blank(4, 2);
        for (final shape in CursorShape.values) {
          for (final focusReporting in const [false, true]) {
            final cursor = CursorState(
              x: 2,
              y: 1,
              visible: shape.index.isEven,
              shape: shape,
            );
            final modes = TerminalModes(
              mouseTracking: true,
              focusReporting: focusReporting,
            );
            final snapFrame = BufferSnapshotFrame(
              snapshot: BufferSnapshot.fromBuffer(
                sessionId: sessionId,
                seq: 1,
                buffer: buf,
                cursor: cursor,
                modes: modes,
              ),
            );
            final snapWire = BufferFrameCodec.encode(snapFrame);
            check(
              BufferFrameCodec.inspectRelayBufferFrame(
                snapWire,
                expectedSession: sessionId,
              ),
            ).equals((isSnapshot: true, seq: 1, cols: 4, rows: 2));
            final decodedSnap =
                (BufferFrameCodec.decode(snapWire) as BufferSnapshotFrame)
                    .snapshot;
            check(decodedSnap.cursor).equals(cursor);
            check(decodedSnap.cursor.hashCode).equals(cursor.hashCode);
            check(decodedSnap.modes).equals(modes);
            check(decodedSnap.modes.hashCode).equals(modes.hashCode);

            final deltaFrame = BufferDeltaFrame(
              delta: BufferDelta(
                sessionId: sessionId,
                seq: 2,
                baseSeq: 1,
                cols: 4,
                rows: 2,
                cursor: cursor,
                modes: modes,
                runs: const [],
              ),
            );
            final deltaWire = BufferFrameCodec.encode(deltaFrame);
            check(
              BufferFrameCodec.inspectRelayBufferFrame(
                deltaWire,
                expectedSession: sessionId,
              ),
            ).equals((isSnapshot: false, seq: 2, cols: 4, rows: 2));
            final decodedDelta =
                (BufferFrameCodec.decode(deltaWire) as BufferDeltaFrame).delta;
            check(decodedDelta.cursor).equals(cursor);
            check(decodedDelta.modes).equals(modes);
          }
        }

        // Clamps cursor.y > 0x1FFF to 0x1FFF and maps reserved shapeIndex == 7 (0xE000) to defaultShape.
        final clampedWire = BufferFrameCodec.encode(
          BufferDeltaFrame(
            delta: BufferDelta(
              sessionId: sessionId,
              seq: 3,
              baseSeq: 2,
              cols: 4,
              rows: 2,
              cursor: const CursorState(
                x: 1,
                y: 0xFFFF,
                visible: true,
                shape: CursorShape.steadyBar,
              ),
              modes: TerminalModes.defaults,
              runs: const [],
            ),
          ),
        );
        final decodedClamped =
            (BufferFrameCodec.decode(clampedWire) as BufferDeltaFrame).delta;
        check(decodedClamped.cursor.y).equals(0x1FFF);
        check(decodedClamped.cursor.shape).equals(CursorShape.steadyBar);

        // Mutate rawY top 3 bits to 7 (0xE000) in the wire frame and verify fallback to defaultShape.
        final reservedShapeWire = Uint8List.fromList(clampedWire);
        final sessionBytes = utf8.encode(sessionId.value).length;
        // Delta layout: version(1) + type(1) + sessionLen(2) + session + seq(8) + baseSeq(8) + cols(2) + rows(2) + cursorX(2) + cursorY(2)
        final cursorYOffset = 1 + 1 + 2 + sessionBytes + 8 + 8 + 2 + 2 + 2;
        final rawYView = ByteData.sublistView(reservedShapeWire);
        rawYView.setUint16(cursorYOffset, 0xE000 | 1, Endian.big);
        final decodedReserved =
            (BufferFrameCodec.decode(reservedShapeWire) as BufferDeltaFrame)
                .delta;
        check(decodedReserved.cursor.y).equals(1);
        check(decodedReserved.cursor.shape).equals(CursorShape.defaultShape);
      },
    );

    test(
      'applies CellRun delta via setRange and rejects baseSeq or size mismatch',
      () {
        const sessionId = SessionId('sess-delta');
        final clientBuffer = Buffer.blank(6, 2);
        clientBuffer.writeString(0, 0, 'abcdef', Style.empty);

        final delta = BufferDelta(
          sessionId: sessionId,
          seq: 11,
          baseSeq: 10,
          cols: 6,
          rows: 2,
          cursor: const CursorState(x: 3, y: 0, visible: false),
          modes: TerminalModes.defaults,
          runs: [
            CellRun(
              startIndex: 1,
              characters: const ['X', 'Y'],
              attributes: Uint32List.fromList([
                0xFF00FF00,
                0xFF000000,
                Modifier.bold,
                0xFF00FF00,
                0xFF000000,
                Modifier.bold,
              ]),
            ),
            CellRun(
              startIndex: 10,
              characters: const ['Z'],
              attributes: Uint32List.fromList([
                0xFFFFFFFF,
                0,
                Modifier.reverse,
              ]),
            ),
          ],
        );

        final wire = BufferFrameCodec.encode(BufferDeltaFrame(delta: delta));
        check(
          BufferFrameCodec.inspectRelayBufferFrame(
            wire,
            expectedSession: sessionId,
          ),
        ).equals((isSnapshot: false, seq: 11, cols: 6, rows: 2));
        check(
          BufferFrameCodec.inspectRelayBufferFrame(
            wire,
            expectedSession: const SessionId('other'),
          ),
        ).isNull();

        final decoded =
            (BufferFrameCodec.decode(wire) as BufferDeltaFrame).delta;

        // Reject stale baseSeq without mutating clientBuffer.
        final wrongSeq = BufferFrameCodec.applyDelta(
          buffer: clientBuffer,
          currentSeq: 9,
          delta: decoded,
        );
        check(wrongSeq).isFalse();
        check(clientBuffer.getCharacter(1, 0)).equals('b');

        // Reject mismatched dimensions without mutating clientBuffer.
        final otherSizeBuffer = Buffer.blank(5, 2);
        final wrongDims = BufferFrameCodec.applyDelta(
          buffer: otherSizeBuffer,
          currentSeq: 10,
          delta: decoded,
        );
        check(wrongDims).isFalse();

        // Apply cleanly when (baseSeq, cols, rows) match.
        final applied = BufferFrameCodec.applyDelta(
          buffer: clientBuffer,
          currentSeq: 10,
          delta: decoded,
        );
        check(applied).isTrue();
        check(clientBuffer.getCharacter(0, 0)).equals('a');
        check(clientBuffer.getCharacter(1, 0)).equals('X');
        check(clientBuffer.getCharacter(2, 0)).equals('Y');
        check(clientBuffer.getCharacter(3, 0)).equals('d');
        check(clientBuffer.getCharacter(4, 1)).equals('Z');
        check(clientBuffer.getForeground(1, 0)).equals(0xFF00FF00);
        check(clientBuffer.getModifiers(4, 1)).equals(Modifier.reverse);
      },
    );

    test('rejects oversized payloads, out-of-bounds headers, and bad runs', () {
      final oversized = Uint8List(BufferFrameCodec.maxFrameBytes + 1);
      check(
        () => BufferFrameCodec.decode(oversized),
      ).throws<ProtocolFormatException>();

      // Unknown protocol version.
      check(
        () => BufferFrameCodec.decode(Uint8List.fromList([99, 1])),
      ).throws<ProtocolFormatException>();

      // Oversized grid dimensions in RegisterSessionFrame / Snapshot header.
      final badSnapshot = BufferSnapshot(
        sessionId: const SessionId('bad-dims'),
        seq: 1,
        cols: BufferFrameCodec.maxGridCols + 1,
        rows: 24,
        cursor: CursorState.origin,
        modes: TerminalModes.defaults,
        characters: const [],
        attributes: Uint32List(0),
      );
      check(
        () =>
            BufferFrameCodec.encode(BufferSnapshotFrame(snapshot: badSnapshot)),
      ).throws<ProtocolFormatException>();

      // Out-of-bounds CellRun span.
      final target = Buffer.blank(4, 2);
      final outOfBoundsDelta = BufferDelta(
        sessionId: const SessionId('bad-run'),
        seq: 2,
        baseSeq: 1,
        cols: 4,
        rows: 2,
        cursor: CursorState.origin,
        modes: TerminalModes.defaults,
        runs: [
          CellRun(
            startIndex: 7,
            characters: const ['A', 'B'],
            attributes: Uint32List(6),
          ),
        ],
      );
      check(
        () => BufferFrameCodec.applyDelta(
          buffer: target,
          currentSeq: 1,
          delta: outOfBoundsDelta,
        ),
      ).throws<ProtocolFormatException>();

      // Empty CellRun (len == 0) and overlapping CellRuns are rejected.
      final emptyRunDelta = BufferDelta(
        sessionId: const SessionId('empty-run'),
        seq: 2,
        baseSeq: 1,
        cols: 4,
        rows: 2,
        cursor: CursorState.origin,
        modes: TerminalModes.defaults,
        runs: [
          CellRun(
            startIndex: 0,
            characters: const [],
            attributes: Uint32List(0),
          ),
        ],
      );
      check(
        () => BufferFrameCodec.encode(BufferDeltaFrame(delta: emptyRunDelta)),
      ).throws<ProtocolFormatException>();

      final overlappingDelta = BufferDelta(
        sessionId: const SessionId('overlap-run'),
        seq: 2,
        baseSeq: 1,
        cols: 4,
        rows: 2,
        cursor: CursorState.origin,
        modes: TerminalModes.defaults,
        runs: [
          CellRun(
            startIndex: 1,
            characters: const ['A', 'B'],
            attributes: Uint32List(6),
          ),
          CellRun(
            startIndex: 2,
            characters: const ['C'],
            attributes: Uint32List(3),
          ),
        ],
      );
      check(
        () =>
            BufferFrameCodec.encode(BufferDeltaFrame(delta: overlappingDelta)),
      ).throws<ProtocolFormatException>();

      // Control characters, whitespace, path separators, or '..' in SessionId are invalid.
      check(const SessionId('bad\x1b]2;pwn\x07').isValid).isFalse();
      check(const SessionId('bad space').isValid).isFalse();
      check(const SessionId('.').isValid).isFalse();
      check(const SessionId('..').isValid).isFalse();
      check(const SessionId('a..b').isValid).isFalse();
      check(const SessionId('../escape').isValid).isFalse();
      check(const SessionId('dir/sess').isValid).isFalse();
      check(const SessionId(r'dir\sess').isValid).isFalse();

      // InputFrame > 64 KiB (maxInputBytes) is rejected on encode and decode.
      check(
        BufferFrameCodec.encode(
          InputFrame(
            sessionId: const SessionId('input-ok'),
            data: Uint8List(BufferFrameCodec.maxInputBytes),
          ),
        ),
      ).isNotEmpty();
      check(
        () => BufferFrameCodec.encode(
          InputFrame(
            sessionId: const SessionId('input-big'),
            data: Uint8List(BufferFrameCodec.maxInputBytes + 1),
          ),
        ),
      ).throws<ProtocolFormatException>();
      final rawOversizedInput =
          (BytesBuilder()
                ..addByte(BufferFrameCodec.protocolVersion)
                ..addByte(0x0B) // _tagInput
                ..add([0, 2, ...'ok'.codeUnits])
                ..add([0x00, 0x01, 0x00, 0x01]) // 65537 > maxInputBytes
                ..add(Uint8List(BufferFrameCodec.maxInputBytes + 1)))
              .takeBytes();
      check(
        () => BufferFrameCodec.decode(rawOversizedInput),
      ).throws<ProtocolFormatException>();

      // Truncated 200x100 snapshot header fails before allocating 20,000 cells.
      final validHeader = BufferFrameCodec.encode(
        BufferSnapshotFrame(
          snapshot: BufferSnapshot.fromBuffer(
            sessionId: const SessionId('trunc'),
            seq: 1,
            buffer: Buffer.blank(200, 100),
            cursor: CursorState.origin,
            modes: TerminalModes.defaults,
          ),
        ),
      );
      final truncated = Uint8List.sublistView(validHeader, 0, 26);
      check(
        () => BufferFrameCodec.decode(truncated),
      ).throws<ProtocolFormatException>();
      check(
        () => BufferFrameCodec.inspectRelayBufferFrame(
          truncated,
          expectedSession: const SessionId('trunc'),
        ),
      ).throws<ProtocolFormatException>();

      // Decoded RegisterSessionFrame with oversized title (> 512 bytes) is rejected.
      final craftedOversizedTitle = BytesBuilder()
        ..addByte(BufferFrameCodec.protocolVersion)
        ..addByte(0x03) // RegisterSessionFrame
        ..addByte(0)
        ..addByte(2)
        ..add('ok'.codeUnits)
        ..addByte(2)
        ..addByte(0x58) // 600 bytes > 512 cap
        ..add(Uint8List(600))
        ..add([0, 80, 0, 24]);
      check(
        () => BufferFrameCodec.decode(craftedOversizedTitle.takeBytes()),
      ).throws<ProtocolFormatException>();
    });

    test(
      'inspectRelayBufferFrame validates grapheme spans, delta runs, baseSeq < seq, and trailing bytes',
      () {
        const sessionId = SessionId('relay-strict');
        final emojiBuf = Buffer.blank(2, 1)
          ..writeString(0, 0, '🚀', Style.empty);
        final validSnap = BufferFrameCodec.encode(
          BufferSnapshotFrame(
            snapshot: BufferSnapshot.fromBuffer(
              sessionId: sessionId,
              seq: 5,
              buffer: emojiBuf,
              cursor: CursorState.origin,
              modes: TerminalModes.defaults,
            ),
          ),
        );

        // Truncated by 2 bytes (still >= header + totalCells * 13 because '🚀' is 4 UTF-8 bytes).
        final truncatedEmojiSnap = Uint8List.sublistView(
          validSnap,
          0,
          validSnap.length - 2,
        );
        check(
          () => BufferFrameCodec.inspectRelayBufferFrame(
            truncatedEmojiSnap,
            expectedSession: sessionId,
          ),
        ).throws<ProtocolFormatException>();

        // Trailing byte after valid snapshot.
        final trailingSnap = Uint8List.fromList([...validSnap, 0x00]);
        check(
          () => BufferFrameCodec.inspectRelayBufferFrame(
            trailingSnap,
            expectedSession: sessionId,
          ),
        ).throws<ProtocolFormatException>();

        // Delta with baseSeq >= seq rejected in encode, decode, and inspectRelayBufferFrame.
        check(
              () => BufferFrameCodec.encode(
                BufferDeltaFrame(
                  delta: BufferDelta(
                    sessionId: sessionId,
                    seq: 5,
                    baseSeq: 5,
                    cols: 2,
                    rows: 1,
                    cursor: CursorState.origin,
                    modes: TerminalModes.defaults,
                    runs: const [],
                  ),
                ),
              ),
            )
            .throws<ProtocolFormatException>()
            .has((e) => e.message, 'message')
            .contains('must precede seq');

        Uint8List craftRawDelta({
          required int seq,
          required int baseSeq,
          required int cols,
          required int rows,
          List<int>? scrollbackBytes,
          List<int>? wrappedRowsBytes,
          required List<int> runPayload,
        }) {
          final b = BytesBuilder()
            ..addByte(BufferFrameCodec.protocolVersion)
            ..addByte(0x0A)
            ..add([0, sessionId.value.length, ...sessionId.value.codeUnits])
            ..add([0, 0, 0, 0, 0, 0, 0, seq])
            ..add([0, 0, 0, 0, 0, 0, 0, baseSeq])
            ..add([0, cols, 0, rows])
            ..add([0, 0, 0, 0, 0, 0, 0]) // cursor + modes (7 bytes)
            ..add(scrollbackBytes ?? List<int>.filled(20, 0))
            ..add(
              wrappedRowsBytes ??
                  List<int>.filled(wrappedRowsByteLength(rows), 0),
            )
            ..addByte(0) // compressionFlag = 0x00 (raw)
            ..add(runPayload);
          return b.takeBytes();
        }

        // Crafted delta with baseSeq == seq.
        final eqSeqDelta = craftRawDelta(
          seq: 4,
          baseSeq: 4,
          cols: 2,
          rows: 1,
          runPayload: const [0, 0, 0, 0],
        );
        check(() => BufferFrameCodec.decode(eqSeqDelta))
            .throws<ProtocolFormatException>()
            .has((e) => e.message, 'message')
            .contains('must precede seq');
        check(
              () => BufferFrameCodec.inspectRelayBufferFrame(
                eqSeqDelta,
                expectedSession: sessionId,
              ),
            )
            .throws<ProtocolFormatException>()
            .has((e) => e.message, 'message')
            .contains('must precede seq');

        // Crafted delta with runCount > totalCells (runCount=3 on 2x1 grid).
        final excessRunCountDelta = craftRawDelta(
          seq: 5,
          baseSeq: 4,
          cols: 2,
          rows: 1,
          runPayload: const [0, 0, 0, 3],
        );
        check(() => BufferFrameCodec.decode(excessRunCountDelta))
            .throws<ProtocolFormatException>()
            .has((e) => e.message, 'message')
            .contains('Delta runCount 3 > 2');
        check(
              () => BufferFrameCodec.inspectRelayBufferFrame(
                excessRunCountDelta,
                expectedSession: sessionId,
              ),
            )
            .throws<ProtocolFormatException>()
            .has((e) => e.message, 'message')
            .contains('Delta runCount 3 > 2');

        // Crafted delta with out-of-bounds CellRun (startIndex=2, len=1 on 2x1 grid).
        final oobRunDelta = craftRawDelta(
          seq: 5,
          baseSeq: 4,
          cols: 2,
          rows: 1,
          runPayload: [
            0, 0, 0, 1, // runCount = 1
            0, 0, 0, 2, // startIndex = 2 (out of bounds for totalCells = 2)
            0, 0, 0, 1, // len = 1
            1, 0x41, // 'A'
            ...List<int>.filled(12, 0), // 3 uint32 attrs
          ],
        );
        check(() => BufferFrameCodec.decode(oobRunDelta))
            .throws<ProtocolFormatException>()
            .has((e) => e.message, 'message')
            .contains('Invalid or overlapping CellRun');
        check(
              () => BufferFrameCodec.inspectRelayBufferFrame(
                oobRunDelta,
                expectedSession: sessionId,
              ),
            )
            .throws<ProtocolFormatException>()
            .has((e) => e.message, 'message')
            .contains('Invalid or overlapping CellRun');

        // Crafted delta with overlapping CellRuns (run0: 0..2, run1: 1..2).
        final overlapRunDelta = craftRawDelta(
          seq: 5,
          baseSeq: 4,
          cols: 4,
          rows: 1,
          runPayload: [
            0, 0, 0, 2, // runCount = 2
            0, 0, 0, 0, 0, 0, 0, 2, // start=0, len=2
            1, 0x41, 1, 0x42, ...List<int>.filled(24, 0), 0,
            0, 0, 0, 1, 0, 0, 0, 1, // start=1 (< nextMinStart=2), len=1
            1, 0x43, ...List<int>.filled(12, 0), 0,
            0, 0, 0, 0, 0, // delta Kitty trailer
          ],
        );
        check(() => BufferFrameCodec.decode(overlapRunDelta))
            .throws<ProtocolFormatException>()
            .has((e) => e.message, 'message')
            .contains('Invalid or overlapping CellRun');
        check(
              () => BufferFrameCodec.inspectRelayBufferFrame(
                overlapRunDelta,
                expectedSession: sessionId,
              ),
            )
            .throws<ProtocolFormatException>()
            .has((e) => e.message, 'message')
            .contains('Invalid or overlapping CellRun');
      },
    );

    test(
      'wraps invalid UTF-8 strings and >= 0x80 single-byte graphemes in ProtocolFormatException',
      () {
        const sessionId = SessionId('bad-utf8');
        // 1. Invalid UTF-8 in readString16 (AuthFrame token).
        final badAuthString = Uint8List.fromList([
          BufferFrameCodec.protocolVersion,
          0x01, // AuthFrame
          0x00, // caster
          0x00,
          0x02, // 2 bytes
          0xC3,
          0x28, // invalid UTF-8 sequence
        ]);
        check(() => BufferFrameCodec.decode(badAuthString))
            .throws<ProtocolFormatException>()
            .has((e) => e.message, 'message')
            .contains('Invalid UTF-8 payload');

        // 2. Single-byte >= 0x80 grapheme (lenMarker = 1, byte = 0xFF) in 1x1 snapshot.
        final singleHighByteSnap = BytesBuilder()
          ..addByte(BufferFrameCodec.protocolVersion)
          ..addByte(0x09)
          ..add([0, sessionId.value.length, ...sessionId.value.codeUnits])
          ..add([0, 0, 0, 0, 0, 0, 0, 1]) // seq = 1
          ..add([0, 1, 0, 1]) // 1x1
          ..add([0, 0, 0, 0, 0, 0, 0]) // cursor + modes (7 bytes)
          ..add(List<int>.filled(20, 0)) // ScrollbackWindow (20 bytes)
          ..addByte(0) // wrappedRows (1 byte for 1 row)
          ..addByte(0) // compressionFlag = 0x00 (raw)
          ..add([1, 0xFF]) // lenMarker = 1, invalid single-byte >= 0x80
          ..add(List<int>.filled(12, 0))
          ..add([0, 0, 0]); // auxFlags + kittyCount
        final singleHighBytes = singleHighByteSnap.takeBytes();
        check(() => BufferFrameCodec.decode(singleHighBytes))
            .throws<CorruptSessionFrameException>()
            .has((e) => e.message, 'message')
            .contains('Invalid single-byte grapheme');
        check(
              () => BufferFrameCodec.inspectRelayBufferFrame(
                singleHighBytes,
                expectedSession: sessionId,
              ),
            )
            .throws<ProtocolFormatException>()
            .has((e) => e.message, 'message')
            .contains('Invalid single-byte grapheme');

        // 3. Multi-byte invalid UTF-8 grapheme (lenMarker = 2, [0xFF, 0xFF]) in 1x1 snapshot.
        final multiBadUtf8Snap = BytesBuilder()
          ..addByte(BufferFrameCodec.protocolVersion)
          ..addByte(0x09)
          ..add([0, sessionId.value.length, ...sessionId.value.codeUnits])
          ..add([0, 0, 0, 0, 0, 0, 0, 1])
          ..add([0, 1, 0, 1])
          ..add([0, 0, 0, 0, 0, 0, 0])
          ..add(List<int>.filled(20, 0)) // ScrollbackWindow (20 bytes)
          ..addByte(0) // wrappedRows (1 byte for 1 row)
          ..addByte(0) // compressionFlag = 0x00 (raw)
          ..add([2, 0xFF, 0xFF])
          ..add(List<int>.filled(12, 0))
          ..add([0, 0, 0]); // auxFlags + kittyCount
        final multiBadBytes = multiBadUtf8Snap.takeBytes();
        check(() => BufferFrameCodec.decode(multiBadBytes))
            .throws<CorruptSessionFrameException>()
            .has((e) => e.message, 'message')
            .contains('Invalid UTF-8 payload');
        check(
              () => BufferFrameCodec.inspectRelayBufferFrame(
                multiBadBytes,
                expectedSession: sessionId,
              ),
            )
            .throws<ProtocolFormatException>()
            .has((e) => e.message, 'message')
            .contains('Invalid UTF-8 payload');
      },
    );

    test(
      'sanitizes C0/DEL/C1 control characters on encode and rejects hostile control bytes on decode/inspect',
      () {
        const sessionId = SessionId('no-ctrl-cells');
        const hostileGraphemes = [
          '\x1b',
          '\x07',
          '\x7f',
          '\x9b',
          'a\x1b]52;c;?\x07',
        ];

        for (final grapheme in hostileGraphemes) {
          final snapWire = BufferFrameCodec.encode(
            BufferSnapshotFrame(
              snapshot: BufferSnapshot(
                sessionId: sessionId,
                seq: 1,
                cols: 2,
                rows: 1,
                cursor: CursorState.origin,
                modes: TerminalModes.defaults,
                characters: [grapheme, ' '],
                attributes: Uint32List(6),
              ),
            ),
          );
          final decodedSnap =
              BufferFrameCodec.decode(snapWire) as BufferSnapshotFrame;
          final expectedClean = grapheme == 'a\x1b]52;c;?\x07'
              ? 'a]52;c;?'
              : '';
          check(decodedSnap.snapshot.characters[0]).equals(expectedClean);

          final deltaWire = BufferFrameCodec.encode(
            BufferDeltaFrame(
              delta: BufferDelta(
                sessionId: sessionId,
                seq: 2,
                baseSeq: 1,
                cols: 2,
                rows: 1,
                cursor: CursorState.origin,
                modes: TerminalModes.defaults,
                runs: [
                  CellRun(
                    startIndex: 0,
                    characters: [grapheme],
                    attributes: Uint32List(3),
                  ),
                ],
              ),
            ),
          );
          final decodedDelta =
              BufferFrameCodec.decode(deltaWire) as BufferDeltaFrame;
          check(
            decodedDelta.delta.runs.single.characters.single,
          ).equals(expectedClean);

          // Raw hostile control bytes on the wire still fail decode and inspect.
          final rawBytes = utf8.encode(grapheme);
          final hostileDeltaWire = Uint8List.fromList([
            BufferFrameCodec.protocolVersion,
            0x0A,
            0,
            sessionId.value.length,
            ...sessionId.value.codeUnits,
            0, 0, 0, 0, 0, 0, 0, 2, // seq
            0, 0, 0, 0, 0, 0, 0, 1, // baseSeq
            0, 2, 0, 1, // 2x1
            0, 0, 0, 0, 0, 0, 0, // cursor + modes
            ...List<int>.filled(20, 0), // scrollback
            0, // wrappedRows
            0, // compressionFlag = 0x00 raw
            0, 0, 0, 1, // runCount = 1
            0, 0, 0, 0, // startIndex = 0
            0, 0, 0, 1, // len = 1
            rawBytes.length,
            ...rawBytes,
            ...List<int>.filled(12, 0), // attrs
            0, // auxFlags = 0
            0, // clearKittyImages = 0
            0, 0, // removals = 0
            0, 0, // upserts = 0
          ]);
          check(
            () => BufferFrameCodec.decode(hostileDeltaWire),
          ).throws<ProtocolFormatException>();
          check(
            () => BufferFrameCodec.inspectRelayBufferFrame(
              hostileDeltaWire,
              expectedSession: sessionId,
            ),
          ).throws<ProtocolFormatException>();
        }
      },
    );

    test(
      'validates ClipboardFrame readBlocked byte and forbids non-empty text when readBlocked',
      () {
        const sessionId = SessionId('s');
        check(
          () => BufferFrameCodec.encode(
            const ClipboardFrame(
              sessionId: sessionId,
              text: 'x',
              readBlocked: true,
            ),
          ),
        ).throws<ProtocolFormatException>();

        // Crafted ClipboardFrame with readBlocked byte == 2.
        final badFlagBytes = BytesBuilder()
          ..addByte(BufferFrameCodec.protocolVersion)
          ..addByte(0x0F) // _tagClipboard
          ..add([0, 1, ...'s'.codeUnits])
          ..addByte(2) // invalid readBlocked byte
          ..add([0, 0, 0, 0]);
        check(
          () => BufferFrameCodec.decode(badFlagBytes.takeBytes()),
        ).throws<ProtocolFormatException>();

        // Crafted ClipboardFrame with readBlocked byte == 1 and non-empty text 'x'.
        final blockedWithTextBytes = BytesBuilder()
          ..addByte(BufferFrameCodec.protocolVersion)
          ..addByte(0x0F) // _tagClipboard
          ..add([0, 1, ...'s'.codeUnits])
          ..addByte(1) // readBlocked == true
          ..add([0, 0, 0, 1, ...'x'.codeUnits]);
        check(
          () => BufferFrameCodec.decode(blockedWithTextBytes.takeBytes()),
        ).throws<ProtocolFormatException>();
      },
    );

    test(
      'round-trips extended TerminalModes, ScrollbackWindow, wrappedRows, and mixed-width scrollback chunks',
      () {
        const sessionId = SessionId('sess-scrollback');
        const modes = TerminalModes(
          mouseTracking: true,
          sgrMouse: false,
          bracketedPaste: true,
          altScreen: true,
          appCursorKeys: true,
          alternateScroll: false,
        );
        const scrollback = ScrollbackWindow(
          clearSeq: 3,
          oldestLine: 1000,
          totalLines: 6000,
        );
        final buf = Buffer.blank(4, 10);
        buf.writeString(0, 0, 'test', Style.empty);
        final snapWrapped = packWrappedRows(
          10,
          (r) => r == 0 || r == 5 || r == 9,
        );

        final snapshotBytes = BufferFrameCodec.encode(
          BufferSnapshotFrame(
            snapshot: BufferSnapshot.fromBuffer(
              sessionId: sessionId,
              seq: 42,
              buffer: buf,
              cursor: CursorState.origin,
              modes: modes,
              scrollback: scrollback,
              wrappedRows: snapWrapped,
            ),
          ),
        );
        check(
          BufferFrameCodec.inspectRelayBufferFrame(
            snapshotBytes,
            expectedSession: sessionId,
          ),
        ).equals((isSnapshot: true, seq: 42, cols: 4, rows: 10));
        final decodedSnapshot =
            BufferFrameCodec.decode(snapshotBytes) as BufferSnapshotFrame;
        check(decodedSnapshot.snapshot.modes).equals(modes);
        check(decodedSnapshot.snapshot.scrollback).equals(scrollback);
        check(decodedSnapshot.snapshot.isRowWrapped(0)).isTrue();
        check(decodedSnapshot.snapshot.isRowWrapped(1)).isFalse();
        check(decodedSnapshot.snapshot.isRowWrapped(5)).isTrue();
        check(decodedSnapshot.snapshot.isRowWrapped(9)).isTrue();

        // Also verify full-byte boundary (rows == 8 -> 1 byte, all 8 bits used).
        final fullByteDelta = BufferFrameCodec.encode(
          BufferDeltaFrame(
            delta: BufferDelta(
              sessionId: sessionId,
              seq: 43,
              baseSeq: 42,
              cols: 4,
              rows: 8,
              cursor: CursorState.origin,
              modes: modes,
              scrollback: scrollback,
              wrappedRows: packWrappedRows(8, (_) => true),
              runs: const [],
            ),
          ),
        );
        check(
          BufferFrameCodec.inspectRelayBufferFrame(
            fullByteDelta,
            expectedSession: sessionId,
          ),
        ).equals((isSnapshot: false, seq: 43, cols: 4, rows: 8));
        final decodedDelta =
            BufferFrameCodec.decode(fullByteDelta) as BufferDeltaFrame;
        check(decodedDelta.delta.modes).equals(modes);
        check(decodedDelta.delta.scrollback).equals(scrollback);
        for (var r = 0; r < 8; r++) {
          check(decodedDelta.delta.isRowWrapped(r)).isTrue();
        }

        const req = RequestScrollbackFrame(
          sessionId: sessionId,
          requestId: 7,
          clearSeq: 3,
          startLine: 1000,
          count: 128,
        );
        final reqDecoded =
            BufferFrameCodec.decode(BufferFrameCodec.encode(req))
                as RequestScrollbackFrame;
        check(reqDecoded.requestId).equals(7);
        check(reqDecoded.clearSeq).equals(3);
        check(reqDecoded.startLine).equals(1000);
        check(reqDecoded.count).equals(128);

        // Mixed-width rows in the same chunk: 120 cells, 80 cells, emoji row, and 0-cell blank row!
        final row120 = List<String>.generate(
          120,
          (i) => String.fromCharCode(0x41 + (i % 26)),
        );
        final row80 = List<String>.generate(
          80,
          (i) => String.fromCharCode(0x61 + (i % 26)),
        );
        final chunk = ScrollbackChunkFrame(
          sessionId: sessionId,
          requestId: 7,
          clearSeq: 3,
          startLine: 1000,
          rows: [
            EncodedScrollbackRow(
              isWrapped: true,
              characters: row120,
              attributes: Uint32List(120 * 3),
            ),
            EncodedScrollbackRow(
              isWrapped: false,
              characters: row80,
              attributes: Uint32List(80 * 3),
            ),
            EncodedScrollbackRow(
              isWrapped: true,
              characters: const ['🚀', ''],
              attributes: Uint32List.fromList([0xFF112233, 0, 1, 0, 0, 0]),
            ),
            EncodedScrollbackRow(
              isWrapped: false,
              characters: const [],
              attributes: Uint32List(0),
            ),
          ],
        );
        final chunkDecoded =
            BufferFrameCodec.decode(BufferFrameCodec.encode(chunk))
                as ScrollbackChunkFrame;
        check(chunkDecoded.requestId).equals(7);
        check(chunkDecoded.clearSeq).equals(3);
        check(chunkDecoded.startLine).equals(1000);
        check(chunkDecoded.rows.length).equals(4);
        check(chunkDecoded.rows[0].isWrapped).isTrue();
        check(chunkDecoded.rows[0].characters).deepEquals(row120);
        check(chunkDecoded.rows[1].isWrapped).isFalse();
        check(chunkDecoded.rows[1].characters).deepEquals(row80);
        check(chunkDecoded.rows[2].isWrapped).isTrue();
        check(chunkDecoded.rows[2].characters).deepEquals(['🚀', '']);
        check(chunkDecoded.rows[3].isWrapped).isFalse();
        check(chunkDecoded.rows[3].characters).isEmpty();
      },
    );

    test(
      'rejects hostile v2 scrollback windows, wrappedRows bits, and 0x10/0x11 wire bounds on encode, decode, and inspect',
      () {
        const sessionId = SessionId('sess-bounds');

        // 1. Encode bounds: oldestLine > totalLines, bad wrappedRows length/high bits, 0x10 count, 0x11 rowCount/cellCount/attrs.
        check(
              () => BufferFrameCodec.encode(
                BufferDeltaFrame(
                  delta: BufferDelta(
                    sessionId: sessionId,
                    seq: 2,
                    baseSeq: 1,
                    cols: 4,
                    rows: 2,
                    cursor: CursorState.origin,
                    modes: TerminalModes.defaults,
                    scrollback: const ScrollbackWindow(
                      clearSeq: 0,
                      oldestLine: 10,
                      totalLines: 5,
                    ),
                    runs: const [],
                  ),
                ),
              ),
            )
            .throws<ProtocolFormatException>()
            .has((e) => e.message, 'message')
            .contains('Invalid scrollback window');

        check(
              () => BufferFrameCodec.encode(
                BufferDeltaFrame(
                  delta: BufferDelta(
                    sessionId: sessionId,
                    seq: 2,
                    baseSeq: 1,
                    cols: 4,
                    rows: 10,
                    cursor: CursorState.origin,
                    modes: TerminalModes.defaults,
                    wrappedRows: Uint8List(1), // needs 2 bytes for 10 rows
                    runs: const [],
                  ),
                ),
              ),
            )
            .throws<ProtocolFormatException>()
            .has((e) => e.message, 'message')
            .contains('Invalid wrappedRows byte length');

        check(
              () => BufferFrameCodec.encode(
                BufferDeltaFrame(
                  delta: BufferDelta(
                    sessionId: sessionId,
                    seq: 2,
                    baseSeq: 1,
                    cols: 4,
                    rows: 10,
                    cursor: CursorState.origin,
                    modes: TerminalModes.defaults,
                    wrappedRows: Uint8List.fromList([
                      0x00,
                      0x04,
                    ]), // bit 2 unused
                    runs: const [],
                  ),
                ),
              ),
            )
            .throws<ProtocolFormatException>()
            .has((e) => e.message, 'message')
            .contains('Non-zero unused high bits in wrappedRows');

        check(
              () => BufferFrameCodec.encode(
                const RequestScrollbackFrame(
                  sessionId: sessionId,
                  requestId: 1,
                  clearSeq: 0,
                  startLine: 0,
                  count: 0,
                ),
              ),
            )
            .throws<ProtocolFormatException>()
            .has((e) => e.message, 'message')
            .contains('Invalid scrollback request count');

        check(
              () => BufferFrameCodec.encode(
                const RequestScrollbackFrame(
                  sessionId: sessionId,
                  requestId: 1,
                  clearSeq: 0,
                  startLine: 0,
                  count: ScrollbackChunkFrame.maxChunkRows + 1,
                ),
              ),
            )
            .throws<ProtocolFormatException>()
            .has((e) => e.message, 'message')
            .contains('Invalid scrollback request count');

        check(
              () => BufferFrameCodec.encode(
                ScrollbackChunkFrame(
                  sessionId: sessionId,
                  requestId: 1,
                  clearSeq: 0,
                  startLine: 0,
                  rows: List<EncodedScrollbackRow>.filled(
                    ScrollbackChunkFrame.maxChunkRows + 1,
                    EncodedScrollbackRow(
                      isWrapped: false,
                      characters: const ['a'],
                      attributes: Uint32List(3),
                    ),
                  ),
                ),
              ),
            )
            .throws<ProtocolFormatException>()
            .has((e) => e.message, 'message')
            .contains('Scrollback chunk row count exceeds cap');

        check(
              () => BufferFrameCodec.encode(
                ScrollbackChunkFrame(
                  sessionId: sessionId,
                  requestId: 1,
                  clearSeq: 0,
                  startLine: 0,
                  rows: [
                    EncodedScrollbackRow(
                      isWrapped: false,
                      characters: List<String>.filled(
                        BufferFrameCodec.maxGridCols + 1,
                        'a',
                      ),
                      attributes: Uint32List(
                        (BufferFrameCodec.maxGridCols + 1) * 3,
                      ),
                    ),
                  ],
                ),
              ),
            )
            .throws<ProtocolFormatException>()
            .has((e) => e.message, 'message')
            .contains('Invalid scrollback row cells=401');

        check(
              () => BufferFrameCodec.encode(
                ScrollbackChunkFrame(
                  sessionId: sessionId,
                  requestId: 1,
                  clearSeq: 0,
                  startLine: 0,
                  rows: [
                    EncodedScrollbackRow(
                      isWrapped: false,
                      characters: const ['a', 'b'],
                      attributes: Uint32List(3), // mismatch != 6
                    ),
                  ],
                ),
              ),
            )
            .throws<ProtocolFormatException>()
            .has((e) => e.message, 'message')
            .contains('Invalid scrollback row cells=2');

        // 2. Raw-byte decode & inspectRelayBufferFrame for oldestLine > totalLines (10 > 5).
        final badWindowBytes = <int>[
          0, 0, 0, 0, // clearSeq = 0
          0, 0, 0, 0, 0, 0, 0, 10, // oldestLine = 10
          0, 0, 0, 0, 0, 0, 0, 5, // totalLines = 5
        ];
        final rawBadWindowDelta =
            (BytesBuilder()
                  ..addByte(BufferFrameCodec.protocolVersion)
                  ..addByte(0x0A)
                  ..add([
                    0,
                    sessionId.value.length,
                    ...sessionId.value.codeUnits,
                  ])
                  ..add([0, 0, 0, 0, 0, 0, 0, 2]) // seq = 2
                  ..add([0, 0, 0, 0, 0, 0, 0, 1]) // baseSeq = 1
                  ..add([0, 2, 0, 1]) // 2x1
                  ..add([0, 0, 0, 0, 0, 0, 0]) // cursor + modes (7 bytes)
                  ..add(badWindowBytes)
                  ..addByte(0) // wrappedRows
                  ..add([0, 0, 0, 0])) // runCount = 0
                .takeBytes();
        check(() => BufferFrameCodec.decode(rawBadWindowDelta))
            .throws<ProtocolFormatException>()
            .has((e) => e.message, 'message')
            .contains('Invalid scrollback window: oldest 10 > total 5');
        check(
              () => BufferFrameCodec.inspectRelayBufferFrame(
                rawBadWindowDelta,
                expectedSession: sessionId,
              ),
            )
            .throws<ProtocolFormatException>()
            .has((e) => e.message, 'message')
            .contains('Invalid scrollback window: oldest 10 > total 5');

        // 3. Raw-byte decode & inspectRelayBufferFrame for non-zero unused high bits in wrappedRows (rows=10, [0x00, 0x04]).
        final rawBadWrappedDelta =
            (BytesBuilder()
                  ..addByte(BufferFrameCodec.protocolVersion)
                  ..addByte(0x0A)
                  ..add([
                    0,
                    sessionId.value.length,
                    ...sessionId.value.codeUnits,
                  ])
                  ..add([0, 0, 0, 0, 0, 0, 0, 2])
                  ..add([0, 0, 0, 0, 0, 0, 0, 1])
                  ..add([
                    0,
                    2,
                    0,
                    10,
                  ]) // 2x10 -> 2 wrappedRows bytes (bits 2..7 of byte 1 unused)
                  ..add([0, 0, 0, 0, 0, 0, 0])
                  ..add(List<int>.filled(20, 0))
                  ..add([0x00, 0x04]) // bit 2 set!
                  ..add([0, 0, 0, 0]))
                .takeBytes();
        check(() => BufferFrameCodec.decode(rawBadWrappedDelta))
            .throws<ProtocolFormatException>()
            .has((e) => e.message, 'message')
            .contains('Non-zero unused high bits in wrappedRows');
        check(
              () => BufferFrameCodec.inspectRelayBufferFrame(
                rawBadWrappedDelta,
                expectedSession: sessionId,
              ),
            )
            .throws<ProtocolFormatException>()
            .has((e) => e.message, 'message')
            .contains('Non-zero unused high bits in wrappedRows');

        // 4. Raw-byte RequestScrollbackFrame (0x10): count == 0 and count == 129.
        Uint8List rawRequestScrollback(int count) =>
            (BytesBuilder()
                  ..addByte(BufferFrameCodec.protocolVersion)
                  ..addByte(0x10)
                  ..add([
                    0,
                    sessionId.value.length,
                    ...sessionId.value.codeUnits,
                  ])
                  ..add([0, 0, 0, 1]) // requestId
                  ..add([0, 0, 0, 0]) // clearSeq
                  ..add(List<int>.filled(8, 0)) // startLine
                  ..add([(count >> 8) & 0xFF, count & 0xFF]))
                .takeBytes();

        for (final badCount in [0, 129]) {
          check(() => BufferFrameCodec.decode(rawRequestScrollback(badCount)))
              .throws<ProtocolFormatException>()
              .has((e) => e.message, 'message')
              .contains('Invalid scrollback request count: $badCount');
        }

        // 5. Raw-byte ScrollbackChunkFrame (0x11): rowCount == 129, rawFlags == 2, cellCount == 401 (and cellCount == 0 valid blank row).
        Uint8List rawChunkHeader(int rowCount, List<int> rowBytes) =>
            (BytesBuilder()
                  ..addByte(BufferFrameCodec.protocolVersion)
                  ..addByte(0x11)
                  ..add([
                    0,
                    sessionId.value.length,
                    ...sessionId.value.codeUnits,
                  ])
                  ..add([0, 0, 0, 1]) // requestId
                  ..add([0, 0, 0, 0]) // clearSeq
                  ..add(List<int>.filled(8, 0)) // startLine
                  ..add([(rowCount >> 8) & 0xFF, rowCount & 0xFF])
                  ..addByte(0) // compressionFlag = 0x00 (raw)
                  ..add(rowBytes))
                .takeBytes();

        check(() => BufferFrameCodec.decode(rawChunkHeader(129, const [])))
            .throws<ProtocolFormatException>()
            .has((e) => e.message, 'message')
            .contains('Scrollback chunk row count exceeds cap: 129');

        check(() => BufferFrameCodec.decode(rawChunkHeader(1, const [2, 0, 0])))
            .throws<ProtocolFormatException>()
            .has((e) => e.message, 'message')
            .contains('Invalid scrollback row flags byte: 2');

        check(
              () => BufferFrameCodec.decode(
                rawChunkHeader(1, const [0, 0x01, 0x91]), // cellCount = 401
              ),
            )
            .throws<ProtocolFormatException>()
            .has((e) => e.message, 'message')
            .contains('Scrollback row cells 401 > 400');

        // Blank trimmed scrollback row (cellCount == 0 + auxFlags == 0) decodes cleanly.
        final blankDecoded =
            BufferFrameCodec.decode(rawChunkHeader(1, const [0, 0, 0, 0]))
                as ScrollbackChunkFrame;
        check(blankDecoded.rows.single.characters).isEmpty();
      },
    );

    test(
      'round-trips file upload frames (0x12..0x15) and rejects malformed filenames, chunks, digests, and status bytes',
      () {
        const sessionId = SessionId('sess-upload');
        final start = const FileUploadStartFrame(
          sessionId: sessionId,
          transferId: 42,
          fileName: 'archive 🚀.tar.gz',
          totalBytes: 131072,
        );
        final decodedStart =
            BufferFrameCodec.decode(BufferFrameCodec.encode(start))
                as FileUploadStartFrame;
        check(decodedStart.sessionId).equals(sessionId);
        check(decodedStart.transferId).equals(42);
        check(decodedStart.fileName).equals('archive 🚀.tar.gz');
        check(decodedStart.totalBytes).equals(131072);

        final chunkData = Uint8List.fromList(
          List<int>.generate(1024, (i) => i & 0xFF),
        );
        final chunk = FileUploadChunkFrame(
          sessionId: sessionId,
          transferId: 42,
          offset: 65536,
          data: chunkData,
        );
        final decodedChunk =
            BufferFrameCodec.decode(BufferFrameCodec.encode(chunk))
                as FileUploadChunkFrame;
        check(decodedChunk.sessionId).equals(sessionId);
        check(decodedChunk.transferId).equals(42);
        check(decodedChunk.offset).equals(65536);
        check(decodedChunk.data).deepEquals(chunkData);

        final digest = Uint8List.fromList(List<int>.generate(32, (i) => i + 1));
        final endComplete = FileUploadEndFrame(
          sessionId: sessionId,
          transferId: 42,
          sha256: digest,
        );
        final decodedEnd =
            BufferFrameCodec.decode(BufferFrameCodec.encode(endComplete))
                as FileUploadEndFrame;
        check(decodedEnd.aborted).isFalse();
        check(decodedEnd.sha256).deepEquals(digest);

        final endAbort = FileUploadEndFrame(
          sessionId: sessionId,
          transferId: 42,
          sha256: Uint8List(0),
          aborted: true,
        );
        final decodedAbort =
            BufferFrameCodec.decode(BufferFrameCodec.encode(endAbort))
                as FileUploadEndFrame;
        check(decodedAbort.aborted).isTrue();
        check(decodedAbort.sha256).isEmpty();

        for (final status in FileUploadStatus.values) {
          final ack = FileUploadAckFrame(
            sessionId: sessionId,
            transferId: 42,
            status: status,
            nextOffset: 65536,
            message: status == .completed ? '/tmp/archive.tar.gz' : 'ok',
          );
          final decodedAck =
              BufferFrameCodec.decode(BufferFrameCodec.encode(ack))
                  as FileUploadAckFrame;
          check(decodedAck.status).equals(status);
          check(decodedAck.nextOffset).equals(65536);
          check(decodedAck.message).equals(ack.message);
        }

        // Reject invalid filenames (empty, '.', '..', slashes, control chars, > 255 bytes).
        for (final badName in [
          '',
          '.',
          '..',
          '../secret',
          r'sub\file.txt',
          'bad\x00name',
          'bad\x1bname',
          'a' * 256,
        ]) {
          check(
            () => BufferFrameCodec.encode(
              FileUploadStartFrame(
                sessionId: sessionId,
                transferId: 1,
                fileName: badName,
                totalBytes: 10,
              ),
            ),
          ).throws<ProtocolFormatException>();
        }

        // Reject empty or > 64 KiB upload chunks.
        check(
          () => BufferFrameCodec.encode(
            FileUploadChunkFrame(
              sessionId: sessionId,
              transferId: 1,
              offset: 0,
              data: Uint8List(0),
            ),
          ),
        ).throws<ProtocolFormatException>();
        check(
          () => BufferFrameCodec.encode(
            FileUploadChunkFrame(
              sessionId: sessionId,
              transferId: 1,
              offset: 0,
              data: Uint8List(FileUploadChunkFrame.maxChunkBytes + 1),
            ),
          ),
        ).throws<ProtocolFormatException>();

        // Reject wrong sha256 byte length on FileUploadEndFrame.
        check(
          () => BufferFrameCodec.encode(
            FileUploadEndFrame(
              sessionId: sessionId,
              transferId: 1,
              sha256: Uint8List(16),
              aborted: false,
            ),
          ),
        ).throws<ProtocolFormatException>();
        check(
          () => BufferFrameCodec.encode(
            FileUploadEndFrame(
              sessionId: sessionId,
              transferId: 1,
              sha256: digest,
              aborted: true,
            ),
          ),
        ).throws<ProtocolFormatException>();

        // Raw decode rejections: bad aborted byte (2) and bad status byte (9).
        final rawBadAborted =
            (BytesBuilder()
                  ..addByte(BufferFrameCodec.protocolVersion)
                  ..addByte(0x14)
                  ..add([0, 1, ...'s'.codeUnits])
                  ..add([0, 0, 0, 1])
                  ..addByte(2)
                  ..add([0, 0, 0, 0]))
                .takeBytes();
        check(
          () => BufferFrameCodec.decode(rawBadAborted),
        ).throws<ProtocolFormatException>();

        final rawBadStatus =
            (BytesBuilder()
                  ..addByte(BufferFrameCodec.protocolVersion)
                  ..addByte(0x15)
                  ..add([0, 1, ...'s'.codeUnits])
                  ..add([0, 0, 0, 1])
                  ..addByte(9)
                  ..add(List<int>.filled(8, 0))
                  ..add([0, 0]))
                .takeBytes();
        check(
          () => BufferFrameCodec.decode(rawBadStatus),
        ).throws<ProtocolFormatException>();
      },
    );

    test(
      'protocol v7 validates resumeToken, SessionCloseReason, RenameSessionFrame, and hostile titles',
      () {
        check(BufferFrameCodec.protocolVersion).equals(7);
        const sessionId = SessionId('sess-v3');

        // Default RegisterSessionFrame resumeToken is 16 zero bytes.
        final defaultReg = RegisterSessionFrame(
          sessionId: sessionId,
          title: 'build',
          cols: 80,
          rows: 24,
        );
        check(defaultReg.resumeToken).deepEquals(Uint8List(16));
        final decodedReg =
            BufferFrameCodec.decode(BufferFrameCodec.encode(defaultReg))
                as RegisterSessionFrame;
        check(decodedReg.resumeToken).deepEquals(Uint8List(16));

        // Wrong resumeToken byte length is rejected on encode and truncated decode.
        for (final badLen in [0, 15, 17, 32]) {
          check(
            () => BufferFrameCodec.encode(
              RegisterSessionFrame(
                sessionId: sessionId,
                title: 'build',
                cols: 80,
                rows: 24,
                resumeToken: Uint8List(badLen),
              ),
            ),
          ).throws<ProtocolFormatException>();
        }
        final validRegBytes = BufferFrameCodec.encode(defaultReg);
        check(
          () => BufferFrameCodec.decode(
            Uint8List.sublistView(validRegBytes, 0, validRegBytes.length - 1),
          ),
        ).throws<ProtocolFormatException>();

        // SessionClosedFrame defaults to exited(0) and round-trips both reasons.
        const defaultClosed = SessionClosedFrame(
          sessionId: sessionId,
          exitCode: 0,
        );
        check(defaultClosed.reason).equals(SessionCloseReason.exited);
        for (final reason in SessionCloseReason.values) {
          final closed = SessionClosedFrame(
            sessionId: sessionId,
            reason: reason,
            exitCode: reason == .exited ? 42 : -1,
          );
          final decodedClosed =
              BufferFrameCodec.decode(BufferFrameCodec.encode(closed))
                  as SessionClosedFrame;
          check(decodedClosed.reason).equals(reason);
          check(decodedClosed.exitCode).equals(closed.exitCode);
        }

        // Invalid SessionCloseReason wire byte (2) is rejected.
        final rawBadReason =
            (BytesBuilder()
                  ..addByte(BufferFrameCodec.protocolVersion)
                  ..addByte(0x0D)
                  ..add([0, 1, ...'s'.codeUnits])
                  ..addByte(2)
                  ..add([0, 0, 0, 0]))
                .takeBytes();
        check(
          () => BufferFrameCodec.decode(rawBadReason),
        ).throws<ProtocolFormatException>();

        // RenameSessionFrame round-trips max-length UTF-8 titles (512 bytes).
        final maxTitle = '🚀' * 128; // 512 UTF-8 bytes
        final rename = RenameSessionFrame(
          sessionId: sessionId,
          title: maxTitle,
        );
        final decodedRename =
            BufferFrameCodec.decode(BufferFrameCodec.encode(rename))
                as RenameSessionFrame;
        check(decodedRename.sessionId).equals(sessionId);
        check(decodedRename.title).equals(maxTitle);

        // Shared boundary title validation rejects untrimmed, empty, >512-byte, C0/C1, and bidi titles
        // across RegisterSessionFrame, SessionDirectoryFrame, and RenameSessionFrame on encode & decode.
        final hostileTitles = <String>[
          '',
          '   ',
          ' leading',
          'trailing ',
          'a' * 513,
          '🚀' * 129,
          'esc\x1b]2;pwn\x07',
          'nul\x00byte',
          'line\nbreak',
          'del\x7fchar',
          'c1\u009bcsi',
          'rlo\u202epwn',
          'lre\u202apwn',
          'lri\u2066pwn',
          'pdi\u2069pwn',
        ];
        for (final badTitle in hostileTitles) {
          check(
            () => BufferFrameCodec.validateTitle(badTitle),
          ).throws<ProtocolFormatException>();
          check(
            () => BufferFrameCodec.encode(
              RegisterSessionFrame(
                sessionId: sessionId,
                title: badTitle,
                cols: 80,
                rows: 24,
              ),
            ),
          ).throws<ProtocolFormatException>();
          check(
            () => BufferFrameCodec.encode(
              SessionDirectoryFrame(
                sessions: [
                  SessionSummary(
                    id: sessionId,
                    title: badTitle,
                    cols: 80,
                    rows: 24,
                  ),
                ],
              ),
            ),
          ).throws<ProtocolFormatException>();
          check(
            () => BufferFrameCodec.encode(
              RenameSessionFrame(sessionId: sessionId, title: badTitle),
            ),
          ).throws<ProtocolFormatException>();
        }

        // Raw wire decode also rejects hostile titles on 0x03, 0x04, and 0x16.
        for (final rawBad in [' untrimmed', 'esc\x1b', 'bidi\u202e', '']) {
          final rawBytes = utf8.encode(rawBad);
          final rawLen = [
            (rawBytes.length >> 8) & 0xFF,
            rawBytes.length & 0xFF,
          ];

          final rawReg =
              (BytesBuilder()
                    ..addByte(BufferFrameCodec.protocolVersion)
                    ..addByte(0x03)
                    ..add([0, 1, ...'s'.codeUnits])
                    ..add(rawLen)
                    ..add(rawBytes)
                    ..add([0, 80, 0, 24])
                    ..add(Uint8List(16)))
                  .takeBytes();
          check(
            () => BufferFrameCodec.decode(rawReg),
          ).throws<ProtocolFormatException>();

          final rawDir =
              (BytesBuilder()
                    ..addByte(BufferFrameCodec.protocolVersion)
                    ..addByte(0x04)
                    ..add([0, 1])
                    ..add([0, 1, ...'s'.codeUnits])
                    ..add(rawLen)
                    ..add(rawBytes)
                    ..add([0, 80, 0, 24, 0, 0, 0, 0, 0]))
                  .takeBytes();
          check(
            () => BufferFrameCodec.decode(rawDir),
          ).throws<ProtocolFormatException>();

          final rawRename =
              (BytesBuilder()
                    ..addByte(BufferFrameCodec.protocolVersion)
                    ..addByte(0x16)
                    ..add([0, 1, ...'s'.codeUnits])
                    ..addByte(0)
                    ..add(rawLen)
                    ..add(rawBytes))
                  .takeBytes();
          check(
            () => BufferFrameCodec.decode(rawRename),
          ).throws<ProtocolFormatException>();
        }
      },
    );
  });

  _defineCompressionAndUtf8FuzzTests();
  _defineV5KttyAndAuxTests();
  _defineV6TitleBellAndAudioTests();
}

void _defineCompressionAndUtf8FuzzTests() {
  group('C1 deflate-raw envelope, C3 zero-alloc UTF-8 validator, and Tracer', () {
    test(
      'compresses >= 512 B 0x09, 0x0A, and 0x11 tails with deflate-raw and rewrites 0x11 requestId without inflating',
      _testCompressionAndScrollbackRewrite,
    );
    test(
      'rejects 32 MiB zip-bombs, oversized uncompressed tails on encode, and corrupt compressed tails with CorruptSessionFrameException',
      _testZipBombAndCorruptSessionTail,
    );
    test(
      'differential test matches zero-alloc _skipGrapheme against utf8.decode across UTF-8 and C0/C1 edge cases',
      _testDifferentialSkipGrapheme,
    );
    test(
      'records balanced B/E Tracer spans around encode, decode, and applyDelta when Tracer is started',
      _testTracerCodecSpans,
    );
  });
}

void _testCompressionAndScrollbackRewrite() {
  const sessionId = SessionId('sess-compress');
  // 1. 80x24 snapshot (> 25 KiB raw tail) compresses with flag 0x01 and passes O(1) inspectRelayBufferFrame.
  final snap = BufferSnapshotFrame(
    snapshot: BufferSnapshot(
      sessionId: sessionId,
      seq: 7,
      cols: 80,
      rows: 24,
      cursor: CursorState.origin,
      modes: TerminalModes.defaults,
      characters: List<String>.filled(80 * 24, 'A'),
      attributes: Uint32List(80 * 24 * 3),
    ),
  );
  final snapWire = BufferFrameCodec.encode(snap);
  // Header length for 'sess-compress' (13 bytes): 2 + 15 + 8 + 4 + 7 + 20 + 3 = 59 -> flag at offset 59.
  check(snapWire[59]).equals(1);
  check(snapWire.length).isLessThan(1024);
  final snapInfo = BufferFrameCodec.inspectRelayBufferFrame(
    snapWire,
    expectedSession: sessionId,
  );
  check(snapInfo).equals((isSnapshot: true, seq: 7, cols: 80, rows: 24));
  final decodedSnap = BufferFrameCodec.decode(snapWire) as BufferSnapshotFrame;
  check(decodedSnap.snapshot.characters).length.equals(80 * 24);
  check(decodedSnap.snapshot.characters.first).equals('A');

  // 2. Large delta (>= 512 B tail) compresses with flag 0x01 and round-trips.
  final delta = BufferDeltaFrame(
    delta: BufferDelta(
      sessionId: sessionId,
      seq: 8,
      baseSeq: 7,
      cols: 80,
      rows: 24,
      cursor: CursorState.origin,
      modes: TerminalModes.defaults,
      runs: [
        CellRun(
          startIndex: 0,
          characters: List<String>.filled(80, 'Z'),
          attributes: Uint32List(80 * 3),
        ),
      ],
    ),
  );
  final deltaWire = BufferFrameCodec.encode(delta);
  check(deltaWire[67]).equals(1);
  final deltaInfo = BufferFrameCodec.inspectRelayBufferFrame(
    deltaWire,
    expectedSession: sessionId,
  );
  check(deltaInfo).equals((isSnapshot: false, seq: 8, cols: 80, rows: 24));
  final decodedDelta = BufferFrameCodec.decode(deltaWire) as BufferDeltaFrame;
  check(decodedDelta.delta.runs.single.characters.first).equals('Z');

  // 3. Large 0x11 ScrollbackChunkFrame compresses with flag 0x01 and rewrites requestId in place.
  final chunk = ScrollbackChunkFrame(
    sessionId: sessionId,
    requestId: 101,
    clearSeq: 2,
    startLine: 50,
    rows: List<EncodedScrollbackRow>.generate(
      16,
      (i) => EncodedScrollbackRow(
        isWrapped: i.isOdd,
        characters: List<String>.filled(80, 'L'),
        attributes: Uint32List(80 * 3),
      ),
    ),
  );
  final chunkWire = BufferFrameCodec.encode(chunk);
  // Header length for 0x11 with 'sess-compress' (13 bytes): 2 + 15 + 4 + 4 + 8 + 2 = 35 -> flag at offset 35.
  check(chunkWire[35]).equals(1);
  check(
    BufferFrameCodec.inspectRelayScrollbackChunkRequestId(
      chunkWire,
      expectedSession: sessionId,
    ),
  ).equals(101);
  check(
    BufferFrameCodec.inspectRelayScrollbackChunkRequestId(
      chunkWire,
      expectedSession: const SessionId('other'),
    ),
  ).isNull();

  final rewritten = BufferFrameCodec.rewriteScrollbackChunkRequestId(
    chunkWire,
    expectedSession: sessionId,
    newRequestId: 9999,
  )!;
  check(rewritten.sublist(35)).deepEquals(chunkWire.sublist(35));
  final decodedRewritten =
      BufferFrameCodec.decode(rewritten) as ScrollbackChunkFrame;
  check(decodedRewritten.requestId).equals(9999);
  check(decodedRewritten.rows).length.equals(16);
}

void _testZipBombAndCorruptSessionTail() {
  const sessionId = SessionId('sess-bomb');
  // 1. 32 MiB zero-bomb compressed with raw deflate level 1.
  final bombPayload = compressDeflateRawLevel1(Uint8List(32 * 1024 * 1024));
  check(bombPayload.length).isLessThan(BufferFrameCodec.maxFrameBytes);

  Uint8List craftCompressedSnap(int declaredUncompressedLen, List<int> body) {
    final b = BytesBuilder()
      ..addByte(BufferFrameCodec.protocolVersion)
      ..addByte(0x09)
      ..add([0, sessionId.value.length, ...sessionId.value.codeUnits])
      ..add([0, 0, 0, 0, 0, 0, 0, 1]) // seq = 1
      ..add([0, 80, 0, 24]) // 80x24
      ..add([0, 0, 0, 0, 0, 0, 0]) // cursor + modes (7 bytes)
      ..add(List<int>.filled(20, 0)) // ScrollbackWindow
      ..add(List<int>.filled(3, 0)) // wrappedRows
      ..addByte(1) // compressionFlag = 0x01 (deflate-raw)
      ..add([
        (declaredUncompressedLen >> 24) & 0xFF,
        (declaredUncompressedLen >> 16) & 0xFF,
        (declaredUncompressedLen >> 8) & 0xFF,
        declaredUncompressedLen & 0xFF,
      ])
      ..add(body);
    return b.takeBytes();
  }

  // Case A: Honest 32 MiB declared length (> maxFrameBytes 4 MiB) rejected before inflating.
  final honestBomb = craftCompressedSnap(32 * 1024 * 1024, bombPayload);
  check(
    () => BufferFrameCodec.inspectRelayBufferFrame(
      honestBomb,
      expectedSession: sessionId,
    ),
  ).throws<ProtocolFormatException>();
  check(() => BufferFrameCodec.decode(honestBomb))
      .throws<CorruptSessionFrameException>()
      .has((e) => e.sessionId, 'sessionId')
      .equals(sessionId);

  // Case B: Spoofed 64 KiB declared length with 32 MiB deflate stream aborted at maxOutputSize.
  final spoofedBomb = craftCompressedSnap(65536, bombPayload);
  check(() => BufferFrameCodec.decode(spoofedBomb))
      .throws<CorruptSessionFrameException>()
      .has((e) => e.sessionId, 'sessionId')
      .equals(sessionId);

  // Case C: Corrupt deflate bytes on 0x09 throw CorruptSessionFrameException(sessionId).
  final corruptSnap = craftCompressedSnap(4096, const [0xFF, 0x00, 0xAA, 0x55]);
  check(() => BufferFrameCodec.decode(corruptSnap))
      .throws<CorruptSessionFrameException>()
      .has((e) => e.sessionId, 'sessionId')
      .equals(sessionId);

  // Case D (Opus-M1): Uncompressed snapshot tail > maxFrameBytes (4 MiB) throws on encode even when repetitive.
  final zalgoCell = 'A' * 64;
  final oversizedSnap = BufferSnapshotFrame(
    snapshot: BufferSnapshot(
      sessionId: sessionId,
      seq: 2,
      cols: 400,
      rows: 200,
      cursor: CursorState.origin,
      modes: TerminalModes.defaults,
      characters: List<String>.filled(400 * 200, zalgoCell),
      attributes: Uint32List(400 * 200 * 3),
    ),
  );
  check(() => BufferFrameCodec.encode(oversizedSnap))
      .throws<ProtocolFormatException>()
      .has((e) => e.message, 'message')
      .contains('Uncompressed frame tail exceeds');
}

void _testDifferentialSkipGrapheme() {
  const sessionId = SessionId('sess-utf8-diff');
  final testCases = <List<int>>[
    // Valid multi-byte UTF-8 (2-byte, 3-byte, 4-byte, ZWJ sequence).
    utf8.encode('é'),
    utf8.encode('⚡'),
    utf8.encode('🚀'),
    utf8.encode('👨‍👩‍👧‍👦'),
    // C1 control characters (U+0080..U+009F -> 0xC2 0x80..0x9F).
    const [0xC2, 0x80],
    const [0xC2, 0x9B],
    const [0xC2, 0x9F],
    // Valid U+00A0 (0xC2 0xA0).
    const [0xC2, 0xA0],
    // Multi-byte containing ASCII C0 or DEL control.
    const [0x61, 0x1B],
    const [0x61, 0x7F],
    // Overlong 2-byte, 3-byte, and 4-byte encodings.
    const [0xC0, 0xAF],
    const [0xC1, 0xBF],
    const [0xE0, 0x80, 0x80],
    const [0xE0, 0x9F, 0xBF],
    const [0xF0, 0x80, 0x80, 0x80],
    const [0xF0, 0x8F, 0xBF, 0xBF],
    // UTF-16 surrogates (U+D800..U+DFFF -> 0xED 0xA0..0xBF).
    const [0xED, 0xA0, 0x80],
    const [0xED, 0xBF, 0xBF],
    // Valid U+D7FF (0xED 0x9F 0xBF).
    const [0xED, 0x9F, 0xBF],
    // Out-of-range > U+10FFFF (0xF4 0x90..0xBF, 0xF5..0xFF).
    const [0xF4, 0x90, 0x80, 0x80],
    const [0xF5, 0x80, 0x80, 0x80],
    // Truncated multi-byte sequences and stray continuation bytes.
    const [0x80, 0x80],
    const [0xE2, 0x82],
    const [0xF0, 0x9F, 0x9A],
  ];

  for (final graphemeBytes in testCases) {
    final wire = _craftSingleCellSnapshot(sessionId, graphemeBytes);
    final decodeOk = _canDecodeFrame(wire);
    final inspectOk = _canInspectFrame(wire, sessionId);
    check(inspectOk).equals(decodeOk);
  }
}

Uint8List _craftSingleCellSnapshot(SessionId sessionId, List<int> grapheme) {
  final b = BytesBuilder()
    ..addByte(BufferFrameCodec.protocolVersion)
    ..addByte(0x09)
    ..add([0, sessionId.value.length, ...sessionId.value.codeUnits])
    ..add([0, 0, 0, 0, 0, 0, 0, 1]) // seq = 1
    ..add([0, 1, 0, 1]) // 1x1
    ..add([0, 0, 0, 0, 0, 0, 0]) // cursor + modes (7 bytes)
    ..add(List<int>.filled(20, 0)) // ScrollbackWindow
    ..addByte(0) // wrappedRows
    ..addByte(0) // compressionFlag = 0x00 (raw)
    ..addByte(grapheme.length)
    ..add(grapheme)
    ..add(List<int>.filled(12, 0))
    ..add([0, 0, 0]); // auxFlags (1B) + kittyCount (2B)
  return b.takeBytes();
}

bool _canDecodeFrame(Uint8List wire) {
  try {
    BufferFrameCodec.decode(wire);
    return true;
  } on ProtocolFormatException {
    return false;
  }
}

bool _canInspectFrame(Uint8List wire, SessionId sessionId) {
  try {
    BufferFrameCodec.inspectRelayBufferFrame(wire, expectedSession: sessionId);
    return true;
  } on ProtocolFormatException {
    return false;
  }
}

Future<void> _testTracerCodecSpans() async {
  final tempDir = await Directory.systemTemp.createTemp('termui_codec_trace_');
  addTearDown(() async {
    await Tracer.stop();
    if (tempDir.existsSync()) {
      await tempDir.delete(recursive: true);
    }
  });
  final traceFile = File('${tempDir.path}/trace.json');
  await Tracer.start(traceFile.path);

  const sessionId = SessionId('sess-trace');
  final snap = BufferSnapshotFrame(
    snapshot: BufferSnapshot(
      sessionId: sessionId,
      seq: 1,
      cols: 4,
      rows: 1,
      cursor: CursorState.origin,
      modes: TerminalModes.defaults,
      characters: const ['a', 'b', 'c', 'd'],
      attributes: Uint32List(12),
    ),
  );
  final encoded = BufferFrameCodec.encode(snap);
  final decoded = BufferFrameCodec.decode(encoded) as BufferSnapshotFrame;
  check(
    () => BufferFrameCodec.decode(Uint8List.fromList([99])),
  ).throws<ProtocolFormatException>();
  final buf = decoded.snapshot.toBuffer();
  final applied = BufferFrameCodec.applyDelta(
    buffer: buf,
    currentSeq: 1,
    delta: BufferDelta(
      sessionId: sessionId,
      seq: 2,
      baseSeq: 1,
      cols: 4,
      rows: 1,
      cursor: CursorState.origin,
      modes: TerminalModes.defaults,
      runs: [
        CellRun(
          startIndex: 0,
          characters: const ['Z'],
          attributes: Uint32List(3),
        ),
      ],
    ),
  );
  check(applied).isTrue();
  await Tracer.stop();

  final events = jsonDecode(await traceFile.readAsString()) as List<Object?>;
  var beginCount = 0;
  var endCount = 0;
  for (final raw in events) {
    final map = raw as Map<String, Object?>;
    if (map['ph'] == 'B') beginCount++;
    if (map['ph'] == 'E') endCount++;
  }
  check(beginCount).equals(4);
  check(endCount).equals(beginCount);
}

void _defineV5KttyAndAuxTests() {
  group('Protocol v5 KTTY modes, sparse aux channels, and KittyImagePayload', () {
    test(
      'round-trips sgrPixelsMouse, kittyKeyboardFlags, SGR 58 underlineColors, deduplicated OSC 8 uriRuns, and clears overwritten aux via applyDelta',
      () {
        const sessionId = SessionId('sess-v5-aux');
        const modes = TerminalModes(
          mouseTracking: true,
          sgrMouse: true,
          sgrPixelsMouse: true,
          kittyKeyboardFlags: 0x1B,
        );
        check('$modes').contains('sgrPixelsMouse: true');
        check('$modes').contains('kittyKeyboardFlags: 27');

        final buf = Buffer.blank(8, 2);
        buf.writeString(
          0,
          0,
          'Link1',
          Style(
            underlineColor: const Color(0xFF, 0x22, 0x88),
            uri: 'https://dart.dev/docs\x07',
          ),
        );
        buf.writeString(
          0,
          1,
          'Link2',
          const Style(uri: 'https://dart.dev/docs'),
        );

        final snap = BufferSnapshot.fromBuffer(
          sessionId: sessionId,
          seq: 1,
          buffer: buf,
          cursor: CursorState.origin,
          modes: modes,
        );
        final snapWire = BufferFrameCodec.encode(
          BufferSnapshotFrame(snapshot: snap),
        );
        check(
          BufferFrameCodec.inspectRelayBufferFrame(
            snapWire,
            expectedSession: sessionId,
          ),
        ).equals((isSnapshot: true, seq: 1, cols: 8, rows: 2));

        final decodedSnap =
            (BufferFrameCodec.decode(snapWire) as BufferSnapshotFrame).snapshot;
        check(decodedSnap.modes).equals(modes);
        check(decodedSnap.modes.hashCode).equals(modes.hashCode);

        final hydrated = decodedSnap.toBuffer();
        check(hydrated.getUnderlineColor(0, 0)).equals(0xFFFF2288);
        check(hydrated.getUnderlineColor(5, 0)).equals(0);
        check(hydrated.getUri(0, 0)).equals('https://dart.dev/docs');
        check(hydrated.getUri(4, 0)).equals('https://dart.dev/docs');
        check(hydrated.getUri(5, 0)).isNull();
        check(hydrated.getUri(2, 1)).equals('https://dart.dev/docs');

        // Overwrite cells 0..4 on row 0 with plain blanks via delta -> clears stale underlineColor and uri!
        final clearDelta = BufferDelta(
          sessionId: sessionId,
          seq: 2,
          baseSeq: 1,
          cols: 8,
          rows: 2,
          cursor: CursorState.origin,
          modes: TerminalModes.defaults,
          runs: [
            CellRun(
              startIndex: 0,
              characters: List<String>.filled(5, ' '),
              attributes: Uint32List(15),
            ),
          ],
        );
        final clearWire = BufferFrameCodec.encode(
          BufferDeltaFrame(delta: clearDelta),
        );
        check(
          BufferFrameCodec.inspectRelayBufferFrame(
            clearWire,
            expectedSession: sessionId,
          ),
        ).equals((isSnapshot: false, seq: 2, cols: 8, rows: 2));
        final decodedClear =
            (BufferFrameCodec.decode(clearWire) as BufferDeltaFrame).delta;
        check(
          BufferFrameCodec.applyDelta(
            buffer: hydrated,
            currentSeq: 1,
            delta: decodedClear,
          ),
        ).isTrue();
        for (var x = 0; x < 5; x++) {
          check(hydrated.getUnderlineColor(x, 0)).equals(0);
          check(hydrated.getUri(x, 0)).isNull();
        }
        // Row 1 link remains untouched.
        check(hydrated.getUri(2, 1)).equals('https://dart.dev/docs');

        // Scrollback chunk rows also round-trip underlineColors and uriRuns.
        final sbChunk = ScrollbackChunkFrame(
          sessionId: sessionId,
          requestId: 9,
          clearSeq: 0,
          startLine: 0,
          rows: [
            EncodedScrollbackRow(
              isWrapped: false,
              characters: 'Click'.split(''),
              attributes: Uint32List(15),
              underlineColors: const {0: 0xFF00AAFF, 4: 0xFF00AAFF},
              uriRuns: const [
                (start: 0, length: 5, uri: 'mailto:team@dart.dev'),
              ],
            ),
          ],
        );
        final sbWire = BufferFrameCodec.encode(sbChunk);
        check(
          BufferFrameCodec.inspectRelayScrollbackChunkRequestId(
            sbWire,
            expectedSession: sessionId,
          ),
        ).equals(9);
        final decodedSb =
            BufferFrameCodec.decode(sbWire) as ScrollbackChunkFrame;
        check(
          decodedSb.rows.single.underlineColors,
        ).isNotNull().deepEquals({0: 0xFF00AAFF, 4: 0xFF00AAFF});
        check(decodedSb.rows.single.uriRuns).isNotNull().deepEquals([
          (start: 0, length: 5, uri: 'mailto:team@dart.dev'),
        ]);

        // clampOsc8Uri strips control chars and UTF-8-safely truncates >2048-byte URIs.
        final hugeUri = 'https://dart.dev/${'🚀' * 600}';
        final clamped = clampOsc8Uri('$hugeUri\x1b\\');
        check(utf8.encode(clamped).length <= maxOsc8UriBytes).isTrue();
        check(clamped.contains('\x1b')).isFalse();
      },
    );

    test(
      'round-trips KittyImagePayload across snapshots and deltas and rejects corrupt aux/Kitty wire frames',
      () {
        const sessionId = SessionId('sess-v5-kitty');
        final rgbaPayload = KittyImagePayload(
          imageId: 0x01020304,
          pixelWidth: 2,
          pixelHeight: 2,
          gridCols: 2,
          gridRows: 1,
          version: 3,
          format: 32,
          bytes: Uint8List.fromList(List<int>.generate(16, (i) => i * 10)),
        );
        Uint8List validPngHeader(int width, int height) {
          final builder = BytesBuilder()
            ..add(const [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
            ..add(const [0x00, 0x00, 0x00, 0x0D])
            ..add(const [0x49, 0x48, 0x44, 0x52]);
          final dims = ByteData(8)
            ..setUint32(0, width)
            ..setUint32(4, height);
          builder
            ..add(dims.buffer.asUint8List())
            ..add(const [0x08, 0x06, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]);
          return builder.toBytes();
        }

        final pngPayload = KittyImagePayload(
          imageId: 77,
          pixelWidth: 8,
          pixelHeight: 8,
          gridCols: 1,
          gridRows: 1,
          version: 1,
          format: 100,
          bytes: validPngHeader(8, 8),
        );

        final snap = BufferSnapshot.fromBuffer(
          sessionId: sessionId,
          seq: 1,
          buffer: Buffer.blank(4, 2),
          cursor: CursorState.origin,
          modes: TerminalModes.defaults,
          kittyImages: [rgbaPayload, pngPayload],
        );
        final snapWire = BufferFrameCodec.encode(
          BufferSnapshotFrame(snapshot: snap),
        );
        check(
          BufferFrameCodec.inspectRelayBufferFrame(
            snapWire,
            expectedSession: sessionId,
          ),
        ).equals((isSnapshot: true, seq: 1, cols: 4, rows: 2));
        final decodedSnap =
            (BufferFrameCodec.decode(snapWire) as BufferSnapshotFrame).snapshot;
        check(decodedSnap.kittyImages).isNotNull().length.equals(2);
        final roundTrippedData = decodedSnap.kittyImages!.first.toImageData();
        check(roundTrippedData.imageId).equals(0x01020304);
        check(roundTrippedData.version).equals(3);
        check(roundTrippedData.rgbaPixels).deepEquals(rgbaPayload.bytes);

        final delta = BufferDelta(
          sessionId: sessionId,
          seq: 2,
          baseSeq: 1,
          cols: 4,
          rows: 2,
          cursor: CursorState.origin,
          modes: TerminalModes.defaults,
          runs: const [],
          clearKittyImages: true,
          kittyRemovals: const [99],
          kittyUpserts: [rgbaPayload],
        );
        final deltaWire = BufferFrameCodec.encode(
          BufferDeltaFrame(delta: delta),
        );
        check(
          BufferFrameCodec.inspectRelayBufferFrame(
            deltaWire,
            expectedSession: sessionId,
          ),
        ).equals((isSnapshot: false, seq: 2, cols: 4, rows: 2));
        final decodedDelta =
            (BufferFrameCodec.decode(deltaWire) as BufferDeltaFrame).delta;
        check(decodedDelta.clearKittyImages).isTrue();
        check(decodedDelta.kittyRemovals).isNotNull().deepEquals([99]);
        check(decodedDelta.kittyUpserts).isNotNull().length.equals(1);

        // Reject out-of-bounds underlineColors, >2048B uriRuns, and mismatched RGBA32 Kitty bytes.
        check(
          () => BufferFrameCodec.encode(
            BufferDeltaFrame(
              delta: BufferDelta(
                sessionId: sessionId,
                seq: 2,
                baseSeq: 1,
                cols: 4,
                rows: 2,
                cursor: CursorState.origin,
                modes: TerminalModes.defaults,
                runs: [
                  CellRun(
                    startIndex: 0,
                    characters: const ['A'],
                    attributes: Uint32List(3),
                    underlineColors: const {1: 0xFFFF0000},
                  ),
                ],
              ),
            ),
          ),
        ).throws<ProtocolFormatException>();

        check(
          () => BufferFrameCodec.encode(
            BufferDeltaFrame(
              delta: BufferDelta(
                sessionId: sessionId,
                seq: 2,
                baseSeq: 1,
                cols: 4,
                rows: 2,
                cursor: CursorState.origin,
                modes: TerminalModes.defaults,
                runs: [
                  CellRun(
                    startIndex: 0,
                    characters: const ['A'],
                    attributes: Uint32List(3),
                    uriRuns: [(start: 0, length: 1, uri: 'a' * 2049)],
                  ),
                ],
              ),
            ),
          ),
        ).throws<ProtocolFormatException>();

        check(
          () => BufferFrameCodec.encode(
            BufferDeltaFrame(
              delta: BufferDelta(
                sessionId: sessionId,
                seq: 2,
                baseSeq: 1,
                cols: 4,
                rows: 2,
                cursor: CursorState.origin,
                modes: TerminalModes.defaults,
                runs: const [],
                kittyUpserts: [
                  KittyImagePayload(
                    imageId: 1,
                    pixelWidth: 2,
                    pixelHeight: 2,
                    gridCols: 1,
                    gridRows: 1,
                    format: 32,
                    bytes: Uint8List(8), // != 16
                  ),
                ],
              ),
            ),
          ),
        ).throws<ProtocolFormatException>();

        // Reject PNG decompression bombs / mismatched IHDR in encode, inspectRelayBufferFrame, and decode.
        check(
          () => BufferFrameCodec.encode(
            BufferDeltaFrame(
              delta: BufferDelta(
                sessionId: sessionId,
                seq: 2,
                baseSeq: 1,
                cols: 4,
                rows: 2,
                cursor: CursorState.origin,
                modes: TerminalModes.defaults,
                runs: const [],
                kittyUpserts: [
                  KittyImagePayload(
                    imageId: 2,
                    pixelWidth: 8,
                    pixelHeight: 8,
                    gridCols: 1,
                    gridRows: 1,
                    format: 100,
                    bytes: validPngHeader(20000, 20000),
                  ),
                ],
              ),
            ),
          ),
        ).throws<ProtocolFormatException>();

        // Craft a raw uncompressed delta frame with pixelWidth=8, pixelHeight=8 but IHDR=20000x20000.
        final validPngDeltaWire = BufferFrameCodec.encode(
          BufferDeltaFrame(
            delta: BufferDelta(
              sessionId: sessionId,
              seq: 2,
              baseSeq: 1,
              cols: 4,
              rows: 2,
              cursor: CursorState.origin,
              modes: TerminalModes.defaults,
              runs: const [],
              kittyUpserts: [pngPayload],
            ),
          ),
        );
        final tamperedPngDelta = Uint8List.fromList(validPngDeltaWire);
        // If uncompressed (compressionFlag == 0 at end - (9 + 21 + pngLen) - 1), overwrite IHDR width to 20000.
        final pngStart = tamperedPngDelta.length - pngPayload.bytes.length;
        if (tamperedPngDelta[pngStart] == 0x89 &&
            tamperedPngDelta[pngStart + 1] == 0x50) {
          ByteData.sublistView(
            tamperedPngDelta,
            pngStart + 16,
            pngStart + 24,
          ).setUint32(0, 20000);
          check(
            () => BufferFrameCodec.inspectRelayBufferFrame(
              tamperedPngDelta,
              expectedSession: sessionId,
            ),
          ).throws<ProtocolFormatException>();
          check(
            () => BufferFrameCodec.decode(tamperedPngDelta),
          ).throws<CorruptSessionFrameException>();
        }

        // Verify clampOsc8Uri short-string fast-path and identical reference deduplication in extractSliceUriRuns.
        const sharedUri = 'https://dart.dev/short';
        check(clampOsc8Uri(sharedUri)).equals(sharedUri);
        final dedupRuns = extractSliceUriRuns([
          sharedUri,
          sharedUri,
          sharedUri,
          null,
        ], 4);
        check(
          dedupRuns,
        ).isNotNull().deepEquals([(start: 0, length: 3, uri: sharedUri)]);

        // Truncated Kitty snapshot trailer fails both inspectRelayBufferFrame and decode.
        final truncKitty = Uint8List.sublistView(
          snapWire,
          0,
          snapWire.length - 3,
        );
        check(
          () => BufferFrameCodec.inspectRelayBufferFrame(
            truncKitty,
            expectedSession: sessionId,
          ),
        ).throws<ProtocolFormatException>();
        check(
          () => BufferFrameCodec.decode(truncKitty),
        ).throws<CorruptSessionFrameException>();
      },
    );
  });
}

void _defineV6TitleBellAndAudioTests() {
  group(
    'Protocol v6 RenameSession.clearPin, ShellTitleFrame, BellFrame, and AudioFrame',
    () {
      test(
        'encodes/decodes 0x16 clearPin, 0x17 sanitized/truncated ShellTitleFrame, and 0x18 BellFrame',
        _testV6TitleAndBellFrames,
      );
      test(
        'round-trips 0x19 AudioFrame (tone, compressed clip, 2 MiB clip, stop) and relay helpers',
        _testV6AudioRoundTripAndRelayHelpers,
      );
      test(
        'rejects oversized/corrupt 0x17, 0x18, and 0x19 frames with CorruptAudioFrameException',
        _testV6HostileAudioAndTitleFrames,
      );
    },
  );
}

void _testV6TitleAndBellFrames() {
  const sessionId = SessionId('sess-v6-title');

  // 0x16 clearPin: true allows empty title '' and non-empty valid title; invalid flags rejected.
  final clearFrame = BufferFrameCodec.encode(
    const RenameSessionFrame(sessionId: sessionId, title: '', clearPin: true),
  );
  final decodedClear =
      BufferFrameCodec.decode(clearFrame) as RenameSessionFrame;
  check(decodedClear.sessionId).equals(sessionId);
  check(decodedClear.title).equals('');
  check(decodedClear.clearPin).isTrue();

  check(
    () => BufferFrameCodec.encode(
      const RenameSessionFrame(
        sessionId: sessionId,
        title: '   ',
        clearPin: true,
      ),
    ),
  ).throws<ProtocolFormatException>();

  final badRenameFlags = Uint8List.fromList(clearFrame);
  badRenameFlags[2 + 2 + sessionId.value.length] = 0x02;
  check(
    () => BufferFrameCodec.decode(badRenameFlags),
  ).throws<ProtocolFormatException>();

  final badDir =
      (BytesBuilder()
            ..addByte(BufferFrameCodec.protocolVersion)
            ..addByte(0x04)
            ..add([0, 1])
            ..add([0, 1, ...'s'.codeUnits])
            ..add([0, 1, ...'a'.codeUnits])
            ..add([0, 80, 0, 24, 0, 0, 0, 0, 0x02]))
          .takeBytes();
  check(
    () => BufferFrameCodec.decode(badDir),
  ).throws<ProtocolFormatException>();

  // 0x17 ShellTitleFrame: allows '', strips C0/C1/bidi controls, UTF-8 truncates to <= 512 bytes.
  final emptyShellTitle =
      BufferFrameCodec.decode(
            BufferFrameCodec.encode(
              const ShellTitleFrame(sessionId: sessionId, title: ''),
            ),
          )
          as ShellTitleFrame;
  check(emptyShellTitle.title).equals('');

  final dirtyShellTitle =
      BufferFrameCodec.decode(
            BufferFrameCodec.encode(
              ShellTitleFrame(
                sessionId: sessionId,
                title:
                    'build\x1b]2;evil\x07\x9b\u061C\u200E\u200F\u202E-${'🚀' * 200}',
              ),
            ),
          )
          as ShellTitleFrame;
  check(dirtyShellTitle.title.contains('\x1b')).isFalse();
  check(dirtyShellTitle.title.contains('\x9b')).isFalse();
  check(dirtyShellTitle.title.contains('\u061C')).isFalse();
  check(dirtyShellTitle.title.contains('\u200E')).isFalse();
  check(dirtyShellTitle.title.contains('\u200F')).isFalse();
  check(dirtyShellTitle.title.contains('\u202E')).isFalse();
  check(dirtyShellTitle.title.startsWith('build]2;evil-')).isTrue();
  check(utf8.encode(dirtyShellTitle.title).length).isLessOrEqual(512);

  // Surrounding whitespace and boundary-exposed trailing spaces are trimmed cleanly
  // so directory/register serialization never rejects sanitized shell titles.
  check(sanitizeShellTitle('  vim  ')).equals('vim');
  check(sanitizeShellTitle('   ')).equals('');
  check(sanitizeShellTitle('\x1b\n   \x07\u061C\u200E\u200F\u202E')).equals('');
  for (final bidi in const ['\u061C', '\u200E', '\u200F']) {
    check(validateSessionTitle('tab$bidi').error).isNotNull();
    check(
      () => BufferFrameCodec.encode(
        RenameSessionFrame(sessionId: sessionId, title: 'tab$bidi'),
      ),
    ).throws<ProtocolFormatException>();
  }
  final boundarySpaced = sanitizeShellTitle('${'a' * 511} b');
  check(boundarySpaced).equals('a' * 511);
  check(boundarySpaced == boundarySpaced.trim()).isTrue();
  check(
    () => BufferFrameCodec.encode(
      SessionDirectoryFrame(
        sessions: [
          SessionSummary(
            id: sessionId,
            title: sanitizeShellTitle('  vim  '),
            cols: 80,
            rows: 24,
          ),
        ],
      ),
    ),
  ).returnsNormally();

  // Raw wire 0x17 with untrimmed whitespace throws ProtocolFormatException.
  final wireWithSpaces = Uint8List.fromList(
    BufferFrameCodec.encode(
      const ShellTitleFrame(sessionId: sessionId, title: 'xxvimxx'),
    ),
  );
  final len = wireWithSpaces.length;
  wireWithSpaces[len - 7] = 0x20;
  wireWithSpaces[len - 6] = 0x20;
  wireWithSpaces[len - 2] = 0x20;
  wireWithSpaces[len - 1] = 0x20;
  check(
    () => BufferFrameCodec.decode(wireWithSpaces),
  ).throws<ProtocolFormatException>();

  // 0x18 BellFrame + relay fast-path helper.
  final bellWire = BufferFrameCodec.encode(
    const BellFrame(sessionId: sessionId),
  );
  check(
    BufferFrameCodec.inspectRelayBellFrame(
      bellWire,
      expectedSession: sessionId,
    ),
  ).isTrue();
  check(
    BufferFrameCodec.inspectRelayBellFrame(
      bellWire,
      expectedSession: const SessionId('other'),
    ),
  ).isFalse();
  final trailingBell = Uint8List.fromList([...bellWire, 0x00]);
  check(
    () => BufferFrameCodec.inspectRelayBellFrame(
      trailingBell,
      expectedSession: sessionId,
    ),
  ).throws<ProtocolFormatException>();
}

void _testV6AudioRoundTripAndRelayHelpers() {
  const sessionId = SessionId('sess-v6-audio');

  // Tone payload (raw).
  const tone = CastToneAudioPayload(
    waveform: 'triangle',
    frequencyHz: 880.0,
    duration: Duration(milliseconds: 250),
    volume: 0.75,
    pan: -0.35,
  );
  final toneWire = BufferFrameCodec.encode(
    const AudioFrame(sessionId: sessionId, payload: tone),
  );
  check(
    BufferFrameCodec.inspectRelayAudioFrame(
      toneWire,
      expectedSession: sessionId,
    ),
  ).isTrue();
  check(
    BufferFrameCodec.inspectRelayAudioFrame(
      toneWire,
      expectedSession: const SessionId('other'),
    ),
  ).isFalse();
  final decodedTone = (BufferFrameCodec.decode(toneWire) as AudioFrame).payload;
  check(decodedTone).equals(tone);

  // Compressible >= 512 B clip payload exercises deflate-raw (0x01) envelope.
  final compressibleClip = Uint8List(4096);
  final clipWire = BufferFrameCodec.encode(
    AudioFrame(
      sessionId: sessionId,
      payload: CastClipAudioPayload(
        clipId: 123,
        format: 'ogg',
        bytes: compressibleClip,
        volume: 0.5,
        pan: 1.0,
        loop: true,
      ),
    ),
  );
  check(clipWire.length).isLessThan(1024);
  check(
    BufferFrameCodec.inspectRelayAudioFrame(
      clipWire,
      expectedSession: sessionId,
    ),
  ).isTrue();
  final decodedClip =
      (BufferFrameCodec.decode(clipWire) as AudioFrame).payload
          as CastClipAudioPayload;
  check(decodedClip.clipId).equals(123);
  check(decodedClip.format).equals('ogg');
  check(decodedClip.volume).equals(0.5);
  check(decodedClip.pan).equals(1.0);
  check(decodedClip.loop).isTrue();
  check(decodedClip.bytes).deepEquals(compressibleClip);

  // Exact 2 MiB clip payload succeeds.
  final maxClipBytes = Uint8List(CastAudioPayload.maxClipBytes);
  final maxClipWire = BufferFrameCodec.encode(
    AudioFrame(
      sessionId: sessionId,
      payload: CastClipAudioPayload(
        clipId: 1,
        format: 'mp3',
        bytes: maxClipBytes,
      ),
    ),
  );
  check(
    BufferFrameCodec.inspectRelayAudioFrame(
      maxClipWire,
      expectedSession: sessionId,
    ),
  ).isTrue();
  final decodedMax =
      (BufferFrameCodec.decode(maxClipWire) as AudioFrame).payload
          as CastClipAudioPayload;
  check(decodedMax.bytes.length).equals(CastAudioPayload.maxClipBytes);

  // Update payloads (pan-only, volume-only, both, and full v7 transport/fade/stop fields).
  for (final update in const [
    CastUpdateAudioPayload(clipId: 5, pan: -0.65),
    CastUpdateAudioPayload(clipId: 6, volume: 0.4),
    CastUpdateAudioPayload(clipId: 7, volume: 0.85, pan: 0.25),
    CastUpdateAudioPayload(
      clipId: 8,
      volume: 0.5,
      pan: -0.25,
      seekPosition: Duration(milliseconds: 1500),
      paused: true,
      speed: 1.5,
      preservePitch: true,
      fadeVolumeTarget: 0.2,
      fadeVolumeDuration: Duration(milliseconds: 350),
      fadeSpeedTarget: 0.75,
      fadeSpeedDuration: Duration(milliseconds: 500),
      scheduleStopDuration: Duration(milliseconds: 900),
    ),
  ]) {
    final wire = BufferFrameCodec.encode(
      AudioFrame(sessionId: sessionId, payload: update),
    );
    check(
      BufferFrameCodec.inspectRelayAudioFrame(wire, expectedSession: sessionId),
    ).isTrue();
    final decoded = (BufferFrameCodec.decode(wire) as AudioFrame).payload;
    check(decoded).equals(update);
  }

  // Clip payload with non-zero startOffset and busId round-trips cleanly.
  final spriteWire = BufferFrameCodec.encode(
    AudioFrame(
      sessionId: sessionId,
      payload: CastClipAudioPayload(
        clipId: 19,
        format: 'wav',
        bytes: Uint8List.fromList([1, 2, 3, 4]),
        startOffset: const Duration(milliseconds: 420),
        busId: 3,
      ),
    ),
  );
  final decodedSprite =
      (BufferFrameCodec.decode(spriteWire) as AudioFrame).payload
          as CastClipAudioPayload;
  check(decodedSprite.startOffset).equals(const Duration(milliseconds: 420));
  check(decodedSprite.busId).equals(3);

  // Bus lifecycle and filter payloads (_audioKindBus = 4) round-trip and pass relay inspection.
  for (final busPayload in const [
    CastBusAudioPayload(op: 'create', busId: 2),
    CastBusAudioPayload(op: 'destroy', busId: 2),
    CastBusAudioPayload(op: 'vol', busId: 2, value: 0.65),
    CastBusAudioPayload(op: 'attach', busId: 2, filterId: 7),
    CastBusAudioPayload(
      op: 'param',
      busId: 2,
      filterId: 0,
      paramId: 2,
      value: 1400.0,
    ),
    CastBusAudioPayload(
      op: 'fade',
      busId: 2,
      filterId: 8,
      paramId: 1,
      value: 1.5,
      duration: Duration(milliseconds: 250),
    ),
  ]) {
    final wire = BufferFrameCodec.encode(
      AudioFrame(sessionId: sessionId, payload: busPayload),
    );
    check(
      BufferFrameCodec.inspectRelayAudioFrame(wire, expectedSession: sessionId),
    ).isTrue();
    final decoded = (BufferFrameCodec.decode(wire) as AudioFrame).payload;
    check(decoded).equals(busPayload);
  }

  // Stream-backed clip (streamId != null, 0 inline bytes) and stream payloads (_audioKindStream = 5)
  // round-trip cleanly; stream chunks are sent raw without deflate-raw overhead.
  final streamClipWire = BufferFrameCodec.encode(
    AudioFrame(
      sessionId: sessionId,
      payload: CastClipAudioPayload(
        clipId: 25,
        format: 'wav',
        bytes: Uint8List(0),
        volume: 0.8,
        pan: -0.2,
        loop: true,
        startOffset: const Duration(milliseconds: 90),
        busId: 3,
        streamId: 11,
      ),
    ),
  );
  check(
    BufferFrameCodec.inspectRelayAudioFrame(
      streamClipWire,
      expectedSession: sessionId,
    ),
  ).isTrue();
  final decodedStreamClip =
      (BufferFrameCodec.decode(streamClipWire) as AudioFrame).payload
          as CastClipAudioPayload;
  check(decodedStreamClip.clipId).equals(25);
  check(decodedStreamClip.streamId).equals(11);
  check(decodedStreamClip.bytes).isEmpty();
  check(decodedStreamClip.busId).equals(3);

  for (final streamPayload in [
    const CastStreamAudioPayload(
      op: 'open',
      streamId: 11,
      maxBufferSize: 8 * 1024 * 1024,
      releaseConsumed: true,
      bufferingTimeNeeds: Duration(milliseconds: 250),
      sampleRate: 44100,
      channels: 1,
    ),
    CastStreamAudioPayload(
      op: 'chunk',
      streamId: 11,
      seq: 0,
      chunkBytes: Uint8List(1024), // >= 512 bytes, must still use raw (0x00)
    ),
    const CastStreamAudioPayload(op: 'end', streamId: 11, seq: 1),
    const CastStreamAudioPayload(op: 'end', streamId: 11),
  ]) {
    final wire = BufferFrameCodec.encode(
      AudioFrame(sessionId: sessionId, payload: streamPayload),
    );
    // Verify raw compression flag (0x00) is always used for CastStreamAudioPayload.
    final sessionIdLen = sessionId.value.length;
    check(wire[4 + sessionIdLen]).equals(0x00);
    check(
      BufferFrameCodec.inspectRelayAudioFrame(wire, expectedSession: sessionId),
    ).isTrue();
    final decoded = (BufferFrameCodec.decode(wire) as AudioFrame).payload;
    check(decoded).equals(streamPayload);
  }

  // Forward-compatible v7 relay accepts unknown audio kind > 6 within tail bounds,
  // while BufferFrameCodec.decode rejects it with CorruptAudioFrameException.
  final futureKindFrame =
      (BytesBuilder()
            ..addByte(BufferFrameCodec.protocolVersion)
            ..addByte(0x19)
            ..add([0, sessionId.value.length, ...sessionId.value.codeUnits])
            ..addByte(0x00) // raw
            ..addByte(0x07) // future v7 audio kind (> 6)
            ..add([1, 2, 3, 4]))
          .takeBytes();
  check(
    BufferFrameCodec.inspectRelayAudioFrame(
      futureKindFrame,
      expectedSession: sessionId,
    ),
  ).isTrue();
  check(
    () => BufferFrameCodec.decode(futureKindFrame),
  ).throws<CorruptAudioFrameException>();
}

void _testV6HostileAudioAndTitleFrames() {
  const sessionId = SessionId('sess-v6-hostile');

  // Raw wire 0x17 containing control chars or > 512 bytes is rejected on decode.
  final rawHostileTitle =
      (BytesBuilder()
            ..addByte(BufferFrameCodec.protocolVersion)
            ..addByte(0x17)
            ..add([0, sessionId.value.length, ...sessionId.value.codeUnits])
            ..add([0, 4])
            ..add('a\x1bbc'.codeUnits))
          .takeBytes();
  check(
    () => BufferFrameCodec.decode(rawHostileTitle),
  ).throws<ProtocolFormatException>();

  final oversizedRawTitle =
      (BytesBuilder()
            ..addByte(BufferFrameCodec.protocolVersion)
            ..addByte(0x17)
            ..add([0, sessionId.value.length, ...sessionId.value.codeUnits])
            ..add([0x02, 0x01]) // 513 bytes
            ..add(List<int>.filled(513, 0x41)))
          .takeBytes();
  check(
    () => BufferFrameCodec.decode(oversizedRawTitle),
  ).throws<ProtocolFormatException>();

  // Encoding > 2 MiB clip or invalid tone/clip parameters fails.
  check(
    () => BufferFrameCodec.encode(
      AudioFrame(
        sessionId: sessionId,
        payload: CastClipAudioPayload(
          clipId: 1,
          format: 'wav',
          bytes: Uint8List(CastAudioPayload.maxClipBytes + 1),
        ),
      ),
    ),
  ).throws<ProtocolFormatException>();
  check(
    () => BufferFrameCodec.encode(
      const AudioFrame(
        sessionId: sessionId,
        payload: CastToneAudioPayload(
          waveform: 'sine',
          frequencyHz: 440,
          duration: Duration(milliseconds: 10),
          pan: 1.5,
        ),
      ),
    ),
  ).throws<ProtocolFormatException>();

  for (final badTone in const [
    CastToneAudioPayload(
      waveform: 'sine',
      frequencyHz: 0.5,
      duration: Duration(milliseconds: 10),
    ),
    CastToneAudioPayload(
      waveform: 'sine',
      frequencyHz: 24001.0,
      duration: Duration(milliseconds: 10),
    ),
    CastToneAudioPayload(
      waveform: 'sine',
      frequencyHz: 440.0,
      duration: Duration(seconds: 61),
    ),
  ]) {
    check(
      () => BufferFrameCodec.encode(
        AudioFrame(sessionId: sessionId, payload: badTone),
      ),
    ).throws<ProtocolFormatException>();
  }

  // Raw wire 0x19 tone frames exceeding 24000 Hz, < 1 Hz, or > 60s throw CorruptAudioFrameException on decode.
  Uint8List rawToneFrame(double freqHz, int durationMicros) {
    final waveformBytes = utf8.encode('sine');
    final tail = ByteData(1 + 2 + waveformBytes.length + 8 + 8 + 8 + 8);
    var offset = 0;
    tail.setUint8(offset++, 0x00); // _audioKindTone
    tail.setUint16(offset, waveformBytes.length);
    offset += 2;
    for (final b in waveformBytes) {
      tail.setUint8(offset++, b);
    }
    tail.setFloat64(offset, freqHz, .big);
    offset += 8;
    tail.setUint32(offset, durationMicros ~/ 0x100000000);
    offset += 4;
    tail.setUint32(offset, durationMicros.remainder(0x100000000));
    offset += 4;
    tail.setFloat64(offset, 1.0, .big);
    offset += 8;
    tail.setFloat64(offset, 0.0, .big);
    return (BytesBuilder()
          ..addByte(BufferFrameCodec.protocolVersion)
          ..addByte(0x19)
          ..add([0, sessionId.value.length, ...sessionId.value.codeUnits])
          ..addByte(0x00) // raw uncompressed
          ..add(tail.buffer.asUint8List()))
        .takeBytes();
  }

  check(
    () => BufferFrameCodec.decode(rawToneFrame(24000.5, 10000)),
  ).throws<CorruptAudioFrameException>();
  check(
    () => BufferFrameCodec.decode(rawToneFrame(0.9, 10000)),
  ).throws<CorruptAudioFrameException>();
  check(
    () => BufferFrameCodec.decode(rawToneFrame(440.0, 60000001)),
  ).throws<CorruptAudioFrameException>();

  // 0x19 deflate-raw zip-bomb (> 2 MiB + header declared uncompressedLen) throws CorruptAudioFrameException before inflation.
  final hugeDeflatePayload = compressDeflateRawLevel1(Uint8List(8192));
  final declaredBomb =
      (BytesBuilder()
            ..addByte(BufferFrameCodec.protocolVersion)
            ..addByte(0x19)
            ..add([0, sessionId.value.length, ...sessionId.value.codeUnits])
            ..addByte(0x01) // deflate-raw
            ..add([0x00, 0x40, 0x00, 0x00]) // 4 MiB declared
            ..add(hugeDeflatePayload))
          .takeBytes();
  check(
    () => BufferFrameCodec.decode(declaredBomb),
  ).throws<CorruptAudioFrameException>();
  check(
    () => BufferFrameCodec.inspectRelayAudioFrame(
      declaredBomb,
      expectedSession: sessionId,
    ),
  ).throws<CorruptAudioFrameException>();

  // 0x19 deflate-raw stream that inflates beyond declared uncompressedLen throws CorruptAudioFrameException.
  final rawDeflate100 = compressDeflateRawLevel1(Uint8List(100));
  final mismatchLen =
      (BytesBuilder()
            ..addByte(BufferFrameCodec.protocolVersion)
            ..addByte(0x19)
            ..add([0, sessionId.value.length, ...sessionId.value.codeUnits])
            ..addByte(0x01)
            ..add([0, 0, 0, 10]) // claims 10 bytes, actually inflates to 100
            ..add(rawDeflate100))
          .takeBytes();
  check(
    () => BufferFrameCodec.decode(mismatchLen),
  ).throws<CorruptAudioFrameException>();

  // Corrupt 0x19 bytes throw CorruptAudioFrameException (NOT CorruptSessionFrameException).
  final corruptBytes =
      (BytesBuilder()
            ..addByte(BufferFrameCodec.protocolVersion)
            ..addByte(0x19)
            ..add([0, sessionId.value.length, ...sessionId.value.codeUnits])
            ..addByte(0x01)
            ..add([0, 0, 0, 64])
            ..add([0xFF, 0xFE, 0xFD]))
          .takeBytes();
  check(
    () => BufferFrameCodec.decode(corruptBytes),
  ).throws<CorruptAudioFrameException>();

  // Invalid CastUpdateAudioPayload instances fail encode with ProtocolFormatException.
  for (final badUpdate in const [
    CastUpdateAudioPayload(clipId: 1),
    CastUpdateAudioPayload(clipId: 0, volume: 0.5),
    CastUpdateAudioPayload(clipId: 1, volume: 1.5),
    CastUpdateAudioPayload(clipId: 1, pan: -1.5),
    CastUpdateAudioPayload(clipId: 1, speed: 0.1),
    CastUpdateAudioPayload(clipId: 1, speed: 8.5),
    CastUpdateAudioPayload(clipId: 1, seekPosition: Duration(milliseconds: -1)),
    CastUpdateAudioPayload(clipId: 1, fadeVolumeTarget: 0.5),
    CastUpdateAudioPayload(
      clipId: 1,
      fadeSpeedDuration: Duration(milliseconds: 100),
    ),
  ]) {
    check(
      () => BufferFrameCodec.encode(
        AudioFrame(sessionId: sessionId, payload: badUpdate),
      ),
    ).throws<ProtocolFormatException>();
  }

  // Raw wire 0x19 kind=3 update frames with invalid uint16 flags, clipId==0, out-of-range gain/pan, or trailing bytes throw CorruptAudioFrameException.
  Uint8List rawUpdateFrame({
    required int clipId,
    required int flags,
    List<double> floats = const [],
    List<int> trailing = const [],
  }) {
    final tail = ByteData(1 + 4 + 2 + floats.length * 8 + trailing.length);
    var offset = 0;
    tail.setUint8(offset++, 0x03); // _audioKindUpdate
    tail.setUint32(offset, clipId, .big);
    offset += 4;
    tail.setUint16(offset, flags, .big);
    offset += 2;
    for (final v in floats) {
      tail.setFloat64(offset, v, .big);
      offset += 8;
    }
    for (final b in trailing) {
      tail.setUint8(offset++, b);
    }
    return (BytesBuilder()
          ..addByte(BufferFrameCodec.protocolVersion)
          ..addByte(0x19)
          ..add([0, sessionId.value.length, ...sessionId.value.codeUnits])
          ..addByte(0x00)
          ..add(tail.buffer.asUint8List()))
        .takeBytes();
  }

  for (final malformed in [
    rawUpdateFrame(clipId: 1, flags: 0x0000),
    rawUpdateFrame(clipId: 1, flags: 0x0200, floats: [0.5]),
    rawUpdateFrame(clipId: 0, flags: 0x0001, floats: [0.5]),
    rawUpdateFrame(clipId: 1, flags: 0x0001, floats: [1.5]),
    rawUpdateFrame(clipId: 1, flags: 0x0002, floats: [-1.5]),
    rawUpdateFrame(clipId: 1, flags: 0x0010, floats: [0.05]),
    rawUpdateFrame(clipId: 1, flags: 0x0001, floats: [0.5], trailing: [0x99]),
  ]) {
    check(
      () => BufferFrameCodec.decode(malformed),
    ).throws<CorruptAudioFrameException>();
    check(
      () => BufferFrameCodec.inspectRelayAudioFrame(
        malformed,
        expectedSession: sessionId,
      ),
    ).throws<CorruptAudioFrameException>();
  }

  // Invalid CastBusAudioPayload instances fail encode with ProtocolFormatException.
  for (final badBus in const [
    CastBusAudioPayload(op: 'create', busId: 0),
    CastBusAudioPayload(op: 'bogus', busId: 1),
    CastBusAudioPayload(op: 'create', busId: 1, value: 0.5),
    CastBusAudioPayload(op: 'vol', busId: 1, value: 1.5),
    CastBusAudioPayload(op: 'vol', busId: 1, filterId: 0, value: 0.5),
    CastBusAudioPayload(op: 'attach', busId: 1, filterId: 12),
    CastBusAudioPayload(op: 'attach', busId: 1, filterId: 0, paramId: 0),
    CastBusAudioPayload(
      op: 'param',
      busId: 1,
      filterId: 0,
      paramId: 67,
      value: 1.0,
    ),
    CastBusAudioPayload(
      op: 'param',
      busId: 1,
      filterId: 0,
      paramId: 0,
      value: 1.0,
      duration: Duration.zero,
    ),
    CastBusAudioPayload(
      op: 'fade',
      busId: 1,
      filterId: 0,
      paramId: 0,
      value: 1.0,
    ),
    CastBusAudioPayload(
      op: 'fade',
      busId: 1,
      filterId: 0,
      paramId: 0,
      value: double.nan,
      duration: Duration.zero,
    ),
  ]) {
    check(
      () => BufferFrameCodec.encode(
        AudioFrame(sessionId: sessionId, payload: badBus),
      ),
    ).throws<ProtocolFormatException>();
  }

  // Raw wire 0x19 kind=4 bus frames with invalid op, busId, filterId, or trailing bytes fail.
  Uint8List rawBusFrame(List<int> body) =>
      (BytesBuilder()
            ..addByte(BufferFrameCodec.protocolVersion)
            ..addByte(0x19)
            ..add([0, sessionId.value.length, ...sessionId.value.codeUnits])
            ..addByte(0x00)
            ..addByte(0x04) // _audioKindBus
            ..add(body))
          .takeBytes();

  for (final malformedBus in [
    rawBusFrame([0x06, 0, 0, 0, 1]), // unknown opCode
    rawBusFrame([0x00, 0, 0, 0, 0]), // busId == 0
    rawBusFrame([0x03, 0, 0, 0, 1, 12]), // filterId == 12
    rawBusFrame([0x00, 0, 0, 0, 1, 0xFF]), // trailing byte
  ]) {
    check(
      () => BufferFrameCodec.decode(malformedBus),
    ).throws<CorruptAudioFrameException>();
    check(
      () => BufferFrameCodec.inspectRelayAudioFrame(
        malformedBus,
        expectedSession: sessionId,
      ),
    ).throws<CorruptAudioFrameException>();
  }

  // 128 MiB decoded PCM stream maxBufferSize round-trips, while 128 MiB + 1 is rejected.
  const maxStreamOpen = AudioFrame(
    sessionId: sessionId,
    payload: CastStreamAudioPayload(
      op: 'open',
      streamId: 9,
      maxBufferSize: CastStreamAudioPayload.maxStreamBufferBytes,
      releaseConsumed: false,
      bufferingTimeNeeds: Duration(milliseconds: 500),
      sampleRate: 48000,
      channels: 2,
    ),
  );
  final maxStreamWire = BufferFrameCodec.encode(maxStreamOpen);
  check(
    (BufferFrameCodec.decode(maxStreamWire) as AudioFrame).payload,
  ).equals(maxStreamOpen.payload);

  // Invalid CastStreamAudioPayload and streamId clip payloads fail encode with ProtocolFormatException.
  for (final badPayload in <CastAudioPayload>[
    const CastStreamAudioPayload(
      op: 'open',
      streamId: 1,
      maxBufferSize: CastStreamAudioPayload.maxStreamBufferBytes + 1,
      releaseConsumed: false,
      bufferingTimeNeeds: Duration.zero,
      sampleRate: 48000,
      channels: 2,
    ),
    CastClipAudioPayload(
      clipId: 1,
      format: 'wav',
      bytes: Uint8List.fromList([1, 2]),
      streamId: 2,
    ),
    const CastStreamAudioPayload(op: 'bogus', streamId: 1),
    const CastStreamAudioPayload(op: 'open', streamId: 0),
    const CastStreamAudioPayload(
      op: 'open',
      streamId: 1,
      seq: 0,
      maxBufferSize: 1024,
      releaseConsumed: false,
      bufferingTimeNeeds: Duration.zero,
      sampleRate: 48000,
      channels: 2,
    ),
    const CastStreamAudioPayload(
      op: 'open',
      streamId: 1,
      maxBufferSize: 0,
      releaseConsumed: false,
      bufferingTimeNeeds: Duration.zero,
      sampleRate: 48000,
      channels: 2,
    ),
    const CastStreamAudioPayload(op: 'chunk', streamId: 1, seq: 0, channels: 2),
    CastStreamAudioPayload(
      op: 'chunk',
      streamId: 1,
      seq: 0,
      chunkBytes: Uint8List(0),
    ),
    const CastStreamAudioPayload(op: 'end', streamId: 1, seq: -1),
    const CastStreamAudioPayload(op: 'end', streamId: 1, sampleRate: 48000),
  ]) {
    check(
      () => BufferFrameCodec.encode(
        AudioFrame(sessionId: sessionId, payload: badPayload),
      ),
    ).throws<ProtocolFormatException>();
  }

  // Raw wire 0x19 kind=5 stream frames with invalid op, maxBufferSize, channels, or byteLen fail.
  Uint8List rawStreamFrame(List<int> body) =>
      (BytesBuilder()
            ..addByte(BufferFrameCodec.protocolVersion)
            ..addByte(0x19)
            ..add([0, sessionId.value.length, ...sessionId.value.codeUnits])
            ..addByte(0x00)
            ..addByte(0x05) // _audioKindStream
            ..add(body))
          .takeBytes();

  for (final malformedStream in [
    rawStreamFrame([0x03, 0, 0, 0, 1]), // unknown opCode
    rawStreamFrame([0x02, 0, 0, 0, 0, 0]), // streamId == 0
    rawStreamFrame([
      0x01,
      0,
      0,
      0,
      1,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
    ]), // chunk byteLen == 0
    rawStreamFrame([
      0x00,
      0,
      0,
      0,
      1,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      1,
      1,
      2,
    ]), // maxBuf == 0
    rawStreamFrame([
      0x00,
      0,
      0,
      0,
      1,
      0x08, // (128 MiB + 1) = 0x08000001
      0,
      0,
      1,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      0xBB,
      0x80,
      2,
    ]), // maxBuf > 128 MiB
  ]) {
    check(
      () => BufferFrameCodec.decode(malformedStream),
    ).throws<CorruptAudioFrameException>();
    check(
      () => BufferFrameCodec.inspectRelayAudioFrame(
        malformedStream,
        expectedSession: sessionId,
      ),
    ).throws<CorruptAudioFrameException>();
  }

  // Phase 4: 0x19 kind=6 CastWaveformQueryAudioPayload and 0x1A AudioWaveformReplyFrame.
  const waveQuery = AudioFrame(
    sessionId: sessionId,
    payload: CastWaveformQueryAudioPayload(requestId: 91),
  );
  final waveQueryWire = BufferFrameCodec.encode(waveQuery);
  check(
    BufferFrameCodec.inspectRelayAudioFrame(
      waveQueryWire,
      expectedSession: sessionId,
    ),
  ).isTrue();
  check(
    (BufferFrameCodec.decode(waveQueryWire) as AudioFrame).payload,
  ).equals(const CastWaveformQueryAudioPayload(requestId: 91));
  check(
    () => BufferFrameCodec.encode(
      const AudioFrame(
        sessionId: sessionId,
        payload: CastWaveformQueryAudioPayload(requestId: 0),
      ),
    ),
  ).throws<ProtocolFormatException>();

  // Forward-compatible unknown v7 audio kind (> 6) passes relay inspection while decode throws.
  final futureKindFrame =
      (BytesBuilder()
            ..addByte(BufferFrameCodec.protocolVersion)
            ..addByte(0x19)
            ..add([0, sessionId.value.length, ...sessionId.value.codeUnits])
            ..addByte(0x00)
            ..addByte(7)
            ..add([1, 2, 3, 4]))
          .takeBytes();
  check(
    BufferFrameCodec.inspectRelayAudioFrame(
      futureKindFrame,
      expectedSession: sessionId,
    ),
  ).isTrue();
  check(
    () => BufferFrameCodec.decode(futureKindFrame),
  ).throws<CorruptAudioFrameException>();

  final samples = Float32List.fromList(
    List<double>.generate(256, (i) => (i - 128) / 128.0),
  );
  final replyWire = BufferFrameCodec.encode(
    AudioWaveformReplyFrame(
      sessionId: sessionId,
      requestId: 91,
      samples: samples,
    ),
  );
  final decodedReply =
      BufferFrameCodec.decode(replyWire) as AudioWaveformReplyFrame;
  check(decodedReply.sessionId).equals(sessionId);
  check(decodedReply.requestId).equals(91);
  check(decodedReply.samples.length).equals(256);
  check(decodedReply.samples[0]).equals(-1.0);
  check(decodedReply.samples[192]).isCloseTo(0.5, 1e-6);

  // Validation guards on AudioWaveformReplyFrame encode & decode.
  check(
    () => BufferFrameCodec.encode(
      AudioWaveformReplyFrame(
        sessionId: sessionId,
        requestId: 0,
        samples: samples,
      ),
    ),
  ).throws<ProtocolFormatException>();
  check(
    () => BufferFrameCodec.encode(
      AudioWaveformReplyFrame(
        sessionId: sessionId,
        requestId: 1,
        samples: Float32List(12),
      ),
    ),
  ).throws<ProtocolFormatException>();
  final nonFiniteSamples = Float32List.fromList(samples)..[5] = double.nan;
  check(
    () => BufferFrameCodec.encode(
      AudioWaveformReplyFrame(
        sessionId: sessionId,
        requestId: 1,
        samples: nonFiniteSamples,
      ),
    ),
  ).throws<ProtocolFormatException>();

  final truncatedReply = Uint8List.sublistView(
    replyWire,
    0,
    replyWire.length - 4,
  );
  check(
    () => BufferFrameCodec.decode(truncatedReply),
  ).throws<ProtocolFormatException>();
  final trailingReply = Uint8List.fromList([...replyWire, 0x00]);
  check(
    () => BufferFrameCodec.decode(trailingReply),
  ).throws<ProtocolFormatException>();
  final poisonedWire = Uint8List.fromList(replyWire);
  // Overwrite last 4 bytes with IEEE-754 little-endian NaN (0x7FC00000).
  poisonedWire[poisonedWire.length - 4] = 0x00;
  poisonedWire[poisonedWire.length - 3] = 0x00;
  poisonedWire[poisonedWire.length - 2] = 0xC0;
  poisonedWire[poisonedWire.length - 1] = 0x7F;
  check(
    () => BufferFrameCodec.decode(poisonedWire),
  ).throws<ProtocolFormatException>();

  // Single-pass scrollback inspection + in-place patch.
  final sbWire = BufferFrameCodec.encode(
    ScrollbackChunkFrame(
      sessionId: sessionId,
      requestId: 17,
      clearSeq: 1,
      startLine: 0,
      rows: [
        EncodedScrollbackRow(
          isWrapped: false,
          characters: ['A'],
          attributes: Uint32List(3),
        ),
      ],
    ),
  );
  final inspected = BufferFrameCodec.inspectRelayScrollbackChunk(
    sbWire,
    expectedSession: sessionId,
  )!;
  check(inspected.requestId).equals(17);
  final patched = BufferFrameCodec.patchScrollbackChunkRequestId(
    sbWire,
    requestIdOffset: inspected.requestIdOffset,
    newRequestId: 99,
    inPlace: true,
  );
  check(identical(patched, sbWire)).isTrue();
  check(
    (BufferFrameCodec.decode(patched) as ScrollbackChunkFrame).requestId,
  ).equals(99);
}
