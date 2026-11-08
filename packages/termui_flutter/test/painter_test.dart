import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/rendering.dart' hide Color;
import 'package:flutter_test/flutter_test.dart';
import 'package:termui/ui/buffer.dart';
import 'package:termui/ui/color.dart';
import 'package:termui/ui/style.dart';
import 'package:termui/ui/widgets/display/kitty_image.dart';
// ignore: implementation_imports
import 'package:termui_flutter/src/rendering/atlas.dart';
// ignore: implementation_imports
import 'package:termui_flutter/src/rendering/painter.dart';

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
}
