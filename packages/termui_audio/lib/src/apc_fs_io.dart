import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'api/audio_types.dart';

const int _maxApcUrlBytes = 16 * 1024 * 1024;
const int _maxApcUrlRedirects = 5;

/// Returns a `dart:io` file-byte reader for local APC audio loading.
Future<Uint8List> Function(String path)? createDefaultApcFileReader() =>
    (path) => File(path).readAsBytes();

/// Returns a `dart:io` HTTP/HTTPS byte reader for caster-host `loadUrl`.
///
/// Enforces `http`/`https` schemes only, at most 5 redirects while blocking
/// `https -> http` downgrades, [connectTimeout], [totalTimeout], and a running
/// `16 MiB` byte cap even when `Content-Length` is omitted.
Future<Uint8List> Function(String url, {LoadProgressCallback? onProgress})?
createDefaultApcUrlReader({
  Duration connectTimeout = const Duration(seconds: 10),
  Duration totalTimeout = const Duration(seconds: 30),
}) => (url, {LoadProgressCallback? onProgress}) {
  final uri = _parseAllowedHttpUri(url, raw: url);
  return _fetchApcUrlBytes(
    uri,
    connectTimeout: connectTimeout,
    totalTimeout: totalTimeout,
    onProgress: onProgress,
  );
};

Uri _parseAllowedHttpUri(String url, {required String raw}) {
  final uri = Uri.tryParse(url.trim());
  if (uri == null ||
      (uri.scheme != 'http' && uri.scheme != 'https') ||
      uri.host.isEmpty) {
    throw ArgumentError.value(
      raw,
      'url',
      'Expected http:// or https:// URL with a non-empty host',
    );
  }
  return uri;
}

Future<Uint8List> _fetchApcUrlBytes(
  Uri initialUri, {
  required Duration connectTimeout,
  required Duration totalTimeout,
  LoadProgressCallback? onProgress,
}) async {
  final client = HttpClient()..connectionTimeout = connectTimeout;
  try {
    return await _downloadWithRedirects(
      client,
      initialUri,
      onProgress: onProgress,
    ).timeout(
      totalTimeout,
      onTimeout: () {
        client.close(force: true);
        throw TimeoutException('Audio URL download timed out', totalTimeout);
      },
    );
  } finally {
    client.close(force: true);
  }
}

Future<Uint8List> _downloadWithRedirects(
  HttpClient client,
  Uri initialUri, {
  LoadProgressCallback? onProgress,
}) async {
  var currentUri = initialUri;
  for (var redirects = 0; ; redirects++) {
    final request = await client.getUrl(currentUri);
    request.followRedirects = false;
    final response = await request.close();
    if (_isRedirectStatus(response.statusCode)) {
      await _drainQuietly(response);
      currentUri = _resolveRedirectUri(currentUri, response, redirects);
      continue;
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      await _drainQuietly(response);
      throw HttpException(
        'Unexpected HTTP status ${response.statusCode}',
        uri: currentUri,
      );
    }
    return _readBoundedResponse(response, currentUri, onProgress: onProgress);
  }
}

bool _isRedirectStatus(int statusCode) =>
    statusCode == HttpStatus.movedPermanently ||
    statusCode == HttpStatus.found ||
    statusCode == HttpStatus.movedTemporarily ||
    statusCode == HttpStatus.seeOther ||
    statusCode == HttpStatus.temporaryRedirect ||
    statusCode == HttpStatus.permanentRedirect;

Uri _resolveRedirectUri(
  Uri currentUri,
  HttpClientResponse response,
  int redirects,
) {
  if (redirects >= _maxApcUrlRedirects) {
    throw HttpException(
      'Too many redirects (max $_maxApcUrlRedirects)',
      uri: currentUri,
    );
  }
  final location = response.headers.value(HttpHeaders.locationHeader);
  if (location == null || location.isEmpty) {
    throw HttpException(
      'Redirect ${response.statusCode} missing Location header',
      uri: currentUri,
    );
  }
  final nextUri = currentUri.resolve(location);
  if ((nextUri.scheme != 'http' && nextUri.scheme != 'https') ||
      nextUri.host.isEmpty) {
    throw HttpException('Blocked non-HTTP redirect target', uri: nextUri);
  }
  if (currentUri.scheme == 'https' && nextUri.scheme != 'https') {
    throw HttpException(
      'Blocked HTTPS to HTTP redirect downgrade',
      uri: nextUri,
    );
  }
  return nextUri;
}

Future<Uint8List> _readBoundedResponse(
  HttpClientResponse response,
  Uri uri, {
  LoadProgressCallback? onProgress,
}) async {
  final contentLength = response.contentLength;
  if (contentLength > _maxApcUrlBytes) {
    throw HttpException(
      'Audio response Content-Length $contentLength exceeds $_maxApcUrlBytes byte limit',
      uri: uri,
    );
  }
  final builder = BytesBuilder(copy: false);
  var received = 0;
  await for (final chunk in response) {
    received += chunk.length;
    if (received > _maxApcUrlBytes) {
      throw HttpException(
        'Audio response exceeds $_maxApcUrlBytes byte limit',
        uri: uri,
      );
    }
    builder.add(chunk);
    if (contentLength > 0) {
      onProgress?.call((received / contentLength).clamp(0.0, 1.0));
    }
  }
  if (received == 0) {
    throw HttpException('Empty audio response body', uri: uri);
  }
  onProgress?.call(1.0);
  return builder.takeBytes();
}

Future<void> _drainQuietly(HttpClientResponse response) async {
  try {
    await response.drain<void>();
  } on Object {
    // Ignore errors draining skipped redirect or error bodies.
  }
}
