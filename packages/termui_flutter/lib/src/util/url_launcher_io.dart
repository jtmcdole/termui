import 'dart:io';

bool _isAllowedUri(Uri uri) => switch (uri.scheme.toLowerCase()) {
  'http' || 'https' => uri.hasAuthority && uri.host.isNotEmpty,
  'mailto' => !uri.hasAuthority && uri.path.isNotEmpty,
  _ => false,
};

/// Launches a validated `http`, `https`, or `mailto` [uri] in the system handler.
Future<bool> launchPlatformExternalUri(Uri uri) async {
  if (!_isAllowedUri(uri)) return false;
  final normalized = '$uri';
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
