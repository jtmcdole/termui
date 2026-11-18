import 'package:flutter/foundation.dart' show LicenseEntry;

import 'about_models.dart';
import 'about_service_stub.dart'
    if (dart.library.io) 'about_service_io.dart'
    as platform;

/// Stateless platform boundary providing build timestamps, SVG assets, and licenses.
abstract interface class AboutService {
  /// Returns synchronous compile-time version and SDK metadata.
  FtermBuildMetadata resolveCompileTimeMetadata();

  /// Resolves the UTC build timestamp from compile-time defines or executable metadata.
  Future<DateTime?> resolveBuildDateUtc();

  /// Loads the raw `web/favicon.svg` XML template.
  Future<String> loadLogoSvgTemplate();

  /// Streams raw [LicenseEntry] items including first-party and font licenses.
  Stream<LicenseEntry> readLicenseEntries();
}

/// Creates the platform-appropriate [AboutService].
AboutService createDefaultAboutService() =>
    platform.createPlatformAboutService();
