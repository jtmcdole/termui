import "package:termui/termui.dart";
// ignore_for_file: public_member_api_docs

Color hslToRgb(double h, double s, double l) {
  double c = (1 - (2 * l - 1).abs()) * s;
  double x = c * (1 - ((h / 60.0) % 2.0 - 1).abs());
  double m = l - c / 2.0;
  double r = 0, g = 0, b = 0;
  if (h >= 0 && h < 60) {
    r = c;
    g = x;
    b = 0;
  } else if (h >= 60 && h < 120) {
    r = x;
    g = c;
    b = 0;
  } else if (h >= 120 && h < 180) {
    r = 0;
    g = c;
    b = x;
  } else if (h >= 180 && h < 240) {
    r = 0;
    g = x;
    b = c;
  } else if (h >= 240 && h < 300) {
    r = x;
    g = 0;
    b = c;
  } else if (h >= 300 && h < 360) {
    r = c;
    g = 0;
    b = x;
  }
  return Color(
    ((r + m) * 255).round(),
    ((g + m) * 255).round(),
    ((b + m) * 255).round(),
  );
}

final Map<String, Style> _categoryStyleCache = {};

Style getCategoryStyle(String category, String name) {
  return _categoryStyleCache.putIfAbsent(name, () {
    int h = fnv1aHash(name).abs() % 360;
    return Style(foreground: hslToRgb(h.toDouble(), 0.75, 0.60));
  });
}

int fnv1aHash(String string) {
  int hash = 0x811c9dc5;
  for (int i = 0; i < string.length; i++) {
    hash ^= string.codeUnitAt(i);
    hash = (hash * 0x01000193) & 0xFFFFFFFF;
  }
  return hash;
}
