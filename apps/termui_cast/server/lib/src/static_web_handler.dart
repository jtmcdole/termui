import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

/// Serves pre-built static Flutter web / WASM assets with strict path-traversal
/// protection, accurate MIME types, and extensionless SPA pass-through.
final class StaticWebHandler {
  final String _canonicalRoot;
  final File _indexFile;
  final Map<String, ({int size, int modifiedMicros, String etag})> _etagCache =
      {};

  /// Creates a static handler rooted at [webRoot], resolving symlinks once.
  StaticWebHandler(String webRoot)
    : this._(Directory(webRoot).resolveSymbolicLinksSync());

  StaticWebHandler._(this._canonicalRoot)
    : _indexFile = File(p.join(_canonicalRoot, 'index.html'));

  /// Handles an incoming HTTP [request] targeting the static web bundle.
  Future<void> handle(HttpRequest request) async {
    final method = request.method;
    if (method != 'GET' && method != 'HEAD') {
      request.response
        ..statusCode = HttpStatus.methodNotAllowed
        ..headers.set(HttpHeaders.allowHeader, 'GET, HEAD');
      await request.response.close();
      return;
    }

    final relPath = _extractSafeRelativePath(request.uri);
    if (relPath == null) {
      request.response.statusCode = HttpStatus.forbidden;
      await request.response.close();
      return;
    }

    try {
      final resolved = await _resolveTargetFile(relPath);
      if (resolved.forbidden) {
        request.response.statusCode = HttpStatus.forbidden;
        await request.response.close();
        return;
      }
      final file = resolved.file;
      if (file == null) {
        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
        return;
      }

      await _writeFileResponse(request, file);
    } on FileSystemException {
      try {
        request.response.statusCode = HttpStatus.forbidden;
      } on StateError {
        // Headers already sent while streaming; close the response stream cleanly.
      }
      await request.response.close();
    }
  }

  String? _extractSafeRelativePath(Uri uri) {
    final rawPath = uri.path;
    if (rawPath.contains('\x00') || rawPath.contains(r'\')) return null;
    if (rawPath.isEmpty || rawPath == '/') return 'index.html';

    final List<String> segments;
    try {
      segments = uri.pathSegments;
    } on FormatException {
      return null;
    }
    final trailingSlash = rawPath.endsWith('/');
    final count = trailingSlash ? segments.length - 1 : segments.length;
    final clean = <String>[];
    for (var i = 0; i < count; i++) {
      final seg = segments[i];
      if (!_isSafeSegment(seg)) return null;
      clean.add(seg);
    }
    if (trailingSlash) clean.add('index.html');
    return p.joinAll(clean);
  }

  static bool _isSafeSegment(String seg) =>
      seg.isNotEmpty &&
      seg != '.' &&
      seg != '..' &&
      !seg.contains('/') &&
      !seg.contains(r'\') &&
      !seg.contains('\x00');

  Future<({File? file, bool forbidden})> _resolveTargetFile(
    String relPath,
  ) async {
    final candidate = p.normalize(p.join(_canonicalRoot, relPath));
    if (!p.isWithin(_canonicalRoot, candidate)) {
      return (file: null, forbidden: true);
    }

    final file = File(candidate);
    if (await file.exists()) {
      final realPath = await file.resolveSymbolicLinks();
      if (!p.isWithin(_canonicalRoot, realPath)) {
        return (file: null, forbidden: true);
      }
      return (file: File(realPath), forbidden: false);
    }

    if (p.extension(relPath).isEmpty && await _indexFile.exists()) {
      return (file: _indexFile, forbidden: false);
    }
    return (file: null, forbidden: false);
  }

  Future<void> _writeFileResponse(HttpRequest request, File file) async {
    final stat = await file.stat();
    if (request.method != 'HEAD') {
      final probe = await file.open();
      await probe.close();
    }
    final ext = p.extension(file.path).toLowerCase();
    final etag = _etagFor(file, stat);
    final response = request.response
      ..headers.contentType = _contentTypeForExtension(ext)
      ..headers.set('x-content-type-options', 'nosniff')
      ..headers.set('x-frame-options', 'DENY')
      ..headers.set('referrer-policy', 'no-referrer')
      ..headers.set('cross-origin-opener-policy', 'same-origin')
      ..headers.set('cross-origin-embedder-policy', 'require-corp')
      ..headers.set(
        'content-security-policy',
        "default-src 'self'; script-src 'self' 'wasm-unsafe-eval'; "
            "worker-src 'self' blob:; style-src 'self' 'unsafe-inline'; "
            "img-src 'self' data:; font-src 'self' data:; "
            "media-src 'self' blob: data:; "
            "manifest-src 'self'; "
            "connect-src 'self' ws: wss:; frame-ancestors 'none'; "
            "base-uri 'self'; object-src 'none'",
      )
      ..headers.set(HttpHeaders.cacheControlHeader, _cacheControlForFile(file))
      ..headers.set(HttpHeaders.etagHeader, etag);

    if (_matchesIfNoneMatch(
      request.headers[HttpHeaders.ifNoneMatchHeader],
      etag,
    )) {
      response.statusCode = HttpStatus.notModified;
      await response.close();
      return;
    }

    response
      ..statusCode = HttpStatus.ok
      ..headers.contentLength = stat.size;

    if (request.method != 'HEAD') {
      await response.addStream(file.openRead());
    }
    await response.close();
  }

  String _etagFor(File file, FileStat stat) {
    final path = file.path;
    final modifiedMicros = stat.modified.microsecondsSinceEpoch;
    final cached = _etagCache[path];
    if (cached != null &&
        cached.size == stat.size &&
        cached.modifiedMicros == modifiedMicros) {
      return cached.etag;
    }
    final digest = sha256.convert(file.readAsBytesSync());
    final etag = '"$digest"';
    _etagCache[path] = (
      size: stat.size,
      modifiedMicros: modifiedMicros,
      etag: etag,
    );
    return etag;
  }

  static bool _matchesIfNoneMatch(List<String>? values, String etag) {
    if (values == null || values.isEmpty) return false;
    final normalizedEtag = _stripWeakPrefix(etag);
    for (final header in values) {
      for (final rawToken in header.split(',')) {
        final token = rawToken.trim();
        if (token == '*' || _stripWeakPrefix(token) == normalizedEtag) {
          return true;
        }
      }
    }
    return false;
  }

  static String _stripWeakPrefix(String token) =>
      token.startsWith('W/') ? token.substring(2) : token;

  static ContentType _contentTypeForExtension(String ext) => switch (ext) {
    '.html' => ContentType.html,
    '.js' ||
    '.mjs' => ContentType('application', 'javascript', charset: 'utf-8'),
    '.wasm' => ContentType('application', 'wasm'),
    '.json' => ContentType.json,
    '.css' => ContentType('text', 'css', charset: 'utf-8'),
    '.png' => ContentType('image', 'png'),
    '.svg' => ContentType('image', 'svg+xml'),
    '.ico' => ContentType('image', 'x-icon'),
    '.ttf' => ContentType('font', 'ttf'),
    '.otf' => ContentType('font', 'otf'),
    '.woff2' => ContentType('font', 'woff2'),
    _ => ContentType.binary,
  };

  String _cacheControlForFile(File file) {
    final name = p.basename(file.path).toLowerCase();
    if (name == 'index.html' ||
        name == 'flutter_bootstrap.js' ||
        name == 'version.json' ||
        name.endsWith('.wasm') ||
        name.endsWith('.js') ||
        name.endsWith('.mjs')) {
      return 'no-cache';
    }
    final rel = p.relative(file.path, from: _canonicalRoot).toLowerCase();
    if (rel.startsWith('canvaskit/') || rel.startsWith(r'canvaskit\')) {
      return 'no-cache';
    }
    return 'public, max-age=3600';
  }
}
