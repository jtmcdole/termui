import 'package:termui/ui/buffer.dart';

/// A utility class to serialize a [Buffer] into a styled ANSI string representation.
abstract final class AnsiScreenshot {
  /// Converts the given [Buffer] to a styled ANSI string representation.
  ///
  /// Set [resetLineEndings] to true to output `\x1b[0m` at the end of every row.
  static String capture(Buffer buffer, {bool resetLineEndings = true}) =>
      BufferAnsiSerialization(buffer).toAnsiString(
        trimTrailingSpaces: true,
        resetLineEndings: resetLineEndings,
      );
}
