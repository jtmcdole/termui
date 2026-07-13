/// A unified logging interface for the trace viewer application.
/// Provides consistent ISO-8601 formatted timestamps for all output.
class TraceLogger {
  /// Logs an informational message tagged with the given [tag].
  static void info(String tag, String message) {
    // ignore: avoid_print
    print('[${DateTime.now().toIso8601String()}] [$tag] $message');
  }

  /// Logs an error message tagged with the given [tag].
  /// Optionally includes an [error] object and [stackTrace].
  static void error(
    String tag,
    String message, [
    Object? error,
    StackTrace? stackTrace,
  ]) {
    // ignore: avoid_print
    print('[${DateTime.now().toIso8601String()}] [ERROR] [$tag] $message');
    if (error != null) {
      // ignore: avoid_print
      print(error);
    }
    if (stackTrace != null) {
      // ignore: avoid_print
      print(stackTrace);
    }
  }
}
