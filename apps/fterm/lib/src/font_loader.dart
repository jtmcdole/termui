import 'package:flutter/foundation.dart'
    show LicenseEntry, LicenseEntryWithLineBreaks, LicenseRegistry;
import 'package:flutter/services.dart';
import 'package:termui_flutter/termui_flutter.dart';

/// Primary monospace font family bundled with `fterm`.
const String castPrimaryFontFamily = 'Cascadia Mono';

/// Fallback monospace and symbol font families bundled with `fterm`.
const List<String> castFallbackFontFamilies = <String>['MesloLGS NF'];

const List<({List<String> packages, String assetPath})> _bundledLicenseAssets =
    [
      (packages: ['fterm'], assetPath: 'LICENSE'),
      (packages: ['Cascadia Mono'], assetPath: 'fonts/OFL-CascadiaMonoPL.txt'),
      (packages: ['MesloLGS NF'], assetPath: 'fonts/LICENSE-MesloLGS.txt'),
    ];

Future<void>? _loadFontsFuture;
bool _bundledLicensesRegistered = false;

Future<String?> _tryLoadAssetText(String assetPath) async {
  try {
    return await rootBundle.loadString(assetPath);
  } on Object {
    return null;
  }
}

Stream<LicenseEntry> _loadBundledLicenseEntries() async* {
  for (final (:packages, :assetPath) in _bundledLicenseAssets) {
    final text = await _tryLoadAssetText(assetPath);
    if (text == null || text.trim().isEmpty) continue;
    yield LicenseEntryWithLineBreaks(packages, text);
  }
}

/// Registers first-party (`fterm`) and bundled font licenses once in [LicenseRegistry].
void ensureFtermLicensesRegistered() {
  if (_bundledLicensesRegistered) return;
  _bundledLicensesRegistered = true;
  LicenseRegistry.addLicense(_loadBundledLicenseEntries);
}

Future<void> _loadSingleFont(String family, String assetPath) async {
  final loader = FontLoader(family)..addFont(rootBundle.load(assetPath));
  await loader.load();
}

Future<void> _registerBundledFonts() async {
  await [
    _loadSingleFont('Cascadia Mono', 'fonts/CascadiaMonoPL.ttf'),
    _loadSingleFont('MesloLGS NF', 'fonts/MesloLGS_NF_Regular.ttf'),
  ].wait;
}

/// Registers bundled monospace `.ttf` assets once and awaits platform font readiness.
Future<void> loadCastFonts() async {
  ensureFtermLicensesRegistered();
  await (_loadFontsFuture ??= _registerBundledFonts());
  await waitForFontsToLoad();
}
