import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:termui/ui/buffer.dart';
import 'package:termui/ui/glyph_cell_list.dart';
import 'package:termui/ui/style.dart';
import 'package:termui/ui/terminal_palette.dart';
import 'package:termui/ui/widgets/display/kitty_image.dart';
// ignore: implementation_imports
import 'package:termui_flutter/src/rendering/atlas_quad_table.dart';
import 'package:termui_flutter/termui_flutter.dart';

Future<({Uint8List rgba, int width, int height})> _readImageRgba(
  ui.Image image,
) async {
  final bytes = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
  return (
    rgba: bytes!.buffer.asUint8List(),
    width: image.width,
    height: image.height,
  );
}

ui.Rect _quadRect(AtlasQuadTable table, int offset) => ui.Rect.fromLTRB(
  table.ltrbQuads[offset],
  table.ltrbQuads[offset + 1],
  table.ltrbQuads[offset + 2],
  table.ltrbQuads[offset + 3],
);

int _pixelAlpha(Uint8List rgba, int imgWidth, int x, int y) =>
    rgba[(y * imgWidth + x) * 4 + 3];

({int r, int g, int b, int a}) _pixelRgba(
  Uint8List rgba,
  int imgWidth,
  int x,
  int y,
) {
  final idx = (y * imgWidth + x) * 4;
  return (r: rgba[idx], g: rgba[idx + 1], b: rgba[idx + 2], a: rgba[idx + 3]);
}

List<int> _columnMaxAlpha(
  Uint8List rgba,
  int imgWidth,
  int imgHeight,
  ui.Rect rect,
) {
  final x0 = rect.left.round().clamp(0, imgWidth);
  final y0 = rect.top.round().clamp(0, imgHeight);
  final x1 = rect.right.round().clamp(0, imgWidth);
  final y1 = rect.bottom.round().clamp(0, imgHeight);
  final cols = <int>[];
  for (var x = x0; x < x1; x++) {
    var maxA = 0;
    for (var y = y0; y < y1; y++) {
      final a = _pixelAlpha(rgba, imgWidth, x, y);
      if (a > maxA) maxA = a;
    }
    cols.add(maxA);
  }
  return cols;
}

List<int> _rowMaxAlpha(
  Uint8List rgba,
  int imgWidth,
  int imgHeight,
  ui.Rect rect,
) {
  final x0 = rect.left.round().clamp(0, imgWidth);
  final y0 = rect.top.round().clamp(0, imgHeight);
  final x1 = rect.right.round().clamp(0, imgWidth);
  final y1 = rect.bottom.round().clamp(0, imgHeight);
  final rows = <int>[];
  for (var y = y0; y < y1; y++) {
    var maxA = 0;
    for (var x = x0; x < x1; x++) {
      final a = _pixelAlpha(rgba, imgWidth, x, y);
      if (a > maxA) maxA = a;
    }
    rows.add(maxA);
  }
  return rows;
}

int _maxMoatAlpha(
  Uint8List rgba,
  int imgWidth,
  int imgHeight,
  ui.Rect rect,
  int moatPx,
) {
  final x0 = rect.left.round();
  final y0 = rect.top.round();
  final x1 = rect.right.round();
  final y1 = rect.bottom.round();
  final mx0 = (x0 - moatPx).clamp(0, imgWidth);
  final my0 = (y0 - moatPx).clamp(0, imgHeight);
  final mx1 = (x1 + moatPx).clamp(0, imgWidth);
  final my1 = (y1 + moatPx).clamp(0, imgHeight);
  var maxA = 0;
  for (var y = my0; y < my1; y++) {
    for (var x = mx0; x < mx1; x++) {
      if (x >= x0 && x < x1 && y >= y0 && y < y1) continue;
      final a = _pixelAlpha(rgba, imgWidth, x, y);
      if (a > maxA) maxA = a;
    }
  }
  return maxA;
}

List<(int start, int end)> _litRuns(List<int> colAlphas, {int threshold = 64}) {
  final runs = <(int, int)>[];
  var inRun = false;
  var runStart = 0;
  for (var i = 0; i < colAlphas.length; i++) {
    final lit = colAlphas[i] >= threshold;
    if (lit && !inRun) {
      inRun = true;
      runStart = i;
    } else if (!lit && inRun) {
      inRun = false;
      runs.add((runStart, i));
    }
  }
  if (inRun) runs.add((runStart, colAlphas.length));
  return runs;
}

void _expectRectParity(
  GlyphAtlas atlas,
  int codePoint,
  int variantBits, {
  required String label,
}) {
  final ch = String.fromCharCode(codePoint);
  final isBold = (variantBits & 1) != 0;
  final isItalic = (variantBits & 2) != 0;
  final expected = atlas.rectFor(ch, isBold: isBold, isItalic: isItalic);
  final offset = atlas.quadTable.quadOffsetForCode(
    codePoint,
    variantBits: variantBits,
  );
  if (expected == null) {
    expect(offset, equals(-1), reason: '$label should be absent');
    return;
  }
  expect(offset, greaterThanOrEqualTo(0), reason: '$label should be present');
  expect(offset % 4, equals(0), reason: '$label offset must align to 4 floats');
  final actual = _quadRect(atlas.quadTable, offset);
  expect(actual.left, closeTo(expected.left, 1e-3), reason: '$label left');
  expect(actual.top, closeTo(expected.top, 1e-3), reason: '$label top');
  expect(actual.right, closeTo(expected.right, 1e-3), reason: '$label right');
  expect(
    actual.bottom,
    closeTo(expected.bottom, 1e-3),
    reason: '$label bottom',
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Pre-baked AtlasDecorationKind sprites', () {
    for (final dpr in const [1.0, 2.0]) {
      test(
        'all 14 decoration sprites have valid quad bounds, white ink, clean moats, and exact geometry at DPR $dpr',
        () async {
          final atlas = await GlyphAtlasGenerator.generate(
            fontSize: 14.0,
            fontFamily: 'Roboto Mono',
            devicePixelRatio: dpr,
          );
          addTearDown(atlas.dispose);

          final img = await _readImageRgba(atlas.image);
          final seenRects = <ui.Rect>[];

          for (final kind in AtlasDecorationKind.values) {
            for (final isWide in const [false, true]) {
              final offset = atlas.quadTable.decorationQuadOffset(
                kind,
                isWide: isWide,
              );
              expect(
                offset,
                greaterThanOrEqualTo(0),
                reason: 'missing $kind isWide=$isWide at dpr=$dpr',
              );
              expect(offset % 4, equals(0));
              expect(
                offset + 4,
                lessThanOrEqualTo(atlas.quadTable.ltrbQuads.length),
              );

              final rect = _quadRect(atlas.quadTable, offset);
              final expectedW = (isWide ? 2 : 1) * atlas.cellWidth * dpr;
              final expectedH = atlas.cellHeight * dpr;

              expect(rect.left, greaterThanOrEqualTo(0.0));
              expect(rect.top, greaterThanOrEqualTo(0.0));
              expect(rect.right, lessThanOrEqualTo(img.width.toDouble()));
              expect(rect.bottom, lessThanOrEqualTo(img.height.toDouble()));
              expect(rect.width, closeTo(expectedW, 1e-3));
              expect(rect.height, closeTo(expectedH, 1e-3));

              for (final other in seenRects) {
                expect(
                  rect.overlaps(other),
                  isFalse,
                  reason: '$kind isWide=$isWide overlaps another decoration',
                );
              }
              seenRects.add(rect);

              // Verify white color channel and non-zero ink inside the quad.
              final x0 = rect.left.round();
              final y0 = rect.top.round();
              final x1 = rect.right.round();
              final y1 = rect.bottom.round();
              var litPixels = 0;
              for (var y = y0; y < y1; y++) {
                for (var x = x0; x < x1; x++) {
                  final px = _pixelRgba(img.rgba, img.width, x, y);
                  if (px.a > 0) {
                    litPixels++;
                    expect(px.r, equals(px.g));
                    expect(px.g, equals(px.b));
                    if (px.a == 255) {
                      expect(px.r, equals(255));
                    }
                  }
                }
              }
              expect(
                litPixels,
                greaterThan(0),
                reason:
                    '$kind isWide=$isWide has no visible pixels at dpr=$dpr',
              );

              // Verify clean moat outside clipped sprite boundary.
              expect(
                _maxMoatAlpha(
                  img.rgba,
                  img.width,
                  img.height,
                  rect,
                  dpr.ceil(),
                ),
                equals(0),
                reason: '$kind isWide=$isWide bled into slot moat at dpr=$dpr',
              );
            }
          }

          // Specific per-kind vertical and horizontal pixel coverage checks.
          final overlineRows = _rowMaxAlpha(
            img.rgba,
            img.width,
            img.height,
            _quadRect(
              atlas.quadTable,
              atlas.quadTable.decorationQuadOffset(
                AtlasDecorationKind.overline,
                isWide: false,
              ),
            ),
          );
          expect(overlineRows.first, equals(255));
          expect(overlineRows.last, equals(0));

          final strikeRows = _rowMaxAlpha(
            img.rgba,
            img.width,
            img.height,
            _quadRect(
              atlas.quadTable,
              atlas.quadTable.decorationQuadOffset(
                AtlasDecorationKind.strikethrough,
                isWide: false,
              ),
            ),
          );
          expect(strikeRows.first, equals(0));
          expect(strikeRows.last, equals(0));
          expect(strikeRows[strikeRows.length ~/ 2], greaterThan(0));

          final singleRect = _quadRect(
            atlas.quadTable,
            atlas.quadTable.decorationQuadOffset(
              AtlasDecorationKind.underlineSingle,
              isWide: false,
            ),
          );
          final singleCols = _columnMaxAlpha(
            img.rgba,
            img.width,
            img.height,
            singleRect,
          );
          expect(singleCols.every((a) => a == 255), isTrue);

          final doubleRows = _rowMaxAlpha(
            img.rgba,
            img.width,
            img.height,
            _quadRect(
              atlas.quadTable,
              atlas.quadTable.decorationQuadOffset(
                AtlasDecorationKind.underlineDouble,
                isWide: false,
              ),
            ),
          );
          final hPx = doubleRows.length;
          final dprPx = dpr.round();
          // Bottom line occupies [h - dprPx, h), gap [h - 2*dprPx, h - dprPx),
          // top line occupies [h - 3*dprPx, h - 2*dprPx).
          expect(doubleRows[hPx - 1], equals(255));
          expect(doubleRows[hPx - dprPx - 1], equals(0));
          expect(doubleRows[hPx - 2 * dprPx - 1], equals(255));
        },
      );

      test(
        'curly, dotted, and dashed sprites tile cleanly across adjacent 1-cell and 2-cell boundaries at DPR $dpr',
        () async {
          final atlas = await GlyphAtlasGenerator.generate(
            fontSize: 14.0,
            fontFamily: 'Roboto Mono',
            devicePixelRatio: dpr,
          );
          addTearDown(atlas.dispose);

          final img = await _readImageRgba(atlas.image);

          // Curly underline: left and right boundary vertical alpha profiles
          // match so tiling adjacent 1-cell or 2-cell sprites leaves no seam.
          for (final isWide in const [false, true]) {
            final rect = _quadRect(
              atlas.quadTable,
              atlas.quadTable.decorationQuadOffset(
                AtlasDecorationKind.underlineCurly,
                isWide: isWide,
              ),
            );
            final xLeft = rect.left.round();
            final xRight = rect.right.round() - 1;
            final y0 = rect.top.round();
            final y1 = rect.bottom.round();

            var leftMax = 0;
            var rightMax = 0;
            var leftWeightedY = 0.0;
            var leftTotalA = 0.0;
            var rightWeightedY = 0.0;
            var rightTotalA = 0.0;
            for (var y = y0; y < y1; y++) {
              final la = _pixelAlpha(img.rgba, img.width, xLeft, y);
              final ra = _pixelAlpha(img.rgba, img.width, xRight, y);
              leftMax = math.max(leftMax, la);
              rightMax = math.max(rightMax, ra);
              leftWeightedY += (y - y0) * la;
              leftTotalA += la;
              rightWeightedY += (y - y0) * ra;
              rightTotalA += ra;
            }
            expect(
              leftMax,
              greaterThan(100),
              reason: 'curly left edge should carry visible stroke',
            );
            expect(
              rightMax,
              greaterThan(100),
              reason: 'curly right edge should carry visible stroke',
            );
            final leftCentroid = leftWeightedY / leftTotalA;
            final rightCentroid = rightWeightedY / rightTotalA;
            expect(
              (leftCentroid - rightCentroid).abs(),
              lessThanOrEqualTo(1.25 * dpr),
              reason:
                  'curly left/right edge vertical centroids must align across cell seam (isWide=$isWide, dpr=$dpr)',
            );

            // Also verify vertical oscillation spans multiple rows.
            final rows = _rowMaxAlpha(img.rgba, img.width, img.height, rect);
            final litRowCount = rows.where((a) => a > 64).length;
            expect(litRowCount, greaterThanOrEqualTo((2 * dpr).round()));
          }

          // Dotted and dashed underlines: quantized to integer full cycles so
          // tiling two sprites side-by-side preserves uniform dash/gap rhythm.
          for (final spec in const [
            (kind: AtlasDecorationKind.underlineDotted, targetPeriod: 2.5),
            (kind: AtlasDecorationKind.underlineDashed, targetPeriod: 4.0),
          ]) {
            for (final isWide in const [false, true]) {
              final rect = _quadRect(
                atlas.quadTable,
                atlas.quadTable.decorationQuadOffset(spec.kind, isWide: isWide),
              );
              final singleCols = _columnMaxAlpha(
                img.rgba,
                img.width,
                img.height,
                rect,
              );
              final spriteLogicalW = (isWide ? 2 : 1) * atlas.cellWidth;
              final expectedCycles = math.max(
                1,
                (spriteLogicalW / spec.targetPeriod).round(),
              );
              final singleRuns = _litRuns(singleCols);
              expect(
                singleRuns.length,
                equals(expectedCycles),
                reason:
                    '${spec.kind} isWide=$isWide dpr=$dpr expected $expectedCycles cycles',
              );

              // Concatenate two adjacent tiles and check boundary gap vs interior gap.
              final tiledCols = <int>[...singleCols, ...singleCols];
              final tiledRuns = _litRuns(tiledCols);
              expect(tiledRuns.length, equals(expectedCycles * 2));

              final gaps = <int>[
                for (var i = 1; i < tiledRuns.length; i++)
                  tiledRuns[i].$1 - tiledRuns[i - 1].$2,
              ];
              final minGap = gaps.reduce(math.min);
              final maxGap = gaps.reduce(math.max);
              expect(
                maxGap - minGap,
                lessThanOrEqualTo(2),
                reason:
                    '${spec.kind} tiled gaps $gaps should be uniform across cell boundary (isWide=$isWide, dpr=$dpr)',
              );
            }
          }
        },
      );
    }

    test(
      'addStyledGlyphs preserves all 14 decoration quads and rasterized pixels verbatim',
      () async {
        final atlas = await GlyphAtlasGenerator.generate(
          fontSize: 14.0,
          fontFamily: 'Roboto Mono',
          devicePixelRatio: 2.0,
        );
        addTearDown(atlas.dispose);

        final beforeImg = await _readImageRgba(atlas.image);
        final expanded = await atlas.addStyledGlyphs([
          ('Ψ', GlyphStyleVariant.regular),
          ('Ψ', GlyphStyleVariant.bold),
          ('🚀', GlyphStyleVariant.regular),
          ('中', GlyphStyleVariant.regular),
        ]);
        addTearDown(expanded.dispose);

        final afterImg = await _readImageRgba(expanded.image);

        for (final kind in AtlasDecorationKind.values) {
          for (final isWide in const [false, true]) {
            final beforeOff = atlas.quadTable.decorationQuadOffset(
              kind,
              isWide: isWide,
            );
            final afterOff = expanded.quadTable.decorationQuadOffset(
              kind,
              isWide: isWide,
            );
            expect(afterOff, greaterThanOrEqualTo(0));
            final beforeRect = _quadRect(atlas.quadTable, beforeOff);
            final afterRect = _quadRect(expanded.quadTable, afterOff);
            expect(afterRect, equals(beforeRect));

            final x0 = beforeRect.left.round();
            final y0 = beforeRect.top.round();
            final x1 = beforeRect.right.round();
            final y1 = beforeRect.bottom.round();
            for (var y = y0; y < y1; y++) {
              for (var x = x0; x < x1; x++) {
                expect(
                  _pixelRgba(afterImg.rgba, afterImg.width, x, y),
                  equals(_pixelRgba(beforeImg.rgba, beforeImg.width, x, y)),
                );
              }
            }
          }
        }
      },
    );

    test(
      'generateEmpty reports -1 for decoration offsets while indexing white rect',
      () async {
        final empty = await GlyphAtlasGenerator.generateEmpty(
          fontSize: 14.0,
          fontFamily: 'Roboto Mono',
        );
        addTearDown(empty.dispose);

        for (final kind in AtlasDecorationKind.values) {
          expect(
            empty.quadTable.decorationQuadOffset(kind, isWide: false),
            equals(-1),
          );
          expect(
            empty.quadTable.decorationQuadOffset(kind, isWide: true),
            equals(-1),
          );
        }
        _expectRectParity(empty, 0xFFFF, 0, label: 'empty white pixel');
        expect(empty.quadTable.quadOffsetForCode(0x41, variantBits: 0), -1);
      },
    );
  });

  group('AtlasQuadTable parity & open-addressed hash table', () {
    test(
      'quadOffsetForCode matches rectFor across ASCII, Box/Block, Braille, dynamic BMP/SMP, and invalid codes',
      () async {
        final baseAtlas = await GlyphAtlasGenerator.generate(
          fontSize: 14.0,
          fontFamily: 'Roboto Mono',
        );
        addTearDown(baseAtlas.dispose);

        final atlas = await baseAtlas.addStyledGlyphs([
          ('Ψ', GlyphStyleVariant.regular),
          ('Ψ', GlyphStyleVariant.bold),
          ('中', GlyphStyleVariant.regular),
          ('🚀', GlyphStyleVariant.regular),
          ('e\u0301', GlyphStyleVariant.regular),
        ]);
        addTearDown(atlas.dispose);

        // ASCII direct table (0x20..0x7E) across all 4 variants.
        for (var cp = 0x20; cp <= 0x7E; cp++) {
          for (var v = 0; v < 4; v++) {
            _expectRectParity(
              atlas,
              cp,
              v,
              label: 'ASCII U+${cp.toRadixString(16)} v=$v',
            );
          }
        }

        // Box/Block direct table (0x2500..0x259F) across all 4 variants.
        for (var cp = 0x2500; cp <= 0x259F; cp++) {
          for (var v = 0; v < 4; v++) {
            _expectRectParity(
              atlas,
              cp,
              v,
              label: 'Box U+${cp.toRadixString(16)} v=$v',
            );
          }
        }

        // Braille direct table (0x2800..0x28FF) across all 4 variants.
        for (var cp = 0x2800; cp <= 0x28FF; cp++) {
          for (var v = 0; v < 4; v++) {
            _expectRectParity(
              atlas,
              cp,
              v,
              label: 'Braille U+${cp.toRadixString(16)} v=$v',
            );
          }
        }

        // Hash-table scalars: initial extras, white pixel, dynamic BMP & SMP.
        for (final cp in const [
          0xF1,
          0x2019,
          0x2022,
          0x2122,
          0x25B6,
          0x25BC,
          0x25CB,
          0x25CF,
          0xFFFF,
          0x03A8, // 'Ψ' (regular + bold, italic/boldItalic fall back to regular)
          0x4E2D, // '中' (regular only)
          0x1F680, // '🚀' (SMP surrogate pair)
          0x0416, // 'Ж' (absent)
        ]) {
          for (var v = 0; v < 4; v++) {
            _expectRectParity(
              atlas,
              cp,
              v,
              label: 'Hash U+${cp.toRadixString(16)} v=$v',
            );
          }
        }

        // Verify bold 'Ψ' differs from regular 'Ψ', while italic falls back to regular.
        final regPsi = atlas.quadTable.quadOffsetForCode(
          0x03A8,
          variantBits: 0,
        );
        final boldPsi = atlas.quadTable.quadOffsetForCode(
          0x03A8,
          variantBits: 1,
        );
        final italicPsi = atlas.quadTable.quadOffsetForCode(
          0x03A8,
          variantBits: 2,
        );
        expect(boldPsi, isNot(equals(regPsi)));
        expect(italicPsi, equals(regPsi));

        // Non-scalar, zero, negative, cluster-flagged, and out-of-range codes return -1.
        expect(
          atlas.quadTable.quadOffsetForCode(
            GlyphCellList.wideContinuationCode,
            variantBits: 0,
          ),
          equals(-1),
        );
        expect(
          atlas.quadTable.quadOffsetForCode(-1, variantBits: 0),
          equals(-1),
        );
        expect(
          atlas.quadTable.quadOffsetForCode(
            GlyphCellList.clusterFlag | 0,
            variantBits: 0,
          ),
          equals(-1),
        );
        expect(
          atlas.quadTable.quadOffsetForCode(
            GlyphCellList.clusterFlag | 99,
            variantBits: 1,
          ),
          equals(-1),
        );
        expect(
          atlas.quadTable.quadOffsetForCode(0x110000, variantBits: 0),
          equals(-1),
        );
      },
    );

    test(
      'partial style atlas matches rectFor when only bold variant exists and ignores invalid charRects keys',
      () async {
        final empty = await GlyphAtlasGenerator.generateEmpty(
          fontSize: 14.0,
          fontFamily: 'Roboto Mono',
        );
        addTearDown(empty.dispose);

        const boldTilde = ui.Rect.fromLTWH(2, 2, 8, 16);
        const boldPsi = ui.Rect.fromLTWH(12, 2, 8, 16);
        const regOmega = ui.Rect.fromLTWH(22, 2, 8, 16);
        const dummy = ui.Rect.fromLTWH(32, 2, 8, 16);

        final partial = GlyphAtlas(
          image: empty.image,
          charRects: const {
            'Ω': regOmega,
            '': dummy,
            '\x00': dummy,
            '\uD800': dummy, // unpaired surrogate
            '->': dummy, // multi-char ligature
          },
          styleRects: const {
            ('~', true, false): boldTilde,
            ('Ψ', true, false): boldPsi,
          },
          cellWidth: empty.cellWidth,
          cellHeight: empty.cellHeight,
          fontSize: empty.fontSize,
          fontFamily: empty.fontFamily,
          nextGridIndex: 1,
        );

        for (final cp in const [0x7E, 0x03A8, 0x03A9]) {
          for (var v = 0; v < 4; v++) {
            _expectRectParity(
              partial,
              cp,
              v,
              label: 'partial U+${cp.toRadixString(16)} v=$v',
            );
          }
        }
        expect(partial.quadTable.quadOffsetForCode(0x03A8, variantBits: 0), -1);
        expect(
          partial.quadTable.quadOffsetForCode(0x03A8, variantBits: 1),
          greaterThanOrEqualTo(0),
        );
        expect(partial.quadTable.quadOffsetForCode(0x03A8, variantBits: 2), -1);
      },
    );

    test(
      'open-addressed hash table handles collisions, updates, and power-of-two resizing cleanly',
      () {
        final builder = AtlasQuadTableBuilder(
          initialQuadCapacity: 4,
          initialHashCapacity: 4,
        );

        // Ignored out-of-range code points.
        builder.putCodePoint(
          0,
          variantBits: 0,
          rect: const ui.Rect.fromLTWH(0, 0, 1, 1),
        );
        builder.putCodePoint(
          0x110000,
          variantBits: 0,
          rect: const ui.Rect.fromLTWH(0, 0, 1, 1),
        );

        final expected = <(int, int), ui.Rect>{};
        var idx = 0;

        void insert(int cp, int variant) {
          final rect = ui.Rect.fromLTWH(
            (idx % 64) * 10.0,
            (idx ~/ 64) * 20.0,
            8.0,
            16.0,
          );
          builder.putCodePoint(cp, variantBits: variant, rect: rect);
          expected[(cp, variant)] = rect;
          idx++;
        }

        // Insert 300+ entries across Cyrillic, CJK, and SMP ranges to force
        // multiple hash table doublings (4 -> 8 -> ... -> 1024) and linear probes.
        for (var cp = 0x0400; cp < 0x04A0; cp++) {
          insert(cp, 0);
          if (cp.isEven) insert(cp, 1);
        }
        for (var cp = 0x4E00; cp < 0x4E40; cp++) {
          insert(cp, 0);
        }
        for (var cp = 0x1F600; cp < 0x1F630; cp++) {
          insert(cp, 0);
        }
        // Variant-only entry (no regular variant 0) to verify non-fallback path.
        insert(0x2603, 2);

        // Overwrite an existing entry to verify in-place replacement without duplicate count.
        const updatedRect = ui.Rect.fromLTWH(999, 888, 12, 24);
        builder.putCodePoint(0x0400, variantBits: 0, rect: updatedRect);
        expected[(0x0400, 0)] = updatedRect;

        final table = builder.build();

        // Capacity is a power of two and keeps load factor <= 0.5.
        final cap = table.debugHashCapacity;
        expect(cap, greaterThanOrEqualTo(512));
        expect(cap & (cap - 1), equals(0));
        expect(table.debugHashCount, equals(expected.length));
        expect(table.debugHashCount * 2, lessThanOrEqualTo(cap));
        expect(table.quadCount, equals(idx + 1));

        for (final entry in expected.entries) {
          final (cp, v) = entry.key;
          final off = table.quadOffsetForCode(cp, variantBits: v);
          expect(off, greaterThanOrEqualTo(0));
          expect(_quadRect(table, off), equals(entry.value));
        }

        // Fallback from missing italic (2) to regular (0).
        final fallbackOff = table.quadOffsetForCode(0x0400, variantBits: 2);
        expect(_quadRect(table, fallbackOff), equals(updatedRect));

        // Missing regular (0) for variant-only key (0x2603, 2) does not fabricate a hit.
        expect(table.quadOffsetForCode(0x2603, variantBits: 0), equals(-1));
        expect(table.quadOffsetForCode(0x2603, variantBits: 1), equals(-1));
        expect(
          table.quadOffsetForCode(0x2603, variantBits: 2),
          greaterThanOrEqualTo(0),
        );

        // Absent hash keys terminate cleanly with -1.
        expect(table.quadOffsetForCode(0x9999, variantBits: 0), equals(-1));
        expect(table.quadOffsetForCode(0x10FFFF, variantBits: 3), equals(-1));
      },
    );
  });

  group('GlyphAtlasController.ensureFallbackPaintersForBuffer glyphCodes scan', () {
    test(
      'skips 0, 0x20, Kitty placeholders, and quadTable hits while creating fallbacks for unbaked scalars and clusters',
      () async {
        final controller = GlyphAtlasController(
          fontSize: 14.0,
          fontFamily: 'Roboto Mono',
        );
        addTearDown(controller.dispose);
        await controller.ensureInitialized();

        final buffer = Buffer(20, 2);
        // Baked ASCII across styles, Box/Block, and Braille -> quadTable hits.
        buffer.writeString(0, 0, 'A', const Style());
        buffer.writeString(1, 0, 'B', const Style(modifiers: Modifier.bold));
        buffer.writeString(2, 0, 'C', const Style(modifiers: Modifier.italic));
        buffer.writeString(
          3,
          0,
          'D',
          const Style(modifiers: Modifier.bold | Modifier.italic),
        );
        buffer.setCell(4, 0, '─', 0, 0, 0);
        buffer.setCell(5, 0, '█', 0, 0, 0);
        buffer.setCell(6, 0, '⣿', 0, 0, 0);
        // Wide continuation cell (code 0) and explicit space (0x20).
        buffer.setCell(7, 0, '', 0, 0, 0);
        buffer.setCell(8, 0, ' ', 0, 0, 0);
        // Kitty placeholders: flagged, raw scalar U+10EEEE, and cluster with diacritics.
        buffer.setCell(9, 0, 'Ж', 0, 0, Modifier.kittyPlaceholder);
        buffer.setCell(10, 0, kittyPlaceholderChar, 0, 0, 0);
        buffer.setCell(11, 0, '$kittyPlaceholderChar\u0305\u0305', 0, 0, 0);

        // Unbaked glyphs that MUST produce fallback painters:
        // - unbaked BMP scalar 'Ж'
        // - unbaked SMP scalar '🚀'
        // - unbaked combining cluster 'e\u0301'
        // - unbaked ZWJ emoji cluster '👨‍👩‍👧'
        buffer.setCell(0, 1, 'Ж', 0, 0, Modifier.bold);
        buffer.setCell(2, 1, '🚀', 0, 0, 0);
        buffer.setCell(4, 1, 'e\u0301', 0, 0, 0);
        buffer.setCell(6, 1, '👨‍👩‍👧', 0, 0, 0);

        controller.ensureFallbackPaintersForBuffer(
          buffer,
          defaultForegroundArgb: 0xFFFFFFFF,
          defaultBackgroundArgb: 0xFF000000,
          faintOpacity: 0.55,
          palette: TerminalColorTheme.termuiDark,
        );

        final chars = controller.fallbackPainters.keys.map((k) => k.$1).toSet();
        expect(chars, equals({'Ж', '🚀', 'e\u0301', '👨‍👩‍👧'}));

        // Bake 'Ж' (bold) and 'e\u0301' (regular) into the controller's atlas,
        // clear remaining cache, and verify re-scanning skips them cleanly.
        controller.requestMissingStyledGlyphs([
          ('Ж', GlyphStyleVariant.bold),
          ('e\u0301', GlyphStyleVariant.regular),
        ]);
        for (var i = 0; i < 40; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 5));
          final atlas = controller.atlas!;
          if (atlas.quadTable.quadOffsetForCode(0x0416, variantBits: 1) >= 0 &&
              atlas.rectFor('e\u0301') != null) {
            break;
          }
        }
        expect(
          controller.atlas!.quadTable.quadOffsetForCode(0x0416, variantBits: 1),
          greaterThanOrEqualTo(0),
        );
        expect(controller.atlas!.rectFor('e\u0301'), isNotNull);

        controller.ensureFallbackPaintersForBuffer(
          buffer,
          defaultForegroundArgb: 0xFFFFFFFF,
          defaultBackgroundArgb: 0xFF000000,
          faintOpacity: 0.55,
          palette: TerminalColorTheme.termuiDark,
        );
        final charsAfterBake = controller.fallbackPainters.keys
            .map((k) => k.$1)
            .toSet();
        expect(charsAfterBake, equals({'🚀', '👨‍👩‍👧'}));
      },
    );
  });
}
