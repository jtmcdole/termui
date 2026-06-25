import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:termui/termui.dart';

// Copy current isWideGrapheme implementation for baseline test
bool _isWideGraphemeBaseline(String grapheme) {
  if (grapheme.isEmpty) return false;
  final codePoint = grapheme.runes.first;

  if (codePoint >= 0x4E00 && codePoint <= 0x9FFF) return true;
  if (codePoint >= 0x3400 && codePoint <= 0x4DBF) return true;
  if (codePoint >= 0xAC00 && codePoint <= 0xD7AF) return true;
  if (codePoint >= 0x3000 && codePoint <= 0x31FF) return true;
  if (codePoint >= 0xFF01 && codePoint <= 0xFF60) return true;
  if (codePoint >= 0xFFE0 && codePoint <= 0xFFE6) return true;
  if (codePoint >= 0x1F300 && codePoint <= 0x1F9FF) return true;
  if (codePoint >= 0x1FA00 && codePoint <= 0x1FAFF) return true;
  if (codePoint >= 0x20000 && codePoint <= 0x2EBEF) return true;
  if (codePoint >= 0xF900 && codePoint <= 0xFAFF) return true;
  if (codePoint >= 0x1100 && codePoint <= 0x11FF) return true;
  if (codePoint >= 0x2E80 && codePoint <= 0x2FFF) return true;
  if (codePoint >= 0x1F000 && codePoint <= 0x1F2FF) return true;

  return false;
}

// Optimized version with ASCII fast-path
bool _isWideGraphemeOptimized(String grapheme) {
  if (grapheme.isEmpty) return false;
  if (grapheme.codeUnitAt(0) < 128) return false;
  final codePoint = grapheme.runes.first;

  if (codePoint >= 0x4E00 && codePoint <= 0x9FFF) return true;
  if (codePoint >= 0x3400 && codePoint <= 0x4DBF) return true;
  if (codePoint >= 0xAC00 && codePoint <= 0xD7AF) return true;
  if (codePoint >= 0x3000 && codePoint <= 0x31FF) return true;
  if (codePoint >= 0xFF01 && codePoint <= 0xFF60) return true;
  if (codePoint >= 0xFFE0 && codePoint <= 0xFFE6) return true;
  if (codePoint >= 0x1F300 && codePoint <= 0x1F9FF) return true;
  if (codePoint >= 0x1FA00 && codePoint <= 0x1FAFF) return true;
  if (codePoint >= 0x20000 && codePoint <= 0x2EBEF) return true;
  if (codePoint >= 0xF900 && codePoint <= 0xFAFF) return true;
  if (codePoint >= 0x1100 && codePoint <= 0x11FF) return true;
  if (codePoint >= 0x2E80 && codePoint <= 0x2FFF) return true;
  if (codePoint >= 0x1F000 && codePoint <= 0x1F2FF) return true;

  return false;
}

// Dummy helper for baseline transitions using Style objects
Style _dummyWriteStyleTransition(Style current, Style target) {
  if (current == target) return current;
  if (target == Style.empty) return Style.empty;
  return target;
}

// Dummy helper for primitive transitions using ints
void _dummyWriteStyleTransitionPrims(
  int currentFg,
  int currentBg,
  int currentMod,
  int targetFg,
  int targetBg,
  int targetMod,
) {
  if (currentFg == targetFg &&
      currentBg == targetBg &&
      currentMod == targetMod) {
    return;
  }
  // Simulate extraction/math
  if (targetFg != currentFg && targetFg != 0) {
    final int r = (targetFg >> 16) & 0xFF;
    final int g = (targetFg >> 8) & 0xFF;
    final int b = targetFg & 0xFF;
    final int sum = r + g + b;
    if (sum < 0) {
      print('impossible');
    }
  }
}

@pragma('vm:never-inline')
void _escapeUint32List(Uint32List list) {
  if (list.isEmpty) {
    print('empty');
  }
}

void main() {
  group('Performance Benchmarks', () {
    test('1. Style Transitions: Object vs Primitive', () {
      // Warm up style transitions to ensure JIT compiler optimizes both paths
      Style activeStyleWarm = Style.empty;
      int curFgWarm = 0, curBgWarm = 0, curModWarm = 0;
      for (var f = 0; f < 500; f++) {
        for (var c = 0; c < 4800; c++) {
          final fg = c % 2 == 0 ? 0xFF00FF00 : 0;
          final bg = c % 3 == 0 ? 0xFFFF0000 : 0;
          final mod = c % 5 == 0 ? 1 : 0;

          final cellStyle = Style(
            foreground: fg != 0 ? Color.argb(fg) : null,
            background: bg != 0 ? Color.argb(bg) : null,
            modifiers: mod,
          );
          activeStyleWarm = _dummyWriteStyleTransition(
            activeStyleWarm,
            cellStyle,
          );
          _dummyWriteStyleTransitionPrims(
            curFgWarm,
            curBgWarm,
            curModWarm,
            fg,
            bg,
            mod,
          );
          curFgWarm = fg;
          curBgWarm = bg;
          curModWarm = mod;
        }
      }

      int minObjectMs = 9999999;
      int minObjectUs = 999999999;
      for (var run = 0; run < 3; run++) {
        final swObject = Stopwatch()..start();
        Style activeStyle = Style.empty;
        // 1,000 iterations * 4800 cells per frame
        for (var f = 0; f < 1000; f++) {
          for (var c = 0; c < 4800; c++) {
            final fg = c % 2 == 0 ? 0xFF00FF00 : 0;
            final bg = c % 3 == 0 ? 0xFFFF0000 : 0;
            final mod = c % 5 == 0 ? 1 : 0;

            final cellStyle = Style(
              foreground: fg != 0 ? Color.argb(fg) : null,
              background: bg != 0 ? Color.argb(bg) : null,
              modifiers: mod,
            );
            activeStyle = _dummyWriteStyleTransition(activeStyle, cellStyle);
          }
        }
        swObject.stop();
        if (swObject.elapsedMicroseconds < minObjectUs) {
          minObjectUs = swObject.elapsedMicroseconds;
          minObjectMs = swObject.elapsedMilliseconds;
        }
      }

      int minPrimsMs = 9999999;
      int minPrimsUs = 999999999;
      for (var run = 0; run < 3; run++) {
        final swPrims = Stopwatch()..start();
        int curFg = 0, curBg = 0, curMod = 0;
        for (var f = 0; f < 1000; f++) {
          for (var c = 0; c < 4800; c++) {
            final fg = c % 2 == 0 ? 0xFF00FF00 : 0;
            final bg = c % 3 == 0 ? 0xFFFF0000 : 0;
            final mod = c % 5 == 0 ? 1 : 0;

            _dummyWriteStyleTransitionPrims(curFg, curBg, curMod, fg, bg, mod);
            curFg = fg;
            curBg = bg;
            curMod = mod;
          }
        }
        swPrims.stop();
        if (swPrims.elapsedMicroseconds < minPrimsUs) {
          minPrimsUs = swPrims.elapsedMicroseconds;
          minPrimsMs = swPrims.elapsedMilliseconds;
        }
      }

      print('Benchmark 1 (Style Transitions over 4.8M cells, best of 3):');
      print('  Object style transitions:    $minObjectMs ms ($minObjectUs us)');
      print('  Primitive style transitions: $minPrimsMs ms ($minPrimsUs us)');
      expect(minPrimsUs, lessThan(minObjectUs));
    });

    test('2. Array Allocation vs Pool Reuse (.fillRange)', () {
      final swAlloc = Stopwatch()..start();
      for (var i = 0; i < 1000000; i++) {
        final list = Uint32List(151);
        _escapeUint32List(list);
      }
      swAlloc.stop();

      final swPool = Stopwatch()..start();
      final pool = Uint32List(151);
      final len = pool.length;
      for (var i = 0; i < 1000000; i++) {
        pool.fillRange(0, len, 0);
        _escapeUint32List(pool);
      }
      swPool.stop();

      print('Benchmark 2 (151 elements over 1M iterations):');
      print('  Array allocation:            ${swAlloc.elapsedMilliseconds} ms');
      print('  Pool reuse (.fillRange):     ${swPool.elapsedMilliseconds} ms');
      // Array allocation is extremely fast and nursery bump-pointer optimized in Dart VM
      expect(swAlloc.elapsedMilliseconds, lessThan(200));
    });

    test('3. Grapheme Width Math vs ASCII Fast-Path', () {
      // 10k mixed strings (mostly ASCII as in standard TUI buffers)
      final list = List<String>.generate(10000, (i) {
        if (i % 20 == 0) return '🌟'; // Unicode emoji
        if (i % 35 == 0) return '한'; // Hangul syllable
        if (i % 2 == 0) return 'a';
        return ' ';
      });

      // Warm up the JIT compiler
      for (var w = 0; w < 500; w++) {
        for (final item in list) {
          _isWideGraphemeBaseline(item);
          _isWideGraphemeOptimized(item);
        }
      }

      int minBaselineMs = 9999999;
      int minBaselineUs = 999999999;
      var baselineTrueCount = 0;
      for (var run = 0; run < 3; run++) {
        final swBaseline = Stopwatch()..start();
        baselineTrueCount = 0;
        for (var i = 0; i < 500; i++) {
          for (final item in list) {
            final res = _isWideGraphemeBaseline(item);
            if (res) {
              baselineTrueCount++;
            }
          }
        }
        swBaseline.stop();
        if (swBaseline.elapsedMicroseconds < minBaselineUs) {
          minBaselineUs = swBaseline.elapsedMicroseconds;
          minBaselineMs = swBaseline.elapsedMilliseconds;
        }
      }

      int minOptimizedMs = 9999999;
      int minOptimizedUs = 999999999;
      var optimizedTrueCount = 0;
      for (var run = 0; run < 3; run++) {
        final swOptimized = Stopwatch()..start();
        optimizedTrueCount = 0;
        for (var i = 0; i < 500; i++) {
          for (final item in list) {
            final res = _isWideGraphemeOptimized(item);
            if (res) {
              optimizedTrueCount++;
            }
          }
        }
        swOptimized.stop();
        if (swOptimized.elapsedMicroseconds < minOptimizedUs) {
          minOptimizedUs = swOptimized.elapsedMicroseconds;
          minOptimizedMs = swOptimized.elapsedMilliseconds;
        }
      }

      print('Benchmark 3 (Grapheme checks on 5M strings, best of 3):');
      print(
        '  Baseline isWideGrapheme:     $minBaselineMs ms ($minBaselineUs us) (count: $baselineTrueCount)',
      );
      print(
        '  Optimized (ASCII fast-path): $minOptimizedMs ms ($minOptimizedUs us) (count: $optimizedTrueCount)',
      );
      expect(minOptimizedUs, lessThan(minBaselineUs));
    });
  });
}
