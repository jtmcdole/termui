import 'dart:io';

/// Launches an external `http` or `https` [url] in the system browser.
Future<bool> launchExternalUrl(String url) async {
  final uri = Uri.tryParse(url.trim());
  if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) {
    return false;
  }
  final normalized = uri.toString();
  try {
    final ProcessResult result;
    if (Platform.isWindows) {
      result = await Process.run('rundll32', [
        'url.dll,FileProtocolHandler',
        normalized,
      ]);
    } else if (Platform.isMacOS) {
      result = await Process.run('open', [normalized]);
    } else if (Platform.isLinux) {
      result = await Process.run('xdg-open', [normalized]);
    } else {
      return false;
    }
    return result.exitCode == 0;
  } on Object catch (_) {
    return false;
  }
}
