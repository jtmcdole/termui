import 'dart:async';
import 'dart:math';
import 'package:termui/termui.dart';
import 'package:termui_test/termui_test.dart';
import 'package:termui_recorder/termui_recorder.dart';
import 'package:flutter_test/flutter_test.dart'
    hide find, Finder, findsOneWidget;
import 'package:termui_tinpot_example/termui_tinpot_app.dart';

class _FirstFinder extends Finder {
  final Finder finder;
  const _FirstFinder(this.finder);
  @override
  Iterable<Element> apply(Iterable<Element> candidates) {
    final results = finder.apply(candidates);
    return results.isEmpty ? [] : [results.first];
  }
}

void main() {
  group('TinpotApp Integration Tests', () {
    test('Mouse clicks on Select Image button trigger callback', () async {
      final tester = TerminalTester(size: const Point(80, 40));

      tester.run(() async {
        bool imagePicked = false;
        final controller = TinpotAppController()
          ..onPickImage = () async {
            imagePicked = true;
          };

        // Run the app without awaiting so it doesn't block the test
        unawaited(runTinpotApp(tester.terminal, controller: controller));

        await tester.pumpAndSettle();

        final selectImageBtn = _FirstFinder(find.text('Select Image'));
        expect(selectImageBtn, findsOneWidget);

        tester.tap(selectImageBtn);
        await tester.pumpAndSettle();
        expect(imagePicked, isTrue);

        // 2. Test slider dragging
        final sliders = find
            .byType<Slider>()
            .apply(collectAllElements(tester.rootElement!))
            .toList();
        expect(
          sliders.length,
          greaterThanOrEqualTo(2),
          reason: 'Expected at least 2 sliders (width and contrast)',
        );

        final widthSliderElement = sliders[0];
        final contrastSliderElement = sliders[1];

        void dragSlider(Element sliderElement, double fraction) {
          Offset offset = Offset.zero;
          Element? current = sliderElement;
          while (current != null) {
            offset += current.relativeOffset;
            current = current.parent;
          }
          final size = sliderElement.size;

          final int startX = (offset.dx + 1 + (size.width ~/ 2));
          final int startY = (offset.dy + 1 + (size.height ~/ 2));
          final int endX = (offset.dx + 1 + (size.width * fraction).toInt());

          tester.mouseDown(startX, startY);
          tester.mouseMove(endX, startY, drag: true);
          tester.mouseUp(endX, startY);
        }

        // Drag width slider to 10%
        dragSlider(widthSliderElement, 0.1);
        await tester.pumpAndSettle();

        final newSliders1 = find
            .byType<Slider>()
            .apply(collectAllElements(tester.rootElement!))
            .toList();
        final newWidthSlider = newSliders1[0].widget as Slider;
        expect(
          newWidthSlider.value,
          lessThan(80),
          reason: 'Width should decrease when dragged left',
        );

        // Drag contrast slider to 10%
        dragSlider(contrastSliderElement, 0.1);
        await tester.pumpAndSettle();

        final newSliders2 = find
            .byType<Slider>()
            .apply(collectAllElements(tester.rootElement!))
            .toList();
        final newContrastSlider1 = newSliders2[1].widget as Slider;
        expect(
          newContrastSlider1.value,
          lessThan(9.0),
          reason: 'Contrast should decrease when dragged left',
        );

        // Drag contrast slider to 90%
        dragSlider(contrastSliderElement, 0.9);
        await tester.pumpAndSettle();

        final newSliders3 = find
            .byType<Slider>()
            .apply(collectAllElements(tester.rootElement!))
            .toList();
        final newContrastSlider2 = newSliders3[1].widget as Slider;
        expect(
          newContrastSlider2.value,
          greaterThan(5.0),
          reason: 'Contrast should increase when dragged right',
        );

        tester.sendKey(LogicalKey.controlC);
        await tester.pumpAndSettle();
      });
    });

    test('UI matches golden file', () async {
      final tester = TerminalTester(size: const Point(100, 40));

      tester.run(() async {
        final controller = TinpotAppController();
        unawaited(runTinpotApp(tester.terminal, controller: controller));
        await tester.pumpAndSettle();

        expect(
          (tester.terminal.backend as MockTerminalBackend).buffer,
          matchesAnsiGolden('goldens/tinpot_app_initial.ansi'),
        );

        tester.sendKey(LogicalKey.controlC);
        await tester.pumpAndSettle();
      });
    });
  });
}
