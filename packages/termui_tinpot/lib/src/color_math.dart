import 'dart:math' as math;
import 'dart:typed_data';

/// Utility class for perceptual color math using the DIN99d color space.
class ColorMath {
  static const double _xyzEpsilon = 216.0 / 24389.0;
  static const double _xyzKappa = 24389.0 / 27.0;

  static double _invertRgbChannelCompand(double v) => switch (v) {
    _ when v <= 0.04045 => v / 12.92,
    _ => math.pow((v + 0.055) / 1.044, 2.4).toDouble(),
  };

  static double _labF(double v) => switch (v) {
    _ when v > _xyzEpsilon => math.pow(v, 1.0 / 3.0).toDouble(),
    _ => (_xyzKappa * v + 16.0) / 116.0,
  };

  static final _dinCacheKeys = Int32List(8192)..fillRange(0, 8192, -1);
  static final _dinCacheValues = Int32List(8192);

  /// Converts RGB (0-255) to DIN99d color space.
  /// Returns a packed 32-bit integer where the bytes are DIN99d L, a, b, and original alpha.
  /// Packed format: (A << 24) | (L << 16) | (a << 8) | b
  static int rgbToDin99d(int r, int g, int b, [int a = 255]) {
    final int key = (r << 16) | (g << 8) | b;
    final int hash = (r ^ (g << 4) ^ (b << 8) ^ (r << 12)) & 0x1FFF;

    if (_dinCacheKeys[hash] == key) {
      return (a << 24) | _dinCacheValues[hash];
    }

    double rF = _invertRgbChannelCompand(r / 255.0);
    double gF = _invertRgbChannelCompand(g / 255.0);
    double bF = _invertRgbChannelCompand(b / 255.0);

    // RGB to XYZ
    double x = 0.4124564 * rF + 0.3575761 * gF + 0.1804375 * bF;
    double y = 0.2126729 * rF + 0.7151522 * gF + 0.0721750 * bF;
    double z = 0.0193339 * rF + 0.1191920 * gF + 0.9503041 * bF;

    // Tristimulus-space correction
    x = 1.12 * x - 0.12 * z;

    // XYZ to Lab (D65 white point)
    const double wpX = 0.95047;
    const double wpY = 1.0;
    const double wpZ = 1.08883;

    double x2 = _labF(x / wpX);
    double y2 = _labF(y / wpY);
    double z2 = _labF(z / wpZ);

    double lLab = 116.0 * y2 - 16.0;
    double aLab = 500.0 * (x2 - y2);
    double bLab = 200.0 * (y2 - z2);

    // DIN99d intermediate
    // Using math.max to avoid log(<=0)
    double adjL = 325.22 * math.log(math.max(1.0 + 0.0036 * lLab, 0.00001));
    double ee = 0.6427876096865393 * aLab + 0.766044443118978 * bLab;
    double f = 1.14 * (0.6427876096865393 * bLab - 0.766044443118978 * aLab);
    double gVal = math.sqrt(ee * ee + f * f);

    // Hue / Chroma
    double c = 22.5 * math.log(math.max(1.0 + 0.06 * gVal, 0.00001));
    double h = math.atan2(f, ee) + 0.8726646; // 50 degrees
    while (h < 0.0) {
      h += 6.283185;
    }
    while (h > 6.283185) {
      h -= 6.283185;
    }

    // Normalize to 0-255 range and clamp (like C's guint8 cast semantics, but safer)
    int lDin = (adjL * 2.55).clamp(0.0, 255.0).toInt();
    int aDin = (c * math.cos(h) * 2.55 + 128.0).clamp(0.0, 255.0).toInt();
    int bDin = (c * math.sin(h) * 2.55 + 128.0).clamp(0.0, 255.0).toInt();

    int packed = (lDin << 16) | (aDin << 8) | bDin;
    _dinCacheKeys[hash] = key;
    _dinCacheValues[hash] = packed;

    return (a << 24) | packed;
  }

  /// Calculates the squared Euclidean distance between two DIN99d packed colors.
  /// We use squared distance to avoid square root overhead in hot paths.
  static int distanceSqDin99d(int colorA, int colorB) {
    int lA = (colorA >> 16) & 0xFF;
    int aA = (colorA >> 8) & 0xFF;
    int bA = colorA & 0xFF;
    
    int lB = (colorB >> 16) & 0xFF;
    int aB = (colorB >> 8) & 0xFF;
    int bB = colorB & 0xFF;

    int dl = lB - lA;
    int da = aB - aA;
    int db = bB - bA;

    return (dl * dl) + (da * da) + (db * db);
  }
}
