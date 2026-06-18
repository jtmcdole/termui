import '../buffer.dart';
import '../style.dart';
import '../layout.dart';
import 'package:clock/clock.dart';

/// An interface for widgets that support animation ticks or time-based rendering.
abstract class Animatable {
  /// Whether this object is currently animating.
  bool get isAnimatable;
}

/// A widget for displaying animated loading/waiting indicators in a TUI.
///
/// It supports automatic wall-clock time-based updates, manual frame ticks,
/// and custom spinner frames.
///
/// ### Predefined Constructors
/// - [Spinner.dots]: Classic Braille dots spinner (`⠋`, `⠙`, `⠹`...).
/// - [Spinner.line]: Classic line/pipe character spinner (`|`, `/`, `-`, `\`).
/// - [Spinner.pulse]: Pulsing block/shade density spinner (`░`, `▒`, `▓`...).
///
/// ### Example Usage
///
/// ```dart
/// final spinner = Spinner.dots(
///   style: Style(foreground: Color(0xFF00FFFF)),
///   speed: Duration(milliseconds: 80),
/// );
/// ```
///
/// ### Properties and Settings
///
/// | Property | Type | Description |
/// | :--- | :--- | :--- |
/// | `frames` | [List]<[String]> | The sequence of characters shown per frame. |
/// | `style` | [Style] | Rendering style (foreground/background color). |
/// | `speed` | [Duration] | Frame rate interval between animations. |
/// | `paused` | [bool] | Stops the animation on the first frame if true. |
class Spinner extends Widget implements Animatable {
  /// The sequence of character frames to cycle through.
  final List<String> frames;

  /// The style applied to the spinner characters.
  final Style style;

  /// The time duration between frame updates.
  final Duration speed;

  /// Whether the spinner animation is currently paused.
  final bool paused;

  /// An optional stopwatch to override the global clock, useful for rendering multiple states.
  final Stopwatch clockStopwatch;
  static final Stopwatch _globalStopwatch = clock.stopwatch()..start();

  int _manualTicks = 0;
  bool _useWallClock = true;

  @override
  bool get isAnimatable => !paused;

  /// Creates a [Spinner] widget with custom frames.
  Spinner({
    required this.frames,
    this.style = Style.empty,
    this.speed = const Duration(milliseconds: 100),
    this.paused = false,
    Stopwatch? clockStopwatch,
  }) : clockStopwatch = clockStopwatch ?? _globalStopwatch;

  /// Creates a classic 10-frame Braille dots spinner.
  factory Spinner.dots({
    Style style = Style.empty,
    Duration speed = const Duration(milliseconds: 80),
    bool paused = false,
    Stopwatch? clockStopwatch,
  }) => Spinner(
    frames: const ['⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏'],
    style: style,
    speed: speed,
    paused: paused,
    clockStopwatch: clockStopwatch,
  );

  /// Creates a classic 4-frame rotating line spinner.
  factory Spinner.line({
    Style style = Style.empty,
    Duration speed = const Duration(milliseconds: 100),
    bool paused = false,
    Stopwatch? clockStopwatch,
  }) => Spinner(
    frames: const ['|', '/', '-', '\\'],
    style: style,
    speed: speed,
    paused: paused,
    clockStopwatch: clockStopwatch,
  );

  /// Creates a 6-frame pulsing density block spinner.
  factory Spinner.pulse({
    Style style = Style.empty,
    Duration speed = const Duration(milliseconds: 120),
    bool paused = false,
    Stopwatch? clockStopwatch,
  }) => Spinner(
    frames: const ['░', '▒', '▓', '█', '▓', '▒'],
    style: style,
    speed: speed,
    paused: paused,
    clockStopwatch: clockStopwatch,
  );

  /// Advance the spinner to the next frame (manual control).
  void tick() {
    _useWallClock = false;
    _manualTicks++;
  }

  /// Get the current visible frame.
  String get currentFrame {
    if (paused) {
      return frames[0];
    }
    if (_useWallClock) {
      final elapsed = clockStopwatch.elapsedMilliseconds;
      final idx = (elapsed ~/ speed.inMilliseconds) % frames.length;
      return frames[idx];
    } else {
      return frames[_manualTicks % frames.length];
    }
  }

  @override
  Element createElement() => SpinnerElement(this);
}

/// An element that manages the rendering and layout of a [Spinner] widget.
class SpinnerElement extends Element {
  /// Creates a [SpinnerElement] for the given [widget].
  SpinnerElement(Spinner super.widget);

  @override
  Size performLayout(BoxConstraints constraints) {
    return constraints.constrain(const Size(1, 1));
  }

  @override
  void performPaint(Buffer buffer, Offset offset) {
    final spinner = widget as Spinner;
    buffer.writeString(
      offset.dx,
      offset.dy,
      spinner.currentFrame,
      spinner.style,
    );
  }
}
