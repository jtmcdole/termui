import 'dart:js_interop';
import 'package:web/web.dart' as web;

/// Waits for web fonts to load on the web platform.
Future<void> waitForFontsToLoad() async {
  try {
    final readyPromise = web.document.fonts.ready;
    await readyPromise.toDart;
  } catch (_) {
    // Fallback if fonts API is unavailable
    await Future.delayed(const Duration(milliseconds: 1000));
  }
}
