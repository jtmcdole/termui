import 'package:termui/termui.dart';

/// A stub for PseudoTerminalView on platforms that do not support dart:ffi (like web).
class PseudoTerminalView extends StatelessWidget {
  /// The running pseudo-terminal process (dynamic to avoid importing pty2).
  final dynamic pty;

  /// If true, the terminal will use a transparent background.
  final bool transparentBackground;

  /// The default foreground color.
  final Color? defaultForeground;

  /// Optional focus node.
  final FocusNode? focusNode;

  /// Optional callback invoked when the underlying PTY process exits.
  final void Function(int exitCode)? onExit;

  /// Creates a stubbed [PseudoTerminalView].
  const PseudoTerminalView({
    super.key,
    required this.pty,
    this.transparentBackground = false,
    this.defaultForeground,
    this.focusNode,
    this.onExit,
  });

  @override
  Widget build(BuildContext context) {
    return const SizedBox();
  }
}
