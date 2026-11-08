import 'package:web/web.dart' as web;

/// Launches an external `http` or `https` [url] in a new browser tab.
Future<bool> launchExternalUrl(String url) async {
  final uri = Uri.tryParse(url.trim());
  if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) {
    return false;
  }
  web.window.open(uri.toString(), '_blank', 'noopener,noreferrer');
  return true;
}
