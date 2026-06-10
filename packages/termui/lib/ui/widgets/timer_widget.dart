import '../buffer.dart';
import '../style.dart';
import '../layout.dart';
import '../color.dart';

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
  void render(Buffer buffer, Rect area) {
    if (area.width <= 0 || area.height <= 0) return;

    final minutes = duration.inMinutes;
    final seconds = duration.inSeconds % 60;

    final mm = minutes.toString().padLeft(2, '0');
    final ss = seconds.toString().padLeft(2, '0');

    final timeStringLength = 5; // "MM:SS"
    final startX = ((area.width - timeStringLength) / 2).floor().clamp(
      0,
      area.width,
    );

    // Draw digits & separators
    if (startX + 5 <= area.width) {
      buffer.writeString(startX, 0, mm, digitStyle);
      buffer.writeString(startX + 2, 0, ':', separatorStyle);
      buffer.writeString(startX + 3, 0, ss, digitStyle);
    } else {
      // Fallback: draw what fits
      final fallback = '$mm:$ss'.substring(0, area.width);
      buffer.writeString(0, 0, fallback, digitStyle);
    }

    if (area.height >= 2) {
      // Draw progress bar below
      final progress = initialDuration.inMilliseconds == 0
          ? 0.0
          : duration.inMilliseconds / initialDuration.inMilliseconds;

      final progressWidth = area.width;
      final filledCount = (progress * progressWidth).round().clamp(
        0,
        progressWidth,
      );

      final barText = '█' * filledCount + '░' * (progressWidth - filledCount);
      buffer.writeString(0, 1, barText, progressStyle);
    }
  }
}
