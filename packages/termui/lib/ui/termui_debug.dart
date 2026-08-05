import 'package:termui/terminal/event.dart';
import 'src/log_native.dart' if (dart.library.js_interop) 'src/log_web.dart';

/// True if the current application is compiled to run on the web.
const bool kIsWeb = identical(0, 0.0);

/// True if the application is running in debug mode.
/// Evaluated exactly once at startup.
final bool kIsDebug = () {
  var isDebug = false;
  assert(() {
    isDebug = true;
    return true;
  }());
  return isDebug;
}();

/// Optional override for error logging (e.g., in test environments).
void Function(String message)? debugLogError;

/// Logs an error message.
/// In release mode, this is a no-op.
/// In debug mode, this writes to stderr natively, or uses print() on the web.
void logError(String message) {
  if (!kIsDebug) return;
  if (debugLogError != null) {
    debugLogError!(message);
  } else {
    platformLog(message);
  }
}

/// Global configuration flags for visual debugging in termui.
/// Highlight the deepest leaf node under the mouse pointer.
bool debugPaintHoverEnabled = false;

/// Render a crosshair over the current mouse position.
bool debugMouseCursorEnabled = false;

/// Paint borders around all active layers.
bool debugPaintLayerBordersEnabled = false;

/// Show active touches and expansion rings for visual debugging.
bool debugShowTouchesEnabled = false;

/// Key sequence to toggle debug overlays globally (if null, hotkey is disabled).
/// Defaults to Ctrl+O to avoid terminal multiplexer conflicts.
KeyEvent? debugToggleKey = const KeyEvent(
  'o',
  KeyType.character,
  modifiers: {Modifier.control},
);
