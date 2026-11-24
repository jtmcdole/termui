import 'package:termui/terminal/event.dart';
import 'package:termui/ui/widgets/core/focusable_state_mixin.dart';
import 'package:termui/ui/widgets/core/widget.dart';
import 'package:termui/ui/widgets/interactive/focus.dart';

/// Shared keyboard activation and focus wrapping for [FocusableStateMixin]
/// interactive controls.
extension FocusableInteractiveExtension<T extends StatefulWidget>
    on FocusableStateMixin<T> {
  /// Handles Space/Enter activation when focused and schedules a rebuild.
  bool handleActivationKeyEvent(
    KeyEvent event, {
    required void Function() onActivate,
  }) {
    if ((isWidgetFocused || focusNode.hasFocus) &&
        (event.baseKey == TermKey.space || event.baseKey == TermKey.enter)) {
      onActivate();
      setState(() {});
      return true;
    }
    return false;
  }

  /// Wraps [child] in a [Focus] widget wired to this state's [focusNode].
  Widget buildFocusableInteractive({
    required bool Function(KeyEvent event) onKeyEvent,
    required Widget child,
  }) => Focus(
    focusNode: focusNode,
    onFocusChange: (_) {
      if (mounted) setState(() {});
    },
    onKeyEvent: onKeyEvent,
    child: child,
  );
}
