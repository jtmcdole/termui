import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:termui/ui/buffer.dart';
import 'package:termui_flutter/src/rendering/search_highlight.dart';
import 'package:termui_flutter/termui_flutter.dart';

final class _RecordedRectDraw {
  final Rect rect;
  final PaintingStyle style;
  final double strokeWidth;
  final Color color;

  const _RecordedRectDraw({
    required this.rect,
    required this.style,
    required this.strokeWidth,
    required this.color,
  });
}

final class _RecordingCanvas implements Canvas {
  final List<_RecordedRectDraw> rectDraws = <_RecordedRectDraw>[];
  Rect? clippedRect;
  int saveCount = 0;
  int restoreCount = 0;

  @override
  void save() {
    saveCount++;
  }

  @override
  void restore() {
    restoreCount++;
  }

  @override
  void clipRect(
    Rect rect, {
    ui.ClipOp clipOp = ui.ClipOp.intersect,
    bool doAntiAlias = true,
  }) {
    clippedRect = rect;
  }

  @override
  void drawRect(Rect rect, Paint paint) {
    rectDraws.add(
      _RecordedRectDraw(
        rect: rect,
        style: paint.style,
        strokeWidth: paint.strokeWidth,
        color: paint.color,
      ),
    );
  }

  @override
  void noSuchMethod(Invocation invocation) => throw UnimplementedError(
    'Unexpected Canvas call: ${invocation.memberName}',
  );
}

final class _TestListenable extends ChangeNotifier {
  void emit() => notifyListeners();
}

final class _TestBufferSignal extends ChangeNotifier
    implements TerminalBufferChangeSignal {
  int _rev = 0;

  @override
  int get cellContentRevision => _rev;

  void emitCellChange() {
    _rev++;
    notifyListeners();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('TerminalSearchHighlight value semantics', () {
    test('equality, hashCode, toString, and public typedef export', () {
      const a = TerminalSearchHighlight(virtualRow: 42, startCol: 3, endCol: 9);
      const b = TerminalSearchHighlight(virtualRow: 42, startCol: 3, endCol: 9);
      const active = TerminalSearchHighlight(
        virtualRow: 42,
        startCol: 3,
        endCol: 9,
        isActive: true,
      );

      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
      expect(a, isNot(equals(active)));
      expect(a.toString(), contains('row: 42'));
      expect(active.toString(), contains('isActive: true'));

      List<TerminalSearchHighlight> readSpans() => const [a, active];
      final TerminalSearchHighlightsProvider provider = readSpans;
      expect(provider(), equals(const [a, active]));
    });
  });

  group('TerminalSearchHighlightPainter', () {
    test('clips to viewport rows/cols and paints active fill + 1.2px border', () {
      const matchColor = Color(0xFF4C9AFF);
      const activeColor = Color(0xFFFFB74D);
      final painter = TerminalSearchHighlightPainter(
        highlightsProvider: () => const <TerminalSearchHighlight>[
          // Above viewport -> clipped
          TerminalSearchHighlight(virtualRow: 9, startCol: 0, endCol: 4),
          // Inside viewport, inactive (viewport row 0)
          TerminalSearchHighlight(virtualRow: 10, startCol: 2, endCol: 6),
          // Inside viewport, active and partially clamped at right edge (row 2)
          TerminalSearchHighlight(
            virtualRow: 12,
            startCol: 8,
            endCol: 15,
            isActive: true,
          ),
          // Below viewport -> clipped
          TerminalSearchHighlight(virtualRow: 15, startCol: 0, endCol: 3),
          // Degenerate span -> skipped
          TerminalSearchHighlight(virtualRow: 11, startCol: 5, endCol: 5),
        ],
        topVirtualRowProvider: () => 10,
        cellWidth: 8.0,
        cellHeight: 16.0,
        cols: 10,
        rows: 5,
        matchColor: matchColor,
        activeMatchColor: activeColor,
      );

      final canvas = _RecordingCanvas();
      painter.paint(canvas, const Size(80, 80));

      expect(canvas.saveCount, equals(1));
      expect(canvas.restoreCount, equals(1));
      expect(canvas.clippedRect, equals(const Rect.fromLTWH(0, 0, 80, 80)));

      // 1 draw for inactive fill + 2 draws (fill + stroke) for active match.
      expect(canvas.rectDraws, hasLength(3));

      final inactiveDraw = canvas.rectDraws[0];
      expect(inactiveDraw.rect, equals(const Rect.fromLTWH(16, 0, 32, 16)));
      expect(inactiveDraw.style, equals(PaintingStyle.fill));
      expect(inactiveDraw.color.a, closeTo(0.28, 0.02));

      final activeFill = canvas.rectDraws[1];
      expect(activeFill.rect, equals(const Rect.fromLTWH(64, 32, 16, 16)));
      expect(activeFill.style, equals(PaintingStyle.fill));
      expect(activeFill.color.a, closeTo(0.45, 0.02));

      final activeBorder = canvas.rectDraws[2];
      expect(activeBorder.rect, equals(const Rect.fromLTWH(64, 32, 16, 16)));
      expect(activeBorder.style, equals(PaintingStyle.stroke));
      expect(activeBorder.strokeWidth, closeTo(1.2, 1e-6));
      expect(activeBorder.color.a, closeTo(0.92, 0.02));
    });

    test('no-ops on empty size or empty highlights', () {
      final canvas = _RecordingCanvas();
      final emptyPainter = TerminalSearchHighlightPainter(
        highlightsProvider: () => const <TerminalSearchHighlight>[],
        topVirtualRowProvider: () => 0,
        cellWidth: 8.0,
        cellHeight: 16.0,
        cols: 10,
        rows: 5,
        matchColor: const Color(0xFF4C9AFF),
        activeMatchColor: const Color(0xFFFFB74D),
      );
      emptyPainter.paint(canvas, const Size(80, 80));
      expect(canvas.rectDraws, isEmpty);
      expect(canvas.saveCount, equals(0));

      final zeroSizePainter = TerminalSearchHighlightPainter(
        highlightsProvider: () => const <TerminalSearchHighlight>[
          TerminalSearchHighlight(virtualRow: 0, startCol: 0, endCol: 4),
        ],
        topVirtualRowProvider: () => 0,
        cellWidth: 8.0,
        cellHeight: 16.0,
        cols: 10,
        rows: 5,
        matchColor: const Color(0xFF4C9AFF),
        activeMatchColor: const Color(0xFFFFB74D),
      );
      zeroSizePainter.paint(canvas, Size.zero);
      expect(canvas.rectDraws, isEmpty);
    });

    test('shouldRepaint compares providers, metrics, and colors', () {
      List<TerminalSearchHighlight> readHighlights() =>
          const <TerminalSearchHighlight>[];
      int readTop() => 0;

      final base = TerminalSearchHighlightPainter(
        highlightsProvider: readHighlights,
        topVirtualRowProvider: readTop,
        cellWidth: 8.0,
        cellHeight: 16.0,
        cols: 80,
        rows: 24,
        matchColor: const Color(0xFF112233),
        activeMatchColor: const Color(0xFF445566),
      );
      final same = TerminalSearchHighlightPainter(
        highlightsProvider: readHighlights,
        topVirtualRowProvider: readTop,
        cellWidth: 8.0,
        cellHeight: 16.0,
        cols: 80,
        rows: 24,
        matchColor: const Color(0xFF112233),
        activeMatchColor: const Color(0xFF445566),
      );
      final diffCols = TerminalSearchHighlightPainter(
        highlightsProvider: readHighlights,
        topVirtualRowProvider: readTop,
        cellWidth: 8.0,
        cellHeight: 16.0,
        cols: 40,
        rows: 24,
        matchColor: const Color(0xFF112233),
        activeMatchColor: const Color(0xFF445566),
      );

      expect(base.shouldRepaint(same), isFalse);
      expect(base.shouldRepaint(diffCols), isTrue);
    });
  });

  group('TerminalSurface conditional search highlight overlay', () {
    testWidgets(
      'mounts zero extra CustomPaint when idle and toggles overlay on listenable updates',
      (tester) async {
        final buffer = Buffer.blank(20, 6);
        final bufferSignal = _TestBufferSignal();
        final highlightSignal = _TestListenable();
        final atlasController = GlyphAtlasController(fontSize: 13.0);
        addTearDown(atlasController.dispose);
        addTearDown(bufferSignal.dispose);
        addTearDown(highlightSignal.dispose);

        var topRow = 0;
        var highlights = const <TerminalSearchHighlight>[];
        var providerReadCount = 0;

        List<TerminalSearchHighlight> readHighlights() {
          providerReadCount++;
          return highlights;
        }

        await tester.pumpWidget(
          Directionality(
            textDirection: TextDirection.ltr,
            child: SizedBox(
              width: 320,
              height: 160,
              child: TerminalSurface(
                atlasController: atlasController,
                bufferProvider: () => buffer,
                bufferListenable: bufferSignal,
                topVirtualRowProvider: () => topRow,
                searchHighlightsProvider: readHighlights,
                searchHighlightsListenable: highlightSignal,
                searchMatchColor: const Color(0xFF3399FF),
                activeSearchMatchColor: const Color(0xFFFFAA00),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        // Idle: only the main terminal CustomPaint should be mounted.
        final allCustomPaints = find.descendant(
          of: find.byType(TerminalSurface),
          matching: find.byType(CustomPaint),
        );
        expect(allCustomPaints, findsOneWidget);

        // Transition empty -> non-empty mounts the overlay CustomPaint.
        highlights = const <TerminalSearchHighlight>[
          TerminalSearchHighlight(virtualRow: 1, startCol: 0, endCol: 4),
          TerminalSearchHighlight(
            virtualRow: 2,
            startCol: 5,
            endCol: 9,
            isActive: true,
          ),
        ];
        highlightSignal.emit();
        await tester.pump();

        expect(allCustomPaints, findsNWidgets(2));
        final overlayWidget = tester.widget<CustomPaint>(allCustomPaints.last);
        expect(overlayWidget.painter, isA<TerminalSearchHighlightPainter>());

        // Updating active highlight while non-empty repaints without mounting
        // extra CustomPaint widgets.
        final readsBeforeUpdate = providerReadCount;
        highlights = const <TerminalSearchHighlight>[
          TerminalSearchHighlight(
            virtualRow: 1,
            startCol: 0,
            endCol: 4,
            isActive: true,
          ),
          TerminalSearchHighlight(virtualRow: 2, startCol: 5, endCol: 9),
        ];
        highlightSignal.emit();
        await tester.pump();

        expect(allCustomPaints, findsNWidgets(2));
        expect(providerReadCount, greaterThan(readsBeforeUpdate));

        // Scrolling via bufferListenable repaints the highlight overlay too.
        final readsBeforeScroll = providerReadCount;
        topRow = 1;
        bufferSignal.emitCellChange();
        await tester.pump();

        expect(allCustomPaints, findsNWidgets(2));
        expect(providerReadCount, greaterThan(readsBeforeScroll));

        // Transition non-empty -> empty unmounts the overlay CustomPaint.
        highlights = const <TerminalSearchHighlight>[];
        highlightSignal.emit();
        await tester.pump();

        expect(allCustomPaints, findsOneWidget);
      },
    );

    testWidgets(
      'renders highlight overlay above TerminalShaderHost when shader binding is active',
      (tester) async {
        final buffer = Buffer.blank(20, 6);
        final highlightSignal = _TestListenable();
        final atlasController = GlyphAtlasController(fontSize: 13.0);
        final shaderController = TerminalShaderController(
          initialBackendOverride: ShaderBackendKind.disabled,
        );
        addTearDown(atlasController.dispose);
        addTearDown(shaderController.dispose);
        addTearDown(highlightSignal.dispose);

        var highlights = const <TerminalSearchHighlight>[];

        await tester.pumpWidget(
          Directionality(
            textDirection: TextDirection.ltr,
            child: SizedBox(
              width: 320,
              height: 160,
              child: TerminalSurface(
                atlasController: atlasController,
                shaderController: shaderController,
                shaderConfig: TerminalShaderConfig.empty,
                buffer: buffer,
                searchHighlightsProvider: () => highlights,
                searchHighlightsListenable: highlightSignal,
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        final surfaceFinder = find.byType(TerminalSurface);
        final customPaints = find.descendant(
          of: surfaceFinder,
          matching: find.byType(CustomPaint),
        );
        // Idle with shader host: still zero search overlay CustomPaint.
        final idleCount = tester.widgetList(customPaints).length;

        highlights = const <TerminalSearchHighlight>[
          TerminalSearchHighlight(
            virtualRow: 0,
            startCol: 0,
            endCol: 3,
            isActive: true,
          ),
        ];
        highlightSignal.emit();
        await tester.pump();

        expect(tester.widgetList(customPaints).length, equals(idleCount + 1));
        final overlayFinder = find.byWidgetPredicate(
          (w) =>
              w is CustomPaint && w.painter is TerminalSearchHighlightPainter,
        );
        expect(overlayFinder, findsOneWidget);
        // Must NOT be a descendant of TerminalShaderHost — it sits above it.
        expect(
          find.descendant(
            of: find.byType(TerminalShaderHost),
            matching: overlayFinder,
          ),
          findsNothing,
        );

        highlights = const <TerminalSearchHighlight>[];
        highlightSignal.emit();
        await tester.pump();

        expect(tester.widgetList(customPaints).length, equals(idleCount));
      },
    );
  });
}
