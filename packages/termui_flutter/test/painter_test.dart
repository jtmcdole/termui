import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/rendering.dart' show RenderCustomPaint;
import 'package:flutter/widgets.dart' hide Color;
import 'package:flutter_test/flutter_test.dart';
import 'package:termui/ui/buffer.dart';
import 'package:termui/ui/color.dart';
import 'package:termui/ui/style.dart';
import 'package:termui/ui/terminal_palette.dart';
import 'package:termui/ui/widgets/core/geometry.dart' as tui_geo;
import 'package:termui/ui/widgets/display/kitty_image.dart';
import 'package:termui_flutter/termui_flutter.dart';
// ignore: implementation_imports
import 'package:termui_flutter/src/rendering/painter.dart';
// ignore: implementation_imports
import 'package:termui_flutter/src/terminal.dart'
    show PrivateTuiView, PrivateTuiViewState;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('isColorEmoji properly distinguishes emoji variations', () {
    // Should be color emojis
    expect(isColorEmoji('🚀'), isTrue, reason: 'Modern emoji should be color');
    expect(
      isColorEmoji('♠\uFE0F'),
      isTrue,
      reason: 'Emoji variation selector makes it color',
    );

    // Should be monochrome (should NOT be color emojis)
    expect(
      isColorEmoji('♠'),
      isFalse,
      reason: 'Naked card suit should be monochrome',
    );
    expect(
      isColorEmoji('♥'),
      isFalse,
      reason: 'Naked card suit should be monochrome',
    );
    expect(
      isColorEmoji('🚀\uFE0E'),
      isFalse,
      reason: 'Text variation selector forces monochrome',
    );
    expect(isColorEmoji('A'), isFalse, reason: 'Normal text is monochrome');
  });

  test(
    'GlyphAtlasGenerator.generateEmpty includes \\uFFFF and paints cleanly',
    () async {
      final atlas = await GlyphAtlasGenerator.generateEmpty(
        fontSize: 13.0,
        fontFamily: 'Roboto Mono',
      );
      addTearDown(() => atlas.image.dispose());

      expect(atlas.charRects.containsKey('\uFFFF'), isTrue);
      expect(atlas.nextGridIndex, equals(1));

      final buffer = Buffer(4, 2)..writeString(0, 0, 'Hi', Style.empty);
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      final painter = TuiAtlasPainter(
        buffer: buffer,
        atlas: atlas,
        fontFamily: 'Roboto Mono',
        fallbackPainters: const {},
        onMissingGlyphs: null,
      );

      expect(
        () => painter.paint(
          canvas,
          Size(4 * atlas.cellWidth, 2 * atlas.cellHeight),
        ),
        returnsNormally,
      );
      recorder.endRecording().dispose();
    },
  );

  test(
    'TuiAtlasPainter renders text modifiers, underline styles, and underlineColor',
    () async {
      final atlas = await GlyphAtlasGenerator.generate(
        fontSize: 16.0,
        fontFamily: 'Roboto Mono',
      );
      addTearDown(() => atlas.image.dispose());

      final buffer = Buffer(12, 2)
        ..writeString(
          0,
          0,
          'B',
          const Style(
            foreground: Color(255, 255, 255),
            modifiers: Modifier.bold,
          ),
        )
        ..writeString(
          1,
          0,
          'D',
          const Style(
            foreground: Color(255, 255, 255),
            modifiers: Modifier.dim,
          ),
        )
        ..writeString(
          2,
          0,
          'I',
          const Style(
            foreground: Color(255, 255, 255),
            modifiers: Modifier.italic,
          ),
        )
        ..writeString(
          3,
          0,
          '█',
          const Style(
            foreground: Color(255, 128, 0),
            modifiers: Modifier.hidden,
          ),
        )
        ..writeString(
          4,
          0,
          ' ',
          const Style(
            foreground: Color(0, 255, 0),
            modifiers: Modifier.overline,
          ),
        )
        ..writeString(
          5,
          0,
          ' ',
          const Style(
            foreground: Color(0, 0, 255),
            modifiers: Modifier.crossedOut,
          ),
        )
        ..writeString(
          6,
          0,
          ' ',
          const Style(
            foreground: Color(255, 255, 255),
            underlineStyle: UnderlineStyle.single,
            underlineColor: Color(255, 0, 128),
          ),
        )
        ..writeString(
          7,
          0,
          ' ',
          const Style(
            foreground: Color(255, 255, 255),
            underlineStyle: UnderlineStyle.doubleLine,
          ),
        )
        ..writeString(
          8,
          0,
          ' ',
          const Style(
            foreground: Color(255, 255, 255),
            underlineStyle: UnderlineStyle.curly,
            underlineColor: Color(255, 0, 128),
          ),
        )
        ..writeString(
          9,
          0,
          ' ',
          const Style(
            foreground: Color(255, 255, 255),
            underlineStyle: UnderlineStyle.dotted,
          ),
        )
        ..writeString(
          10,
          0,
          ' ',
          const Style(
            foreground: Color(255, 255, 255),
            underlineStyle: UnderlineStyle.dashed,
          ),
        )
        ..writeString(
          11,
          0,
          'A',
          const Style(
            foreground: Color(255, 128, 0),
            underlineStyle: UnderlineStyle.single,
            modifiers:
                Modifier.hidden | Modifier.overline | Modifier.crossedOut,
          ),
        );

      final width = (12 * atlas.cellWidth).ceil();
      final height = (2 * atlas.cellHeight).ceil();
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      final painter = TuiAtlasPainter(
        buffer: buffer,
        atlas: atlas,
        fontFamily: 'Roboto Mono',
        fallbackPainters: const {},
        onMissingGlyphs: null,
      );

      painter.paint(canvas, Size(12 * atlas.cellWidth, 2 * atlas.cellHeight));

      final picture = recorder.endRecording();
      final image = await picture.toImage(width, height);
      picture.dispose();
      addTearDown(image.dispose);

      final bytes = await image.toByteData();
      expect(bytes, isNotNull);
      final data = bytes!.buffer.asUint8List();

      bool hasPixelInCellWithColor(
        int col,
        int targetR,
        int targetG,
        int targetB,
      ) {
        final startX = (col * atlas.cellWidth).floor();
        final endX = ((col + 1) * atlas.cellWidth).ceil().clamp(0, width);
        final endY = atlas.cellHeight.ceil().clamp(0, height);
        for (var y = 0; y < endY; y++) {
          for (var x = startX; x < endX; x++) {
            final idx = (y * width + x) * 4;
            final r = data[idx];
            final g = data[idx + 1];
            final b = data[idx + 2];
            final a = data[idx + 3];
            if (a > 0 && r == targetR && g == targetG && b == targetB) {
              return true;
            }
          }
        }
        return false;
      }

      // Col 3 ('█' with Modifier.hidden) should have zero orange pixels
      expect(
        hasPixelInCellWithColor(3, 255, 128, 0),
        isFalse,
        reason: 'Modifier.hidden must suppress foreground rendering',
      );
      // Col 4 (overline in green) should have green pixels
      expect(
        hasPixelInCellWithColor(4, 0, 255, 0),
        isTrue,
        reason: 'Modifier.overline should render top line in fg color',
      );
      // Col 5 (crossedOut in blue) should have blue pixels
      expect(
        hasPixelInCellWithColor(5, 0, 0, 255),
        isTrue,
        reason: 'Modifier.crossedOut should render strikethrough line',
      );
      // Col 6 (single underline with underlineColor RGB(255, 0, 128))
      expect(
        hasPixelInCellWithColor(6, 255, 0, 128),
        isTrue,
        reason: 'Underline should use custom SGR 58 underlineColor',
      );
      // Col 11 (Modifier.hidden + underline + overline + crossedOut) should have zero orange pixels
      expect(
        hasPixelInCellWithColor(11, 255, 128, 0),
        isFalse,
        reason:
            'Modifier.hidden must suppress underline, overline, and strikethrough decorations',
      );

      // When Col 3 ('█' with Modifier.hidden) is selected via selectionStart/selectionEnd,
      // TuiAtlasPainter highlights the cell and reveals the hidden glyph in white.
      final selectedRecorder = ui.PictureRecorder();
      final selectedCanvas = Canvas(selectedRecorder);
      TuiAtlasPainter(
        buffer: buffer,
        atlas: atlas,
        fontFamily: 'Roboto Mono',
        fallbackPainters: const {},
        onMissingGlyphs: null,
        selectionStart: const math.Point(3, 0),
        selectionEnd: const math.Point(3, 0),
      ).paint(selectedCanvas, Size(12 * atlas.cellWidth, 2 * atlas.cellHeight));
      final selectedPic = selectedRecorder.endRecording();
      final selectedImg = await selectedPic.toImage(width, height);
      selectedPic.dispose();
      addTearDown(selectedImg.dispose);
      final selectedData = (await selectedImg.toByteData())!.buffer
          .asUint8List();

      var foundRevealedWhite = false;
      final startX = (3 * atlas.cellWidth).floor();
      final endX = (4 * atlas.cellWidth).ceil().clamp(0, width);
      final endY = atlas.cellHeight.ceil().clamp(0, height);
      for (var y = 0; y < endY; y++) {
        for (var x = startX; x < endX; x++) {
          final idx = (y * width + x) * 4;
          if (selectedData[idx] == 255 &&
              selectedData[idx + 1] == 255 &&
              selectedData[idx + 2] == 255 &&
              selectedData[idx + 3] > 0) {
            foundRevealedWhite = true;
          }
        }
      }
      expect(
        foundRevealedWhite,
        isTrue,
        reason: 'Selecting a Modifier.hidden cell must reveal its glyph',
      );
    },
  );

  test(
    'TuiAtlasPainter renders KittyImage U+10EEEE placeholders and respects cell occlusion',
    () async {
      final atlas = await GlyphAtlasGenerator.generate(
        fontSize: 16.0,
        fontFamily: 'Roboto Mono',
      );
      addTearDown(() => atlas.image.dispose());

      // Register a 2x1 grid KittyImage: col 0 is pure cyan (0, 255, 255), col 1 is pure magenta (255, 0, 255).
      final rgba = Uint8List.fromList([
        0, 255, 255, 255, // pixel (0,0) -> col 0
        255, 0, 255, 255, // pixel (1,0) -> col 1
      ]);
      const imageId = 0x1234;
      KittyImageRegistry.register(
        KittyImageData(
          imageId: imageId,
          pixelWidth: 2,
          pixelHeight: 1,
          rgbaPixels: rgba,
          gridCols: 2,
          gridRows: 1,
        ),
      );

      final buffer = Buffer(2, 1);
      buffer.setAttributes(
        0,
        0,
        char: kittyPlaceholderCell(0, 0),
        fg: 0xFF000000 | imageId,
        bg: 0xFF000000,
        modifiers: Modifier.kittyPlaceholder,
      );
      // Occlude col 1 with an opaque yellow background cell (simulating a floating TUI window)
      buffer.writeString(
        1,
        0,
        ' ',
        const Style(background: Color(255, 255, 0)),
      );

      final missing = <String>[];
      final painter = TuiAtlasPainter(
        buffer: buffer,
        atlas: atlas,
        fontFamily: 'Roboto Mono',
        fallbackPainters: {},
        onMissingGlyphs: missing.addAll,
      );

      final w = (atlas.cellWidth * 2).ceil();
      final h = atlas.cellHeight.ceil();
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      painter.paint(canvas, Size(w.toDouble(), h.toDouble()));
      final picture = recorder.endRecording();
      final img = await picture.toImage(w, h);
      final bytes = (await img.toByteData(format: ui.ImageByteFormat.rawRgba))!;

      expect(
        missing,
        isEmpty,
        reason:
            'U+10EEEE placeholders should not be reported as missing glyphs',
      );

      bool hasPixelInCell(int col, int targetR, int targetG, int targetB) {
        final int x0 = (col * atlas.cellWidth).floor();
        final int x1 = ((col + 1) * atlas.cellWidth).ceil().clamp(0, w);
        for (var y = 0; y < h; y++) {
          for (var x = x0; x < x1; x++) {
            final idx = (y * w + x) * 4;
            if (bytes.getUint8(idx) == targetR &&
                bytes.getUint8(idx + 1) == targetG &&
                bytes.getUint8(idx + 2) == targetB) {
              return true;
            }
          }
        }
        return false;
      }

      expect(
        hasPixelInCell(0, 0, 255, 255),
        isTrue,
        reason: 'Col 0 should render KittyImage tile (0,0) in cyan',
      );
      expect(
        hasPixelInCell(1, 255, 0, 255),
        isFalse,
        reason: 'Occluded Col 1 should not render KittyImage tile (0,1)',
      );
      expect(
        hasPixelInCell(1, 255, 255, 0),
        isTrue,
        reason:
            'Occluded Col 1 should render the occluding window yellow background',
      );
    },
  );

  test(
    'TuiAtlasPainter underlines hoveredLink by default and applies hoveredLinkStyler overrides',
    () async {
      final atlas = await GlyphAtlasGenerator.generate(
        fontSize: 16.0,
        fontFamily: 'Roboto Mono',
      );
      addTearDown(atlas.image.dispose);

      final plainBuf = Buffer(10, 2)..writeString(0, 0, 'a b', const Style());
      final underlinedBuf = Buffer(10, 2)
        ..writeString(0, 0, 'a b', const Style(modifiers: Modifier.underline));
      const hoveredLink = (
        uri: 'https://example.com',
        startCol: 0,
        startRow: 0,
        endCol: 2,
        endRow: 0,
      );

      Future<Uint8List> paintWith(
        Buffer buf, {
        ResolvedTerminalLink? link,
        HoveredLinkStyler? styler,
      }) async {
        final w = (10 * atlas.cellWidth).ceil();
        final h = (2 * atlas.cellHeight).ceil();
        final rec = ui.PictureRecorder();
        TuiAtlasPainter(
          buffer: buf,
          atlas: atlas,
          fontFamily: 'Roboto Mono',
          fallbackPainters: const {},
          onMissingGlyphs: null,
          hoveredLink: link,
          hoveredLinkStyler: styler,
        ).paint(Canvas(rec), Size(w.toDouble(), h.toDouble()));
        final pic = rec.endRecording();
        final img = await pic.toImage(w, h);
        pic.dispose();
        addTearDown(img.dispose);
        return (await img.toByteData())!.buffer.asUint8List();
      }

      final plainBytes = await paintWith(plainBuf);
      final expectedUnderlinedBytes = await paintWith(underlinedBuf);
      final defaultHoverBytes = await paintWith(plainBuf, link: hoveredLink);

      expect(defaultHoverBytes, isNot(equals(plainBytes)));
      expect(defaultHoverBytes, equals(expectedUnderlinedBytes));

      var callCount = 0;
      final customBytes = await paintWith(
        plainBuf,
        link: hoveredLink,
        styler: (link, cellCount, _, styles) {
          callCount++;
          expect(link, equals(hoveredLink));
          expect(cellCount, equals(3));
          styles.fillBackground(0xFF1B263B);
          styles.fillModifiers(Modifier.underline | Modifier.bold);
          styles.underlineMatchesForeground = true;
          for (var i = 0; i < cellCount; i++) {
            styles.setForeground(i, 0xFF00FF00 + i);
          }
          expect(styles.backgroundAt(1), equals(0xFF1B263B));
          expect(styles.underlineColorAt(2), equals(0xFF00FF02));
          styles.setUnderlineColor(1, 0xFFFF00FF);
          expect(styles.underlineColorAt(1), equals(0xFFFF00FF));
        },
      );
      expect(callCount, equals(1));
      expect(customBytes, isNot(equals(defaultHoverBytes)));

      final defaultPainter = TuiAtlasPainter(
        buffer: plainBuf,
        atlas: atlas,
        fontFamily: 'Roboto Mono',
        fallbackPainters: const {},
        onMissingGlyphs: null,
        hoveredLink: hoveredLink,
      );
      final styledPainter = TuiAtlasPainter(
        buffer: plainBuf,
        atlas: atlas,
        fontFamily: 'Roboto Mono',
        fallbackPainters: const {},
        onMissingGlyphs: null,
        hoveredLink: hoveredLink,
        hoveredLinkStyler: (_, count, _, styles) {
          for (var i = 0; i < count; i++) {
            styles.setForeground(i, 0xFF112233 + i);
          }
        },
      );
      expect(styledPainter.shouldRepaint(defaultPainter), isTrue);
    },
  );

  test(
    'HoveredLinkCellStyles handles setBackground->fillBackground, setModifiers->fillModifiers, and reset(-1)',
    () {
      final styles = HoveredLinkCellStyles()..reset(4);
      styles.setBackground(1, 0xFFAA0000);
      expect(styles.backgroundAt(1), equals(0xFFAA0000));
      styles.fillBackground(0xFF00BBCC);
      expect(styles.backgroundAt(0), equals(0xFF00BBCC));
      expect(styles.backgroundAt(1), equals(0xFF00BBCC));
      expect(styles.backgroundAt(3), equals(0xFF00BBCC));

      styles.setModifiers(2, Modifier.bold);
      expect(styles.modifiersAt(2), equals(Modifier.bold));
      styles.fillModifiers(Modifier.underline);
      expect(styles.modifiersAt(0), equals(Modifier.underline));
      expect(styles.modifiersAt(2), equals(Modifier.underline));

      styles.reset(-1);
      expect(styles.length, equals(0));
      expect(styles.backgroundAt(0), isNull);
      expect(styles.modifiersAt(0), isNull);
    },
  );

  test(
    'TuiAtlasPainter renders fallback unbaked glyph inside hoveredLink with styler fgArgb, handles throwing styler, and clips off-top links',
    () async {
      final atlas = await GlyphAtlasGenerator.generate(
        fontSize: 16.0,
        fontFamily: 'Roboto Mono',
      );
      addTearDown(atlas.image.dispose);

      Future<Uint8List> paintWith(
        Buffer buf, {
        ResolvedTerminalLink? link,
        HoveredLinkStyler? styler,
      }) async {
        final w = (buf.width * atlas.cellWidth).ceil();
        final h = (buf.height * atlas.cellHeight).ceil();
        final rec = ui.PictureRecorder();
        TuiAtlasPainter(
          buffer: buf,
          atlas: atlas,
          fontFamily: 'Roboto Mono',
          fallbackPainters: const {},
          onMissingGlyphs: null,
          hoveredLink: link,
          hoveredLinkStyler: styler,
        ).paint(Canvas(rec), Size(w.toDouble(), h.toDouble()));
        final pic = rec.endRecording();
        final img = await pic.toImage(w, h);
        pic.dispose();
        addTearDown(img.dispose);
        return (await img.toByteData())!.buffer.asUint8List();
      }

      // 1. Unbaked fallback glyph (\u4E2D) receives overridden foreground color.
      final fallbackBuf = Buffer(6, 2)
        ..writeString(0, 0, '\u4E2D', const Style());
      const fallbackLink = (
        uri: 'https://example.com/cjk',
        startCol: 0,
        startRow: 0,
        endCol: 0,
        endRow: 0,
      );
      final expectedRedFallbackBuf = Buffer(6, 2)
        ..writeString(
          0,
          0,
          '\u4E2D',
          const Style(
            foreground: Color(255, 0, 0),
            modifiers: Modifier.underline,
          ),
        );
      final expectedFallbackBytes = await paintWith(expectedRedFallbackBuf);
      final hoveredFallbackBytes = await paintWith(
        fallbackBuf,
        link: fallbackLink,
        styler: (_, _, _, styles) {
          styles.setForeground(0, 0xFFFF0000);
        },
      );
      expect(hoveredFallbackBytes, equals(expectedFallbackBytes));

      // 2. Throwing hoveredLinkStyler reports error and falls back cleanly to default underline.
      final plainBuf = Buffer(10, 2)..writeString(0, 0, 'abc', const Style());
      const plainLink = (
        uri: 'https://example.com/abc',
        startCol: 0,
        startRow: 0,
        endCol: 2,
        endRow: 0,
      );
      final defaultHoverBytes = await paintWith(plainBuf, link: plainLink);
      final reportedErrors = <FlutterErrorDetails>[];
      final previousOnError = FlutterError.onError;
      FlutterError.onError = reportedErrors.add;
      try {
        final fallbackOnThrowBytes = await paintWith(
          plainBuf,
          link: plainLink,
          styler: (_, _, _, styles) {
            styles.setForeground(0, 0xFF00FF00);
            throw StateError('boom');
          },
        );
        expect(reportedErrors, hasLength(1));
        expect(fallbackOnThrowBytes, equals(defaultHoverBytes));
      } finally {
        FlutterError.onError = previousOnError;
      }

      // 3. Off-top clipped link (startRow: -1, endRow: 0) styles visible row 0 cells cleanly.
      const clippedLink = (
        uri: 'https://example.com/wrapped',
        startCol: 5,
        startRow: -1,
        endCol: 2,
        endRow: 0,
      );
      int? observedCount;
      final clippedBytes = await paintWith(
        plainBuf,
        link: clippedLink,
        styler: (_, count, _, styles) {
          observedCount = count;
          styles.fillBackground(0xFF224466);
        },
      );
      expect(observedCount, equals(3));
      final expectedClippedBuf = Buffer(10, 2)
        ..writeString(
          0,
          0,
          'abc',
          const Style(
            background: Color(0x22, 0x44, 0x66),
            modifiers: Modifier.underline,
          ),
        );
      expect(clippedBytes, equals(await paintWith(expectedClippedBuf)));
    },
  );

  _defineThemePalettePainterTests();
}

void _defineThemePalettePainterTests() {
  group('Theme palette, default colors, faintOpacity, and live updates', () {
    test(
      'resolveCellForegroundArgb & resolveCellBackgroundArgb honor theme, reverse, and faintOpacity',
      _testResolveCellColors,
    );
    test(
      'TuiAtlasPainter renders custom defaultBg, SGR 58;5;n underline, and fallback CJK faintOpacity',
      _testUnderlineAndFallbackPaint,
    );
    testWidgets(
      'PrivateTuiView updates fallbackPainters & TuiAtlasPainter when theme changes',
      _testLiveThemeUpdate,
    );
    test(
      'GlyphAtlas.hasNativeVariant and rectFor resolve all four style variants and fall back cleanly',
      _testAtlasHasNativeVariantAndRectFor,
    );
    testWidgets(
      'TuiAtlasPainter compares delegate fields in shouldRepaint and repaints via repaint Listenable',
      _testShouldRepaintAndListenable,
    );
    test(
      'TuiAtlasPainter resets _kittyPaint.color before drawImageRect after translucent subpixel paint',
      _testKittyPaintColorResetAfterSubpixels,
    );
    test(
      'TuiAtlasPainter enableBleed masks neighbor bleed over default-background edges',
      _testEnableBleedCoversAdjacentBackgroundEdges,
    );
  });
}

void _testResolveCellColors() {
  const theme = TerminalColorTheme.solarizedLight;
  final defBg = theme.background.argb;
  final defFg = theme.foreground.argb;

  expect(
    TuiAtlasPainter.resolveCellBackgroundArgb(
      0,
      0,
      isReverse: false,
      defaultForegroundArgb: defFg,
      defaultBackgroundArgb: defBg,
      palette: theme,
    ),
    equals(defBg),
  );
  expect(
    TuiAtlasPainter.resolveCellForegroundArgb(
      const Color.ansi(4).argb,
      0,
      modifiers: Modifier.none,
      isReverse: false,
      defaultForegroundArgb: defFg,
      defaultBackgroundArgb: defBg,
      faintOpacity: 0.75,
      palette: theme,
    ),
    equals(theme.ansi[4].argb),
  );

  final revBg = TuiAtlasPainter.resolveCellBackgroundArgb(
    0,
    const Color.ansi(1).argb,
    isReverse: true,
    defaultForegroundArgb: defFg,
    defaultBackgroundArgb: defBg,
    palette: theme,
  );
  expect(revBg, equals(theme.ansi[1].argb));

  final dimFg = TuiAtlasPainter.resolveCellForegroundArgb(
    const Color.ansi(4).argb,
    0,
    modifiers: Modifier.dim,
    isReverse: false,
    defaultForegroundArgb: defFg,
    defaultBackgroundArgb: defBg,
    faintOpacity: 0.75,
    palette: theme,
  );
  expect((dimFg >> 24) & 0xFF, equals((255 * 0.75).round()));
  expect(dimFg & 0x00FFFFFF, equals(theme.ansi[4].argb & 0x00FFFFFF));
}

int _countMatchingRgbPixels(
  ByteData bytes,
  int strideWidth, {
  required int x0,
  required int x1,
  required int y0,
  required int y1,
  required Color target,
}) {
  var matches = 0;
  for (var y = y0; y < y1; y++) {
    for (var x = x0; x < x1; x++) {
      final idx = (y * strideWidth + x) * 4;
      if (bytes.getUint8(idx) == target.r &&
          bytes.getUint8(idx + 1) == target.g &&
          bytes.getUint8(idx + 2) == target.b) {
        matches++;
      }
    }
  }
  return matches;
}

Future<void> _testUnderlineAndFallbackPaint() async {
  final atlas = await GlyphAtlasGenerator.generateEmpty(
    fontSize: 13.0,
    fontFamily: 'Roboto Mono',
  );
  addTearDown(() => atlas.image.dispose());

  const theme = TerminalColorTheme.solarizedLight;
  final buffer = Buffer(4, 2)
    ..writeString(
      0,
      0,
      'A',
      const Style(
        foreground: Color.ansi(4),
        underlineColor: Color.ansi(1),
        modifiers: Modifier.underline,
      ),
    )
    ..writeString(
      2,
      0,
      '漢',
      const Style(foreground: Color.ansi(2), modifiers: Modifier.dim),
    );

  final fallbackColor = ui.Color(
    ((255 * 0.75).round() << 24) | (theme.ansi[2].argb & 0x00FFFFFF),
  );
  final fallbackKey = ('漢', false, false, true, fallbackColor);
  final fallbackTp = TextPainter(
    text: TextSpan(
      text: '漢',
      style: TextStyle(fontSize: 13.0, color: fallbackColor),
    ),
    textDirection: TextDirection.ltr,
  )..layout();
  addTearDown(fallbackTp.dispose);

  final w = (4 * atlas.cellWidth).ceil();
  final h = (2 * atlas.cellHeight).ceil();
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  TuiAtlasPainter(
    buffer: buffer,
    atlas: atlas,
    fontFamily: 'Roboto Mono',
    fallbackPainters: {fallbackKey: fallbackTp},
    onMissingGlyphs: null,
    defaultForegroundArgb: theme.foreground.argb,
    defaultBackgroundArgb: theme.background.argb,
    faintOpacity: 0.75,
    palette: theme,
  ).paint(canvas, Size(w.toDouble(), h.toDouble()));

  final picture = recorder.endRecording();
  final image = await picture.toImage(w, h);
  addTearDown(() {
    picture.dispose();
    image.dispose();
  });
  final byteData = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
  expect(byteData, isNotNull);
  final bytes = byteData!;

  // Empty Col 1 uses theme.background (#FDF6E3).
  final sampleX = (1.5 * atlas.cellWidth).floor();
  final sampleY = (0.5 * atlas.cellHeight).floor();
  final bgIdx = (sampleY * w + sampleX) * 4;
  expect(bytes.getUint8(bgIdx), equals(0xFD));
  expect(bytes.getUint8(bgIdx + 1), equals(0xF6));
  expect(bytes.getUint8(bgIdx + 2), equals(0xE3));

  // Col 0 underline uses resolved theme.ansi[1] (#DC322F).
  final matchingUnderlinePixels = _countMatchingRgbPixels(
    bytes,
    w,
    x0: 0,
    x1: atlas.cellWidth.ceil().clamp(0, w),
    y0: (atlas.cellHeight * 0.75).floor(),
    y1: atlas.cellHeight.ceil().clamp(0, h),
    target: theme.ansi[1],
  );
  expect(matchingUnderlinePixels, greaterThan(0));
}

Future<void> _pumpUntilReady(
  WidgetTester tester,
  bool Function() isReady,
) async {
  for (var i = 0; i < 40 && !isReady(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
    await tester.pump();
  }
}

Matcher _matchesFallbackKey(String glyph, int expectedArgb) =>
    predicate<(String, bool, bool, bool, ui.Color)>(
      (k) => k.$1 == glyph && k.$4 && k.$5.toARGB32() == expectedArgb,
      'fallback painter for "$glyph" with ARGB $expectedArgb',
    );

Matcher _matchesLigatureKey(String ligature, int expectedArgb) =>
    predicate<(String, bool, bool, ui.Color)>(
      (k) => k.$1 == ligature && k.$4.toARGB32() == expectedArgb,
      'ligature painter for "$ligature" with ARGB $expectedArgb',
    );

Future<void> _testLiveThemeUpdate(WidgetTester tester) async {
  final terminal = FlutterTerminal(
    initialFontSize: 13.0,
    enableLigatures: true,
  );
  addTearDown(terminal.dispose);
  void Function(Buffer)? drawFrame;

  Widget buildWithTheme(TerminalColorTheme theme, double faintOpacity) {
    return WidgetsApp(
      color: const ui.Color(0xFF000000),
      pageRouteBuilder: <T>(settings, builder) => PageRouteBuilder<T>(
        settings: settings,
        pageBuilder: (context, _, _) => builder(context),
      ),
      home: SizedBox(
        width: 320,
        height: 200,
        child: Terminal(
          terminal: terminal,
          enableLigatures: true,
          backgroundColor: ui.Color(theme.background.argb),
          foregroundColor: ui.Color(theme.foreground.argb),
          faintOpacity: faintOpacity,
          palette: theme,
          onRun: (_, onDraw) async {
            drawFrame = onDraw;
          },
        ),
      ),
    );
  }

  await tester.runAsync(() async {
    await tester.pumpWidget(
      buildWithTheme(TerminalColorTheme.termuiDark, 0.55),
    );
    final state = tester.state<PrivateTuiViewState>(
      find.byType(PrivateTuiView),
    );
    await _pumpUntilReady(
      tester,
      () => state.debugAtlas != null && drawFrame != null,
    );
    expect(state.debugAtlas, isNotNull);
    expect(drawFrame, isNotNull);

    final buf = Buffer(16, 2)
      ..writeString(0, 0, 'Ж', const Style(modifiers: Modifier.dim))
      ..writeString(2, 0, '<!--', const Style(modifiers: Modifier.dim));
    drawFrame!(buf);
    await Future<void>.microtask(() {});

    final expectedDarkColor =
        ((255 * 0.55).round() << 24) |
        (TerminalColorTheme.termuiDark.foreground.argb & 0x00FFFFFF);
    expect(
      state.debugFallbackPainterKeys,
      contains(_matchesFallbackKey('Ж', expectedDarkColor)),
    );
    await tester.pump();

    CustomPaint paintWidget() => tester.widget<CustomPaint>(
      find.descendant(
        of: find.byType(PrivateTuiView),
        matching: find.byType(CustomPaint),
      ),
    );

    final darkPainter = paintWidget().painter! as TuiAtlasPainter;
    expect(darkPainter.palette.id, equals(TerminalColorTheme.termuiDark.id));
    expect(
      darkPainter.ligaturePainters.keys,
      contains(_matchesLigatureKey('<!--', expectedDarkColor)),
    );

    await tester.pumpWidget(
      buildWithTheme(TerminalColorTheme.solarizedLight, 0.8),
    );
    await tester.pump();

    final lightPainter = paintWidget().painter! as TuiAtlasPainter;
    expect(
      lightPainter.palette.id,
      equals(TerminalColorTheme.solarizedLight.id),
    );
    expect(
      lightPainter.defaultBackgroundArgb,
      equals(TerminalColorTheme.solarizedLight.background.argb),
    );
    expect(lightPainter.faintOpacity, equals(0.8));
    final expectedLightColor =
        ((255 * 0.8).round() << 24) |
        (TerminalColorTheme.solarizedLight.foreground.argb & 0x00FFFFFF);
    expect(
      lightPainter.ligaturePainters.keys,
      contains(_matchesLigatureKey('<!--', expectedLightColor)),
    );
    expect(
      lightPainter.ligaturePainters.keys,
      isNot(
        contains(
          predicate<(String, bool, bool, ui.Color)>(
            (k) => k.$4.toARGB32() == expectedDarkColor,
            'ligature painter retaining previous dark theme color',
          ),
        ),
      ),
    );
    expect(lightPainter.shouldRepaint(darkPainter), isTrue);
  });
}

Future<void> _testAtlasHasNativeVariantAndRectFor() async {
  final atlas = await GlyphAtlasGenerator.generate(
    fontSize: 14.0,
    fontFamily: 'Roboto Mono',
  );
  addTearDown(atlas.image.dispose);

  // 'A' is prebaked across all 4 variants.
  for (final variant in GlyphStyleVariant.values) {
    expect(atlas.hasNativeVariant('A', variant), isTrue);
    final rect = atlas.rectFor(
      'A',
      isBold: variant.isBold,
      isItalic: variant.isItalic,
    );
    expect(rect, isNotNull);
    expect(rect, equals(atlas.styledCharRects[('A', variant)]));
  }

  // '─' (0x2500) is procedural and aliased across all 4 variants.
  for (final variant in GlyphStyleVariant.values) {
    expect(atlas.hasNativeVariant('─', variant), isTrue);
    expect(
      atlas.rectFor('─', isBold: variant.isBold, isItalic: variant.isItalic),
      equals(atlas.rectFor('─')),
    );
  }
  // '╭' (0x256D) is prebaked only for regular, not bold/italic/boldItalic.
  expect(atlas.hasNativeVariant('╭', GlyphStyleVariant.regular), isTrue);
  expect(atlas.hasNativeVariant('╭', GlyphStyleVariant.bold), isFalse);
  expect(atlas.hasNativeVariant('╭', GlyphStyleVariant.italic), isFalse);
  expect(atlas.hasNativeVariant('╭', GlyphStyleVariant.boldItalic), isFalse);
  expect(atlas.rectFor('╭', isBold: true), equals(atlas.rectFor('╭')));
  expect(atlas.rectFor('╭', isItalic: true), equals(atlas.rectFor('╭')));
  expect(atlas.hasNativeVariant('Ж', GlyphStyleVariant.regular), isFalse);
  expect(atlas.rectFor('Ж'), isNull);
}

Future<void> _testShouldRepaintAndListenable(WidgetTester tester) async {
  final atlas = await tester.runAsync(
    () => GlyphAtlasGenerator.generateEmpty(
      fontSize: 13.0,
      fontFamily: 'Roboto Mono',
    ),
  );
  addTearDown(atlas!.image.dispose);

  final bufA = Buffer(4, 2)..writeString(0, 0, 'Hi', Style.empty);
  final bufB = Buffer(4, 2)..writeString(0, 0, 'Yo', Style.empty);
  final repaintA = ValueNotifier<int>(0);
  final repaintB = ValueNotifier<int>(0);
  addTearDown(repaintA.dispose);
  addTearDown(repaintB.dispose);

  TuiAtlasPainter makePainter({
    Buffer? buffer,
    Listenable? repaint,
    int defaultFg = 0xFFFFFFFF,
    int? activePtyCols,
    String composing = '',
    int cursorCol = 0,
    void Function(List<String>)? onMissing,
  }) => TuiAtlasPainter(
    repaint: repaint,
    buffer: buffer ?? bufA,
    atlas: atlas,
    fontFamily: 'Roboto Mono',
    fallbackPainters: const {},
    onMissingGlyphs: onMissing,
    defaultForegroundArgb: defaultFg,
    activePtyCols: activePtyCols,
    composingText: composing,
    cursorCol: cursorCol,
  );

  final base = makePainter(repaint: repaintA);
  expect(
    makePainter(repaint: null).shouldRepaint(makePainter(repaint: null)),
    isTrue,
  );
  expect(base.shouldRepaint(makePainter(repaint: repaintA)), isFalse);
  expect(
    base.shouldRepaint(makePainter(buffer: bufB, repaint: repaintA)),
    isTrue,
  );
  expect(base.shouldRepaint(makePainter(repaint: repaintB)), isTrue);
  expect(
    base.shouldRepaint(makePainter(repaint: repaintA, defaultFg: 0xFF00FF00)),
    isTrue,
  );
  expect(
    base.shouldRepaint(makePainter(repaint: repaintA, activePtyCols: 2)),
    isTrue,
  );
  expect(
    base.shouldRepaint(makePainter(repaint: repaintA, composing: 'a')),
    isTrue,
  );
  expect(
    base.shouldRepaint(makePainter(repaint: repaintA, cursorCol: 1)),
    isTrue,
  );
  expect(
    base.shouldRepaint(makePainter(repaint: repaintA, onMissing: (_) {})),
    isTrue,
  );

  var missingCallbacks = 0;
  final missingBuf = Buffer(4, 2)..writeString(0, 0, 'Ж', Style.empty);
  final countingPainter = makePainter(
    buffer: missingBuf,
    repaint: repaintA,
    onMissing: (_) => missingCallbacks++,
  );
  await tester.pumpWidget(
    Directionality(
      textDirection: TextDirection.ltr,
      child: CustomPaint(
        size: Size(4 * atlas.cellWidth, 2 * atlas.cellHeight),
        painter: countingPainter,
      ),
    ),
  );
  await tester.pump();
  expect(missingCallbacks, equals(1));

  final renderPaint = tester.renderObject<RenderCustomPaint>(
    find.byType(CustomPaint),
  );
  expect(renderPaint.debugNeedsPaint, isFalse);

  repaintA.value++;
  expect(renderPaint.debugNeedsPaint, isTrue);
  await tester.pump();
  await tester.pump();
  expect(renderPaint.debugNeedsPaint, isFalse);
  expect(missingCallbacks, equals(2));
}

Future<void> _testKittyPaintColorResetAfterSubpixels() async {
  final atlas = await GlyphAtlasGenerator.generateEmpty(
    fontSize: 16.0,
    fontFamily: 'Roboto Mono',
  );
  addTearDown(atlas.image.dispose);

  const imageId = 0x5678;
  final translucentRgba = Uint8List.fromList([255, 0, 0, 64]);
  final kittyData = KittyImageData(
    imageId: imageId,
    pixelWidth: 1,
    pixelHeight: 1,
    rgbaPixels: translucentRgba,
    gridCols: 1,
    gridRows: 1,
  );
  final registry = KittyImageRegistry()..registerImage(kittyData);
  final buffer = Buffer(1, 1)
    ..registerKittyRegistry(const tui_geo.Rect(0, 0, 1, 1), registry)
    ..setAttributes(
      0,
      0,
      char: kittyPlaceholderCell(0, 0),
      fg: 0xFF000000 | imageId,
      bg: 0xFF000000,
      modifiers: Modifier.kittyPlaceholder,
    );

  final kittyImages = <KittyImageData, ui.Image>{};
  final painter = TuiAtlasPainter(
    buffer: buffer,
    atlas: atlas,
    fontFamily: 'Roboto Mono',
    fallbackPainters: const {},
    onMissingGlyphs: null,
    kittyImages: kittyImages,
  );

  final w = atlas.cellWidth.ceil();
  final h = atlas.cellHeight.ceil();

  // Frame 1: undecoded translucent Kitty subpixel sets _kittyPaint.color alpha < 255.
  final rec1 = ui.PictureRecorder();
  painter.paint(Canvas(rec1), Size(w.toDouble(), h.toDouble()));
  rec1.endRecording().dispose();

  // Frame 2: same painter instance now has a decoded opaque GPU image in kittyImages.
  final decodedCompleter = Completer<ui.Image>();
  ui.decodeImageFromPixels(
    Uint8List.fromList([0, 255, 0, 255]),
    1,
    1,
    ui.PixelFormat.rgba8888,
    decodedCompleter.complete,
  );
  final gpuImage = await decodedCompleter.future;
  addTearDown(gpuImage.dispose);
  kittyImages[kittyData] = gpuImage;

  final rec2 = ui.PictureRecorder();
  painter.paint(Canvas(rec2), Size(w.toDouble(), h.toDouble()));
  final pic2 = rec2.endRecording();
  final rendered = await pic2.toImage(w, h);
  pic2.dispose();
  addTearDown(rendered.dispose);

  final bytes = (await rendered.toByteData())!.buffer.asUint8List();
  final centerOffset = ((h ~/ 2) * w + (w ~/ 2)) * 4;
  expect(bytes[centerOffset + 1], equals(255));
  expect(bytes[centerOffset + 3], equals(255));
}

Future<void> _testEnableBleedCoversAdjacentBackgroundEdges() async {
  final atlas = await GlyphAtlasGenerator.generateEmpty(
    fontSize: 16.0,
    fontFamily: 'Roboto Mono',
  );
  addTearDown(atlas.image.dispose);

  const defaultBg = 0xFF000000;
  const redBg = 0xFFFF0000;
  final buffer = Buffer(3, 3)
    ..setAttributes(1, 0, char: ' ', fg: 0xFFFFFFFF, bg: redBg);

  final painter = TuiAtlasPainter(
    buffer: buffer,
    atlas: atlas,
    fontFamily: 'Roboto Mono',
    fallbackPainters: const {},
    onMissingGlyphs: null,
    enableBleed: true,
    defaultBackgroundArgb: defaultBg,
  );

  final cellW = atlas.cellWidth;
  final cellH = atlas.cellHeight;
  final imgW = (3 * cellW).ceil();
  final imgH = (3 * cellH).ceil();
  final rec = ui.PictureRecorder();
  painter.paint(Canvas(rec), Size(imgW.toDouble(), imgH.toDouble()));
  final pic = rec.endRecording();
  final rendered = await pic.toImage(imgW, imgH);
  pic.dispose();
  addTearDown(rendered.dispose);

  final bytes = (await rendered.toByteData())!.buffer.asUint8List();
  (int, int, int, int) pixelAt(int px, int py) {
    final offset = (py * imgW + px) * 4;
    return (
      bytes[offset],
      bytes[offset + 1],
      bytes[offset + 2],
      bytes[offset + 3],
    );
  }

  expect(
    pixelAt((cellW * 1.5).floor(), (cellH * 0.5).floor()),
    equals((255, 0, 0, 255)),
  );

  final rightEdgeX = (2 * cellW).floor();
  final bottomEdgeY = cellH.floor();
  final leftCornerX = cellW.floor() - 1;
  expect(pixelAt(rightEdgeX, (cellH * 0.5).floor()), equals((0, 0, 0, 255)));
  expect(
    pixelAt((cellW * 2.5).floor(), (cellH * 0.5).floor()),
    equals((0, 0, 0, 255)),
  );
  expect(pixelAt((cellW * 1.5).floor(), bottomEdgeY), equals((0, 0, 0, 255)));
  expect(
    pixelAt((cellW * 1.5).floor(), (cellH * 1.5).floor()),
    equals((0, 0, 0, 255)),
  );
  expect(pixelAt(rightEdgeX, bottomEdgeY), equals((0, 0, 0, 255)));
  expect(pixelAt(leftCornerX, bottomEdgeY), equals((0, 0, 0, 255)));

  final transRec = ui.PictureRecorder();
  TuiAtlasPainter(
    buffer: buffer,
    atlas: atlas,
    fontFamily: 'Roboto Mono',
    fallbackPainters: const {},
    onMissingGlyphs: null,
    enableBleed: true,
    defaultBackgroundArgb: 0x80102030,
  ).paint(Canvas(transRec), Size(imgW.toDouble(), imgH.toDouble()));
  final transPic = transRec.endRecording();
  final transImg = await transPic.toImage(imgW, imgH);
  transPic.dispose();
  addTearDown(transImg.dispose);
  final transBytes = (await transImg.toByteData())!.buffer.asUint8List();
  final adjOff = ((cellH * 1.5).floor() * imgW + (cellW * 1.5).floor()) * 4;
  final baseOff = ((cellH * 0.5).floor() * imgW + (cellW * 2.5).floor()) * 4;
  expect(
    transBytes.sublist(adjOff, adjOff + 4),
    equals(transBytes.sublist(baseOff, baseOff + 4)),
  );
}
