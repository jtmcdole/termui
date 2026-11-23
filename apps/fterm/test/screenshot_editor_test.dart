import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:fterm/src/feedback/screenshot_annotations.dart';
import 'package:fterm/src/font_loader.dart';
import 'package:fterm/src/ui/fterm_overlays.dart';
import 'package:fterm/src/ui/fterm_screenshot_editor.dart';
import 'package:material_ui/material_ui.dart';
import 'package:termui/termui.dart' as tui;

Future<ui.Image> _createSolidImage(int width, int height, Color color) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(
    recorder,
    Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
  );
  canvas.drawRect(
    Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
    Paint()..color = color,
  );
  final picture = recorder.endRecording();
  try {
    return await picture.toImage(width, height);
  } finally {
    picture.dispose();
  }
}

Future<({int r, int g, int b, int a})> _readPngPixel(
  Uint8List pngBytes,
  int x,
  int y,
) async {
  final codec = await ui.instantiateImageCodec(pngBytes);
  final frame = await codec.getNextFrame();
  final image = frame.image;
  try {
    final rgba = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    final bytes = rgba!.buffer.asUint8List();
    final offset = (y * image.width + x) * 4;
    return (
      r: bytes[offset],
      g: bytes[offset + 1],
      b: bytes[offset + 2],
      a: bytes[offset + 3],
    );
  } finally {
    image.dispose();
    codec.dispose();
  }
}

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    await loadCastFonts();
  });

  group('ScreenshotAnnotation geometry and summaries', () {
    test('normalizes reverse drags, clamps bounds, and projects rects', () {
      final a = ScreenshotAnnotation.fromNormalizedPoints(
        tool: ScreenshotAnnotationTool.redact,
        start: const Offset(0.8, 1.4),
        end: const Offset(-0.2, 0.25),
      );
      expect(
        a.normalizedRect,
        equals(const Rect.fromLTRB(0.0, 0.25, 0.8, 1.0)),
      );
      expect(a.isEmpty, isFalse);

      final projected = a.toCanvasRect(const Rect.fromLTWH(10, 20, 100, 200));
      expect(projected, equals(const Rect.fromLTRB(10, 70, 90, 220)));

      final b = ScreenshotAnnotation.fromNormalizedPoints(
        tool: ScreenshotAnnotationTool.redact,
        start: const Offset(0.0, 0.25),
        end: const Offset(0.8, 1.0),
      );
      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
    });

    test('computeFittedImageRect preserves aspect ratio and centers image', () {
      expect(
        computeFittedImageRect(const Size(400, 400), const Size(200, 100)),
        equals(const Rect.fromLTWH(0, 100, 400, 200)),
      );
      expect(
        computeFittedImageRect(const Size(400, 200), const Size(100, 200)),
        equals(const Rect.fromLTWH(150, 0, 100, 200)),
      );
      expect(
        computeFittedImageRect(Size.zero, const Size(100, 100)),
        equals(Rect.zero),
      );
    });

    test('pointerToNormalizedImagePoint respects hitSlop and clamps', () {
      const bounds = Rect.fromLTWH(20, 40, 200, 100);
      expect(
        pointerToNormalizedImagePoint(const Offset(120, 90), bounds),
        equals(const Offset(0.5, 0.5)),
      );
      // Within 8px slop clamps cleanly to edge.
      expect(
        pointerToNormalizedImagePoint(const Offset(15, 40), bounds),
        equals(const Offset(0.0, 0.0)),
      );
      // Far outside rejects drag start.
      expect(pointerToNormalizedImagePoint(const Offset(0, 0), bounds), isNull);
    });

    test('formatAnnotationSummary counts blackouts and highlights cleanly', () {
      expect(
        formatAnnotationSummary(const []),
        equals('No edits — raw pane capture'),
      );
      const r = Rect.fromLTRB(0.1, 0.1, 0.4, 0.4);
      expect(
        formatAnnotationSummary(const [
          ScreenshotAnnotation(
            tool: ScreenshotAnnotationTool.redact,
            normalizedRect: r,
          ),
        ]),
        equals('1 blackout'),
      );
      expect(
        formatAnnotationSummary(const [
          ScreenshotAnnotation(
            tool: ScreenshotAnnotationTool.redact,
            normalizedRect: r,
          ),
          ScreenshotAnnotation(
            tool: ScreenshotAnnotationTool.redact,
            normalizedRect: r,
          ),
          ScreenshotAnnotation(
            tool: ScreenshotAnnotationTool.highlight,
            normalizedRect: r,
          ),
        ]),
        equals('2 blackouts · 1 highlight'),
      );
    });
  });

  group('renderAnnotatedScreenshotPng pixel compositing', () {
    test('obliterates redacted pixels to opaque black, tints highlights, and leaves untouched pixels intact', () async {
      const bgColor = Color(0xFF00CCFF);
      final source = await _createSolidImage(120, 80, bgColor);
      addTearDown(source.dispose);

      // Unannotated export preserves exact pixels.
      final rawPng = await renderAnnotatedScreenshotPng(source, const []);
      expect(rawPng, isNotNull);
      final rawCenter = await _readPngPixel(rawPng!, 60, 40);
      expect(rawCenter, equals((r: 0, g: 0xCC, b: 0xFF, a: 255)));

      // Annotated export: left blackout, right highlight, center untouched.
      final annotatedPng = await renderAnnotatedScreenshotPng(source, const [
        ScreenshotAnnotation(
          tool: ScreenshotAnnotationTool.redact,
          normalizedRect: Rect.fromLTRB(0.0, 0.0, 0.30, 1.0),
        ),
        ScreenshotAnnotation(
          tool: ScreenshotAnnotationTool.highlight,
          normalizedRect: Rect.fromLTRB(0.70, 0.10, 0.95, 0.90),
        ),
      ]);
      expect(annotatedPng, isNotNull);

      // Redacted pixel (interior and edge) must be 100% opaque black.
      expect(
        await _readPngPixel(annotatedPng!, 15, 40),
        equals((r: 0, g: 0, b: 0, a: 255)),
      );
      expect(
        await _readPngPixel(annotatedPng, 0, 0),
        equals((r: 0, g: 0, b: 0, a: 255)),
      );

      // Center untouched pixel remains exact cyan.
      expect(
        await _readPngPixel(annotatedPng, 60, 40),
        equals((r: 0, g: 0xCC, b: 0xFF, a: 255)),
      );

      // Highlighted pixel is visibly tinted yellow while staying non-black.
      final hi = await _readPngPixel(annotatedPng, 98, 40);
      expect(hi.a, equals(255));
      expect(hi.r, greaterThan(40));
      expect(hi.g, greaterThan(180));
      expect(hi.b, lessThan(230));
    });
  });

  group('FtermScreenshotEditorDialog widget interaction', () {
    testWidgets(
      'supports Black Out & Highlight drag drawing, Undo/Redo/Clear, keyboard shortcuts, and Save/Cancel',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(1280, 820));
        addTearDown(() => tester.binding.setSurfaceSize(null));

        final image = await tester.runAsync(
          () => _createSolidImage(320, 200, const Color(0xFF1E293B)),
        );
        addTearDown(() => image!.dispose());

        final palette = FtermOverlayPalette.fromTerminalTheme(
          tui.TerminalColorTheme.presets.first,
        );

        List<ScreenshotAnnotation>? savedResult;
        await tester.pumpWidget(
          MaterialApp(
            debugShowCheckedModeBanner: false,
            home: Builder(
              builder: (context) => Scaffold(
                body: Center(
                  child: FilledButton(
                    key: const ValueKey('open-editor'),
                    onPressed: () async {
                      savedResult = await showFtermScreenshotEditorDialog(
                        context: context,
                        image: image!,
                        palette: palette,
                      );
                    },
                    child: const Text('Open'),
                  ),
                ),
              ),
            ),
          ),
        );

        await tester.tap(find.byKey(const ValueKey('open-editor')));
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('fterm-screenshot-editor')),
          findsOneWidget,
        );
        expect(
          find.textContaining('No edits — raw pane capture'),
          findsOneWidget,
        );

        final canvasFinder = find.byKey(
          const ValueKey('screenshot-editor-canvas'),
        );
        final canvasRect = tester.getRect(canvasFinder);

        // 1. Accidental tiny click (< 4px) is ignored.
        await tester.dragFrom(canvasRect.center, const Offset(1, 1));
        await tester.pumpAndSettle();
        expect(
          find.textContaining('No edits — raw pane capture'),
          findsOneWidget,
        );

        // 2. Default tool is Black Out: drag a redaction box.
        await tester.dragFrom(
          canvasRect.topLeft + const Offset(120, 80),
          const Offset(140, 60),
        );
        await tester.pumpAndSettle();
        expect(find.textContaining('1 blackout'), findsOneWidget);

        // 3. Press 'H' shortcut to switch to Highlight and drag a highlight box.
        await tester.sendKeyEvent(LogicalKeyboardKey.keyH);
        await tester.pumpAndSettle();
        await tester.dragFrom(
          canvasRect.topLeft + const Offset(300, 160),
          const Offset(150, 70),
        );
        await tester.pumpAndSettle();
        expect(find.textContaining('1 blackout · 1 highlight'), findsOneWidget);

        // 4. Undo removes highlight, Redo brings it back.
        await tester.tap(find.byKey(const ValueKey('screenshot-editor-undo')));
        await tester.pumpAndSettle();
        expect(find.textContaining('1 blackout · 320×200px'), findsOneWidget);

        await tester.tap(find.byKey(const ValueKey('screenshot-editor-redo')));
        await tester.pumpAndSettle();
        expect(find.textContaining('1 blackout · 1 highlight'), findsOneWidget);

        // 5. Clear removes both, then Undo/Redo restores cleanly via Redo.
        await tester.tap(find.byKey(const ValueKey('screenshot-editor-clear')));
        await tester.pumpAndSettle();
        expect(
          find.textContaining('No edits — raw pane capture'),
          findsOneWidget,
        );
        await tester.tap(find.byKey(const ValueKey('screenshot-editor-redo')));
        await tester.tap(find.byKey(const ValueKey('screenshot-editor-redo')));
        await tester.pumpAndSettle();
        expect(find.textContaining('1 blackout · 1 highlight'), findsOneWidget);

        // 6. Save PNG pops dialog with both annotations in draw order.
        await tester.tap(find.byKey(const ValueKey('screenshot-editor-save')));
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('fterm-screenshot-editor')),
          findsNothing,
        );
        expect(savedResult, isNotNull);
        expect(savedResult, hasLength(2));
        expect(savedResult![0].tool, equals(ScreenshotAnnotationTool.redact));
        expect(
          savedResult![1].tool,
          equals(ScreenshotAnnotationTool.highlight),
        );

        // 7. Re-open and cancel via Escape returns null.
        await tester.tap(find.byKey(const ValueKey('open-editor')));
        await tester.pumpAndSettle();
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('fterm-screenshot-editor')),
          findsNothing,
        );
        expect(savedResult, isNull);
      },
    );
  });
}
