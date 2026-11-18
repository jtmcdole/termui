import 'about_models.dart';
import 'about_service.dart';
import 'fterm_svg_baker.dart';

/// Repository coordinating build metadata, SVG logo baking, and package licenses.
final class AboutRepository {
  static const Map<String, int> _priorityRanks = {
    'fterm': 0,
    'Cascadia Mono': 1,
    'MesloLGS NF': 2,
    'termui': 3,
    'termui_flutter': 4,
    'termui_pty': 5,
    'termui_audio': 6,
    'termui_audio_flutter': 7,
    'pty2': 8,
    'termui_cast_client_core': 9,
    'termui_cast_protocol': 10,
    'termui_caster_cli': 11,
  };

  final AboutService _service;

  /// Creates an [AboutRepository] backed by [_service].
  const AboutRepository({required AboutService service}) : _service = service;

  /// Returns synchronous compile-time build and toolchain metadata.
  FtermBuildMetadata initialBuildMetadata() =>
      _service.resolveCompileTimeMetadata();

  /// Resolves build version, optional build date, and SDK metadata.
  Future<FtermBuildMetadata> loadBuildMetadata() async {
    final compileTime = initialBuildMetadata();
    final resolvedDate = await _service.resolveBuildDateUtc();
    return resolvedDate == null
        ? compileTime.copyWith(clearBuildDate: true)
        : compileTime.copyWith(buildDateUtc: resolvedDate);
  }

  /// Loads `web/favicon.svg`, parses vector geometry, and bakes [version] into
  /// a standalone SVG XML document.
  Future<(FtermLogoScene scene, String versionedSvg)> loadLogoAssets({
    required String version,
  }) async {
    try {
      final rawSvg = await _service.loadLogoSvgTemplate();
      if (rawSvg.trim().isEmpty) {
        return (FtermLogoScene.fallback(), '');
      }
      final baked = bakeVersionIntoFtermSvg(rawSvg, version: version);
      return (FtermLogoScene.parse(rawSvg), baked);
    } on Object {
      return (FtermLogoScene.fallback(), '');
    }
  }

  /// Collects, deduplicates per package, and prioritizes open-source licenses.
  Future<List<PackageLicenseSummary>> loadPackageLicenses() async {
    final noticesByPackage = <String, List<PackageLicenseNotice>>{};
    final seenByPackage = <String, Set<String>>{};

    await for (final entry in _service.readLicenseEntries()) {
      final paragraphs = [
        for (final p in entry.paragraphs)
          LicenseParagraphItem(text: p.text, indent: p.indent),
      ];
      if (paragraphs.isEmpty) continue;
      final canonical = paragraphs.map((p) => p.text.trim()).join('\n\n');
      final notice = PackageLicenseNotice(
        paragraphs: paragraphs,
        canonicalText: canonical,
      );

      for (final pkg in entry.packages) {
        final seen = seenByPackage.putIfAbsent(pkg, () => <String>{});
        if (!seen.add(canonical)) continue;
        noticesByPackage
            .putIfAbsent(pkg, () => <PackageLicenseNotice>[])
            .add(notice);
      }
    }

    final summaries = [
      for (final MapEntry(:key, :value) in noticesByPackage.entries)
        PackageLicenseSummary(packageName: key, notices: value),
    ]..sort(_comparePackages);

    return List<PackageLicenseSummary>.unmodifiable(summaries);
  }

  static int _comparePackages(
    PackageLicenseSummary a,
    PackageLicenseSummary b,
  ) {
    final rankA = _priorityRanks[a.packageName];
    final rankB = _priorityRanks[b.packageName];
    if (rankA != null && rankB != null) return rankA.compareTo(rankB);
    if (rankA != null) return -1;
    if (rankB != null) return 1;
    return a.packageName.toLowerCase().compareTo(b.packageName.toLowerCase());
  }
}
