## 0.3.1

 - **PERF**(termui_flutter): optimize TUI rendering and fix sub-pixel sampling artifacts.

## 0.3.0

> Note: This release has breaking changes.

 - **PERF**(tinpot): optimize hot loop allocations and bitwise operations.
 - **PERF**(tinpot): Make symbol candidates compile-time const and hoist block filtering.
 - **PERF**(tinpot): Eliminate closures, unbox pixel getters, and add Din99d direct-mapped cache.
 - **PERF**: math.
 - **PERF**(tinpot): Replace record allocations and sorting with bounded insertion topK.
 - **PERF**(tinpot): Implement branchless candidate scoring.
 - **FIX**(tinpot): Use true color error for candidate shape evaluation.
 - **FIX**(tinpot): Exclude TAG_DOT characters to prevent line breakage.
 - **FEAT**(tinpot): Add --work CLI flag to control CellQuantizer shape evaluation effort.
 - **BREAKING** **REFACTOR**(tinpot): optimize quantization render loop and fix ansi screenshot bloat.

## 0.2.0

> Note: This release has breaking changes.

 - **PERF**(tinpot): optimize hot loop allocations and bitwise operations.
 - **PERF**(tinpot): Make symbol candidates compile-time const and hoist block filtering.
 - **PERF**(tinpot): Eliminate closures, unbox pixel getters, and add Din99d direct-mapped cache.
 - **PERF**: math.
 - **PERF**(tinpot): Replace record allocations and sorting with bounded insertion topK.
 - **PERF**(tinpot): Implement branchless candidate scoring.
 - **FIX**(tinpot): Use true color error for candidate shape evaluation.
 - **FIX**(tinpot): Exclude TAG_DOT characters to prevent line breakage.
 - **FEAT**(tinpot): Add --work CLI flag to control CellQuantizer shape evaluation effort.
 - **BREAKING** **REFACTOR**(tinpot): optimize quantization render loop and fix ansi screenshot bloat.

## 0.1.0

* Initial open source release.
* Added `TermuiTinpot` class and `TinpotOutputCell` to parse `package:image` inputs into terminal output grids.
* Optimized color comparisons using approximate DIN99d calculations and bitwise color distances.
* Removed hard dependency on legacy terminal computing symbols to maintain standard cross-platform font compatibility.
