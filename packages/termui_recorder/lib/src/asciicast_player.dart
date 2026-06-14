import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'package:termui/terminal/terminal.dart';

/// Represents a single event inside an Asciicast recording.
class AsciicastEvent {
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
class AsciicastPlayer {
  /// The raw JSONL asciicast string data to play.
  final String asciicastData;

  final StringSink? _stdoutOverride;

  /// Creates a new [AsciicastPlayer] for the given [asciicastData].
  AsciicastPlayer(this.asciicastData, {StringSink? stdout})
    : _stdoutOverride = stdout;

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
    final lines = asciicastData.split(RegExp(r'\r?\n'));
    if (lines.isEmpty) return;

    // Parse header (line 0)
    var castWidth = 80;
    var castHeight = 24;
    try {
      final header = jsonDecode(lines[0]) as Map<String, dynamic>;
      castWidth = header['width'] as int? ?? 80;
      castHeight = header['height'] as int? ?? 24;
    } catch (_) {
      // Ignore malformed header JSON
    }

    // Parse events (subsequent lines)
    final events = <AsciicastEvent>[];
    for (var i = 1; i < lines.length; i++) {
      final line = lines[i].trim();
      if (line.isEmpty) continue;
      try {
        final array = jsonDecode(line) as List<dynamic>;
        if (array.length == 3) {
          final time = (array[0] as num).toDouble();
          final type = array[1] as String;
          final data = array[2] as String;
          events.add(AsciicastEvent(time, type, data));
        }
      } catch (_) {
        // Skip malformed lines
      }
    }

    if (events.isEmpty) return;

    if (!interactive) {
      // Non-interactive playback: just delay and write directly to stdout
      final out = _stdoutOverride ?? stdout;
      final stopwatch = Stopwatch()..start();
      for (final event in events) {
        if (event.type != 'o') {
          continue;
        }
        final targetRealElapsedMs = event.time * 1000.0 / speedMultiplier;
        final actualRealElapsedMs = stopwatch.elapsedMilliseconds;
        final sleepMs = (targetRealElapsedMs - actualRealElapsedMs).round();
        if (sleepMs > 0) {
          await Future<void>.delayed(Duration(milliseconds: sleepMs));
        }
        out.write(event.data);
        if (out is Stdout) {
          await out.flush();
        }
      }
      return;
    }

    // Interactive playback using raw terminal mode
    await Terminal.runGuarded((terminal) async {
      terminal.enterAlternateScreen();
      terminal.hideCursor();
      terminal.clear();
      terminal.home();

      var isPaused = paused || speedMultiplier == 0.0;
      var speed = speedMultiplier == 0.0 ? 1.0 : math.max(0.1, speedMultiplier);
      var quit = false;
      var hasSteppedWhilePaused = false;

      // Synchronization variables for drift-free absolute timing
      final stopwatch = Stopwatch()..start();
      var totalPausedMs = 0;
      var pauseStartMs = 0;

      var recordedTimeAtLastSpeedChange = 0.0;
      var realTimeAtLastSpeedChangeMs = 0.0;

      _InterruptibleSleep? currentSleep;
      var currentIndex = 0;

      void alignPlaybackTime(double eventTime) {
        recordedTimeAtLastSpeedChange = eventTime;
        realTimeAtLastSpeedChangeMs =
            (stopwatch.elapsedMilliseconds - totalPausedMs).toDouble();
      }

      int? findLastRenderedOIndex(int beforeIndex) {
        for (var i = beforeIndex - 1; i >= 0; i--) {
          if (events[i].type == 'o') {
            return i;
          }
        }
        return null;
      }

      void stepForward() {
        if (currentIndex >= events.length) return;
        hasSteppedWhilePaused = true;
        var foundO = false;
        while (currentIndex < events.length && !foundO) {
          final event = events[currentIndex];
          if (event.type == 'o') {
            terminal.backend.write(event.data);
            foundO = true;
          }
          currentIndex++;
        }
      }

      void stepBackward() {
        final lastO = findLastRenderedOIndex(currentIndex);
        if (lastO == null) return;
        final prevO = findLastRenderedOIndex(lastO);
        if (prevO == null) return;

        hasSteppedWhilePaused = true;
        currentIndex = prevO + 1;

        // Clear terminal screen and re-render
        terminal.clear();
        terminal.home();

        // Replay all 'o' events up to prevO
        for (var i = 0; i <= prevO; i++) {
          final event = events[i];
          if (event.type == 'o') {
            terminal.backend.write(event.data);
          }
        }
      }

      final keySubscription = terminal.events.listen((event) {
        if (event is KeyEvent) {
          if (event.key == 'q' || event.type == KeyType.escape) {
            quit = true;
            currentSleep?.interrupt();
          } else if (event.key == ' ') {
            isPaused = !isPaused;
            if (isPaused) {
              pauseStartMs = stopwatch.elapsedMilliseconds;
              hasSteppedWhilePaused = false;
            } else {
              totalPausedMs += stopwatch.elapsedMilliseconds - pauseStartMs;
              if (hasSteppedWhilePaused && currentIndex < events.length) {
                alignPlaybackTime(events[currentIndex].time);
              }
            }
            _renderStatusBar(
              terminal,
              isPaused,
              speed,
              castWidth,
              castHeight,
              events,
              currentIndex,
            );
            currentSleep?.interrupt();
          } else if (event.key == '.') {
            if (isPaused) {
              stepForward();
              if (currentIndex < events.length) {
                alignPlaybackTime(events[currentIndex].time);
              }
              _renderStatusBar(
                terminal,
                isPaused,
                speed,
                castWidth,
                castHeight,
                events,
                currentIndex,
              );
            }
          } else if (event.key == ',') {
            if (isPaused) {
              stepBackward();
              if (currentIndex < events.length) {
                alignPlaybackTime(events[currentIndex].time);
              }
              _renderStatusBar(
                terminal,
                isPaused,
                speed,
                castWidth,
                castHeight,
                events,
                currentIndex,
              );
            }
          } else if (event.key == '+' || event.key == '=') {
            final actualRealElapsedMs =
                stopwatch.elapsedMilliseconds - totalPausedMs;
            recordedTimeAtLastSpeedChange =
                recordedTimeAtLastSpeedChange +
                (actualRealElapsedMs - realTimeAtLastSpeedChangeMs) *
                    speed /
                    1000.0;
            realTimeAtLastSpeedChangeMs = actualRealElapsedMs.toDouble();

            speed = math.min(100.0, speed * 1.25);
            _renderStatusBar(
              terminal,
              isPaused,
              speed,
              castWidth,
              castHeight,
              events,
              currentIndex,
            );
            currentSleep?.interrupt();
          } else if (event.key == '-' || event.key == '_') {
            final actualRealElapsedMs =
                stopwatch.elapsedMilliseconds - totalPausedMs;
            recordedTimeAtLastSpeedChange =
                recordedTimeAtLastSpeedChange +
                (actualRealElapsedMs - realTimeAtLastSpeedChangeMs) *
                    speed /
                    1000.0;
            realTimeAtLastSpeedChangeMs = actualRealElapsedMs.toDouble();

            speed = math.max(0.1, speed * 0.8);
            _renderStatusBar(
              terminal,
              isPaused,
              speed,
              castWidth,
              castHeight,
              events,
              currentIndex,
            );
            currentSleep?.interrupt();
          }
        }
      });

      _renderStatusBar(
        terminal,
        isPaused,
        speed,
        castWidth,
        castHeight,
        events,
        currentIndex,
      );

      try {
        while ((currentIndex < events.length || noCloseAtEnd) && !quit) {
          if (currentIndex >= events.length) {
            isPaused = true;
            currentSleep = _InterruptibleSleep();
            await currentSleep.sleep(const Duration(milliseconds: 50));
            continue;
          }
          final event = events[currentIndex];

          if (isPaused) {
            currentSleep = _InterruptibleSleep();
            await currentSleep.sleep(const Duration(milliseconds: 50));
            continue;
          }

          final actualRealElapsedMs =
              stopwatch.elapsedMilliseconds - totalPausedMs;
          final targetRealElapsedMs =
              realTimeAtLastSpeedChangeMs +
              (event.time - recordedTimeAtLastSpeedChange) * 1000.0 / speed;

          final sleepMs = (targetRealElapsedMs - actualRealElapsedMs).round();
          if (sleepMs > 0) {
            currentSleep = _InterruptibleSleep();
            await currentSleep.sleep(Duration(milliseconds: sleepMs));
            if (quit) break;
            if (isPaused) continue;
          }

          if (event.type == 'o') {
            terminal.backend.write(event.data);
          }

          _renderStatusBar(
            terminal,
            isPaused,
            speed,
            castWidth,
            castHeight,
            events,
            currentIndex + 1,
          );

          currentIndex++;
        }
      } finally {
        await keySubscription.cancel();
        terminal.exitAlternateScreen();
        terminal.showCursor();
      }
    });
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
    // Determine status bar location: draw at the bottom of the screen if possible,
    // or fallback to the last line of the cast viewport.
    final size = terminal.backend.size;
    final termWidth = size.x > 0 ? size.x : castWidth;
    final termHeight = size.y > 0 ? size.y : castHeight;
    final row = termHeight;

    var metadataText = '';
    final activeIndex = nextIndex - 1;
    if (activeIndex >= 0 && activeIndex < events.length) {
      final activeEvent = events[activeIndex];
      if (activeEvent.type == 'o') {
        if (activeIndex > 0 &&
            events[activeIndex - 1].type == 'd' &&
            events[activeIndex - 1].time == activeEvent.time) {
          metadataText = events[activeIndex - 1].data;
        }
      }
    }

    // Save cursor position, move to status line, write status, restore cursor position
    final speedStr = speed.toStringAsFixed(2);
    final statusText =
        ' [${isPaused ? "PAUSED" : "PLAYING"}] Speed: ${speedStr}x | (Space: Pause, +/-: Speed, q: Quit, ,/.: Step) ';

    final sb = StringBuffer();
    sb.write('\x1b[s'); // Save cursor position

    final boxTopRow = row - 2;
    final boxContentRow = row - 1;

    if (boxTopRow >= 1) {
      if (metadataText.isNotEmpty) {
        // Draw top border of the box
        final title = ' Debug Metadata ';
        final borderLen = termWidth - title.length - 2;
        final topBorder = '┌─$title${'─' * (borderLen > 0 ? borderLen : 0)}┐';
        sb.write('\x1b[$boxTopRow;1H\x1b[K$topBorder');

        // Draw content of the box enclosed in vertical lines
        final contentWidth = termWidth - 2;
        var contentStr = metadataText;
        if (contentStr.length > contentWidth) {
          contentStr = contentStr.substring(0, contentWidth);
        } else {
          contentStr = contentStr.padRight(contentWidth);
        }
        sb.write('\x1b[$boxContentRow;1H\x1b[K│$contentStr│');
      } else {
        // Clear the metadata box lines
        sb.write('\x1b[$boxTopRow;1H\x1b[K');
        sb.write('\x1b[$boxContentRow;1H\x1b[K');
      }
    }

    // We style the status bar with reverse video (black on white) for high visibility
    sb.write('\x1b[$row;1H\x1b[7m$statusText\x1b[0m\x1b[K');
    sb.write('\x1b[u'); // Restore cursor position

    terminal.backend.write(sb.toString());
  }
}

class _InterruptibleSleep {
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
