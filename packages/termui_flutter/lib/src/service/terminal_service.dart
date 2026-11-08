import 'package:flutter/services.dart';
import '../util/file_saver.dart';
import '../util/url_launcher.dart';

/// MVVM Service for Terminal tasks like saving screenshots and accessing the clipboard.
abstract interface class TerminalService {
  /// Saves a screenshot to storage.
  Future<String?> saveScreenshot(String basename, Uint8List bytes);

  /// Writes [text] to the system/browser clipboard.
  Future<void> setClipboard(String text);

  /// Reads plain text from the system/browser clipboard.
  Future<String?> getClipboard();

  /// Opens an external `http` or `https` [url] in the host OS or browser.
  Future<bool> openUrl(String url);
}

/// Default implementation of [TerminalService] that uses the top-level saveFile function
/// and Flutter's [Clipboard] service.
final class DefaultTerminalService implements TerminalService {
  /// Creates a default terminal service.
  const DefaultTerminalService();

  @override
  Future<String?> saveScreenshot(String basename, Uint8List bytes) =>
      saveFile(basename, bytes);

  @override
  Future<void> setClipboard(String text) =>
      Clipboard.setData(ClipboardData(text: text));

  @override
  Future<String?> getClipboard() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    return data?.text;
  }

  @override
  Future<bool> openUrl(String url) => launchExternalUrl(url);
}
