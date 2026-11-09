import 'url_launcher_stub.dart'
    if (dart.library.io) 'url_launcher_io.dart'
    if (dart.library.js_interop) 'url_launcher_web.dart'
    as impl;

final RegExp _controlChars = RegExp(r'[\x00-\x1F\x7F-\x9F]');

/// Parses [url] when it uses an allowed external launch scheme (`http`,
/// `https`, or `mailto`), or returns `null` when malformed or disallowed.
Uri? parseAllowedExternalUri(String url) {
  final trimmed = url.trim();
  if (trimmed.isEmpty || _controlChars.hasMatch(trimmed)) return null;
  final uri = Uri.tryParse(trimmed);
  if (uri == null) return null;
  return switch (uri.scheme.toLowerCase()) {
    'http' || 'https' when uri.hasAuthority && uri.host.isNotEmpty => uri,
    'mailto' when !uri.hasAuthority && uri.path.isNotEmpty => uri,
    _ => null,
  };
}

/// Whether [url] is a valid `http`, `https`, or `mailto` external URL.
bool isAllowedExternalUrl(String url) => parseAllowedExternalUri(url) != null;

/// Launches an external `http`, `https`, or `mailto` [url] in the host OS or browser.
Future<bool> launchExternalUrl(String url) async {
  final uri = parseAllowedExternalUri(url);
  if (uri == null) return false;
  return impl.launchPlatformExternalUri(uri);
}
