import 'package:flutter_test/flutter_test.dart';
import 'package:termui_flutter/src/backend.dart';

void main() {
  test(
    'FlutterTerminalBackend parses OSC 22 sequence with ST terminator',
    () async {
      final backend = FlutterTerminalBackend();
      String? capturedCursor;
      backend.mouseCursorChanges.listen((c) => capturedCursor = c);

      backend.write('\x1b]22;pointer\x1b\\');
      await Future.delayed(Duration.zero);
      expect(capturedCursor, equals('pointer'));
    },
  );

  test(
    'FlutterTerminalBackend parses OSC 22 sequence with BEL terminator',
    () async {
      final backend = FlutterTerminalBackend();
      String? capturedCursor;
      backend.mouseCursorChanges.listen((c) => capturedCursor = c);

      backend.write('\x1b]22;crosshair\x07');
      await Future.delayed(Duration.zero);
      expect(capturedCursor, equals('crosshair'));
    },
  );

  test(
    'FlutterTerminalBackend parses reset cursor (empty parameter)',
    () async {
      final backend = FlutterTerminalBackend();
      String? capturedCursor = 'not_null';
      backend.mouseCursorChanges.listen((c) => capturedCursor = c);

      backend.write('\x1b]22;\x1b\\');
      await Future.delayed(Duration.zero);
      expect(capturedCursor, isNull);
    },
  );
}
