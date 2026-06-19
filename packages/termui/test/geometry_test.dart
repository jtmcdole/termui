import 'package:test/test.dart';
import 'package:termui/ui/widgets/core/geometry.dart';

void main() {
  group('Size Tests', () {
    test('Constructor and properties', () {
      const size = Size(10, 20);
      expect(size.width, 10);
      expect(size.height, 20);
    });

    test('Size.zero constants', () {
      expect(Size.zero.width, 0);
      expect(Size.zero.height, 0);
    });

    test('Equality and Hashcode', () {
      const size1 = Size(10, 20);
      const size2 = Size(10, 20);
      const size3 = Size(10, 21);

      expect(size1, equals(size2));
      expect(size1, isNot(equals(size3)));
      expect(size1.hashCode, equals(size2.hashCode));
      expect(size1.hashCode, isNot(equals(size3.hashCode)));
    });

    test('toString representation', () {
      const size = Size(10, 20);
      expect(size.toString(), 'Size(10, 20)');
    });
  });

  group('Offset Tests', () {
    test('Constructor and properties', () {
      const offset = Offset(5, -3);
      expect(offset.dx, 5);
      expect(offset.dy, -3);
    });

    test('Offset.zero constants', () {
      expect(Offset.zero.dx, 0);
      expect(Offset.zero.dy, 0);
    });

    test('Addition and subtraction operators', () {
      const o1 = Offset(2, 3);
      const o2 = Offset(4, 5);

      final sum = o1 + o2;
      expect(sum.dx, 6);
      expect(sum.dy, 8);

      final diff = o1 - o2;
      expect(diff.dx, -2);
      expect(diff.dy, -2);
    });

    test('Equality and Hashcode', () {
      const o1 = Offset(2, 3);
      const o2 = Offset(2, 3);
      const o3 = Offset(2, 4);

      expect(o1, equals(o2));
      expect(o1, isNot(equals(o3)));
      expect(o1.hashCode, equals(o2.hashCode));
      expect(o1.hashCode, isNot(equals(o3.hashCode)));
    });

    test('toString representation', () {
      const offset = Offset(2, 3);
      expect(offset.toString(), 'Offset(2, 3)');
    });
  });

  group('BoxConstraints Tests', () {
    test('Default values', () {
      const constraints = BoxConstraints();
      expect(constraints.minWidth, 0);
      expect(constraints.maxWidth, BoxConstraints.infinity);
      expect(constraints.minHeight, 0);
      expect(constraints.maxHeight, BoxConstraints.infinity);
    });

    test('BoxConstraints.tight constructor', () {
      final constraints = BoxConstraints.tight(const Size(15, 25));
      expect(constraints.minWidth, 15);
      expect(constraints.maxWidth, 15);
      expect(constraints.minHeight, 25);
      expect(constraints.maxHeight, 25);
      expect(constraints.isTight, isTrue);
    });

    test('BoxConstraints.loose constructor', () {
      final constraints = BoxConstraints.loose(const Size(15, 25));
      expect(constraints.minWidth, 0);
      expect(constraints.maxWidth, 15);
      expect(constraints.minHeight, 0);
      expect(constraints.maxHeight, 25);
      expect(constraints.isTight, isFalse);
    });

    test('BoxConstraints.tightFor constructor', () {
      const c1 = BoxConstraints.tightFor(width: 10, height: 20);
      expect(c1.minWidth, 10);
      expect(c1.maxWidth, 10);
      expect(c1.minHeight, 20);
      expect(c1.maxHeight, 20);

      const c2 = BoxConstraints.tightFor(width: 10);
      expect(c2.minWidth, 10);
      expect(c2.maxWidth, 10);
      expect(c2.minHeight, 0);
      expect(c2.maxHeight, BoxConstraints.infinity);
    });

    test('Constrain clamps size correctly', () {
      const constraints = BoxConstraints(
        minWidth: 5,
        maxWidth: 10,
        minHeight: 5,
        maxHeight: 10,
      );

      expect(constraints.constrain(const Size(2, 2)), const Size(5, 5));
      expect(constraints.constrain(const Size(7, 8)), const Size(7, 8));
      expect(constraints.constrain(const Size(12, 15)), const Size(10, 10));
    });

    test('Boundedness checks', () {
      const c1 = BoxConstraints(maxWidth: 10, maxHeight: 10);
      expect(c1.hasBoundedWidth, isTrue);
      expect(c1.hasBoundedHeight, isTrue);

      const c2 = BoxConstraints();
      expect(c2.hasBoundedWidth, isFalse);
      expect(c2.hasBoundedHeight, isFalse);
    });

    test('copyWith works correctly', () {
      const constraints = BoxConstraints(
        minWidth: 1,
        maxWidth: 2,
        minHeight: 3,
        maxHeight: 4,
      );

      final copy = constraints.copyWith(minWidth: 10, maxHeight: 40);

      expect(copy.minWidth, 10);
      expect(copy.maxWidth, 2);
      expect(copy.minHeight, 3);
      expect(copy.maxHeight, 40);
    });

    test('toString representation', () {
      const constraints = BoxConstraints(
        minWidth: 1,
        maxWidth: 2,
        minHeight: 3,
        maxHeight: 4,
      );
      expect(
        constraints.toString(),
        'BoxConstraints(minWidth: 1, maxWidth: 2, minHeight: 3, maxHeight: 4)',
      );
    });
  });
}
