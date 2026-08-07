import 'package:test/test.dart';
import 'package:termui/termui.dart';

void main() {
  group('BufferAnsiSerialization', () {
    test(
      'round-trips Buffer toAnsiString and BufferAnsiSerialization.fromAnsi',
      () {
        final buffer = Buffer(10, 5);
        buffer.setCharacter(2, 2, 'A');
        buffer.setForeground(2, 2, 0xFFFF0000); // Red
        buffer.setBackground(2, 2, 0xFF0000FF); // Blue

        final ansiStr = buffer.toAnsiString();
        expect(ansiStr, contains('\x1B[38;2;255;0;0m'));
        expect(ansiStr, contains('\x1B[48;2;0;0;255mA'));

        final restored = BufferAnsiSerialization.fromAnsi(ansiStr);
        expect(restored.width, equals(10));
        expect(restored.height, equals(5));
        expect(restored.getCharacter(2, 2), equals('A'));
        expect(restored.getForeground(2, 2), equals(0xFFFF0000));
        expect(restored.getBackground(2, 2), equals(0xFF0000FF));
      },
    );
  });
}
