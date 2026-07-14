import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:example_flutter/src/tui_player/cast_parser.dart';

void main() {
  test('decompressCast decodes gzip bytes asynchronously', () async {
    const mockCast =
        '{"version": 2, "width": 80, "height": 24}\n[1.0, "o", "test"]';
    final gzippedBytes = gzip.encode(utf8.encode(mockCast));
    final bytes = Uint8List.fromList(gzippedBytes);

    final result = await decompressCast(bytes, 'test.cast');

    expect(result, equals(mockCast));
  });

  test('decompressCast decodes uncompressed bytes', () async {
    const mockCast =
        '{"version": 2, "width": 80, "height": 24}\n[1.0, "o", "test"]';
    final bytes = Uint8List.fromList(utf8.encode(mockCast));
    final result = await decompressCast(bytes, 'test.cast');
    expect(result, equals(mockCast));
  });

  test('decompressCast falls back to utf8 on corrupted gzip data', () async {
    const mockCast =
        '{"version": 2, "width": 80, "height": 24}\n[1.0, "o", "test"]';
    final invalidGzip = [0x1f, 0x8b] + utf8.encode(mockCast);
    final bytes = Uint8List.fromList(invalidGzip);
    final result = await decompressCast(bytes, 'test.cast');

    expect(result.codeUnitAt(0), equals(0x1f));
    expect(result.codeUnitAt(1), equals(0xFFFD)); // Invalid UTF-8 replaced by
    expect(result.substring(2), equals(mockCast));
  });
}
