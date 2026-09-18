import 'package:test/test.dart';
import 'package:termui/termui.dart';

void main() {
  group('ScrollBar trackHeight <= 0 tests', () {
    test(
      'vertical ScrollBarElement.performLayout handles trackHeight == 0 without throwing',
      () {
        final controller = DiscreteScrollController()
          ..totalExtent = 100
          ..viewportExtent = 10;
        final scrollBar = ScrollBar(
          direction: LayoutDirection.vertical,
          controller: controller,
        );
        final element = scrollBar.createElement() as ScrollBarElement;
        element.mount(null);

        // Height 0 causes trackHeight = 0
        expect(
          () => element.layout(const BoxConstraints(maxWidth: 1, maxHeight: 0)),
          returnsNormally,
        );
        expect(element.thumbHeight, 0);
        expect(element.thumbPos, 0);
      },
    );

    test(
      'horizontal ScrollBarElement.performLayout handles trackHeight (width) == 0 without throwing',
      () {
        final controller = DiscreteScrollController()
          ..totalExtent = 100
          ..viewportExtent = 10;
        final scrollBar = ScrollBar(
          direction: LayoutDirection.horizontal,
          controller: controller,
        );
        final element = scrollBar.createElement() as ScrollBarElement;
        element.mount(null);

        // Width 0 causes trackHeight = 0
        expect(
          () => element.layout(const BoxConstraints(maxWidth: 0, maxHeight: 1)),
          returnsNormally,
        );
        expect(element.thumbHeight, 0);
        expect(element.thumbPos, 0);
      },
    );

    test(
      'LayoutBuilder getIntrinsicHeight does not crash when subtree contains Expanded ScrollBar',
      () {
        final controller = DiscreteScrollController()
          ..totalExtent = 100
          ..viewportExtent = 10;
        final widget = LayoutBuilder(
          builder: (context, constraints) {
            return Column([
              Expanded(
                child: ScrollBar(
                  direction: LayoutDirection.vertical,
                  controller: controller,
                ),
              ),
            ]);
          },
        );

        expect(() => widget.getIntrinsicHeight(80), returnsNormally);
      },
    );
  });
}
