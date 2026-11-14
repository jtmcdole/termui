import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:termui/termui.dart';

int _clampInt(int v, int lo, int hi) => v < lo ? lo : (v > hi ? hi : v);
int _toByte(double v) => v <= 0.0 ? 0 : (v >= 255.0 ? 255 : v.round());
double _clamp01(double v) => v.isFinite ? v.clamp(0.0, 1.0) : 0.0;
int _validId(int id) => (id & 0xFFFFFFFF) == 0 ? 1 : (id & 0xFFFFFFFF);
HsvColor _sanitize(HsvColor c) =>
    HsvColor(_normHue(c.hue), _clamp01(c.saturation), _clamp01(c.value));
int _mixWheel(int bg, int fg1, int vb, int a) =>
    (((fg1 * vb + 127) ~/ 255) * a + bg * (255 - a) + 127) ~/ 255;

double _normHue(double hue) {
  if (!hue.isFinite) return 0.0;
  final w = hue % 360.0;
  final p = w < 0.0 ? w + 360.0 : w;
  return p == 0.0 || p >= 360.0 ? 0.0 : p;
}

(int, int, int) _hsvToRgb(double hue, double sat, double val) {
  final (h60, s, v) = (_normHue(hue) / 60.0, _clamp01(sat), _clamp01(val));
  int ch(int n) {
    final k = (n + h60) % 6.0;
    return _toByte((v - v * s * max(0.0, min(k, min(4.0 - k, 1.0)))) * 255.0);
  }

  return (ch(5), ch(3), ch(1));
}

(double, double) _cellPx((double width, double height) raw) => (
  raw.$1 > 0 && raw.$1.isFinite ? raw.$1 : 8.0,
  raw.$2 > 0 && raw.$2.isFinite ? raw.$2 : 16.0,
);

/// Immutable HSV color with [hue] in `[0, 360)`, [saturation] in `0..1`,
/// and [value] in `0..1`.
final class HsvColor {
  /// Hue angle in degrees (`0.0 <= hue < 360.0`).
  final double hue;

  /// Saturation component (`0.0 .. 1.0`).
  final double saturation;

  /// Value (brightness) component (`0.0 .. 1.0`).
  final double value;

  /// Creates an [HsvColor] value.
  const HsvColor(this.hue, this.saturation, this.value);

  /// Converts an RGB [Color] to [HsvColor], preserving [fallbackHue] and
  /// [fallbackSaturation] when `V == 0`, or [fallbackHue] when `S == 0`.
  factory HsvColor.fromColor(
    Color color, {
    double fallbackHue = 0,
    double fallbackSaturation = 0,
  }) {
    final (r, g, b) = (color.r / 255.0, color.g / 255.0, color.b / 255.0);
    final cMax = max(r, max(g, b));
    final d = cMax - min(r, min(g, b));
    final fh = _normHue(fallbackHue);
    if (cMax <= 0.0) return HsvColor(fh, _clamp01(fallbackSaturation), 0.0);
    if (d <= 0.0) return HsvColor(fh, 0.0, cMax);
    final sector = cMax == r
        ? ((g - b) / d) % 6.0
        : (cMax == g ? (b - r) / d + 2.0 : (r - g) / d + 4.0);
    return HsvColor(_normHue(60.0 * sector), (d / cMax).clamp(0.0, 1.0), cMax);
  }

  /// Converts this HSV color to an opaque 24-bit RGB [Color].
  Color toColor() {
    final (r, g, b) = _hsvToRgb(hue, saturation, value);
    return Color(r, g, b);
  }

  @override
  bool operator ==(Object other) =>
      other is HsvColor &&
      other.hue == hue &&
      other.saturation == saturation &&
      other.value == value;

  @override
  int get hashCode => Object.hash(hue, saturation, value);

  @override
  String toString() => 'HsvColor($hue, $saturation, $value)';
}

enum _DragTarget { wheel, valueBar }

final class _WheelLayout {
  final int w, h;
  late final int barW = min(max(4, (w * 0.14).round()), max(1, w ~/ 3));
  late final int rem = max(1, w - barW);
  late final int gapW = w < 16 ? 0 : _clampInt((w * 0.06).round(), 1, rem ~/ 4);
  late final int wheelW = max(1, rem - gapW);
  late final int barL = wheelW + gapW;
  int get barR => min(w, max(barL + 1, w - (w > 31 && barW > 5 ? 1 : 0)));
  late final double pad = (min(wheelW, h) * 0.05).clamp(1.0, 4.0);
  late final double r = max(1.0, (min(wheelW, h) - 2.0 * pad) * 0.5);
  late final int barT = _clampInt((cy - r).floor(), 0, max(0, h - 2));
  late final int barB = _clampInt((cy + r).ceil(), barT + 1, h);
  int get barSpan => max(1, barB - 1 - barT);
  double get cx => wheelW * 0.5;
  double get cy => h * 0.5;
  double get barU => (wheelW + gapW * 0.5) / w;
  _WheelLayout(this.w, this.h);

  factory _WheelLayout.fromCells(int cols, int rows, double cw, double ch) {
    final (pw, ph) = (cols * cw, rows * ch);
    final s = max(pw, ph) > 256.0 ? 256.0 / max(pw, ph) : 1.0;
    int c2(double v) => _clampInt((v * s).round(), 2, 256);
    return _WheelLayout(c2(pw), c2(ph));
  }

  void paintBar(Uint8List px, (int, int, int) barRgb, bool dark, int tickY) {
    final (br, bg, bb) = barRgb;
    final core = dark ? 0 : 255;
    for (var py = barT; py < barB; py++) {
      final dist = (py - tickY).abs();
      final bv = (1.0 - (py - barT) / barSpan).clamp(0.0, 1.0);
      final c = dist == 0 ? core : 255 - core;
      final (r, g, b) = dist <= 1
          ? (c, c, c)
          : (_toByte(br * bv), _toByte(bg * bv), _toByte(bb * bv));
      for (var x = barL, i = (py * w + x) * 4; x < barR; x++, i += 4) {
        px[i] = r;
        px[i + 1] = g;
        px[i + 2] = b;
      }
    }
  }

  void paintReticle(Uint8List px, int cx, int cy) {
    final scale = (r / 24.0).clamp(0.45, 1.0);
    final (rOut, rIn) = (5.2 * scale, 3.4 * scale);
    final bound = rOut.ceil() + 2;
    final (x0, x1) = (max(0, cx - bound), min(wheelW - 1, cx + bound));
    final (y0, y1) = (max(0, cy - bound), min(h - 1, cy + bound));
    for (var py = y0; py <= y1; py++) {
      final dy2 = (py - cy) * (py - cy);
      for (var x = x0, i = (py * w + x0) * 4; x <= x1; x++, i += 4) {
        final d2 = ((x - cx) * (x - cx) + dy2).toDouble();
        for (final (rad, c) in [(rOut, 0), (rIn, 255)]) {
          final a = _clamp01(1.0 - (d2 - rad * rad).abs() / (2.2 * rad));
          if (a <= 0.0) continue;
          final inv = 1.0 - a;
          px[i] = _toByte(px[i] * inv + c * a);
          px[i + 1] = _toByte(px[i + 1] * inv + c * a);
          px[i + 2] = _toByte(px[i + 2] * inv + c * a);
        }
      }
    }
  }
}

final Map<(int, int), Uint8List> _lutCache = {};

Uint8List _polarLut(_WheelLayout l) {
  final key = (l.w, l.h);
  if (_lutCache[key] case final cached?) return cached;
  if (_lutCache.length >= 4) _lutCache.remove(_lutCache.keys.first);
  final lut = Uint8List(l.wheelW * l.h * 4);
  for (var py = 0, i = 0; py < l.h; py++) {
    final dy = py + 0.5 - l.cy;
    for (var px = 0; px < l.wheelW; px++, i += 4) {
      final dx = px + 0.5 - l.cx;
      final dist = sqrt(dx * dx + dy * dy);
      final a = ((l.r + 0.75 - dist) / 1.5).clamp(0.0, 1.0);
      if (a <= 0.0) continue;
      final hue = dist > 1e-6 ? _normHue(atan2(-dy, dx) * 180.0 / pi) : 0.0;
      final (r, g, b) = _hsvToRgb(hue, (dist / l.r).clamp(0.0, 1.0), 1.0);
      lut[i] = r;
      lut[i + 1] = g;
      lut[i + 2] = b;
      lut[i + 3] = _toByte(a * 255.0);
    }
  }
  return _lutCache[key] = lut;
}

/// Pure-Dart `termui` widget rendering a unified Kitty Graphics (`U+10EEEE`)
/// HSV color wheel and brightness bar with sub-cell pixel-mouse picking.
final class HsvColorWheelPicker extends StatefulWidget {
  /// Active HSV color reflected by the wheel reticle and brightness tick.
  final HsvColor hsvColor;

  /// Logical pixel size of one terminal cell `(width, height)`.
  final (double width, double height) cellPixelSize;

  /// Opaque resolved 24-bit RGB background color (must not be ANSI-indexed).
  final Color panelBackgroundColor;

  /// Invoked when clicking or dragging updates the active [HsvColor].
  final void Function(HsvColor color) onChanged;

  /// Unique 32-bit Kitty Graphics image identifier registered globally.
  final int imageId;

  /// Optional explicit column count; defaults to incoming layout constraints.
  final int? columns;

  /// Optional explicit row count; defaults to incoming layout constraints.
  final int? rows;

  /// Creates an [HsvColorWheelPicker].
  const HsvColorWheelPicker({
    super.key,
    required this.hsvColor,
    required this.cellPixelSize,
    required this.panelBackgroundColor,
    required this.onChanged,
    this.imageId = 0x00F41E77,
    this.columns,
    this.rows,
  });

  @override
  State<HsvColorWheelPicker> createState() => _HsvColorWheelPickerState();
}

final class _HsvColorWheelPickerState extends State<HsvColorWheelPicker>
    implements MouseEventHandlerWithArea {
  late HsvColor _workingHsv = _sanitize(widget.hsvColor);
  _DragTarget? _dragTarget;
  int _originCol0 = 0, _originRow0 = 0, _imageVersion = -1;
  Object? _baseKey, _snapshotKey;
  Uint8List? _basePixels, _snapshotPixels;

  bool get _measuring => Zone.current[#isMeasuringIntrinsics] == true;

  @override
  void didUpdateWidget(HsvColorWheelPicker oldWidget) {
    super.didUpdateWidget(oldWidget);
    final oldId = _validId(oldWidget.imageId);
    if (oldId != _validId(widget.imageId) && !_measuring) {
      KittyImageRegistry.unregister(oldId);
    }
    if (widget.hsvColor == oldWidget.hsvColor) return;
    final next = _sanitize(widget.hsvColor);
    if (_dragTarget == null || next.toColor() != _workingHsv.toColor()) {
      _dragTarget = null;
      _workingHsv = next;
    }
  }

  @override
  void dispose() {
    if (!_measuring) KittyImageRegistry.unregister(_validId(widget.imageId));
    super.dispose();
  }

  void _finishRelease() {
    _dragTarget = null;
    final ext = _sanitize(widget.hsvColor);
    if (ext.toColor() != _workingHsv.toColor() && mounted) {
      setState(() => _workingHsv = ext);
    }
  }

  @override
  void handleMouseEvent(MouseEvent event, int localX, int localY, Rect area) {
    if (event.type == .release) {
      _finishRelease();
      return;
    }
    final isPress = event.type == .press;
    if (min(area.width, area.height) <= 0 ||
        !_acceptPointer(event, localX, localY, isPress)) {
      return;
    }
    final (cw, ch) = _cellPx(widget.cellPixelSize);
    final (px, py) = (event.pixelX, event.pixelY);
    final hasPx = px != null && py != null;
    final rawU = hasPx
        ? (px - 0.5 - _originCol0 * cw) / (area.width * cw)
        : (localX + 0.5) / area.width;
    final rawV = hasPx
        ? (py - 0.5 - _originRow0 * ch) / (area.height * ch)
        : (localY + 0.5) / area.height;
    final layout = _WheelLayout.fromCells(area.width, area.height, cw, ch);
    if (isPress) _dragTarget = rawU >= layout.barU ? .valueBar : .wheel;
    final nextHsv = _sampleHsv(layout, rawU, rawV, isPress);
    if (nextHsv == _workingHsv) return;
    _workingHsv = nextHsv;
    if (mounted) setState(() {});
    widget.onChanged(nextHsv);
  }

  bool _acceptPointer(MouseEvent event, int localX, int localY, bool isPress) {
    if (isPress) {
      if (event.button != .left) return false;
      _originCol0 = ((event.globalX ?? event.x) - 1) - localX;
      _originRow0 = ((event.globalY ?? event.y) - 1) - localY;
      return true;
    }
    return event.type == .drag &&
        _dragTarget != null &&
        (event.button == .left || event.button == .none);
  }

  HsvColor _sampleHsv(_WheelLayout l, double rawU, double rawV, bool isPress) {
    final c = _workingHsv;
    if (_dragTarget == .valueBar) {
      final v = _clamp01(1.0 - (rawV * l.h - (l.barT + 0.5)) / l.barSpan);
      return HsvColor(c.hue, c.saturation, v);
    }
    final (dx, dy) = (rawU * l.w - l.cx, rawV * l.h - l.cy);
    final dist = sqrt(dx * dx + dy * dy);
    final hue = dist > 1e-6 ? _normHue(atan2(-dy, dx) * 180.0 / pi) : c.hue;
    final val = isPress && c.value < 0.05 ? 1.0 : c.value;
    return HsvColor(hue, (dist / l.r).clamp(0.0, 1.0), val);
  }

  (Uint8List, int) _ensureSnapshot(_WheelLayout l) {
    final bg = widget.panelBackgroundColor;
    assert(!bg.isAnsiIndexed);
    final c = _workingHsv;
    final rad = c.hue * pi / 180.0;
    final satR = c.saturation * l.r;
    final rx = _clampInt((l.cx + satR * cos(rad)).round(), 0, l.wheelW - 1);
    final ry = _clampInt((l.cy - satR * sin(rad)).round(), 0, l.h - 1);
    final tickY = (l.barT + (1.0 - c.value) * l.barSpan).round();
    final vByte = _toByte(max(c.value, 0.25) * 255.0);
    final barRgb = _hsvToRgb(c.hue, c.saturation, 1.0);
    final darkTick = c.value > 0.5;
    final key = (l.w, l.h, bg.argb, vByte, barRgb, darkTick, rx, ry, tickY);
    if (_snapshotKey == key && _snapshotPixels != null) {
      return (_snapshotPixels!, _imageVersion);
    }
    final snap = Uint8List.fromList(_ensureBaseWheel(l, bg, vByte));
    l.paintBar(snap, barRgb, darkTick, tickY);
    l.paintReticle(snap, rx, ry);
    _snapshotKey = key;
    return (_snapshotPixels = snap, ++_imageVersion);
  }

  Uint8List _ensureBaseWheel(_WheelLayout l, Color bg, int vByte) {
    final key = (l.w, l.h, bg.argb, vByte);
    if (_baseKey == key && _basePixels != null) return _basePixels!;
    final lut = _polarLut(l);
    final pixels = Uint8List(l.w * l.h * 4);
    final (bgr, bgg, bgb) = (bg.r, bg.g, bg.b);
    for (var py = 0, li = 0, oi = 0; py < l.h; py++) {
      for (var x = 0; x < l.w; x++, oi += 4) {
        int r = bgr, g = bgg, b = bgb;
        if (x < l.wheelW) {
          final a = lut[li + 3];
          if (a > 0) {
            r = _mixWheel(bgr, lut[li], vByte, a);
            g = _mixWheel(bgg, lut[li + 1], vByte, a);
            b = _mixWheel(bgb, lut[li + 2], vByte, a);
          }
          li += 4;
        }
        pixels[oi] = r;
        pixels[oi + 1] = g;
        pixels[oi + 2] = b;
        pixels[oi + 3] = 255;
      }
    }
    _baseKey = key;
    return _basePixels = pixels;
  }

  @override
  Widget build(BuildContext context) {
    final (cw, ch) = _cellPx(widget.cellPixelSize);
    return LayoutBuilder(
      builder: (context, c) {
        final wMax = c.hasBoundedWidth ? c.maxWidth : max(c.minWidth, 24);
        final hMax = c.hasBoundedHeight ? c.maxHeight : max(c.minHeight, 10);
        final sz = c.constrain(
          Size(max(1, widget.columns ?? wMax), max(1, widget.rows ?? hMax)),
        );
        final cols = _clampInt(sz.width, 1, kittyDiacritics.length);
        final rows = _clampInt(sz.height, 1, kittyDiacritics.length);
        final l = _WheelLayout.fromCells(cols, rows, cw, ch);
        final snap = _measuring ? (Uint8List(0), 0) : _ensureSnapshot(l);
        return KittyImage(
          imageId: _validId(widget.imageId),
          pixelWidth: l.w,
          pixelHeight: l.h,
          rgbaPixels: snap.$1,
          columns: cols,
          rows: rows,
          version: snap.$2,
        );
      },
    );
  }
}
