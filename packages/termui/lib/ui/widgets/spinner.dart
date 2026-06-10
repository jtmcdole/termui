import '../buffer.dart';
import '../style.dart';
import '../layout.dart';

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
  static final int _globalStartTimeMs = DateTime.now().millisecondsSinceEpoch;

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
  });

  /// Creates a classic 10-frame Braille dots spinner.
  factory Spinner.dots({
    Style style = Style.empty,
    Duration speed = const Duration(milliseconds: 80),
    bool paused = false,
  }) => Spinner(
    frames: const ['⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏'],
    style: style,
    speed: speed,
    paused: paused,
  );

  /// Creates a classic 4-frame rotating line spinner.
  factory Spinner.line({
    Style style = Style.empty,
    Duration speed = const Duration(milliseconds: 100),
    bool paused = false,
  }) => Spinner(
    frames: const ['|', '/', '-', '\\'],
    style: style,
    speed: speed,
    paused: paused,
  );

  /// Creates a 6-frame pulsing density block spinner.
  factory Spinner.pulse({
    Style style = Style.empty,
    Duration speed = const Duration(milliseconds: 120),
    bool paused = false,
  }) => Spinner(
    frames: const ['░', '▒', '▓', '█', '▓', '▒'],
    style: style,
    speed: speed,
    paused: paused,
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
      final elapsed =
          DateTime.now().millisecondsSinceEpoch - _globalStartTimeMs;
      final idx = (elapsed ~/ speed.inMilliseconds) % frames.length;
      return frames[idx];
    } else {
      return frames[_manualTicks % frames.length];
    }
  }

  @override
  void render(Buffer buffer, Rect area) {
    if (area.width <= 0 || area.height <= 0) return;
    buffer.writeString(0, 0, currentFrame, style);
  }
}
