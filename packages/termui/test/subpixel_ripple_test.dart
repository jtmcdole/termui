import 'dart:math';
import 'package:fake_async/fake_async.dart';
import 'package:termui/termui.dart';
import 'package:test/test.dart';

void main() {
  group('SubpixelRippleManager Tests', () {
    late SubpixelRippleManager manager;

    setUp(() {
      manager = SubpixelRippleManager();
    });

    test('addRipple schedules new ripple correctly', () {
      fakeAsync((_) {
        expect(manager.hasActiveRipples, isFalse);
        manager.addRipple(const Point<int>(5, 5));
        expect(manager.hasActiveRipples, isTrue);
        expect(manager.ripples.length, equals(1));
        expect(manager.ripples.first.center, equals(const Point<int>(5, 5)));
      });
    });

    test('updateRipples removes expired ripples', () {
      fakeAsync((async) {
        manager.addRipple(const Point<int>(10, 10), durationMs: 10);
        expect(manager.hasActiveRipples, isTrue);

        async.elapse(const Duration(milliseconds: 20));
        manager.updateRipples();
        expect(manager.hasActiveRipples, isFalse);
      });
    });

    test('paint method writes sub-pixel circle characters onto buffer', () {
      fakeAsync((async) {
        final buffer = Buffer(40, 20);

        manager.addRipple(const Point<int>(20, 10), durationMs: 100);
        async.elapse(const Duration(milliseconds: 50));

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

        manager.paint(buffer);

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
    });

    test(
      'SubpixelRippleWidget paints correctly through declarative element',
      () {
        fakeAsync((async) {
          final localManager = SubpixelRippleManager();
          localManager.addRipple(const Point<int>(15, 8), durationMs: 100);
          async.elapse(const Duration(milliseconds: 50));

          final widget = SubpixelRippleWidget(manager: localManager);
          final element = widget.createElement() as SubpixelRippleWidgetElement;

          final size = element.layout(BoxConstraints.tight(const Size(40, 20)));
          expect(size.width, equals(40));
          expect(size.height, equals(20));

          final buffer = Buffer(40, 20);
          element.paint(buffer, Offset.zero);

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
        });
      },
    );
  });
}
