import 'dart:typed_data';
import 'package:core_bus/core_bus.dart';

/// The central event bus for the termui player.
final playerEventBus = EventBus();

/// Reusable class encapsulating playback metrics.
class PlaybackState {
  final double currentTime;
  final double totalDuration;
  final bool isPlaying;
  final bool isLooping;
  final double speedMultiplier;
  final String? activeFilename;
  final int cols;
  final int rows;

  const PlaybackState({
    required this.currentTime,
    required this.totalDuration,
    required this.isPlaying,
    required this.isLooping,
    required this.speedMultiplier,
    this.activeFilename,
    required this.cols,
    required this.rows,
  });
}

/// Dispatched when the player state changes.
const playbackStateEvent = Event<PlaybackState>.broadcast(
  name: 'playbackState',
);

/// Dispatched when a new cast is successfully loaded.
class LoadedCastInfo {
  final String filename;
  final int cols;
  final int rows;
  final double totalDuration;

  const LoadedCastInfo({
    required this.filename,
    required this.cols,
    required this.rows,
    required this.totalDuration,
  });
}

const castLoadedEvent = Event<LoadedCastInfo>.broadcast(name: 'castLoaded');

/// Dispatched when the list of saved files is updated.
const savedCastsChangedEvent = Event<List<String>>.broadcast(
  name: 'savedCastsChanged',
);

/// Dispatched when the TUI requests a native file picker upload.
const uploadCastRequestedEvent = Event<void>.broadcast(
  name: 'uploadCastRequested',
);

/// Payload containing details of a cast uploaded via native bridge.
class UploadedCastData {
  final String filename;
  final Uint8List bytes;
  const UploadedCastData(this.filename, this.bytes);
}

/// Dispatched when the native picker has retrieved a file.
const castUploadedEvent = Event<UploadedCastData>.broadcast(
  name: 'castUploaded',
);
