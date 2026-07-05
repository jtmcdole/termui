import 'package:termui/terminal/event.dart';

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
