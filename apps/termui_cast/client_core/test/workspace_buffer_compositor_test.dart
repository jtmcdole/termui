import 'dart:typed_data';

import 'package:checks/checks.dart';
import 'package:clock/clock.dart';
import 'package:termui/termui.dart';
import 'package:termui_cast_client_core/src/session_slot.dart';
import 'package:termui_cast_client_core/src/workspace_buffer_compositor.dart';
import 'package:termui_cast_protocol/termui_cast_protocol.dart';
import 'package:test/test.dart';

void main() {
  group('WorkspaceBufferCompositor.lookupVirtualLine', () {
    SessionSlot makeSlot([String id = 'lookup-slot']) => SessionSlot(
      id: SessionId(id),
      clock: const Clock(),
      requestTimeout: const Duration(seconds: 2),
      onVisualChange: () {},
      onClearSelection: () {},
      onRequestKeyframe: () {},
      onRequestScrollback: (_) {},
    );

    test(
      'reads hydrated scrollback rows (including oldestLine > 0), unhydrated placeholders, live rows, and out-of-range rows',
      () async {
        final slot = makeSlot();
        addTearDown(slot.dispose);
        await slot.machine.handle(.subscribe);

        final liveBuf = Buffer.blank(8, 2)
          ..writeString(0, 0, 'LiveRow0', const Style())
          ..writeString(0, 1, 'LiveRow1', const Style());
        liveBuf.setUri(0, 0, 'https://dart.dev');

        await slot.machine.handle(
          .snapshot,
          BufferSnapshot.fromBuffer(
            sessionId: slot.id,
            seq: 1,
            buffer: liveBuf,
            cursor: const CursorState(x: 0, y: 1, visible: false),
            modes: TerminalModes.defaults,
            scrollback: const ScrollbackWindow(
              clearSeq: 0,
              oldestLine: 5000,
              totalLines: 5004,
            ),
            wrappedRows: packWrappedRows(2, (row) => row == 0),
          ),
        );

        slot.ingestScrollbackChunk(
          ScrollbackChunkFrame(
            sessionId: slot.id,
            requestId: 1,
            clearSeq: 0,
            startLine: 5002,
            rows: [
              EncodedScrollbackRow(
                isWrapped: true,
                characters: 'Hist5002'.split(''),
                attributes: Uint32List(8 * 3),
                uriRuns: const [
                  (start: 2, length: 4, uri: 'https://example.org'),
                ],
              ),
            ],
          ),
        );

        // Unhydrated retained scrollback row returns empty non-null placeholder.
        final missing = WorkspaceBufferCompositor.lookupVirtualLine(
          slot,
          liveBuf,
          5000,
        );
        check(missing).isNotNull();
        check(missing!.isWrapped).isFalse();
        check(missing.characters).isEmpty();
        check(missing.uris).isNull();

        // Hydrated scrollback row returns characters, wrap bit, and expanded URIs.
        final hydrated = WorkspaceBufferCompositor.lookupVirtualLine(
          slot,
          liveBuf,
          5002,
        );
        check(hydrated).isNotNull();
        check(hydrated!.isWrapped).isTrue();
        check(hydrated.characters.join()).equals('Hist5002');
        check(hydrated.uris).isNotNull();
        check(hydrated.uris![2]).equals('https://example.org');
        check(hydrated.uris![0]).isNull();

        // Live rows immediately follow totalLines.
        final live0 = WorkspaceBufferCompositor.lookupVirtualLine(
          slot,
          liveBuf,
          5004,
        );
        check(live0).isNotNull();
        check(live0!.isWrapped).isTrue();
        check(live0.characters.join()).equals('LiveRow0');
        check(live0.uris![0]).equals('https://dart.dev');

        final live1 = WorkspaceBufferCompositor.lookupVirtualLine(
          slot,
          liveBuf,
          5005,
        );
        check(live1).isNotNull();
        check(live1!.isWrapped).isFalse();
        check(live1.characters.join()).equals('LiveRow1');

        // Past bottom of live buffer returns null.
        check(
          WorkspaceBufferCompositor.lookupVirtualLine(slot, liveBuf, 5006),
        ).isNull();
      },
    );
  });

  group('WorkspaceBufferCompositor Rainbow Road helpers', () {
    test('exposes hover cadence, background, modifiers, and animated hues', () {
      check(
        WorkspaceBufferCompositor.rainbowHoverTickInterval,
      ).equals(const Duration(milliseconds: 40));
      check(
        WorkspaceBufferCompositor.rainbowLinkBackgroundArgb,
      ).equals(0xFF1B263B);
      check(
        WorkspaceBufferCompositor.rainbowLinkModifiers,
      ).equals(Modifier.underline | Modifier.bold);

      final phase0 = WorkspaceBufferCompositor.rainbowPhaseHueAt(0);
      final phaseHalf = WorkspaceBufferCompositor.rainbowPhaseHueAt(600);
      check(phase0).equals(0.0);
      check(phaseHalf).equals(180.0);

      final fgAt0 = WorkspaceBufferCompositor.rainbowLinkForegroundAt(0, 100);
      final fgAt0Phase = WorkspaceBufferCompositor.rainbowLinkForegroundAtPhase(
        0,
        WorkspaceBufferCompositor.rainbowPhaseHueAt(100),
      );
      check(fgAt0).equals(fgAt0Phase);

      final fgLater = WorkspaceBufferCompositor.rainbowLinkForegroundAt(0, 500);
      final fgNextCell = WorkspaceBufferCompositor.rainbowLinkForegroundAt(
        1,
        100,
      );
      check(fgAt0).not((it) => it.equals(fgLater));
      check(fgAt0).not((it) => it.equals(fgNextCell));
      // Alpha channel is always opaque 0xFF.
      check((fgAt0 >> 24) & 0xFF).equals(0xFF);
    });
  });
}
