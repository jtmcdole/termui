import 'package:termui/ui/layout.dart';
import 'package:termui/ui/style.dart';
import 'package:termui/ui/color.dart';
import 'package:termui/ui/widget_toolkit.dart';
import 'example_base.dart';

/// Example demonstrating various progress indicators and spinners.
class IndicatorsExample extends WidgetBookExample {
  /// The current progress value (0.0 to 1.0).
  double progressVal = 0.0;

  /// The current frame count for spinner animation.
  int frameCount = 0;

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
  bool tick(Duration duration) {
    progressVal += 0.005;
    if (progressVal > 1.0) progressVal = 0.0;

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
        child: Text('1. Standard Progress Bar (Block, Linear):'),
      ),
      SizedBox(
        height: 1,
        child: LinearProgressIndicator(progressVal, showPercentage: true),
      ),
      const SizedBox(height: 1, child: Text('')),
      SizedBox(
        height: 1,
        child: Text('2. Smooth Progress Bar (Eighths, easeInOutCubic):'),
      ),
      SizedBox(
        height: 1,
        child: LinearProgressIndicator(
          progressVal,
          smooth: true,
          showPercentage: true,
          easing: Easing.easeInOutCubic,
        ),
      ),
      const SizedBox(height: 1, child: Text('')),
      SizedBox(
        height: 1,
        child: Text(
          '3. Gradient Smooth Progress Bar (Cherry -> Julep, easeOutBounce):',
        ),
      ),
      SizedBox(
        height: 1,
        child: LinearProgressIndicator(
          progressVal,
          smooth: true,
          showPercentage: true,
          startColor: CharmColors.cherry,
          endColor: CharmColors.julep,
          easing: Easing.easeOutBounce,
        ),
      ),
      const SizedBox(height: 1, child: Text('')),
      SizedBox(
        height: 1,
        child: Row([
          const SizedBox(
            width: 17,
            child: Text('Spinners:  Line [', wrap: false),
          ),
          SizedBox(width: 1, child: spinnerLine),
          const SizedBox(width: 10, child: Text(']   Dots [', wrap: false)),
          SizedBox(width: 1, child: spinnerDots),
          const SizedBox(width: 1, child: Text(']', wrap: false)),
        ]),
      ),
      const Expanded(child: Text('')),
    ]);
  }
}
