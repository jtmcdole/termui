import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:archive/archive.dart';
import 'package:termui/termui.dart';
import 'package:termui_pty/termui_pty.dart';
import 'events.dart';
import 'repository/repository.dart';

typedef AsciicastHeader = ({int version, int width, int height});
typedef AsciicastEvent = ({double time, String type, String data});

class AsciicastPlayerViewModel {
  final SavedCastsRepository repository;
  final VirtualTerminal virtualTerminal = VirtualTerminal(
    width: 80,
    height: 24,
  );

  // Playback parameters
  AsciicastHeader header = (version: 2, width: 80, height: 24);
  List<AsciicastEvent> events = [];
  double _currentTime = 0.0;
  double _totalDuration = 0.0;
  bool _isPlaying = false;
  bool _isLooping = false;
  double _speedMultiplier = 1.0;
  String? _activeFilename;

  // Direct render callback for high-performance TUI pipeline
  void Function(Buffer)? onFrameRedrawn;

  // Internals for chronological optimization
  int _lastPlayedIndex = 0;
  Timer? _playbackTimer;
  DateTime _lastTickTime = DateTime.now();

  bool _isDisposed = false;

  AsciicastPlayerViewModel({SavedCastsRepository? repository})
    : repository = repository ?? SavedCastsRepository();

  // Getters
  double get currentTime => _currentTime;
  double get totalDuration => _totalDuration;
  bool get isPlaying => _isPlaying;
  bool get isPaused => !_isPlaying;
  bool get isLooping => _isLooping;
  double get speedMultiplier => _speedMultiplier;
  String? get activeFilename => _activeFilename;

  /// Loads list of saved casts and posts to event bus.
  Future<void> refreshSavedCasts() async {
    final list = await repository.listCasts();
    savedCastsChangedEvent.post(playerEventBus, list);
  }

  /// Delegates saved cast listing to ViewModel to prevent View bypassing VM.
  Future<List<String>> listCasts() => repository.listCasts();

  /// Parses raw JSONL asciicast string data.
  Future<void> loadCastData(String filename, String rawData) async {
    pause();
    _activeFilename = filename;

    if (rawData.isEmpty) return;
    final lines = rawData.split(RegExp(r'\r?\n'));
    if (lines.isEmpty) return;

    var castWidth = 80;
    var castHeight = 24;
    var version = 2;

    try {
      final firstLine = lines[0].trim();
      if (firstLine.isNotEmpty) {
        final parsedHeader = jsonDecode(firstLine) as Map<String, dynamic>;
        version = parsedHeader['version'] as int? ?? 2;
        if (version == 3) {
          final term = parsedHeader['term'] as Map<String, dynamic>?;
          castWidth = term?['cols'] as int? ?? 80;
          castHeight = term?['rows'] as int? ?? 24;
        } else {
          castWidth = parsedHeader['width'] as int? ?? 80;
          castHeight = parsedHeader['height'] as int? ?? 24;
        }
      }
    } catch (_) {
      // Keep defaults
    }

    header = (version: version, width: castWidth, height: castHeight);
    virtualTerminal.resize(castWidth, castHeight);
    _clearTerminal();

    final parsedEvents = <AsciicastEvent>[];
    var accumulatedTime = 0.0;

    for (var i = 1; i < lines.length; i++) {
      final line = lines[i].trim();
      if (line.isEmpty) continue;
      try {
        if (jsonDecode(line) case [num timeNum, String type, String data]) {
          var time = timeNum.toDouble();
          if (version == 3) {
            accumulatedTime += time;
            time = accumulatedTime;
          }
          parsedEvents.add((time: time, type: type, data: data));
        }
      } catch (_) {
        // Skip malformed lines
      }
    }

    events = parsedEvents;
    _totalDuration = events.isEmpty ? 0.0 : events.last.time;
    _currentTime = 0.0;
    _lastPlayedIndex = 0;

    castLoadedEvent.post(
      playerEventBus,
      LoadedCastInfo(
        filename: filename,
        cols: castWidth,
        rows: castHeight,
        totalDuration: _totalDuration,
      ),
    );

    _dispatchState();
  }

  /// Loads a saved cast from repository by filename.
  Future<void> loadSavedCast(String filename) async {
    final raw = await repository.loadCast(filename);
    if (raw != null) {
      await loadCastData(filename, raw);
    }
  }

  /// Saves a cast file to storage (decompressing if Gzipped).
  Future<void> uploadCast(String filename, Uint8List bytes) async {
    String decoded;
    try {
      if (bytes case [0x1f, 0x8b, ...]) {
        final decompressed = GZipDecoder().decodeBytes(bytes);
        decoded = utf8.decode(decompressed);
      } else {
        decoded = utf8.decode(bytes);
      }
    } catch (e) {
      decoded = utf8.decode(bytes, allowMalformed: true);
    }

    // Save to storage
    await repository.saveCast(filename, decoded);
    await refreshSavedCasts();
    await loadCastData(filename, decoded);
  }

  /// Deletes a saved cast.
  Future<void> deleteCast(String filename) async {
    await repository.deleteCast(filename);
    await refreshSavedCasts();
    if (_activeFilename == filename) {
      _activeFilename = null;
      events = [];
      _totalDuration = 0.0;
      _currentTime = 0.0;
      _lastPlayedIndex = 0;
      _clearTerminal();
      _dispatchState();
    }
  }

  /// Sets playback speed.
  void setSpeed(double speed) {
    _speedMultiplier = speed;
    if (_isPlaying) {
      _startTimer();
    }
    _dispatchState();
  }

  /// Toggles loop option.
  void setLoop(bool enabled) {
    _isLooping = enabled;
    _dispatchState();
  }

  /// Toggles play / pause state.
  void togglePlay() {
    if (_isPlaying) {
      pause();
    } else {
      play();
    }
  }

  /// Pauses playback.
  void pause() {
    _isPlaying = false;
    _stopTimer();
    _dispatchState();
  }

  /// Starts or resumes playback.
  void play() {
    if (events.isEmpty) return;
    if (_currentTime >= _totalDuration) {
      seek(0.0);
    }
    _isPlaying = true;
    _startTimer();
    _dispatchState();
  }

  /// Seeks to a specific timestamp in seconds.
  void seek(double targetTime) {
    if (events.isEmpty) return;

    targetTime = targetTime.clamp(0.0, _totalDuration);

    if (targetTime < _currentTime) {
      _clearTerminal();
      _lastPlayedIndex = 0;
    }

    while (_lastPlayedIndex < events.length &&
        events[_lastPlayedIndex].time <= targetTime) {
      final event = events[_lastPlayedIndex];
      if (event.type == 'o') {
        virtualTerminal.write(event.data.codeUnits);
      }
      _lastPlayedIndex++;
    }

    _currentTime = targetTime;

    if (_currentTime >= _totalDuration) {
      _currentTime = _totalDuration;
      if (_isLooping) {
        seek(0.0);
      } else {
        pause();
      }
    } else {
      _dispatchState();
    }
  }

  /// Steps forward one event.
  void stepForward() {
    if (events.isEmpty || _lastPlayedIndex >= events.length) return;
    pause();

    var index = _lastPlayedIndex;
    var found = false;
    while (index < events.length && !found) {
      final event = events[index];
      if (event.type == 'o') {
        virtualTerminal.write(event.data.codeUnits);
        _currentTime = event.time;
        found = true;
      }
      index++;
    }
    _lastPlayedIndex = index;
    _dispatchState();
  }

  /// Steps backward one event.
  void stepBackward() {
    if (events.isEmpty || _lastPlayedIndex <= 0) return;
    pause();

    // Find the previous output event
    var targetIndex = _lastPlayedIndex - 2;
    while (targetIndex >= 0 && events[targetIndex].type != 'o') {
      targetIndex--;
    }

    if (targetIndex < 0) {
      seek(0.0);
    } else {
      seek(events[targetIndex].time);
    }
  }

  void _clearTerminal() {
    final eraseMod = virtualTerminal.transparentBackground
        ? Modifier.transparent
        : Modifier.none;
    virtualTerminal.buffer.fillAttributes(
      char: ' ',
      fg: 0,
      bg: 0,
      modifiers: eraseMod,
    );
    virtualTerminal.cursorX = 0;
    virtualTerminal.cursorY = 0;
  }

  void _startTimer() {
    _playbackTimer?.cancel();
    _lastTickTime = DateTime.now();
    _playbackTimer = Timer.periodic(const Duration(milliseconds: 16), (timer) {
      if (!_isPlaying) {
        timer.cancel();
        return;
      }
      final now = DateTime.now();
      final elapsedMs = now.difference(_lastTickTime).inMilliseconds;
      _lastTickTime = now;

      final deltaSeconds = (elapsedMs / 1000.0) * _speedMultiplier;
      seek(_currentTime + deltaSeconds);
    });
  }

  void _stopTimer() {
    _playbackTimer?.cancel();
    _playbackTimer = null;
  }

  void _dispatchState() {
    if (_isDisposed) return;
    onFrameRedrawn?.call(virtualTerminal.buffer);
    playbackStateEvent.post(
      playerEventBus,
      PlaybackState(
        currentTime: _currentTime,
        totalDuration: _totalDuration,
        isPlaying: _isPlaying,
        isLooping: _isLooping,
        speedMultiplier: _speedMultiplier,
        activeFilename: _activeFilename,
        cols: header.width,
        rows: header.height,
      ),
    );
  }

  void dispose() {
    _isDisposed = true;
    _stopTimer();
    virtualTerminal.dispose();
  }
}
