import 'dart:typed_data';
import '../util/file_saver.dart';

/// MVVM Service for Terminal tasks like saving screenshots.
abstract class TerminalService {
  /// Saves a screenshot to storage.
  Future<String?> saveScreenshot(String basename, Uint8List bytes);
}

/// Default implementation of [TerminalService] that uses the top-level saveFile function.
class DefaultTerminalService implements TerminalService {
  /// Creates a default terminal service.
  const DefaultTerminalService();

  @override
  Future<String?> saveScreenshot(String basename, Uint8List bytes) =>
      saveFile(basename, bytes);
}
