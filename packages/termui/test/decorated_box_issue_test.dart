import 'package:termui/termui.dart';
import 'package:test/test.dart';

void main() {
  test(
    'DecoratedBox calculates correct intrinsic height under unbounded constraints',
    () {
      final menuBarRow = Row([
        Text(' File ', style: const Style(foreground: Color(255, 255, 255))),
      ]);

      final w = Column([
        DecoratedBox(
          decoration: const BoxDecoration(border: Border.single),
          child: menuBarRow,
        ),
      ]);

      final rootElement = w.createElement();
      rootElement.rebuild();
      rootElement.layout(
        BoxConstraints(
          minWidth: 0,
          maxWidth: 80,
          minHeight: 0,
          maxHeight: BoxConstraints.infinity,
        ),
      );

      // The text is 1 high, + top border + bottom border = 3
      expect(rootElement.size.height, greaterThanOrEqualTo(3));
    },
  );

  test(
    'DecoratedBox calculates correct intrinsic width under unbounded constraints',
    () {
      final menuCol = Column([
        Text('File', style: const Style(foreground: Color(255, 255, 255))),
      ]);

      final w = Row([
        DecoratedBox(
          decoration: const BoxDecoration(border: Border.single),
          child: menuCol,
        ),
      ]);

      final rootElement = w.createElement();
      rootElement.rebuild();
      rootElement.layout(
        BoxConstraints(
          minWidth: 0,
          maxWidth: BoxConstraints.infinity,
          minHeight: 0,
          maxHeight: 24,
        ),
      );

      // The text is "File" (width 4).
      // + left border (width 1) + right border (width 1) = 6
      expect(rootElement.size.width, greaterThanOrEqualTo(6));
    },
  );

  test(
    'DecoratedBox renders without throwing when borderGradientAngle is NaN',
    () {
      const startColor = Color(10, 20, 30);
      final widget = DecoratedBox(
        decoration: const BoxDecoration(
          border: Border.single,
          borderStartColor: startColor,
          borderEndColor: Color(200, 210, 220),
          borderGradientAngle: double.nan,
        ),
        child: Text('Hi'),
      );

      final element = widget.createElement();
      element.mount(null);
      element.layout(const BoxConstraints.tightFor(width: 6, height: 3));

      final buffer = Buffer(6, 3);
      expect(() => element.paint(buffer, Offset.zero), returnsNormally);
      expect(buffer.getCharacter(0, 0), equals('┌'));
    },
  );
}
