import 'dart:math';
import 'package:termui/termui.dart';
import 'package:test/test.dart';

void main() {
  group('SubpixelRippleManager Tests', () {
    late SubpixelRippleManager manager;

    setUp(() {
      manager = SubpixelRippleManager();
    });

    test('addRipple schedules new ripple correctly', () {
      expect(manager.hasActiveRipples, isFalse);
      manager.addRipple(const Point<int>(5, 5));
      expect(manager.hasActiveRipples, isTrue);
      expect(manager.ripples.length, equals(1));
      expect(manager.ripples.first.center, equals(const Point<int>(5, 5)));
    });

    test('updateRipples removes expired ripples', () async {
      manager.addRipple(const Point<int>(10, 10), durationMs: 10);
      expect(manager.hasActiveRipples, isTrue);

      await Future.delayed(const Duration(milliseconds: 20));
      manager.updateRipples();
      expect(manager.hasActiveRipples, isFalse);
    });

    test('paint method writes sub-pixel circle characters onto buffer', () {
      final buffer = Buffer(40, 20);
      final now = DateTime.now().millisecondsSinceEpoch;

      // Inject a ripple that is exactly 50ms into its 100ms duration
      manager.addRipple(
        const Point<int>(20, 10),
        durationMs: 100,
        startTime: now - 50,
      );

      // Verify buffer is empty
      var bufferModified = false;
      for (var y = 0; y < buffer.height; y++) {
        for (var x = 0; x < buffer.width; x++) {
          final char = buffer.getCharacter(x, y);
          if (char != ' ') {
            bufferModified = true;
          }
        }
      }
      expect(bufferModified, isFalse);

      // Paint the buffer, it will calculate elapsed as 50ms (or slightly more)
      manager.paint(buffer);

      // Verify the buffer now contains Braille character coordinates
      for (var y = 0; y < buffer.height; y++) {
        for (var x = 0; x < buffer.width; x++) {
          final char = buffer.getCharacter(x, y);
          if (char.isNotEmpty && char.codeUnitAt(0) >= 0x2800) {
            bufferModified = true;
          }
        }
      }
      expect(bufferModified, isTrue);
    });

    test(
      'SubpixelRippleWidget paints correctly through declarative element',
      () {
        final manager = SubpixelRippleManager();
        final now = DateTime.now().millisecondsSinceEpoch;
        manager.addRipple(
          const Point<int>(15, 8),
          durationMs: 100,
          startTime: now - 50,
        );

        final widget = SubpixelRippleWidget(manager: manager);
        final element = widget.createElement() as SubpixelRippleWidgetElement;

        // Layout it tight to 40x20
        final size = element.layout(BoxConstraints.tight(const Size(40, 20)));
        expect(size.width, equals(40));
        expect(size.height, equals(20));

        final buffer = Buffer(40, 20);
        element.paint(buffer, Offset.zero);

        // Verify the buffer contains Braille character coordinates
        var bufferModified = false;
        for (var y = 0; y < buffer.height; y++) {
          for (var x = 0; x < buffer.width; x++) {
            final char = buffer.getCharacter(x, y);
            if (char != ' ' && char.codeUnitAt(0) >= 0x2800) {
              bufferModified = true;
            }
          }
        }
        expect(bufferModified, isTrue);

        element.unmount();
      },
    );
  });
}
