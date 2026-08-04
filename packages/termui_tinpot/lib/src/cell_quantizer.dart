import 'dart:typed_data';
import 'termui_tinpot.dart';
import 'symbol_map.dart';

class CellQuantizer {
  static TinpotOutputCell quantize(
    Uint32List pixelsRgb,
    List<SymbolCandidate> candidates,
  ) {
    assert(pixelsRgb.length == 64);

    // 1. Find min and max pixels (like Tinpot)
    // Find the channel with the max range
    int minR = 255, maxR = 0;
    int minG = 255, maxG = 0;
    int minB = 255, maxB = 0;
    int minIndexR = 0, maxIndexR = 0;
    int minIndexG = 0, maxIndexG = 0;
    int minIndexB = 0, maxIndexB = 0;

    for (int i = 0; i < 64; i++) {
      int p = pixelsRgb[i];
      int r = (p >> 16) & 0xFF;
      int g = (p >> 8) & 0xFF;
      int b = p & 0xFF;

      if (r < minR) {
        minR = r;
        minIndexR = i;
      }
      if (r >= maxR) {
        maxR = r;
        maxIndexR = i;
      }

      if (g < minG) {
        minG = g;
        minIndexG = i;
      }
      if (g >= maxG) {
        maxG = g;
        maxIndexG = i;
      }

      if (b < minB) {
        minB = b;
        minIndexB = i;
      }
      if (b >= maxB) {
        maxB = b;
        maxIndexB = i;
      }
    }

    int rangeR = maxR - minR;
    int rangeG = maxG - minG;
    int rangeB = maxB - minB;

    final (c1, c2) = switch (null) {
      _ when rangeR >= rangeG && rangeR >= rangeB => (
        pixelsRgb[minIndexR],
        pixelsRgb[maxIndexR],
      ),
      _ when rangeG >= rangeR && rangeG >= rangeB => (
        pixelsRgb[minIndexG],
        pixelsRgb[maxIndexG],
      ),
      _ => (pixelsRgb[minIndexB], pixelsRgb[maxIndexB]),
    };

    // 2. Generate ideal bitmap mask based on min/max colors
    int idealMaskHigh = 0;
    int idealMaskLow = 0;
    for (int i = 0; i < 64; i++) {
      int d1 = _distSqRgb(pixelsRgb[i], c1);
      int d2 = _distSqRgb(pixelsRgb[i], c2);
      // Tie-break to c1 (background) if colors are exactly equal (e.g. solid color blocks)
      // This ensures the ideal mask is all 0s, which cleanly matches the Space character (non-inverted).
      if (d2 < d1) {
        if (i < 32) {
          idealMaskHigh |= (1 << (31 - i));
        } else {
          idealMaskLow |= (1 << (31 - (i - 32)));
        }
      }
    }

    int invMaskHigh = (~idealMaskHigh) & 0xFFFFFFFF;
    int invMaskLow = (~idealMaskLow) & 0xFFFFFFFF;

    int popcount32(int x) {
      x &= 0xFFFFFFFF;
      x -= ((x >>> 1) & 0x55555555);
      x = (x & 0x33333333) + ((x >>> 2) & 0x33333333);
      x = (x + (x >>> 4)) & 0x0f0f0f0f;
      x += (x >>> 8);
      x += (x >>> 16);
      return x & 0x3f;
    }

    var scoredCandidates =
        <({SymbolCandidate candidate, int distance, bool inverted})>[
          for (final candidate in candidates)
            () {
              final cMaskHigh = candidate.bitmap >>> 32;
              final cMaskLow = candidate.bitmap & 0xFFFFFFFF;

              final xorHigh1 = idealMaskHigh ^ cMaskHigh;
              final xorLow1 = idealMaskLow ^ cMaskLow;
              final dist1 = popcount32(xorHigh1) + popcount32(xorLow1);

              final xorHigh2 = invMaskHigh ^ cMaskHigh;
              final xorLow2 = invMaskLow ^ cMaskLow;
              final dist2 = popcount32(xorHigh2) + popcount32(xorLow2);

              return dist1 <= dist2
                  ? (candidate: candidate, distance: dist1, inverted: false)
                  : (candidate: candidate, distance: dist2, inverted: true);
            }(),
        ];

    // Sort by Hamming distance to find the best structural matches, breaking ties predictably
    scoredCandidates.sort((a, b) {
      int cmp = a.distance.compareTo(b.distance);
      if (cmp != 0) return cmp;
      if (a.inverted != b.inverted) {
        return a.inverted ? 1 : -1;
      }
      return a.candidate.codePoint.compareTo(b.candidate.codePoint);
    });

    // Evaluate exact error for the top 5 structural candidates
    int workFactor = 5;
    if (scoredCandidates.length > workFactor) {
      scoredCandidates = scoredCandidates.sublist(0, workFactor);
    }

    int bestError = -1;
    SymbolCandidate? bestCandidate;
    int bestFg = c2;
    int bestBg = c1;

    for (final (:candidate, :inverted, distance: _) in scoredCandidates) {
      final invert = inverted;

      int cMaskHigh = candidate.bitmap >>> 32;
      int cMaskLow = candidate.bitmap & 0xFFFFFFFF;

      int highBits = invert ? (~cMaskHigh & 0xFFFFFFFF) : cMaskHigh;
      int lowBits = invert ? (~cMaskLow & 0xFFFFFFFF) : cMaskLow;

      int sumrFg = 0, sumgFg = 0, sumbFg = 0, countFg = 0;
      int sumrBg = 0, sumgBg = 0, sumbBg = 0, countBg = 0;

      for (int i = 0; i < 32; i++) {
        bool isFg = ((highBits >> (31 - i)) & 1) == 1;
        int r = pixelsRgb[i];
        if (isFg) {
          sumrFg += (r >> 16) & 0xFF;
          sumgFg += (r >> 8) & 0xFF;
          sumbFg += r & 0xFF;
          countFg++;
        } else {
          sumrBg += (r >> 16) & 0xFF;
          sumgBg += (r >> 8) & 0xFF;
          sumbBg += r & 0xFF;
          countBg++;
        }
      }

      for (int i = 0; i < 32; i++) {
        bool isFg = ((lowBits >> (31 - i)) & 1) == 1;
        int r = pixelsRgb[32 + i];
        if (isFg) {
          sumrFg += (r >> 16) & 0xFF;
          sumgFg += (r >> 8) & 0xFF;
          sumbFg += r & 0xFF;
          countFg++;
        } else {
          sumrBg += (r >> 16) & 0xFF;
          sumgBg += (r >> 8) & 0xFF;
          sumbBg += r & 0xFF;
          countBg++;
        }
      }

      int meanFg = c2;
      if (countFg > 0) {
        meanFg =
            (0xFF << 24) |
            ((sumrFg ~/ countFg) << 16) |
            ((sumgFg ~/ countFg) << 8) |
            (sumbFg ~/ countFg);
      }

      int meanBg = c1;
      if (countBg > 0) {
        meanBg =
            (0xFF << 24) |
            ((sumrBg ~/ countBg) << 16) |
            ((sumgBg ~/ countBg) << 8) |
            (sumbBg ~/ countBg);
      }

      int error = 0;
      for (int i = 0; i < 32; i++) {
        bool isFg = ((highBits >> (31 - i)) & 1) == 1;
        int targetMean = isFg ? meanFg : meanBg;
        error += _distSqRgb(pixelsRgb[i], targetMean);
      }
      for (int i = 0; i < 32; i++) {
        bool isFg = ((lowBits >> (31 - i)) & 1) == 1;
        int targetMean = isFg ? meanFg : meanBg;
        error += _distSqRgb(pixelsRgb[32 + i], targetMean);
      }

      // If error is equal, pick the one with the better Hamming distance.
      // Since candidates are already sorted by Hamming distance, the first one encountered is inherently preferred.
      if (bestError == -1 || error < bestError) {
        bestError = error;
        bestCandidate = candidate;

        if (invert) {
          bestFg = meanBg;
          bestBg = meanFg;
        } else {
          bestFg = meanFg;
          bestBg = meanBg;
        }
      }
    }

    return (
      character: String.fromCharCode(bestCandidate?.codePoint ?? 0x20),
      fgColorArgb: bestFg,
      bgColorArgb: bestBg,
    );
  }

  static int _distSqRgb(int p1, int p2) {
    int dr = ((p1 >> 16) & 0xFF) - ((p2 >> 16) & 0xFF);
    int dg = ((p1 >> 8) & 0xFF) - ((p2 >> 8) & 0xFF);
    int db = (p1 & 0xFF) - (p2 & 0xFF);
    return dr * dr + dg * dg + db * db;
  }
}
