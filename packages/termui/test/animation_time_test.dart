import 'dart:math';
import 'package:test/test.dart';
import 'package:fake_async/fake_async.dart';
import 'package:termui/ui/widgets/display/spinner.dart';
import 'package:termui/ui/animation/animation_effect.dart';
import 'package:termui/ui/buffer.dart';
import 'package:termui/ui/widgets/layout/row.dart';
import 'package:termui/ui/widgets/core/widget.dart';
import 'package:termui/ui/widgets/core/geometry.dart';
import 'package:termui/ui/style.dart';

final class TestAnimationEffect extends TuiAnimationEffect {
  TestAnimationEffect({required super.duration});

  @override
  void paint(Buffer buffer, Rect area, Style baseStyle) {
    // No-op for testing progress calculation
  }
}

void main() {
  group('Animation Time Tests with clock and fake_async', () {
    test('Spinner progresses deterministically based on fake time', () {
      fakeAsync((async) {
        final spinner = Spinner.dots(speed: const Duration(milliseconds: 100));

        // Initial frame
        expect(spinner.currentFrame, '⠋');

        // Advance time by 100ms
        async.elapse(const Duration(milliseconds: 100));
        expect(spinner.currentFrame, '⠙');

        // Advance time by another 200ms (total 300ms elapsed)
        async.elapse(const Duration(milliseconds: 200));
        expect(spinner.currentFrame, '⠸');
      });
    });

    test(
      'TuiAnimationEffect progresses deterministically based on fake time',
      () {
        fakeAsync((async) {
          final effect = TestAnimationEffect(
            duration: const Duration(milliseconds: 1000),
          );

          // Start animation
          effect.start(const Point(0, 0), () {});

          expect(effect.progress, 0.0);

          // Advance 500ms -> progress 0.5
          async.elapse(const Duration(milliseconds: 500));
          expect(effect.progress, closeTo(0.5, 0.01));

          // Advance another 500ms -> progress 1.0
          async.elapse(const Duration(milliseconds: 500));
          expect(effect.progress, 1.0);

          // Tick to complete the animation
          effect.tick();
          expect(effect.isAnimating, isFalse);
        });
      },
    );

    test(
      'Can render multiple spinner states on the same line using optional stopwatches',
      () {
        final width = 20;
        final buffer = Buffer.blank(width, 1);

        final layout = Row([
          Spinner.dots(clockStopwatch: MockStopwatch(0)),
          Spinner.dots(clockStopwatch: MockStopwatch(80)),
          Spinner.dots(clockStopwatch: MockStopwatch(160)),
          Spinner.dots(clockStopwatch: MockStopwatch(240)),
          Spinner.dots(clockStopwatch: MockStopwatch(320)),
        ]);

        final elementWrapper = ElementWidget(layout);
        elementWrapper.layout(BoxConstraints.tight(Size(width, 1)));
        elementWrapper.paint(buffer, Offset.zero);

        // With Row layout, each gets equal width (4 columns out of 20).
        expect(buffer.getCharacter(0, 0), '⠋');
        expect(buffer.getCharacter(4, 0), '⠙');
        expect(buffer.getCharacter(8, 0), '⠹');
        expect(buffer.getCharacter(12, 0), '⠸');
        expect(buffer.getCharacter(16, 0), '⠼');
      },
    );
  });
}

class MockStopwatch implements Stopwatch {
  final int _elapsedMs;
  MockStopwatch(this._elapsedMs);

  @override
  int get elapsedMilliseconds => _elapsedMs;

  @override
  int get elapsedMicroseconds => _elapsedMs * 1000;

  @override
  Duration get elapsed => Duration(milliseconds: _elapsedMs);

  @override
  int get elapsedTicks => _elapsedMs * 1000;

  @override
  int get frequency => 1000000;

  @override
  bool get isRunning => true;

  @override
  void reset() {}

  @override
  void start() {}

  @override
  void stop() {}
}
