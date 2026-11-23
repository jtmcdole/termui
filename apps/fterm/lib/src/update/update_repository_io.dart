import 'dart:async';
import 'dart:convert';
import 'dart:ffi' show Abi;
import 'dart:io';
import 'dart:typed_data';

import 'fterm_version.dart';
import 'update_models.dart';

/// Hard 64 MiB cap on streaming desktop release archive downloads.
const int kMaxArchiveDownloadBytes = 64 * 1024 * 1024;

/// HTTP connect timeout for GitHub API and asset CDN requests.
const Duration kUpdateHttpConnectTimeout = Duration(seconds: 15);

/// Per-chunk read idle timeout during streaming downloads.
const Duration kUpdateDownloadChunkTimeout = Duration(seconds: 60);

final RegExp _sha256DigestPattern = RegExp(r'^sha256:([0-9a-fA-F]{64})$');

/// Minimal HTTP response returned by [UpdateHttpClient.getJson].
final class UpdateHttpResponse {
  /// HTTP status code (e.g. `200`, `304`, `404`).
  final int statusCode;

  /// Decoded UTF-8 response body.
  final String body;

  /// Optional HTTP `ETag` response header.
  final String? etag;

  /// Creates an [UpdateHttpResponse].
  const UpdateHttpResponse({
    required this.statusCode,
    required this.body,
    this.etag,
  });
}

/// Injectable HTTP seam for GitHub tag/release discovery and binary downloads.
abstract interface class UpdateHttpClient {
  /// Performs a `GET` request expecting JSON (or `304 Not Modified`).
  Future<UpdateHttpResponse> getJson(Uri uri, {Map<String, String> headers});

  /// Streams `GET` [uri] to [destinationFile], enforcing [maxBytes] and
  /// reporting throttled byte progress via [onProgress].
  Future<void> downloadToFile({
    required Uri uri,
    required File destinationFile,
    required int expectedBytes,
    int maxBytes = kMaxArchiveDownloadBytes,
    void Function(DownloadProgress progress)? onProgress,
  });

  /// Closes underlying sockets.
  void close();
}

/// Default `dart:io` [HttpClient] implementation of [UpdateHttpClient].
final class IoUpdateHttpClient implements UpdateHttpClient {
  HttpClient? _client;
  final Duration _connectTimeout;
  final Duration _chunkTimeout;

  /// Creates an [IoUpdateHttpClient] (lazily opening [HttpClient] on first request).
  IoUpdateHttpClient({
    this._client,
    this._connectTimeout = kUpdateHttpConnectTimeout,
    this._chunkTimeout = kUpdateDownloadChunkTimeout,
  });

  HttpClient get _activeClient =>
      _client ??= (HttpClient()..connectionTimeout = _connectTimeout);

  @override
  Future<UpdateHttpResponse> getJson(
    Uri uri, {
    Map<String, String> headers = const {},
  }) async {
    final request = await _activeClient.getUrl(uri).timeout(_connectTimeout);
    headers.forEach(request.headers.set);
    final response = await request.close().timeout(_chunkTimeout);
    final chunks = BytesBuilder(copy: false);
    await for (final chunk in response.timeout(_chunkTimeout)) {
      chunks.add(chunk);
      if (chunks.length > 4 * 1024 * 1024) {
        throw const UpdateException('GitHub API JSON response exceeded 4 MiB.');
      }
    }
    return UpdateHttpResponse(
      statusCode: response.statusCode,
      body: utf8.decode(chunks.takeBytes(), allowMalformed: true),
      etag: response.headers.value(HttpHeaders.etagHeader),
    );
  }

  @override
  Future<void> downloadToFile({
    required Uri uri,
    required File destinationFile,
    required int expectedBytes,
    int maxBytes = kMaxArchiveDownloadBytes,
    void Function(DownloadProgress progress)? onProgress,
  }) async {
    if (expectedBytes <= 0 || expectedBytes > maxBytes) {
      throw UpdateException(
        'Release asset size ($expectedBytes bytes) exceeds allowed bounds.',
      );
    }
    final request = await _activeClient.getUrl(uri).timeout(_connectTimeout);
    request.headers.set(
      HttpHeaders.userAgentHeader,
      'fterm/$kFtermBuildVersion',
    );
    final response = await request.close().timeout(_chunkTimeout);
    if (response.statusCode != HttpStatus.ok) {
      await response.drain<void>();
      throw UpdateException(
        'Archive download failed with HTTP ${response.statusCode}.',
      );
    }
    await _pipeResponseWithCap(
      response: response,
      destinationFile: destinationFile,
      expectedBytes: expectedBytes,
      maxBytes: maxBytes,
      onProgress: onProgress,
    );
  }

  Future<void> _pipeResponseWithCap({
    required HttpClientResponse response,
    required File destinationFile,
    required int expectedBytes,
    required int maxBytes,
    required void Function(DownloadProgress progress)? onProgress,
  }) async {
    final sink = destinationFile.openWrite();
    var received = 0;
    var lastReportedBytes = 0;
    try {
      await for (final chunk in response.timeout(_chunkTimeout)) {
        received += chunk.length;
        if (received > maxBytes) {
          throw UpdateException(
            'Archive download exceeded safety cap ($maxBytes bytes).',
          );
        }
        sink.add(chunk);
        if (onProgress != null &&
            (received == expectedBytes ||
                received - lastReportedBytes >= 64 * 1024)) {
          lastReportedBytes = received;
          onProgress(
            DownloadProgress(
              receivedBytes: received,
              totalBytes: expectedBytes,
            ),
          );
        }
      }
      await sink.flush();
    } finally {
      await sink.close();
    }
    onProgress?.call(
      DownloadProgress(receivedBytes: received, totalBytes: expectedBytes),
    );
  }

  @override
  void close() {
    _client?.close(force: true);
    _client = null;
  }
}

/// Resolves the [DesktopTargetPlatform] for [abi] and host [environment].
DesktopTargetPlatform resolveHostTargetPlatform({
  Abi? abi,
  Map<String, String>? environment,
  bool isWeb = false,
}) {
  if (isWeb) return DesktopTargetPlatform.unsupported;
  final currentAbi = abi ?? Abi.current();
  final env = environment ?? Platform.environment;
  return switch (currentAbi) {
    Abi.macosArm64 => DesktopTargetPlatform.macosArm64,
    Abi.linuxX64 => DesktopTargetPlatform.linuxX64,
    Abi.linuxArm64 => DesktopTargetPlatform.linuxArm64,
    Abi.windowsArm64 => DesktopTargetPlatform.windowsArm64,
    Abi.windowsX64 =>
      _isWindowsHostArm64(env)
          ? DesktopTargetPlatform.windowsArm64
          : DesktopTargetPlatform.windowsX64,
    _ => DesktopTargetPlatform.unsupported,
  };
}

bool _isWindowsHostArm64(Map<String, String> env) =>
    env['PROCESSOR_ARCHITEW6432']?.trim().toUpperCase() == 'ARM64' ||
    env['PROCESSOR_ARCHITECTURE']?.trim().toUpperCase() == 'ARM64';

/// Resolves the primary and optional fallback archive filenames for [target].
({String? primary, String? fallback, String? missingMessage})
assetNamesForTarget(DesktopTargetPlatform target) => switch (target) {
  DesktopTargetPlatform.macosArm64 => (
    primary: 'fterm-macos-arm64.tar.gz',
    fallback: null,
    missingMessage: 'No prebuilt archive for macos-arm64 in this release.',
  ),
  DesktopTargetPlatform.linuxX64 => (
    primary: 'fterm-linux-x64.tar.gz',
    fallback: null,
    missingMessage: 'No prebuilt archive for linux-x64 in this release.',
  ),
  DesktopTargetPlatform.linuxArm64 => (
    primary: 'fterm-linux-arm64.tar.gz',
    fallback: null,
    missingMessage: 'No prebuilt archive for linux-arm64 in this release.',
  ),
  DesktopTargetPlatform.windowsX64 => (
    primary: 'fterm-windows-x64.zip',
    fallback: null,
    missingMessage: 'No prebuilt archive for windows-x64 in this release.',
  ),
  DesktopTargetPlatform.windowsArm64 => (
    primary: 'fterm-windows-arm64.zip',
    fallback: 'fterm-windows-x64.zip',
    missingMessage: 'No prebuilt archive for windows-arm64 in this release.',
  ),
  DesktopTargetPlatform.unsupported => (
    primary: null,
    fallback: null,
    missingMessage: 'Prebuilt updates are unavailable for this platform.',
  ),
};

/// Discovers `fterm-v*` tags and immutable GitHub Releases for `jtmcdole/termui`.
final class IoUpdateRepository {
  static final Uri _defaultMatchingRefsUri = Uri.parse(
    'https://api.github.com/repos/jtmcdole/termui/git/matching-refs/tags/fterm-v',
  );
  static const String _defaultReleaseTagBase =
      'https://api.github.com/repos/jtmcdole/termui/releases/tags/';

  /// Underlying HTTP client.
  final UpdateHttpClient httpClient;

  /// Target desktop OS and CPU architecture.
  final DesktopTargetPlatform targetPlatform;

  final Uri _matchingRefsUri;
  final String _releaseTagBaseUrl;

  /// Creates an [IoUpdateRepository].
  IoUpdateRepository({
    required this.httpClient,
    required this.targetPlatform,
    Uri? matchingRefsUri,
    this._releaseTagBaseUrl = _defaultReleaseTagBase,
  }) : _matchingRefsUri = matchingRefsUri ?? _defaultMatchingRefsUri;

  Map<String, String> _apiHeaders({String? ifNoneMatch}) => <String, String>{
    HttpHeaders.acceptHeader: 'application/vnd.github+json',
    'X-GitHub-Api-Version': '2022-11-28',
    HttpHeaders.userAgentHeader: 'fterm/$kFtermBuildVersion',
    if (ifNoneMatch != null && ifNoneMatch.isNotEmpty)
      HttpHeaders.ifNoneMatchHeader: ifNoneMatch,
  };

  /// Queries `matching-refs/tags/fterm-v` (honoring [lastEtag] + [cachedTags] on
  /// `304`) and validates the newest immutable release above [currentVersion].
  Future<UpdateCheckOutcome> checkForUpdates({
    required FtermSemVer currentVersion,
    required bool includePrereleases,
    String? lastEtag,
    List<String> cachedTags = const [],
  }) async {
    final (tags, nextEtag) = await _fetchOrReuseTagNames(
      lastEtag: lastEtag,
      cachedTags: cachedTags,
    );
    final candidates = _selectCandidateTags(
      tags: tags,
      currentVersion: currentVersion,
      includePrereleases: includePrereleases,
    );
    var shouldCacheTagState = true;
    for (final (:tagName, :version) in candidates) {
      final result = await _inspectCandidateRelease(
        tagName: tagName,
        version: version,
        includePrereleases: includePrereleases,
      );
      if (result.isTransientMissOrDraft) {
        shouldCacheTagState = false;
        continue;
      }
      if (result.update != null) {
        return UpdateCheckOutcome(
          availableUpdate: result.update,
          tagEtag: nextEtag,
          cachedTags: tags,
          cacheTagState: shouldCacheTagState,
        );
      }
    }
    return UpdateCheckOutcome(
      availableUpdate: null,
      tagEtag: nextEtag,
      cachedTags: tags,
      cacheTagState: shouldCacheTagState,
    );
  }

  Future<(List<String> tags, String? etag)> _fetchOrReuseTagNames({
    required String? lastEtag,
    required List<String> cachedTags,
  }) async {
    final canSendEtag = lastEtag != null && cachedTags.isNotEmpty;
    final response = await httpClient.getJson(
      _matchingRefsUri,
      headers: _apiHeaders(ifNoneMatch: canSendEtag ? lastEtag : null),
    );
    if (response.statusCode == HttpStatus.notModified && canSendEtag) {
      return (cachedTags, lastEtag);
    }
    if (response.statusCode != HttpStatus.ok) {
      throw UpdateException(
        'GitHub tag lookup failed (HTTP ${response.statusCode}).',
      );
    }
    return (_parseMatchingRefsJson(response.body), response.etag);
  }

  static List<String> _parseMatchingRefsJson(String rawBody) {
    final Object? decoded;
    try {
      decoded = jsonDecode(rawBody);
    } on FormatException catch (e) {
      throw UpdateException('Malformed GitHub tag refs JSON: ${e.message}');
    }
    if (decoded is! List<Object?>) {
      throw const UpdateException('Expected JSON list from matching-refs API.');
    }
    final tags = <String>[];
    for (final entry in decoded) {
      if (entry case {'ref': final String ref}
          when ref.startsWith('refs/tags/$kFtermReleaseTagPrefix')) {
        final tagName = ref.substring('refs/tags/'.length);
        if (FtermSemVer.tryParseReleaseTag(tagName) != null) {
          tags.add(tagName);
        }
      }
    }
    return tags;
  }

  static List<({String tagName, FtermSemVer version})> _selectCandidateTags({
    required List<String> tags,
    required FtermSemVer currentVersion,
    required bool includePrereleases,
  }) {
    final parsed = <({String tagName, FtermSemVer version})>[];
    for (final tagName in tags.toSet()) {
      final version = FtermSemVer.tryParseReleaseTag(tagName);
      if (version == null || version <= currentVersion) continue;
      if (version.isPrerelease && !includePrereleases) continue;
      parsed.add((tagName: tagName, version: version));
    }
    parsed.sort((a, b) => b.version.compareTo(a.version));
    return parsed;
  }

  Future<({AvailableUpdate? update, bool isTransientMissOrDraft})>
  _inspectCandidateRelease({
    required String tagName,
    required FtermSemVer version,
    required bool includePrereleases,
  }) async {
    final uri = Uri.parse('$_releaseTagBaseUrl${Uri.encodeComponent(tagName)}');
    final response = await httpClient.getJson(uri, headers: _apiHeaders());
    if (response.statusCode == HttpStatus.notFound) {
      return (update: null, isTransientMissOrDraft: true);
    }
    if (response.statusCode != HttpStatus.ok) {
      throw UpdateException(
        'GitHub release lookup for $tagName failed (HTTP ${response.statusCode}).',
      );
    }
    final decoded = _decodeJsonObject(response.body, context: tagName);
    if (decoded['draft'] == true) {
      return (update: null, isTransientMissOrDraft: true);
    }
    final isPrerelease = decoded['prerelease'] == true || version.isPrerelease;
    if (isPrerelease && !includePrereleases) {
      return (update: null, isTransientMissOrDraft: false);
    }
    if (decoded['immutable'] != true) {
      throw UpdateException(
        'Refusing update $tagName: GitHub release is not immutable.',
      );
    }
    return (
      update: _buildAvailableUpdate(decoded, tagName, version, isPrerelease),
      isTransientMissOrDraft: false,
    );
  }

  AvailableUpdate _buildAvailableUpdate(
    Map<Object?, Object?> json,
    String tagName,
    FtermSemVer version,
    bool isPrerelease,
  ) {
    final htmlUrlRaw = switch (json['html_url']) {
      final String s when s.trim().isNotEmpty => s.trim(),
      _ => kFtermReleasesHtmlUrl,
    };
    final htmlUrl =
        Uri.tryParse(htmlUrlRaw) ?? Uri.parse(kFtermReleasesHtmlUrl);
    final notes = switch (json['body']) {
      final String s => s.trim(),
      _ => '',
    };
    final publishedAt = switch (json['published_at']) {
      final String s => DateTime.tryParse(s)?.toUtc(),
      _ => null,
    };
    final (asset, reason) = _matchReleaseAsset(json['assets']);
    return AvailableUpdate(
      version: version,
      tagName: tagName,
      htmlUrl: htmlUrl,
      notes: notes,
      isPrerelease: isPrerelease,
      publishedAt: publishedAt,
      asset: asset,
      unavailableAssetReason: reason,
    );
  }

  (ReleaseAssetInfo?, String?) _matchReleaseAsset(Object? rawAssets) {
    final (:primary, :fallback, :missingMessage) = assetNamesForTarget(
      targetPlatform,
    );
    if (primary == null) {
      return (null, missingMessage);
    }
    if (rawAssets is! List<Object?>) {
      return (null, missingMessage);
    }
    final byName = <String, Map<Object?, Object?>>{
      for (final item in rawAssets)
        if (item case final Map<Object?, Object?> map)
          if (map['name'] case final String name) name: map,
    };
    final chosenMap =
        byName[primary] ?? (fallback == null ? null : byName[fallback]);
    if (chosenMap == null) {
      return (null, missingMessage);
    }
    return (_parseValidatedAsset(chosenMap), null);
  }

  static ReleaseAssetInfo _parseValidatedAsset(Map<Object?, Object?> map) {
    final name = map['name'] as String;
    final size = switch (map['size']) {
      final int s when s > 0 && s <= kMaxArchiveDownloadBytes => s,
      _ => throw UpdateException('Asset "$name" has invalid byte size.'),
    };
    final digestRaw = switch (map['digest']) {
      final String d => d.trim(),
      _ => '',
    };
    final match = _sha256DigestPattern.firstMatch(digestRaw);
    if (match == null) {
      throw UpdateException('Asset "$name" is missing a valid sha256 digest.');
    }
    final urlRaw = switch (map['browser_download_url']) {
      final String u => u.trim(),
      _ => '',
    };
    final url = Uri.tryParse(urlRaw);
    if (url == null || url.scheme != 'https') {
      throw UpdateException('Asset "$name" has invalid HTTPS download URL.');
    }
    return ReleaseAssetInfo(
      name: name,
      browserDownloadUrl: url,
      size: size,
      sha256Hex: match.group(1)!.toLowerCase(),
    );
  }

  static Map<Object?, Object?> _decodeJsonObject(
    String rawBody, {
    required String context,
  }) {
    final Object? decoded;
    try {
      decoded = jsonDecode(rawBody);
    } on FormatException catch (e) {
      throw UpdateException(
        'Malformed release JSON for $context: ${e.message}',
      );
    }
    if (decoded is! Map<Object?, Object?>) {
      throw UpdateException('Expected JSON object for release $context.');
    }
    return decoded;
  }
}
