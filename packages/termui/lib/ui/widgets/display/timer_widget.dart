import 'package:termui/termui.dart';

/// An interactive countdown timer widget.
///
/// It renders a digital clock readout (format "MM:SS") centered in its viewport
/// with an optional graphical progress bar on the line below.
///
/// ### Example Usage
///
/// ```dart
/// final timer = TimerWidget(
///   duration: const Duration(minutes: 5),
///   running: true,
///   onFinished: () {
///     print('Time is up!');
///   },
/// );
/// ```
///
/// ### Properties and Settings
///
/// | Property | Type | Description |
/// | :--- | :--- | :--- |
/// | `duration` | [Duration] | The current remaining duration of the countdown. |
/// | `initialDuration`| [Duration] | The starting countdown duration (for progress). |
/// | `onFinished` | `void Function()?` | Callback triggered when duration reaches zero. |
/// | `digitStyle` | [Style] | Rendering style for the digit characters. |
/// | `separatorStyle`| [Style] | Rendering style for the ':' character. |
/// | `progressStyle` | [Style] | Rendering style for the bottom progress bar. |
/// | `running` | [bool] | Active running/paused state of the timer. |
class TimerWidget extends Widget {
  /// The current remaining duration.
  Duration duration;

  /// The initial duration the timer started with.
  final Duration initialDuration;

  /// An optional callback executed when the timer finishes.
  final void Function()? onFinished;

  /// The styling for the digits of the countdown.
  final Style digitStyle;

  /// The styling for the separator character.
  final Style separatorStyle;

  /// The styling for the progress bar.
  final Style progressStyle;

  /// Indicates whether the timer is actively counting down.
  bool running;

  /// Creates a [TimerWidget] to display a countdown.
  TimerWidget({
    required this.duration,
    this.running = false,
    this.onFinished,
    this.digitStyle = const Style(
      foreground: Colors.orange,
      modifiers: Modifier.bold,
    ),
    this.separatorStyle = const Style(modifiers: Modifier.dim),
    this.progressStyle = const Style(foreground: Colors.green),
  }) : initialDuration = duration;

  /// Decrements the remaining duration by the specified [delta] amount.
  ///
  /// If the timer is not [running] or [duration] is already zero, this method
  /// has no effect. If the decrement causes the remaining time to fall at or
  /// below zero, the timer stops running, clamps to zero, and invokes
  /// [onFinished].
  ///
  /// | Parameter | Type | Description |
  /// | :--- | :--- | :--- |
  /// | `delta` | [Duration] | The time step duration to subtract. |
  void tick(Duration delta) {
    if (!running) return;
    if (duration > Duration.zero) {
      duration -= delta;
      if (duration <= Duration.zero) {
        duration = Duration.zero;
        running = false;
        if (onFinished != null) {
          onFinished!();
        }
      }
    }
  }

  @override
  Element createElement() => TimerWidgetElement(this);
}

/// An element that manages the rendering and layout of a [TimerWidget] widget.
class TimerWidgetElement extends Element {
  /// Creates a [TimerWidgetElement] for the given [widget].
  TimerWidgetElement(TimerWidget super.widget);

  @override
  Size performLayout(BoxConstraints constraints) {
    final w = constraints.maxWidth == BoxConstraints.infinity
        ? 10
        : constraints.maxWidth;
    final h = constraints.maxHeight == BoxConstraints.infinity
        ? 2
        : constraints.maxHeight;
    return constraints.constrain(Size(w, h));
  }

  @override
  void performPaint(Buffer buffer, Offset offset) {
    final viewport = Viewport(
      buffer,
      Rect(offset.dx, offset.dy, size.width, size.height),
    );
    final timer = widget as TimerWidget;
    if (size.width <= 0 || size.height <= 0) return;

    final minutes = timer.duration.inMinutes;
    final seconds = timer.duration.inSeconds % 60;

    final mm = minutes.toString().padLeft(2, '0');
    final ss = seconds.toString().padLeft(2, '0');

    const timeStringLength = 5; // "MM:SS"
    final startX = ((size.width - timeStringLength) / 2).floor().clamp(
      0,
      size.width,
    );

    // Draw digits & separators
    if (startX + 5 <= size.width) {
      viewport.writeString(startX, 0, mm, timer.digitStyle);
      viewport.writeString(startX + 2, 0, ':', timer.separatorStyle);
      viewport.writeString(startX + 3, 0, ss, timer.digitStyle);
    } else {
      // Fallback: draw what fits
      final fallback = '$mm:$ss'.substring(0, size.width);
      viewport.writeString(0, 0, fallback, timer.digitStyle);
    }

    if (size.height >= 2) {
      // Draw progress bar below
      final progress = timer.initialDuration.inMilliseconds == 0
          ? 0.0
          : timer.duration.inMilliseconds /
                timer.initialDuration.inMilliseconds;

      final progressWidth = size.width;
      final filledCount = (progress * progressWidth).round().clamp(
        0,
        progressWidth,
      );

      final barText = '█' * filledCount + '░' * (progressWidth - filledCount);
      viewport.writeString(0, 1, barText, timer.progressStyle);
    }
  }
}
