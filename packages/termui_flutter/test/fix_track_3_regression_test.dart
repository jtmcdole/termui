import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart' hide Color;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:termui/terminal/terminal.dart' as term;
import 'package:termui/ui/buffer.dart';
import 'package:termui/ui/color.dart' as tui_color;
import 'package:termui/ui/style.dart';
import 'package:termui/ui/widgets/core/geometry.dart' as tui_geom;
import 'package:termui/ui/widgets/display/kitty_image.dart';
// ignore: implementation_imports
import 'package:termui_flutter/src/rendering/painter.dart';
// ignore: implementation_imports
import 'package:termui_flutter/src/service/terminal_service.dart';
// ignore: implementation_imports
import 'package:termui_flutter/src/terminal.dart';
import 'package:termui_flutter/termui_flutter.dart';

final class _TestTerminalService implements TerminalService {
  int screenshotCount = 0;
  int getClipboardCount = 0;
  String? clipboardText = 'clip';

  @override
  Future<String?> saveScreenshot(String basename, Uint8List bytes) async {
    screenshotCount++;
    return basename;
  }

  @override
  Future<void> setClipboard(String text) async {
    clipboardText = text;
  }

  @override
  Future<String?> getClipboard() async {
    getClipboardCount++;
    return clipboardText;
  }

  @override
  Future<bool> openUrl(String url) async => true;
}

Future<Uint8List> _createSolidPngBytes(
  int width,
  int height,
  ui.Color color,
) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawRect(
    Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
    Paint()..color = color,
  );
  final picture = recorder.endRecording();
  final image = await picture.toImage(width, height);
  picture.dispose();
  final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  return byteData!.buffer.asUint8List();
}

bool _hasCellColor(
  Uint8List rgba,
  int imageWidth,
  int imageHeight,
  double cellWidth,
  double cellHeight,
  int col,
  int r,
  int g,
  int b,
) {
  final x0 = (col * cellWidth).floor().clamp(0, imageWidth);
  final x1 = ((col + 1) * cellWidth).ceil().clamp(0, imageWidth);
  final y1 = cellHeight.ceil().clamp(0, imageHeight);
  for (var y = 0; y < y1; y++) {
    for (var x = x0; x < x1; x++) {
      final idx = (y * imageWidth + x) * 4;
      if (rgba[idx + 3] > 0 &&
          rgba[idx] == r &&
          rgba[idx + 1] == g &&
          rgba[idx + 2] == b) {
        return true;
      }
    }
  }
  return false;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('[H1] Key release gating & Kitty keyboard protocol', () {
    test('tracks Kitty keyboard CSI > / < / = u flags and explicit toggle', () {
      final terminal = FlutterTerminal();
      addTearDown(terminal.dispose);

      expect(terminal.reportKeyReleaseEvents, isFalse);

      // Push flags = 2 (report event types)
      terminal.backend.write('\x1b[>2u');
      expect(terminal.reportKeyReleaseEvents, isTrue);

      // Push flags = 1 (disambiguate only, bit 2 cleared)
      terminal.backend.write('\x1b[>1u');
      expect(terminal.reportKeyReleaseEvents, isFalse);

      // Pop 1 entry -> restores flags = 2
      terminal.backend.write('\x1b[<u');
      expect(terminal.reportKeyReleaseEvents, isTrue);

      // Modify mode 3 (clear bit 2): CSI = 2 ; 3 u
      terminal.backend.write('\x1b[=2;3u');
      expect(terminal.reportKeyReleaseEvents, isFalse);

      // Modify mode 2 (OR bit 2): CSI = 2 ; 2 u
      terminal.backend.write('\x1b[=2;2u');
      expect(terminal.reportKeyReleaseEvents, isTrue);

      // Set mode 1: CSI = 0 ; 1 u
      terminal.backend.write('\x1b[=0;1u');
      expect(terminal.reportKeyReleaseEvents, isFalse);

      // Mask to 5 bits (0x1F) and reset on RIS (\x1bc) and DECSTR (\x1b[!p)
      terminal.backend.write('\x1b[>63u');
      expect(terminal.kittyKeyboardFlags, equals(0x1F));
      terminal.backend.write('\x1bc');
      expect(terminal.kittyKeyboardFlags, equals(0));
      expect(terminal.reportKeyReleaseEvents, isFalse);

      terminal.backend.write('\x1b[=95;1u');
      expect(terminal.kittyKeyboardFlags, equals(0x1F));
      terminal.backend.write('\x1b[!p');
      expect(terminal.kittyKeyboardFlags, equals(0));

      // Explicit override
      terminal.setReportKeyReleaseEvents(true);
      expect(terminal.reportKeyReleaseEvents, isTrue);
      terminal.setReportKeyReleaseEvents(false);
      expect(terminal.reportKeyReleaseEvents, isFalse);
    });

    testWidgets(
      'ignores KeyUpEvent by default and emits release only when enabled without running host shortcuts',
      (tester) async {
        final terminal = FlutterTerminal();
        addTearDown(terminal.dispose);
        final service = _TestTerminalService();
        final events = <term.InputEvent>[];
        final sub = terminal.events.listen(events.add);
        addTearDown(sub.cancel);

        await tester.pumpWidget(
          MaterialApp(
            home: SizedBox(
              width: 400,
              height: 300,
              child: Terminal(
                terminal: terminal,
                service: service,
                onRun: (_, _) async {},
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        final focusFinder = find.descendant(
          of: find.byType(Terminal),
          matching: find.byType(Focus),
        );
        tester.widget<Focus>(focusFinder).focusNode?.requestFocus();
        await tester.pump();

        // Default: KeyDown + KeyUp produces ONLY a single press event.
        await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
        await tester.pump();
        expect(events.whereType<term.KeyEvent>().length, equals(1));
        expect(
          events.whereType<term.KeyEvent>().single.eventType,
          equals(term.KeyEventType.press),
        );

        // Enable Kitty key release reporting via CSI > 2 u
        events.clear();
        terminal.backend.write('\x1b[>2u');
        await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
        await tester.pump();
        final keyEvents = events.whereType<term.KeyEvent>().toList();
        expect(keyEvents.length, equals(2));
        expect(keyEvents[0].eventType, equals(term.KeyEventType.press));
        expect(keyEvents[1].eventType, equals(term.KeyEventType.release));

        // Even with release events enabled, Shift+Insert only pastes ONCE (on down, NOT up).
        final beforePasteCount = service.getClipboardCount;
        await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.insert);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
        await tester.pump();
        expect(service.getClipboardCount - beforePasteCount, equals(1));

        // Unshifted Control+O across C0 ('\x0f'), CapsLock ('O'), and lowercase ('o')
        // emits normalized KeyEvent('o', modifiers: {control}); Control+Shift+O populates shiftedCodepoint 79.
        terminal.backend.write('\x1b[=0;1u');
        for (final ch in const ['\x0f', 'O', 'o']) {
          events.clear();
          await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
          await tester.sendKeyEvent(LogicalKeyboardKey.keyO, character: ch);
          await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
          await tester.pump();
          expect(
            events.whereType<term.KeyEvent>().single,
            equals(
              const term.KeyEvent(
                'o',
                term.KeyType.character,
                modifiers: {term.Modifier.control},
              ),
            ),
          );
        }

        events.clear();
        await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.keyO, character: '\x0f');
        await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
        await tester.pump();
        expect(
          events.whereType<term.KeyEvent>().single,
          equals(
            const term.KeyEvent(
              'o',
              term.KeyType.character,
              modifiers: {term.Modifier.control, term.Modifier.shift},
              shiftedCodepoint: 79,
            ),
          ),
        );

        // AltGr (Control+Alt) composed characters must NOT be overwritten by keyLabel.
        for (final (key, composed) in const [
          (LogicalKeyboardKey.keyQ, '@'),
          (LogicalKeyboardKey.keyO, 'ó'),
        ]) {
          events.clear();
          await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
          await tester.sendKeyDownEvent(LogicalKeyboardKey.altRight);
          await tester.sendKeyEvent(key, character: composed);
          await tester.sendKeyUpEvent(LogicalKeyboardKey.altRight);
          await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
          await tester.pump();
          expect(
            events.whereType<term.KeyEvent>().single,
            equals(
              term.KeyEvent(
                composed,
                term.KeyType.character,
                modifiers: const {term.Modifier.control, term.Modifier.alt},
              ),
            ),
          );
        }

        // Shift+<letter> release (KeyUpEvent has null character) keeps shiftedCodepoint.
        terminal.backend.write('\x1b[=2;1u');
        await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
        await tester.sendKeyDownEvent(LogicalKeyboardKey.keyO, character: 'O');
        events.clear();
        await tester.sendKeyUpEvent(LogicalKeyboardKey.keyO);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
        await tester.pump();
        expect(
          events.whereType<term.KeyEvent>().single,
          equals(
            const term.KeyEvent(
              'o',
              term.KeyType.character,
              modifiers: {term.Modifier.shift},
              eventType: term.KeyEventType.release,
              shiftedCodepoint: 79,
            ),
          ),
        );
      },
    );
  });

  group('[L4] & Phase 4/5: Ligature controls & MouseEvent pixelX/pixelY', () {
    testWidgets(
      'toggleLigatures works, caller terminal is not mutated in initState, and widget enableLigatures is non-sticky',
      (tester) async {
        final callerTerminal = FlutterTerminal(enableLigatures: false);
        addTearDown(callerTerminal.dispose);

        var widgetEnableLigatures = true;
        late StateSetter rebuildHost;

        await tester.pumpWidget(
          MaterialApp(
            home: StatefulBuilder(
              builder: (context, setState) {
                rebuildHost = setState;
                return SizedBox(
                  width: 400,
                  height: 300,
                  child: Terminal(
                    terminal: callerTerminal,
                    enableLigatures: widgetEnableLigatures,
                    onRun: (_, drawFrame) async {
                      drawFrame(Buffer(10, 2));
                    },
                  ),
                );
              },
            ),
          ),
        );
        await tester.pumpAndSettle();

        // Caller-supplied terminal must NOT have been mutated in initState!
        expect(callerTerminal.enableLigatures, isFalse);

        CustomPaint paintWidget() => tester.widget<CustomPaint>(
          find.descendant(
            of: find.byType(PrivateTuiView),
            matching: find.byType(CustomPaint),
          ),
        );

        expect(
          (paintWidget().painter! as TuiAtlasPainter).enableLigatures,
          isTrue,
        );

        // Rebuilding Terminal(enableLigatures: true -> false) must turn ligatures off!
        rebuildHost(() {
          widgetEnableLigatures = false;
        });
        await tester.pump();
        expect(
          (paintWidget().painter! as TuiAtlasPainter).enableLigatures,
          isFalse,
        );

        // Runtime toggleLigatures() flips ligatures dynamically.
        callerTerminal.toggleLigatures();
        await tester.pumpAndSettle();
        expect(callerTerminal.enableLigatures, isTrue);
        expect(
          (paintWidget().painter! as TuiAtlasPainter).enableLigatures,
          isTrue,
        );

        callerTerminal.toggleLigatures();
        await tester.pumpAndSettle();
        expect(callerTerminal.enableLigatures, isFalse);
        expect(
          (paintWidget().painter! as TuiAtlasPainter).enableLigatures,
          isFalse,
        );
      },
    );

    testWidgets('populates 1-based pixelX and pixelY on MouseEvent', (
      tester,
    ) async {
      final terminal = FlutterTerminal();
      addTearDown(terminal.dispose);
      final mouseEvents = <term.MouseEvent>[];
      final sub = terminal.events.listen((e) {
        if (e is term.MouseEvent) mouseEvents.add(e);
      });
      addTearDown(sub.cancel);

      await tester.pumpWidget(
        MaterialApp(
          home: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 400,
              height: 300,
              child: Terminal(
                terminal: terminal,
                onRun: (_, drawFrame) async {
                  drawFrame(Buffer(20, 10));
                },
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final customPaintFinder = find.descendant(
        of: find.byType(PrivateTuiView),
        matching: find.byType(CustomPaint),
      );
      final topLeft = tester.getTopLeft(customPaintFinder);
      final gesture = await tester.startGesture(
        topLeft + const Offset(23.7, 41.2),
        kind: PointerDeviceKind.mouse,
      );
      await tester.pump();
      await gesture.up();
      await tester.pump();

      expect(mouseEvents, isNotEmpty);
      expect(mouseEvents.first.pixelX, equals(24));
      expect(mouseEvents.first.pixelY, equals(42));
    });
  });

  group('[M7] & Phase 4: GlyphStyleVariant, pre-baked ligatures, lazy variants', () {
    test(
      'GlyphAtlas pre-bakes 19 ligatures across 4 GlyphStyleVariants and addStyledGlyphs allocates lazily',
      () async {
        expect(
          GlyphStyleVariant.fromFlags(isBold: false, isItalic: false),
          equals(GlyphStyleVariant.regular),
        );
        expect(
          GlyphStyleVariant.fromFlags(isBold: true, isItalic: false),
          equals(GlyphStyleVariant.bold),
        );
        expect(
          GlyphStyleVariant.fromFlags(isBold: false, isItalic: true),
          equals(GlyphStyleVariant.italic),
        );
        expect(
          GlyphStyleVariant.fromFlags(isBold: true, isItalic: true),
          equals(GlyphStyleVariant.boldItalic),
        );

        final atlas = await GlyphAtlasGenerator.generate(
          fontSize: 14.0,
          fontFamily: 'Roboto Mono',
        );
        addTearDown(atlas.image.dispose);

        const expectedLigatures = [
          '->',
          '=>',
          '!=',
          '==',
          '<=',
          '>=',
          '===',
          '!==',
          '::',
          '|>',
          '&&',
          '||',
          '++',
          '--',
          '//',
          '??',
          '?.',
          '..',
          '...',
        ];
        for (final lig in expectedLigatures) {
          for (final variant in GlyphStyleVariant.values) {
            final rect = atlas.styledCharRects[(lig, variant)];
            expect(
              rect,
              isNotNull,
              reason: 'Missing pre-baked ligature $lig ($variant)',
            );
            expect(
              rect!.width,
              closeTo(
                lig.length * atlas.cellWidth * atlas.devicePixelRatio,
                0.01,
              ),
            );
            expect(
              atlas.rectFor(
                lig,
                isBold: variant.isBold,
                isItalic: variant.isItalic,
              ),
              equals(rect),
            );
          }
        }

        // Lazy dynamic CJK variant allocation: adding regular '漢' (wide = 2 cols)
        // advances nextGridIndex by at most 3 (2 + at most 1 wrap alignment), NOT 8!
        final beforeIdx = atlas.nextGridIndex;
        final cjkAtlas = await atlas.addStyledGlyphs(const [
          ('漢', GlyphStyleVariant.regular),
        ]);
        addTearDown(cjkAtlas.image.dispose);

        expect(cjkAtlas.nextGridIndex - beforeIdx, lessThanOrEqualTo(3));
        expect(
          cjkAtlas.styledCharRects.containsKey((
            '漢',
            GlyphStyleVariant.regular,
          )),
          isTrue,
        );
        expect(
          cjkAtlas.styledCharRects.containsKey(('漢', GlyphStyleVariant.bold)),
          isFalse,
        );
      },
    );
  });

  group('[H7] & [MEDIUM-4]: Hidden ligatures, LRU cap, and font resize disposal', () {
    test(
      'Modifier.hidden ligatures draw zero fg pixels when unselected and reveal when selected',
      () async {
        final atlas = await GlyphAtlasGenerator.generate(
          fontSize: 16.0,
          fontFamily: 'Roboto Mono',
        );
        addTearDown(atlas.image.dispose);

        final buffer = Buffer(12, 1)
          ..writeString(
            0,
            0,
            '==',
            const Style(
              foreground: tui_color.Color(255, 128, 0),
              modifiers: Modifier.hidden,
            ),
          )
          ..writeString(
            3,
            0,
            '->',
            const Style(
              foreground: tui_color.Color(255, 128, 0),
              modifiers: Modifier.hidden,
            ),
          )
          ..writeString(
            6,
            0,
            '<!--',
            const Style(
              foreground: tui_color.Color(255, 128, 0),
              modifiers: Modifier.hidden,
            ),
          );

        final w = (12 * atlas.cellWidth).ceil();
        final h = atlas.cellHeight.ceil();
        final ligaturePainters =
            <(String, bool, bool, ui.Color), TextPainter>{};

        final recorder = ui.PictureRecorder();
        final canvas = Canvas(recorder);
        TuiAtlasPainter(
          buffer: buffer,
          atlas: atlas,
          fontFamily: 'Roboto Mono',
          fallbackPainters: const {},
          ligaturePainters: ligaturePainters,
          enableLigatures: true,
          onMissingGlyphs: null,
        ).paint(canvas, Size(w.toDouble(), h.toDouble()));
        final pic = recorder.endRecording();
        final img = await pic.toImage(w, h);
        pic.dispose();
        addTearDown(img.dispose);
        final rgba = (await img.toByteData())!.buffer.asUint8List();

        expect(ligaturePainters, isEmpty);
        for (var col = 0; col < 10; col++) {
          expect(
            _hasCellColor(
              rgba,
              w,
              h,
              atlas.cellWidth,
              atlas.cellHeight,
              col,
              255,
              128,
              0,
            ),
            isFalse,
            reason: 'Hidden ligature col $col must not render foreground',
          );
        }

        // Now select cols 0..1 ('==') and verify white glyph pixels appear!
        final selRecorder = ui.PictureRecorder();
        final selCanvas = Canvas(selRecorder);
        TuiAtlasPainter(
          buffer: buffer,
          atlas: atlas,
          fontFamily: 'Roboto Mono',
          fallbackPainters: const {},
          ligaturePainters: ligaturePainters,
          enableLigatures: true,
          onMissingGlyphs: null,
          selectionStart: const math.Point(0, 0),
          selectionEnd: const math.Point(1, 0),
        ).paint(selCanvas, Size(w.toDouble(), h.toDouble()));
        final selPic = selRecorder.endRecording();
        final selImg = await selPic.toImage(w, h);
        selPic.dispose();
        addTearDown(selImg.dispose);
        final selRgba = (await selImg.toByteData())!.buffer.asUint8List();

        final revealed =
            _hasCellColor(
              selRgba,
              w,
              h,
              atlas.cellWidth,
              atlas.cellHeight,
              0,
              255,
              255,
              255,
            ) ||
            _hasCellColor(
              selRgba,
              w,
              h,
              atlas.cellWidth,
              atlas.cellHeight,
              1,
              255,
              255,
              255,
            );
        expect(revealed, isTrue);
      },
    );

    test(
      'fallback ligaturePainters caps at 128 entries and disposes on font-size change',
      () async {
        final emptyAtlas = await GlyphAtlasGenerator.generateEmpty(
          fontSize: 14.0,
          fontFamily: 'Roboto Mono',
        );
        addTearDown(emptyAtlas.image.dispose);

        final ligaturePainters =
            <(String, bool, bool, ui.Color), TextPainter>{};
        final buffer = Buffer(4, 1);
        for (var i = 0; i < 150; i++) {
          buffer.writeString(
            0,
            0,
            '<!--',
            Style(foreground: tui_color.Color(i, (i * 3) & 0xFF, 128)),
          );
          final recorder = ui.PictureRecorder();
          final canvas = Canvas(recorder);
          TuiAtlasPainter(
            buffer: buffer,
            atlas: emptyAtlas,
            fontFamily: 'Roboto Mono',
            fallbackPainters: const {},
            ligaturePainters: ligaturePainters,
            enableLigatures: true,
            onMissingGlyphs: null,
          ).paint(
            canvas,
            Size(4 * emptyAtlas.cellWidth, emptyAtlas.cellHeight),
          );
          recorder.endRecording().dispose();
        }

        expect(ligaturePainters.length, equals(128));
        for (final p in ligaturePainters.values) {
          p.dispose();
        }
      },
    );

    testWidgets(
      'PrivateTuiViewState disposes and clears fallback ligaturePainters on font resize',
      (tester) async {
        final terminal = FlutterTerminal(
          initialFontSize: 14.0,
          enableLigatures: true,
        );
        addTearDown(terminal.dispose);
        late void Function(Buffer) drawFrame;

        await tester.pumpWidget(
          MaterialApp(
            home: SizedBox(
              width: 400,
              height: 300,
              child: Terminal(
                terminal: terminal,
                enableLigatures: true,
                onRun: (_, onDraw) async {
                  drawFrame = onDraw;
                },
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        // '<!--' is a 4-char ligature not in the 19 pre-baked ligatures -> uses _ligaturePainters
        final buf = Buffer(10, 2)
          ..writeString(
            0,
            0,
            '<!--',
            const Style(foreground: tui_color.Color(10, 200, 100)),
          );
        drawFrame(buf);
        await tester.pumpAndSettle();

        CustomPaint paintWidget() => tester.widget<CustomPaint>(
          find.descendant(
            of: find.byType(PrivateTuiView),
            matching: find.byType(CustomPaint),
          ),
        );

        final paintersBefore =
            (paintWidget().painter! as TuiAtlasPainter).ligaturePainters;
        expect(paintersBefore, isNotEmpty);
        final oldPainterRef = paintersBefore.values.first;

        // Change font size -> _recreateAtlas() must dispose & clear _ligaturePainters
        terminal.setFontSize(18.0);
        await tester.pumpAndSettle();

        // After font size change, oldPainterRef was disposed (debugAssertNotDisposed or replaced)
        final paintersAfter =
            (paintWidget().painter! as TuiAtlasPainter).ligaturePainters;
        expect(
          paintersAfter.values.any((p) => identical(p, oldPainterRef)),
          isFalse,
        );
      },
    );
  });

  group(
    '[HIGH-2 / L5], [MEDIUM-1], [H6]: Kitty PNG f=100, 32-bit IDs, scoped registries',
    () {
      test(
        'TuiAtlasPainter resolves 32-bit imageIds and scoped Buffer.registerKittyRegistry without collision',
        () async {
          final atlas = await GlyphAtlasGenerator.generate(
            fontSize: 16.0,
            fontFamily: 'Roboto Mono',
          );
          addTearDown(atlas.image.dispose);

          // Test 1: 32-bit imageIds sharing low 24 bits (0x01000005 vs 0x02000005)
          final registry32 = KittyImageRegistry();
          final redData = KittyImageData(
            imageId: 0x01000005,
            pixelWidth: 1,
            pixelHeight: 1,
            rgbaPixels: Uint8List.fromList([255, 0, 0, 255]),
            gridCols: 1,
            gridRows: 1,
          );
          final greenData = KittyImageData(
            imageId: 0x02000005,
            pixelWidth: 1,
            pixelHeight: 1,
            rgbaPixels: Uint8List.fromList([0, 255, 0, 255]),
            gridCols: 1,
            gridRows: 1,
          );
          registry32.registerImage(redData);
          registry32.registerImage(greenData);

          // Test 2: Two scoped panes BOTH using imageId = 1 with distinct colors (blue vs yellow)
          final leftRegistry = KittyImageRegistry()
            ..registerImage(
              KittyImageData(
                imageId: 1,
                pixelWidth: 1,
                pixelHeight: 1,
                rgbaPixels: Uint8List.fromList([0, 0, 255, 255]),
                gridCols: 1,
                gridRows: 1,
              ),
            );
          final rightRegistry = KittyImageRegistry()
            ..registerImage(
              KittyImageData(
                imageId: 1,
                pixelWidth: 1,
                pixelHeight: 1,
                rgbaPixels: Uint8List.fromList([255, 255, 0, 255]),
                gridCols: 1,
                gridRows: 1,
              ),
            );

          final buffer = Buffer(4, 1)
            ..registerKittyRegistry(const tui_geom.Rect(0, 0, 2, 1), registry32)
            ..registerKittyRegistry(
              const tui_geom.Rect(2, 0, 1, 1),
              leftRegistry,
            )
            ..registerKittyRegistry(
              const tui_geom.Rect(3, 0, 1, 1),
              rightRegistry,
            );

          // Col 0: 0x01000005 (msb=1, low24=5 -> red)
          buffer.setAttributes(
            0,
            0,
            char: kittyPlaceholderCell(0, 0, imageIdMsb: 1),
            fg: 0xFF000005,
            bg: 0xFF000000,
            modifiers: Modifier.kittyPlaceholder,
          );
          // Col 1: 0x02000005 (msb=2, low24=5 -> green)
          buffer.setAttributes(
            1,
            0,
            char: kittyPlaceholderCell(0, 0, imageIdMsb: 2),
            fg: 0xFF000005,
            bg: 0xFF000000,
            modifiers: Modifier.kittyPlaceholder,
          );
          // Col 2: left pane imageId = 1 -> blue
          buffer.setAttributes(
            2,
            0,
            char: kittyPlaceholderCell(0, 0),
            fg: 0xFF000001,
            bg: 0xFF000000,
            modifiers: Modifier.kittyPlaceholder,
          );
          // Col 3: right pane imageId = 1 -> yellow
          buffer.setAttributes(
            3,
            0,
            char: kittyPlaceholderCell(0, 0),
            fg: 0xFF000001,
            bg: 0xFF000000,
            modifiers: Modifier.kittyPlaceholder,
          );

          final w = (4 * atlas.cellWidth).ceil();
          final h = atlas.cellHeight.ceil();
          final recorder = ui.PictureRecorder();
          final canvas = Canvas(recorder);
          TuiAtlasPainter(
            buffer: buffer,
            atlas: atlas,
            fontFamily: 'Roboto Mono',
            fallbackPainters: const {},
            onMissingGlyphs: null,
          ).paint(canvas, Size(w.toDouble(), h.toDouble()));
          final pic = recorder.endRecording();
          final img = await pic.toImage(w, h);
          pic.dispose();
          addTearDown(img.dispose);
          final rgba = (await img.toByteData())!.buffer.asUint8List();

          expect(
            _hasCellColor(
              rgba,
              w,
              h,
              atlas.cellWidth,
              atlas.cellHeight,
              0,
              255,
              0,
              0,
            ),
            isTrue,
          );
          expect(
            _hasCellColor(
              rgba,
              w,
              h,
              atlas.cellWidth,
              atlas.cellHeight,
              1,
              0,
              255,
              0,
            ),
            isTrue,
          );
          expect(
            _hasCellColor(
              rgba,
              w,
              h,
              atlas.cellWidth,
              atlas.cellHeight,
              2,
              0,
              0,
              255,
            ),
            isTrue,
          );
          expect(
            _hasCellColor(
              rgba,
              w,
              h,
              atlas.cellWidth,
              atlas.cellHeight,
              3,
              255,
              255,
              0,
            ),
            isTrue,
          );
        },
      );

      testWidgets(
        'decodes f=100 PNG KittyImageData via instantiateImageCodec and isolates scoped GPU images',
        (tester) async {
          late Uint8List pngCyan;
          late Uint8List pngMagenta;
          await tester.runAsync(() async {
            pngCyan = await _createSolidPngBytes(
              4,
              4,
              const ui.Color(0xFF00FFFF),
            );
            pngMagenta = await _createSolidPngBytes(
              4,
              4,
              const ui.Color(0xFFFF00FF),
            );
          });

          final paneA = KittyImageRegistry()
            ..registerImage(
              KittyImageData.fromPng(
                imageId: 1,
                pixelWidth: 4,
                pixelHeight: 4,
                pngBytes: pngCyan,
                gridCols: 1,
                gridRows: 1,
              ),
            );
          final paneB = KittyImageRegistry()
            ..registerImage(
              KittyImageData.fromPng(
                imageId: 1,
                pixelWidth: 4,
                pixelHeight: 4,
                pngBytes: pngMagenta,
                gridCols: 1,
                gridRows: 1,
              ),
            );

          final terminal = FlutterTerminal();
          addTearDown(terminal.dispose);
          late void Function(Buffer) drawFrame;

          await tester.pumpWidget(
            MaterialApp(
              home: SizedBox(
                width: 300,
                height: 200,
                child: Terminal(
                  terminal: terminal,
                  onRun: (_, onDraw) async {
                    drawFrame = onDraw;
                  },
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();

          final buf = Buffer(4, 2)
            ..registerKittyRegistry(const tui_geom.Rect(0, 0, 2, 2), paneA)
            ..registerKittyRegistry(const tui_geom.Rect(2, 0, 2, 2), paneB);
          buf.setAttributes(
            0,
            0,
            char: kittyPlaceholderCell(0, 0),
            fg: 0xFF000001,
            bg: 0xFF000000,
            modifiers: Modifier.kittyPlaceholder,
          );
          buf.setAttributes(
            2,
            0,
            char: kittyPlaceholderCell(0, 0),
            fg: 0xFF000001,
            bg: 0xFF000000,
            modifiers: Modifier.kittyPlaceholder,
          );

          drawFrame(buf);
          await tester.runAsync(() async {
            for (var i = 0; i < 30; i++) {
              await Future<void>.delayed(const Duration(milliseconds: 10));
            }
          });
          await tester.pumpAndSettle();

          final paintWidget = tester.widget<CustomPaint>(
            find.descendant(
              of: find.byType(PrivateTuiView),
              matching: find.byType(CustomPaint),
            ),
          );
          final activePainter = paintWidget.painter! as TuiAtlasPainter;
          final dataA = paneA.lookupImage(1)!;
          final dataB = paneB.lookupImage(1)!;

          // Both distinct PNG KittyImageData instances with imageId == 1 must be decoded and cached!
          expect(activePainter.kittyImages[dataA], isNotNull);
          expect(activePainter.kittyImages[dataB], isNotNull);
          expect(
            identical(
              activePainter.kittyImages[dataA],
              activePainter.kittyImages[dataB],
            ),
            isFalse,
          );

          // Verify painting with those decoded GPU PNG textures renders both cyan and magenta!
          final w = (4 * activePainter.atlas.cellWidth).ceil();
          final h = (2 * activePainter.atlas.cellHeight).ceil();
          final recorder = ui.PictureRecorder();
          final canvas = Canvas(recorder);
          activePainter.paint(canvas, Size(w.toDouble(), h.toDouble()));
          final pic = recorder.endRecording();
          late Uint8List rgba;
          await tester.runAsync(() async {
            final img = await pic.toImage(w, h);
            pic.dispose();
            rgba = (await img.toByteData())!.buffer.asUint8List();
            img.dispose();
          });

          expect(
            _hasCellColor(
              rgba,
              w,
              h,
              activePainter.atlas.cellWidth,
              activePainter.atlas.cellHeight,
              0,
              0,
              255,
              255,
            ),
            isTrue,
          );
          expect(
            _hasCellColor(
              rgba,
              w,
              h,
              activePainter.atlas.cellWidth,
              activePainter.atlas.cellHeight,
              2,
              255,
              0,
              255,
            ),
            isTrue,
          );
        },
      );

      testWidgets(
        'deduplicates intra-cell pointer motion unless ?1016 SGR-Pixels is active',
        (tester) async {
          final terminal = FlutterTerminal();
          addTearDown(terminal.dispose);
          final mouseEvents = <term.MouseEvent>[];
          final sub = terminal.events.listen((e) {
            if (e is term.MouseEvent) mouseEvents.add(e);
          });
          addTearDown(sub.cancel);

          await tester.pumpWidget(
            MaterialApp(
              home: Align(
                alignment: Alignment.topLeft,
                child: SizedBox(
                  width: 400,
                  height: 300,
                  child: Terminal(
                    terminal: terminal,
                    onRun: (_, drawFrame) async {
                      drawFrame(Buffer(20, 10));
                    },
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();

          final customPaintFinder = find.descendant(
            of: find.byType(PrivateTuiView),
            matching: find.byType(CustomPaint),
          );
          final topLeft = tester.getTopLeft(customPaintFinder);

          // Default (?1016 off): intra-cell sub-pixel drags within cell (0,0) emit once on press + first drag, not per pixel!
          expect(terminal.reportPixelMouseEvents, isFalse);
          final gesture = await tester.startGesture(
            topLeft + const Offset(1.0, 2.0),
            kind: PointerDeviceKind.mouse,
          );
          await tester.pump();
          await gesture.moveTo(topLeft + const Offset(2.0, 2.0));
          await tester.pump();
          await gesture.moveTo(topLeft + const Offset(3.0, 2.0));
          await tester.pump();
          await gesture.up();
          await tester.pump();

          final dragCountDefault = mouseEvents
              .where((e) => e.type == term.MouseEventType.drag)
              .length;
          expect(dragCountDefault, lessThanOrEqualTo(1));

          // Enable ?1016 via DECSET sequence: every 1px drag emits a distinct MouseEvent.
          mouseEvents.clear();
          terminal.backend.write('\x1b[?1002;1016h');
          expect(terminal.reportPixelMouseEvents, isTrue);

          final gesturePx = await tester.startGesture(
            topLeft + const Offset(1.0, 2.0),
            kind: PointerDeviceKind.mouse,
          );
          await tester.pump();
          await gesturePx.moveTo(topLeft + const Offset(2.0, 2.0));
          await tester.pump();
          await gesturePx.moveTo(topLeft + const Offset(3.0, 2.0));
          await tester.pump();
          await gesturePx.up();
          await tester.pump();

          final dragEventsPx = mouseEvents
              .where((e) => e.type == term.MouseEventType.drag)
              .toList();
          expect(dragEventsPx.length, equals(2));
          expect(dragEventsPx[0].pixelX, equals(3));
          expect(dragEventsPx[1].pixelX, equals(4));

          terminal.backend.write('\x1b[?1016l');
          expect(terminal.reportPixelMouseEvents, isFalse);
        },
      );

      testWidgets(
        'kittyImagesById retains previous GPU texture when KittyImageData version updates',
        (tester) async {
          late Uint8List pngCyan;
          late ui.Image gpuTex;
          late GlyphAtlas atlas;
          await tester.runAsync(() async {
            pngCyan = await _createSolidPngBytes(
              4,
              4,
              const ui.Color(0xFF00FFFF),
            );
            final codec = await ui.instantiateImageCodec(pngCyan);
            final frame = await codec.getNextFrame();
            gpuTex = frame.image;
            codec.dispose();
            atlas = await GlyphAtlasGenerator.generate(
              fontSize: 14.0,
              fontFamily: 'Roboto Mono',
            );
          });
          addTearDown(gpuTex.dispose);
          addTearDown(atlas.image.dispose);

          final registry = KittyImageRegistry()
            ..registerImage(
              KittyImageData.fromPng(
                imageId: 42,
                pixelWidth: 4,
                pixelHeight: 4,
                pngBytes: pngCyan,
                gridCols: 1,
                gridRows: 1,
              ),
            );
          final dataV1 = registry.lookupImage(42)!;
          final dataV2 = dataV1.copyWith(gridCols: 2, version: 2);
          registry.registerImage(dataV2);

          final buf = Buffer(4, 2)
            ..registerKittyRegistry(const tui_geom.Rect(0, 0, 4, 2), registry);
          buf.setAttributes(
            0,
            0,
            char: kittyPlaceholderCell(0, 0),
            fg: 0xFF00002A,
            bg: 0xFF000000,
            modifiers: Modifier.kittyPlaceholder,
          );
          buf.setAttributes(
            1,
            0,
            char: kittyPlaceholderCell(0, 1),
            fg: 0xFF00002A,
            bg: 0xFF000000,
            modifiers: Modifier.kittyPlaceholder,
          );

          // Simulate frame right after dataV2 was registered (before dataV2 is in kittyImages,
          // while kittyImagesById[(registry, 42)] still holds gpuTex).
          final painter = TuiAtlasPainter(
            buffer: buf,
            atlas: atlas,
            fontFamily: 'Roboto Mono',
            fallbackPainters: {},
            onMissingGlyphs: null,
            kittyImages: {dataV1: gpuTex},
            kittyImagesById: {(registry, 42): gpuTex},
          );
          final w = (4 * atlas.cellWidth).ceil();
          final h = (2 * atlas.cellHeight).ceil();
          final recorder = ui.PictureRecorder();
          painter.paint(Canvas(recorder), Size(w.toDouble(), h.toDouble()));
          final pic = recorder.endRecording();
          late Uint8List rgba;
          await tester.runAsync(() async {
            final img = await pic.toImage(w, h);
            pic.dispose();
            rgba = (await img.toByteData())!.buffer.asUint8List();
            img.dispose();
          });

          // PNG tile must render cyan from kittyImagesById[(global, 42)] instead of blanking!
          expect(
            _hasCellColor(
              rgba,
              w,
              h,
              atlas.cellWidth,
              atlas.cellHeight,
              0,
              0,
              255,
              255,
            ),
            isTrue,
          );

          // A separate pane registry with imageId 42 must NOT inherit global's texture!
          final otherPaneRegistry = KittyImageRegistry()..registerImage(dataV2);
          buf.registerKittyRegistry(
            const tui_geom.Rect(0, 0, 4, 2),
            otherPaneRegistry,
          );
          final isolatedRecorder = ui.PictureRecorder();
          painter.paint(
            Canvas(isolatedRecorder),
            Size(w.toDouble(), h.toDouble()),
          );
          final isolatedPic = isolatedRecorder.endRecording();
          late Uint8List isolatedRgba;
          await tester.runAsync(() async {
            final img = await isolatedPic.toImage(w, h);
            isolatedPic.dispose();
            isolatedRgba = (await img.toByteData())!.buffer.asUint8List();
            img.dispose();
          });
          expect(
            _hasCellColor(
              isolatedRgba,
              w,
              h,
              atlas.cellWidth,
              atlas.cellHeight,
              0,
              0,
              255,
              255,
            ),
            isFalse,
          );
        },
      );

      test(
        'GlyphAtlas.addStyledGlyphs safely aborts without drawImage assertion if disposed mid-flight',
        () async {
          final atlas = await GlyphAtlasGenerator.generate(
            fontSize: 14.0,
            fontFamily: 'Roboto Mono',
          );
          final inFlight = atlas.addStyledGlyphs([
            ('A', GlyphStyleVariant.boldItalic),
          ]);
          atlas.dispose();
          final returned = await inFlight;
          expect(identical(returned, atlas), isTrue);
          expect(atlas.isDisposed, isTrue);
        },
      );
    },
  );
}
