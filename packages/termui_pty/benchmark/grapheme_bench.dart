import 'package:benchmark_harness/benchmark_harness.dart';

bool isWideGraphemeString(String grapheme) {
  if (grapheme.isEmpty) return false;
  if (grapheme.codeUnitAt(0) < 128) return false;
  final codePoint = grapheme.runes.first;
  return codePoint >= 0x1100 &&
      (codePoint <= 0x115f ||
          codePoint == 0x2329 ||
          codePoint == 0x232a ||
          (codePoint >= 0x2e80 && codePoint <= 0xa4cf && codePoint != 0x303f) ||
          (codePoint >= 0xac00 && codePoint <= 0xd7a3) ||
          (codePoint >= 0xf900 && codePoint <= 0xfaff) ||
          (codePoint >= 0xfe10 && codePoint <= 0xfe19) ||
          (codePoint >= 0xfe30 && codePoint <= 0xfe6f) ||
          (codePoint >= 0xff00 && codePoint <= 0xff60) ||
          (codePoint >= 0xffe0 && codePoint <= 0xffe6) ||
          (codePoint >= 0x20000 && codePoint <= 0x2fffd) ||
          (codePoint >= 0x30000 && codePoint <= 0x3fffd));
}

bool isWideGraphemeInt(int codePoint) {
  if (codePoint < 128) return false;
  return codePoint >= 0x1100 &&
      (codePoint <= 0x115f ||
          codePoint == 0x2329 ||
          codePoint == 0x232a ||
          (codePoint >= 0x2e80 && codePoint <= 0xa4cf && codePoint != 0x303f) ||
          (codePoint >= 0xac00 && codePoint <= 0xd7a3) ||
          (codePoint >= 0xf900 && codePoint <= 0xfaff) ||
          (codePoint >= 0xfe10 && codePoint <= 0xfe19) ||
          (codePoint >= 0xfe30 && codePoint <= 0xfe6f) ||
          (codePoint >= 0xff00 && codePoint <= 0xff60) ||
          (codePoint >= 0xffe0 && codePoint <= 0xffe6) ||
          (codePoint >= 0x20000 && codePoint <= 0x2fffd) ||
          (codePoint >= 0x30000 && codePoint <= 0x3fffd));
}

class StringBench extends BenchmarkBase {
  final String text =
      "Hello World! This is a test string to see if the wide grapheme check is slow when using strings. " *
      100;
  StringBench() : super("StringBench");
  @override
  void run() {
    for (var i = 0; i < text.length; i++) {
      isWideGraphemeString(text[i]);
    }
  }
}

class IntBench extends BenchmarkBase {
  final String text =
      "Hello World! This is a test string to see if the wide grapheme check is slow when using strings. " *
      100;
  IntBench() : super("IntBench");
  @override
  void run() {
    for (var i = 0; i < text.length; i++) {
      isWideGraphemeInt(text.codeUnitAt(i));
    }
  }
}

void main() {
  StringBench().report();
  IntBench().report();
}
