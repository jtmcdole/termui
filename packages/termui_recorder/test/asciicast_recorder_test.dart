import 'dart:convert';
import 'package:test/test.dart';
import 'package:termui/ui/buffer.dart';
import 'package:termui/ui/style.dart';
import 'package:termui_recorder/termui_recorder.dart';

void main() {
  group('AsciicastRecorder', () {
    test('records asciicast header and frame updates', () {
      final sb = StringBuffer();
      final recorder = AsciicastRecorder(
        StringSinkAsciicastWriter(sb),
        width: 80,
        height: 24,
      );

      final buffer = Buffer.blank(80, 24);
      buffer.setAttributes(
        0,
        0,
        char: 'A',
        fg: Style.empty.foreground?.argb,
        bg: Style.empty.background?.argb,
        modifiers: Style.empty.modifiers,
      );

      // Record first frame
      recorder.recordFrame(buffer);

      final lines = sb.toString().trim().split('\n');
      expect(lines, isNotEmpty);

      // Verify header format (Line 0)
      final header = jsonDecode(lines[0]) as Map<String, dynamic>;
      expect(header['version'], equals(3));
      expect(header['term']['cols'], equals(80));
      expect(header['term']['rows'], equals(24));

      // Verify first frame event format (Line 1)
      final event = jsonDecode(lines[1]) as List<dynamic>;
      expect(event.length, equals(3));
      expect(event[0], isA<double>()); // timestamp
      expect(event[1], equals('o')); // output type
      expect(event[2], contains('A')); // character written
    });
  });
}
