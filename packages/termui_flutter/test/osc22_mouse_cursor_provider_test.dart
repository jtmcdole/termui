import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:termui/terminal/terminal.dart' as term;
import 'package:termui/ui/buffer.dart';
import 'package:termui/ui/style.dart';
// ignore: implementation_imports
import 'package:termui_flutter/src/rendering/staging_cache.dart';
import 'package:termui_flutter/termui_flutter.dart';

final class _FakeBufferChangeSignal extends ChangeNotifier
    implements TerminalBufferChangeSignal {
  int _cellContentRevision = 0;

  @override
  int get cellContentRevision => _cellContentRevision;

  void notifyOverlayOnly() => notifyListeners();

  void notifyCellMutation() {
    _cellContentRevision++;
    notifyListeners();
  }
}

MouseCursor _readSurfaceMouseCursor(WidgetTester tester) {
  final region = tester.widget<MouseRegion>(
    find.descendant(
      of: find.byType(TerminalSurface),
      matching: find.byType(MouseRegion),
    ),
  );
  return region.cursor;
}

Future<GlyphAtlasController> _createInitializedAtlas(
  WidgetTester tester,
) async {
  final controller = GlyphAtlasController(
    fontSize: 13.0,
    fontFamily: 'Roboto Mono',
    devicePixelRatio: 1.0,
  );
  addTearDown(controller.dispose);
  await tester.runAsync(controller.ensureInitialized);
  expect(controller.atlas, isNotNull);
  return controller;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('TerminalSurface OSC 22 mouseCursorNameProvider', () {
    testWidgets(
      'updates MouseRegion.cursor on bufferListenable notifications across all 35 MousePointer shapes and null/unknown fallback',
      (tester) async {
        final atlasController = await _createInitializedAtlas(tester);
        final signal = _FakeBufferChangeSignal();
        addTearDown(signal.dispose);
        final buf = Buffer.blank(16, 4)
          ..writeString(0, 0, 'OSC 22 TEST', Style.empty);

        String? activeShape;
        String? readCursorShape() => activeShape;

        await tester.pumpWidget(
          Directionality(
            textDirection: TextDirection.ltr,
            child: SizedBox(
              width: 320,
              height: 160,
              child: TerminalSurface(
                atlasController: atlasController,
                bufferProvider: () => buf,
                bufferListenable: signal,
                mouseCursorNameProvider: readCursorShape,
              ),
            ),
          ),
        );
        await tester.pump();
        expect(
          _readSurfaceMouseCursor(tester),
          equals(SystemMouseCursors.basic),
        );

        const expectedByPointer = <term.MousePointer, MouseCursor>{
          term.MousePointer.defaultCursor: SystemMouseCursors.basic,
          term.MousePointer.text: SystemMouseCursors.text,
          term.MousePointer.pointer: SystemMouseCursors.click,
          term.MousePointer.crosshair: SystemMouseCursors.precise,
          term.MousePointer.help: SystemMouseCursors.help,
          term.MousePointer.progress: SystemMouseCursors.progress,
          term.MousePointer.wait: SystemMouseCursors.wait,
          term.MousePointer.move: SystemMouseCursors.move,
          term.MousePointer.notAllowed: SystemMouseCursors.forbidden,
          term.MousePointer.grab: SystemMouseCursors.grab,
          term.MousePointer.grabbing: SystemMouseCursors.grabbing,
          term.MousePointer.none: SystemMouseCursors.none,
          term.MousePointer.alias: SystemMouseCursors.alias,
          term.MousePointer.copy: SystemMouseCursors.copy,
          term.MousePointer.cell: SystemMouseCursors.cell,
          term.MousePointer.noDrop: SystemMouseCursors.noDrop,
          term.MousePointer.zoomIn: SystemMouseCursors.zoomIn,
          term.MousePointer.zoomOut: SystemMouseCursors.zoomOut,
          term.MousePointer.resizeUpDown: SystemMouseCursors.resizeUpDown,
          term.MousePointer.resizeLeftRight: SystemMouseCursors.resizeLeftRight,
          term.MousePointer.allScroll: SystemMouseCursors.allScroll,
          term.MousePointer.contextMenu: SystemMouseCursors.contextMenu,
          term.MousePointer.verticalText: SystemMouseCursors.verticalText,
          term.MousePointer.colResize: SystemMouseCursors.resizeColumn,
          term.MousePointer.rowResize: SystemMouseCursors.resizeRow,
          term.MousePointer.resizeUp: SystemMouseCursors.resizeUp,
          term.MousePointer.resizeDown: SystemMouseCursors.resizeDown,
          term.MousePointer.resizeLeft: SystemMouseCursors.resizeLeft,
          term.MousePointer.resizeRight: SystemMouseCursors.resizeRight,
          term.MousePointer.resizeUpLeft: SystemMouseCursors.resizeUpLeft,
          term.MousePointer.resizeUpRight: SystemMouseCursors.resizeUpRight,
          term.MousePointer.resizeDownLeft: SystemMouseCursors.resizeDownLeft,
          term.MousePointer.resizeDownRight: SystemMouseCursors.resizeDownRight,
          term.MousePointer.resizeUpRightDownLeft:
              SystemMouseCursors.resizeUpRightDownLeft,
          term.MousePointer.resizeUpLeftDownRight:
              SystemMouseCursors.resizeUpLeftDownRight,
        };
        expect(expectedByPointer, hasLength(term.MousePointer.values.length));

        for (final entry in expectedByPointer.entries) {
          activeShape = entry.key.value;
          signal.notifyOverlayOnly();
          await tester.pump();
          expect(
            _readSurfaceMouseCursor(tester),
            equals(entry.value),
            reason: 'OSC 22 shape "${entry.key.value}" should map accurately',
          );
        }

        // Transitioning back to null restores SystemMouseCursors.basic.
        activeShape = 'nesw-resize';
        signal.notifyOverlayOnly();
        await tester.pump();
        expect(
          _readSurfaceMouseCursor(tester),
          equals(SystemMouseCursors.resizeUpRightDownLeft),
        );

        activeShape = null;
        signal.notifyOverlayOnly();
        await tester.pump();
        expect(
          _readSurfaceMouseCursor(tester),
          equals(SystemMouseCursors.basic),
        );

        // Unknown names also fall back cleanly to SystemMouseCursors.basic.
        activeShape = 'pointer';
        signal.notifyCellMutation();
        await tester.pump();
        expect(
          _readSurfaceMouseCursor(tester),
          equals(SystemMouseCursors.click),
        );

        activeShape = 'ktty-invalid-shape';
        signal.notifyCellMutation();
        await tester.pump();
        expect(
          _readSurfaceMouseCursor(tester),
          equals(SystemMouseCursors.basic),
        );
      },
    );

    testWidgets(
      'overlayOnly cursor-only updates change MouseRegion.cursor while preserving staging cache',
      (tester) async {
        final atlasController = await _createInitializedAtlas(tester);
        final signal = _FakeBufferChangeSignal();
        addTearDown(signal.dispose);
        final buf = Buffer.blank(16, 4)
          ..writeString(0, 0, 'CACHED ROW 0', Style.empty)
          ..writeString(0, 1, 'CACHED ROW 1', Style.empty);

        String? activeShape;
        String? readCursorShape() => activeShape;

        await tester.pumpWidget(
          Directionality(
            textDirection: TextDirection.ltr,
            child: SizedBox(
              width: 320,
              height: 160,
              child: TerminalSurface(
                atlasController: atlasController,
                bufferProvider: () => buf,
                bufferListenable: signal,
                mouseCursorNameProvider: readCursorShape,
                enableRowCache: true,
              ),
            ),
          ),
        );
        await tester.pump();

        final state = tester.state<TerminalSurfaceState>(
          find.byType(TerminalSurface),
        );
        final cacheBefore = state.debugStagingCache;
        final bgTransformsBefore = stagingCacheInternalsOf(cacheBefore)
            .active
            .bgTransforms;
        expect(bgTransformsBefore.isNotEmpty, isTrue);

        // Warm overlay-only cursor update: MouseRegion updates without invalidating staging cache.
        activeShape = 'pointer';
        signal.notifyOverlayOnly();
        await tester.pump();

        expect(
          _readSurfaceMouseCursor(tester),
          equals(SystemMouseCursors.click),
        );
        expect(identical(state.debugStagingCache, cacheBefore), isTrue);
        expect(
          identical(
            stagingCacheInternalsOf(state.debugStagingCache)
                .active
                .bgTransforms,
            bgTransformsBefore,
          ),
          isTrue,
        );
        expect(state.debugStagingCache.lastRowMisses, equals(0));
        expect(state.debugStagingCache.lastRowHits, equals(buf.height));

        // Second overlay-only update back to null keeps staging cache warm.
        activeShape = null;
        signal.notifyOverlayOnly();
        await tester.pump();
        expect(
          _readSurfaceMouseCursor(tester),
          equals(SystemMouseCursors.basic),
        );
        expect(state.debugStagingCache.lastRowMisses, equals(0));
        expect(state.debugStagingCache.lastRowHits, equals(buf.height));
      },
    );

    testWidgets(
      'syncs cursor on mount, provider swap, and terminal transitioning from non-null to null',
      (tester) async {
        final atlasController = await _createInitializedAtlas(tester);
        final buf = Buffer.blank(12, 4)..writeString(0, 0, 'SWAP', Style.empty);

        String? providerA() => 'pointer';
        String? providerB() => 'nesw-resize';

        Widget buildTree({
          FlutterTerminal? terminal,
          String? mouseCursorName,
          String? Function()? mouseCursorNameProvider,
        }) => Directionality(
          textDirection: TextDirection.ltr,
          child: SizedBox(
            width: 320,
            height: 160,
            child: TerminalSurface(
              atlasController: atlasController,
              terminal: terminal,
              buffer: buf,
              mouseCursorName: mouseCursorName,
              mouseCursorNameProvider: mouseCursorNameProvider,
            ),
          ),
        );

        // 1. Mounts directly with initial value from mouseCursorNameProvider.
        await tester.pumpWidget(buildTree(mouseCursorNameProvider: providerA));
        await tester.pump();
        expect(
          _readSurfaceMouseCursor(tester),
          equals(SystemMouseCursors.click),
        );

        // 2. Swapping provider immediately updates MouseRegion.cursor.
        await tester.pumpWidget(buildTree(mouseCursorNameProvider: providerB));
        await tester.pump();
        expect(
          _readSurfaceMouseCursor(tester),
          equals(SystemMouseCursors.resizeUpRightDownLeft),
        );

        // 3. Removing provider falls back to static mouseCursorName.
        await tester.pumpWidget(buildTree(mouseCursorName: 'crosshair'));
        await tester.pump();
        expect(
          _readSurfaceMouseCursor(tester),
          equals(SystemMouseCursors.precise),
        );

        // 4. Transitioning terminal from null -> non-null resets stale external cursor.
        final terminal = FlutterTerminal();
        addTearDown(terminal.dispose);

        await tester.pumpWidget(
          buildTree(terminal: terminal, mouseCursorNameProvider: providerA),
        );
        await tester.pump();
        expect(
          _readSurfaceMouseCursor(tester),
          equals(SystemMouseCursors.basic),
        );

        terminal.backend.write('\x1b]22;wait\x07');
        await tester.pump();
        await tester.pump();
        expect(
          _readSurfaceMouseCursor(tester),
          equals(SystemMouseCursors.wait),
        );

        // 5. Detaching terminal (non-null -> null) re-syncs from provider.
        var mutableShape = 'pointer';
        String? readMutable() => mutableShape;
        await tester.pumpWidget(
          buildTree(terminal: null, mouseCursorNameProvider: readMutable),
        );
        await tester.pump();
        expect(
          _readSurfaceMouseCursor(tester),
          equals(SystemMouseCursors.click),
        );

        // 6. Rebuilding with the same tear-off reference re-evaluates provider value.
        mutableShape = 'grab';
        await tester.pumpWidget(
          buildTree(terminal: null, mouseCursorNameProvider: readMutable),
        );
        await tester.pump();
        expect(
          _readSurfaceMouseCursor(tester),
          equals(SystemMouseCursors.grab),
        );
      },
    );
  });
}
