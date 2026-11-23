import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'server_config.dart';

/// Serves pre-built static Flutter web / WASM assets with strict path-traversal
/// protection, accurate MIME types, subpath `<base href>` rewriting, HTTP
/// compression (`.br`/`.gz` sidecars + bounded in-memory gzip), and
/// extensionless SPA pass-through.
final class StaticWebHandler {
  /// Maximum aggregate byte size retained in the in-memory gzip cache (`32 MiB`).
  static const int maxCompressedCacheBytes = 32 * 1024 * 1024;

  static const Set<String> _compressibleExtensions = {
    '.wasm',
    '.js',
    '.mjs',
    '.html',
    '.json',
    '.css',
    '.svg',
    '.ttf',
    '.otf',
  };

  static final RegExp _baseHrefPattern = RegExp(
    r'''<base\s+href=(["'])(?:/|\$FLUTTER_BASE_HREF)\1\s*/?>''',
    caseSensitive: false,
  );

  final String _canonicalRoot;
  final String _basePath;
  final int _baseSegmentCount;
  final File _indexFile;
  final Map<
    String,
    ({String basePath, int size, int modifiedMicros, String digest})
  >
  _digestCache = {};
  final Map<String, _GzipCacheEntry> _gzipCache = {};
  int _gzipCacheBytes = 0;

  /// Creates a static handler rooted at [webRoot], resolving symlinks once,
  /// optionally mounted under [basePath] (`''` for root or `/prefix`).
  ///
  /// Throws a [FormatException] when [basePath] fails
  /// [ServerConfig.normalizeBasePath] validation.
  StaticWebHandler(String webRoot, {String basePath = ''})
    : this._(
        Directory(webRoot).resolveSymbolicLinksSync(),
        ServerConfig.normalizeBasePath(basePath),
      );

  StaticWebHandler._(this._canonicalRoot, this._basePath)
    : _baseSegmentCount = _basePath.isEmpty
          ? 0
          : _basePath.substring(1).split('/').length,
      _indexFile = File(p.join(_canonicalRoot, 'index.html'));

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

    final rawPath = request.uri.path;
    if (_basePath.isNotEmpty &&
        rawPath != _basePath &&
        !rawPath.startsWith('$_basePath/')) {
      request.response.statusCode = HttpStatus.notFound;
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
    final strippedPath = _basePath.isEmpty
        ? rawPath
        : rawPath.substring(_basePath.length);
    if (strippedPath.isEmpty || strippedPath == '/') return 'index.html';

    final List<String> segments;
    try {
      segments = uri.pathSegments;
    } on FormatException {
      return null;
    }
    final trailingSlash = strippedPath.endsWith('/');
    final count = trailingSlash ? segments.length - 1 : segments.length;
    if (count < _baseSegmentCount) return null;
    final clean = <String>[];
    for (var i = _baseSegmentCount; i < count; i++) {
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
    final isCompressible = _compressibleExtensions.contains(ext);
    final rewriteIndex = _basePath.isNotEmpty && file.path == _indexFile.path;
    final payload = await _prepareResponsePayload(
      request,
      file,
      stat,
      isCompressible: isCompressible,
      rewriteIndex: rewriteIndex,
    );

    final response = request.response;
    _applyStandardHeaders(
      response,
      file: file,
      ext: ext,
      etag: payload.etag,
      isCompressible: isCompressible,
      contentEncoding: payload.contentEncoding,
    );

    if (_matchesIfNoneMatch(
      request.headers[HttpHeaders.ifNoneMatchHeader],
      payload.etag,
    )) {
      response.statusCode = HttpStatus.notModified;
      await response.close();
      return;
    }

    response
      ..statusCode = HttpStatus.ok
      ..headers.contentLength = payload.contentLength;

    if (request.method != 'HEAD') {
      final inMemory = payload.bytes;
      if (inMemory != null) {
        response.add(inMemory);
      } else {
        await response.addStream(payload.streamFile!.openRead());
      }
    }
    await response.close();
  }

  void _applyStandardHeaders(
    HttpResponse response, {
    required File file,
    required String ext,
    required String etag,
    required bool isCompressible,
    required String? contentEncoding,
  }) {
    response.headers
      ..contentType = _contentTypeForExtension(ext)
      ..set('x-content-type-options', 'nosniff')
      ..set('x-frame-options', 'DENY')
      ..set('referrer-policy', 'no-referrer')
      ..set('cross-origin-opener-policy', 'same-origin')
      ..set('cross-origin-embedder-policy', 'require-corp')
      ..set(
        'content-security-policy',
        "default-src 'self'; script-src 'self' 'wasm-unsafe-eval'; "
            "worker-src 'self' blob:; style-src 'self' 'unsafe-inline'; "
            "img-src 'self' data:; font-src 'self' data:; "
            "media-src 'self' blob: data:; "
            "manifest-src 'self'; "
            "connect-src 'self' ws: wss:; frame-ancestors 'none'; "
            "base-uri 'self'; object-src 'none'",
      )
      ..set(HttpHeaders.cacheControlHeader, _cacheControlForFile(file))
      ..set(HttpHeaders.etagHeader, etag);
    if (isCompressible) {
      response.headers.set(HttpHeaders.varyHeader, 'Accept-Encoding');
    }
    if (contentEncoding != null) {
      response.headers.set(HttpHeaders.contentEncodingHeader, contentEncoding);
    }
  }

  Future<_ResponsePayload> _prepareResponsePayload(
    HttpRequest request,
    File file,
    FileStat stat, {
    required bool isCompressible,
    required bool rewriteIndex,
  }) async {
    if (!isCompressible) {
      final digest = _digestForRawFile(file, stat);
      return (
        etag: '"$digest"',
        contentEncoding: null,
        contentLength: stat.size,
        bytes: null,
        streamFile: file,
      );
    }

    final prefs = _parseAcceptEncoding(
      request.headers[HttpHeaders.acceptEncodingHeader],
    );
    final sidecar = rewriteIndex
        ? null
        : await _resolvePreferredSidecar(file, prefs);
    if (sidecar != null) {
      final sidecarStat = await sidecar.file.stat();
      final digest = _digestForRawFile(sidecar.file, sidecarStat);
      return (
        etag: '"$digest-${sidecar.encoding}"',
        contentEncoding: sidecar.encoding,
        contentLength: sidecarStat.size,
        bytes: null,
        streamFile: sidecar.file,
      );
    }

    if (prefs.gzip > 0) {
      final entry = _gzipEntryFor(file, stat, rewriteIndex: rewriteIndex);
      return (
        etag: entry.etag,
        contentEncoding: 'gzip',
        contentLength: entry.bytes.length,
        bytes: entry.bytes,
        streamFile: null,
      );
    }

    if (rewriteIndex) {
      final rewritten = _readRewrittenIndexBytes(file);
      final digest = '${sha256.convert(rewritten)}';
      return (
        etag: '"$digest"',
        contentEncoding: null,
        contentLength: rewritten.length,
        bytes: rewritten,
        streamFile: null,
      );
    }

    final digest = _digestForRawFile(file, stat);
    return (
      etag: '"$digest"',
      contentEncoding: null,
      contentLength: stat.size,
      bytes: null,
      streamFile: file,
    );
  }

  Future<({File file, String encoding})?> _resolvePreferredSidecar(
    File file,
    ({double br, double gzip}) prefs,
  ) async {
    final brFile = prefs.br > 0 ? await _resolveSidecarFile(file, '.br') : null;
    if (brFile != null && (prefs.gzip <= 0 || prefs.br >= prefs.gzip)) {
      return (file: brFile, encoding: 'br');
    }
    if (prefs.gzip > 0) {
      final gzFile = await _resolveSidecarFile(file, '.gz');
      if (gzFile != null) return (file: gzFile, encoding: 'gzip');
    }
    return null;
  }

  Future<File?> _resolveSidecarFile(File baseFile, String suffix) async {
    final sidecar = File('${baseFile.path}$suffix');
    if (!await sidecar.exists()) return null;
    final realPath = await sidecar.resolveSymbolicLinks();
    if (!p.isWithin(_canonicalRoot, realPath)) return null;
    return File(realPath);
  }

  _GzipCacheEntry _gzipEntryFor(
    File file,
    FileStat stat, {
    required bool rewriteIndex,
  }) {
    final path = file.path;
    final modifiedMicros = stat.modified.microsecondsSinceEpoch;
    final cached = _gzipCache[path];
    if (cached != null &&
        cached.basePath == _basePath &&
        cached.size == stat.size &&
        cached.modifiedMicros == modifiedMicros) {
      return cached;
    }

    final entityBytes = rewriteIndex
        ? _readRewrittenIndexBytes(file)
        : file.readAsBytesSync();
    final digest = '${sha256.convert(entityBytes)}';
    final compressed = Uint8List.fromList(gzip.encode(entityBytes));
    final entry = (
      basePath: _basePath,
      size: stat.size,
      modifiedMicros: modifiedMicros,
      bytes: compressed,
      etag: '"$digest-gzip"',
    );
    _storeGzipCacheEntry(path, entry);
    return entry;
  }

  void _storeGzipCacheEntry(String path, _GzipCacheEntry entry) {
    final previous = _gzipCache.remove(path);
    if (previous != null) {
      _gzipCacheBytes -= previous.bytes.length;
    }
    final size = entry.bytes.length;
    if (size > maxCompressedCacheBytes) return;
    while (_gzipCache.isNotEmpty &&
        _gzipCacheBytes + size > maxCompressedCacheBytes) {
      final oldestKey = _gzipCache.keys.first;
      final removed = _gzipCache.remove(oldestKey);
      if (removed != null) _gzipCacheBytes -= removed.bytes.length;
    }
    _gzipCache[path] = entry;
    _gzipCacheBytes += size;
  }

  Uint8List _readRewrittenIndexBytes(File file) {
    final rawHtml = utf8.decode(file.readAsBytesSync(), allowMalformed: true);
    final rewritten = rawHtml.replaceFirstMapped(
      _baseHrefPattern,
      (_) => '<base href="$_basePath/">',
    );
    return Uint8List.fromList(utf8.encode(rewritten));
  }

  String _digestForRawFile(File file, FileStat stat) {
    final path = file.path;
    final modifiedMicros = stat.modified.microsecondsSinceEpoch;
    final cached = _digestCache[path];
    if (cached != null &&
        cached.basePath == _basePath &&
        cached.size == stat.size &&
        cached.modifiedMicros == modifiedMicros) {
      return cached.digest;
    }
    final digest = '${sha256.convert(file.readAsBytesSync())}';
    _digestCache[path] = (
      basePath: _basePath,
      size: stat.size,
      modifiedMicros: modifiedMicros,
      digest: digest,
    );
    return digest;
  }

  static ({double br, double gzip}) _parseAcceptEncoding(
    List<String>? headerValues,
  ) {
    if (headerValues == null || headerValues.isEmpty) {
      return (br: 0.0, gzip: 0.0);
    }
    final qValues = <String, double>{};
    for (final part in headerValues.expand((header) => header.split(','))) {
      final parsed = _parseEncodingToken(part);
      if (parsed == null) continue;
      final existing = qValues[parsed.coding];
      if (existing == 0.0) continue;
      if (existing == null || parsed.q == 0.0 || parsed.q > existing) {
        qValues[parsed.coding] = parsed.q;
      }
    }
    final wildcard = qValues['*'] ?? 0.0;
    return (br: qValues['br'] ?? wildcard, gzip: qValues['gzip'] ?? wildcard);
  }

  static ({String coding, double q})? _parseEncodingToken(String part) {
    final pieces = part.split(';');
    final coding = pieces.first.trim().toLowerCase();
    if (coding.isEmpty) return null;
    final q = _parseQualityValue(pieces);
    return q == null ? null : (coding: coding, q: q);
  }

  static double? _parseQualityValue(List<String> pieces) {
    for (var i = 1; i < pieces.length; i++) {
      final param = pieces[i].trim();
      if (param.length < 2) continue;
      if (!param.startsWith('q=') && !param.startsWith('Q=')) continue;
      final parsed = double.tryParse(param.substring(2).trim());
      if (parsed == null || parsed.isNaN || parsed < 0.0 || parsed > 1.0) {
        return null;
      }
      return parsed;
    }
    return 1.0;
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

typedef _GzipCacheEntry = ({
  String basePath,
  int size,
  int modifiedMicros,
  Uint8List bytes,
  String etag,
});

typedef _ResponsePayload = ({
  String etag,
  String? contentEncoding,
  int contentLength,
  Uint8List? bytes,
  File? streamFile,
});
