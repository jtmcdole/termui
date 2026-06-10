import 'dart:math';

/// An abstract base class for native terminal backend implementations.
///
/// Provides methods to interact with the console, such as enabling raw mode,
/// reading input, and querying the terminal size.
abstract class TerminalBackend {
  /// Whether the host platform is Windows.
  bool get isWindows;

  /// Stream of raw input bytes from the terminal.
  Stream<List<int>> get rawInput;

  /// Writes output data back to the terminal.
  void write(String data);

  /// Retrieves the current terminal size.
  Point<int> get size;

  /// Watches terminal size changes.
  Stream<Point<int>> watchSize();

  /// Configures raw mode.
  void enableRawMode();

  /// Restores terminal configuration.
  void disableRawMode();

  /// Cleans up resources.
  void dispose();
}
