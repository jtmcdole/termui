import 'package:termui/termui.dart';
import 'package:termui/terminal/terminal.dart' as term;

/// Handles Space/Enter activation for a focusable interactive control.
bool handleActivationKeyEvent({
  required bool hasFocus,
  required term.KeyEvent event,
  required void Function() onActivate,
}) {
  if (hasFocus &&
      (event.baseKey == term.TermKey.space ||
          event.baseKey == term.TermKey.enter)) {
    onActivate();
    return true;
  }
  return false;
}

/// Wraps [child] in a [Focus] widget that triggers [onFocusRebuild] on focus
/// changes and routes key events to [onKeyEvent].
Widget buildFocusableInteractive({
  required FocusNode focusNode,
  required bool Function() isMounted,
  required void Function() onFocusRebuild,
  required bool Function(term.KeyEvent event) onKeyEvent,
  required Widget child,
}) {
  return Focus(
    focusNode: focusNode,
    onFocusChange: (_) {
      if (isMounted()) onFocusRebuild();
    },
    onKeyEvent: onKeyEvent,
    child: child,
  );
}
