import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' hide Color;
import 'package:flutter_test/flutter_test.dart';
import 'package:termui/ui/buffer.dart';
import 'package:termui/ui/color.dart' as tui_color;
import 'package:termui/ui/glyph_cell_list.dart';
import 'package:termui/ui/style.dart';
import 'package:termui/ui/terminal_palette.dart';
import 'package:termui/ui/widgets/core/geometry.dart' as tui_geo;
import 'package:termui/ui/widgets/display/kitty_image.dart';
// ignore: implementation_imports
import 'package:termui_flutter/src/rendering/painter.dart';
// ignore: implementation_imports
import 'package:termui_flutter/src/rendering/staging_cache.dart';
// ignore: implementation_imports
import 'package:termui_flutter/src/terminal_surface.dart';
import 'package:termui_flutter/termui_flutter.dart';

Future<Uint8List> _renderRgba(TuiAtlasPainter painter) async {
  final w = (painter.buffer.width * painter.atlas.cellWidth).ceil();
  final h = (painter.buffer.height * painter.atlas.cellHeight).ceil();
  final recorder = ui.PictureRecorder();
  painter.paint(Canvas(recorder), Size(w.toDouble(), h.toDouble()));
  final picture = recorder.endRecording();
  final image = await picture.toImage(w, h);
  picture.dispose();
  try {
    return (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!.buffer
        .asUint8List();
  } finally {
    image.dispose();
  }
}

void _paintDry(TuiAtlasPainter painter) {
  final w = painter.buffer.width * painter.atlas.cellWidth;
  final h = painter.buffer.height * painter.atlas.cellHeight;
  final recorder = ui.PictureRecorder();
  painter.paint(Canvas(recorder), Size(w, h));
  recorder.endRecording().dispose();
}

bool _cellContainsColor(
  Uint8List rgba,
  int imgWidth,
  int imgHeight,
  GlyphAtlas atlas,
  int col,
  int row,
  int targetR,
  int targetG,
  int targetB, {
  int spanCols = 1,
}) {
  final x0 = (col * atlas.cellWidth).floor().clamp(0, imgWidth);
  final x1 = ((col + spanCols) * atlas.cellWidth).ceil().clamp(0, imgWidth);
  final y0 = (row * atlas.cellHeight).floor().clamp(0, imgHeight);
  final y1 = ((row + 1) * atlas.cellHeight).ceil().clamp(0, imgHeight);
  for (var y = y0; y < y1; y++) {
    for (var x = x0; x < x1; x++) {
      final idx = (y * imgWidth + x) * 4;
      if (rgba[idx + 3] > 0 &&
          rgba[idx] == targetR &&
          rgba[idx + 1] == targetG &&
          rgba[idx + 2] == targetB) {
        return true;
      }
    }
  }
  return false;
}

bool _cellContainsTintedInk(
  Uint8List rgba,
  int imgWidth,
  int imgHeight,
  GlyphAtlas atlas,
  int col,
  int row,
  bool Function(int r, int g, int b, int a) matcher, {
  int spanCols = 1,
}) {
  final x0 = (col * atlas.cellWidth).floor().clamp(0, imgWidth);
  final x1 = ((col + spanCols) * atlas.cellWidth).ceil().clamp(0, imgWidth);
  final y0 = (row * atlas.cellHeight).floor().clamp(0, imgHeight);
  final y1 = ((row + 1) * atlas.cellHeight).ceil().clamp(0, imgHeight);
  for (var y = y0; y < y1; y++) {
    for (var x = x0; x < x1; x++) {
      final idx = (y * imgWidth + x) * 4;
      if (matcher(rgba[idx], rgba[idx + 1], rgba[idx + 2], rgba[idx + 3])) {
        return true;
      }
    }
  }
  return false;
}

bool _cellIsUniformColor(
  Uint8List rgba,
  int imgWidth,
  int imgHeight,
  GlyphAtlas atlas,
  int col,
  int row,
  int targetR,
  int targetG,
  int targetB,
) {
  // Inset by 1px to avoid adjacent cell overhang interference.
  final x0 = (col * atlas.cellWidth).floor().clamp(0, imgWidth) + 1;
  final x1 = ((col + 1) * atlas.cellWidth).ceil().clamp(0, imgWidth) - 1;
  final y0 = (row * atlas.cellHeight).floor().clamp(0, imgHeight) + 1;
  final y1 = ((row + 1) * atlas.cellHeight).ceil().clamp(0, imgHeight) - 1;
  if (x0 >= x1 || y0 >= y1) return false;
  for (var y = y0; y < y1; y++) {
    for (var x = x0; x < x1; x++) {
      final idx = (y * imgWidth + x) * 4;
      if (rgba[idx] != targetR ||
          rgba[idx + 1] != targetG ||
          rgba[idx + 2] != targetB ||
          rgba[idx + 3] != 255) {
        return false;
      }
    }
  }
  return true;
}

void _populateDense200x60Buffer(Buffer buf) {
  for (var y = 0; y < buf.height; y++) {
    final fg = (y % 3 == 0)
        ? const tui_color.Color(0x62, 0xD1, 0x96)
        : const tui_color.Color(0xE6, 0xED, 0xF3);
    final bg = y.isEven ? const tui_color.Color(0x14, 0x17, 0x1F) : null;
    final line =
        'row=${y.toString().padLeft(2, '0')} '
        'status=OK latency=${y * 3}us payload=0123456789abcdef_termui_row_cache';
    buf.writeString(
      0,
      y,
      line.padRight(buf.width),
      Style(foreground: fg, background: bg),
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Public exports & TuiAtlasStagingCache fingerprints', () {
    test('exports TuiAtlasStagingCache and AtlasDecorationKind publicly', () {
      final cache = TuiAtlasStagingCache();
      expect(cache.cols, equals(0));
      expect(cache.rows, equals(0));
      cache.ensureGridCapacity(8, 2);
      expect(cache.cols, equals(8));
      expect(cache.rows, equals(2));
      expect(AtlasDecorationKind.values, hasLength(7));
    });

    test('computeRowFingerprint reacts to cells, raw attrs, underlineColors, overrideMask, uris, and cluster reuse', () {
      final cache = TuiAtlasStagingCache();
      final buf = Buffer.blank(8, 2)..writeString(0, 0, 'Hello', Style.empty);

      final fpBase = cache.computeRowFingerprint(
        buffer: buf,
        row: 0,
        selectionHash: 0,
        hoveredLinkHash: 0,
        configHash: 1,
      );
      expect(
        cache.computeRowFingerprint(
          buffer: buf,
          row: 0,
          selectionHash: 0,
          hoveredLinkHash: 0,
          configHash: 1,
        ),
        equals(fpBase),
      );

      // Selection, hovered link, config, and bleed predecessor hashes all alter fingerprint.
      expect(
        cache.computeRowFingerprint(
          buffer: buf,
          row: 0,
          selectionHash: 42,
          hoveredLinkHash: 0,
          configHash: 1,
        ),
        isNot(equals(fpBase)),
      );
      expect(
        cache.computeRowFingerprint(
          buffer: buf,
          row: 0,
          selectionHash: 0,
          hoveredLinkHash: 99,
          configHash: 1,
        ),
        isNot(equals(fpBase)),
      );
      expect(
        cache.computeRowFingerprint(
          buffer: buf,
          row: 0,
          selectionHash: 0,
          hoveredLinkHash: 0,
          configHash: 2,
        ),
        isNot(equals(fpBase)),
      );
      expect(
        cache.computeRowFingerprint(
          buffer: buf,
          row: 0,
          selectionHash: 0,
          hoveredLinkHash: 0,
          configHash: 1,
          prevRowBgMaskHash: 7,
        ),
        isNot(equals(fpBase)),
      );

      // Zero-filled override mask preserves identical fingerprint; non-zero byte changes it.
      final mask = Uint8List(buf.width * buf.height);
      expect(
        cache.computeRowFingerprint(
          buffer: buf,
          row: 0,
          selectionHash: 0,
          hoveredLinkHash: 0,
          configHash: 1,
          cellOverrideMask: mask,
        ),
        equals(fpBase),
      );
      mask[2] = 1;
      expect(
        cache.computeRowFingerprint(
          buffer: buf,
          row: 0,
          selectionHash: 0,
          hoveredLinkHash: 0,
          configHash: 1,
          cellOverrideMask: mask,
        ),
        isNot(equals(fpBase)),
      );

      // Custom underline color and URI alter fingerprint.
      buf.setUnderlineColor(1, 0, 0xFFFF0080);
      final fpUl = cache.computeRowFingerprint(
        buffer: buf,
        row: 0,
        selectionHash: 0,
        hoveredLinkHash: 0,
        configHash: 1,
      );
      expect(fpUl, isNot(equals(fpBase)));

      buf.setUri(1, 0, 'https://termui.dev');
      final fpUri = cache.computeRowFingerprint(
        buffer: buf,
        row: 0,
        selectionHash: 0,
        hoveredLinkHash: 0,
        configHash: 1,
        mixCellUris: true,
      );
      expect(fpUri, isNot(equals(fpUl)));

      // Cluster ID reuse after clear() must produce a distinct fingerprint.
      buf.clear();
      buf.setAttributes(0, 0, char: '👨‍👩‍👧');
      final fpClusterA = cache.computeRowFingerprint(
        buffer: buf,
        row: 0,
        selectionHash: 0,
        hoveredLinkHash: 0,
        configHash: 1,
      );
      buf.clear();
      buf.setAttributes(0, 0, char: '👩‍🚀');
      expect(
        buf.glyphCodes[0],
        equals(GlyphCellList.clusterFlag | 0),
        reason: 'sanity: both clusters occupy table slot 0 after clear()',
      );
      final fpClusterB = cache.computeRowFingerprint(
        buffer: buf,
        row: 0,
        selectionHash: 0,
        hoveredLinkHash: 0,
        configHash: 1,
      );
      expect(fpClusterB, isNot(equals(fpClusterA)));
    });
  });

  group('200x60 Row cache hit/miss & raw attribute invalidation', () {
    test('hits 59/60 rows on 1-row tail and interior updates and invalidates on raw buffer.attributes writes', () async {
      final atlas = await GlyphAtlasGenerator.generate(
        fontSize: 13.0,
        fontFamily: 'Roboto Mono',
      );
      addTearDown(atlas.dispose);

      final buf = Buffer.blank(200, 60);
      _populateDense200x60Buffer(buf);
      final cache = TuiAtlasStagingCache();

      TuiAtlasPainter makePainter({TuiAtlasStagingCache? useCache}) =>
          TuiAtlasPainter(
            buffer: buf,
            atlas: atlas,
            stagingCache: useCache,
            fontFamily: 'Roboto Mono',
            fallbackPainters: const {},
            onMissingGlyphs: null,
            enableBleed: false,
          );

      // Cold paint: 0 hits, 60 misses.
      _paintDry(makePainter(useCache: cache));
      expect(cache.lastRowHits, equals(0));
      expect(cache.lastRowMisses, equals(60));

      // Clean repaint: 60 hits, 0 misses.
      _paintDry(makePainter(useCache: cache));
      expect(cache.lastRowHits, equals(60));
      expect(cache.lastRowMisses, equals(0));

      // 1-row tail mutation (row 59): 59 hits, 1 miss (in-place prefix path).
      buf.writeString(0, 59, 'TAIL_UPDATED_FRAME_1', Style.empty);
      _paintDry(makePainter(useCache: cache));
      expect(cache.lastRowHits, equals(59));
      expect(cache.lastRowMisses, equals(1));

      // 1-row interior mutation (row 10): 59 hits, 1 miss (compaction path).
      buf.writeString(
        0,
        10,
        'INTERIOR_MUTATED_WITH_UNDERLINES',
        const Style(
          foreground: tui_color.Color(255, 200, 0),
          underlineStyle: UnderlineStyle.curly,
          modifiers: Modifier.overline | Modifier.crossedOut,
        ),
      );
      _paintDry(makePainter(useCache: cache));
      expect(cache.lastRowHits, equals(59));
      expect(cache.lastRowMisses, equals(1));

      // Shrink row 10 back down to fewer sprites (contraction compaction path).
      buf.writeString(0, 10, ' '.padRight(200), Style.empty);
      _paintDry(makePainter(useCache: cache));
      expect(cache.lastRowHits, equals(59));
      expect(cache.lastRowMisses, equals(1));

      // Raw buffer.attributes[...] direct mutation on row 25 must invalidate immediately.
      final cellIdx = 25 * buf.width + 7;
      buf.attributes[cellIdx * 3] = 0xFFFF0000;
      _paintDry(makePainter(useCache: cache));
      expect(cache.lastRowHits, equals(59));
      expect(cache.lastRowMisses, equals(1));

      // Raw bg & modifier write on row 26.
      final cellIdx2 = 26 * buf.width + 3;
      buf.attributes[cellIdx2 * 3 + 1] = 0xFF00FF00;
      buf.attributes[cellIdx2 * 3 + 2] = Modifier.underlineCurly;
      _paintDry(makePainter(useCache: cache));
      expect(cache.lastRowHits, equals(59));
      expect(cache.lastRowMisses, equals(1));
    });

    test('compacted multi-channel rows (emoji, italic, fallback, ligature, Kitty, decorations) match uncached pixels', () async {
      final baseAtlas = await GlyphAtlasGenerator.generate(
        fontSize: 14.0,
        fontFamily: 'Roboto Mono',
      );
      final atlas = await baseAtlas.addGlyphs(const ['🚀', '中', 'e\u0301']);
      if (!identical(atlas.image, baseAtlas.image)) baseAtlas.dispose();
      addTearDown(atlas.dispose);

      final rgba = Uint8List.fromList([0, 255, 255, 255]);
      final registry = KittyImageRegistry()
        ..registerImage(
          KittyImageData(
            imageId: 77,
            pixelWidth: 1,
            pixelHeight: 1,
            rgbaPixels: rgba,
            gridCols: 1,
            gridRows: 1,
          ),
        );

      final buf = Buffer.blank(16, 6)
        ..registerKittyRegistry(const tui_geo.Rect(0, 0, 16, 6), registry)
        ..writeString(
          0,
          0,
          '🚀 中 e\u0301',
          const Style(
            foreground: tui_color.Color(255, 255, 255),
            underlineStyle: UnderlineStyle.curly,
            underlineColor: tui_color.Color(255, 64, 128),
          ),
        )
        ..writeString(
          0,
          1,
          '╭Ж',
          const Style(
            foreground: tui_color.Color(0, 255, 128),
            modifiers: Modifier.italic | Modifier.bold,
          ),
        )
        ..writeString(
          0,
          2,
          '=== <!--',
          const Style(
            foreground: tui_color.Color(128, 200, 255),
            modifiers: Modifier.underline,
          ),
        )
        ..setAttributes(
          0,
          3,
          char: kittyPlaceholderCell(0, 0),
          fg: 0xFF000000 | 77,
          bg: 0xFF102030,
          modifiers: Modifier.kittyPlaceholder,
        )
        ..writeString(
          0,
          4,
          'RAW_ATTR_ROW',
          const Style(foreground: tui_color.Color(255, 255, 255)),
        )
        ..writeString(
          0,
          5,
          'TAIL_ROW',
          const Style(foreground: tui_color.Color(200, 200, 200)),
        );

      final cache = TuiAtlasStagingCache();
      final ligPaintersCached = <(String, bool, bool, ui.Color), TextPainter>{};
      final ligPaintersFresh = <(String, bool, bool, ui.Color), TextPainter>{};
      addTearDown(() {
        for (final tp in ligPaintersCached.values) {
          tp.dispose();
        }
        for (final tp in ligPaintersFresh.values) {
          tp.dispose();
        }
      });

      TuiAtlasPainter buildPainter({required bool cached}) => TuiAtlasPainter(
        buffer: buf,
        atlas: atlas,
        stagingCache: cached ? cache : null,
        fontFamily: 'Roboto Mono',
        fallbackPainters: const {},
        ligaturePainters: cached ? ligPaintersCached : ligPaintersFresh,
        enableLigatures: true,
        enableBleed: false,
        onMissingGlyphs: null,
      );

      // Warm cache on frame 1.
      final frame1Cached = await _renderRgba(buildPainter(cached: true));
      final frame1Fresh = await _renderRgba(buildPainter(cached: false));
      expect(frame1Cached, equals(frame1Fresh));

      // Mutate interior row 4 via raw attributes[...], forcing compaction of rows 0..3 and 5!
      final idx = 4 * buf.width + 0;
      buf.attributes[idx * 3] = 0xFFFF0000;
      buf.attributes[idx * 3 + 1] = 0xFF004400;
      buf.attributes[idx * 3 + 2] = Modifier.underlineDouble;

      final frame2Cached = await _renderRgba(buildPainter(cached: true));
      expect(cache.lastRowHits, equals(5));
      expect(cache.lastRowMisses, equals(1));
      final frame2Fresh = await _renderRgba(buildPainter(cached: false));
      expect(frame2Cached, equals(frame2Fresh));

      // Overwrite half of wide CJK '中' at col 3 on row 0 -> clears partner cell cleanly.
      buf.setAttributes(4, 0, char: 'X', fg: 0xFF00FFFF);
      expect(buf.glyphCodes[3], equals(GlyphCellList.spaceCode));
      final frame3Cached = await _renderRgba(buildPainter(cached: true));
      expect(cache.lastRowHits, equals(5));
      expect(cache.lastRowMisses, equals(1));
      expect(
        frame3Cached,
        equals(await _renderRgba(buildPainter(cached: false))),
      );
    });
  });

  group('cellOverrideMask suppression across all passes', () {
    test('suppresses static text, emoji, italic, fallback, ligature (split runs), and decorations while preserving backgrounds and clean rows', () async {
      final baseAtlas = await GlyphAtlasGenerator.generate(
        fontSize: 16.0,
        fontFamily: 'Roboto Mono',
      );
      final atlas = await baseAtlas.addGlyphs(const ['🚀']);
      if (!identical(atlas.image, baseAtlas.image)) baseAtlas.dispose();
      addTearDown(atlas.dispose);

      const cellBg = tui_color.Color(0x20, 0x30, 0x40);
      const brightFg = tui_color.Color(0xFF, 0x40, 0x20);
      final buf = Buffer.blank(12, 6)
        // Row 0: normal/bold/italic ASCII text
        ..writeString(
          0,
          0,
          'ABC',
          const Style(
            foreground: brightFg,
            background: cellBg,
            modifiers: Modifier.bold,
          ),
        )
        // Row 1: color emoji
        ..writeString(
          0,
          1,
          '🚀',
          const Style(foreground: brightFg, background: cellBg),
        )
        // Row 2: synthetic italic ('╭') + unbaked fallback ('Ж')
        ..writeString(
          0,
          2,
          '╭',
          const Style(
            foreground: brightFg,
            background: cellBg,
            modifiers: Modifier.italic | Modifier.bold,
          ),
        )
        ..writeString(
          2,
          2,
          'Ж',
          const Style(foreground: brightFg, background: cellBg),
        )
        // Row 3: pre-baked ligature '===' and fallback ligature '<!--'
        ..writeString(
          0,
          3,
          '===',
          const Style(foreground: brightFg, background: cellBg),
        )
        ..writeString(
          5,
          3,
          '<!--',
          const Style(foreground: brightFg, background: cellBg),
        )
        // Row 4: all decorations with SGR 58 custom underline color
        ..writeString(
          0,
          4,
          'X',
          const Style(
            foreground: brightFg,
            background: cellBg,
            underlineStyle: UnderlineStyle.curly,
            underlineColor: tui_color.Color(0x00, 0xFF, 0xFF),
            modifiers: Modifier.overline | Modifier.crossedOut,
          ),
        )
        // Row 5: untouched control row
        ..writeString(
          0,
          5,
          'KEEP',
          const Style(foreground: tui_color.Color(0x00, 0xFF, 0x00)),
        );

      final cache = TuiAtlasStagingCache();
      final ligPainters = <(String, bool, bool, ui.Color), TextPainter>{};
      addTearDown(() {
        for (final tp in ligPainters.values) {
          tp.dispose();
        }
      });

      final w = (buf.width * atlas.cellWidth).ceil();
      final h = (buf.height * atlas.cellHeight).ceil();

      TuiAtlasPainter makePainter({Uint8List? mask}) => TuiAtlasPainter(
        buffer: buf,
        atlas: atlas,
        stagingCache: cache,
        cellOverrideMask: mask,
        fontFamily: 'Roboto Mono',
        fallbackPainters: const {},
        ligaturePainters: ligPainters,
        enableLigatures: true,
        enableBleed: false,
        onMissingGlyphs: null,
      );

      // Baseline unmasked frame (antialiased cyan curly underline over orange 'X' / dark bg).
      final baseline = await _renderRgba(makePainter());
      expect(cache.lastRowMisses, equals(6));
      expect(
        _cellContainsTintedInk(
          baseline,
          w,
          h,
          atlas,
          0,
          4,
          (r, g, b, a) => a > 0 && g > 100 && b > 100,
        ),
        isTrue,
      );
      expect(ligPainters.keys.any((k) => k.$1 == '<!--'), isTrue);
      for (final tp in ligPainters.values) {
        tp.dispose();
      }
      ligPainters.clear();

      // Mask selected cells on rows 0..4 (leave row 5 untouched).
      final mask = Uint8List(buf.width * buf.height);
      mask[0 * buf.width + 1] = 1; // 'B' on row 0
      mask[1 * buf.width + 0] = 1; // '🚀' on row 1
      mask[2 * buf.width + 0] = 1; // '╭' synthetic italic on row 2
      mask[2 * buf.width + 2] = 1; // 'Ж' fallback on row 2
      mask[3 * buf.width + 2] =
          1; // 3rd '=' of '===' -> splits to '==' + masked
      mask[3 * buf.width + 6] = 1; // '!' of '<!--' -> splits ligature
      mask[4 * buf.width + 0] = 1; // 'X' + overline + strike + curly underline

      final maskedRgba = await _renderRgba(makePainter(mask: mask));
      // Row 5 untouched -> 1 cache hit, 5 misses!
      expect(cache.lastRowHits, equals(1));
      expect(cache.lastRowMisses, equals(5));

      // Masked cells show ONLY solid cellBg (0x20, 0x30, 0x40), zero fg/decoration ink!
      for (final (col, row) in const [
        (1, 0),
        (0, 1),
        (0, 2),
        (2, 2),
        (2, 3),
        (6, 3),
        (0, 4),
      ]) {
        expect(
          _cellIsUniformColor(
            maskedRgba,
            w,
            h,
            atlas,
            col,
            row,
            0x20,
            0x30,
            0x40,
          ),
          isTrue,
          reason: 'masked cell ($col, $row) must render only background',
        );
      }

      // '<!--' ligature was split by masking col 6, so no '<!--' ligature painter was used.
      expect(ligPainters.keys.any((k) => k.$1 == '<!--'), isFalse);

      // Untouched row 5 still renders its green text.
      expect(
        _cellContainsColor(maskedRgba, w, h, atlas, 0, 5, 0x00, 0xFF, 0x00),
        isTrue,
      );

      // Clearing only row 0 mask -> 5 cache hits, 1 miss!
      mask[0 * buf.width + 1] = 0;
      await _renderRgba(makePainter(mask: mask));
      expect(cache.lastRowHits, equals(5));
      expect(cache.lastRowMisses, equals(1));

      // Clearing mask completely restores exact baseline pixels.
      final restored = await _renderRgba(makePainter(mask: null));
      expect(restored, equals(baseline));
    });
  });

  group('enableBleed row y+1 propagation, selection, hover, palette & decorations', () {
    test('enableBleed invalidates row y+1 only when row y non-default bg mask changes', () async {
      final atlas = await GlyphAtlasGenerator.generate(
        fontSize: 16.0,
        fontFamily: 'Roboto Mono',
      );
      addTearDown(atlas.dispose);

      final buf = Buffer.blank(4, 4);
      final cache = TuiAtlasStagingCache();

      TuiAtlasPainter makePainter({required bool cached}) => TuiAtlasPainter(
        buffer: buf,
        atlas: atlas,
        stagingCache: cached ? cache : null,
        fontFamily: 'Roboto Mono',
        fallbackPainters: const {},
        onMissingGlyphs: null,
        enableBleed: true,
        defaultBackgroundArgb: 0xFF000000,
      );

      // Frame 1: all default bg -> 0 hits, 4 misses.
      await _renderRgba(makePainter(cached: true));
      expect(cache.lastRowHits, equals(0));
      expect(cache.lastRowMisses, equals(4));

      // Frame 2: set cell (1, 0) bg to red -> row 0 AND row 1 must restage, rows 2..3 hit!
      buf.setAttributes(1, 0, char: ' ', fg: 0xFFFFFFFF, bg: 0xFFFF0000);
      final bleedRedCached = await _renderRgba(makePainter(cached: true));
      expect(cache.lastRowMisses, equals(2));
      expect(cache.lastRowHits, equals(2));
      expect(
        bleedRedCached,
        equals(await _renderRgba(makePainter(cached: false))),
      );

      // Frame 3: change only char on (1, 0) (bg still red) -> ONLY row 0 restages!
      buf.setAttributes(1, 0, char: 'A', fg: 0xFFFFFFFF, bg: 0xFFFF0000);
      await _renderRgba(makePainter(cached: true));
      expect(cache.lastRowMisses, equals(1));
      expect(cache.lastRowHits, equals(3));

      // Frame 4: reset (1, 0) bg back to default -> row 0 AND row 1 restage, rows 2..3 hit!
      buf.setAttributes(1, 0, char: 'A', fg: 0xFFFFFFFF, bg: 0xFF000000);
      final bleedClearedCached = await _renderRgba(makePainter(cached: true));
      expect(cache.lastRowMisses, equals(2));
      expect(cache.lastRowHits, equals(2));
      expect(
        bleedClearedCached,
        equals(await _renderRgba(makePainter(cached: false))),
      );
    });

    test('selection drags (controller modes & manual bounds) hit untouched rows and match uncached pixels', () async {
      final atlas = await GlyphAtlasGenerator.generate(
        fontSize: 14.0,
        fontFamily: 'Roboto Mono',
      );
      addTearDown(atlas.dispose);

      final buf = Buffer.blank(12, 6);
      for (var y = 0; y < 6; y++) {
        buf.writeString(0, y, 'LINE_${y}_TEXT', Style.empty);
      }
      final cache = TuiAtlasStagingCache();
      final selCtrl = TerminalSelectionController();
      addTearDown(selCtrl.dispose);

      TuiAtlasPainter makeCtrlPainter({
        required bool cached,
        int topVirtualRow = 0,
      }) => TuiAtlasPainter(
        buffer: buf,
        atlas: atlas,
        stagingCache: cached ? cache : null,
        fontFamily: 'Roboto Mono',
        fallbackPainters: const {},
        onMissingGlyphs: null,
        selectionController: selCtrl,
        topVirtualRow: topVirtualRow,
        enableBleed: false,
      );

      await _renderRgba(makeCtrlPainter(cached: true));
      expect(cache.lastRowMisses, equals(6));

      // Start selection on row 1 (cols 2..6): only row 1 misses, 5 rows hit!
      selCtrl.startSelection(
        2,
        1,
        region: const SelectionRegion(
          minCol: 1,
          maxCol: 10,
          minRow: 0,
          maxRow: 10,
        ),
      );
      selCtrl.updateSelection(6, 1);
      final sel1 = await _renderRgba(makeCtrlPainter(cached: true));
      expect(cache.lastRowHits, equals(5));
      expect(cache.lastRowMisses, equals(1));
      expect(sel1, equals(await _renderRgba(makeCtrlPainter(cached: false))));

      // Drag to row 2 col 4: rows 1 & 2 miss, 4 rows hit!
      selCtrl.updateSelection(4, 2);
      final sel2 = await _renderRgba(makeCtrlPainter(cached: true));
      expect(cache.lastRowHits, equals(4));
      expect(cache.lastRowMisses, equals(2));
      expect(sel2, equals(await _renderRgba(makeCtrlPainter(cached: false))));

      // Switch to block mode & line mode + topVirtualRow offset.
      selCtrl.updateSelection(5, 3, mode: SelectionMode.block);
      expect(
        await _renderRgba(makeCtrlPainter(cached: true)),
        equals(await _renderRgba(makeCtrlPainter(cached: false))),
      );
      selCtrl.updateSelection(5, 3, mode: SelectionMode.line);
      expect(
        await _renderRgba(makeCtrlPainter(cached: true, topVirtualRow: 1)),
        equals(
          await _renderRgba(makeCtrlPainter(cached: false, topVirtualRow: 1)),
        ),
      );

      // Manual selectionStart/selectionEnd/selectionBoxMode/selectionColBounds.
      TuiAtlasPainter makeManualPainter({
        required bool cached,
        required math.Point<int> end,
        bool box = false,
      }) => TuiAtlasPainter(
        buffer: buf,
        atlas: atlas,
        stagingCache: cached ? cache : null,
        fontFamily: 'Roboto Mono',
        fallbackPainters: const {},
        onMissingGlyphs: null,
        selectionStart: const math.Point(2, 1),
        selectionEnd: end,
        selectionColBounds: const (1, 9),
        selectionBoxMode: box,
        enableBleed: false,
      );

      await _renderRgba(
        makeManualPainter(cached: true, end: const math.Point(7, 2)),
      );
      final manualDrag = await _renderRgba(
        makeManualPainter(cached: true, end: const math.Point(7, 3)),
      );
      expect(cache.lastRowHits, greaterThanOrEqualTo(4));
      expect(
        manualDrag,
        equals(
          await _renderRgba(
            makeManualPainter(cached: false, end: const math.Point(7, 3)),
          ),
        ),
      );
      expect(
        await _renderRgba(
          makeManualPainter(
            cached: true,
            end: const math.Point(7, 3),
            box: true,
          ),
        ),
        equals(
          await _renderRgba(
            makeManualPainter(
              cached: false,
              end: const math.Point(7, 3),
              box: true,
            ),
          ),
        ),
      );
    });

    test('rainbow hover ticks invalidate only hovered link rows and tint underlines independently from glyph fg', () async {
      final atlas = await GlyphAtlasGenerator.generate(
        fontSize: 16.0,
        fontFamily: 'Roboto Mono',
      );
      addTearDown(atlas.dispose);

      final buf = Buffer.blank(16, 6);
      for (var y = 0; y < 6; y++) {
        buf.writeString(0, y, 'https://a.dev/$y', Style.empty);
      }
      const link = (
        uri: 'https://a.dev/2',
        startCol: 0,
        startRow: 2,
        endCol: 14,
        endRow: 2,
      );
      const rowSpans = <TerminalLinkRowSpan>[(row: 2, startCol: 0, endCol: 14)];

      final cache = TuiAtlasStagingCache();
      var tick = 0;
      void rainbowStyler(
        ResolvedTerminalLink _,
        int cellCount,
        DateTime _,
        HoveredLinkCellStyles styles,
      ) {
        final fg = tick.isEven ? 0xFF00FF00 : 0xFF00AAFF;
        final ul = tick.isEven ? 0xFFFF00FF : 0xFFFFFF00;
        for (var i = 0; i < cellCount; i++) {
          styles.setForeground(i, fg);
          styles.setUnderlineColor(i, ul);
        }
        styles.fillModifiers(Modifier.underlineCurly);
      }

      TuiAtlasPainter makePainter({required bool cached}) => TuiAtlasPainter(
        buffer: buf,
        atlas: atlas,
        stagingCache: cached ? cache : null,
        fontFamily: 'Roboto Mono',
        fallbackPainters: const {},
        onMissingGlyphs: null,
        hoveredLink: link,
        hoveredLinkRowSpans: rowSpans,
        hoveredLinkStyler: rainbowStyler,
        enableBleed: false,
      );

      final w = (buf.width * atlas.cellWidth).ceil();
      final h = (buf.height * atlas.cellHeight).ceil();

      // Tick 0: warm cache (fg = green (0,255,0), curly underline = magenta (255,0,255)).
      final tick0Rgba = await _renderRgba(makePainter(cached: true));
      expect(cache.lastRowMisses, equals(6));
      expect(
        _cellContainsTintedInk(
          tick0Rgba,
          w,
          h,
          atlas,
          1,
          2,
          (r, g, b, a) => a > 0 && r > 80 && b > 80,
        ),
        isTrue,
        reason: 'hovered underline tinted magenta independently from green fg',
      );

      // Tick 1: only row 2 misses, 5 rows hit (fg = (0,170,255), curly underline = yellow (255,255,0)).
      tick = 1;
      final tick1Rgba = await _renderRgba(makePainter(cached: true));
      expect(cache.lastRowHits, equals(5));
      expect(cache.lastRowMisses, equals(1));
      expect(tick1Rgba, equals(await _renderRgba(makePainter(cached: false))));
      expect(
        _cellContainsTintedInk(
          tick1Rgba,
          w,
          h,
          atlas,
          1,
          2,
          (r, g, b, a) => a > 0 && r > 80 && g > 150,
        ),
        isTrue,
        reason: 'tick 1 updated underline color to yellow',
      );
    });

    test('palette switches, theme changes, atlas updates, and all 7 decoration kinds + empty atlas strip fallback', () async {
      final atlas = await GlyphAtlasGenerator.generate(
        fontSize: 16.0,
        fontFamily: 'Roboto Mono',
      );
      addTearDown(atlas.dispose);

      final buf = Buffer.blank(14, 2)
        ..writeString(
          0,
          0,
          'A',
          const Style(
            foreground: tui_color.Color.ansi(1),
            modifiers: Modifier.overline,
          ),
        )
        ..writeString(
          1,
          0,
          'B',
          const Style(
            foreground: tui_color.Color.ansi(2),
            modifiers: Modifier.crossedOut,
          ),
        )
        ..writeString(
          2,
          0,
          'C',
          const Style(
            foreground: tui_color.Color(255, 255, 255),
            underlineStyle: UnderlineStyle.single,
            underlineColor: tui_color.Color(255, 0, 128),
          ),
        )
        ..writeString(
          3,
          0,
          'D',
          const Style(
            foreground: tui_color.Color(255, 255, 255),
            underlineStyle: UnderlineStyle.doubleLine,
            underlineColor: tui_color.Color(0, 255, 255),
          ),
        )
        ..writeString(
          4,
          0,
          'E',
          const Style(
            foreground: tui_color.Color(255, 255, 255),
            underlineStyle: UnderlineStyle.curly,
            underlineColor: tui_color.Color(255, 128, 0),
          ),
        )
        ..writeString(
          5,
          0,
          'F',
          const Style(
            foreground: tui_color.Color(255, 255, 255),
            underlineStyle: UnderlineStyle.dotted,
            underlineColor: tui_color.Color(128, 255, 0),
          ),
        )
        ..writeString(
          6,
          0,
          'G',
          const Style(
            foreground: tui_color.Color(255, 255, 255),
            underlineStyle: UnderlineStyle.dashed,
            underlineColor: tui_color.Color(128, 0, 255),
          ),
        )
        ..writeString(
          8,
          0,
          '中',
          const Style(
            foreground: tui_color.Color(255, 255, 255),
            underlineStyle: UnderlineStyle.curly,
            underlineColor: tui_color.Color(255, 0, 255),
          ),
        );

      final cache = TuiAtlasStagingCache();
      final w = (buf.width * atlas.cellWidth).ceil();
      final h = (buf.height * atlas.cellHeight).ceil();

      // Dark palette render.
      final darkRgba = await _renderRgba(
        TuiAtlasPainter(
          buffer: buf,
          atlas: atlas,
          stagingCache: cache,
          fontFamily: 'Roboto Mono',
          fontFamilyFallback: const ['monospace'],
          fallbackPainters: const {},
          onMissingGlyphs: null,
          palette: TerminalColorTheme.termuiDark,
        ),
      );
      expect(cache.lastRowMisses, equals(2));
      expect(
        _cellContainsTintedInk(
          darkRgba,
          w,
          h,
          atlas,
          8,
          0,
          (r, g, b, a) => a > 0 && r > 120 && b > 120 && g < 30,
          spanCols: 2,
        ),
        isTrue,
        reason: 'wide 2-cell curly underline tinted magenta',
      );

      // Switch palette -> invalidates all rows!
      final lightRgba = await _renderRgba(
        TuiAtlasPainter(
          buffer: buf,
          atlas: atlas,
          stagingCache: cache,
          fontFamily: 'Roboto Mono',
          fontFamilyFallback: const ['monospace'],
          fallbackPainters: const {},
          onMissingGlyphs: null,
          palette: TerminalColorTheme.solarizedLight,
        ),
      );
      expect(cache.lastRowHits, equals(0));
      expect(cache.lastRowMisses, equals(2));
      expect(lightRgba, isNot(equals(darkRgba)));

      // Switch fontFamilyFallback -> invalidates all rows!
      await _renderRgba(
        TuiAtlasPainter(
          buffer: buf,
          atlas: atlas,
          stagingCache: cache,
          fontFamily: 'Roboto Mono',
          fontFamilyFallback: const ['DejaVu Sans Mono'],
          fallbackPainters: const {},
          onMissingGlyphs: null,
          palette: TerminalColorTheme.solarizedLight,
        ),
      );
      expect(cache.lastRowHits, equals(0));
      expect(cache.lastRowMisses, equals(2));

      // Empty atlas fallback strips render overline, strikethrough, single, double, and wide cleanly.
      final emptyAtlas = await GlyphAtlasGenerator.generateEmpty(
        fontSize: 16.0,
        fontFamily: 'Roboto Mono',
      );
      addTearDown(emptyAtlas.dispose);
      final ew = (buf.width * emptyAtlas.cellWidth).ceil();
      final eh = (buf.height * emptyAtlas.cellHeight).ceil();
      final emptyRgba = await _renderRgba(
        TuiAtlasPainter(
          buffer: buf,
          atlas: emptyAtlas,
          stagingCache: cache,
          fontFamily: 'Roboto Mono',
          fallbackPainters: const {},
          onMissingGlyphs: null,
        ),
      );
      expect(cache.lastRowHits, equals(0));
      expect(cache.lastRowMisses, equals(2));
      expect(
        _cellContainsColor(
          emptyRgba,
          ew,
          eh,
          emptyAtlas,
          3,
          0,
          0x00,
          0xFF,
          0xFF,
        ),
        isTrue,
      );
      expect(
        _cellContainsColor(
          emptyRgba,
          ew,
          eh,
          emptyAtlas,
          8,
          0,
          0xFF,
          0x00,
          0xFF,
          spanCols: 2,
        ),
        isTrue,
      );
    });
  });

  group('TerminalSurface wiring (enableRowCache, setState preservation, IME composingPainter, Kitty scan)', () {
    testWidgets(
      'preserves _stagingCache across OSC 22 setState, supports enableRowCache rollback, and caches IME composingPainter',
      (tester) async {
        final terminal = FlutterTerminal();
        addTearDown(terminal.dispose);

        final rgba = Uint8List.fromList([0, 255, 0, 255]);
        final kittyData = KittyImageData(
          imageId: 901,
          pixelWidth: 1,
          pixelHeight: 1,
          rgbaPixels: rgba,
          gridCols: 1,
          gridRows: 1,
        );
        final registry = KittyImageRegistry()..registerImage(kittyData);
        final buf = Buffer.blank(20, 6)
          ..registerKittyRegistry(const tui_geo.Rect(0, 0, 20, 6), registry)
          ..writeString(0, 0, 'HELLO_SURFACE', Style.empty)
          ..setAttributes(
            0,
            1,
            char: kittyPlaceholderCell(0, 0),
            fg: 0xFF000000 | 901,
            bg: 0xFF000000,
            modifiers: Modifier.kittyPlaceholder,
          );
        final imeClient = TerminalImeClient();
        addTearDown(imeClient.dispose);

        Widget buildSurface({
          required bool enableRowCache,
          ui.Color fgColor = const ui.Color(0xFFFFFFFF),
        }) => Directionality(
          textDirection: TextDirection.ltr,
          child: SizedBox(
            width: 320,
            height: 200,
            child: TerminalSurface(
              terminal: terminal,
              imeClient: imeClient,
              buffer: buf,
              enableRowCache: enableRowCache,
              foregroundColor: fgColor,
              cursorPosition: const (col: 2, row: 0),
            ),
          ),
        );

        await tester.runAsync<void>(() async {
          await tester.pumpWidget(buildSurface(enableRowCache: true));
          final state = tester.state<TerminalSurfaceState>(
            find.byType(TerminalSurface),
          );
          for (var i = 0; i < 40 && state.atlasController.atlas == null; i++) {
            await Future<void>.delayed(const Duration(milliseconds: 10));
            await tester.pump();
          }
          expect(state.atlasController.atlas, isNotNull);
        });
        await tester.pump();

        final state = tester.state<TerminalSurfaceState>(
          find.byType(TerminalSurface),
        );
        final cacheBefore = state.debugStagingCache;
        final bgTransformsBefore = stagingCacheInternalsOf(cacheBefore)
            .active
            .bgTransforms;
        expect(bgTransformsBefore.isNotEmpty, isTrue);

        final painterBefore =
            tester.widget<CustomPaint>(find.byType(CustomPaint)).painter!
                as TuiAtlasPainter;
        expect(identical(painterBefore.stagingCache, cacheBefore), isTrue);

        // Trigger OSC 22 mouse cursor setState rebuild -> staging cache and backing array preserved!
        terminal.backend.write('\x1b]22;pointer\x07');
        await tester.pump();
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

        // Start IME composition -> _composingPainter cached and reused across rebuilds!
        imeClient.updateEditingValueWithDeltas([
          const TextEditingDeltaInsertion(
            oldText: '',
            textInserted: '´',
            insertionOffset: 0,
            selection: TextSelection.collapsed(offset: 1),
            composing: TextRange(start: 0, end: 1),
          ),
        ]);
        await tester.pump();
        final cachedTp1 = state.debugComposingPainter;
        expect(cachedTp1, isNotNull);
        final painterComposing =
            tester.widget<CustomPaint>(find.byType(CustomPaint)).painter!
                as TuiAtlasPainter;
        expect(identical(painterComposing.composingPainter, cachedTp1), isTrue);

        // Unrelated OSC 22 rebuild keeps exact same cached TextPainter instance!
        terminal.backend.write('\x1b]22;text\x07');
        await tester.pump();
        expect(identical(state.debugComposingPainter, cachedTp1), isTrue);

        // Changing foreground color rebuilds cached composing TextPainter cleanly.
        await tester.pumpWidget(
          buildSurface(
            enableRowCache: true,
            fgColor: const ui.Color(0xFF00FF00),
          ),
        );
        await tester.pump();
        expect(state.debugComposingPainter, isNotNull);
        expect(identical(state.debugComposingPainter, cachedTp1), isFalse);

        // Toggle enableRowCache: false -> stagingCache passed to painter becomes null!
        await tester.pumpWidget(buildSurface(enableRowCache: false));
        await tester.pump();
        final painterBypassed =
            tester.widget<CustomPaint>(find.byType(CustomPaint)).painter!
                as TuiAtlasPainter;
        expect(painterBypassed.stagingCache, isNull);

        // Toggle back to enableRowCache: true -> cache re-enabled and paints cleanly!
        await tester.pumpWidget(buildSurface(enableRowCache: true));
        await tester.pump();
        final painterReenabled =
            tester.widget<CustomPaint>(find.byType(CustomPaint)).painter!
                as TuiAtlasPainter;
        expect(identical(painterReenabled.stagingCache, cacheBefore), isTrue);

        // Unmount disposes cached composing TextPainter cleanly without throwing.
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
      },
    );
  });

  group('Step 1 200x60 TuiAtlasPainter CPU paint benchmark', () {
    test('measures 200x60 1-row tail, 1-row interior, full redraw, and curly diagnostics CPU paint time', () async {
      final atlas = await GlyphAtlasGenerator.generate(
        fontSize: 13.0,
        fontFamily: 'Roboto Mono',
      );
      addTearDown(atlas.dispose);

      final buf = Buffer.blank(200, 60);
      _populateDense200x60Buffer(buf);
      final cache = TuiAtlasStagingCache();
      final size = Size(
        buf.width * atlas.cellWidth,
        buf.height * atlas.cellHeight,
      );

      double measureAvgMs(
        int iters,
        void Function(int i) beforePaint, {
        required bool cached,
      }) {
        // Warmup
        for (var i = 0; i < 30; i++) {
          beforePaint(i);
          final rec = ui.PictureRecorder();
          TuiAtlasPainter(
            buffer: buf,
            atlas: atlas,
            stagingCache: cached ? cache : null,
            fontFamily: 'Roboto Mono',
            fallbackPainters: const {},
            onMissingGlyphs: null,
            enableBleed: false,
          ).paint(Canvas(rec), size);
          rec.endRecording().dispose();
        }
        var totalUs = 0;
        final sw = Stopwatch();
        for (var i = 0; i < iters; i++) {
          beforePaint(i);
          final rec = ui.PictureRecorder();
          final canvas = Canvas(rec);
          final painter = TuiAtlasPainter(
            buffer: buf,
            atlas: atlas,
            stagingCache: cached ? cache : null,
            fontFamily: 'Roboto Mono',
            fallbackPainters: const {},
            onMissingGlyphs: null,
            enableBleed: false,
          );
          sw
            ..reset()
            ..start();
          painter.paint(canvas, size);
          sw.stop();
          totalUs += sw.elapsedMicroseconds;
          rec.endRecording().dispose();
        }
        return totalUs / 1000.0 / iters;
      }

      final tail1RowMs = measureAvgMs(
        200,
        (i) => buf.writeString(
          0,
          59,
          'TAIL_TICK_${i.toString().padLeft(4, '0')}',
          Style.empty,
        ),
        cached: true,
      );
      expect(cache.lastRowHits, equals(59));
      expect(cache.lastRowMisses, equals(1));

      final interior1RowMs = measureAvgMs(200, (i) {
        final attrIdx = (30 * buf.width + 42) * 3 + 2;
        buf.attributes[attrIdx] = i.isEven ? Modifier.reverse : Modifier.none;
      }, cached: true);
      expect(cache.lastRowHits, equals(59));
      expect(cache.lastRowMisses, equals(1));

      final fullDirtyMs = measureAvgMs(
        100,
        (_) => cache.invalidateAllRows(),
        cached: true,
      );
      expect(cache.lastRowHits, equals(0));
      expect(cache.lastRowMisses, equals(60));

      // Dense 200x60 curly underlines (0 Path allocations).
      for (var y = 0; y < buf.height; y++) {
        buf.writeString(
          0,
          y,
          'curly_diagnostic_line_$y'.padRight(buf.width),
          const Style(
            foreground: tui_color.Color(0xE6, 0xED, 0xF3),
            underlineStyle: UnderlineStyle.curly,
            underlineColor: tui_color.Color(0xFF, 0x55, 0x55),
          ),
        );
      }
      final curlyFullMs = measureAvgMs(
        60,
        (_) => cache.invalidateAllRows(),
        cached: true,
      );
      final curly1RowMs = measureAvgMs(
        150,
        (i) => buf.writeString(
          0,
          59,
          'curly_tail_$i'.padRight(buf.width),
          const Style(
            foreground: tui_color.Color(0xE6, 0xED, 0xF3),
            underlineStyle: UnderlineStyle.curly,
            underlineColor: tui_color.Color(0xFF, 0x55, 0x55),
          ),
        ),
        cached: true,
      );

      // ignore: avoid_print
      print(
        'tui_atlas_painter_benchmark (200x60): '
        '1rowTail=${tail1RowMs.toStringAsFixed(3)}ms, '
        '1rowInterior=${interior1RowMs.toStringAsFixed(3)}ms, '
        'fullDirty=${fullDirtyMs.toStringAsFixed(3)}ms, '
        'curlyFull=${curlyFullMs.toStringAsFixed(3)}ms, '
        'curly1Row=${curly1RowMs.toStringAsFixed(3)}ms',
      );
    });
  });
}
