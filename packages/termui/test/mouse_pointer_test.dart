import 'package:termui/termui.dart';
import 'package:test/test.dart';

void main() {
  group('MousePointer OSC 22 mapping', () {
    test('covers all 35 CSS/W3C shapes with unique round-trip names', () {
      expect(MousePointer.values, hasLength(35));
      final seen = <String>{};
      for (final pointer in MousePointer.values) {
        expect(seen.add(pointer.value), isTrue, reason: pointer.value);
        expect(MousePointer.fromOsc22Name(pointer.value), equals(pointer));
      }
    });

    test('returns null for null, empty, or unsupported names', () {
      expect(MousePointer.fromOsc22Name(null), isNull);
      expect(MousePointer.fromOsc22Name(''), isNull);
      expect(MousePointer.fromOsc22Name('not-a-cursor'), isNull);
      expect(MousePointer.fromOsc22Name('POINTER'), isNull);
    });
  });
}
