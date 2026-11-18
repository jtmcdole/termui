import 'dart:io' show File, FileSystemException, Platform;

import 'package:flutter/foundation.dart' show LicenseEntry, LicenseRegistry;
import 'package:flutter/services.dart' show rootBundle;
import 'package:path/path.dart' as p;

import '../font_loader.dart';
import 'about_models.dart';
import 'about_service.dart';

/// Creates the native desktop (`dart:io`) [AboutService].
AboutService createPlatformAboutService() => const IoAboutService();

/// Native desktop [AboutService] resolving build timestamps without sync I/O.
final class IoAboutService implements AboutService {
  /// Raw `FTERM_BUILD_DATE` override (defaults to [kFtermDefineBuildDate]).
  final String defineBuildDate;

  /// Optional executable path override for deterministic unit tests.
  final String? resolvedExecutableOverride;

  /// Optional environment map override for deterministic unit tests.
  final Map<String, String>? environmentOverride;

  /// Optional async file modification reader for deterministic unit tests.
  final Future<DateTime?> Function(String path)? executableModifiedUtcReader;

  /// Optional SVG loader seam for headless unit tests.
  final Future<String> Function()? svgTemplateLoader;

  /// Optional license stream seam for deterministic unit tests.
  final Stream<LicenseEntry> Function()? licenseStreamFactory;

  /// Optional compile-time metadata override for deterministic unit tests.
  final FtermBuildMetadata? compileTimeMetadataOverride;

  /// Creates an [IoAboutService] with optional testing seams.
  const IoAboutService({
    this.defineBuildDate = kFtermDefineBuildDate,
    this.resolvedExecutableOverride,
    this.environmentOverride,
    this.executableModifiedUtcReader,
    this.svgTemplateLoader,
    this.licenseStreamFactory,
    this.compileTimeMetadataOverride,
  });

  @override
  FtermBuildMetadata resolveCompileTimeMetadata() =>
      compileTimeMetadataOverride ??
      FtermBuildMetadata.compileTime(defineBuildDate: defineBuildDate);

  @override
  Future<DateTime?> resolveBuildDateUtc() async {
    if (tryParseBuildDateUtc(defineBuildDate) case final defined?) {
      return defined;
    }
    final env = environmentOverride ?? Platform.environment;
    if (resolvedExecutableOverride == null && env.containsKey('FLUTTER_TEST')) {
      return null;
    }
    final exePath = resolvedExecutableOverride ?? Platform.resolvedExecutable;
    final pathContext = exePath.contains('\\') && !exePath.contains('/')
        ? p.windows
        : p.context;
    if (pathContext.basenameWithoutExtension(exePath).toLowerCase() !=
        'fterm') {
      return null;
    }
    final reader = executableModifiedUtcReader ?? _defaultReadModifiedUtc;
    return reader(exePath);
  }

  static Future<DateTime?> _defaultReadModifiedUtc(String path) async {
    try {
      return (await File(path).lastModified()).toUtc();
    } on FileSystemException {
      return null;
    }
  }

  @override
  Future<String> loadLogoSvgTemplate() {
    ensureFtermLicensesRegistered();
    final loader = svgTemplateLoader;
    return loader != null ? loader() : rootBundle.loadString('web/favicon.svg');
  }

  @override
  Stream<LicenseEntry> readLicenseEntries() {
    ensureFtermLicensesRegistered();
    final streamFactory = licenseStreamFactory;
    return streamFactory != null ? streamFactory() : LicenseRegistry.licenses;
  }
}
