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

/// Hotkey to toggle debug overlays globally (if null, hotkey is disabled).
KeyType? debugToggleHotkey = KeyType.f6;
