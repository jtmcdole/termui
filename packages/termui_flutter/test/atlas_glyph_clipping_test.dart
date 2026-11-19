import 'dart:io';
import 'dart:ui' as ui;

import 'package:characters/characters.dart';
import 'package:flutter/painting.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:termui/ui/buffer.dart';
import 'package:termui/ui/color.dart' as tui_color;
import 'package:termui/ui/style.dart';
import 'package:termui/ui/terminal_palette.dart';
// ignore: implementation_imports
import 'package:termui_flutter/src/rendering/atlas.dart'
    show isProceduralAtlasCharacter;
// ignore: implementation_imports
import 'package:termui_flutter/src/rendering/painter.dart';
import 'package:termui_flutter/termui_flutter.dart';

const String _primaryFont = 'Cascadia Mono';
const List<String> _fallbackFonts = <String>['MesloLGS NF'];

Future<void>? _bundledFontsLoaded;

Future<File> _resolveFontFile(String fileName) async {
  const candidates = <String>[
    'example/fonts',
    'packages/termui_flutter/example/fonts',
  ];
  for (final dir in candidates) {
    final file = File('$dir/$fileName');
    if (await file.exists()) return file;
  }
  throw StateError('Unable to locate bundled test font: $fileName');
}

Future<void> _loadSingleFont(String family, String fileName) async {
  final file = await _resolveFontFile(fileName);
  final bytes = await file.readAsBytes();
  final byteData = ByteData.sublistView(bytes);
  final loader = FontLoader(family)..addFont(Future<ByteData>.value(byteData));
  await loader.load();
}

Future<void> _ensureBundledFontsLoaded() => _bundledFontsLoaded ??= [
  _loadSingleFont(_primaryFont, 'CascadiaMonoPL.ttf'),
  _loadSingleFont('MesloLGS NF', 'MesloLGS_NF_Regular.ttf'),
].wait.then((_) {});

Future<({Uint8List rgba, int width, int height})> _readImageRgba(
  ui.Image image,
) async {
  final byteData = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
  return (
    rgba: byteData!.buffer.asUint8List(),
    width: image.width,
    height: image.height,
  );
}

Buffer _bufferFromLines(List<String> lines, {Style style = Style.empty}) {
  final rows = lines.map((l) => l.characters.toList(growable: false)).toList();
  final width = rows.fold<int>(0, (m, r) => r.length > m ? r.length : m);
  final buf = Buffer(width, rows.length);
  for (var y = 0; y < rows.length; y++) {
    for (var x = 0; x < rows[y].length; x++) {
      buf.setCell(
        x,
        y,
        rows[y][x],
        style.foreground?.argb ?? 0,
        style.background?.argb ?? 0,
        style.modifiers,
      );
    }
  }
  return buf;
}

Future<ui.Image> _paintBufferToImage({
  required Buffer buffer,
  required GlyphAtlas atlas,
  Map<(String, bool, bool, bool, Color), TextPainter>? fallbackPainters,
  double devicePixelRatio = 1.0,
  bool enableBleed = false,
  int bgArgb = 0xFF141414,
  int fgArgb = 0xFFE6E6E6,
  TerminalColorTheme palette = TerminalColorTheme.termuiDark,
}) async {
  final logicalW = buffer.width * atlas.cellWidth;
  final logicalH = buffer.height * atlas.cellHeight;
  final physW = (logicalW * devicePixelRatio).ceil();
  final physH = (logicalH * devicePixelRatio).ceil();

  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder)..scale(devicePixelRatio);
  TuiAtlasPainter(
    buffer: buffer,
    atlas: atlas,
    fontFamily: _primaryFont,
    fontFamilyFallback: _fallbackFonts,
    fallbackPainters: fallbackPainters ?? {},
    onMissingGlyphs: null,
    enableBleed: enableBleed,
    defaultBackgroundArgb: bgArgb,
    defaultForegroundArgb: fgArgb,
    palette: palette,
  ).paint(canvas, Size(logicalW, logicalH));

  final picture = recorder.endRecording();
  try {
    return await picture.toImage(physW, physH);
  } finally {
    picture.dispose();
  }
}

Future<({Uint8List rgba, int width, int height})> _paintBufferToRgba({
  required Buffer buffer,
  required GlyphAtlas atlas,
  Map<(String, bool, bool, bool, Color), TextPainter>? fallbackPainters,
  double devicePixelRatio = 1.0,
  bool enableBleed = false,
  int bgArgb = 0xFF141414,
  int fgArgb = 0xFFE6E6E6,
}) async {
  final image = await _paintBufferToImage(
    buffer: buffer,
    atlas: atlas,
    fallbackPainters: fallbackPainters,
    devicePixelRatio: devicePixelRatio,
    enableBleed: enableBleed,
    bgArgb: bgArgb,
    fgArgb: fgArgb,
  );
  try {
    return await _readImageRgba(image);
  } finally {
    image.dispose();
  }
}

/// Measures the maximum alpha (`0..255`) inside the slot moat ring:
/// `[sourceRect.inflate(slotPadPx)] \ [sourceRect.inflate(overhangPx)]`.
/// Also returns the maximum alpha inside [sourceRect] so tests confirm the glyph
/// actually rasterized visible ink.
({int maxMoatAlpha, int maxInsideAlpha}) _measureSlotMoatAlpha({
  required Uint8List atlasRgba,
  required int atlasWidth,
  required int atlasHeight,
  required Rect sourceRect,
  required int slotPadPx,
  required int overhangPx,
}) {
  final sx0 = (sourceRect.left.round() - slotPadPx).clamp(0, atlasWidth);
  final sy0 = (sourceRect.top.round() - slotPadPx).clamp(0, atlasHeight);
  final sx1 = (sourceRect.right.round() + slotPadPx).clamp(0, atlasWidth);
  final sy1 = (sourceRect.bottom.round() + slotPadPx).clamp(0, atlasHeight);

  final ox0 = sourceRect.left.round() - overhangPx;
  final oy0 = sourceRect.top.round() - overhangPx;
  final ox1 = sourceRect.right.round() + overhangPx;
  final oy1 = sourceRect.bottom.round() + overhangPx;

  final rx0 = sourceRect.left.round();
  final ry0 = sourceRect.top.round();
  final rx1 = sourceRect.right.round();
  final ry1 = sourceRect.bottom.round();

  var maxMoatAlpha = 0;
  var maxInsideAlpha = 0;

  for (var y = sy0; y < sy1; y++) {
    for (var x = sx0; x < sx1; x++) {
      final a = atlasRgba[(y * atlasWidth + x) * 4 + 3];
      if (x >= rx0 && x < rx1 && y >= ry0 && y < ry1) {
        if (a > maxInsideAlpha) maxInsideAlpha = a;
        continue;
      }
      if (x >= ox0 && x < ox1 && y >= oy0 && y < oy1) continue;
      if (a > maxMoatAlpha) maxMoatAlpha = a;
    }
  }

  return (maxMoatAlpha: maxMoatAlpha, maxInsideAlpha: maxInsideAlpha);
}

({int minX, int maxX, int minY, int maxY, int count}) _measureInkBounds(
  ({Uint8List rgba, int width, int height}) img, {
  required int x0,
  required int x1,
  required int y0,
  required int y1,
  int bgR = 0x14,
  int bgG = 0x14,
  int bgB = 0x14,
  int threshold = 16,
}) {
  var minX = x1;
  var maxX = -1;
  var minY = y1;
  var maxY = -1;
  var count = 0;
  final cx0 = x0.clamp(0, img.width);
  final cx1 = x1.clamp(0, img.width);
  final cy0 = y0.clamp(0, img.height);
  final cy1 = y1.clamp(0, img.height);

  for (var y = cy0; y < cy1; y++) {
    for (var x = cx0; x < cx1; x++) {
      final off = (y * img.width + x) * 4;
      final dr = (img.rgba[off] - bgR).abs();
      final dg = (img.rgba[off + 1] - bgG).abs();
      final db = (img.rgba[off + 2] - bgB).abs();
      final delta = dr > dg ? (dr > db ? dr : db) : (dg > db ? dg : db);
      if (delta > threshold) {
        count++;
        if (x < minX) minX = x;
        if (x > maxX) maxX = x;
        if (y < minY) minY = y;
        if (y > maxY) maxY = y;
      }
    }
  }
  return (minX: minX, maxX: maxX, minY: minY, maxY: maxY, count: count);
}

int _maxPixelChannelDiff(Uint8List a, Uint8List b) {
  expect(a.length, equals(b.length));
  var maxDiff = 0;
  for (var i = 0; i < a.length; i++) {
    final d = (a[i] - b[i]).abs();
    if (d > maxDiff) maxDiff = d;
  }
  return maxDiff;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await _ensureBundledFontsLoaded();
  });

  group('Selective Option A Stage 1 invariants', () {
    test('isProceduralAtlasCharacter matches exact procedural code points', () {
      const expectedProcedural = <int>[
        0x2580,
        0x2584,
        0x2588,
        0x2589,
        0x258A,
        0x258B,
        0x258C,
        0x258D,
        0x258E,
        0x258F,
        0x2590,
        0x2591,
        0x2592,
        0x2593,
        0x2500,
        0x2502,
        0x250C,
        0x2510,
        0x2514,
        0x2518,
        0x251C,
        0x2524,
        0x252C,
        0x2534,
        0x253C,
        0x2550,
        0x2551,
        0x2554,
        0x2557,
        0x255A,
        0x255D,
      ];
      final expectedSet = expectedProcedural.toSet();
      for (var cp = 0x2500; cp <= 0x259F; cp++) {
        final ch = String.fromCharCode(cp);
        expect(
          isProceduralAtlasCharacter(ch),
          equals(expectedSet.contains(cp)),
          reason:
              'Unexpected isProceduralAtlasCharacter for U+${cp.toRadixString(16)}',
        );
      }
      expect(isProceduralAtlasCharacter('╭'), isFalse); // U+256D
      expect(isProceduralAtlasCharacter('▁'), isFalse); // U+2581
      expect(isProceduralAtlasCharacter('A'), isFalse);
      expect(isProceduralAtlasCharacter(''), isFalse);
      expect(isProceduralAtlasCharacter('██'), isFalse);
    });

    test(
      'Invariant 1: atlas slot moat integrity at dpr = 1.0, 1.5, 2.0',
      () async {
        expect(GlyphAtlas.padding, equals(3.0));
        expect(GlyphAtlasGenerator.padding, equals(3.0));
        expect(GlyphAtlas.overhang, equals(2.0));

        const extraChars = <String>[
          '\uF306',
          '\uF1FA',
          '\uF179',
          '\uF8FF',
          '\uE711',
          '\u23A7', // ⎧
          '\u23A8', // ⎨
          '\u23A9', // ⎩
          't\u0361',
        ];

        for (final dpr in <double>[1.0, 1.5, 2.0]) {
          final base = await GlyphAtlasGenerator.generate(
            fontSize: 13.0,
            fontFamily: _primaryFont,
            fontFamilyFallback: _fallbackFonts,
            devicePixelRatio: dpr,
          );
          addTearDown(base.dispose);
          final atlas = await base.addGlyphs(extraChars);
          addTearDown(atlas.dispose);

          final padPx = (atlas.actualPadding * dpr).round();
          final overhangPx = (atlas.actualOverhang * dpr).round();
          expect(padPx - overhangPx, greaterThanOrEqualTo(1));

          final (:rgba, :width, :height) = await _readImageRgba(atlas.image);

          final targets = <(String, bool, bool)>[
            for (final ch in extraChars) (ch, false, false),
            ('@', false, true),
            ('f', false, true),
            ('W', false, true),
          ];

          for (final (ch, isBold, isItalic) in targets) {
            final rect = atlas.rectFor(ch, isBold: isBold, isItalic: isItalic);
            expect(rect, isNotNull, reason: 'missing rect for $ch');
            final moat = _measureSlotMoatAlpha(
              atlasRgba: rgba,
              atlasWidth: width,
              atlasHeight: height,
              sourceRect: rect!,
              slotPadPx: padPx,
              overhangPx: overhangPx,
            );
            expect(
              moat.maxInsideAlpha,
              greaterThan(0),
              reason: 'glyph "$ch" at dpr=$dpr should render visible ink',
            );
            expect(
              moat.maxMoatAlpha,
              equals(0),
              reason:
                  'glyph "$ch" (italic=$isItalic) at dpr=$dpr leaked ink into '
                  'slot moat outside overhang',
            );
          }

          // White tile \uFFFF must also preserve an outer transparent moat.
          final whiteRect = atlas.charRects['\uFFFF']!;
          final whiteMoat = _measureSlotMoatAlpha(
            atlasRgba: rgba,
            atlasWidth: width,
            atlasHeight: height,
            sourceRect: whiteRect,
            slotPadPx: padPx,
            overhangPx: padPx - 1,
          );
          expect(whiteMoat.maxInsideAlpha, equals(255));
          expect(whiteMoat.maxMoatAlpha, equals(0));
        }
      },
    );

    test('Invariant 2: standalone prompt icons overhang into trailing space and '
        'paint overhanging edge over cursor background on x + 1', () async {
      for (final dpr in <double>[1.0, 2.0]) {
        final base = await GlyphAtlasGenerator.generate(
          fontSize: 13.0,
          fontFamily: _primaryFont,
          fontFamilyFallback: _fallbackFonts,
          devicePixelRatio: dpr,
        );
        addTearDown(base.dispose);
        final atlas = await base.addGlyphs(const <String>['\uF306', '\uF179']);
        addTearDown(atlas.dispose);

        final cellW = (atlas.cellWidth * dpr).round();
        final overhangPx = (atlas.actualOverhang * dpr).round();

        // 1. Standalone prompt icons: ' \uF306  \uF179 '
        final promptBuf = _bufferFromLines(const [' \uF306  \uF179 ']);
        final promptImg = await _paintBufferToRgba(
          buffer: promptBuf,
          atlas: atlas,
          devicePixelRatio: dpr,
        );

        final f306Trailing = _measureInkBounds(
          promptImg,
          x0: 2 * cellW,
          x1: 2 * cellW + overhangPx,
          y0: 0,
          y1: promptImg.height,
        );
        final f179Trailing = _measureInkBounds(
          promptImg,
          x0: 5 * cellW,
          x1: 5 * cellW + overhangPx,
          y0: 0,
          y1: promptImg.height,
        );
        expect(
          f306Trailing.count,
          greaterThan(0),
          reason: '\\uF306 at dpr=$dpr should overhang into trailing space',
        );
        expect(
          f179Trailing.count,
          greaterThan(0),
          reason: '\\uF179 at dpr=$dpr should overhang into trailing space',
        );

        // Gap between \uF306 overhang and \uF179 left overhang stays pure background.
        final gapBounds = _measureInkBounds(
          promptImg,
          x0: 2 * cellW + overhangPx,
          x1: 4 * cellW - overhangPx,
          y0: 0,
          y1: promptImg.height,
        );
        expect(gapBounds.count, equals(0));

        // 2. Cursor-adjacent \uF179 paints overhanging edge over cursor background on x + 1.
        const cursorR = 0;
        const cursorG = 220;
        const cursorB = 120;
        final cursorBuf = Buffer(3, 1)
          ..writeString(
            0,
            0,
            ' ',
            const Style(
              foreground: tui_color.Color(255, 255, 255),
              background: tui_color.Color(20, 20, 20),
            ),
          )
          ..writeString(
            1,
            0,
            '\uF179',
            const Style(
              foreground: tui_color.Color(255, 255, 255),
              background: tui_color.Color(20, 20, 20),
            ),
          )
          ..writeString(
            2,
            0,
            ' ',
            const Style(
              foreground: tui_color.Color(20, 20, 20),
              background: tui_color.Color(cursorR, cursorG, cursorB),
            ),
          );
        final cursorImg = await _paintBufferToRgba(
          buffer: cursorBuf,
          atlas: atlas,
          devicePixelRatio: dpr,
        );

        var maxOverhangRedOverCursor = 0;
        for (var y = 0; y < cursorImg.height; y++) {
          for (var x = 2 * cellW; x < 2 * cellW + overhangPx; x++) {
            final r = cursorImg.rgba[(y * cursorImg.width + x) * 4];
            if (r > maxOverhangRedOverCursor) maxOverhangRedOverCursor = r;
          }
        }
        expect(
          maxOverhangRedOverCursor,
          greaterThan(80),
          reason:
              '\\uF179 at dpr=$dpr should paint white overhanging edge over '
              'green cursor background at x + 1',
        );
      }
    });

    test(
      'Invariant 3: italics and unrounded ascent+descent descenders across 13pt and 14pt',
      () async {
        final expectedHeights = <double, double>{13.0: 16.0, 14.0: 17.0};

        for (final entry in expectedHeights.entries) {
          final fontSize = entry.key;
          final expectedCellHeight = entry.value;
          final atlas = await GlyphAtlasGenerator.generate(
            fontSize: fontSize,
            fontFamily: _primaryFont,
            fontFamilyFallback: _fallbackFonts,
          );
          addTearDown(atlas.dispose);

          expect(
            atlas.cellHeight,
            equals(expectedCellHeight),
            reason: 'fontSize=$fontSize cellHeight mismatch',
          );

          final (:rgba, :width, :height) = await _readImageRgba(atlas.image);
          final padPx = atlas.actualPadding.round();
          final overhangPx = atlas.actualOverhang.round();

          final checks = <(String, bool, bool)>[
            ('@', false, true),
            ('f', false, true),
            ('W', false, true),
            ('W', true, false),
            ('Y', true, false),
            ('&', true, false),
            ('g', false, false),
            ('j', false, false),
            ('p', false, false),
            ('q', false, false),
            ('y', false, false),
            (',', false, false),
            (';', false, false),
            ('Q', false, false),
          ];

          for (final (ch, isBold, isItalic) in checks) {
            final rect = atlas.rectFor(ch, isBold: isBold, isItalic: isItalic);
            expect(rect, isNotNull);
            final moat = _measureSlotMoatAlpha(
              atlasRgba: rgba,
              atlasWidth: width,
              atlasHeight: height,
              sourceRect: rect!,
              slotPadPx: padPx,
              overhangPx: overhangPx,
            );
            expect(moat.maxInsideAlpha, greaterThan(0));
            expect(
              moat.maxMoatAlpha,
              equals(0),
              reason:
                  "'$ch' (bold=$isBold, italic=$isItalic) at ${fontSize}pt "
                  'exceeded overhang into slot moat',
            );
          }

          // Render italic @, f, W and synthetic italic '╭' (no native italic variant).
          final italicBuf = _bufferFromLines(const [
            ' @  f  W  \u256D ',
          ], style: const Style(modifiers: Modifier.italic));
          final italicImg = await _paintBufferToRgba(
            buffer: italicBuf,
            atlas: atlas,
          );
          final cellW = atlas.cellWidth.round();
          final cellH = atlas.cellHeight.round();
          for (final col in <int>[1, 4, 7, 10]) {
            final bounds = _measureInkBounds(
              italicImg,
              x0: col * cellW - overhangPx,
              x1: (col + 1) * cellW + overhangPx,
              y0: 0,
              y1: cellH,
            );
            expect(
              bounds.count,
              greaterThan(0),
              reason:
                  'italic col=$col at ${fontSize}pt should render visible ink',
            );
          }

          // Render descenders and verify bottom-row ink lives cleanly inside cellHeight.
          final descBuf = _bufferFromLines(const ['gjpqy,;Q']);
          final descImg = await _paintBufferToRgba(
            buffer: descBuf,
            atlas: atlas,
          );
          for (var col = 0; col < 8; col++) {
            final bounds = _measureInkBounds(
              descImg,
              x0: col * cellW,
              x1: (col + 1) * cellW,
              y0: 0,
              y1: cellH,
            );
            expect(bounds.count, greaterThan(0));
            expect(
              bounds.maxY,
              greaterThan(atlas.standardBaseline.floor()),
              reason:
                  'descender col=$col at ${fontSize}pt must extend below baseline',
            );
            expect(bounds.maxY, lessThan(cellH));
          }
        }
      },
    );

    test(
      'Invariant 4: 3-row stacked math seamless across rows and combining tie-bars anchored on left',
      () async {
        final base = await GlyphAtlasGenerator.generate(
          fontSize: 13.0,
          fontFamily: _primaryFont,
          fontFamilyFallback: _fallbackFonts,
        );
        addTearDown(base.dispose);
        final atlas = await base.addGlyphs(const <String>[
          '\u23A7', // ⎧
          '\u23A8', // ⎨
          '\u23A9', // ⎩
          '\u2320', // ⌠
          '\u23AE', // ⎮
          '\u2321', // ⌡
          't\u0361',
          'o\u0361',
        ]);
        addTearDown(atlas.dispose);

        final mathBuf = _bufferFromLines(const [
          '\u23A7 \u2320',
          '\u23A8 \u23AE',
          '\u23A9 \u2321',
        ]);
        final mathImg = await _paintBufferToRgba(buffer: mathBuf, atlas: atlas);
        final cellW = atlas.cellWidth.round();
        final cellH = atlas.cellHeight.round();

        bool hasLitPixelInRow(int col, int y) {
          for (var x = col * cellW; x < (col + 1) * cellW; x++) {
            final r = mathImg.rgba[(y * mathImg.width + x) * 4];
            if (r - 0x14 > 24) return true;
          }
          return false;
        }

        for (final col in <int>[0, 2]) {
          expect(hasLitPixelInRow(col, cellH - 1), isTrue);
          expect(hasLitPixelInRow(col, cellH), isTrue);
          expect(hasLitPixelInRow(col, 2 * cellH - 1), isTrue);
          expect(hasLitPixelInRow(col, 2 * cellH), isTrue);
        }

        // Combining tie-bars: ' t\u0361s o\u0361o ' and trailing-space overhang ' t\u0361  o\u0361 '
        final tieBuf = _bufferFromLines(const [' t\u0361s o\u0361o ']);
        final tieImg = await _paintBufferToRgba(buffer: tieBuf, atlas: atlas);

        final cell0Ink = _measureInkBounds(
          tieImg,
          x0: 0,
          x1: cellW,
          y0: 0,
          y1: tieImg.height,
        );
        final cell3Ink = _measureInkBounds(
          tieImg,
          x0: 3 * cellW,
          x1: 4 * cellW,
          y0: 0,
          y1: tieImg.height,
        );
        expect(
          cell0Ink.count,
          equals(0),
          reason: 't\\u0361 should anchor on left without bleeding into cell 0',
        );
        expect(
          cell3Ink.count,
          equals(0),
          reason: 'o\\u0361 should anchor on left without bleeding into cell 3',
        );

        final tieTrailBuf = _bufferFromLines(const [' t\u0361  o\u0361 ']);
        final tieTrailImg = await _paintBufferToRgba(
          buffer: tieTrailBuf,
          atlas: atlas,
        );
        final overhangPx = atlas.actualOverhang.round();
        final tRightOverhang = _measureInkBounds(
          tieTrailImg,
          x0: 2 * cellW,
          x1: 2 * cellW + overhangPx,
          y0: 0,
          y1: tieTrailImg.height,
        );
        final oRightOverhang = _measureInkBounds(
          tieTrailImg,
          x0: 5 * cellW,
          x1: 5 * cellW + overhangPx,
          y0: 0,
          y1: tieTrailImg.height,
        );
        expect(
          tRightOverhang.count,
          greaterThan(0),
          reason: 't\\u0361 should overhang rightward into trailing space',
        );
        expect(
          oRightOverhang.count,
          greaterThan(0),
          reason: 'o\\u0361 should overhang rightward into trailing space',
        );
      },
    );

    test(
      'Invariant 5: procedural block zero neighbor bleed (enableBleed: false) '
      'and Frame-1 fallback parity with Frame-2 baked atlas on " \\uF179 "',
      () async {
        // 5a. Procedural block ' █ ' with enableBleed: false -> maxNeighborDelta == 0.
        for (final dpr in <double>[1.0, 2.0]) {
          final atlas = await GlyphAtlasGenerator.generate(
            fontSize: 13.0,
            fontFamily: _primaryFont,
            fontFamilyFallback: _fallbackFonts,
            devicePixelRatio: dpr,
          );
          addTearDown(atlas.dispose);

          final blockBuf = _bufferFromLines(const [' \u2588 ']);
          final blockImg = await _paintBufferToRgba(
            buffer: blockBuf,
            atlas: atlas,
            devicePixelRatio: dpr,
            enableBleed: false,
          );
          final cellW = (atlas.cellWidth * dpr).round();
          var maxNeighborDelta = 0;
          for (var y = 0; y < blockImg.height; y++) {
            for (var x = 0; x < blockImg.width; x++) {
              if (x >= cellW && x < 2 * cellW) continue;
              final off = (y * blockImg.width + x) * 4;
              for (var c = 0; c < 3; c++) {
                final d = (blockImg.rgba[off + c] - 0x14).abs();
                if (d > maxNeighborDelta) maxNeighborDelta = d;
              }
            }
          }
          expect(
            maxNeighborDelta,
            equals(0),
            reason: 'Procedural block at dpr=$dpr bled into neighbor cells',
          );
        }

        // 5b. Frame-1 fallback parity (cached and transient) with Frame-2 baked atlas on ' \uF179 '.
        final iconBuf = _bufferFromLines(const [' \uF179 ']);
        for (final (fontSize, dpr) in <(double, double)>[
          (13.0, 1.0),
          (13.0, 1.5),
          (13.0, 2.0),
          (14.0, 1.0),
          (14.0, 2.0),
        ]) {
          final controller = GlyphAtlasController(
            fontSize: fontSize,
            fontFamily: _primaryFont,
            fontFamilyFallback: _fallbackFonts,
            devicePixelRatio: dpr,
          );
          addTearDown(controller.dispose);
          await controller.ensureInitialized();

          final unbakedAtlas = controller.atlas!;
          expect(unbakedAtlas.rectFor('\uF179'), isNull);

          controller.ensureFallbackPaintersForBuffer(
            iconBuf,
            defaultForegroundArgb: 0xFFE6E6E6,
            defaultBackgroundArgb: 0xFF141414,
            faintOpacity: 140 / 255,
            palette: TerminalColorTheme.termuiDark,
          );

          final frame1Cached = await _paintBufferToRgba(
            buffer: iconBuf,
            atlas: unbakedAtlas,
            fallbackPainters: controller.fallbackPainters,
            devicePixelRatio: dpr,
          );
          final frame1Transient = await _paintBufferToRgba(
            buffer: iconBuf,
            atlas: unbakedAtlas,
            devicePixelRatio: dpr,
          );

          final bakedAtlas = await unbakedAtlas.addStyledGlyphs(const [
            ('\uF179', GlyphStyleVariant.regular),
          ]);
          addTearDown(bakedAtlas.dispose);

          final frame2 = await _paintBufferToRgba(
            buffer: iconBuf,
            atlas: bakedAtlas,
            devicePixelRatio: dpr,
          );

          final bounds1 = _measureInkBounds(
            frame1Cached,
            x0: 0,
            x1: frame1Cached.width,
            y0: 0,
            y1: frame1Cached.height,
          );
          final bounds2 = _measureInkBounds(
            frame2,
            x0: 0,
            x1: frame2.width,
            y0: 0,
            y1: frame2.height,
          );

          expect(
            bounds1,
            equals(bounds2),
            reason:
                'fs=$fontSize dpr=$dpr Frame-1 bounds=$bounds1 vs Frame-2=$bounds2',
          );
          expect(
            _maxPixelChannelDiff(frame1Cached.rgba, frame2.rgba),
            equals(0),
            reason: 'fs=$fontSize dpr=$dpr cached Frame-1 vs Frame-2 mismatch',
          );
          expect(
            _maxPixelChannelDiff(frame1Transient.rgba, frame2.rgba),
            equals(0),
            reason:
                'fs=$fontSize dpr=$dpr transient Frame-1 vs Frame-2 mismatch',
          );
        }
      },
    );
  });

  group(
    'Selective Option A visual golden',
    skip: !Platform.isLinux
        ? 'Flutter pixel goldens run on Linux only (see apps/fterm/README.md).'
        : null,
    () {
      test(
        'renders unclipped prompt icons, cursors, italics, ties, math, and 6x zoom',
        () async {
          final pngBytes = await _renderBoardPngBytes();
          await expectLater(
            pngBytes,
            matchesGoldenFile('goldens/selective_option_a_glyph_overhang.png'),
          );
        },
      );
    },
  );
}

typedef _BoardRun = ({String text, int fg, int bg, int mod});

const int _panelBgArgb = 0xFF14171F;
const int _panelFgArgb = 0xFFE6E9F0;
const List<String> _boardExtraGlyphs = <String>[
  '\u276F',
  '\uF306',
  '\uF179',
  '\uF09B',
  '\uE7A8',
  '\uF07B',
  '\uF1FA',
  '\uE711',
  '\uF302',
  't\u0361',
  'k\u0361',
  'o\u0361',
  'e\u0301\u0308',
  'A\u0308\u0301',
  '\u23A7',
  '\u23A8',
  '\u23A9',
  '\u2320',
  '\u23AE',
  '\u2321',
  '\u239B',
  '\u239C',
  '\u239D',
  '\u239E',
  '\u239F',
  '\u23A0',
  '\uE0B6',
  '\uE0B4',
  '\uE0C2',
  '\uE0C0',
];

void _writeBoardRuns(
  Buffer buf,
  int y,
  List<_BoardRun> runs, {
  int startX = 0,
}) {
  var x = startX;
  for (final (:text, :fg, :bg, :mod) in runs) {
    for (final grapheme in text.characters) {
      if (x >= buf.width) return;
      buf.setCell(x, y, grapheme, fg, bg, mod, blend: false);
      x++;
    }
  }
}

Buffer _buildPromptShowcaseBuffer() {
  final buf = Buffer.blank(52, 9);
  const fgDefault = _panelFgArgb;
  const bgDefault = _panelBgArgb;
  final muted = const tui_color.Color.ansi(7).argb;
  final red = const tui_color.Color.ansi(9).argb;
  final green = const tui_color.Color.ansi(10).argb;
  final yellow = const tui_color.Color.ansi(11).argb;
  final blue = const tui_color.Color.ansi(12).argb;
  final magenta = const tui_color.Color.ansi(13).argb;
  final cyan = const tui_color.Color.ansi(14).argb;
  final white = const tui_color.Color.ansi(15).argb;
  const pillBlue = 0xFF7AA2F7;
  const pillRed = 0xFFF7768E;

  _writeBoardRuns(buf, 0, [
    (text: '\u276F ', fg: green, bg: bgDefault, mod: Modifier.bold),
    (text: '\uF306  debian  ', fg: red, bg: bgDefault, mod: Modifier.none),
    (text: '\uF179  macOS  ', fg: white, bg: bgDefault, mod: Modifier.none),
    (text: '\uF09B  main  ', fg: magenta, bg: bgDefault, mod: Modifier.none),
    (text: '\uE7A8  1.85  ', fg: yellow, bg: bgDefault, mod: Modifier.none),
    (text: '\uF07B  src', fg: blue, bg: bgDefault, mod: Modifier.none),
  ]);
  _writeBoardRuns(buf, 1, [
    (text: 'cursor: ', fg: muted, bg: bgDefault, mod: Modifier.none),
    (text: '\u276F ', fg: green, bg: bgDefault, mod: Modifier.none),
    (text: '\uF179', fg: white, bg: bgDefault, mod: Modifier.none),
    (text: ' ', fg: pillBlue, bg: bgDefault, mod: Modifier.reverse),
    (text: '   \u276F ', fg: green, bg: bgDefault, mod: Modifier.none),
    (text: '\uF306', fg: red, bg: bgDefault, mod: Modifier.none),
    (text: ' ', fg: pillBlue, bg: bgDefault, mod: Modifier.reverse),
  ]);
  _writeBoardRuns(buf, 2, [
    (text: '\u276F ', fg: green, bg: bgDefault, mod: Modifier.none),
    (text: 'cat ', fg: fgDefault, bg: bgDefault, mod: Modifier.none),
    (text: '\uF306' * 7, fg: red, bg: bgDefault, mod: Modifier.none),
    (text: '\uF179' * 7, fg: cyan, bg: bgDefault, mod: Modifier.none),
  ]);
  _writeBoardRuns(buf, 3, [
    (text: 'italic: ', fg: muted, bg: bgDefault, mod: Modifier.none),
    (
      text: '@@@ fff WWW // 77',
      fg: yellow,
      bg: bgDefault,
      mod: Modifier.italic,
    ),
    (text: '   desc: ', fg: muted, bg: bgDefault, mod: Modifier.none),
    (text: 'gjpqy,;Q', fg: fgDefault, bg: bgDefault, mod: Modifier.none),
  ]);
  _writeBoardRuns(buf, 4, [
    (text: 'tie: ', fg: muted, bg: bgDefault, mod: Modifier.none),
    (
      text: 't\u0361s  k\u0361p  o\u0361o',
      fg: cyan,
      bg: bgDefault,
      mod: Modifier.none,
    ),
    (text: '   stack: ', fg: muted, bg: bgDefault, mod: Modifier.none),
    (
      text: 'e\u0301\u0308  A\u0308\u0301',
      fg: green,
      bg: bgDefault,
      mod: Modifier.none,
    ),
  ]);
  _writeBoardRuns(buf, 5, [
    (text: 'math: ', fg: muted, bg: bgDefault, mod: Modifier.none),
    (
      text: '\u23A7 x+1   \u2320  \u239B 1  0 \u239E',
      fg: fgDefault,
      bg: bgDefault,
      mod: Modifier.none,
    ),
  ]);
  _writeBoardRuns(buf, 6, [
    (
      text: '\u23A8 0     \u23AE  \u239C 0  1 \u239F',
      fg: fgDefault,
      bg: bgDefault,
      mod: Modifier.none,
    ),
  ], startX: 6);
  _writeBoardRuns(buf, 7, [
    (
      text: '\u23A9 x-1   \u2321  \u239D 0  0 \u23A0',
      fg: fgDefault,
      bg: bgDefault,
      mod: Modifier.none,
    ),
  ], startX: 6);
  _writeBoardRuns(buf, 8, [
    (text: 'pl: ', fg: muted, bg: bgDefault, mod: Modifier.none),
    (text: '\uE0B6', fg: pillBlue, bg: bgDefault, mod: Modifier.none),
    (text: 'MAIN', fg: bgDefault, bg: pillBlue, mod: Modifier.bold),
    (text: '\uE0B4  ', fg: pillBlue, bg: bgDefault, mod: Modifier.none),
    (text: '\uE0C2', fg: pillRed, bg: bgDefault, mod: Modifier.none),
    (text: 'HOT', fg: bgDefault, bg: pillRed, mod: Modifier.bold),
    (text: '\uE0C0  ', fg: pillRed, bg: bgDefault, mod: Modifier.none),
    (
      text: '\u250C\u2500\u2500\u2510 ',
      fg: cyan,
      bg: bgDefault,
      mod: Modifier.none,
    ),
    (
      text: '\u2588\u2588\u2593\u2592\u2591',
      fg: blue,
      bg: bgDefault,
      mod: Modifier.none,
    ),
  ]);
  return buf;
}

Buffer _buildZoomRowBuffer() {
  final buf = Buffer.blank(30, 1);
  _writeBoardRuns(buf, 0, const [
    (text: '\u276F ', fg: 0xFF7EE7AD, bg: _panelBgArgb, mod: Modifier.none),
    (text: '\uF306 ', fg: 0xFFFF7B85, bg: _panelBgArgb, mod: Modifier.none),
    (text: '\uF179', fg: 0xFFF0F6FC, bg: _panelBgArgb, mod: Modifier.none),
    (text: ' ', fg: 0xFFF0F6FC, bg: 0xFF3B4261, mod: Modifier.none),
    (text: ' ', fg: _panelFgArgb, bg: _panelBgArgb, mod: Modifier.none),
    (text: '\uF09B  ', fg: 0xFFDF9BFF, bg: _panelBgArgb, mod: Modifier.none),
    (
      text: 't\u0361s o\u0361o  ',
      fg: _panelFgArgb,
      bg: _panelBgArgb,
      mod: Modifier.none,
    ),
    (
      text: '\uF306\uF306\uF306',
      fg: 0xFFFF7B85,
      bg: _panelBgArgb,
      mod: Modifier.none,
    ),
    (
      text: '\uF179\uF179\uF179  ',
      fg: 0xFF7CE0EC,
      bg: _panelBgArgb,
      mod: Modifier.none,
    ),
    (text: '\u2588 ', fg: 0xFF79B8FF, bg: _panelBgArgb, mod: Modifier.none),
  ]);
  return buf;
}

Future<GlyphAtlas> _buildBoardAtlas({required double devicePixelRatio}) async {
  final base = await GlyphAtlasGenerator.generate(
    fontSize: 13.0,
    fontFamily: _primaryFont,
    fontFamilyFallback: _fallbackFonts,
    devicePixelRatio: devicePixelRatio,
  );
  final expanded = await base.addGlyphs(_boardExtraGlyphs);
  if (!identical(expanded, base)) {
    base.dispose();
  }
  return expanded;
}

void _drawBoardCaption(Canvas canvas, String text, Offset offset) {
  final painter = TextPainter(
    text: TextSpan(
      text: text,
      style: const TextStyle(
        color: Color(0xFFB4BED2),
        fontFamily: _primaryFont,
        fontSize: 13.0,
        fontWeight: FontWeight.w500,
      ),
    ),
    textDirection: TextDirection.ltr,
  )..layout();
  try {
    painter.paint(canvas, offset);
  } finally {
    painter.dispose();
  }
}

void _drawZoomCellGrid(
  Canvas canvas,
  Rect bounds,
  int cols,
  double cellStepX,
  Paint strokePaint,
) {
  canvas.drawRect(bounds, strokePaint);
  for (var col = 1; col < cols; col++) {
    final x = bounds.left + col * cellStepX;
    canvas.drawLine(
      Offset(x, bounds.top),
      Offset(x, bounds.bottom),
      strokePaint,
    );
  }
}

Future<ui.Image> _composeSelectiveOptionABoardImage() async {
  const boardW = 1488;
  const boardH = 498;
  const pad = 24.0;
  const labelH = 22.0;
  const gap = 22.0;
  const zoom = 6.0;
  const topSlotH = 288.0;
  const topY = pad + labelH;
  const bottomLabelY = topY + topSlotH + gap;
  const bottomY = bottomLabelY + labelH;

  final atlas2x = await _buildBoardAtlas(devicePixelRatio: 2.0);
  final atlas1x = await _buildBoardAtlas(devicePixelRatio: 1.0);
  try {
    final topImg = await _paintBufferToImage(
      buffer: _buildPromptShowcaseBuffer(),
      atlas: atlas2x,
      devicePixelRatio: 2.0,
      bgArgb: _panelBgArgb,
      fgArgb: _panelFgArgb,
    );
    final bottomImg = await _paintBufferToImage(
      buffer: _buildZoomRowBuffer(),
      atlas: atlas1x,
      devicePixelRatio: 1.0,
      bgArgb: _panelBgArgb,
      fgArgb: _panelFgArgb,
    );
    try {
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      canvas.drawRect(
        Rect.fromLTWH(0, 0, boardW.toDouble(), boardH.toDouble()),
        Paint()..color = const Color(0xFF0B0E14),
      );

      final gridPaint = Paint()
        ..color = const Color(0xFF283246)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.0;

      _drawBoardCaption(
        canvas,
        'Top Panel: 13pt @ 2.0x DPR (Production TuiAtlasPainter)',
        const Offset(pad, pad),
      );
      final topRect = Rect.fromLTWH(
        pad,
        topY,
        topImg.width.toDouble(),
        topImg.height.toDouble(),
      );
      canvas.drawImage(topImg, topRect.topLeft, Paint());
      canvas.drawRect(topRect, gridPaint);

      _drawBoardCaption(
        canvas,
        'Bottom Panel: 6x Nearest-Neighbor Zoom of 13pt @ 1.0x DPR (30 cols x 1 row, 1px #283246 cell grid)',
        const Offset(pad, bottomLabelY),
      );
      final bottomRect = Rect.fromLTWH(
        pad,
        bottomY,
        bottomImg.width * zoom,
        bottomImg.height * zoom,
      );
      canvas.drawImageRect(
        bottomImg,
        Rect.fromLTWH(
          0,
          0,
          bottomImg.width.toDouble(),
          bottomImg.height.toDouble(),
        ),
        bottomRect,
        Paint()..filterQuality = FilterQuality.none,
      );
      _drawZoomCellGrid(
        canvas,
        bottomRect,
        30,
        atlas1x.cellWidth * zoom,
        gridPaint,
      );

      final picture = recorder.endRecording();
      try {
        return await picture.toImage(boardW, boardH);
      } finally {
        picture.dispose();
      }
    } finally {
      topImg.dispose();
      bottomImg.dispose();
    }
  } finally {
    atlas2x.dispose();
    atlas1x.dispose();
  }
}

Future<Uint8List> _renderBoardPngBytes() async {
  final composite = await _composeSelectiveOptionABoardImage();
  try {
    final byteData = await composite.toByteData(format: ui.ImageByteFormat.png);
    return byteData!.buffer.asUint8List();
  } finally {
    composite.dispose();
  }
}
