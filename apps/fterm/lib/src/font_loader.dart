import 'package:flutter/services.dart';
import 'package:termui_flutter/termui_flutter.dart';

/// Primary monospace font family bundled with `fterm`.
const String castPrimaryFontFamily = 'Cascadia Mono';

/// Fallback monospace and symbol font families bundled with `fterm`.
const List<String> castFallbackFontFamilies = <String>['MesloLGS NF'];

Future<void>? _loadFontsFuture;

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
  await (_loadFontsFuture ??= _registerBundledFonts());
  await waitForFontsToLoad();
}
