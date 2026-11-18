import 'dart:async';

import 'package:flutter/foundation.dart' show ChangeNotifier;

import 'about_models.dart';
import 'about_repository.dart';
import 'fterm_svg_baker.dart';

/// MVVM ViewModel backing `FtermAboutOverlay` and `FtermLicensesOverlay`.
final class AboutViewModel extends ChangeNotifier {
  final AboutRepository _repository;

  FtermBuildMetadata _metadata;
  FtermLogoScene _logoScene;
  String? _versionedSvg;

  List<PackageLicenseSummary> _allPackages = const [];
  List<PackageLicenseSummary> _filteredPackages = const [];
  String _filterQuery = '';
  String? _selectedPackageName;
  bool _isLoadingLicenses = false;
  String? _licenseError;

  Future<void>? _initFuture;
  Future<void>? _licensesFuture;
  bool _disposed = false;

  /// Creates an [AboutViewModel] pre-seeded with compile-time version and logo geometry.
  AboutViewModel({required AboutRepository repository})
    : _repository = repository,
      _metadata = repository.initialBuildMetadata(),
      _logoScene = FtermLogoScene.fallback();

  /// Active build version, optional build date, and SDK metadata.
  FtermBuildMetadata get metadata => _metadata;

  /// Parsed vector logo geometry consumed by `FtermVersionedLogo`.
  FtermLogoScene get logoScene => _logoScene;

  /// Version-stamped `favicon.svg` XML, or `null` before asset load completes.
  String? get versionedSvg => _versionedSvg;

  /// Filtered list of open-source packages matching [filterQuery].
  List<PackageLicenseSummary> get filteredPackages => _filteredPackages;

  /// Total deduplicated package count loaded from `LicenseRegistry`.
  int get totalPackageCount => _allPackages.length;

  /// Current case-insensitive package search filter.
  String get filterQuery => _filterQuery;

  /// Currently selected package name in the master-detail license viewer.
  String? get selectedPackageName => _selectedPackageName;

  /// Whether license entries are currently loading asynchronously.
  bool get isLoadingLicenses => _isLoadingLicenses;

  /// Optional error message if reading licenses failed.
  String? get licenseError => _licenseError;

  /// Currently selected [PackageLicenseSummary], or `null` when none match.
  PackageLicenseSummary? get selectedPackage {
    final name = _selectedPackageName;
    if (name == null) return _filteredPackages.firstOrNull;
    for (final pkg in _filteredPackages) {
      if (pkg.packageName == name) return pkg;
    }
    return _filteredPackages.firstOrNull;
  }

  /// Idempotently resolves async build date metadata and bakes the vector SVG.
  Future<void> ensureInitialized() => _initFuture ??= _runInit();

  Future<void> _runInit() async {
    final loadedMetadata = await _repository.loadBuildMetadata();
    if (_disposed) return;
    _metadata = loadedMetadata;
    final (scene, svg) = await _repository.loadLogoAssets(
      version: loadedMetadata.version,
    );
    if (_disposed) return;
    _logoScene = scene;
    _versionedSvg = svg.isEmpty ? null : svg;
    notifyListeners();
  }

  /// Idempotently loads all deduplicated package licenses from `LicenseRegistry`.
  Future<void> ensureLicensesLoaded() => _licensesFuture ??= _runLoadLicenses();

  Future<void> _runLoadLicenses() async {
    _isLoadingLicenses = true;
    _licenseError = null;
    _safeNotify();
    try {
      final loaded = await _repository.loadPackageLicenses();
      if (_disposed) return;
      _allPackages = loaded;
      _applyFilter();
    } on Object catch (e) {
      if (_disposed) return;
      _licenseError = '$e';
      _licensesFuture = null;
    } finally {
      if (!_disposed) {
        _isLoadingLicenses = false;
        notifyListeners();
      }
    }
  }

  /// Updates the package search filter and keeps [selectedPackage] valid.
  void setFilterQuery(String query) {
    if (_disposed || _filterQuery == query) return;
    _filterQuery = query;
    _applyFilter();
    notifyListeners();
  }

  /// Selects [packageName] in the master-detail licenses list.
  void selectPackage(String packageName) {
    if (_disposed || _selectedPackageName == packageName) return;
    _selectedPackageName = packageName;
    notifyListeners();
  }

  void _applyFilter() {
    final query = _filterQuery.trim().toLowerCase();
    _filteredPackages = query.isEmpty
        ? _allPackages
        : List<PackageLicenseSummary>.unmodifiable([
            for (final pkg in _allPackages)
              if (pkg.packageName.toLowerCase().contains(query)) pkg,
          ]);

    final current = _selectedPackageName;
    final stillVisible =
        current != null &&
        _filteredPackages.any((pkg) => pkg.packageName == current);
    if (!stillVisible) {
      _selectedPackageName = _filteredPackages.firstOrNull?.packageName;
    }
  }

  void _safeNotify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
