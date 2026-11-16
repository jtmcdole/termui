import 'fterm_version.dart';

/// Coarse lifecycle state of the `fterm` desktop auto-update workflow.
enum UpdateStatus {
  /// Idle (no pending actionable update).
  idle,

  /// Querying GitHub tag refs and release metadata.
  checking,

  /// A newer verified immutable release is available.
  available,

  /// Streaming, hashing, and extracting the release archive into staging.
  downloading,

  /// Release archive is verified and staged, awaiting user restart or quit.
  readyToRestart,

  /// Update discovery, staging, or swap pre-flight encountered an error.
  error,
}

/// Self-update capability of the running `fterm` binary and filesystem root.
enum SelfUpdateCapability {
  /// Portable desktop install with write access to swap in place.
  supported,

  /// Web WASM/JS client (self-update UI is hidden).
  unsupportedWeb,

  /// Non-portable, debug, test, or read-only install (shows GitHub Release link).
  readOnlyOrNonPortable,

  /// macOS `.app` blocked by `App Management` TCC (`EPERM`); offers Reveal in Finder.
  macosAppManagementDenied,
}

/// Host desktop OS and CPU target resolved for release asset matching.
enum DesktopTargetPlatform {
  /// Apple Silicon macOS (`fterm-macos-arm64.tar.gz`).
  macosArm64,

  /// Linux x86_64 (`fterm-linux-x64.tar.gz`).
  linuxX64,

  /// Linux AArch64 (`fterm-linux-arm64.tar.gz`).
  linuxArm64,

  /// Windows x86_64 (`fterm-windows-x64.zip`).
  windowsX64,

  /// Windows ARM64 native or Prism-emulated (`fterm-windows-arm64.zip` with
  /// fallback to `fterm-windows-x64.zip`).
  windowsArm64,

  /// Unsupported platform (e.g. Web or Intel macOS `x64`).
  unsupported,
}

/// Validated GitHub Release binary archive asset metadata.
final class ReleaseAssetInfo {
  /// Archive filename (e.g. `fterm-windows-x64.zip`).
  final String name;

  /// HTTPS download URL for the archive.
  final Uri browserDownloadUrl;

  /// Exact expected archive size in bytes (`> 0`).
  final int size;

  /// Lowercase 64-character hex SHA-256 digest locked by GitHub Immutable Releases.
  final String sha256Hex;

  /// Creates validated release asset metadata.
  const ReleaseAssetInfo({
    required this.name,
    required this.browserDownloadUrl,
    required this.size,
    required this.sha256Hex,
  });
}

/// Verified immutable GitHub Release exceeding the running `fterm` version.
final class AvailableUpdate {
  /// Parsed semantic version of the release.
  final FtermSemVer version;

  /// Full Git tag name (e.g. `fterm-v0.3.0`).
  final String tagName;

  /// Browser URL for viewing release notes and manual downloads on GitHub.
  final Uri htmlUrl;

  /// Release body markdown summary.
  final String notes;

  /// Whether GitHub marks this release as a pre-release.
  final bool isPrerelease;

  /// Optional publication timestamp.
  final DateTime? publishedAt;

  /// Matched binary archive asset for this host, or `null` when unavailable.
  final ReleaseAssetInfo? asset;

  /// Human-readable reason when [asset] is `null` (e.g. `linux-arm64`).
  final String? unavailableAssetReason;

  /// Creates an immutable [AvailableUpdate] description.
  const AvailableUpdate({
    required this.version,
    required this.tagName,
    required this.htmlUrl,
    this.notes = '',
    this.isPrerelease = false,
    this.publishedAt,
    this.asset,
    this.unavailableAssetReason,
  });
}

/// Verified and extracted release staged beside the portable installation.
final class StagedUpdate {
  /// Source release metadata.
  final AvailableUpdate update;

  /// Private `0700` / user-ACL staging directory path.
  final String stagingDirPath;

  /// Extracted payload path (`<staging>/extracted` or `<staging>/extracted/fterm.app`).
  final String stagedPayloadPath;

  /// Target portable root (`<Dir>` on Windows/Linux, `<Parent>/<App>.app` on macOS).
  final String portableRootPath;

  /// Validated relative manifest paths owned by the bundle (empty for macOS `.app`).
  final List<String> manifestEntries;

  /// Creates an immutable [StagedUpdate] handle.
  StagedUpdate({
    required this.update,
    required this.stagingDirPath,
    required this.stagedPayloadPath,
    required this.portableRootPath,
    List<String> manifestEntries = const [],
  }) : manifestEntries = manifestEntries.isEmpty
           ? const []
           : List<String>.unmodifiable(manifestEntries);
}

/// Byte-level download progress snapshot.
final class DownloadProgress {
  /// Bytes written so far.
  final int receivedBytes;

  /// Expected total bytes (`> 0`).
  final int totalBytes;

  /// Creates a [DownloadProgress] snapshot.
  const DownloadProgress({
    required this.receivedBytes,
    required this.totalBytes,
  });

  /// Clamped progress ratio in `[0.0, 1.0]`.
  double get fraction =>
      totalBytes <= 0 ? 0.0 : (receivedBytes / totalBytes).clamp(0.0, 1.0);
}

/// Result returned by a GitHub update discovery check.
final class UpdateCheckOutcome {
  /// Newer immutable release when available, or `null` when up to date.
  final AvailableUpdate? availableUpdate;

  /// Updated `ETag` to persist when [cacheTagState] is `true`.
  final String? tagEtag;

  /// Updated `fterm-v*` tag names to persist when [cacheTagState] is `true`.
  final List<String> cachedTags;

  /// Whether `(tagEtag, cachedTags)` should be persisted (false when a newer
  /// tag returned `404` or is still a `draft`).
  final bool cacheTagState;

  /// Creates an [UpdateCheckOutcome].
  UpdateCheckOutcome({
    required this.availableUpdate,
    required this.tagEtag,
    required List<String> cachedTags,
    required this.cacheTagState,
  }) : cachedTags = cachedTags.isEmpty
           ? const []
           : List<String>.unmodifiable(cachedTags);
}

/// Domain exception thrown when update discovery, verification, or swap fails.
final class UpdateException implements Exception {
  /// User-facing explanation of the failure.
  final String message;

  /// Whether macOS `App Management` TCC (`EPERM`) blocked modifying `.app`.
  final bool isMacosPermissionDenied;

  /// Creates an [UpdateException].
  const UpdateException(this.message, {this.isMacosPermissionDenied = false});

  @override
  String toString() => message;
}
