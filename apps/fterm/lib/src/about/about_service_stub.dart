import 'package:flutter/foundation.dart' show LicenseEntry, LicenseRegistry;
import 'package:flutter/services.dart' show rootBundle;

import '../font_loader.dart';
import 'about_models.dart';
import 'about_service.dart';

/// Creates the Web/Wasm stub [AboutService].
AboutService createPlatformAboutService() => const WebAboutService();

/// Web/Wasm [AboutService] reading compile-time build dates and bundled assets.
final class WebAboutService implements AboutService {
  /// Raw `FTERM_BUILD_DATE` override (defaults to [kFtermDefineBuildDate]).
  final String defineBuildDate;

  /// Optional SVG loader seam for headless tests.
  final Future<String> Function()? svgTemplateLoader;

  /// Optional license stream seam for deterministic tests.
  final Stream<LicenseEntry> Function()? licenseStreamFactory;

  /// Optional compile-time metadata override for deterministic tests.
  final FtermBuildMetadata? compileTimeMetadataOverride;

  /// Creates a [WebAboutService].
  const WebAboutService({
    this.defineBuildDate = kFtermDefineBuildDate,
    this.svgTemplateLoader,
    this.licenseStreamFactory,
    this.compileTimeMetadataOverride,
  });

  @override
  FtermBuildMetadata resolveCompileTimeMetadata() =>
      compileTimeMetadataOverride ??
      FtermBuildMetadata.compileTime(defineBuildDate: defineBuildDate);

  @override
  Future<DateTime?> resolveBuildDateUtc() =>
      Future<DateTime?>.value(tryParseBuildDateUtc(defineBuildDate));

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
