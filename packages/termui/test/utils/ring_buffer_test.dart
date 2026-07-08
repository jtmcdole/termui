import 'package:test/test.dart';
import 'package:termui/termui.dart';

void main() {
  group('RingBuffer', () {
    test('maintains capacity and wraps elements', () {
      final buffer = RingBuffer<int>(5);

      for (var i = 1; i <= 3; i++) {
        buffer.add(i);
      }
      expect(buffer.length, 3);
      expect(buffer.toList(), [1, 2, 3]);

      for (var i = 4; i <= 7; i++) {
        buffer.add(i);
      }
      expect(buffer.length, 5);
      // The first two elements (1, 2) should be overwritten.
      expect(buffer.toList(), [3, 4, 5, 6, 7]);

      // Check indexed access
      expect(buffer.elementAt(0), 3);
      expect(buffer.elementAt(4), 7);
    });

    test('iterable works correctly', () {
      final buffer = RingBuffer<double>(3);
      buffer.add(1.0);
      buffer.add(2.0);
      buffer.add(3.0);
      buffer.add(4.0); // overwrites 1.0

      int index = 0;
      final expected = [2.0, 3.0, 4.0];
      for (final value in buffer) {
        expect(value, expected[index++]);
      }
    });

    test('throws ArgumentError when capacity is <= 0', () {
      expect(() => RingBuffer<int>(0), throwsArgumentError);
      expect(() => RingBuffer<int>(-1), throwsArgumentError);
    });

    test('operator[] works identically to elementAt and validates bounds', () {
      final buffer = RingBuffer<int>(3);
      buffer.add(10);
      buffer.add(20);
      expect(buffer[0], 10);
      expect(buffer[1], 20);
      expect(() => buffer[-1], throwsRangeError);
      expect(() => buffer[2], throwsRangeError);
    });

    test('setting length shrinks capacity and elements', () {
      final buffer = RingBuffer<int>(5);
      buffer.addAll([1, 2, 3, 4, 5]);

      buffer.length = 3;
      expect(buffer.length, 3);
      expect(buffer.toList(), [1, 2, 3]);

      // Adding element should wrap around capacity 3
      buffer.add(4);
      expect(buffer.toList(), [2, 3, 4]);
    });

    test('setting length expands capacity and pads with null', () {
      final buffer = RingBuffer<int?>(3);
      buffer.addAll([1, 2]);

      buffer.length = 4;
      expect(buffer.length, 4);
      expect(buffer.toList(), [1, 2, null, null]);

      // Adding element should wrap around capacity 4
      buffer.add(5);
      expect(buffer.toList(), [2, null, null, 5]);
    });

    test(
      'setting length expands capacity of a wrapped buffer and preserves element order',
      () {
        final buffer = RingBuffer<int?>(3);
        buffer.addAll([1, 2, 3]); // buffer is [1, 2, 3], head=0, tail=0
        buffer.add(
          4,
        ); // buffer is [4, 2, 3], head=1, tail=1 (logical order: 2, 3, 4)

        buffer.length = 5;
        expect(buffer.length, 5);
        expect(buffer.toList(), [2, 3, 4, null, null]);

        buffer.add(5);
        expect(buffer.toList(), [3, 4, null, null, 5]);
      },
    );

    test('removeFirst removes and returns elements in FIFO order', () {
      final buffer = RingBuffer<int>(3);
      buffer.addAll([1, 2]);
      expect(buffer.removeFirst(), 1);
      expect(buffer.removeFirst(), 2);
      expect(() => buffer.removeFirst(), throwsStateError);
    });

    test('setting length to 0 clears buffer', () {
      final buffer = RingBuffer<int>(3);
      buffer.addAll([1, 2]);
      buffer.length = 0;
      expect(buffer.length, 0);
      expect(buffer.isEmpty, true);
    });

    test('setting length to negative throws ArgumentError', () {
      final buffer = RingBuffer<int>(3);
      expect(() => buffer.length = -1, throwsArgumentError);
    });

    test('operator[]= updates elements correctly', () {
      final buffer = RingBuffer<int>(3);
      buffer.addAll([1, 2]);
      buffer[1] = 20;
      expect(buffer[1], 20);
      expect(() => buffer[2] = 30, throwsRangeError);
      expect(() => buffer[-1] = 0, throwsRangeError);
    });

    test('physicalIndex maps logical index to internal buffer index', () {
      final buffer = RingBuffer<int>(3);
      buffer.addAll([1, 2]);
      expect(buffer.physicalIndex(0), 0);
      expect(buffer.physicalIndex(1), 1);
      expect(() => buffer.physicalIndex(2), throwsRangeError);
      expect(() => buffer.physicalIndex(-1), throwsRangeError);
    });
  });
}
