import 'package:flutter/services.dart' show FlutterVersion, appBuildNumber;

import '../update/fterm_version.dart';

/// Canonical GitHub repository URL for `termui` / `fterm`.
const String kFtermRepoUrl = 'https://github.com/jtmcdole/termui';

/// Compact display label for [kFtermRepoUrl].
const String kFtermRepoDisplayLabel = 'github.com/jtmcdole/termui';

/// Repository-wide MIT copyright notice displayed in the About overlay.
const String kFtermCopyrightNotice =
    'MIT License · Copyright © 2026 John Thomas McDole';

/// Humorous McDole Heavy Industries motto displayed on the About splash hero.
const String kFtermMotto = 'Ananas Maximus, Lucrum Maximum.';

/// Compile-time UTC ISO-8601 build timestamp injected by release/CI builds.
const String kFtermDefineBuildDate = String.fromEnvironment('FTERM_BUILD_DATE');

/// Parses an ISO-8601 date/time string into UTC, returning `null` when empty or invalid.
DateTime? tryParseBuildDateUtc(String raw) {
  final trimmed = raw.trim();
  if (trimmed.isEmpty) return null;
  return DateTime.tryParse(trimmed)?.toUtc();
}

/// Immutable build and toolchain metadata displayed on the About overlay.
final class FtermBuildMetadata {
  /// Semantic application version (`kFtermBuildVersion` / `appBuildName`).
  final String version;

  /// Optional Flutter build number (`appBuildNumber`).
  final String? buildNumber;

  /// UTC build timestamp resolved from `FTERM_BUILD_DATE` or binary mtime.
  final DateTime? buildDateUtc;

  /// Flutter framework version captured at compile time, when provided.
  final String? flutterVersion;

  /// Flutter release channel captured at compile time, when provided.
  final String? flutterChannel;

  /// Dart SDK version captured at compile time, when provided.
  final String? dartVersion;

  /// Creates immutable build metadata.
  const FtermBuildMetadata({
    required this.version,
    this.buildNumber,
    this.buildDateUtc,
    this.flutterVersion,
    this.flutterChannel,
    this.dartVersion,
  });

  /// Creates metadata seeded from Flutter compile-time environment constants.
  factory FtermBuildMetadata.compileTime({
    DateTime? buildDateUtc,
    String defineBuildDate = kFtermDefineBuildDate,
  }) => FtermBuildMetadata(
    version: kFtermBuildVersion,
    buildNumber: _nonEmpty(appBuildNumber),
    buildDateUtc: buildDateUtc ?? tryParseBuildDateUtc(defineBuildDate),
    flutterVersion: _nonEmpty(FlutterVersion.version),
    flutterChannel: _nonEmpty(FlutterVersion.channel),
    dartVersion: _compactDartVersion(FlutterVersion.dartVersion),
  );

  /// Returns a copy overriding [buildDateUtc] (or clearing it when requested).
  FtermBuildMetadata copyWith({
    DateTime? buildDateUtc,
    bool clearBuildDate = false,
  }) => FtermBuildMetadata(
    version: version,
    buildNumber: buildNumber,
    buildDateUtc: clearBuildDate ? null : (buildDateUtc ?? this.buildDateUtc),
    flutterVersion: flutterVersion,
    flutterChannel: flutterChannel,
    dartVersion: dartVersion,
  );

  /// User-facing version label (for example `v0.3.0` or `v0.3.0+42`).
  String get displayVersion {
    final number = buildNumber;
    if (number == null || number.isEmpty) return 'v$version';
    return 'v$version+$number';
  }

  /// Formatted UTC timestamp (`YYYY-MM-DD HH:MM UTC`), or `null` when unavailable.
  String? get formattedBuildDate {
    final dt = buildDateUtc?.toUtc();
    if (dt == null) return null;
    final date = '${_pad4(dt.year)}-${_pad2(dt.month)}-${_pad2(dt.day)}';
    final time = '${_pad2(dt.hour)}:${_pad2(dt.minute)}';
    return '$date $time UTC';
  }

  /// Single-line Flutter/Dart SDK summary, or `null` if no SDK metadata was baked in.
  String? get runtimeToolchainLabel {
    final parts = <String>[
      if (flutterVersion case final fv?)
        switch (flutterChannel) {
          final ch? => 'Flutter $fv ($ch)',
          null => 'Flutter $fv',
        },
      if (dartVersion case final dv?) 'Dart $dv',
    ];
    if (parts.isEmpty) return null;
    return parts.join(' · ');
  }

  static String? _nonEmpty(String? value) {
    final trimmed = value?.trim();
    return (trimmed == null || trimmed.isEmpty) ? null : trimmed;
  }

  static String? _compactDartVersion(String? raw) {
    final trimmed = _nonEmpty(raw);
    if (trimmed == null) return null;
    return trimmed.split(RegExp(r'\s+')).first;
  }

  static String _pad2(int value) => value.toString().padLeft(2, '0');
  static String _pad4(int value) => value.toString().padLeft(4, '0');
}

/// Immutable paragraph within a package license block.
final class LicenseParagraphItem {
  /// Paragraph body text.
  final String text;

  /// Flutter `LicenseParagraph` indentation level (`-1` for centered headings).
  final int indent;

  /// Creates an immutable [LicenseParagraphItem].
  const LicenseParagraphItem({required this.text, required this.indent});
}

/// Deduplicated license block associated with a package.
final class PackageLicenseNotice {
  /// Ordered paragraphs forming this license block.
  final List<LicenseParagraphItem> paragraphs;

  /// Normalized canonical text used to deduplicate identical notices per package.
  final String canonicalText;

  /// Creates an immutable [PackageLicenseNotice].
  PackageLicenseNotice({
    required List<LicenseParagraphItem> paragraphs,
    required this.canonicalText,
  }) : paragraphs = List<LicenseParagraphItem>.unmodifiable(paragraphs);
}

/// Aggregated open-source license entry for one package or bundled asset.
final class PackageLicenseSummary {
  /// Display package or bundled font name.
  final String packageName;

  /// Deduplicated notices registered for [packageName].
  final List<PackageLicenseNotice> notices;

  /// Creates an immutable [PackageLicenseSummary].
  PackageLicenseSummary({
    required this.packageName,
    required List<PackageLicenseNotice> notices,
  }) : notices = List<PackageLicenseNotice>.unmodifiable(notices);

  /// Number of distinct license notices held for [packageName].
  int get noticeCount => notices.length;
}
