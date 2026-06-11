import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:termui/terminal/terminal.dart';

/// A player that reads an Asciinema Asciicast v2 file (.cast) and plays it
/// back in the terminal with interactive playback controls.
class AsciicastPlayer {
  /// The asciicast file to play.
  final File file;

  final StringSink? _stdoutOverride;

  /// Creates a new [AsciicastPlayer] for the given [file].
  AsciicastPlayer(this.file, {StringSink? stdout}) : _stdoutOverride = stdout;

  /// Plays the asciicast session back to the terminal.
  ///
  /// * [speedMultiplier]: Speed factor (e.g., 2.0 for double speed, 0.5 for half speed).
  /// * [interactive]: Enables keyboard controls during playback:
  ///   - `Space`: Pause/resume playback
  ///   - `+` or `=`: Speed up playback (x1.25)
  ///   - `-` or `_`: Slow down playback (x0.8)
  ///   - `q` or `Escape`: Quit playback
  Future<void> play({
    double speedMultiplier = 1.0,
    bool interactive = true,
  }) async {
    if (!file.existsSync()) {
      throw FileSystemException('Asciicast file does not exist', file.path);
    }

    final lines = file.readAsLinesSync();
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
    final events = <(double, String)>[];
    for (var i = 1; i < lines.length; i++) {
      final line = lines[i].trim();
      if (line.isEmpty) continue;
      try {
        final array = jsonDecode(line) as List<dynamic>;
        if (array.length == 3 && array[1] == 'o') {
          final elapsedSeconds = (array[0] as num).toDouble();
          final data = array[2] as String;
          events.add((elapsedSeconds, data));
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
      for (final (time, data) in events) {
        final targetRealElapsedMs = time * 1000.0 / speedMultiplier;
        final actualRealElapsedMs = stopwatch.elapsedMilliseconds;
        final sleepMs = (targetRealElapsedMs - actualRealElapsedMs).round();
        if (sleepMs > 0) {
          await Future<void>.delayed(Duration(milliseconds: sleepMs));
        }
        out.write(data);
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

      var isPaused = false;
      var speed = speedMultiplier;
      var quit = false;

      // Synchronization variables for drift-free absolute timing
      final stopwatch = Stopwatch()..start();
      var totalPausedMs = 0;
      var pauseStartMs = 0;

      var recordedTimeAtLastSpeedChange = 0.0;
      var realTimeAtLastSpeedChangeMs = 0.0;

      _InterruptibleSleep? currentSleep;

      final keySubscription = terminal.events.listen((event) {
        if (event is KeyEvent) {
          if (event.key == 'q' || event.type == KeyType.escape) {
            quit = true;
            currentSleep?.interrupt();
          } else if (event.key == ' ') {
            isPaused = !isPaused;
            if (isPaused) {
              pauseStartMs = stopwatch.elapsedMilliseconds;
            } else {
              totalPausedMs += stopwatch.elapsedMilliseconds - pauseStartMs;
            }
            _renderStatusBar(terminal, isPaused, speed, castWidth, castHeight);
            currentSleep?.interrupt();
          } else if (event.key == '+' || event.key == '=') {
            final actualRealElapsedMs =
                stopwatch.elapsedMilliseconds - totalPausedMs;
            recordedTimeAtLastSpeedChange =
                recordedTimeAtLastSpeedChange +
                (actualRealElapsedMs - realTimeAtLastSpeedChangeMs) *
                    speed /
                    1000.0;
            realTimeAtLastSpeedChangeMs = actualRealElapsedMs.toDouble();

            speed *= 1.25;
            _renderStatusBar(terminal, isPaused, speed, castWidth, castHeight);
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

            speed *= 0.8;
            _renderStatusBar(terminal, isPaused, speed, castWidth, castHeight);
            currentSleep?.interrupt();
          }
        }
      });

      _renderStatusBar(terminal, isPaused, speed, castWidth, castHeight);

      try {
        for (final (time, data) in events) {
          if (quit) break;

          while (!quit) {
            if (isPaused) {
              currentSleep = _InterruptibleSleep();
              await currentSleep.sleep(const Duration(milliseconds: 50));
              continue;
            }

            final actualRealElapsedMs =
                stopwatch.elapsedMilliseconds - totalPausedMs;
            final targetRealElapsedMs =
                realTimeAtLastSpeedChangeMs +
                (time - recordedTimeAtLastSpeedChange) * 1000.0 / speed;

            final sleepMs = (targetRealElapsedMs - actualRealElapsedMs).round();
            if (sleepMs <= 0) {
              break;
            }

            currentSleep = _InterruptibleSleep();
            await currentSleep.sleep(Duration(milliseconds: sleepMs));
          }

          if (quit) break;

          terminal.backend.write(data);
          // Re-render status bar if the frame could have overwritten it
          if (isPaused || speed != speedMultiplier) {
            _renderStatusBar(terminal, isPaused, speed, castWidth, castHeight);
          }
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
  ) {
    // Determine status bar location: draw at the bottom of the screen if possible,
    // or fallback to the last line of the cast viewport.
    final size = terminal.backend.size;
    final termHeight = size.y > 0 ? size.y : castHeight;
    final row = termHeight;

    // Save cursor position, move to status line, write status, restore cursor position
    final speedStr = speed.toStringAsFixed(2);
    final statusText =
        ' [${isPaused ? "PAUSED" : "PLAYING"}] Speed: ${speedStr}x | (Space: Pause, +/-: Speed, q: Quit) ';

    // We style the status bar with reverse video (black on white) for high visibility
    final ansiStatus =
        '\x1b[s' // Save cursor position
        '\x1b[$row;1H' // Move cursor to row, col 1
        '\x1b[7m' // Enable reverse video
        '$statusText'
        '\x1b[0m' // Reset styling
        '\x1b[u'; // Restore cursor position
    terminal.backend.write(ansiStatus);
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
