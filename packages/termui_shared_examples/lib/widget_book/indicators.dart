import 'package:termui/termui.dart';
import 'package:termui/ui/event.dart' as ui;
import 'example_base.dart';

/// Example demonstrating various progress indicators and spinners.
class IndicatorsExample extends WidgetBookExample {
  /// The current progress value (0.0 to 1.0).
  double progressVal = 0.0;

  /// The current frame count for spinner animation.
  int frameCount = 0;

  /// The active cross axis fill mode, toggleable via 'p'.
  CrossAxisFill fillMode = CrossAxisFill.span;

  /// Whether progress incrementing is paused, toggleable via spacebar.
  bool isPaused = false;

  /// A line-style spinner.
  final spinnerLine = Spinner.line(
    style: const Style(foreground: CharmColors.tang, modifiers: Modifier.bold),
  );

  /// A dot-style spinner.
  final spinnerDots = Spinner.dots(
    style: const Style(foreground: CharmColors.julep, modifiers: Modifier.bold),
  );

  @override
  bool get requiresTick => true;

  @override
  bool handleKeyEvent(ui.KeyEvent event) {
    if (event.key == 'p') {
      fillMode = fillMode == CrossAxisFill.span
          ? CrossAxisFill.precise
          : CrossAxisFill.span;
      return true;
    } else if (event.key == ' ') {
      isPaused = !isPaused;
      return true;
    }
    return false;
  }

  @override
  bool tick(Duration duration) {
    if (!isPaused) {
      progressVal += 0.005;
      if (progressVal > 1.0) progressVal = 0.0;
    }

    frameCount++;
    if (frameCount % 6 == 0) {
      spinnerLine.tick();
      spinnerDots.tick();
    }
    return true;
  }

  @override
  Widget build({
    required bool focusDemoPane,
    required int width,
    required int height,
  }) {
    return Column([
      SizedBox(
        height: 1,
        child: Text(
          'Press [p] to toggle fill mode: ${fillMode.name}  |  Press [Space] to ${isPaused ? 'resume' : 'pause'}',
          style: const Style(modifiers: Modifier.bold),
        ),
      ),
      const SizedBox(height: 1, child: Text('')),

      // 1, 2, 3 wide braille and eighths
      SizedBox(height: 1, child: Text('Braille Horizontal (1, 2, 3 high):')),
      SizedBox(
        height: 1,
        child: LinearProgressIndicator(
          progressVal,
          barType: ProgressBarType.braille,
          crossAxisFill: fillMode,
          showPercentage: false,
        ),
      ),
      const SizedBox(height: 1, child: Text('')),
      SizedBox(
        height: 2,
        child: LinearProgressIndicator(
          progressVal,
          barType: ProgressBarType.braille,
          crossAxisFill: fillMode,
          showPercentage: false,
        ),
      ),
      const SizedBox(height: 1, child: Text('')),
      SizedBox(
        height: 3,
        child: LinearProgressIndicator(
          progressVal,
          barType: ProgressBarType.braille,
          crossAxisFill: fillMode,
          showPercentage: true,
        ),
      ),
      const SizedBox(height: 1, child: Text('')),

      SizedBox(height: 1, child: Text('Eighths Horizontal (1, 2, 3 high):')),
      SizedBox(
        height: 1,
        child: LinearProgressIndicator(
          progressVal,
          barType: ProgressBarType.blocks,
          smooth: true,
          crossAxisFill: fillMode,
          showPercentage: false,
        ),
      ),
      const SizedBox(height: 1, child: Text('')),
      SizedBox(
        height: 2,
        child: LinearProgressIndicator(
          progressVal,
          barType: ProgressBarType.blocks,
          smooth: true,
          crossAxisFill: fillMode,
          showPercentage: false,
        ),
      ),
      const SizedBox(height: 1, child: Text('')),
      SizedBox(
        height: 3,
        child: LinearProgressIndicator(
          progressVal,
          barType: ProgressBarType.blocks,
          smooth: true,
          crossAxisFill: fillMode,
          showPercentage: true,
        ),
      ),
      const SizedBox(height: 1, child: Text('')),

      // Vertical Options
      SizedBox(height: 1, child: Text('Vertical Options (Braille & Blocks):')),
      SizedBox(
        height: 6,
        child: Row([
          SizedBox(
            width: 15,
            child: Column([
              const SizedBox(height: 1, child: Text('bottom to top')),
              Expanded(
                child: Row([
                  SizedBox(
                    width: 3,
                    child: LinearProgressIndicator(
                      progressVal,
                      direction: ProgressDirection.bottomToTop,
                      barType: ProgressBarType.braille,
                      crossAxisFill: fillMode,
                      showPercentage: false,
                    ),
                  ),
                ]),
              ),
            ]),
          ),
          const SizedBox(width: 4, child: Text('')),
          SizedBox(
            width: 15,
            child: Column([
              const SizedBox(height: 1, child: Text('top to bottom')),
              Expanded(
                child: Row([
                  SizedBox(
                    width: 5,
                    child: LinearProgressIndicator(
                      progressVal,
                      direction: ProgressDirection.topToBottom,
                      barType: ProgressBarType.blocks,
                      style: const Style(
                        foreground: CharmColors.pepper,
                        background: CharmColors.iron,
                      ),
                      smooth: true,
                      crossAxisFill: fillMode,
                      showPercentage: false,
                    ),
                  ),
                ]),
              ),
            ]),
          ),
        ]),
      ),
      const SizedBox(height: 1, child: Text('')),

      // Multiple stops with easeInOutBounce
      SizedBox(
        height: 1,
        child: Text('Multiple Gradient Stops (easeInOutCubic):'),
      ),
      SizedBox(
        height: 1,
        child: LinearProgressIndicator(
          progressVal,
          barType: ProgressBarType.blocks,
          smooth: true,
          easing: Easing.easeInOutCubic,
          colorBuilder: (fraction, fill) => (
            fg: [
              (color: CharmColors.cherry, stop: 0.0),
              (color: CharmColors.julep, stop: 0.5),
              (color: CharmColors.tang, stop: 1.0),
            ],
            bg: null,
          ),
        ),
      ),
      SizedBox(
        height: 1,
        child: Row([
          Text('^ stop 1 (cherry)'),
          Expanded(child: Text('')),
          Text('^ stop 2 (julep)'),
          Expanded(child: Text('')),
          Text('^ stop 3 (tang)'),
        ]),
      ),
      const SizedBox(height: 1, child: Text('')),

      // Trippy gradient using fullness with bounce
      SizedBox(
        height: 1,
        child: Text('Trippy Dynamic Gradient (easeOutBounce, solid 8ths):'),
      ),
      SizedBox(
        height: 2,
        child: LinearProgressIndicator(
          progressVal,
          barType: ProgressBarType.blocks,
          smooth: true,
          easing: Easing.easeOutBounce,
          crossAxisFill: fillMode,
          colorBuilder: (fraction, fill) {
            // Dynamic colors shifting over time based on fraction/fill
            final v = (fill * 255).toInt().clamp(0, 255);
            return (
              fg: [
                (color: Color(255 - v, v, 255), stop: 0.0),
                (color: Color(255, 255 - v, v), stop: 1.0),
              ],
              bg: null,
            );
          },
        ),
      ),

      const Expanded(child: Text('')),
    ]);
  }
}
