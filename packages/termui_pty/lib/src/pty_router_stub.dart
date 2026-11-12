import 'dart:typed_data';

import 'pty_router.dart';

/// Web/non-`dart:io` stub for [Pty2RoutedBackend] throwing [UnsupportedError]
/// when attempting to spawn local OS shells on browser targets.
final class Pty2RoutedBackend implements RoutedPtyBackend {
  /// Throws [UnsupportedError] on non-`dart:io` platforms such as Web WASM.
  static Map<String, String> buildChildEnvironment({
    required Map<String, String> baseEnvironment,
    Map<String, String>? overrides,
  }) => throw UnsupportedError(
    'Local PTY backends require dart:io and are unsupported on this platform.',
  );

  /// Throws [UnsupportedError] on non-`dart:io` platforms such as Web WASM.
  static Future<String?> ensureConPtyReady({
    bool download = false,
    void Function(String message)? onWarning,
  }) => throw UnsupportedError(
    'Local PTY backends require dart:io and are unsupported on this platform.',
  );

  /// Throws [UnsupportedError] on non-`dart:io` platforms such as Web WASM.
  factory Pty2RoutedBackend.start(
    String executable,
    List<String> arguments, {
    int initialCols = 80,
    int initialRows = 24,
    int pixelWidth = 0,
    int pixelHeight = 0,
    String? workingDirectory,
    Map<String, String>? environment,
    bool ackProcessed = true,
    bool raw = false,
  }) => throw UnsupportedError(
    'Spawning local OS shells requires dart:io and is unsupported on Web.',
  );

  /// Throws [UnsupportedError] on non-`dart:io` platforms such as Web WASM.
  factory Pty2RoutedBackend.wrap(Object pty, {bool ackProcessed = true}) =>
      throw UnsupportedError(
        'Local PTY backends require dart:io and are unsupported on Web.',
      );

  @override
  Stream<Uint8List> get output => throw UnsupportedError('Pty2RoutedBackend');

  @override
  Future<int> get exitCode => throw UnsupportedError('Pty2RoutedBackend');

  @override
  void write(Uint8List bytes) => throw UnsupportedError('Pty2RoutedBackend');

  @override
  void resize(int cols, int rows, {int pixelWidth = 0, int pixelHeight = 0}) =>
      throw UnsupportedError('Pty2RoutedBackend');

  @override
  void kill([Object? signal]) => throw UnsupportedError('Pty2RoutedBackend');

  @override
  Future<void> dispose() async {}
}
