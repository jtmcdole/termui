# Tinpot

A high-performance pure Dart engine for converting images to ANSI terminal text using structural symbols, inspired by [Chafa](https://hpjansson.org/chafa/).

Tinpot is designed to integrate seamlessly with Dart CLI applications (like those built with `termui`), allowing you to render rich, colorful images directly into your terminal. By utilizing structural block symbols (such as ` `, `▀`, `▄`, `█`) and accurate DIN99d color space evaluation, it creates a fast, surprisingly high-fidelity approximation of images for standard TTY environments.

## Features

- **High-Performance**: Operates directly on contiguous bit-packed color arrays, unrolled loops, and bitwise arithmetic to process pixels quickly.
- **WASM-Compatible Output**: Generates clean, predictable ANSI blocks mapping perfectly to classic `chafa` terminal output (focusing on strict standard block symbols).
- **Exact Mean Color Selection**: Ensures mathematically accurate foreground/background representations using Euclidean distance checks within the perceptual DIN99d color space.
- **Terminal Scale Compensation**: Internally handles mapping a 1:1 image aspect ratio to the classic 1:2 height distortion of physical terminal cells.

## Example

```dart
import 'dart:io';
import 'package:image/image.dart' as img;
import 'package:termui_tinpot/termui_tinpot.dart';

void main() {
  final image = img.decodeImage(File('image.png').readAsBytesSync())!;

  // Converts image to a 2D array of terminal cells (60 columns, auto-scaled rows)
  final engine = TermuiTinpot();
  final grid = engine.convert(image, 60, (60 / (image.width / image.height) / 2).floor());

  // Use Termui or iterate manually to emit standard ANSI color codes
  // ...
}
```
