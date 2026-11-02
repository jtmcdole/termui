import 'dart:typed_data';
import 'symbol_map.dart';
import 'color_math.dart';

final class QuantizeResult {
  String character = ' ';
  int fgColorArgb = 0;
  int bgColorArgb = 0;
}

final class CellQuantizer {
  final Int32List _pixelsDin99d = Int32List(64);
  final Int32List _deltaNorm = Int32List(64);
  final Int32List _pixelsFg = Int32List(64);
  final Int32List _pixelsBg = Int32List(64);
  final int workFactor;
  final List<SymbolCandidate?> _topCandidates;
  final Int32List _topDistances;
  final List<bool> _topInverted;

  CellQuantizer({this.workFactor = 5})
    : _topCandidates = List.filled(workFactor, null),
      _topDistances = Int32List(workFactor),
      _topInverted = List.filled(workFactor, false);

  void quantize(
    Uint32List pixelsRgb,
    List<SymbolCandidate> candidates,
    QuantizeResult result, {
    bool useDin99d = false,
    bool useMedian = false,
  }) {
    assert(pixelsRgb.length == 64);

    if (useDin99d) {
      _fillDin99dPixels(pixelsRgb);
    }

    final (dominantChannel, c1, c2) = _findDominantEndpoints(pixelsRgb);
    final (baseErrorNorm, baseErrorInv) = _precomputeDeltaErrors(
      pixelsRgb,
      c1,
      c2,
      useDin99d: useDin99d,
    );

    _selectTopCandidates(candidates, baseErrorNorm, baseErrorInv);
    _refineBestCluster(
      pixelsRgb,
      dominantChannel,
      c1,
      c2,
      result,
      useDin99d: useDin99d,
      useMedian: useMedian,
    );
  }

  void _fillDin99dPixels(Uint32List pixelsRgb) {
    for (var i = 0; i < 64; i++) {
      _pixelsDin99d[i] = _rgbToDin99d(pixelsRgb[i]);
    }
  }

  static int _rgbToDin99d(int argb) => ColorMath.rgbToDin99d(
    (argb >> 16) & 0xFF,
    (argb >> 8) & 0xFF,
    argb & 0xFF,
  );

  static (int, int, int) _channelExtrema(Uint32List pixelsRgb, int shift) {
    var minVal = 255;
    var maxVal = 0;
    var minIdx = 0;
    var maxIdx = 0;

    for (var i = 0; i < 64; i++) {
      final v = (pixelsRgb[i] >> shift) & 0xFF;
      if (v < minVal) {
        minVal = v;
        minIdx = i;
      }
      if (v >= maxVal) {
        maxVal = v;
        maxIdx = i;
      }
    }

    return (maxVal - minVal, minIdx, maxIdx);
  }

  static (int, int, int) _findDominantEndpoints(Uint32List pixelsRgb) {
    final (rangeR, minIdxR, maxIdxR) = _channelExtrema(pixelsRgb, 16);
    final (rangeG, minIdxG, maxIdxG) = _channelExtrema(pixelsRgb, 8);
    final (rangeB, minIdxB, maxIdxB) = _channelExtrema(pixelsRgb, 0);

    if (rangeR >= rangeG && rangeR >= rangeB) {
      return (0, pixelsRgb[minIdxR], pixelsRgb[maxIdxR]);
    }
    if (rangeG >= rangeR && rangeG >= rangeB) {
      return (1, pixelsRgb[minIdxG], pixelsRgb[maxIdxG]);
    }
    return (2, pixelsRgb[minIdxB], pixelsRgb[maxIdxB]);
  }

  (int, int) _precomputeDeltaErrors(
    Uint32List pixelsRgb,
    int c1,
    int c2, {
    required bool useDin99d,
  }) {
    final c1Din = useDin99d ? _rgbToDin99d(c1) : 0;
    final c2Din = useDin99d ? _rgbToDin99d(c2) : 0;

    var baseErrorNorm = 0;
    var baseErrorInv = 0;

    for (var i = 0; i < 64; i++) {
      final d1 = useDin99d
          ? ColorMath.distanceSqDin99d(_pixelsDin99d[i], c1Din)
          : _distSqRgb(pixelsRgb[i], c1);
      final d2 = useDin99d
          ? ColorMath.distanceSqDin99d(_pixelsDin99d[i], c2Din)
          : _distSqRgb(pixelsRgb[i], c2);

      baseErrorNorm += d2;
      _deltaNorm[i] = d1 - d2;
      baseErrorInv += d1;
    }

    return (baseErrorNorm, baseErrorInv);
  }

  void _selectTopCandidates(
    List<SymbolCandidate> candidates,
    int baseErrorNorm,
    int baseErrorInv,
  ) {
    _topDistances.fillRange(0, workFactor, 0x7FFFFFFF);
    _topCandidates.fillRange(0, workFactor, null);
    _topInverted.fillRange(0, workFactor, false);

    for (final candidate in candidates) {
      final deltaSum = _computeMaskDeltaSum(
        candidate.bitmapHigh,
        candidate.bitmapLow,
      );
      final errorNorm = baseErrorNorm + deltaSum;
      final errorInv = baseErrorInv - deltaSum;
      final inverted = errorNorm > errorInv;
      final dist = inverted ? errorInv : errorNorm;

      final insertIdx = _findInsertIndex(dist, candidate, inverted);
      if (insertIdx < workFactor) {
        _insertCandidateAt(insertIdx, dist, candidate, inverted);
      }
    }
  }

  int _computeMaskDeltaSum(int cMaskHigh, int cMaskLow) {
    var deltaSum = 0;
    for (var i = 0; i < 32; i++) {
      deltaSum += _deltaNorm[i] * ((cMaskHigh >> (31 - i)) & 1);
      deltaSum += _deltaNorm[32 + i] * ((cMaskLow >> (31 - i)) & 1);
    }
    return deltaSum;
  }

  int _findInsertIndex(int dist, SymbolCandidate candidate, bool inverted) {
    for (var k = 0; k < workFactor; k++) {
      if (_isBetterCandidate(dist, candidate, inverted, k)) {
        return k;
      }
    }
    return workFactor;
  }

  bool _isBetterCandidate(
    int dist,
    SymbolCandidate candidate,
    bool inverted,
    int slot,
  ) {
    final existingDist = _topDistances[slot];
    if (dist < existingDist) return true;
    if (dist > existingDist) return false;

    final topCandidate = _topCandidates[slot];
    if (topCandidate == null) return true;

    if (candidate.popcount != topCandidate.popcount) {
      return candidate.popcount < topCandidate.popcount;
    }
    if (inverted != _topInverted[slot]) {
      return !inverted;
    }
    return candidate.character.compareTo(topCandidate.character) < 0;
  }

  void _insertCandidateAt(
    int insertIdx,
    int dist,
    SymbolCandidate candidate,
    bool inverted,
  ) {
    for (var j = workFactor - 1; j > insertIdx; j--) {
      _topDistances[j] = _topDistances[j - 1];
      _topCandidates[j] = _topCandidates[j - 1];
      _topInverted[j] = _topInverted[j - 1];
    }
    _topDistances[insertIdx] = dist;
    _topCandidates[insertIdx] = candidate;
    _topInverted[insertIdx] = inverted;
  }

  void _refineBestCluster(
    Uint32List pixelsRgb,
    int dominantChannel,
    int c1,
    int c2,
    QuantizeResult result, {
    required bool useDin99d,
    required bool useMedian,
  }) {
    var bestError = -1;
    SymbolCandidate? bestCandidate;
    var bestFg = c2;
    var bestBg = c1;

    for (var k = 0; k < workFactor; k++) {
      final candidate = _topCandidates[k];
      if (candidate == null) break;

      final (error, fg, bg) = _evaluateCandidateCluster(
        pixelsRgb,
        candidate,
        _topInverted[k],
        dominantChannel,
        c1,
        c2,
        useDin99d: useDin99d,
        useMedian: useMedian,
      );

      if (bestError == -1 || error < bestError) {
        bestError = error;
        bestCandidate = candidate;
        bestFg = fg;
        bestBg = bg;
      }
    }

    result.character = bestCandidate?.character ?? ' ';
    result.fgColorArgb = bestFg;
    result.bgColorArgb = bestBg;
  }

  (int, int, int) _evaluateCandidateCluster(
    Uint32List pixelsRgb,
    SymbolCandidate candidate,
    bool invert,
    int dominantChannel,
    int c1,
    int c2, {
    required bool useDin99d,
    required bool useMedian,
  }) {
    final highBits = invert
        ? (~candidate.bitmapHigh & 0xFFFFFFFF)
        : candidate.bitmapHigh;
    final lowBits = invert
        ? (~candidate.bitmapLow & 0xFFFFFFFF)
        : candidate.bitmapLow;

    final (meanFg, meanBg) = useMedian
        ? _computeMedianClusters(pixelsRgb, highBits, lowBits, dominantChannel)
        : _computeMeanClusters(pixelsRgb, highBits, lowBits, c2, c1);

    final error = _computeClusterError(
      pixelsRgb,
      highBits,
      lowBits,
      meanFg,
      meanBg,
      useDin99d: useDin99d,
    );

    final fg = invert ? meanBg : meanFg;
    final bg = invert ? meanFg : meanBg;
    return (error, fg, bg);
  }

  (int, int) _computeMedianClusters(
    Uint32List pixelsRgb,
    int highBits,
    int lowBits,
    int dominantChannel,
  ) {
    var fgCount = 0;
    var bgCount = 0;

    for (var i = 0; i < 64; i++) {
      final p = pixelsRgb[i];
      if (_isMaskBitSet(highBits, lowBits, i)) {
        _pixelsFg[fgCount++] = p;
      } else {
        _pixelsBg[bgCount++] = p;
      }
    }

    final shift = (2 - dominantChannel) * 8;
    return (
      _medianByChannel(_pixelsFg, fgCount, shift),
      _medianByChannel(_pixelsBg, bgCount, shift),
    );
  }

  static int _medianByChannel(Int32List pxs, int count, int shift) {
    if (count == 0) return 0;
    if (count == 1) return pxs[0];

    for (var i = 1; i < count; i++) {
      final key = pxs[i];
      final keyVal = (key >> shift) & 0xFF;
      var j = i - 1;
      while (j >= 0 && ((pxs[j] >> shift) & 0xFF) > keyVal) {
        pxs[j + 1] = pxs[j];
        j--;
      }
      pxs[j + 1] = key;
    }
    return pxs[count ~/ 2];
  }

  static (int, int) _computeMeanClusters(
    Uint32List pixelsRgb,
    int highBits,
    int lowBits,
    int defaultFg,
    int defaultBg,
  ) {
    var sumrFg = 0, sumgFg = 0, sumbFg = 0, countFg = 0;
    var sumrBg = 0, sumgBg = 0, sumbBg = 0, countBg = 0;

    for (var i = 0; i < 64; i++) {
      final p = pixelsRgb[i];
      final r = (p >> 16) & 0xFF;
      final g = (p >> 8) & 0xFF;
      final b = p & 0xFF;
      if (_isMaskBitSet(highBits, lowBits, i)) {
        sumrFg += r;
        sumgFg += g;
        sumbFg += b;
        countFg++;
      } else {
        sumrBg += r;
        sumgBg += g;
        sumbBg += b;
        countBg++;
      }
    }

    final meanFg = countFg > 0
        ? _packMeanArgb(sumrFg, sumgFg, sumbFg, countFg)
        : defaultFg;
    final meanBg = countBg > 0
        ? _packMeanArgb(sumrBg, sumgBg, sumbBg, countBg)
        : defaultBg;
    return (meanFg, meanBg);
  }

  static int _packMeanArgb(int sumR, int sumG, int sumB, int count) =>
      (0xFF << 24) |
      ((sumR ~/ count) << 16) |
      ((sumG ~/ count) << 8) |
      (sumB ~/ count);

  int _computeClusterError(
    Uint32List pixelsRgb,
    int highBits,
    int lowBits,
    int meanFg,
    int meanBg, {
    required bool useDin99d,
  }) {
    if (useDin99d) {
      final meanFgDin = _rgbToDin99d(meanFg);
      final meanBgDin = _rgbToDin99d(meanBg);
      var error = 0;
      for (var i = 0; i < 64; i++) {
        final targetDin = _isMaskBitSet(highBits, lowBits, i)
            ? meanFgDin
            : meanBgDin;
        error += ColorMath.distanceSqDin99d(_pixelsDin99d[i], targetDin);
      }
      return error;
    }

    var error = 0;
    for (var i = 0; i < 64; i++) {
      final targetMean = _isMaskBitSet(highBits, lowBits, i) ? meanFg : meanBg;
      error += _distSqRgb(pixelsRgb[i], targetMean);
    }
    return error;
  }

  static bool _isMaskBitSet(int highBits, int lowBits, int index) {
    final word = index < 32 ? highBits : lowBits;
    final bitOffset = 31 - (index & 31);
    return ((word >> bitOffset) & 1) == 1;
  }

  static int _distSqRgb(int p1, int p2) {
    int dr = ((p1 >> 16) & 0xFF) - ((p2 >> 16) & 0xFF);
    int dg = ((p1 >> 8) & 0xFF) - ((p2 >> 8) & 0xFF);
    int db = (p1 & 0xFF) - (p2 & 0xFF);
    return dr * dr + dg * dg + db * db;
  }
}
