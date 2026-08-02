---
name: dart-use-clock-package
description: Guidelines for dealing with time in Dart. Explains why and how to use package:clock and clock.now() instead of DateTime.now() to ensure testability.
---

# Dart Time & Testability Guidelines

When working with time-dependent logic in Dart (e.g., animations, physics updates, timeouts, or scheduling), you should **never** use the core library's `DateTime.now()`. 

Instead, always use `clock.now()` from `package:clock`.

## Why `clock.now()` over `DateTime.now()`?

Synchronous testing libraries (like `fake_async` and `package:test`) can intercept and mock Dart's event loops, microtasks, and `Timer` classes. However, they **cannot** mock the underlying system clock exposed by `DateTime.now()`. 

If your production code relies on `DateTime.now()`, any time manipulation in tests (e.g., `fakeAsync.elapse(Duration(seconds: 1))` or pumping the `TerminalTester`) will result in your code reading a delta of `0` milliseconds because the real-world wall-clock time hasn't changed.

`package:clock` is explicitly designed to integrate with `fake_async`. By using `clock.now()`, tests can deterministically manipulate time, fast-forwarding hours of simulated time instantly without blocking the test runner.

## Example

### ❌ Bad (Untestable)
```dart
import 'dart:core';

class ParticleSystem {
  DateTime _lastTick;

  void start() {
    _lastTick = DateTime.now();
  }

  void update() {
    final now = DateTime.now();
    double dt = now.difference(_lastTick).inMilliseconds / 1000.0;
    _lastTick = now;
    // ... update logic
  }
}
```

### ✅ Good (Testable)
```dart
import 'package:clock/clock.dart';

class ParticleSystem {
  DateTime _lastTick;

  void start() {
    _lastTick = clock.now();
  }

  void update() {
    final now = clock.now();
    double dt = now.difference(_lastTick).inMilliseconds / 1000.0;
    _lastTick = now;
    // ... update logic
  }
}
```

## Setup

1. Add `clock` to your dependencies in `pubspec.yaml`:
```yaml
dependencies:
  clock: ^1.1.1
```

2. Import it wherever you need time access:
```dart
import 'package:clock/clock.dart';
```
