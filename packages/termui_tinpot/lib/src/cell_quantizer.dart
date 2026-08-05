import 'dart:typed_data';
import 'termui_tinpot.dart';
import 'symbol_map.dart';
import 'color_math.dart';

class CellQuantizer {
  final Int32List _pixelsDin99d = Int32List(64);
  final Int32List _deltaNorm = Int32List(64);
  final Int32List _deltaInv = Int32List(64);
  static const int _workFactor = 5;
  final List<SymbolCandidate?> _topCandidates = List.filled(_workFactor, null);
  final Int32List _topDistances = Int32List(_workFactor);
  final List<bool> _topInverted = List.filled(_workFactor, false);
  
  TinpotOutputCell quantize(
    Uint32List pixelsRgb,
    List<SymbolCandidate> candidates, {
    bool useDin99d = false,
    bool useMedian = false,
  }) {
    assert(pixelsRgb.length == 64);

    if (useDin99d) {
      for (int i = 0; i < 64; i++) {
        int p = pixelsRgb[i];
        _pixelsDin99d[i] = ColorMath.rgbToDin99d(
          (p >> 16) & 0xFF,
          (p >> 8) & 0xFF,
          p & 0xFF,
        );
      }
    }

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
    int dominantChannel = 0;
    if (rangeR >= rangeG && rangeR >= rangeB) {
      dominantChannel = 0;
    } else if (rangeG >= rangeR && rangeG >= rangeB) {
      dominantChannel = 1;
    } else {
      dominantChannel = 2;
    }

    final (c1, c2) = switch (null) {
      _ when dominantChannel == 0 => (
        pixelsRgb[minIndexR],
        pixelsRgb[maxIndexR],
      ),
      _ when dominantChannel == 1 => (
        pixelsRgb[minIndexG],
        pixelsRgb[maxIndexG],
      ),
      _ => (pixelsRgb[minIndexB], pixelsRgb[maxIndexB]),
    };

    int c2Din = useDin99d
        ? ColorMath.rgbToDin99d((c2 >> 16) & 0xFF, (c2 >> 8) & 0xFF, c2 & 0xFF)
        : 0;

    int c1Din = useDin99d
        ? ColorMath.rgbToDin99d((c1 >> 16) & 0xFF, (c1 >> 8) & 0xFF, c1 & 0xFF)
        : 0;

    // Precompute distances and deltas
    int baseErrorNorm = 0;
    int baseErrorInv = 0;

    for (int i = 0; i < 64; i++) {
      int d1, d2;
      if (useDin99d) {
        d1 = ColorMath.distanceSqDin99d(_pixelsDin99d[i], c1Din);
        d2 = ColorMath.distanceSqDin99d(_pixelsDin99d[i], c2Din);
      } else {
        d1 = _distSqRgb(pixelsRgb[i], c1);
        d2 = _distSqRgb(pixelsRgb[i], c2);
      }

      baseErrorNorm += d2;
      _deltaNorm[i] = d1 - d2;

      baseErrorInv += d1;
      _deltaInv[i] = d2 - d1;
    }

    _topDistances.fillRange(0, _workFactor, 0x7FFFFFFF);
    _topCandidates.fillRange(0, _workFactor, null);
    _topInverted.fillRange(0, _workFactor, false);

    for (final candidate in candidates) {
      final cMaskHigh = candidate.bitmap >>> 32;
      final cMaskLow = candidate.bitmap & 0xFFFFFFFF;

      int errorNorm = baseErrorNorm;
      int errorInv = baseErrorInv;

      for (int i = 0; i < 32; i++) {
        int bitHigh = (cMaskHigh >> (31 - i)) & 1;
        errorNorm += _deltaNorm[i] * bitHigh;
        errorInv += _deltaInv[i] * bitHigh;
      }
      for (int i = 0; i < 32; i++) {
        int bitLow = (cMaskLow >> (31 - i)) & 1;
        errorNorm += _deltaNorm[32 + i] * bitLow;
        errorInv += _deltaInv[32 + i] * bitLow;
      }

      int dist = errorNorm <= errorInv ? errorNorm : errorInv;
      bool inverted = errorNorm > errorInv;

      int insertIdx = _workFactor;
      for (int k = 0; k < _workFactor; k++) {
        int d = _topDistances[k];
        if (dist < d) {
          insertIdx = k;
          break;
        } else if (dist == d) {
          final topCandidate = _topCandidates[k];
          if (topCandidate == null) {
            insertIdx = k;
            break;
          }
          if (candidate.popcount < topCandidate.popcount) {
            insertIdx = k;
            break;
          } else if (candidate.popcount == topCandidate.popcount) {
            if (!inverted && _topInverted[k]) {
              insertIdx = k;
              break;
            } else if (inverted == _topInverted[k]) {
              if (candidate.codePoint < topCandidate.codePoint) {
                insertIdx = k;
                break;
              }
            }
          }
        }
      }

      if (insertIdx < _workFactor) {
        for (int j = _workFactor - 1; j > insertIdx; j--) {
          _topDistances[j] = _topDistances[j - 1];
          _topCandidates[j] = _topCandidates[j - 1];
          _topInverted[j] = _topInverted[j - 1];
        }
        _topDistances[insertIdx] = dist;
        _topCandidates[insertIdx] = candidate;
        _topInverted[insertIdx] = inverted;
      }
    }

    int bestError = -1;
    SymbolCandidate? bestCandidate;
    int bestFg = c2;
    int bestBg = c1;

    for (int k = 0; k < _workFactor; k++) {
      final candidate = _topCandidates[k];
      if (candidate == null) break;
      final invert = _topInverted[k];

      int cMaskHigh = candidate.bitmap >>> 32;
      int cMaskLow = candidate.bitmap & 0xFFFFFFFF;

      int highBits = invert ? (~cMaskHigh & 0xFFFFFFFF) : cMaskHigh;
      int lowBits = invert ? (~cMaskLow & 0xFFFFFFFF) : cMaskLow;

      int meanFg = c2;
      int meanBg = c1;

      if (useMedian) {
        List<int> pixelsFg = [];
        List<int> pixelsBg = [];

        for (int i = 0; i < 32; i++) {
          bool isFg = ((highBits >> (31 - i)) & 1) == 1;
          int p = pixelsRgb[i];
          if (isFg) {
            pixelsFg.add(p);
          } else {
            pixelsBg.add(p);
          }
        }
        for (int i = 0; i < 32; i++) {
          bool isFg = ((lowBits >> (31 - i)) & 1) == 1;
          int p = pixelsRgb[32 + i];
          if (isFg) {
            pixelsFg.add(p);
          } else {
            pixelsBg.add(p);
          }
        }

        int getMedian(List<int> pxs) {
          if (pxs.isEmpty) return 0;
          if (pxs.length == 1) return pxs[0];
          if (dominantChannel == 0) {
            pxs.sort((a, b) => ((a >> 16) & 0xFF).compareTo((b >> 16) & 0xFF));
          } else if (dominantChannel == 1) {
            pxs.sort((a, b) => ((a >> 8) & 0xFF).compareTo((b >> 8) & 0xFF));
          } else {
            pxs.sort((a, b) => (a & 0xFF).compareTo(b & 0xFF));
          }
          return pxs[pxs.length ~/ 2];
        }

        if (pixelsFg.isNotEmpty) {
          meanFg = getMedian(pixelsFg);
        }
        if (pixelsBg.isNotEmpty) {
          meanBg = getMedian(pixelsBg);
        }
      } else {
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

        if (countFg > 0) {
          meanFg =
              (0xFF << 24) |
              ((sumrFg ~/ countFg) << 16) |
              ((sumgFg ~/ countFg) << 8) |
              (sumbFg ~/ countFg);
        }

        if (countBg > 0) {
          meanBg =
              (0xFF << 24) |
              ((sumrBg ~/ countBg) << 16) |
              ((sumgBg ~/ countBg) << 8) |
              (sumbBg ~/ countBg);
        }
      }

      int meanFgDin = useDin99d
          ? ColorMath.rgbToDin99d(
              (meanFg >> 16) & 0xFF,
              (meanFg >> 8) & 0xFF,
              meanFg & 0xFF,
            )
          : 0;
      int meanBgDin = useDin99d
          ? ColorMath.rgbToDin99d(
              (meanBg >> 16) & 0xFF,
              (meanBg >> 8) & 0xFF,
              meanBg & 0xFF,
            )
          : 0;

      int error = 0;
      for (int i = 0; i < 32; i++) {
        bool isFg = ((highBits >> (31 - i)) & 1) == 1;
        if (useDin99d) {
          int targetDin = isFg ? meanFgDin : meanBgDin;
          error += ColorMath.distanceSqDin99d(_pixelsDin99d[i], targetDin);
        } else {
          int targetMean = isFg ? meanFg : meanBg;
          error += _distSqRgb(pixelsRgb[i], targetMean);
        }
      }
      for (int i = 0; i < 32; i++) {
        bool isFg = ((lowBits >> (31 - i)) & 1) == 1;
        if (useDin99d) {
          int targetDin = isFg ? meanFgDin : meanBgDin;
          error += ColorMath.distanceSqDin99d(_pixelsDin99d[32 + i], targetDin);
        } else {
          int targetMean = isFg ? meanFg : meanBg;
          error += _distSqRgb(pixelsRgb[32 + i], targetMean);
        }
      }

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
