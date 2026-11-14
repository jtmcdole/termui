import 'dart:math';
import 'dart:typed_data';

import 'package:checks/checks.dart';
import 'package:clock/clock.dart';
import 'package:termui/termui.dart';
import 'package:termui_cast_client_core/src/models.dart';
import 'package:termui_cast_client_core/src/session_slot.dart';
import 'package:termui_cast_client_core/src/workspace_buffer_compositor.dart';
import 'package:termui_cast_protocol/termui_cast_protocol.dart';
import 'package:test/test.dart';

void main() {
  group('WorkspaceBufferCompositor cursor shape rendering', () {
    SessionSlot makeSlot() => SessionSlot(
      id: const SessionId('cursor-slot'),
      clock: const Clock(),
      requestTimeout: const Duration(seconds: 2),
      onVisualChange: () {},
      onClearSelection: () {},
      onRequestKeyframe: () {},
      onRequestScrollback: (_) {},
    );

    test(
      'renders bar (▏), underline (▁), and block (Modifier.reverse) cursors on blank and non-blank cells',
      () {
        final slot = makeSlot();
        addTearDown(slot.dispose);

        final src = Buffer.blank(6, 1)
          ..setAttributes(
            1,
            0,
            char: 'A',
            fg: 0xFFFFFFFF,
            bg: 0,
            modifiers: Modifier.none,
          )
          ..setAttributes(
            2,
            0,
            char: 'U',
            fg: 0xFFFFFFFF,
            bg: 0,
            modifiers: Modifier.underline,
          )
          ..writeString(3, 0, '🚀', Style.empty);
        slot.buffer = src;

        // 1. Bar cursor on blank cell (x=0) draws '▏' without Modifier.reverse or Modifier.transparent.
        for (final barShape in const [
          CursorShape.blinkingBar,
          CursorShape.steadyBar,
        ]) {
          slot.cursor = CursorState(x: 0, y: 0, visible: true, shape: barShape);
          final outBlank = WorkspaceBufferCompositor.compose(
            slot: slot,
            viewportCols: 6,
            viewportRows: 1,
            hoveredLink: null,
            activeSelection: null,
            nowMs: 0,
            hiddenClipboardNotice: null,
          );
          check(outBlank.getCharacter(0, 0)).equals('▏');
          check(
            outBlank.getModifiers(0, 0) &
                (Modifier.reverse | Modifier.transparent),
          ).equals(0);

          // Bar cursor on non-blank cell (x=1, 'A') keeps 'A' legible via Modifier.reverse.
          slot.cursor = CursorState(x: 1, y: 0, visible: true, shape: barShape);
          final outGlyph = WorkspaceBufferCompositor.compose(
            slot: slot,
            viewportCols: 6,
            viewportRows: 1,
            hoveredLink: null,
            activeSelection: null,
            nowMs: 0,
            hiddenClipboardNotice: null,
          );
          check(outGlyph.getCharacter(1, 0)).equals('A');
          check(
            outGlyph.getModifiers(1, 0) & Modifier.reverse,
          ).equals(Modifier.reverse);
        }

        // 2. Underline cursor on blank cell (x=0) draws '▁'; on non-blank cell falls back to Modifier.reverse.
        for (final underlineShape in const [
          CursorShape.blinkingUnderline,
          CursorShape.steadyUnderline,
        ]) {
          slot.cursor = CursorState(
            x: 0,
            y: 0,
            visible: true,
            shape: underlineShape,
          );
          final outBlank = WorkspaceBufferCompositor.compose(
            slot: slot,
            viewportCols: 6,
            viewportRows: 1,
            hoveredLink: null,
            activeSelection: null,
            nowMs: 0,
            hiddenClipboardNotice: null,
          );
          check(outBlank.getCharacter(0, 0)).equals('▁');
          check(
            outBlank.getModifiers(0, 0) &
                (Modifier.reverse | Modifier.transparent),
          ).equals(0);

          // Non-blank cell (x=1, 'A') -> toggles Modifier.reverse so TuiAtlasPainter renders it.
          slot.cursor = CursorState(
            x: 1,
            y: 0,
            visible: true,
            shape: underlineShape,
          );
          final outGlyph = WorkspaceBufferCompositor.compose(
            slot: slot,
            viewportCols: 6,
            viewportRows: 1,
            hoveredLink: null,
            activeSelection: null,
            nowMs: 0,
            hiddenClipboardNotice: null,
          );
          check(outGlyph.getCharacter(1, 0)).equals('A');
          check(
            outGlyph.getModifiers(1, 0) & Modifier.reverse,
          ).equals(Modifier.reverse);
        }

        // 3. Block cursor shapes (defaultShape, blinkingBlock, steadyBlock) toggle Modifier.reverse.
        for (final blockShape in const [
          CursorShape.defaultShape,
          CursorShape.blinkingBlock,
          CursorShape.steadyBlock,
        ]) {
          slot.cursor = CursorState(
            x: 0,
            y: 0,
            visible: true,
            shape: blockShape,
          );
          final outBlock = WorkspaceBufferCompositor.compose(
            slot: slot,
            viewportCols: 6,
            viewportRows: 1,
            hoveredLink: null,
            activeSelection: null,
            nowMs: 0,
            hiddenClipboardNotice: null,
          );
          check(outBlock.getCharacter(0, 0)).equals(' ');
          check(
            outBlock.getModifiers(0, 0) & Modifier.reverse,
          ).equals(Modifier.reverse);
        }

        // 4. Wide grapheme ('🚀' at x=3..4): cursor at x=3 or continuation cell x=4 inverts both cells.
        for (final cursorX in const [3, 4]) {
          slot.cursor = CursorState(
            x: cursorX,
            y: 0,
            visible: true,
            shape: CursorShape.steadyBar,
          );
          final outWide = WorkspaceBufferCompositor.compose(
            slot: slot,
            viewportCols: 6,
            viewportRows: 1,
            hoveredLink: null,
            activeSelection: null,
            nowMs: 0,
            hiddenClipboardNotice: null,
          );
          check(outWide.getCharacter(3, 0)).equals('🚀');
          check(outWide.getCharacter(4, 0)).equals('');
          check(
            outWide.getModifiers(3, 0) & Modifier.reverse,
          ).equals(Modifier.reverse);
          check(
            outWide.getModifiers(4, 0) & Modifier.reverse,
          ).equals(Modifier.reverse);
        }
      },
    );
  });

  group('WorkspaceBufferCompositor v5 OSC 8, SGR 58, Kitty, & selection', () {
    SessionSlot makeSlot([String id = 'v5-slot']) => SessionSlot(
      id: SessionId(id),
      clock: const Clock(),
      requestTimeout: const Duration(seconds: 2),
      onVisualChange: () {},
      onClearSelection: () {},
      onRequestKeyframe: () {},
      onRequestScrollback: (_) {},
    );

    test(
      'highlights soft-wrapped OSC 8 Rainbow Road across scrollback + live row 0, preserves SGR 58, and clears aux under overlays',
      () async {
        final slot = makeSlot();
        addTearDown(slot.dispose);
        await slot.machine.handle(.subscribe);

        const linkUri = 'https://dart.dev/guides/language';
        const ulColor = 0xFF22CC88;
        final liveBuf = Buffer.blank(8, 3);
        liveBuf.writeString(
          0,
          0,
          'Guides',
          const Style(underlineColor: Color(0x22, 0xCC, 0x88)),
        );
        for (var x = 0; x < 6; x++) {
          liveBuf.setUri(x, 0, linkUri);
        }
        liveBuf.writeString(0, 1, 'RowOne!!', const Style());
        for (var x = 0; x < 8; x++) {
          liveBuf.setUri(x, 1, 'https://stale.example');
          liveBuf.setUnderlineColor(x, 1, 0xFFFF0000);
        }

        await slot.machine.handle(
          .snapshot,
          BufferSnapshot.fromBuffer(
            sessionId: slot.id,
            seq: 1,
            buffer: liveBuf,
            cursor: const CursorState(x: 0, y: 2, visible: false),
            modes: TerminalModes.defaults,
            scrollback: const ScrollbackWindow(
              clearSeq: 0,
              oldestLine: 0,
              totalLines: 1,
            ),
            wrappedRows: packWrappedRows(3, (row) => row == 0),
          ),
        );
        slot.ingestScrollbackChunk(
          ScrollbackChunkFrame(
            sessionId: slot.id,
            requestId: 1,
            clearSeq: 0,
            startLine: 0,
            rows: [
              EncodedScrollbackRow(
                isWrapped: false,
                characters: 'DartLang'.split(''),
                attributes: Uint32List(8 * 3),
                underlineColors: const {0: ulColor, 7: ulColor},
                uriRuns: const [(start: 0, length: 8, uri: linkUri)],
              ),
            ],
          ),
        );

        // Verify ScrollbackPageCache per-cell accessors.
        check(slot.scrollbackCache.underlineColorAt(0, 0)).equals(ulColor);
        check(slot.scrollbackCache.underlineColorAt(0, 3)).equals(0);
        check(slot.scrollbackCache.uriAt(0, 4)).equals(linkUri);

        // Scroll up 1 line so screenY=0 is scrollback row 0 and screenY=1 is live row 0.
        check(slot.scrollBy(1, viewportCols: 8, viewportRows: 3)).isTrue();
        final matched = WorkspaceBufferCompositor.matchUrlAtCell(slot, 2, 1);
        check(matched).isNotNull();
        check(matched!.url).equals(Uri.parse(linkUri));
        check(matched.range.anchor).equals(const Point<int>(0, 0));
        check(matched.range.focus).equals(const Point<int>(5, 1));

        final composed1 = WorkspaceBufferCompositor.compose(
          slot: slot,
          viewportCols: 8,
          viewportRows: 3,
          hoveredLink: matched,
          activeSelection: null,
          nowMs: 100,
          hiddenClipboardNotice: null,
        );
        final composed2 = WorkspaceBufferCompositor.compose(
          slot: slot,
          viewportCols: 8,
          viewportRows: 3,
          hoveredLink: matched,
          activeSelection: null,
          nowMs: 500,
          hiddenClipboardNotice: null,
        );
        // Rainbow Road animates across BOTH row 0 (scrollback) and row 1 (live row 0),
        // except the scrollbar thumb on rightmost column x=7 which clears stale aux!
        check(
          composed1.getForeground(0, 0),
        ).not((it) => it.equals(composed2.getForeground(0, 0)));
        check(
          composed1.getForeground(3, 1),
        ).not((it) => it.equals(composed2.getForeground(3, 1)));
        check(composed1.getUnderlineColor(0, 0)).equals(ulColor);
        check(composed1.getUnderlineColor(2, 1)).equals(ulColor);
        check(composed1.getUri(2, 1)).equals(linkUri);

        // Scrollbar thumb painted on rightmost column (x=7) clears stale URI & underlineColor!
        final thumbRow = [
          0,
          1,
          2,
        ].firstWhere((y) => composed1.getCharacter(7, y) == '▐');
        check(composed1.getUri(7, thumbRow)).isNull();
        check(composed1.getUnderlineColor(7, thumbRow)).equals(0);

        // Hidden-dock clipboard notice on row 0 clears stale URI & underlineColor across row 0.
        final withNotice = WorkspaceBufferCompositor.compose(
          slot: slot,
          viewportCols: 8,
          viewportRows: 3,
          hoveredLink: null,
          activeSelection: null,
          nowMs: 0,
          hiddenClipboardNotice: 'Copied!',
        );
        for (var x = 0; x < 8; x++) {
          check(withNotice.getUri(x, 0)).isNull();
          check(withNotice.getUnderlineColor(x, 0)).equals(0);
        }
      },
    );

    test(
      'binds per-session KittyImageRegistry, gates delta Kitty updates on seq, and supports split-pane + box selection',
      () async {
        final slotA = makeSlot('kitty-a');
        final slotB = makeSlot('kitty-b');
        addTearDown(slotA.dispose);
        addTearDown(slotB.dispose);
        await slotA.machine.handle(.subscribe);
        await slotB.machine.handle(.subscribe);

        final paneBuf = Buffer.blank(12, 3)
          ..writeString(0, 0, 'Left0│Right0', const Style())
          ..writeString(0, 1, 'Left1│Right1', const Style())
          ..writeString(0, 2, 'Left2│Right2', const Style());
        final imgPayload = KittyImagePayload(
          imageId: 42,
          pixelWidth: 2,
          pixelHeight: 2,
          gridCols: 2,
          gridRows: 1,
          version: 1,
          bytes: Uint8List.fromList(List<int>.filled(16, 0xAA)),
        );

        await slotA.machine.handle(
          .snapshot,
          BufferSnapshot.fromBuffer(
            sessionId: slotA.id,
            seq: 1,
            buffer: paneBuf,
            cursor: CursorState.origin,
            modes: TerminalModes.defaults,
            kittyImages: [imgPayload],
          ),
        );
        await slotB.machine.handle(
          .snapshot,
          BufferSnapshot.fromBuffer(
            sessionId: slotB.id,
            seq: 1,
            buffer: Buffer.blank(12, 3),
            cursor: CursorState.origin,
            modes: TerminalModes.defaults,
          ),
        );

        final outA = WorkspaceBufferCompositor.compose(
          slot: slotA,
          viewportCols: 12,
          viewportRows: 3,
          hoveredLink: null,
          activeSelection: null,
          nowMs: 0,
          hiddenClipboardNotice: null,
        );
        final outB = WorkspaceBufferCompositor.compose(
          slot: slotB,
          viewportCols: 12,
          viewportRows: 3,
          hoveredLink: null,
          activeSelection: null,
          nowMs: 0,
          hiddenClipboardNotice: null,
        );
        check(outA.lookupKittyImage(0, 0, 42)).isNotNull();
        check(outB.lookupKittyImage(0, 0, 42)).isNull();
        check(KittyImageRegistry.lookup(42)).isNull();

        // Sequence-gapped delta (baseSeq=99 != seq=1) must NOT clear or mutate slotA.kittyRegistry!
        await slotA.machine.handle(
          .delta,
          BufferDelta(
            sessionId: slotA.id,
            seq: 100,
            baseSeq: 99,
            cols: 12,
            rows: 3,
            cursor: CursorState.origin,
            modes: TerminalModes.defaults,
            runs: const [],
            clearKittyImages: true,
          ),
        );
        check(slotA.state).equals(.awaitingKeyframe);
        check(slotA.kittyRegistry.lookupImage(42)).isNotNull();

        // Split-pane stream selection stays bounded to left pane (cols 0..4),
        // while Alt+Drag box selection crosses the `│` divider cleanly.
        final region = TerminalSelectionController.resolveRegionForCell(
          paneBuf,
          1,
          0,
        );
        check(region).equals(
          const SelectionRegion(minCol: 0, maxCol: 4, minRow: 0, maxRow: 2),
        );
        final streamSel = TerminalSelection(
          anchor: const Point<int>(0, 0),
          focus: const Point<int>(4, 2),
          region: region,
        );
        check(
          WorkspaceBufferCompositor.extractSelectionText(slotA, streamSel),
        ).equals('Left0\nLeft1\nLeft2');

        const boxSel = TerminalSelection(
          anchor: Point<int>(3, 0),
          focus: Point<int>(7, 1),
          mode: .box,
        );
        check(
          WorkspaceBufferCompositor.extractSelectionText(slotA, boxSel),
        ).equals('t0│Ri\nt1│Ri');
      },
    );
  });
}
