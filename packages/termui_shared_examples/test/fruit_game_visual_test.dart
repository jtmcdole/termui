import 'dart:math';
import 'package:test/test.dart';
import 'package:termui/termui.dart';
import 'package:termui_test/termui_test.dart';
import 'package:termui_shared_examples/widget_book/fruit_game.dart';

Offset getAbsoluteOffset(Element element) {
  Offset offset = Offset.zero;
  Element? current = element;
  while (current != null) {
    offset += current.relativeOffset;
    current = current.parent;
  }
  return offset;
}

void main() {
  test('Verify 3 fruit are visible and no visual distortions on drag and drop', () {
    final tester = TerminalTester(size: const Point<int>(80, 24));
    tester.run(() async {
      final example = FruitGameExample()..init();
      example.currentSlots[0] = '🍎';
      example.currentSlots[1] = '🍊';
      example.currentSlots[2] = '🍇';

      await tester.pumpWidget(
        example.build(focusDemoPane: true, width: 80, height: 24),
      );

      // Verify all 3 fruits are fully rendered and visible without clipping.
      expect(
        find.text(' [ 🍎 ] '),
        findsOneWidget,
        reason: 'First fruit is missing or clipped',
      );
      expect(
        find.text(' [ 🍊 ] '),
        findsOneWidget,
        reason: 'Second fruit is missing or clipped',
      );
      expect(
        find.text(' [ 🍇 ] '),
        findsOneWidget,
        reason: 'Third fruit is missing or clipped',
      );

      // Check if fruits are visibly horizontally aligned without overflow
      final buffer = tester.buffer!;
      var fruitLineStr = '';
      for (var y = 0; y < buffer.height; y++) {
        var line = '';
        for (var x = 0; x < buffer.width; x++) {
          line += buffer.getCharacter(x, y);
        }
        if (line.contains('🍎')) {
          fruitLineStr = line;
        }
      }
      expect(fruitLineStr.contains('🍎'), isTrue);
      expect(fruitLineStr.contains('🍊'), isTrue);
      expect(
        fruitLineStr.contains('🍇'),
        isTrue,
        reason:
            'Third fruit is clipped/wrapped and not visible on the same line',
      );

      final fruitFinder = find.text(' [ 🍎 ] ');
      final fruitElements = fruitFinder
          .apply(collectAllElements(tester.rootElement!))
          .toList();
      final absoluteOffset = getAbsoluteOffset(fruitElements.first);

      final startX = absoluteOffset.dx.toInt() + 2;
      final startY = absoluteOffset.dy.toInt() + 1;

      tester.mouseDown(startX, startY);
      await tester.pump();

      // We drag the fruit across the right border of the playfield to trigger the distortion.
      tester.mouseMove(58, 10);
      await tester.pump();

      tester.mouseUp(58, 10);
      await tester.pump();

      await tester.pump(const Duration(milliseconds: 100));

      final ansiOutput = tester.backend.stdout;
      // Termui clears and moves to specific coords. If the buffer correctly emitted spaces,
      // it should not leave dangling emoji cells causing the terminal to shift border chars.
      // But instead of testing ANSI output which could be complex, we can check if `Renderer`
      // wrote a space over the second half of the wide char!
      // However, terminal ANSI sequence check for duplicated borders:
      expect(
        ansiOutput.contains('┐┐'),
        isFalse,
        reason: 'Found distorted borders with duplicated characters',
      );
      expect(
        ansiOutput.contains('││'),
        isFalse,
        reason: 'Found distorted borders with duplicated characters',
      );
    });
  });
}
