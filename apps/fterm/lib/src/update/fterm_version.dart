import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/services.dart' show appBuildName;

/// Compile-time `fterm` semantic version populated automatically by Flutter
/// (`appBuildName` / `FLUTTER_BUILD_NAME`) from `apps/fterm/pubspec.yaml` on
/// `flutter test`, `flutter run`, and `flutter build`.
///
/// Override at build time with `flutter build <target> --release --build-name=X.Y.Z`
/// (note: `flutter run` does not accept `--build-name`, and Flutter reserves
/// `FLUTTER_BUILD_NAME` against manual `--dart-define` overrides).
const String kFtermBuildVersion = appBuildName ?? '0.0.0-dev';

/// Git tag prefix isolating `fterm` desktop releases from Melos package tags.
const String kFtermReleaseTagPrefix = 'fterm-v';

/// Browser fallback URL listing `fterm-v*` releases on GitHub.
const String kFtermReleasesHtmlUrl =
    'https://github.com/jtmcdole/termui/releases?q=fterm-v';

/// Immutable Semantic Versioning 2.0.0 value supporting pre-release precedence.
final class FtermSemVer implements Comparable<FtermSemVer> {
  static final RegExp _pattern = RegExp(
    r'^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)'
    r'(?:-((?:0|[1-9]\d*|\d*[a-zA-Z-][0-9a-zA-Z-]*)'
    r'(?:\.(?:0|[1-9]\d*|\d*[a-zA-Z-][0-9a-zA-Z-]*))*))?'
    r'(?:\+([0-9a-zA-Z-]+(?:\.[0-9a-zA-Z-]+)*))?$',
  );
  static final RegExp _digitsOnly = RegExp(r'^\d+$');

  /// Major version component (`>= 0`).
  final int major;

  /// Minor version component (`>= 0`).
  final int minor;

  /// Patch version component (`>= 0`).
  final int patch;

  /// Dot-separated pre-release identifiers (empty for stable releases).
  final List<String> prerelease;

  /// Optional `+...` build metadata (ignored when comparing precedence).
  final String? buildMetadata;

  /// Creates an immutable [FtermSemVer].
  FtermSemVer(
    this.major,
    this.minor,
    this.patch, {
    List<String> prerelease = const [],
    this.buildMetadata,
  }) : assert(major >= 0 && minor >= 0 && patch >= 0),
       prerelease = prerelease.isEmpty
           ? const []
           : List<String>.unmodifiable(prerelease);

  /// Whether this version carries pre-release identifiers (e.g. `0.3.0-rc.1`).
  bool get isPrerelease => prerelease.isNotEmpty;

  /// Parses [raw] (without `v` or `fterm-v` prefix), throwing [FormatException]
  /// if malformed.
  factory FtermSemVer.parse(String raw) {
    final parsed = tryParse(raw);
    if (parsed == null) {
      throw FormatException('Invalid semantic version: "$raw".');
    }
    return parsed;
  }

  /// Parses [raw] as SemVer 2.0.0, returning `null` if malformed.
  static FtermSemVer? tryParse(String raw) {
    final match = _pattern.firstMatch(raw.trim());
    if (match == null) return null;
    final major = int.tryParse(match.group(1)!);
    final minor = int.tryParse(match.group(2)!);
    final patch = int.tryParse(match.group(3)!);
    if (major == null || minor == null || patch == null) return null;
    final preRaw = match.group(4);
    final buildRaw = match.group(5);
    return FtermSemVer(
      major,
      minor,
      patch,
      prerelease: preRaw == null ? const [] : preRaw.split('.'),
      buildMetadata: buildRaw,
    );
  }

  /// Parses an `fterm-v<semver>` tag or `refs/tags/fterm-v<semver>` Git ref,
  /// returning `null` for non-`fterm` tags or malformed versions.
  static FtermSemVer? tryParseReleaseTag(String tagOrRef) {
    final trimmed = tagOrRef.trim();
    final String tagName;
    if (trimmed.startsWith('refs/tags/')) {
      tagName = trimmed.substring('refs/tags/'.length);
    } else {
      tagName = trimmed;
    }
    if (!tagName.startsWith(kFtermReleaseTagPrefix)) return null;
    return tryParse(tagName.substring(kFtermReleaseTagPrefix.length));
  }

  @override
  int compareTo(FtermSemVer other) {
    if (major != other.major) return major.compareTo(other.major);
    if (minor != other.minor) return minor.compareTo(other.minor);
    if (patch != other.patch) return patch.compareTo(other.patch);
    return _comparePrerelease(prerelease, other.prerelease);
  }

  static int _comparePrerelease(List<String> a, List<String> b) {
    if (a.isEmpty && b.isEmpty) return 0;
    if (a.isEmpty) return 1;
    if (b.isEmpty) return -1;
    final shared = a.length < b.length ? a.length : b.length;
    for (var i = 0; i < shared; i++) {
      final cmp = _compareIdentifier(a[i], b[i]);
      if (cmp != 0) return cmp;
    }
    return a.length.compareTo(b.length);
  }

  static int _compareIdentifier(String a, String b) {
    if (a == b) return 0;
    final aIsNum = _digitsOnly.hasMatch(a);
    final bIsNum = _digitsOnly.hasMatch(b);
    if (aIsNum && bIsNum) {
      if (a.length != b.length) return a.length.compareTo(b.length);
      return a.compareTo(b);
    }
    if (aIsNum) return -1;
    if (bIsNum) return 1;
    return a.compareTo(b);
  }

  /// Returns `true` when this version has strictly lower precedence than [other].
  bool operator <(FtermSemVer other) => compareTo(other) < 0;

  /// Returns `true` when this version has lower or equal precedence to [other].
  bool operator <=(FtermSemVer other) => compareTo(other) <= 0;

  /// Returns `true` when this version has strictly higher precedence than [other].
  bool operator >(FtermSemVer other) => compareTo(other) > 0;

  /// Returns `true` when this version has higher or equal precedence to [other].
  bool operator >=(FtermSemVer other) => compareTo(other) >= 0;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is FtermSemVer &&
          other.major == major &&
          other.minor == minor &&
          other.patch == patch &&
          listEquals(other.prerelease, prerelease);

  @override
  int get hashCode =>
      Object.hash(major, minor, patch, Object.hashAll(prerelease));

  @override
  String toString() {
    final base = '$major.$minor.$patch';
    final withPre = prerelease.isEmpty ? base : '$base-${prerelease.join('.')}';
    return buildMetadata == null ? withPre : '$withPre+$buildMetadata';
  }
}
