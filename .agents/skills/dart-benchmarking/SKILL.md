---
name: dart-benchmarking
description: Guidelines and best practices for writing microbenchmarks, analyzing GC overhead, and evaluating performance on VM, JS, and WASM compilation targets.
---

# Dart Performance Benchmarking Guidelines

## 1. When to Use This Skill
Use this skill when:
* Deciding between object allocation/GC vs. caching/pooling patterns (e.g. `Canvas`, `Buffer`, or `Element` trees).
* Optimizing tight rendering, painting, or event processing loops.
* Verifying performance across multiple targets (VM, JS, WASM).

## 2. Allocation vs. Caching Tradeoffs
In the Dart VM, nursery bump-pointer allocation is highly optimized for short-lived ("nursery") objects. Caching objects and clearing them using an O(N) loop (e.g., `canvas.clear()` or `.fillRange()`) can actually be slower than fresh allocations due to the clear loop's CPU overhead.

### Microbenchmark Template
When verifying allocations vs. caching:
```dart
test('Allocation vs Caching Microbenchmark', () {
  final buffer = Buffer(40, 20);

  // 1. Fresh Allocation per iteration
  final swAlloc = Stopwatch()..start();
  for (var i = 0; i < 5000; i++) {
    final canvas = Canvas(40, 20);
    final el = canvas.createElement();
    el.layout(BoxConstraints.tight(const Size(40, 20)));
    el.paint(buffer, Offset.zero);
    el.unmount();
  }
  swAlloc.stop();

  // 2. Cached & Cleared per iteration
  final swCached = Stopwatch()..start();
  final cachedCanvas = Canvas(40, 20);
  final cachedEl = cachedCanvas.createElement();
  for (var i = 0; i < 5000; i++) {
    cachedCanvas.clear();
    cachedEl.layout(BoxConstraints.tight(const Size(40, 20)));
    cachedEl.paint(buffer, Offset.zero);
  }
  cachedEl.unmount();
  swCached.stop();

  print('Fresh Allocations:           ${swAlloc.elapsedMilliseconds} ms');
  print('Cached & Cleared Canvas/El:  ${swCached.elapsedMilliseconds} ms');
});
```

## 3. Web & WASM Compilation Targets
When targeting WASM (WebAssembly) or Web (Dart2JS):
* **WASM Heap Dynamics:** WASM has a linear memory space. Garbage collection of GC-managed objects in Dart-to-WASM relies on WasmGC, which may have different allocation and cleanup characteristics compared to the native Dart VM.
* **Array Clearing (O(N) vs. Native Copies):** On the web/JS targets, clearing large typed arrays can benefit from native optimized JS/WASM instructions (like `typedarray.fill()`), but allocating many tiny short-lived structures can introduce GC pressure depending on the browser's GC engine.
* **Always run benchmarks on the target target:** If the application is intended for Web/WASM, do not rely solely on VM benchmarks. Compile and run performance tests using `dart test -p chrome` or specialized Web/WASM benchmark runners to collect actual performance profiles.
