import 'package:web/web.dart' as web;

bool _isAllowedUri(Uri uri) => switch (uri.scheme.toLowerCase()) {
  'http' || 'https' => uri.hasAuthority && uri.host.isNotEmpty,
  'mailto' => !uri.hasAuthority && uri.path.isNotEmpty,
  _ => false,
};

/// Launches a validated `http`, `https`, or `mailto` [uri] in a new browser tab.
Future<bool> launchPlatformExternalUri(Uri uri) async {
  if (!_isAllowedUri(uri)) return false;
  web.window.open('$uri', '_blank', 'noopener,noreferrer');
  return true;
}
