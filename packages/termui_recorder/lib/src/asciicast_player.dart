import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'package:characters/characters.dart';
import 'package:clock/clock.dart';
import 'package:termui/terminal/terminal.dart';
import 'package:termui/ui/buffer.dart';

typedef _ParsedCast = ({int width, int height, List<AsciicastEvent> events});

/// Represents a single event inside an Asciicast recording.
final class AsciicastEvent {
  /// The timestamp of the event in seconds.
  final double time;

  /// The type of the event (e.g. 'o' for output, 'd' for debug/metadata).
  final String type;

  /// The string payload of the event.
  final String data;

  /// Creates a new asciicast event.
  AsciicastEvent(this.time, this.type, this.data);
}

/// A player that reads Asciinema Asciicast v2 data (.cast) and plays it
/// back in the terminal with interactive playback and time-travel controls.
final class AsciicastPlayer {
  static final RegExp _dangerousEscapeRegex = RegExp(
    r'\x1b(?:\][\s\S]*?(?:\x07|\x1b\\|$)|[P^_][\s\S]*?(?:\x1b\\|$)|\[[?>=]?[0-9;]*c)',
  );

  /// The raw JSONL asciicast string data to play.
  final String asciicastData;

  final StringSink? _stdoutOverride;

  /// Creates a new [AsciicastPlayer] for the given [asciicastData].
  AsciicastPlayer(this.asciicastData, {StringSink? stdout})
    : _stdoutOverride = stdout;

  /// Strips host-manipulating escape sequences (OSC, DCS, PM, APC, and DA CSI)
  /// from recorded terminal output before writing to a host terminal.
  static String sanitizeOutput(String data) =>
      data.replaceAll(_dangerousEscapeRegex, '');

  /// Plays the asciicast session back to the terminal.
  ///
  /// * [speedMultiplier]: Speed factor (e.g., 2.0 for double speed, 0.5 for half speed).
  /// * [interactive]: Enables keyboard controls during playback:
  ///   - `Space`: Pause/resume playback
  ///   - `.` (Period): Step forward one frame (only works if paused)
  ///   - `,` (Comma): Step backward one frame (only works if paused)
  ///   - `+` or `=`: Speed up playback (x1.25)
  ///   - `-` or `_`: Slow down playback (x0.8)
  ///   - `q` or `Escape`: Quit playback
  Future<void> play({
    double speedMultiplier = 1.0,
    bool interactive = true,
    bool paused = false,
    bool noCloseAtEnd = false,
  }) async {
    final parsed = _parseAsciicast(asciicastData);
    if (parsed == null) return;

    if (!interactive) {
      await _playNonInteractive(parsed.events, speedMultiplier);
      return;
    }

    await Terminal.runGuarded((terminal) async {
      final session = _InteractivePlaybackSession(
        terminal: terminal,
        events: parsed.events,
        castWidth: parsed.width,
        castHeight: parsed.height,
        initialPaused: paused || speedMultiplier == 0.0,
        initialSpeed: speedMultiplier == 0.0
            ? 1.0
            : math.max(0.1, speedMultiplier),
        noCloseAtEnd: noCloseAtEnd,
        renderStatusBar: _renderStatusBar,
      );
      await session.run();
    });
  }

  static _ParsedCast? _parseAsciicast(String raw) {
    final lines = const LineSplitter().convert(raw);
    if (lines.isEmpty) return null;

    final (castWidth, castHeight, version) = _parseHeader(lines.first);
    final events = _parseEvents(lines, version);
    if (events.isEmpty) return null;
    return (width: castWidth, height: castHeight, events: events);
  }

  static (int width, int height, int version) _parseHeader(String headerLine) {
    try {
      final header = jsonDecode(headerLine) as Map<String, Object?>;
      final version = header['version'] as int? ?? 2;
      if (version == 3) {
        final term = header['term'] as Map<String, Object?>?;
        return (
          term?['cols'] as int? ?? 80,
          term?['rows'] as int? ?? 24,
          version,
        );
      }
      return (
        header['width'] as int? ?? 80,
        header['height'] as int? ?? 24,
        version,
      );
    } catch (_) {
      return (80, 24, 2);
    }
  }

  static List<AsciicastEvent> _parseEvents(List<String> lines, int version) {
    final events = <AsciicastEvent>[];
    var accumulatedTime = 0.0;
    for (var i = 1; i < lines.length; i++) {
      final line = lines[i].trim();
      if (line.isEmpty) continue;
      final event = _tryDecodeEventLine(line, version, accumulatedTime);
      if (event != null) {
        accumulatedTime = event.time;
        events.add(event);
      }
    }
    return events;
  }

  static AsciicastEvent? _tryDecodeEventLine(
    String line,
    int version,
    double accumulatedTime,
  ) {
    try {
      if (jsonDecode(line) case [
        final num timestamp,
        final String eventType,
        final data,
      ]) {
        final time = version == 3
            ? accumulatedTime + timestamp.toDouble()
            : timestamp.toDouble();
        final dataStr = data is String ? data : jsonEncode(data);
        return AsciicastEvent(time, eventType, dataStr);
      }
    } catch (_) {
      // Skip malformed lines
    }
    return null;
  }

  Future<void> _playNonInteractive(
    List<AsciicastEvent> events,
    double speedMultiplier,
  ) async {
    final out = _stdoutOverride;
    final speed = speedMultiplier <= 0 ? 1.0 : speedMultiplier;
    final stopwatch = clock.stopwatch()..start();
    for (final event in events) {
      if (event.type != 'o') continue;
      final targetRealElapsedMs = event.time * 1000.0 / speed;
      final sleepMs = (targetRealElapsedMs - stopwatch.elapsedMilliseconds)
          .round();
      if (sleepMs > 0) {
        await Future<void>.delayed(Duration(milliseconds: sleepMs));
      }
      final safeData = sanitizeOutput(event.data);
      if (out != null) {
        out.write(safeData);
      } else {
        print(safeData);
      }
    }
  }

  void _renderStatusBar(
    Terminal terminal,
    bool isPaused,
    double speed,
    int castWidth,
    int castHeight,
    List<AsciicastEvent> events,
    int nextIndex,
  ) {
    final size = terminal.backend.size;
    final termWidth = size.x > 0 ? size.x : castWidth;
    if (termWidth < 2) return;
    final termHeight = size.y > 0 ? size.y : castHeight;
    final row = termHeight;

    final metadataText = _findMetadataForIndex(events, nextIndex - 1);
    final speedStr = speed.toStringAsFixed(2);
    final statusText = _truncateToDisplayWidth(
      ' [${isPaused ? "PAUSED" : "PLAYING"}] Speed: ${speedStr}x | (Space: Pause, +/-: Speed, q: Quit, ,/.: Step) ',
      termWidth,
    );

    final sb = StringBuffer()..write('\x1b[s');
    final boxTopRow = row - 2;
    final boxContentRow = row - 1;

    if (metadataText.isNotEmpty && boxTopRow >= 1) {
      const title = ' Debug Metadata ';
      final titleWidth = _displayWidth(title);
      final borderLen = termWidth - titleWidth - 2;
      final topBorder = termWidth >= titleWidth + 3
          ? '┌─$title${'─' * (borderLen > 0 ? borderLen : 0)}┐'
          : '┌${'─' * (termWidth - 2)}┐';
      sb.write('\x1b[$boxTopRow;1H\x1b[K$topBorder');

      final contentWidth = termWidth - 2;
      final contentStr = _padOrTruncateDisplayWidth(metadataText, contentWidth);
      sb.write('\x1b[$boxContentRow;1H\x1b[K│$contentStr│');
    }

    sb.write('\x1b[$row;1H\x1b[7m$statusText\x1b[0m\x1b[K');
    sb.write('\x1b[u');
    terminal.backend.write(sb.toString());
  }

  static String _findMetadataForIndex(
    List<AsciicastEvent> events,
    int activeIndex,
  ) {
    if (activeIndex <= 0 || activeIndex >= events.length) return '';
    final activeEvent = events[activeIndex];
    final prevEvent = events[activeIndex - 1];
    if (activeEvent.type == 'o' &&
        prevEvent.type == 'd' &&
        prevEvent.time == activeEvent.time) {
      return prevEvent.data;
    }
    return '';
  }

  static int _displayWidth(String text) {
    var width = 0;
    for (final grapheme in text.characters) {
      width += graphemeWidth(grapheme);
    }
    return width;
  }

  static String _truncateToDisplayWidth(String text, int maxWidth) {
    if (maxWidth <= 0) return '';
    final sb = StringBuffer();
    var usedWidth = 0;
    for (final grapheme in text.characters) {
      final w = graphemeWidth(grapheme);
      if (usedWidth + w > maxWidth) break;
      sb.write(grapheme);
      usedWidth += w;
    }
    return sb.toString();
  }

  static String _padOrTruncateDisplayWidth(String text, int targetWidth) {
    if (targetWidth <= 0) return '';
    final sb = StringBuffer();
    var usedWidth = 0;
    for (final grapheme in text.characters) {
      final w = graphemeWidth(grapheme);
      if (usedWidth + w > targetWidth) break;
      sb.write(grapheme);
      usedWidth += w;
    }
    if (usedWidth < targetWidth) {
      sb.write(' ' * (targetWidth - usedWidth));
    }
    return sb.toString();
  }
}

typedef _StatusBarRenderer =
    void Function(
      Terminal terminal,
      bool isPaused,
      double speed,
      int castWidth,
      int castHeight,
      List<AsciicastEvent> events,
      int nextIndex,
    );

final class _InteractivePlaybackSession {
  final Terminal terminal;
  final List<AsciicastEvent> events;
  final int castWidth;
  final int castHeight;
  final bool noCloseAtEnd;
  final _StatusBarRenderer renderStatusBar;

  final Stopwatch stopwatch = clock.stopwatch()..start();
  bool isPaused;
  double speed;
  bool quit = false;
  bool hasSteppedWhilePaused = false;
  int totalPausedMs = 0;
  int pauseStartMs = 0;
  double recordedTimeAtLastSpeedChange = 0.0;
  double realTimeAtLastSpeedChangeMs = 0.0;
  _InterruptibleSleep? currentSleep;
  int currentIndex = 0;

  _InteractivePlaybackSession({
    required this.terminal,
    required this.events,
    required this.castWidth,
    required this.castHeight,
    required bool initialPaused,
    required double initialSpeed,
    required this.noCloseAtEnd,
    required this.renderStatusBar,
  }) : isPaused = initialPaused,
       speed = initialSpeed;

  Future<void> run() async {
    terminal.enterAlternateScreen();
    terminal.hideCursor();
    terminal.clear();
    terminal.home();

    final keySubscription = terminal.events.listen(_handleTerminalEvent);
    _drawStatus(currentIndex);

    try {
      await _playbackLoop();
    } finally {
      await keySubscription.cancel();
      terminal.exitAlternateScreen();
      terminal.showCursor();
    }
  }

  Future<void> _playbackLoop() async {
    while ((currentIndex < events.length || noCloseAtEnd) && !quit) {
      if (currentIndex >= events.length || isPaused) {
        if (currentIndex >= events.length) isPaused = true;
        await _sleepMs(50);
        continue;
      }

      final event = events[currentIndex];
      final sleepMs = _computeSleepMs(event.time);
      if (sleepMs > 0) {
        await _sleepMs(sleepMs);
        if (quit || isPaused) continue;
      }

      if (event.type == 'o') {
        terminal.backend.write(AsciicastPlayer.sanitizeOutput(event.data));
      }
      _drawStatus(currentIndex + 1);
      currentIndex++;
    }
  }

  int _computeSleepMs(double eventTime) {
    final actualRealElapsedMs = stopwatch.elapsedMilliseconds - totalPausedMs;
    final targetRealElapsedMs =
        realTimeAtLastSpeedChangeMs +
        (eventTime - recordedTimeAtLastSpeedChange) * 1000.0 / speed;
    return (targetRealElapsedMs - actualRealElapsedMs).round();
  }

  Future<void> _sleepMs(int ms) {
    final sleep = _InterruptibleSleep();
    currentSleep = sleep;
    return sleep.sleep(Duration(milliseconds: ms));
  }

  void _drawStatus(int nextIndex) {
    renderStatusBar(
      terminal,
      isPaused,
      speed,
      castWidth,
      castHeight,
      events,
      nextIndex,
    );
  }

  void _alignPlaybackTime(double eventTime) {
    recordedTimeAtLastSpeedChange = eventTime;
    realTimeAtLastSpeedChangeMs =
        (stopwatch.elapsedMilliseconds - totalPausedMs).toDouble();
  }

  void _handleTerminalEvent(Object event) {
    if (event is! KeyEvent) return;
    final key = event.key;
    if (key == 'q' || event.type == KeyType.escape) {
      quit = true;
      currentSleep?.interrupt();
      return;
    }
    switch (key) {
      case ' ':
        _togglePause();
      case '.' when isPaused:
        _stepForward();
      case ',' when isPaused:
        _stepBackward();
      case '+' || '=':
        _changeSpeed(1.25);
      case '-' || '_':
        _changeSpeed(0.8);
    }
  }

  void _togglePause() {
    isPaused = !isPaused;
    if (isPaused) {
      pauseStartMs = stopwatch.elapsedMilliseconds;
      hasSteppedWhilePaused = false;
    } else {
      totalPausedMs += stopwatch.elapsedMilliseconds - pauseStartMs;
      if (hasSteppedWhilePaused && currentIndex < events.length) {
        _alignPlaybackTime(events[currentIndex].time);
      }
    }
    _drawStatus(currentIndex);
    currentSleep?.interrupt();
  }

  void _changeSpeed(double factor) {
    final actualRealElapsedMs = stopwatch.elapsedMilliseconds - totalPausedMs;
    recordedTimeAtLastSpeedChange +=
        (actualRealElapsedMs - realTimeAtLastSpeedChangeMs) * speed / 1000.0;
    realTimeAtLastSpeedChangeMs = actualRealElapsedMs.toDouble();
    speed = (speed * factor).clamp(0.1, 100.0);
    _drawStatus(currentIndex);
    currentSleep?.interrupt();
  }

  void _stepForward() {
    if (currentIndex >= events.length) return;
    hasSteppedWhilePaused = true;
    while (currentIndex < events.length) {
      final event = events[currentIndex++];
      if (event.type == 'o') {
        terminal.backend.write(AsciicastPlayer.sanitizeOutput(event.data));
        break;
      }
    }
    if (currentIndex < events.length) {
      _alignPlaybackTime(events[currentIndex].time);
    }
    _drawStatus(currentIndex);
  }

  void _stepBackward() {
    final lastO = _findLastRenderedOIndex(currentIndex);
    if (lastO == null) return;
    final prevO = _findLastRenderedOIndex(lastO);
    if (prevO == null) return;

    hasSteppedWhilePaused = true;
    currentIndex = prevO + 1;
    terminal.clear();
    terminal.home();

    for (var i = 0; i <= prevO; i++) {
      final event = events[i];
      if (event.type == 'o') {
        terminal.backend.write(AsciicastPlayer.sanitizeOutput(event.data));
      }
    }
    if (currentIndex < events.length) {
      _alignPlaybackTime(events[currentIndex].time);
    }
    _drawStatus(currentIndex);
  }

  int? _findLastRenderedOIndex(int beforeIndex) {
    for (var i = beforeIndex - 1; i >= 0; i--) {
      if (events[i].type == 'o') return i;
    }
    return null;
  }
}

final class _InterruptibleSleep {
  Timer? _timer;
  Completer<void>? _completer;

  Future<void> sleep(Duration duration) {
    if (duration <= Duration.zero) return Future.value();
    _completer = Completer<void>();
    _timer = Timer(duration, () {
      if (_completer != null && !_completer!.isCompleted) {
        _completer!.complete();
      }
    });
    return _completer!.future;
  }

  void interrupt() {
    _timer?.cancel();
    if (_completer != null && !_completer!.isCompleted) {
      _completer!.complete();
    }
  }
}
