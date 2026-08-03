import 'dart:io' as io;

/// Platform specific logging.
void platformLog(String message) {
  io.stderr.writeln(message);
}
